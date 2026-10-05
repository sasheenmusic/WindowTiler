import AppKit
import ApplicationServices
import WindowTilerCore

@_silgen_name("_AXUIElementGetWindow")
func foregroundWindowID(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

@MainActor final class ForegroundHarness: NSObject, NSApplicationDelegate {
    let service = PresetWindowService()
    let targetID = "com.windowtiler.foreground-target-fixture"
    let coverID = "com.windowtiler.foreground-cover-fixture"
    var apps: [String: NSRunningApplication] = [:]
    var screen: PresetScreen!
    var failures = 0
    let small = PresetRect(x: 0.08, y: 0.12, width: 0.32, height: 0.38)
    let full = PresetRect(x: 0, y: 0, width: 1, height: 1)
    func output(_ message: String) { FileHandle.standardOutput.write(Data((message + "\n").utf8)) }
    func check(_ condition: Bool, _ name: String) { output("\(condition ? "PASS" : "FAIL") \(name)"); if !condition { failures += 1 } }
    func pause(_ seconds: Double = 0.35) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    func command(_ command: String, _ id: String) {
        DistributedNotificationCenter.default().postNotificationName(.init("com.windowtiler.fixture.\(command)"), object: id, userInfo: nil, deliverImmediately: true)
    }
    func attribute(_ name: String, _ element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    func window(_ id: String, title: String = "Fixture Main") -> AXUIElement? {
        guard let app = apps[id] else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        return (attribute(kAXWindowsAttribute, root) as? [AXUIElement])?.first { attribute(kAXTitleAttribute, $0) as? String == title }
    }
    func number(_ element: AXUIElement?) -> CGWindowID? {
        guard let element else { return nil }; var id: CGWindowID = 0
        return foregroundWindowID(element, &id) == .success ? id : nil
    }
    func frame(_ element: AXUIElement?) -> CGRect? {
        guard let element, let p = attribute(kAXPositionAttribute, element), let s = attribute(kAXSizeAttribute, element),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    func matches(_ a: CGRect?, _ b: CGRect?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.minX-b.minX) < 3 && abs(a.minY-b.minY) < 3 && abs(a.width-b.width) < 3 && abs(a.height-b.height) < 3
    }
    func orderedIDs() -> [CGWindowID] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap {
            ($0[kCGWindowLayer as String] as? Int) == 0 ? ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value : nil
        }
    }
    func above(_ first: CGWindowID?, _ second: CGWindowID?) -> Bool {
        guard let first, let second else { return false }
        let ids = orderedIDs()
        guard let a = ids.firstIndex(of: first), let b = ids.firstIndex(of: second) else { return false }
        return a < b
    }
    func waitAbove(_ first: CGWindowID?, _ second: CGWindowID?) async -> Bool {
        for _ in 0..<15 { if above(first, second) { return true }; await pause(0.1) }
        return false
    }
    func checkRaised(_ report: PresetApplyReport, _ first: CGWindowID?, _ second: CGWindowID?, _ name: String, additional: Bool = true) async {
        let raised = await waitAbove(first, second)
        check(report.tiled == 1 && report.failures.isEmpty && raised && additional, name)
        if !report.failures.isEmpty { output("DETAIL \(report.failures.joined(separator: " | "))") }
    }
    func coverIsReady(_ cover: CGWindowID?, _ target: CGWindowID?, _ extra: CGWindowID?) -> Bool {
        above(cover, target) && above(cover, extra)
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == apps[coverID]?.processIdentifier
    }
    func setupCover(_ cover: CGWindowID?, _ target: CGWindowID?, _ extra: CGWindowID?) async -> Bool {
        command("front", coverID)
        let accepted = apps[coverID]?.activate(options: []) ?? false
        for _ in 0..<30 {
            if coverIsReady(cover, target, extra) { return true }
            await pause(0.1)
        }
        output("SETUP activationAccepted=\(accepted) targetPID=\(apps[targetID]?.processIdentifier ?? -1) coverPID=\(apps[coverID]?.processIdentifier ?? -1) frontmostPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) targetID=\(target ?? 0) coverID=\(cover ?? 0) extraID=\(extra ?? 0) coverAboveTarget=\(above(cover,target)) coverAboveExtra=\(above(cover,extra)) CGOrder=\(orderedIDs())")
        return false
    }
    func multiAppPreset() -> LayoutPreset {
        let left = PresetRect(x: 0.04, y: 0.1, width: 0.42, height: 0.7)
        let right = PresetRect(x: 0.52, y: 0.1, width: 0.42, height: 0.7)
        return LayoutPreset(name: "Multiple foreground fixtures", screens: [PresetScreen(id: screen.id, name: screen.name,
            savedWidth: screen.savedWidth, savedHeight: screen.savedHeight,
            slots: [PresetSlot(rect: left, app: PresetApp(bundleID: targetID, name: "Target")),
                    PresetSlot(rect: right, app: PresetApp(bundleID: coverID, name: "Cover"))])], rememberApps: true)
    }
    func preset(_ id: String, rect: PresetRect, remember: Bool = true) -> LayoutPreset {
        LayoutPreset(name: "Foreground fixture", screens: [PresetScreen(id: screen.id, name: screen.name,
            savedWidth: screen.savedWidth, savedHeight: screen.savedHeight,
            slots: [PresetSlot(rect: rect, app: PresetApp(bundleID: id, name: "Foreground fixture"))])], rememberApps: remember)
    }
    func apply(_ preset: LayoutPreset) async -> PresetApplyReport {
        await withCheckedContinuation { continuation in service.apply(preset) { continuation.resume(returning: $0) } }
    }
    func launch(_ id: String, name: String) async -> NSRunningApplication? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(name).app")
        return await withCheckedContinuation { continuation in
            let config = NSWorkspace.OpenConfiguration(); config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in continuation.resume(returning: app) }
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) { Task { @MainActor in await tests() } }
    func tests() async {
        guard AXIsProcessTrusted() else { output("BLOCKED Accessibility unavailable"); NSApp.terminate(nil); return }
        apps[targetID] = await launch(targetID, name: "WindowTilerForegroundTargetFixture")
        apps[coverID] = await launch(coverID, name: "WindowTilerForegroundCoverFixture")
        await pause(0.8)
        guard window(targetID) != nil, window(coverID) != nil,
              let captured = try? service.captureScreens(), let screen = captured.first(where: { $0.slots.contains { $0.app?.bundleID == targetID } }) else {
            output("BLOCKED fixtures unavailable"); NSApp.terminate(nil); return
        }
        self.screen = screen
        let target = number(window(targetID)); let cover = number(window(coverID))
        _ = await apply(preset(targetID, rect: small))
        command("extra", targetID); command("maximize", coverID); await pause()
        let extra = number(window(targetID, title: "Fixture Extra"))
        let extraFrame = frame(window(targetID, title: "Fixture Extra"))
        let coverReady = await setupCover(cover, target, extra)
        check(coverReady, "covering app starts foreground above both target windows")
        let coverFrame = frame(window(coverID))
        var report = await apply(preset(targetID, rect: small))
        await checkRaised(report, target, cover, "remembered target raised above foreground covering app")
        check(matches(frame(window(coverID)), coverFrame) && !apps[coverID]!.isHidden && attribute(kAXMinimizedAttribute, window(coverID)!) as? Bool == false, "unselected covering app geometry and state unchanged")
        let extraUnmoved = matches(frame(window(targetID, title: "Fixture Extra")), extraFrame)
        let extraBelowCover = above(cover, extra)
        check(extraUnmoved && extraBelowCover, "extra same-app window stays below cover with geometry unchanged")
        if !extraUnmoved || !extraBelowCover { output("EXTRA geometryUnchanged=\(extraUnmoved) belowCover=\(extraBelowCover) CGOrder=\(orderedIDs()) coverID=\(cover ?? 0) extraID=\(extra ?? 0)") }
        report = await apply(preset(coverID, rect: full))
        await checkRaised(report, cover, target, "single maximized preset raised above other windows", additional: above(cover, extra))
        for cycle in 1...3 {
            report = await apply(preset(targetID, rect: small))
            await checkRaised(report, target, cover, "cycle \(cycle) target preset brought front")
            report = await apply(preset(coverID, rect: full))
            await checkRaised(report, cover, target, "cycle \(cycle) covering preset brought front")
        }
        // A third, unselected normal window covers two apps before applying a
        // two-app preset. It belongs to the harness, so discovery excludes it.
        let third = NSWindow(contentRect: NSScreen.screens[0].visibleFrame,
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        third.title = "Foreground third cover"
        third.isReleasedWhenClosed = false
        third.setFrame(NSScreen.screens[0].visibleFrame, display: true)
        third.orderFrontRegardless()
        let thirdID = CGWindowID(third.windowNumber)
        let thirdFrame = third.frame
        var thirdReady = false
        for _ in 0..<20 {
            if above(thirdID, target) && above(thirdID, cover) && above(thirdID, extra) { thirdReady = true; break }
            await pause(0.1)
        }
        check(thirdReady, "third unrelated window covers both selected apps")
        report = await apply(multiAppPreset())
        let targetAboveThird = await waitAbove(target, thirdID)
        let coverAboveThird = await waitAbove(cover, thirdID)
        check(report.tiled == 2 && report.failures.isEmpty && targetAboveThird && coverAboveThird, "multi-app preset raises both selected windows above third cover")
        let thirdUnchanged = third.frame == thirdFrame && third.isVisible && !third.isMiniaturized
        let extraBelowThird = above(thirdID, extra)
        check(thirdUnchanged && extraBelowThird, "multi-app preset leaves third cover and same-app extra unchanged")
        if !thirdUnchanged || !extraBelowThird { output("THIRD geometryAndStateUnchanged=\(thirdUnchanged) extraBelowThird=\(extraBelowThird) CGOrder=\(orderedIDs()) thirdID=\(thirdID) extraID=\(extra ?? 0)") }
        if !report.failures.isEmpty { output("DETAIL \(report.failures.joined(separator: " | "))") }
        third.close()
        // Hide only the disposable cover so layout-only discovery selects the
        // fixture target first. Bring the extra above it before reapplying.
        command("hide", coverID); command("closeExtra", targetID); await pause()
        command("extra", targetID); await pause()
        let newExtra = number(window(targetID, title: "Fixture Extra"))
        let newExtraFrame = frame(window(targetID, title: "Fixture Extra"))
        check(above(newExtra, target), "layout-only target initially covered")
        report = await apply(preset(targetID, rect: small, remember: false))
        await checkRaised(report, target, newExtra, "layout-only preset raises its selected window")
        check(matches(frame(window(targetID, title: "Fixture Extra")), newExtraFrame) && apps[coverID]!.isHidden, "layout-only extras and unrelated hidden state unchanged")
        let beforeGather = orderedIDs().filter { $0 == target || $0 == newExtra }
        let gather: [String] = await withCheckedContinuation { continuation in service.gatherForTiling { continuation.resume(returning: $0) } }
        await pause()
        check(gather.isEmpty && orderedIDs().filter { $0 == target || $0 == newExtra } == beforeGather, "ordinary gather keeps window stacking")
        for id in [targetID, coverID] { command("terminate", id) }
        await pause()
        output("RESULT failures=\(failures)")
        NSApp.terminate(nil)
    }
}
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let delegate = MainActor.assumeIsolated { ForegroundHarness() }
application.delegate = delegate
application.run()
