import Foundation
import GRDB
import XCTest
@testable import MarkdownReader

final class MemoryStoreTests: XCTestCase {
    func testFreshStoreCreatesSchemaWALAndPrivatePermissions() throws {
        let fixture = try makeStore()
        let store = fixture.store

        let pragmas = try store.dbPool.read { db in
            (
                try Int.fetchOne(db, sql: "PRAGMA user_version"),
                try Int.fetchOne(db, sql: "PRAGMA foreign_keys"),
                try String.fetchOne(db, sql: "PRAGMA journal_mode"),
                try String.fetchAll(db, sql: "PRAGMA quick_check")
            )
        }
        XCTAssertEqual(pragmas.0, SQLiteMemoryStore.latestSchemaVersion)
        XCTAssertEqual(pragmas.1, 1)
        XCTAssertEqual(pragmas.2?.lowercased(), "wal")
        XCTAssertEqual(pragmas.3, ["ok"])

        let tableNames = try store.dbPool.read { db in
            try String.fetchSet(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')"
            )
        }
        XCTAssertTrue(tableNames.isSuperset(of: [
            "documents", "document_locations", "reading_state", "memories",
            "confirmed_anchors", "memory_resolutions", "memory_history",
            "memories_fts", "documents_fts", "legacy_reading_imports",
        ]))

        XCTAssertEqual(try permissions(at: fixture.directory), 0o700)
        XCTAssertEqual(try permissions(at: fixture.databaseURL), 0o600)
        let sidecarURLs = try FileManager.default.contentsOfDirectory(
            at: fixture.directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(fixture.databaseURL.lastPathComponent) }
        for url in sidecarURLs {
            XCTAssertEqual(try permissions(at: url), 0o600)
        }
    }

