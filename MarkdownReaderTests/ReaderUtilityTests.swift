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
        defaults.set(0.5, forKey: "reader.position.legacy")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for index in 0...ReadingPositionStore.maximumEntries {
            let url = root.appendingPathComponent("private-note-\(index).md")
            ReadingPositionStore.set(Double(index), for: url, defaults: defaults, now: Double(index))
        }

        let oldest = root.appendingPathComponent("private-note-0.md")
        let newest = root.appendingPathComponent("private-note-\(ReadingPositionStore.maximumEntries).md")
        XCTAssertNil(ReadingPositionStore.fraction(for: oldest, defaults: defaults))
        XCTAssertEqual(ReadingPositionStore.fraction(for: newest, defaults: defaults), 1)
        XCTAssertNil(defaults.object(forKey: "reader.position.legacy"))

        let storedData = try XCTUnwrap(defaults.data(forKey: ReadingPositionStore.storageKey))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: storedData) as? [String: Any])
        XCTAssertLessThanOrEqual(object.count, ReadingPositionStore.maximumEntries)
        let serialized = String(decoding: storedData, as: UTF8.self)
        XCTAssertFalse(serialized.contains("private-note"))
        XCTAssertFalse(serialized.contains(Data(newest.path.utf8).base64EncodedString()))
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
