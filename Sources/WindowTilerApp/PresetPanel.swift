import AppKit
import Carbon
import WindowTilerCore

/// Preset editing never places windows. The owner applies changes through these callbacks.
final class PresetPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onSaveNew: ((LayoutPreset) -> Bool)?
    var onChange: ((LayoutPreset) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onApply: ((UUID) -> Void)?
    var onNew: (() -> Void)?
    var onUpdate: ((UUID) -> Void)?
    var onValidateShortcut: ((PresetShortcut, UUID?) -> String?)?
    var onRecordingShortcutChange: ((Bool) -> Void)?

    private let manage = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    private let table = NSTableView()
    private let details = NSStackView()
    private let apply = NSButton(title: "Apply", target: nil, action: nil)
    private let rename = NSButton(title: "Rename…", target: nil, action: nil)
    private let delete = NSButton(title: "Delete…", target: nil, action: nil)
    private let update = NSButton(title: "Update from Current Windows…", target: nil, action: nil)
    private var presets: [LayoutPreset] = []
    private var activeID: UUID?
    private var selectedID: UUID?
    private var savePanel: NSPanel?
    private var saveDraft: LayoutPreset?
    private var saveDetails: NSStackView?
    private var saveName: NSTextField?
    private var saveButton: NSButton?
    private var isRefreshing = false
    private var hasRenderedManage = false
    private var renderedPreset: LayoutPreset?
    private var renderedSelectionIsActive = false
    private weak var manageRecorder: PresetShortcutRecorder?
    private weak var saveRecorder: PresetShortcutRecorder?
    var isRecordingShortcut: Bool { (manageRecorder?.isRecording ?? false) || (saveRecorder?.isRecording ?? false) }

    override init() {
        super.init()
        manage.title = "Manage Presets"
        manage.isReleasedWhenClosed = false
        manage.hidesOnDeactivate = false
        manage.delegate = self
        manage.minSize = NSSize(width: 740, height: 520)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("preset")))
        table.headerView = nil
        table.rowHeight = 34
        table.delegate = self
        table.dataSource = self
        table.allowsEmptySelection = false
        table.setAccessibilityLabel("Saved presets")
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .bezelBorder
        let new = NSButton(title: "New…", target: self, action: #selector(newPressed))
        rename.target = self
        rename.action = #selector(renamePressed)
        delete.target = self
        delete.action = #selector(deletePressed)
        let listButtons = horizontal([new, rename, delete])
        let left = vertical([label("Presets", bold: true), listScroll, listButtons])
        left.widthAnchor.constraint(equalToConstant: 255).isActive = true
        listScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true

        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 14
        let detailScroll = scrolling(details)
        update.target = self
        update.action = #selector(updatePressed)
        apply.target = self
        apply.action = #selector(applyPressed)
        apply.keyEquivalent = "\r"
        let actions = horizontal([update, NSView(), apply])
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 680))
        for view in [left, detailScroll, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        manage.contentView = content
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            left.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            left.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            listButtons.widthAnchor.constraint(equalTo: left.widthAnchor),
            detailScroll.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 20),
            detailScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            detailScroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            detailScroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -14),
            detailScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            actions.leadingAnchor.constraint(equalTo: detailScroll.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: detailScroll.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            actions.heightAnchor.constraint(equalToConstant: 32),
        ])
        manage.setContentSize(NSSize(width: 820, height: 680))
        renderManage()
    }

    func showManage(presets: [LayoutPreset], activeID: UUID?) {
        refresh(presets: presets, activeID: activeID)
        show(manage)
    }

    func refresh(presets: [LayoutPreset], activeID: UUID?) {
        let listChanged = self.presets != presets || self.activeID != activeID
        self.presets = presets
        self.activeID = activeID
        if selectedID == nil || !presets.contains(where: { $0.id == selectedID }) {
            selectedID = presets.first(where: { $0.id == activeID })?.id ?? presets.first?.id
        }
        let row = presets.firstIndex(where: { $0.id == selectedID })
        if listChanged || table.selectedRow != (row ?? -1) {
            isRefreshing = true
            if listChanged { table.reloadData() }
            if let row {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else {
                table.deselectAll(nil)
            }
            isRefreshing = false
        }
        renderManage()
    }

    func showSave(screens: [PresetScreen], currentScreenID: String?) {
        if let savePanel { show(savePanel); return }
        let defaultID = currentScreenID ?? screens.first?.id
        var includedScreens = screens
        for index in includedScreens.indices {
            includedScreens[index].isIncluded = includedScreens[index].id == defaultID
        }
        saveDraft = LayoutPreset(name: "", screens: includedScreens, rememberApps: true,
                                 launchMissingApps: false, shortcut: nil)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Save Preset"
        panel.minSize = NSSize(width: 480, height: 480)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        savePanel = panel
        let name = NSTextField(string: "")
        name.placeholderString = "Preset name"
        name.setAccessibilityLabel("Preset name")
        name.delegate = self
        saveName = name
        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 14
        saveDetails = form
        let scroll = scrolling(form)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSave))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save and Activate", target: self, action: #selector(savePressed))
        save.keyEquivalent = "\r"
        save.isEnabled = false
        saveButton = save
        let buttons = horizontal([NSView(), cancel, save])
        let heading = label("Name", bold: true)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 700))
        for view in [heading, name, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20).isActive = true
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20).isActive = true
        }
        panel.contentView = content
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            name.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            name.heightAnchor.constraint(equalToConstant: 24),
            scroll.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            buttons.heightAnchor.constraint(equalToConstant: 32),
        ])
        panel.setContentSize(NSSize(width: 520, height: 700))
        renderSave()
        show(panel)
        panel.makeFirstResponder(name)
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Preset Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        let window = savePanel ?? manage
        if window.isVisible { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { presets.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard presets.indices.contains(row) else { return nil }
        let preset = presets[row]
        let check = NSImageView()
        check.image = preset.id == activeID ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Active") : nil
        check.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let name = label(preset.name)
        name.lineBreakMode = .byTruncatingTail
        let cell = horizontal([check, name])
        cell.spacing = 6
        cell.setAccessibilityLabel(preset.name + (preset.id == activeID ? ", active" : ""))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRefreshing, presets.indices.contains(table.selectedRow) else { return }
        selectedID = presets[table.selectedRow].id
        renderManage()
    }

    private func renderManage() {
        let preset = presets.first(where: { $0.id == selectedID })
        let selectionIsActive = preset.map { $0.id == activeID } ?? false
        guard !hasRenderedManage || preset != renderedPreset || selectionIsActive != renderedSelectionIsActive else { return }
        hasRenderedManage = true
        renderedPreset = preset
        renderedSelectionIsActive = selectionIsActive
        clear(details)
        [rename, delete, update, apply].forEach { $0.isEnabled = preset != nil }
        guard let preset else {
            details.addArrangedSubview(label("No saved presets", bold: true))
            details.addArrangedSubview(label("Arrange your windows, then choose New to save their spots.", secondary: true))
            return
        }
        details.addArrangedSubview(label(preset.name, bold: true))
        details.addArrangedSubview(label(preset.id == activeID ? "Active · Changes apply as you edit." : "Changes save as you edit.", secondary: true))
        apply.title = preset.id == activeID ? "Apply Again" : "Apply"
        buildForm(preset, in: details, saving: false)
    }

    private func renderSave() {
        guard let draft = saveDraft, let form = saveDetails else { return }
        clear(form)
        form.addArrangedSubview(label("Only shown windows are saved. Hidden and minimized windows are skipped.", secondary: true))
        buildForm(draft, in: form, saving: true)
        validateSave()
    }

    private func buildForm(_ preset: LayoutPreset, in stack: NSStackView, saving: Bool) {
        let remember = PresetActionButton(checkbox: "Remember apps", checked: preset.rememberApps) { [weak self] state in
            self?.edit(saving: saving) { value in
                value.rememberApps = state
                if !state { value.launchMissingApps = false }
            }
        }
        remember.toolTip = "Keep each app in its saved spot. Turn this off to use any shown windows."
        let launch = PresetActionButton(checkbox: "Launch missing apps", checked: preset.launchMissingApps) { [weak self] state in
            self?.edit(saving: saving) { $0.launchMissingApps = state }
        }
        launch.isEnabled = preset.rememberApps
        stack.addArrangedSubview(remember)
        stack.addArrangedSubview(launch)
        stack.addArrangedSubview(label("Screens", bold: true))
        if preset.screens.isEmpty { stack.addArrangedSubview(label("No screens were captured.", secondary: true)) }
        for (screenIndex, screen) in preset.screens.enumerated() {
            let toggle = PresetActionButton(checkbox: screen.name, checked: screen.isIncluded) { [weak self] state in
                self?.edit(saving: saving) { $0.screens[screenIndex].isIncluded = state }
            }
            toggle.setAccessibilityLabel("Include \(screen.name)")
            let preview = PresetScreenPreview(screen: screen, rememberApps: preset.rememberApps)
            preview.alphaValue = screen.isIncluded ? 1 : 0.45
            let card = vertical([toggle, preview])
            card.spacing = 8
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            preview.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
            let ratio = screen.savedWidth > 0 && screen.savedHeight > 0 ? screen.savedWidth / screen.savedHeight : 1.6
            preview.heightAnchor.constraint(equalTo: preview.widthAnchor, multiplier: 1 / max(1.0, min(ratio, 3.0))).isActive = true
            for (slotIndex, slot) in screen.slots.enumerated() {
                guard let app = slot.app else { continue }
                let check = PresetActionButton(checkbox: app.name, checked: slot.restoreApp) { [weak self] state in
                    self?.edit(saving: saving) { $0.screens[screenIndex].slots[slotIndex].restoreApp = state }
                }
                check.isEnabled = preset.rememberApps && screen.isIncluded
                check.toolTip = "Leave this app alone and keep its saved spot empty."
                let icon = NSImageView(image: PresetScreenPreview.icon(for: app))
                icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
                let appRow = horizontal([icon, check])
                appRow.spacing = 6
                card.addArrangedSubview(appRow)
            }
            if screen.slots.isEmpty { card.addArrangedSubview(label("No shown windows on this screen.", secondary: true)) }
        }
        stack.addArrangedSubview(label("Shortcut (optional)", bold: true))
        let recorder = PresetShortcutRecorder(shortcut: preset.shortcut)
        if saving { saveRecorder = recorder } else { manageRecorder = recorder }
        recorder.onValidate = { [weak self] shortcut in
            self?.onValidateShortcut?(shortcut, saving ? nil : preset.id)
        }
        recorder.onChange = { [weak self] shortcut in
            self?.edit(saving: saving) { $0.shortcut = shortcut }
        }
        recorder.onRecordingChange = { [weak self] recording in self?.onRecordingShortcutChange?(recording) }
        stack.addArrangedSubview(recorder)
        recorder.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(label("Preview only. With Remember apps off, shown windows fill these spots.", secondary: true))
    }

    private func edit(saving: Bool, change: (inout LayoutPreset) -> Void) {
        if saving {
            guard var value = saveDraft else { return }
            change(&value)
            saveDraft = value
            renderSave()
        } else {
            guard let index = presets.firstIndex(where: { $0.id == selectedID }) else { return }
            change(&presets[index])
            let value = presets[index]
            renderManage()
            onChange?(value)
        }
    }

    @objc private func newPressed() { onNew?() }
    @objc private func applyPressed() { if let selectedID { onApply?(selectedID) } }

    @objc private func renamePressed() {
        guard let preset = presets.first(where: { $0.id == selectedID }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Preset"
        let field = NSTextField(string: preset.name)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.setAccessibilityLabel("Preset name")
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: manage) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { self.showError("Enter a name for this preset."); return }
            guard let index = self.presets.firstIndex(where: { $0.id == preset.id }) else { return }
            self.presets[index].name = name
            let value = self.presets[index]
            self.table.reloadData()
            self.renderManage()
            self.onChange?(value)
        }
        manage.attachedSheet?.makeFirstResponder(field)
    }

    @objc private func deletePressed() {
        guard let preset = presets.first(where: { $0.id == selectedID }) else { return }
        confirm(title: "Delete “\(preset.name)” ?", detail: "This removes the saved preset and its shortcut.", action: "Delete") { [weak self] in
            self?.onDelete?(preset.id)
        }
    }

    @objc private func updatePressed() {
        guard let preset = presets.first(where: { $0.id == selectedID }) else { return }
        confirm(title: "Update “\(preset.name)” ?", detail: "Replace its saved spots with the windows shown now. Its name and shortcut stay the same.", action: "Update") { [weak self] in
            self?.onUpdate?(preset.id)
        }
    }

    private func confirm(title: String, detail: String, action: String, completion: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: manage) { response in
            if response == .alertFirstButtonReturn { completion() }
        }
    }

    @objc private func cancelSave() { savePanel?.close(); discardSave() }

    @objc private func savePressed() {
        guard var draft = saveDraft else { return }
        draft.name = saveName?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !draft.name.isEmpty else { showError("Enter a name for this preset."); return }
        guard draft.screens.contains(where: { $0.isIncluded && !$0.slots.isEmpty }) else {
            showError("Choose a screen with at least one shown window."); return
        }
        if let shortcut = draft.shortcut, let error = onValidateShortcut?(shortcut, nil) {
            showError(error); return
        }
        guard onSaveNew?(draft) == true else { return }
        selectedID = draft.id
        refresh(presets: presets, activeID: activeID)
        savePanel?.close()
        discardSave()
    }

    private func validateSave() {
        let hasName = !(saveName?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        saveButton?.isEnabled = hasName && (saveDraft?.screens.contains(where: { $0.isIncluded && !$0.slots.isEmpty }) ?? false)
    }

    private func discardSave() {
        savePanel = nil
        saveDraft = nil
        saveDetails = nil
        saveName = nil
        saveButton = nil
    }

    private func show(_ panel: NSPanel) {
        if !panel.isVisible { panel.center() }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func label(_ value: String, bold: Bool = false, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .systemFont(ofSize: bold ? 14 : 12, weight: bold ? .semibold : .regular)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func vertical(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func horizontal(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func scrolling(_ stack: NSStackView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = PresetDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12),
        ])
        return scroll
    }

    private func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
    }
}

