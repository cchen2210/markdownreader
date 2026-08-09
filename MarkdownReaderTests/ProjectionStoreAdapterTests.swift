import XCTest
@testable import MarkdownReader

final class ProjectionStoreAdapterTests: XCTestCase {
    func testPersistedExactSelectorIsRehydratedAndRetained() throws {
        let projection = try DocumentProjection.build(
            sourceData: Data("Same passage.\n\nSame passage.".utf8)
        )
        let block = projection.blocks[1]
        let run = try XCTUnwrap(block.textRuns.first)
        let selection = ProjectionSelection(
            sourceRevisionHash: projection.source.revisionHash,
            renderRevision: projection.renderRevision,
            projectionVersion: projection.version,
            blockID: block.id,
            canonicalUTF8RangeInBlock: UTF8ByteRange(0, block.canonicalUTF8Count),
            selectedVisibleText: block.canonicalText,
            runIDs: [run.id]
        )
        let anchor = try projection.makeInitialAnchor(
            memoryID: UUID(),
            from: selection
        )
        let confirmed = try MemoryAnchorResolver.confirmInitialSelection(
            anchor: anchor,
            selection: selection,
            currentProjection: projection
        )
        let draft = try ProjectionStoreAdapter.resolutionDraft(
            from: confirmed,
            projection: projection
        )
        let record = CurrentResolutionRecord(
            memoryID: anchor.memoryID,
            anchorID: anchor.id,
            state: draft.state,
            checkedRevisionHash: draft.checkedRevisionHash,
            resolverPolicyVersion: draft.resolverPolicyVersion,
            resolvedSelector: draft.resolvedSelector,
            evidence: draft.evidence,
            lastCheckedAt: draft.lastCheckedAt,
            recordVersion: 1
        )

        let snapshot = try ProjectionStoreAdapter.resolutionSnapshot(
            from: record,
            projection: projection
        )
        let result = try XCTUnwrap(
            MemoryAnchorResolver.resolveBatch(
                anchors: [anchor],
                currentProjection: projection,
                currentResolutionsByAnchorID: [anchor.id: snapshot]
            ).first
        )

        XCTAssertTrue(result.retainedCheckedResolution)
        XCTAssertEqual(result.resolution.resolvedSelector?.blockID, block.id)
        XCTAssertEqual(result.resolution.resolvedSelector?.runFragments.map(\.runID), [run.id])
    }

    func testPersistedSelectorWithMismatchedBlockMetadataIsRejected() throws {
        let projection = try DocumentProjection.build(sourceData: Data("Passage".utf8))
        let block = try XCTUnwrap(projection.blocks.first)
        let run = try XCTUnwrap(block.textRuns.first)
        let selection = ProjectionSelection(
            sourceRevisionHash: projection.source.revisionHash,
            renderRevision: projection.renderRevision,
            projectionVersion: projection.version,
            blockID: block.id,
            canonicalUTF8RangeInBlock: UTF8ByteRange(0, block.canonicalUTF8Count),
            selectedVisibleText: block.canonicalText,
            runIDs: [run.id]
        )
        let anchor = try projection.makeInitialAnchor(memoryID: UUID(), from: selection)
        let recovery = try MemoryAnchorResolver.confirmInitialSelection(
            anchor: anchor,
            selection: selection,
            currentProjection: projection
        )
        let draft = try ProjectionStoreAdapter.resolutionDraft(from: recovery, projection: projection)
        var selector = try XCTUnwrap(draft.resolvedSelector)
        selector.blockOrdinal += 1
        let record = CurrentResolutionRecord(
            memoryID: anchor.memoryID,
            anchorID: anchor.id,
            state: .resolved,
            checkedRevisionHash: draft.checkedRevisionHash,
            resolverPolicyVersion: draft.resolverPolicyVersion,
            resolvedSelector: selector,
            evidence: draft.evidence,
            lastCheckedAt: draft.lastCheckedAt,
            recordVersion: 1
        )

        XCTAssertThrowsError(
            try ProjectionStoreAdapter.resolutionSnapshot(from: record, projection: projection)
        ) { error in
            XCTAssertEqual(error as? ProjectionStoreAdapterError, .invalidResolution)
        }
    }
}
