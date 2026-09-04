import XCTest
import CoreGraphics
@testable import WindowTilerCore

final class RowPlanTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 30, width: 3440, height: 1410)

    func testEveryRowPlanUpToFiveByFiveTilesTheScreenExactly() {
        var checked = 0
        for plan in allPlans() {
            let frames = LayoutEngine.frames(rowCounts: plan, in: bounds)
            let expected = plan.reduce(0, +)
            XCTAssertEqual(frames.count, expected, "Wrong frame count for \(plan)")

            let rowTops = frames.map(\.minY)
            XCTAssertEqual(Set(rowTops).count, plan.count, "Wrong row count for \(plan)")
            let heights = Set(frames.map(\.height))
            XCTAssertLessThanOrEqual((heights.max() ?? 0) - (heights.min() ?? 0), 1, "Uneven rows for \(plan)")

            let perRow = Dictionary(grouping: frames, by: \.minY)
                .sorted { $0.key < $1.key }
                .map { $0.value.count }
            XCTAssertEqual(perRow, plan, "Rows hold the wrong counts for \(plan)")

            XCTAssertEqual(frames.reduce(CGFloat.zero) { $0 + $1.width * $1.height }, bounds.width * bounds.height, accuracy: 0.5, "Area not covered for \(plan)")
            XCTAssertEqual(frames.map(\.minX).min(), bounds.minX)
            XCTAssertEqual(frames.map(\.maxX).max(), bounds.maxX)
            XCTAssertEqual(frames.map(\.minY).min(), bounds.minY)
            XCTAssertEqual(frames.map(\.maxY).max(), bounds.maxY)
            XCTAssertTrue(frames.allSatisfy {
                $0.minX.rounded() == $0.minX && $0.minY.rounded() == $0.minY
                    && $0.width.rounded() == $0.width && $0.height.rounded() == $0.height
            }, "Non-pixel boundary for \(plan)")

            for index in frames.indices {
                XCTAssertTrue(bounds.contains(frames[index]))
                if index + 1 < frames.count {
                    let next = frames[index + 1]
                    let sameRowToTheRight = next.minY == frames[index].minY && next.minX == frames[index].maxX
                    let startsNextRow = next.minY == frames[index].maxY && next.minX == bounds.minX
                    XCTAssertTrue(sameRowToTheRight || startsNextRow, "Not in reading order for \(plan) at \(index)")
                }
                for other in frames.indices where other > index {
                    XCTAssertFalse(frames[index].intersects(frames[other]), "Overlap for \(plan)")
                }
            }
            checked += 1
        }
        XCTAssertEqual(checked, 3_905)
    }

    func testFourOnTopOneBelowGivesTwoEqualBands() {
        let frames = LayoutEngine.frames(rowCounts: [4, 1], in: bounds)
        XCTAssertEqual(frames.count, 5)
        XCTAssertEqual(frames.prefix(4).map(\.width), [860, 860, 860, 860])
        XCTAssertEqual(frames[4], CGRect(x: 0, y: 735, width: 3440, height: 705))
        XCTAssertEqual(Set(frames.map(\.height)), [705])
    }

    func testEmptyPlanProducesNoFrames() {
        XCTAssertEqual(LayoutEngine.frames(rowCounts: [], in: bounds), [])
        XCTAssertEqual(LayoutEngine.frames(rowCounts: [0, 0], in: bounds), [])
    }

    func testRowPlanDropsEmptyBandsAndValidatesLimits() {
        let plan = RowPlan(rowCounts: [4, 0, 1, 0, 0])
        XCTAssertEqual(plan.rows, [4, 1])
        XCTAssertEqual(plan.windowCount, 5)
        XCTAssertEqual(plan.title, "4 + 1")
        XCTAssertTrue(plan.isValid)
        XCTAssertTrue(plan.fits(windowCount: 5))
        XCTAssertFalse(plan.fits(windowCount: 4))
        XCTAssertFalse(plan.fits(windowCount: 6))

        XCTAssertFalse(RowPlan(rowCounts: []).isValid)
        XCTAssertFalse(RowPlan(rowCounts: [6]).isValid)
        XCTAssertFalse(RowPlan(rowCounts: [1, 1, 1, 1, 1, 1]).isValid)
        XCTAssertTrue(RowPlan(rowCounts: [5, 5, 5, 5, 5]).fits(windowCount: 25))
    }

    /// Every band count from 1 to 5, for 1 to 5 bands: 5 + 25 + 125 + 625 + 3125.
    private func allPlans() -> [[Int]] {
        var plans: [[Int]] = []
        var current: [Int] = []
        func extend() {
            if !current.isEmpty { plans.append(current) }
            guard current.count < RowPlan.maximumRows else { return }
            for count in 1...RowPlan.maximumColumns {
                current.append(count)
                extend()
                current.removeLast()
            }
        }
        extend()
        return plans
    }
}
