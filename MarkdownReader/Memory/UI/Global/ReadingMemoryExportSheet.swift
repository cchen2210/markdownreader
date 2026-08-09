import SwiftUI

enum ReadingMemoryExportFormat: String, CaseIterable, Hashable, Identifiable, Sendable {
    case markdown
    case json

    var id: Self { self }

    var label: String {
        switch self {
        case .markdown: "Markdown"
        case .json: "JSON"
        }
    }

    var fileExtension: String { rawValue == "markdown" ? "md" : "json" }
}

enum ReadingMemoryExportInclude: String, CaseIterable, Hashable, Identifiable, Sendable {
    case allMemories
    case currentFilter
    case selection
    case needsRepair

    var id: Self { self }

    var label: String {
        switch self {
        case .allMemories: "All memories"
        case .currentFilter: "Current filter"
        case .selection: "Selected memories"
        case .needsRepair: "Memories needing attention"
        }
    }
}

struct ReadingMemoryExportConfiguration: Equatable, Sendable {
    var format: ReadingMemoryExportFormat
    var include: ReadingMemoryExportInclude
    var includesNotes: Bool
    var includesRepairLabels: Bool
    var includesAnchorDetails: Bool
    var groupsByDocument: Bool
    var includesFileLocations: Bool

    init(
        format: ReadingMemoryExportFormat = .markdown,
        include: ReadingMemoryExportInclude = .allMemories,
        includesNotes: Bool = true,
        includesRepairLabels: Bool = true,
        includesAnchorDetails: Bool = false,
        groupsByDocument: Bool = true,
        includesFileLocations: Bool = false
    ) {
        self.format = format
        self.include = include
        self.includesNotes = includesNotes
        self.includesRepairLabels = includesRepairLabels
        self.includesAnchorDetails = includesAnchorDetails
        self.groupsByDocument = groupsByDocument
        self.includesFileLocations = includesFileLocations
    }

    var normalizedForExport: Self {
        var copy = self
        if copy.format == .json {
            copy.includesNotes = true
            copy.includesRepairLabels = true
            copy.includesAnchorDetails = true
            copy.groupsByDocument = true
        }
        return copy
    }
}

struct ReadingMemoryExportPreview: Equatable, Sendable {
    let renderedConfiguration: ReadingMemoryExportConfiguration?
    let data: Data?
    let itemCount: Int
    let isPreparing: Bool
    let errorMessage: String?

    init(
        renderedConfiguration: ReadingMemoryExportConfiguration? = nil,
        data: Data? = nil,
        itemCount: Int = 0,
        isPreparing: Bool = false,
        errorMessage: String? = nil
    ) {
        self.renderedConfiguration = renderedConfiguration?.normalizedForExport
        self.data = data
        self.itemCount = max(0, itemCount)
        self.isPreparing = isPreparing
        self.errorMessage = errorMessage
    }

