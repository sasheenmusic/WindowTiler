import AppKit
import WindowTilerCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tiler = WindowTiler()
    private var statusItem: NSStatusItem!
    private var hotKeyManager: HotKeyManager!
    private var eventMonitor: WindowEventMonitor?
    private var shortcutItems: [NSMenuItem] = []
    private var windowsPerRowItems: [NSMenuItem] = []
    private var autoRetileItem: NSMenuItem!
    private var swapByDraggingItem: NSMenuItem!
    private var dragSwap: DragSwapController?
    private let layoutPanel = LayoutPanel()
    /// A layout the user picked in the panel. Active only while automatic
    /// re-tiling is off; ends by itself when the visible window set changes.
    private var handPickedPlan: RowPlan?
    private var settleTimer: Timer?
    private var safetyNetTimer: Timer?
    private var lastTopology: String?
    private var isTiling = false
    /// Set by a Space switch: tile on the next check even if the window
    /// count signature did not change (another Space can hold the same
    /// number of windows of the same apps).
    private var tileRequested = false
    /// Window events arrive in bursts (an app opening three windows, a Space
    /// switch). Wait for them to stop before reading the window list once.
    private let settleTime: TimeInterval = 0.25
    /// Accessibility observers can miss an app that was still starting up.
    /// A slow poll catches anything the observers did not report.
    private let safetyNetInterval: TimeInterval = 3
    private let shortcutDefaultsKey = "shortcutIndex"
    private let autoRetileDefaultsKey = "autoRetile"
    private let windowsPerRowDefaultsKey = "windowsPerRow"
    private let swapByDraggingDefaultsKey = "swapByDragging"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.notice("Window Tiler launched")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "diagnostics.lastLaunchAt")
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.grid.2x2", accessibilityDescription: "Window Tiler")
        hotKeyManager = HotKeyManager { [weak self] in self?.tileWindows() }
        layoutPanel.onApply = { [weak self] plan in self?.applyHandPickedPlan(plan) }
        layoutPanel.onAutomatic = { [weak self] in self?.chooseAutomaticLayout() }
        buildMenu()
        selectShortcut(index: savedShortcutIndex(), interactive: false)
        selectWindowsPerRow(savedWindowsPerRow(), interactive: false)

        let accessibilityEnabled = tiler.isAccessibilityEnabled(prompt: true)
        UserDefaults.standard.set(accessibilityEnabled, forKey: "diagnostics.accessibilityEnabled")
        startWindowMonitor()
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

        swapByDraggingItem = NSMenuItem(title: "Swap Windows by Dragging", action: #selector(toggleSwapByDragging), keyEquivalent: "")
        swapByDraggingItem.target = self
        swapByDraggingItem.state = isSwapByDraggingEnabled ? .on : .off
        menu.addItem(swapByDraggingItem)

        let layoutItem = NSMenuItem(title: "Choose Layout…", action: #selector(openLayoutPanel), keyEquivalent: "")
        layoutItem.target = self
        menu.addItem(layoutItem)
        menu.addItem(.separator())

        let perRowHeading = NSMenuItem(title: "Windows Per Row", action: nil, keyEquivalent: "")
        perRowHeading.isEnabled = false
        menu.addItem(perRowHeading)
        windowsPerRowItems = TilingLimits.windowsPerRowChoices.map { count in
            let item = NSMenuItem(title: "\(count)", action: #selector(windowsPerRowSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = count
            menu.addItem(item)
            return item
        }
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

    private func savedWindowsPerRow() -> Int {
        let stored = UserDefaults.standard.integer(forKey: windowsPerRowDefaultsKey)
        return TilingLimits.windowsPerRowChoices.contains(stored) ? stored : TilingLimits.defaultWindowsPerRow
    }

    @objc private func windowsPerRowSelected(_ sender: NSMenuItem) {
        selectWindowsPerRow(sender.tag, interactive: true)
    }

    /// - Parameter interactive: the user just picked this, so the screen
    ///   should reflect it now. A hand-picked layout ends (the setting shapes
    ///   the automatic layout, and picking it means wanting that layout).
    private func selectWindowsPerRow(_ count: Int, interactive: Bool) {
        guard TilingLimits.windowsPerRowChoices.contains(count) else { return }
        UserDefaults.standard.set(count, forKey: windowsPerRowDefaultsKey)
        tiler.windowsPerRow = count
        windowsPerRowItems.forEach { $0.state = $0.tag == count ? .on : .off }
        guard interactive else { return }
        Log.app.notice("Windows per row set to \(count)")
        if handPickedPlan != nil {
            chooseAutomaticLayout()
        } else if isAutoRetileEnabled {
            performTile(showFeedback: false, relearn: false, reason: "windows per row set to \(count)")
        }
    }

    private var isSwapByDraggingEnabled: Bool {
        if UserDefaults.standard.object(forKey: swapByDraggingDefaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: swapByDraggingDefaultsKey)
    }

    @objc private func toggleSwapByDragging() {
        let enabled = !isSwapByDraggingEnabled
        UserDefaults.standard.set(enabled, forKey: swapByDraggingDefaultsKey)
        swapByDraggingItem.state = enabled ? .on : .off
        dragSwap?.isEnabled = enabled
        Log.app.notice("Swap by dragging \(enabled ? "on" : "off", privacy: .public)")
    }

    /// The user released a dragged window. Runs under the tiling lock so
    /// the window-change path stays quiet while windows are placed.
    private func finishDrag(_ element: AXUIElement, startFrame: CGRect, pointer: CGPoint) {
        guard !isTiling else { return }
        isTiling = true
        defer { isTiling = false }
        let outcome = tiler.finishDrag(of: element, startFrame: startFrame, pointer: pointer)
        let reason: String
        switch outcome {
        case .swapped: reason = "drag swap"
        case .snappedBack: reason = "drag snapped back"
        case .ignored: return
        }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.windowtiler.app.didTile"),
            object: nil,
            userInfo: ["reason": reason],
            deliverImmediately: true
        )
    }

    private var isAutoRetileEnabled: Bool {
        if UserDefaults.standard.object(forKey: autoRetileDefaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: autoRetileDefaultsKey)
    }

    @objc private func shortcutSelected(_ sender: NSMenuItem) {
        selectShortcut(index: sender.tag, interactive: true)
    }

    /// - Parameter interactive: the user just picked this shortcut, so a
    ///   failure deserves an alert. At launch a failure is only logged; a
    ///   modal alert there would block startup.
    private func selectShortcut(index: Int, interactive: Bool) {
        guard HotKeyChoice.choices.indices.contains(index) else { return }
        let registered = hotKeyManager.register(HotKeyChoice.choices[index])
        UserDefaults.standard.set(registered, forKey: "diagnostics.hotKeyRegistered")
        shortcutItems.enumerated().forEach { $0.element.state = $0.offset == index && registered ? .on : .off }
        if registered {
            Log.app.notice("Registered shortcut \(HotKeyChoice.choices[index].title, privacy: .public)")
            UserDefaults.standard.set(index, forKey: shortcutDefaultsKey)
            statusItem.button?.toolTip = "Window Tiler — \(HotKeyChoice.choices[index].title)"
        } else {
            Log.app.error("Could not register shortcut \(HotKeyChoice.choices[index].title, privacy: .public)")
            statusItem.button?.toolTip = "Window Tiler — no shortcut registered"
            if interactive {
                showAlert(title: "Shortcut unavailable", message: "Another app is already using that shortcut. Choose a different one from the Window Tiler menu.")
            }
        }
    }

    @objc private func tileWindows() {
        performTile(showFeedback: true, relearn: true, reason: "hotkey or menu")
    }

    private func performTile(showFeedback: Bool, relearn: Bool, reason: String) {
        guard tiler.isAccessibilityEnabled(prompt: showFeedback) else {
            if showFeedback { showPermissionHelp() }
            return
        }
        guard !isTiling else { return }
        isTiling = true
        defer { isTiling = false }

        let started = CFAbsoluteTimeGetCurrent()
        let result = tiler.tileAllWindows(relearn: relearn, plan: handPickedPlan)
        let durationMilliseconds = Int((CFAbsoluteTimeGetCurrent() - started) * 1_000)
        rememberTopology()
        // Lightweight signal for the live test harness (no disk writes).
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.windowtiler.app.didTile"),
            object: nil,
            userInfo: ["reason": reason, "tiled": result.tiled, "constrained": result.constrained, "failed": result.failed],
            deliverImmediately: true
        )
        Log.tiling.notice("[\(reason, privacy: .public)] tiled \(result.tiled) fixed-size \(result.constrained) failed \(result.failed) in \(durationMilliseconds) ms")
        if showFeedback && result.tiled == 0 && result.constrained == 0 {
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
        setAutoRetile(!isAutoRetileEnabled, reason: "automatic re-tiling enabled")
    }

    /// Turning automatic re-tiling on always means the automatic layout, so
    /// any hand-picked plan ends here.
    private func setAutoRetile(_ enabled: Bool, reason: String) {
        if enabled { handPickedPlan = nil }
        UserDefaults.standard.set(enabled, forKey: autoRetileDefaultsKey)
        autoRetileItem.state = enabled ? .on : .off
        rememberTopology()
        if enabled { performTile(showFeedback: false, relearn: false, reason: reason) }
    }

    // MARK: - Hand-picked layout

    @objc private func openLayoutPanel() {
        layoutPanel.show(near: statusItem.button, windowCount: windowCountForPanel())
    }

    /// The count on the display that holds the menu-bar icon (where the
    /// panel opens). Nil while the window set is unknown.
    private func windowCountForPanel() -> Int? {
        guard let counts = tiler.windowCountsPerScreen() else { return nil }
        let screen = layoutPanel.screenIndex
            ?? statusItem.button?.window?.screen.flatMap { screen in NSScreen.screens.firstIndex(where: { $0 == screen }) }
            ?? 0
        return counts.indices.contains(screen) ? counts[screen] : nil
    }

    private func applyHandPickedPlan(_ plan: RowPlan) {
        handPickedPlan = plan
        UserDefaults.standard.set(false, forKey: autoRetileDefaultsKey)
        autoRetileItem.state = .off
        rememberTopology()
        Log.tiling.notice("Hand-picked rows \(plan.title, privacy: .public); automatic re-tiling paused until the window set changes")
        performTile(showFeedback: true, relearn: true, reason: "hand-picked rows \(plan.title)")
    }

    private func chooseAutomaticLayout() {
        handPickedPlan = nil
        if isAutoRetileEnabled {
            performTile(showFeedback: false, relearn: true, reason: "automatic layout chosen")
        } else {
            setAutoRetile(true, reason: "automatic layout chosen")
        }
    }

    /// The window set changed under a hand-picked layout: that layout was a
    /// one-time arrangement, so automatic re-tiling comes back on its own.
    private func endHandPickedLayout() {
        guard handPickedPlan != nil else { return }
        handPickedPlan = nil
        UserDefaults.standard.set(true, forKey: autoRetileDefaultsKey)
        autoRetileItem.state = .on
        Log.tiling.notice("Visible window set changed; hand-picked layout ends and automatic re-tiling is back on")
    }

    // MARK: - Watching for window changes

    /// Records the current window set as the baseline. An unknown set (an
    /// app is not answering) never replaces a known one.
    private func rememberTopology() {
        if let topology = tiler.windowTopologySignature() {
            lastTopology = topology
        }
    }

    private func startWindowMonitor() {
        rememberTopology()
        let controller = DragSwapController(
            tiler: tiler,
            isBusy: { [weak self] in self?.isTiling ?? true },
            perform: { [weak self] element, startFrame, pointer in
                self?.finishDrag(element, startFrame: startFrame, pointer: pointer)
            }
        )
        controller.isEnabled = isSwapByDraggingEnabled
        dragSwap = controller
        eventMonitor = WindowEventMonitor(
            onChange: { [weak self] in self?.windowsMayHaveChanged() },
            onSpaceChange: { [weak self] in
                self?.tileRequested = true
                self?.windowsMayHaveChanged()
            },
            onWindowMoved: { [weak self] element in self?.dragSwap?.windowMoved(element) }
        )
        safetyNetTimer = Timer.scheduledTimer(withTimeInterval: safetyNetInterval, repeats: true) { [weak self] _ in
            self?.eventMonitor?.refresh()
            self?.checkForWindowChanges()
        }
        safetyNetTimer?.tolerance = safetyNetInterval / 2
    }

    /// Called for every window event. Restarts the settle timer so one check
    /// runs after the burst ends.
    private func windowsMayHaveChanged() {
        guard isAutoRetileEnabled || handPickedPlan != nil || layoutPanel.isVisible else { return }
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: settleTime, repeats: false) { [weak self] _ in
            self?.checkForWindowChanges()
        }
    }

    private func checkForWindowChanges() {
        if layoutPanel.isVisible, !isTiling {
            layoutPanel.update(windowCount: windowCountForPanel())
        }
        guard isAutoRetileEnabled || handPickedPlan != nil,
              !isTiling,
              NSApp.modalWindow == nil,
              tiler.isAccessibilityEnabled(prompt: false) else { return }
        // A nil signature means the state is unknown, not changed. Without a
        // baseline yet, this signature becomes the baseline; nothing is tiled.
        guard let topology = tiler.windowTopologySignature() else { return }
        guard let known = lastTopology else {
            lastTopology = topology
            return
        }
        if tileRequested {
            tileRequested = false
            lastTopology = topology
            endHandPickedLayout()
            performTile(showFeedback: false, relearn: false, reason: "space changed")
            return
        }
        guard topology != known else { return }
        Log.tiling.notice("Visible window set changed. Was: \(known, privacy: .public) Now: \(topology, privacy: .public)")
        lastTopology = topology
        endHandPickedLayout()
        performTile(showFeedback: false, relearn: false, reason: "visible window set changed")
    }

    // MARK: - Alerts

    private func showPermissionHelp() {
        showAlert(
            title: "Allow Window Tiler to move windows",
            message: "In System Settings → Privacy & Security → Accessibility, turn on Window Tiler. Then use the shortcut again."
        )
    }

    private func showAlert(title: String, message: String) {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
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
