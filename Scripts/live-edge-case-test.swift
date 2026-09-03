import AppKit
import Foundation
import SwiftUI

private struct Check: Codable {
    let direction: String
    let visibleWindows: Int
    let rows: Int
    let hasExpectedRows: Bool
    let automaticRetileObserved: Bool
    let retileMilliseconds: Int
    let fillsUsableScreen: Bool
    let staysInsideScreen: Bool
    let hasNoOverlaps: Bool
    let details: String

    var passed: Bool {
        automaticRetileObserved && hasExpectedRows && fillsUsableScreen && staysInsideScreen && hasNoOverlaps
    }
}

private struct Report: Codable {
    let screen: String
    let checks: [Check]
    let passed: Bool
}

@MainActor
private final class LiveTestDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var appsHiddenForTest: [NSRunningApplication] = []
    private var checks: [Check] = []
    private let tilerDefaults = UserDefaults(suiteName: "com.windowtiler.app")!
    private let maximumWindowCount = max(
        1,
        Int(ProcessInfo.processInfo.environment["WINDOW_TILER_TEST_COUNT"] ?? "10") ?? 10
    )
    private let pauseOnFailure = ProcessInfo.processInfo.environment["WINDOW_TILER_PAUSE_ON_FAILURE"] == "1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        hideOtherApps()
        createWindows()
        Task {
            await prepareBaseline()
            await runTest()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for app in appsHiddenForTest where !app.isTerminated { app.unhide() }
    }

    private func hideOtherApps() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where
            app.processIdentifier != ownPID
                && app.bundleIdentifier != "com.windowtiler.app"
                && app.activationPolicy == .regular
                && !app.isHidden
                && !app.isTerminated {
            appsHiddenForTest.append(app)
            app.hide()
        }
    }

    private func createWindows() {
        NSWindow.allowsAutomaticWindowTabbing = false
        for index in 1...maximumWindowCount {
            let window = NSWindow(
                contentRect: CGRect(x: 80 + index * 24, y: 80 + index * 18, width: 520, height: 420),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Window Tiler Edge \(index)"
            window.tabbingMode = .disallowed
            window.animationBehavior = .none
            // Window 1 behaves like a real third-party minimum-size app; the
            // all remaining windows stay fully flexible.
            window.contentMinSize = index == 1
                ? CGSize(width: 700, height: 440)
                : CGSize(width: 180, height: 120)
            window.contentView = NSHostingView(rootView:
                ZStack {
                    Color(hue: Double(index) / 12.0, saturation: 0.28, brightness: 0.96)
                    VStack(spacing: 10) {
                        Text("EDGE \(index)").font(.system(size: 30, weight: .bold))
                        Text("Real resizable macOS window").font(.system(size: 14))
                    }
                }
            )
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func sleep(milliseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    private func prepareBaseline() async {
        // Hiding other apps and ordering new windows are asynchronous. Wait
        // until both are settled so a normal app cannot briefly substitute
        // for a fixture window while preserving the same total count.
        for _ in 0..<40 {
            for app in appsHiddenForTest where !app.isHidden && !app.isTerminated {
                app.hide()
            }
            if appsHiddenForTest.allSatisfy({ $0.isHidden || $0.isTerminated })
                && windows.allSatisfy(\.isVisible) {
                break
            }
            await sleep(milliseconds: 100)
        }

        let before = lastTileTime()
        setVisibleCount(0)
        _ = await waitForAutomaticRetile(after: before, expectedCount: 0)
        await sleep(milliseconds: 350)
    }

    private func restoreOtherApps() async {
        for _ in 0..<50 {
            for app in appsHiddenForTest where app.isHidden && !app.isTerminated {
                app.unhide()
            }
            if appsHiddenForTest.allSatisfy({ !$0.isHidden || $0.isTerminated }) {
                return
            }
            await sleep(milliseconds: 100)
        }
    }

    private func lastTileTime() -> Double {
        tilerDefaults.synchronize()
        return tilerDefaults.double(forKey: "diagnostics.lastTileAt")
    }

    private func waitForAutomaticRetile(after previous: Double, expectedCount: Int) async -> (observed: Bool, milliseconds: Int) {
        let started = Date()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            tilerDefaults.synchronize()
            let time = tilerDefaults.double(forKey: "diagnostics.lastTileAt")
            let reason = tilerDefaults.string(forKey: "diagnostics.lastTileReason")
            let count = tilerDefaults.integer(forKey: "diagnostics.lastTiledCount")
                + tilerDefaults.integer(forKey: "diagnostics.lastConstrainedCount")
            let failed = tilerDefaults.integer(forKey: "diagnostics.lastFailedCount")
            if time > previous, reason == "visible window set changed", count == expectedCount, failed == 0 {
                await sleep(milliseconds: 350)
                return (true, Int(Date().timeIntervalSince(started) * 1_000) - 350)
            }
            await sleep(milliseconds: 100)
        }
        return (false, Int(Date().timeIntervalSince(started) * 1_000))
    }

    private func setVisibleCount(_ count: Int) {
        for (index, window) in windows.enumerated() {
            if index < count {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.orderFrontRegardless()
            } else if !window.isMiniaturized {
                window.miniaturize(nil)
            }
        }
    }

    private func setOpenCount(_ count: Int) {
        for (index, window) in windows.enumerated() {
            if index < count {
                window.orderFrontRegardless()
            } else if window.isVisible {
                window.close()
            }
        }
    }

    private func validate(
        direction: String,
        count: Int,
        automatic: Bool,
        retileMilliseconds: Int
    ) -> Check {
        guard let screen = NSScreen.main else {
            return Check(direction: direction, visibleWindows: count, rows: 0, hasExpectedRows: false, automaticRetileObserved: automatic, retileMilliseconds: retileMilliseconds, fillsUsableScreen: false, staysInsideScreen: false, hasNoOverlaps: false, details: "No main screen")
        }
        let bounds = screen.visibleFrame
        let frames = windows.prefix(count).map(\.frame)
        if count == 0 {
            return Check(
                direction: direction,
                visibleWindows: 0,
                rows: 0,
                hasExpectedRows: true,
                automaticRetileObserved: automatic,
                retileMilliseconds: retileMilliseconds,
                fillsUsableScreen: true,
                staysInsideScreen: true,
                hasNoOverlaps: true,
                details: "no visible windows; automatic pass completed"
            )
        }
        let tolerance: CGFloat = 1.0
        let inside = frames.allSatisfy {
            $0.minX >= bounds.minX - tolerance && $0.maxX <= bounds.maxX + tolerance
                && $0.minY >= bounds.minY - tolerance && $0.maxY <= bounds.maxY + tolerance
        }
        var noOverlaps = true
        for first in frames.indices {
            for second in frames.indices where second > first {
                if frames[first].intersection(frames[second]).width > tolerance
                    && frames[first].intersection(frames[second]).height > tolerance {
                    noOverlaps = false
                }
            }
        }
        let area = frames.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
        let edgeAligned = abs((frames.map(\.minX).min() ?? .infinity) - bounds.minX) <= tolerance
            && abs((frames.map(\.maxX).max() ?? -.infinity) - bounds.maxX) <= tolerance
            && abs((frames.map(\.minY).min() ?? .infinity) - bounds.minY) <= tolerance
            && abs((frames.map(\.maxY).max() ?? -.infinity) - bounds.maxY) <= tolerance
        let fills = abs(area - bounds.width * bounds.height) <= max(2, bounds.width * 0.002) && edgeAligned
        let rows = Set(frames.map { Int($0.minY.rounded()) }).count
        let expectedRows = Int(ceil(Double(count) / 5.0))
        let frameDetails = frames.map {
            "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))"
        }.joined(separator: " | ")
        return Check(
            direction: direction,
            visibleWindows: count,
            rows: rows,
            hasExpectedRows: rows == expectedRows,
            automaticRetileObserved: automatic,
            retileMilliseconds: retileMilliseconds,
            fillsUsableScreen: fills,
            staysInsideScreen: inside,
            hasNoOverlaps: noOverlaps,
            details: "area=\(Int(area))/\(Int(bounds.width * bounds.height)); frame=\(Int(bounds.width))x\(Int(bounds.height)); windows=\(frameDetails)"
        )
    }

    private func runCount(_ count: Int, direction: String) async {
        let before = lastTileTime()
        setVisibleCount(count)
        let retile = await waitForAutomaticRetile(after: before, expectedCount: count)
        let check = validate(direction: direction, count: count, automatic: retile.observed, retileMilliseconds: retile.milliseconds)
        checks.append(check)
        print("\(check.passed ? "PASS" : "FAIL") \(direction) count=\(count) rows=\(check.rows) retile=\(check.retileMilliseconds)ms \(check.details)")
        fflush(stdout)
        if !check.passed && pauseOnFailure { await sleep(milliseconds: 15_000) }
    }

    private func runOpenCount(_ count: Int, direction: String) async {
        let before = lastTileTime()
        setOpenCount(count)
        let retile = await waitForAutomaticRetile(after: before, expectedCount: count)
        let check = validate(direction: direction, count: count, automatic: retile.observed, retileMilliseconds: retile.milliseconds)
        checks.append(check)
        print("\(check.passed ? "PASS" : "FAIL") \(direction) count=\(count) rows=\(check.rows) retile=\(check.retileMilliseconds)ms \(check.details)")
        fflush(stdout)
        if !check.passed && pauseOnFailure { await sleep(milliseconds: 15_000) }
    }

    private func runTest() async {
        await runCount(maximumWindowCount, direction: "minimizing")
        for count in stride(from: maximumWindowCount - 1, through: 1, by: -1) {
            await runCount(count, direction: "minimizing")
        }
        if maximumWindowCount >= 2 {
            for count in 2...maximumWindowCount {
                await runCount(count, direction: "restoring")
            }
        }
        for count in stride(from: maximumWindowCount - 1, through: 0, by: -1) {
            await runOpenCount(count, direction: "closing")
        }
        for count in 1...maximumWindowCount {
            await runOpenCount(count, direction: "opening")
        }

        let frame = NSScreen.main?.visibleFrame ?? .zero
        let report = Report(
            screen: "\(Int(frame.width))x\(Int(frame.height))",
            checks: checks,
            passed: checks.count == maximumWindowCount * 4 - 1 && checks.allSatisfy(\.passed)
        )
        if let data = try? JSONEncoder().encode(report) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/window-tiler-live-edge-report.json"))
        }

        for window in windows { window.orderOut(nil) }
        await restoreOtherApps()
        await sleep(milliseconds: 500)
        print(report.passed ? "LIVE_EDGE_CASES_PASS" : "LIVE_EDGE_CASES_FAIL")
        fflush(stdout)
        NSApp.terminate(nil)
    }
}

@main
private enum LiveEdgeCaseTest {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = LiveTestDelegate()
        app.delegate = delegate
        app.run()
    }
}
