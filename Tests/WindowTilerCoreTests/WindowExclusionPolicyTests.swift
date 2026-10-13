import XCTest
@testable import WindowTilerCore

final class WindowExclusionPolicyTests: XCTestCase {
    private typealias Facts = WindowExclusionPolicy.ProcessFacts
    private typealias Settings = WindowExclusionPolicy.Settings

    private let godot = "org.godotengine.godot"

    /// An app opened from Finder or the Dock: its parent is launchd and it
    /// answers for itself.
    private func ordinaryApp(pid: pid_t = 500, bundle: String? = "com.example.editor") -> Facts {
        Facts(pid: pid, parentPID: 1, responsiblePID: pid, responsibleIsAlive: true, bundleIdentifier: bundle)
    }

    private func reason(_ facts: Facts, _ settings: Settings = Settings()) -> WindowExclusionPolicy.Reason? {
        WindowExclusionPolicy.reason(for: facts, settings: settings)
    }

    func testAppOpenedFromFinderIsTiled() {
        XCTAssertNil(reason(ordinaryApp()))
    }

    func testNeverTileListExcludesBySavedBundleIdentifier() {
        let settings = Settings(neverTileBundleIdentifiers: ["com.example.editor"])
        XCTAssertEqual(reason(ordinaryApp(), settings), .neverTileApp)
        XCTAssertNil(reason(ordinaryApp(bundle: "com.example.other"), settings))
    }

    func testNeverTileListStillAppliesWhenAutomaticRulesAreOff() {
        let settings = Settings(leaveAgentWindowsAlone: false, neverTileBundleIdentifiers: ["com.example.editor"])
        XCTAssertEqual(reason(ordinaryApp(), settings), .neverTileApp)
    }

    func testGodotDebugRunIsRecognizedByEitherArgument() {
        for flag in ["--remote-debug", "--editor-pid"] {
            let game = Facts(pid: 600, parentPID: 1, responsiblePID: 600, responsibleIsAlive: true,
                             arguments: ["/Applications/Godot.app/Contents/MacOS/Godot", "--path", "/tmp/game", flag, "tcp://127.0.0.1:6007"],
                             bundleIdentifier: godot)
            XCTAssertEqual(reason(game), .godotDebugRun, flag)
        }
    }

    func testGodotEditorSharingTheBundleIdentifierIsTiled() {
        let editor = Facts(pid: 601, parentPID: 1, responsiblePID: 601, responsibleIsAlive: true,
                           arguments: ["/Applications/Godot.app/Contents/MacOS/Godot", "--editor", "--path", "/tmp/game"],
                           bundleIdentifier: godot)
        XCTAssertNil(reason(editor))
    }

    func testGodotFlagsAlsoCountWithAnEqualsValue() {
        XCTAssertEqual(reason(Facts(pid: 602, parentPID: 1, arguments: ["Godot", "--remote-debug=tcp://127.0.0.1:6007"])), .godotDebugRun)
        XCTAssertEqual(reason(Facts(pid: 603, parentPID: 1, arguments: ["Godot", "--editor-pid=4321"])), .godotDebugRun)
    }

    func testSimilarFlagsAreNotGodotDebugRuns() {
        let facts = Facts(pid: 604, parentPID: 1, arguments: ["Chromium", "--remote-debugging-port=9222", "--editor-pid-file"])
        XCTAssertNil(reason(facts))
    }

    func testAppStartedByAnotherProgramHasAParentOtherThanLaunchd() {
        let facts = Facts(pid: 700, parentPID: 4321, responsiblePID: 700, responsibleIsAlive: true)
        XCTAssertEqual(reason(facts), .startedByAnotherProgram)
    }

    func testLaunchdAndKernelParentsDoNotCount() {
        XCTAssertNil(reason(Facts(pid: 700, parentPID: 1)))
        XCTAssertNil(reason(Facts(pid: 700, parentPID: 0)))
    }

    func testOrphanedProcessIsStillExcludedThroughItsLiveResponsibleApp() {
        // An agent's background run, re-parented to launchd when its shell exited.
        let orphan = Facts(pid: 800, parentPID: 1, responsiblePID: 90, responsibleIsAlive: true)
        XCTAssertEqual(reason(orphan), .startedByAnotherProgram)
    }

    func testResponsibleProcessThatHasExitedDoesNotExclude() {
        // An app that relaunched itself through a helper that is gone.
        let relaunched = Facts(pid: 801, parentPID: 1, responsiblePID: 91, responsibleIsAlive: false)
        XCTAssertNil(reason(relaunched))
    }

    func testProcessResponsibleForItselfIsNotExcluded() {
        XCTAssertNil(reason(Facts(pid: 802, parentPID: 1, responsiblePID: 802, responsibleIsAlive: true)))
    }

    func testUnknownFactsNeverExclude() {
        XCTAssertNil(reason(Facts(pid: 900)))
        XCTAssertNil(reason(Facts(pid: 900, responsibleIsAlive: true)))
        XCTAssertNil(reason(Facts(pid: 900, bundleIdentifier: nil)))
    }

