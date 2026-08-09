import SwiftUI

struct DocumentRelinkConfirmationView: View {
    let proposal: DocumentRelinkProposal
    let isConfirming: Bool
    let confirmLabel: String
    let alternativeLabel: String?
    let onConfirm: () -> Void
    let onAlternative: (() -> Void)?
    let onCancel: () -> Void

    init(
        proposal: DocumentRelinkProposal,
        isConfirming: Bool,
        confirmLabel: String = "Confirm Relink",
        alternativeLabel: String? = nil,
        onConfirm: @escaping () -> Void,
        onAlternative: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.proposal = proposal
        self.isConfirming = isConfirming
        self.confirmLabel = confirmLabel
        self.alternativeLabel = alternativeLabel
        self.onConfirm = onConfirm
        self.onAlternative = onAlternative
        self.onCancel = onCancel
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.marginaliaAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Confirm original document")
                    .font(.system(size: 24, weight: .semibold, design: .serif))
                Text("Review the file identity before changing \(proposal.documentDisplayName). Nothing has been relinked yet.")
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(palette.secondaryInk)
            }

            pathEvidence
            identityEvidence
            hashEvidence
            recoveryEvidence

            if !proposal.conflictingDocumentIDs.isEmpty {
                Label(
                    "This candidate is already registered to another record. Reading Memory will not merge them.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(palette.accentLabel)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isConfirming)
                Spacer()
                if isConfirming {
                    ProgressView()
                        .controlSize(.small)
                }
                if let alternativeLabel, let onAlternative {
                    Button(alternativeLabel, action: onAlternative)
                        .disabled(isConfirming || !proposal.canConfirm)
                }
                Button(confirmLabel, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isConfirming || !proposal.canConfirm)
            }
        }
        .padding(24)
        .frame(minWidth: 540, idealWidth: 600, maxWidth: 660, alignment: .leading)
        .background(palette.paper)
        .interactiveDismissDisabled(true)
    }

    private var pathEvidence: some View {
        evidenceGroup("Paths") {
            evidenceRow("Previously registered", proposal.oldPath.path, monospace: true)
            evidenceRow("Selected candidate", proposal.candidatePath.path, monospace: true)
        }
    }

    private var identityEvidence: some View {
        evidenceGroup("File identity") {
            evidenceRow("Registered", proposal.storedIdentityFingerprint, monospace: true)
            evidenceRow("Candidate", proposal.candidateIdentityFingerprint, monospace: true)
            evidenceRow("Assessment", proposal.identitiesMatch ? "Same filesystem identity" : "Different filesystem identity")
        }
    }

    private var hashEvidence: some View {
        evidenceGroup("Content hash") {
            evidenceRow("Last confirmed", proposal.storedContentHash ?? "Not recorded", monospace: true)
            evidenceRow("Candidate", proposal.candidateContentHash, monospace: true)
            evidenceRow("Assessment", proposal.hashesMatch ? "Exact byte hash matches" : "Content has changed")
        }
    }

    private var recoveryEvidence: some View {
        evidenceGroup("Memory recovery preview") {
            evidenceRow("Saved memories", "\(proposal.recovery.memoryCount)")
            evidenceRow("Exact-policy result", proposal.recovery.summary)
        }
    }

    private func evidenceGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(palette.metadataInk)
            VStack(alignment: .leading, spacing: 7, content: content)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.sidebar, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func evidenceRow(
        _ label: String,
        _ value: String,
        monospace: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(palette.metadataInk)
            Text(value)
                .font(monospace ? .system(size: 11.5, design: .monospaced) : .system(size: 13, design: .serif))
                .foregroundStyle(palette.ink)
                .textSelection(.enabled)
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
