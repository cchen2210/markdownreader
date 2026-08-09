import XCTest
@testable import MarkdownReader

final class MemoryArchiveExporterTests: XCTestCase {
    func testArchiveIsDeterministicAndExcludesLocationsByDefault() throws {
        let fixture = try makeFixture()
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let first = try MemoryArchiveExporter.makePayload(
            snapshot: fixture,
            storeSequence: 7,
            includeFileLocations: false,
            createdAt: date
        )
        let second = try MemoryArchiveExporter.makePayload(
            snapshot: fixture,
            storeSequence: 7,
            includeFileLocations: false,
            createdAt: date
        )

        XCTAssertEqual(first, second)
        let json = String(decoding: first.json, as: UTF8.self)
        XCTAssertTrue(json.contains("\"exportSchemaVersion\" : 1"))
        XCTAssertFalse(json.contains("private/notes"))
        XCTAssertFalse(json.contains("bookmarkData"))
        XCTAssertFalse(json.contains("fileResourceIdentifier"))
        let markdown = String(decoding: first.markdown, as: UTF8.self)
        XCTAssertTrue(markdown.contains("human-readable export"))
        XCTAssertTrue(markdown.contains("Needs repair · loose slip"))
        XCTAssertTrue(markdown.contains("> Passage kept exactly"))
    }

    func testLocationIsIncludedOnlyWithExplicitChoice() throws {
        let payload = try MemoryArchiveExporter.makePayload(
            snapshot: makeFixture(),
            storeSequence: 1,
            includeFileLocations: true,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(String(decoding: payload.json, as: UTF8.self).contains("private/notes"))
    }

    func testMarkdownOptionsAreAppliedWithoutChangingJSONArchive() throws {
        let fixture = try makeFixture()
        let date = Date(timeIntervalSince1970: 0)
        let defaults = try MemoryArchiveExporter.makePayload(
            snapshot: fixture,
            storeSequence: 1,
            includeFileLocations: false,
            createdAt: date
        )
        let customized = try MemoryArchiveExporter.makePayload(
            snapshot: fixture,
            storeSequence: 1,
            includeFileLocations: false,
            markdownOptions: MemoryArchiveMarkdownOptions(
                includesNotes: false,
                includesRepairLabels: false,
                includesAnchorDetails: true,
                groupsByDocument: false
            ),
            createdAt: date
        )
        let markdown = String(decoding: customized.markdown, as: UTF8.self)

        XCTAssertFalse(markdown.contains("A note"))
        XCTAssertFalse(markdown.contains("**Needs repair · loose slip"))
        XCTAssertTrue(markdown.contains("From notes.md"))
        XCTAssertTrue(markdown.contains("Anchor ID:"))
        XCTAssertEqual(customized.json, defaults.json)
    }

    func testArchiveOmitsSecurityBookmarksFileIdentityAndStoreHistory() throws {
        let fixture = try makeFixture()
        let payload = try MemoryArchiveExporter.makePayload(
            snapshot: fixture,
            storeSequence: 1,
            includeFileLocations: false,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let json = String(decoding: payload.json, as: UTF8.self)
        let bookmark = fixture.documents[0].bookmarkData!.base64EncodedString()
        let resourceIdentifier = fixture.documents[0].fileIdentity.fileResourceIdentifier!.base64EncodedString()

        XCTAssertFalse(json.contains("bookmarkData"))
        XCTAssertFalse(json.contains("fileIdentity"))
        XCTAssertFalse(json.contains("fileResourceIdentifier"))
        XCTAssertFalse(json.contains("volumeIdentifier"))
        XCTAssertFalse(json.contains("history"))
        XCTAssertFalse(json.contains(bookmark))
        XCTAssertFalse(json.contains(resourceIdentifier))
    }

    func testMalformedSnapshotFailsInsteadOfSelectingAnUnrelatedAnchor() throws {
        var fixture = try makeFixture()
        fixture.memories[0].memory.currentAnchorID = UUID()

        XCTAssertThrowsError(
            try MemoryArchiveExporter.makePayload(
                snapshot: fixture,
                storeSequence: 1,
                includeFileLocations: false
            )
        ) { error in
            guard case let MemoryStoreError.invalidRecord(reason) = error else {
                return XCTFail("Expected invalidRecord, got \(error)")
            }
            XCTAssertTrue(reason.contains("confirmed anchor"))
        }
    }

    func testPayloadMutationInvalidationHappensBeforeDestinationIsTouched() throws {
        let payload = try MemoryArchiveExporter.makePayload(
            snapshot: makeFixture(),
            storeSequence: 41,
            includeFileLocations: false,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("Reading Memory.md")
            let oldBytes = Data("previous export".utf8)
            try oldBytes.write(to: destination)

            XCTAssertThrowsError(
                try MemoryArchiveAtomicWriter.write(
                    payload,
                    representation: .markdown,
                    currentStoreSequence: 42,
                    to: destination,
                    coordinator: ImmediateMemoryArchiveFileCoordinator()
                )
            ) { error in
                XCTAssertEqual(
                    error as? MemoryArchiveExportError,
                    .payloadInvalidated(payloadSequence: 41, currentSequence: 42)
                )
            }
            XCTAssertEqual(try Data(contentsOf: destination), oldBytes)
        }
    }

    func testAtomicWriterCreatesPrivateFileWithExactPreviewBytes() throws {
        let payload = try MemoryArchiveExporter.makePayload(
            snapshot: makeFixture(),
            storeSequence: 8,
            includeFileLocations: false,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let previewBytes = try payload.data(for: .json, currentStoreSequence: 8)

        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("Reading Memory.json")
            try MemoryArchiveAtomicWriter.write(
                payload,
                representation: .json,
                currentStoreSequence: 8,
                to: destination,
                coordinator: ImmediateMemoryArchiveFileCoordinator()
            )

            XCTAssertEqual(try Data(contentsOf: destination), previewBytes)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o600)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                ["Reading Memory.json"]
            )
        }
    }

