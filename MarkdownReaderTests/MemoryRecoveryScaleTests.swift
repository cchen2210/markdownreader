import Foundation
import XCTest
@testable import MarkdownReader

final class MemoryRecoveryScaleTests: XCTestCase {
    private static let anchorCount = 500
    private static let expectedFixtureByteCount = 1_048_999
    private static let expectedFixtureSHA256 =
        "616af611130f623f9a47c982e8eedd28d40baf85afa638f84f1d8aa2a2ccf11a"

    func testOneMiBProjectionRecoversFiveHundredAnchorsDeterministicallyUnderBudget() throws {
        let sourceData = Self.fixtureSourceData()
        XCTAssertEqual(sourceData.count, Self.expectedFixtureByteCount)
        XCTAssertLessThanOrEqual(
            abs(sourceData.count - 1_048_576),
            4 * 1_024,
            "The recovery fixture must remain bounded to approximately 1 MiB"
        )

        let originalBuildStart = ProcessInfo.processInfo.systemUptime
        let original = try DocumentProjection.build(
            sourceData: sourceData,
            renderRevision: try XCTUnwrap(
                UUID(uuidString: "00000000-0000-0000-0000-000000000001")
            )
        )
        let originalBuildDuration = ProcessInfo.processInfo.systemUptime - originalBuildStart

        XCTAssertEqual(original.source.revisionHash, Self.expectedFixtureSHA256)
        XCTAssertEqual(original.blocks.count, Self.anchorCount)

        let anchors = try original.blocks.enumerated().map { index, block in
            try Self.makeAnchor(index: index, block: block, projection: original)
        }
        XCTAssertEqual(anchors.count, Self.anchorCount)

        let currentSourceData = Data(
            ("Recovery preface inserted after capture.\n\n" + String(decoding: sourceData, as: UTF8.self)).utf8
        )
        let currentBuildStart = ProcessInfo.processInfo.systemUptime
        let current = try DocumentProjection.build(
            sourceData: currentSourceData,
            renderRevision: try XCTUnwrap(
                UUID(uuidString: "00000000-0000-0000-0000-000000000002")
            )
        )
        let currentBuildDuration = ProcessInfo.processInfo.systemUptime - currentBuildStart
        XCTAssertEqual(current.blocks.count, Self.anchorCount + 1)

        var baseline: [MemoryResolutionSnapshot]?
        for _ in 0..<3 {
            let outcomes = try Self.resolveAll(
                anchors: anchors,
                priorProjection: original,
                currentProjection: current
            )
            if let baseline {
                XCTAssertEqual(outcomes, baseline)
            } else {
                baseline = outcomes
            }
        }
        let expectedOutcomes = try XCTUnwrap(baseline)
        Self.assertResolvedAfterPrefaceInsertion(expectedOutcomes)

        var durations: [TimeInterval] = []
        durations.reserveCapacity(20)
        for _ in 0..<20 {
            let start = ProcessInfo.processInfo.systemUptime
            let outcomes = try Self.resolveAll(
                anchors: anchors,
                priorProjection: original,
                currentProjection: current
            )
            durations.append(ProcessInfo.processInfo.systemUptime - start)
            XCTAssertEqual(outcomes, expectedOutcomes)
        }

        let p95 = durations.sorted()[18]
        print(
            String(
                format: "MemoryRecoveryScale configuration=%@ original-build=%.3fs current-build=%.3fs p95=%.3fs runs=20 anchors=%d bytes=%d sha256=%@",
                Self.buildConfiguration,
                originalBuildDuration,
                currentBuildDuration,
                p95,
                anchors.count,
                sourceData.count,
                Self.expectedFixtureSHA256
            )
        )
        XCTAssertLessThan(p95, 1.0, "Warm 500-anchor recovery p95 exceeded 1 second")
    }

