import Foundation

public enum PresetStoreError: LocalizedError {
    case invalidData(String)

    public var errorDescription: String? {
        switch self {
        case .invalidData(let reason): return "Invalid saved layout: \(reason)"
        }
    }
}

/// Stores saved layouts only. The currently applied layout belongs to runtime state.
public struct PresetStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Missing files are a new store; unreadable or corrupt files remain untouched.
    public func load() throws -> [LayoutPreset] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return []
        }
        let presets = try JSONDecoder().decode([LayoutPreset].self, from: data)
        try validate(presets)
        return presets
    }

    /// Validates and encodes before touching the destination, then replaces it atomically.
    public func save(_ presets: [LayoutPreset]) throws {
        try validate(presets)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(presets)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private func validate(_ presets: [LayoutPreset]) throws {
        var presetIDs = Set<UUID>()
        for preset in presets {
            guard presetIDs.insert(preset.id).inserted else { throw PresetStoreError.invalidData("duplicate preset ID") }
            guard !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PresetStoreError.invalidData("empty preset name")
            }
            var screenIDs = Set<String>()
            var slotIDs = Set<UUID>()
            for screen in preset.screens {
                guard !screen.id.isEmpty, screenIDs.insert(screen.id).inserted else {
                    throw PresetStoreError.invalidData("empty or duplicate display ID")
                }
                guard screen.savedWidth.isFinite, screen.savedHeight.isFinite,
                      screen.savedWidth > 0, screen.savedHeight > 0 else {
                    throw PresetStoreError.invalidData("invalid saved display size")
                }
                for slot in screen.slots {
                    guard slotIDs.insert(slot.id).inserted else { throw PresetStoreError.invalidData("duplicate slot ID") }
                    guard slot.rect.isValid else { throw PresetStoreError.invalidData("invalid slot rectangle") }
                }
            }
        }
    }
}
