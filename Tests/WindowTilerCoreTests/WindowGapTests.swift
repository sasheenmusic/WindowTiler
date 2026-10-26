import XCTest
import CoreGraphics
@testable import WindowTilerCore

final class WindowGapTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 30, width: 3440, height: 1410)
    private let minimum = CGSize(width: 320, height: 240)

    private func gapped(_ cells: [CGRect], _ gap: CGFloat) -> [CGRect] {
        cells.map { WindowGap.windowFrame(in: $0, gap: gap) }
    }

    /// Every window keeps a full gap from the screen edges and from each
    /// neighbor it shares a row or column with.
    private func assertSpaced(_ frames: [CGRect], gap: CGFloat, _ label: String) {
        let inner = screen.insetBy(dx: gap, dy: gap)
        for frame in frames {
            XCTAssertTrue(inner.contains(frame), "Closer than the gap to an edge for \(label)")
        }
        for first in frames.indices {
            for second in frames.indices where second != first {
                XCTAssertFalse(
                    frames[first].insetBy(dx: -gap / 2 + 0.5, dy: -gap / 2 + 0.5)
                        .intersects(frames[second].insetBy(dx: -gap / 2 + 0.5, dy: -gap / 2 + 0.5)),
                    "Neighbors closer than the gap for \(label)"
                )
            }
        }
        // Edges get exactly the gap: some window touches each inner edge.
        XCTAssertEqual(frames.map(\.minX).min(), inner.minX, "Left edge for \(label)")
        XCTAssertEqual(frames.map(\.maxX).max(), inner.maxX, "Right edge for \(label)")
        XCTAssertEqual(frames.map(\.minY).min(), inner.minY, "Top edge for \(label)")
        XCTAssertEqual(frames.map(\.maxY).max(), inner.maxY, "Bottom edge for \(label)")
    }

    func testChoicesAreEvenSoHalfGapsStayOnWholePixels() {
        XCTAssertEqual(WindowGap.choices.first, 0)
        XCTAssertTrue(WindowGap.choices.allSatisfy { $0 % 2 == 0 })
        XCTAssertTrue(WindowGap.choices.contains(WindowGap.defaultGap))
    }

    func testNoGapLeavesTheLayoutUnchanged() {
        let cells = ConstraintGridEngine.frames(minimumSizes: Array(repeating: minimum, count: 5), in: screen)
        XCTAssertEqual(WindowGap.layoutBounds(screen, gap: 0), screen)
        XCTAssertEqual(gapped(cells, 0), cells)
    }

    func testAutomaticLayoutKeepsAFullGapEverywhere() {
        for gap in WindowGap.choices.dropFirst().map(CGFloat.init) {
            for count in 1...12 {
                let cells = ConstraintGridEngine.frames(
                    minimumSizes: Array(repeating: WindowGap.cellSize(for: minimum, gap: gap), count: count),
                    in: WindowGap.layoutBounds(screen, gap: gap)
                )
                let frames = gapped(cells, gap)
                XCTAssertEqual(frames.count, count)
                XCTAssertTrue(frames.allSatisfy { $0.width >= minimum.width && $0.height >= minimum.height })
                assertSpaced(frames, gap: gap, "\(count) windows, gap \(gap)")
            }
        }
    }

    func testHandPickedRowsKeepAFullGapEverywhere() {
        let gap: CGFloat = 12
        let cells = LayoutEngine.frames(rowCounts: [4, 1], in: WindowGap.layoutBounds(screen, gap: gap))
        let frames = gapped(cells, gap)
        assertSpaced(frames, gap: gap, "rows 4 + 1")
        // Neighbors in the top row are exactly one gap apart.
        XCTAssertEqual(frames[1].minX - frames[0].maxX, gap)
        XCTAssertEqual(frames[4].minY - frames[0].maxY, gap)
    }

    func testFixedSizeWindowKeepsItsExactSize() {
        let gap: CGFloat = 16
        let native = CGSize(width: 700, height: 500)
        let layout = MosaicLayoutEngine.frames(
            constrainedSizes: [WindowGap.cellSize(for: native, gap: gap)],
            flexibleMinimumSizes: [WindowGap.cellSize(for: minimum, gap: gap)],
            in: WindowGap.layoutBounds(screen, gap: gap)
        )
        let fixed = gapped(layout.constrainedFrames, gap)
        XCTAssertEqual(fixed.first?.size, native)
        assertSpaced(fixed + gapped(layout.flexibleFrames, gap), gap: gap, "fixed + flexible")
    }
}
