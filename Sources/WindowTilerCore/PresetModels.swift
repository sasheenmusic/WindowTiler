import CoreGraphics
import Foundation

/// Fractions of a display's usable frame, measured from its top-left corner.
public struct PresetRect: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1 + 1e-9 && y + height <= 1 + 1e-9
    }

    /// Clips an on-screen window to the usable frame before normalizing it.
    public init?(frame: CGRect, in usableFrame: CGRect) {
        guard Self.isUsable(usableFrame), Self.isUsable(frame) else { return nil }
        let clipped = frame.intersection(usableFrame)
        guard Self.isUsable(clipped) else { return nil }
        self.init(
            x: Double((clipped.minX - usableFrame.minX) / usableFrame.width),
            y: Double((clipped.minY - usableFrame.minY) / usableFrame.height),
            width: Double(clipped.width / usableFrame.width),
            height: Double(clipped.height / usableFrame.height)
        )
    }

    /// Projects a saved slot into the current top-left usable display frame.
    /// A window's minimum size can expand a slot, but never beyond the display.
    public func frame(in usableFrame: CGRect, minimumSize: CGSize = .zero) -> CGRect? {
        guard isValid, Self.isUsable(usableFrame),
              minimumSize.width.isFinite, minimumSize.height.isFinite,
              minimumSize.width >= 0, minimumSize.height >= 0 else { return nil }
        let projectedWidth = min(usableFrame.width, max(CGFloat(width) * usableFrame.width, minimumSize.width))
        let projectedHeight = min(usableFrame.height, max(CGFloat(height) * usableFrame.height, minimumSize.height))
        return CGRect(
            x: min(usableFrame.maxX - projectedWidth, max(usableFrame.minX, usableFrame.minX + CGFloat(x) * usableFrame.width)),
            y: min(usableFrame.maxY - projectedHeight, max(usableFrame.minY, usableFrame.minY + CGFloat(y) * usableFrame.height)),
            width: projectedWidth,
            height: projectedHeight
        )
    }

    private static func isUsable(_ frame: CGRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.width, frame.height, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0
    }
}

public struct PresetApp: Codable, Equatable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

public struct PresetSlot: Codable, Equatable, Identifiable {
    public var id: UUID
    public var rect: PresetRect
    public var app: PresetApp?
    public var restoreApp: Bool

    public init(id: UUID = UUID(), rect: PresetRect, app: PresetApp? = nil, restoreApp: Bool = true) {
        self.id = id
        self.rect = rect
        self.app = app
        self.restoreApp = restoreApp
    }
}

public struct PresetScreen: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var savedWidth: Double
    public var savedHeight: Double
    public var slots: [PresetSlot]
    public var isIncluded: Bool

    public init(id: String, name: String, savedWidth: Double, savedHeight: Double, slots: [PresetSlot] = [], isIncluded: Bool = true) {
        self.id = id
        self.name = name
        self.savedWidth = savedWidth
        self.savedHeight = savedHeight
        self.slots = slots
        self.isIncluded = isIncluded
    }
}

public struct PresetShortcut: Codable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct LayoutPreset: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var screens: [PresetScreen]
    public var rememberApps: Bool
    public var launchMissingApps: Bool
    public var shortcut: PresetShortcut?

    public init(id: UUID = UUID(), name: String, screens: [PresetScreen] = [], rememberApps: Bool = true, launchMissingApps: Bool = false, shortcut: PresetShortcut? = nil) {
        self.id = id
        self.name = name
        self.screens = screens
        self.rememberApps = rememberApps
        self.launchMissingApps = launchMissingApps
        self.shortcut = shortcut
    }
}
