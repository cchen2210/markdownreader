import Foundation
import GRDB

extension SQLiteMemoryStore {
    func createDocument(_ document: NewDocument, location: NewDocumentLocation?) throws -> DocumentRecord {
        try Self.validateDocument(document)
        if let location {
            try Self.validateFileURL(location.url)
        }

        let record = try write { db in
            let id = Self.normalizedID(document.id)
            guard try !dbRowExists(db, table: "documents", id: id) else {
                throw MemoryStoreError.duplicateIdentifier(.document)
            }
            try db.execute(
                sql: """
                    INSERT INTO documents (
                        id, display_name, bookmark_data, volume_identifier,
                        file_resource_identifier, last_confirmed_content_hash,
                        detected_text_encoding, had_byte_order_mark, availability,
                        is_favourite, record_version, created_at, last_opened_at, last_seen_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
                    """,
                arguments: [
                    id,
                    document.displayName,
                    document.bookmarkData,
                    document.fileIdentity.volumeIdentifier,
                    document.fileIdentity.fileResourceIdentifier,
                    document.lastConfirmedContentHash,
                    document.detectedTextEncoding,
                    document.hadByteOrderMark.map { $0 ? 1 : 0 },
                    document.availability.rawValue,
                    document.isFavourite ? 1 : 0,
                    Self.timestamp(document.createdAt),
                    Self.timestamp(document.lastOpenedAt),
                    Self.timestamp(document.lastSeenAt),
                ]
            )
            if let location {
                try insertDocumentLocation(db, documentID: document.id, location: location)
            }
            try refreshDocumentFTS(db, documentID: document.id)
            return try requireDocument(db, id: document.id)
        }
        publish(kind: .document, documentIDs: [document.id])
        return record
    }

