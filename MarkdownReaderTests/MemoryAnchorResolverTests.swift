import XCTest
@testable import MarkdownReader

final class MemoryAnchorResolverTests: XCTestCase {
    func testUnchangedPassageResolvesWithExactSelectorAndRunFragments() throws {
        let original = try projection("# Notes\n\nRemember this important idea today.")
        let anchor = try anchor(
            quote: "important idea",
            blockOrdinal: 1,
            projection: original
        )

        let result = try MemoryAnchorResolver.resolve(
            anchor: anchor,
            priorProjection: original,
            currentProjection: original
        )

        XCTAssertEqual(result.resolution.state, .resolved)
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(
            result.resolution.resolvedSelector?.canonicalUTF8RangeInBlock,
            anchor.canonicalUTF8RangeInBlock
        )
        XCTAssertFalse(result.resolution.resolvedSelector?.runFragments.isEmpty ?? true)
        XCTAssertEqual(
            result.resolution.evidence,
            [.exactPassage, .matchingPrefix, .matchingSuffix, .sameBlockFingerprint, .sameHeading]
        )
    }

    func testInsertionAboveAndHeadingRenameRemainResolved() throws {
        let original = try projection("# Old heading\n\nContext before. Keep this. Context after.")
        let anchor = try anchor(quote: "Keep this.", blockOrdinal: 1, projection: original)
        let changed = try projection("Preface.\n\n# Renamed heading\n\nContext before. Keep this. Context after.")

        let result = try MemoryAnchorResolver.resolve(
            anchor: anchor,
            priorProjection: original,
            currentProjection: changed
        )

        XCTAssertEqual(result.resolution.state, .resolved)
        XCTAssertEqual(result.resolution.resolvedSelector?.blockID, "block-2")
        XCTAssertTrue(result.resolution.evidence.contains(.sameBlockFingerprint))
        XCTAssertFalse(result.resolution.evidence.contains(.sameHeading))
    }

    func testUniqueUnchangedBlockSurvivesReorderWithoutOrdinalPairing() throws {
        let original = try projection("Alpha.\n\nKeep target here.\n\nOmega.")
        let anchor = try anchor(quote: "target", blockOrdinal: 1, projection: original)
        let reordered = try projection("Omega.\n\nAlpha.\n\nKeep target here.")

        let result = try MemoryAnchorResolver.resolve(
            anchor: anchor,
            priorProjection: original,
            currentProjection: reordered
        )

        XCTAssertEqual(result.resolution.state, .resolved)
        XCTAssertEqual(result.resolution.resolvedSelector?.blockID, "block-2")
    }

    func testDuplicateIdenticalBlocksAreAmbiguousAndNeverPairedByOrdinal() throws {
        let original = try projection("Same sentence.\n\nSame sentence.")
        let anchor = try anchor(
            quote: "Same sentence.",
            blockOrdinal: 0,
            projection: original
        )
        XCTAssertEqual(anchor.blockFingerprintOccurrenceCountInSection, 2)

        let result = try MemoryAnchorResolver.resolve(
            anchor: anchor,
            priorProjection: original,
            currentProjection: original
        )

        XCTAssertEqual(result.resolution.state, .ambiguous)
        XCTAssertNil(result.resolution.resolvedSelector)
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertNotEqual(result.candidates[0].id, result.candidates[1].id)
    }

    func testDuplicateQuoteWithDifferentContextUsesAllStoredContext() throws {
        let original = try projection("Before original target after original.")
        let anchor = try anchor(quote: "target", blockOrdinal: 0, projection: original)
        let duplicated = try projection(
            "Before duplicate target after duplicate. Before original target after original."
        )

        let result = try MemoryAnchorResolver.resolve(
            anchor: anchor,
            priorProjection: original,
            currentProjection: duplicated
        )

        XCTAssertEqual(result.resolution.state, .resolved)
        XCTAssertEqual(result.candidates.count, 1)
        let selector = try XCTUnwrap(result.resolution.resolvedSelector)
        let block = try XCTUnwrap(duplicated.block(id: selector.blockID))
        XCTAssertEqual(
            CanonicalMarkdownText.substring(
                block.canonicalText,
                utf8Range: selector.canonicalUTF8RangeInBlock
            ),
            "target"
        )
    }

    func testChangedQuoteBecomesOrphanedWithoutNeedsReviewProposal() throws {
        let original = try projection("Prefix saved wording suffix.")
        let anchor = try anchor(quote: "saved wording", blockOrdinal: 0, projection: original)
        let changed = try projection("Prefix revised wording suffix.")
        let anchorBefore = anchor

        let result = try MemoryAnchorResolver.resolve(
            anchor: anchor,
            priorProjection: original,
            currentProjection: changed
        )

        XCTAssertEqual(result.resolution.state, .orphaned)
        XCTAssertNil(result.resolution.resolvedSelector)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(anchor, anchorBefore, "automatic recovery must not mutate an anchor")
    }

    func testCRLFAndNFDChangesDoNotBreakCanonicalExactRecovery() throws {
        let original = try projection("# Café\r\n\r\nKeep Cafe\u{301} passage.")
        let anchor = try anchor(quote: "Café", blockOrdinal: 1, projection: original)
        let changed = try projection("# Café\n\nKeep Café passage.")

        let result = try MemoryAnchorResolver.resolve(
            anchor: anchor,
            priorProjection: original,
            currentProjection: changed
        )

        XCTAssertNotEqual(original.source.revisionHash, changed.source.revisionHash)
        XCTAssertEqual(result.resolution.state, .resolved)
    }

