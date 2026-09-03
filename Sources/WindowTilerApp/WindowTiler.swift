import AppKit
import ApplicationServices
import WindowTilerCore

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
    private var learnedLimits: [String: SizeLimits] = [:]
    /// How far short of a requested size a window lands because it snaps to
    /// a grid (Terminal resizes in whole character cells, 8x16 points with a
    /// typical font). Learned per window; a shortfall inside this allowance
    /// is treated as a tiled window with a little wiggle room, not as a
    /// bounded one.
    private var snapAllowances: [String: CGSize] = [:]
    private var applicationElements: [pid_t: AXUIElement] = [:]
    private var unresponsiveUntil: [pid_t: Date] = [:]
    private let systemWideElement = AXUIElementCreateSystemWide()

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
        UserDefaults.standard.set(summaries.joined(separator: " | "), forKey: "diagnostics.lastLayout")
        return .init(tiled: tiled, constrained: constrained, failed: failed)
    }

    // MARK: - Tiling one screen

    private func tile(windows: [Window], in screen: CGRect, summaries: inout [String]) -> TilingResult {
        guard !windows.isEmpty else { return .empty }

        var limits = windows.map { window -> SizeLimits in
            guard window.sizeIsSettable else {
                return SizeLimits(minimum: window.currentSize, maximum: window.currentSize)
            }
            return clamp(learnedLimits[window.identity]
                ?? SizeLimits(minimum: TilingLimits.minimumTileSize, maximum: screen.size), to: screen)
        }
        var bounded = Set(windows.indices.filter { !windows[$0].sizeIsSettable })
        var boundedIndices: [Int] = []
        var flexibleIndices: [Int] = []
        var layout = MosaicLayout(constrainedFrames: [], flexibleFrames: [])

        // Each pass asks every window for its tile, then reads back what the
        // window really did. Windows that refuse to shrink teach us a minimum,
        // windows that refuse to grow teach us a maximum, and the layout is
        // recomputed with that knowledge until nothing new is learned.
        for _ in 0..<maximumPasses {
            (layout, bounded, boundedIndices, flexibleIndices) = partition(
                windows: windows, limits: limits, bounded: bounded, in: screen
            )
            for (position, index) in boundedIndices.enumerated() {
                request(frame: layout.constrainedFrames[position], for: windows[index].element)
            }
            for (position, index) in flexibleIndices.enumerated() where position < layout.flexibleFrames.count {
                request(frame: layout.flexibleFrames[position], for: windows[index].element)
            }
            // One settle for the whole screen instead of a sleep per window.
            usleep(40_000)

            var learnedSomething = false
            for (position, index) in flexibleIndices.enumerated() where position < layout.flexibleFrames.count {
                let requested = layout.flexibleFrames[position].size
                guard let actual = sizeAttribute(kAXSizeAttribute, from: windows[index].element) else { continue }
                var updated = limits[index]
                if actual.width > requested.width + sizeTolerance { updated.minimum.width = max(updated.minimum.width, actual.width) }
                if actual.height > requested.height + sizeTolerance { updated.minimum.height = max(updated.minimum.height, actual.height) }
                if actual.width < requested.width - sizeTolerance { updated.maximum.width = min(updated.maximum.width, actual.width) }
                if actual.height < requested.height - sizeTolerance { updated.maximum.height = min(updated.maximum.height, actual.height) }
                updated = clamp(updated, to: screen)
                learnSnap(identity: windows[index].identity, requested: requested, actual: actual)
                if updated.minimum != limits[index].minimum || updated.maximum != limits[index].maximum {
                    limits[index] = updated
                    learnedLimits[windows[index].identity] = updated
                    learnedSomething = true
                }
            }
            if !learnedSomething { break }
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
            if applyBounded(frame: layout.constrainedFrames[position], to: windows[index].element) {
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
            switch finish(
                frame: layout.flexibleFrames[position],
                for: windows[index].element,
                snapAllowance: snapAllowances[windows[index].identity]
            ) {
            case .tiled: tiled += 1
            case .constrained: constrainedCount += 1
            case .failed: failed += 1
            }
        }
        return .init(tiled: tiled, constrained: constrainedCount, failed: failed)
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
        learnedLimits = learnedLimits.filter { live.contains($0.key) }
        snapAllowances = snapAllowances.filter { live.contains($0.key) }
    }

    /// A shortfall of at most one grid cell is snapping. Remember the largest
    /// shortfall seen on each axis; that is this window's wiggle room.
    private func learnSnap(identity: String, requested: CGSize, actual: CGSize) {
        let shortWidth = requested.width - actual.width
        let shortHeight = requested.height - actual.height
        var allowance = snapAllowances[identity] ?? .zero
        if shortWidth > sizeTolerance, shortWidth <= boundedTolerance { allowance.width = max(allowance.width, shortWidth) }
        if shortHeight > sizeTolerance, shortHeight <= boundedTolerance { allowance.height = max(allowance.height, shortHeight) }
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
        let resize = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        let finalMove = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
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
        // A grid-snapped window lands a little short of its tile. Leave it
        // at the tile's top-left corner, where it already is, so it does not
        // jump on every re-tile; the wiggle room stays at the bottom/right.
        let allowance = snapAllowance ?? CGSize(width: boundedTolerance, height: boundedTolerance)
        let snapped = frame.width - actual.width <= max(allowance.width, sizeTolerance)
            && frame.height - actual.height <= max(allowance.height, sizeTolerance)
            && actual.width <= frame.width + sizeTolerance
            && actual.height <= frame.height + sizeTolerance
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
        if let blockedUntil = unresponsiveUntil[pid], blockedUntil > Date() { return [] }
        let app = applicationElement(for: pid)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        if status == .cannotComplete {
            // The app did not answer within the messaging timeout. Leave it
            // alone for a while instead of stalling on every request.
            unresponsiveUntil[pid] = Date().addingTimeInterval(unresponsiveCooldown)
            Log.tiling.warning("\(appName, privacy: .public) (pid \(pid)) did not answer within \(self.messagingTimeout) s; skipping it for \(self.unresponsiveCooldown) s")
            return []
        }
        guard status == .success, let elements = value as? [AXUIElement] else { return [] }

        var standard: [Window] = []
        var dialogs: [Window] = []
        // Each on-screen entry may identify only one Accessibility window, so
        // two identical-looking windows of one app keep distinct identities.
        var unclaimed = onScreen
        for element in elements {
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
                  let position = pointAttribute(kAXPositionAttribute, from: element),
                  let size = sizeAttribute(kAXSizeAttribute, from: element),
                  size.width > 80, size.height > 80 else { continue }

            let frame = CGRect(origin: position, size: size)
            let identity: String
            if onScreen != nil {
                guard let matchIndex = unclaimed?.firstIndex(where: { matches($0.bounds, frame) }),
                      let match = unclaimed?.remove(at: matchIndex) else { continue }
                identity = "\(pid):w\(match.number)"
            } else {
                identity = "\(pid):h\(CFHash(element))"
            }
            let window = Window(
                element: element,
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
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
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
