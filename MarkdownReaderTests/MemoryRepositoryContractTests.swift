import Foundation
import GRDB
import XCTest
@testable import MarkdownReader

final class MemoryRepositoryContractTests: XCTestCase {
    func testFirstDocumentOpenImportsOnlyItsLegacyReadingPosition() async throws {
        let fixture = try makeFixture()
        let defaults = fixture.defaults
        let openedURL = fixture.directory.appendingPathComponent("Opened.md")
        let unopenedURL = fixture.directory.appendingPathComponent("Unopened.md")
        try Data("# Opened\n\nA document.".utf8).write(to: openedURL)
        try Data("# Unopened".utf8).write(to: unopenedURL)
        ReadingPositionStore.set(0.64, for: openedURL, defaults: defaults, now: 10)
        ReadingPositionStore.set(0.28, for: unopenedURL, defaults: defaults, now: 20)
        let openedLegacy = try XCTUnwrap(
            ReadingPositionStore.legacyPosition(for: openedURL, defaults: defaults)
        )
        let repository = MemoryRepository(
            store: fixture.store,
            legacyReadingPositionDefaults: defaults
        )

        let registered = try await repository.openDocument(
            at: openedURL,
            source: sourceMetadata,
            openedAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(registered.readingState?.fallbackScrollFraction, 0.64)
        XCTAssertNil(registered.readingState?.semanticPosition)
        XCTAssertNil(ReadingPositionStore.legacyPosition(for: openedURL, defaults: defaults))
        XCTAssertEqual(
            ReadingPositionStore.legacyPosition(for: unopenedURL, defaults: defaults)?.fraction,
            0.28
        )
        let imports = try fixture.store.dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT legacy_key_hash, document_id FROM legacy_reading_imports"
            )
        }
        XCTAssertEqual(imports.count, 1)
        XCTAssertEqual(imports[0]["legacy_key_hash"], openedLegacy.keyHash)
        XCTAssertEqual(
            imports[0]["document_id"],
            registered.document.id.uuidString.lowercased()
        )
    }

    @MainActor
    func testLibraryStartupDoesNotCrawlOrConsumeLegacyPositions() async throws {
        let fixture = try makeFixture()
        let url = fixture.directory.appendingPathComponent("NotOpened.md")
        ReadingPositionStore.set(0.55, for: url, defaults: fixture.defaults, now: 10)
        let repository = MemoryRepository(
            store: fixture.store,
            legacyReadingPositionDefaults: fixture.defaults
        )

        let library = ReadingMemoryLibrary(repository: repository)
        await Task.yield()

        XCTAssertTrue(library.isReady)
        XCTAssertNotNil(ReadingPositionStore.legacyPosition(for: url, defaults: fixture.defaults))
        XCTAssertTrue(try fixture.store.snapshot().documents.isEmpty)
        let importCount = try await fixture.store.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM legacy_reading_imports") ?? -1
        }
        XCTAssertEqual(importCount, 0)
    }

    func testStaleWindowNoteCommitPreservesCommittedNoteFTSAndHistory() async throws {
        let fixture = try makeFixture()
        let document = try fixture.store.createDocument(
            NewDocument(
                displayName: "Windows.md",
                lastConfirmedContentHash: "revision-one",
                detectedTextEncoding: "utf8",
                hadByteOrderMark: false,
                createdAt: Date(timeIntervalSince1970: 2_000)
            ),
            location: NewDocumentLocation(
                url: fixture.directory.appendingPathComponent("Windows.md"),
                observedAt: Date(timeIntervalSince1970: 2_000)
            )
        )
        let request = captureRequest(document: document)
        let created = try fixture.store.createMemory(request)
        let windowARecord = created.storedMemory.memory
        let windowBRecord = created.storedMemory.memory
        let repository = MemoryRepository(
            store: fixture.store,
            legacyReadingPositionDefaults: fixture.defaults
        )

        let committed = try await repository.updateNote(
            memoryID: request.id,
            noteText: "committed in window A",
            expectedRecordVersion: windowARecord.recordVersion,
            at: Date(timeIntervalSince1970: 2_100)
        )
        XCTAssertEqual(committed.memory.recordVersion, 2)

        do {
            _ = try await repository.updateNote(
                memoryID: request.id,
                noteText: "draft from stale window B",
                expectedRecordVersion: windowBRecord.recordVersion,
                at: Date(timeIntervalSince1970: 2_200)
            )
            XCTFail("A stale window must not overwrite the committed note.")
        } catch {
            XCTAssertEqual(
                error as? MemoryStoreError,
                .versionConflict(entity: .memory, expected: 1, actual: 2)
            )
        }

        let stored = try XCTUnwrap(fixture.store.memory(id: request.id))
        XCTAssertEqual(stored.memory.noteText, "committed in window A")
        XCTAssertEqual(stored.memory.recordVersion, 2)
        XCTAssertEqual(stored.history.map(\.kind), [.created, .noteEdited])
        XCTAssertEqual(
            try fixture.store.searchMemories(
                MemorySearchQuery(text: "committed in window A", scope: .notes)
            ).map(\.memory.id),
            [request.id]
        )
        XCTAssertTrue(
            try fixture.store.searchMemories(
                MemorySearchQuery(text: "draft from stale window B", scope: .notes)
            ).isEmpty
        )
    }
}

