import CoreGraphics

public enum ConstraintGridEngine {
    private struct Row {
        var indices: [Int] = []
        var minimumWidth: CGFloat = 0
        var minimumHeight: CGFloat = 0
    }

    private struct Candidate {
        let frames: [CGRect]
        let rows: Int
        let balanceScore: CGFloat
    }

    /// Produces a complete edge-to-edge partition. Minimums determine how much
    /// space a window must receive; every window may grow to absorb the rest.
    public static func frames(
        minimumSizes: [CGSize],
        in bounds: CGRect,
        gap: CGFloat = 0
    ) -> [CGRect] {
        guard !minimumSizes.isEmpty else { return [] }

        let preferredRows = Int(ceil(Double(minimumSizes.count) / 5.0))
        var candidates: [Candidate] = []
        for rowCount in 1...minimumSizes.count {
            for order in orders(for: minimumSizes) {
                guard let rows = makeRows(
                    minimumSizes: minimumSizes,
                    order: order,
                    count: rowCount,
                    availableWidth: bounds.width - gap * CGFloat(max(0, minimumSizes.count - rowCount))
                ), rows.reduce(0, { $0 + $1.minimumHeight })
                    + gap * CGFloat(max(0, rowCount - 1)) <= bounds.height else { continue }

                let frames = makeFrames(rows: rows, minimumSizes: minimumSizes, in: bounds, gap: gap)
                let areas = frames.map { $0.width * $0.height }
                let rowHeights = rows.compactMap { $0.indices.first.map { frames[$0].height } }
                let heightSpread = ((rowHeights.max() ?? 0) - (rowHeights.min() ?? 0)) / max(1, bounds.height)
                let areaSpread = ((areas.max() ?? 0) - (areas.min() ?? 0)) / max(1, bounds.width * bounds.height)
                candidates.append(Candidate(
                    frames: frames,
                    rows: rowCount,
                    balanceScore: heightSpread * 100 + areaSpread
                ))
            }
        }

        if let best = candidates.min(by: {
            let left = $0.balanceScore + CGFloat(abs($0.rows - preferredRows)) * 0.25
            let right = $1.balanceScore + CGFloat(abs($1.rows - preferredRows)) * 0.25
            return left < right
        }) {
            return best.frames
        }

        return LayoutEngine.frames(count: minimumSizes.count, in: bounds, gap: gap)
    }

    private static func orders(for sizes: [CGSize]) -> [[Int]] {
        let indices = Array(sizes.indices)
        return [
            indices.sorted { sizes[$0].height == sizes[$1].height
                ? sizes[$0].width > sizes[$1].width
                : sizes[$0].height > sizes[$1].height },
            indices.sorted { sizes[$0].width == sizes[$1].width
                ? sizes[$0].height > sizes[$1].height
                : sizes[$0].width > sizes[$1].width },
            indices.sorted { sizes[$0].width * sizes[$0].height > sizes[$1].width * sizes[$1].height },
        ]
    }

    private static func makeRows(
        minimumSizes: [CGSize],
        order: [Int],
        count: Int,
        availableWidth: CGFloat
    ) -> [Row]? {
        var rows = Array(repeating: Row(), count: count)
        let targetCount = Int(ceil(Double(minimumSizes.count) / Double(count)))

        for index in order {
            let size = minimumSizes[index]
            let pixelWidth = ceil(size.width)
            let pixelHeight = ceil(size.height)
            let choices = rows.indices.filter { rows[$0].minimumWidth + pixelWidth <= availableWidth }
            guard let selected = choices.min(by: { first, second in
                let firstGrowth = max(rows[first].minimumHeight, pixelHeight) - rows[first].minimumHeight
                let secondGrowth = max(rows[second].minimumHeight, pixelHeight) - rows[second].minimumHeight
                let firstOverload = max(0, rows[first].indices.count + 1 - targetCount)
                let secondOverload = max(0, rows[second].indices.count + 1 - targetCount)
                let firstCost = firstGrowth + CGFloat(firstOverload) * 10_000
                let secondCost = secondGrowth + CGFloat(secondOverload) * 10_000
                if firstCost != secondCost { return firstCost < secondCost }
                return rows[first].minimumWidth < rows[second].minimumWidth
            }) else { return nil }

            rows[selected].indices.append(index)
            rows[selected].minimumWidth += pixelWidth
            rows[selected].minimumHeight = max(rows[selected].minimumHeight, pixelHeight)
        }
        return rows.allSatisfy { !$0.indices.isEmpty } ? rows : nil
    }

    private static func makeFrames(
        rows: [Row],
        minimumSizes: [CGSize],
        in bounds: CGRect,
        gap: CGFloat
    ) -> [CGRect] {
        var result = Array(repeating: CGRect.zero, count: minimumSizes.count)
        let availableHeight = bounds.height - gap * CGFloat(max(0, rows.count - 1))
        let rowHeights = distributeWholePixels(
            minimums: rows.map(\.minimumHeight),
            total: availableHeight
        )
        var y = bounds.minY

        for (rowNumber, row) in rows.enumerated() {
            let rowHeight = rowNumber == rows.count - 1
                ? bounds.maxY - y
                : rowHeights[rowNumber]

            let rowGapWidth = gap * CGFloat(max(0, row.indices.count - 1))
            let columnWidths = distributeWholePixels(
                minimums: row.indices.map { minimumSizes[$0].width },
                total: bounds.width - rowGapWidth
            )
            var x = bounds.minX
            for (column, index) in row.indices.enumerated() {
                let width = column == row.indices.count - 1
                    ? bounds.maxX - x
                    : columnWidths[column]
                result[index] = CGRect(x: x, y: y, width: width, height: rowHeight)
                x += width + gap
            }
            y += rowHeight + gap
        }
        return result
    }

    /// Equalizes values while honoring lower bounds, like water rising around
    /// blocks of different heights.
    private static func distributeWholePixels(minimums: [CGFloat], total: CGFloat) -> [CGFloat] {
        var continuous = Array(repeating: CGFloat.zero, count: minimums.count)
        var remaining = Set(minimums.indices)
        var remainingTotal = total

        while !remaining.isEmpty {
            let even = remainingTotal / CGFloat(remaining.count)
            let fixed = remaining.filter { minimums[$0] > even }
            if fixed.isEmpty {
                for index in remaining { continuous[index] = even }
                break
            }
            for index in fixed {
                continuous[index] = minimums[index]
                remainingTotal -= minimums[index]
                remaining.remove(index)
            }
        }

        let lowerBounds = minimums.map { ceil($0) }
        var result = continuous.indices.map { max(lowerBounds[$0], floor(continuous[$0])) }
        var delta = Int(round(total - result.reduce(0, +)))
        while delta > 0 {
            let index = result.indices.min { result[$0] < result[$1] }!
            result[index] += 1
            delta -= 1
        }
        while delta < 0 {
            guard let index = result.indices
                .filter({ result[$0] > lowerBounds[$0] })
                .max(by: { result[$0] < result[$1] }) else { break }
            result[index] -= 1
            delta += 1
        }
        return result
    }
}
