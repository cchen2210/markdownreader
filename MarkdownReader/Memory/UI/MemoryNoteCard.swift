import SwiftUI

struct MemoryNoteCard: View {
    let memory: MemoryPresentation
    let isSelected: Bool
    var compact = false
    var showsAnchorDetails: Binding<Bool> = .constant(false)
    var onSelect: () -> Void = {}
    var onEditNote: () -> Void = {}
    var onReviewLocation: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.marginaliaAppearance) private var appearance

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            stateRule
                .frame(width: ruleWidth)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    MemoryStateMark(state: memory.state, size: 9)
                    Text("· \(memory.kind.label)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.metadataInk)
                }

                primaryText

                if case .chooseLocation = memory.state,
                   !memory.candidateLocations.isEmpty {
                    candidateLocations
                }

                Text(memory.savedAt)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.metadataInk)

                action

                if memory.anchorDetails != nil, isSelected {
                    Divider()
                        .overlay(palette.hairline)
                    DisclosureGroup("Anchor details", isExpanded: showsAnchorDetails) {
                        MemoryAnchorDetailsView(memory: memory)
                            .padding(.top, 7)
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(palette.secondaryInk)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isSelected ? 10 : 2)
        .padding(.vertical, isSelected ? 10 : 4)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7)
                    .fill(palette.selectedFill)
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(palette.accent, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onChange(of: isSelected) { _, selected in
            if !selected {
                showsAnchorDetails.wrappedValue = false
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(memory.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction(named: "Select", onSelect)
    }

    private var candidateLocations: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(memory.candidateLocations) { candidate in
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.headingPath ?? candidate.locationLabel)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(palette.ink)
                    Text("“\(candidate.passage)”")
                        .font(.system(size: 13.5, design: .serif))
                        .foregroundStyle(palette.secondaryInk)
                        .lineLimit(compact && !isSelected ? 2 : nil)
                    Text(candidate.locationLabel)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.metadataInk)
                }
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(palette.hairline)
                        .frame(width: 1)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Candidate locations")
    }

    @ViewBuilder
    private var primaryText: some View {
        if memory.hasNote, let note = memory.note {
            Text(note)
                .font(.system(size: isSelected ? 15 : 14.5, design: .serif))
                .lineSpacing(4)
                .foregroundStyle(isSelected ? palette.ink : palette.secondaryInk)
                .lineLimit(compact && !isSelected ? 3 : nil)
                .textSelection(.enabled)
        } else if let passage = memory.passage, !passage.isEmpty {
            Text("“\(passage)”")
                .font(.system(size: 14.5, design: .serif))
                .italic(!isIncreasedContrast && memory.state.isLooseSlip)
                .foregroundStyle(palette.secondaryInk)
                .lineLimit(compact && !isSelected ? 3 : nil)
                .textSelection(.enabled)
        } else {
            Text(memory.title)
                .font(.system(size: 14.5, weight: .medium, design: .serif))
                .foregroundStyle(palette.secondaryInk)
                .lineLimit(compact ? 2 : nil)
        }
    }

    @ViewBuilder
    private var action: some View {
        HStack(spacing: 12) {
            Button(memory.hasNote ? "Edit note…" : "Write a note", action: onEditNote)
                .buttonStyle(.link)

            switch memory.state {
            case .chooseLocation:
                Button("Review locations…", action: onReviewLocation)
                    .buttonStyle(.link)
            case .needsRepair:
                Button("Reattach…", action: onReviewLocation)
                    .buttonStyle(.link)
            case .resolved:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var stateRule: some View {
        switch memory.state {
        case .resolved:
            Rectangle()
                .fill(palette.accent)
        case .chooseLocation:
            Rectangle()
                .stroke(
                    palette.accent,
                    style: StrokeStyle(lineWidth: ruleWidth, dash: [4, 3])
                )
        case .needsRepair:
            Rectangle()
                .fill(palette.metadataInk)
                .opacity(isIncreasedContrast ? 1 : 0.7)
        }
    }

    private var ruleWidth: CGFloat {
        isIncreasedContrast ? 3 : 2
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