extension PresetPanel: NSWindowDelegate, NSTextFieldDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === savePanel { saveRecorder?.stop(); discardSave() }
        if window === manage { manageRecorder?.stop() }
    }
    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === savePanel { saveRecorder?.stop() }
        if window === manage { manageRecorder?.stop() }
    }
    func controlTextDidChange(_ obj: Notification) { validateSave() }
}

private final class PresetActionButton: NSButton {
    private let handler: (Bool) -> Void
    init(checkbox title: String, checked: Bool, handler: @escaping (Bool) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        setButtonType(.switch)
        state = checked ? .on : .off
        target = self
        action = #selector(changed)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { handler(state == .on) }
}

private final class PresetDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class PresetShortcutRecorder: NSStackView {
    var onValidate: ((PresetShortcut) -> String?)?
    var onChange: ((PresetShortcut?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private var shortcut: PresetShortcut?
    private var monitor: Any?
    var isRecording: Bool { monitor != nil }
    private let record = NSButton(title: "Record Shortcut", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let error = NSTextField(wrappingLabelWithString: "")
    init(shortcut: PresetShortcut?) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 5
        record.target = self
        record.action = #selector(start)
        record.setAccessibilityLabel("Record preset shortcut")
        clearButton.target = self
        clearButton.action = #selector(clearShortcut)
        let row = NSStackView(views: [record, clearButton])
        row.orientation = .horizontal
        row.spacing = 8
        addArrangedSubview(row)
        error.font = .systemFont(ofSize: 11)
        error.textColor = .secondaryLabelColor
        addArrangedSubview(error)
        updateTitle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor); onRecordingChange?(false) }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stop() }
        super.viewWillMove(toWindow: newWindow)
    }
    @objc private func start() {
        if monitor != nil { stop(); return }
        record.title = "Press Shortcut…"
        error.stringValue = "Use ⌘, ⌃, or ⌥ with a key. Esc cancels."
        onRecordingChange?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.keyCode == UInt16(kVK_Escape) { self.stop(); return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            let candidate = PresetShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            if let message = Self.validationError(candidate) ?? self.onValidate?(candidate) {
                self.error.stringValue = message
                NSSound.beep()
                return nil
            }
            self.shortcut = candidate
            self.stop()
            self.onChange?(candidate)
            return nil
        }
    }
    @objc private func clearShortcut() { stop(); shortcut = nil; updateTitle(); onChange?(nil) }
    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            onRecordingChange?(false)
        }
        error.stringValue = ""
        updateTitle()
    }
    private func updateTitle() {
        record.title = shortcut.map(Self.title) ?? "Record Shortcut"
        clearButton.isEnabled = shortcut != nil
    }
    private static func validationError(_ shortcut: PresetShortcut) -> String? {
        let flags = shortcut.modifiers
        let cmd = UInt32(cmdKey), opt = UInt32(optionKey), ctrl = UInt32(controlKey), shift = UInt32(shiftKey)
        guard flags & (cmd | opt | ctrl) != 0 else { return "Add ⌘, ⌃, or ⌥ to the shortcut." }
        if flags & cmd != 0 && [kVK_ANSI_Q, kVK_Tab, kVK_Space].contains(Int(shortcut.keyCode)) {
            return "That shortcut is used by macOS. Choose another."
        }
        if flags & cmd != 0 && flags & shift != 0 && [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5].contains(Int(shortcut.keyCode)) {
            return "That shortcut is used for screenshots. Choose another."
        }
        if flags & cmd != 0 && flags & opt != 0 && [kVK_ANSI_H, kVK_ANSI_M].contains(Int(shortcut.keyCode)) {
            return "That shortcut is used by macOS. Choose another."
        }
        let commandOnly = flags == cmd || flags == cmd | shift
        let reserved = [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_C, kVK_ANSI_V,
                        kVK_ANSI_X, kVK_ANSI_A, kVK_ANSI_Z, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_S,
                        kVK_ANSI_P, kVK_ANSI_F, kVK_Tab, kVK_Space, kVK_ANSI_Grave]
        if commandOnly && reserved.contains(Int(shortcut.keyCode)) { return "That shortcut is used by macOS or other apps. Add ⌃ or ⌥." }
        if flags & cmd != 0 && flags & opt != 0 && shortcut.keyCode == UInt32(kVK_Escape) {
            return "That shortcut is used by macOS. Choose another."
        }
        if flags == ctrl && [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].contains(Int(shortcut.keyCode)) {
            return "That shortcut is used by macOS. Add ⌘ or ⌥."
        }
        return nil
    }
    static func title(_ shortcut: PresetShortcut) -> String {
        var title = ""
        if shortcut.modifiers & UInt32(controlKey) != 0 { title += "⌃" }
        if shortcut.modifiers & UInt32(optionKey) != 0 { title += "⌥" }
        if shortcut.modifiers & UInt32(shiftKey) != 0 { title += "⇧" }
        if shortcut.modifiers & UInt32(cmdKey) != 0 { title += "⌘" }
        let keys: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"Return",37:"L",38:"J",39:"′",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"Tab",49:"Space",50:"`",51:"Delete",53:"Esc",96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",109:"F10",111:"F12",118:"F4",120:"F2",122:"F1",123:"←",124:"→",125:"↓",126:"↑"]
        return title + (keys[shortcut.keyCode] ?? "Key \(shortcut.keyCode)")
    }
}

