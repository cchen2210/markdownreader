import SwiftUI

/// Store-independent two-pane commonplace book. The caller supplies already
/// ordered projections and owns every repository or document-opening action.
struct ReadingMemoryView: View {
    @Binding private var facet: ReadingMemoryFacet
    @Binding private var searchText: String
    @Binding private var searchScope: ReadingMemorySearchScope
    @Binding private var selectedMemoryID: UUID?
    @Binding private var selectedDocumentID: UUID?
    @Binding private var showsExportSheet: Bool
    @Binding private var exportConfiguration: ReadingMemoryExportConfiguration

    private let counts: ReadingMemorySidebarCounts
    private let memories: [ReadingMemoryEntryPresentation]
    private let documents: [ReadingDocumentPresentation]
    private let searchSummary: ReadingMemorySearchSummary?
    private let isLoading: Bool
    private let actions: ReadingMemoryActions
    private let exportPreview: ReadingMemoryExportPreview
    private let exportActions: ReadingMemoryExportActions

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @Environment(\.marginaliaAppearance) private var appearance

    init(
        facet: Binding<ReadingMemoryFacet>,
        searchText: Binding<String>,
        searchScope: Binding<ReadingMemorySearchScope>,
        selectedMemoryID: Binding<UUID?>,
        selectedDocumentID: Binding<UUID?>,
        showsExportSheet: Binding<Bool>,
        exportConfiguration: Binding<ReadingMemoryExportConfiguration>,
        counts: ReadingMemorySidebarCounts,
        memories: [ReadingMemoryEntryPresentation],
        documents: [ReadingDocumentPresentation],
        searchSummary: ReadingMemorySearchSummary? = nil,
        isLoading: Bool = false,
        actions: ReadingMemoryActions = ReadingMemoryActions(),
        exportPreview: ReadingMemoryExportPreview = ReadingMemoryExportPreview(),
        exportActions: ReadingMemoryExportActions = ReadingMemoryExportActions()
    ) {
        _facet = facet
        _searchText = searchText
        _searchScope = searchScope
        _selectedMemoryID = selectedMemoryID
        _selectedDocumentID = selectedDocumentID
        _showsExportSheet = showsExportSheet
        _exportConfiguration = exportConfiguration
        self.counts = counts
        self.memories = memories
        self.documents = documents
        self.searchSummary = searchSummary
        self.isLoading = isLoading
        self.actions = actions
        self.exportPreview = exportPreview
        self.exportActions = exportActions
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ReadingMemorySidebar(
                selection: $facet,
                counts: counts,
                onSelect: actions.selectFacet
            )
        } detail: {
            VStack(spacing: 0) {
                header

                Rectangle()
                    .fill(palette.hairline)
                    .frame(height: accessibilityContrast == .increased ? 2 : 1)

                results
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.paper)
            .navigationTitle(facet.label)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        actions.openDocumentPicker()
                    } label: {
                        Label("Open Document…", systemImage: "doc.badge.plus")
                    }
                    .help("Open a Markdown document")

