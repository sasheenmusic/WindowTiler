import XCTest
import CoreGraphics
@testable import WindowTilerCore

final class LayoutEngineTests: XCTestCase {
    func testFlexibleWindowCountsOneThroughTwentyFiveFillScreenWithExpectedRows() {
        let bounds = CGRect(x: 0, y: 30, width: 3440, height: 1410)

        for count in 1...25 {
            let frames = ConstraintGridEngine.frames(
                minimumSizes: Array(repeating: CGSize(width: 320, height: 240), count: count),
                in: bounds
            )
            let expectedRows = Int(ceil(Double(count) / 5.0))

            XCTAssertEqual(frames.count, count, "Wrong frame count for \(count) windows")
            XCTAssertEqual(Set(frames.map(\.minY)).count, expectedRows, "Wrong row count for \(count) windows")
            let windowsPerRow = Dictionary(grouping: frames, by: \.minY).values.map(\.count)
            XCTAssertLessThanOrEqual(windowsPerRow.max() ?? 0, 5, "More than five tiles across for \(count) windows")
            XCTAssertEqual(frames.reduce(CGFloat.zero) { $0 + $1.width * $1.height }, bounds.width * bounds.height, accuracy: 0.5)
            XCTAssertEqual(frames.map(\.minX).min(), bounds.minX)
            XCTAssertEqual(frames.map(\.maxX).max(), bounds.maxX)
            XCTAssertEqual(frames.map(\.minY).min(), bounds.minY)
            XCTAssertEqual(frames.map(\.maxY).max(), bounds.maxY)
            XCTAssertTrue(frames.allSatisfy {
                $0.minX.rounded() == $0.minX && $0.minY.rounded() == $0.minY
                    && $0.width.rounded() == $0.width && $0.height.rounded() == $0.height
            }, "Non-pixel boundary for \(count) windows")

            for first in frames.indices {
                XCTAssertTrue(bounds.contains(frames[first]))
                for second in frames.indices where second > first {
                    XCTAssertFalse(frames[first].intersects(frames[second]), "Overlap for \(count) windows")
                }
            }
        }
    }

    func testCountsBeyondFiveAcrossCapacityStillTileEveryWindow() {
        let bounds = CGRect(x: 0, y: 30, width: 3440, height: 1410)

        for count in [26, 30, 50, 51, 75, 100] {
            let frames = ConstraintGridEngine.frames(
                minimumSizes: Array(repeating: CGSize(width: 320, height: 240), count: count),
                in: bounds
            )

            XCTAssertEqual(frames.count, count, "Wrong frame count for \(count) windows")
            XCTAssertEqual(frames.reduce(CGFloat.zero) { $0 + $1.width * $1.height }, bounds.width * bounds.height, accuracy: 0.5)
            XCTAssertTrue(frames.allSatisfy { bounds.contains($0) && $0.width > 0 && $0.height > 0 })
            for first in frames.indices {
                for second in frames.indices where second > first {
                    XCTAssertFalse(frames[first].intersects(frames[second]), "Overlap for \(count) windows")
                }
            }
        }
    }

    func testNoWindowsProducesNoFrames() {
        XCTAssertEqual(LayoutEngine.frames(count: 0, in: CGRect(x: 0, y: 0, width: 1000, height: 800)), [])
    }

    func testOneWindowFillsBoundsWithGap() {
        XCTAssertEqual(
            LayoutEngine.frames(count: 1, in: CGRect(x: 0, y: 0, width: 1000, height: 800), gap: 10),
            [CGRect(x: 10, y: 10, width: 980, height: 780)]
        )
    }

    func testProductionLayoutTouchesEveryScreenEdgeWithNoGaps() {
        let bounds = CGRect(x: 0, y: 30, width: 3440, height: 1410)
        let frames = ConstraintGridEngine.frames(
            minimumSizes: Array(repeating: CGSize(width: 320, height: 240), count: 8),
            in: bounds
        )

        XCTAssertEqual(frames.map(\.minX).min(), bounds.minX)
        XCTAssertEqual(frames.map(\.maxX).max(), bounds.maxX)
        XCTAssertEqual(frames.map(\.minY).min(), bounds.minY)
        XCTAssertEqual(frames.map(\.maxY).max(), bounds.maxY)
        XCTAssertEqual(Dictionary(grouping: frames, by: \.minY).values.map(\.count).sorted(), [4, 4])
    }

