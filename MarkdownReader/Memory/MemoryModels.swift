import Foundation

enum DocumentAvailability: String, Codable, CaseIterable, Sendable {
    case available
    case unavailable
}

enum ReadingMemoryKind: String, Codable, CaseIterable, Sendable {
    case passage
    case headingBookmark
}

enum AnchorConfirmation: String, Codable, CaseIterable, Sendable {
    case initialCapture
    case manualReattach
}

enum MemoryResolutionState: String, Codable, CaseIterable, Sendable {
    case resolved
    case ambiguous
    case needsReview
    case orphaned
}

enum MemoryHistoryKind: String, Codable, CaseIterable, Sendable {
    case created
    case noteEdited
    case resolutionChanged
    case reattached
    case restored
}

struct FileIdentity: Codable, Equatable, Sendable {
    var volumeIdentifier: Data?
    var fileResourceIdentifier: Data?

    init(volumeIdentifier: Data? = nil, fileResourceIdentifier: Data? = nil) {
        self.volumeIdentifier = volumeIdentifier
        self.fileResourceIdentifier = fileResourceIdentifier
    }

    var isComplete: Bool {
        volumeIdentifier != nil && fileResourceIdentifier != nil
    }
}

struct DocumentRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var displayName: String
    var bookmarkData: Data?
    var fileIdentity: FileIdentity
    var lastConfirmedContentHash: String?
    var detectedTextEncoding: String?
    var hadByteOrderMark: Bool?
    var availability: DocumentAvailability
    var isFavourite: Bool
    var recordVersion: Int64
    var createdAt: Date
    var lastOpenedAt: Date
    var lastSeenAt: Date
}

struct NewDocument: Codable, Equatable, Sendable {
    var id: UUID
    var displayName: String
    var bookmarkData: Data?
    var fileIdentity: FileIdentity
    var lastConfirmedContentHash: String?
    var detectedTextEncoding: String?
    var hadByteOrderMark: Bool?
    var availability: DocumentAvailability
    var isFavourite: Bool
    var createdAt: Date
    var lastOpenedAt: Date
    var lastSeenAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        bookmarkData: Data? = nil,
        fileIdentity: FileIdentity = FileIdentity(),
        lastConfirmedContentHash: String? = nil,
        detectedTextEncoding: String? = nil,
        hadByteOrderMark: Bool? = nil,
        availability: DocumentAvailability = .available,
        isFavourite: Bool = false,
        createdAt: Date = Date(),
        lastOpenedAt: Date? = nil,
        lastSeenAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.fileIdentity = fileIdentity
        self.lastConfirmedContentHash = lastConfirmedContentHash
        self.detectedTextEncoding = detectedTextEncoding
        self.hadByteOrderMark = hadByteOrderMark
        self.availability = availability
        self.isFavourite = isFavourite
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt ?? createdAt
        self.lastSeenAt = lastSeenAt ?? createdAt
    }
}

struct DocumentLocationRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var documentID: UUID
    var url: URL
    var isCurrent: Bool
    var firstSeenAt: Date
    var lastSeenAt: Date
}

struct NewDocumentLocation: Codable, Equatable, Sendable {
    var id: UUID
    var url: URL
    var observedAt: Date

    init(id: UUID = UUID(), url: URL, observedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.observedAt = observedAt
    }
}

struct SemanticReadingPosition: Codable, Equatable, Sendable {
    var blockFingerprint: String
    var canonicalUTF8Offset: Int64

    init(blockFingerprint: String, canonicalUTF8Offset: Int64) {
        self.blockFingerprint = blockFingerprint
        self.canonicalUTF8Offset = canonicalUTF8Offset
    }
}

struct ReadingStateRecord: Codable, Equatable, Sendable {
    var documentID: UUID
    var semanticPosition: SemanticReadingPosition?
    var fallbackScrollFraction: Double
    var lastSemanticHeading: String?
    var lastReadAt: Date
    var recordVersion: Int64
}

struct ReadingStateUpdate: Codable, Equatable, Sendable {
    var semanticPosition: SemanticReadingPosition?
    var fallbackScrollFraction: Double
    var lastSemanticHeading: String?
    var lastReadAt: Date

