import CoreGraphics

/// Space left between tiled windows and along the screen edges, so the
/// desktop background shows through. The layout engines work on padded
/// cells: the screen is shrunk by half a gap, every cell is laid out edge to
/// edge as before, and each window is then inset by half a gap inside its
/// cell. Neighbors end up a full gap apart, and so do windows and the edges.
public enum WindowGap {
    /// Points. Even values keep every half-gap on a whole pixel.
    public static let choices = [0, 8, 16, 32, 64, 128]
    public static let defaultGap = 0

    /// The area the padded cells fill.
    public static func layoutBounds(_ screen: CGRect, gap: CGFloat) -> CGRect {
        guard gap > 0 else { return screen }
        return screen.insetBy(dx: gap / 2, dy: gap / 2)
    }

    /// The cell a window of this size needs so it keeps that size once inset.
    public static func cellSize(for windowSize: CGSize, gap: CGFloat) -> CGSize {
        CGSize(width: windowSize.width + gap, height: windowSize.height + gap)
    }

    /// The window's frame inside its padded cell.
    public static func windowFrame(in cell: CGRect, gap: CGFloat) -> CGRect {
        guard gap > 0, cell.width > gap, cell.height > gap else { return cell }
        return cell.insetBy(dx: gap / 2, dy: gap / 2)
    }
}
