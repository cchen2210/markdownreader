import Foundation
import XCTest
@testable import MarkdownReader

final class MemoryFTSScaleTests: XCTestCase {
    func testFiveHundredMemoryFixtureSearchesCorrectlyWithinFirstPageBudget() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownReader-FTS500-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("ReadingMemory.sqlite3")
        let store = try SQLiteMemoryStore(databaseURL: databaseURL)
        addTeardownBlock { try? store.dbPool.close() }
        let document = try store.createDocument(
            NewDocument(
                id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
                displayName: "FTS-500.md",
                lastConfirmedContentHash: "fixture-revision-500",
                detectedTextEncoding: "utf8",
                hadByteOrderMark: false,
                createdAt: Date(timeIntervalSince1970: 10_000)
            ),
            location: NewDocumentLocation(
                id: try XCTUnwrap(UUID(uuidString: "20000000-0000-0000-0000-000000000001")),
                url: directory.appendingPathComponent("FTS-500.md"),
                observedAt: Date(timeIntervalSince1970: 10_000)
            )
        )

        var expectedTargetID: UUID?
        for index in 0..<500 {
            let request = try fixtureCapture(index: index, document: document)
            _ = try store.createMemory(request)
            if index == 377 { expectedTargetID = request.id }
        }

        let targetQuery = MemorySearchQuery(
            text: "Archive passage number 377 constellation",
            scope: .passages,
            facet: .highlights,
            limit: 50
        )
        let targetResults = try store.searchMemories(targetQuery)
        XCTAssertEqual(targetResults.map(\.memory.id), [try XCTUnwrap(expectedTargetID)])
        XCTAssertEqual(targetResults.first?.totalCount, 1)

        let noteResults = try store.searchMemories(
            MemorySearchQuery(
                text: "Even field note",
                scope: .notes,
                facet: .notes,
                limit: 500
            )
        )
        XCTAssertEqual(noteResults.count, 250)
        XCTAssertEqual(noteResults.first?.totalCount, 250)
        XCTAssertTrue(noteResults.allSatisfy { $0.memory.noteText?.contains("Even field note") == true })
        XCTAssertTrue(
            try store.searchMemories(
                MemorySearchQuery(text: "Even field note", scope: .passages, limit: 500)
            ).isEmpty
        )

        for _ in 0..<3 { _ = try store.searchMemories(targetQuery) }
        let warmP95 = try p95OfTwentyQueries(in: store, query: targetQuery)
        XCTAssertLessThan(warmP95, 0.150, "Warm 500-memory FTS p95 exceeded 150 ms")

        // A new pool exercises query correctness after reopening the durable
        // database instead of relying only on the writer's existing connection.
        let reopened = try SQLiteMemoryStore(databaseURL: databaseURL)
        defer { try? reopened.dbPool.close() }
        XCTAssertEqual(
            try reopened.searchMemories(targetQuery).map(\.memory.id),
            [try XCTUnwrap(expectedTargetID)]
        )
        for _ in 0..<3 { _ = try reopened.searchMemories(targetQuery) }
        let reopenedP95 = try p95OfTwentyQueries(in: reopened, query: targetQuery)
        XCTAssertLessThan(reopenedP95, 0.150, "Reopened 500-memory FTS p95 exceeded 150 ms")
    }
}

private extension MemoryFTSScaleTests {
    func fixtureCapture(index: Int, document: DocumentRecord) throws -> CreateMemoryRequest {
        let memoryID = try XCTUnwrap(
            UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index + 1))
        )
        let anchorID = try XCTUnwrap(
            UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", index + 1))
        )
        let quote = String(format: "Archive passage number %03d constellation", index)
        let localRange = CanonicalTextRange(
            lowerBound: 0,
            upperBound: Int64(quote.utf8.count)
        )
        let globalStart = Int64(index * 96)
        let globalRange = CanonicalTextRange(
            lowerBound: globalStart,
            upperBound: globalStart + Int64(quote.utf8.count)
        )
        let heading = StoredHeadingBreadcrumb(level: 1, title: "Chapter \(index / 100)")
        let selector = ResolvedSelector(
            sourceRevisionHash: "fixture-revision-500",
            projectionVersion: 1,
            blockID: "block-\(index)",
            canonicalUTF8RangeInBlock: localRange,
            canonicalTextPosition: globalRange,
            blockKind: "paragraph",
            blockFingerprint: "fixture-block-\(index)",
            headingPath: [heading],
            blockOrdinal: Int64(index),
            sourceUTF8Span: nil
        )
        let createdAt = Date(timeIntervalSince1970: 10_001 + Double(index))
        let note = index.isMultiple(of: 2)
            ? String(format: "Even field note number %03d", index)
            : nil
        return CreateMemoryRequest(
            id: memoryID,
            documentID: document.id,
            kind: .passage,
            originalVisibleQuote: quote,
            canonicalMatchQuote: quote,
            noteText: note,
            expectedDocumentRecordVersion: document.recordVersion,
            anchor: NewConfirmedAnchor(
                id: anchorID,
                confirmation: .initialCapture,
                createdAt: createdAt,
                selectorVersion: 1,
                projectionVersion: 1,
                sourceRevisionHash: "fixture-revision-500",
                resolverPolicyVersion: 1,
                exactQuote: quote,
                prefix: "",
                suffix: "",
                canonicalTextPosition: globalRange,
                canonicalUTF8RangeInBlock: localRange,
                blockKind: "paragraph",
                blockFingerprint: "fixture-block-\(index)",
                headingPath: [heading],
                blockOrdinal: Int64(index),
                blockFingerprintOccurrenceCountInSection: 1,
                sourceUTF8Span: nil
            ),
            resolution: ResolutionDraft(
                state: .resolved,
                checkedRevisionHash: "fixture-revision-500",
                resolverPolicyVersion: 1,
                resolvedSelector: selector,
                evidence: [.init(kind: .exactQuote)],
                lastCheckedAt: createdAt
            ),
            createdAt: createdAt
        )
    }

    func p95OfTwentyQueries(
        in store: SQLiteMemoryStore,
        query: MemorySearchQuery
    ) throws -> TimeInterval {
        var durations: [TimeInterval] = []
        durations.reserveCapacity(20)
        for _ in 0..<20 {
            let start = ProcessInfo.processInfo.systemUptime
            _ = try store.searchMemories(query)
            durations.append(ProcessInfo.processInfo.systemUptime - start)
        }
        return durations.sorted()[18]
    }
}
