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
    private struct LearnedLimits {
        let limits: SizeLimits
        let learnedAt: Date
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
    private var unresponsiveUntil: [pid_t: Date] = [:]
    private let systemWideElement = AXUIElementCreateSystemWide()
    private let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"

    /// Seconds to wait for another app before giving up on an Accessibility
    /// request. The default is six seconds per request, which lets one hung
    /// app freeze the tiler.
    private let messagingTimeout: Float = 1.0
    private let unresponsiveCooldown: TimeInterval = 5
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

        let screens = screenBoundsInAccessibilityCoordinates()
        guard !screens.isEmpty else { return .empty }

        let windows = eligibleWindows()
        pruneLearnedLimits(keeping: windows.map(\.identity))

        var grouped = Array(repeating: [Window](), count: screens.count)
        for window in windows {
            guard let screenIndex = ScreenGeometryEngine.screenIndex(
                for: window.center,
                screens: screens
            ) else { continue }
            grouped[screenIndex].append(window)
        }

        let enhancedUIApps = disableEnhancedUserInterface(for: Set(windows.map(\.pid)))
        defer { restoreEnhancedUserInterface(for: enhancedUIApps) }

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
            return AXUIElementSetAttributeValue(app, enhancedUserInterfaceAttribute as CFString, kCFBooleanFalse) == .success
        }
    }

    private func restoreEnhancedUserInterface(for pids: [pid_t]) {
        for pid in pids {
            AXUIElementSetAttributeValue(applicationElement(for: pid), enhancedUserInterfaceAttribute as CFString, kCFBooleanTrue)
        }
    }

    // MARK: - Tiling one screen

    private func tile(windows: [Window], in screen: CGRect, summaries: inout [String]) -> TilingResult {
        guard !windows.isEmpty else { return .empty }

        var limits = windows.map { window -> SizeLimits in
            guard window.sizeIsSettable else {
                return SizeLimits(minimum: window.currentSize, maximum: window.currentSize)
            }
            return clamp(learnedLimits[window.identity]?.limits
                ?? SizeLimits(minimum: TilingLimits.minimumTileSize, maximum: screen.size), to: screen)
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
            guard !confirmed.isEmpty else { break }
            // One settle for the whole screen instead of a sleep per window.
            usleep(40_000)

            for (position, index) in flexibleIndices.enumerated() where position < layout.flexibleFrames.count {
                guard let actual = sizeAttribute(kAXSizeAttribute, from: windows[index].element) else { continue }
                if let origin = pointAttribute(kAXPositionAttribute, from: windows[index].element) {
                    observed[index] = CGRect(origin: origin, size: actual)
                }
                // Learn only from a resize the app accepted. A refused or
                // timed-out request leaves the old size in place, and reading
                // that back as a limit is exactly the cache poisoning the
                // audit found.
                guard confirmed.contains(index) else { continue }
                let requested = layout.flexibleFrames[position].size
                // A deviation within one grid cell is snapping and must not
                // be recorded as a limit: a 12-point shortfall in a short
                // tile would otherwise become a hard maximum that later
                // turns the window into a fixed-size block.
                learnSnap(identity: windows[index].identity, requested: requested, actual: actual)
                var updated = limits[index]
                if actual.width > requested.width + boundedTolerance { updated.minimum.width = max(updated.minimum.width, actual.width) }
                if actual.height > requested.height + boundedTolerance { updated.minimum.height = max(updated.minimum.height, actual.height) }
                if actual.width < requested.width - boundedTolerance { updated.maximum.width = min(updated.maximum.width, actual.width) }
                if actual.height < requested.height - boundedTolerance { updated.maximum.height = min(updated.maximum.height, actual.height) }
                updated = clamp(updated, to: screen)
                if updated.minimum != limits[index].minimum || updated.maximum != limits[index].maximum {
                    limits[index] = updated
                    learnedLimits[windows[index].identity] = LearnedLimits(limits: updated, learnedAt: Date())
                    learnedOnLastPass = true
                }
            }
            if !learnedOnLastPass { break }
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
            usleep(40_000)
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
            if isSettled(observed[index], in: layout.constrainedFrames[position], allowance: nil)
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

    /// True when a window sits at its tile's origin and within its size
    /// wiggle room, so no request is needed.
    private func isSettled(_ observed: CGRect, in frame: CGRect, allowance: CGSize?) -> Bool {
        let wiggle = allowance ?? .zero
        return abs(observed.minX - frame.minX) <= sizeTolerance
            && abs(observed.minY - frame.minY) <= sizeTolerance
            && abs(observed.width - frame.width) <= max(wiggle.width, sizeTolerance)
            && abs(observed.height - frame.height) <= max(wiggle.height, sizeTolerance)
    }

    private func clamp(_ limits: SizeLimits, to screen: CGRect) -> SizeLimits {
        let minimum = CGSize(
            width: min(max(TilingLimits.minimumTileSize.width, limits.minimum.width), screen.width),
            height: min(max(TilingLimits.minimumTileSize.height, limits.minimum.height), screen.height)
        )
        let maximum = CGSize(
            width: max(minimum.width, min(screen.width, limits.maximum.width)),
            height: max(minimum.height, min(screen.height, limits.maximum.height))
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
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return (false, false) }
        let firstMove = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        if firstMove == .cannotComplete {
            quarantine(element)
            return (false, false)
        }
        let resize = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        let finalMove = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        if resize == .cannotComplete || finalMove == .cannotComplete { quarantine(element) }
        return (firstMove == .success || finalMove == .success, resize == .success)
    }

    private func finish(frame: CGRect, for element: AXUIElement, snapAllowance: CGSize?) -> ApplyResult {
        let outcome = request(frame: frame, for: element)
        guard outcome.moved else { return .failed }
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
        return outcome.moved && (outcome.resized || !isAttributeSettable(kAXSizeAttribute, on: element))
    }

    /// Some apps accept a resize request but clamp it to a fixed or minimum
    /// size. They cannot be scaled by the public macOS window API, so center
    /// their actual native size in the equal tile instead of leaving them at
    /// an arbitrary position.
    private func centerConstrainedWindow(_ element: AXUIElement, in frame: CGRect) -> ApplyResult {
        guard let actualSize = sizeAttribute(kAXSizeAttribute, from: element) else { return .failed }
        var centered = CGPoint(
            x: frame.midX - actualSize.width / 2,
            y: frame.midY - actualSize.height / 2
        )
        guard let centeredValue = AXValueCreate(.cgPoint, &centered) else { return .failed }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, centeredValue) == .success
            ? .constrained
            : .failed
    }

    // MARK: - Discovering windows

    /// Ignores window position and size so our own tiling does not trigger a
    /// loop, but changes when a visible window opens, closes, or minimizes.
    func windowTopologySignature() -> String {
        let screens = screenBoundsInAccessibilityCoordinates()
        let signature = ScreenGeometryEngine.topologySignature(
            windowCenters: eligibleWindows().map { ($0.identity, $0.center) },
            screens: screens
        )
        // An app that is not answering keeps a stable placeholder so it does
        // not look like its windows closed and reopened while it is skipped.
        let skipped = unresponsiveUntil.keys.sorted().map { "unresponsive:\($0)" }
        return ([signature] + skipped).joined(separator: "|")
    }

    private func eligibleWindows() -> [Window] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let onScreen = onScreenWindowsByProcess()
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && !$0.isTerminated
                && !$0.isHidden
                && $0.processIdentifier != ownPID
        }
        let livePIDs = Set(running.map(\.processIdentifier))
        applicationElements = applicationElements.filter { livePIDs.contains($0.key) }
        unresponsiveUntil = unresponsiveUntil.filter { livePIDs.contains($0.key) && $0.value > Date() }

        return running
            .flatMap { app -> [Window] in
                // The Accessibility window list contains windows on every
                // Space. Only windows the system currently draws on screen
                // take part in the layout; if the on-screen list is not
                // available, fall back to accepting every window.
                windows(
                    for: app.processIdentifier,
                    appName: app.localizedName ?? app.bundleIdentifier ?? "App",
                    bundleIdentifier: app.bundleIdentifier,
                    onScreen: onScreen.map { $0[app.processIdentifier] ?? [] }
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
        onScreen: [OnScreenWindow]?
    ) -> [Window] {
        guard !isQuarantined(pid) else { return [] }
        let app = applicationElement(for: pid)
        guard let elements = attribute(kAXWindowsAttribute, from: app) as? [AXUIElement] else { return [] }

        var standard: [Window] = []
        var dialogs: [Window] = []
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
            var number: CGWindowID = 0
            if windowServerID(element, &number) == .success, number != 0 {
                if onScreen != nil, !(onScreen!.contains { $0.number == Int(number) }) { continue }
                identity = "\(pid):w\(number)"
            } else if onScreen != nil {
                // Fallback for the rare window with no id: match by frame.
                guard let matchIndex = unclaimed?.firstIndex(where: { matches($0.bounds, frame) }),
                      let match = unclaimed?.remove(at: matchIndex) else { continue }
                identity = "\(pid):w\(match.number)"
            } else {
                identity = "\(pid):h\(CFHash(element))"
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
        // Dialogs count only when they are the app's main window. Open and
        // Save panels of an app that already has a normal window would
        // otherwise reflow the whole desktop twice.
        return standard.isEmpty ? dialogs : standard
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

    private func isAttributeSettable(_ name: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success
            && settable.boolValue
    }

    private func attribute(_ name: String, from element: AXUIElement) -> AnyObject? {
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
        guard AXUIElementGetPid(element, &pid) == .success, !isQuarantined(pid) else { return }
        unresponsiveUntil[pid] = Date().addingTimeInterval(unresponsiveCooldown)
        Log.tiling.warning("pid \(pid) did not answer within \(self.messagingTimeout) s; skipping it for \(self.unresponsiveCooldown) s")
    }

    private func isQuarantined(_ pid: pid_t) -> Bool {
        guard let until = unresponsiveUntil[pid] else { return false }
        return until > Date()
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
