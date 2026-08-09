import Darwin
import Foundation
import GRDB

final class SQLiteMemoryStore: MemoryStore, @unchecked Sendable {
    static let latestSchemaVersion = 1
    static let applicationSupportDirectoryName = "com.cchen.MarkdownReader"
    static let databaseFileName = "ReadingMemory.sqlite3"

    let schemaVersion = SQLiteMemoryStore.latestSchemaVersion
    let databaseURL: URL
    let dbPool: DatabasePool

    private let fileManager: FileManager
    private let observersLock = NSLock()
    private var observers: [UUID: AsyncStream<MemoryStoreChange>.Continuation] = [:]
    /// Mirrors the last sequence committed by this store instance for local
    /// observation delivery. The authoritative value is persisted in SQLite.
    private var changeSequence: UInt64 = 0

    convenience init(fileManager: FileManager = .default) throws {
        let applicationSupport: URL
        do {
            applicationSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            throw MemoryStoreError.openFailed
        }
        let directory = applicationSupport
            .appendingPathComponent(Self.applicationSupportDirectoryName, isDirectory: true)
        try self.init(
            databaseURL: directory.appendingPathComponent(Self.databaseFileName),
            fileManager: fileManager
        )
    }

    init(databaseURL: URL, fileManager: FileManager = .default) throws {
        guard databaseURL.isFileURL else {
            throw MemoryStoreError.invalidRecord("Reading Memory requires a local database location.")
        }
        self.databaseURL = databaseURL.standardizedFileURL
        self.fileManager = fileManager

        let directory = self.databaseURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw MemoryStoreError.openFailed
        }

        let existedWithContent = Self.fileExistsWithContent(at: self.databaseURL, fileManager: fileManager)
        if existedWithContent {
            try Self.preflightExistingDatabase(at: self.databaseURL)
        }

