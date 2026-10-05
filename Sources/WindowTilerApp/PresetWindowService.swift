import AppKit
import ApplicationServices
import WindowTilerCore

@_silgen_name("_AXUIElementGetWindow")
private func presetWindowID(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

struct PresetApplyReport {
    let tiled: Int
    let failures: [String]
}

/// One-shot restoration. All app/window work runs on the main queue with
/// bounded AX timeouts and delayed polling, so cancellation and UI events can
/// run between requests. This service never monitors or enforces a saved frame.
final class PresetWindowService {
    private struct Screen {
        let id: String
        let name: String
        let frame: CGRect
    }
    private struct Window {
        let element: AXUIElement
        let app: NSRunningApplication
        let id: CGWindowID
        let frame: CGRect
    }
    private struct Work {
        var screen: Screen
        var frame: CGRect?
        let rect: PresetRect?
        let binding: PresetApp?
        let window: Window?
        let launch: Bool
        let restore: Bool
        var unlistedID: CGWindowID? = nil
        var originalFrame: CGRect? = nil
    }
    private final class Run {
        var completion: ((PresetApplyReport) -> Void)?
        var work: [Work] = []
        var index = 0
        var tiled = 0
        var failures: [String] = []
        var expectedSpaces: [String: UInt64] = [:]
        var expectedFullscreenExits = Set<String>()
        var exitingFullscreenWindows: [String: AXUIElement] = [:]
        var pulledWindowIDs = Set<CGWindowID>()
        var unvalidatedPulls: [CGWindowID: UInt64] = [:]
        var isFinishing = false
        init(_ completion: @escaping (PresetApplyReport) -> Void) { self.completion = completion }
        deinit {
            // A released service must still deliver the promised completion.
            if let completion {
                let report = PresetApplyReport(tiled: tiled, failures: failures + ["Restoration was cancelled."])
                DispatchQueue.main.async { completion(report) }
            }
        }
    }
    private enum CaptureError: LocalizedError {
        case inaccessible, unavailable, busy
        var errorDescription: String? {
            switch self {
            case .inaccessible: return "Enable Accessibility access for WindowTiler."
            case .unavailable: return "Cannot read the current windows. Try again."
            case .busy: return "An app is not answering. Try again shortly."
            }
        }
    }

    private let spaces = PresetSpaceBridge()
    private var active: Run?
    private var cleanupRun: Run?
    private let quarantine = AppQuarantine.shared
    private let enhancedUI = EnhancedUIState.shared
    private var enhancedLeases = Set<EnhancedUIState.Lease>()
    private var spaceObserver: NSObjectProtocol?
    var isApplying: Bool { active != nil || cleanupRun != nil }
    private(set) var lastOperationWasCancelled = false

    init() {
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let run = self.active else { return }
            if run.expectedSpaces.isEmpty && run.expectedFullscreenExits.isEmpty {
                self.finish(run, failure: "Restoration stopped because the active desktop changed.", cancelled: true)
            } else {
                _ = self.navigationIsUnchanged(run)
            }
        }
    }

    deinit {
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        let leases = enhancedLeases
        if Thread.isMainThread { leases.forEach(enhancedUI.end) }
        else {
            let helper = enhancedUI
            DispatchQueue.main.async { leases.forEach(helper.end) }
        }
    }

    static func currentScreenID() -> String? {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        return screen.flatMap(displayID)
    }

    func captureScreens() throws -> [PresetScreen] {
        if !Thread.isMainThread { return try DispatchQueue.main.sync { try captureScreens() } }
        guard AXIsProcessTrusted() else { throw CaptureError.inaccessible }
        let currentScreens = screens()
        let discovery = try shownWindows()
        guard !discovery.observedPIDs.contains(where: quarantine.contains) else { throw CaptureError.busy }
        let shown = discovery.windows
        return currentScreens.map { screen in
            var boundApps = Set<String>()
            let windows = readingOrder(shown.filter { screenFor($0.frame, among: currentScreens)?.id == screen.id })
            let slots = windows.compactMap { window -> PresetSlot? in
                guard let rect = PresetRect(frame: window.frame, in: screen.frame) else { return nil }
                let app = window.app.bundleIdentifier.map {
                    PresetApp(bundleID: $0, name: window.app.localizedName ?? $0)
                }
                let restore = app.map { boundApps.insert($0.bundleID).inserted } ?? false
                return PresetSlot(rect: rect, app: app, restoreApp: restore)
            }
            return PresetScreen(id: screen.id, name: screen.name,
                                savedWidth: Double(screen.frame.width), savedHeight: Double(screen.frame.height), slots: slots)
        }
    }

    func apply(_ preset: LayoutPreset, completion: @escaping (PresetApplyReport) -> Void) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                guard let self else { completion(.init(tiled: 0, failures: ["Restoration was cancelled."])); return }
                self.apply(preset, completion: completion)
            }
            return
        }
        let run = begin(completion)
        guard AXIsProcessTrusted() else { finish(run, failure: "Enable Accessibility access for WindowTiler."); return }
        let connected = screens()
        let shown: [Window]
        do { shown = preset.rememberApps ? [] : try shownWindows().windows }
        catch { finish(run, failure: error.localizedDescription); return }
        var boundApps = Set<String>()
        for saved in preset.screens where saved.isIncluded {
            guard let screen = connected.first(where: { $0.id.caseInsensitiveCompare(saved.id) == .orderedSame }) else {
                run.failures.append("\(saved.name): display is disconnected.")
                continue
            }
            let slots = saved.slots.sorted { ($0.rect.y, $0.rect.x, $0.id.uuidString) < ($1.rect.y, $1.rect.x, $1.id.uuidString) }
            let current = readingOrder(shown.filter { screenFor($0.frame, among: connected)?.id == screen.id })
            for (index, slot) in slots.enumerated() {
                guard let frame = slot.rect.frame(in: screen.frame) else {
                    run.failures.append("\(saved.name): saved position is invalid."); continue
                }
                if preset.rememberApps {
                    guard slot.restoreApp, let app = slot.app else { continue }
                    guard boundApps.insert(app.bundleID).inserted else {
                        run.failures.append("\(app.name): this app is saved in more than one slot."); continue
                    }
                    run.work.append(Work(screen: screen, frame: frame, rect: slot.rect, binding: app, window: nil,
                                         launch: preset.launchMissingApps, restore: true))
                } else if index < current.count {
                    run.work.append(Work(screen: screen, frame: frame, rect: slot.rect, binding: nil, window: current[index], launch: false, restore: false))
                }
            }
        }
        next(run)
    }

    /// Explicit manual tiling may gather normal windows from other desktops,
    /// retaining each window's physical screen. Automatic reflow never calls it.
    func gatherForTiling(completion: @escaping ([String]) -> Void) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                guard let self else { completion(["Gathering was cancelled."]); return }
                self.gatherForTiling(completion: completion)
            }
            return
        }
        let run = begin { completion($0.failures) }
        guard AXIsProcessTrusted() else { finish(run, failure: "Enable Accessibility access for WindowTiler."); return }
        let connected = screens()
        let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for app in runningApps() where !app.isHidden {
            let accessible = windows(for: app, restoring: false)
            for window in accessible {
                guard let screen = screenFor(window.frame, among: connected) else { continue }
                run.work.append(Work(screen: screen, frame: nil, rect: nil, binding: nil, window: window, launch: false, restore: false))
            }
            let known = Set(accessible.map(\.id))
            for info in all {
                guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                      (info[kCGWindowLayer as String] as? Int) == 0,
                      let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value, !known.contains(id),
                      let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                      let frame = CGRect(dictionaryRepresentation: dictionary), frame.width > 80, frame.height > 80,
                      let screen = screenFor(frame, among: connected), let destination = spaces.activeDesktop(on: screen.id),
                      let membership = spaces.spaces(of: id), membership.count == 1, let source = membership.first,
                      source != destination, spaces.isUserDesktop(source), spaces.nonMinimizedWindows(on: source)?.contains(id) == true else { continue }
                var work = Work(screen: screen, frame: nil, rect: nil, binding: PresetApp(bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? "App"), window: nil, launch: false, restore: false)
                work.unlistedID = id
                work.originalFrame = frame
                run.work.append(work)
            }
            if quarantine.contains(app.processIdentifier) {
                run.failures.append("\(app.localizedName ?? "App"): app is not answering.")
            }
        }
        next(run)
    }

    func cancel() {
        if !Thread.isMainThread { DispatchQueue.main.async { [weak self] in self?.cancel() }; return }
        if let run = active { finish(run, failure: "Restoration was cancelled.", cancelled: true) }
    }

    private func begin(_ completion: @escaping (PresetApplyReport) -> Void) -> Run {
        cancel()
        enhancedUI.restorePending()
        let run = Run(completion)
        lastOperationWasCancelled = false
        for screen in screens() {
            if let space = spaces.activeSpace(on: screen.id) { run.expectedSpaces[screen.id] = space }
        }
        active = run
        return run
    }

    private func finish(_ run: Run, failure: String? = nil, cancelled: Bool = false) {
        guard let completion = run.completion, !run.isFinishing else { return }
        run.isFinishing = true
        if active === run { active = nil }
        let leases = enhancedLeases
        enhancedLeases.removeAll()
        leases.forEach(enhancedUI.end)
        if let failure { run.failures.append(failure) }
        let deliver = { [weak self] in
            run.completion = nil
            self?.lastOperationWasCancelled = cancelled
            completion(.init(tiled: run.tiled, failures: run.failures))
        }
        guard !run.unvalidatedPulls.isEmpty else { deliver(); return }
        cleanupRun = run
        rollbackPulls(run, started: Date(), deadline: Date().addingTimeInterval(3), requested: [], stable: [:], completion: deliver)
    }

    /// Forward moves are asynchronous. Force a compensating request even if
    /// the old membership still reads "original", then keep bookkeeping until
    /// the source is verified on three later samples. New work waits for this.
    private func rollbackPulls(_ run: Run, started: Date, deadline: Date, requested: Set<CGWindowID>, stable: [CGWindowID: Int], completion: @escaping () -> Void) {
        var requested = requested
        var stable = stable
        for (id, original) in run.unvalidatedPulls {
            if !requested.contains(id), spaces.requestMove(id, to: original, evenIfAlreadyThere: true) == nil {
                requested.insert(id)
            }
            if requested.contains(id), Date().timeIntervalSince(started) >= 0.3, spaces.spaces(of: id) == [original] {
                stable[id] = (stable[id] ?? 0) + 1
                if stable[id, default: 0] >= 3 { run.unvalidatedPulls[id] = nil }
            } else { stable[id] = 0 }
        }
        if run.unvalidatedPulls.isEmpty || Date() >= deadline {
            if !run.unvalidatedPulls.isEmpty { run.failures.append("macOS did not confirm returning an unidentified window to its original desktop.") }
            run.unvalidatedPulls.removeAll()
            if cleanupRun === run { cleanupRun = nil }
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
            rollbackPulls(run, started: started, deadline: deadline, requested: requested, stable: stable, completion: completion)
        }
    }

    private func next(_ run: Run) {
        guard active === run, run.completion != nil else { return }
        if cleanupRun != nil { later(run) { $0.next(run) }; return }
        guard navigationIsUnchanged(run) else { return }
        guard run.index < run.work.count else { finish(run); return }
        let work = run.work[run.index]
        run.index += 1
        // Recheck mount/display topology before touching or launching any app.
        guard screens().contains(where: { $0.id == work.screen.id && $0.frame == work.screen.frame }) else {
            failed(run, work, "Display was disconnected or changed size."); return
        }
        if let window = work.window { restore(window, work: work, run: run); return }
        guard let binding = work.binding else { next(run); return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: binding.bundleID).first {
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  app.activationPolicy == .regular else { failed(run, work, "App has no normal desktop window."); return }
            findWindow(app, work: work, run: run, deadline: Date().addingTimeInterval(1)); return
        }
        guard work.launch else { failed(run, work, "App is not running."); return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: binding.bundleID) else {
            failed(run, work, "App is not installed."); return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
            DispatchQueue.main.async {
                guard let self, self.active === run else { return }
                guard let app, error == nil else { self.failed(run, work, "App could not launch."); return }
                self.later(run, delay: 0.4) { $0.findWindow(app, work: work, run: run, deadline: Date().addingTimeInterval(8)) }
            }
        }
    }

    private func findWindow(_ app: NSRunningApplication, work: Work, run: Run, deadline: Date) {
        guard active === run else { return }
        if work.restore, app.isHidden {
            _ = app.unhide()
            if app.isHidden, Date() < deadline {
                later(run) { $0.findWindow(app, work: work, run: run, deadline: deadline) }
                return
            }
        }
        if (!app.isFinishedLaunching || quarantine.contains(app.processIdentifier)) && !app.isTerminated && Date() < deadline {
            later(run) { $0.findWindow(app, work: work, run: run, deadline: deadline) }
            return
        }
        let candidates = windows(for: app, restoring: work.restore)
        if let window = readingOrder(candidates).first(where: { work.unlistedID == nil || $0.id == work.unlistedID }) {
            run.unvalidatedPulls[window.id] = nil
            restore(window, work: work, run: run)
            return
        }
        if pullUnlistedWindow(app, work: work, run: run) { return }
        guard !app.isTerminated, !quarantine.contains(app.processIdentifier), Date() < deadline else {
            failed(run, work, "No accessible normal window is available."); return
        }
        later(run) { $0.findWindow(app, work: work, run: run, deadline: deadline) }
    }

    /// AppKit omits off-Space windows from AXWindows. Under the saved-app
    /// one-window contract, one large normal-layer CG window can be pulled
    /// into view first, then validated with AX before any geometry changes.
    /// Ambiguous apps (multiple candidates) are left untouched.
    private func pullUnlistedWindow(_ app: NSRunningApplication, work: Work, run: Run) -> Bool {
        guard let accessible = attribute(kAXWindowsAttribute, applicationElement(app)) as? [AXUIElement], accessible.isEmpty || work.unlistedID != nil,
              let destination = spaces.activeDesktop(on: work.screen.id),
              let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let candidates = list.compactMap { info -> CGWindowID? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dictionary), frame.width > 80, frame.height > 80 else { return nil }
            return number.uint32Value
        }
        let selected: CGWindowID?
        if let targeted = work.unlistedID { selected = candidates.contains(targeted) ? targeted : nil }
        else { selected = candidates.count == 1 ? candidates.first : nil }
        guard let id = selected, !run.pulledWindowIDs.contains(id),
              let original = spaces.spaces(of: id), original.count == 1,
              let source = original.first, source != destination, spaces.isUserDesktop(source) else { return false }
        run.pulledWindowIDs.insert(id)
        run.unvalidatedPulls[id] = source
        if let failure = spaces.requestMove(id, to: destination) {
            finish(run, failure: "\(app.localizedName ?? "App"): \(failure)")
            return true
        }
        awaitPulledWindow(app, id: id, work: work, destination: destination, run: run, deadline: Date().addingTimeInterval(3))
        return true
    }

    private func awaitPulledWindow(_ app: NSRunningApplication, id: CGWindowID, work: Work, destination: UInt64, run: Run, deadline: Date) {
        guard active === run, navigationIsUnchanged(run) else { return }
        if spaces.spaces(of: id)?.contains(destination) == true,
           let window = windows(for: app, restoring: work.restore).first(where: { $0.id == id }) {
            run.unvalidatedPulls[id] = nil
            restore(window, work: work, run: run)
            return
        }
        guard Date() < deadline else {
            finish(run, failure: "\(app.localizedName ?? "App"): window could not be identified after desktop movement.")
            return
        }
        later(run) { $0.awaitPulledWindow(app, id: id, work: work, destination: destination, run: run, deadline: deadline) }
    }

    private func restore(_ window: Window, work: Work, run: Run) {
        guard active === run else { return }
        guard navigationIsUnchanged(run) else { return }
        // Freeze the destination before fullscreen exit can change Spaces.
        let destination = spaces.activeDesktop(on: work.screen.id)
        let fullscreen = bool("AXFullScreen", window.element) == true
        let initialSpace = spaces.activeSpace(on: work.screen.id)
        let exitsDestinationFullscreen = work.restore && fullscreen && destination == nil
            && initialSpace != nil && spaces.spaces(of: window.id)?.contains(initialSpace!) == true
            && screenFor(window.frame, among: screens())?.id == work.screen.id
        if destination == nil, initialSpace != nil, !exitsDestinationFullscreen,
           !isShown(window.id) || screenFor(window.frame, among: screens())?.id != work.screen.id {
            failed(run, work, "The target display is in full screen. Leave full screen and try again."); return
        }
        if work.restore {
            if fullscreen, let sourceScreen = screenFor(window.frame, among: screens()) {
                run.expectedFullscreenExits.insert(sourceScreen.id)
                run.exitingFullscreenWindows[sourceScreen.id] = window.element
            }
            // NSRunningApplication.unhide can return false even when macOS
            // shows the app. Judge the settled app state, not that return code.
            if window.app.isHidden { _ = window.app.unhide() }
            if bool(kAXMinimizedAttribute, window.element) == true,
               !set(kAXMinimizedAttribute, kCFBooleanFalse, on: window.element) {
                failed(run, work, "Window could not be restored."); return
            }
            if bool("AXFullScreen", window.element) == true,
               !set("AXFullScreen", kCFBooleanFalse, on: window.element) {
                failed(run, work, "Window could not leave full screen."); return
            }
        }
        if let destination {
            awaitNormal(window, work: work, destination: destination, run: run, deadline: Date().addingTimeInterval(5))
        } else if exitsDestinationFullscreen, let initialSpace {
            awaitDesktopAfterFullscreen(window, work: work, initialSpace: initialSpace, run: run, deadline: Date().addingTimeInterval(5))
        } else {
            // Public APIs suffice for a window confirmed shown on its target
            // screen. An unavailable private API must not break these presets.
            awaitShownFallback(window, work: work, run: run, deadline: Date().addingTimeInterval(2))
        }
    }

    private func awaitDesktopAfterFullscreen(_ window: Window, work: Work, initialSpace: UInt64, run: Run, deadline: Date) {
        guard active === run else { return }
        guard navigationIsUnchanged(run) else { return }
        let stillFullscreen = bool("AXFullScreen", window.element) == true
        if !stillFullscreen, let destination = spaces.activeDesktop(on: work.screen.id) {
            run.expectedSpaces[work.screen.id] = destination
            run.expectedFullscreenExits.remove(work.screen.id)
            let updated = refreshAfterFullscreen(work, run: run)
            awaitNormal(window, work: updated, destination: destination, run: run, deadline: deadline)
            return
        }
        if let current = spaces.activeSpace(on: work.screen.id), current != initialSpace, stillFullscreen {
            failed(run, work, "Active desktop changed during restoration."); return
        }
        guard Date() < deadline else { failed(run, work, "Window did not leave full screen."); return }
        later(run) { $0.awaitDesktopAfterFullscreen(window, work: work, initialSpace: initialSpace, run: run, deadline: deadline) }
    }

    private func awaitShownFallback(_ window: Window, work: Work, run: Run, deadline: Date) {
        guard active === run else { return }
        guard navigationIsUnchanged(run) else { return }
        if let id = number(window.element), isShown(id), !window.app.isHidden,
           bool(kAXMinimizedAttribute, window.element) != true, bool("AXFullScreen", window.element) != true,
           let actual = frame(window.element), screenFor(actual, among: screens())?.id == work.screen.id {
            let expectedExit = run.expectedFullscreenExits.contains(work.screen.id)
            if expectedExit, let current = spaces.activeSpace(on: work.screen.id) { run.expectedSpaces[work.screen.id] = current }
            run.expectedFullscreenExits.remove(work.screen.id)
            let updated = refreshAfterFullscreen(work, run: run)
            if let target = updated.frame { place(window, id: id, frame: target, work: updated, destination: nil, run: run) }
            else { run.tiled += 1; scheduleNext(run) }
            return
        }
        guard Date() < deadline else {
            failed(run, work, "Desktop movement is unavailable for this window."); return
        }
        later(run) { $0.awaitShownFallback(window, work: work, run: run, deadline: deadline) }
    }

    private func refreshAfterFullscreen(_ work: Work, run: Run) -> Work {
        guard let screen = screens().first(where: { $0.id == work.screen.id }) else { return work }
        func refresh(_ original: Work) -> Work {
            var updated = original
            updated.screen = screen
            if let rect = original.rect { updated.frame = rect.frame(in: screen.frame) }
            return updated
        }
        for index in run.index..<run.work.count where run.work[index].screen.id == screen.id {
            run.work[index] = refresh(run.work[index])
        }
        return refresh(work)
    }

    private func awaitNormal(_ window: Window, work: Work, destination: UInt64, run: Run, deadline: Date) {
        guard active === run else { return }
        guard navigationIsUnchanged(run) else { return }
        guard !quarantine.contains(window.app.processIdentifier) else { failed(run, work, "App is not answering."); return }
        if bool("AXFullScreen", window.element) != true, bool(kAXMinimizedAttribute, window.element) != true,
           let id = number(window.element), spaces.spaces(of: id) == nil {
            awaitShownFallback(window, work: work, run: run, deadline: deadline)
            return
        }
        guard !window.app.isHidden, bool("AXFullScreen", window.element) != true, bool(kAXMinimizedAttribute, window.element) != true,
              let id = number(window.element), let membership = spaces.spaces(of: id), !membership.isEmpty,
              membership.allSatisfy(spaces.isUserDesktop) else {
            guard Date() < deadline else { failed(run, work, "Window did not return to an ordinary desktop."); return }
            later(run) { $0.awaitNormal(window, work: work, destination: destination, run: run, deadline: deadline) }; return
        }
        guard spaces.activeDesktop(on: work.screen.id) == destination else {
            finish(run, failure: "Restoration stopped because the active desktop changed.", cancelled: true); return
        }
        if let failure = spaces.requestMove(id, to: destination) { failed(run, work, failure); return }
        verifySpace(window, id: id, work: work, destination: destination, run: run, deadline: Date().addingTimeInterval(2))
    }

    private func verifySpace(_ window: Window, id: CGWindowID, work: Work, destination: UInt64, run: Run, deadline: Date) {
        guard active === run else { return }
        guard navigationIsUnchanged(run) else { return }
        guard spaces.activeDesktop(on: work.screen.id) == destination else {
            finish(run, failure: "Restoration stopped because the active desktop changed.", cancelled: true); return
        }
        if spaces.spaces(of: id)?.contains(destination) == true {
            let updated = refreshAfterFullscreen(work, run: run)
            if let frame = updated.frame { place(window, id: id, frame: frame, work: updated, destination: destination, run: run) }
            else {
                // WindowServer may change displays during a Space move. A
                // gather preserves the original physical display and size.
                if let actual = frame(window.element), screenFor(actual, among: screens())?.id != work.screen.id {
                    guard setPoint((work.originalFrame ?? window.frame).origin, on: window.element) else {
                        failed(run, work, "Window could not remain on its original display."); return
                    }
                }
                later(run, delay: 0.1) { service in
                    guard let actual = service.frame(window.element),
                          service.screenFor(actual, among: service.screens())?.id == work.screen.id,
                          service.spaces.activeDesktop(on: work.screen.id) == destination,
                          service.spaces.spaces(of: id)?.contains(destination) == true else {
                        service.failed(run, work, "Window did not remain on its display's active desktop."); return
                    }
                    run.tiled += 1
                    service.scheduleNext(run)
                }
            }
            return
        }
        guard Date() < deadline else { failed(run, work, "macOS did not move the window to the active desktop."); return }
        later(run) { $0.verifySpace(window, id: id, work: work, destination: destination, run: run, deadline: deadline) }
    }

    private func place(_ window: Window, id: CGWindowID, frame: CGRect, work: Work, destination: UInt64?, run: Run) {
        let lease = enhancedUI.begin(for: [window.app.processIdentifier])
        enhancedLeases.insert(lease)
        let moved = setPoint(frame.origin, on: window.element)
        let resized = setSize(frame.size, on: window.element)
        _ = setPoint(frame.origin, on: window.element)
        later(run, delay: 0.15) { service in
            if service.enhancedLeases.remove(lease) != nil { service.enhancedUI.end(lease) }
            guard moved, let actual = service.frame(window.element) else {
                service.failed(run, work, "Window could not be positioned."); return
            }
            // Native minimum/fixed/grid sizes win. Keep the native size and
            // center in the saved slot, clamping the origin to the display.
            var origin = frame.origin
            if !resized || abs(actual.width - frame.width) > 32 || abs(actual.height - frame.height) > 32 {
                origin = CGPoint(x: frame.midX - actual.width / 2, y: frame.midY - actual.height / 2)
                run.failures.append("\(window.app.localizedName ?? "App"): restored using its minimum or fixed window size.")
            }
            origin.x = max(work.screen.frame.minX, min(origin.x, work.screen.frame.maxX - actual.width))
            origin.y = max(work.screen.frame.minY, min(origin.y, work.screen.frame.maxY - actual.height))
            guard service.setPoint(origin, on: window.element) else {
                service.failed(run, work, "Window could not be positioned."); return
            }
            service.later(run, delay: 0.1) { service in
                guard service.active === run else { return }
                guard let verified = service.frame(window.element),
                      abs(verified.minX - origin.x) <= 3, abs(verified.minY - origin.y) <= 3,
                      service.screenFor(verified, among: service.screens())?.id == work.screen.id,
                      service.isOnDestination(id, screenID: work.screen.id, desktop: destination) else {
                    service.failed(run, work, "Window did not keep the requested position."); return
                }
                run.tiled += 1
                service.scheduleNext(run)
            }
        }
    }

    private func isOnDestination(_ id: CGWindowID, screenID: String, desktop: UInt64?) -> Bool {
        guard let desktop else { return isShown(id) }
        return spaces.activeDesktop(on: screenID) == desktop && spaces.spaces(of: id)?.contains(desktop) == true
    }

    private func isShown(_ id: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id
            && ($0[kCGWindowLayer as String] as? Int) == 0 }
    }

    private func failed(_ run: Run, _ work: Work, _ message: String) {
        // No expected transition may outlive its one window operation.
        run.expectedFullscreenExits.removeAll()
        run.exitingFullscreenWindows.removeAll()
        run.failures.append("\(work.binding?.name ?? work.window?.app.localizedName ?? work.screen.name): \(message)")
        scheduleNext(run)
    }
    private func scheduleNext(_ run: Run) { later(run, delay: 0) { $0.next(run) } }
    private func later(_ run: Run, delay: Double = 0.2, _ body: @escaping (PresetWindowService) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.active === run, self.navigationIsUnchanged(run) else { return }
            body(self)
        }
    }

    @discardableResult private func navigationIsUnchanged(_ run: Run) -> Bool {
        guard active === run else { return false }
        for screenID in Array(run.expectedFullscreenExits) {
            guard let window = run.exitingFullscreenWindows[screenID], bool("AXFullScreen", window) != true,
                  let desktop = spaces.activeDesktop(on: screenID) else { continue }
            run.expectedSpaces[screenID] = desktop
            run.expectedFullscreenExits.remove(screenID)
            run.exitingFullscreenWindows[screenID] = nil
            if let screen = screens().first(where: { $0.id == screenID }) {
                for index in run.index..<run.work.count where run.work[index].screen.id == screenID {
                    run.work[index].screen = screen
                    if let rect = run.work[index].rect { run.work[index].frame = rect.frame(in: screen.frame) }
                }
            }
        }
        for (screen, expected) in run.expectedSpaces where !run.expectedFullscreenExits.contains(screen) {
            guard spaces.activeSpace(on: screen) == expected else {
                finish(run, failure: "Restoration stopped because the active desktop changed.", cancelled: true)
                return false
            }
        }
        return true
    }

    // MARK: Discovery and bounded Accessibility requests

    private static func displayID(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
    private func screens() -> [Screen] {
        let connected = NSScreen.screens
        guard let primary = connected.first else { return [] }
        let frames = ScreenGeometryEngine.accessibilityFrames(visibleFrames: connected.map(\.visibleFrame), primaryFrame: primary.frame)
        return zip(connected, frames).compactMap { screen, frame in
            Self.displayID(screen).map { Screen(id: $0, name: screen.localizedName, frame: frame) }
        }
    }
    private func screenFor(_ frame: CGRect, among screens: [Screen]) -> Screen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let index = ScreenGeometryEngine.screenIndex(for: center, screens: screens.map(\.frame)) { return screens[index] }
        return nil
    }
    private func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }.sorted { $0.processIdentifier < $1.processIdentifier }
    }
    /// Both lists come from the same snapshot, before any Accessibility calls.
    /// A background app with no shown normal-layer window must not delay Save.
    static func shownWindowSnapshot(from list: [[String: Any]], eligiblePIDs: Set<pid_t>) -> (ids: Set<CGWindowID>, pids: Set<pid_t>) {
        var ids = Set<CGWindowID>()
        var pids = Set<pid_t>()
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let owner = info[kCGWindowOwnerPID as String] as? NSNumber,
                  eligiblePIDs.contains(owner.int32Value) else { continue }
            ids.insert(number.uint32Value)
            pids.insert(owner.int32Value)
        }
        return (ids, pids)
    }

    private func shownWindows() throws -> (windows: [Window], observedPIDs: Set<pid_t>) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw CaptureError.unavailable
        }
        let eligible = runningApps().filter { !$0.isHidden }
        let snapshot = Self.shownWindowSnapshot(from: list, eligiblePIDs: Set(eligible.map(\.processIdentifier)))
        let apps = eligible.filter { snapshot.pids.contains($0.processIdentifier) }
        let windows = apps.flatMap { self.windows(for: $0, restoring: false).filter { snapshot.ids.contains($0.id) } }
        return (windows, snapshot.pids)
    }
    private func readingOrder(_ windows: [Window]) -> [Window] {
        windows.sorted { (round($0.frame.minY / 16), round($0.frame.minX / 16), $0.id)
            < (round($1.frame.minY / 16), round($1.frame.minX / 16), $1.id) }
    }
    private func applicationElement(_ app: NSRunningApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }
    private func windows(for app: NSRunningApplication, restoring: Bool) -> [Window] {
        guard !quarantine.contains(app.processIdentifier),
              let elements = attribute(kAXWindowsAttribute, applicationElement(app)) as? [AXUIElement] else { return [] }
        return elements.compactMap { element in
            let subrole = attribute(kAXSubroleAttribute, element) as? String
            // AppKit can expose ordinary hidden/minimized windows as AXDialog.
            // Only a miniaturizable remembered window gets this exception;
            // capture/gather still exclude all dialogs and modal guards apply.
            let restorableNormal = restoring && subrole == kAXDialogSubrole
                && attribute(kAXMinimizeButtonAttribute, element) != nil
            guard attribute(kAXRoleAttribute, element) as? String == kAXWindowRole,
                  subrole == kAXStandardWindowSubrole || restorableNormal,
                  bool(kAXModalAttribute, element) != true else { return nil }
            let identifier = attribute(kAXIdentifierAttribute, element) as? String
            guard identifier != "open-panel", identifier != "save-panel" else { return nil }
            if app.bundleIdentifier == "com.electron.wispr-flow",
               attribute(kAXTitleAttribute, element) as? String == "Status" { return nil }
            guard restoring || (bool(kAXMinimizedAttribute, element) != true && bool("AXFullScreen", element) != true),
                  let frame = frame(element), frame.width > 80, frame.height > 80,
                  let id = number(element) else { return nil }
            return Window(element: element, app: app, id: id, frame: frame)
        }
    }
    private func isQuarantined(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && quarantine.contains(pid)
    }
    private func checked(_ status: AXError, _ element: AXUIElement) -> Bool {
        if status == .cannotComplete {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success { quarantine.add(pid) }
        }
        return status == .success
    }
    private func attribute(_ name: String, _ element: AXUIElement) -> CFTypeRef? {
        guard !isQuarantined(element) else { return nil }
        var result: CFTypeRef?
        return checked(AXUIElementCopyAttributeValue(element, name as CFString, &result), element) ? result : nil
    }
    private func bool(_ name: String, _ element: AXUIElement) -> Bool? { attribute(name, element) as? Bool }
    private func number(_ element: AXUIElement) -> CGWindowID? {
        guard !isQuarantined(element) else { return nil }
        var id: CGWindowID = 0
        return checked(presetWindowID(element, &id), element) && id != 0 ? id : nil
    }
    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(kAXPositionAttribute, element), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(kAXSizeAttribute, element), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    @discardableResult private func set(_ name: String, _ value: CFTypeRef, on element: AXUIElement) -> Bool {
        guard !isQuarantined(element) else { return false }
        return checked(AXUIElementSetAttributeValue(element, name as CFString, value), element)
    }
    private func setPoint(_ point: CGPoint, on element: AXUIElement) -> Bool {
        var value = point
        guard let ax = AXValueCreate(.cgPoint, &value) else { return false }
        return set(kAXPositionAttribute, ax, on: element)
    }
    private func setSize(_ size: CGSize, on element: AXUIElement) -> Bool {
        var value = size
        guard let ax = AXValueCreate(.cgSize, &value) else { return false }
        return set(kAXSizeAttribute, ax, on: element)
    }
}
