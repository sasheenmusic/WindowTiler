import Foundation
import XCTest
@testable import WindowTilerCore

final class PresetRectTests: XCTestCase {
    func testCaptureAndRestorePreserveExactWindowAndGapsOnNegativeDisplayOrigin() throws {
        let screen = CGRect(x: -1920, y: -1080, width: 1920, height: 1055)
        let window = CGRect(x: -1900, y: -1040, width: 900, height: 1000)
        let rect = try XCTUnwrap(PresetRect(frame: window, in: screen))
        let restored = try XCTUnwrap(rect.frame(in: screen))
        XCTAssertEqual(restored.minX, window.minX, accuracy: 1e-9)
        XCTAssertEqual(restored.minY, window.minY, accuracy: 1e-9)
        XCTAssertEqual(restored.width, window.width, accuracy: 1e-9)
        XCTAssertEqual(restored.height, window.height, accuracy: 1e-9)
    }

    func testProjectionScalesToDifferentDisplaySizeAndPosition() throws {
        let rect = PresetRect(x: 0.1, y: 0.2, width: 0.4, height: 0.5)
        let frame = try XCTUnwrap(rect.frame(in: CGRect(x: 3000, y: -600, width: 1000, height: 800)))
        XCTAssertEqual(frame, CGRect(x: 3100, y: -440, width: 400, height: 400))
    }

    func testMinimumWindowSizeExpandsAndClampsAtDisplayEdge() throws {
        let rect = PresetRect(x: 0.8, y: 0.9, width: 0.2, height: 0.1)
        let screen = CGRect(x: -1000, y: -500, width: 1000, height: 800)
        XCTAssertEqual(rect.frame(in: screen, minimumSize: CGSize(width: 400, height: 300)), CGRect(x: -400, y: 0, width: 400, height: 300))
        XCTAssertEqual(rect.frame(in: screen, minimumSize: CGSize(width: 2000, height: 1000)), screen)
    }

    func testCaptureClipsPartlyOffscreenWindowAndRejectsOffscreenWindow() throws {
        let screen = CGRect(x: -1000, y: -500, width: 1000, height: 800)
        let clipped = try XCTUnwrap(PresetRect(frame: CGRect(x: -1100, y: -600, width: 500, height: 400), in: screen))
        XCTAssertEqual(clipped.frame(in: screen), CGRect(x: -1000, y: -500, width: 400, height: 300))
        XCTAssertNil(PresetRect(frame: CGRect(x: 100, y: 0, width: 500, height: 400), in: screen))
    }

    func testInvalidGeometryAndConstraintsNeverProduceFrames() {
        let valid = PresetRect(x: 0, y: 0, width: 1, height: 1)
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertNil(valid.frame(in: .zero))
        XCTAssertNil(valid.frame(in: CGRect(x: CGFloat.infinity, y: 0, width: 1000, height: 800)))
        XCTAssertNil(valid.frame(in: screen, minimumSize: CGSize(width: -1, height: 10)))
        XCTAssertNil(valid.frame(in: screen, minimumSize: CGSize(width: CGFloat.nan, height: 10)))
        XCTAssertNil(PresetRect(x: 0, y: 0, width: 2, height: 1).frame(in: screen))
        XCTAssertNil(PresetRect(frame: .zero, in: screen))
    }
}