        var configuration = Configuration()
        configuration.label = "ReadingMemory"
        configuration.journalMode = .wal
        configuration.busyMode = .timeout(5)
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA trusted_schema = OFF")
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }

        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: self.databaseURL.path, configuration: configuration)
        } catch {
            throw Self.openError(from: error)
        }
        self.dbPool = pool

        let migrator = Self.makeMigrator()
        let migrationState: MigrationState
        do {
            migrationState = try pool.read { db in
                let foundVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
                if foundVersion > Self.latestSchemaVersion {
                    throw MemoryStoreError.unsupportedSchema(
                        found: foundVersion,
                        supported: Self.latestSchemaVersion
                    )
                }
                if try migrator.hasBeenSuperseded(db) {
                    throw MemoryStoreError.unsupportedSchema(
                        found: max(foundVersion, Self.latestSchemaVersion + 1),
                        supported: Self.latestSchemaVersion
                    )
                }
                return MigrationState(
                    foundVersion: foundVersion,
                    needsMigration: try !migrator.hasCompletedMigrations(db)
                )
            }
        } catch let error as MemoryStoreError {
            try? pool.close()
            throw error
        } catch {
            try? pool.close()
            throw Self.openError(from: error)
        }

        var backupURL: URL?
        if migrationState.needsMigration && existedWithContent {
            do {
                backupURL = try Self.createVerifiedBackup(
                    from: pool,
                    databaseURL: self.databaseURL,
                    fromVersion: migrationState.foundVersion,
                    fileManager: fileManager
                )
            } catch {
                try? pool.close()
                throw MemoryStoreError.backupFailed
            }
        }

        do {
            if migrationState.needsMigration {
                try migrator.migrate(pool)
                if let backupURL {
                    try pool.write { db in
                        try db.execute(
                            sql: "INSERT OR REPLACE INTO store_metadata (key, value) VALUES (?, ?)",
                            arguments: [Self.pendingBackupMetadataKey, backupURL.lastPathComponent]
                        )
                    }
                }
            } else {
                try Self.pruneBackupAfterSuccessfulRelaunch(
                    in: pool,
                    databaseURL: self.databaseURL,
                    fileManager: fileManager
                )
            }
            changeSequence = try Self.initializeChangeSequenceIfNeeded(in: pool)
            try hardenStoreFiles()
        } catch let error as MemoryStoreError {
            try? pool.close()
            throw error
        } catch {
            try? pool.close()
            throw MemoryStoreError.migrationFailed
        }
    }

    deinit {
        observersLock.lock()
        let continuations = Array(observers.values)
        observers.removeAll()
        observersLock.unlock()
        continuations.forEach { $0.finish() }
    }

    func observeChanges() -> AsyncStream<MemoryStoreChange> {
        let identifier = UUID()
        return AsyncStream { continuation in
            observersLock.lock()
            observers[identifier] = continuation
            observersLock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.observersLock.lock()
                self.observers.removeValue(forKey: identifier)
                self.observersLock.unlock()
            }
        }
    }

    func read<T>(_ body: (Database) throws -> T) throws -> T {
        do {
            return try dbPool.read(body)
        } catch let error as MemoryStoreError {
            throw error
        } catch let error as DatabaseError
            where error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB {
            throw MemoryStoreError.corruptedDatabase
        } catch {
            throw MemoryStoreError.readFailed
        }
    }

    func write<T>(_ body: (Database) throws -> T) throws -> T {
        defer { try? hardenStoreFiles() }
        do {
            let committed = try dbPool.write { db -> (value: T, sequence: UInt64) in
                let changesBeforeBody = db.totalChangesCount
                let value = try body(db)
                guard db.totalChangesCount != changesBeforeBody else {
                    return (value, try Self.fetchChangeSequence(db))
                }
                // This update is in the same transaction as the domain write.
                // If either the body or commit fails, neither change survives.
                let sequence = try Self.advanceChangeSequence(db)
                return (value, sequence)
            }
            observersLock.lock()
            changeSequence = max(changeSequence, committed.sequence)
            observersLock.unlock()
            return committed.value
        } catch let error as MemoryStoreError {
            throw error
        } catch let error as DatabaseError
            where error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB {
            throw MemoryStoreError.corruptedDatabase
        } catch {
            throw MemoryStoreError.writeFailed
        }
    }

    func publish(
        kind: MemoryStoreChangeKind,
        documentIDs: Set<UUID> = [],
        memoryIDs: Set<UUID> = []
    ) {
        observersLock.lock()
        let change = MemoryStoreChange(
            sequence: changeSequence,
            kind: kind,
            documentIDs: documentIDs,
            memoryIDs: memoryIDs
        )
        let continuations = Array(observers.values)
        observersLock.unlock()
        continuations.forEach { $0.yield(change) }
    }

    func currentSequence() throws -> UInt64 {
        try read { db in
            try Self.fetchChangeSequence(db)
        }
    }

    static let changeSequenceMetadataKey = "change_sequence"

    static func fetchChangeSequence(_ db: Database) throws -> UInt64 {
        guard let encoded = try String.fetchOne(
            db,
            sql: "SELECT value FROM store_metadata WHERE key = ?",
            arguments: [changeSequenceMetadataKey]
        ), let sequence = UInt64(encoded) else {
            throw MemoryStoreError.invalidRecord("The durable store change sequence is invalid.")
        }
        return sequence
    }

    static func advanceChangeSequence(_ db: Database) throws -> UInt64 {
        let current = try fetchChangeSequence(db)
        guard current < UInt64.max else {
            throw MemoryStoreError.invalidRecord("The durable store change sequence is exhausted.")
        }
        let next = current + 1
        try db.execute(
            sql: "UPDATE store_metadata SET value = ? WHERE key = ?",
            arguments: [String(next), changeSequenceMetadataKey]
        )
        guard db.changesCount == 1 else {
            throw MemoryStoreError.invalidRecord("The durable store change sequence could not be advanced.")
        }
        return next
    }

    func hardenStoreFiles() throws {
        let directory = databaseURL.deletingLastPathComponent()
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let names = try fileManager.contentsOfDirectory(atPath: directory.path)
        let databaseName = databaseURL.lastPathComponent
        for name in names where Self.isPrivateStoreFile(name, databaseName: databaseName) {
            let path = directory.appendingPathComponent(name).path
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }
}