    func testIndexedBatchMatchesScalarResolutionForResolvedAmbiguousAndOrphanedAnchors() throws {
        let original = try DocumentProjection.build(
            sourceData: Data(
                "Unique passage stays.\n\nDuplicate passage.\n\nDuplicate passage.\n\nThis passage disappears.\n".utf8
            )
        )
        let anchors = try [
            Self.makeAnchor(
                quote: "Unique passage stays.",
                block: original.blocks[0],
                projection: original,
                identity: 1_001
            ),
            Self.makeAnchor(
                quote: "Duplicate passage.",
                block: original.blocks[1],
                projection: original,
                identity: 1_002
            ),
            Self.makeAnchor(
                quote: "This passage disappears.",
                block: original.blocks[3],
                projection: original,
                identity: 1_003
            )
        ]
        let current = try DocumentProjection.build(
            sourceData: Data(
                "Inserted preface.\n\nUnique passage stays.\n\nDuplicate passage.\n\nDuplicate passage.\n".utf8
            )
        )

        let scalar = try anchors.map { anchor in
            try MemoryAnchorResolver.resolve(
                anchor: anchor,
                priorProjection: original,
                currentProjection: current
            )
        }
        let batch = try MemoryAnchorResolver.resolveBatch(
            anchors: anchors,
            priorProjection: original,
            currentProjection: current
        )

        XCTAssertEqual(batch, scalar)
        XCTAssertEqual(batch.map(\.resolution.state), [.resolved, .ambiguous, .orphaned])
        XCTAssertEqual(batch[0].candidates.count, 1)
        XCTAssertEqual(batch[1].candidates.count, 2)
        XCTAssertTrue(batch[2].candidates.isEmpty)

        let retainedScalar = try MemoryAnchorResolver.resolve(
            anchor: anchors[0],
            priorProjection: original,
            currentProjection: current,
            currentResolution: scalar[0].resolution
        )
        let retainedBatch = try XCTUnwrap(
            MemoryAnchorResolver.resolveBatch(
                anchors: [anchors[0]],
                priorProjection: original,
                currentProjection: current,
                currentResolutionsByAnchorID: [anchors[0].id: scalar[0].resolution]
            ).first
        )
        XCTAssertEqual(retainedBatch, retainedScalar)
        XCTAssertTrue(retainedBatch.retainedCheckedResolution)
    }

