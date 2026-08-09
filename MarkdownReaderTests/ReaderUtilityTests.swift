import XCTest
@testable import MarkdownReader

final class ReaderUtilityTests: XCTestCase {
    @MainActor
    func testViewModelRendersAndReloadsWithoutPublishingStaleContent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("notes.md")
        try Data("# First".utf8).write(to: fileURL)
        let model = ReaderViewModel(source: "# First", fileURL: fileURL)

        try await waitUntil { !model.isRendering }
        XCTAssertEqual(model.rendered.outline.map(\.title), ["First"])

        try Data("# Second".utf8).write(to: fileURL)
        model.reloadFromDisk()
        try await waitUntil { model.source == "# Second" }

        XCTAssertEqual(model.rendered.outline.map(\.title), ["Second"])
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testEditorNameDoesNotMutateMissingPreference() {
        let suiteName = "MarkdownReaderTests.Editor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ReaderPreferences(defaults: defaults)
        let missingPath = "/Applications/Definitely Missing \(UUID().uuidString).app"
        preferences.preferredEditorPath = missingPath

        XCTAssertEqual(ExternalEditor.editorName(preferences: preferences), "Not Selected")
        XCTAssertEqual(preferences.preferredEditorPath, missingPath)
    }

    func testReadingPositionsClampAndPruneWithoutStoringPaths() throws {
        let suiteName = "MarkdownReaderTests.Positions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for index in 0...ReadingPositionStore.maximumEntries {
            let url = root.appendingPathComponent("private-note-\(index).md")
            ReadingPositionStore.set(Double(index), for: url, defaults: defaults, now: Double(index))
        }

        let oldest = root.appendingPathComponent("private-note-0.md")
        let newest = root.appendingPathComponent("private-note-\(ReadingPositionStore.maximumEntries).md")
        XCTAssertNil(ReadingPositionStore.fraction(for: oldest, defaults: defaults))
        XCTAssertEqual(ReadingPositionStore.fraction(for: newest, defaults: defaults), 1)

