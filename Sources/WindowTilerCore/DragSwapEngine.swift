import CoreGraphics

/// The decisions behind "drag a window onto another and they trade places",
/// kept free of Accessibility so they can be tested.
public enum DragSwapEngine {
    public struct Candidate: Equatable {
        public let id: String
        public let frame: CGRect

        public init(id: String, frame: CGRect) {
            self.id = id
            self.frame = frame
        }
    }

    public enum DragKind: Equatable {
        case move
        /// The size changed: the user dragged an edge, not the window.
        case resize
        /// Barely moved: a click that wobbled, not a drag.
        case wobble
    }

    public static func classify(
        startFrame: CGRect,
        endFrame: CGRect,
        minimumDistance: CGFloat = 24,
        sizeTolerance: CGFloat = 2
    ) -> DragKind {
        if abs(startFrame.width - endFrame.width) > sizeTolerance
            || abs(startFrame.height - endFrame.height) > sizeTolerance {
            return .resize
        }
        let distance = hypot(endFrame.minX - startFrame.minX, endFrame.minY - startFrame.minY)
        return distance < minimumDistance ? .wobble : .move
    }

    /// The window under the pointer, front to back, never the dragged one.
    public static func target(
        at pointer: CGPoint,
        excluding draggedID: String,
        among candidates: [Candidate]
    ) -> String? {
        candidates.first { $0.id != draggedID && $0.frame.contains(pointer) }?.id
    }

    /// Each window takes the other's slot.
    public static func swappedSlots(dragged: Candidate, target: Candidate) -> [Candidate] {
        [
            Candidate(id: dragged.id, frame: target.frame),
            Candidate(id: target.id, frame: dragged.frame),
        ]
    }
}
