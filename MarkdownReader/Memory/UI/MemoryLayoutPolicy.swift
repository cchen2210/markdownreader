import CoreGraphics
import Foundation

/// Resolves the current-document Memory surface without borrowing width from
/// the reader's chosen text measure. This type is intentionally UI-framework
/// agnostic so breakpoint behavior can be tested without constructing a view.
struct MemoryLayoutPolicy: Equatable, Sendable {
    static let fullGutterWidth: CGFloat = 300
    static let minimumRailWidth: CGFloat = 160
    static let maximumRailWidth: CGFloat = 240
    static let inspectorWidth: CGFloat = 288
    static let defaultDocumentInsets: CGFloat = 48

    enum Mode: Equatable, Sendable {
        case hidden
        case fullGutter(width: CGFloat)
        case rail(width: CGFloat)
        case overlayInspector(width: CGFloat)

        var annotationWidth: CGFloat {
            switch self {
            case .hidden:
                return 0
            case let .fullGutter(width), let .rail(width), let .overlayInspector(width):
                return width
            }
        }

        var overlaysDocument: Bool {
            if case .overlayInspector = self { return true }
            return false
        }
    }

    let mode: Mode
    /// Width offered to the WebKit document viewport. Overlay inspectors do not
    /// reduce this value.
    let documentViewportWidth: CGFloat
    /// Width available for the chosen text measure after document insets.
    let availableTextWidth: CGFloat

    static func resolve(
        availableWidth: CGFloat,
        chosenTextMeasure: CGFloat,
        documentInsets: CGFloat = defaultDocumentInsets,
        showsMemorySurface: Bool = true
    ) -> MemoryLayoutPolicy {
        let availableWidth = max(0, availableWidth.isFinite ? availableWidth : 0)
        let chosenTextMeasure = max(0, chosenTextMeasure.isFinite ? chosenTextMeasure : 0)
        let documentInsets = max(0, documentInsets.isFinite ? documentInsets : 0)

        guard showsMemorySurface else {
            return result(
                mode: .hidden,
                availableWidth: availableWidth,
                documentInsets: documentInsets
            )
        }

        let protectedDocumentWidth = chosenTextMeasure + documentInsets
        let remainder = availableWidth - protectedDocumentWidth

        if remainder >= fullGutterWidth {
            return result(
                mode: .fullGutter(width: fullGutterWidth),
                availableWidth: availableWidth,
                documentInsets: documentInsets
            )
        }

        if remainder >= minimumRailWidth {
            return result(
                mode: .rail(width: min(maximumRailWidth, remainder)),
                availableWidth: availableWidth,
                documentInsets: documentInsets
            )
        }

        // The inspector overlays the page. It may occlude content while open,
        // but it never permanently narrows the reading measure.
        return result(
            mode: .overlayInspector(width: inspectorWidth),
            availableWidth: availableWidth,
            documentInsets: documentInsets
        )
    }

    private static func result(
        mode: Mode,
        availableWidth: CGFloat,
        documentInsets: CGFloat
    ) -> MemoryLayoutPolicy {
        let documentViewportWidth: CGFloat
        switch mode {
        case .hidden, .overlayInspector:
            documentViewportWidth = availableWidth
        case let .fullGutter(width), let .rail(width):
            documentViewportWidth = max(0, availableWidth - width)
        }

        return MemoryLayoutPolicy(
            mode: mode,
            documentViewportWidth: documentViewportWidth,
            availableTextWidth: max(0, documentViewportWidth - documentInsets)
        )
    }
}