    var displayText: String {
        guard let data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct ReadingMemoryExportActions {
    var requestPreview: (ReadingMemoryExportConfiguration) -> Void
    var save: (Data, ReadingMemoryExportConfiguration) -> Void
    var cancel: () -> Void

    init(
        requestPreview: @escaping (ReadingMemoryExportConfiguration) -> Void = { _ in },
        save: @escaping (Data, ReadingMemoryExportConfiguration) -> Void = { _, _ in },
        cancel: @escaping () -> Void = {}
    ) {
        self.requestPreview = requestPreview
        self.save = save
        self.cancel = cancel
    }
}

struct ReadingMemoryExportSheet: View {
    @Binding var configuration: ReadingMemoryExportConfiguration
    let preview: ReadingMemoryExportPreview
    let actions: ReadingMemoryExportActions
    var onDismiss: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.marginaliaAppearance) private var appearance

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Export Reading Memory")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundStyle(palette.ink)
                Spacer()
                Text(".\(activeConfiguration.format.fileExtension)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(palette.metadataInk)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 17)

            Divider()
                .overlay(palette.hairline)

            HStack(alignment: .top, spacing: 0) {
                options
                    .frame(width: 280)
                    .padding(20)

                Divider()
                    .overlay(palette.hairline)

                previewPane
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            }

            Divider()
                .overlay(palette.hairline)

            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 13)
        }
        .frame(minWidth: 720, minHeight: 540)
        .background(palette.paper)
        .task(id: activeConfiguration) {
            guard preview.renderedConfiguration != activeConfiguration || preview.data == nil else {
                return
            }
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                actions.requestPreview(activeConfiguration)
            } catch {
                // A newer option set superseded this preview request.
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 17) {
            optionGroup("FORMAT") {
                Picker("Format", selection: $configuration.format) {
                    ForEach(ReadingMemoryExportFormat.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(formatExplanation)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.metadataInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            optionGroup("INCLUDE") {
                Picker("Include", selection: $configuration.include) {
                    ForEach(ReadingMemoryExportInclude.allCases) { include in
                        Text(include.label).tag(include)
                    }
                }
                .labelsHidden()

                Toggle("Notes", isOn: $configuration.includesNotes)
                    .disabled(configuration.format == .json)
                Toggle("Repair labels", isOn: $configuration.includesRepairLabels)
                    .disabled(configuration.format == .json)
                Toggle("Anchor details", isOn: anchorDetailsBinding)
                    .disabled(configuration.format == .json)
                Toggle("Group by document", isOn: $configuration.groupsByDocument)
                    .disabled(configuration.format == .json)
                Toggle("File locations", isOn: $configuration.includesFileLocations)
            }

            if configuration.includesFileLocations {
                Text("File locations can reveal folder names and account names on this Mac.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.accentLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .toggleStyle(.checkbox)
        .foregroundStyle(palette.secondaryInk)
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("PREVIEW")
                    .font(.system(size: 11.5, weight: .semibold))
                    .tracking(0.65)
                    .foregroundStyle(palette.metadataInk)

                Spacer()

                Text(previewStatus)
                    .font(.system(size: 11.5))
                    .foregroundStyle(previewIsCurrent ? palette.metadataInk : palette.accentLabel)
            }

            Group {
                if preview.isPreparing {
                    ProgressView("Preparing exact export bytes…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = preview.errorMessage {
                    MemoryEmptyStateView(
                        title: "Preview unavailable",
                        message: errorMessage,
                        actionTitle: "Try Again",
                        action: { actions.requestPreview(activeConfiguration) },
                        compact: true
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if previewIsCurrent, !preview.displayText.isEmpty {
                    ScrollView([.horizontal, .vertical]) {
                        Text(preview.displayText)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(palette.secondaryInk)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(12)
                    }
                } else {
                    MemoryEmptyStateView(
                        title: preview.data == nil ? "Preparing preview" : "Preview is out of date",
                        message: "Save stays unavailable until the preview matches these options.",
                        compact: true
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(palette.sidebar.opacity(0.55))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(palette.hairline, lineWidth: accessibilityContrast == .increased ? 2 : 1)
            }

            Text("The preview is decoded from the exact UTF-8 bytes passed to Save.")
                .font(.system(size: 11.5))
                .foregroundStyle(palette.metadataInk)
        }
    }

    private var footer: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(archiveExplanation)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(palette.secondaryInk)
                Text("The app makes no network transfer. Data leaves app storage only through an export you choose.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.metadataInk)
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            Button("Cancel") {
                actions.cancel()
                onDismiss()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Save…") {
                guard let data = preview.data, previewIsCurrent else { return }
                actions.save(data, activeConfiguration)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
    }

    private func optionGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(0.65)
                .foregroundStyle(palette.metadataInk)
            content()
        }
    }

    private var anchorDetailsBinding: Binding<Bool> {
        Binding(
            get: { activeConfiguration.includesAnchorDetails },
            set: { configuration.includesAnchorDetails = $0 }
        )
    }

    private var activeConfiguration: ReadingMemoryExportConfiguration {
        configuration.normalizedForExport
    }

    private var previewIsCurrent: Bool {
        preview.renderedConfiguration == activeConfiguration && preview.data != nil && !preview.isPreparing
    }

    private var canSave: Bool {
        previewIsCurrent && preview.errorMessage == nil
    }

    private var previewStatus: String {
        if preview.isPreparing { return "Preparing…" }
        if preview.errorMessage != nil { return "Could not prepare" }
        if !previewIsCurrent { return "Options changed" }
        let bytes = preview.data?.count ?? 0
        let items = preview.itemCount
        return "\(items) \(items == 1 ? "memory" : "memories") · \(bytes) bytes"
    }

    private var formatExplanation: String {
        switch configuration.format {
        case .markdown:
            "A human-readable reading notebook. It is deliberately not importable."
        case .json:
            "A versioned, machine-readable archive with anchor evidence."
        }
    }

    private var archiveExplanation: String {
        switch configuration.format {
        case .markdown:
            "Markdown is for reading and sharing. It is not an app backup and cannot be imported."
        case .json:
            "JSON preserves your memories and their anchor evidence. Import and document re-linking are not part of this release."
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