    func testTurningTheToggleOffTilesEveryAutomaticCase() {
        let off = Settings(leaveAgentWindowsAlone: false)
        XCTAssertNil(reason(Facts(pid: 1000, parentPID: 4321), off))
        XCTAssertNil(reason(Facts(pid: 1001, parentPID: 1, responsiblePID: 90, responsibleIsAlive: true), off))
        XCTAssertNil(reason(Facts(pid: 1002, parentPID: 1, arguments: ["--remote-debug"]), off))
    }

    func testRulesApplyInOrder() {
        // A Godot debug run started by a program: the more specific reason wins.
        let game = Facts(pid: 1100, parentPID: 4321, responsiblePID: 90, responsibleIsAlive: true,
                         arguments: ["Godot", "--remote-debug", "tcp://127.0.0.1:6007"], bundleIdentifier: godot)
        XCTAssertEqual(reason(game), .godotDebugRun)
        // The Never Tile list outranks both automatic rules.
        XCTAssertEqual(reason(game, Settings(neverTileBundleIdentifiers: [godot])), .neverTileApp)
        // A parent outranks the responsible process.
        let child = Facts(pid: 1101, parentPID: 4321, responsiblePID: 90, responsibleIsAlive: true)
        XCTAssertEqual(reason(child), .startedByAnotherProgram)
    }

    func testReasonLabelsCompleteTheMenuLine() {
        XCTAssertEqual("Godot (\(WindowExclusionPolicy.Reason.godotDebugRun.label))", "Godot (debug run)")
        XCTAssertEqual(WindowExclusionPolicy.Reason.startedByAnotherProgram.label, "started by another program")
    }

    // MARK: - Windows of a tiled process

    private func windowReason(_ title: String?, _ bundle: String? = "org.godotengine.godot",
                              _ settings: Settings = Settings()) -> WindowExclusionPolicy.Reason? {
        WindowExclusionPolicy.reason(forWindowTitled: title, bundleIdentifier: bundle, settings: settings)
    }

    func testGodotEditorGameWindowIsLeftAlone() {
        // Godot's default "embed game / make floating" run opens this in the editor itself.
        XCTAssertEqual(windowReason("Platformer (DEBUG)"), .godotDebugRun)
    }

    func testGodotEditorMainWindowIsStillTiled() {
        XCTAssertNil(windowReason("Platformer - Godot Engine"))
        XCTAssertNil(windowReason("(DEBUG) notes"))
        XCTAssertNil(windowReason("Platformer (DEBUG)x"))
    }

    func testOnlyGodotWindowsAreJudgedByTitle() {
        XCTAssertNil(windowReason("Notes (DEBUG)", "com.example.editor"))
        XCTAssertNil(windowReason("Notes (DEBUG)", nil))
        XCTAssertFalse(WindowExclusionPolicy.inspectsWindowTitles(bundleIdentifier: "com.example.editor", settings: Settings()))
        XCTAssertTrue(WindowExclusionPolicy.inspectsWindowTitles(bundleIdentifier: "org.godotengine.godot", settings: Settings()))
    }

    func testUnknownWindowTitleNeverExcludes() {
        XCTAssertNil(windowReason(nil))
        XCTAssertNil(windowReason(""))
    }

    func testWindowRuleFollowsTheToggle() {
        let off = Settings(leaveAgentWindowsAlone: false)
        XCTAssertNil(windowReason("Platformer (DEBUG)", "org.godotengine.godot", off))
        XCTAssertFalse(WindowExclusionPolicy.inspectsWindowTitles(bundleIdentifier: "org.godotengine.godot", settings: off))
    }

    // MARK: - Never Tile choices

    private func choice(_ identifier: String, _ name: String) -> WindowExclusionPolicy.AppChoice {
        .init(bundleIdentifier: identifier, name: name)
    }

    func testChoicesAreSortedByNameIgnoringCase() {
        let choices = WindowExclusionPolicy.neverTileChoices(
            running: [choice("c", "Safari"), choice("a", "arc"), choice("b", "Terminal")],
            saved: [], nameForSaved: { $0 }
        )
        XCTAssertEqual(choices.map(\.name), ["arc", "Safari", "Terminal"])
    }

    func testSavedAppsThatAreNotRunningStayListed() {
        let choices = WindowExclusionPolicy.neverTileChoices(
            running: [choice("com.apple.Safari", "Safari")],
            saved: ["com.example.gone", "com.apple.Safari"],
            nameForSaved: { $0 == "com.example.gone" ? "Gone App" : "wrong" }
        )
        XCTAssertEqual(choices.map(\.bundleIdentifier), ["com.example.gone", "com.apple.Safari"])
        XCTAssertEqual(choices.map(\.name), ["Gone App", "Safari"])
    }

    func testSeveralProcessesOfOneAppAreOneChoice() {
        let choices = WindowExclusionPolicy.neverTileChoices(
            running: [choice(godot, "Godot"), choice(godot, "Godot"), choice("b", "Blender")],
            saved: [godot], nameForSaved: { _ in "unused" }
        )
        XCTAssertEqual(choices.map(\.bundleIdentifier), ["b", godot])
    }

    func testEqualNamesKeepAStableOrder() {
        let choices = WindowExclusionPolicy.neverTileChoices(
            running: [choice("z.app", "Same"), choice("a.app", "Same")],
            saved: [], nameForSaved: { $0 }
        )
        XCTAssertEqual(choices.map(\.bundleIdentifier), ["a.app", "z.app"])
    }
}