    func testInitialCaptureConfirmsSelectedDuplicateWithoutRediscovery() throws {
        let projection = try DocumentProjection.build(
            sourceData: Data("Identical passage.\n\nIdentical passage.\n".utf8)
        )
        let selectedBlock = projection.blocks[0]
        let selection = try Self.selection(
            quote: "Identical passage.",
            block: selectedBlock,
            projection: projection
        )
        let anchor = try projection.makeInitialAnchor(
            memoryID: try XCTUnwrap(
                UUID(uuidString: "30000000-0000-0000-0000-000000000001")
            ),
            from: selection,
            anchorID: try XCTUnwrap(
                UUID(uuidString: "40000000-0000-0000-0000-000000000001")
            ),
            createdAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(
            try MemoryAnchorResolver.resolve(
                anchor: anchor,
                currentProjection: projection
            ).resolution.state,
            .ambiguous,
            "Automatic quote search is correctly ambiguous for duplicate passages"
        )

        let confirmed = try MemoryAnchorResolver.confirmInitialSelection(
            anchor: anchor,
            selection: selection,
            currentProjection: projection
        )
        XCTAssertEqual(confirmed.resolution.state, .resolved)
        XCTAssertEqual(confirmed.resolution.resolvedSelector?.blockID, selectedBlock.id)
        XCTAssertEqual(
            confirmed.resolution.resolvedSelector?.canonicalUTF8RangeInBlock,
            selection.canonicalUTF8RangeInBlock
        )
        XCTAssertTrue(confirmed.candidates.isEmpty)
    }

    func testPersistedSelectorReconstructionMatchesExplicitMultiRunConfirmation() throws {
        let projection = try DocumentProjection.build(
            sourceData: Data("Prefix Café and **bold text** suffix.\n".utf8)
        )
        let block = try XCTUnwrap(projection.blocks.first)
        let selection = try Self.selection(
            quote: "Café and bold text",
            block: block,
            projection: projection
        )
        let anchor = try projection.makeInitialAnchor(
            memoryID: try XCTUnwrap(
                UUID(uuidString: "50000000-0000-0000-0000-000000000001")
            ),
            from: selection,
            anchorID: try XCTUnwrap(
                UUID(uuidString: "60000000-0000-0000-0000-000000000001")
            ),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let explicitlyConfirmed = try MemoryAnchorResolver.confirmInitialSelection(
            anchor: anchor,
            selection: selection,
            currentProjection: projection
        )

        let reconstructed = try MemoryAnchorResolver.reconstructResolvedSelector(
            projection: projection,
            blockID: block.id,
            canonicalUTF8RangeInBlock: selection.canonicalUTF8RangeInBlock
        )

        XCTAssertEqual(reconstructed, explicitlyConfirmed.resolution.resolvedSelector)
        XCTAssertGreaterThan(reconstructed.runFragments.count, 1)
    }
}

private extension MemoryRecoveryScaleTests {
    static var buildConfiguration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

    static func fixtureSourceData() -> Data {
        let filler = String(repeating: "stable recovery context ", count: 42)
        let paragraphs = (0..<anchorCount).map { index in
            let token = String(format: "%03d", index)
            return "Reading memory block \(token). \(filler)Anchor \(token) is remembered exactly. \(filler)Closing context \(token)."
        }
        return Data((paragraphs.joined(separator: "\n\n") + "\n").utf8)
    }

    static func makeAnchor(
        index: Int,
        block: SemanticBlock,
        projection: DocumentProjection
    ) throws -> ConfirmedMemoryAnchor {
        let token = String(format: "%03d", index)
        return try makeAnchor(
            quote: "Anchor \(token) is remembered exactly.",
            block: block,
            projection: projection,
            identity: index + 1
        )
    }

    static func makeAnchor(
        quote: String,
        block: SemanticBlock,
        projection: DocumentProjection,
        identity: Int
    ) throws -> ConfirmedMemoryAnchor {
        let selection = try selection(
            quote: quote,
            block: block,
            projection: projection
        )
        return try projection.makeInitialAnchor(
            memoryID: try XCTUnwrap(
                UUID(
                    uuidString: String(
                        format: "10000000-0000-0000-0000-%012d",
                        identity
                    )
                )
            ),
            from: selection,
            anchorID: try XCTUnwrap(
                UUID(
                    uuidString: String(
                        format: "20000000-0000-0000-0000-%012d",
                        identity
                    )
                )
            ),
            createdAt: Date(timeIntervalSince1970: TimeInterval(identity))
        )
    }

    static func selection(
        quote: String,
        block: SemanticBlock,
        projection: DocumentProjection
    ) throws -> ProjectionSelection {
        let range = try XCTUnwrap(block.canonicalText.range(of: quote))
        let lowerBound = block.canonicalText.utf8.distance(
            from: block.canonicalText.utf8.startIndex,
            to: range.lowerBound
        )
        let upperBound = block.canonicalText.utf8.distance(
            from: block.canonicalText.utf8.startIndex,
            to: range.upperBound
        )
        let selection = ProjectionSelection(
            sourceRevisionHash: projection.source.revisionHash,
            renderRevision: projection.renderRevision,
            projectionVersion: projection.version,
            blockID: block.id,
            canonicalUTF8RangeInBlock: UTF8ByteRange(lowerBound, upperBound),
            selectedVisibleText: quote,
            runIDs: block.textRuns.map(\.id)
        )
        return selection
    }

    static func resolveAll(
        anchors: [ConfirmedMemoryAnchor],
        priorProjection: DocumentProjection,
        currentProjection: DocumentProjection
    ) throws -> [MemoryResolutionSnapshot] {
        try MemoryAnchorResolver.resolveBatch(
            anchors: anchors,
            priorProjection: priorProjection,
            currentProjection: currentProjection
        ).map(\.resolution)
    }

    static func assertResolvedAfterPrefaceInsertion(
        _ outcomes: [MemoryResolutionSnapshot],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(outcomes.count, anchorCount, file: file, line: line)
        for (index, outcome) in outcomes.enumerated() {
            XCTAssertEqual(outcome.state, .resolved, file: file, line: line)
            XCTAssertEqual(
                outcome.resolvedSelector?.blockID,
                "block-\(index + 1)",
                file: file,
                line: line
            )
            XCTAssertEqual(outcome.resolvedSelector?.runFragments.count, 1, file: file, line: line)
        }
    }
}
