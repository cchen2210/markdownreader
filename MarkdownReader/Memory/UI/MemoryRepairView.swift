import SwiftUI

struct MemoryRepairView: View {
    @ObservedObject var session: MemoryRepairSession
    var onCommit: (MemoryRepairCommit) -> Void = { _ in }
    var onCancel: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.marginaliaAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            savedPassage

            switch session.mode {
            case .chooseLocation:
                candidateChooser
            case .reattachLooseSlip:
                reattachmentChooser
            }

            if let errorMessage = session.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.metadataInk)
                    .accessibilityLabel("Repair error. \(errorMessage)")
            }

            footer
        }
        .padding(22)
        .frame(minWidth: 420, idealWidth: 500, maxWidth: 560, alignment: .leading)
        .background(palette.paper)
        .foregroundStyle(palette.ink)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(session.mode == .chooseLocation ? "Choose a location" : "Reattach memory")
                .font(.system(size: 24, weight: .semibold, design: .serif))
            Text(
                session.mode == .chooseLocation
                    ? "The exact passage appears more than once. Nothing is selected yet."
                    : "Reattachment mode · select one passage in the source document."
            )
            .font(.system(size: 12.5))
            .foregroundStyle(palette.metadataInk)
        }
    }

    private var savedPassage: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Saved passage")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(palette.metadataInk)
                .textCase(.uppercase)
            Text("“\(session.savedPassage)”")
                .font(.system(size: 15, design: .serif))
                .italic()
                .lineSpacing(4)
                .textSelection(.enabled)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.sidebar, in: RoundedRectangle(cornerRadius: 7))
    }

    private var candidateChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(session.candidates) { candidate in
                Button {
                    session.selectCandidate(id: candidate.id)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(
                            systemName: session.selectedCandidateID == candidate.id
                                ? "largecircle.fill.circle"
                                : "circle"
                        )
                        .foregroundStyle(palette.accent)
                        .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.locationLabel)
                                .font(.system(size: 12, weight: .semibold))
                            Text("“\(candidate.passage)”")
                                .font(.system(size: 14, design: .serif))
                                .lineLimit(4)
                            if let heading = candidate.headingPath {
                                Text(heading)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(palette.metadataInk)
                            }
                            Text(candidate.evidenceLabel)
                                .font(.system(size: 11.5))
                                .foregroundStyle(palette.metadataInk)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        session.selectedCandidateID == candidate.id
                            ? palette.selectedFill
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(
                                session.selectedCandidateID == candidate.id
                                    ? palette.accent
                                    : palette.hairline,
                                lineWidth: session.selectedCandidateID == candidate.id ? 2 : 1
                            )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(candidate.locationLabel). \(candidate.passage). \(candidate.evidenceLabel)"
                )
                .accessibilityValue(
                    session.selectedCandidateID == candidate.id ? "Selected" : "Not selected"
                )
            }
        }
    }

    private var reattachmentChooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Selection alone never saves anything. Check the current selection, review it here, then choose Use Selection.")
                .font(.system(size: 12.5))
                .foregroundStyle(palette.secondaryInk)

            Button("Check Current Selection") {
                Task { await session.captureCurrentSelection() }
            }
            .disabled(session.isWorking || session.isCancelled || session.didCommit)

            if let quote = session.pendingSelectionQuote {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Ready to attach", systemImage: "checkmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.accent)
                    Text("“\(quote)”")
                        .font(.system(size: 14, design: .serif))
                        .lineLimit(5)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.selectedFill, in: RoundedRectangle(cornerRadius: 7))
            } else {
                Text("No valid source selection checked.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.metadataInk)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                session.cancel()
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(session.isWorking || session.didCommit)

            Spacer()

            if session.isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            Button(session.mode == .chooseLocation ? "Use this location" : "Use Selection") {
                Task {
                    let commit: MemoryRepairCommit?
                    switch session.mode {
                    case .chooseLocation:
                        commit = await session.commitSelectedCandidate()
                    case .reattachLooseSlip:
                        commit = await session.commitCurrentSelection()
                    }
                    if let commit { onCommit(commit) }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent)
            .disabled(
                session.mode == .chooseLocation
                    ? !session.canUseSelectedCandidate
                    : !session.canUseCurrentSelection
            )
            .keyboardShortcut(.defaultAction)
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
