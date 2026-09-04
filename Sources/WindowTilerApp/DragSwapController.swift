import AppKit
import ApplicationServices

/// Turns "a window moved while the mouse button was down, then the button
/// came up" into a drop the tiler can act on. Moves made by Window Tiler
/// itself or by scripts happen with the button up and are ignored.
final class DragSwapController {
    var isEnabled = true

    private let tiler: WindowTiler
    private let isBusy: () -> Bool
    private let perform: (AXUIElement, CGRect, CGPoint) -> Void
    private var dragged: AXUIElement?
    private var startFrame = CGRect.zero
    private var monitors: [Any] = []
    /// The dragged app finishes its own move a moment after the button
    /// comes up; read positions after that.
    private let dropDelay: TimeInterval = 0.08

    init(
        tiler: WindowTiler,
        isBusy: @escaping () -> Bool,
        perform: @escaping (AXUIElement, CGRect, CGPoint) -> Void
    ) {
        self.tiler = tiler
        self.isBusy = isBusy
        self.perform = perform
        // Global monitors see other apps' events, local ones our own.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            self?.mouseUp()
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] event in
            self?.mouseUp()
            return event
        }) {
            monitors.append(local)
        }
    }

    deinit {
        monitors.forEach(NSEvent.removeMonitor)
    }

    /// Called for every window-moved notification. The first one that
    /// arrives with the left button held starts a drag.
    func windowMoved(_ element: AXUIElement) {
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        if !buttonDown {
            // A mouse-up that was never delivered: forget the stale drag.
            if dragged != nil { cancel() }
            return
        }
        guard isEnabled, !isBusy(), dragged == nil, let frame = tiler.frame(of: element) else { return }
        dragged = element
        startFrame = frame
        tiler.isDragging = true
    }

    private func cancel() {
        dragged = nil
        tiler.isDragging = false
    }

    private func mouseUp() {
        guard let element = dragged else { return }
        dragged = nil
        let location = NSEvent.mouseLocation
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let pointer = CGPoint(x: location.x, y: top - location.y)
        let start = startFrame
        DispatchQueue.main.asyncAfter(deadline: .now() + dropDelay) { [weak self] in
            guard let self else { return }
            self.tiler.isDragging = false
            self.perform(element, start, pointer)
        }
    }
}
