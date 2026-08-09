import Foundation
import GRDB

extension SQLiteMemoryStore {
    func searchMemories(_ query: MemorySearchQuery) throws -> [MemorySearchResult] {
        try Self.validatePagination(limit: query.limit, offset: query.offset)
        return try read { db in
            var joins = """
                JOIN memory_resolutions r ON r.memory_id = m.id
                JOIN documents d ON d.id = m.document_id
                LEFT JOIN document_locations dl
                    ON dl.document_id = d.id AND dl.is_current = 1
                """
            var predicates: [String] = []
            var arguments = StatementArguments()

            if let expression = Self.ftsExpression(for: query.text, scope: query.scope) {
                joins += "\nJOIN memories_fts ON memories_fts.memory_id = m.id"
                predicates.append("memories_fts MATCH ?")
                arguments += [expression]
            }

            switch query.facet {
            case .all:
                break
            case .highlights:
                predicates.append("m.kind = 'passage'")
            case .notes:
                predicates.append("m.note_text IS NOT NULL AND length(trim(m.note_text)) > 0")
            case .bookmarks:
                predicates.append("m.kind = 'headingBookmark'")
            case .chooseLocation:
                predicates.append("r.state = 'ambiguous'")
            case .needsRepair:
                predicates.append("r.state IN ('needsReview', 'orphaned')")
            }

            let whereClause = predicates.isEmpty ? "" : "WHERE \(predicates.joined(separator: " AND "))"
            arguments += [query.limit, query.offset]
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT m.*, r.state AS result_resolution_state,
                           d.display_name AS result_document_display_name,
                           d.availability AS result_document_availability,
                           dl.file_path AS result_file_path,
                           COUNT(*) OVER() AS result_total_count
                    FROM memories m
                    \(joins)
                    \(whereClause)
                    ORDER BY m.created_at DESC, m.id ASC
                    LIMIT ? OFFSET ?
                    """,
                arguments: arguments
            )
            return try rows.map { row in
                let stateRaw: String = row["result_resolution_state"]
                let displayName: String = row["result_document_display_name"]
                let availabilityRaw: String = row["result_document_availability"]
                let path: String? = row["result_file_path"]
                let total: Int = row["result_total_count"]
                guard let state = MemoryResolutionState(rawValue: stateRaw),
                      let availability = DocumentAvailability(rawValue: availabilityRaw) else {
                    throw MemoryStoreError.corruptedDatabase
                }
                return MemorySearchResult(
                    memory: try Self.decodeMemory(row),
                    resolutionState: state,
                    documentDisplayName: displayName,
                    documentAvailability: availability,
                    currentDocumentURL: path.map { URL(fileURLWithPath: $0) },
                    totalCount: total
                )
            }
        }
    }

    func searchDocuments(_ query: DocumentSearchQuery) throws -> [DocumentSearchResult] {
        try Self.validatePagination(limit: query.limit, offset: query.offset)
        return try read { db in
            var joins = """
                LEFT JOIN reading_state rs ON rs.document_id = d.id
                LEFT JOIN document_locations dl
                    ON dl.document_id = d.id AND dl.is_current = 1
                """
            var predicates: [String] = []
            var arguments = StatementArguments()
            if let expression = Self.ftsExpression(for: query.text) {
                joins += "\nJOIN documents_fts ON documents_fts.document_id = d.id"
                predicates.append("documents_fts MATCH ?")
                arguments += [expression]
            }
            switch query.facet {
            case .all:
                break
            case .continueReading:
                predicates.append("rs.document_id IS NOT NULL")
            case .favourites:
                predicates.append("d.is_favourite = 1")
            }
            let whereClause = predicates.isEmpty ? "" : "WHERE \(predicates.joined(separator: " AND "))"
            let ordering: String
            switch query.facet {
            case .continueReading:
                ordering = "rs.last_read_at DESC, d.display_name COLLATE NOCASE, d.id"
            case .all, .favourites:
                ordering = "d.last_opened_at DESC, d.display_name COLLATE NOCASE, d.id"
            }
            arguments += [query.limit, query.offset]

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT d.*,
                           dl.file_path AS result_file_path,
                           rs.document_id AS rs_document_id,
                           rs.semantic_block_fingerprint AS rs_block_fingerprint,
                           rs.canonical_utf8_offset AS rs_canonical_offset,
                           rs.fallback_scroll_fraction AS rs_scroll_fraction,
                           rs.last_semantic_heading AS rs_last_heading,
                           rs.last_read_at AS rs_last_read_at,
                           rs.record_version AS rs_record_version,
                           (
                               SELECT COUNT(*) FROM documents duplicate
                               WHERE duplicate.display_name = d.display_name
                           ) AS result_duplicate_name_count,
                           COUNT(*) OVER() AS result_total_count
                    FROM documents d
                    \(joins)
                    \(whereClause)
                    ORDER BY \(ordering)
                    LIMIT ? OFFSET ?
                    """,
                arguments: arguments
            )
            return try rows.map { row in
                let path: String? = row["result_file_path"]
                let duplicateNameCount: Int = row["result_duplicate_name_count"]
                let provenance = path.flatMap { path -> String? in
                    guard duplicateNameCount > 1 else { return nil }
                    return URL(fileURLWithPath: path)
                        .deletingLastPathComponent()
                        .lastPathComponent
                }
                let readingState = try Self.decodeJoinedReadingState(row)
                let total: Int = row["result_total_count"]
                return DocumentSearchResult(
                    document: try Self.decodeDocument(row),
                    currentURL: path.map { URL(fileURLWithPath: $0) },
                    parentFolderProvenance: provenance,
                    readingState: readingState,
                    totalCount: total
                )
            }
        }
    }

    func snapshot() throws -> MemoryStoreSnapshot {
        try snapshotWithSequence().snapshot
    }

    func snapshotWithSequence() throws -> SequencedMemoryStoreSnapshot {
        try read { db in
            SequencedMemoryStoreSnapshot(
                snapshot: try makeSnapshot(db),
                sequence: try Self.fetchChangeSequence(db)
            )
        }
    }

    private func makeSnapshot(_ db: Database) throws -> MemoryStoreSnapshot {
        let documentRows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM documents ORDER BY display_name COLLATE NOCASE, id"
        )
        let locationRows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM document_locations
                ORDER BY document_id, first_seen_at, id
                """
        )
        let readingRows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM reading_state ORDER BY document_id"
        )
        let memoryIDStrings = try String.fetchAll(
            db,
            sql: """
                SELECT id FROM memories
                ORDER BY document_id, created_at, id
                """
        )
        let memories = try memoryIDStrings.map { idString in
            try requireStoredMemory(db, id: Self.decodedID(idString))
        }
        return MemoryStoreSnapshot(
            schemaVersion: schemaVersion,
            documents: try documentRows.map(Self.decodeDocument),
            documentLocations: try locationRows.map(Self.decodeDocumentLocation),
            readingStates: try readingRows.map(Self.decodeReadingState),
            memories: memories
        )
    }
}

private extension SQLiteMemoryStore {
    static func validatePagination(limit: Int, offset: Int) throws {
        guard (1...500).contains(limit), offset >= 0 else {
            throw MemoryStoreError.invalidRecord("Search pagination is outside the supported range.")
        }
    }

    static func ftsExpression(for text: String, scope: MemorySearchScope) -> String? {
        guard let phrase = quotedFTSPhrase(text) else { return nil }
        switch scope {
        case .all:
            return phrase
        case .passages:
            return "passage_text : \(phrase)"
        case .notes:
            return "note_text : \(phrase)"
        case .headings:
            return "heading_text : \(phrase)"
        }
    }

    static func ftsExpression(for text: String) -> String? {
        quotedFTSPhrase(text)
    }

    static func quotedFTSPhrase(_ text: String) -> String? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return "\"\(normalized.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func decodeJoinedReadingState(_ row: Row) throws -> ReadingStateRecord? {
        let documentID: String? = row["rs_document_id"]
        guard let documentID else { return nil }
        let fingerprint: String? = row["rs_block_fingerprint"]
        let offset: Int64? = row["rs_canonical_offset"]
        let fraction: Double = row["rs_scroll_fraction"]
        let heading: String? = row["rs_last_heading"]
        let readAt: Double = row["rs_last_read_at"]
        let version: Int64 = row["rs_record_version"]
        let position: SemanticReadingPosition?
        switch (fingerprint, offset) {
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
}
