import Foundation
import XCTest
@testable import MarkdownReader

final class MemoryCoordinatedWriteTests: XCTestCase {
    func testCaptureRejectsSourceReplacementBeforeStoreCommit() async throws {
        let fixture = try makeFixture()
        let prepared = try await makeCapture(in: fixture)

        try Data("# Changed\n\nThe selected passage no longer exists.\n".utf8)
            .write(to: fixture.documentURL)

        do {
            _ = try await fixture.repository.createMemory(
                prepared.request,
                verifyingSourceAt: fixture.documentURL,
                filePresenter: nil,
                expectedRevisionHash: prepared.projection.source.revisionHash
            )
            XCTFail("A capture must not commit after the coordinated source bytes change.")
        } catch {
            XCTAssertEqual(error as? MemoryStoreError, .staleSourceRevision)
        }

        XCTAssertTrue(try fixture.store.snapshot().memories.isEmpty)
    }

    func testCaptureCommitsWhileMatchingSourceIsCoordinated() async throws {
        let fixture = try makeFixture()
        let prepared = try await makeCapture(in: fixture)

        let mutation = try await fixture.repository.createMemory(
            prepared.request,
            verifyingSourceAt: fixture.documentURL,
            filePresenter: nil,
            expectedRevisionHash: prepared.projection.source.revisionHash
        )

        XCTAssertEqual(mutation.storedMemory.memory.id, prepared.request.id)
        XCTAssertEqual(try fixture.store.snapshot().memories.count, 1)
    }

    func testUndoReattachmentRejectsSourceChangeAfterCurrentProjectionValidation() async throws {
        let fixture = try makeFixture()
        let prepared = try await makeCapture(in: fixture)
        let created = try await fixture.repository.createMemory(
            prepared.request,
            verifyingSourceAt: fixture.documentURL,
            filePresenter: nil,
            expectedRevisionHash: prepared.projection.source.revisionHash
        )
        let manualAnchor = try prepared.projection.makeManualReattachment(
            superseding: prepared.anchor,
            from: prepared.selection,
            anchorID: UUID()
        )
        let manualRecovery = try MemoryAnchorResolver.confirmManualSelection(
            anchor: manualAnchor,
            selection: prepared.selection,
            currentProjection: prepared.projection
        )
        var manualResolution = try ProjectionStoreAdapter.resolutionDraft(
            from: manualRecovery,
            projection: prepared.projection
        )
        manualResolution.evidence.append(ResolutionEvidence(kind: .manualConfirmation))
        let reattached = try await fixture.repository.reattachMemory(
            memoryID: prepared.request.id,
            anchor: ProjectionStoreAdapter.newAnchor(from: manualAnchor),
            resolution: manualResolution,
            expectedMemoryRecordVersion: created.storedMemory.memory.recordVersion,
            expectedResolutionRecordVersion: created.storedMemory.resolution.recordVersion,
            expectedDocumentRecordVersion: created.undo.expectedDocumentRecordVersion,
            verifyingSourceAt: fixture.documentURL,
            filePresenter: nil,
            expectedRevisionHash: prepared.projection.source.revisionHash
        )
        let priorRecovery = try MemoryAnchorResolver.resolve(
            anchor: prepared.anchor,
            currentProjection: prepared.projection
        )
        let priorResolution = try ProjectionStoreAdapter.resolutionDraft(
            from: priorRecovery,
            projection: prepared.projection
        )

        try Data("# Changed\n\nThe validated projection is no longer current.\n".utf8)
            .write(to: fixture.documentURL)

        do {
            _ = try await fixture.repository.undoReattachment(
                reattached.undo,
                validatedResolution: priorResolution,
                expectedCurrentAnchorID: manualAnchor.id,
                verifyingSourceAt: fixture.documentURL,
                filePresenter: nil,
                expectedRevisionHash: prepared.projection.source.revisionHash
            )
            XCTFail("Undo must not commit after the coordinated source bytes change.")
        } catch {
            XCTAssertEqual(error as? MemoryStoreError, .staleSourceRevision)
        }

        let stored = try XCTUnwrap(fixture.store.memory(id: prepared.request.id))
        XCTAssertEqual(stored.memory.currentAnchorID, manualAnchor.id)
        XCTAssertEqual(stored.memory.recordVersion, reattached.storedMemory.memory.recordVersion)
        XCTAssertEqual(stored.resolution.recordVersion, reattached.storedMemory.resolution.recordVersion)
    }