    func testFiveWindowsUseBalancedThreeAndTwoRows() {
        let frames = LayoutEngine.frames(count: 5, in: CGRect(x: 0, y: 0, width: 1200, height: 800), gap: 8)
        XCTAssertEqual(frames.count, 5)
        XCTAssertEqual(frames.filter { $0.minY == frames[0].minY }.count, 3)
        XCTAssertEqual(frames.filter { $0.minY == frames[3].minY }.count, 2)
        XCTAssertGreaterThan(frames[3].width, frames[0].width)
        XCTAssertLessThan(frames[3].height, frames[0].height)

        let areas = frames.map { $0.width * $0.height }
        XCTAssertLessThan(areas.max()! - areas.min()!, 5_000)
    }

    func testFramesStayInsideOffsetBounds() {
        let bounds = CGRect(x: -1440, y: 25, width: 1440, height: 875)
        for frame in LayoutEngine.frames(count: 9, in: bounds) {
            XCTAssertTrue(bounds.contains(frame))
        }
    }

    func testLayoutsFromOneThroughThirtyAreCompleteAndNonOverlapping() {
        let bounds = CGRect(x: -1512, y: 38, width: 1512, height: 944)

        for count in 1...30 {
            let frames = LayoutEngine.frames(count: count, in: bounds, gap: 8)
            XCTAssertEqual(frames.count, count, "Wrong tile count for \(count) windows")

            for (index, frame) in frames.enumerated() {
                XCTAssertTrue(bounds.contains(frame), "Tile \(index) escaped the screen for count \(count)")
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThan(frame.height, 0)

                for otherIndex in frames.indices where otherIndex > index {
                    XCTAssertFalse(
                        frame.intersects(frames[otherIndex]),
                        "Tiles \(index) and \(otherIndex) overlap for count \(count)"
                    )
                }
            }
        }
    }

    func testEveryWindowGetsNearlyEqualArea() {
        let bounds = CGRect(x: 0, y: 0, width: 1728, height: 1079)

        for count in 2...30 {
            let areas = LayoutEngine.frames(count: count, in: bounds, gap: 8)
                .map { $0.width * $0.height }
            let ratio = areas.max()! / areas.min()!
            XCTAssertLessThan(ratio, 1.08, "Area balance is poor for \(count) windows")
        }
    }

    func testConstraintGridChoosesTallerRowsForNineDesktopWindows() {
        let minimums = Array(repeating: CGSize(width: 500, height: 500), count: 9)
        let frames = ConstraintGridEngine.frames(
            minimumSizes: minimums,
            in: CGRect(x: 0, y: 0, width: 3440, height: 1410),
            gap: 8
        )

        XCTAssertEqual(frames.count, 9)
        XCTAssertTrue(frames.allSatisfy { $0.width >= 500 && $0.height >= 500 })
        XCTAssertEqual(Set(frames.map(\.minY)).count, 2)
    }

    func testEightFlexibleAppsUseFourOnTopAndFourOnBottom() {
        let frames = ConstraintGridEngine.frames(
            minimumSizes: Array(repeating: CGSize(width: 320, height: 240), count: 8),
            in: CGRect(x: 0, y: 0, width: 3440, height: 1410),
            gap: 8
        )

        let rows = Dictionary(grouping: frames, by: \.minY).values.map(\.count).sorted()
        XCTAssertEqual(rows, [4, 4])
    }

    func testTenFlexibleAppsUseFiveOnTopAndFiveOnBottom() {
        let frames = ConstraintGridEngine.frames(
            minimumSizes: Array(repeating: CGSize(width: 320, height: 240), count: 10),
            in: CGRect(x: 0, y: 0, width: 3440, height: 1410)
        )

        let rows = Dictionary(grouping: frames, by: \.minY).values.map(\.count).sorted()
        XCTAssertEqual(rows, [5, 5])
        XCTAssertEqual(Set(frames.map(\.height)), [705])
    }

