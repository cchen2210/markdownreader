import SwiftUI

struct CurrentDocumentMemorySidebar: View {
    let memories: [MemoryPresentation]
    @Binding var selection: UUID?
    @Binding var searchText: String
    var onSelect: (UUID) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.marginaliaAppearance) private var appearance

    var body: some View {
        Group {
            if memories.isEmpty {
                MemoryEmptyStateView(
                    title: "Nothing kept here",
                    message: "Select a passage and choose Remember — or press ⌘⇧M.",
                    compact: true
                )
            } else if filteredMemories.isEmpty {
                MemoryEmptyStateView(
                    title: "No matches",
                    message: "Try another passage, note, or heading.",
                    compact: true
                )
            } else {
                List(selection: $selection) {
                    if !locatedMemories.isEmpty {
                        Section("In this document") {
                            rows(locatedMemories)
                        }
                    }

                    if !attentionMemories.isEmpty {
                        Section("Waiting on you · \(attentionMemories.count)") {
                            rows(attentionMemories)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search this document")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text("\(memories.count) \(memories.count == 1 ? "memory" : "memories")")
                Spacer()
                if attentionCount > 0 {
                    Text("\(attentionCount) need attention")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(palette.metadataInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(palette.sidebar)
            .overlay(alignment: .top) { Divider().overlay(palette.hairline) }
        }
        .navigationTitle("Memory")
        .frame(minWidth: 200, idealWidth: 248, maxWidth: 360)
        .background(palette.sidebar)
    }

    @ViewBuilder
    private func rows(_ rows: [MemoryPresentation]) -> some View {
        ForEach(rows) { memory in
            MemorySidebarRow(memory: memory, isSelected: selection == memory.id)
                .tag(memory.id)
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = memory.id
                    onSelect(memory.id)
                }
        }
    }

    private var filteredMemories: [MemoryPresentation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return memories }
        return memories.filter { memory in
            [memory.title, memory.passage, memory.note, memory.headingPath]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var locatedMemories: [MemoryPresentation] {
        filteredMemories.filter { !$0.state.needsAttention }
    }

    private var attentionMemories: [MemoryPresentation] {
        filteredMemories.filter(\.state.needsAttention)
    }

    private var attentionCount: Int {
        memories.lazy.filter(\.state.needsAttention).count
    }

    private var palette: MarginaliaPalette {
        MarginaliaPalette.resolve(
            appearance: appearance,
            systemColorScheme: colorScheme,
            increasedContrast: accessibilityContrast == .increased
        )
    }
}

private struct MemorySidebarRow: View {
    let memory: MemoryPresentation
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.marginaliaAppearance) private var appearance

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            MemoryStateMark(state: memory.state, size: 8, showsLabel: false)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                Text(memory.title)
                    .font(.system(size: 14.5, weight: isSelected ? .semibold : .regular, design: .serif))
                    .foregroundStyle(palette.ink)
                    .lineLimit(2)

                Text(metadata)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.metadataInk)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(memory.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var metadata: String {
        var values = [memory.state.shortLabel]
        if memory.hasNote { values.append("note") }
        values.append(memory.savedAt)
        return values.joined(separator: " · ")
    }

    private var palette: MarginaliaPalette {
        MarginaliaPalette.resolve(
            appearance: appearance,
            systemColorScheme: colorScheme,
            increasedContrast: accessibilityContrast == .increased
        )
    }
}
