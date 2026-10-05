import AppKit
import ApplicationServices
import WindowTilerCore
import Darwin
import CoreServices

@_silgen_name("_AXUIElementGetWindow")
func testWindowID(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

@MainActor final class Harness: NSObject, NSApplicationDelegate {
    let service = PresetWindowService()
    let bridge = PresetSpaceBridge()
    let fixtureID = "com.windowtiler.preset-fixture"
    let fixtureURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/WindowTilerPresetRegressionFixture.app")
    var own: NSWindow?
    var errors = 0
    var app: NSRunningApplication!
    var screen: PresetScreen!
    let rect = PresetRect(x: 0.08, y: 0.12, width: 0.32, height: 0.38)

    func output(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }
    func check(_ condition: Bool, _ name: String) {
        output("\(condition ? "PASS" : "FAIL") \(name)")
        if !condition { errors += 1 }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        own = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 200, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        own?.title = "Harness own window"
        own?.orderFront(nil)
        Task { @MainActor in await tests() }
    }
    func pause(_ seconds: Double = 0.7) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    func command(_ value: String) { DistributedNotificationCenter.default().postNotificationName(.init("com.windowtiler.fixture.\(value)"), object: nil, userInfo: nil, deliverImmediately: true) }
    func attribute(_ name: String, _ window: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, name as CFString, &value) == .success ? value : nil
    }
    func windows() -> [AXUIElement] {
        guard let app else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        return attribute(kAXWindowsAttribute, root) as? [AXUIElement] ?? []
    }
    func mainWindow() -> AXUIElement? {
        windows().first { attribute(kAXTitleAttribute, $0) as? String == "Fixture Main" }
    }
    func named(_ title: String) -> AXUIElement? { windows().first { attribute(kAXTitleAttribute, $0) as? String == title } }
    func frame(_ window: AXUIElement?) -> CGRect? {
        guard let window, let p = attribute(kAXPositionAttribute, window), let s = attribute(kAXSizeAttribute, window),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    func number(_ window: AXUIElement?) -> CGWindowID? {
        guard let window else { return nil }
        var id: CGWindowID = 0
        return testWindowID(window, &id) == .success && id != 0 ? id : nil
    }
    func matches(_ a: CGRect?, _ b: CGRect?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.minX-b.minX) < 3 && abs(a.minY-b.minY) < 3 && abs(a.width-b.width) < 3 && abs(a.height-b.height) < 3
    }
    func targetFrame() -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let frames = ScreenGeometryEngine.accessibilityFrames(visibleFrames: NSScreen.screens.map(\.visibleFrame), primaryFrame: primary.frame)
        return rect.frame(in: frames[0])
    }
    func preset(screenID: String? = nil, launch: Bool = false, remember: Bool = true) -> LayoutPreset {
        LayoutPreset(name: "Isolated Regression", screens: [PresetScreen(id: screenID ?? screen.id, name: "Fixture display", savedWidth: screen.savedWidth, savedHeight: screen.savedHeight,
            slots: [PresetSlot(rect: rect, app: PresetApp(bundleID: fixtureID, name: "Fixture"))])], rememberApps: remember, launchMissingApps: launch)
    }
    func apply(_ preset: LayoutPreset) async -> PresetApplyReport {
        await withCheckedContinuation { continuation in service.apply(preset) { continuation.resume(returning: $0) } }
    }
    func fixtureDiagnostics(_ stage: String) {
        output("FIXTURE_DIAG \(stage) pid=\(app.processIdentifier) bundle=\(app.bundleIdentifier ?? "nil") lookup=\(NSRunningApplication.runningApplications(withBundleIdentifier:fixtureID).map(\.processIdentifier)) hidden=\(app.isHidden) url=\(NSWorkspace.shared.urlForApplication(withBundleIdentifier:fixtureID)?.path ?? "nil")")
        for window in windows() {
            output("WINDOW_DIAG title=\(attribute(kAXTitleAttribute,window) as? String ?? "nil") role=\(attribute(kAXRoleAttribute,window) as? String ?? "nil") subrole=\(attribute(kAXSubroleAttribute,window) as? String ?? "nil") identifier=\(attribute(kAXIdentifierAttribute,window) as? String ?? "nil") miniButton=\(attribute(kAXMinimizeButtonAttribute,window) != nil) min=\(attribute(kAXMinimizedAttribute,window) as? Bool ?? false) fullscreen=\(attribute("AXFullScreen",window) as? Bool ?? false) frame=\(String(describing:frame(window))) id=\(String(describing:number(window)))")
        }
    }
    func capturedFixtureCount() -> Int {
        let screens = (try? service.captureScreens()) ?? []
        return screens.flatMap(\.slots).filter { $0.app?.bundleID == fixtureID }.count
    }
    func launchFixture() async -> NSRunningApplication? {
        await withCheckedContinuation { continuation in
            let config = NSWorkspace.OpenConfiguration(); config.activates = false
            NSWorkspace.shared.openApplication(at: fixtureURL, configuration: config) { app, _ in continuation.resume(returning: app) }
        }
    }
    func tests() async {
        output("AX_TRUSTED \(AXIsProcessTrusted()) SCREENS \(NSScreen.screens.count)")
        guard AXIsProcessTrusted(), !NSScreen.screens.isEmpty else { output("BLOCKED no GUI Accessibility session"); NSApp.terminate(nil); return }
        let registered = LSRegisterURL(fixtureURL as CFURL, true)
        output("FIXTURE_REGISTER \(registered)")
        app = await launchFixture(); await pause(1)
        guard app != nil, mainWindow() != nil else { output("BLOCKED fixture unavailable"); NSApp.terminate(nil); return }
        do {
            let captured = try service.captureScreens()
            screen = captured.first { $0.slots.contains { $0.app?.bundleID == fixtureID } }
            check(screen != nil, "capture shown normal fixture")
            check(!captured.flatMap(\.slots).contains { $0.app?.bundleID == Bundle.main.bundleIdentifier }, "capture excludes harness own window")
            output("CAPTURE screens=\(captured.count) eligible=\(captured.flatMap(\.slots).count)")
        } catch { output("FAIL capture \(error.localizedDescription)"); errors += 1 }
        guard screen != nil else { command("terminate"); NSApp.terminate(nil); return }
        var report = await apply(preset())
        check(report.tiled == 1 && report.failures.isEmpty && matches(frame(mainWindow()), targetFrame()), "exact same-desktop restore")
        if !report.failures.isEmpty { output("DETAIL \(report.failures.joined(separator: " | "))") }
        var changedResolution = preset()
        changedResolution.screens[0].savedWidth /= 2
        changedResolution.screens[0].savedHeight /= 2
        report = await apply(changedResolution)
        check(report.tiled == 1 && report.failures.isEmpty && matches(frame(mainWindow()), targetFrame()), "normalized geometry scales from saved resolution")
        command("extra"); await pause()
        let extra = frame(named("Fixture Extra"))
        fixtureDiagnostics("extra")
        let duplicateCapture = (try? service.captureScreens())?.flatMap(\.slots).filter { $0.app?.bundleID == fixtureID } ?? []
        output("DUPLICATE count=\(duplicateCapture.count) bound=\(duplicateCapture.filter(\.restoreApp).count)")
        check(duplicateCapture.count == 2 && duplicateCapture.filter(\.restoreApp).count == 1, "capture binds one window per app")
        report = await apply(preset()); await pause(0.1)
        check(report.tiled == 1 && report.failures.isEmpty && matches(frame(named("Fixture Extra")), extra), "remembered extra window untouched")
        command("closeExtra"); command("dialog"); await pause()
        check(capturedFixtureCount() == 1, "capture excludes helper/dialog")
        command("closeExtra"); command("minimize"); await pause()
        fixtureDiagnostics("minimized")
        check(capturedFixtureCount() == 0, "capture excludes minimized")
        report = await apply(preset())
        output("MIN_REPORT tiled=\(report.tiled) failures=\(report.failures.joined(separator: " | "))")
        check(report.tiled == 1 && report.failures.isEmpty && attribute(kAXMinimizedAttribute, mainWindow()!) as? Bool == false, "restore minimized fixture")
        command("hide"); await pause()
        fixtureDiagnostics("hidden")
        check(capturedFixtureCount() == 0, "capture excludes hidden")
        report = await apply(preset())
        output("HIDDEN_REPORT tiled=\(report.tiled) failures=\(report.failures.joined(separator: " | "))")
        fixtureDiagnostics("after hidden restore")
        check(report.tiled == 1 && report.failures.isEmpty && !app.isHidden, "restore hidden fixture")
        command("unhide"); await pause(0.4)
        let beforeMissing = frame(mainWindow())
        report = await apply(preset(screenID: UUID().uuidString, launch: true))
        check(report.tiled == 0 && !report.failures.isEmpty && matches(frame(mainWindow()), beforeMissing), "disconnected display skipped")
        await withCheckedContinuation { continuation in
            var calls = 0
            service.apply(preset()) { result in
                calls += 1
                self.check(calls == 1 && self.service.lastOperationWasCancelled, "cancel completion once")
                continuation.resume()
            }
            service.cancel()
        }
        await pause(0.4)
        command("fullscreen"); await pause(2.5)
        let entered = mainWindow().flatMap { attribute("AXFullScreen", $0) as? Bool } == true
        check(entered, "fixture entered fullscreen")
        if entered {
            report = await apply(preset())
            await pause(0.4)
            check(report.tiled == 1 && report.failures.isEmpty && mainWindow().flatMap { attribute("AXFullScreen", $0) as? Bool } != true && matches(frame(mainWindow()), targetFrame()), "restore current fullscreen fixture")
            if !report.failures.isEmpty { output("DETAIL \(report.failures.joined(separator: " | "))") }
        }
        command("exitFullscreen"); await pause(1)
        command("minimum"); await pause(0.3)
        report = await apply(preset())
        check(report.tiled == 1 && report.failures.contains(where: { $0.contains("minimum or fixed") }), "native size constraints reported")
        command("normalMinimum"); await pause(0.2)
        _ = await apply(preset())
        await crossSpace()
        command("terminate"); await pause(1)
        report = await apply(preset(screenID: UUID().uuidString, launch: true))
        check(report.tiled == 0 && !report.failures.isEmpty && NSRunningApplication.runningApplications(withBundleIdentifier: fixtureID).isEmpty, "disconnected display never launches app")
        report = await apply(preset(launch: false))
        check(report.tiled == 0 && !report.failures.isEmpty && NSRunningApplication.runningApplications(withBundleIdentifier: fixtureID).isEmpty, "missing app not launched by default")
        report = await apply(preset(launch: true)); await pause(0.4)
        app = NSRunningApplication.runningApplications(withBundleIdentifier: fixtureID).first
        check(report.tiled == 1 && report.failures.isEmpty && app != nil && matches(frame(mainWindow()), targetFrame()), "launch missing fixture and restore")
        if !report.failures.isEmpty { output("DETAIL \(report.failures.joined(separator: " | "))") }
        fixtureDiagnostics("after missing launch")
        command("closeMain"); await pause(0.4)
        let existingPID = app.processIdentifier
        report = await apply(preset(launch: true))
        check(report.tiled == 0 && !report.failures.isEmpty && app.processIdentifier == existingPID && windows().isEmpty, "running app never creates replacement windows")
        command("terminate"); await pause(0.5)
        output("RESULT failures=\(errors)")
        NSApp.terminate(nil)
    }
    func crossSpace() async {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { output("SKIP cross-Space unavailable"); return }
        defer { dlclose(handle) }
        typealias Connection = @convention(c) () -> Int32
        typealias Displays = @convention(c) (Int32) -> Unmanaged<CFArray>?
        guard let c = dlsym(handle, "SLSMainConnectionID"), let d = dlsym(handle,"SLSCopyManagedDisplaySpaces") else { output("SKIP cross-Space unavailable"); return }
        let cid = unsafeBitCast(c,to:Connection.self)()
        let records = unsafeBitCast(d,to:Displays.self)(cid)?.takeRetainedValue() as? [[String:Any]] ?? []
        let users = records.flatMap { $0["Spaces"] as? [[String:Any]] ?? [] }.compactMap { $0["ManagedSpaceID"] as? NSNumber }.map(\.uint64Value).filter(bridge.isUserDesktop)
        guard let original = bridge.activeDesktop(on:screen.id), let other = users.first(where: { $0 != original }), let id = number(mainWindow()) else {
            output("SKIP cross-Space: no second existing user desktop"); return
        }
        if let failure = bridge.requestMove(id,to:other) { output("FAIL cross-Space setup \(failure)"); errors += 1; return }
        await pause(0.5)
        output("SPACE_AFTER \(bridge.spaces(of:id) ?? [])")
        fixtureDiagnostics("other Space")
        check(bridge.spaces(of:id)?.contains(other) == true, "fixture moved to existing other desktop")
        let report = await apply(preset())
        check(report.tiled == 1 && report.failures.isEmpty && bridge.spaces(of:id)?.contains(original) == true && matches(frame(mainWindow()),targetFrame()), "restore fixture from another Space")
        if !report.failures.isEmpty { output("DETAIL \(report.failures.joined(separator:" | "))") }
        if bridge.spaces(of:id)?.contains(original) != true { _ = bridge.requestMove(id,to:original) }
        await pause(0.5)
        _ = bridge.requestMove(id,to:other); await pause(0.4)
        command("hide"); await pause(0.4)
        let hiddenReport = await apply(preset())
        check(hiddenReport.tiled == 1 && hiddenReport.failures.isEmpty && !app.isHidden && bridge.spaces(of:id)?.contains(original) == true, "restore hidden fixture from another Space")
        if !hiddenReport.failures.isEmpty { output("DETAIL \(hiddenReport.failures.joined(separator:" | "))") }
        command("unhide"); _ = bridge.requestMove(id,to:original); await pause(0.4)
        _ = bridge.requestMove(id,to:other); await pause(0.4)
        let beforeGather = frame(mainWindow())
        let gatherFailures: [String] = await withCheckedContinuation { continuation in service.gatherForTiling { continuation.resume(returning:$0) } }
        check(gatherFailures.isEmpty && bridge.spaces(of:id)?.contains(original) == true, "gather fixture from another Space")
        if !gatherFailures.isEmpty { output("DETAIL \(gatherFailures.joined(separator:" | "))") }
        _ = beforeGather
        _ = bridge.requestMove(id,to:other); await pause(0.4)
        var cancellationCalls = 0
        await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
            service.apply(preset()) { _ in
                cancellationCalls += 1
                continuation.resume()
            }
            service.cancel()
        }
        await pause(0.6)
        check(cancellationCalls == 1 && bridge.spaces(of:id) == [other], "cancel pending pull returns fixture to original Space once")
        _ = bridge.requestMove(id,to:original); await pause(0.4)
        command("invalid"); await pause(0.4)
        guard let invalidID = number(named("Fixture Invalid")) else { check(false,"invalid fixture created"); return }
        let invalidBefore = frame(named("Fixture Invalid"))
        _ = bridge.requestMove(invalidID,to:other); await pause(0.4)
        check(bridge.spaces(of:invalidID) == [other], "nonstandard fixture moved for validation test")
        let failedGather: [String] = await withCheckedContinuation { continuation in service.gatherForTiling { continuation.resume(returning:$0) } }
        check(!failedGather.isEmpty && bridge.spaces(of:invalidID) == [other], "failed AX validation returns nonstandard fixture")
        if failedGather.isEmpty || bridge.spaces(of:invalidID) != [other] { output("DETAIL \(failedGather.joined(separator:" | "))") }
        _ = bridge.requestMove(invalidID,to:original); await pause(0.4)
        check(matches(frame(named("Fixture Invalid")),invalidBefore), "nonstandard fixture geometry untouched")
        command("closeExtra"); await pause(0.3)
    }
}
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let harness = Harness()
    application.delegate = harness
    application.run()
}
