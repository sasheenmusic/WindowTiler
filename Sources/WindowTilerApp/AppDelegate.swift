import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tiler = WindowTiler()
    private var statusItem: NSStatusItem!
    private var hotKeyManager: HotKeyManager!
    private var shortcutItems: [NSMenuItem] = []
    private var autoRetileItem: NSMenuItem!
    private var monitorTimer: Timer?
    private var lastTopology: String?
    private var pendingTopology: String?
    private var pendingTopologySince: Date?
    private let monitorInterval: TimeInterval = 0.1
    private let topologySettleTime: TimeInterval = 0.2
    private let shortcutDefaultsKey = "shortcutIndex"
    private let autoRetileDefaultsKey = "autoRetile"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Window Tiler launched")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "diagnostics.lastLaunchAt")
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.grid.2x2", accessibilityDescription: "Window Tiler")
        hotKeyManager = HotKeyManager { [weak self] in self?.tileWindows() }
        buildMenu()
        selectShortcut(index: savedShortcutIndex())
        startWindowMonitor()

        let accessibilityEnabled = tiler.isAccessibilityEnabled(prompt: true)
        UserDefaults.standard.set(accessibilityEnabled, forKey: "diagnostics.accessibilityEnabled")
        if !accessibilityEnabled {
            showPermissionHelp()
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        let tileItem = NSMenuItem(title: "Tile All Windows", action: #selector(tileWindows), keyEquivalent: "")
        tileItem.target = self
        menu.addItem(tileItem)

        autoRetileItem = NSMenuItem(title: "Automatically Re-tile When Windows Change", action: #selector(toggleAutoRetile), keyEquivalent: "")
        autoRetileItem.target = self
        autoRetileItem.state = isAutoRetileEnabled ? .on : .off
        menu.addItem(autoRetileItem)
        menu.addItem(.separator())

        let heading = NSMenuItem(title: "Keyboard Shortcut", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)

        shortcutItems = HotKeyChoice.choices.enumerated().map { index, choice in
            let item = NSMenuItem(title: choice.title, action: #selector(shortcutSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
            return item
        }

        menu.addItem(.separator())
        let permissionItem = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Window Tiler", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func savedShortcutIndex() -> Int {
        let stored = UserDefaults.standard.integer(forKey: shortcutDefaultsKey)
        return HotKeyChoice.choices.indices.contains(stored) ? stored : 0
    }

    private var isAutoRetileEnabled: Bool {
        if UserDefaults.standard.object(forKey: autoRetileDefaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: autoRetileDefaultsKey)
    }

    @objc private func shortcutSelected(_ sender: NSMenuItem) {
        selectShortcut(index: sender.tag)
    }

    private func selectShortcut(index: Int) {
        guard HotKeyChoice.choices.indices.contains(index) else { return }
        let registered = hotKeyManager.register(HotKeyChoice.choices[index])
        UserDefaults.standard.set(registered, forKey: "diagnostics.hotKeyRegistered")
        shortcutItems.enumerated().forEach { $0.element.state = $0.offset == index && registered ? .on : .off }
        if registered {
            NSLog("Window Tiler registered shortcut %@", HotKeyChoice.choices[index].title)
            UserDefaults.standard.set(index, forKey: shortcutDefaultsKey)
            statusItem.button?.toolTip = "Window Tiler — \(HotKeyChoice.choices[index].title)"
        } else {
            NSLog("Window Tiler could not register shortcut %@", HotKeyChoice.choices[index].title)
            showAlert(title: "Shortcut unavailable", message: "Another app is already using that shortcut. Choose a different one from the Window Tiler menu.")
        }
    }

    @objc private func tileWindows() {
        performTile(showFeedback: true, reason: "hotkey or menu")
    }

    private func performTile(showFeedback: Bool, reason: String) {
        guard tiler.isAccessibilityEnabled(prompt: true) else {
            if showFeedback { showPermissionHelp() }
            return
        }
        let started = CFAbsoluteTimeGetCurrent()
        let result = tiler.tileAllWindows()
        let durationMilliseconds = Int((CFAbsoluteTimeGetCurrent() - started) * 1_000)
        lastTopology = tiler.windowTopologySignature()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "diagnostics.lastTileAt")
        UserDefaults.standard.set(reason, forKey: "diagnostics.lastTileReason")
        UserDefaults.standard.set(result.tiled, forKey: "diagnostics.lastTiledCount")
        UserDefaults.standard.set(result.constrained, forKey: "diagnostics.lastConstrainedCount")
        UserDefaults.standard.set(result.failed, forKey: "diagnostics.lastFailedCount")
        UserDefaults.standard.set(durationMilliseconds, forKey: "diagnostics.lastTileDurationMilliseconds")
        NSLog(
            "Window Tiler [%@]: tiled %d, fixed-size %d, failed %d",
            reason,
            result.tiled,
            result.constrained,
            result.failed
        )
        if showFeedback && result.tiled == 0 {
            showAlert(title: "No windows tiled", message: "No normal app windows were available to move.")
        } else if showFeedback && (result.constrained > 0 || result.failed > 0) {
            var details = "Tiled \(result.tiled) resizable windows."
            if result.constrained > 0 {
                details += " Fitted \(result.constrained) bounded windows and tiled everything else around them."
            }
            if result.failed > 0 {
                details += " \(result.failed) windows could not be moved."
            }
            showAlert(title: "Tiling finished", message: details)
        }
    }

    @objc private func toggleAutoRetile() {
        let enabled = !isAutoRetileEnabled
        UserDefaults.standard.set(enabled, forKey: autoRetileDefaultsKey)
        autoRetileItem.state = enabled ? .on : .off
        lastTopology = tiler.windowTopologySignature()
        if enabled { performTile(showFeedback: false, reason: "automatic re-tiling enabled") }
    }

    private func startWindowMonitor() {
        lastTopology = tiler.windowTopologySignature()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: monitorInterval, repeats: true) { [weak self] _ in
            self?.checkForWindowChanges()
        }
        if let monitorTimer {
            RunLoop.main.add(monitorTimer, forMode: .common)
        }
    }

    private func checkForWindowChanges() {
        guard isAutoRetileEnabled, tiler.isAccessibilityEnabled(prompt: false) else { return }
        let topology = tiler.windowTopologySignature()
        guard topology != lastTopology else {
            pendingTopology = nil
            pendingTopologySince = nil
            return
        }
        if topology != pendingTopology {
            pendingTopology = topology
            pendingTopologySince = Date()
            return
        }
        guard let since = pendingTopologySince,
              Date().timeIntervalSince(since) >= topologySettleTime else { return }
        NSLog("Window Tiler detected a visible window-set change")
        pendingTopology = nil
        pendingTopologySince = nil
        lastTopology = topology
        performTile(showFeedback: false, reason: "visible window set changed")
    }

    private func showPermissionHelp() {
        showAlert(
            title: "Allow Window Tiler to move windows",
            message: "In System Settings → Privacy & Security → Accessibility, turn on Window Tiler. Then use the shortcut again."
        )
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
