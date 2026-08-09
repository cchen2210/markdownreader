import XCTest
@testable import MarkdownReader

final class FileRefreshPresenterTests: XCTestCase {
    func testWatcherSeesUncoordinatedWrite() throws {
        let fileURL = try makeTemporaryFile(contents: "before")
        let changed = expectation(description: "Uncoordinated write observed")
        let observed = LockedSet<String>()
        let presenter = FileRefreshPresenter(
            url: fileURL,
            onChange: {
                if observed.insert("changed").inserted { changed.fulfill() }
            },
            onMove: { _ in },
            onDelete: {}
        )
        presenter.start()
        defer { presenter.stop() }

        try Data("after".utf8).write(to: fileURL)

        wait(for: [changed], timeout: 2)
    }

    func testWatcherRearmsAcrossAtomicSaves() throws {
        let fileURL = try makeTemporaryFile(contents: "before")
        let firstSave = expectation(description: "First atomic save observed")
        let secondSave = expectation(description: "Second atomic save observed")
        let observed = LockedSet<String>()
        let presenter = FileRefreshPresenter(
            url: fileURL,
            onChange: {
                guard let value = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
                let isNew = observed.insert(value).inserted
                guard isNew else { return }
                if value == "first" { firstSave.fulfill() }
                if value == "second" { secondSave.fulfill() }
            },
            onMove: { _ in },
            onDelete: {}
        )
        presenter.start()
        defer { presenter.stop() }

        try Data("first".utf8).write(to: fileURL, options: .atomic)
        wait(for: [firstSave], timeout: 3)
        try Data("second".utf8).write(to: fileURL, options: .atomic)
        wait(for: [secondSave], timeout: 3)
    }

    private func makeTemporaryFile(contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("notes.md")
        try Data(contents.utf8).write(to: fileURL)
        return fileURL
    }
}

private final class LockedSet<Element: Hashable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values = Set<Element>()

    @discardableResult
    func insert(_ value: Element) -> (inserted: Bool, memberAfterInsert: Element) {
        lock.lock()
        defer { lock.unlock() }
        return values.insert(value)
    }
}