    func testCoordinatedUndoAllowsUnrelatedVersionChangesWhenAnchorGenerationIsCurrent() async throws {
        let fixture = try makeFixture()
        let prepared = try await makeCapture(in: fixture)
        let created = try await fixture.repository.createMemory(
            prepared.request,
            verifyingSourceAt: fixture.documentURL,
            filePresenter: nil,
            expectedRevisionHash: prepared.projection.source.revisionHash
        )
        let manualAnchor = try prepared.projection.makeManualReattachment(
            superseding: prepared.anchor,
            from: prepared.selection,
            anchorID: UUID()
        )
        let manualRecovery = try MemoryAnchorResolver.confirmManualSelection(
            anchor: manualAnchor,
            selection: prepared.selection,
            currentProjection: prepared.projection
        )
        let manualResolution = try ProjectionStoreAdapter.resolutionDraft(
            from: manualRecovery,
            projection: prepared.projection
        )
        let reattached = try await fixture.repository.reattachMemory(
            memoryID: prepared.request.id,
            anchor: ProjectionStoreAdapter.newAnchor(from: manualAnchor),
            resolution: manualResolution,
            expectedMemoryRecordVersion: created.storedMemory.memory.recordVersion,
            expectedResolutionRecordVersion: created.storedMemory.resolution.recordVersion,
            expectedDocumentRecordVersion: created.undo.expectedDocumentRecordVersion,
            verifyingSourceAt: fixture.documentURL,
            filePresenter: nil,
            expectedRevisionHash: prepared.projection.source.revisionHash
        )
        let noteEdit = try await fixture.repository.updateNote(
            memoryID: prepared.request.id,
            noteText: "Keep this newer note",
            expectedRecordVersion: reattached.storedMemory.memory.recordVersion
        )
        let currentDocument = try XCTUnwrap(
            fixture.store.document(id: prepared.request.documentID)
        )
        let favourite = try await fixture.repository.setFavourite(
            documentID: currentDocument.id,
            isFavourite: true,
            expectedRecordVersion: currentDocument.recordVersion
        )
        let resolutionMutation = try await fixture.repository.replaceResolution(
            memoryID: prepared.request.id,
            anchorID: manualAnchor.id,
            resolution: manualResolution,
            expectedResolutionRecordVersion: reattached.storedMemory.resolution.recordVersion,
            expectedDocumentRecordVersion: favourite.document.recordVersion
        )
        XCTAssertGreaterThan(
            resolutionMutation.resolution.recordVersion,
            reattached.undo.expectedResolutionRecordVersion
        )
        let priorRecovery = try MemoryAnchorResolver.resolve(
            anchor: prepared.anchor,
            currentProjection: prepared.projection
        )
        let priorResolution = try ProjectionStoreAdapter.resolutionDraft(
            from: priorRecovery,
            projection: prepared.projection
        )

        let restored = try await fixture.repository.undoReattachment(
            reattached.undo,
            validatedResolution: priorResolution,
            expectedCurrentAnchorID: manualAnchor.id,
            verifyingSourceAt: fixture.documentURL,
            filePresenter: nil,
            expectedRevisionHash: prepared.projection.source.revisionHash
        )

        XCTAssertEqual(restored.memory.currentAnchorID, prepared.anchor.id)
        XCTAssertEqual(restored.memory.noteText, noteEdit.memory.noteText)
        XCTAssertEqual(restored.resolution.anchorID, prepared.anchor.id)
    }

    func testRestoreAsNewRequiresExplicitProposalAndRevalidatesRegisteredSource() async throws {
        let fixture = try makeFixture()
        let prepared = try await makeCapture(in: fixture)
        let created = try await fixture.repository.createMemory(
            prepared.request,
            verifyingSourceAt: fixture.documentURL,
            filePresenter: nil,
            expectedRevisionHash: prepared.projection.source.revisionHash
        )
        let deleted = try await fixture.repository.deleteMemory(
            memoryID: created.storedMemory.memory.id,
            expectedRecordVersion: created.storedMemory.memory.recordVersion
        )
        let document = try XCTUnwrap(
            fixture.store.document(id: created.storedMemory.memory.documentID)
        )
        let favourite = try fixture.store.setFavourite(
            documentID: document.id,
            isFavourite: true,
            expectedRecordVersion: document.recordVersion
        )

        do {
            _ = try await fixture.repository.restoreDeletedMemory(deleted)
            XCTFail("Exact undo must retain its original optimistic precondition.")
        } catch {
            XCTAssertEqual(
                error as? MemoryStoreError,
                .versionConflict(
                    entity: .document,
                    expected: document.recordVersion,
                    actual: favourite.document.recordVersion
                )
            )
        }

        let proposal = try await fixture.repository.prepareRestoreDeletedMemoryAsNew(
            deleted,
            sourceURL: fixture.documentURL,
            filePresenter: nil
        )
        XCTAssertEqual(
            proposal.request.expectedDocumentRecordVersion,
            favourite.document.recordVersion
        )
        XCTAssertEqual(proposal.expectedRevisionHash, prepared.projection.source.revisionHash)

        let restored = try await fixture.repository.restoreDeletedMemoryAsNew(proposal)
        XCTAssertNotEqual(restored.memory.id, deleted.storedMemory.memory.id)
        XCTAssertEqual(restored.memory.documentID, document.id)
        XCTAssertEqual(restored.memory.originalVisibleQuote, deleted.storedMemory.memory.originalVisibleQuote)
        XCTAssertEqual(try fixture.store.snapshot().memories.map(\.memory.id), [restored.memory.id])
    }

