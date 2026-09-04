import XCTest
import CoreGraphics
@testable import WindowTilerCore

final class WindowsPerRowTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 30, width: 3440, height: 1410)
    private let minimum = CGSize(width: 320, height: 240)

    private func rowCounts(_ frames: [CGRect]) -> [Int] {
        Dictionary(grouping: frames, by: \.minY).sorted { $0.key < $1.key }.map { $0.value.count }
    }

    private func assertComplete(_ frames: [CGRect], count: Int, _ label: String) {
        XCTAssertEqual(frames.count, count, "Wrong frame count for \(label)")
        XCTAssertEqual(frames.reduce(CGFloat.zero) { $0 + $1.width * $1.height }, bounds.width * bounds.height, accuracy: 0.5, "Area not covered for \(label)")
        for first in frames.indices {
            XCTAssertTrue(bounds.contains(frames[first]), "Escaped bounds for \(label)")
            for second in frames.indices where second > first {
                XCTAssertFalse(frames[first].intersects(frames[second]), "Overlap for \(label)")
            }
        }
    }

    func testEveryFoldCapsRowsAtTheChosenWidth() {
        for fold in TilingLimits.windowsPerRowChoices {
            // Five rows of 240-point minimums is the most this screen holds.
            for count in 1...(5 * fold) {
                let frames = ConstraintGridEngine.frames(
                    minimumSizes: Array(repeating: minimum, count: count),
                    in: bounds,
                    windowsPerRow: fold
                )
                let label = "\(count) windows at \(fold) per row"
                assertComplete(frames, count: count, label)
                let rows = rowCounts(frames)
                XCTAssertEqual(rows.count, Int(ceil(Double(count) / Double(fold))), "Wrong row count for \(label)")
                XCTAssertLessThanOrEqual(rows.max() ?? 0, fold, "Row wider than the fold for \(label)")
            }
        }
    }

    func testFiveWindowsAtTwoPerRowStackAsTwoTwoOne() {
        let frames = ConstraintGridEngine.frames(
            minimumSizes: Array(repeating: minimum, count: 5),
            in: bounds,
            windowsPerRow: 2
        )
        XCTAssertEqual(rowCounts(frames), [2, 2, 1])
    }

    func testScreenTooShortForTheFoldFallsBackToClosestCompleteLayout() {
        // Six rows of 240 points need 1440, more than this screen's 1410.
        let frames = ConstraintGridEngine.frames(
            minimumSizes: Array(repeating: minimum, count: 12),
            in: bounds,
            windowsPerRow: 2
        )
        assertComplete(frames, count: 12, "12 windows at 2 per row")
        XCTAssertGreaterThan(rowCounts(frames).max() ?? 0, 2)
        XCTAssertTrue(frames.allSatisfy { $0.width >= minimum.width && $0.height >= minimum.height })
    }

    func testMosaicPassesTheFoldToFlexibleRegions() {
        let layout = MosaicLayoutEngine.frames(
            constrainedSizes: [CGSize(width: 900, height: 552)],
            flexibleMinimumSizes: Array(repeating: minimum, count: 6),
            in: bounds,
            windowsPerRow: 3
        )
        XCTAssertEqual(layout.flexibleFrames.count, 6)
        XCTAssertLessThanOrEqual(rowCounts(layout.flexibleFrames).max() ?? 0, 3)
    }

    func testDefaultFoldKeepsTodaysLayouts() {
        let eight = ConstraintGridEngine.frames(minimumSizes: Array(repeating: minimum, count: 8), in: bounds)
        XCTAssertEqual(rowCounts(eight), [4, 4])
        let ten = ConstraintGridEngine.frames(minimumSizes: Array(repeating: minimum, count: 10), in: bounds)
        XCTAssertEqual(rowCounts(ten), [5, 5])
    }
}
