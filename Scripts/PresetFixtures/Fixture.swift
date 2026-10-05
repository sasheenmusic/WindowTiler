import AppKit

final class InvalidFixtureWindow: NSWindow {
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .dialog }
}

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var tokens: [NSObjectProtocol] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        try? String(ProcessInfo.processInfo.processIdentifier).write(to: Bundle.main.bundleURL.appendingPathComponent("Contents/fixture.pid"), atomically: true, encoding: .utf8)
        NSWindow.allowsAutomaticWindowTabbing = false
        let window = makeWindow("Fixture Main", NSRect(x: 180, y: 160, width: 640, height: 420))
        window.minSize = NSSize(width: 180, height: 140)
        window.collectionBehavior = [.fullScreenPrimary]
        for command in ["extra", "closeExtra", "dialog", "hide", "unhide", "minimize", "fullscreen", "exitFullscreen", "invalid", "minimum", "normalMinimum", "closeMain", "terminate"] {
            tokens.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.windowtiler.fixture.\(command)"), object: nil, queue: .main) { [weak self] _ in
                self?.perform(command)
            })
        }
    }
    func makeWindow(_ title: String, _ rect: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.tabbingMode = .disallowed
        window.title = title
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: rect.size))
        let label = NSTextField(labelWithString: "WindowTiler isolated test fixture")
        label.frame = NSRect(x: 20, y: 30, width: 260, height: 40)
        view.addSubview(label)
        window.contentView = view
        windows.append(window)
        window.orderFront(nil)
        return window
    }
    func perform(_ command: String) {
        guard let main = windows.first else { return }
        switch command {
        case "extra": _ = makeWindow("Fixture Extra", NSRect(x: 870, y: 500, width: 280, height: 200))
        case "closeExtra": for extra in windows.dropFirst() { extra.close() }; windows = [main]
        case "dialog":
            let dialog = NSPanel(contentRect: NSRect(x: 950, y: 160, width: 240, height: 150), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            dialog.title = "Fixture Dialog"
            dialog.isReleasedWhenClosed = false
            windows.append(dialog)
            dialog.orderFront(nil)
        case "hide": NSApp.hide(nil)
        case "unhide": NSApp.unhideWithoutActivation()
        case "minimize": main.miniaturize(nil)
        case "fullscreen": if !main.styleMask.contains(.fullScreen) { main.toggleFullScreen(nil) }
        case "exitFullscreen": if main.styleMask.contains(.fullScreen) { main.toggleFullScreen(nil) }
        case "invalid":
            let window = InvalidFixtureWindow(contentRect: NSRect(x: 650, y: 350, width: 360, height: 220), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Fixture Invalid"
            window.tabbingMode = .disallowed
            window.isReleasedWhenClosed = false
            windows.append(window)
            window.orderFront(nil)
        case "minimum": main.minSize = NSSize(width: 1700, height: 1100)
        case "normalMinimum": main.minSize = NSSize(width: 180, height: 140)
        case "closeMain": main.close()
        case "terminate": NSApp.terminate(nil)
        default: break
        }
    }
}
let application = NSApplication.shared
let fixtureDelegate = FixtureDelegate()
application.delegate = fixtureDelegate
application.run()
