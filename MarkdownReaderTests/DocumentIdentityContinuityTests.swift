import Darwin
import Foundation
import XCTest
@testable import MarkdownReader

final class DocumentIdentityContinuityTests: XCTestCase {
    func testActiveSamePathAtomicReplacementPreservesDocumentUUID() async throws {
        let fixture = try makeFixture()
        let documentURL = fixture.directory.appendingPathComponent("Atomic.md")
        try write("# Before\n\nOriginal passage.", to: documentURL)
        let originalProjection = try projection(at: documentURL)
        let registered = try await fixture.repository.openDocument(
            at: documentURL,
            source: originalProjection.source
        )
        let originalIdentity = registered.document.fileIdentity

        try atomicallyReplace(
            documentURL,
            with: "# After\n\nReplacement passage with a new inode."
        )
        let replacementProjection = try projection(at: documentURL)
        let replacementIdentity = try DocumentIdentityProbe.observe(documentURL).identity
        XCTAssertNotEqual(replacementIdentity, originalIdentity)

        let reopened = try await fixture.repository.openDocument(
            at: documentURL,
            source: replacementProjection.source,
            activeDocumentID: registered.document.id
        )

        XCTAssertEqual(reopened.document.id, registered.document.id)
        XCTAssertEqual(reopened.document.fileIdentity, replacementIdentity)
        XCTAssertEqual(
            reopened.document.lastConfirmedContentHash,
            replacementProjection.source.revisionHash
        )
        let snapshot = try fixture.store.snapshot()
        XCTAssertEqual(snapshot.documents.map(\.id), [registered.document.id])
        XCTAssertEqual(
            snapshot.documentLocations.filter(\.isCurrent).map { $0.url.standardizedFileURL },
            [documentURL.standardizedFileURL]
        )
    }

    func testColdOpenAtRegisteredPathWithChangedIdentityRequiresDecisionWithoutBinding() async throws {
        let fixture = try makeFixture()
        let documentURL = fixture.directory.appendingPathComponent("Collision.md")
        try write("# Registered\n\nOriginal bytes.", to: documentURL)
        let originalProjection = try projection(at: documentURL)
        let registered = try await fixture.repository.openDocument(
            at: documentURL,
            source: originalProjection.source
        )
        let before = try fixture.store.snapshotWithSequence()

        try atomicallyReplace(
            documentURL,
            with: "# Collision\n\nUnrelated replacement bytes."
        )
        let candidateProjection = try projection(at: documentURL)
        let coldRepository = MemoryRepository(
            store: fixture.store,
            legacyReadingPositionDefaults: fixture.defaults
        )

        do {
            _ = try await coldRepository.openDocument(
                at: documentURL,
                source: candidateProjection.source
            )
            XCTFail("A cold path collision must require an explicit identity decision.")
        } catch let error as DocumentIdentityDecisionRequiredError {
            let decision = error.decision
            XCTAssertEqual(decision.registeredDocumentID, registered.document.id)
            XCTAssertEqual(decision.registeredPath.standardizedFileURL, documentURL.standardizedFileURL)
            XCTAssertEqual(decision.candidatePath.standardizedFileURL, documentURL.standardizedFileURL)
            XCTAssertNotEqual(
                decision.storedIdentityFingerprint,
                decision.candidateIdentityFingerprint
            )
            XCTAssertEqual(
                decision.storedContentHash,
                originalProjection.source.revisionHash
            )
            XCTAssertEqual(
                decision.candidateContentHash,
                candidateProjection.source.revisionHash
            )
            XCTAssertTrue(decision.identityMatchedDocumentIDs.isEmpty)
        }

        let after = try fixture.store.snapshotWithSequence()
        XCTAssertEqual(after, before)
    }

