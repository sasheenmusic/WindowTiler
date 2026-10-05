import AppKit

// Runs the real updater in a disposable app. It never creates or moves windows.
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var updater: AppUpdater?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let info = Bundle.main.infoDictionary!
        let version = info["CFBundleVersion"] as! String
        let receipt = URL(fileURLWithPath: info["FixtureReceipt"] as! String)
        let line = "launched \(version) \(ProcessInfo.processInfo.processIdentifier)\n"
        if !FileManager.default.fileExists(atPath: receipt.path) {
            FileManager.default.createFile(atPath: receipt.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: receipt) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        }
        guard version == "1" else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return
        }
        updater = AppUpdater(isIdle: { true })
        // A new bundle has no last-check date, so Sparkle checks on first launch.
    }

    func applicationWillTerminate(_ notification: Notification) { updater?.shutdown() }
}

let app = NSApplication.shared
let delegate = FixtureDelegate()
app.delegate = delegate
app.run()