    func testRestoreAsNewRejectsSameBytesAtReplacementIdentityAfterConfirmation() async throws {
        let fixture = try makeFixture()
        let prepared = try await makeCapture(in: fixture)
        let created = try await fixture.repository.createMemory(
            prepared.request,
            verifyingSourceAt: fixture.documentURL,
            filePresenter: nil,
            expectedRevisionHash: prepared.projection.source.revisionHash
        )
        let deleted = try await fixture.repository.deleteMemory(
            memoryID: created.storedMemory.memory.id,
            expectedRecordVersion: created.storedMemory.memory.recordVersion
        )
        let document = try XCTUnwrap(
            fixture.store.document(id: created.storedMemory.memory.documentID)
        )
        _ = try fixture.store.setFavourite(
            documentID: document.id,
            isFavourite: true,
            expectedRecordVersion: document.recordVersion
        )
        let proposal = try await fixture.repository.prepareRestoreDeletedMemoryAsNew(
            deleted,
            sourceURL: fixture.documentURL,
            filePresenter: nil
        )

        let matchingBytes = try Data(contentsOf: fixture.documentURL)
        let replacementURL = fixture.directory.appendingPathComponent("Replacement.md")
        try matchingBytes.write(to: replacementURL)
        try FileManager.default.removeItem(at: fixture.documentURL)
        try FileManager.default.moveItem(at: replacementURL, to: fixture.documentURL)
        XCTAssertNotEqual(
            try DocumentIdentityProbe.observe(fixture.documentURL).identity,
            proposal.expectedFileIdentity
        )

        do {
            _ = try await fixture.repository.restoreDeletedMemoryAsNew(proposal)
            XCTFail("Confirmation must not authorize a replacement file, even when its bytes match.")
        } catch {
            XCTAssertEqual(error as? MemoryStoreError, .staleSourceIdentity)
        }
        XCTAssertTrue(try fixture.store.snapshot().memories.isEmpty)
    }
}

private extension MemoryCoordinatedWriteTests {
    struct Fixture {
        let directory: URL
        let documentURL: URL
        let store: SQLiteMemoryStore
        let repository: MemoryRepository
        let defaults: UserDefaults
    }

    struct PreparedCapture {
        let projection: DocumentProjection
        let selection: ProjectionSelection
        let anchor: ConfirmedMemoryAnchor
        let request: CreateMemoryRequest
    }

    func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownReader-CoordinatedWrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let documentURL = directory.appendingPathComponent("Document.md")
        try Data("# Heading\n\nA passage selected for Reading Memory.\n".utf8)
            .write(to: documentURL)
        let store = try SQLiteMemoryStore(
            databaseURL: directory.appendingPathComponent("ReadingMemory.sqlite3")
        )
        let suiteName = "MarkdownReader.CoordinatedWrite.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let repository = MemoryRepository(
            store: store,
            legacyReadingPositionDefaults: defaults
        )
        addTeardownBlock {
            try? store.dbPool.close()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        return Fixture(
            directory: directory,
            documentURL: documentURL,
            store: store,
            repository: repository,
            defaults: defaults
        )
    }

    func makeCapture(in fixture: Fixture) async throws -> PreparedCapture {
        let data = try Data(contentsOf: fixture.documentURL)
        let projection = try DocumentProjection.build(
            sourceData: data,
            documentURL: fixture.documentURL
        )
        let registered = try await fixture.repository.openDocument(
            at: fixture.documentURL,
            source: projection.source
        )
        let block = try XCTUnwrap(projection.blocks.first { $0.kind == .paragraph })
        let selection = ProjectionSelection(
            sourceRevisionHash: projection.source.revisionHash,
            renderRevision: projection.renderRevision,
            projectionVersion: projection.version,
            blockID: block.id,
            canonicalUTF8RangeInBlock: UTF8ByteRange(0, block.canonicalUTF8Count),
            selectedVisibleText: block.canonicalText,
            runIDs: block.textRuns.map(\.id)
        )
        let memoryID = UUID()
        let anchor = try projection.makeInitialAnchor(memoryID: memoryID, from: selection)
        let recovery = try MemoryAnchorResolver.resolve(
            anchor: anchor,
            currentProjection: projection
        )
        let resolution = try ProjectionStoreAdapter.resolutionDraft(
            from: recovery,
            projection: projection
        )
        return PreparedCapture(
            projection: projection,
            selection: selection,
            anchor: anchor,
            request: CreateMemoryRequest(
                id: memoryID,
                documentID: registered.document.id,
                kind: .passage,
                originalVisibleQuote: selection.selectedVisibleText,
                canonicalMatchQuote: anchor.exactQuote,
                noteText: nil,
                expectedDocumentRecordVersion: registered.document.recordVersion,
                anchor: ProjectionStoreAdapter.newAnchor(from: anchor),
                resolution: resolution
            )
        )
    }
}
