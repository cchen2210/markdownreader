import XCTest
@testable import MarkdownReader

@MainActor
final class MemoryRepairSessionTests: XCTestCase {
    func testAmbiguousChooserStartsWithNothingSelectedAndCancelDoesNotWrite() throws {
        let fixture = try makeAmbiguousFixture()
        var writeCount = 0
        let session = try makeSession(fixture: fixture) { _ in
            writeCount += 1
            throw TestError.unexpectedWrite
        }

        XCTAssertEqual(session.mode, .chooseLocation)
        XCTAssertEqual(session.candidates.count, 2)
        XCTAssertNil(session.selectedCandidateID)
        XCTAssertFalse(session.canUseSelectedCandidate)

        session.selectCandidate(id: try XCTUnwrap(session.candidates.first?.id))
        XCTAssertTrue(session.canUseSelectedCandidate)
        session.cancel()

        XCTAssertTrue(session.isCancelled)
        XCTAssertNil(session.selectedCandidateID)
        XCTAssertEqual(writeCount, 0)
    }

    func testCandidateAcceptanceRechecksAndCreatesManualGenerationWithUndo() async throws {
        let fixture = try makeAmbiguousFixture()
        let anchorID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000002")!
        var capturedRequest: MemoryRepairWriteRequest?
        let session = try makeSession(
            fixture: fixture,
            anchorID: anchorID,
            write: { request in
                capturedRequest = request
                return self.mutation(for: request, replacing: fixture.stored, document: fixture.document)
            }
        )
        session.selectCandidate(id: try XCTUnwrap(session.candidates.last?.id))

        let commit = await session.commitSelectedCandidate()

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.anchor.id, anchorID)
        XCTAssertEqual(request.anchor.confirmation, .manualReattach)
        XCTAssertEqual(request.anchor.supersedesAnchorID, fixture.stored.memory.currentAnchorID)
        XCTAssertEqual(request.resolution.state, .resolved)
        XCTAssertTrue(request.resolution.evidence.contains { $0.kind == .manualConfirmation })
        XCTAssertEqual(commit?.undo.previousAnchorID, fixture.stored.memory.currentAnchorID)
        XCTAssertEqual(commit?.storedMemory.anchors.count, 2)
        XCTAssertTrue(session.didCommit)
    }

    func testOrphanUsesExplicitDOMSelectionAndRevalidatesBeforeWrite() async throws {
        let fixture = try makeOrphanFixture()
        let domSelection = try domSelection(
            for: "Replacement passage",
            in: fixture.projection
        )
        var sourceChecks = 0
        var capturedRequest: MemoryRepairWriteRequest?
        let dependencies = MemoryRepairDependencies(
            captureDOMSelection: { domSelection },
            sourceMatchesRevision: { revision in
                sourceChecks += 1
                return revision == fixture.projection.source.revisionHash
            },
            reattachMemory: { request in
                capturedRequest = request
                return self.mutation(for: request, replacing: fixture.stored, document: fixture.document)
            },
            undoReattachment: { _ in throw TestError.unexpectedWrite },
            makeAnchorID: { UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000003")! },
            now: { Date(timeIntervalSince1970: 3_000) }
        )
        let session = try MemoryRepairSession(
            storedMemory: fixture.stored,
            document: fixture.document,
            documentMemories: [fixture.stored],
            projection: fixture.projection,
            dependencies: dependencies
        )

        XCTAssertEqual(session.mode, .reattachLooseSlip)
        XCTAssertFalse(session.canUseCurrentSelection)
        await session.captureCurrentSelection()
        XCTAssertEqual(session.pendingSelectionQuote, "Replacement passage")
        XCTAssertTrue(session.canUseCurrentSelection)

        let commit = await session.commitCurrentSelection()

        XCTAssertEqual(sourceChecks, 2, "Selection check and commit must each recheck exact bytes")
        XCTAssertEqual(capturedRequest?.anchor.exactQuote, "Replacement passage")
        XCTAssertEqual(capturedRequest?.anchor.confirmation, .manualReattach)
        XCTAssertEqual(
            commit?.storedMemory.memory.originalVisibleQuote,
            "Original saved passage",
            "Repair must retain the immutable saved passage text"
        )
        XCTAssertNotNil(commit?.undo)
    }

    func testOrphanCancelClearsEphemeralSelectionWithoutWriting() async throws {
        let fixture = try makeOrphanFixture()
        let domSelection = try domSelection(for: "Replacement passage", in: fixture.projection)
        var writeCount = 0
        let dependencies = MemoryRepairDependencies(
            captureDOMSelection: { domSelection },
            sourceMatchesRevision: { _ in true },
            reattachMemory: { _ in
                writeCount += 1
                throw TestError.unexpectedWrite
            },
            undoReattachment: { _ in throw TestError.unexpectedWrite }
        )
        let session = try MemoryRepairSession(
            storedMemory: fixture.stored,
            document: fixture.document,
            documentMemories: [fixture.stored],
            projection: fixture.projection,
            dependencies: dependencies
        )

        await session.captureCurrentSelection()
        XCTAssertNotNil(session.pendingSelectionQuote)
        session.cancel()
        let commit = await session.commitCurrentSelection()

        XCTAssertNil(commit)
        XCTAssertNil(session.pendingSelectionQuote)
        XCTAssertEqual(writeCount, 0)
    }

    func testOrphanOverlapIsRejectedBeforeUseSelectionIsEnabled() async throws {
        let fixture = try makeOrphanFixture()
        let overlapping = try resolvedStoredMemory(
            quote: "Replacement passage",
            projection: fixture.projection,
            documentID: fixture.document.id
        )
        let domSelection = try domSelection(for: "Replacement passage", in: fixture.projection)
        var writeCount = 0
        let dependencies = MemoryRepairDependencies(
            captureDOMSelection: { domSelection },
            sourceMatchesRevision: { _ in true },
            reattachMemory: { _ in
                writeCount += 1
                throw TestError.unexpectedWrite
            },
            undoReattachment: { _ in throw TestError.unexpectedWrite }
        )
        let session = try MemoryRepairSession(
            storedMemory: fixture.stored,
            document: fixture.document,
            documentMemories: [fixture.stored, overlapping],
            projection: fixture.projection,
            dependencies: dependencies
        )

        await session.captureCurrentSelection()

        XCTAssertNil(session.pendingSelectionQuote)
        XCTAssertFalse(session.canUseCurrentSelection)
        XCTAssertEqual(session.errorMessage, DocumentProjectionError.overlappingSelection.errorDescription)
        XCTAssertEqual(writeCount, 0)
    }

    func testUndoRebuildsCurrentProjectionAndValidatesPriorImmutableAnchor() async throws {
        let fixture = try makeAmbiguousFixture()
        let currentProjection = try DocumentProjection.build(
            sourceData: Data("# Trust\n\nRepeated memory\n\nCurrent context".utf8)
        )
        let sourceURL = URL(fileURLWithPath: "/tmp/Current-Undo.md")
        var capturedRequest: MemoryRepairUndoWriteRequest?
        let (session, commit) = try await makeCommittedUndoSession(
            fixture: fixture,
            currentProjection: currentProjection,
            sourceURL: sourceURL
        ) { request, committed in
            capturedRequest = request
            return self.restoredMemory(for: request, replacing: committed)
        }

        let restored = await session.undo(commit.undo)

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.payload, commit.undo)
        XCTAssertEqual(request.expectedCurrentAnchorID, repairAnchorID)
        XCTAssertEqual(request.sourceURL, sourceURL)
        XCTAssertEqual(request.expectedRevisionHash, currentProjection.source.revisionHash)
        XCTAssertEqual(
            request.validatedResolution.checkedRevisionHash,
            currentProjection.source.revisionHash
        )
        XCTAssertEqual(request.validatedResolution.state, .resolved)
        XCTAssertEqual(
            request.validatedResolution.resolvedSelector?.sourceRevisionHash,
            currentProjection.source.revisionHash
        )
        XCTAssertEqual(restored?.memory.currentAnchorID, commit.undo.previousAnchorID)
        XCTAssertFalse(session.didCommit)
        XCTAssertNil(session.errorMessage)
    }

    func testUndoRefusesWhenCurrentAnchorGenerationChangedBeforeProjectionLoad() async throws {
        let fixture = try makeAmbiguousFixture()
        var projectionLoadCount = 0
        var undoWriteCount = 0
        let (session, commit) = try await makeCommittedUndoSession(
            fixture: fixture,
            currentProjection: fixture.projection,
            sourceURL: URL(fileURLWithPath: "/tmp/Changed-Generation.md"),
            latestAnchorID: UUID(),
            onProjectionLoad: { projectionLoadCount += 1 }
        ) { _, _ in
            undoWriteCount += 1
            throw TestError.unexpectedWrite
        }

        let restored = await session.undo(commit.undo)

        XCTAssertNil(restored)
        XCTAssertEqual(projectionLoadCount, 0)
        XCTAssertEqual(undoWriteCount, 0)
        XCTAssertEqual(
            session.errorMessage,
            MemoryRepairError.anchorGenerationChanged.errorDescription
        )
        XCTAssertTrue(session.didCommit)
    }

    func testUndoFinalCoordinatedHashMismatchLeavesReattachedGenerationCurrent() async throws {
        let fixture = try makeAmbiguousFixture()
        let currentProjection = try DocumentProjection.build(
            sourceData: Data("# Trust\n\nRepeated memory\n\nCurrent bytes".utf8)
        )
        var capturedRequest: MemoryRepairUndoWriteRequest?
        let (session, commit) = try await makeCommittedUndoSession(
            fixture: fixture,
            currentProjection: currentProjection,
            sourceURL: URL(fileURLWithPath: "/tmp/Changed-Before-Commit.md")
        ) { request, _ in
            capturedRequest = request
            // Mirrors the repository's final coordinated byte-hash gate when
            // the source changes after projection load but before commit.
            throw MemoryStoreError.staleSourceRevision
        }

        let restored = await session.undo(commit.undo)

        XCTAssertNil(restored)
        XCTAssertEqual(capturedRequest?.expectedRevisionHash, currentProjection.source.revisionHash)
        XCTAssertEqual(session.errorMessage, MemoryStoreError.staleSourceRevision.errorDescription)
        XCTAssertTrue(session.didCommit)
    }

    func testUndoPreservesOptimisticVersionConflictBehavior() async throws {
        let fixture = try makeAmbiguousFixture()
        let expectedConflict = MemoryStoreError.versionConflict(
            entity: .memory,
            expected: 2,
            actual: 3
        )
        let (session, commit) = try await makeCommittedUndoSession(
            fixture: fixture,
            currentProjection: fixture.projection,
            sourceURL: URL(fileURLWithPath: "/tmp/Version-Conflict.md")
        ) { _, _ in
            throw expectedConflict
        }

        let restored = await session.undo(commit.undo)

        XCTAssertNil(restored)
        XCTAssertEqual(session.errorMessage, expectedConflict.errorDescription)
        XCTAssertTrue(session.didCommit)
    }

    private struct Fixture {
        let projection: DocumentProjection
        let document: DocumentRecord
        let stored: StoredMemory
    }

    private enum TestError: Error {
        case unexpectedWrite
    }

    private var repairAnchorID: UUID {
        UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000099")!
    }

    private func makeAmbiguousFixture() throws -> Fixture {
        let oldProjection = try DocumentProjection.build(
            sourceData: Data("# Trust\n\nRepeated memory".utf8)
        )
        let currentProjection = try DocumentProjection.build(
            sourceData: Data("# Trust\n\nRepeated memory\n\nRepeated memory".utf8)
        )
        let initial = try oldProjection.makeInitialAnchor(
            memoryID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000010")!,
            from: selection(for: oldProjection.blocks[1], in: oldProjection),
            anchorID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000011")!,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        return fixture(
            currentProjection: currentProjection,
            initialAnchor: initial,
            state: .ambiguous
        )
    }

    private func makeOrphanFixture() throws -> Fixture {
        let oldProjection = try DocumentProjection.build(
            sourceData: Data("# Trust\n\nOriginal saved passage".utf8)
        )
        let currentProjection = try DocumentProjection.build(
            sourceData: Data("# Trust\n\nReplacement passage".utf8)
        )
        let initial = try oldProjection.makeInitialAnchor(
            memoryID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000020")!,
            from: selection(for: oldProjection.blocks[1], in: oldProjection),
            anchorID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000021")!,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        return fixture(
            currentProjection: currentProjection,
            initialAnchor: initial,
            state: .orphaned
        )
    }

    private func fixture(
        currentProjection: DocumentProjection,
        initialAnchor: ConfirmedMemoryAnchor,
        state: MemoryResolutionState
    ) -> Fixture {
        let documentID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-000000000001")!
        let document = DocumentRecord(
            id: documentID,
            displayName: "Reading.md",
            bookmarkData: nil,
            fileIdentity: FileIdentity(),
            lastConfirmedContentHash: currentProjection.source.revisionHash,
            detectedTextEncoding: "utf8",
            hadByteOrderMark: false,
            availability: .available,
            isFavourite: false,
            recordVersion: 1,
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastOpenedAt: Date(timeIntervalSince1970: 2_000),
            lastSeenAt: Date(timeIntervalSince1970: 2_000)
        )
        let memory = ReadingMemoryRecord(
            id: initialAnchor.memoryID,
            documentID: documentID,
            kind: .passage,
            originalVisibleQuote: initialAnchor.exactQuote,
            canonicalMatchQuote: initialAnchor.exactQuote,
            noteText: nil,
            createdAt: initialAnchor.createdAt,
            updatedAt: initialAnchor.createdAt,
            recordVersion: 1,
            originalAnchorID: initialAnchor.id,
            currentAnchorID: initialAnchor.id
        )
        let stored = StoredMemory(
            memory: memory,
            anchors: [record(initialAnchor)],
            resolution: CurrentResolutionRecord(
                memoryID: memory.id,
                anchorID: initialAnchor.id,
                state: state,
                checkedRevisionHash: currentProjection.source.revisionHash,
                resolverPolicyVersion: MemoryAnchorResolver.policyVersion,
                resolvedSelector: nil,
                evidence: [],
                lastCheckedAt: Date(timeIntervalSince1970: 2_000),
                recordVersion: 1
            ),
            history: []
        )
        return Fixture(projection: currentProjection, document: document, stored: stored)
    }

    private func makeSession(
        fixture: Fixture,
        anchorID: UUID = UUID(),
        write: @escaping (MemoryRepairWriteRequest) async throws -> ReattachmentMutation
    ) throws -> MemoryRepairSession {
        try MemoryRepairSession(
            storedMemory: fixture.stored,
            document: fixture.document,
            documentMemories: [fixture.stored],
            projection: fixture.projection,
            dependencies: MemoryRepairDependencies(
                captureDOMSelection: { throw TestError.unexpectedWrite },
                sourceMatchesRevision: { _ in true },
                reattachMemory: write,
                undoReattachment: { _ in throw TestError.unexpectedWrite },
                makeAnchorID: { anchorID },
                now: { Date(timeIntervalSince1970: 3_000) }
            )
        )
    }

    private func makeCommittedUndoSession(
        fixture: Fixture,
        currentProjection: DocumentProjection,
        sourceURL: URL,
        latestAnchorID: UUID? = nil,
        onProjectionLoad: @escaping () -> Void = {},
        undo: @escaping (MemoryRepairUndoWriteRequest, StoredMemory) async throws -> StoredMemory
    ) async throws -> (MemoryRepairSession, MemoryRepairCommit) {
        var committedStored: StoredMemory?
        let expectedCurrentAnchorID = latestAnchorID ?? repairAnchorID
        let session = try MemoryRepairSession(
            storedMemory: fixture.stored,
            document: fixture.document,
            documentMemories: [fixture.stored],
            projection: fixture.projection,
            dependencies: MemoryRepairDependencies(
                captureDOMSelection: { throw TestError.unexpectedWrite },
                sourceMatchesRevision: { _ in true },
                reattachMemory: { request in
                    let mutation = self.mutation(
                        for: request,
                        replacing: fixture.stored,
                        document: fixture.document
                    )
                    committedStored = mutation.storedMemory
                    return mutation
                },
                loadCurrentProjection: {
                    onProjectionLoad()
                    return MemoryRepairProjectionSnapshot(
                        sourceURL: sourceURL,
                        projection: currentProjection
                    )
                },
                currentAnchorID: { _ in expectedCurrentAnchorID },
                undoReattachment: { request in
                    try await undo(request, try XCTUnwrap(committedStored))
                },
                makeAnchorID: { self.repairAnchorID },
                now: { Date(timeIntervalSince1970: 3_000) }
            )
        )
        session.selectCandidate(id: try XCTUnwrap(session.candidates.last?.id))
        let pendingCommit = await session.commitSelectedCandidate()
        let commit = try XCTUnwrap(pendingCommit)
        return (session, commit)
    }

    private func restoredMemory(
        for request: MemoryRepairUndoWriteRequest,
        replacing committed: StoredMemory
    ) -> StoredMemory {
        var memory = committed.memory
        memory.currentAnchorID = request.payload.previousAnchorID
        memory.updatedAt = request.validatedResolution.lastCheckedAt
        memory.recordVersion += 1
        let resolution = CurrentResolutionRecord(
            memoryID: memory.id,
            anchorID: request.payload.previousAnchorID,
            state: request.validatedResolution.state,
            checkedRevisionHash: request.validatedResolution.checkedRevisionHash,
            resolverPolicyVersion: request.validatedResolution.resolverPolicyVersion,
            resolvedSelector: request.validatedResolution.resolvedSelector,
            evidence: request.validatedResolution.evidence,
            lastCheckedAt: request.validatedResolution.lastCheckedAt,
            recordVersion: committed.resolution.recordVersion + 1
        )
        return StoredMemory(
            memory: memory,
            anchors: committed.anchors,
            resolution: resolution,
            history: committed.history
        )
    }

    private func mutation(
        for request: MemoryRepairWriteRequest,
        replacing previous: StoredMemory,
        document: DocumentRecord
    ) -> ReattachmentMutation {
        var memory = previous.memory
        memory.currentAnchorID = request.anchor.id
        memory.updatedAt = request.anchor.createdAt
        memory.recordVersion += 1
        let resolution = CurrentResolutionRecord(
            memoryID: memory.id,
            anchorID: request.anchor.id,
            state: request.resolution.state,
            checkedRevisionHash: request.resolution.checkedRevisionHash,
            resolverPolicyVersion: request.resolution.resolverPolicyVersion,
            resolvedSelector: request.resolution.resolvedSelector,
            evidence: request.resolution.evidence,
            lastCheckedAt: request.resolution.lastCheckedAt,
            recordVersion: previous.resolution.recordVersion + 1
        )
        let stored = StoredMemory(
            memory: memory,
            anchors: previous.anchors + [record(request.anchor, memoryID: memory.id)],
            resolution: resolution,
            history: previous.history
        )
        return ReattachmentMutation(
            storedMemory: stored,
            undo: ReattachmentUndoPayload(
                memoryID: memory.id,
                previousAnchorID: previous.memory.currentAnchorID!,
                previousResolution: previous.resolution,
                expectedDocumentRecordVersion: document.recordVersion,
                expectedMemoryRecordVersion: memory.recordVersion,
                expectedResolutionRecordVersion: resolution.recordVersion
            )
        )
    }

    private func resolvedStoredMemory(
        quote: String,
        projection: DocumentProjection,
        documentID: UUID
    ) throws -> StoredMemory {
        let block = try XCTUnwrap(projection.blocks.first { $0.canonicalText == quote })
        let anchor = try projection.makeInitialAnchor(
            memoryID: UUID(),
            from: selection(for: block, in: projection)
        )
        let recovery = try MemoryAnchorResolver.resolve(
            anchor: anchor,
            currentProjection: projection
        )
        let draft = try ProjectionStoreAdapter.resolutionDraft(from: recovery, projection: projection)
        let memory = ReadingMemoryRecord(
            id: anchor.memoryID,
            documentID: documentID,
            kind: .passage,
            originalVisibleQuote: quote,
            canonicalMatchQuote: quote,
            noteText: nil,
            createdAt: Date(),
            updatedAt: Date(),
            recordVersion: 1,
            originalAnchorID: anchor.id,
            currentAnchorID: anchor.id
        )
        return StoredMemory(
            memory: memory,
            anchors: [record(anchor)],
            resolution: CurrentResolutionRecord(
                memoryID: memory.id,
                anchorID: anchor.id,
                state: draft.state,
                checkedRevisionHash: draft.checkedRevisionHash,
                resolverPolicyVersion: draft.resolverPolicyVersion,
                resolvedSelector: draft.resolvedSelector,
                evidence: draft.evidence,
                lastCheckedAt: draft.lastCheckedAt,
                recordVersion: 1
            ),
            history: []
        )
    }

    private func selection(
        for block: SemanticBlock,
        in projection: DocumentProjection
    ) -> ProjectionSelection {
        ProjectionSelection(
            sourceRevisionHash: projection.source.revisionHash,
            renderRevision: projection.renderRevision,
            projectionVersion: projection.version,
            blockID: block.id,
            canonicalUTF8RangeInBlock: UTF8ByteRange(0, block.canonicalUTF8Count),
            selectedVisibleText: block.canonicalText,
            runIDs: block.textRuns.map(\.id)
        )
    }

    private func domSelection(
        for quote: String,
        in projection: DocumentProjection
    ) throws -> DOMProjectionSelection {
        let block = try XCTUnwrap(projection.blocks.first { $0.canonicalText == quote })
        let first = try XCTUnwrap(block.textRuns.first)
        let last = try XCTUnwrap(block.textRuns.last)
        return DOMProjectionSelection(
            sourceRevisionHash: projection.source.revisionHash,
            renderRevision: projection.renderRevision,
            projectionVersion: projection.version,
            blockID: block.id,
            start: DOMProjectionPoint(runID: first.id, utf16Offset: 0),
            end: DOMProjectionPoint(runID: last.id, utf16Offset: last.domText.utf16.count),
            selectedVisibleText: quote
        )
    }

    private func record(_ anchor: ConfirmedMemoryAnchor) -> ConfirmedAnchorRecord {
        record(ProjectionStoreAdapter.newAnchor(from: anchor), memoryID: anchor.memoryID)
    }

    private func record(
        _ anchor: NewConfirmedAnchor,
        memoryID: UUID
    ) -> ConfirmedAnchorRecord {
        ConfirmedAnchorRecord(
            id: anchor.id,
            memoryID: memoryID,
            supersedesAnchorID: anchor.supersedesAnchorID,
            confirmation: anchor.confirmation,
            createdAt: anchor.createdAt,
            selectorVersion: anchor.selectorVersion,
            projectionVersion: anchor.projectionVersion,
            sourceRevisionHash: anchor.sourceRevisionHash,
            resolverPolicyVersion: anchor.resolverPolicyVersion,
            exactQuote: anchor.exactQuote,
            prefix: anchor.prefix,
            suffix: anchor.suffix,
            canonicalTextPosition: anchor.canonicalTextPosition,
            canonicalUTF8RangeInBlock: anchor.canonicalUTF8RangeInBlock,
            blockKind: anchor.blockKind,
            blockFingerprint: anchor.blockFingerprint,
            headingPath: anchor.headingPath,
            blockOrdinal: anchor.blockOrdinal,
            blockFingerprintOccurrenceCountInSection: anchor.blockFingerprintOccurrenceCountInSection,
            sourceUTF8Span: anchor.sourceUTF8Span
        )
    }
}