    init(
        semanticPosition: SemanticReadingPosition?,
        fallbackScrollFraction: Double,
        lastSemanticHeading: String? = nil,
        lastReadAt: Date = Date()
    ) {
        self.semanticPosition = semanticPosition
        self.fallbackScrollFraction = fallbackScrollFraction
        self.lastSemanticHeading = lastSemanticHeading
        self.lastReadAt = lastReadAt
    }
}

struct CanonicalTextRange: Codable, Equatable, Sendable {
    var lowerBound: Int64
    var upperBound: Int64

    init(lowerBound: Int64, upperBound: Int64) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    var isValid: Bool {
        lowerBound >= 0 && upperBound >= lowerBound
    }
}

struct SourceUTF8Span: Codable, Equatable, Sendable {
    var lowerBound: Int64
    var upperBound: Int64

    init(lowerBound: Int64, upperBound: Int64) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    var isValid: Bool {
        lowerBound >= 0 && upperBound >= lowerBound
    }
}

struct StoredHeadingBreadcrumb: Codable, Equatable, Sendable {
    var level: Int
    var title: String

    init(level: Int, title: String) {
        self.level = level
        self.title = title
    }
}

struct ResolvedSelector: Codable, Equatable, Sendable {
    var sourceRevisionHash: String
    var projectionVersion: Int
    var blockID: String
    var canonicalUTF8RangeInBlock: CanonicalTextRange
    var canonicalTextPosition: CanonicalTextRange
    var blockKind: String
    var blockFingerprint: String
    var headingPath: [StoredHeadingBreadcrumb]
    var blockOrdinal: Int64
    var sourceUTF8Span: SourceUTF8Span?
}

struct ResolutionEvidence: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case exactQuote
        case prefix
        case suffix
        case blockFingerprint
        case blockKind
        case headingPath
        case manualConfirmation
    }

    var kind: Kind
    var matched: Bool

    init(kind: Kind, matched: Bool = true) {
        self.kind = kind
        self.matched = matched
    }
}

struct ReadingMemoryRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var documentID: UUID
    var kind: ReadingMemoryKind
    var originalVisibleQuote: String?
    var canonicalMatchQuote: String?
    var noteText: String?
    var createdAt: Date
    var updatedAt: Date
    var recordVersion: Int64
    var originalAnchorID: UUID?
    var currentAnchorID: UUID?
}

struct NewConfirmedAnchor: Codable, Equatable, Sendable {
    var id: UUID
    var supersedesAnchorID: UUID?
    var confirmation: AnchorConfirmation
    var createdAt: Date
    var selectorVersion: Int
    var projectionVersion: Int
    var sourceRevisionHash: String
    var resolverPolicyVersion: Int
    var exactQuote: String
    var prefix: String
    var suffix: String
    var canonicalTextPosition: CanonicalTextRange
    var canonicalUTF8RangeInBlock: CanonicalTextRange
    var blockKind: String
    var blockFingerprint: String
    var headingPath: [StoredHeadingBreadcrumb]
    var blockOrdinal: Int64
    var blockFingerprintOccurrenceCountInSection: Int
    var sourceUTF8Span: SourceUTF8Span?

    init(
        id: UUID = UUID(),
        supersedesAnchorID: UUID? = nil,
        confirmation: AnchorConfirmation,
        createdAt: Date = Date(),
        selectorVersion: Int,
        projectionVersion: Int,
        sourceRevisionHash: String,
        resolverPolicyVersion: Int,
        exactQuote: String,
        prefix: String,
        suffix: String,
        canonicalTextPosition: CanonicalTextRange,
        canonicalUTF8RangeInBlock: CanonicalTextRange,
        blockKind: String,
        blockFingerprint: String,
        headingPath: [StoredHeadingBreadcrumb],
        blockOrdinal: Int64,
        blockFingerprintOccurrenceCountInSection: Int,
        sourceUTF8Span: SourceUTF8Span? = nil
    ) {
        self.id = id
        self.supersedesAnchorID = supersedesAnchorID
        self.confirmation = confirmation
        self.createdAt = createdAt
        self.selectorVersion = selectorVersion
        self.projectionVersion = projectionVersion
        self.sourceRevisionHash = sourceRevisionHash
        self.resolverPolicyVersion = resolverPolicyVersion
        self.exactQuote = exactQuote
        self.prefix = prefix
        self.suffix = suffix
        self.canonicalTextPosition = canonicalTextPosition
        self.canonicalUTF8RangeInBlock = canonicalUTF8RangeInBlock
        self.blockKind = blockKind
        self.blockFingerprint = blockFingerprint
        self.headingPath = headingPath
        self.blockOrdinal = blockOrdinal
        self.blockFingerprintOccurrenceCountInSection = blockFingerprintOccurrenceCountInSection
        self.sourceUTF8Span = sourceUTF8Span
    }
}

