import SwiftUI

struct ReadingMemoryEntryView: View {
    let entry: ReadingMemoryEntryPresentation
    let isExpanded: Bool
    var onSelect: () -> Void = {}
    var onOpenMemory: () -> Void = {}
    var onOpenDocument: () -> Void = {}
    var onEditNote: () -> Void = {}
    var onReviewLocation: () -> Void = {}
    var onDelete: () -> Void = {}

    @State private var showsAnchorDetails = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.marginaliaAppearance) private var appearance

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            provenance
                .frame(width: 158, alignment: .trailing)

            content
                .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { showsAnchorDetails = false }
        }
        .contextMenu {
            Button("Open in Document", action: onOpenMemory)
            Button(entry.memory.hasNote ? "Edit Note…" : "Write a Note…", action: onEditNote)
            if entry.memory.state.needsAttention {
                Button(reviewActionTitle, action: onReviewLocation)
            }
            Divider()
            Button("Delete Memory", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.accessibilityLabel)
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
        .accessibilityAction(named: "Select", onSelect)
        .accessibilityAction(named: "Open in Document", onOpenMemory)
    }

    private var provenance: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if entry.documentID != nil {
                Button(entry.documentName, action: onOpenDocument)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.secondaryInk)
                    .multilineTextAlignment(.trailing)
                    .help("Open \(entry.documentName)")
            } else {
                Text(entry.documentName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.secondaryInk)
                    .multilineTextAlignment(.trailing)
            }

            if let parentFolder = entry.parentFolder, !parentFolder.isEmpty {
                Text(parentFolder)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let heading = effectiveHeading, !heading.isEmpty {
                Text(heading)
                    .lineLimit(2)
            }

            Text(entry.provenanceDate)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(palette.metadataInk)
        .multilineTextAlignment(.trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(provenanceAccessibilityLabel)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 11) {
            stateRule
                .frame(width: ruleWidth)

            VStack(alignment: .leading, spacing: isExpanded ? 11 : 7) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    MemoryStateMark(state: entry.memory.state, size: 9)

                    Text("· \(entry.memory.kind.label)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.metadataInk)

                    Spacer(minLength: 8)

                    if entry.memory.hasNote {
                        Text("NOTE")
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(palette.metadataInk)
                    }
                }

                if isExpanded {
                    expandedText
                    retainedMatchNote
                    expandedActions
                    anchorDetails
                } else {
                    collapsedText
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isExpanded ? 12 : 2)
        .padding(.vertical, isExpanded ? 12 : 7)
        .background {
            if isExpanded {
                RoundedRectangle(cornerRadius: 7)
                    .fill(palette.selectedFill)
            }
        }
        .overlay {
            if isExpanded {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(palette.accent, lineWidth: 2)
            }
        }
    }

    @ViewBuilder
    private var collapsedText: some View {
        if entry.memory.hasNote, let note = entry.memory.note {
            Text(note)
                .font(.system(size: 15, design: .serif))
                .foregroundStyle(palette.secondaryInk)
                .lineSpacing(3)
                .lineLimit(3)
        } else if let passage = entry.memory.passage, !passage.isEmpty {
            Text("“\(passage)”")
                .font(.system(size: 15, design: .serif))
                .foregroundStyle(palette.secondaryInk)
                .lineSpacing(3)
                .lineLimit(3)
        } else {
            Text(entry.memory.title)
                .font(.system(size: 15, weight: .medium, design: .serif))
                .foregroundStyle(palette.secondaryInk)
                .lineLimit(2)
        }
    }

    private var expandedText: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let passage = entry.memory.passage, !passage.isEmpty {
                Text("“\(passage)”")
                    .font(.system(size: 15.5, design: .serif))
                    .italic()
                    .foregroundStyle(palette.secondaryInk)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            } else if !entry.memory.hasNote {
                Text(entry.memory.title)
                    .font(.system(size: 16, weight: .medium, design: .serif))
                    .foregroundStyle(palette.ink)
                    .textSelection(.enabled)
            }

            if entry.memory.hasNote, let note = entry.memory.note {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your note")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(palette.metadataInk)
                    Text(note)
                        .font(.system(size: 15.5, design: .serif))
                        .foregroundStyle(palette.ink)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private var retainedMatchNote: some View {
        if let explanation = entry.retainedMatchExplanation, !explanation.isEmpty {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .accessibilityHidden(true)
                Text(explanation)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(palette.metadataInk)
            .accessibilityElement(children: .combine)
        }
    }

    private var expandedActions: some View {
        HStack(spacing: 14) {
            Button("Open in Document", action: onOpenMemory)
                .buttonStyle(.link)

            Button(entry.memory.hasNote ? "Edit Note…" : "Write a Note…", action: onEditNote)
                .buttonStyle(.link)

            if entry.memory.state.needsAttention {
                Button(reviewActionTitle, action: onReviewLocation)
                    .buttonStyle(.link)
            }
        }
        .font(.system(size: 12.5))
    }

    @ViewBuilder
    private var anchorDetails: some View {
        if entry.memory.anchorDetails != nil {
            Divider()
                .overlay(palette.hairline)

            DisclosureGroup("Anchor details", isExpanded: $showsAnchorDetails) {
                MemoryAnchorDetailsView(memory: entry.memory)
                    .padding(.top, 7)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(palette.secondaryInk)
        }
    }

    @ViewBuilder
    private var stateRule: some View {
        switch entry.memory.state {
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
                .opacity(accessibilityContrast == .increased ? 1 : 0.72)
        }
    }

    private var effectiveHeading: String? {
        entry.heading ?? entry.memory.headingPath
    }

    private var reviewActionTitle: String {
        switch entry.memory.state {
        case .chooseLocation: "Review Locations…"
        case .needsRepair: "Reattach…"
        case .resolved: "Review Location…"
        }
    }

    private var provenanceAccessibilityLabel: String {
        var components = ["From \(entry.documentName)"]
        if let heading = effectiveHeading, !heading.isEmpty {
            components.append("under \(heading)")
        }
        components.append(entry.provenanceDate)
        return components.joined(separator: ", ")
    }

    private var ruleWidth: CGFloat {
        accessibilityContrast == .increased ? 3 : 2
    }

    private var palette: MarginaliaPalette {
        MarginaliaPalette.resolve(
            appearance: appearance,
            systemColorScheme: colorScheme,
            increasedContrast: accessibilityContrast == .increased
        )
    }
}
