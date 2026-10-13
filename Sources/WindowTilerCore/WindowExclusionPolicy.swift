import Foundation

/// Which processes' windows Window Tiler must leave completely alone, decided
/// from facts about the process rather than the window. Coding agents open
/// and close test windows (game runs, automated browsers, GUI scripts) all
/// day, and tiling them would keep reflowing the user's real windows. Kept
/// free of system calls so every rule can be tested.
public enum WindowExclusionPolicy {
    /// What is known about one process. Anything unknown is nil or empty and
    /// never counts as a reason to exclude: a process that cannot be read is
    /// tiled as before.
    public struct ProcessFacts: Equatable {
        public var pid: pid_t
        public var parentPID: pid_t?
        /// The process macOS holds responsible for this one (the app or
        /// terminal a command was started from). Unlike the parent it
        /// survives the process being orphaned.
        public var responsiblePID: pid_t?
        public var responsibleIsAlive: Bool
        public var arguments: [String]
        public var bundleIdentifier: String?

        public init(
            pid: pid_t,
            parentPID: pid_t? = nil,
            responsiblePID: pid_t? = nil,
            responsibleIsAlive: Bool = false,
            arguments: [String] = [],
            bundleIdentifier: String? = nil
        ) {
            self.pid = pid
            self.parentPID = parentPID
            self.responsiblePID = responsiblePID
            self.responsibleIsAlive = responsibleIsAlive
            self.arguments = arguments
            self.bundleIdentifier = bundleIdentifier
        }
    }

    public struct Settings: Equatable {
        /// The automatic rules below. The Never Tile list applies either way.
        public var leaveAgentWindowsAlone: Bool
        public var neverTileBundleIdentifiers: Set<String>

        public init(leaveAgentWindowsAlone: Bool = true, neverTileBundleIdentifiers: Set<String> = []) {
            self.leaveAgentWindowsAlone = leaveAgentWindowsAlone
            self.neverTileBundleIdentifiers = neverTileBundleIdentifiers
        }
    }

    public enum Reason: Equatable {
        case neverTileApp
        case godotDebugRun
        case startedByAnotherProgram

        /// Completes "<app name> (...)" in the menu, so a wrong guess is visible.
        public var label: String {
            switch self {
            case .neverTileApp: return "on the Never Tile list"
            case .godotDebugRun: return "debug run"
            case .startedByAnotherProgram: return "started by another program"
            }
        }
    }

    private static let godotBundleIdentifier = "org.godotengine.godot"

    /// Godot's editor adds these when it runs a game for debugging. The game
    /// shares the editor's bundle identifier, so only the arguments tell them
    /// apart. Matched as a whole flag, with or without "=value", so Chromium's
    /// unrelated `--remote-debugging-port` is not mistaken for one.
    private static let godotDebugArguments = ["--remote-debug", "--editor-pid"]

    /// Godot titles the floating window that shows a game it runs inside the
    /// editor "<project> (DEBUG)".
    private static let godotDebugWindowSuffix = " (DEBUG)"

    private static func isGodotDebugArgument(_ argument: String) -> Bool {
        godotDebugArguments.contains { argument == $0 || argument.hasPrefix($0 + "=") }
    }

    /// The first matching rule, or nil when the process should be tiled.
    public static func reason(for process: ProcessFacts, settings: Settings) -> Reason? {
        if let identifier = process.bundleIdentifier, settings.neverTileBundleIdentifiers.contains(identifier) {
            return .neverTileApp
        }
        guard settings.leaveAgentWindowsAlone else { return nil }
        if process.arguments.contains(where: isGodotDebugArgument) {
            return .godotDebugRun
        }
        // Apps opened from Finder, the Dock, Spotlight, or `open` belong to
        // launchd (pid 1). Anything with another parent was started by a program.
        if let parent = process.parentPID, parent > 1 {
            return .startedByAnotherProgram
        }
        // An agent's background process is orphaned to launchd when its
        // shell exits, but macOS still names the app it came from. The
        // responsible process must still be running: an app that relaunches
        // itself through a helper that has since exited is an ordinary app.
        if let responsible = process.responsiblePID, responsible != process.pid, process.responsibleIsAlive {
            return .startedByAnotherProgram
        }
        return nil
    }

    /// Whether this app's window titles can matter, so callers read them
    /// (an Accessibility request each) only for the one app that needs it.
    public static func inspectsWindowTitles(bundleIdentifier: String?, settings: Settings) -> Bool {
        settings.leaveAgentWindowsAlone && bundleIdentifier == godotBundleIdentifier
    }

    /// The rule for one window of a process that is itself tiled. With
    /// Godot's default of running a game inside the editor, the game owns no
    /// window: the user's own editor opens a floating "(DEBUG)" one, which no
    /// process rule can see. The editor's other windows are unaffected. An
    /// unknown title never excludes.
    public static func reason(forWindowTitled title: String?, bundleIdentifier: String?, settings: Settings) -> Reason? {
        guard inspectsWindowTitles(bundleIdentifier: bundleIdentifier, settings: settings),
              title?.hasSuffix(godotDebugWindowSuffix) == true else { return nil }
        return .godotDebugRun
    }

    public struct AppChoice: Equatable {
        public let bundleIdentifier: String
        public let name: String

        public init(bundleIdentifier: String, name: String) {
            self.bundleIdentifier = bundleIdentifier
            self.name = name
        }
    }

    /// The apps the Never Tile menu offers: those showing windows now, plus
    /// saved apps that are not running, so they can still be taken off the
    /// list. One entry per bundle identifier (a Godot editor and its debug
    /// run are one app here), sorted by name.
    public static func neverTileChoices(
        running: [AppChoice],
        saved: Set<String>,
        nameForSaved: (String) -> String
    ) -> [AppChoice] {
        var byIdentifier: [String: AppChoice] = [:]
        for app in running where byIdentifier[app.bundleIdentifier] == nil {
            byIdentifier[app.bundleIdentifier] = app
        }
        for identifier in saved where byIdentifier[identifier] == nil {
            byIdentifier[identifier] = AppChoice(bundleIdentifier: identifier, name: nameForSaved(identifier))
        }
        return byIdentifier.values.sorted { first, second in
            let order = first.name.localizedCaseInsensitiveCompare(second.name)
            return order == .orderedSame ? first.bundleIdentifier < second.bundleIdentifier : order == .orderedAscending
        }
    }
}