/// Read-only miniature; slot coordinates are normalized from the top left.
private final class PresetScreenPreview: NSView {
    private let screen: PresetScreen
    private let rememberApps: Bool
    private let appIcons: [String: NSImage]
    override var isFlipped: Bool { true }
    init(screen: PresetScreen, rememberApps: Bool) {
        self.screen = screen
        self.rememberApps = rememberApps
        var icons: [String: NSImage] = [:]
        if rememberApps {
            for slot in screen.slots where slot.restoreApp {
                if let app = slot.app, icons[app.bundleID] == nil { icons[app.bundleID] = Self.icon(for: app) }
            }
        }
        appIcons = icons
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityLabel("\(screen.name) layout preview, \(screen.slots.count) spots. View only.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func icon(for app: PresetApp) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: app.name) ?? NSImage(size: NSSize(width: 32, height: 32))
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let canvas = bounds.insetBy(dx: 2, dy: 2)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: canvas, xRadius: 8, yRadius: 8).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: canvas, xRadius: 8, yRadius: 8).stroke()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: canvas, xRadius: 8, yRadius: 8).addClip()
        for (index, slot) in screen.slots.enumerated() {
            let rect = NSRect(x: canvas.minX + slot.rect.x * canvas.width,
                              y: canvas.minY + slot.rect.y * canvas.height,
                              width: slot.rect.width * canvas.width,
                              height: slot.rect.height * canvas.height).insetBy(dx: 3, dy: 3)
            guard rect.width > 0, rect.height > 0 else { continue }
            let boundApp = rememberApps && slot.restoreApp ? slot.app : nil
            (boundApp == nil ? NSColor.quaternaryLabelColor : NSColor.controlAccentColor.withAlphaComponent(0.15)).setFill()
            let shape = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            shape.fill()
            NSColor.separatorColor.setStroke()
            shape.stroke()
            let iconSize = min(32, min(rect.width - 8, rect.height - 8))
            if let app = boundApp, let icon = appIcons[app.bundleID], iconSize >= 12 {
                icon.draw(in: NSRect(x: rect.midX - iconSize / 2, y: rect.midY - iconSize / 2,
                                                  width: iconSize, height: iconSize), from: .zero,
                                         operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else if rect.width > 20 && rect.height > 20 {
                let text = "\(index + 1)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