struct ConfirmedAnchorRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var memoryID: UUID
    var supersedesAnchorID: UUID?
    var confirmation: AnchorConfirmation
    var createdAt: Date
    var selectorVersion: Int
    var projectionVersion: Int
    var sourceRevisionHash: String
    var resolverPolicyVersion: Int
    var exactQuote: String
    var prefix: String
    var suffix: String
    var canonicalTextPosition: CanonicalTextRange
    var canonicalUTF8RangeInBlock: CanonicalTextRange
    var blockKind: String
    var blockFingerprint: String
    var headingPath: [StoredHeadingBreadcrumb]
    var blockOrdinal: Int64
    var blockFingerprintOccurrenceCountInSection: Int
    var sourceUTF8Span: SourceUTF8Span?
}

struct ResolutionDraft: Codable, Equatable, Sendable {
    var state: MemoryResolutionState
    var checkedRevisionHash: String
    var resolverPolicyVersion: Int
    var resolvedSelector: ResolvedSelector?
    var evidence: [ResolutionEvidence]
    var lastCheckedAt: Date

    init(
        state: MemoryResolutionState,
        checkedRevisionHash: String,
        resolverPolicyVersion: Int,
        resolvedSelector: ResolvedSelector?,
        evidence: [ResolutionEvidence],
        lastCheckedAt: Date = Date()
    ) {
        self.state = state
        self.checkedRevisionHash = checkedRevisionHash
        self.resolverPolicyVersion = resolverPolicyVersion
        self.resolvedSelector = resolvedSelector
        self.evidence = evidence
        self.lastCheckedAt = lastCheckedAt
    }
}

struct CurrentResolutionRecord: Codable, Equatable, Sendable {
    var memoryID: UUID
    var anchorID: UUID
    var state: MemoryResolutionState
    var checkedRevisionHash: String
    var resolverPolicyVersion: Int
    var resolvedSelector: ResolvedSelector?
    var evidence: [ResolutionEvidence]
    var lastCheckedAt: Date
    var recordVersion: Int64
}

struct MemoryHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var memoryID: UUID
    var kind: MemoryHistoryKind
    var snapshot: Data
    var createdAt: Date
}

struct StoredMemory: Codable, Equatable, Sendable {
    var memory: ReadingMemoryRecord
    var anchors: [ConfirmedAnchorRecord]
    var resolution: CurrentResolutionRecord
    var history: [MemoryHistoryRecord]
}

struct CreateMemoryRequest: Codable, Equatable, Sendable {
    var id: UUID
    var documentID: UUID
    var kind: ReadingMemoryKind
    var originalVisibleQuote: String?
    var canonicalMatchQuote: String?
    var noteText: String?
    var expectedDocumentRecordVersion: Int64
    var anchor: NewConfirmedAnchor
    var resolution: ResolutionDraft
    var createdAt: Date

    init(
        id: UUID = UUID(),
        documentID: UUID,
        kind: ReadingMemoryKind,
        originalVisibleQuote: String?,
        canonicalMatchQuote: String?,
        noteText: String? = nil,
        expectedDocumentRecordVersion: Int64,
        anchor: NewConfirmedAnchor,
        resolution: ResolutionDraft,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.documentID = documentID
        self.kind = kind
        self.originalVisibleQuote = originalVisibleQuote
        self.canonicalMatchQuote = canonicalMatchQuote
        self.noteText = noteText
        self.expectedDocumentRecordVersion = expectedDocumentRecordVersion
        self.anchor = anchor
        self.resolution = resolution
        self.createdAt = createdAt
    }
}

