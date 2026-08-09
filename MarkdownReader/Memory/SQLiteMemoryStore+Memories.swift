import Foundation
import GRDB

extension SQLiteMemoryStore {
    func createMemory(_ request: CreateMemoryRequest) throws -> CreatedMemoryMutation {
        try Self.validateCreateMemoryRequest(request)
        let mutation = try write { db in
            let document = try requireDocumentVersion(
                db,
                id: request.documentID,
                expected: request.expectedDocumentRecordVersion
            )
            try requireCurrentRevision(
                document: document,
                checkedRevisionHash: request.anchor.sourceRevisionHash
            )
            guard request.resolution.checkedRevisionHash == request.anchor.sourceRevisionHash else {
                throw MemoryStoreError.staleSourceRevision
            }
            guard try fetchMemory(db, id: request.id) == nil else {
                throw MemoryStoreError.duplicateIdentifier(.memory)
            }
            guard try fetchAnchor(db, id: request.anchor.id) == nil else {
                throw MemoryStoreError.duplicateIdentifier(.anchor)
            }

            if request.kind == .passage, let selector = request.resolution.resolvedSelector {
                try rejectOverlap(
                    db,
                    documentID: request.documentID,
                    revisionHash: request.anchor.sourceRevisionHash,
                    range: selector.canonicalTextPosition,
                    excludingMemoryID: nil
                )
            }

            try insertNewMemory(db, request: request)
            try insertAnchor(
                db,
                memoryID: request.id,
                anchor: request.anchor
            )
            try insertResolution(
                db,
                memoryID: request.id,
                anchorID: request.anchor.id,
                resolution: request.resolution,
                recordVersion: 1
            )
            try refreshMemoryFTS(db, memoryID: request.id)
            try appendHistory(
                db,
                memoryID: request.id,
                kind: .created,
                at: request.createdAt
            )
            let stored = try requireStoredMemory(db, id: request.id)
            return CreatedMemoryMutation(
                storedMemory: stored,
                undo: CreateMemoryUndoPayload(
                    memoryID: request.id,
                    expectedMemoryRecordVersion: stored.memory.recordVersion,
                    expectedDocumentRecordVersion: document.recordVersion
                )
            )
        }
        publish(
            kind: .memory,
            documentIDs: [request.documentID],
            memoryIDs: [request.id]
        )
        return mutation
    }

    func memory(id: UUID) throws -> StoredMemory? {
        try read { db in
            try fetchStoredMemory(db, id: id)
        }
    }

    func updateNote(
        memoryID: UUID,
        noteText: String?,
        expectedRecordVersion: Int64,
        at: Date
    ) throws -> NoteEditMutation {
        let mutation = try write { db in
            let current = try requireMemoryVersion(db, id: memoryID, expected: expectedRecordVersion)
            if current.noteText == noteText {
                return NoteEditMutation(
                    memory: current,
                    undo: NoteEditUndoPayload(
                        memoryID: memoryID,
                        previousNoteText: current.noteText,
                        expectedMemoryRecordVersion: current.recordVersion
                    )
                )
            }
            try db.execute(
                sql: """
                    UPDATE memories
                    SET note_text = ?, updated_at = ?, record_version = record_version + 1
                    WHERE id = ? AND record_version = ?
                    """,
                arguments: [
                    noteText,
                    Self.timestamp(at),
                    Self.normalizedID(memoryID),
                    expectedRecordVersion,
                ]
            )
            try refreshMemoryFTS(db, memoryID: memoryID)
            try appendHistory(db, memoryID: memoryID, kind: .noteEdited, at: at)
            let updated = try requireMemory(db, id: memoryID)
            return NoteEditMutation(
                memory: updated,
                undo: NoteEditUndoPayload(
                    memoryID: memoryID,
                    previousNoteText: current.noteText,
                    expectedMemoryRecordVersion: updated.recordVersion
                )
            )
        }
        publish(
            kind: .memory,
            documentIDs: [mutation.memory.documentID],
            memoryIDs: [memoryID]
        )
        return mutation
    }

    func undoNoteEdit(_ payload: NoteEditUndoPayload, at: Date) throws -> ReadingMemoryRecord {
        let memory = try write { db in
            let current = try requireMemoryVersion(
                db,
                id: payload.memoryID,
                expected: payload.expectedMemoryRecordVersion
            )
            guard current.noteText != payload.previousNoteText else { return current }
            try db.execute(
                sql: """
                    UPDATE memories
                    SET note_text = ?, updated_at = ?, record_version = record_version + 1
                    WHERE id = ? AND record_version = ?
                    """,
                arguments: [
                    payload.previousNoteText,
                    Self.timestamp(at),
                    Self.normalizedID(payload.memoryID),
                    payload.expectedMemoryRecordVersion,
                ]
            )
            try refreshMemoryFTS(db, memoryID: payload.memoryID)
            try appendHistory(db, memoryID: payload.memoryID, kind: .noteEdited, at: at)
            return try requireMemory(db, id: payload.memoryID)
        }
        publish(
            kind: .memory,
            documentIDs: [memory.documentID],
            memoryIDs: [payload.memoryID]
        )
        return memory
    }

    func replaceResolution(
        memoryID: UUID,
        anchorID: UUID,
        resolution: ResolutionDraft,
        expectedResolutionRecordVersion: Int64,
        expectedDocumentRecordVersion: Int64
    ) throws -> ResolutionMutation {
        try Self.validateResolution(resolution)
        let mutation = try write { db in
            let memory = try requireMemory(db, id: memoryID)
            let document = try requireDocumentVersion(
                db,
                id: memory.documentID,
                expected: expectedDocumentRecordVersion
            )
            try requireCurrentRevision(
                document: document,
                checkedRevisionHash: resolution.checkedRevisionHash
            )
            let anchor = try requireAnchor(db, id: anchorID)
            guard anchor.memoryID == memoryID else {
                throw MemoryStoreError.invalidRecord("The resolution anchor belongs to another memory.")
            }
            let current = try requireResolutionVersion(
                db,
                memoryID: memoryID,
                expected: expectedResolutionRecordVersion
            )
            if memory.kind == .passage, let selector = resolution.resolvedSelector {
                try rejectOverlap(
                    db,
                    documentID: memory.documentID,
                    revisionHash: resolution.checkedRevisionHash,
                    range: selector.canonicalTextPosition,
                    excludingMemoryID: memoryID
                )
            }

            try updateResolutionRow(
                db,
                memoryID: memoryID,
                anchorID: anchorID,
                resolution: resolution,
                expectedRecordVersion: current.recordVersion
            )
            try appendHistory(
                db,
                memoryID: memoryID,
                kind: .resolutionChanged,
                at: resolution.lastCheckedAt
            )
            return ResolutionMutation(resolution: try requireResolution(db, memoryID: memoryID))
        }
        let memory = try self.memory(id: memoryID)?.memory
        publish(
            kind: .resolution,
            documentIDs: memory.map { [$0.documentID] } ?? [],
            memoryIDs: [memoryID]
        )
        return mutation
    }

