import AppKit
import Sparkle

// The public secure-coding initializer supplies a scheduled, not-downloaded state.
private final class ScheduledStateDecoder: NSCoder {
    override var allowsKeyedCoding: Bool { true }
    override func containsValue(forKey key: String) -> Bool { true }
    override func decodeBool(forKey key: String) -> Bool { false }
    override func decodeInteger(forKey key: String) -> Int { 0 }
}

@main
struct UpdaterTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let domain = Bundle.main.bundleIdentifier!
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            assertions += 1
        }
        func pump(_ duration: TimeInterval = 1.4) {
            RunLoop.main.run(until: Date().addingTimeInterval(duration))
        }
        var idle = false
        var installs = 0
        let wrapper = AppUpdater(isIdle: { idle }, startAutomatically: false)
        let menu = NSMenu()
        wrapper.appendMenuItems(to: menu)
        let automatic = menu.items[1]
        func toggle() { _ = wrapper.perform(automatic.action!, with: automatic) }
        func offer() -> Bool {
            wrapper.updater(wrapper.updater, willInstallUpdateOnQuit: .empty(), immediateInstallationBlock: { installs += 1 })
        }

        check(wrapper.automaticallyInstallsUpdates, "Automatic defaults must enable checks and downloads")
        check(menu.items[0].title == "Check for Updates…" && automatic.state == .on, "Update menu defaults")
        check(!wrapper.updater.sendsSystemProfile, "System profile must stay off")
        check(offer() && installs == 0, "Automatic callback must not install before its delegate returns")
        pump()
        check(installs == 0, "Busy application must defer installation")
        toggle()
        check(!wrapper.updater.automaticallyChecksForUpdates && !wrapper.updater.automaticallyDownloadsUpdates, "Turning off must disable checks and downloads")
        idle = true
        pump()
        check(installs == 0, "Turning off must cancel an already scheduled installation")
        toggle()
        pump()
        check(installs == 1, "Turning on must resume pending update once idle")
        pump()
        check(installs == 1, "Update must install only once")

        idle = false
        check(offer(), "Accept another automatic update")
        wrapper.updater(wrapper.updater, didAbortWithError: NSError(domain: "fixture", code: 1))
        idle = true
        pump()
        check(installs == 1, "Aborted update must discard its install callback")

        idle = false
        check(offer(), "Accept shutdown fixture")
        wrapper.shutdown()
        idle = true
        pump()
        check(installs == 1, "Shutdown must discard its install callback")

        var relaunches = 0
        wrapper.onWillRelaunch = { relaunches += 1 }
        wrapper.updaterWillRelaunchApplication(wrapper.updater)
        check(relaunches == 1, "Sparkle relaunch must notify preset preservation")
        check(wrapper.supportsGentleScheduledUpdateReminders && !wrapper.standardUserDriverShouldHandleShowingScheduledUpdate(.empty(), andInImmediateFocus: true), "Scheduled reminders must stay in the menu")
        let state = SPUUserUpdateState(coder: ScheduledStateDecoder())!
        wrapper.standardUserDriverWillHandleShowingUpdate(false, forUpdate: .empty(), state: state)
        check(menu.items[0].title == "Update Available…", "Scheduled update must display its menu reminder")
        wrapper.standardUserDriverDidReceiveUserAttention(forUpdate: .empty())
        check(menu.items[0].title == "Check for Updates…", "User attention must clear reminder")
        wrapper.standardUserDriverWillHandleShowingUpdate(false, forUpdate: .empty(), state: state)
        wrapper.standardUserDriverWillFinishUpdateSession()
        check(menu.items[0].title == "Check for Updates…", "Session completion must clear reminder")
        toggle()
        check(!offer(), "Disabled automatic updates must leave installation to Sparkle's normal UI")
        check(menu.items[0].action != nil, "Manual update action must remain present when automatic updates are disabled")
        print("PASS: \(assertions) updater assertions (no checks, downloads, or installations performed)")
    }
}
