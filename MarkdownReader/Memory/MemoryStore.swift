import Foundation

protocol MemoryStore: AnyObject, Sendable {
    var schemaVersion: Int { get }

    func observeChanges() -> AsyncStream<MemoryStoreChange>

    func createDocument(_ document: NewDocument, location: NewDocumentLocation?) throws -> DocumentRecord
    func createReplacementDocument(
        _ document: NewDocument,
        location: NewDocumentLocation,
        replacingDocumentID: UUID,
        expectedReplacedDocumentRecordVersion: Int64
    ) throws -> DocumentRecord
    func document(id: UUID) throws -> DocumentRecord?
    func documents(matching identity: FileIdentity) throws -> [DocumentRecord]
    func documentLocations(documentID: UUID) throws -> [DocumentLocationRecord]
    func recordLocation(
        _ location: NewDocumentLocation,
        for documentID: UUID,
        expectedRecordVersion: Int64
    ) throws -> DocumentRecord
    func updateDocumentMetadata(
        documentID: UUID,
        displayName: String,
        bookmarkData: Data?,
        fileIdentity: FileIdentity,
        lastConfirmedContentHash: String?,
        detectedTextEncoding: String?,
        hadByteOrderMark: Bool?,
        availability: DocumentAvailability,
        openedAt: Date,
        expectedRecordVersion: Int64
    ) throws -> DocumentRecord
    func setFavourite(
        documentID: UUID,
        isFavourite: Bool,
        expectedRecordVersion: Int64
    ) throws -> FavouriteMutation
    func undoFavourite(_ payload: FavouriteUndoPayload) throws -> DocumentRecord

    func readingState(documentID: UUID) throws -> ReadingStateRecord?
    func updateReadingState(
        documentID: UUID,
        update: ReadingStateUpdate,
        expectedRecordVersion: Int64?
    ) throws -> ReadingStateRecord
    func importLegacyReadingStateIfNeeded(
        documentID: UUID,
        legacyKeyHash: String,
        fallbackScrollFraction: Double,
        importedAt: Date
    ) throws -> ReadingStateRecord?

    func createMemory(_ request: CreateMemoryRequest) throws -> CreatedMemoryMutation
    func memory(id: UUID) throws -> StoredMemory?
    func updateNote(
        memoryID: UUID,
        noteText: String?,
        expectedRecordVersion: Int64,
        at: Date
    ) throws -> NoteEditMutation
    func undoNoteEdit(_ payload: NoteEditUndoPayload, at: Date) throws -> ReadingMemoryRecord
    func replaceResolution(
        memoryID: UUID,
        anchorID: UUID,
        resolution: ResolutionDraft,
        expectedResolutionRecordVersion: Int64,
        expectedDocumentRecordVersion: Int64
    ) throws -> ResolutionMutation
    func reattachMemory(
        memoryID: UUID,
        anchor: NewConfirmedAnchor,
        resolution: ResolutionDraft,
        expectedMemoryRecordVersion: Int64,
        expectedResolutionRecordVersion: Int64,
        expectedDocumentRecordVersion: Int64
    ) throws -> ReattachmentMutation
    func undoReattachment(
        _ payload: ReattachmentUndoPayload,
        validatedResolution: ResolutionDraft
    ) throws -> StoredMemory
    func deleteMemory(
        memoryID: UUID,
        expectedRecordVersion: Int64
    ) throws -> DeletedMemoryUndoPayload
    func undoCreateMemory(_ payload: CreateMemoryUndoPayload) throws
    func restoreDeletedMemory(_ payload: DeletedMemoryUndoPayload, at: Date) throws -> StoredMemory
    func validateRestoreDeletedMemoryAsNew(_ request: RestoreDeletedMemoryAsNewRequest) throws
    func restoreDeletedMemoryAsNew(
        _ request: RestoreDeletedMemoryAsNewRequest,
        at: Date
    ) throws -> StoredMemory

    func forgetDocument(
        documentID: UUID,
        expectedRecordVersion: Int64
    ) throws -> ForgottenDocumentUndoPayload
    func restoreForgottenDocument(
        _ payload: ForgottenDocumentUndoPayload,
        at: Date
    ) throws -> DocumentRecord

    func searchMemories(_ query: MemorySearchQuery) throws -> [MemorySearchResult]
    func searchDocuments(_ query: DocumentSearchQuery) throws -> [DocumentSearchResult]
    func snapshot() throws -> MemoryStoreSnapshot
    func snapshotWithSequence() throws -> SequencedMemoryStoreSnapshot
    func currentSequence() throws -> UInt64
}
