// Own-process AppKit state tests. No windows are shown and no global keys,
// preferences, window placements, or external apps are used.
import AppKit
import WindowTilerCore

@main enum PresetUIRefreshTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }
    static func recordButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == "Record Shortcut" { return button }
        return view.subviews.lazy.compactMap { recordButton(in: $0) }.first
    }
    static func main() {
        let app = NSApplication.shared
        let panel = PresetPanel()
        var preset = LayoutPreset(name: "Test", screens: [PresetScreen(id: "screen", name: "Screen", savedWidth: 1000, savedHeight: 800,
            slots: [PresetSlot(rect: PresetRect(x: 0, y: 0, width: 1, height: 1))])])
        panel.refresh(presets: [preset], activeID: preset.id)
        guard let window = app.windows.first(where: { $0.title == "Manage Presets" }),
              let content = window.contentView, let button = recordButton(in: content) else { fatalError("No recorder") }
        var recordingChanges: [Bool] = []
        panel.onRecordingShortcutChange = { recordingChanges.append($0) }
        button.performClick(nil)
        require(panel.isRecordingShortcut, "Recorder did not start")
        panel.refresh(presets: [preset], activeID: preset.id)
        require(panel.isRecordingShortcut, "Unchanged refresh cancelled recording")
        require(recordingChanges == [true], "Unchanged refresh resumed global hotkeys")
        require(button.window === window, "Unchanged refresh replaced controls")
        preset.rememberApps = false
        panel.refresh(presets: [preset], activeID: preset.id)
        require(!panel.isRecordingShortcut && recordingChanges == [true, false], "Changed form failed to stop its old recorder")
        require(recordButton(in: content) !== button, "Changed model retained stale controls")
        window.close()
        print("PASS: 6 UI refresh assertions")
    }
}