private extension SQLiteMemoryStore {
    struct MigrationState {
        var foundVersion: Int
        var needsMigration: Bool
    }

    static let migrationIdentifier = "ReadingMemory.v1"
    static let pendingBackupMetadataKey = "pending_backup_prune"
    static let backupPrefix = ".ReadingMemory.migration-backup-"

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(migrationIdentifier, foreignKeyChecks: .immediate) { db in
            try db.execute(sql: schemaV1SQL)
        }
        return migrator
    }

    static let schemaV1SQL = """
        CREATE TABLE store_metadata (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );

        INSERT INTO store_metadata (key, value) VALUES ('change_sequence', '0');

        CREATE TABLE documents (
            id TEXT PRIMARY KEY NOT NULL,
            display_name TEXT NOT NULL,
            bookmark_data BLOB,
            volume_identifier BLOB,
            file_resource_identifier BLOB,
            last_confirmed_content_hash TEXT,
            detected_text_encoding TEXT,
            had_byte_order_mark INTEGER CHECK (had_byte_order_mark IN (0, 1)),
            availability TEXT NOT NULL CHECK (availability IN ('available', 'unavailable')),
            is_favourite INTEGER NOT NULL CHECK (is_favourite IN (0, 1)),
            record_version INTEGER NOT NULL CHECK (record_version >= 1),
            created_at REAL NOT NULL,
            last_opened_at REAL NOT NULL,
            last_seen_at REAL NOT NULL
        );

        CREATE INDEX documents_resource_identity
            ON documents (volume_identifier, file_resource_identifier);
        CREATE INDEX documents_last_opened ON documents (last_opened_at DESC);

        CREATE TABLE document_locations (
            id TEXT PRIMARY KEY NOT NULL,
            document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            file_path TEXT NOT NULL,
            is_current INTEGER NOT NULL CHECK (is_current IN (0, 1)),
            first_seen_at REAL NOT NULL,
            last_seen_at REAL NOT NULL,
            UNIQUE (document_id, file_path)
        );

        CREATE UNIQUE INDEX document_locations_one_current
            ON document_locations (document_id) WHERE is_current = 1;
        CREATE INDEX document_locations_path ON document_locations (file_path);

        CREATE TABLE reading_state (
            document_id TEXT PRIMARY KEY NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            semantic_block_fingerprint TEXT,
            canonical_utf8_offset INTEGER,
            fallback_scroll_fraction REAL NOT NULL
                CHECK (fallback_scroll_fraction >= 0 AND fallback_scroll_fraction <= 1),
            last_semantic_heading TEXT,
            last_read_at REAL NOT NULL,
            record_version INTEGER NOT NULL CHECK (record_version >= 1),
            CHECK (
                (semantic_block_fingerprint IS NULL AND canonical_utf8_offset IS NULL)
                OR (semantic_block_fingerprint IS NOT NULL AND canonical_utf8_offset >= 0)
            )
        );

        CREATE INDEX reading_state_last_read ON reading_state (last_read_at DESC);

        CREATE TABLE legacy_reading_imports (
            legacy_key_hash TEXT PRIMARY KEY NOT NULL,
            document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            imported_at REAL NOT NULL
        );

        CREATE TABLE memories (
            id TEXT PRIMARY KEY NOT NULL,
            document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            kind TEXT NOT NULL CHECK (kind IN ('passage', 'headingBookmark')),
            original_visible_quote TEXT,
            canonical_match_quote TEXT,
            note_text TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            record_version INTEGER NOT NULL CHECK (record_version >= 1),
            original_anchor_id TEXT REFERENCES confirmed_anchors(id)
                ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
            current_anchor_id TEXT REFERENCES confirmed_anchors(id)
                ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
            CHECK (kind != 'passage' OR original_visible_quote IS NOT NULL),
            CHECK (kind != 'passage' OR canonical_match_quote IS NOT NULL)
        );

        CREATE INDEX memories_document_created ON memories (document_id, created_at DESC);
        CREATE INDEX memories_updated ON memories (updated_at DESC);

        CREATE TABLE confirmed_anchors (
            id TEXT PRIMARY KEY NOT NULL,
            memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            supersedes_anchor_id TEXT REFERENCES confirmed_anchors(id)
                ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
            confirmation TEXT NOT NULL CHECK (confirmation IN ('initialCapture', 'manualReattach')),
            created_at REAL NOT NULL,
            selector_version INTEGER NOT NULL CHECK (selector_version >= 1),
            projection_version INTEGER NOT NULL CHECK (projection_version >= 1),
            source_revision_hash TEXT NOT NULL,
            resolver_policy_version INTEGER NOT NULL CHECK (resolver_policy_version >= 1),
            exact_quote TEXT NOT NULL,
            prefix_text TEXT NOT NULL,
            suffix_text TEXT NOT NULL,
            canonical_start INTEGER NOT NULL CHECK (canonical_start >= 0),
            canonical_end INTEGER NOT NULL CHECK (canonical_end >= canonical_start),
            block_local_start INTEGER NOT NULL CHECK (block_local_start >= 0),
            block_local_end INTEGER NOT NULL CHECK (block_local_end > block_local_start),
            block_kind TEXT NOT NULL,
            block_fingerprint TEXT NOT NULL,
            heading_path_json BLOB NOT NULL,
            block_ordinal INTEGER NOT NULL CHECK (block_ordinal >= 0),
            block_fingerprint_occurrence_count INTEGER NOT NULL
                CHECK (block_fingerprint_occurrence_count >= 1),
            source_utf8_start INTEGER,
            source_utf8_end INTEGER,
            CHECK (
                (source_utf8_start IS NULL AND source_utf8_end IS NULL)
                OR (source_utf8_start >= 0 AND source_utf8_end >= source_utf8_start)
            )
        );

        CREATE INDEX confirmed_anchors_memory_created
            ON confirmed_anchors (memory_id, created_at, id);

        CREATE TABLE memory_resolutions (
            memory_id TEXT PRIMARY KEY NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            anchor_id TEXT NOT NULL REFERENCES confirmed_anchors(id) ON DELETE CASCADE,
            state TEXT NOT NULL CHECK (state IN ('resolved', 'ambiguous', 'needsReview', 'orphaned')),
            checked_revision_hash TEXT NOT NULL,
            resolver_policy_version INTEGER NOT NULL CHECK (resolver_policy_version >= 1),
            resolved_selector_json BLOB,
            evidence_json BLOB NOT NULL,
            last_checked_at REAL NOT NULL,
            record_version INTEGER NOT NULL CHECK (record_version >= 1)
        );

        CREATE INDEX memory_resolutions_state ON memory_resolutions (state, last_checked_at DESC);

        CREATE TABLE memory_history (
            id TEXT PRIMARY KEY NOT NULL,
            memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            kind TEXT NOT NULL CHECK (
                kind IN ('created', 'noteEdited', 'resolutionChanged', 'reattached', 'restored')
            ),
            snapshot_json BLOB NOT NULL,
            created_at REAL NOT NULL
        );

        CREATE INDEX memory_history_memory_created
            ON memory_history (memory_id, created_at, id);

        CREATE VIRTUAL TABLE memories_fts USING fts5(
            memory_id UNINDEXED,
            document_id UNINDEXED,
            passage_text,
            note_text,
            heading_text,
            tokenize = 'unicode61 remove_diacritics 2'
        );

        CREATE VIRTUAL TABLE documents_fts USING fts5(
            document_id UNINDEXED,
            display_name,
            parent_folder,
            last_heading,
            tokenize = 'unicode61 remove_diacritics 2'
        );

        PRAGMA user_version = 1;
        """

    static func fileExistsWithContent(at url: URL, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }

    static func initializeChangeSequenceIfNeeded(in pool: DatabasePool) throws -> UInt64 {
        try pool.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO store_metadata (key, value) VALUES (?, '0')",
                arguments: [changeSequenceMetadataKey]
            )
            return try fetchChangeSequence(db)
        }
    }

    static func preflightExistingDatabase(at url: URL) throws {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 16) ?? Data()
            guard header == Data("SQLite format 3\0".utf8) else {
                throw MemoryStoreError.corruptedDatabase
            }

            var configuration = Configuration()
            configuration.readonly = true
            configuration.foreignKeysEnabled = true
            let queue = try DatabaseQueue(path: url.path, configuration: configuration)
            defer { try? queue.close() }
            let results = try queue.read { db in
                try String.fetchAll(db, sql: "PRAGMA quick_check")
            }
            guard results == ["ok"] else {
                throw MemoryStoreError.corruptedDatabase
            }
        } catch let error as MemoryStoreError {
            throw error
        } catch let error as DatabaseError
            where error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB {
            throw MemoryStoreError.corruptedDatabase
        } catch {
            throw MemoryStoreError.openFailed
        }
    }

    static func openError(from error: Error) -> MemoryStoreError {
        if let error = error as? MemoryStoreError {
            return error
        }
        if let error = error as? DatabaseError,
           error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB {
            return .corruptedDatabase
        }
        return .openFailed
    }

    static func createVerifiedBackup(
        from source: DatabasePool,
        databaseURL: URL,
        fromVersion: Int,
        fileManager: FileManager
    ) throws -> URL {
        let directory = databaseURL.deletingLastPathComponent()
        let name = "\(backupPrefix)v\(fromVersion)-to-v\(latestSchemaVersion)-\(UUID().uuidString.lowercased()).sqlite3"
        let backupURL = directory.appendingPathComponent(name)

        let destination = try DatabaseQueue(path: backupURL.path)
        do {
            try source.backup(to: destination)
            let result = try destination.read { db in
                try String.fetchAll(db, sql: "PRAGMA quick_check")
            }
            guard result == ["ok"] else {
                throw MemoryStoreError.backupFailed
            }
            try destination.writeWithoutTransaction { db in
                _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE")
            }
            try destination.close()
            for suffix in ["-wal", "-shm", "-journal"] {
                let sidecar = URL(fileURLWithPath: backupURL.path + suffix)
                if fileManager.fileExists(atPath: sidecar.path) {
                    try fileManager.removeItem(at: sidecar)
                }
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            try synchronizeFile(at: backupURL)
            try synchronizeDirectory(at: directory)
            return backupURL
        } catch {
            try? destination.close()
            try? fileManager.removeItem(at: backupURL)
            throw error
        }
    }

    static func pruneBackupAfterSuccessfulRelaunch(
        in pool: DatabasePool,
        databaseURL: URL,
        fileManager: FileManager
    ) throws {
        let pendingName: String? = try pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM store_metadata WHERE key = ?",
                arguments: [pendingBackupMetadataKey]
            )
        }
        guard let pendingName else { return }

        let directory = databaseURL.deletingLastPathComponent()
        let names = try fileManager.contentsOfDirectory(atPath: directory.path)
        for name in names where name.hasPrefix(backupPrefix) {
            try fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        try synchronizeDirectory(at: directory)
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM store_metadata WHERE key = ? AND value = ?",
                arguments: [pendingBackupMetadataKey, pendingName]
            )
        }
    }

    static func isPrivateStoreFile(_ name: String, databaseName: String) -> Bool {
        name == databaseName
            || name == "\(databaseName)-wal"
            || name == "\(databaseName)-shm"
            || name == "\(databaseName)-journal"
            || name.hasPrefix(backupPrefix)
            || name.hasPrefix(".\(databaseName).tmp-")
    }

    static func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    static func synchronizeDirectory(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw MemoryStoreError.backupFailed }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw MemoryStoreError.backupFailed }
    }
}

