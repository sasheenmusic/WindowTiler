import CoreGraphics
import XCTest
@testable import WindowTilerCore

final class ScreenGeometryEngineTests: XCTestCase {
    func testAccessibilityCoordinatesForMonitorsInEveryDirection() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visibleFrames = [
            CGRect(x: 80, y: 0, width: 1840, height: 1055),       // primary, Dock on left
            CGRect(x: 1920, y: 0, width: 2560, height: 1440),     // right and taller
            CGRect(x: -1280, y: 0, width: 1280, height: 1024),    // left
            CGRect(x: 0, y: 1080, width: 1920, height: 1080),     // above
            CGRect(x: 0, y: -900, width: 1600, height: 900),      // below
        ]

        XCTAssertEqual(
            ScreenGeometryEngine.accessibilityFrames(
                visibleFrames: visibleFrames,
                primaryFrame: primary
            ),
            [
                CGRect(x: 80, y: 25, width: 1840, height: 1055),
                CGRect(x: 1920, y: -360, width: 2560, height: 1440),
                CGRect(x: -1280, y: 56, width: 1280, height: 1024),
                CGRect(x: 0, y: -1080, width: 1920, height: 1080),
                CGRect(x: 0, y: 1080, width: 1600, height: 900),
            ]
        )
    }

    func testWindowCentersChooseContainingOrNearestMonitor() {
        let screens = [
            CGRect(x: -1280, y: 56, width: 1280, height: 1024),
            CGRect(x: 0, y: 25, width: 1920, height: 1055),
            CGRect(x: 1920, y: -360, width: 2560, height: 1440),
        ]

        XCTAssertEqual(ScreenGeometryEngine.screenIndex(for: CGPoint(x: -500, y: 500), screens: screens), 0)
        XCTAssertEqual(ScreenGeometryEngine.screenIndex(for: CGPoint(x: 900, y: 500), screens: screens), 1)
        XCTAssertEqual(ScreenGeometryEngine.screenIndex(for: CGPoint(x: 3000, y: 0), screens: screens), 2)
        XCTAssertEqual(ScreenGeometryEngine.screenIndex(for: CGPoint(x: 5000, y: 500), screens: screens), 2)
        XCTAssertNil(ScreenGeometryEngine.screenIndex(for: .zero, screens: []))
    }

    func testTopologyChangesAcrossMonitorsButNotWithinOneMonitor() {
        let screens = [
            CGRect(x: 0, y: 25, width: 1920, height: 1055),
            CGRect(x: 1920, y: -360, width: 2560, height: 1440),
        ]
        let firstPosition = ScreenGeometryEngine.topologySignature(
            windowCenters: [("window-a", CGPoint(x: 200, y: 200))],
            screens: screens
        )
        let movedWithinFirstScreen = ScreenGeometryEngine.topologySignature(
            windowCenters: [("window-a", CGPoint(x: 1600, y: 800))],
            screens: screens
        )
        let movedToSecondScreen = ScreenGeometryEngine.topologySignature(
            windowCenters: [("window-a", CGPoint(x: 2500, y: 500))],
            screens: screens
        )
        let displayDisconnected = ScreenGeometryEngine.topologySignature(
            windowCenters: [("window-a", CGPoint(x: 2500, y: 500))],
            screens: [screens[0]]
        )

        XCTAssertEqual(firstPosition, movedWithinFirstScreen)
        XCTAssertNotEqual(firstPosition, movedToSecondScreen)
        XCTAssertNotEqual(movedToSecondScreen, displayDisconnected)
    }

    func testMixedMonitorSizesEachReceiveCompleteIndependentLayout() {
        let screens = [
            CGRect(x: -1280, y: 56, width: 1280, height: 1024),
            CGRect(x: 0, y: 25, width: 1512, height: 944),
            CGRect(x: 1512, y: -1180, width: 2160, height: 3840), // rotated display
            CGRect(x: 3672, y: -135, width: 3840, height: 2160),
        ]

        for (screen, count) in zip(screens, [3, 10, 12, 25]) {
            let frames = ConstraintGridEngine.frames(
                minimumSizes: Array(repeating: CGSize(width: 320, height: 240), count: count),
                in: screen
            )

            XCTAssertEqual(frames.count, count)
            XCTAssertEqual(frames.reduce(0) { $0 + $1.width * $1.height }, screen.width * screen.height, accuracy: 0.5)
            XCTAssertTrue(frames.allSatisfy(screen.contains))
            for first in frames.indices {
                for second in frames.indices where second > first {
                    XCTAssertFalse(frames[first].intersects(frames[second]))
                }
            }
        }
    }
}
