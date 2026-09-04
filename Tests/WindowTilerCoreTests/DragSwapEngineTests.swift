import XCTest
import CoreGraphics
@testable import WindowTilerCore

final class DragSwapEngineTests: XCTestCase {
    private let a = DragSwapEngine.Candidate(id: "a", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    private let b = DragSwapEngine.Candidate(id: "b", frame: CGRect(x: 800, y: 0, width: 800, height: 600))
    private let behindB = DragSwapEngine.Candidate(id: "c", frame: CGRect(x: 700, y: 0, width: 900, height: 600))

    func testDraggingTheWindowBodyIsAMove() {
        let start = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertEqual(DragSwapEngine.classify(startFrame: start, endFrame: start.offsetBy(dx: 900, dy: 20)), .move)
        XCTAssertEqual(DragSwapEngine.classify(startFrame: start, endFrame: start.offsetBy(dx: 0, dy: 30)), .move)
    }

    func testDraggingAnEdgeIsAResize() {
        let start = CGRect(x: 0, y: 0, width: 800, height: 600)
        let narrower = CGRect(x: 100, y: 0, width: 700, height: 600)
        XCTAssertEqual(DragSwapEngine.classify(startFrame: start, endFrame: narrower), .resize)
    }

    func testATinyMoveIsAWobble() {
        let start = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertEqual(DragSwapEngine.classify(startFrame: start, endFrame: start.offsetBy(dx: 5, dy: 3)), .wobble)
        XCTAssertEqual(DragSwapEngine.classify(startFrame: start, endFrame: start.offsetBy(dx: 1, dy: 1)), .wobble)
    }

    func testFrontmostWindowUnderThePointerIsTheTarget() {
        // The dragged window a is drawn frontmost and sits over b.
        let draggedNow = DragSwapEngine.Candidate(id: "a", frame: CGRect(x: 900, y: 50, width: 800, height: 600))
        let candidates = [draggedNow, b, behindB]
        XCTAssertEqual(DragSwapEngine.target(at: CGPoint(x: 1200, y: 300), excluding: "a", among: candidates), "b")
    }

    func testWindowBehindAnotherIsNotTheTarget() {
        XCTAssertEqual(DragSwapEngine.target(at: CGPoint(x: 1200, y: 300), excluding: "a", among: [b, behindB]), "b")
        XCTAssertEqual(DragSwapEngine.target(at: CGPoint(x: 1200, y: 300), excluding: "a", among: [behindB, b]), "c")
    }

    func testPointerOverNothingOrOnlyTheDraggedWindowIsAMiss() {
        let draggedNow = DragSwapEngine.Candidate(id: "a", frame: CGRect(x: 2000, y: 700, width: 800, height: 600))
        XCTAssertNil(DragSwapEngine.target(at: CGPoint(x: 2100, y: 800), excluding: "a", among: [draggedNow, b]))
        XCTAssertNil(DragSwapEngine.target(at: CGPoint(x: 3000, y: 1300), excluding: "a", among: [draggedNow, b]))
    }

    func testSwappedSlotsExchangeFrames() {
        let swapped = DragSwapEngine.swappedSlots(dragged: a, target: b)
        XCTAssertEqual(swapped, [
            DragSwapEngine.Candidate(id: "a", frame: b.frame),
            DragSwapEngine.Candidate(id: "b", frame: a.frame),
        ])
    }
}