    func reattachMemory(
        memoryID: UUID,
        anchor: NewConfirmedAnchor,
        resolution: ResolutionDraft,
        expectedMemoryRecordVersion: Int64,
        expectedResolutionRecordVersion: Int64,
        expectedDocumentRecordVersion: Int64
    ) throws -> ReattachmentMutation {
        try Self.validateAnchor(anchor)
        try Self.validateResolution(resolution)
        guard anchor.confirmation == .manualReattach,
              resolution.state == .resolved,
              resolution.checkedRevisionHash == anchor.sourceRevisionHash,
              let resolvedSelector = resolution.resolvedSelector,
              resolvedSelector.projectionVersion == anchor.projectionVersion,
              resolvedSelector.canonicalTextPosition == anchor.canonicalTextPosition,
              resolvedSelector.canonicalUTF8RangeInBlock == anchor.canonicalUTF8RangeInBlock,
              resolvedSelector.blockKind == anchor.blockKind else {
            throw MemoryStoreError.invalidRecord("A manual reattachment must confirm one resolved location.")
        }

        let mutation = try write { db in
            let memory = try requireMemoryVersion(
                db,
                id: memoryID,
                expected: expectedMemoryRecordVersion
            )
            let document = try requireDocumentVersion(
                db,
                id: memory.documentID,
                expected: expectedDocumentRecordVersion
            )
            try requireCurrentRevision(
                document: document,
                checkedRevisionHash: anchor.sourceRevisionHash
            )
            let currentResolution = try requireResolutionVersion(
                db,
                memoryID: memoryID,
                expected: expectedResolutionRecordVersion
            )
            guard let previousAnchorID = memory.currentAnchorID,
                  anchor.supersedesAnchorID == previousAnchorID else {
                throw MemoryStoreError.invalidRecord("The reattachment does not supersede the current anchor.")
            }
            guard try fetchAnchor(db, id: anchor.id) == nil else {
                throw MemoryStoreError.duplicateIdentifier(.anchor)
            }
            if memory.kind == .passage, let selector = resolution.resolvedSelector {
                try rejectOverlap(
                    db,
                    documentID: memory.documentID,
                    revisionHash: anchor.sourceRevisionHash,
                    range: selector.canonicalTextPosition,
                    excludingMemoryID: memoryID
                )
            }

            try insertAnchor(db, memoryID: memoryID, anchor: anchor)
            try db.execute(
                sql: """
                    UPDATE memories
                    SET current_anchor_id = ?, updated_at = ?, record_version = record_version + 1
                    WHERE id = ? AND record_version = ?
                    """,
                arguments: [
                    Self.normalizedID(anchor.id),
                    Self.timestamp(anchor.createdAt),
                    Self.normalizedID(memoryID),
                    expectedMemoryRecordVersion,
                ]
            )
            try updateResolutionRow(
                db,
                memoryID: memoryID,
                anchorID: anchor.id,
                resolution: resolution,
                expectedRecordVersion: expectedResolutionRecordVersion
            )
            try refreshMemoryFTS(db, memoryID: memoryID)
            try appendHistory(db, memoryID: memoryID, kind: .reattached, at: anchor.createdAt)
            let stored = try requireStoredMemory(db, id: memoryID)
            return ReattachmentMutation(
                storedMemory: stored,
                undo: ReattachmentUndoPayload(
                    memoryID: memoryID,
                    previousAnchorID: previousAnchorID,
                    previousResolution: currentResolution,
                    expectedDocumentRecordVersion: document.recordVersion,
                    expectedMemoryRecordVersion: stored.memory.recordVersion,
                    expectedResolutionRecordVersion: stored.resolution.recordVersion
                )
            )
        }
        publish(
            kind: .memory,
            documentIDs: [mutation.storedMemory.memory.documentID],
            memoryIDs: [memoryID]
        )
        return mutation
    }

    func undoReattachment(
        _ payload: ReattachmentUndoPayload,
        validatedResolution: ResolutionDraft
    ) throws -> StoredMemory {
        try Self.validateResolution(validatedResolution)
        let stored = try write { db in
            let memory = try requireMemoryVersion(
                db,
                id: payload.memoryID,
                expected: payload.expectedMemoryRecordVersion
            )
            let document = try requireDocumentVersion(
                db,
                id: memory.documentID,
                expected: payload.expectedDocumentRecordVersion
            )
            try requireCurrentRevision(
                document: document,
                checkedRevisionHash: validatedResolution.checkedRevisionHash
            )
            _ = try requireResolutionVersion(
                db,
                memoryID: payload.memoryID,
                expected: payload.expectedResolutionRecordVersion
            )
            let previousAnchor = try requireAnchor(db, id: payload.previousAnchorID)
            guard previousAnchor.memoryID == payload.memoryID else {
                throw MemoryStoreError.invalidRecord("The prior anchor belongs to another memory.")
            }
            if memory.kind == .passage, let selector = validatedResolution.resolvedSelector {
                try rejectOverlap(
                    db,
                    documentID: memory.documentID,
                    revisionHash: validatedResolution.checkedRevisionHash,
                    range: selector.canonicalTextPosition,
                    excludingMemoryID: payload.memoryID
                )
            }
            try db.execute(
                sql: """
                    UPDATE memories
                    SET current_anchor_id = ?, updated_at = ?, record_version = record_version + 1
                    WHERE id = ? AND record_version = ?
                    """,
                arguments: [
                    Self.normalizedID(payload.previousAnchorID),
                    Self.timestamp(validatedResolution.lastCheckedAt),
                    Self.normalizedID(payload.memoryID),
                    payload.expectedMemoryRecordVersion,
                ]
            )
            try updateResolutionRow(
                db,
                memoryID: payload.memoryID,
                anchorID: payload.previousAnchorID,
                resolution: validatedResolution,
                expectedRecordVersion: payload.expectedResolutionRecordVersion
            )
            try appendHistory(
                db,
                memoryID: payload.memoryID,
                kind: .resolutionChanged,
                at: validatedResolution.lastCheckedAt
            )
            return try requireStoredMemory(db, id: payload.memoryID)
        }
        publish(
            kind: .memory,
            documentIDs: [stored.memory.documentID],
            memoryIDs: [payload.memoryID]
        )
        return stored
    }

