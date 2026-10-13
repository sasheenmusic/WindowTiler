import AppKit
import ApplicationServices
import WindowTilerCore

/// The one filter every window-discovery path asks, so a process Window Tiler
/// leaves alone is never moved, resized, counted, swapped, gathered,
/// captured, or used to fill a preset slot. Nothing is decided once and
/// remembered: parents, responsible processes, and settings all change, so
/// each pass asks again (the few system calls involved are cheap).
final class WindowExclusions {
    static let shared = WindowExclusions()

    /// What the Never Tile menu shows when it opens.
    struct Overview {
        let choices: [WindowExclusionPolicy.AppChoice]
        /// "Godot (debug run)", for what the automatic rules are leaving alone now.
        let leftAlone: [String]
    }

    private struct RunningApp {
        let pid: pid_t
        let name: String
        let bundleIdentifier: String?
    }

    /// Loaded from the saved choices at launch and replaced when the menu changes them.
    var settings = WindowExclusionPolicy.Settings()
    private let reader: ProcessFactsReader

    init(reader: ProcessFactsReader = ProcessFactsReader()) {
        self.reader = reader
    }

    func reason(forPID pid: pid_t, bundleIdentifier: String?) -> WindowExclusionPolicy.Reason? {
        // With agent rules off only the bundle identifier can matter, so skip the process lookup.
        guard settings.leaveAgentWindowsAlone else {
            return WindowExclusionPolicy.reason(
                for: .init(pid: pid, bundleIdentifier: bundleIdentifier), settings: settings)
        }
        let facts = reader.facts(for: pid)
        return WindowExclusionPolicy.reason(
            for: .init(
                pid: pid,
                parentPID: facts?.parentPID,
                responsiblePID: facts?.responsiblePID,
                responsibleIsAlive: facts?.responsibleIsAlive ?? false,
                arguments: facts?.arguments ?? [],
                bundleIdentifier: bundleIdentifier
            ),
            settings: settings
        )
    }

    /// Takes plain values rather than an `NSRunningApplication` so the
    /// discovery checks can drive it with fake apps.
    func isExcluded(pid: pid_t, bundleIdentifier: String?) -> Bool {
        reason(forPID: pid, bundleIdentifier: bundleIdentifier) != nil
    }

    /// Whether this app's windows need their titles checked, so every other
    /// app is spared the Accessibility request.
    func readsWindowTitles(of bundleIdentifier: String?) -> Bool {
        WindowExclusionPolicy.inspectsWindowTitles(bundleIdentifier: bundleIdentifier, settings: settings)
    }

    /// One window of an app that is otherwise tiled.
    func isExcludedWindow(titled title: String?, bundleIdentifier: String?) -> Bool {
        WindowExclusionPolicy.reason(forWindowTitled: title, bundleIdentifier: bundleIdentifier, settings: settings) != nil
    }

    func forget(except live: Set<pid_t>) {
        reader.forget(except: live)
    }

    // MARK: - Menu

    /// Reads the apps showing windows right now. Runs when the menu opens, so
    /// it may afford what a discovery pass cannot: a title read for the apps
    /// whose windows are judged by title.
    func overview() -> Overview {
        let apps = appsWithWindowsOnScreen()
        let running = apps.compactMap { app in
            app.bundleIdentifier.map { WindowExclusionPolicy.AppChoice(bundleIdentifier: $0, name: app.name) }
        }
        var leftAlone = Set<String>()
        for app in apps {
            // The Never Tile list is shown by its own checkmarks.
            if let reason = reason(forPID: app.pid, bundleIdentifier: app.bundleIdentifier), reason != .neverTileApp {
                leftAlone.insert("\(app.name) (\(reason.label))")
            } else if hasDebugWindow(pid: app.pid, bundleIdentifier: app.bundleIdentifier) {
                leftAlone.insert("\(app.name) (\(WindowExclusionPolicy.Reason.godotDebugRun.label))")
            }
        }
        let choices = WindowExclusionPolicy.neverTileChoices(
            running: running, saved: settings.neverTileBundleIdentifiers, nameForSaved: displayName
        )
        return Overview(choices: choices, leftAlone: leftAlone.sorted())
    }

    private func appsWithWindowsOnScreen() -> [RunningApp] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let shown = Set(list.compactMap { info -> pid_t? in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width > 80, bounds.height > 80 else { return nil }
            return pid
        })
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { shown.contains($0.processIdentifier) && $0.processIdentifier != ownPID
                && $0.activationPolicy == .regular && !$0.isTerminated }
            .map { RunningApp(pid: $0.processIdentifier, name: $0.localizedName ?? $0.bundleIdentifier ?? "App", bundleIdentifier: $0.bundleIdentifier) }
    }

    private func hasDebugWindow(pid: pid_t, bundleIdentifier: String?) -> Bool {
        let quarantine = AppQuarantine.shared
        guard readsWindowTitles(of: bundleIdentifier), !quarantine.contains(pid) else { return false }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        var windows: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows)
        if status == .cannotComplete { quarantine.add(pid) }
        guard status == .success, let elements = windows as? [AXUIElement] else { return false }
        return elements.contains { element in
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success else { return false }
            return isExcludedWindow(titled: title as? String, bundleIdentifier: bundleIdentifier)
        }
    }

    private func displayName(forBundleIdentifier identifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return identifier }
        return url.deletingPathExtension().lastPathComponent
    }
}
