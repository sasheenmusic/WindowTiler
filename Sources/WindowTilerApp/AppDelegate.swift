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
    private var appUpdater: AppUpdater?
    private let layoutPanel = LayoutPanel()
    private let presetPanel = PresetPanel()
    private let presetWindows = PresetWindowService()
    private let presetStore = PresetStore(fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WindowTiler/presets.json"))
    private var presets: [LayoutPreset] = []
    private var activePresetID: UUID?
    private var presetHotKeys: [UUID: HotKeyManager] = [:]
    private var presetLoadError: String?
    private var applicationRevision = 0
    private var suppressSpaceEventsUntil = Date.distantPast
    private var needsSpaceBaseline = false
    private var pendingWindowSetChange = false
    private var needsPermissionRetile = false
    private var lastAccessibilityEnabled = false
    private var isShowingPermissionHelp = false
    private var spaceTransitionTimer: Timer?
    /// A layout the user picked in the panel. Active only while automatic
    /// re-tiling is off; ends by itself when the visible window set changes.
    private var handPickedPlan: RowPlan?
    private var deferredTilingTimer: Timer?
    private var settleTimer: Timer?
    private var safetyNetTimer: Timer?
    private var lastTopology: String?
    private var isTiling = false
    private var isOrdinaryTiling = false
    private var queuedPresetID: UUID?
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
        configurePresets()
        appUpdater = AppUpdater(isIdle: { [weak self] in
            guard let self else { return false }
            return !self.isTiling && !self.isOrdinaryTiling && !self.presetWindows.isApplying
                && !self.presetPanel.isRecordingShortcut && NSApp.modalWindow == nil
                && NSEvent.pressedMouseButtons == 0
                && !NSApp.windows.contains { $0.isVisible && $0.level != .statusBar }
        })
        appUpdater?.onWillRelaunch = { [weak self] in self?.rememberPresetForUpdate() }
        buildMenu()
        selectShortcut(index: savedShortcutIndex(), interactive: false)
        selectWindowsPerRow(savedWindowsPerRow(), interactive: false)
        registerPresetShortcuts()

        let accessibilityEnabled = tiler.isAccessibilityEnabled(prompt: false)
        lastAccessibilityEnabled = accessibilityEnabled
        UserDefaults.standard.set(accessibilityEnabled, forKey: "diagnostics.accessibilityEnabled")
        startWindowMonitor()
        if !accessibilityEnabled {
            showPermissionHelp()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Sparkle also asks here before a manual install. Do not cut off a
        // window placement or asynchronous cross-desktop rollback in progress.
        guard !isTiling, !isOrdinaryTiling, !presetWindows.isApplying else {
            showPresetFeedback(["Wait for the current layout to finish, then quit or install the update again."])
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        appUpdater?.shutdown()
        applicationRevision += 1
        presetWindows.cancel()
        settleTimer?.invalidate()
        safetyNetTimer?.invalidate()
        feedbackTimer?.invalidate()
        deferredTilingTimer?.invalidate()
        spaceTransitionTimer?.invalidate()
    }

    private func buildMenu() {
        let menu = NSMenu()
        let tileItem = NSMenuItem(title: "Tile All Windows", action: #selector(tileWindows), keyEquivalent: "")
        tileItem.target = self
        menu.addItem(tileItem)

        autoRetileItem = NSMenuItem(title: "Automatically Re-tile When Windows Change", action: #selector(toggleAutoRetile), keyEquivalent: "")
        autoRetileItem.target = self
        autoRetileItem.state = isAutoRetileEnabled && activePresetID == nil ? .on : .off
        menu.addItem(autoRetileItem)

        swapByDraggingItem = NSMenuItem(title: "Swap Windows by Dragging", action: #selector(toggleSwapByDragging), keyEquivalent: "")
        swapByDraggingItem.target = self
        swapByDraggingItem.state = isSwapByDraggingEnabled ? .on : .off
        menu.addItem(swapByDraggingItem)

        let layoutItem = NSMenuItem(title: "Choose Layout…", action: #selector(openLayoutPanel), keyEquivalent: "")
        layoutItem.target = self
        menu.addItem(layoutItem)
        menu.addItem(.separator())
        let presetsHeading = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        presetsHeading.isEnabled = false
        menu.addItem(presetsHeading)
        if presets.isEmpty {
            let empty = NSMenuItem(title: "No saved presets", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for preset in presets {
            let item = NSMenuItem(title: preset.name, action: #selector(presetSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.id.uuidString
            item.state = activePresetID == preset.id ? .on : .off
            menu.addItem(item)
        }
        let savePreset = NSMenuItem(title: "Save Preset…", action: #selector(savePresetPressed), keyEquivalent: "")
        savePreset.target = self
        menu.addItem(savePreset)
        let managePresets = NSMenuItem(title: "Manage Presets…", action: #selector(managePresetsPressed), keyEquivalent: "")
        managePresets.target = self
        menu.addItem(managePresets)
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

        // Menu construction already runs on AppKit's main thread.
        MainActor.assumeIsolated { appUpdater?.appendMenuItems(to: menu) }
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
        if activePresetID != nil { return }
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
        dragSwap?.isEnabled = enabled && activePresetID == nil
        Log.app.notice("Swap by dragging \(enabled ? "on" : "off", privacy: .public)")
    }

    /// The user released a dragged window. Runs under the tiling lock so
    /// the window-change path stays quiet while windows are placed.
    private func finishDrag(_ element: AXUIElement, startFrame: CGRect, pointer: CGPoint) {
        guard !isTiling, !presetWindows.isApplying, activePresetID == nil else { return }
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
        let choice = HotKeyChoice.choices[index]
        if interactive, let conflict = presets.first(where: { $0.shortcut?.keyCode == choice.keyCode && $0.shortcut?.modifiers == choice.modifiers }) {
            if interactive { showAlert(title: "Shortcut already used", message: "This shortcut belongs to the preset “\(conflict.name)”.") }
            return
        }
        let registered = hotKeyManager.register(choice)
        UserDefaults.standard.set(hotKeyManager.currentChoice != nil, forKey: "diagnostics.hotKeyRegistered")
        let selectedIndex = registered ? index : savedShortcutIndex()
        shortcutItems.enumerated().forEach { $0.element.state = $0.offset == selectedIndex && hotKeyManager.currentChoice != nil ? .on : .off }
        if registered {
            Log.app.notice("Registered shortcut \(HotKeyChoice.choices[index].title, privacy: .public)")
            UserDefaults.standard.set(index, forKey: shortcutDefaultsKey)
            statusItem.button?.toolTip = "Window Tiler — \(HotKeyChoice.choices[index].title)"
        } else {
            Log.app.error("Could not register shortcut \(HotKeyChoice.choices[index].title, privacy: .public)")
            if hotKeyManager.currentChoice == nil { statusItem.button?.toolTip = "Window Tiler — no shortcut registered" }
            if interactive {
                showAlert(title: "Shortcut unavailable", message: "Another app is already using that shortcut. Choose a different one from the Window Tiler menu.")
            }
        }
    }

    @objc private func tileWindows() {
        if let activePresetID {
            applyPreset(activePresetID)
            return
        }
        guard !isTiling, tiler.isAccessibilityEnabled(prompt: false) else {
            if !tiler.isAccessibilityEnabled(prompt: false) { showPermissionHelp() }
            return
        }
        isTiling = true
        applicationRevision += 1
        let revision = applicationRevision
        presetWindows.gatherForTiling { [weak self] failures in
            guard let self, self.applicationRevision == revision else { return }
            self.isTiling = false
            if self.presetWindows.lastOperationWasCancelled {
                self.rememberTopology()
                if !failures.isEmpty { self.showPresetFeedback(failures) }
                return
            }
            self.performTile(showFeedback: true, relearn: true, reason: "hotkey or menu")
            if !failures.isEmpty { self.showPresetFeedback(failures) }
        }
    }

    private func performTile(showFeedback: Bool, relearn: Bool, reason: String) {
        guard tiler.isAccessibilityEnabled(prompt: false) else {
            if showFeedback { showPermissionHelp() }
            return
        }
        guard activePresetID == nil else { return }
        deferredTilingTimer?.invalidate()
        if isOrdinaryTiling || presetWindows.isApplying {
            let revision = applicationRevision
            deferredTilingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                guard let self, self.applicationRevision == revision else { return }
                self.performTile(showFeedback: showFeedback, relearn: relearn, reason: reason)
            }
            return
        }
        guard !isTiling else { return }
        _ = refreshAccessibilityState()
        pendingWindowSetChange = false
        needsPermissionRetile = false
        isTiling = true
        isOrdinaryTiling = true
        defer {
            isOrdinaryTiling = false
            isTiling = false
            if let queued = queuedPresetID {
                queuedPresetID = nil
                applyPreset(queued)
            }
        }

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
        if pendingWindowSetChange { windowsMayHaveChanged() }
    }

    @objc private func toggleAutoRetile() {
        if activePresetID != nil {
            deactivatePreset()
        } else {
            setAutoRetile(!isAutoRetileEnabled, reason: "automatic re-tiling enabled")
        }
    }

    /// Turning automatic re-tiling on always means the automatic layout, so
    /// any hand-picked plan ends here.
    private func setAutoRetile(_ enabled: Bool, reason: String) {
        if !enabled {
            deferredTilingTimer?.invalidate()
            pendingWindowSetChange = false
            needsPermissionRetile = false
        }
        if enabled { handPickedPlan = nil }
        UserDefaults.standard.set(enabled, forKey: autoRetileDefaultsKey)
        autoRetileItem.state = enabled && activePresetID == nil ? .on : .off
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
        guard !presetWindows.isApplying, let counts = tiler.windowCountsPerScreen() else { return nil }
        return windowCountForPanel(from: counts)
    }

    private func windowCountForPanel(from counts: [Int]?) -> Int? {
        guard let counts else { return nil }
        let screen = layoutPanel.screenIndex
            ?? statusItem.button?.window?.screen.flatMap { screen in NSScreen.screens.firstIndex(where: { $0 == screen }) }
            ?? 0
        return counts.indices.contains(screen) ? counts[screen] : nil
    }

    private func applyHandPickedPlan(_ plan: RowPlan) {
        clearPresetSession()
        handPickedPlan = plan
        UserDefaults.standard.set(false, forKey: autoRetileDefaultsKey)
        autoRetileItem.state = .off
        rememberTopology()
        Log.tiling.notice("Hand-picked rows \(plan.title, privacy: .public); automatic re-tiling paused until the window set changes")
        performTile(showFeedback: true, relearn: true, reason: "hand-picked rows \(plan.title)")
    }

    private func chooseAutomaticLayout() {
        clearPresetSession()
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
        guard refreshAccessibilityState(), !presetWindows.isApplying else { return }
        if let topology = tiler.windowTopologySignature() {
            lastTopology = topology
            needsSpaceBaseline = Date() < suppressSpaceEventsUntil
        }
    }

    @discardableResult
    private func refreshAccessibilityState() -> Bool {
        let enabled = tiler.isAccessibilityEnabled(prompt: false)
        guard enabled != lastAccessibilityEnabled else { return enabled }
        lastAccessibilityEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "diagnostics.accessibilityEnabled")
        tiler.resetAccessibilityState()
        eventMonitor?.reset()
        lastTopology = nil
        if enabled, activePresetID == nil, isAutoRetileEnabled || handPickedPlan != nil {
            needsPermissionRetile = true
        }
        return enabled
    }

    private func startWindowMonitor() {
        rememberTopology()
        let controller = DragSwapController(
            tiler: tiler,
            isBusy: { [weak self] in
                guard let self else { return true }
                return self.isTiling || self.presetWindows.isApplying
            },
            perform: { [weak self] element, startFrame, pointer in
                self?.finishDrag(element, startFrame: startFrame, pointer: pointer)
            }
        )
        controller.isEnabled = isSwapByDraggingEnabled && activePresetID == nil
        dragSwap = controller
        eventMonitor = WindowEventMonitor(
            onChange: { [weak self] change in self?.windowsMayHaveChanged(change) },
            onSpaceChange: { [weak self] in
                guard let self else { return }
                // Space navigation is not a request to rearrange windows. Wait
                // for the transition, then accept its window set as a baseline.
                self.suppressSpaceEventsUntil = Date().addingTimeInterval(1)
                self.needsSpaceBaseline = true
                self.spaceTransitionTimer?.invalidate()
                self.spaceTransitionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                    guard let self, !self.isTiling, self.needsSpaceBaseline else { return }
                    if self.activePresetID == nil, self.isAutoRetileEnabled || self.handPickedPlan != nil {
                        self.checkForWindowChanges()
                    } else {
                        self.rememberTopology()
                    }
                }
                self.windowsMayHaveChanged()
            },
            onWindowMoved: { [weak self] element in self?.dragSwap?.windowMoved(element) }
        )
        safetyNetTimer = Timer.scheduledTimer(withTimeInterval: safetyNetInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.refreshAccessibilityState() { self.eventMonitor?.refresh() }
            self.checkForWindowChanges()
        }
        safetyNetTimer?.tolerance = safetyNetInterval / 2
    }

    /// Called for every window event. Restarts the settle timer so one check
    /// runs after the burst ends.
    private func windowsMayHaveChanged(_ change: WindowEventMonitor.Change = .geometry) {
        if change == .windowSet, activePresetID == nil, isAutoRetileEnabled || handPickedPlan != nil,
           needsSpaceBaseline || isTiling || presetWindows.isApplying || NSApp.modalWindow != nil {
            pendingWindowSetChange = true
        }
        guard activePresetID == nil || layoutPanel.isVisible else { return }
        guard isAutoRetileEnabled || handPickedPlan != nil || layoutPanel.isVisible else { return }
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: settleTime, repeats: false) { [weak self] _ in
            self?.checkForWindowChanges()
        }
    }

    private func checkForWindowChanges() {
        guard refreshAccessibilityState() else { return }
        let canCheckTopology = activePresetID == nil
            && (isAutoRetileEnabled || handPickedPlan != nil)
            && !isTiling && !presetWindows.isApplying && NSApp.modalWindow == nil
        let topology: String?
        if layoutPanel.isVisible, !isTiling, canCheckTopology {
            let snapshot = tiler.windowTopologyAndCounts()
            layoutPanel.update(windowCount: windowCountForPanel(from: snapshot?.counts))
            topology = snapshot?.signature
        } else {
            topology = canCheckTopology ? tiler.windowTopologySignature() : nil
            if layoutPanel.isVisible, !isTiling {
                layoutPanel.update(windowCount: windowCountForPanel())
            }
        }
        // A nil signature means the state is unknown, not changed. Without a
        // baseline yet, this signature becomes the baseline; nothing is tiled.
        guard canCheckTopology, let topology else { return }
        if needsSpaceBaseline {
            lastTopology = topology
            guard Date() >= suppressSpaceEventsUntil else { return }
            needsSpaceBaseline = false
            guard pendingWindowSetChange || needsPermissionRetile else { return }
        }
        let known = lastTopology
        guard known != nil || pendingWindowSetChange || needsPermissionRetile else {
            lastTopology = topology
            return
        }
        let changedTopology = known.map { $0 != topology } ?? false
        guard changedTopology || pendingWindowSetChange || needsPermissionRetile else { return }
        let reason = needsPermissionRetile ? "accessibility permission enabled" : "visible window set changed"
        Log.tiling.notice("[\(reason, privacy: .public)] Was: \(known ?? "unknown", privacy: .public) Now: \(topology, privacy: .public)")
        lastTopology = topology
        if changedTopology || pendingWindowSetChange { endHandPickedLayout() }
        performTile(showFeedback: false, relearn: false, reason: reason)
    }

    // MARK: - Saved presets

    private func configurePresets() {
        do { presets = try presetStore.load() }
        catch { presetLoadError = "Saved presets could not be read. The file has been left unchanged. \(error.localizedDescription)" }
        restorePresetAfterUpdate()
        presetPanel.onSaveNew = { [weak self] in self?.savePreset($0, isNew: true) ?? false }
        presetPanel.onChange = { [weak self] in _ = self?.savePreset($0, isNew: false) }
        presetPanel.onDelete = { [weak self] in self?.deletePreset($0) }
        presetPanel.onApply = { [weak self] in self?.applyPreset($0) }
        presetPanel.onNew = { [weak self] in self?.savePresetPressed() }
        presetPanel.onUpdate = { [weak self] in self?.updatePresetFromWindows($0) }
        presetPanel.onValidateShortcut = { [weak self] shortcut, id in self?.shortcutConflict(shortcut, excluding: id) }
        presetPanel.onRecordingShortcutChange = { [weak self] recording in
            guard let self else { return }
            let managers = [self.hotKeyManager! ] + Array(self.presetHotKeys.values)
            if recording { managers.forEach { $0.suspend() } }
            else {
                let restored = managers.map { $0.resume() }
                if restored.contains(false) { self.showPresetFeedback(["A shortcut became unavailable. Choose another in Manage Presets."]) }
            }
        }
    }

    /// An updater restart should keep automatic tiling paused without moving windows.
    /// Consume this once, and only after the app version actually increased.
    private func restorePresetAfterUpdate() {
        let key = "updateResumePreset"
        let marker = UserDefaults.standard.object(forKey: key) as? [String: Any]
        UserDefaults.standard.set(nil, forKey: key)
        guard let marker,
              let previousBuild = marker["build"] as? String,
              let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              currentBuild.compare(previousBuild, options: .numeric) == .orderedDescending,
              let savedAt = marker["savedAt"] as? Double,
              (0...600).contains(Date().timeIntervalSince1970 - savedAt),
              let rawID = marker["presetID"] as? String,
              let id = UUID(uuidString: rawID), presets.contains(where: { $0.id == id }) else { return }
        activePresetID = id
    }

    private func rememberPresetForUpdate() {
        guard let activePresetID,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            UserDefaults.standard.set(nil, forKey: "updateResumePreset")
            return
        }
        UserDefaults.standard.set(["build": build, "savedAt": Date().timeIntervalSince1970,
                                   "presetID": activePresetID.uuidString], forKey: "updateResumePreset")
    }

    private func shortcutConflict(_ shortcut: PresetShortcut, excluding id: UUID?) -> String? {
        let global = HotKeyChoice.choices[savedShortcutIndex()]
        if shortcut.keyCode == global.keyCode && shortcut.modifiers == global.modifiers {
            return "This shortcut is already used for Tile All Windows."
        }
        if let other = presets.first(where: { $0.id != id && $0.shortcut == shortcut }) {
            return "This shortcut is already used by “\(other.name)”."
        }
        return nil
    }

    private func registerPresetShortcuts() {
        for preset in presets {
            guard let shortcut = preset.shortcut else { continue }
            guard shortcutConflict(shortcut, excluding: preset.id) == nil else {
                Log.app.error("Saved preset shortcut conflicts with another shortcut")
                DispatchQueue.main.async { [weak self] in
                    self?.showPresetFeedback(["The shortcut for “\(preset.name)” conflicts with another shortcut. Choose another in Manage Presets."])
                }
                continue
            }
            let manager = makePresetHotKey(preset.id)
            if manager.register(HotKeyChoice(title: preset.name, keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)) {
                presetHotKeys[preset.id] = manager
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.showPresetFeedback(["The shortcut for “\(preset.name)” is unavailable. Choose another in Manage Presets."])
                }
            }
        }
    }

    private func makePresetHotKey(_ id: UUID) -> HotKeyManager {
        HotKeyManager { [weak self] in self?.togglePreset(id) }
    }

    private func refreshPresetControls() {
        buildMenu()
        shortcutItems.enumerated().forEach { $0.element.state = $0.offset == savedShortcutIndex() && hotKeyManager.currentChoice != nil ? .on : .off }
        windowsPerRowItems.forEach { $0.state = $0.tag == savedWindowsPerRow() ? .on : .off }
        dragSwap?.isEnabled = isSwapByDraggingEnabled && activePresetID == nil
        presetPanel.refresh(presets: presets, activeID: activePresetID)
    }

    @objc private func savePresetPressed() {
        if let presetLoadError { presetPanel.showError(presetLoadError); return }
        guard !isTiling, !presetWindows.isApplying else { showPresetFeedback(["Wait for the current layout to finish, then save again."]); return }
        do {
            let screens = try presetWindows.captureScreens()
            presetPanel.showSave(screens: screens, currentScreenID: PresetWindowService.currentScreenID())
        } catch { presetPanel.showError(error.localizedDescription) }
    }

    @objc private func managePresetsPressed() {
        presetPanel.showManage(presets: presets, activeID: activePresetID)
        if let presetLoadError { presetPanel.showError(presetLoadError) }
    }

    @objc private func presetSelected(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value) else { return }
        togglePreset(id)
    }

    private func togglePreset(_ id: UUID) {
        if queuedPresetID == id { queuedPresetID = nil; return }
        if activePresetID == id { deactivatePreset() }
        else { applyPreset(id) }
    }

    @discardableResult
    private func savePreset(_ value: LayoutPreset, isNew: Bool) -> Bool {
        if isNew, isOrdinaryTiling {
            presetPanel.showError("Wait for the current layout to finish, then save again.")
            return false
        }
        guard presetLoadError == nil else { presetPanel.showError(presetLoadError!); return false }
        var preset = value
        preset.name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preset.name.isEmpty else { presetPanel.showError("Give the preset a name."); return false }
        guard !presets.contains(where: { $0.id != preset.id && $0.name.localizedCaseInsensitiveCompare(preset.name) == .orderedSame }) else {
            presetPanel.showError("A preset already has that name.")
            refreshPresetControls()
            return false
        }
        guard preset.screens.contains(where: { $0.isIncluded && !$0.slots.isEmpty }) else {
            presetPanel.showError("Select a screen with at least one saved window.")
            refreshPresetControls()
            return false
        }
        if !preset.rememberApps { preset.launchMissingApps = false }
        let previous = presets.first { $0.id == preset.id }
        var candidateManager: HotKeyManager?
        if let shortcut = preset.shortcut, previous?.shortcut != shortcut || presetHotKeys[preset.id] == nil {
            if let conflict = shortcutConflict(shortcut, excluding: preset.id) {
                presetPanel.showError(conflict)
                refreshPresetControls()
                return false
            }
            let manager = makePresetHotKey(preset.id)
            guard manager.register(HotKeyChoice(title: preset.name, keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)) else {
                presetPanel.showError("That shortcut is unavailable. Try another combination.")
                refreshPresetControls()
                return false
            }
            candidateManager = manager
        }
        var updated = presets
        if let index = updated.firstIndex(where: { $0.id == preset.id }) { updated[index] = preset }
        else { updated.append(preset) }
        do { try presetStore.save(updated) }
        catch {
            presetPanel.showError("The preset could not be saved. \(error.localizedDescription)")
            refreshPresetControls()
            return false
        }
        presets = updated
        if preset.shortcut == nil { presetHotKeys.removeValue(forKey: preset.id) }
        else if let candidateManager { presetHotKeys[preset.id] = candidateManager }
        if isNew {
            // Captured windows already have the requested geometry. Activating
            // without moving them also preserves the user's keyboard focus.
            cancelPresetApplication()
            activePresetID = preset.id
            handPickedPlan = nil
            rememberTopology()
        }
        refreshPresetControls()
        if !isNew, activePresetID == preset.id,
           previous?.screens != preset.screens || previous?.rememberApps != preset.rememberApps || previous?.launchMissingApps != preset.launchMissingApps {
            applyPreset(preset.id)
        }
        return true
    }

    private func updatePresetFromWindows(_ id: UUID) {
        guard var preset = presets.first(where: { $0.id == id }) else { return }
        guard !isTiling, !presetWindows.isApplying else { showPresetFeedback(["Wait for the current layout to finish, then update again."]); return }
        do {
            let captured = try presetWindows.captureScreens()
            var merged = preset.screens
            for var screen in captured {
                if let index = merged.firstIndex(where: { $0.id == screen.id }) {
                    let old = merged[index]
                    screen.isIncluded = old.isIncluded
                    let bound = Set(old.slots.filter { $0.restoreApp }.compactMap { $0.app?.bundleID })
                    let excluded = Set(old.slots.compactMap { $0.app?.bundleID }).subtracting(bound)
                    for index in screen.slots.indices {
                        if let app = screen.slots[index].app, excluded.contains(app.bundleID) { screen.slots[index].restoreApp = false }
                    }
                    merged[index] = screen
                } else {
                    screen.isIncluded = false
                    merged.append(screen)
                }
            }
            preset.screens = merged
            savePreset(preset, isNew: false)
        } catch { presetPanel.showError(error.localizedDescription) }
    }

    private func deletePreset(_ id: UUID) {
        guard presetLoadError == nil else { return }
        let updated = presets.filter { $0.id != id }
        do { try presetStore.save(updated) }
        catch { presetPanel.showError("The preset could not be deleted. \(error.localizedDescription)"); return }
        presets = updated
        presetHotKeys.removeValue(forKey: id)
        if activePresetID == id { deactivatePreset() }
        else { refreshPresetControls() }
    }

    private func cancelPresetApplication() {
        deferredTilingTimer?.invalidate()
        queuedPresetID = nil
        pendingWindowSetChange = false
        needsPermissionRetile = false
        applicationRevision += 1
        presetWindows.cancel()
        isTiling = isOrdinaryTiling
    }

    private func clearPresetSession() {
        cancelPresetApplication()
        activePresetID = nil
        refreshPresetControls()
    }

    private func deactivatePreset() {
        clearPresetSession()
        handPickedPlan = nil
        setAutoRetile(true, reason: "preset turned off")
    }

    private func applyPreset(_ id: UUID) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        if isOrdinaryTiling { queuedPresetID = id; return }
        guard tiler.isAccessibilityEnabled(prompt: false) else { showPermissionHelp(); return }
        cancelPresetApplication()
        let revision = applicationRevision
        activePresetID = id
        handPickedPlan = nil
        isTiling = true
        refreshPresetControls()
        presetWindows.apply(preset) { [weak self] report in
            guard let self, self.applicationRevision == revision else { return }
            self.isTiling = false
            self.rememberTopology()
            self.refreshPresetControls()
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.windowtiler.app.didTile"), object: nil,
                userInfo: ["reason": "preset", "tiled": report.tiled, "failed": report.failures.count], deliverImmediately: true)
            if !report.failures.isEmpty { self.showPresetFeedback(report.failures) }
        }
    }

    private var feedbackPanel: NSPanel?
    private var feedbackTimer: Timer?

    private func showPresetFeedback(_ messages: [String]) {
        feedbackTimer?.invalidate()
        feedbackPanel?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 130),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Window Tiler"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        let label = NSTextField(wrappingLabelWithString: messages.joined(separator: "\n"))
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            content.widthAnchor.constraint(equalToConstant: 430)
        ])
        panel.contentView = content
        panel.setContentSize(NSSize(width: 430, height: max(90, min(400, content.fittingSize.height))))
        panel.center()
        panel.orderFrontRegardless()
        feedbackPanel = panel
        feedbackTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            self?.feedbackPanel?.close()
            self?.feedbackPanel = nil
        }
    }

    // MARK: - Alerts

    private func showPermissionHelp() {
        guard !isShowingPermissionHelp else { return }
        isShowingPermissionHelp = true
        defer { isShowingPermissionHelp = false }
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        let alert = NSAlert()
        alert.messageText = "Allow Window Tiler to move windows"
        alert.informativeText = "Add this app in System Settings → Privacy & Security → Accessibility, then turn it on.\n\nAlready on? Quit Window Tiler, remove only its entry, add this app again, turn it on, and reopen it."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Show This App")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn: openAccessibilitySettings()
        case .alertSecondButtonReturn: NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        default: break
        }
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