    func deleteMemory(
        memoryID: UUID,
        expectedRecordVersion: Int64
    ) throws -> DeletedMemoryUndoPayload {
        let payload = try write { db in
            let stored = try requireStoredMemory(db, id: memoryID)
            guard stored.memory.recordVersion == expectedRecordVersion else {
                throw MemoryStoreError.versionConflict(
                    entity: .memory,
                    expected: expectedRecordVersion,
                    actual: stored.memory.recordVersion
                )
            }
            let document = try requireDocument(db, id: stored.memory.documentID)
            try db.execute(
                sql: "DELETE FROM memories_fts WHERE memory_id = ?",
                arguments: [Self.normalizedID(memoryID)]
            )
            try db.execute(
                sql: "DELETE FROM memories WHERE id = ? AND record_version = ?",
                arguments: [Self.normalizedID(memoryID), expectedRecordVersion]
            )
            return DeletedMemoryUndoPayload(
                storedMemory: stored,
                expectedDocumentRecordVersion: document.recordVersion
            )
        }
        publish(
            kind: .memory,
            documentIDs: [payload.storedMemory.memory.documentID],
            memoryIDs: [memoryID]
        )
        return payload
    }

    func undoCreateMemory(_ payload: CreateMemoryUndoPayload) throws {
        let documentID = try write { db in
            _ = try requireDocumentVersion(
                db,
                id: try requireMemory(db, id: payload.memoryID).documentID,
                expected: payload.expectedDocumentRecordVersion
            )
            let memory = try requireMemoryVersion(
                db,
                id: payload.memoryID,
                expected: payload.expectedMemoryRecordVersion
            )
            try db.execute(
                sql: "DELETE FROM memories_fts WHERE memory_id = ?",
                arguments: [Self.normalizedID(payload.memoryID)]
            )
            try db.execute(
                sql: "DELETE FROM memories WHERE id = ? AND record_version = ?",
                arguments: [Self.normalizedID(payload.memoryID), payload.expectedMemoryRecordVersion]
            )
            return memory.documentID
        }
        publish(kind: .memory, documentIDs: [documentID], memoryIDs: [payload.memoryID])
    }

    func restoreDeletedMemory(
        _ payload: DeletedMemoryUndoPayload,
        at: Date
    ) throws -> StoredMemory {
        let stored = try write { db in
            let document = try requireDocumentVersion(
                db,
                id: payload.storedMemory.memory.documentID,
                expected: payload.expectedDocumentRecordVersion
            )
            guard try fetchMemory(db, id: payload.storedMemory.memory.id) == nil else {
                throw MemoryStoreError.duplicateIdentifier(.memory)
            }
            if payload.storedMemory.memory.kind == .passage,
               let selector = payload.storedMemory.resolution.resolvedSelector {
                try requireCurrentRevision(
                    document: document,
                    checkedRevisionHash: payload.storedMemory.resolution.checkedRevisionHash
                )
                try rejectOverlap(
                    db,
                    documentID: document.id,
                    revisionHash: payload.storedMemory.resolution.checkedRevisionHash,
                    range: selector.canonicalTextPosition,
                    excludingMemoryID: nil
                )
            }
            let restored = try insertStoredMemoryForUndo(db, stored: payload.storedMemory)
            try refreshMemoryFTS(db, memoryID: restored.memory.id)
            try appendHistory(db, memoryID: restored.memory.id, kind: .restored, at: at)
            return try requireStoredMemory(db, id: restored.memory.id)
        }
        publish(
            kind: .memory,
            documentIDs: [stored.memory.documentID],
            memoryIDs: [stored.memory.id]
        )
        return stored
    }

    func validateRestoreDeletedMemoryAsNew(
        _ request: RestoreDeletedMemoryAsNewRequest
    ) throws {
        try read { db in
            _ = try validateRestoreDeletedMemoryAsNew(db, request: request)
        }
    }

    func restoreDeletedMemoryAsNew(
        _ request: RestoreDeletedMemoryAsNewRequest,
        at: Date
    ) throws -> StoredMemory {
        let restored = try write { db in
            _ = try validateRestoreDeletedMemoryAsNew(db, request: request)

            let source = request.deleted.storedMemory
            let newMemoryID = UUID()
            let anchorIDMap = Dictionary(
                uniqueKeysWithValues: source.anchors.map { ($0.id, UUID()) }
            )
            let copied = try copyDeletedMemoryAsNew(
                source,
                memoryID: newMemoryID,
                anchorIDMap: anchorIDMap,
                restoredAt: at
            )

            try insertMemoryRecord(db, memory: copied.memory)
            for anchor in copied.anchors {
                try insertAnchorRecord(db, anchor: anchor)
            }
            try insertResolutionRecord(db, resolution: copied.resolution)
            for history in copied.history {
                try insertHistoryRecord(db, history: history)
            }
            try refreshMemoryFTS(db, memoryID: newMemoryID)
            try appendHistory(db, memoryID: newMemoryID, kind: .restored, at: at)
            return try requireStoredMemory(db, id: newMemoryID)
        }
        publish(
            kind: .memory,
            documentIDs: [restored.memory.documentID],
            memoryIDs: [restored.memory.id]
        )
        return restored
    }