    func testExistingSchemaIsBackedUpAndPrunedOnlyAfterNextSuccessfulOpen() throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("ReadingMemory.sqlite3")
        do {
            let queue = try DatabaseQueue(path: databaseURL.path)
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE predecessor (value TEXT NOT NULL)")
                try db.execute(sql: "INSERT INTO predecessor VALUES ('kept')")
                try db.execute(sql: "PRAGMA user_version = 0")
            }
            try queue.close()
        }

        var firstStore: SQLiteMemoryStore? = try SQLiteMemoryStore(databaseURL: databaseURL)
        XCTAssertNotNil(firstStore)
        var backups = try migrationBackups(in: directory)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try permissions(at: try XCTUnwrap(backups.first)), 0o600)
        let backupCheck = try DatabaseQueue(path: try XCTUnwrap(backups.first).path)
        XCTAssertEqual(
            try backupCheck.read { db in try String.fetchAll(db, sql: "PRAGMA quick_check") },
            ["ok"]
        )
        try backupCheck.close()

        firstStore = nil
        let secondStore = try SQLiteMemoryStore(databaseURL: databaseURL)
        XCTAssertEqual(secondStore.schemaVersion, 1)
        backups = try migrationBackups(in: directory)
        XCTAssertTrue(backups.isEmpty)
    }

    func testCorruptOpenDoesNotRewritePrivateBytes() throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("ReadingMemory.sqlite3")
        let original = Data("private words that are not sqlite".utf8)
        try original.write(to: databaseURL)

        XCTAssertThrowsError(try SQLiteMemoryStore(databaseURL: databaseURL)) { error in
            XCTAssertEqual(error as? MemoryStoreError, .corruptedDatabase)
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), original)
    }

    func testDocumentsLocationsReadingStateFavouriteAndOptimisticVersions() throws {
        let store = try makeStore().store
        let createdAt = date(1_000)
        let firstURL = URL(fileURLWithPath: "/private/notes/first/Readme.md")
        let document = try store.createDocument(
            NewDocument(
                displayName: "Readme.md",
                fileIdentity: FileIdentity(
                    volumeIdentifier: Data([1, 2]),
                    fileResourceIdentifier: Data([3, 4])
                ),
                lastConfirmedContentHash: "revision-one",
                detectedTextEncoding: "utf-8",
                hadByteOrderMark: false,
                createdAt: createdAt
            ),
            location: NewDocumentLocation(url: firstURL, observedAt: createdAt)
        )
        XCTAssertEqual(document.recordVersion, 1)
        XCTAssertEqual(
            try store.documents(matching: document.fileIdentity).map(\.id),
            [document.id]
        )

        let moved = try store.recordLocation(
            NewDocumentLocation(
                url: URL(fileURLWithPath: "/private/notes/second/Readme.md"),
                observedAt: date(1_100)
            ),
            for: document.id,
            expectedRecordVersion: 1
        )
        XCTAssertEqual(moved.recordVersion, 2)
        let locations = try store.documentLocations(documentID: document.id)
        XCTAssertEqual(locations.count, 2)
        XCTAssertEqual(locations.filter(\.isCurrent).count, 1)
        XCTAssertTrue(locations.contains { $0.url == firstURL && !$0.isCurrent })

        XCTAssertThrowsError(
            try store.recordLocation(
                NewDocumentLocation(url: firstURL),
                for: document.id,
                expectedRecordVersion: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? MemoryStoreError,
                .versionConflict(entity: .document, expected: 1, actual: 2)
            )
        }

        let favourite = try store.setFavourite(
            documentID: document.id,
            isFavourite: true,
            expectedRecordVersion: 2
        )
        XCTAssertTrue(favourite.document.isFavourite)
        let unfavourited = try store.undoFavourite(favourite.undo)
        XCTAssertFalse(unfavourited.isFavourite)

        let state = try store.updateReadingState(
            documentID: document.id,
            update: ReadingStateUpdate(
                semanticPosition: SemanticReadingPosition(
                    blockFingerprint: "block-7",
                    canonicalUTF8Offset: 42
                ),
                fallbackScrollFraction: 0.375,
                lastSemanticHeading: "Identity",
                lastReadAt: date(1_200)
            ),
            expectedRecordVersion: nil
        )
        XCTAssertEqual(state.recordVersion, 1)
        XCTAssertEqual(state.semanticPosition?.canonicalUTF8Offset, 42)

        XCTAssertThrowsError(
            try store.updateReadingState(
                documentID: document.id,
                update: ReadingStateUpdate(semanticPosition: nil, fallbackScrollFraction: 0.5),
                expectedRecordVersion: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? MemoryStoreError,
                .versionConflict(entity: .readingState, expected: 0, actual: 1)
            )
        }
    }

    func testLegacyReadingImportIsLazyAndConsumesOnlyOneHashedKey() throws {
        let store = try makeStore().store
        let document = try createDocument(in: store)

        let imported = try store.importLegacyReadingStateIfNeeded(
            documentID: document.id,
            legacyKeyHash: "sha256-key-one",
            fallbackScrollFraction: 0.7,
            importedAt: date(1_500)
        )
        XCTAssertEqual(imported?.fallbackScrollFraction, 0.7)
        XCTAssertNil(
            try store.importLegacyReadingStateIfNeeded(
                documentID: document.id,
                legacyKeyHash: "sha256-key-one",
                fallbackScrollFraction: 0.1,
                importedAt: date(1_600)
            )
        )
        let secondMarker = try store.importLegacyReadingStateIfNeeded(
            documentID: document.id,
            legacyKeyHash: "sha256-key-two",
            fallbackScrollFraction: 0.1,
            importedAt: date(1_700)
        )
        XCTAssertEqual(secondMarker?.fallbackScrollFraction, 0.7)
        let consumedCount = try store.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM legacy_reading_imports")
        }
        XCTAssertEqual(consumedCount, 2)
    }

    func testCaptureSearchNoteDeleteRestoreAndDeterministicSnapshot() throws {
        let store = try makeStore().store
        let document = try createDocument(in: store)
        let request = makeCapture(
            document: document,
            quote: "A retained passage about careful memory",
            note: "first private note",
            range: CanonicalTextRange(lowerBound: 20, upperBound: 60)
        )
        let created = try store.createMemory(request)
        XCTAssertEqual(created.storedMemory.anchors.count, 1)
        XCTAssertEqual(created.storedMemory.history.map(\.kind), [.created])
        XCTAssertEqual(
            created.storedMemory.anchors.first?.canonicalUTF8RangeInBlock,
            request.anchor.canonicalUTF8RangeInBlock
        )
        XCTAssertEqual(
            created.storedMemory.anchors.first?.blockFingerprintOccurrenceCountInSection,
            1
        )
        XCTAssertEqual(
            created.storedMemory.anchors.first?.headingPath,
            [StoredHeadingBreadcrumb(level: 1, title: "Trust")]
        )
        XCTAssertEqual(
            created.storedMemory.resolution.resolvedSelector?.blockID,
            "block-id-block-one"
        )

        let passageResults = try store.searchMemories(
            MemorySearchQuery(text: "retained passage", scope: .passages, facet: .highlights)
        )
        XCTAssertEqual(passageResults.map(\.memory.id), [request.id])
        XCTAssertEqual(passageResults.first?.totalCount, 1)
        XCTAssertEqual(
            try store.searchMemories(
                MemorySearchQuery(text: "private note", scope: .notes, facet: .notes)
            ).count,
            1
        )

        let edited = try store.updateNote(
            memoryID: request.id,
            noteText: "replacement observation",
            expectedRecordVersion: 1,
            at: date(2_100)
        )
        XCTAssertEqual(edited.memory.recordVersion, 2)
        XCTAssertTrue(
            try store.searchMemories(
                MemorySearchQuery(text: "private note", scope: .notes, facet: .notes)
            ).isEmpty
        )
        XCTAssertEqual(
            try store.searchMemories(
                MemorySearchQuery(text: "replacement observation", scope: .notes, facet: .notes)
            ).map(\.memory.id),
            [request.id]
        )

        XCTAssertThrowsError(
            try store.updateNote(
                memoryID: request.id,
                noteText: "stale draft",
                expectedRecordVersion: 1,
                at: date(2_200)
            )
        ) { error in
            XCTAssertEqual(
                error as? MemoryStoreError,
                .versionConflict(entity: .memory, expected: 1, actual: 2)
            )
        }

        let snapshotA = try store.snapshot().deterministicJSONData()
        let snapshotB = try store.snapshot().deterministicJSONData()
        XCTAssertEqual(snapshotA, snapshotB)

        let deleted = try store.deleteMemory(memoryID: request.id, expectedRecordVersion: 2)
        let physicalCounts = try store.dbPool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memories WHERE id = ?", arguments: [request.id.uuidString.lowercased()]),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM confirmed_anchors WHERE memory_id = ?", arguments: [request.id.uuidString.lowercased()]),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_resolutions WHERE memory_id = ?", arguments: [request.id.uuidString.lowercased()]),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_history WHERE memory_id = ?", arguments: [request.id.uuidString.lowercased()]),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memories_fts WHERE memory_id = ?", arguments: [request.id.uuidString.lowercased()])
            )
        }
        XCTAssertEqual([physicalCounts.0, physicalCounts.1, physicalCounts.2, physicalCounts.3, physicalCounts.4], [0, 0, 0, 0, 0])

        let restored = try store.restoreDeletedMemory(deleted, at: date(2_300))
        XCTAssertEqual(restored.memory.id, request.id)
        XCTAssertGreaterThan(restored.memory.recordVersion, deleted.storedMemory.memory.recordVersion)
        XCTAssertEqual(restored.history.last?.kind, .restored)
    }

    func testCaptureRejectsStaleSourceAndOverlappingPassage() throws {
        let store = try makeStore().store
        let document = try createDocument(in: store)
        let first = makeCapture(
            document: document,
            quote: "first exact passage",
            range: CanonicalTextRange(lowerBound: 100, upperBound: 120)
        )
        _ = try store.createMemory(first)

        let overlapping = makeCapture(
            document: document,
            quote: "second exact passage",
            range: CanonicalTextRange(lowerBound: 119, upperBound: 140)
        )
        XCTAssertThrowsError(try store.createMemory(overlapping)) { error in
            XCTAssertEqual(error as? MemoryStoreError, .overlappingMemory(first.id))
        }

        var stale = makeCapture(
            document: document,
            quote: "stale exact passage",
            range: CanonicalTextRange(lowerBound: 200, upperBound: 220)
        )
        stale.anchor.sourceRevisionHash = "older-revision"
        stale.resolution.checkedRevisionHash = "older-revision"
        stale.resolution.resolvedSelector?.sourceRevisionHash = "older-revision"
        XCTAssertThrowsError(try store.createMemory(stale)) { error in
            XCTAssertEqual(error as? MemoryStoreError, .staleSourceRevision)
        }
    }

    func testDeleteUndoRejectsOverlapCreatedAfterDeletion() throws {
        let store = try makeStore().store
        let document = try createDocument(in: store)
        let deletedRequest = makeCapture(
            document: document,
            quote: "original remembered passage",
            range: CanonicalTextRange(lowerBound: 300, upperBound: 328)
        )
        _ = try store.createMemory(deletedRequest)
        let payload = try store.deleteMemory(
            memoryID: deletedRequest.id,
            expectedRecordVersion: 1
        )

        let replacement = makeCapture(
            document: document,
            quote: "new memory in that location",
            range: CanonicalTextRange(lowerBound: 300, upperBound: 328)
        )
        _ = try store.createMemory(replacement)

        XCTAssertThrowsError(try store.restoreDeletedMemory(payload, at: date(2_500))) { error in
            XCTAssertEqual(error as? MemoryStoreError, .overlappingMemory(replacement.id))
        }
        XCTAssertNil(try store.memory(id: deletedRequest.id))
    }

    func testRestoreDeletedAsNewPreservesRemappedLineageAfterExactUndoVersionConflict() throws {
        let store = try makeStore().store
        let document = try createDocument(in: store)
        let request = makeCapture(
            document: document,
            quote: "restore this remembered passage",
            note: "keep this private note",
            range: CanonicalTextRange(lowerBound: 10, upperBound: 42)
        )
        let created = try store.createMemory(request)
        let reattachedSelector = selector(
            range: CanonicalTextRange(lowerBound: 80, upperBound: 112),
            fingerprint: "block-two"
        )
        let reattachedAnchor = NewConfirmedAnchor(
            supersedesAnchorID: request.anchor.id,
            confirmation: .manualReattach,
            createdAt: date(2_100),
            selectorVersion: 1,
            projectionVersion: 1,
            sourceRevisionHash: "revision-one",
            resolverPolicyVersion: 1,
            exactQuote: request.anchor.exactQuote,
            prefix: "new prefix",
            suffix: "new suffix",
            canonicalTextPosition: reattachedSelector.canonicalTextPosition,
            canonicalUTF8RangeInBlock: reattachedSelector.canonicalUTF8RangeInBlock,
            blockKind: reattachedSelector.blockKind,
            blockFingerprint: reattachedSelector.blockFingerprint,
            headingPath: reattachedSelector.headingPath,
            blockOrdinal: reattachedSelector.blockOrdinal,
            blockFingerprintOccurrenceCountInSection: 1
        )
        let reattached = try store.reattachMemory(
            memoryID: request.id,
            anchor: reattachedAnchor,
            resolution: ResolutionDraft(
                state: .resolved,
                checkedRevisionHash: "revision-one",
                resolverPolicyVersion: 1,
                resolvedSelector: reattachedSelector,
                evidence: [.init(kind: .manualConfirmation)],
                lastCheckedAt: date(2_100)
            ),
            expectedMemoryRecordVersion: created.storedMemory.memory.recordVersion,
            expectedResolutionRecordVersion: created.storedMemory.resolution.recordVersion,
            expectedDocumentRecordVersion: document.recordVersion
        )
        let deleted = try store.deleteMemory(
            memoryID: request.id,
            expectedRecordVersion: reattached.storedMemory.memory.recordVersion
        )
        let favourite = try store.setFavourite(
            documentID: document.id,
            isFavourite: true,
            expectedRecordVersion: document.recordVersion
        )

        XCTAssertThrowsError(try store.restoreDeletedMemory(deleted, at: date(2_200))) { error in
            XCTAssertEqual(
                error as? MemoryStoreError,
                .versionConflict(
                    entity: .document,
                    expected: document.recordVersion,
                    actual: favourite.document.recordVersion
                )
            )
        }

        let restoreRequest = RestoreDeletedMemoryAsNewRequest(
            deleted: deleted,
            expectedDocumentRecordVersion: favourite.document.recordVersion
        )
        XCTAssertNoThrow(try store.validateRestoreDeletedMemoryAsNew(restoreRequest))
        let restored = try store.restoreDeletedMemoryAsNew(restoreRequest, at: date(2_300))

        XCTAssertNotEqual(restored.memory.id, deleted.storedMemory.memory.id)
        XCTAssertEqual(restored.memory.documentID, document.id)
        XCTAssertEqual(restored.memory.noteText, "keep this private note")
        XCTAssertEqual(restored.memory.originalVisibleQuote, request.originalVisibleQuote)
        XCTAssertEqual(restored.memory.recordVersion, 1)
        XCTAssertNil(try store.memory(id: deleted.storedMemory.memory.id))

        let oldAnchorIDs = Set(deleted.storedMemory.anchors.map(\.id))
        let newAnchorIDs = Set(restored.anchors.map(\.id))
        XCTAssertEqual(newAnchorIDs.count, oldAnchorIDs.count)
        XCTAssertTrue(newAnchorIDs.isDisjoint(with: oldAnchorIDs))
        let initial = try XCTUnwrap(restored.anchors.first { $0.confirmation == .initialCapture })
        let manual = try XCTUnwrap(restored.anchors.first { $0.confirmation == .manualReattach })
        XCTAssertEqual(manual.supersedesAnchorID, initial.id)
        XCTAssertEqual(restored.memory.originalAnchorID, initial.id)
        XCTAssertEqual(restored.memory.currentAnchorID, manual.id)
        XCTAssertEqual(restored.resolution.anchorID, manual.id)

        XCTAssertEqual(restored.history.count, deleted.storedMemory.history.count + 1)
        XCTAssertEqual(restored.history.last?.kind, .restored)
        XCTAssertTrue(
            Set(restored.history.map(\.id)).isDisjoint(
                with: Set(deleted.storedMemory.history.map(\.id))
            )
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        for history in restored.history.dropLast() {
            let snapshot = try decoder.decode(MemoryHistorySnapshot.self, from: history.snapshot)
            XCTAssertEqual(snapshot.memory.id, restored.memory.id)
            XCTAssertEqual(snapshot.resolution.memoryID, restored.memory.id)
            XCTAssertTrue(snapshot.anchors.allSatisfy { $0.memoryID == restored.memory.id })
            XCTAssertTrue(newAnchorIDs.contains(snapshot.resolution.anchorID))
        }
    }

    func testRestoreDeletedAsNewStillRejectsOverlapAndStaleRevision() throws {
        let store = try makeStore().store
        var document = try createDocument(in: store)
        let deletedRequest = makeCapture(
            document: document,
            quote: "deleted remembered passage",
            range: CanonicalTextRange(lowerBound: 300, upperBound: 328)
        )
        _ = try store.createMemory(deletedRequest)
        let deleted = try store.deleteMemory(memoryID: deletedRequest.id, expectedRecordVersion: 1)

        let replacement = makeCapture(
            document: document,
            quote: "replacement remembered passage",
            range: CanonicalTextRange(lowerBound: 300, upperBound: 328)
        )
        _ = try store.createMemory(replacement)
        let request = RestoreDeletedMemoryAsNewRequest(
            deleted: deleted,
            expectedDocumentRecordVersion: document.recordVersion
        )
        XCTAssertThrowsError(try store.validateRestoreDeletedMemoryAsNew(request)) { error in
            XCTAssertEqual(error as? MemoryStoreError, .overlappingMemory(replacement.id))
        }
        XCTAssertNil(try store.memory(id: deletedRequest.id))

        _ = try store.deleteMemory(memoryID: replacement.id, expectedRecordVersion: 1)
        document = try store.updateDocumentMetadata(
            documentID: document.id,
            displayName: document.displayName,
            bookmarkData: document.bookmarkData,
            fileIdentity: document.fileIdentity,
            lastConfirmedContentHash: "revision-two",
            detectedTextEncoding: document.detectedTextEncoding,
            hadByteOrderMark: document.hadByteOrderMark,
            availability: document.availability,
            openedAt: date(2_400),
            expectedRecordVersion: document.recordVersion
        )
        let staleRequest = RestoreDeletedMemoryAsNewRequest(
            deleted: deleted,
            expectedDocumentRecordVersion: document.recordVersion
        )
        XCTAssertThrowsError(try store.restoreDeletedMemoryAsNew(staleRequest, at: date(2_500))) { error in
            XCTAssertEqual(error as? MemoryStoreError, .staleSourceRevision)
        }
        XCTAssertNil(try store.memory(id: deletedRequest.id))
    }

    func testManualReattachmentCreatesImmutableGenerationAndUndoRestoresPriorCurrentAnchor() throws {
        let store = try makeStore().store
        let document = try createDocument(in: store)
        let request = makeCapture(
            document: document,
            quote: "reattach this passage",
            range: CanonicalTextRange(lowerBound: 10, upperBound: 31)
        )
        let created = try store.createMemory(request)

        let newSelector = selector(
            range: CanonicalTextRange(lowerBound: 80, upperBound: 101),
            fingerprint: "block-two"
        )
        let newAnchor = NewConfirmedAnchor(
            supersedesAnchorID: request.anchor.id,
            confirmation: .manualReattach,
            createdAt: date(3_000),
            selectorVersion: 1,
            projectionVersion: 1,
            sourceRevisionHash: "revision-one",
            resolverPolicyVersion: 1,
            exactQuote: request.anchor.exactQuote,
            prefix: "new prefix",
            suffix: "new suffix",
            canonicalTextPosition: newSelector.canonicalTextPosition,
            canonicalUTF8RangeInBlock: newSelector.canonicalUTF8RangeInBlock,
            blockKind: newSelector.blockKind,
            blockFingerprint: newSelector.blockFingerprint,
            headingPath: newSelector.headingPath,
            blockOrdinal: newSelector.blockOrdinal,
            blockFingerprintOccurrenceCountInSection: 1
        )
        let reattached = try store.reattachMemory(
            memoryID: request.id,
            anchor: newAnchor,
            resolution: ResolutionDraft(
                state: .resolved,
                checkedRevisionHash: "revision-one",
                resolverPolicyVersion: 1,
                resolvedSelector: newSelector,
                evidence: [.init(kind: .manualConfirmation)],
                lastCheckedAt: date(3_000)
            ),
            expectedMemoryRecordVersion: created.storedMemory.memory.recordVersion,
            expectedResolutionRecordVersion: created.storedMemory.resolution.recordVersion,
            expectedDocumentRecordVersion: document.recordVersion
        )
        XCTAssertEqual(reattached.storedMemory.anchors.count, 2)
        XCTAssertEqual(reattached.storedMemory.memory.currentAnchorID, newAnchor.id)
        XCTAssertEqual(reattached.storedMemory.anchors.first?.exactQuote, request.anchor.exactQuote)

        let undone = try store.undoReattachment(
            reattached.undo,
            validatedResolution: ResolutionDraft(
                state: .resolved,
                checkedRevisionHash: "revision-one",
                resolverPolicyVersion: 1,
                resolvedSelector: selector(
                    range: request.anchor.canonicalTextPosition,
                    fingerprint: request.anchor.blockFingerprint
                ),
                evidence: [.init(kind: .exactQuote)],
                lastCheckedAt: date(3_100)
            )
        )
        XCTAssertEqual(undone.memory.currentAnchorID, request.anchor.id)
        XCTAssertEqual(undone.anchors.count, 2)
        XCTAssertEqual(undone.resolution.anchorID, request.anchor.id)
    }

    func testForgetDocumentAndUndoRoundTripMemoryReadingStateAndFavourite() throws {
        let store = try makeStore().store
        var document = try createDocument(in: store)
        let favourite = try store.setFavourite(
            documentID: document.id,
            isFavourite: true,
            expectedRecordVersion: document.recordVersion
        )
        document = favourite.document
        _ = try store.updateReadingState(
            documentID: document.id,
            update: ReadingStateUpdate(
                semanticPosition: nil,
                fallbackScrollFraction: 0.25,
                lastReadAt: date(3_500)
            ),
            expectedRecordVersion: nil
        )
        let request = makeCapture(
            document: document,
            quote: "memory restored after forget",
            range: CanonicalTextRange(lowerBound: 0, upperBound: 28)
        )
        _ = try store.createMemory(request)

        let forgotten = try store.forgetDocument(
            documentID: document.id,
            expectedRecordVersion: document.recordVersion
        )
        XCTAssertNil(try store.memory(id: request.id))
        XCTAssertNil(try store.readingState(documentID: document.id))
        XCTAssertFalse(try XCTUnwrap(store.document(id: document.id)).isFavourite)

        let restoredDocument = try store.restoreForgottenDocument(forgotten, at: date(3_600))
        XCTAssertTrue(restoredDocument.isFavourite)
        XCTAssertNotNil(try store.readingState(documentID: document.id))
        XCTAssertNotNil(try store.memory(id: request.id))
    }

    func testDocumentSearchUsesFilenameHeadingAndDuplicateFolderProvenance() throws {
        let store = try makeStore().store
        let first = try store.createDocument(
            NewDocument(displayName: "Notes.md", lastConfirmedContentHash: "one"),
            location: NewDocumentLocation(url: URL(fileURLWithPath: "/private/alpha/Notes.md"))
        )
        let second = try store.createDocument(
            NewDocument(displayName: "Notes.md", lastConfirmedContentHash: "two"),
            location: NewDocumentLocation(url: URL(fileURLWithPath: "/private/beta/Notes.md"))
        )
        _ = try store.updateReadingState(
            documentID: first.id,
            update: ReadingStateUpdate(
                semanticPosition: nil,
                fallbackScrollFraction: 0.2,
                lastSemanticHeading: "Recovery contract"
            ),
            expectedRecordVersion: nil
        )
        _ = try store.setFavourite(
            documentID: second.id,
            isFavourite: true,
            expectedRecordVersion: second.recordVersion
        )

        let headings = try store.searchDocuments(
            DocumentSearchQuery(text: "Recovery contract", facet: .continueReading)
        )
        XCTAssertEqual(headings.map(\.document.id), [first.id])
        XCTAssertEqual(headings.first?.parentFolderProvenance, "alpha")
        let favourites = try store.searchDocuments(
            DocumentSearchQuery(text: "Notes", facet: .favourites)
        )
        XCTAssertEqual(favourites.map(\.document.id), [second.id])
        XCTAssertEqual(favourites.first?.parentFolderProvenance, "beta")
    }

    func testChangeObservationCarriesOnlyIdentifiers() async throws {
        let store = try makeStore().store
        let stream = store.observeChanges()
        var iterator = stream.makeAsyncIterator()
        let document = try createDocument(in: store)

        let change = await iterator.next()
        XCTAssertEqual(change?.kind, .document)
        XCTAssertEqual(change?.documentIDs, [document.id])
        XCTAssertTrue(change?.memoryIDs.isEmpty == true)
    }
}

