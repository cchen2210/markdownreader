import SwiftUI

struct ReadingMemorySidebar: View {
    @Binding var selection: ReadingMemoryFacet
    let counts: ReadingMemorySidebarCounts
    var onSelect: (ReadingMemoryFacet) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.marginaliaAppearance) private var appearance

    var body: some View {
        List(selection: $selection) {
            facetSection(.library)
            facetSection(.kinds)
            facetSection(.attention)
        }
        .listStyle(.sidebar)
        .navigationTitle("Reading Memory")
        .navigationSplitViewColumnWidth(min: 220, ideal: 244, max: 300)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text(totalLabel)
                Spacer(minLength: 8)
                if attentionCount > 0 {
                    Text("\(attentionCount) need attention")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(palette.metadataInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(palette.sidebar)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(palette.hairline)
                    .frame(height: accessibilityContrast == .increased ? 2 : 1)
            }
        }
        .background(palette.sidebar)
        .onChange(of: selection) { _, facet in
            onSelect(facet)
        }
    }

    @ViewBuilder
    private func facetSection(_ group: ReadingMemoryFacet.Group) -> some View {
        Section(group.rawValue) {
            ForEach(ReadingMemoryFacet.allCases.filter { $0.group == group }) { facet in
                ReadingMemorySidebarRow(
                    facet: facet,
                    count: counts.count(for: facet),
                    isSelected: selection == facet
                )
                .tag(facet)
            }
        }
    }

    private var attentionCount: Int {
        counts.count(for: .chooseLocation) + counts.count(for: .needsRepair)
    }

    private var totalLabel: String {
        let total = counts.count(for: .allMemories)
        return "\(total) \(total == 1 ? "memory" : "memories")"
    }

    private var palette: MarginaliaPalette {
        MarginaliaPalette.resolve(
            appearance: appearance,
            systemColorScheme: colorScheme,
            increasedContrast: accessibilityContrast == .increased
        )
    }
}
private struct ReadingMemorySidebarRow: View {
    let facet: ReadingMemoryFacet
    let count: Int
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.marginaliaAppearance) private var appearance

    var body: some View {
        HStack(spacing: 8) {
            if let state = attentionState {
                MemoryStateMark(state: state, size: 8, showsLabel: false)
            }

            Text(facet.label)
                .foregroundStyle(palette.ink)

            Spacer(minLength: 8)

            Text(count, format: .number)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(palette.metadataInk)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background {
                    Capsule()
                        .fill(isSelected ? palette.paper.opacity(0.72) : Color.clear)
                }
        }
        .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(facet.label), \(count) \(count == 1 ? "item" : "items")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var attentionState: MemoryPresentation.State? {
        switch facet {
        case .chooseLocation:
            .chooseLocation(candidateCount: count)
        case .needsRepair:
            .needsRepair(hasProposedLocation: false)
        default:
            nil
        }
    }

    private var palette: MarginaliaPalette {
        MarginaliaPalette.resolve(
            appearance: appearance,
            systemColorScheme: colorScheme,
            increasedContrast: accessibilityContrast == .increased
        )
    }
}
