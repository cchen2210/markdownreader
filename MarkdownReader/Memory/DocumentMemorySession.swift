import Foundation

@MainActor
final class DocumentMemorySession: ObservableObject {
    private struct RecoveryBatch {
        var memories: [StoredMemory]
        var results: [UUID: MemoryRecoveryResult]
    }

    @Published private(set) var document: DocumentRecord?
    @Published private(set) var memories: [StoredMemory] = []
    @Published private(set) var presentations: [MemoryPresentation] = []
    @Published var selectedMemoryID: UUID?
    @Published var showsMemorySurface = false
    @Published var editingMemoryID: UUID?
    @Published var noteDraft = ""
    @Published private(set) var noteConflict: MemoryNoteConflict?
    @Published private(set) var pendingDocumentRelinkProposal: DocumentRelinkProposal?
    @Published private(set) var pendingRestoreDeletedAsNewProposal: RestoreDeletedMemoryAsNewProposal?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isWorking = false

    private var projection: DocumentProjection?
    private var readingState: ReadingStateRecord?
    private var recoveryResults: [UUID: MemoryRecoveryResult] = [:]
    private var editingBaseRecordVersion: Int64?
    private weak var webController: ReaderWebController?
    private var synchronizationGeneration = 0
    private var restoredDocumentID: UUID?
    private var pendingStoreRefreshLibrary: ReadingMemoryLibrary?

    var attentionCount: Int {
        presentations.lazy.filter(\.state.needsAttention).count
    }

    func synchronize(
        library: ReadingMemoryLibrary,
        content: ReaderContentSnapshot,
        fileURL: URL?,
        webController: ReaderWebController,
        restorePosition: Bool
    ) async {
        synchronizationGeneration &+= 1
        let generation = synchronizationGeneration
        self.webController = webController
        guard let projection = content.projection, let fileURL else {
            clearForUnavailableProjection()
            return
        }
        isWorking = true
        defer {
            if generation == synchronizationGeneration {
                finishWorking()
            }
        }
        do {
            let repository = try library.requireRepository()
            let registered = try await repository.openDocument(
                at: fileURL,
                source: projection.source,
                activeDocumentID: document?.id
            )
            guard generation == synchronizationGeneration else { return }
            let recovered = try await recoverAndPersist(
                using: repository,
                document: registered.document,
                memories: registered.memories,
                projection: projection
            )
            guard generation == synchronizationGeneration else { return }
            self.projection = projection
            document = registered.document
            memories = recovered.memories
            readingState = registered.readingState
            recoveryResults = recovered.results
            pendingDocumentRelinkProposal = nil
            rebuildPresentations()
            applyMarks()
            if restoredDocumentID != registered.document.id {
                if restorePosition {
                    restoreReadingPosition()
                }
                restoredDocumentID = registered.document.id
            }
            errorMessage = nil
        } catch let identityError as DocumentIdentityDecisionRequiredError {
            guard generation == synchronizationGeneration else { return }
            do {
                let repository = try library.requireRepository()
                pendingDocumentRelinkProposal = try await repository.stageDocumentRelink(
                    documentID: identityError.decision.registeredDocumentID,
                    to: identityError.decision.candidatePath
                )
                errorMessage = nil
            } catch {
                pendingDocumentRelinkProposal = nil
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? identityError.errorDescription
            }
            webController.clearMemoryMarks()
        } catch {
            guard generation == synchronizationGeneration else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Reading Memory is unavailable for this document."
            webController.clearMemoryMarks()
        }
    }

    func confirmPendingDocumentRelink(
        asReplacement: Bool,
        library: ReadingMemoryLibrary
    ) async -> Bool {
        guard let proposal = pendingDocumentRelinkProposal else { return false }
        isWorking = true
        defer { finishWorking() }
        do {
            let repository = try library.requireRepository()
            if asReplacement {
                _ = try await repository.confirmDocumentReplacement(proposalID: proposal.id)
            } else {
                _ = try await repository.confirmDocumentRelink(proposalID: proposal.id)
            }
            pendingDocumentRelinkProposal = nil
            errorMessage = nil
            return true
        } catch {
            pendingDocumentRelinkProposal = nil
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "The document identity changed during confirmation. Nothing was relinked."
            return false
        }
    }

