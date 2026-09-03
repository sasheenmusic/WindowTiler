import AppKit
import ApplicationServices

/// Reports when the set of visible windows may have changed, without polling.
/// It listens to each running app through Accessibility observers and to the
/// system for launches, quits, hides, Space switches, and display changes.
final class WindowEventMonitor {
    private var observers: [pid_t: AXObserver] = [:]
    /// Apps whose attachment timed out; not retried before this date.
    private var retryAfter: [pid_t: Date] = [:]
    private let messagingTimeout: Float = 1.0
    private let attachCooldown: TimeInterval = 5
    private var workspaceTokens: [NSObjectProtocol] = []
    private let onChange: () -> Void

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

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let workspace = NSWorkspace.shared.notificationCenter
        let workspaceNames: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        workspaceTokens = workspaceNames.map { name in
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
                self?.onChange()
            }
        }
        workspaceTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.onChange() })
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
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ownPID
        }
        let livePIDs = Set(apps.map(\.processIdentifier))
        for (pid, observer) in observers where !livePIDs.contains(pid) {
            detach(observer)
            observers[pid] = nil
        }
        retryAfter = retryAfter.filter { livePIDs.contains($0.key) && $0.value > Date() }
        for pid in livePIDs where observers[pid] == nil && retryAfter[pid] == nil {
            attach(pid: pid)
        }
    }

    private func attach(pid: pid_t) {
        var observer: AXObserver?
        let callback: AXObserverCallback = { observer, element, notification, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<WindowEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
            if notification as String == kAXWindowCreatedNotification {
                // Destruction is only reported reliably when it was requested
                // on the window itself, so watch each new window directly.
                monitor.watchWindow(element, with: observer)
            }
            monitor.onChange()
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
                retryAfter[pid] = Date().addingTimeInterval(attachCooldown)
                return
            }
            // A notification the app simply does not support is not a failure.
            guard status == .success || status == .notificationAlreadyRegistered || status == .notificationUnsupported else { return }
        }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        if status == .cannotComplete {
            retryAfter[pid] = Date().addingTimeInterval(attachCooldown)
            return
        }
        guard status == .success, let windows = value as? [AXUIElement] else { return }
        for window in windows {
            switch watchWindow(window, with: observer) {
            case .success: continue
            case .timedOut:
                retryAfter[pid] = Date().addingTimeInterval(attachCooldown)
                return
            case .failed: return
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
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