                    Button {
                        showsExportSheet = true
                        actions.requestExport()
                    } label: {
                        Label("Export…", systemImage: "square.and.arrow.up")
                    }
                    .help("Export Reading Memory")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 520)
        .background(palette.paper)
        .sheet(isPresented: $showsExportSheet) {
            ReadingMemoryExportSheet(
                configuration: $exportConfiguration,
                preview: exportPreview,
                actions: exportActions,
                onDismiss: { showsExportSheet = false }
            )
            .marginaliaAppearance(appearance)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(facet.label)
                    .font(.system(size: 24, weight: .medium, design: .serif))
                    .foregroundStyle(palette.ink)

                Text(resultSummary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.metadataInk)

                Spacer(minLength: 0)
            }

            ReadingMemorySearchBar(
                text: $searchText,
                scope: $searchScope,
                facet: facet,
                onDebouncedSearch: actions.search
            )
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(palette.paper)
    }

    @ViewBuilder
    private var results: some View {
        if isLoading && visibleCount == 0 {
            ProgressView("Loading Reading Memory…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleCount == 0 {
            globalEmptyState
        } else if facet.presentsDocuments {
            documentResults
        } else {
            memoryResults
        }
    }

    private var memoryResults: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(memories.enumerated()), id: \.element.id) { index, entry in
                    ReadingMemoryEntryView(
                        entry: entry,
                        isExpanded: selectedMemoryID == entry.id,
                        onSelect: { selectMemory(entry.id) },
                        onOpenMemory: { actions.openMemory(entry.id) },
                        onOpenDocument: {
                            if let documentID = entry.documentID {
                                actions.openDocument(documentID)
                            }
                        },
                        onEditNote: { actions.editNote(entry.id) },
                        onReviewLocation: { actions.reviewLocation(entry.id) },
                        onDelete: { actions.deleteMemory(entry.id) }
                    )
                    .padding(.horizontal, 24)
                    .padding(.vertical, 5)

                    if index < memories.count - 1 {
                        Rectangle()
                            .fill(palette.hairline)
                            .frame(height: accessibilityContrast == .increased ? 2 : 1)
                            .padding(.leading, 202)
                            .padding(.trailing, 24)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .accessibilityLabel("\(memories.count) \(memories.count == 1 ? "memory" : "memories")")
    }

    private var documentResults: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(documents.enumerated()), id: \.element.id) { index, document in
                    ReadingDocumentRow(
                        document: document,
                        isSelected: selectedDocumentID == document.id,
                        onSelect: { selectDocument(document.id) },
                        onOpen: { actions.openDocument(document.id) },
                        onToggleFavourite: { actions.toggleFavourite(document.id) },
                        onForget: { actions.forgetDocument(document.id) }
                    )
                    .padding(.horizontal, 24)
                    .padding(.vertical, 5)

                    if index < documents.count - 1 {
                        Rectangle()
                            .fill(palette.hairline)
                            .frame(height: accessibilityContrast == .increased ? 2 : 1)
                            .padding(.leading, 202)
                            .padding(.trailing, 24)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .accessibilityLabel("\(documents.count) \(documents.count == 1 ? "document" : "documents")")
    }

    private var globalEmptyState: some View {
        VStack(spacing: 12) {
            Text(emptyTitle)
                .font(.system(size: 20, weight: .medium, design: .serif))
                .foregroundStyle(palette.ink)

            Text(emptyMessage)
                .font(.system(size: 14, design: .serif))
                .foregroundStyle(palette.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               facet == .allMemories {
                Button("Open a Document…", action: actions.openDocumentPicker)
            }
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityElement(children: .contain)
    }

    private func selectMemory(_ id: UUID) {
        selectedMemoryID = id
        selectedDocumentID = nil
        actions.selectMemory(id)
    }

    private func selectDocument(_ id: UUID) {
        selectedDocumentID = id
        selectedMemoryID = nil
    }

    private var visibleCount: Int {
        facet.presentsDocuments ? documents.count : memories.count
    }

    private var resultSummary: String {
        let noun: String
        if facet.presentsDocuments {
            noun = visibleCount == 1 ? "document" : "documents"
        } else {
            noun = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (visibleCount == 1 ? "memory" : "memories")
                : (visibleCount == 1 ? "result" : "results")
        }

        var components = ["\(visibleCount) \(noun)"]
        if !facet.presentsDocuments,
           let searchSummary,
           searchSummary.documentCount > 0 {
            let documents = searchSummary.documentCount
            components.append("in \(documents) \(documents == 1 ? "document" : "documents")")
        }
        if let searchSummary, searchSummary.attentionCount > 0 {
            components.append("\(searchSummary.attentionCount) need attention")
        }
        return components.joined(separator: " · ")
    }

    private var emptyTitle: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? facet.emptyTitle
            : "No matches"
    }

    private var emptyMessage: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? facet.emptyMessage
            : (facet.presentsDocuments
                ? "Try another document name, folder, or heading."
                : "Try another passage, note, or heading.")
    }

    private var palette: MarginaliaPalette {
        MarginaliaPalette.resolve(
            appearance: appearance,
            systemColorScheme: colorScheme,
            increasedContrast: accessibilityContrast == .increased
        )
    }
}