    func cancelPendingDocumentRelink(library: ReadingMemoryLibrary) async {
        guard let proposal = pendingDocumentRelinkProposal else { return }
        pendingDocumentRelinkProposal = nil
        guard let repository = try? library.requireRepository() else { return }
        await repository.cancelDocumentRelink(proposalID: proposal.id)
    }

    func refreshFromStore(library: ReadingMemoryLibrary) async {
        guard !isWorking else {
            pendingStoreRefreshLibrary = library
            return
        }
        guard let currentDocument = document, let projection else { return }
        synchronizationGeneration &+= 1
        let generation = synchronizationGeneration
        isWorking = true
        defer {
            if generation == synchronizationGeneration {
                finishWorking()
            }
        }
        do {
            let repository = try library.requireRepository()
            guard let registered = try await repository.documentState(documentID: currentDocument.id) else {
                return
            }
            let recovered = try await recoverAndPersist(
                using: repository,
                document: registered.document,
                memories: registered.memories,
                projection: projection
            )
            guard generation == synchronizationGeneration else { return }
            document = registered.document
            memories = recovered.memories
            readingState = registered.readingState
            recoveryResults = recovered.results
            rebuildPresentations()
            applyMarks()
            errorMessage = nil
        } catch {
            guard generation == synchronizationGeneration else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Reading Memory changed in another window and could not be refreshed."
        }
    }

    func rememberPassage(
        withNote: Bool,
        model: ReaderViewModel,
        library: ReadingMemoryLibrary
    ) async -> CreateMemoryUndoPayload? {
        guard let projection, let document, let webController else {
            errorMessage = "Reading Memory is not ready for this document."
            return nil
        }
        isWorking = true
        defer { finishWorking() }
        do {
            let domSelection = try await webController.captureMemorySelection()
            let selection = try projection.selection(fromDOM: domSelection)
            let passageMemoryIDs = Set(
                memories.lazy
                    .filter { $0.memory.kind == .passage }
                    .map(\.memory.id)
            )
            if let existingID = recoveryResults.first(where: { candidateMemoryID, result in
                guard passageMemoryIDs.contains(candidateMemoryID) else { return false }
                guard let selector = result.resolution.resolvedSelector,
                      selector.blockID == selection.blockID else { return false }
                let existing = selector.canonicalUTF8RangeInBlock
                let candidate = selection.canonicalUTF8RangeInBlock
                return existing.lowerBound < candidate.upperBound
                    && candidate.lowerBound < existing.upperBound
            })?.key {
                selectedMemoryID = existingID
                showsMemorySurface = true
                webController.scrollToMemory(existingID)
                errorMessage = nil
                return nil
            }
            return try await createMemory(
                kind: .passage,
                selection: selection,
                withNote: withNote,
                document: document,
                model: model,
                library: library
            )
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "The selected passage could not be remembered."
            return nil
        }
    }