    func testCurrentNineWindowDesktopUsesTwoEqualHeightBands() {
        let bounds = CGRect(x: 0, y: 30, width: 3440, height: 1410)
        let frames = ConstraintGridEngine.frames(
            minimumSizes: [
                CGSize(width: 500, height: 375),
                CGSize(width: 516, height: 280),
                CGSize(width: 529, height: 240),
                CGSize(width: 381, height: 240),
                CGSize(width: 512, height: 520),
                CGSize(width: 480, height: 600),
                CGSize(width: 380, height: 512),
                CGSize(width: 320, height: 240),
                CGSize(width: 723, height: 470),
            ],
            in: bounds
        )

        let bands = Dictionary(grouping: frames, by: \.minY)
        XCTAssertEqual(bands.count, 2)
        XCTAssertEqual(Set(frames.map(\.height)), [705])
        XCTAssertEqual(frames.reduce(CGFloat.zero) { $0 + $1.width * $1.height }, bounds.width * bounds.height, accuracy: 0.5)
    }

    func testFourFlexibleAppsUseOneRow() {
        let frames = ConstraintGridEngine.frames(
            minimumSizes: Array(repeating: CGSize(width: 320, height: 240), count: 4),
            in: CGRect(x: 0, y: 0, width: 3440, height: 1410),
            gap: 8
        )

        XCTAssertEqual(Set(frames.map(\.minY)).count, 1)
    }

    func testSixFlexibleAppsBalanceAcrossTwoRows() {
        let frames = ConstraintGridEngine.frames(
            minimumSizes: Array(repeating: CGSize(width: 320, height: 240), count: 6),
            in: CGRect(x: 0, y: 0, width: 3440, height: 1410),
            gap: 8
        )

        let rows = Dictionary(grouping: frames, by: \.minY).values.map(\.count).sorted()
        XCTAssertEqual(rows, [3, 3])
    }

    func testConstraintGridKeepsUnevenMinimumsOnScreenWithoutOverlap() {
        let minimums = [
            CGSize(width: 700, height: 500),
            CGSize(width: 500, height: 650),
            CGSize(width: 320, height: 240),
            CGSize(width: 450, height: 400),
            CGSize(width: 600, height: 350),
        ]
        let bounds = CGRect(x: -1720, y: 30, width: 3440, height: 1410)
        let frames = ConstraintGridEngine.frames(minimumSizes: minimums, in: bounds)

        XCTAssertEqual(frames.count, minimums.count)
        XCTAssertTrue(frames.allSatisfy(bounds.contains))
        for first in frames.indices {
            for second in frames.indices where second > first {
                XCTAssertFalse(frames[first].intersects(frames[second]))
            }
        }
    }

    func testMosaicFillsEveryRegionAroundMinimumWindowsWithoutOverlap() {
        let bounds = CGRect(x: 0, y: 0, width: 3440, height: 1410)
        let layout = MosaicLayoutEngine.frames(
            constrainedSizes: [
                CGSize(width: 900, height: 552),
                CGSize(width: 720, height: 772),
                CGSize(width: 723, height: 470),
                CGSize(width: 512, height: 586),
            ],
            flexibleMinimumSizes: Array(repeating: CGSize(width: 320, height: 240), count: 6),
            in: bounds
        )

        XCTAssertEqual(layout.constrainedFrames.count, 4)
        XCTAssertEqual(layout.flexibleFrames.count, 6)
        let allFrames = layout.constrainedFrames + layout.flexibleFrames
        XCTAssertTrue(allFrames.allSatisfy(bounds.contains))
        for first in allFrames.indices {
            for second in allFrames.indices where second > first {
                XCTAssertFalse(allFrames[first].intersects(allFrames[second]))
            }
        }

        let totalArea = allFrames.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
        XCTAssertEqual(totalArea, bounds.width * bounds.height, accuracy: 0.5)
    }
}