struct MemoryHistorySnapshot: Codable, Equatable, Sendable {
    var memory: ReadingMemoryRecord
    var anchors: [ConfirmedAnchorRecord]
    var resolution: CurrentResolutionRecord
}

struct CreatedMemoryMutation: Codable, Equatable, Sendable {
    var storedMemory: StoredMemory
    var undo: CreateMemoryUndoPayload
}

struct CreateMemoryUndoPayload: Codable, Equatable, Sendable {
    var memoryID: UUID
    var expectedMemoryRecordVersion: Int64
    var expectedDocumentRecordVersion: Int64
}

struct NoteEditMutation: Codable, Equatable, Sendable {
    var memory: ReadingMemoryRecord
    var undo: NoteEditUndoPayload
}

struct NoteEditUndoPayload: Codable, Equatable, Sendable {
    var memoryID: UUID
    var previousNoteText: String?
    var expectedMemoryRecordVersion: Int64
}

struct FavouriteMutation: Codable, Equatable, Sendable {
    var document: DocumentRecord
    var undo: FavouriteUndoPayload
}

struct FavouriteUndoPayload: Codable, Equatable, Sendable {
    var documentID: UUID
    var previousValue: Bool
    var expectedDocumentRecordVersion: Int64
}

struct ResolutionMutation: Codable, Equatable, Sendable {
    var resolution: CurrentResolutionRecord
}

struct ReattachmentMutation: Codable, Equatable, Sendable {
    var storedMemory: StoredMemory
    var undo: ReattachmentUndoPayload
}

struct ReattachmentUndoPayload: Codable, Equatable, Sendable {
    var memoryID: UUID
    var previousAnchorID: UUID
    var previousResolution: CurrentResolutionRecord
    var expectedDocumentRecordVersion: Int64
    var expectedMemoryRecordVersion: Int64
    var expectedResolutionRecordVersion: Int64
}

struct DeletedMemoryUndoPayload: Codable, Equatable, Sendable {
    var storedMemory: StoredMemory
    var expectedDocumentRecordVersion: Int64
}

/// The immutable database precondition captured before presenting the
/// explicit "Restore as New" confirmation. The normal deletion undo always
/// runs first; this request is only used when that exact-identity restore can
/// no longer be committed safely.
struct RestoreDeletedMemoryAsNewRequest: Codable, Equatable, Sendable {
    var deleted: DeletedMemoryUndoPayload
    var expectedDocumentRecordVersion: Int64
}

/// A validated restore proposal binds the database precondition to the exact
/// registered source file that was checked. Commit revalidates every field
/// after the user confirms, so the confirmation cannot authorize a changed
/// document or a replacement file.
struct RestoreDeletedMemoryAsNewProposal: Identifiable, Equatable, Sendable {
    var id: UUID
    var request: RestoreDeletedMemoryAsNewRequest
    var sourceURL: URL
    var expectedFileIdentity: FileIdentity
    var expectedRevisionHash: String

    init(
        id: UUID = UUID(),
        request: RestoreDeletedMemoryAsNewRequest,
        sourceURL: URL,
        expectedFileIdentity: FileIdentity,
        expectedRevisionHash: String
    ) {
        self.id = id
        self.request = request
        self.sourceURL = sourceURL
        self.expectedFileIdentity = expectedFileIdentity
        self.expectedRevisionHash = expectedRevisionHash
    }

    var deletedMemory: StoredMemory { request.deleted.storedMemory }
}

struct ForgottenDocumentUndoPayload: Codable, Equatable, Sendable {
    var documentBeforeForget: DocumentRecord
    var readingState: ReadingStateRecord?
    var memories: [StoredMemory]
    var expectedDocumentRecordVersion: Int64
}

enum MemorySearchScope: String, Codable, CaseIterable, Sendable {
    case all
    case passages
    case notes
    case headings
}

enum MemorySearchFacet: String, Codable, CaseIterable, Sendable {
    case all
    case highlights
    case notes
    case bookmarks
    case chooseLocation
    case needsRepair
}

struct MemorySearchQuery: Codable, Equatable, Sendable {
    var text: String
    var scope: MemorySearchScope
    var facet: MemorySearchFacet
    var limit: Int
    var offset: Int