    func testMovedWholeBlockWithinSameHeadingSectionResolves() throws {
        let original = try projection("# Section\n\nKeep exactly.\n\nAnother block.")
        let anchor = try anchor(
            quote: "Keep exactly.",
            blockOrdinal: 1,
            projection: original
        )
        XCTAssertTrue(anchor.prefix.isEmpty)
        XCTAssertTrue(anchor.suffix.isEmpty)
        let moved = try projection("# Section\n\nAnother block.\n\nKeep exactly.")

        let result = try MemoryAnchorResolver.resolve(
            anchor: anchor,
            priorProjection: original,
            currentProjection: moved
        )

        XCTAssertEqual(result.resolution.state, .resolved)
        XCTAssertEqual(result.resolution.resolvedSelector?.blockID, "block-2")
    }

    func testSameCheckedHashRetainsExplicitResolvedSelector() throws {
        let projection = try projection("Same sentence.\n\nSame sentence.")
        let anchor = try anchor(
            quote: "Same sentence.",
            blockOrdinal: 0,
            projection: projection
        )
        let ambiguous = try MemoryAnchorResolver.resolve(
            anchor: anchor,
            priorProjection: projection,
            currentProjection: projection
        )
        let chosen = try XCTUnwrap(ambiguous.candidates.last)
        let checked = MemoryResolutionSnapshot(
            anchorID: anchor.id,
            state: .resolved,
            checkedRevisionHash: projection.source.revisionHash,
            resolverPolicyVersion: MemoryAnchorResolver.policyVersion,
            resolvedSelector: chosen.selector,
            evidence: chosen.evidence
        )

        let retained = try MemoryAnchorResolver.resolve(
            anchor: anchor,
            priorProjection: projection,
            currentProjection: projection,
            currentResolution: checked
        )

        XCTAssertTrue(retained.retainedCheckedResolution)
        XCTAssertEqual(retained.resolution.resolvedSelector, chosen.selector)
        XCTAssertTrue(retained.candidates.isEmpty)
    }

    func testContextSelectorsCapAt64UTF8BytesWithoutSplittingScalar() throws {
        let prefix = String(repeating: "é", count: 40)
        let suffix = String(repeating: "🧠", count: 20)
        let projection = try projection("\(prefix)TARGET\(suffix)")
        let anchor = try anchor(quote: "TARGET", blockOrdinal: 0, projection: projection)

        XCTAssertLessThanOrEqual(anchor.prefix.utf8.count, 64)
        XCTAssertLessThanOrEqual(anchor.suffix.utf8.count, 64)
        XCTAssertEqual(anchor.prefix.utf8.count % "é".utf8.count, 0)
        XCTAssertEqual(anchor.suffix.utf8.count % "🧠".utf8.count, 0)
        XCTAssertEqual(
            try MemoryAnchorResolver.resolve(
                anchor: anchor,
                currentProjection: projection
            ).resolution.state,
            .resolved
        )
    }

    func testResolverRejectsUnknownPolicyWithoutGuessing() throws {
        let projection = try projection("Passage.")
        let valid = try anchor(quote: "Passage.", blockOrdinal: 0, projection: projection)
        let future = ConfirmedMemoryAnchor(
            id: valid.id,
            memoryID: valid.memoryID,
            supersedesAnchorID: valid.supersedesAnchorID,
            confirmation: valid.confirmation,
            createdAt: valid.createdAt,
            selectorVersion: valid.selectorVersion,
            projectionVersion: valid.projectionVersion,
            sourceRevisionHash: valid.sourceRevisionHash,
            resolverPolicyVersion: 2,
            exactQuote: valid.exactQuote,
            prefix: valid.prefix,
            suffix: valid.suffix,
            canonicalTextPosition: valid.canonicalTextPosition,
            canonicalUTF8RangeInBlock: valid.canonicalUTF8RangeInBlock,
            blockKind: valid.blockKind,
            blockFingerprint: valid.blockFingerprint,
            headingPath: valid.headingPath,
            blockOrdinal: valid.blockOrdinal,
            blockFingerprintOccurrenceCountInSection: valid.blockFingerprintOccurrenceCountInSection,
            sourceUTF8Span: valid.sourceUTF8Span
        )

        XCTAssertThrowsError(
            try MemoryAnchorResolver.resolve(
                anchor: future,
                currentProjection: projection
            )
        ) {
            XCTAssertEqual(
                $0 as? MemoryAnchorResolverError,
                .unsupportedPolicyVersion(2)
            )
        }
    }

    private func projection(_ source: String) throws -> DocumentProjection {
        try DocumentProjection.build(sourceData: Data(source.utf8))
    }

    private func anchor(
        quote: String,
        blockOrdinal: Int,
        projection: DocumentProjection
    ) throws -> ConfirmedMemoryAnchor {
        let block = projection.blocks[blockOrdinal]
        let range = try XCTUnwrap(block.canonicalText.range(of: quote))
        let lower = block.canonicalText.utf8.distance(
            from: block.canonicalText.utf8.startIndex,
            to: range.lowerBound
        )
        let upper = block.canonicalText.utf8.distance(
            from: block.canonicalText.utf8.startIndex,
            to: range.upperBound
        )
        let selection = ProjectionSelection(
            sourceRevisionHash: projection.source.revisionHash,
            renderRevision: projection.renderRevision,
            projectionVersion: projection.version,
            blockID: block.id,
            canonicalUTF8RangeInBlock: UTF8ByteRange(lower, upper),
            selectedVisibleText: quote,
            runIDs: block.textRuns.map(\.id)
        )
        return try projection.makeInitialAnchor(
            memoryID: UUID(),
            from: selection,
            anchorID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }
}