    /// One atomic identity decision: the prior record keeps its memories and
    /// history but no longer claims the path, while a new document record
    /// becomes the current owner of the replacement file.
    func createReplacementDocument(
        _ document: NewDocument,
        location: NewDocumentLocation,
        replacingDocumentID: UUID,
        expectedReplacedDocumentRecordVersion: Int64
    ) throws -> DocumentRecord {
        try Self.validateDocument(document)
        try Self.validateFileURL(location.url)
        guard document.id != replacingDocumentID,
              document.fileIdentity.isComplete else {
            throw MemoryStoreError.invalidRecord("A replacement needs a distinct complete file identity.")
        }
        let created = try write { db in
            let replaced = try requireDocumentVersion(
                db,
                id: replacingDocumentID,
                expected: expectedReplacedDocumentRecordVersion
            )
            guard replaced.fileIdentity != document.fileIdentity else {
                throw MemoryStoreError.invalidRecord("The replacement has the original file identity.")
            }
            let path = Self.normalizedFilePath(location.url)
            let priorPath = try String.fetchOne(
                db,
                sql: """
                    SELECT file_path FROM document_locations
                    WHERE document_id = ? AND is_current = 1
                    ORDER BY last_seen_at DESC, id ASC LIMIT 1
                    """,
                arguments: [Self.normalizedID(replacingDocumentID)]
            )
            guard priorPath == path else {
                throw MemoryStoreError.staleSourceIdentity
            }
            guard try !dbRowExists(db, table: "documents", id: Self.normalizedID(document.id)) else {
                throw MemoryStoreError.duplicateIdentifier(.document)
            }
            let identityOwner = try String.fetchOne(
                db,
                sql: """
                    SELECT id FROM documents
                    WHERE volume_identifier = ? AND file_resource_identifier = ?
                    LIMIT 1
                    """,
                arguments: [
                    document.fileIdentity.volumeIdentifier,
                    document.fileIdentity.fileResourceIdentifier,
                ]
            )
            guard identityOwner == nil else {
                throw MemoryStoreError.staleSourceIdentity
            }

            try db.execute(
                sql: """
                    UPDATE document_locations
                    SET is_current = 0
                    WHERE document_id = ? AND is_current = 1
                    """,
                arguments: [Self.normalizedID(replacingDocumentID)]
            )
            try db.execute(
                sql: """
                    UPDATE documents
                    SET availability = ?, last_seen_at = ?, record_version = record_version + 1
                    WHERE id = ? AND record_version = ?
                    """,
                arguments: [
                    DocumentAvailability.unavailable.rawValue,
                    Self.timestamp(location.observedAt),
                    Self.normalizedID(replacingDocumentID),
                    expectedReplacedDocumentRecordVersion,
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO documents (
                        id, display_name, bookmark_data, volume_identifier,
                        file_resource_identifier, last_confirmed_content_hash,
                        detected_text_encoding, had_byte_order_mark, availability,
                        is_favourite, record_version, created_at, last_opened_at, last_seen_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
                    """,
                arguments: [
                    Self.normalizedID(document.id),
                    document.displayName,
                    document.bookmarkData,
                    document.fileIdentity.volumeIdentifier,
                    document.fileIdentity.fileResourceIdentifier,
                    document.lastConfirmedContentHash,
                    document.detectedTextEncoding,
                    document.hadByteOrderMark.map { $0 ? 1 : 0 },
                    document.availability.rawValue,
                    document.isFavourite ? 1 : 0,
                    Self.timestamp(document.createdAt),
                    Self.timestamp(document.lastOpenedAt),
                    Self.timestamp(document.lastSeenAt),
                ]
            )
            try insertDocumentLocation(db, documentID: document.id, location: location)
            try refreshDocumentFTS(db, documentID: replacingDocumentID)
            try refreshDocumentFTS(db, documentID: document.id)
            return try requireDocument(db, id: document.id)
        }
        publish(
            kind: .document,
            documentIDs: [replacingDocumentID, document.id]
        )
        return created
    }

    func document(id: UUID) throws -> DocumentRecord? {
        try read { db in
            try fetchDocument(db, id: id)
        }
    }

    func documents(matching identity: FileIdentity) throws -> [DocumentRecord] {
        guard identity.isComplete else { return [] }
        return try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM documents
                    WHERE volume_identifier = ? AND file_resource_identifier = ?
                    ORDER BY last_seen_at DESC, id ASC
                    """,
                arguments: [identity.volumeIdentifier, identity.fileResourceIdentifier]
            )
            return try rows.map(Self.decodeDocument)
        }
    }

    func documentLocations(documentID: UUID) throws -> [DocumentLocationRecord] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM document_locations
                    WHERE document_id = ?
                    ORDER BY is_current DESC, last_seen_at DESC, id ASC
                    """,
                arguments: [Self.normalizedID(documentID)]
            )
            return try rows.map(Self.decodeDocumentLocation)
        }
    }

    func recordLocation(
        _ location: NewDocumentLocation,
        for documentID: UUID,
        expectedRecordVersion: Int64
    ) throws -> DocumentRecord {
        try Self.validateFileURL(location.url)
        let record = try write { db in
            _ = try requireDocumentVersion(db, id: documentID, expected: expectedRecordVersion)
            try db.execute(
                sql: "UPDATE document_locations SET is_current = 0 WHERE document_id = ? AND is_current = 1",
                arguments: [Self.normalizedID(documentID)]
            )

            let path = Self.normalizedFilePath(location.url)
            if let existingID = try String.fetchOne(
                db,
                sql: "SELECT id FROM document_locations WHERE document_id = ? AND file_path = ?",
                arguments: [Self.normalizedID(documentID), path]
            ) {
                try db.execute(
                    sql: """
                        UPDATE document_locations
                        SET is_current = 1, last_seen_at = ?
                        WHERE id = ?
                        """,
                    arguments: [Self.timestamp(location.observedAt), existingID]
                )
            } else {
                try insertDocumentLocation(db, documentID: documentID, location: location)
            }

            try db.execute(
                sql: """
                    UPDATE documents
                    SET last_seen_at = ?, record_version = record_version + 1
                    WHERE id = ? AND record_version = ?
                    """,
                arguments: [
                    Self.timestamp(location.observedAt),
                    Self.normalizedID(documentID),
                    expectedRecordVersion,
                ]
            )
            try refreshDocumentFTS(db, documentID: documentID)
            return try requireDocument(db, id: documentID)
        }
        publish(kind: .document, documentIDs: [documentID])
        return record
    }

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
    ) throws -> DocumentRecord {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryStoreError.invalidRecord("A document needs a display name.")
        }
        let record = try write { db in
            _ = try requireDocumentVersion(db, id: documentID, expected: expectedRecordVersion)
            try db.execute(
                sql: """
                    UPDATE documents
                    SET display_name = ?, bookmark_data = ?, volume_identifier = ?,
                        file_resource_identifier = ?, last_confirmed_content_hash = ?,
                        detected_text_encoding = ?, had_byte_order_mark = ?, availability = ?,
                        last_opened_at = ?, last_seen_at = ?, record_version = record_version + 1
                    WHERE id = ? AND record_version = ?
                    """,
                arguments: [
                    displayName,
                    bookmarkData,
                    fileIdentity.volumeIdentifier,
                    fileIdentity.fileResourceIdentifier,
                    lastConfirmedContentHash,
                    detectedTextEncoding,
                    hadByteOrderMark.map { $0 ? 1 : 0 },
                    availability.rawValue,
                    Self.timestamp(openedAt),
                    Self.timestamp(openedAt),
                    Self.normalizedID(documentID),
                    expectedRecordVersion,
                ]
            )
            try refreshDocumentFTS(db, documentID: documentID)
            return try requireDocument(db, id: documentID)
        }
        publish(kind: .document, documentIDs: [documentID])
        return record
    }

    func setFavourite(
        documentID: UUID,
        isFavourite: Bool,
        expectedRecordVersion: Int64
    ) throws -> FavouriteMutation {
        let mutation = try write { db in
            let current = try requireDocumentVersion(db, id: documentID, expected: expectedRecordVersion)
            if current.isFavourite == isFavourite {
                return FavouriteMutation(
                    document: current,
                    undo: FavouriteUndoPayload(
                        documentID: documentID,
                        previousValue: current.isFavourite,
                        expectedDocumentRecordVersion: current.recordVersion
                    )
                )
            }
            try db.execute(
                sql: """
                    UPDATE documents
                    SET is_favourite = ?, record_version = record_version + 1
                    WHERE id = ? AND record_version = ?
                    """,
                arguments: [isFavourite ? 1 : 0, Self.normalizedID(documentID), expectedRecordVersion]
            )
            let updated = try requireDocument(db, id: documentID)
            return FavouriteMutation(
                document: updated,
                undo: FavouriteUndoPayload(
                    documentID: documentID,
                    previousValue: current.isFavourite,
                    expectedDocumentRecordVersion: updated.recordVersion
                )
            )
        }
        publish(kind: .document, documentIDs: [documentID])
        return mutation
    }

    func undoFavourite(_ payload: FavouriteUndoPayload) throws -> DocumentRecord {
        let record = try write { db in
            let current = try requireDocumentVersion(
                db,
                id: payload.documentID,
                expected: payload.expectedDocumentRecordVersion
            )
            guard current.isFavourite != payload.previousValue else { return current }
            try db.execute(
                sql: """
                    UPDATE documents
                    SET is_favourite = ?, record_version = record_version + 1
                    WHERE id = ? AND record_version = ?
                    """,
                arguments: [
                    payload.previousValue ? 1 : 0,
                    Self.normalizedID(payload.documentID),
                    payload.expectedDocumentRecordVersion,
                ]
            )
            return try requireDocument(db, id: payload.documentID)
        }
        publish(kind: .document, documentIDs: [payload.documentID])
        return record
    }

    func readingState(documentID: UUID) throws -> ReadingStateRecord? {
        try read { db in
            try fetchReadingState(db, documentID: documentID)
        }
    }

    func updateReadingState(
        documentID: UUID,
        update: ReadingStateUpdate,
        expectedRecordVersion: Int64?
    ) throws -> ReadingStateRecord {
        try Self.validateReadingState(update)
        let state = try write { db in
            guard try fetchDocument(db, id: documentID) != nil else {
                throw MemoryStoreError.notFound(.document)
            }
            let current = try fetchReadingState(db, documentID: documentID)
            switch (current, expectedRecordVersion) {
            case (nil, nil):
                try db.execute(
                    sql: """
                        INSERT INTO reading_state (
                            document_id, semantic_block_fingerprint, canonical_utf8_offset,
                            fallback_scroll_fraction, last_semantic_heading, last_read_at, record_version
                        ) VALUES (?, ?, ?, ?, ?, ?, 1)
                        """,
                    arguments: Self.readingStateArguments(documentID: documentID, update: update)
                )
            case let (.some(current), .some(expected)) where current.recordVersion == expected:
                try db.execute(
                    sql: """
                        UPDATE reading_state
                        SET semantic_block_fingerprint = ?, canonical_utf8_offset = ?,
                            fallback_scroll_fraction = ?, last_semantic_heading = ?, last_read_at = ?,
                            record_version = record_version + 1
                        WHERE document_id = ? AND record_version = ?
                        """,
                    arguments: [
                        update.semanticPosition?.blockFingerprint,
                        update.semanticPosition?.canonicalUTF8Offset,
                        update.fallbackScrollFraction,
                        update.lastSemanticHeading,
                        Self.timestamp(update.lastReadAt),
                        Self.normalizedID(documentID),
                        expected,
                    ]
                )
            case let (.some(current), .some(expected)):
                throw MemoryStoreError.versionConflict(
                    entity: .readingState,
                    expected: expected,
                    actual: current.recordVersion
                )
            case let (.some(current), nil):
                throw MemoryStoreError.versionConflict(
                    entity: .readingState,
                    expected: 0,
                    actual: current.recordVersion
                )
            case (nil, let .some(expected)):
                throw MemoryStoreError.versionConflict(
                    entity: .readingState,
                    expected: expected,
                    actual: nil
                )
            }
            try refreshDocumentFTS(db, documentID: documentID)
            return try requireReadingState(db, documentID: documentID)
        }
        publish(kind: .readingState, documentIDs: [documentID])
        return state
    }

    func importLegacyReadingStateIfNeeded(
        documentID: UUID,
        legacyKeyHash: String,
        fallbackScrollFraction: Double,
        importedAt: Date
    ) throws -> ReadingStateRecord? {
        let update = ReadingStateUpdate(
            semanticPosition: nil,
            fallbackScrollFraction: fallbackScrollFraction,
            lastReadAt: importedAt
        )
        try Self.validateReadingState(update)
        guard !legacyKeyHash.isEmpty else {
            throw MemoryStoreError.invalidRecord("The legacy reading-position key is invalid.")
        }

        let state: ReadingStateRecord? = try write { db in
            guard try fetchDocument(db, id: documentID) != nil else {
                throw MemoryStoreError.notFound(.document)
            }
            let consumed = try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM legacy_reading_imports WHERE legacy_key_hash = ?",
                arguments: [legacyKeyHash]
            ) != nil
            guard !consumed else { return nil }

            let state: ReadingStateRecord
            if let existing = try fetchReadingState(db, documentID: documentID) {
                state = existing
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO reading_state (
                            document_id, semantic_block_fingerprint, canonical_utf8_offset,
                            fallback_scroll_fraction, last_semantic_heading, last_read_at, record_version
                        ) VALUES (?, NULL, NULL, ?, NULL, ?, 1)
                        """,
                    arguments: [
                        Self.normalizedID(documentID),
                        fallbackScrollFraction,
                        Self.timestamp(importedAt),
                    ]
                )
                state = try requireReadingState(db, documentID: documentID)
            }
            try db.execute(
                sql: """
                    INSERT INTO legacy_reading_imports (legacy_key_hash, document_id, imported_at)
                    VALUES (?, ?, ?)
                    """,
                arguments: [legacyKeyHash, Self.normalizedID(documentID), Self.timestamp(importedAt)]
            )
            try refreshDocumentFTS(db, documentID: documentID)
            return state
        }
        if state != nil {
            publish(kind: .readingState, documentIDs: [documentID])
        }
        return state
    }
}

