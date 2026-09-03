import CoreGraphics

public struct MosaicLayout: Equatable {
    public let constrainedFrames: [CGRect]
    public let flexibleFrames: [CGRect]

    public init(constrainedFrames: [CGRect], flexibleFrames: [CGRect]) {
        self.constrainedFrames = constrainedFrames
        self.flexibleFrames = flexibleFrames
    }
}

public enum MosaicLayoutEngine {
    private struct Candidate {
        let constrainedFrames: [CGRect]
        let freeRegions: [CGRect]
    }

    /// Places native/minimum-size windows as exact rectangles, then tiles all
    /// flexible windows through every remaining rectangle. All boundaries are
    /// shared, so there are no rounding seams between neighboring windows.
    public static func frames(
        constrainedSizes: [CGSize],
        flexibleMinimumSizes: [CGSize],
        in bounds: CGRect
    ) -> MosaicLayout {
        guard !constrainedSizes.isEmpty else {
            return MosaicLayout(
                constrainedFrames: [],
                flexibleFrames: ConstraintGridEngine.frames(
                    minimumSizes: flexibleMinimumSizes,
                    in: bounds
                )
            )
        }

        let candidates = [
            columnsAcrossTop(constrainedSizes, in: bounds),
            rowsDownLeft(constrainedSizes, in: bounds),
        ].compactMap { $0 }

        guard let chosen = candidates.max(by: {
            score($0, flexibleCount: flexibleMinimumSizes.count)
                < score($1, flexibleCount: flexibleMinimumSizes.count)
        }) else {
            // If the native windows cannot fit in either direction, retain the
            // ordinary constraint-aware grid as the safest bounded fallback.
            let all = constrainedSizes + flexibleMinimumSizes
            let frames = ConstraintGridEngine.frames(minimumSizes: all, in: bounds)
            return MosaicLayout(
                constrainedFrames: Array(frames.prefix(constrainedSizes.count)),
                flexibleFrames: Array(frames.dropFirst(constrainedSizes.count))
            )
        }

        return MosaicLayout(
            constrainedFrames: chosen.constrainedFrames,
            flexibleFrames: fill(
                chosen.freeRegions,
                minimumSizes: flexibleMinimumSizes
            )
        )
    }

    private static func columnsAcrossTop(_ sizes: [CGSize], in bounds: CGRect) -> Candidate? {
        guard sizes.allSatisfy({ $0.width <= bounds.width && $0.height <= bounds.height }),
              sizes.reduce(0, { $0 + $1.width }) <= bounds.width else { return nil }

        var x = bounds.minX
        var frames: [CGRect] = []
        var regions: [CGRect] = []
        for size in sizes {
            let right = x + size.width
            let bottom = bounds.minY + size.height
            frames.append(CGRect(x: x, y: bounds.minY, width: size.width, height: size.height))
            if bottom < bounds.maxY {
                regions.append(CGRect(x: x, y: bottom, width: size.width, height: bounds.maxY - bottom))
            }
            x = right
        }
        if x < bounds.maxX {
            regions.append(CGRect(x: x, y: bounds.minY, width: bounds.maxX - x, height: bounds.height))
        }
        return Candidate(constrainedFrames: frames, freeRegions: regions)
    }

    private static func rowsDownLeft(_ sizes: [CGSize], in bounds: CGRect) -> Candidate? {
        guard sizes.allSatisfy({ $0.width <= bounds.width && $0.height <= bounds.height }),
              sizes.reduce(0, { $0 + $1.height }) <= bounds.height else { return nil }

        var y = bounds.minY
        var frames: [CGRect] = []
        var regions: [CGRect] = []
        for size in sizes {
            let right = bounds.minX + size.width
            let bottom = y + size.height
            frames.append(CGRect(x: bounds.minX, y: y, width: size.width, height: size.height))
            if right < bounds.maxX {
                regions.append(CGRect(x: right, y: y, width: bounds.maxX - right, height: size.height))
            }
            y = bottom
        }
        if y < bounds.maxY {
            regions.append(CGRect(x: bounds.minX, y: y, width: bounds.width, height: bounds.maxY - y))
        }
        return Candidate(constrainedFrames: frames, freeRegions: regions)
    }

    private static func score(_ candidate: Candidate, flexibleCount: Int) -> Double {
        let usable = candidate.freeRegions.filter(TilingLimits.isUsableRegion)
        let fillable = min(usable.count, flexibleCount)
        let unfilledArea = usable
            .sorted { $0.width * $0.height > $1.width * $1.height }
            .dropFirst(fillable)
            .reduce(CGFloat.zero) { $0 + $1.width * $1.height }
        // Filling every separate region matters much more than its orientation.
        return Double(fillable) * 1_000_000_000 - Double(unfilledArea)
    }

    private static func fill(_ regions: [CGRect], minimumSizes: [CGSize]) -> [CGRect] {
        guard !minimumSizes.isEmpty else { return [] }

        let usableRegions = regions
            .filter(TilingLimits.isUsableRegion)
            .sorted { $0.width * $0.height > $1.width * $1.height }
        guard !usableRegions.isEmpty else { return [] }

        var counts = Array(repeating: 0, count: usableRegions.count)
        for index in 0..<min(minimumSizes.count, usableRegions.count) {
            counts[index] = 1
        }
        if minimumSizes.count > usableRegions.count {
            for _ in usableRegions.count..<minimumSizes.count {
                let best = usableRegions.indices.max {
                    let left = usableRegions[$0].width * usableRegions[$0].height / CGFloat(counts[$0] + 1)
                    let right = usableRegions[$1].width * usableRegions[$1].height / CGFloat(counts[$1] + 1)
                    return left < right
                }!
                counts[best] += 1
            }
        }

        var result = Array(repeating: CGRect.zero, count: minimumSizes.count)
        var nextWindow = 0
        for regionIndex in usableRegions.indices where counts[regionIndex] > 0 {
            let end = nextWindow + counts[regionIndex]
            let indices = Array(nextWindow..<end)
            let frames = ConstraintGridEngine.frames(
                minimumSizes: indices.map { minimumSizes[$0] },
                in: usableRegions[regionIndex]
            )
            for (offset, windowIndex) in indices.enumerated() {
                result[windowIndex] = frames[offset]
            }
            nextWindow = end
        }
        return result
    }
}