    func forgetDocument(
        documentID: UUID,
        expectedRecordVersion: Int64
    ) throws -> ForgottenDocumentUndoPayload {
        let payload = try write { db in
            let document = try requireDocumentVersion(
                db,
                id: documentID,
                expected: expectedRecordVersion
            )
            let memoryIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM memories WHERE document_id = ? ORDER BY created_at, id",
                arguments: [Self.normalizedID(documentID)]
            )
            let memories = try memoryIDs.map { idString in
                try requireStoredMemory(db, id: Self.decodedID(idString))
            }
            let readingState = try fetchReadingState(db, documentID: documentID)

            try db.execute(
                sql: "DELETE FROM memories_fts WHERE document_id = ?",
                arguments: [Self.normalizedID(documentID)]
            )
            try db.execute(
                sql: "DELETE FROM memories WHERE document_id = ?",
                arguments: [Self.normalizedID(documentID)]
            )
            try db.execute(
                sql: "DELETE FROM reading_state WHERE document_id = ?",
                arguments: [Self.normalizedID(documentID)]
            )
            try db.execute(
                sql: """
                    UPDATE documents
                    SET is_favourite = 0, record_version = record_version + 1
                    WHERE id = ? AND record_version = ?
                    """,
                arguments: [Self.normalizedID(documentID), expectedRecordVersion]
            )
            try refreshDocumentFTS(db, documentID: documentID)
            let updated = try requireDocument(db, id: documentID)
            return ForgottenDocumentUndoPayload(
                documentBeforeForget: document,
                readingState: readingState,
                memories: memories,
                expectedDocumentRecordVersion: updated.recordVersion
            )
        }
        publish(
            kind: .reset,
            documentIDs: [documentID],
            memoryIDs: Set(payload.memories.map(\.memory.id))
        )
        return payload
    }

    func restoreForgottenDocument(
        _ payload: ForgottenDocumentUndoPayload,
        at: Date
    ) throws -> DocumentRecord {
        let result = try write { db in
            let documentID = payload.documentBeforeForget.id
            let current = try requireDocumentVersion(
                db,
                id: documentID,
                expected: payload.expectedDocumentRecordVersion
            )
            guard try fetchReadingState(db, documentID: documentID) == nil else {
                throw MemoryStoreError.versionConflict(
                    entity: .readingState,
                    expected: payload.readingState?.recordVersion ?? 0,
                    actual: try fetchReadingState(db, documentID: documentID)?.recordVersion
                )
            }
            for stored in payload.memories {
                guard try fetchMemory(db, id: stored.memory.id) == nil else {
                    throw MemoryStoreError.duplicateIdentifier(.memory)
                }
            }

            try db.execute(
                sql: """
                    UPDATE documents
                    SET is_favourite = ?, record_version = record_version + 1
                    WHERE id = ? AND record_version = ?
                    """,
                arguments: [
                    payload.documentBeforeForget.isFavourite ? 1 : 0,
                    Self.normalizedID(documentID),
                    current.recordVersion,
                ]
            )
            if var state = payload.readingState {
                state.recordVersion += 1
                try insertReadingState(db, state: state)
            }
            for stored in payload.memories {
                if stored.memory.kind == .passage,
                   let selector = stored.resolution.resolvedSelector {
                    try requireCurrentRevision(
                        document: current,
                        checkedRevisionHash: stored.resolution.checkedRevisionHash
                    )
                    try rejectOverlap(
                        db,
                        documentID: documentID,
                        revisionHash: stored.resolution.checkedRevisionHash,
                        range: selector.canonicalTextPosition,
                        excludingMemoryID: nil
                    )
                }
                let restored = try insertStoredMemoryForUndo(db, stored: stored)
                try refreshMemoryFTS(db, memoryID: restored.memory.id)
                try appendHistory(db, memoryID: restored.memory.id, kind: .restored, at: at)
            }
            try refreshDocumentFTS(db, documentID: documentID)
            return try requireDocument(db, id: documentID)
        }
        publish(
            kind: .reset,
            documentIDs: [result.id],
            memoryIDs: Set(payload.memories.map(\.memory.id))
        )
        return result
    }
}

extension SQLiteMemoryStore {
    static func validateCreateMemoryRequest(_ request: CreateMemoryRequest) throws {
        try validateAnchor(request.anchor)
        try validateResolution(request.resolution)
        guard request.expectedDocumentRecordVersion >= 1,
              request.anchor.confirmation == .initialCapture,
              request.anchor.supersedesAnchorID == nil,
              request.resolution.state == .resolved,
              request.resolution.checkedRevisionHash == request.anchor.sourceRevisionHash,
              request.canonicalMatchQuote == request.anchor.exactQuote else {
            throw MemoryStoreError.invalidRecord("The initial capture is incomplete or stale.")
        }
        guard let resolvedSelector = request.resolution.resolvedSelector,
              resolvedSelector.sourceRevisionHash == request.anchor.sourceRevisionHash,
              resolvedSelector.projectionVersion == request.anchor.projectionVersion,
              resolvedSelector.canonicalTextPosition == request.anchor.canonicalTextPosition,
              resolvedSelector.canonicalUTF8RangeInBlock
                == request.anchor.canonicalUTF8RangeInBlock,
              resolvedSelector.blockKind == request.anchor.blockKind else {
            throw MemoryStoreError.invalidRecord("The initial resolution does not match its confirmed anchor.")
        }
        switch request.kind {
        case .passage:
            guard request.originalVisibleQuote?.isEmpty == false,
                  request.canonicalMatchQuote?.isEmpty == false else {
                throw MemoryStoreError.invalidRecord("A passage memory needs its original and canonical quote.")
            }
        case .headingBookmark:
            guard request.originalVisibleQuote?.isEmpty == false else {
                throw MemoryStoreError.invalidRecord("A heading bookmark needs a visible heading.")
            }
        }
    }

    func requireCurrentRevision(
        document: DocumentRecord,
        checkedRevisionHash: String
    ) throws {
        guard let documentHash = document.lastConfirmedContentHash,
              documentHash == checkedRevisionHash else {
            throw MemoryStoreError.staleSourceRevision
        }
    }