    init(
        text: String = "",
        scope: MemorySearchScope = .all,
        facet: MemorySearchFacet = .all,
        limit: Int = 100,
        offset: Int = 0
    ) {
        self.text = text
        self.scope = scope
        self.facet = facet
        self.limit = limit
        self.offset = offset
    }
}

struct MemorySearchResult: Codable, Equatable, Sendable {
    var memory: ReadingMemoryRecord
    var resolutionState: MemoryResolutionState
    var documentDisplayName: String
    var documentAvailability: DocumentAvailability
    var currentDocumentURL: URL?
    var totalCount: Int
}

enum DocumentSearchFacet: String, Codable, CaseIterable, Sendable {
    case all
    case continueReading
    case favourites
}

struct DocumentSearchQuery: Codable, Equatable, Sendable {
    var text: String
    var facet: DocumentSearchFacet
    var limit: Int
    var offset: Int

    init(text: String = "", facet: DocumentSearchFacet = .all, limit: Int = 100, offset: Int = 0) {
        self.text = text
        self.facet = facet
        self.limit = limit
        self.offset = offset
    }
}

struct DocumentSearchResult: Codable, Equatable, Sendable {
    var document: DocumentRecord
    var currentURL: URL?
    var parentFolderProvenance: String?
    var readingState: ReadingStateRecord?
    var totalCount: Int
}

struct MemoryStoreSnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var documents: [DocumentRecord]
    var documentLocations: [DocumentLocationRecord]
    var readingStates: [ReadingStateRecord]
    var memories: [StoredMemory]

    func deterministicJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(self)
    }
}

/// A snapshot and the durable mutation sequence observed in the same SQLite
/// read transaction. Export previews retain this value so a later save can
/// prove that no committed store mutation intervened.
struct SequencedMemoryStoreSnapshot: Codable, Equatable, Sendable {
    var snapshot: MemoryStoreSnapshot
    var sequence: UInt64
}

enum MemoryStoreEntity: String, Codable, Sendable {
    case document
    case documentLocation
    case readingState
    case memory
    case anchor
    case resolution
}

enum MemoryStoreError: Error, Equatable, Sendable {
    case openFailed
    case migrationFailed
    case backupFailed
    case corruptedDatabase
    case unsupportedSchema(found: Int, supported: Int)
    case notFound(MemoryStoreEntity)
    case duplicateIdentifier(MemoryStoreEntity)
    case versionConflict(entity: MemoryStoreEntity, expected: Int64, actual: Int64?)
    case staleSourceRevision
    case staleSourceIdentity
    case overlappingMemory(UUID)
    case invalidRecord(String)
    case readFailed
    case writeFailed
}

extension MemoryStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .openFailed:
            return "Reading Memory could not be opened. Markdown reading is still available."
        case .migrationFailed:
            return "Reading Memory could not be upgraded. The previous database was kept for recovery."
        case .backupFailed:
            return "Reading Memory could not make a verified migration backup. No migration was attempted."
        case .corruptedDatabase:
            return "Reading Memory appears to be damaged. The database was left unchanged."
        case let .unsupportedSchema(found, supported):
            return "Reading Memory uses schema version \(found), but this app supports up to version \(supported)."
        case let .notFound(entity):
            return "The requested \(entity.rawValue) no longer exists."
        case let .duplicateIdentifier(entity):
            return "A \(entity.rawValue) with this identifier already exists."
        case let .versionConflict(entity, _, _):
            return "The \(entity.rawValue) changed in another window."
        case .staleSourceRevision:
            return "The document changed. Select the passage again before saving."
        case .staleSourceIdentity:
            return "The document at this location is a different file. Reopen or relink it before restoring the memory."
        case .overlappingMemory:
            return "This passage overlaps an existing memory."
        case let .invalidRecord(reason):
            return reason
        case .readFailed:
            return "Reading Memory could not read its local database."
        case .writeFailed:
            return "Reading Memory could not save this change."
        }
    }
}

enum MemoryStoreChangeKind: String, Codable, Sendable {
    case document
    case readingState
    case memory
    case resolution
    case reset
}

struct MemoryStoreChange: Codable, Equatable, Sendable {
    var sequence: UInt64
    var kind: MemoryStoreChangeKind
    var documentIDs: Set<UUID>
    var memoryIDs: Set<UUID>
}