        let storedData = try XCTUnwrap(defaults.data(forKey: ReadingPositionStore.storageKey))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: storedData) as? [String: Any])
        XCTAssertLessThanOrEqual(object.count, ReadingPositionStore.maximumEntries)
        let serialized = String(decoding: storedData, as: UTF8.self)
        XCTAssertFalse(serialized.contains("private-note"))
        XCTAssertFalse(serialized.contains(Data(newest.path.utf8).base64EncodedString()))
    }

    func testLegacyPositionLookupAndRemovalTouchOnlyRequestedDocument() throws {
        let suiteName = "MarkdownReaderTests.LegacyPositions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let requestedURL = root.appendingPathComponent("requested.md")
        let untouchedURL = root.appendingPathComponent("untouched.md")
        ReadingPositionStore.set(0.42, for: requestedURL, defaults: defaults, now: 10)
        ReadingPositionStore.set(0.84, for: untouchedURL, defaults: defaults, now: 20)

        let position = try XCTUnwrap(
            ReadingPositionStore.legacyPosition(for: requestedURL, defaults: defaults)
        )
        XCTAssertEqual(position.fraction, 0.42)
        XCTAssertFalse(position.keyHash.contains("requested"))
        XCTAssertTrue(ReadingPositionStore.removeLegacyPosition(position, defaults: defaults))

        XCTAssertNil(ReadingPositionStore.legacyPosition(for: requestedURL, defaults: defaults))
        XCTAssertEqual(
            ReadingPositionStore.legacyPosition(for: untouchedURL, defaults: defaults)?.fraction,
            0.84
        )
        XCTAssertEqual(ReadingPositionStore.fraction(for: untouchedURL, defaults: defaults), 0.84)
    }

    func testLegacyRemovalDoesNotDeleteAConcurrentNewerPosition() throws {
        let suiteName = "MarkdownReaderTests.LegacyPositionRace.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("race.md")
        ReadingPositionStore.set(0.2, for: url, defaults: defaults, now: 10)
        let staleSnapshot = try XCTUnwrap(
            ReadingPositionStore.legacyPosition(for: url, defaults: defaults)
        )

        ReadingPositionStore.set(0.9, for: url, defaults: defaults, now: 20)

        XCTAssertFalse(
            ReadingPositionStore.removeLegacyPosition(staleSnapshot, defaults: defaults)
        )
        XCTAssertEqual(ReadingPositionStore.fraction(for: url, defaults: defaults), 0.9)
    }

    func testLegacyPositionSurvivesFailedImport() throws {
        enum ImportFailure: Error { case expected }
        let suiteName = "MarkdownReaderTests.LegacyPositionFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("retry.md")
        ReadingPositionStore.set(0.7, for: url, defaults: defaults, now: 10)

        XCTAssertThrowsError(
            try ReadingPositionStore.consumeLegacyPosition(for: url, defaults: defaults) { _ in
                throw ImportFailure.expected
            }
        ) { error in
            XCTAssertTrue(error is ImportFailure)
        }
        XCTAssertEqual(
            ReadingPositionStore.legacyPosition(for: url, defaults: defaults)?.fraction,
            0.7
        )
    }

    func testIndividualLegacyKeyImportDoesNotCrawlSiblingKeys() throws {
        let suiteName = "MarkdownReaderTests.IndividualLegacyPosition.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("individual.md")
        ReadingPositionStore.set(0.1, for: url, defaults: defaults, now: 10)
        let mapPosition = try XCTUnwrap(
            ReadingPositionStore.legacyPosition(for: url, defaults: defaults)
        )
        XCTAssertTrue(ReadingPositionStore.removeLegacyPosition(mapPosition, defaults: defaults))
        let individualKey = "reader.position.\(mapPosition.keyHash)"
        let siblingKey = "reader.position.unrelated-hash"
        defaults.set(0.31, forKey: individualKey)
        defaults.set(0.62, forKey: siblingKey)

        var importedFraction: Double?
        XCTAssertTrue(
            ReadingPositionStore.consumeLegacyPosition(for: url, defaults: defaults) { position in
                importedFraction = position.fraction
            }
        )

        XCTAssertEqual(importedFraction, 0.31)
        XCTAssertNil(defaults.object(forKey: individualKey))
        XCTAssertEqual(defaults.double(forKey: siblingKey), 0.62)
    }

    func testLinkResolverAllowsSafeTargetsAndBlocksEscapes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let documentURL = root.appendingPathComponent("readme.md")
        let localURL = root.appendingPathComponent("guide.md")
            .standardizedFileURL
            .resolvingSymlinksInPath()

        XCTAssertEqual(
            LinkTargetResolver.resolve("guide.md#intro", relativeTo: documentURL),
            .markdown(localURL)
        )
        XCTAssertEqual(
            LinkTargetResolver.resolve("https://example.com/docs", relativeTo: documentURL),
            .external(try XCTUnwrap(URL(string: "https://example.com/docs")))
        )
        XCTAssertNil(LinkTargetResolver.resolve("../secret.md", relativeTo: documentURL))
        XCTAssertNil(LinkTargetResolver.resolve("%252e%252e%252fsecret.md", relativeTo: documentURL))
        XCTAssertNil(LinkTargetResolver.resolve("file:///tmp/secret.md", relativeTo: documentURL))
        XCTAssertNil(LinkTargetResolver.resolve("javascript:alert(1)", relativeTo: documentURL))
        XCTAssertNil(LinkTargetResolver.resolve("data:text/html,owned", relativeTo: documentURL))
    }

    func testHeadingBookmarksUseGeometryWithoutWrappingReadableText() {
        XCTAssertTrue(MemoryWebBridge.markJavaScript.contains("row.kind !== 'passage'"))
        XCTAssertTrue(MemoryWebBridge.markJavaScript.contains("data-memory-block-tokens"))
        XCTAssertTrue(MemoryWebBridge.geometryHelperJavaScript.contains("memoryBlockTokens"))
        XCTAssertFalse(
            MemoryWebBridge.markJavaScript.contains("row.kind === 'headingBookmark' && range.extractContents")
        )
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for asynchronous state change")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
