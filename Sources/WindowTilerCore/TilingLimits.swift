import CoreGraphics

public enum TilingLimits {
    /// The smallest tile any flexible window is assumed to accept. Both the
    /// layout engines and the app's size learning use this single value.
    public static let minimumTileSize = CGSize(width: 320, height: 240)

    /// The most windows the automatic layout puts in one row before it
    /// starts another. Chosen in the menu; the default is five.
    public static let windowsPerRowChoices = [2, 3, 4, 5]
    public static let defaultWindowsPerRow = 5

    public static func isUsableRegion(_ rect: CGRect) -> Bool {
        rect.width >= minimumTileSize.width && rect.height >= minimumTileSize.height
    }
}
