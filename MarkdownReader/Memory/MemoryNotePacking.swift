import CoreGraphics
import Foundation

struct MemoryNoteLayoutInput: Equatable, Sendable {
    let id: UUID
    let desiredTop: CGFloat
    let height: CGFloat
}

struct MemoryNoteLayout: Equatable, Sendable {
    let id: UUID
    let desiredTop: CGFloat
    let top: CGFloat
    let height: CGFloat

    var bottom: CGFloat { top + height }
    var leaderDrop: CGFloat { max(0, top - desiredTop) }
}

enum MemoryNotePacking {
    static let collisionSpacing: CGFloat = 12
    static let scrollReachabilityPadding: CGFloat = 24

    /// Packs notes downward in one stable pass. Prose remains fixed; callers may
    /// extend only their native bottom inset when the final note overflows.
    static func pack(
        _ inputs: [MemoryNoteLayoutInput],
        minimumTop: CGFloat = 0,
        spacing: CGFloat = collisionSpacing
    ) -> [MemoryNoteLayout] {
        let ordered = inputs.enumerated().sorted { left, right in
            if left.element.desiredTop == right.element.desiredTop {
                return left.offset < right.offset
            }
            return left.element.desiredTop < right.element.desiredTop
        }

        var priorBottom = minimumTop - spacing
        return ordered.map { _, input in
            let top = max(minimumTop, input.desiredTop, priorBottom + spacing)
            let layout = MemoryNoteLayout(
                id: input.id,
                desiredTop: input.desiredTop,
                top: top,
                height: max(0, input.height)
            )
            priorBottom = layout.bottom
            return layout
        }
    }

    /// Returns the extra WebKit scroll extent required for the final packed
    /// note to clear the bottom of the viewport. `baseDocumentHeight` must not
    /// include an earlier Marginalia inset.
    static func requiredBottomInset(
        contentBottom: CGFloat,
        baseDocumentHeight: CGFloat,
        bottomPadding: CGFloat = scrollReachabilityPadding
    ) -> CGFloat {
        let contentBottom = contentBottom.isFinite ? max(0, contentBottom) : 0
        let baseDocumentHeight = baseDocumentHeight.isFinite ? max(0, baseDocumentHeight) : 0
        let bottomPadding = bottomPadding.isFinite ? max(0, bottomPadding) : 0
        return max(0, contentBottom + bottomPadding - baseDocumentHeight)
    }
}
