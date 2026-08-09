import Foundation

@MainActor
final class ReadingMemoryWindowModel: ObservableObject {
    @Published var facet: ReadingMemoryFacet = .allMemories
    @Published var searchText = ""
    @Published var searchScope: ReadingMemorySearchScope = .all
    @Published var selectedMemoryID: UUID?
    @Published var selectedDocumentID: UUID?
    @Published var showsExportSheet = false
    @Published var exportConfiguration = ReadingMemoryExportConfiguration()
    @Published private(set) var exportPreview = ReadingMemoryExportPreview()
    @Published private(set) var counts = ReadingMemorySidebarCounts()
    @Published private(set) var memories: [ReadingMemoryEntryPresentation] = []
    @Published private(set) var documents: [ReadingDocumentPresentation] = []
    @Published private(set) var searchSummary: ReadingMemorySearchSummary?
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published var editingMemoryID: UUID?
    @Published var noteDraft = ""
    @Published private(set) var noteConflict: MemoryNoteConflict?
    @Published private(set) var pendingRestoreDeletedAsNewProposal: RestoreDeletedMemoryAsNewProposal?

    private var snapshot: MemoryStoreSnapshot?
    private var snapshotSequence: UInt64?
    private var visibleMemoryIDs: Set<UUID> = []
    private var visibleDocumentIDs: Set<UUID> = []
    private var editingBaseRecordVersion: Int64?
    private var preparedExportPayload: MemoryArchivePayload?
    private var preparedExportConfiguration: ReadingMemoryExportConfiguration?
    private var refreshGeneration = 0
    private var exportGeneration = 0

    func refresh(library: ReadingMemoryLibrary) {
        guard library.isReady else {
            errorMessage = library.errorMessage
            return
        }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        exportGeneration &+= 1
        preparedExportPayload = nil
        preparedExportConfiguration = nil
        if showsExportSheet {
            exportPreview = ReadingMemoryExportPreview(
                renderedConfiguration: exportConfiguration.normalizedForExport,
                isPreparing: true
            )
        }
        isLoading = true
        let request = ReadingMemorySearchRequest(text: searchText, scope: searchScope, facet: facet)
        Task {
            do {
                let repository = try library.requireRepository()
                async let loadedSnapshot = repository.snapshotWithSequence()
                if request.facet.presentsDocuments {
                    let results = try await repository.searchDocuments(Self.documentQuery(from: request))
                    let sequenced = try await loadedSnapshot
                    guard generation == refreshGeneration else { return }
                    apply(
                        snapshot: sequenced.snapshot,
                        sequence: sequenced.sequence,
                        documentResults: results
                    )
                    if showsExportSheet { prepareExport(exportConfiguration) }
                } else {
                    let results = try await repository.searchMemories(Self.memoryQuery(from: request))
                    let sequenced = try await loadedSnapshot
                    guard generation == refreshGeneration else { return }
                    apply(
                        snapshot: sequenced.snapshot,
                        sequence: sequenced.sequence,
                        memoryResults: results
                    )
                    if showsExportSheet { prepareExport(exportConfiguration) }
                }
                isLoading = false
                errorMessage = nil
            } catch {
                guard generation == refreshGeneration else { return }
                isLoading = false
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Reading Memory could not be loaded."
            }
        }
    }

    func search(_ request: ReadingMemorySearchRequest, library: ReadingMemoryLibrary) {
        searchText = request.text
        searchScope = request.scope
        facet = request.facet
        refresh(library: library)
    }

    func selectFacet(_ facet: ReadingMemoryFacet, library: ReadingMemoryLibrary) {
        self.facet = facet
        selectedMemoryID = nil
        selectedDocumentID = nil
        refresh(library: library)
    }

    func beginEditingNote(memoryID: UUID) {
        guard !isWorking,
              let stored = snapshot?.memories.first(where: { $0.memory.id == memoryID }) else { return }
        selectedMemoryID = memoryID
        editingMemoryID = memoryID
        editingBaseRecordVersion = stored.memory.recordVersion
        noteDraft = stored.memory.noteText ?? ""
        noteConflict = nil
    }

    func cancelEditingNote() {
        guard !isWorking else { return }
        editingMemoryID = nil
        editingBaseRecordVersion = nil
        noteDraft = ""
        noteConflict = nil
    }

