import CoreGraphics

public enum TilingLimits {
    /// The smallest tile any flexible window is assumed to accept. Both the
    /// layout engines and the app's size learning use this single value.
    public static let minimumTileSize = CGSize(width: 320, height: 240)

    public static func isUsableRegion(_ rect: CGRect) -> Bool {
        rect.width >= minimumTileSize.width && rect.height >= minimumTileSize.height
    }
}