    func testConfirmedRelinkRequiresStagedEvidenceAndPreservesDocumentAndMemoryIDs() async throws {
        let fixture = try makeFixture()
        let sourceText = "# Notes\n\nRemember this passage."
        let oldURL = fixture.directory.appendingPathComponent("Old.md")
        let candidateURL = fixture.directory.appendingPathComponent("Located.md")
        try write(sourceText, to: oldURL)
        try write(sourceText, to: candidateURL)
        let oldProjection = try projection(at: oldURL)
        let registered = try await fixture.repository.openDocument(
            at: oldURL,
            source: oldProjection.source
        )
        let memoryID = try createPassageMemory(
            projection: oldProjection,
            document: registered.document,
            store: fixture.store
        )
        let sequenceBeforeStage = try fixture.store.currentSequence()

        let proposal = try await fixture.repository.stageDocumentRelink(
            documentID: registered.document.id,
            to: candidateURL
        )

        XCTAssertTrue(proposal.canConfirm)
        XCTAssertFalse(proposal.identitiesMatch)
        XCTAssertTrue(proposal.hashesMatch)
        XCTAssertEqual(proposal.recovery.memoryCount, 1)
        XCTAssertEqual(proposal.recovery.resolvedCount, 1)
        XCTAssertEqual(proposal.recovery.ambiguousCount, 0)
        XCTAssertEqual(proposal.recovery.needsReviewCount, 0)
        XCTAssertEqual(proposal.recovery.orphanedCount, 0)
        XCTAssertEqual(proposal.recovery.invalidAnchorCount, 0)
        XCTAssertEqual(try fixture.store.currentSequence(), sequenceBeforeStage)
        XCTAssertEqual(
            try currentURL(for: registered.document.id, in: fixture.store),
            oldURL.standardizedFileURL
        )

        let confirmed = try await fixture.repository.confirmDocumentRelink(
            proposalID: proposal.id
        )

        XCTAssertEqual(confirmed.id, registered.document.id)
        XCTAssertEqual(
            confirmed.fileIdentity,
            try DocumentIdentityProbe.observe(candidateURL).identity
        )
        XCTAssertEqual(
            try currentURL(for: registered.document.id, in: fixture.store),
            candidateURL.standardizedFileURL
        )
        let snapshot = try fixture.store.snapshot()
        XCTAssertEqual(snapshot.documents.map(\.id), [registered.document.id])
        XCTAssertEqual(snapshot.memories.map { $0.memory.id }, [memoryID])
    }

    func testNewFileWithIdenticalBytesStillReceivesNewIdentityAndUUID() async throws {
        let fixture = try makeFixture()
        let sourceText = "# Copy\n\nIdentical bytes are not identity."
        let firstURL = fixture.directory.appendingPathComponent("First.md")
        let secondURL = fixture.directory.appendingPathComponent("Second.md")
        try write(sourceText, to: firstURL)
        try write(sourceText, to: secondURL)

        let first = try await fixture.repository.openDocument(
            at: firstURL,
            source: try projection(at: firstURL).source
        )
        let second = try await fixture.repository.openDocument(
            at: secondURL,
            source: try projection(at: secondURL).source
        )

        XCTAssertNotEqual(first.document.id, second.document.id)
        XCTAssertNotEqual(first.document.fileIdentity, second.document.fileIdentity)
        XCTAssertEqual(first.document.lastConfirmedContentHash, second.document.lastConfirmedContentHash)
        XCTAssertEqual(Set(try fixture.store.snapshot().documents.map(\.id)), [first.document.id, second.document.id])
    }

    func testRelinkCandidateOwnedByAnotherRecordCannotConfirmOrMerge() async throws {
        let fixture = try makeFixture()
        let firstURL = fixture.directory.appendingPathComponent("FirstOwned.md")
        let secondURL = fixture.directory.appendingPathComponent("SecondOwned.md")
        try write("# First\n\nOne record.", to: firstURL)
        try write("# Second\n\nAnother record.", to: secondURL)
        let first = try await fixture.repository.openDocument(
            at: firstURL,
            source: try projection(at: firstURL).source
        )
        let second = try await fixture.repository.openDocument(
            at: secondURL,
            source: try projection(at: secondURL).source
        )
        let before = try fixture.store.snapshotWithSequence()

        let proposal = try await fixture.repository.stageDocumentRelink(
            documentID: first.document.id,
            to: secondURL
        )

        XCTAssertFalse(proposal.canConfirm)
        XCTAssertEqual(proposal.conflictingDocumentIDs, [second.document.id])
        do {
            _ = try await fixture.repository.confirmDocumentRelink(proposalID: proposal.id)
            XCTFail("A candidate owned by another record must never be merged.")
        } catch let error as DocumentRelinkError {
            XCTAssertEqual(error, .candidateAlreadyRegistered([second.document.id]))
        }
        XCTAssertEqual(try fixture.store.snapshotWithSequence(), before)
    }

