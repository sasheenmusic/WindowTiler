import AppKit
import WindowTilerCore

/// Five rows of five squares. Each row is a band of the screen, top to
/// bottom; clicking the k-th square in a row puts k windows in that band.
/// Clicking the square that already is the row's count clears the row.
final class RowMatrixView: NSView {
    var rowCounts = Array(repeating: 0, count: RowPlan.maximumRows) {
        didSet { needsDisplay = true }
    }
    var onChange: (([Int]) -> Void)?

    private let squareSize: CGFloat = 18
    private let gap: CGFloat = 5
    private let padding: CGFloat = 12
    private let labelWidth: CGFloat = 44
    private let countWidth: CGFloat = 22
    private var hovered: (row: Int, column: Int)?

    override var isFlipped: Bool { true }
    /// A floating panel is often behind another app when clicked; the
    /// first click must pick a square, not just bring the panel forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        let columns = CGFloat(RowPlan.maximumColumns)
        let rows = CGFloat(RowPlan.maximumRows)
        return NSSize(
            width: padding + labelWidth + columns * squareSize + (columns - 1) * gap + 8 + countWidth + padding,
            height: padding + rows * squareSize + (rows - 1) * gap + padding
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    private func squareRect(row: Int, column: Int) -> NSRect {
        NSRect(
            x: padding + labelWidth + CGFloat(column) * (squareSize + gap),
            y: padding + CGFloat(row) * (squareSize + gap),
            width: squareSize,
            height: squareSize
        )
    }

    private func square(at point: NSPoint) -> (row: Int, column: Int)? {
        for row in 0..<RowPlan.maximumRows {
            for column in 0..<RowPlan.maximumColumns
            where squareRect(row: row, column: column).insetBy(dx: -gap / 2, dy: -gap / 2).contains(point) {
                return (row, column)
            }
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let labelFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont, .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let countAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        for row in 0..<RowPlan.maximumRows {
            let rowRect = squareRect(row: row, column: 0)
            let label = NSAttributedString(string: "Row \(row + 1)", attributes: labelAttributes)
            label.draw(at: NSPoint(x: padding, y: rowRect.midY - label.size().height / 2))

            for column in 0..<RowPlan.maximumColumns {
                let rect = squareRect(row: row, column: column)
                let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                let filled = column < rowCounts[row]
                let previewed = hovered.map { $0.row == row && column <= $0.column } ?? false
                if filled {
                    NSColor.controlAccentColor.setFill()
                } else if previewed {
                    NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
                } else {
                    NSColor.labelColor.withAlphaComponent(0.12).setFill()
                }
                path.fill()
            }

            if rowCounts[row] > 0 {
                let count = NSAttributedString(string: "\(rowCounts[row])", attributes: countAttributes)
                let x = squareRect(row: row, column: RowPlan.maximumColumns - 1).maxX + 8
                count.draw(at: NSPoint(x: x, y: rowRect.midY - count.size().height / 2))
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let target = square(at: convert(event.locationInWindow, from: nil))
        if target?.row != hovered?.row || target?.column != hovered?.column {
            hovered = target
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let target = square(at: convert(event.locationInWindow, from: nil)) else { return }
        let picked = target.column + 1
        rowCounts[target.row] = rowCounts[target.row] == picked ? 0 : picked
        onChange?(rowCounts)
    }
}