extension SQLiteMemoryStore {
    static func normalizedID(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    static func decodedID(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else {
            throw MemoryStoreError.corruptedDatabase
        }
        return id
    }

    static func timestamp(_ date: Date) -> Double {
        date.timeIntervalSince1970
    }

    static func date(_ timestamp: Double) -> Date {
        Date(timeIntervalSince1970: timestamp)
    }

    static func encodedJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    static func decodedJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw MemoryStoreError.corruptedDatabase
        }
    }

    static func validateDocument(_ document: NewDocument) throws {
        guard !document.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryStoreError.invalidRecord("A document needs a display name.")
        }
    }

    static func validateReadingState(_ update: ReadingStateUpdate) throws {
        guard update.fallbackScrollFraction.isFinite,
              (0...1).contains(update.fallbackScrollFraction) else {
            throw MemoryStoreError.invalidRecord("Reading progress must be between zero and one.")
        }
        if let position = update.semanticPosition {
            guard !position.blockFingerprint.isEmpty, position.canonicalUTF8Offset >= 0 else {
                throw MemoryStoreError.invalidRecord("The semantic reading position is invalid.")
            }
        }
    }

    static func validateAnchor(_ anchor: NewConfirmedAnchor) throws {
        guard anchor.selectorVersion >= 1,
              anchor.projectionVersion >= 1,
              anchor.resolverPolicyVersion >= 1,
              !anchor.sourceRevisionHash.isEmpty,
              !anchor.exactQuote.isEmpty,
              anchor.canonicalTextPosition.isValid,
              anchor.canonicalTextPosition.upperBound > anchor.canonicalTextPosition.lowerBound,
              anchor.canonicalUTF8RangeInBlock.isValid,
              anchor.canonicalUTF8RangeInBlock.upperBound
                > anchor.canonicalUTF8RangeInBlock.lowerBound,
              !anchor.blockKind.isEmpty,
              !anchor.blockFingerprint.isEmpty,
              anchor.blockOrdinal >= 0,
              anchor.blockFingerprintOccurrenceCountInSection >= 1,
              anchor.headingPath.allSatisfy({
                  (1...6).contains($0.level) && !$0.title.isEmpty
              }),
              anchor.sourceUTF8Span?.isValid != false else {
            throw MemoryStoreError.invalidRecord("The confirmed anchor is incomplete or invalid.")
        }
    }

    static func validateResolution(_ resolution: ResolutionDraft) throws {
        guard resolution.resolverPolicyVersion >= 1,
              !resolution.checkedRevisionHash.isEmpty else {
            throw MemoryStoreError.invalidRecord("The resolution is incomplete.")
        }
        switch resolution.state {
        case .resolved:
            guard let selector = resolution.resolvedSelector,
                  !selector.sourceRevisionHash.isEmpty,
                  selector.projectionVersion >= 1,
                  !selector.blockID.isEmpty,
                  selector.canonicalUTF8RangeInBlock.isValid,
                  selector.canonicalUTF8RangeInBlock.upperBound
                    > selector.canonicalUTF8RangeInBlock.lowerBound,
                  selector.canonicalTextPosition.isValid,
                  selector.canonicalTextPosition.upperBound > selector.canonicalTextPosition.lowerBound,
                  !selector.blockKind.isEmpty,
                  !selector.blockFingerprint.isEmpty,
                  selector.blockOrdinal >= 0,
                  selector.headingPath.allSatisfy({
                      (1...6).contains($0.level) && !$0.title.isEmpty
                  }),
                  selector.sourceUTF8Span?.isValid != false else {
                throw MemoryStoreError.invalidRecord("A resolved memory needs a resolved selector.")
            }
            guard selector.sourceRevisionHash == resolution.checkedRevisionHash,
                  selector.canonicalTextPosition.upperBound
                    - selector.canonicalTextPosition.lowerBound
                    == selector.canonicalUTF8RangeInBlock.upperBound
                    - selector.canonicalUTF8RangeInBlock.lowerBound else {
                throw MemoryStoreError.invalidRecord("The resolved selector does not match its checked revision.")
            }
        case .ambiguous, .needsReview, .orphaned:
            guard resolution.resolvedSelector == nil else {
                throw MemoryStoreError.invalidRecord("An unresolved memory cannot claim a resolved location.")
            }
        }
    }
}