    func rejectOverlap(
        _ db: Database,
        documentID: UUID,
        revisionHash: String,
        range: CanonicalTextRange,
        excludingMemoryID: UUID?
    ) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT m.id, r.resolved_selector_json
                FROM memories m
                JOIN memory_resolutions r ON r.memory_id = m.id
                WHERE m.document_id = ?
                  AND m.kind = 'passage'
                  AND r.state = 'resolved'
                  AND r.checked_revision_hash = ?
                  AND r.resolved_selector_json IS NOT NULL
                ORDER BY m.id
                """,
            arguments: [Self.normalizedID(documentID), revisionHash]
        )
        for row in rows {
            let idString: String = row["id"]
            let id = try Self.decodedID(idString)
            if id == excludingMemoryID { continue }
            let data: Data = row["resolved_selector_json"]
            let selector = try Self.decodedJSON(ResolvedSelector.self, from: data)
            let existing = selector.canonicalTextPosition
            if range.lowerBound < existing.upperBound && existing.lowerBound < range.upperBound {
                throw MemoryStoreError.overlappingMemory(id)
            }
        }
    }

    func insertNewMemory(_ db: Database, request: CreateMemoryRequest) throws {
        try db.execute(
            sql: """
                INSERT INTO memories (
                    id, document_id, kind, original_visible_quote, canonical_match_quote,
                    note_text, created_at, updated_at, record_version,
                    original_anchor_id, current_anchor_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                """,
            arguments: [
                Self.normalizedID(request.id),
                Self.normalizedID(request.documentID),
                request.kind.rawValue,
                request.originalVisibleQuote,
                request.canonicalMatchQuote,
                request.noteText,
                Self.timestamp(request.createdAt),
                Self.timestamp(request.createdAt),
                Self.normalizedID(request.anchor.id),
                Self.normalizedID(request.anchor.id),
            ]
        )
    }

    func fetchMemory(_ db: Database, id: UUID) throws -> ReadingMemoryRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM memories WHERE id = ?",
            arguments: [Self.normalizedID(id)]
        ) else { return nil }
        return try Self.decodeMemory(row)
    }

    func requireMemory(_ db: Database, id: UUID) throws -> ReadingMemoryRecord {
        guard let memory = try fetchMemory(db, id: id) else {
            throw MemoryStoreError.notFound(.memory)
        }
        return memory
    }

    func requireMemoryVersion(
        _ db: Database,
        id: UUID,
        expected: Int64
    ) throws -> ReadingMemoryRecord {
        guard let memory = try fetchMemory(db, id: id) else {
            throw MemoryStoreError.versionConflict(entity: .memory, expected: expected, actual: nil)
        }
        guard memory.recordVersion == expected else {
            throw MemoryStoreError.versionConflict(
                entity: .memory,
                expected: expected,
                actual: memory.recordVersion
            )
        }
        return memory
    }

    static func decodeMemory(_ row: Row) throws -> ReadingMemoryRecord {
        let id: String = row["id"]
        let documentID: String = row["document_id"]
        let kindRaw: String = row["kind"]
        let visibleQuote: String? = row["original_visible_quote"]
        let canonicalQuote: String? = row["canonical_match_quote"]
        let note: String? = row["note_text"]
        let created: Double = row["created_at"]
        let updated: Double = row["updated_at"]
        let version: Int64 = row["record_version"]
        let originalAnchor: String? = row["original_anchor_id"]
        let currentAnchor: String? = row["current_anchor_id"]
        guard let kind = ReadingMemoryKind(rawValue: kindRaw) else {
            throw MemoryStoreError.corruptedDatabase
        }
        return ReadingMemoryRecord(
            id: try decodedID(id),
            documentID: try decodedID(documentID),
            kind: kind,
            originalVisibleQuote: visibleQuote,
            canonicalMatchQuote: canonicalQuote,
            noteText: note,
            createdAt: date(created),
            updatedAt: date(updated),
            recordVersion: version,
            originalAnchorID: try originalAnchor.map(decodedID),
            currentAnchorID: try currentAnchor.map(decodedID)
        )
    }

    func insertAnchor(
        _ db: Database,
        memoryID: UUID,
        anchor: NewConfirmedAnchor
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO confirmed_anchors (
                    id, memory_id, supersedes_anchor_id, confirmation, created_at,
                    selector_version, projection_version, source_revision_hash,
                    resolver_policy_version, exact_quote, prefix_text, suffix_text,
                    canonical_start, canonical_end, block_local_start, block_local_end,
                    block_kind, block_fingerprint, heading_path_json, block_ordinal,
                    block_fingerprint_occurrence_count, source_utf8_start, source_utf8_end
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                Self.normalizedID(anchor.id),
                Self.normalizedID(memoryID),
                anchor.supersedesAnchorID.map(Self.normalizedID),
                anchor.confirmation.rawValue,
                Self.timestamp(anchor.createdAt),
                anchor.selectorVersion,
                anchor.projectionVersion,
                anchor.sourceRevisionHash,
                anchor.resolverPolicyVersion,
                anchor.exactQuote,
                anchor.prefix,
                anchor.suffix,
                anchor.canonicalTextPosition.lowerBound,
                anchor.canonicalTextPosition.upperBound,
                anchor.canonicalUTF8RangeInBlock.lowerBound,
                anchor.canonicalUTF8RangeInBlock.upperBound,
                anchor.blockKind,
                anchor.blockFingerprint,
                try Self.encodedJSON(anchor.headingPath),
                anchor.blockOrdinal,
                anchor.blockFingerprintOccurrenceCountInSection,
                anchor.sourceUTF8Span?.lowerBound,
                anchor.sourceUTF8Span?.upperBound,
            ]
        )
    }

    func fetchAnchor(_ db: Database, id: UUID) throws -> ConfirmedAnchorRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM confirmed_anchors WHERE id = ?",
            arguments: [Self.normalizedID(id)]
        ) else { return nil }
        return try Self.decodeAnchor(row)
    }

    func requireAnchor(_ db: Database, id: UUID) throws -> ConfirmedAnchorRecord {
        guard let anchor = try fetchAnchor(db, id: id) else {
            throw MemoryStoreError.notFound(.anchor)
        }
        return anchor
    }

    static func decodeAnchor(_ row: Row) throws -> ConfirmedAnchorRecord {
        let id: String = row["id"]
        let memoryID: String = row["memory_id"]
        let supersedes: String? = row["supersedes_anchor_id"]
        let confirmationRaw: String = row["confirmation"]
        let created: Double = row["created_at"]
        let selectorVersion: Int = row["selector_version"]
        let projectionVersion: Int = row["projection_version"]
        let sourceHash: String = row["source_revision_hash"]
        let policyVersion: Int = row["resolver_policy_version"]
        let exactQuote: String = row["exact_quote"]
        let prefix: String = row["prefix_text"]
        let suffix: String = row["suffix_text"]
        let canonicalStart: Int64 = row["canonical_start"]
        let canonicalEnd: Int64 = row["canonical_end"]
        let blockLocalStart: Int64 = row["block_local_start"]
        let blockLocalEnd: Int64 = row["block_local_end"]
        let blockKind: String = row["block_kind"]
        let blockFingerprint: String = row["block_fingerprint"]
        let headingData: Data = row["heading_path_json"]
        let blockOrdinal: Int64 = row["block_ordinal"]
        let occurrenceCount: Int = row["block_fingerprint_occurrence_count"]
        let sourceStart: Int64? = row["source_utf8_start"]
        let sourceEnd: Int64? = row["source_utf8_end"]
        guard let confirmation = AnchorConfirmation(rawValue: confirmationRaw) else {
            throw MemoryStoreError.corruptedDatabase
        }
        let sourceSpan: SourceUTF8Span?
        switch (sourceStart, sourceEnd) {
        case let (.some(start), .some(end)):
            sourceSpan = SourceUTF8Span(lowerBound: start, upperBound: end)
        case (nil, nil):
            sourceSpan = nil
        default:
            throw MemoryStoreError.corruptedDatabase
        }
        return ConfirmedAnchorRecord(
            id: try decodedID(id),
            memoryID: try decodedID(memoryID),
            supersedesAnchorID: try supersedes.map(decodedID),
            confirmation: confirmation,
            createdAt: date(created),
            selectorVersion: selectorVersion,
            projectionVersion: projectionVersion,
            sourceRevisionHash: sourceHash,
            resolverPolicyVersion: policyVersion,
            exactQuote: exactQuote,
            prefix: prefix,
            suffix: suffix,
            canonicalTextPosition: CanonicalTextRange(
                lowerBound: canonicalStart,
                upperBound: canonicalEnd
            ),
            canonicalUTF8RangeInBlock: CanonicalTextRange(
                lowerBound: blockLocalStart,
                upperBound: blockLocalEnd
            ),
            blockKind: blockKind,
            blockFingerprint: blockFingerprint,
            headingPath: try decodedJSON([StoredHeadingBreadcrumb].self, from: headingData),
            blockOrdinal: blockOrdinal,
            blockFingerprintOccurrenceCountInSection: occurrenceCount,
            sourceUTF8Span: sourceSpan
        )
    }

    func insertResolution(
        _ db: Database,
        memoryID: UUID,
        anchorID: UUID,
        resolution: ResolutionDraft,
        recordVersion: Int64
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO memory_resolutions (
                    memory_id, anchor_id, state, checked_revision_hash,
                    resolver_policy_version, resolved_selector_json, evidence_json,
                    last_checked_at, record_version
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                Self.normalizedID(memoryID),
                Self.normalizedID(anchorID),
                resolution.state.rawValue,
                resolution.checkedRevisionHash,
                resolution.resolverPolicyVersion,
                try resolution.resolvedSelector.map(Self.encodedJSON),
                try Self.encodedJSON(resolution.evidence),
                Self.timestamp(resolution.lastCheckedAt),
                recordVersion,
            ]
        )
    }

    func updateResolutionRow(
        _ db: Database,
        memoryID: UUID,
        anchorID: UUID,
        resolution: ResolutionDraft,
        expectedRecordVersion: Int64
    ) throws {
        try db.execute(
            sql: """
                UPDATE memory_resolutions
                SET anchor_id = ?, state = ?, checked_revision_hash = ?,
                    resolver_policy_version = ?, resolved_selector_json = ?,
                    evidence_json = ?, last_checked_at = ?, record_version = record_version + 1
                WHERE memory_id = ? AND record_version = ?
                """,
            arguments: [
                Self.normalizedID(anchorID),
                resolution.state.rawValue,
                resolution.checkedRevisionHash,
                resolution.resolverPolicyVersion,
                try resolution.resolvedSelector.map(Self.encodedJSON),
                try Self.encodedJSON(resolution.evidence),
                Self.timestamp(resolution.lastCheckedAt),
                Self.normalizedID(memoryID),
                expectedRecordVersion,
            ]
        )
    }

    func fetchResolution(_ db: Database, memoryID: UUID) throws -> CurrentResolutionRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM memory_resolutions WHERE memory_id = ?",
            arguments: [Self.normalizedID(memoryID)]
        ) else { return nil }
        return try Self.decodeResolution(row)
    }

    func requireResolution(_ db: Database, memoryID: UUID) throws -> CurrentResolutionRecord {
        guard let resolution = try fetchResolution(db, memoryID: memoryID) else {
            throw MemoryStoreError.notFound(.resolution)
        }
        return resolution
    }

    func requireResolutionVersion(
        _ db: Database,
        memoryID: UUID,
        expected: Int64
    ) throws -> CurrentResolutionRecord {
        guard let resolution = try fetchResolution(db, memoryID: memoryID) else {
            throw MemoryStoreError.versionConflict(entity: .resolution, expected: expected, actual: nil)
        }
        guard resolution.recordVersion == expected else {
            throw MemoryStoreError.versionConflict(
                entity: .resolution,
                expected: expected,
                actual: resolution.recordVersion
            )
        }
        return resolution
    }

    static func decodeResolution(_ row: Row) throws -> CurrentResolutionRecord {
        let memoryID: String = row["memory_id"]
        let anchorID: String = row["anchor_id"]
        let stateRaw: String = row["state"]
        let checkedHash: String = row["checked_revision_hash"]
        let policy: Int = row["resolver_policy_version"]
        let selectorData: Data? = row["resolved_selector_json"]
        let evidenceData: Data = row["evidence_json"]
        let checkedAt: Double = row["last_checked_at"]
        let version: Int64 = row["record_version"]
        guard let state = MemoryResolutionState(rawValue: stateRaw) else {
            throw MemoryStoreError.corruptedDatabase
        }
        return CurrentResolutionRecord(
            memoryID: try decodedID(memoryID),
            anchorID: try decodedID(anchorID),
            state: state,
            checkedRevisionHash: checkedHash,
            resolverPolicyVersion: policy,
            resolvedSelector: try selectorData.map { try decodedJSON(ResolvedSelector.self, from: $0) },
            evidence: try decodedJSON([ResolutionEvidence].self, from: evidenceData),
            lastCheckedAt: date(checkedAt),
            recordVersion: version
        )
    }

    func fetchStoredMemory(_ db: Database, id: UUID) throws -> StoredMemory? {
        guard let memory = try fetchMemory(db, id: id) else { return nil }
        let anchorRows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM confirmed_anchors
                WHERE memory_id = ? ORDER BY created_at, id
                """,
            arguments: [Self.normalizedID(id)]
        )
        let historyRows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM memory_history
                WHERE memory_id = ? ORDER BY created_at, id
                """,
            arguments: [Self.normalizedID(id)]
        )
        return StoredMemory(
            memory: memory,
            anchors: try anchorRows.map(Self.decodeAnchor),
            resolution: try requireResolution(db, memoryID: id),
            history: try historyRows.map(Self.decodeHistory)
        )
    }

    func requireStoredMemory(_ db: Database, id: UUID) throws -> StoredMemory {
        guard let stored = try fetchStoredMemory(db, id: id) else {
            throw MemoryStoreError.notFound(.memory)
        }
        return stored
    }

    static func decodeHistory(_ row: Row) throws -> MemoryHistoryRecord {
        let id: String = row["id"]
        let memoryID: String = row["memory_id"]
        let kindRaw: String = row["kind"]
        let snapshot: Data = row["snapshot_json"]
        let created: Double = row["created_at"]
        guard let kind = MemoryHistoryKind(rawValue: kindRaw) else {
            throw MemoryStoreError.corruptedDatabase
        }
        return MemoryHistoryRecord(
            id: try decodedID(id),
            memoryID: try decodedID(memoryID),
            kind: kind,
            snapshot: snapshot,
            createdAt: date(created)
        )
    }

    func appendHistory(
        _ db: Database,
        memoryID: UUID,
        kind: MemoryHistoryKind,
        at: Date
    ) throws {
        let stored = try requireStoredMemory(db, id: memoryID)
        let snapshot = MemoryHistorySnapshot(
            memory: stored.memory,
            anchors: stored.anchors,
            resolution: stored.resolution
        )
        try db.execute(
            sql: """
                INSERT INTO memory_history (id, memory_id, kind, snapshot_json, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [
                Self.normalizedID(UUID()),
                Self.normalizedID(memoryID),
                kind.rawValue,
                try Self.encodedJSON(snapshot),
                Self.timestamp(at),
            ]
        )
    }

    func refreshMemoryFTS(_ db: Database, memoryID: UUID) throws {
        let id = Self.normalizedID(memoryID)
        try db.execute(sql: "DELETE FROM memories_fts WHERE memory_id = ?", arguments: [id])
        guard let memory = try fetchMemory(db, id: memoryID) else { return }
        let anchor: ConfirmedAnchorRecord?
        if let currentAnchorID = memory.currentAnchorID {
            anchor = try fetchAnchor(db, id: currentAnchorID)
        } else {
            anchor = nil
        }
        var headingComponents = anchor?.headingPath.map(\.title) ?? []
        if memory.kind == .headingBookmark, let quote = memory.originalVisibleQuote {
            headingComponents.append(quote)
        }
        try db.execute(
            sql: """
                INSERT INTO memories_fts (
                    memory_id, document_id, passage_text, note_text, heading_text
                ) VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [
                id,
                Self.normalizedID(memory.documentID),
                memory.originalVisibleQuote ?? "",
                memory.noteText ?? "",
                headingComponents.joined(separator: " › "),
            ]
        )
    }

    func insertStoredMemoryForUndo(
        _ db: Database,
        stored: StoredMemory
    ) throws -> StoredMemory {
        var memory = stored.memory
        memory.recordVersion += 1
        var resolution = stored.resolution
        resolution.recordVersion += 1

        try insertMemoryRecord(db, memory: memory)
        for anchor in stored.anchors {
            try insertAnchorRecord(db, anchor: anchor)
        }
        try insertResolutionRecord(db, resolution: resolution)
        for history in stored.history {
            try insertHistoryRecord(db, history: history)
        }
        return try requireStoredMemory(db, id: memory.id)
    }

    private func validateRestoreDeletedMemoryAsNew(
        _ db: Database,
        request: RestoreDeletedMemoryAsNewRequest
    ) throws -> DocumentRecord {
        let source = request.deleted.storedMemory
        let memory = source.memory
        guard request.expectedDocumentRecordVersion >= 1,
              request.deleted.expectedDocumentRecordVersion >= 1 else {
            throw MemoryStoreError.invalidRecord("The deletion undo precondition is invalid.")
        }
        let document = try requireDocumentVersion(
            db,
            id: memory.documentID,
            expected: request.expectedDocumentRecordVersion
        )
        guard try fetchMemory(db, id: memory.id) == nil else {
            throw MemoryStoreError.invalidRecord("This memory has already been restored.")
        }
        try Self.validateDeletedMemoryForRestoreAsNew(source)
        try requireCurrentRevision(
            document: document,
            checkedRevisionHash: source.resolution.checkedRevisionHash
        )
        if memory.kind == .passage,
           let selector = source.resolution.resolvedSelector {
            try rejectOverlap(
                db,
                documentID: memory.documentID,
                revisionHash: source.resolution.checkedRevisionHash,
                range: selector.canonicalTextPosition,
                excludingMemoryID: nil
            )
        }
        return document
    }

    private static func validateDeletedMemoryForRestoreAsNew(
        _ source: StoredMemory
    ) throws {
        let memory = source.memory
        let anchorIDs = Set(source.anchors.map(\.id))
        guard !source.anchors.isEmpty,
              anchorIDs.count == source.anchors.count,
              let originalAnchorID = memory.originalAnchorID,
              let currentAnchorID = memory.currentAnchorID,
              anchorIDs.contains(originalAnchorID),
              anchorIDs.contains(currentAnchorID),
              source.resolution.memoryID == memory.id,
              source.resolution.anchorID == currentAnchorID,
              source.history.allSatisfy({ $0.memoryID == memory.id }) else {
            throw MemoryStoreError.invalidRecord("The deleted memory lineage is incomplete.")
        }

        for anchor in source.anchors {
            guard anchor.memoryID == memory.id,
                  anchor.supersedesAnchorID.map(anchorIDs.contains) != false else {
                throw MemoryStoreError.invalidRecord("The deleted memory anchor history is invalid.")
            }
            try validateAnchor(
                NewConfirmedAnchor(
                    id: anchor.id,
                    supersedesAnchorID: anchor.supersedesAnchorID,
                    confirmation: anchor.confirmation,
                    createdAt: anchor.createdAt,
                    selectorVersion: anchor.selectorVersion,
                    projectionVersion: anchor.projectionVersion,
                    sourceRevisionHash: anchor.sourceRevisionHash,
                    resolverPolicyVersion: anchor.resolverPolicyVersion,
                    exactQuote: anchor.exactQuote,
                    prefix: anchor.prefix,
                    suffix: anchor.suffix,
                    canonicalTextPosition: anchor.canonicalTextPosition,
                    canonicalUTF8RangeInBlock: anchor.canonicalUTF8RangeInBlock,
                    blockKind: anchor.blockKind,
                    blockFingerprint: anchor.blockFingerprint,
                    headingPath: anchor.headingPath,
                    blockOrdinal: anchor.blockOrdinal,
                    blockFingerprintOccurrenceCountInSection: anchor.blockFingerprintOccurrenceCountInSection,
                    sourceUTF8Span: anchor.sourceUTF8Span
                )
            )
        }
        try validateResolution(
            ResolutionDraft(
                state: source.resolution.state,
                checkedRevisionHash: source.resolution.checkedRevisionHash,
                resolverPolicyVersion: source.resolution.resolverPolicyVersion,
                resolvedSelector: source.resolution.resolvedSelector,
                evidence: source.resolution.evidence,
                lastCheckedAt: source.resolution.lastCheckedAt
            )
        )

        for history in source.history {
            let snapshot = try decodedJSON(MemoryHistorySnapshot.self, from: history.snapshot)
            let snapshotAnchorIDs = Set(snapshot.anchors.map(\.id))
            guard snapshot.memory.id == memory.id,
                  snapshot.memory.documentID == memory.documentID,
                  snapshot.anchors.allSatisfy({ $0.memoryID == memory.id }),
                  snapshot.resolution.memoryID == memory.id,
                  snapshotAnchorIDs.contains(snapshot.resolution.anchorID),
                  snapshot.memory.originalAnchorID.map(snapshotAnchorIDs.contains) != false,
                  snapshot.memory.currentAnchorID.map(snapshotAnchorIDs.contains) != false,
                  snapshotAnchorIDs.isSubset(of: anchorIDs) else {
                throw MemoryStoreError.invalidRecord("The deleted memory audit history is invalid.")
            }
        }
    }

    private func copyDeletedMemoryAsNew(
        _ source: StoredMemory,
        memoryID: UUID,
        anchorIDMap: [UUID: UUID],
        restoredAt: Date
    ) throws -> StoredMemory {
        func mappedAnchorID(_ oldID: UUID?) throws -> UUID? {
            guard let oldID else { return nil }
            guard let mapped = anchorIDMap[oldID] else {
                throw MemoryStoreError.invalidRecord("The deleted memory anchor history is incomplete.")
            }
            return mapped
        }

        var memory = source.memory
        memory.id = memoryID
        memory.updatedAt = restoredAt
        memory.recordVersion = 1
        memory.originalAnchorID = try mappedAnchorID(memory.originalAnchorID)
        memory.currentAnchorID = try mappedAnchorID(memory.currentAnchorID)

        let anchors = try source.anchors.map { old -> ConfirmedAnchorRecord in
            guard let id = anchorIDMap[old.id] else {
                throw MemoryStoreError.invalidRecord("The deleted memory anchor history is incomplete.")
            }
            var anchor = old
            anchor.id = id
            anchor.memoryID = memoryID
            anchor.supersedesAnchorID = try mappedAnchorID(old.supersedesAnchorID)
            return anchor
        }

        var resolution = source.resolution
        resolution.memoryID = memoryID
        guard let mappedResolutionAnchorID = anchorIDMap[source.resolution.anchorID] else {
            throw MemoryStoreError.invalidRecord("The deleted memory resolution has no confirmed anchor.")
        }
        resolution.anchorID = mappedResolutionAnchorID
        resolution.recordVersion = 1

        let history = try source.history.map { old -> MemoryHistoryRecord in
            let oldSnapshot = try Self.decodedJSON(MemoryHistorySnapshot.self, from: old.snapshot)
            var snapshotMemory = oldSnapshot.memory
            snapshotMemory.id = memoryID
            snapshotMemory.originalAnchorID = try mappedAnchorID(snapshotMemory.originalAnchorID)
            snapshotMemory.currentAnchorID = try mappedAnchorID(snapshotMemory.currentAnchorID)

            let snapshotAnchors = try oldSnapshot.anchors.map { oldAnchor -> ConfirmedAnchorRecord in
                guard let id = anchorIDMap[oldAnchor.id] else {
                    throw MemoryStoreError.invalidRecord("The deleted memory audit history has an unknown anchor.")
                }
                var anchor = oldAnchor
                anchor.id = id
                anchor.memoryID = memoryID
                anchor.supersedesAnchorID = try mappedAnchorID(oldAnchor.supersedesAnchorID)
                return anchor
            }

            var snapshotResolution = oldSnapshot.resolution
            snapshotResolution.memoryID = memoryID
            guard let snapshotResolutionAnchorID = anchorIDMap[oldSnapshot.resolution.anchorID] else {
                throw MemoryStoreError.invalidRecord("The deleted memory audit history has an unknown resolution anchor.")
            }
            snapshotResolution.anchorID = snapshotResolutionAnchorID

            return MemoryHistoryRecord(
                id: UUID(),
                memoryID: memoryID,
                kind: old.kind,
                snapshot: try Self.encodedJSON(
                    MemoryHistorySnapshot(
                        memory: snapshotMemory,
                        anchors: snapshotAnchors,
                        resolution: snapshotResolution
                    )
                ),
                createdAt: old.createdAt
            )
        }

        return StoredMemory(
            memory: memory,
            anchors: anchors,
            resolution: resolution,
            history: history
        )
    }

    func insertMemoryRecord(_ db: Database, memory: ReadingMemoryRecord) throws {
        try db.execute(
            sql: """
                INSERT INTO memories (
                    id, document_id, kind, original_visible_quote, canonical_match_quote,
                    note_text, created_at, updated_at, record_version,
                    original_anchor_id, current_anchor_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                Self.normalizedID(memory.id),
                Self.normalizedID(memory.documentID),
                memory.kind.rawValue,
                memory.originalVisibleQuote,
                memory.canonicalMatchQuote,
                memory.noteText,
                Self.timestamp(memory.createdAt),
                Self.timestamp(memory.updatedAt),
                memory.recordVersion,
                memory.originalAnchorID.map(Self.normalizedID),
                memory.currentAnchorID.map(Self.normalizedID),
            ]
        )
    }

    func insertAnchorRecord(_ db: Database, anchor: ConfirmedAnchorRecord) throws {
        try insertAnchor(
            db,
            memoryID: anchor.memoryID,
            anchor: NewConfirmedAnchor(
                id: anchor.id,
                supersedesAnchorID: anchor.supersedesAnchorID,
                confirmation: anchor.confirmation,
                createdAt: anchor.createdAt,
                selectorVersion: anchor.selectorVersion,
                projectionVersion: anchor.projectionVersion,
                sourceRevisionHash: anchor.sourceRevisionHash,
                resolverPolicyVersion: anchor.resolverPolicyVersion,
                exactQuote: anchor.exactQuote,
                prefix: anchor.prefix,
                suffix: anchor.suffix,
                canonicalTextPosition: anchor.canonicalTextPosition,
                canonicalUTF8RangeInBlock: anchor.canonicalUTF8RangeInBlock,
                blockKind: anchor.blockKind,
                blockFingerprint: anchor.blockFingerprint,
                headingPath: anchor.headingPath,
                blockOrdinal: anchor.blockOrdinal,
                blockFingerprintOccurrenceCountInSection: anchor.blockFingerprintOccurrenceCountInSection,
                sourceUTF8Span: anchor.sourceUTF8Span
            )
        )
    }

    func insertResolutionRecord(_ db: Database, resolution: CurrentResolutionRecord) throws {
        try insertResolution(
            db,
            memoryID: resolution.memoryID,
            anchorID: resolution.anchorID,
            resolution: ResolutionDraft(
                state: resolution.state,
                checkedRevisionHash: resolution.checkedRevisionHash,
                resolverPolicyVersion: resolution.resolverPolicyVersion,
                resolvedSelector: resolution.resolvedSelector,
                evidence: resolution.evidence,
                lastCheckedAt: resolution.lastCheckedAt
            ),
            recordVersion: resolution.recordVersion
        )
    }

    func insertHistoryRecord(_ db: Database, history: MemoryHistoryRecord) throws {
        try db.execute(
            sql: """
                INSERT INTO memory_history (id, memory_id, kind, snapshot_json, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [
                Self.normalizedID(history.id),
                Self.normalizedID(history.memoryID),
                history.kind.rawValue,
                history.snapshot,
                Self.timestamp(history.createdAt),
            ]
        )
    }

    func insertReadingState(_ db: Database, state: ReadingStateRecord) throws {
        try db.execute(
            sql: """
                INSERT INTO reading_state (
                    document_id, semantic_block_fingerprint, canonical_utf8_offset,
                    fallback_scroll_fraction, last_semantic_heading, last_read_at, record_version
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                Self.normalizedID(state.documentID),
                state.semanticPosition?.blockFingerprint,
                state.semanticPosition?.canonicalUTF8Offset,
                state.fallbackScrollFraction,
                state.lastSemanticHeading,
                Self.timestamp(state.lastReadAt),
                state.recordVersion,
            ]
        )
    }
}
