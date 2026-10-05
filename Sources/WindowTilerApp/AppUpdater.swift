import AppKit
import Sparkle

/// Sparkle owns checking, downloading, verification, and its standard UI.
/// Only a downloaded automatic update waits here for an idle opportunity.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate, NSMenuItemValidation {
    private var controller: SPUStandardUpdaterController!
    private let isIdle: () -> Bool
    private var pendingAutomaticInstall: (() -> Void)?
    private var idleTimer: Timer?
    private weak var checkMenuItem: NSMenuItem?
    private var hasUpdateReminder = false {
        didSet { checkMenuItem?.title = hasUpdateReminder ? "Update Available…" : "Check for Updates…" }
    }
    var onWillRelaunch: (() -> Void)?

    var updater: SPUUpdater { controller.updater }
    var automaticallyInstallsUpdates: Bool {
        updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
    }
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    init(isIdle: @escaping () -> Bool, startAutomatically: Bool = true) {
        self.isIdle = isIdle
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        updater.sendsSystemProfile = false
        if startAutomatically { controller.startUpdater() }
    }

    func appendMenuItems(to menu: NSMenu) {
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        check.target = self
        check.title = hasUpdateReminder ? "Update Available…" : "Check for Updates…"
        checkMenuItem = check
        menu.addItem(check)
        let automatic = NSMenuItem(title: "Automatically Install Updates", action: #selector(toggleAutomaticUpdates(_:)), keyEquivalent: "")
        automatic.target = self
        automatic.state = automaticallyInstallsUpdates ? .on : .off
        menu.addItem(automatic)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        // Once the user takes over, the standard UI owns the install choice.
        clearPendingInstall()
        hasUpdateReminder = false
        controller.checkForUpdates(sender)
    }

    @objc private func toggleAutomaticUpdates(_ sender: NSMenuItem) {
        let enabled = !automaticallyInstallsUpdates
        if enabled {
            updater.automaticallyChecksForUpdates = true
            updater.automaticallyDownloadsUpdates = true
            startIdleTimerIfNeeded()
        } else {
            updater.automaticallyDownloadsUpdates = false
            updater.automaticallyChecksForUpdates = false
            idleTimer?.invalidate()
            idleTimer = nil
        }
        sender.state = automaticallyInstallsUpdates ? .on : .off
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) { return updater.canCheckForUpdates }
        if menuItem.action == #selector(toggleAutomaticUpdates(_:)) {
            menuItem.state = automaticallyInstallsUpdates ? .on : .off
        }
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard automaticallyInstallsUpdates else { return false }
        pendingAutomaticInstall = immediateInstallHandler
        // The callback may only be invoked after this delegate returns true.
        startIdleTimerIfNeeded()
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { onWillRelaunch?() }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        hasUpdateReminder = !handleShowingUpdate
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        hasUpdateReminder = false
    }

    func standardUserDriverWillFinishUpdateSession() { hasUpdateReminder = false }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        clearPendingInstall()
        hasUpdateReminder = false
    }

    private func startIdleTimerIfNeeded() {
        guard pendingAutomaticInstall != nil, automaticallyInstallsUpdates, idleTimer == nil else { return }
        // Default run-loop mode also prevents a restart while a menu is tracking.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.installWhenIdle() }
        }
        idleTimer?.tolerance = 0.2
    }

    private func installWhenIdle() {
        guard automaticallyInstallsUpdates else {
            idleTimer?.invalidate()
            idleTimer = nil
            return
        }
        guard isIdle(), let install = pendingAutomaticInstall else { return }
        clearPendingInstall()
        install()
    }

    private func clearPendingInstall() {
        idleTimer?.invalidate()
        idleTimer = nil
        pendingAutomaticInstall = nil
    }

    func shutdown() { clearPendingInstall() }
    deinit { idleTimer?.invalidate() }
}