extension SQLiteMemoryStore {
    static func validateFileURL(_ url: URL) throws {
        guard url.isFileURL, !url.path.isEmpty else {
            throw MemoryStoreError.invalidRecord("A document location must be a local file URL.")
        }
    }

    static func normalizedFilePath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    func dbRowExists(_ db: Database, table: String, id: String) throws -> Bool {
        // `table` is selected exclusively by internal callers, never user input.
        try Int.fetchOne(db, sql: "SELECT 1 FROM \(table) WHERE id = ?", arguments: [id]) != nil
    }

    func fetchDocument(_ db: Database, id: UUID) throws -> DocumentRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM documents WHERE id = ?",
            arguments: [Self.normalizedID(id)]
        ) else { return nil }
        return try Self.decodeDocument(row)
    }

    func requireDocument(_ db: Database, id: UUID) throws -> DocumentRecord {
        guard let document = try fetchDocument(db, id: id) else {
            throw MemoryStoreError.notFound(.document)
        }
        return document
    }

    func requireDocumentVersion(
        _ db: Database,
        id: UUID,
        expected: Int64
    ) throws -> DocumentRecord {
        guard let document = try fetchDocument(db, id: id) else {
            throw MemoryStoreError.versionConflict(entity: .document, expected: expected, actual: nil)
        }
        guard document.recordVersion == expected else {
            throw MemoryStoreError.versionConflict(
                entity: .document,
                expected: expected,
                actual: document.recordVersion
            )
        }
        return document
    }

    static func decodeDocument(_ row: Row) throws -> DocumentRecord {
        let idString: String = row["id"]
        let displayName: String = row["display_name"]
        let bookmarkData: Data? = row["bookmark_data"]
        let volumeIdentifier: Data? = row["volume_identifier"]
        let resourceIdentifier: Data? = row["file_resource_identifier"]
        let contentHash: String? = row["last_confirmed_content_hash"]
        let encoding: String? = row["detected_text_encoding"]
        let bom: Int64? = row["had_byte_order_mark"]
        let availabilityRaw: String = row["availability"]
        let favourite: Int64 = row["is_favourite"]
        let version: Int64 = row["record_version"]
        let created: Double = row["created_at"]
        let opened: Double = row["last_opened_at"]
        let seen: Double = row["last_seen_at"]
        guard let availability = DocumentAvailability(rawValue: availabilityRaw) else {
            throw MemoryStoreError.corruptedDatabase
        }
        return DocumentRecord(
            id: try decodedID(idString),
            displayName: displayName,
            bookmarkData: bookmarkData,
            fileIdentity: FileIdentity(
                volumeIdentifier: volumeIdentifier,
                fileResourceIdentifier: resourceIdentifier
            ),
            lastConfirmedContentHash: contentHash,
            detectedTextEncoding: encoding,
            hadByteOrderMark: bom.map { $0 != 0 },
            availability: availability,
            isFavourite: favourite != 0,
            recordVersion: version,
            createdAt: date(created),
            lastOpenedAt: date(opened),
            lastSeenAt: date(seen)
        )
    }

    static func decodeDocumentLocation(_ row: Row) throws -> DocumentLocationRecord {
        let id: String = row["id"]
        let documentID: String = row["document_id"]
        let path: String = row["file_path"]
        let current: Int64 = row["is_current"]
        let firstSeen: Double = row["first_seen_at"]
        let lastSeen: Double = row["last_seen_at"]
        return DocumentLocationRecord(
            id: try decodedID(id),
            documentID: try decodedID(documentID),
            url: URL(fileURLWithPath: path),
            isCurrent: current != 0,
            firstSeenAt: date(firstSeen),
            lastSeenAt: date(lastSeen)
        )
    }

    func insertDocumentLocation(
        _ db: Database,
        documentID: UUID,
        location: NewDocumentLocation
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO document_locations (
                    id, document_id, file_path, is_current, first_seen_at, last_seen_at
                ) VALUES (?, ?, ?, 1, ?, ?)
                """,
            arguments: [
                Self.normalizedID(location.id),
                Self.normalizedID(documentID),
                Self.normalizedFilePath(location.url),
                Self.timestamp(location.observedAt),
                Self.timestamp(location.observedAt),
            ]
        )
    }

    func fetchReadingState(_ db: Database, documentID: UUID) throws -> ReadingStateRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM reading_state WHERE document_id = ?",
            arguments: [Self.normalizedID(documentID)]
        ) else { return nil }
        return try Self.decodeReadingState(row)
    }

    func requireReadingState(_ db: Database, documentID: UUID) throws -> ReadingStateRecord {
        guard let state = try fetchReadingState(db, documentID: documentID) else {
            throw MemoryStoreError.notFound(.readingState)
        }
        return state
    }

    static func decodeReadingState(_ row: Row) throws -> ReadingStateRecord {
        let documentID: String = row["document_id"]
        let blockFingerprint: String? = row["semantic_block_fingerprint"]
        let offset: Int64? = row["canonical_utf8_offset"]
        let fraction: Double = row["fallback_scroll_fraction"]
        let heading: String? = row["last_semantic_heading"]
        let readAt: Double = row["last_read_at"]
        let version: Int64 = row["record_version"]
        let position: SemanticReadingPosition?
        switch (blockFingerprint, offset) {
        case let (.some(fingerprint), .some(offset)):
            position = SemanticReadingPosition(
                blockFingerprint: fingerprint,
                canonicalUTF8Offset: offset
            )
        case (nil, nil):
            position = nil
        default:
            throw MemoryStoreError.corruptedDatabase
        }
        return ReadingStateRecord(
            documentID: try decodedID(documentID),
            semanticPosition: position,
            fallbackScrollFraction: fraction,
            lastSemanticHeading: heading,
            lastReadAt: date(readAt),
            recordVersion: version
        )
    }

    static func readingStateArguments(
        documentID: UUID,
        update: ReadingStateUpdate
    ) -> StatementArguments {
        [
            normalizedID(documentID),
            update.semanticPosition?.blockFingerprint,
            update.semanticPosition?.canonicalUTF8Offset,
            update.fallbackScrollFraction,
            update.lastSemanticHeading,
            timestamp(update.lastReadAt),
        ]
    }

    func refreshDocumentFTS(_ db: Database, documentID: UUID) throws {
        let id = Self.normalizedID(documentID)
        try db.execute(sql: "DELETE FROM documents_fts WHERE document_id = ?", arguments: [id])
        guard let document = try fetchDocument(db, id: documentID) else { return }
        let path = try String.fetchOne(
            db,
            sql: """
                SELECT file_path FROM document_locations
                WHERE document_id = ? AND is_current = 1
                """,
            arguments: [id]
        )
        let parentFolder = path.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent
        } ?? ""
        let heading = try String.fetchOne(
            db,
            sql: "SELECT last_semantic_heading FROM reading_state WHERE document_id = ?",
            arguments: [id]
        ) ?? ""
        try db.execute(
            sql: """
                INSERT INTO documents_fts (document_id, display_name, parent_folder, last_heading)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [id, document.displayName, parentFolder, heading]
        )
    }
}