    func saveNote(library: ReadingMemoryLibrary) async -> NoteEditUndoPayload? {
        guard !isWorking,
              let memoryID = editingMemoryID,
              let expectedRecordVersion = editingBaseRecordVersion else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let repository = try library.requireRepository()
            let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let mutation = try await repository.updateNote(
                memoryID: memoryID,
                noteText: trimmed.isEmpty ? nil : noteDraft,
                expectedRecordVersion: expectedRecordVersion
            )
            editingMemoryID = nil
            editingBaseRecordVersion = nil
            noteDraft = ""
            noteConflict = nil
            refresh(library: library)
            return mutation.undo
        } catch let storeError as MemoryStoreError {
            if case .versionConflict(entity: .memory, expected: _, actual: _) = storeError,
               let latest = try? await library.requireRepository().memory(id: memoryID) {
                noteConflict = MemoryNoteConflict(
                    memoryID: memoryID,
                    latestNoteText: latest.memory.noteText,
                    latestRecordVersion: latest.memory.recordVersion
                )
            }
            errorMessage = storeError.errorDescription
                ?? "The note changed in another window. Your draft was kept."
            return nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "The note could not be saved. Your draft was kept."
            return nil
        }
    }

    func useLatestConflictedNote(library: ReadingMemoryLibrary) async {
        guard !isWorking, let conflict = noteConflict else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let repository = try library.requireRepository()
            guard let latest = try await repository.memory(id: conflict.memoryID) else { return }
            if var snapshot {
                if let index = snapshot.memories.firstIndex(where: { $0.memory.id == conflict.memoryID }) {
                    snapshot.memories[index] = latest
                }
                self.snapshot = snapshot
            }
            editingBaseRecordVersion = latest.memory.recordVersion
            noteDraft = latest.memory.noteText ?? ""
            noteConflict = nil
            refresh(library: library)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
        }
    }

    func replaceConflictedNote(library: ReadingMemoryLibrary) async -> NoteEditUndoPayload? {
        guard !isWorking, let conflict = noteConflict else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let repository = try library.requireRepository()
            let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let mutation = try await repository.updateNote(
                memoryID: conflict.memoryID,
                noteText: trimmed.isEmpty ? nil : noteDraft,
                expectedRecordVersion: conflict.latestRecordVersion
            )
            editingMemoryID = nil
            editingBaseRecordVersion = nil
            noteDraft = ""
            noteConflict = nil
            refresh(library: library)
            return mutation.undo
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "The note changed again. Your draft was kept."
            if let latest = try? await library.requireRepository().memory(id: conflict.memoryID) {
                noteConflict = MemoryNoteConflict(
                    memoryID: conflict.memoryID,
                    latestNoteText: latest.memory.noteText,
                    latestRecordVersion: latest.memory.recordVersion
                )
            }
            return nil
        }
    }

    func cancelNoteConflict() {
        guard !isWorking else { return }
        noteConflict = nil
    }

    func deleteMemory(_ memoryID: UUID, library: ReadingMemoryLibrary) async -> DeletedMemoryUndoPayload? {
        guard let stored = snapshot?.memories.first(where: { $0.memory.id == memoryID }) else { return nil }
        pendingRestoreDeletedAsNewProposal = nil
        do {
            let repository = try library.requireRepository()
            let payload = try await repository.deleteMemory(
                memoryID: memoryID,
                expectedRecordVersion: stored.memory.recordVersion
            )
            if selectedMemoryID == memoryID { selectedMemoryID = nil }
            refresh(library: library)
            return payload
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
            return nil
        }
    }

    func toggleFavourite(_ documentID: UUID, library: ReadingMemoryLibrary) async -> FavouriteUndoPayload? {
        guard let document = snapshot?.documents.first(where: { $0.id == documentID }) else { return nil }
        do {
            let repository = try library.requireRepository()
            let mutation = try await repository.setFavourite(
                documentID: documentID,
                isFavourite: !document.isFavourite,
                expectedRecordVersion: document.recordVersion
            )
            refresh(library: library)
            return mutation.undo
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
            return nil
        }
    }

    func forgetDocument(
        _ documentID: UUID,
        library: ReadingMemoryLibrary
    ) async -> ForgottenDocumentUndoPayload? {
        guard let document = snapshot?.documents.first(where: { $0.id == documentID }) else { return nil }
        do {
            let repository = try library.requireRepository()
            let payload = try await repository.forgetDocument(
                documentID: documentID,
                expectedRecordVersion: document.recordVersion
            )
            if selectedDocumentID == documentID { selectedDocumentID = nil }
            selectedMemoryID = nil
            refresh(library: library)
            return payload
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
            return nil
        }
    }

    func restoreForgotten(
        _ payload: ForgottenDocumentUndoPayload,
        library: ReadingMemoryLibrary
    ) async {
        do {
            let repository = try library.requireRepository()
            let restored = try await repository.restoreForgottenDocument(payload)
            selectedDocumentID = restored.id
            refresh(library: library)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
        }
    }

    func restoreDeleted(_ payload: DeletedMemoryUndoPayload, library: ReadingMemoryLibrary) async {
        pendingRestoreDeletedAsNewProposal = nil
        do {
            let repository = try library.requireRepository()
            _ = try await repository.restoreDeletedMemory(payload)
            selectedMemoryID = payload.storedMemory.memory.id
            errorMessage = nil
            refresh(library: library)
        } catch {
            let exactRestoreMessage = (error as? LocalizedError)?.errorDescription
                ?? "The deleted memory could not be restored exactly."
            do {
                let repository = try library.requireRepository()
                pendingRestoreDeletedAsNewProposal = try await repository
                    .prepareRestoreDeletedMemoryAsNew(payload)
                errorMessage = nil
            } catch {
                let fallbackMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Restore as New is not safe for the current document."
                errorMessage = "\(exactRestoreMessage) Restore as New is unavailable: \(fallbackMessage)"
            }
        }
    }

    func confirmRestoreDeletedAsNew(library: ReadingMemoryLibrary) async {
        guard let proposal = pendingRestoreDeletedAsNewProposal, !isLoading else { return }
        isLoading = true
        do {
            let repository = try library.requireRepository()
            let restored = try await repository.restoreDeletedMemoryAsNew(proposal)
            selectedMemoryID = restored.memory.id
            pendingRestoreDeletedAsNewProposal = nil
            errorMessage = nil
            isLoading = false
            refresh(library: library)
        } catch {
            isLoading = false
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Restore as New could not be completed safely."
        }
    }

    func cancelRestoreDeletedAsNew() {
        pendingRestoreDeletedAsNewProposal = nil
    }

    func undoNote(_ payload: NoteEditUndoPayload, library: ReadingMemoryLibrary) async {
        do {
            let repository = try library.requireRepository()
            _ = try await repository.undoNoteEdit(payload)
            refresh(library: library)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
        }
    }

    func undoFavourite(_ payload: FavouriteUndoPayload, library: ReadingMemoryLibrary) async {
        do {
            let repository = try library.requireRepository()
            _ = try await repository.undoFavourite(payload)
            refresh(library: library)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
        }
    }

    func prepareExport(_ configuration: ReadingMemoryExportConfiguration) {
        guard let snapshot, let snapshotSequence else {
            exportPreview = ReadingMemoryExportPreview(errorMessage: "Reading Memory has not finished loading.")
            return
        }
        exportGeneration &+= 1
        preparedExportPayload = nil
        preparedExportConfiguration = nil
        let generation = exportGeneration
        let normalized = configuration.normalizedForExport
        exportPreview = ReadingMemoryExportPreview(
            renderedConfiguration: normalized,
            isPreparing: true
        )
        let filtered = exportSnapshot(snapshot, configuration: normalized)
        Task { [weak self] in
            do {
                let payload = try await Task.detached(priority: .utility) { [filtered] in
                    try MemoryArchiveExporter.makePayload(
                        snapshot: filtered,
                        storeSequence: snapshotSequence,
                        includeFileLocations: normalized.includesFileLocations,
                        markdownOptions: MemoryArchiveMarkdownOptions(
                            includesNotes: normalized.includesNotes,
                            includesRepairLabels: normalized.includesRepairLabels,
                            includesAnchorDetails: normalized.includesAnchorDetails,
                            groupsByDocument: normalized.groupsByDocument
                        )
                    )
                }.value
                guard let self, generation == self.exportGeneration else { return }
                let data = normalized.format == .json ? payload.json : payload.markdown
                self.preparedExportPayload = payload
                self.preparedExportConfiguration = normalized
                self.exportPreview = ReadingMemoryExportPreview(
                    renderedConfiguration: normalized,
                    data: data,
                    itemCount: filtered.memories.count
                )
            } catch {
                guard let self, generation == self.exportGeneration else { return }
                self.preparedExportPayload = nil
                self.preparedExportConfiguration = nil
                self.exportPreview = ReadingMemoryExportPreview(
                    renderedConfiguration: normalized,
                    errorMessage: (error as? LocalizedError)?.errorDescription
                        ?? "The archive could not be prepared."
                )
            }
        }
    }

    func preparedArchive(
        matching configuration: ReadingMemoryExportConfiguration,
        previewData: Data
    ) throws -> (payload: MemoryArchivePayload, representation: MemoryArchiveRepresentation) {
        let normalized = configuration.normalizedForExport
        guard preparedExportConfiguration == normalized,
              exportPreview.renderedConfiguration == normalized,
              exportPreview.data == previewData,
              let payload = preparedExportPayload else {
            throw ReadingMemoryExportUIError.previewUnavailable
        }
        let representation: MemoryArchiveRepresentation = normalized.format == .json ? .json : .markdown
        guard try payload.data(
            for: representation,
            currentStoreSequence: payload.storeSequence
        ) == previewData else {
            throw ReadingMemoryExportUIError.previewUnavailable
        }
        return (payload, representation)
    }

    func validateExportDestination(_ destinationURL: URL) throws {
        guard destinationURL.isFileURL, let snapshot else {
            throw ReadingMemoryExportUIError.destinationCouldNotBeVerified
        }
        let canonicalPath = destinationURL.standardizedFileURL.resolvingSymlinksInPath().path
        let registeredPaths = Set(snapshot.documentLocations.map {
            $0.url.standardizedFileURL.resolvingSymlinksInPath().path
        })
        if registeredPaths.contains(canonicalPath) {
            throw ReadingMemoryExportUIError.sourceDocumentDestination
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory) else {
            return
        }
        guard !isDirectory.boolValue else {
            throw ReadingMemoryExportUIError.destinationCouldNotBeVerified
        }
        let observation: DocumentIdentityProbe.Observation
        do {
            observation = try DocumentIdentityProbe.observe(destinationURL)
        } catch {
            throw ReadingMemoryExportUIError.destinationCouldNotBeVerified
        }
        guard observation.identity.isComplete else {
            throw ReadingMemoryExportUIError.destinationCouldNotBeVerified
        }
        if snapshot.documents.contains(where: { $0.fileIdentity == observation.identity }) {
            throw ReadingMemoryExportUIError.sourceDocumentDestination
        }
    }

    func currentURL(for documentID: UUID) -> URL? {
        snapshot?.documentLocations
            .filter { $0.documentID == documentID && $0.isCurrent }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .first?.url
    }

    func documentID(for memoryID: UUID) -> UUID? {
        snapshot?.memories.first { $0.memory.id == memoryID }?.memory.documentID
    }

    func memoryHasNote(_ memoryID: UUID) -> Bool {
        guard let note = snapshot?.memories.first(where: { $0.memory.id == memoryID })?.memory.noteText else {
            return false
        }
        return !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var editingPresentation: MemoryPresentation? {
        guard let editingMemoryID else { return nil }
        return memories.first { $0.id == editingMemoryID }?.memory
            ?? makeMemoryPresentation(
                snapshot?.memories.first { $0.memory.id == editingMemoryID }
            )
    }

    func dismissError() { errorMessage = nil }

    private func apply(
        snapshot: MemoryStoreSnapshot,
        sequence: UInt64,
        memoryResults: [MemorySearchResult]
    ) {
        self.snapshot = snapshot
        snapshotSequence = sequence
        rebuildCounts(snapshot)
        let storedByID = Dictionary(uniqueKeysWithValues: snapshot.memories.map { ($0.memory.id, $0) })
        visibleMemoryIDs = Set(memoryResults.map(\.memory.id))
        visibleDocumentIDs = Set(memoryResults.map(\.memory.documentID))
        memories = memoryResults.compactMap { result in
            guard let stored = storedByID[result.memory.id] else { return nil }
            return makeEntry(stored: stored, result: result)
        }
        documents = []
        searchSummary = ReadingMemorySearchSummary(
            documentCount: Set(memoryResults.map(\.memory.documentID)).count,
            attentionCount: memoryResults.lazy.filter { $0.resolutionState != .resolved }.count
        )
    }

    private func apply(
        snapshot: MemoryStoreSnapshot,
        sequence: UInt64,
        documentResults: [DocumentSearchResult]
    ) {
        self.snapshot = snapshot
        snapshotSequence = sequence
        rebuildCounts(snapshot)
        visibleMemoryIDs = []
        visibleDocumentIDs = Set(documentResults.map(\.document.id))
        memories = []
        documents = documentResults.map(makeDocumentPresentation)
        searchSummary = nil
    }

    private func rebuildCounts(_ snapshot: MemoryStoreSnapshot) {
        let memoryRecords = snapshot.memories
        let states = memoryRecords.map(\.resolution.state)
        counts = ReadingMemorySidebarCounts([
            .allMemories: memoryRecords.count,
            .continueReading: snapshot.readingStates.count,
            .favourites: snapshot.documents.lazy.filter(\.isFavourite).count,
            .highlights: memoryRecords.lazy.filter { $0.memory.kind == .passage }.count,
            .notes: memoryRecords.lazy.filter {
                !($0.memory.noteText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }.count,
            .bookmarks: memoryRecords.lazy.filter { $0.memory.kind == .headingBookmark }.count,
            .chooseLocation: states.lazy.filter { $0 == .ambiguous }.count,
            .needsRepair: states.lazy.filter { $0 == .needsReview || $0 == .orphaned }.count,
        ])
    }

    private func makeEntry(stored: StoredMemory, result: MemorySearchResult) -> ReadingMemoryEntryPresentation {
        let anchor = stored.anchors.first { $0.id == stored.memory.currentAnchorID }
        return ReadingMemoryEntryPresentation(
            memory: makeMemoryPresentation(stored)!,
            documentID: stored.memory.documentID,
            documentName: result.documentDisplayName,
            parentFolder: result.currentDocumentURL?.deletingLastPathComponent().lastPathComponent,
            heading: anchor?.headingPath.last?.title,
            provenanceDate: Self.relativeDate(stored.memory.createdAt),
            retainedMatchExplanation: stored.resolution.state == .resolved
                ? Self.evidenceSummary(stored.resolution.evidence)
                : nil
        )
    }

    private func makeMemoryPresentation(_ stored: StoredMemory?) -> MemoryPresentation? {
        guard let stored else { return nil }
        let anchor = stored.anchors.first { $0.id == stored.memory.currentAnchorID }
        let state: MemoryPresentation.State
        switch stored.resolution.state {
        case .resolved: state = .resolved
        case .ambiguous: state = .chooseLocation(candidateCount: nil)
        case .needsReview: state = .needsRepair(hasProposedLocation: true)
        case .orphaned: state = .needsRepair(hasProposedLocation: false)
        }
        let quote = stored.memory.originalVisibleQuote
        let title = anchor?.headingPath.last?.title
            ?? quote?.split(separator: "\n").first.map(String.init)
            ?? "Remembered passage"
        return MemoryPresentation(
            id: stored.memory.id,
            kind: stored.memory.kind == .passage ? .passage : .headingBookmark,
            state: state,
            title: title,
            passage: quote,
            note: stored.memory.noteText,
            headingPath: anchor?.headingPath.map(\.title).joined(separator: " › "),
            savedAt: Self.relativeDate(stored.memory.createdAt),
            anchorDetails: MemoryPresentation.AnchorDetails(
                foundBy: Self.evidenceSummary(stored.resolution.evidence) ?? "No automatic recovery claim",
                lastChecked: Self.relativeDate(stored.resolution.lastCheckedAt),
                candidateSummary: stored.resolution.state.rawValue,
                savedPassage: quote
            )
        )
    }

    private func makeDocumentPresentation(_ result: DocumentSearchResult) -> ReadingDocumentPresentation {
        ReadingDocumentPresentation(
            id: result.document.id,
            displayName: result.document.displayName,
            parentFolder: result.parentFolderProvenance
                ?? result.currentURL?.deletingLastPathComponent().lastPathComponent,
            lastHeading: result.readingState?.lastSemanticHeading,
            lastRead: Self.relativeDate(result.readingState?.lastReadAt ?? result.document.lastOpenedAt),
            progress: result.readingState?.fallbackScrollFraction,
            isFavourite: result.document.isFavourite,
            isOriginalAvailable: result.document.availability == .available
                && result.currentURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
        )
    }

    private func exportSnapshot(
        _ source: MemoryStoreSnapshot,
        configuration: ReadingMemoryExportConfiguration
    ) -> MemoryStoreSnapshot {
        let includedMemoryIDs: Set<UUID>
        let includedDocumentIDs: Set<UUID>
        switch configuration.include {
        case .allMemories:
            includedMemoryIDs = Set(source.memories.map(\.memory.id))
            includedDocumentIDs = Set(source.documents.map(\.id))
        case .currentFilter:
            includedMemoryIDs = visibleMemoryIDs
            includedDocumentIDs = visibleDocumentIDs
        case .selection:
            includedMemoryIDs = Set([selectedMemoryID].compactMap { $0 })
            includedDocumentIDs = Set([selectedDocumentID].compactMap { $0 })
        case .needsRepair:
            includedMemoryIDs = Set(source.memories.compactMap {
                $0.resolution.state == .resolved ? nil : $0.memory.id
            })
            includedDocumentIDs = []
        }
        var memories = source.memories.filter { stored in
            includedMemoryIDs.contains(stored.memory.id)
                || includedDocumentIDs.contains(stored.memory.documentID)
        }
        if !configuration.includesNotes {
            memories = memories.map { stored in
                var copy = stored
                copy.memory.noteText = nil
                return copy
            }
        }
        let documentIDs = Set(memories.map(\.memory.documentID)).union(includedDocumentIDs)
        return MemoryStoreSnapshot(
            schemaVersion: source.schemaVersion,
            documents: source.documents.filter { documentIDs.contains($0.id) },
            documentLocations: source.documentLocations.filter { documentIDs.contains($0.documentID) },
            readingStates: source.readingStates.filter { documentIDs.contains($0.documentID) },
            memories: memories
        )
    }

    private static func memoryQuery(from request: ReadingMemorySearchRequest) -> MemorySearchQuery {
        MemorySearchQuery(
            text: request.text,
            scope: MemorySearchScope(rawValue: request.scope.rawValue) ?? .all,
            facet: {
                switch request.facet {
                case .highlights: .highlights
                case .notes: .notes
                case .bookmarks: .bookmarks
                case .chooseLocation: .chooseLocation
                case .needsRepair: .needsRepair
                default: .all
                }
            }(),
            limit: 500
        )
    }

    private static func documentQuery(from request: ReadingMemorySearchRequest) -> DocumentSearchQuery {
        DocumentSearchQuery(
            text: request.text,
            facet: request.facet == .favourites ? .favourites : .continueReading,
            limit: 500
        )
    }

    private static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private static func evidenceSummary(_ evidence: [ResolutionEvidence]) -> String? {
        let labels = evidence.filter(\.matched).map { item in
            switch item.kind {
            case .exactQuote: "Exact passage"
            case .prefix: "matching text before"
            case .suffix: "matching text after"
            case .blockFingerprint: "same block"
            case .blockKind: "same block kind"
            case .headingPath: "same heading"
            case .manualConfirmation: "manually confirmed"
            }
        }
        return labels.isEmpty ? nil : Array(Set(labels)).sorted().joined(separator: " · ")
    }
}

private enum ReadingMemoryExportUIError: LocalizedError {
    case previewUnavailable
    case sourceDocumentDestination
    case destinationCouldNotBeVerified

    var errorDescription: String? {
        switch self {
        case .previewUnavailable:
            "The export preview changed or is no longer current. Refresh it before saving."
        case .sourceDocumentDestination:
            "Choose a different destination. Reading Memory will never replace a registered source Markdown file."
        case .destinationCouldNotBeVerified:
            "The export destination could not be verified safely. Choose another local file."
        }
    }
}