    func bookmarkHeading(
        model: ReaderViewModel,
        library: ReadingMemoryLibrary
    ) async -> CreateMemoryUndoPayload? {
        guard let projection, let document, let webController else {
            errorMessage = "Reading Memory is not ready for this document."
            return nil
        }
        isWorking = true
        defer { finishWorking() }
        do {
            let target = try await webController.headingBookmarkTarget()
            guard target.sourceRevisionHash == projection.source.revisionHash else {
                throw DocumentProjectionError.staleSourceRevision
            }
            guard target.renderRevision == projection.renderRevision else {
                throw DocumentProjectionError.staleRenderRevision
            }
            guard target.projectionVersion == projection.version,
                  let targetBlock = projection.block(id: target.blockID) else {
                throw DocumentProjectionError.staleProjectionVersion
            }
            let block: SemanticBlock?
            if targetBlock.kind == .heading {
                block = targetBlock
            } else if let breadcrumb = targetBlock.headingPath.last {
                block = projection.blocks.last { candidate in
                    candidate.kind == .heading
                        && candidate.ordinal <= targetBlock.ordinal
                        && candidate.headingLevel == breadcrumb.level
                        && candidate.canonicalText == breadcrumb.title
                }
            } else {
                block = nil
            }
            guard let block else {
                errorMessage = "No heading is available at the selection or top of the visible page."
                return nil
            }
            let selection = ProjectionSelection(
                sourceRevisionHash: projection.source.revisionHash,
                renderRevision: projection.renderRevision,
                projectionVersion: projection.version,
                blockID: block.id,
                canonicalUTF8RangeInBlock: UTF8ByteRange(0, block.canonicalUTF8Count),
                selectedVisibleText: block.canonicalText,
                runIDs: block.textRuns.map(\.id)
            )
            return try await createMemory(
                kind: .headingBookmark,
                selection: selection,
                withNote: false,
                document: document,
                model: model,
                library: library
            )
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "The heading could not be bookmarked."
            return nil
        }
    }

    func beginEditingNote(memoryID: UUID) {
        guard !isWorking,
              let stored = memories.first(where: { $0.memory.id == memoryID }) else { return }
        selectedMemoryID = memoryID
        editingMemoryID = memoryID
        editingBaseRecordVersion = stored.memory.recordVersion
        noteDraft = stored.memory.noteText ?? ""
        noteConflict = nil
        showsMemorySurface = true
    }

    func cancelNoteEditing() {
        guard !isWorking else { return }
        editingMemoryID = nil
        editingBaseRecordVersion = nil
        noteDraft = ""
        noteConflict = nil
    }

