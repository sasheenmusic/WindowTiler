import AppKit
import ApplicationServices
import WindowTilerCore

struct TilingResult {
    let tiled: Int
    let constrained: Int
    let failed: Int
}

final class WindowTiler {
    private struct SizeLimits {
        let minimum: CGSize
        let maximum: CGSize
    }

    private var sizeLimitsCache: [String: SizeLimits] = [:]

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

    func isAccessibilityEnabled(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func tileAllWindows() -> TilingResult {
        guard isAccessibilityEnabled(prompt: true) else { return .init(tiled: 0, constrained: 0, failed: 0) }

        let screens = screenBoundsInAccessibilityCoordinates()
        guard !screens.isEmpty else { return .init(tiled: 0, constrained: 0, failed: 0) }

        var grouped = Array(repeating: [Window](), count: screens.count)
        for window in eligibleWindows() {
            guard let screenIndex = ScreenGeometryEngine.screenIndex(
                for: window.center,
                screens: screens
            ) else { continue }
            grouped[screenIndex].append(window)
        }

        var tiled = 0
        var constrained = 0
        var failed = 0
        for index in screens.indices {
            let windows = grouped[index]
            let result = tile(windows: windows, in: screens[index])
            tiled += result.tiled
            constrained += result.constrained
            failed += result.failed
        }
        return .init(tiled: tiled, constrained: constrained, failed: failed)
    }

    private func tile(windows: [Window], in screen: CGRect) -> TilingResult {
        let limits = windows.map { sizeLimits(for: $0, on: screen) }
        var constrained = Set(windows.indices.filter { !windows[$0].sizeIsSettable })
        var constrainedIndices: [Int] = []
        var flexibleIndices: [Int] = []
        var layout = MosaicLayout(constrainedFrames: [], flexibleFrames: [])

        // A window may report that it is resizable but still enforce a maximum
        // size (System Settings does this). Repartition until every flexible
        // tile is inside the window's real min/max range.
        for _ in 0...windows.count {
            constrainedIndices = windows.indices.filter { constrained.contains($0) }
            flexibleIndices = windows.indices.filter { !constrained.contains($0) }
            layout = MosaicLayoutEngine.frames(
                constrainedSizes: constrainedIndices.map {
                    windows[$0].sizeIsSettable ? limits[$0].maximum : windows[$0].currentSize
                },
                flexibleMinimumSizes: flexibleIndices.map { limits[$0].minimum },
                in: screen
            )

            let newlyConstrained = flexibleIndices.enumerated().compactMap { position, index -> Int? in
                guard position < layout.flexibleFrames.count else { return index }
                let frame = layout.flexibleFrames[position]
                // Terminal and some AppKit windows snap to a character/pixel
                // grid and may stop a few points short of the requested size.
                // That is not a genuinely fixed-size window and must not send
                // the entire desktop into the bounded-window mosaic fallback.
                let maximumTolerance: CGFloat = 32
                return frame.width > limits[index].maximum.width + maximumTolerance
                    || frame.height > limits[index].maximum.height + maximumTolerance ? index : nil
            }
            if newlyConstrained.isEmpty { break }
            constrained.formUnion(newlyConstrained)
        }

        let summary = windows.indices.map { index in
            let state = constrained.contains(index) ? "bounded" : "flexible"
            return "\(windows[index].name): min \(Int(limits[index].minimum.width))x\(Int(limits[index].minimum.height)), max \(Int(limits[index].maximum.width))x\(Int(limits[index].maximum.height)), \(state)"
        }.joined(separator: " | ")
        UserDefaults.standard.set(summary, forKey: "diagnostics.lastLayout")

        var tiled = 0
        var constrainedCount = 0
        var failed = 0

        for (position, index) in constrainedIndices.enumerated() {
            if applyConstrained(frame: layout.constrainedFrames[position], to: windows[index].element) {
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
            switch apply(frame: layout.flexibleFrames[position], to: windows[index].element) {
            case .tiled: tiled += 1
            case .constrained: constrainedCount += 1
            case .failed: failed += 1
            }
        }
        return .init(tiled: tiled, constrained: constrainedCount, failed: failed)
    }

    private func applyConstrained(frame: CGRect, to element: AXUIElement) -> Bool {
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        let sizeResult = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        let moveResult = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        return moveResult == .success && (sizeResult == .success || !isAttributeSettable(kAXSizeAttribute, on: element))
    }

    private func sizeLimits(for window: Window, on screen: CGRect) -> SizeLimits {
        let cacheKey = "\(window.identity)@\(ScreenGeometryEngine.signature(for: screen))"
        if let cached = sizeLimitsCache[cacheKey] { return cached }
        guard window.sizeIsSettable else {
            let limits = SizeLimits(minimum: window.currentSize, maximum: window.currentSize)
            sizeLimitsCache[cacheKey] = limits
            return limits
        }

        var probe = CGSize(width: 80, height: 80)
        var probePosition = screen.origin
        if let positionValue = AXValueCreate(.cgPoint, &probePosition) {
            AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, positionValue)
        }
        if let probeValue = AXValueCreate(.cgSize, &probe) {
            AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, probeValue)
        }
        usleep(20_000)
        let minimumActual = sizeAttribute(kAXSizeAttribute, from: window.element) ?? window.currentSize

        probe = CGSize(width: screen.width * 2, height: screen.height * 2)
        if let probeValue = AXValueCreate(.cgSize, &probe) {
            AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, probeValue)
        }
        usleep(20_000)
        let maximumActual = sizeAttribute(kAXSizeAttribute, from: window.element) ?? window.currentSize

