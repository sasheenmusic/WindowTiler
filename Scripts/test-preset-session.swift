// Compiled by test-preset-session.sh with the production AppDelegate, HotKey,
// and Log sources. Every placement, store, defaults, and observer is in memory.
import AppKit
import ApplicationServices
import Carbon
import WindowTilerCore

final class UserDefaults {
    static let standard = UserDefaults()
    private var values: [String: Any] = ["autoRetile": true, "swapByDragging": false]
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func object(forKey key: String) -> Any? { values[key] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
}

final class PresetStore {
    static var saved: [LayoutPreset] = []
    static var failSave = false
    init(fileURL: URL) {}
    func load() throws -> [LayoutPreset] { Self.saved }
    func save(_ presets: [LayoutPreset]) throws {
        if Self.failSave { throw NSError(domain: "TestStore", code: 1) }
        Self.saved = presets
    }
}

// No actual menu-bar icon is installed by this coordinator test.
final class NSStatusBar {
    static let system = NSStatusBar()
    static let squareLength: CGFloat = 24
    func statusItem(withLength length: CGFloat) -> NSStatusItem { NSStatusItem() }
}
final class NSStatusItem {
    static let squareLength: CGFloat = 24
    var button: NSStatusBarButton? { nil }
    var menu: NSMenu?
}
final class DistributedNotificationCenter {
    static let instance = DistributedNotificationCenter()
    static func `default`() -> DistributedNotificationCenter { instance }
    func postNotificationName(_ name: Notification.Name, object: String?, userInfo: [AnyHashable: Any]?, deliverImmediately: Bool) {}
}
final class NSAlert {
    static var presentations: [(title: String, message: String, buttons: [String])] = []
    static var response: NSApplication.ModalResponse = .alertThirdButtonReturn
    static var onRunModal: (() -> Void)?
    var messageText = ""
    var informativeText = ""
    var buttons: [String] = []
    func addButton(withTitle title: String) { buttons.append(title) }
    @discardableResult func runModal() -> NSApplication.ModalResponse {
        Self.presentations.append((messageText, informativeText, buttons))
        let callback = Self.onRunModal
        Self.onRunModal = nil
        callback?()
        return Self.response
    }
}
// Recovery actions are recorded only; Settings and Finder never open in tests.
final class NSWorkspace {
    static let shared = NSWorkspace()
    var openedURLs: [URL] = []
    var revealedURLs: [[URL]] = []
    @discardableResult func open(_ url: URL) -> Bool { openedURLs.append(url); return true }
    func activateFileViewerSelecting(_ urls: [URL]) { revealedURLs.append(urls) }
}

final class WindowTiler {
    static var latest: WindowTiler!
    static var initialAccessibilityEnabled = true
    var windowsPerRow = 2
    var accessibilityEnabled: Bool
    var resetCount = 0
    var systemPromptCount = 0
    var topology: String? = "initial"
    var tileCount = 0
    var onTile: (() -> Void)?
    init() { accessibilityEnabled = Self.initialAccessibilityEnabled; Self.latest = self }
    func isAccessibilityEnabled(prompt: Bool) -> Bool { if prompt { systemPromptCount += 1 }; return accessibilityEnabled }
    func resetAccessibilityState() { resetCount += 1 }
    func windowTopologySignature() -> String? { topology }
    func windowCountsPerScreen() -> [Int]? { [2] }
    struct TileResult { var tiled = 2; var constrained = 0; var failed = 0 }
    enum DragOutcome { case swapped, snappedBack, ignored }
    func tileAllWindows(relearn: Bool, plan: RowPlan?) -> TileResult { tileCount += 1; onTile?(); return TileResult() }
    func finishDrag(of element: AXUIElement, startFrame: CGRect, pointer: CGPoint) -> DragOutcome { .ignored }
}

final class WindowEventMonitor {
    enum Change { case windowSet, geometry }
    static var latest: WindowEventMonitor!
    let onChange: (Change) -> Void
    let spaceChange: () -> Void
    var resetCount = 0
    init(onChange: @escaping (Change) -> Void, onSpaceChange: @escaping () -> Void, onWindowMoved: @escaping (AXUIElement) -> Void) {
        self.onChange = onChange; spaceChange = onSpaceChange; Self.latest = self
    }
    func change(_ kind: Change = .windowSet) { onChange(kind) }
    func refresh() {}
    func reset() { resetCount += 1; refresh() }
}
final class DragSwapController {
    var isEnabled = false
    init(tiler: WindowTiler, isBusy: @escaping () -> Bool, perform: @escaping (AXUIElement, CGRect, CGPoint) -> Void) {}
    func windowMoved(_ element: AXUIElement) {}
}
final class LayoutPanel {
    var onApply: ((RowPlan) -> Void)?
    var onAutomatic: (() -> Void)?
    let isVisible = false
    let screenIndex: Int? = 0
    func show(near button: NSStatusBarButton?, windowCount: Int?) {}
    func update(windowCount: Int?) {}
}

struct PresetApplyReport { var tiled = 2; var failures: [String] = [] }
final class PresetWindowService {
    static var latest: PresetWindowService!
    var applyCount = 0
    var isApplying = false
    var deferred = false
    var completions: [(PresetApplyReport) -> Void] = []
    var lastOperationWasCancelled = false
    init() { Self.latest = self }
    static func currentScreenID() -> String? { "screen" }
    func captureScreens() throws -> [PresetScreen] { PresetStore.saved.first?.screens ?? [] }
    func apply(_ preset: LayoutPreset, completion: @escaping (PresetApplyReport) -> Void) {
        applyCount += 1
        if deferred { completions.append(completion) } else { completion(PresetApplyReport()) }
    }
    func gatherForTiling(completion: @escaping ([String]) -> Void) { completion([]) }
    // Retain queued callbacks to prove the coordinator rejects stale results.
    func cancel() {}
}

final class PresetPanel {
    static var latest: PresetPanel!
    var onSaveNew: ((LayoutPreset) -> Bool)?
    var onChange: ((LayoutPreset) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onApply: ((UUID) -> Void)?
    var onNew: (() -> Void)?
    var onUpdate: ((UUID) -> Void)?
    var onValidateShortcut: ((PresetShortcut, UUID?) -> String?)?
    var onRecordingShortcutChange: ((Bool) -> Void)?
    var activeID: UUID?
    var presets: [LayoutPreset] = []
    var errors: [String] = []
    var isRecordingShortcut = false
    init() { Self.latest = self }
    func refresh(presets: [LayoutPreset], activeID: UUID?) { self.presets = presets; self.activeID = activeID }
    func showManage(presets: [LayoutPreset], activeID: UUID?) { refresh(presets: presets, activeID: activeID) }
    func showSave(screens: [PresetScreen], currentScreenID: String?) {}
    func showError(_ value: String) { errors.append(value) }
}

// Do not start Sparkle or touch update preferences in the coordinator fixture.
final class AppUpdater {
    static var latest: AppUpdater!
    let isIdle: () -> Bool
    var onWillRelaunch: (() -> Void)?
    init(isIdle: @escaping () -> Bool, startAutomatically: Bool = true) { self.isIdle = isIdle; Self.latest = self }
    func appendMenuItems(to menu: NSMenu) {}
    func shutdown() {}
}

@main enum PresetSessionTests {
    struct Failure: Error { let description: String }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }
    static func pump(_ seconds: TimeInterval = 0.35) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
    static func preset(_ name: String) -> LayoutPreset {
        LayoutPreset(name: name, screens: [PresetScreen(id: "screen", name: "Test", savedWidth: 1000, savedHeight: 800,
            slots: [PresetSlot(rect: PresetRect(x: 0, y: 0, width: 0.5, height: 1))])])
    }
    static func menuToggle(_ delegate: AppDelegate, _ id: UUID) {
        let menuItem = NSMenuItem()
        menuItem.representedObject = id.uuidString
        _ = delegate.perform(NSSelectorFromString("presetSelected:"), with: menuItem)
    }
    static func globalHotkey() throws {
        var event: EventRef?
        try require(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(), 0, &event) == noErr,
                    "Could not create internal hotkey event")
        guard let event else { throw Failure(description: "No event") }
        defer { ReleaseEvent(event) }
        var id = EventHotKeyID(signature: OSType(0x57544C52), id: 1)
        try require(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                      MemoryLayout<EventHotKeyID>.size, &id) == noErr, "Could not set hotkey ID")
        try require(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr, "Hotkey callback not delivered")
    }
    static func busy(_ delegate: AppDelegate) -> Bool {
        Mirror(reflecting: delegate).children.first { $0.label == "isTiling" }?.value as? Bool ?? false
    }
    static func main() {
        do { try run(); print("PASS: all preset session checks") }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
    static func run() throws {
        _ = NSApplication.shared
        let existing = preset("Existing")
        PresetStore.saved = [existing]
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        let panel = PresetPanel.latest!, windows = PresetWindowService.latest!, tiler = WindowTiler.latest!, events = WindowEventMonitor.latest!
        var saved = preset("Saved")
        try require(panel.onSaveNew?(saved) == true && panel.activeID == saved.id, "Save did not activate")
        try require(windows.applyCount == 0 && tiler.tileCount == 0, "Save moved already captured windows")
        print("PASS: save activates without placement")

        var inactive = existing
        inactive.screens[0].slots[0].rect.width = 0.4
        panel.onChange?(inactive)
        try require(panel.activeID == saved.id && windows.applyCount == 0, "Inactive editing changed active layout")
        saved.name = "Renamed"
        panel.onChange?(saved)
        try require(windows.applyCount == 0, "Rename unnecessarily placed windows")
        saved.screens[0].slots[0].rect.width = 0.6
        panel.onChange?(saved)
        try require(windows.applyCount == 1, "Active geometry change was not applied once")
        print("PASS: edits respect active state and geometry")

        var duplicate = preset("renamed")
        try require(panel.onSaveNew?(duplicate) == false && panel.activeID == saved.id, "Duplicate name activated")
        let storedBeforeFailure = PresetStore.saved
        PresetStore.failSave = true
        duplicate.name = "Disk failure"
        try require(panel.onSaveNew?(duplicate) == false, "Failed store write reported success")
        var rejectedEdit = saved
        rejectedEdit.screens[0].slots[0].rect.width = 0.7
        panel.onChange?(rejectedEdit)
        try require(PresetStore.saved == storedBeforeFailure && panel.presets == storedBeforeFailure && windows.applyCount == 1,
                    "Failed persistence changed stored state or applied geometry")
        PresetStore.failSave = false
        print("PASS: failed save/change preserves session and stored state")

        tiler.topology = "future window"
        events.change(); pump()
        try require(windows.applyCount == 1 && tiler.tileCount == 0, "Future windows reapplied active preset")
        _ = delegate.perform(NSSelectorFromString("tileWindows"))
        try globalHotkey()
        try require(windows.applyCount == 3 && panel.activeID == saved.id && tiler.tileCount == 0,
                    "Global apply/menu shortcut did not reapply active preset")
        menuToggle(delegate, saved.id)
        try require(panel.activeID == nil && tiler.tileCount == 1, "Preset toggle did not return to automatic tiling")
        print("PASS: future events stay quiet; global reapply and preset toggle")

        panel.onApply?(existing.id)
        events.spaceChange(); tiler.topology = "second Space"; pump(1.15)
        try require(panel.activeID == existing.id && tiler.tileCount == 1, "Space transition rearranged active preset")
        menuToggle(delegate, existing.id)
        tiler.topology = "new window after Space transition"
        events.change(); pump()
        try require(panel.activeID == nil && tiler.tileCount == 3, "Automatic events stayed blocked after Space transition/deactivation")
        print("PASS: Space baseline does not block future automatic events")

        windows.deferred = true
        panel.onApply?(existing.id)
        panel.onApply?(saved.id)
        try require(windows.completions.count == 2 && busy(delegate), "Deferred applications were not pending")
        windows.completions.removeFirst()(PresetApplyReport())
        try require(busy(delegate) && panel.activeID == saved.id, "Old completion cleared newer operation")
        windows.completions.removeFirst()(PresetApplyReport())
        try require(!busy(delegate), "Current completion left tiling locked")
        windows.deferred = false
        panel.onDelete?(saved.id)
        try require(panel.activeID == nil && !PresetStore.saved.contains { $0.id == saved.id } && tiler.tileCount == 4,
                    "Deleting active preset did not resume automatic tiling")
        print("PASS: stale callbacks are ignored; active deletion ends session")

        panel.onApply?(existing.id)
        let beforeRollback = tiler.tileCount
        windows.isApplying = true
        menuToggle(delegate, existing.id)
        try require(panel.activeID == nil && tiler.tileCount == beforeRollback,
                    "Deactivation tiled before pending preset rollback finished")
        pump()
        try require(tiler.tileCount == beforeRollback, "Waiting rollback still triggered direct tiling")
        windows.isApplying = false
        pump()
        try require(tiler.tileCount == beforeRollback + 1, "Rollback completion did not trigger exactly one automatic tile")
        pump()
        try require(tiler.tileCount == beforeRollback + 1, "Deferred automatic tile ran more than once")
        print("PASS: deactivation waits for rollback before one automatic tile")

        let beforeSpace = tiler.tileCount
        events.spaceChange()
        tiler.topology = "navigation-only desktop"
        events.change(.geometry)
        pump(1.2)
        try require(tiler.tileCount == beforeSpace, "Navigation alone rearranged the destination desktop")
        events.change(.geometry); pump()
        try require(tiler.tileCount == beforeSpace, "Moved-only event forced reflow after navigation")
        print("PASS: navigation and moved-only events preserve windows")

        events.spaceChange()
        tiler.topology = "next desktop baseline"
        pump(0.4)
        tiler.topology = "T3 opened during transition"
        events.change(.windowSet)
        pump(0.35)
        try require(tiler.tileCount == beforeSpace, "Real window event tiled before the desktop settled")
        pump(0.5)
        try require(tiler.tileCount == beforeSpace + 1, "Desktop baseline swallowed the real window event")
        pump()
        try require(tiler.tileCount == beforeSpace + 1, "Transition window event caused duplicate reflow")
        print("PASS: real window event survives desktop baseline once")

        let beforeBusy = tiler.tileCount
        tiler.onTile = {
            tiler.onTile = nil
            tiler.topology = "window created while tiling"
            events.change(.windowSet)
        }
        tiler.topology = "trigger initial layout"
        events.change(); pump(0.9)
        try require(tiler.tileCount == beforeBusy + 2, "Post-tile baseline swallowed a window created during placement")
        pump()
        try require(tiler.tileCount == beforeBusy + 2, "Busy window event repeated after recovery")
        print("PASS: real window event during placement gets one follow-up")

        let queuedOther = preset("Queued other")
        try require(panel.onSaveNew?(queuedOther) == true, "Could not create second queued preset")
        menuToggle(delegate, queuedOther.id)
        let beforeReentrantApply = windows.applyCount
        let expectedTileStart = tiler.tileCount
        var startedInsideTile = false
        var savedInsideTile = false
        tiler.onTile = {
            tiler.onTile = nil
            savedInsideTile = panel.onSaveNew?(preset("Too early")) == true
            panel.onApply?(queuedOther.id)
            panel.onApply?(existing.id)
            startedInsideTile = windows.applyCount != beforeReentrantApply || panel.activeID != nil
        }
        tiler.topology = "reentrant ordinary placement"
        events.change(); pump()
        try require(!savedInsideTile && !PresetStore.saved.contains(where: { $0.name == "Too early" }),
                    "Save activated or persisted a capture inside an ordinary placement")
        try require(!startedInsideTile && tiler.tileCount == expectedTileStart + 1 && windows.applyCount == beforeReentrantApply + 1 && panel.activeID == existing.id,
                    "Reentrant preset requests were not coalesced after ordinary placement")
        menuToggle(delegate, existing.id)
        print("PASS: preset requests wait for ordinary placement and latest intent wins")

        // A separate launch begins without AX permission. All app/observer
        // state stays fake; no real permission prompts or desktop changes.
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        WindowTiler.initialAccessibilityEnabled = false
        let recovering = AppDelegate()
        let alertsBeforeDenied = NSAlert.presentations.count
        NSAlert.onRunModal = { _ = recovering.perform(NSSelectorFromString("tileWindows")) }
        recovering.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { recovering.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        let recoveredTiler = WindowTiler.latest!, recoveredEvents = WindowEventMonitor.latest!, recoveredPanel = PresetPanel.latest!
        try require(!UserDefaults.standard.bool(forKey: "diagnostics.accessibilityEnabled") && recoveredTiler.tileCount == 0,
                    "Untrusted startup moved windows or recorded access")
        try require(NSAlert.presentations.count == alertsBeforeDenied + 1 && recoveredTiler.systemPromptCount == 0,
                    "Permission callbacks opened duplicate alerts or requested a second system prompt")
        try require(NSAlert.presentations.last?.message.contains("remove only its entry") == true,
                    "Permission recovery did not explain an already-enabled entry")
        let deniedWindows = PresetWindowService.latest!
        NSAlert.response = .alertFirstButtonReturn
        recoveredPanel.onApply?(existing.id)
        try require(NSWorkspace.shared.openedURLs.last?.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                    "Permission action did not open Accessibility Settings")
        NSAlert.response = .alertSecondButtonReturn
        recoveredPanel.onApply?(existing.id)
        try require(NSWorkspace.shared.revealedURLs.last == [Bundle.main.bundleURL],
                    "Permission recovery revealed an assumed installation instead of the running app")
        try require(deniedWindows.applyCount == 0 && recoveredPanel.activeID == nil && recoveredTiler.systemPromptCount == 0,
                    "Denied preset actions bypassed permission or requested duplicate system prompts")
        NSAlert.response = .alertThirdButtonReturn
        print("PASS: permission recovery uses one alert, correct actions, and the actual running app")
        recoveredTiler.accessibilityEnabled = true
        recoveredEvents.change(.geometry); pump()
        try require(recoveredTiler.resetCount == 1 && recoveredEvents.resetCount == 1,
                    "Permission recovery did not invalidate cached handles and observers")
        try require(recoveredTiler.tileCount == 1 && UserDefaults.standard.bool(forKey: "diagnostics.accessibilityEnabled"),
                    "Permission recovery did not automatically place the existing windows once")
        recoveredEvents.change(.geometry); pump()
        try require(recoveredTiler.tileCount == 1, "Stable permission caused repeated automatic tiling")
        print("PASS: startup permission recovery resets discovery and tiles once")

        recoveredPanel.onApply?(existing.id)
        let beforePermission = recoveredTiler.tileCount
        recoveredTiler.accessibilityEnabled = false
        pump(3.1)
        try require(recoveredEvents.resetCount == 2 && recoveredPanel.activeID == existing.id,
                    "Permission revocation failed to reset observers or changed the active preset")
        recoveredTiler.accessibilityEnabled = true
        pump(3.1)
        try require(recoveredEvents.resetCount == 3 && recoveredTiler.tileCount == beforePermission && recoveredPanel.activeID == existing.id,
                    "Permission recovery rearranged or deactivated an active preset")
        print("PASS: permission polling preserves an active preset")

        try require(recovering.applicationShouldTerminate(NSApp) == .terminateNow, "Idle app refused termination")
        PresetWindowService.latest.isApplying = true
        try require(recovering.applicationShouldTerminate(NSApp) == .terminateCancel, "Quit interrupted native layout cleanup")
        PresetWindowService.latest.isApplying = false
        try require(recovering.applicationShouldTerminate(NSApp) == .terminateNow, "Finished layout kept blocking termination")
        print("PASS: manual update and quit wait for native layout cleanup")

        AppUpdater.latest.onWillRelaunch?()
        let marker = UserDefaults.standard.object(forKey: "updateResumePreset") as? [String: Any]
        try require(marker?["presetID"] as? String == existing.id.uuidString && marker?["build"] as? String == "3",
                    "Update restart did not save the active preset")
        recovering.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        WindowTiler.initialAccessibilityEnabled = true
        PresetStore.saved = [existing]
        for (oldBuild, age, shouldRestore) in [("2", 0.0, true), ("3", 0.0, false), ("2", 601.0, false)] {
            UserDefaults.standard.set(["build": oldBuild, "savedAt": Date().timeIntervalSince1970 - age,
                                       "presetID": existing.id.uuidString], forKey: "updateResumePreset")
            let restarted = AppDelegate()
            restarted.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            _ = restarted.perform(NSSelectorFromString("managePresetsPressed"))
            try require((PresetPanel.latest.activeID == existing.id) == shouldRestore,
                        "Preset update restore did not honor version and age")
            try require(WindowTiler.latest.tileCount == 0 && PresetWindowService.latest.applyCount == 0,
                        "Update restart moved windows")
            try require(UserDefaults.standard.object(forKey: "updateResumePreset") == nil,
                        "Update restart marker was not consumed")
            restarted.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        }
        print("PASS: update restart preserves the preset without moving windows; ordinary and stale restarts do not")
    }
}