private extension MemoryStoreTests {
    struct StoreFixture {
        var store: SQLiteMemoryStore
        var directory: URL
        var databaseURL: URL
    }

    func makeStore() throws -> StoreFixture {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("ReadingMemory.sqlite3")
        return StoreFixture(
            store: try SQLiteMemoryStore(databaseURL: databaseURL),
            directory: directory,
            databaseURL: databaseURL
        )
    }

    func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownReader-MemoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func createDocument(in store: SQLiteMemoryStore) throws -> DocumentRecord {
        try store.createDocument(
            NewDocument(
                displayName: "Reading.md",
                lastConfirmedContentHash: "revision-one",
                detectedTextEncoding: "utf-8",
                hadByteOrderMark: false,
                createdAt: date(2_000)
            ),
            location: NewDocumentLocation(
                url: URL(fileURLWithPath: "/private/reading/Reading.md"),
                observedAt: date(2_000)
            )
        )
    }

    func makeCapture(
        document: DocumentRecord,
        quote: String,
        note: String? = nil,
        range: CanonicalTextRange
    ) -> CreateMemoryRequest {
        let resolvedSelector = selector(range: range, fingerprint: "block-one")
        let anchor = NewConfirmedAnchor(
            confirmation: .initialCapture,
            createdAt: date(2_000),
            selectorVersion: 1,
            projectionVersion: 1,
            sourceRevisionHash: "revision-one",
            resolverPolicyVersion: 1,
            exactQuote: quote,
            prefix: "prefix",
            suffix: "suffix",
            canonicalTextPosition: range,
            canonicalUTF8RangeInBlock: range,
            blockKind: resolvedSelector.blockKind,
            blockFingerprint: resolvedSelector.blockFingerprint,
            headingPath: resolvedSelector.headingPath,
            blockOrdinal: resolvedSelector.blockOrdinal,
            blockFingerprintOccurrenceCountInSection: 1
        )
        return CreateMemoryRequest(
            documentID: document.id,
            kind: .passage,
            originalVisibleQuote: quote,
            canonicalMatchQuote: quote,
            noteText: note,
            expectedDocumentRecordVersion: document.recordVersion,
            anchor: anchor,
            resolution: ResolutionDraft(
                state: .resolved,
                checkedRevisionHash: "revision-one",
                resolverPolicyVersion: 1,
                resolvedSelector: resolvedSelector,
                evidence: [
                    .init(kind: .exactQuote),
                    .init(kind: .prefix),
                    .init(kind: .suffix),
                ],
                lastCheckedAt: date(2_000)
            ),
            createdAt: date(2_000)
        )
    }

    func selector(range: CanonicalTextRange, fingerprint: String) -> ResolvedSelector {
        ResolvedSelector(
            sourceRevisionHash: "revision-one",
            projectionVersion: 1,
            blockID: "block-id-\(fingerprint)",
            canonicalUTF8RangeInBlock: range,
            canonicalTextPosition: range,
            blockKind: "paragraph",
            blockFingerprint: fingerprint,
            headingPath: [StoredHeadingBreadcrumb(level: 1, title: "Trust")],
            blockOrdinal: 1,
            sourceUTF8Span: nil
        )
    }

    func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    func migrationBackups(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".ReadingMemory.migration-backup-") }
    }
}