        var restore = window.currentSize
        if let restoreValue = AXValueCreate(.cgSize, &restore) {
            AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, restoreValue)
        }
        var restorePosition = window.currentPosition
        if let restorePositionValue = AXValueCreate(.cgPoint, &restorePosition) {
            AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, restorePositionValue)
        }

        let minimum = CGSize(width: max(320, minimumActual.width), height: max(240, minimumActual.height))
        let maximum = CGSize(
            width: max(minimum.width, min(screen.width, maximumActual.width)),
            height: max(minimum.height, min(screen.height, maximumActual.height))
        )
        let limits = SizeLimits(minimum: minimum, maximum: maximum)
        sizeLimitsCache[cacheKey] = limits
        return limits
    }

    /// Ignores window position and size so our own tiling does not trigger a
    /// loop, but changes when a visible window opens, closes, or minimizes.
    func windowTopologySignature() -> String {
        let screens = screenBoundsInAccessibilityCoordinates()
        return ScreenGeometryEngine.topologySignature(
            windowCenters: eligibleWindows().map { ($0.identity, $0.center) },
            screens: screens
        )
    }

    private func eligibleWindows() -> [Window] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular
                    && !$0.isTerminated
                    && !$0.isHidden
                    && $0.processIdentifier != ownPID
            }
            .flatMap { windows(
                for: $0.processIdentifier,
                appName: $0.localizedName ?? $0.bundleIdentifier ?? "App",
                bundleIdentifier: $0.bundleIdentifier
            ) }
            .sorted { $0.identity < $1.identity }
    }

    private func windows(for pid: pid_t, appName: String, bundleIdentifier: String?) -> [Window] {
        let app = AXUIElementCreateApplication(pid)
        guard let elements = attribute(kAXWindowsAttribute, from: app) as? [AXUIElement] else { return [] }

        return elements.compactMap { element in
            let subrole = attribute(kAXSubroleAttribute, from: element) as? String
            let title = attribute(kAXTitleAttribute, from: element) as? String
            let isAppWindow = subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
            guard (attribute(kAXRoleAttribute, from: element) as? String) == kAXWindowRole,
                  isAppWindow,
                  // Wispr exposes a large transparent status HUD as a window.
                  // Tiling it creates what looks like an empty desktop tile.
                  !(bundleIdentifier == "com.electron.wispr-flow" && title == "Status"),
                  (attribute(kAXMinimizedAttribute, from: element) as? Bool) != true,
                  let position = pointAttribute(kAXPositionAttribute, from: element),
                  let size = sizeAttribute(kAXSizeAttribute, from: element),
                  size.width > 80, size.height > 80 else { return nil }

            let identity = "\(pid):\(CFHash(element))"
            return Window(
                element: element,
                name: title.flatMap { $0.isEmpty ? nil : $0 } ?? appName,
                center: CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2),
                identity: identity,
                currentPosition: position,
                currentSize: size,
                sizeIsSettable: isAttributeSettable(kAXSizeAttribute, on: element)
            )
        }
    }

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

    private func apply(frame: CGRect, to element: AXUIElement) -> ApplyResult {
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return .failed }

        // Moving before and after resizing handles apps that constrain their size at screen edges.
        let firstMove = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        let resize = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        let finalMove = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        guard firstMove == .success || finalMove == .success else { return .failed }

        guard resize == .success,
              var actualSize = sizeAttribute(kAXSizeAttribute, from: element) else {
            return centerConstrainedWindow(element, in: frame)
        }

        var sizeMatches = abs(actualSize.width - frame.width) <= 2
            && abs(actualSize.height - frame.height) <= 2
        // Some apps (notably System Settings) recalculate their content size
        // after each request. A few quick identical requests converge on the
        // shared boundary instead of leaving the window slightly too tall.
        var previousSize = actualSize
        for _ in 0..<8 where !sizeMatches {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
            usleep(20_000)
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
            if let retriedSize = sizeAttribute(kAXSizeAttribute, from: element) {
                actualSize = retriedSize
                sizeMatches = abs(actualSize.width - frame.width) <= 2
                    && abs(actualSize.height - frame.height) <= 2
                if !sizeMatches,
                   abs(actualSize.width - previousSize.width) < 0.5,
                   abs(actualSize.height - previousSize.height) < 0.5 {
                    break
                }
                previousSize = actualSize
            }
        }
        return sizeMatches ? .tiled : centerConstrainedWindow(element, in: frame)
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


    private func screenBoundsInAccessibilityCoordinates() -> [CGRect] {
        guard let primary = NSScreen.screens.first else { return [] }
        return ScreenGeometryEngine.accessibilityFrames(
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            primaryFrame: primary.frame
        )
    }
}
