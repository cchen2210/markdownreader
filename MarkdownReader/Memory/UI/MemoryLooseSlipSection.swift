import SwiftUI

struct MemoryLooseSlipSection: View {
    let memories: [MemoryPresentation]
    @Binding var selection: UUID?
    var compact = false
    var onSelect: (UUID) -> Void = { _ in }
    var onEditNote: (UUID) -> Void = { _ in }
    var onReviewLocation: (UUID) -> Void = { _ in }

    @State private var expandedAnchorID: UUID?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.marginaliaAppearance) private var appearance

    var body: some View {
        if !memories.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                DashedMemoryRule(color: palette.metadataInk)
                    .frame(height: isIncreasedContrast ? 2 : 1)

                Text(sectionTitle)
                    .font(.system(size: 11.5, weight: .semibold))
                    .tracking(0.7)
                    .textCase(.uppercase)
                    .foregroundStyle(palette.metadataInk)

                ForEach(memories) { memory in
                    MemoryNoteCard(
                        memory: memory,
                        isSelected: selection == memory.id,
                        compact: compact,
                        showsAnchorDetails: anchorBinding(for: memory.id),
                        onSelect: {
                            selection = memory.id
                            onSelect(memory.id)
                        },
                        onEditNote: { onEditNote(memory.id) },
                        onReviewLocation: { onReviewLocation(memory.id) }
                    )
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(sectionTitle), \(memories.count)")
        }
    }

    private func anchorBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedAnchorID == id },
            set: { expandedAnchorID = $0 ? id : nil }
        )
    }

    private var sectionTitle: String {
        memories.allSatisfy(\.state.isLooseSlip) ? "Loose slips" : "Waiting on you"
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

private struct DashedMemoryRule: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: proxy.size.height / 2))
                path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height / 2))
            }
            .stroke(color, style: StrokeStyle(lineWidth: proxy.size.height, dash: [5, 4]))
        }
        .accessibilityHidden(true)
    }
}
