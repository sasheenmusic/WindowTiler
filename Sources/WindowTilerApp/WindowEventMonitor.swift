import AppKit
import ApplicationServices

/// Reports when the set of visible windows may have changed, without polling.
/// It listens to each running app through Accessibility observers and to the
/// system for launches, quits, hides, Space switches, and display changes.
final class WindowEventMonitor {
    enum Change { case windowSet, geometry }
    private var observers: [pid_t: AXObserver] = [:]
    private let quarantine = AppQuarantine.shared
    private let messagingTimeout: Float = 1.0
    private var workspaceTokens: [NSObjectProtocol] = []
    private let onChange: (Change) -> Void
    private let onSpaceChange: () -> Void
    private let onWindowMoved: (AXUIElement) -> Void

    /// Registered on the application element; these fire for any window.
    private static let applicationNotifications: [String] = [
        kAXWindowCreatedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXWindowMovedNotification,
    ]

    /// Registered on every window element, existing and newly created.
    private static let windowNotifications: [String] = [
        kAXUIElementDestroyedNotification,
    ]

    /// - Parameters:
    ///   - onChange: the visible window set may have changed.
    ///   - onSpaceChange: the user switched desktops; the owner can refresh
    ///     its window baseline without rearranging the new desktop.
    ///   - onWindowMoved: a window reported a new position (by anyone,
    ///     including Window Tiler itself).
    init(
        onChange: @escaping (Change) -> Void,
        onSpaceChange: @escaping () -> Void,
        onWindowMoved: @escaping (AXUIElement) -> Void = { _ in }
    ) {
        self.onChange = onChange
        self.onSpaceChange = onSpaceChange
        self.onWindowMoved = onWindowMoved
        let workspace = NSWorkspace.shared.notificationCenter
        let workspaceNames: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        workspaceTokens = workspaceNames.map { name in
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
                self?.onChange(.windowSet)
            }
        }
        workspaceTokens.append(workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
            self?.onSpaceChange()
        })
        workspaceTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.onChange(.windowSet) })
        refresh()
    }

    deinit {
        workspaceTokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceTokens.forEach(NotificationCenter.default.removeObserver)
        observers.values.forEach(detach)
    }

    /// Attaches to newly launched apps and forgets apps that have quit. Safe
    /// to call often; apps already observed are left alone.
    func refresh() {
        guard AXIsProcessTrusted() else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ownPID
        }
        let livePIDs = Set(apps.map(\.processIdentifier))
        for (pid, observer) in observers where !livePIDs.contains(pid) {
            detach(observer)
            observers[pid] = nil
        }
        for pid in livePIDs where observers[pid] == nil && !quarantine.contains(pid) {
            attach(pid: pid)
        }
    }

    /// Permission changes invalidate registrations made with the old access.
    func reset() {
        observers.values.forEach(detach)
        observers.removeAll()
        refresh()
    }

    private func attach(pid: pid_t) {
        var observer: AXObserver?
        let callback: AXObserverCallback = { observer, element, notification, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<WindowEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
            if notification as String == kAXWindowCreatedNotification {
                // Destruction is only reported reliably when it was requested
                // on the window itself, so watch each new window directly. If
                // that fails, the whole attachment is redone by the next
                // refresh so the close is not missed.
                let result = monitor.watchWindow(element, with: observer)
                if result != .success, let pid = monitor.observers.first(where: { $0.value == observer })?.key {
                    monitor.invalidate(observer, for: pid, timedOut: result == .timedOut)
                }
            }
            if notification as String == kAXWindowMovedNotification {
                monitor.onWindowMoved(element)
            }
            monitor.onChange(notification as String == kAXWindowMovedNotification ? .geometry : .windowSet)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // An app that is still starting up may refuse registrations or its
        // window list. Nothing is recorded unless every required step
        // succeeds, so the next refresh tries the whole attachment again.
        // An app that does not answer at all is left alone for a while
        // after its first timeout instead of paying one per registration.
        for name in Self.applicationNotifications {
            let status = AXObserverAddNotification(observer, app, name as CFString, refcon)
            if status == .cannotComplete {
                quarantine.add(pid)
                return
            }
            // A notification the app simply does not support is not a failure.
            guard status == .success || status == .notificationAlreadyRegistered || status == .notificationUnsupported else { return }
        }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        if status == .cannotComplete {
            quarantine.add(pid)
            return
        }
        guard status == .success, let windows = value as? [AXUIElement] else { return }
        for window in windows {
            switch watchWindow(window, with: observer) {
            case .success: continue
            case .timedOut:
                quarantine.add(pid)
                return
            case .failed: return
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    private func invalidate(_ observer: AXObserver, for pid: pid_t, timedOut: Bool) {
        detach(observer)
        observers[pid] = nil
        if timedOut { quarantine.add(pid) }
    }

    private enum WatchResult { case success, timedOut, failed }

    @discardableResult
    private func watchWindow(_ window: AXUIElement, with observer: AXObserver) -> WatchResult {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.windowNotifications {
            let status = AXObserverAddNotification(observer, window, name as CFString, refcon)
            if status == .cannotComplete { return .timedOut }
            guard status == .success || status == .notificationAlreadyRegistered || status == .notificationUnsupported else { return .failed }
        }
        return .success
    }

    private func detach(_ observer: AXObserver) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}
