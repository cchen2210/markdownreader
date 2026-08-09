import SwiftUI

struct MemoryInspectorView: View {
    let memories: [MemoryPresentation]
    @Binding var selection: UUID?
    var width: CGFloat = MemoryLayoutPolicy.inspectorWidth
    var onClose: () -> Void = {}
    var onSelect: (UUID) -> Void = { _ in }
    var onEditNote: (UUID) -> Void = { _ in }
    var onReviewLocation: (UUID) -> Void = { _ in }

    @State private var expandedAnchorID: UUID?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.marginaliaAppearance) private var appearance

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Memory")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.ink)
                Spacer()
                Text("\(memories.count) in this document")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.metadataInk)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close Memory Inspector")
                .accessibilityLabel("Close Memory Inspector")
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 45)
            .overlay(alignment: .bottom) { Divider().overlay(palette.hairline) }

            if memories.isEmpty {
                Spacer()
                MemoryEmptyStateView(
                    title: "Nothing kept here",
                    message: "Select a passage and choose Remember — or press ⌘⇧M.",
                    compact: true
                )
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(locatedMemories) { memory in
                            note(memory)
                        }

                        MemoryLooseSlipSection(
                            memories: unlocatedMemories,
                            selection: $selection,
                            compact: true,
                            onSelect: onSelect,
                            onEditNote: onEditNote,
                            onReviewLocation: onReviewLocation
                        )
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: width)
        .background(palette.sidebar)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(palette.hairline)
                .frame(width: isIncreasedContrast ? 1.5 : 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 16, x: -8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Memory inspector")
    }

    private func note(_ memory: MemoryPresentation) -> some View {
        MemoryNoteCard(
            memory: memory,
            isSelected: selection == memory.id,
            compact: true,
            showsAnchorDetails: anchorBinding(for: memory.id),
            onSelect: {
                selection = memory.id
                onSelect(memory.id)
            },
            onEditNote: { onEditNote(memory.id) },
            onReviewLocation: { onReviewLocation(memory.id) }
        )
    }

    private func anchorBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedAnchorID == id },
            set: { expandedAnchorID = $0 ? id : nil }
        )
    }

    private var locatedMemories: [MemoryPresentation] {
        memories.filter { !$0.state.isLooseSlip }
    }

    private var unlocatedMemories: [MemoryPresentation] {
        memories.filter(\.state.isLooseSlip)
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
