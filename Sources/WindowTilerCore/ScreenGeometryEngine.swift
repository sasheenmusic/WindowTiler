import CoreGraphics

public enum ScreenGeometryEngine {
    /// Converts AppKit's bottom-left desktop coordinates into the top-left
    /// coordinate system used by the macOS Accessibility API.
    public static func accessibilityFrames(
        visibleFrames: [CGRect],
        primaryFrame: CGRect
    ) -> [CGRect] {
        let primaryTop = primaryFrame.maxY
        return visibleFrames.map { visible in
            CGRect(
                x: visible.minX,
                y: primaryTop - visible.maxY,
                width: visible.width,
                height: visible.height
            )
        }
    }

    /// Uses the monitor containing the window center. If a window is between
    /// or outside displays, selects the physically nearest monitor.
    public static func screenIndex(for point: CGPoint, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        if let containing = screens.indices.first(where: { screens[$0].contains(point) }) {
            return containing
        }
        return screens.indices.min {
            distance(from: point, to: screens[$0]) < distance(from: point, to: screens[$1])
        }
    }

    public static func signature(for frame: CGRect) -> String {
        "\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)"
    }

    /// Changes only when monitors change, windows open/close, or a window
    /// crosses onto a different monitor. Ordinary tiling within one monitor
    /// therefore cannot trigger an automatic re-tile loop.
    public static func topologySignature(
        windowCenters: [(identity: String, center: CGPoint)],
        screens: [CGRect]
    ) -> String {
        let screenKeys = screens.map(signature(for:))
        let windowLocations = windowCenters.map { window -> String in
            let screenKey = screenIndex(for: window.center, screens: screens)
                .map { screenKeys[$0] } ?? "offscreen"
            return "\(window.identity)@\(screenKey)"
        }
        return (screenKeys.sorted() + windowLocations.sorted()).joined(separator: "|")
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}
