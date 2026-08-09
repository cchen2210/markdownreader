import CryptoKit
import Foundation

struct RegisteredMemoryDocument: Equatable, Sendable {
    let document: DocumentRecord
    let location: URL
    let memories: [StoredMemory]
    let readingState: ReadingStateRecord?
}

private struct PendingDocumentRelink: Sendable {
    let proposal: DocumentRelinkProposal
    let candidateIdentity: FileIdentity
}

/// The single asynchronous boundary around the synchronous GRDB store. No
/// document window ever performs database work on the main actor.
actor MemoryRepository {
    private let store: any MemoryStore
    private let legacyReadingPositionDefaults: UserDefaults
    private var activeDocumentLocations: [UUID: URL] = [:]
    private var pendingDocumentRelinks: [UUID: PendingDocumentRelink] = [:]

    init(
        store: any MemoryStore,
        legacyReadingPositionDefaults: UserDefaults = .standard
    ) {
        self.store = store
        self.legacyReadingPositionDefaults = legacyReadingPositionDefaults
    }

    static func live(
        legacyReadingPositionDefaults: UserDefaults = .standard
    ) throws -> MemoryRepository {
        try MemoryRepository(
            store: SQLiteMemoryStore(),
            legacyReadingPositionDefaults: legacyReadingPositionDefaults
        )
    }

    func changes() -> AsyncStream<MemoryStoreChange> {
        store.observeChanges()
    }

    func openDocument(
        at url: URL,
        source: ProjectionSourceMetadata,
        activeDocumentID: UUID? = nil,
        openedAt: Date = Date()
    ) throws -> RegisteredMemoryDocument {
        let observation = try DocumentIdentityProbe.observe(url)
        let bookmark = try? observation.displayURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let snapshotBeforeOpen = try store.snapshot()
        let identityMatches = try store.documents(matching: observation.identity)
        let pathDocuments = Self.currentPathDocuments(
            at: observation.displayURL,
            snapshot: snapshotBeforeOpen
        )
        let currentIdentityMatch = pathDocuments.first { $0.fileIdentity == observation.identity }
        let changedPathRecord = pathDocuments.first { $0.fileIdentity != observation.identity }
        let unambiguousIdentityMatch = changedPathRecord == nil
            ? identityMatches.sorted(by: { $0.lastSeenAt > $1.lastSeenAt }).first
            : nil

        let document: DocumentRecord
        if let existing = currentIdentityMatch ?? unambiguousIdentityMatch {
            var updated = try store.updateDocumentMetadata(
                documentID: existing.id,
                displayName: observation.displayURL.lastPathComponent,
                bookmarkData: bookmark,
                fileIdentity: observation.identity,
                lastConfirmedContentHash: source.revisionHash,
                detectedTextEncoding: source.encoding.rawValue,
                hadByteOrderMark: source.byteOrderMark != .none,
                availability: .available,
                openedAt: openedAt,
                expectedRecordVersion: existing.recordVersion
            )
            let locations = try store.documentLocations(documentID: updated.id)
            if !locations.contains(where: { $0.isCurrent && $0.url.standardizedFileURL == observation.displayURL }) {
                updated = try store.recordLocation(
                    NewDocumentLocation(url: observation.displayURL, observedAt: openedAt),
                    for: updated.id,
                    expectedRecordVersion: updated.recordVersion
                )
            }
            document = updated
        } else if let collided = changedPathRecord {
            let identityConflicts = identityMatches
                .map(\.id)
                .filter { $0 != collided.id }
                .sorted { $0.uuidString < $1.uuidString }
            let activePath = activeDocumentLocations[collided.id]?.standardizedFileURL
            if activeDocumentID == collided.id,
               activePath == observation.displayURL.standardizedFileURL,
               identityConflicts.isEmpty {
                // The in-process session already proved continuity by opening
                // this exact record/path. Atomic-save inode replacement may
                // update identity without changing the durable document UUID.
                document = try recordActiveMove(
                    documentID: collided.id,
                    to: observation.displayURL,
                    source: source,
                    movedAt: openedAt,
                    expectedDocumentRecordVersion: collided.recordVersion
                )
            } else {
                throw DocumentIdentityDecisionRequiredError(
                    decision: Self.openIdentityDecision(
                        document: collided,
                        registeredURL: Self.currentURL(
                            for: collided.id,
                            snapshot: snapshotBeforeOpen
                        ) ?? observation.displayURL,
                        observation: observation,
                        source: source,
                        identityMatchedDocumentIDs: identityConflicts
                    )
                )
            }
        } else if let activeDocumentID,
                  let activeURL = activeDocumentLocations[activeDocumentID],
                  let activeDocument = try store.document(id: activeDocumentID) {
            // A changed identity at a different path is not the same-path
            // atomic-save exception. It requires the explicit relink flow.
            throw DocumentIdentityDecisionRequiredError(
                decision: Self.openIdentityDecision(
                    document: activeDocument,
                    registeredURL: activeURL,
                    observation: observation,
                    source: source,
                    identityMatchedDocumentIDs: []
                )
            )
        } else {
            // Same bytes are deliberately irrelevant here: a copy receives a
            // new UUID. Any older same-path record remains available for an
            // explicit replacement/relink decision instead of being merged.
            document = try store.createDocument(
                NewDocument(
                    displayName: observation.displayURL.lastPathComponent,
                    bookmarkData: bookmark,
                    fileIdentity: observation.identity,
                    lastConfirmedContentHash: source.revisionHash,
                    detectedTextEncoding: source.encoding.rawValue,
                    hadByteOrderMark: source.byteOrderMark != .none,
                    availability: .available,
                    createdAt: openedAt
                ),
                location: NewDocumentLocation(url: observation.displayURL, observedAt: openedAt)
            )
        }

        activeDocumentLocations[document.id] = observation.displayURL
        try ReadingPositionStore.consumeLegacyPosition(
            for: observation.displayURL,
            defaults: legacyReadingPositionDefaults
        ) { legacyPosition in
            // The SQLite operation atomically creates reading_state (only when
            // absent) and records this one hashed legacy key as consumed. The
            // UserDefaults value is removed only after that transaction commits.
            _ = try store.importLegacyReadingStateIfNeeded(
                documentID: document.id,
                legacyKeyHash: legacyPosition.keyHash,
                fallbackScrollFraction: legacyPosition.fraction,
                importedAt: openedAt
            )
        }
        let snapshot = try store.snapshot()
        return RegisteredMemoryDocument(
            document: document,
            location: observation.displayURL,
            memories: snapshot.memories.filter { $0.memory.documentID == document.id },
            readingState: snapshot.readingStates.first { $0.documentID == document.id }
        )
    }

    private func recordActiveMove(
        documentID: UUID,
        to newURL: URL,
        source: ProjectionSourceMetadata,
        movedAt: Date = Date(),
        expectedDocumentRecordVersion: Int64? = nil,
        expectedFileIdentity: FileIdentity? = nil
    ) throws -> DocumentRecord {
        guard var document = try store.document(id: documentID) else {
            throw MemoryStoreError.notFound(.document)
        }
        let observation = try DocumentIdentityProbe.observe(newURL)
        if let expectedFileIdentity,
           observation.identity != expectedFileIdentity {
            throw DocumentRelinkError.proposalChanged
        }
        if let expectedDocumentRecordVersion,
           document.recordVersion != expectedDocumentRecordVersion {
            throw MemoryStoreError.versionConflict(
                entity: .document,
                expected: expectedDocumentRecordVersion,
                actual: document.recordVersion
            )
        }
        let snapshot = try store.snapshot()
        let conflicts = try conflictingDocumentIDs(
            for: observation,
            candidateURL: observation.displayURL,
            excluding: documentID,
            snapshot: snapshot
        )
        guard conflicts.isEmpty else {
            throw DocumentRelinkError.candidateAlreadyRegistered(conflicts)
        }
        document = try store.updateDocumentMetadata(
            documentID: documentID,
            displayName: observation.displayURL.lastPathComponent,
            bookmarkData: try? observation.displayURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ),
            fileIdentity: observation.identity,
            lastConfirmedContentHash: source.revisionHash,
            detectedTextEncoding: source.encoding.rawValue,
            hadByteOrderMark: source.byteOrderMark != .none,
            availability: .available,
            openedAt: movedAt,
            expectedRecordVersion: document.recordVersion
        )
        let alreadyCurrent = Self.currentURL(for: documentID, snapshot: snapshot)?
            .standardizedFileURL == observation.displayURL.standardizedFileURL
        if !alreadyCurrent {
            document = try store.recordLocation(
                NewDocumentLocation(url: observation.displayURL, observedAt: movedAt),
                for: documentID,
                expectedRecordVersion: document.recordVersion
            )
        }
        activeDocumentLocations[documentID] = observation.displayURL
        return document
    }

    /// Builds ephemeral identity, byte-hash, and exact-recovery evidence for a
    /// Locate Original candidate. This method does not mutate the store.
    func stageDocumentRelink(
        documentID: UUID,
        to candidateURL: URL
    ) throws -> DocumentRelinkProposal {
        guard let document = try store.document(id: documentID) else {
            throw MemoryStoreError.notFound(.document)
        }
        let snapshot = try store.snapshot()
        guard let oldURL = Self.currentURL(for: documentID, snapshot: snapshot)
            ?? Self.mostRecentURL(for: documentID, snapshot: snapshot) else {
            throw MemoryStoreError.notFound(.documentLocation)
        }
        let observation = try DocumentIdentityProbe.observe(candidateURL)
        let projection = try Self.projection(at: observation.displayURL)
        let conflicts = try conflictingDocumentIDs(
            for: observation,
            candidateURL: observation.displayURL,
            excluding: documentID,
            snapshot: snapshot
        )
        let recovery = Self.recoveryEvidence(
            documentID: documentID,
            projection: projection,
            snapshot: snapshot
        )
        let proposal = DocumentRelinkProposal(
            id: UUID(),
            documentID: documentID,
            documentDisplayName: document.displayName,
            oldPath: oldURL,
            candidatePath: observation.displayURL,
            storedIdentityFingerprint: Self.identityFingerprint(document.fileIdentity),
            candidateIdentityFingerprint: Self.identityFingerprint(observation.identity),
            identitiesMatch: document.fileIdentity == observation.identity,
            storedContentHash: document.lastConfirmedContentHash,
            candidateContentHash: projection.source.revisionHash,
            recovery: recovery,
            conflictingDocumentIDs: conflicts,
            expectedDocumentRecordVersion: document.recordVersion
        )
        pendingDocumentRelinks[proposal.id] = PendingDocumentRelink(
            proposal: proposal,
            candidateIdentity: observation.identity
        )
        return proposal
    }

    /// Re-probes the candidate and all displayed evidence before the one
    /// authorized record move. Stale review data fails closed.
    func confirmDocumentRelink(
        proposalID: UUID,
        confirmedAt: Date = Date()
    ) throws -> DocumentRecord {
        guard let pending = pendingDocumentRelinks[proposalID] else {
            throw DocumentRelinkError.proposalNotFound
        }
        let proposal = pending.proposal
        guard proposal.conflictingDocumentIDs.isEmpty else {
            throw DocumentRelinkError.candidateAlreadyRegistered(proposal.conflictingDocumentIDs)
        }
        guard let document = try store.document(id: proposal.documentID),
              document.recordVersion == proposal.expectedDocumentRecordVersion else {
            pendingDocumentRelinks.removeValue(forKey: proposalID)
            throw DocumentRelinkError.proposalChanged
        }
        let snapshot = try store.snapshot()
        guard (Self.currentURL(for: proposal.documentID, snapshot: snapshot)
                ?? Self.mostRecentURL(for: proposal.documentID, snapshot: snapshot))?.standardizedFileURL
                == proposal.oldPath.standardizedFileURL else {
            pendingDocumentRelinks.removeValue(forKey: proposalID)
            throw DocumentRelinkError.proposalChanged
        }

        let observation = try DocumentIdentityProbe.observe(proposal.candidatePath)
        let projection = try Self.projection(at: observation.displayURL)
        let conflicts = try conflictingDocumentIDs(
            for: observation,
            candidateURL: observation.displayURL,
            excluding: proposal.documentID,
            snapshot: snapshot
        )
        guard conflicts.isEmpty else {
            pendingDocumentRelinks.removeValue(forKey: proposalID)
            throw DocumentRelinkError.candidateAlreadyRegistered(conflicts)
        }
        let recovery = Self.recoveryEvidence(
            documentID: proposal.documentID,
            projection: projection,
            snapshot: snapshot
        )
        guard observation.identity == pending.candidateIdentity,
              observation.displayURL.standardizedFileURL == proposal.candidatePath.standardizedFileURL,
              projection.source.revisionHash == proposal.candidateContentHash,
              Self.identityFingerprint(document.fileIdentity) == proposal.storedIdentityFingerprint,
              document.lastConfirmedContentHash == proposal.storedContentHash,
              recovery == proposal.recovery else {
            pendingDocumentRelinks.removeValue(forKey: proposalID)
            throw DocumentRelinkError.proposalChanged
        }

        let updated = try withCoordinatedSource(
            at: observation.displayURL,
            filePresenter: nil,
            expectedRevisionHash: proposal.candidateContentHash
        ) {
            try recordActiveMove(
                documentID: proposal.documentID,
                to: observation.displayURL,
                source: projection.source,
                movedAt: confirmedAt,
                expectedDocumentRecordVersion: proposal.expectedDocumentRecordVersion,
                expectedFileIdentity: pending.candidateIdentity
            )
        }
        pendingDocumentRelinks.removeValue(forKey: proposalID)
        return updated
    }

    /// Confirms that a same-path, different-identity file is a replacement,
    /// not the original document. The prior document and all of its memories
    /// remain intact; a new document UUID is created for the replacement.
    /// Future opens prefer the current path record whose filesystem identity
    /// matches, so the two histories are never merged implicitly.
    func confirmDocumentReplacement(
        proposalID: UUID,
        confirmedAt: Date = Date()
    ) throws -> DocumentRecord {
        guard let pending = pendingDocumentRelinks[proposalID] else {
            throw DocumentRelinkError.proposalNotFound
        }
        let proposal = pending.proposal
        guard proposal.conflictingDocumentIDs.isEmpty else {
            throw DocumentRelinkError.candidateAlreadyRegistered(proposal.conflictingDocumentIDs)
        }
        guard let original = try store.document(id: proposal.documentID),
              original.recordVersion == proposal.expectedDocumentRecordVersion else {
            pendingDocumentRelinks.removeValue(forKey: proposalID)
            throw DocumentRelinkError.proposalChanged
        }
        let snapshot = try store.snapshot()
        guard Self.currentURL(for: proposal.documentID, snapshot: snapshot)?.standardizedFileURL
                == proposal.oldPath.standardizedFileURL else {
            pendingDocumentRelinks.removeValue(forKey: proposalID)
            throw DocumentRelinkError.proposalChanged
        }

        let observation = try DocumentIdentityProbe.observe(proposal.candidatePath)
        let projection = try Self.projection(at: observation.displayURL)
        let conflicts = try conflictingDocumentIDs(
            for: observation,
            candidateURL: observation.displayURL,
            excluding: proposal.documentID,
            snapshot: snapshot
        )
        guard conflicts.isEmpty else {
            pendingDocumentRelinks.removeValue(forKey: proposalID)
            throw DocumentRelinkError.candidateAlreadyRegistered(conflicts)
        }
        let recovery = Self.recoveryEvidence(
            documentID: proposal.documentID,
            projection: projection,
            snapshot: snapshot
        )
        guard observation.identity == pending.candidateIdentity,
              observation.displayURL.standardizedFileURL == proposal.candidatePath.standardizedFileURL,
              projection.source.revisionHash == proposal.candidateContentHash,
              Self.identityFingerprint(original.fileIdentity) == proposal.storedIdentityFingerprint,
              original.lastConfirmedContentHash == proposal.storedContentHash,
              recovery == proposal.recovery else {
            pendingDocumentRelinks.removeValue(forKey: proposalID)
            throw DocumentRelinkError.proposalChanged
        }

        let created = try withCoordinatedSource(
            at: observation.displayURL,
            filePresenter: nil,
            expectedRevisionHash: proposal.candidateContentHash
        ) {
            let finalObservation = try DocumentIdentityProbe.observe(observation.displayURL)
            guard finalObservation.identity == pending.candidateIdentity else {
                throw DocumentRelinkError.proposalChanged
            }
            return try store.createReplacementDocument(
                NewDocument(
                    displayName: finalObservation.displayURL.lastPathComponent,
                    bookmarkData: try? finalObservation.displayURL.bookmarkData(
                        options: [.withSecurityScope],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ),
                    fileIdentity: finalObservation.identity,
                    lastConfirmedContentHash: projection.source.revisionHash,
                    detectedTextEncoding: projection.source.encoding.rawValue,
                    hadByteOrderMark: projection.source.byteOrderMark != .none,
                    availability: .available,
                    createdAt: confirmedAt
                ),
                location: NewDocumentLocation(
                    url: finalObservation.displayURL,
                    observedAt: confirmedAt
                ),
                replacingDocumentID: original.id,
                expectedReplacedDocumentRecordVersion: proposal.expectedDocumentRecordVersion
            )
        }
        activeDocumentLocations.removeValue(forKey: original.id)
        activeDocumentLocations[created.id] = observation.displayURL
        pendingDocumentRelinks.removeValue(forKey: proposalID)
        return created
    }

    func cancelDocumentRelink(proposalID: UUID) {
        pendingDocumentRelinks.removeValue(forKey: proposalID)
    }

    func documentState(documentID: UUID) throws -> RegisteredMemoryDocument? {
        guard let document = try store.document(id: documentID) else { return nil }
        let snapshot = try store.snapshot()
        let currentURL = snapshot.documentLocations
            .filter { $0.documentID == documentID && $0.isCurrent }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .first?.url ?? activeDocumentLocations[documentID]
        guard let currentURL else { return nil }
        return RegisteredMemoryDocument(
            document: document,
            location: currentURL,
            memories: snapshot.memories.filter { $0.memory.documentID == documentID },
            readingState: snapshot.readingStates.first { $0.documentID == documentID }
        )
    }

    func createMemory(_ request: CreateMemoryRequest) throws -> CreatedMemoryMutation {
        try store.createMemory(request)
    }

    /// Holds coordinated read access from the final byte-hash check through
    /// the synchronous SQLite transaction. An external coordinated writer
    /// cannot replace the source between validation and capture commit.
    func createMemory(
        _ request: CreateMemoryRequest,
        verifyingSourceAt sourceURL: URL,
        filePresenter: FileRefreshPresenter?,
        expectedRevisionHash: String
    ) throws -> CreatedMemoryMutation {
        try withCoordinatedSource(
            at: sourceURL,
            filePresenter: filePresenter,
            expectedRevisionHash: expectedRevisionHash
        ) {
            try store.createMemory(request)
        }
    }

    func memory(id: UUID) throws -> StoredMemory? {
        try store.memory(id: id)
    }

    func updateNote(
        memoryID: UUID,
        noteText: String?,
        expectedRecordVersion: Int64,
        at: Date = Date()
    ) throws -> NoteEditMutation {
        try store.updateNote(
            memoryID: memoryID,
            noteText: noteText,
            expectedRecordVersion: expectedRecordVersion,
            at: at
        )
    }

    func replaceResolution(
        memoryID: UUID,
        anchorID: UUID,
        resolution: ResolutionDraft,
        expectedResolutionRecordVersion: Int64,
        expectedDocumentRecordVersion: Int64
    ) throws -> ResolutionMutation {
        try store.replaceResolution(
            memoryID: memoryID,
            anchorID: anchorID,
            resolution: resolution,
            expectedResolutionRecordVersion: expectedResolutionRecordVersion,
            expectedDocumentRecordVersion: expectedDocumentRecordVersion
        )
    }

    func reattachMemory(
        memoryID: UUID,
        anchor: NewConfirmedAnchor,
        resolution: ResolutionDraft,
        expectedMemoryRecordVersion: Int64,
        expectedResolutionRecordVersion: Int64,
        expectedDocumentRecordVersion: Int64
    ) throws -> ReattachmentMutation {
        try store.reattachMemory(
            memoryID: memoryID,
            anchor: anchor,
            resolution: resolution,
            expectedMemoryRecordVersion: expectedMemoryRecordVersion,
            expectedResolutionRecordVersion: expectedResolutionRecordVersion,
            expectedDocumentRecordVersion: expectedDocumentRecordVersion
        )
    }

    func reattachMemory(
        memoryID: UUID,
        anchor: NewConfirmedAnchor,
        resolution: ResolutionDraft,
        expectedMemoryRecordVersion: Int64,
        expectedResolutionRecordVersion: Int64,
        expectedDocumentRecordVersion: Int64,
        verifyingSourceAt sourceURL: URL,
        filePresenter: FileRefreshPresenter?,
        expectedRevisionHash: String
    ) throws -> ReattachmentMutation {
        try withCoordinatedSource(
            at: sourceURL,
            filePresenter: filePresenter,
            expectedRevisionHash: expectedRevisionHash
        ) {
            try store.reattachMemory(
                memoryID: memoryID,
                anchor: anchor,
                resolution: resolution,
                expectedMemoryRecordVersion: expectedMemoryRecordVersion,
                expectedResolutionRecordVersion: expectedResolutionRecordVersion,
                expectedDocumentRecordVersion: expectedDocumentRecordVersion
            )
        }
    }

    func undoReattachment(
        _ payload: ReattachmentUndoPayload,
        validatedResolution: ResolutionDraft
    ) throws -> StoredMemory {
        try store.undoReattachment(payload, validatedResolution: validatedResolution)
    }

    func undoReattachment(
        _ payload: ReattachmentUndoPayload,
        validatedResolution: ResolutionDraft,
        expectedCurrentAnchorID: UUID,
        verifyingSourceAt sourceURL: URL,
        filePresenter: FileRefreshPresenter?,
        expectedRevisionHash: String
    ) throws -> StoredMemory {
        try withCoordinatedSource(
            at: sourceURL,
            filePresenter: filePresenter,
            expectedRevisionHash: expectedRevisionHash
        ) {
            guard let current = try store.memory(id: payload.memoryID) else {
                throw MemoryStoreError.notFound(.memory)
            }
            guard current.memory.currentAnchorID == expectedCurrentAnchorID else {
                throw MemoryStoreError.versionConflict(
                    entity: .memory,
                    expected: payload.expectedMemoryRecordVersion,
                    actual: current.memory.recordVersion
                )
            }
            guard let document = try store.document(id: current.memory.documentID) else {
                throw MemoryStoreError.notFound(.document)
            }
            var refreshed = payload
            refreshed.expectedDocumentRecordVersion = document.recordVersion
            refreshed.expectedMemoryRecordVersion = current.memory.recordVersion
            refreshed.expectedResolutionRecordVersion = current.resolution.recordVersion
            return try store.undoReattachment(
                refreshed,
                validatedResolution: validatedResolution
            )
        }
    }

    func undoCreateMemory(_ payload: CreateMemoryUndoPayload) throws {
        try store.undoCreateMemory(payload)
    }

    func undoNoteEdit(_ payload: NoteEditUndoPayload, at: Date = Date()) throws -> ReadingMemoryRecord {
        try store.undoNoteEdit(payload, at: at)
    }

    func undoFavourite(_ payload: FavouriteUndoPayload) throws -> DocumentRecord {
        try store.undoFavourite(payload)
    }

    func deleteMemory(memoryID: UUID, expectedRecordVersion: Int64) throws -> DeletedMemoryUndoPayload {
        try store.deleteMemory(memoryID: memoryID, expectedRecordVersion: expectedRecordVersion)
    }

    func restoreDeletedMemory(_ payload: DeletedMemoryUndoPayload, at: Date = Date()) throws -> StoredMemory {
        try store.restoreDeletedMemory(payload, at: at)
    }

    /// Performs a read-only safety check for the explicit fallback shown after
    /// exact deletion undo fails. No memory is created here. The proposal pins
    /// the current document version, registered file identity, and byte hash so
    /// confirmation cannot silently turn into a restore against newer state.
    func prepareRestoreDeletedMemoryAsNew(
        _ payload: DeletedMemoryUndoPayload,
        sourceURL preferredSourceURL: URL? = nil,
        filePresenter: FileRefreshPresenter? = nil
    ) throws -> RestoreDeletedMemoryAsNewProposal {
        let documentID = payload.storedMemory.memory.documentID
        guard let document = try store.document(id: documentID),
              document.fileIdentity.isComplete else {
            throw MemoryStoreError.staleSourceIdentity
        }
        let snapshot = try store.snapshot()
        guard let sourceURL = preferredSourceURL
            ?? Self.currentURL(for: documentID, snapshot: snapshot)
            ?? activeDocumentLocations[documentID] else {
            throw MemoryStoreError.invalidRecord("The registered Markdown file is unavailable.")
        }
        let revisionHash = payload.storedMemory.resolution.checkedRevisionHash
        let request = RestoreDeletedMemoryAsNewRequest(
            deleted: payload,
            expectedDocumentRecordVersion: document.recordVersion
        )
        try store.validateRestoreDeletedMemoryAsNew(request)
        try withCoordinatedSource(
            at: sourceURL,
            filePresenter: filePresenter,
            expectedRevisionHash: revisionHash,
            expectedFileIdentity: document.fileIdentity
        ) {}
        return RestoreDeletedMemoryAsNewProposal(
            request: request,
            sourceURL: sourceURL.standardizedFileURL,
            expectedFileIdentity: document.fileIdentity,
            expectedRevisionHash: revisionHash
        )
    }

    /// Commits only after rechecking the exact proposal that the user saw.
    /// The store repeats all lineage, revision, overlap, and optimistic-version
    /// checks inside the same SQLite write transaction.
    func restoreDeletedMemoryAsNew(
        _ proposal: RestoreDeletedMemoryAsNewProposal,
        filePresenter: FileRefreshPresenter? = nil,
        at: Date = Date()
    ) throws -> StoredMemory {
        guard let document = try store.document(
            id: proposal.deletedMemory.memory.documentID
        ), document.fileIdentity == proposal.expectedFileIdentity else {
            throw MemoryStoreError.staleSourceIdentity
        }
        return try withCoordinatedSource(
            at: proposal.sourceURL,
            filePresenter: filePresenter,
            expectedRevisionHash: proposal.expectedRevisionHash,
            expectedFileIdentity: proposal.expectedFileIdentity
        ) {
            try store.restoreDeletedMemoryAsNew(proposal.request, at: at)
        }
    }

    func forgetDocument(
        documentID: UUID,
        expectedRecordVersion: Int64
    ) throws -> ForgottenDocumentUndoPayload {
        try store.forgetDocument(
            documentID: documentID,
            expectedRecordVersion: expectedRecordVersion
        )
    }

    func restoreForgottenDocument(
        _ payload: ForgottenDocumentUndoPayload,
        at: Date = Date()
    ) throws -> DocumentRecord {
        try store.restoreForgottenDocument(payload, at: at)
    }

    func setFavourite(
        documentID: UUID,
        isFavourite: Bool,
        expectedRecordVersion: Int64
    ) throws -> FavouriteMutation {
        try store.setFavourite(
            documentID: documentID,
            isFavourite: isFavourite,
            expectedRecordVersion: expectedRecordVersion
        )
    }

    func readingState(documentID: UUID) throws -> ReadingStateRecord? {
        try store.readingState(documentID: documentID)
    }

    func updateReadingState(
        documentID: UUID,
        update: ReadingStateUpdate,
        expectedRecordVersion: Int64?
    ) throws -> ReadingStateRecord {
        try store.updateReadingState(
            documentID: documentID,
            update: update,
            expectedRecordVersion: expectedRecordVersion
        )
    }

    func searchMemories(_ query: MemorySearchQuery) throws -> [MemorySearchResult] {
        try store.searchMemories(query)
    }

    func searchDocuments(_ query: DocumentSearchQuery) throws -> [DocumentSearchResult] {
        try store.searchDocuments(query)
    }

    func snapshot() throws -> MemoryStoreSnapshot {
        try store.snapshot()
    }

    func snapshotWithSequence() throws -> SequencedMemoryStoreSnapshot {
        try store.snapshotWithSequence()
    }

    func currentSequence() throws -> UInt64 {
        try store.currentSequence()
    }

    /// This synchronous actor-isolated method intentionally has no suspension
    /// point between the durable sequence read and atomic replacement. A
    /// mutation submitted through this repository cannot interleave there.
    func writeArchive(
        _ payload: MemoryArchivePayload,
        representation: MemoryArchiveRepresentation,
        to destinationURL: URL
    ) throws {
        let sequence = try store.currentSequence()
        try MemoryArchiveAtomicWriter.write(
            payload,
            representation: representation,
            currentStoreSequence: sequence,
            to: destinationURL
        )
    }

    private func conflictingDocumentIDs(
        for observation: DocumentIdentityProbe.Observation,
        candidateURL: URL,
        excluding documentID: UUID,
        snapshot: MemoryStoreSnapshot
    ) throws -> [UUID] {
        var identifiers = Set(
            try store.documents(matching: observation.identity)
                .map(\.id)
                .filter { $0 != documentID }
        )
        identifiers.formUnion(
            Self.currentPathDocuments(at: candidateURL, snapshot: snapshot)
                .map(\.id)
                .filter { $0 != documentID }
        )
        return identifiers.sorted { $0.uuidString < $1.uuidString }
    }

    private static func projection(at url: URL) throws -> DocumentProjection {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try DocumentProjection.build(sourceData: data, documentURL: url)
    }

    private static func currentPathDocuments(
        at url: URL,
        snapshot: MemoryStoreSnapshot
    ) -> [DocumentRecord] {
        let path = url.standardizedFileURL.path
        let documentByID = Dictionary(uniqueKeysWithValues: snapshot.documents.map { ($0.id, $0) })
        return snapshot.documentLocations
            .filter { $0.isCurrent && $0.url.standardizedFileURL.path == path }
            .sorted {
                if $0.lastSeenAt == $1.lastSeenAt {
                    return $0.documentID.uuidString < $1.documentID.uuidString
                }
                return $0.lastSeenAt > $1.lastSeenAt
            }
            .compactMap { documentByID[$0.documentID] }
    }

    private static func currentURL(
        for documentID: UUID,
        snapshot: MemoryStoreSnapshot
    ) -> URL? {
        snapshot.documentLocations
            .filter { $0.documentID == documentID && $0.isCurrent }
            .sorted {
                if $0.lastSeenAt == $1.lastSeenAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.lastSeenAt > $1.lastSeenAt
            }
            .first?.url
    }

    private static func mostRecentURL(
        for documentID: UUID,
        snapshot: MemoryStoreSnapshot
    ) -> URL? {
        snapshot.documentLocations
            .filter { $0.documentID == documentID }
            .sorted {
                if $0.lastSeenAt == $1.lastSeenAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.lastSeenAt > $1.lastSeenAt
            }
            .first?.url
    }

    private static func openIdentityDecision(
        document: DocumentRecord,
        registeredURL: URL,
        observation: DocumentIdentityProbe.Observation,
        source: ProjectionSourceMetadata,
        identityMatchedDocumentIDs: [UUID]
    ) -> DocumentOpenIdentityDecision {
        DocumentOpenIdentityDecision(
            registeredDocumentID: document.id,
            registeredPath: registeredURL,
            candidatePath: observation.displayURL,
            storedIdentityFingerprint: identityFingerprint(document.fileIdentity),
            candidateIdentityFingerprint: identityFingerprint(observation.identity),
            storedContentHash: document.lastConfirmedContentHash,
            candidateContentHash: source.revisionHash,
            identityMatchedDocumentIDs: identityMatchedDocumentIDs
        )
    }

    private static func identityFingerprint(_ identity: FileIdentity) -> String {
        guard identity.isComplete else { return "Unavailable" }
        var payload = Data()
        for component in [identity.volumeIdentifier, identity.fileResourceIdentifier] {
            let value = component ?? Data()
            var length = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
            payload.append(value)
        }
        return SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func recoveryEvidence(
        documentID: UUID,
        projection: DocumentProjection,
        snapshot: MemoryStoreSnapshot
    ) -> DocumentRelinkRecoveryEvidence {
        let memories = snapshot.memories.filter { $0.memory.documentID == documentID }
        var resolved = 0
        var ambiguous = 0
        var needsReview = 0
        var orphaned = 0
        var invalid = 0
        for stored in memories {
            guard let anchorID = stored.memory.currentAnchorID,
                  let record = stored.anchors.first(where: { $0.id == anchorID }) else {
                invalid += 1
                continue
            }
            do {
                let anchor = try ProjectionStoreAdapter.confirmedAnchor(from: record)
                let currentResolution = try? ProjectionStoreAdapter.resolutionSnapshot(
                    from: stored.resolution,
                    projection: projection
                )
                let result = try MemoryAnchorResolver.resolve(
                    anchor: anchor,
                    currentProjection: projection,
                    currentResolution: currentResolution
                )
                switch result.resolution.state {
                case .resolved: resolved += 1
                case .ambiguous: ambiguous += 1
                case .needsReview: needsReview += 1
                case .orphaned: orphaned += 1
                }
            } catch {
                invalid += 1
            }
        }
        return DocumentRelinkRecoveryEvidence(
            memoryCount: memories.count,
            resolvedCount: resolved,
            ambiguousCount: ambiguous,
            needsReviewCount: needsReview,
            orphanedCount: orphaned,
            invalidAnchorCount: invalid
        )
    }

    private func withCoordinatedSource<Value>(
        at sourceURL: URL,
        filePresenter: FileRefreshPresenter?,
        expectedRevisionHash: String,
        expectedFileIdentity: FileIdentity? = nil,
        operation: () throws -> Value
    ) throws -> Value {
        var coordinatorError: NSError?
        var result: Result<Value, Error>?
        let coordinator = NSFileCoordinator(filePresenter: filePresenter)
        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: [],
            error: &coordinatorError
        ) { coordinatedURL in
            result = Result {
                if let expectedFileIdentity {
                    guard expectedFileIdentity.isComplete,
                          try DocumentIdentityProbe.observe(coordinatedURL).identity
                            == expectedFileIdentity else {
                        throw MemoryStoreError.staleSourceIdentity
                    }
                }
                let data = try Data(contentsOf: coordinatedURL, options: .mappedIfSafe)
                let hash = SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
                guard hash == expectedRevisionHash else {
                    throw MemoryStoreError.staleSourceRevision
                }
                return try operation()
            }
        }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

}
