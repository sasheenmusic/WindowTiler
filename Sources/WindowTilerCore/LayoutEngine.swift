import CoreGraphics

public enum LayoutEngine {
    /// Creates a balanced grid that uses every row fully. Rows with more
    /// windows receive proportionally more height so every window gets an
    /// approximately equal share of the screen.
    public static func frames(count: Int, in bounds: CGRect, gap: CGFloat = 0) -> [CGRect] {
        guard count > 0, bounds.width > 0, bounds.height > 0 else { return [] }

        let columnTarget = Int(ceil(sqrt(Double(count))))
        let rowCount = Int(ceil(Double(count) / Double(columnTarget)))
        return frames(count: count, rows: rowCount, in: bounds, gap: gap)
    }

    public static func frames(count: Int, rows rowCount: Int, in bounds: CGRect, gap: CGFloat = 0) -> [CGRect] {
        guard count > 0, rowCount > 0, rowCount <= count, bounds.width > 0, bounds.height > 0 else { return [] }

        let baseColumns = count / rowCount
        let extraColumns = count % rowCount
        let availableHeight = max(1, bounds.height - gap * CGFloat(rowCount + 1))

        var result: [CGRect] = []
        var windowsBeforeRow = 0
        for row in 0..<rowCount {
            let columns = baseColumns + (row < extraColumns ? 1 : 0)
            let availableWidth = max(1, bounds.width - gap * CGFloat(columns + 1))
            let rowStart = round(availableHeight * CGFloat(windowsBeforeRow) / CGFloat(count))
            let rowEnd = round(availableHeight * CGFloat(windowsBeforeRow + columns) / CGFloat(count))
            let rowY = bounds.minY + gap + rowStart + gap * CGFloat(row)
            let rowHeight = max(1, rowEnd - rowStart)

            for column in 0..<columns {
                let columnStart = round(availableWidth * CGFloat(column) / CGFloat(columns))
                let columnEnd = round(availableWidth * CGFloat(column + 1) / CGFloat(columns))
                result.append(CGRect(
                    x: bounds.minX + gap + columnStart + gap * CGFloat(column),
                    y: rowY,
                    width: max(1, columnEnd - columnStart),
                    height: rowHeight
                ))
            }
            windowsBeforeRow += columns
        }
        return result
    }
}
