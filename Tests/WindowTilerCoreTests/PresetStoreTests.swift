import Foundation
import XCTest
@testable import WindowTilerCore

final class PresetStoreTests: XCTestCase {
    private var directory: URL!
    private var store: PresetStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WindowTilerPresets-\(UUID().uuidString)")
        store = PresetStore(fileURL: directory.appendingPathComponent("nested/presets.json"))
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testMissingFileIsEmptyAndDoesNotCreateFile() throws {
        XCTAssertEqual(try store.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRoundTripPreservesDisabledSlotsAndAppMetadata() throws {
        var preset = samplePreset()
        preset.rememberApps = false
        preset.launchMissingApps = true
        preset.screens[0].isIncluded = false
        preset.screens[0].slots[0].restoreApp = false
        preset.shortcut = PresetShortcut(keyCode: 18, modifiers: 0x900)
        try store.save([preset])

        let loaded = try XCTUnwrap(store.load().first)
        XCTAssertEqual(loaded, preset)
        XCTAssertEqual(loaded.screens[0].slots.count, 1)
        XCTAssertEqual(loaded.screens[0].slots[0].app?.bundleID, "com.apple.Safari")
        XCTAssertFalse(loaded.screens[0].slots[0].restoreApp)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [[String: Any]]
        XCTAssertEqual(Set(try XCTUnwrap(json?.first).keys), ["id", "name", "screens", "rememberApps", "launchMissingApps", "shortcut"])
    }

    func testExplicitEmptySaveReplacesPreviousPresets() throws {
        try store.save([samplePreset()])
        try store.save([])
        XCTAssertEqual(try store.load(), [])
    }

    func testCorruptFileThrowsWithoutChangingItsBytes() throws {
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("{broken json".utf8)
        try corrupt.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt)
    }

    func testMalformedModelThrowsWithoutChangingItsBytes() throws {
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let malformed = Data("[{\"id\":\"\(UUID().uuidString)\",\"name\":\"Work\"}]".utf8)
        try malformed.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), malformed)
    }

    func testInvalidSaveLeavesPreviouslySavedFileIntact() throws {
        let original = samplePreset()
        try store.save([original])
        let originalBytes = try Data(contentsOf: store.fileURL)
        for rect in [
            PresetRect(x: -0.1, y: 0, width: 0.5, height: 0.5),
            PresetRect(x: 0.8, y: 0, width: 0.5, height: 0.5),
            PresetRect(x: 0, y: 0, width: 0, height: 0.5),
            PresetRect(x: .nan, y: 0, width: 0.5, height: 0.5),
            PresetRect(x: 0, y: 0, width: .infinity, height: 0.5),
        ] {
            var invalid = original
            invalid.screens[0].slots[0].rect = rect
            XCTAssertThrowsError(try store.save([invalid]))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), originalBytes)
        }
        XCTAssertEqual(try store.load(), [original])
    }

    func testInvalidGeometryInJSONIsRejectedOnLoad() throws {
        var preset = samplePreset()
        preset.screens[0].slots[0].rect.height = -1
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = try JSONEncoder().encode([preset])
        try invalid.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), invalid)
    }

    func testDuplicateIDsAndInvalidDisplaySizesAreRejected() throws {
        let preset = samplePreset()
        XCTAssertThrowsError(try store.save([preset, preset]))
        var duplicateScreen = preset
        duplicateScreen.screens.append(preset.screens[0])
        XCTAssertThrowsError(try store.save([duplicateScreen]))
        var duplicateSlot = preset
        duplicateSlot.screens[0].slots.append(preset.screens[0].slots[0])
        XCTAssertThrowsError(try store.save([duplicateSlot]))
        for size in [0.0, -1.0, Double.infinity] {
            var invalid = preset
            invalid.screens[0].savedWidth = size
            XCTAssertThrowsError(try store.save([invalid]))
        }
        var emptyName = preset
        emptyName.name = " \n "
        XCTAssertThrowsError(try store.save([emptyName]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testUnreadablePathThrowsInsteadOfBecomingEmptyStore() throws {
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.load())
    }

    private func samplePreset() -> LayoutPreset {
        LayoutPreset(name: "Work", screens: [
            PresetScreen(id: "display-uuid", name: "Desk", savedWidth: 1920, savedHeight: 1055, slots: [
                PresetSlot(rect: PresetRect(x: 0.1, y: 0.2, width: 0.4, height: 0.5), app: PresetApp(bundleID: "com.apple.Safari", name: "Safari"))
            ])
        ])
    }
}