    func commitNote(library: ReadingMemoryLibrary) async -> NoteEditUndoPayload? {
        guard !isWorking,
              let memoryID = editingMemoryID,
              let expectedRecordVersion = editingBaseRecordVersion else { return nil }
        isWorking = true
        defer { finishWorking() }
        do {
            let repository = try library.requireRepository()
            let normalized = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let mutation = try await repository.updateNote(
                memoryID: memoryID,
                noteText: normalized.isEmpty ? nil : noteDraft,
                expectedRecordVersion: expectedRecordVersion
            )
            if let index = memories.firstIndex(where: { $0.memory.id == memoryID }) {
                memories[index].memory = mutation.memory
            }
            editingMemoryID = nil
            editingBaseRecordVersion = nil
            noteDraft = ""
            noteConflict = nil
            rebuildPresentations()
            applyMarks()
            errorMessage = nil
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
            // The draft intentionally remains available after an optimistic
            // conflict so the reader can copy or explicitly replace it.
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
        defer { finishWorking() }
        do {
            let repository = try library.requireRepository()
            guard let latest = try await repository.memory(id: conflict.memoryID),
                  let index = memories.firstIndex(where: { $0.memory.id == conflict.memoryID }) else { return }
            memories[index] = latest
            editingBaseRecordVersion = latest.memory.recordVersion
            noteDraft = latest.memory.noteText ?? ""
            noteConflict = nil
            rebuildPresentations()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
        }
    }

    func replaceConflictedNote(library: ReadingMemoryLibrary) async -> NoteEditUndoPayload? {
        guard !isWorking, let conflict = noteConflict else { return nil }
        isWorking = true
        defer { finishWorking() }
        do {
            let repository = try library.requireRepository()
            let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let mutation = try await repository.updateNote(
                memoryID: conflict.memoryID,
                noteText: trimmed.isEmpty ? nil : noteDraft,
                expectedRecordVersion: conflict.latestRecordVersion
            )
            if let index = memories.firstIndex(where: { $0.memory.id == conflict.memoryID }) {
                memories[index].memory = mutation.memory
            }
            editingMemoryID = nil
            editingBaseRecordVersion = nil
            noteDraft = ""
            noteConflict = nil
            rebuildPresentations()
            applyMarks()
            errorMessage = nil
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

    func deleteSelected(library: ReadingMemoryLibrary) async -> DeletedMemoryUndoPayload? {
        guard let memoryID = selectedMemoryID,
              let stored = memories.first(where: { $0.memory.id == memoryID }) else { return nil }
        pendingRestoreDeletedAsNewProposal = nil
        do {
            let repository = try library.requireRepository()
            let payload = try await repository.deleteMemory(
                memoryID: memoryID,
                expectedRecordVersion: stored.memory.recordVersion
            )
            memories.removeAll { $0.memory.id == memoryID }
            recoveryResults.removeValue(forKey: memoryID)
            selectedMemoryID = nil
            rebuildPresentations()
            applyMarks()
            return payload
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
            return nil
        }
    }

    func undoCreate(_ payload: CreateMemoryUndoPayload, library: ReadingMemoryLibrary) async {
        do {
            let repository = try library.requireRepository()
            try await repository.undoCreateMemory(payload)
            memories.removeAll { $0.memory.id == payload.memoryID }
            recoveryResults.removeValue(forKey: payload.memoryID)
            if selectedMemoryID == payload.memoryID { selectedMemoryID = nil }
            rebuildPresentations()
            applyMarks()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
        }
    }

    func undoNote(_ payload: NoteEditUndoPayload, library: ReadingMemoryLibrary) async {
        do {
            let repository = try library.requireRepository()
            let memory = try await repository.undoNoteEdit(payload)
            guard let index = memories.firstIndex(where: { $0.memory.id == memory.id }) else { return }
            memories[index].memory = memory
            rebuildPresentations()
            applyMarks()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
        }
    }

    func undoDelete(
        _ payload: DeletedMemoryUndoPayload,
        model: ReaderViewModel,
        library: ReadingMemoryLibrary
    ) async {
        pendingRestoreDeletedAsNewProposal = nil
        do {
            let repository = try library.requireRepository()
            let restored = try await repository.restoreDeletedMemory(payload)
            presentRestoredMemory(restored)
            pendingRestoreDeletedAsNewProposal = nil
            errorMessage = nil
        } catch {
            let exactRestoreMessage = (error as? LocalizedError)?.errorDescription
                ?? "The deleted memory could not be restored exactly."
            do {
                let repository = try library.requireRepository()
                let proposal = try await repository.prepareRestoreDeletedMemoryAsNew(
                    payload,
                    sourceURL: model.fileURL,
                    filePresenter: model.coordinatedFilePresenter
                )
                pendingRestoreDeletedAsNewProposal = proposal
                errorMessage = nil
            } catch {
                let fallbackMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Restore as New is not safe for the current document."
                errorMessage = "\(exactRestoreMessage) Restore as New is unavailable: \(fallbackMessage)"
            }
        }
    }

    func confirmRestoreDeletedAsNew(
        model: ReaderViewModel,
        library: ReadingMemoryLibrary
    ) async {
        guard let proposal = pendingRestoreDeletedAsNewProposal, !isWorking else { return }
        isWorking = true
        defer { finishWorking() }
        do {
            let repository = try library.requireRepository()
            let restored = try await repository.restoreDeletedMemoryAsNew(
                proposal,
                filePresenter: model.coordinatedFilePresenter
            )
            presentRestoredMemory(restored)
            pendingRestoreDeletedAsNewProposal = nil
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Restore as New could not be completed safely."
        }
    }

    func cancelRestoreDeletedAsNew() {
        pendingRestoreDeletedAsNewProposal = nil
    }

    func undoFavourite(_ payload: FavouriteUndoPayload, library: ReadingMemoryLibrary) async {
        do {
            let repository = try library.requireRepository()
            document = try await repository.undoFavourite(payload)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
        }
    }

    func toggleFavourite(library: ReadingMemoryLibrary) async -> FavouriteUndoPayload? {
        guard let document else { return nil }
        do {
            let repository = try library.requireRepository()
            let mutation = try await repository.setFavourite(
                documentID: document.id,
                isFavourite: !document.isFavourite,
                expectedRecordVersion: document.recordVersion
            )
            self.document = mutation.document
            return mutation.undo
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
            return nil
        }
    }

    func selectAdjacentMemory(offset: Int) {
        guard !presentations.isEmpty else { return }
        let current = selectedMemoryID.flatMap { id in presentations.firstIndex { $0.id == id } }
        let start = current ?? (offset > 0 ? -1 : presentations.count)
        let next = min(max(start + offset, 0), presentations.count - 1)
        selectedMemoryID = presentations[next].id
        showsMemorySurface = true
    }

    func dismissError() {
        errorMessage = nil
    }

    private func presentRestoredMemory(_ restored: StoredMemory) {
        memories.removeAll { $0.memory.id == restored.memory.id }
        memories.append(restored)
        if let projection,
           let anchorID = restored.memory.currentAnchorID,
           let record = restored.anchors.first(where: { $0.id == anchorID }) {
            if let anchor = try? ProjectionStoreAdapter.confirmedAnchor(from: record),
               let recovery = try? MemoryAnchorResolver.resolve(
                   anchor: anchor,
                   currentProjection: projection
               ) {
                recoveryResults[restored.memory.id] = recovery
            }
        }
        selectedMemoryID = restored.memory.id
        rebuildPresentations()
        applyMarks()
    }

    func report(_ message: String) {
        errorMessage = message
    }

    func saveReadingState(
        selectedHeadingID: String?,
        outline: [OutlineEntry],
        enabled: Bool,
        library: ReadingMemoryLibrary
    ) async {
        guard enabled, let document, let projection, let webController else { return }
        let domPosition = try? await webController.currentReadingPosition()
        let projectedPosition = domPosition.flatMap { try? projection.readingPosition(fromDOM: $0) }
        let fraction: Double
        if let fallback = domPosition?.fallbackScrollFraction {
            fraction = fallback
        } else {
            guard let fallback = await webController.readingPositionFraction() else { return }
            fraction = fallback
        }
        let semanticPosition = projectedPosition.map {
            SemanticReadingPosition(
                blockFingerprint: $0.blockFingerprint,
                canonicalUTF8Offset: $0.canonicalUTF8OffsetInBlock
            )
        }
        let semanticHeading = projectedPosition?.headingPath.last?.title
            ?? selectedHeadingID.flatMap { id in
                outline.first(where: { $0.id == id })?.title
            }
        let update = ReadingStateUpdate(
            semanticPosition: semanticPosition,
            fallbackScrollFraction: fraction,
            lastSemanticHeading: semanticHeading
        )
        do {
            let repository = try library.requireRepository()
            do {
                readingState = try await repository.updateReadingState(
                    documentID: document.id,
                    update: update,
                    expectedRecordVersion: readingState?.recordVersion
                )
            } catch let storeError as MemoryStoreError {
                guard case .versionConflict(entity: _, expected: _, actual: _) = storeError else {
                    throw storeError
                }
                readingState = try await repository.readingState(documentID: document.id)
                readingState = try await repository.updateReadingState(
                    documentID: document.id,
                    update: update,
                    expectedRecordVersion: readingState?.recordVersion
                )
            }
        } catch {
            // Reading-state persistence is best effort and must never interrupt
            // closing or reading the source document.
        }
    }

    func restoreReadingPosition() {
        guard let projection, let webController, let readingState else { return }
        let target: ProjectionReadingRestoreTarget?
        let blockID: String?
        if let semantic = readingState.semanticPosition {
            let matches = projection.blocks.filter { $0.fingerprint == semantic.blockFingerprint }
            blockID = matches.count == 1 ? matches[0].id : nil
            target = blockID.flatMap {
                projection.readingRestoreTarget(
                    blockID: $0,
                    canonicalUTF8OffsetInBlock: semantic.canonicalUTF8Offset
                )
            }
        } else {
            blockID = nil
            target = nil
        }
        webController.requestReadingRestore(
            blockID: blockID,
            point: target?.point,
            fallbackFraction: readingState.fallbackScrollFraction,
            context: MemoryRenderContext(
                sourceRevisionHash: projection.source.revisionHash,
                projectionVersion: projection.version,
                renderRevision: projection.renderRevision
            )
        )
    }

    private func createMemory(
        kind: ReadingMemoryKind,
        selection: ProjectionSelection,
        withNote: Bool,
        document: DocumentRecord,
        model: ReaderViewModel,
        library: ReadingMemoryLibrary
    ) async throws -> CreateMemoryUndoPayload {
        guard let projection else { throw ReadingMemoryLibraryError.unavailable(nil) }
        let memoryID = UUID()
        let passageMemoryIDs = Set(
            memories.lazy
                .filter { $0.memory.kind == .passage }
                .map(\.memory.id)
        )
        let existing = recoveryResults.compactMap { memoryID, result -> ExistingResolvedPassage? in
            guard passageMemoryIDs.contains(memoryID) else { return nil }
            guard let selector = result.resolution.resolvedSelector else { return nil }
            return ExistingResolvedPassage(
                memoryID: memoryID,
                canonicalTextPosition: selector.canonicalTextPosition
            )
        }
        let anchor = try projection.makeInitialAnchor(
            memoryID: memoryID,
            from: selection,
            existingPassages: kind == .passage ? existing : []
        )
        let recovery = try MemoryAnchorResolver.confirmInitialSelection(
            anchor: anchor,
            selection: selection,
            currentProjection: projection,
            existingPassages: kind == .passage ? existing : []
        )
        guard recovery.resolution.state == .resolved else {
            throw ProjectionStoreAdapterError.invalidResolution
        }
        let resolution = try ProjectionStoreAdapter.resolutionDraft(
            from: recovery,
            projection: projection
        )
        let repository = try library.requireRepository()
        guard let sourceURL = model.fileURL else {
            throw DocumentProjectionError.staleSourceRevision
        }
        let request = CreateMemoryRequest(
            id: memoryID,
            documentID: document.id,
            kind: kind,
            originalVisibleQuote: selection.selectedVisibleText,
            canonicalMatchQuote: anchor.exactQuote,
            noteText: nil,
            expectedDocumentRecordVersion: document.recordVersion,
            anchor: ProjectionStoreAdapter.newAnchor(from: anchor),
            resolution: resolution
        )
        let mutation = try await repository.createMemory(
            request,
            verifyingSourceAt: sourceURL,
            filePresenter: model.coordinatedFilePresenter,
            expectedRevisionHash: projection.source.revisionHash
        )
        memories.removeAll { $0.memory.id == memoryID }
        memories.append(mutation.storedMemory)
        recoveryResults[memoryID] = recovery
        selectedMemoryID = memoryID
        showsMemorySurface = true
        rebuildPresentations()
        applyMarks()
        if withNote {
            beginEditingNote(memoryID: memoryID)
        }
        errorMessage = nil
        return mutation.undo
    }

    private func recoverAndPersist(
        using repository: MemoryRepository,
        document: DocumentRecord,
        memories storedMemories: [StoredMemory],
        projection: DocumentProjection
    ) async throws -> RecoveryBatch {
        let resolved = try await Task.detached(priority: .userInitiated) {
            let inputs = try storedMemories.compactMap { stored -> (UUID, ConfirmedMemoryAnchor, MemoryResolutionSnapshot?)? in
                guard let anchorID = stored.memory.currentAnchorID,
                      let record = stored.anchors.first(where: { $0.id == anchorID }) else { return nil }
                let anchor = try ProjectionStoreAdapter.confirmedAnchor(from: record)
                let currentResolution = try? ProjectionStoreAdapter.resolutionSnapshot(
                    from: stored.resolution,
                    projection: projection
                )
                return (stored.memory.id, anchor, currentResolution)
            }
            let currentByAnchorID = Dictionary(
                uniqueKeysWithValues: inputs.compactMap { input in
                    input.2.map { (input.1.id, $0) }
                }
            )
            let results = try MemoryAnchorResolver.resolveBatch(
                anchors: inputs.map(\.1),
                currentProjection: projection,
                currentResolutionsByAnchorID: currentByAnchorID
            )
            return zip(inputs, results).map { input, result in
                (input.0, input.1.id, result)
            }
        }.value
        let resolvedByMemory = Dictionary(uniqueKeysWithValues: resolved.map { ($0.0, ($0.1, $0.2)) })
        var updatedMemories = storedMemories
        var results: [UUID: MemoryRecoveryResult] = [:]
        for index in updatedMemories.indices {
            let stored = updatedMemories[index]
            guard let (anchorID, result) = resolvedByMemory[stored.memory.id] else { continue }
            results[stored.memory.id] = result
            let draft = try ProjectionStoreAdapter.resolutionDraft(
                from: result,
                projection: projection
            )
            let needsWrite = stored.resolution.checkedRevisionHash != draft.checkedRevisionHash
                || stored.resolution.state != draft.state
                || stored.resolution.resolvedSelector != draft.resolvedSelector
            if needsWrite {
                let mutation = try await repository.replaceResolution(
                    memoryID: stored.memory.id,
                    anchorID: anchorID,
                    resolution: draft,
                    expectedResolutionRecordVersion: stored.resolution.recordVersion,
                    expectedDocumentRecordVersion: document.recordVersion
                )
                updatedMemories[index].resolution = mutation.resolution
            }
        }
        return RecoveryBatch(memories: updatedMemories, results: results)
    }

    private func rebuildPresentations() {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        presentations = memories
            .sorted { $0.memory.createdAt > $1.memory.createdAt }
            .map { stored in
                let result = recoveryResults[stored.memory.id]
                let state: MemoryPresentation.State
                switch result?.resolution.state ?? ProjectionStoreAdapter.anchorState(stored.resolution.state) {
                case .resolved:
                    state = .resolved
                case .ambiguous:
                    state = .chooseLocation(candidateCount: result?.candidates.count)
                case .needsReview:
                    state = .needsRepair(hasProposedLocation: true)
                case .orphaned:
                    state = .needsRepair(hasProposedLocation: false)
                }
                let anchor = stored.anchors.first { $0.id == stored.memory.currentAnchorID }
                let heading = anchor?.headingPath.last?.title
                let quote = stored.memory.originalVisibleQuote
                let title = heading ?? quote?.split(separator: "\n").first.map(String.init) ?? "Remembered passage"
                let evidence = result?.resolution.evidence.map { evidence in
                    switch evidence {
                    case .exactPassage: "Exact passage"
                    case .matchingPrefix, .matchingSuffix: "matching surrounding text"
                    case .sameBlockFingerprint: "same block"
                    case .sameHeading: "same heading"
                    }
                }
                let candidateLocations = result?.candidates.prefix(8).enumerated().compactMap {
                    offset, candidate -> MemoryPresentation.CandidateLocation? in
                    guard let block = projection?.block(id: candidate.selector.blockID),
                          let passage = CanonicalMarkdownText.substring(
                            block.canonicalText,
                            utf8Range: candidate.selector.canonicalUTF8RangeInBlock
                          ) else { return nil }
                    let heading = block.headingPath.map(\.title).joined(separator: " › ")
                    return MemoryPresentation.CandidateLocation(
                        id: candidate.id,
                        headingPath: heading.isEmpty ? nil : heading,
                        passage: passage,
                        locationLabel: "Location \(offset + 1)"
                    )
                } ?? []
                return MemoryPresentation(
                    id: stored.memory.id,
                    kind: stored.memory.kind == .passage ? .passage : .headingBookmark,
                    state: state,
                    title: title,
                    passage: quote,
                    note: stored.memory.noteText,
                    headingPath: anchor?.headingPath.map(\.title).joined(separator: " › "),
                    savedAt: formatter.localizedString(for: stored.memory.createdAt, relativeTo: Date()),
                    anchorDetails: MemoryPresentation.AnchorDetails(
                        foundBy: Array(Set(evidence ?? [])).joined(separator: " · "),
                        lastChecked: formatter.localizedString(
                            for: stored.resolution.lastCheckedAt,
                            relativeTo: Date()
                        ),
                        candidateSummary: result.map { "\($0.candidates.count)" } ?? "Stored state",
                        savedPassage: quote
                    ),
                    candidateLocations: candidateLocations
                )
            }
    }

    private func applyMarks() {
        guard let projection, let webController else { return }
        let presentationByID = Dictionary(uniqueKeysWithValues: presentations.map { ($0.id, $0) })
        let kindByMemoryID = Dictionary(uniqueKeysWithValues: memories.map { ($0.memory.id, $0.memory.kind) })
        let ordered = recoveryResults
            .compactMap { memoryID, result -> (UUID, ResolvedMemorySelector, MemoryRenderMark.Kind)? in
                guard let storedKind = kindByMemoryID[memoryID] else { return nil }
                if result.resolution.state == .resolved,
                   let selector = result.resolution.resolvedSelector {
                    let kind: MemoryRenderMark.Kind = storedKind == .passage
                        ? .passage
                        : .headingBookmark
                    return (memoryID, selector, kind)
                }
                if result.resolution.state == .ambiguous,
                   let candidate = result.candidates.first {
                    return (memoryID, candidate.selector, .locationChoice)
                }
                return nil
            }
            .sorted {
                if $0.1.canonicalTextPosition.lowerBound != $1.1.canonicalTextPosition.lowerBound {
                    return $0.1.canonicalTextPosition.lowerBound < $1.1.canonicalTextPosition.lowerBound
                }
                return $0.0.uuidString < $1.0.uuidString
            }
        let marks = ordered.enumerated().map { index, pair in
            let presentation = presentationByID[pair.0]
            return MemoryRenderMark(
                memoryID: pair.0,
                token: "mark-\(index)",
                kind: pair.2,
                selector: pair.1,
                accessibilityLabel: presentation?.accessibilityLabel
                    ?? "Resolved remembered passage. \(index + 1) of \(ordered.count) in this document."
            )
        }
        webController.setMemoryMarks(
            marks,
            context: MemoryRenderContext(
                sourceRevisionHash: projection.source.revisionHash,
                projectionVersion: projection.version,
                renderRevision: projection.renderRevision
            )
        )
    }

    private func finishWorking() {
        isWorking = false
        guard let library = pendingStoreRefreshLibrary else { return }
        pendingStoreRefreshLibrary = nil
        Task { [weak self] in
            await self?.refreshFromStore(library: library)
        }
    }

    private func clearForUnavailableProjection() {
        projection = nil
        document = nil
        memories = []
        presentations = []
        recoveryResults = [:]
        editingMemoryID = nil
        editingBaseRecordVersion = nil
        noteDraft = ""
        noteConflict = nil
        readingState = nil
        restoredDocumentID = nil
        pendingDocumentRelinkProposal = nil
        pendingRestoreDeletedAsNewProposal = nil
        webController?.clearMemoryMarks()
    }
}
