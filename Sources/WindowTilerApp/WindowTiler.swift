import AppKit
import ApplicationServices
import WindowTilerCore

/// Returns the window server's id for an Accessibility window. Not in the
/// public headers, but it has been stable for many macOS releases and every
/// tiling manager (Amethyst, yabai, Rectangle) relies on it.
@_silgen_name("_AXUIElementGetWindow")
private func windowServerID(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

struct TilingResult {
    let tiled: Int
    let constrained: Int
    let failed: Int

    static let empty = TilingResult(tiled: 0, constrained: 0, failed: 0)
}

final class WindowTiler {
    private struct SizeLimits {
        var minimum: CGSize
        var maximum: CGSize
    }

    private enum ApplyResult {
        case tiled
        case constrained
        case failed
    }

    private struct Window {
        let element: AXUIElement
        let pid: pid_t
        let name: String
        let center: CGPoint
        let identity: String
        let currentPosition: CGPoint
        let currentSize: CGSize
        let sizeIsSettable: Bool
    }

    private struct OnScreenWindow {
        let number: Int
        let bounds: CGRect
    }

    /// Size limits observed while tiling, keyed by window identity. They are
    /// learned from what each window actually does when asked to fill a tile
    /// (no separate shrink/grow probe), dropped when the window closes, and
    /// cleared on every manual tile so a changed layout is re-measured.
    /// Only what was actually observed. An axis never seen to be limited
    /// stays at its sentinel (0 for a minimum, infinity for a maximum) so a
    /// default copied from one screen never becomes a "limit" on another.
    private struct LearnedLimits {
        var minimum = CGSize.zero
        var maximum = CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
        var learnedAt = Date()

        var isEmpty: Bool { minimum == .zero && maximum.width == .infinity && maximum.height == .infinity }
    }

    private var learnedLimits: [String: LearnedLimits] = [:]
    /// A window's real limits can change (a toggled sidebar, a different
    /// System Settings pane). Learned limits older than this are measured
    /// again on the next tile, so stale values cannot stick around.
    private let learnedLimitsLifetime: TimeInterval = 10 * 60
    /// How far short of a requested size a window lands because it snaps to
    /// a grid (Terminal resizes in whole character cells, 8x16 points with a
    /// typical font). Learned per window; a shortfall inside this allowance
    /// is treated as a tiled window with a little wiggle room, not as a
    /// bounded one.
    private var snapAllowances: [String: CGSize] = [:]
    private var applicationElements: [pid_t: AXUIElement] = [:]
    private let quarantine = AppQuarantine.shared
    /// Apps whose AXEnhancedUserInterface flag we switched off and could not
    /// switch back yet (they were quarantined mid-tile). Retried each tile.
    private var pendingEnhancedUIRestore = Set<pid_t>()
    /// Unchanged sizes seen once after a request during the current tile,
    /// by window identity. A clamp is only believed once a second, separate
    /// attempt in the same tile shows the same unchanged size; the record
    /// is consumed by that confirmation and never outlives the tile.
    private var pendingClamps: [String: CGSize] = [:]
    private let systemWideElement = AXUIElementCreateSystemWide()
    private let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"

    /// Seconds to wait for another app before giving up on an Accessibility
    /// request. The default is six seconds per request, which lets one hung
    /// app freeze the tiler.
    private let messagingTimeout: Float = 1.0
    private let maximumPasses = 4
    private let sizeTolerance: CGFloat = 2
    /// Largest grid step treated as snapping rather than a real size limit.
    /// One character cell of a very large terminal font is about 16x32
    /// points; anything beyond this is a genuinely bounded window and sends
    /// the layout into the bounded-window mosaic.
    private let boundedTolerance: CGFloat = 32

    init() {
        AXUIElementSetMessagingTimeout(systemWideElement, messagingTimeout)
    }

    func isAccessibilityEnabled(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// - Parameter relearn: forget every learned size limit first. Manual
    ///   tiles use this so a window whose limits changed (a toggled sidebar,
    ///   a new font size) is measured again.
    func tileAllWindows(relearn: Bool) -> TilingResult {
        guard isAccessibilityEnabled(prompt: false) else { return .empty }
        if relearn {
            learnedLimits.removeAll()
            snapAllowances.removeAll()
        }
        pendingClamps.removeAll()

        let screens = screenBoundsInAccessibilityCoordinates()
        guard !screens.isEmpty else { return .empty }

        guard let windows = eligibleWindows() else {
            Log.tiling.error("The window server's on-screen list is unavailable; not tiling")
            return .empty
        }
        pruneLearnedLimits(keeping: windows.map(\.identity))

        var grouped = Array(repeating: [Window](), count: screens.count)
        for window in windows {
            guard let screenIndex = ScreenGeometryEngine.screenIndex(
                for: window.center,
                screens: screens
            ) else { continue }
            grouped[screenIndex].append(window)
        }

        restoreEnhancedUserInterface()
        pendingEnhancedUIRestore.formUnion(disableEnhancedUserInterface(for: Set(windows.map(\.pid))))
        defer { restoreEnhancedUserInterface() }

        var tiled = 0
        var constrained = 0
        var failed = 0
        var summaries: [String] = []
        for index in screens.indices {
            let result = tile(windows: grouped[index], in: screens[index], summaries: &summaries)
            tiled += result.tiled
            constrained += result.constrained
            failed += result.failed
        }
        Log.tiling.debug("Layout: \(summaries.joined(separator: " | "), privacy: .public)")
        return .init(tiled: tiled, constrained: constrained, failed: failed)
    }

    /// With this flag set (assistive apps turn it on), Chromium and Electron
    /// apps animate or refuse moves and resizes. Switch it off for the apps
    /// being tiled and put it back afterwards; returns the apps that had it.
    private func disableEnhancedUserInterface(for pids: Set<pid_t>) -> [pid_t] {
        pids.filter { pid in
            let app = applicationElement(for: pid)
            guard (attribute(enhancedUserInterfaceAttribute, from: app) as? Bool) == true else { return false }
            return setAttribute(enhancedUserInterfaceAttribute, to: kCFBooleanFalse, on: app)
        }
    }

    /// An app quarantined while tiling keeps its pending restoration and is
    /// retried at the start and end of every later tile.
    private func restoreEnhancedUserInterface() {
        for pid in pendingEnhancedUIRestore where !isQuarantined(pid) {
            if setAttribute(enhancedUserInterfaceAttribute, to: kCFBooleanTrue, on: applicationElement(for: pid)) {
                pendingEnhancedUIRestore.remove(pid)
            }
        }
    }

    // MARK: - Tiling one screen

    private func tile(windows: [Window], in screen: CGRect, summaries: inout [String]) -> TilingResult {
        guard !windows.isEmpty else { return .empty }

        var limits = windows.map { window -> SizeLimits in
            guard window.sizeIsSettable else {
                return SizeLimits(minimum: window.currentSize, maximum: window.currentSize)
            }
            return effectiveLimits(learnedLimits[window.identity] ?? LearnedLimits(), on: screen)
        }
        var bounded = Set(windows.indices.filter { !windows[$0].sizeIsSettable })
        var boundedIndices: [Int] = []
        var flexibleIndices: [Int] = []
        var layout = MosaicLayout(constrainedFrames: [], flexibleFrames: [])
        // Where each window was last seen. A window already sitting in its
        // tile is left alone: no request, no self-triggered move event.
        var observed = windows.map { CGRect(origin: $0.currentPosition, size: $0.currentSize) }

        // Each pass asks every window for its tile, then reads back what the
        // window really did. Windows that refuse to shrink teach us a minimum,
        // windows that refuse to grow teach us a maximum, and the layout is
        // recomputed with that knowledge until nothing new is learned.
        var learnedOnLastPass = false
        for _ in 0..<maximumPasses {
            (layout, bounded, boundedIndices, flexibleIndices) = partition(
                windows: windows, limits: limits, bounded: bounded, in: screen
            )
            let confirmed = requestUnsettled(
                windows: windows, layout: layout, boundedIndices: boundedIndices,
                flexibleIndices: flexibleIndices, observed: observed
            )
            learnedOnLastPass = false
            var needsAnotherPass = false
            guard !confirmed.isEmpty else { break }
            let before = observed
            settle()

            for (position, index) in flexibleIndices.enumerated()
            where position < layout.flexibleFrames.count && !isQuarantined(windows[index].pid) {
                guard let actual = sizeAttribute(kAXSizeAttribute, from: windows[index].element) else { continue }
                let requested = layout.flexibleFrames[position].size
                if let origin = pointAttribute(kAXPositionAttribute, from: windows[index].element) {
                    observed[index] = CGRect(origin: origin, size: actual)
                }
                // Learn only from a resize the app accepted. A refused or
                // timed-out request leaves the old size in place, and reading
                // that back as a limit is exactly the cache poisoning the
                // audit found.
                guard confirmed.contains(index) else { continue }
                // An accepted request only means the app took it. A size that
                // did not change at all is believed as a clamp only when a
                // second, separate attempt shows the same unchanged size; a
                // busy or still-opening window never teaches a limit.
                let identity = windows[index].identity
                if actual == before[index].size, actual != requested {
                    if pendingClamps[identity] != actual {
                        pendingClamps[identity] = actual
                        needsAnotherPass = true
                        continue
                    }
                    pendingClamps[identity] = nil
                } else {
                    pendingClamps[identity] = nil
                }
                // A deviation within one grid cell is snapping and must not
                // be recorded as a limit: a 12-point shortfall in a short
                // tile would otherwise become a hard maximum that later
                // turns the window into a fixed-size block.
                learnSnap(identity: windows[index].identity, requested: requested, actual: actual)
                let previous = learnedLimits[windows[index].identity] ?? LearnedLimits()
                var learned = previous
                if actual.width > requested.width + boundedTolerance { learned.minimum.width = max(learned.minimum.width, actual.width) }
                if actual.height > requested.height + boundedTolerance { learned.minimum.height = max(learned.minimum.height, actual.height) }
                if actual.width < requested.width - boundedTolerance { learned.maximum.width = min(learned.maximum.width, actual.width) }
                if actual.height < requested.height - boundedTolerance { learned.maximum.height = min(learned.maximum.height, actual.height) }
                if learned.minimum != previous.minimum || learned.maximum != previous.maximum {
                    learned.learnedAt = Date()
                    learnedLimits[windows[index].identity] = learned
                    limits[index] = effectiveLimits(learned, on: screen)
                    learnedOnLastPass = true
                }
            }
            if !learnedOnLastPass && !needsAnotherPass { break }
        }
        if learnedOnLastPass {
            // The last pass taught us something; lay out once more so the
            // final frames honor it.
            (layout, bounded, boundedIndices, flexibleIndices) = partition(
                windows: windows, limits: limits, bounded: bounded, in: screen
            )
            _ = requestUnsettled(
                windows: windows, layout: layout, boundedIndices: boundedIndices,
                flexibleIndices: flexibleIndices, observed: observed
            )
            settle()
        }

        summaries.append(contentsOf: windows.indices.map { index in
            var state = bounded.contains(index) ? "bounded" : "flexible"
            if let snap = snapAllowances[windows[index].identity] {
                state += " snap \(Int(snap.width))x\(Int(snap.height))"
            }
            return "\(windows[index].name): min \(Int(limits[index].minimum.width))x\(Int(limits[index].minimum.height)), max \(Int(limits[index].maximum.width))x\(Int(limits[index].maximum.height)), \(state)"
        })

        var tiled = 0
        var constrainedCount = 0
        var failed = 0
        for (position, index) in boundedIndices.enumerated() {
            if isQuarantined(windows[index].pid) {
                failed += 1
            } else if isSettled(observed[index], in: layout.constrainedFrames[position], allowance: nil)
                || applyBounded(frame: layout.constrainedFrames[position], to: windows[index].element) {
                constrainedCount += 1
            } else {
                failed += 1
            }
        }
        for (position, index) in flexibleIndices.enumerated() {
            guard position < layout.flexibleFrames.count,
                  layout.flexibleFrames[position].width > 0,
                  layout.flexibleFrames[position].height > 0 else {
                failed += 1
                continue
            }
            let allowance = snapAllowances[windows[index].identity]
            if isQuarantined(windows[index].pid) {
                failed += 1
                continue
            }
            if isSettled(observed[index], in: layout.flexibleFrames[position], allowance: allowance) {
                tiled += 1
                continue
            }
            switch finish(frame: layout.flexibleFrames[position], for: windows[index].element, snapAllowance: allowance) {
            case .tiled: tiled += 1
            case .constrained: constrainedCount += 1
            case .failed: failed += 1
            }
        }
        return .init(tiled: tiled, constrained: constrainedCount, failed: failed)
    }

    /// Asks every window that is not already in its tile to move there.
    /// Returns the indices of flexible windows whose resize was accepted.
    private func requestUnsettled(
        windows: [Window],
        layout: MosaicLayout,
        boundedIndices: [Int],
        flexibleIndices: [Int],
        observed: [CGRect]
    ) -> Set<Int> {
        var confirmed = Set<Int>()
        for (position, index) in boundedIndices.enumerated()
        where !isSettled(observed[index], in: layout.constrainedFrames[position], allowance: nil)
            && !isQuarantined(windows[index].pid) {
            request(frame: layout.constrainedFrames[position], for: windows[index].element)
        }
        for (position, index) in flexibleIndices.enumerated()
        where position < layout.flexibleFrames.count
            && !isSettled(observed[index], in: layout.flexibleFrames[position], allowance: snapAllowances[windows[index].identity])
            && !isQuarantined(windows[index].pid) {
            if request(frame: layout.flexibleFrames[position], for: windows[index].element).resized {
                confirmed.insert(index)
            }
        }
        return confirmed
    }

    /// A window may report that it is resizable but still enforce a maximum
    /// size (System Settings does this). Repartition until every flexible
    /// tile is inside the window's known min/max range.
    private func partition(
        windows: [Window],
        limits: [SizeLimits],
        bounded initialBounded: Set<Int>,
        in screen: CGRect
    ) -> (MosaicLayout, Set<Int>, [Int], [Int]) {
        var bounded = initialBounded
        var boundedIndices: [Int] = []
        var flexibleIndices: [Int] = []
        var layout = MosaicLayout(constrainedFrames: [], flexibleFrames: [])

        for _ in 0...windows.count {
            boundedIndices = windows.indices.filter { bounded.contains($0) }
            flexibleIndices = windows.indices.filter { !bounded.contains($0) }
            layout = MosaicLayoutEngine.frames(
                constrainedSizes: boundedIndices.map {
                    windows[$0].sizeIsSettable ? limits[$0].maximum : windows[$0].currentSize
                },
                flexibleMinimumSizes: flexibleIndices.map { limits[$0].minimum },
                in: screen
            )
            let newlyBounded = flexibleIndices.enumerated().compactMap { position, index -> Int? in
                guard position < layout.flexibleFrames.count else { return index }
                let frame = layout.flexibleFrames[position]
                return frame.width > limits[index].maximum.width + boundedTolerance
                    || frame.height > limits[index].maximum.height + boundedTolerance ? index : nil
            }
            if newlyBounded.isEmpty { break }
            bounded.formUnion(newlyBounded)
        }
        return (layout, bounded, boundedIndices, flexibleIndices)
    }

    /// Gives the apps a moment to apply their new frames. Runs the main run
    /// loop instead of sleeping so the menu and hotkey stay responsive; the
    /// delegate's isTiling flag keeps a nested tile from starting meanwhile.
    private func settle() {
        let deadline = Date().addingTimeInterval(0.04)
        // run(mode:before:) may return after a single event; keep going
        // until the deadline so the apps really get their 40 ms.
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: deadline)
        }
    }

    /// True when a window sits at its tile's origin and within its size
    /// wiggle room, so no request is needed.
    private func isSettled(_ observed: CGRect, in frame: CGRect, allowance: CGSize?) -> Bool {
        let wiggle = allowance ?? .zero
        return abs(observed.minX - frame.minX) <= sizeTolerance
            && abs(observed.minY - frame.minY) <= sizeTolerance
            && abs(observed.width - frame.width) <= max(wiggle.width, sizeTolerance)
            && abs(observed.height - frame.height) <= max(wiggle.height, sizeTolerance)
    }

    /// Learned limits combined with this screen's bounds.
    private func effectiveLimits(_ learned: LearnedLimits, on screen: CGRect) -> SizeLimits {
        let maximum = CGSize(
            width: min(screen.width, learned.maximum.width),
            height: min(screen.height, learned.maximum.height)
        )
        // A window observed to be smaller than the usual minimum tile keeps
        // that true size, so the layout reserves exactly what it occupies.
        let minimum = CGSize(
            width: min(max(TilingLimits.minimumTileSize.width, learned.minimum.width), maximum.width),
            height: min(max(TilingLimits.minimumTileSize.height, learned.minimum.height), maximum.height)
        )
        return SizeLimits(minimum: minimum, maximum: maximum)
    }

    private func pruneLearnedLimits(keeping identities: [String]) {
        let live = Set(identities)
        let expiry = Date().addingTimeInterval(-learnedLimitsLifetime)
        learnedLimits = learnedLimits.filter { live.contains($0.key) && $0.value.learnedAt > expiry }
        snapAllowances = snapAllowances.filter { live.contains($0.key) }
    }

    /// A deviation of at most one grid cell in either direction is snapping
    /// (Terminal rounds to the nearest whole cell). Remember the largest seen
    /// on each axis; that is this window's wiggle room.
    private func learnSnap(identity: String, requested: CGSize, actual: CGSize) {
        let widthGap = abs(requested.width - actual.width)
        let heightGap = abs(requested.height - actual.height)
        var allowance = snapAllowances[identity] ?? .zero
        if widthGap > sizeTolerance, widthGap <= boundedTolerance { allowance.width = max(allowance.width, widthGap) }
        if heightGap > sizeTolerance, heightGap <= boundedTolerance { allowance.height = max(allowance.height, heightGap) }
        if allowance != .zero { snapAllowances[identity] = allowance }
    }

    // MARK: - Applying frames

    /// Moving before and after resizing handles apps that constrain their
    /// size at screen edges.
    @discardableResult
    private func request(frame: CGRect, for element: AXUIElement) -> (moved: Bool, resized: Bool) {
        var position = frame.origin
        var size = frame.size
        guard !isQuarantined(element),
              let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return (false, false) }
        let firstMove = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        if firstMove == .cannotComplete {
            quarantine(element)
            return (false, false)
        }
        let resize = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        if resize == .cannotComplete {
            quarantine(element)
            return (firstMove == .success, false)
        }
        let finalMove = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        if finalMove == .cannotComplete { quarantine(element) }
        return (firstMove == .success || finalMove == .success, resize == .success)
    }

    private func finish(frame: CGRect, for element: AXUIElement, snapAllowance: CGSize?) -> ApplyResult {
        let outcome = request(frame: frame, for: element)
        guard outcome.moved, !isQuarantined(element) else { return .failed }
        guard outcome.resized, let actual = sizeAttribute(kAXSizeAttribute, from: element) else {
            return centerConstrainedWindow(element, in: frame)
        }
        let widthGap = abs(actual.width - frame.width)
        let heightGap = abs(actual.height - frame.height)
        if widthGap <= sizeTolerance && heightGap <= sizeTolerance { return .tiled }
        // A grid-snapped window lands within one cell of its tile. Leave it
        // at the tile's top-left corner, where it already is, so it does not
        // jump on every re-tile; the wiggle room stays at the bottom/right.
        let allowance = snapAllowance ?? CGSize(width: boundedTolerance, height: boundedTolerance)
        let snapped = widthGap <= max(allowance.width, sizeTolerance)
            && heightGap <= max(allowance.height, sizeTolerance)
        return snapped ? .tiled : centerConstrainedWindow(element, in: frame)
    }

    private func applyBounded(frame: CGRect, to element: AXUIElement) -> Bool {
        let outcome = request(frame: frame, for: element)
        guard outcome.moved, !isQuarantined(element),
              let actual = sizeAttribute(kAXSizeAttribute, from: element) else { return false }
        // The frame is the window's own size, so it must land within tolerance.
        return abs(actual.width - frame.width) <= sizeTolerance
            && abs(actual.height - frame.height) <= sizeTolerance
    }

    /// Some apps accept a resize request but clamp it to a fixed or minimum
    /// size. They cannot be scaled by the public macOS window API, so center
    /// their actual native size in the equal tile instead of leaving them at
    /// an arbitrary position.
    private func centerConstrainedWindow(_ element: AXUIElement, in frame: CGRect) -> ApplyResult {
        guard let actualSize = sizeAttribute(kAXSizeAttribute, from: element),
              !isQuarantined(element) else { return .failed }
        var centered = CGPoint(
            x: frame.midX - actualSize.width / 2,
            y: frame.midY - actualSize.height / 2
        )
        guard let centeredValue = AXValueCreate(.cgPoint, &centered) else { return .failed }
        let status = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, centeredValue)
        if status == .cannotComplete { quarantine(element) }
        return status == .success ? .constrained : .failed
    }

    // MARK: - Discovering windows

    /// Ignores window position and size so our own tiling does not trigger a
    /// loop, but changes when a visible window opens, closes, or minimizes.
    /// Nil when the visible-window list is unavailable, so the caller can
    /// treat the state as unknown instead of as a change.
    func windowTopologySignature() -> String? {
        let screens = screenBoundsInAccessibilityCoordinates()
        guard let windows = eligibleWindows() else { return nil }
        let signature = ScreenGeometryEngine.topologySignature(
            windowCenters: windows.map { ($0.identity, $0.center) },
            screens: screens
        )
        // While an app is not answering, its windows cannot be listed, so
        // the true window set is unknown; report that rather than a change.
        guard quarantine.pids.isEmpty else { return nil }
        return signature
    }

    /// Nil if the window server's on-screen list cannot be read. Without it
    /// a window's Space cannot be established, and tiling windows from other
    /// Spaces is exactly the bug the list guards against.
    private func eligibleWindows() -> [Window]? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let onScreen = onScreenWindowsByProcess() else { return nil }
        let alive = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ownPID
        }
        // Per-app state outlives hiding; only a quit app is forgotten.
        let alivePIDs = Set(alive.map(\.processIdentifier))
        applicationElements = applicationElements.filter { alivePIDs.contains($0.key) }
        quarantine.forget(except: alivePIDs)
        pendingEnhancedUIRestore = pendingEnhancedUIRestore.filter { alivePIDs.contains($0) }
        let running = alive.filter { !$0.isHidden }

        return running
            .flatMap { app -> [Window] in
                // The Accessibility window list contains windows on every
                // Space. Only windows the system currently draws on screen
                // take part in the layout.
                windows(
                    for: app.processIdentifier,
                    appName: app.localizedName ?? app.bundleIdentifier ?? "App",
                    bundleIdentifier: app.bundleIdentifier,
                    onScreen: onScreen[app.processIdentifier] ?? []
                )
            }
            .sorted { $0.identity < $1.identity }
    }

    private func applicationElement(for pid: pid_t) -> AXUIElement {
        if let element = applicationElements[pid] { return element }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        applicationElements[pid] = element
        return element
    }

    private func windows(
        for pid: pid_t,
        appName: String,
        bundleIdentifier: String?,
        onScreen: [OnScreenWindow]
    ) -> [Window] {
        guard !isQuarantined(pid) else { return [] }
        let app = applicationElement(for: pid)
        guard let elements = attribute(kAXWindowsAttribute, from: app) as? [AXUIElement] else { return [] }

        var standard: [Window] = []
        var dialogs: [Window] = []
        var hasStandardWindow = false
        // Each on-screen entry may identify only one Accessibility window, so
        // two identical-looking windows of one app keep distinct identities.
        var unclaimed = onScreen
        for element in elements {
            // Stop probing an app as soon as one request has timed out.
            guard !isQuarantined(pid) else { return [] }
            let subrole = attribute(kAXSubroleAttribute, from: element) as? String
            let isStandard = subrole == kAXStandardWindowSubrole
            let isDialog = subrole == kAXDialogSubrole
            guard isStandard || isDialog else { continue }
            // Open and Save panels report themselves as standard windows and
            // are not modal, but the shared panel service labels them.
            if let identifier = attribute(kAXIdentifierAttribute, from: element) as? String,
               identifier == "open-panel" || identifier == "save-panel" { continue }
            if isStandard { hasStandardWindow = true }
            // Other modal dialogs (alerts, sheets shown as windows) are never tiled.
            if isDialog, (attribute(kAXModalAttribute, from: element) as? Bool) == true { continue }
            let title = attribute(kAXTitleAttribute, from: element) as? String
            guard (attribute(kAXRoleAttribute, from: element) as? String) == kAXWindowRole,
                  // Wispr exposes a large transparent status HUD as a window.
                  // Tiling it creates what looks like an empty desktop tile.
                  !(bundleIdentifier == "com.electron.wispr-flow" && title == "Status"),
                  (attribute(kAXMinimizedAttribute, from: element) as? Bool) != true,
                  // A full-screen window lives on its own Space and is drawn
                  // on screen while that Space is active; it must be left alone.
                  (attribute("AXFullScreen", from: element) as? Bool) != true,
                  let position = pointAttribute(kAXPositionAttribute, from: element),
                  let size = sizeAttribute(kAXSizeAttribute, from: element),
                  size.width > 80, size.height > 80 else { continue }

            let frame = CGRect(origin: position, size: size)
            let identity: String
            if let number = windowNumber(of: element) {
                guard let matchIndex = unclaimed.firstIndex(where: { $0.number == Int(number) }) else { continue }
                unclaimed.remove(at: matchIndex)
                identity = "\(pid):w\(number)"
            } else {
                // Fallback for the rare window with no id: match by frame.
                guard let matchIndex = unclaimed.firstIndex(where: { matches($0.bounds, frame) }) else { continue }
                identity = "\(pid):w\(unclaimed.remove(at: matchIndex).number)"
            }
            let window = Window(
                element: element,
                pid: pid,
                name: title.flatMap { $0.isEmpty ? nil : $0 } ?? appName,
                center: CGPoint(x: frame.midX, y: frame.midY),
                identity: identity,
                currentPosition: position,
                currentSize: size,
                sizeIsSettable: isAttributeSettable(kAXSizeAttribute, on: element)
            )
            if isStandard { standard.append(window) } else { dialogs.append(window) }
        }
        // A non-modal dialog counts only when it is the app's main window,
        // that is, when the app has no standard window at all (minimized
        // ones included).
        return hasStandardWindow ? standard : dialogs
    }

    private func matches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2 && abs(lhs.minY - rhs.minY) <= 2
            && abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
    }

    /// Windows the window server currently draws, grouped by owning process.
    /// Returns nil if the list cannot be read. No Screen Recording permission
    /// is needed for bounds and owner; only window titles require it.
    private func onScreenWindowsByProcess() -> [pid_t: [OnScreenWindow]]? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        var result: [pid_t: [OnScreenWindow]] = [:]
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { continue }
            result[pid, default: []].append(OnScreenWindow(number: number, bounds: bounds))
        }
        return result
    }

    // MARK: - Accessibility helpers

    // Every helper below refuses to talk to a quarantined app, so one
    // timed-out request is the last one that app receives for a while, no
    // matter which code path asks.

    private func isAttributeSettable(_ name: String, on element: AXUIElement) -> Bool {
        guard !isQuarantined(element) else { return false }
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, name as CFString, &settable)
        if status == .cannotComplete { quarantine(element) }
        return status == .success && settable.boolValue
    }

    @discardableResult
    private func setAttribute(_ name: String, to value: CFTypeRef, on element: AXUIElement) -> Bool {
        guard !isQuarantined(element) else { return false }
        let status = AXUIElementSetAttributeValue(element, name as CFString, value)
        if status == .cannotComplete { quarantine(element) }
        return status == .success
    }

    /// The window server id, or nil if the app did not answer.
    private func windowNumber(of element: AXUIElement) -> CGWindowID? {
        guard !isQuarantined(element) else { return nil }
        var number: CGWindowID = 0
        let status = windowServerID(element, &number)
        if status == .cannotComplete { quarantine(element) }
        return status == .success && number != 0 ? number : nil
    }

    private func attribute(_ name: String, from element: AXUIElement) -> AnyObject? {
        guard !isQuarantined(element) else { return nil }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard status == .success else {
            if status == .cannotComplete { quarantine(element) }
            return nil
        }
        return value
    }

    /// Every timed-out request costs the full messaging timeout on the main
    /// thread, so the first one is enough to leave the app alone for a while.
    private func quarantine(_ element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return }
        quarantine.add(pid)
    }

    private func isQuarantined(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && isQuarantined(pid)
    }

    private func isQuarantined(_ pid: pid_t) -> Bool {
        quarantine.contains(pid)
    }

    private func pointAttribute(_ name: String, from element: AXUIElement) -> CGPoint? {
        guard let value = attribute(name, from: element), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ name: String, from element: AXUIElement) -> CGSize? {
        guard let value = attribute(name, from: element), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private func screenBoundsInAccessibilityCoordinates() -> [CGRect] {
        guard let primary = NSScreen.screens.first else { return [] }
        return ScreenGeometryEngine.accessibilityFrames(
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            primaryFrame: primary.frame
        )
    }
}
