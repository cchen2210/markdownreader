import GRDB
import XCTest
@testable import MarkdownReader

final class MemoryStoreSequenceTests: XCTestCase {
    func testSnapshotAndSequenceComeFromOneDurableStoreBoundary() throws {
        let fixture = try makeFixture()

        let empty = try fixture.store.snapshotWithSequence()
        XCTAssertEqual(empty.sequence, 0)
        XCTAssertTrue(empty.snapshot.documents.isEmpty)
        XCTAssertEqual(try fixture.store.currentSequence(), 0)

        let first = try createDocument(in: fixture.store, name: "First.md")
        XCTAssertEqual(try fixture.store.currentSequence(), 1)
        _ = try fixture.store.setFavourite(
            documentID: first.id,
            isFavourite: true,
            expectedRecordVersion: first.recordVersion
        )

        let sequenced = try fixture.store.snapshotWithSequence()
        XCTAssertEqual(sequenced.sequence, 2)
        XCTAssertEqual(sequenced.snapshot.documents.map(\.displayName), ["First.md"])
        XCTAssertEqual(sequenced.snapshot.documents.first?.isFavourite, true)
        XCTAssertEqual(try fixture.store.snapshot(), sequenced.snapshot)
    }

    func testEverySuccessfulMutationTransactionAdvancesExactlyOnce() throws {
        let fixture = try makeFixture()
        let document = try createDocument(in: fixture.store, name: "Reading.md")
        XCTAssertEqual(try fixture.store.currentSequence(), 1)

        let state = try fixture.store.updateReadingState(
            documentID: document.id,
            update: ReadingStateUpdate(
                semanticPosition: nil,
                fallbackScrollFraction: 0.25,
                lastReadAt: Date(timeIntervalSince1970: 2_000)
            ),
            expectedRecordVersion: nil
        )
        XCTAssertEqual(state.recordVersion, 1)
        XCTAssertEqual(try fixture.store.currentSequence(), 2)

        _ = try fixture.store.updateReadingState(
            documentID: document.id,
            update: ReadingStateUpdate(
                semanticPosition: nil,
                fallbackScrollFraction: 0.75,
                lastReadAt: Date(timeIntervalSince1970: 2_100)
            ),
            expectedRecordVersion: state.recordVersion
        )
        XCTAssertEqual(try fixture.store.currentSequence(), 3)
    }

    func testSequencePersistsAcrossStoreReopen() throws {
        let fixture = try makeFixture()
        _ = try createDocument(in: fixture.store, name: "Persistent.md")
        XCTAssertEqual(try fixture.store.currentSequence(), 1)
        try fixture.store.dbPool.close()

        let reopened = try SQLiteMemoryStore(databaseURL: fixture.databaseURL)
        addTeardownBlock { try? reopened.dbPool.close() }
        XCTAssertEqual(try reopened.currentSequence(), 1)

        _ = try createDocument(in: reopened, name: "Second.md")
        let sequenced = try reopened.snapshotWithSequence()
        XCTAssertEqual(sequenced.sequence, 2)
        XCTAssertEqual(
            sequenced.snapshot.documents.map(\.displayName),
            ["Persistent.md", "Second.md"]
        )
    }

    func testExistingDatabaseWithoutSequenceMetadataIsInitializedWithoutDataLoss() throws {
        let fixture = try makeFixture()
        _ = try createDocument(in: fixture.store, name: "Legacy.md")
        try fixture.store.dbPool.close()

        let queue = try DatabaseQueue(path: fixture.databaseURL.path)
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM store_metadata WHERE key = ?",
                arguments: [SQLiteMemoryStore.changeSequenceMetadataKey]
            )
        }
        try queue.close()

        let reopened = try SQLiteMemoryStore(databaseURL: fixture.databaseURL)
        addTeardownBlock { try? reopened.dbPool.close() }
        let sequenced = try reopened.snapshotWithSequence()
        XCTAssertEqual(sequenced.sequence, 0)
        XCTAssertEqual(sequenced.snapshot.documents.map(\.displayName), ["Legacy.md"])
    }

    func testFailedAndRolledBackWritesDoNotAdvanceSequence() throws {
        let fixture = try makeFixture()
        let document = try createDocument(in: fixture.store, name: "Stable.md")
        let committedSequence = try fixture.store.currentSequence()

        XCTAssertThrowsError(
            try fixture.store.setFavourite(
                documentID: document.id,
                isFavourite: true,
                expectedRecordVersion: document.recordVersion + 99
            )
        )
        XCTAssertEqual(try fixture.store.currentSequence(), committedSequence)

        XCTAssertThrowsError(
            try fixture.store.write { db -> Void in
                try db.execute(
                    sql: "UPDATE documents SET display_name = 'Must Roll Back' WHERE id = ?",
                    arguments: [document.id.uuidString.lowercased()]
                )
                throw MemoryStoreError.invalidRecord("forced rollback")
            }
        ) { error in
            XCTAssertEqual(error as? MemoryStoreError, .invalidRecord("forced rollback"))
        }

        XCTAssertEqual(try fixture.store.currentSequence(), committedSequence)
        XCTAssertEqual(try fixture.store.document(id: document.id)?.displayName, "Stable.md")
    }

    func testRepositoryArchiveWriteValidatesCurrentSequenceWithoutSuspension() async throws {
        let fixture = try makeFixture()
        let sequenced = try fixture.store.snapshotWithSequence()
        let payload = try MemoryArchiveExporter.makePayload(
            snapshot: sequenced.snapshot,
            storeSequence: sequenced.sequence,
            includeFileLocations: false,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let repository = MemoryRepository(store: fixture.store)
        let destination = fixture.directory.appendingPathComponent("Reading Memory.md")

        try await repository.writeArchive(
            payload,
            representation: .markdown,
            to: destination
        )
        XCTAssertEqual(
            try Data(contentsOf: destination),
            try payload.data(for: .markdown, currentStoreSequence: 0)
        )

        _ = try createDocument(in: fixture.store, name: "Changed.md")
        let committedBytes = try Data(contentsOf: destination)
        do {
            try await repository.writeArchive(
                payload,
                representation: .markdown,
                to: destination
            )
            XCTFail("A stale export payload must not replace the destination.")
        } catch {
            XCTAssertEqual(
                error as? MemoryArchiveExportError,
                .payloadInvalidated(payloadSequence: 0, currentSequence: 1)
            )
        }
        XCTAssertEqual(try Data(contentsOf: destination), committedBytes)
    }

    private struct Fixture {
        let store: SQLiteMemoryStore
        let directory: URL
        let databaseURL: URL
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownReader-SequenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("ReadingMemory.sqlite3")
        let store = try SQLiteMemoryStore(databaseURL: databaseURL)
        addTeardownBlock {
            try? store.dbPool.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return Fixture(store: store, directory: directory, databaseURL: databaseURL)
    }

    private func createDocument(
        in store: SQLiteMemoryStore,
        name: String
    ) throws -> DocumentRecord {
        try store.createDocument(
            NewDocument(
                displayName: name,
                createdAt: Date(timeIntervalSince1970: 1_000)
            ),
            location: nil
        )
    }
}