    func testAtomicWriterReplacesExistingFileAndRemovesSiblingTemporaryFile() throws {
        let exactBytes = Data("replacement bytes\nwith a second line".utf8)
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("Reading Memory.md")
            try Data("old bytes".utf8).write(to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o644)],
                ofItemAtPath: destination.path
            )

            try MemoryArchiveAtomicWriter.writeExactBytes(
                exactBytes,
                to: destination,
                coordinator: ImmediateMemoryArchiveFileCoordinator()
            )

            XCTAssertEqual(try Data(contentsOf: destination), exactBytes)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o600)
            let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertFalse(siblings.contains { $0.contains(".memory-export-") })
        }
    }

    func testSystemFileCoordinatorCompletesAtomicReplaceInAppHost() throws {
        let exactBytes = Data("coordinated bytes".utf8)
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("Reading Memory.md")
            try Data("old bytes".utf8).write(to: destination)

            try MemoryArchiveAtomicWriter.writeExactBytes(exactBytes, to: destination)

            XCTAssertEqual(try Data(contentsOf: destination), exactBytes)
        }
    }

    func testAtomicWriterFailsExplicitlyForDirectoryDestination() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("not-a-file", isDirectory: true)
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: false
            )

            XCTAssertThrowsError(
                try MemoryArchiveAtomicWriter.writeExactBytes(
                    Data("bytes".utf8),
                    to: destination,
                    coordinator: ImmediateMemoryArchiveFileCoordinator()
                )
            )
            var isDirectory = ObjCBool(false)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory)
            )
            XCTAssertTrue(isDirectory.boolValue)
        }
    }

    func testAtomicWriterDoesNotFallbackWhenCoordinationFails() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("Reading Memory.md")
            let oldBytes = Data("old bytes".utf8)
            try oldBytes.write(to: destination)

            XCTAssertThrowsError(
                try MemoryArchiveAtomicWriter.writeExactBytes(
                    Data("new bytes".utf8),
                    to: destination,
                    coordinator: RejectingMemoryArchiveFileCoordinator()
                )
            ) { error in
                XCTAssertEqual(
                    error as? MemoryArchiveWriteError,
                    .coordinationFailed(domain: "TestProvider", code: 1)
                )
            }
            XCTAssertEqual(try Data(contentsOf: destination), oldBytes)
        }
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryArchiveExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func makeFixture() throws -> MemoryStoreSnapshot {
        let documentID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let memoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let anchorID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let date = Date(timeIntervalSince1970: 100)
        let document = DocumentRecord(
            id: documentID,
            displayName: "notes.md",
            bookmarkData: Data("secret".utf8),
            fileIdentity: FileIdentity(fileResourceIdentifier: Data("inode".utf8)),
            lastConfirmedContentHash: "abc",
            detectedTextEncoding: "utf-8",
            hadByteOrderMark: false,
            availability: .available,
            isFavourite: true,
            recordVersion: 1,
            createdAt: date,
            lastOpenedAt: date,
            lastSeenAt: date
        )
        let memory = ReadingMemoryRecord(
            id: memoryID,
            documentID: documentID,
            kind: .passage,
            originalVisibleQuote: "Passage kept exactly",
            canonicalMatchQuote: "Passage kept exactly",
            noteText: "A note",
            createdAt: date,
            updatedAt: date,
            recordVersion: 1,
            originalAnchorID: anchorID,
            currentAnchorID: anchorID
        )
        let anchor = ConfirmedAnchorRecord(
            id: anchorID,
            memoryID: memoryID,
            supersedesAnchorID: nil,
            confirmation: .initialCapture,
            createdAt: date,
            selectorVersion: 1,
            projectionVersion: 1,
            sourceRevisionHash: "abc",
            resolverPolicyVersion: 1,
            exactQuote: "Passage kept exactly",
            prefix: "",
            suffix: "",
            canonicalTextPosition: CanonicalTextRange(lowerBound: 0, upperBound: 20),
            canonicalUTF8RangeInBlock: CanonicalTextRange(lowerBound: 0, upperBound: 20),
            blockKind: "paragraph",
            blockFingerprint: "fingerprint",
            headingPath: [StoredHeadingBreadcrumb(level: 1, title: "A heading")],
            blockOrdinal: 0,
            blockFingerprintOccurrenceCountInSection: 1,
            sourceUTF8Span: nil
        )
        let resolution = CurrentResolutionRecord(
            memoryID: memoryID,
            anchorID: anchorID,
            state: .orphaned,
            checkedRevisionHash: "def",
            resolverPolicyVersion: 1,
            resolvedSelector: nil,
            evidence: [],
            lastCheckedAt: date,
            recordVersion: 1
        )
        return MemoryStoreSnapshot(
            schemaVersion: 1,
            documents: [document],
            documentLocations: [
                DocumentLocationRecord(
                    id: UUID(),
                    documentID: documentID,
                    url: URL(fileURLWithPath: "/Users/person/private/notes.md"),
                    isCurrent: true,
                    firstSeenAt: date,
                    lastSeenAt: date
                ),
            ],
            readingStates: [],
            memories: [StoredMemory(memory: memory, anchors: [anchor], resolution: resolution, history: [])]
        )
    }
}

private struct ImmediateMemoryArchiveFileCoordinator: MemoryArchiveFileCoordinating {
    func coordinateReplacing(
        at destinationURL: URL,
        accessor: (URL) throws -> Void
    ) throws {
        try accessor(destinationURL)
    }
}

private struct RejectingMemoryArchiveFileCoordinator: MemoryArchiveFileCoordinating {
    func coordinateReplacing(
        at destinationURL: URL,
        accessor: (URL) throws -> Void
    ) throws {
        throw MemoryArchiveWriteError.coordinationFailed(domain: "TestProvider", code: 1)
    }
}
