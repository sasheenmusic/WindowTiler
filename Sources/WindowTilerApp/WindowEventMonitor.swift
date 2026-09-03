import AppKit
import ApplicationServices

/// Reports when the set of visible windows may have changed, without polling.
/// It listens to each running app through Accessibility observers and to the
/// system for launches, quits, hides, Space switches, and display changes.
final class WindowEventMonitor {
    private var observers: [pid_t: AXObserver] = [:]
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
        for pid in livePIDs where observers[pid] == nil {
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
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var registered = false
        for name in Self.applicationNotifications {
            let status = AXObserverAddNotification(observer, app, name as CFString, refcon)
            if status == .success || status == .notificationAlreadyRegistered {
                registered = true
            }
        }
        // An app that is still starting up may refuse every notification.
        // Leaving it unregistered lets the next refresh try again.
        guard registered else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer

        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] {
            windows.forEach { watchWindow($0, with: observer) }
        }
    }

    private func watchWindow(_ window: AXUIElement, with observer: AXObserver) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.windowNotifications {
            AXObserverAddNotification(observer, window, name as CFString, refcon)
        }
    }

    private func detach(_ observer: AXObserver) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}