    func testConfirmedReplacementCreatesNewUUIDAndFutureColdOpenChoosesItsIdentity() async throws {
        let fixture = try makeFixture()
        let documentURL = fixture.directory.appendingPathComponent("Replacement.md")
        try write("# Original\n\nKeep the old memories.", to: documentURL)
        let originalProjection = try projection(at: documentURL)
        let original = try await fixture.repository.openDocument(
            at: documentURL,
            source: originalProjection.source
        )
        let memoryID = try createPassageMemory(
            projection: originalProjection,
            document: original.document,
            store: fixture.store
        )

        try atomicallyReplace(documentURL, with: "# Replacement\n\nThis is a new document.")
        let replacementProjection = try projection(at: documentURL)
        let coldRepository = MemoryRepository(
            store: fixture.store,
            legacyReadingPositionDefaults: fixture.defaults
        )
        let decision: DocumentOpenIdentityDecision
        do {
            _ = try await coldRepository.openDocument(
                at: documentURL,
                source: replacementProjection.source
            )
            XCTFail("A cold replacement requires an explicit decision.")
            return
        } catch let error as DocumentIdentityDecisionRequiredError {
            decision = error.decision
        }
        let proposal = try await coldRepository.stageDocumentRelink(
            documentID: decision.registeredDocumentID,
            to: documentURL
        )
        let replacement = try await coldRepository.confirmDocumentReplacement(
            proposalID: proposal.id
        )

        XCTAssertNotEqual(replacement.id, original.document.id)
        let reopened = try await coldRepository.openDocument(
            at: documentURL,
            source: replacementProjection.source
        )
        XCTAssertEqual(reopened.document.id, replacement.id)
        let snapshot = try fixture.store.snapshot()
        XCTAssertEqual(Set(snapshot.documents.map(\.id)), [original.document.id, replacement.id])
        XCTAssertEqual(snapshot.memories.map { $0.memory.id }, [memoryID])
        XCTAssertEqual(snapshot.memories.first?.memory.documentID, original.document.id)
        XCTAssertEqual(
            snapshot.documents.first { $0.id == original.document.id }?.availability,
            .unavailable
        )
        XCTAssertFalse(
            snapshot.documentLocations.contains {
                $0.documentID == original.document.id && $0.isCurrent
            }
        )
        XCTAssertEqual(
            snapshot.documentLocations.first {
                $0.documentID == replacement.id && $0.isCurrent
            }?.url.standardizedFileURL,
            documentURL.standardizedFileURL
        )

        let locatedOriginalURL = fixture.directory.appendingPathComponent("Located-Original.md")
        try write("# Original\n\nKeep the old memories.", to: locatedOriginalURL)
        let relink = try await coldRepository.stageDocumentRelink(
            documentID: original.document.id,
            to: locatedOriginalURL
        )
        let recoveredOriginal = try await coldRepository.confirmDocumentRelink(proposalID: relink.id)
        XCTAssertEqual(recoveredOriginal.id, original.document.id)
        XCTAssertEqual(recoveredOriginal.availability, .available)
        XCTAssertEqual(
            try currentURL(for: original.document.id, in: fixture.store),
            locatedOriginalURL.standardizedFileURL
        )
    }
}

private extension DocumentIdentityContinuityTests {
    struct Fixture {
        let directory: URL
        let store: SQLiteMemoryStore
        let repository: MemoryRepository
        let defaults: UserDefaults
        let defaultsSuiteName: String
    }

    func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownReader-IdentityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaultsSuiteName = "MarkdownReader.IdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        let store = try SQLiteMemoryStore(
            databaseURL: directory.appendingPathComponent("ReadingMemory.sqlite3")
        )
        let fixture = Fixture(
            directory: directory,
            store: store,
            repository: MemoryRepository(
                store: store,
                legacyReadingPositionDefaults: defaults
            ),
            defaults: defaults,
            defaultsSuiteName: defaultsSuiteName
        )
        addTeardownBlock {
            try? store.dbPool.close()
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        return fixture
    }

    func projection(at url: URL) throws -> DocumentProjection {
        try DocumentProjection.build(
            sourceData: Data(contentsOf: url),
            documentURL: url
        )
    }

    func write(_ string: String, to url: URL) throws {
        try Data(string.utf8).write(to: url)
    }

    func atomicallyReplace(_ destinationURL: URL, with contents: String) throws {
        let replacementURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".replacement-\(UUID().uuidString).md")
        try write(contents, to: replacementURL)
        let result = replacementURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
    }

    func currentURL(for documentID: UUID, in store: SQLiteMemoryStore) throws -> URL? {
        try store.documentLocations(documentID: documentID)
            .first(where: \.isCurrent)?
            .url
            .standardizedFileURL
    }

    func createPassageMemory(
        projection: DocumentProjection,
        document: DocumentRecord,
        store: SQLiteMemoryStore
    ) throws -> UUID {
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
        _ = try store.createMemory(
            CreateMemoryRequest(
                id: memoryID,
                documentID: document.id,
                kind: .passage,
                originalVisibleQuote: selection.selectedVisibleText,
                canonicalMatchQuote: anchor.exactQuote,
                expectedDocumentRecordVersion: document.recordVersion,
                anchor: ProjectionStoreAdapter.newAnchor(from: anchor),
                resolution: resolution
            )
        )
        return memoryID
    }
}
