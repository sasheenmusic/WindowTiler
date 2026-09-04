import AppKit
import WindowTilerCore

/// A small floating panel where the user says how many windows go in each
/// band of the screen, then applies that once.
final class LayoutPanel: NSObject {
    var onApply: ((RowPlan) -> Void)?
    var onAutomatic: (() -> Void)?

    private let panel: NSPanel
    private let matrix = RowMatrixView()
    private let countLabel = NSTextField(labelWithString: "")
    private let totalLabel = NSTextField(labelWithString: "")
    private let applyButton: NSButton
    private var windowCount: Int?
    private var lastAppliedPlan: RowPlan?

    var isVisible: Bool { panel.isVisible }

    /// Index in `NSScreen.screens` of the display the panel is on.
    var screenIndex: Int? {
        panel.screen.flatMap { screen in NSScreen.screens.firstIndex(where: { $0 == screen }) }
    }

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 260),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        applyButton = NSButton(title: "Apply", target: nil, action: nil)
        super.init()

        panel.title = "Layout"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true

        countLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        totalLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        totalLabel.textColor = .secondaryLabelColor

        let automaticButton = NSButton(title: "Automatic", target: self, action: #selector(automaticPressed))
        applyButton.target = self
        applyButton.action = #selector(applyPressed)
        applyButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [automaticButton, NSView(), applyButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fill

        let stack = NSStackView(views: [countLabel, matrix, totalLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        panel.contentView = content
        let size = stack.fittingSize
        panel.setContentSize(NSSize(width: max(size.width, 300), height: size.height))

        matrix.onChange = { [weak self] _ in self?.refresh() }
        refresh()
    }

    /// Opens the panel just below the menu-bar icon, ready for clicks.
    func show(near statusButton: NSStatusBarButton?, windowCount: Int?) {
        self.windowCount = windowCount
        if let last = lastAppliedPlan, let count = windowCount, last.windowCount == count {
            matrix.rowCounts = last.rows + Array(repeating: 0, count: RowPlan.maximumRows - last.rows.count)
        } else if !panel.isVisible {
            matrix.rowCounts = Array(repeating: 0, count: RowPlan.maximumRows)
        }
        refresh()

        if let anchor = statusButton?.window?.frame {
            var origin = NSPoint(x: anchor.midX - panel.frame.width / 2, y: anchor.minY - 6)
            if let visible = statusButton?.window?.screen?.visibleFrame {
                origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
            }
            panel.setFrameTopLeftPoint(origin)
        } else {
            panel.center()
        }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(matrix)
    }

    func update(windowCount: Int?) {
        self.windowCount = windowCount
        refresh()
    }

    private func refresh() {
        let plan = RowPlan(rowCounts: matrix.rowCounts)
        let placed = plan.windowCount
        let capacity = RowPlan.maximumColumns * RowPlan.maximumRows

        switch windowCount {
        case nil:
            countLabel.stringValue = "Counting windows…"
            totalLabel.stringValue = "\(placed) placed"
        case let count? where count > capacity:
            countLabel.stringValue = "Too many windows for the matrix (\(count))"
            totalLabel.stringValue = "The matrix holds up to \(capacity). Use Automatic."
        case let count?:
            countLabel.stringValue = count == 1 ? "1 window open" : "\(count) windows open"
            if placed > count {
                let extra = placed - count
                totalLabel.stringValue = "\(placed) of \(count) placed, \(extra == 1 ? "one" : "\(extra)") too many"
            } else {
                totalLabel.stringValue = "\(placed) of \(count) placed"
            }
        }
        applyButton.isEnabled = windowCount.map(plan.fits(windowCount:)) ?? false
    }

    @objc private func applyPressed() {
        let plan = RowPlan(rowCounts: matrix.rowCounts)
        guard let count = windowCount, plan.fits(windowCount: count) else { return }
        lastAppliedPlan = plan
        panel.close()
        onApply?(plan)
    }

    @objc private func automaticPressed() {
        panel.close()
        onAutomatic?()
    }
}