private extension MemoryRepositoryContractTests {
    struct Fixture {
        let store: SQLiteMemoryStore
        let directory: URL
        let defaults: UserDefaults
    }

    var sourceMetadata: ProjectionSourceMetadata {
        ProjectionSourceMetadata(
            revisionHash: "revision-one",
            byteCount: 22,
            encoding: .utf8,
            byteOrderMark: .none
        )
    }

    func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownReader-RepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "MarkdownReader.RepositoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = try SQLiteMemoryStore(
            databaseURL: directory.appendingPathComponent("ReadingMemory.sqlite3")
        )
        let fixture = Fixture(
            store: store,
            directory: directory,
            defaults: defaults
        )
        addTeardownBlock {
            try? store.dbPool.close()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        return fixture
    }

    func captureRequest(document: DocumentRecord) -> CreateMemoryRequest {
        let memoryID = UUID()
        let anchorID = UUID()
        let range = CanonicalTextRange(lowerBound: 0, upperBound: 22)
        let selector = ResolvedSelector(
            sourceRevisionHash: "revision-one",
            projectionVersion: 1,
            blockID: "block-0",
            canonicalUTF8RangeInBlock: range,
            canonicalTextPosition: range,
            blockKind: "paragraph",
            blockFingerprint: "block-fingerprint",
            headingPath: [StoredHeadingBreadcrumb(level: 1, title: "Windows")],
            blockOrdinal: 0,
            sourceUTF8Span: nil
        )
        let anchor = NewConfirmedAnchor(
            id: anchorID,
            confirmation: .initialCapture,
            createdAt: Date(timeIntervalSince1970: 2_000),
            selectorVersion: 1,
            projectionVersion: 1,
            sourceRevisionHash: "revision-one",
            resolverPolicyVersion: 1,
            exactQuote: "A concurrent note test",
            prefix: "",
            suffix: "",
            canonicalTextPosition: range,
            canonicalUTF8RangeInBlock: range,
            blockKind: "paragraph",
            blockFingerprint: "block-fingerprint",
            headingPath: [StoredHeadingBreadcrumb(level: 1, title: "Windows")],
            blockOrdinal: 0,
            blockFingerprintOccurrenceCountInSection: 1,
            sourceUTF8Span: nil
        )
        return CreateMemoryRequest(
            id: memoryID,
            documentID: document.id,
            kind: .passage,
            originalVisibleQuote: "A concurrent note test",
            canonicalMatchQuote: "A concurrent note test",
            noteText: "original note",
            expectedDocumentRecordVersion: document.recordVersion,
            anchor: anchor,
            resolution: ResolutionDraft(
                state: .resolved,
                checkedRevisionHash: "revision-one",
                resolverPolicyVersion: 1,
                resolvedSelector: selector,
                evidence: [.init(kind: .exactQuote)],
                lastCheckedAt: Date(timeIntervalSince1970: 2_000)
            ),
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
    }
}
