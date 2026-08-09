import SwiftUI

struct MemoryGutterView: View {
    let placements: [MemoryGutterPlacement]
    let unlocatedMemories: [MemoryPresentation]
    @Binding var selection: UUID?
    let width: CGFloat
    let viewportHeight: CGFloat
    let canvasHeight: CGFloat
    let scrollOffset: CGFloat
    let looseSlipTop: CGFloat
    var compact = false
    var onSelect: (UUID) -> Void = { _ in }
    var onEditNote: (UUID) -> Void = { _ in }
    var onReviewLocation: (UUID) -> Void = { _ in }
    var onMeasuredNoteHeights: ([UUID: CGFloat]) -> Void = { _ in }
    var onMeasuredLooseSlipHeight: (CGFloat) -> Void = { _ in }

    @State private var expandedAnchorID: UUID?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.marginaliaAppearance) private var appearance

    var body: some View {
        ZStack(alignment: .topLeading) {
            palette.paper

            annotationCanvas
                .offset(y: -effectiveScrollOffset)
        }
        .frame(width: width, height: max(0, viewportHeight), alignment: .topLeading)
        .clipped()
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(palette.hairline)
                .frame(width: isIncreasedContrast ? 1.5 : 1)
        }
        .onPreferenceChange(MemoryNoteHeightPreferenceKey.self, perform: onMeasuredNoteHeights)
        .onPreferenceChange(MemoryLooseSlipHeightPreferenceKey.self, perform: onMeasuredLooseSlipHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var annotationCanvas: some View {
        ZStack(alignment: .topLeading) {
            ForEach(marginPlacements) { placement in
                leader(for: placement)
                MemoryNoteCard(
                    memory: placement.memory,
                    isSelected: selection == placement.id,
                    compact: compact,
                    showsAnchorDetails: anchorBinding(for: placement.id),
                    onSelect: {
                        selection = placement.id
                        onSelect(placement.id)
                    },
                    onEditNote: { onEditNote(placement.id) }
                )
                .frame(width: max(80, width - 28), alignment: .leading)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: MemoryNoteHeightPreferenceKey.self,
                            value: [placement.id: proxy.size.height]
                        )
                    }
                }
                .offset(x: 18, y: placement.noteY)
                .accessibilitySortPriority(Double(marginPlacements.count - placementIndex(placement)))
            }

            MemoryLooseSlipSection(
                memories: unlocatedMemories,
                selection: $selection,
                compact: compact,
                onSelect: onSelect,
                onEditNote: onEditNote,
                onReviewLocation: onReviewLocation
            )
            .frame(width: max(80, width - 28), alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MemoryLooseSlipHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
            .offset(x: 18, y: max(0, looseSlipTop))
        }
        .frame(
            width: width,
            height: max(max(0, viewportHeight), max(0, canvasHeight)),
            alignment: .topLeading
        )
    }

    private func leader(for placement: MemoryGutterPlacement) -> some View {
        MemoryLeader(
            anchorY: placement.anchorY,
            noteY: placement.noteY,
            color: palette.accent.opacity(selection == placement.id ? 0.55 : 0.32),
            lineWidth: isIncreasedContrast ? 2 : 1,
            isDashed: placement.memory.state.needsAttention
        )
        .frame(width: 18, height: max(max(0, viewportHeight), max(0, canvasHeight)), alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private var effectiveScrollOffset: CGFloat {
        let maximum = max(0, canvasHeight - viewportHeight)
        return min(max(0, scrollOffset), maximum)
    }

    private func anchorBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedAnchorID == id },
            set: { expandedAnchorID = $0 ? id : nil }
        )
    }

    private var marginPlacements: [MemoryGutterPlacement] {
        placements
    }

    private func placementIndex(_ placement: MemoryGutterPlacement) -> Int {
        marginPlacements.firstIndex(where: { $0.id == placement.id }) ?? 0
    }

    private var accessibilityLabel: String {
        let count = marginPlacements.count + unlocatedMemories.count
        guard count > 0 else { return "Margin, empty. No remembered passages in this document." }
        return "Margin, \(count) remembered \(count == 1 ? "passage" : "passages")."
    }

    private var isIncreasedContrast: Bool {
        accessibilityContrast == .increased
    }

    private var palette: MarginaliaPalette {
        MarginaliaPalette.resolve(
            appearance: appearance,
            systemColorScheme: colorScheme,
            increasedContrast: isIncreasedContrast
        )
    }
}

private struct MemoryNoteHeightPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct MemoryLooseSlipHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MemoryLeader: View {
    let anchorY: CGFloat
    let noteY: CGFloat
    let color: Color
    let lineWidth: CGFloat
    let isDashed: Bool

    var body: some View {
        Canvas { context, size in
            let startY = max(0, min(anchorY, size.height))
            let endY = max(0, min(noteY + 13, size.height))
            var path = Path()
            path.move(to: CGPoint(x: 0, y: startY))
            path.addLine(to: CGPoint(x: size.width - 4, y: startY))
            if abs(endY - startY) > 0.5 {
                path.addLine(to: CGPoint(x: size.width - 4, y: endY))
            }
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: lineWidth, dash: isDashed ? [4, 3] : [])
            )
        }
    }
}
