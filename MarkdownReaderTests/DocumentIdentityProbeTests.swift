import XCTest
@testable import MarkdownReader

final class DocumentIdentityProbeTests: XCTestCase {
    func testCopyWithIdenticalBytesHasDifferentResourceIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.md")
        let second = directory.appendingPathComponent("second.md")
        try Data("same bytes".utf8).write(to: first)
        try FileManager.default.copyItem(at: first, to: second)

        let firstObservation = try DocumentIdentityProbe.observe(first)
        let secondObservation = try DocumentIdentityProbe.observe(second)

        XCTAssertEqual(firstObservation.identity.volumeIdentifier, secondObservation.identity.volumeIdentifier)
        XCTAssertNotEqual(
            firstObservation.identity.fileResourceIdentifier,
            secondObservation.identity.fileResourceIdentifier,
            "Content equality must never merge copied documents"
        )
    }

    func testSymlinkResolvesToSameResourceIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.md")
        let alias = directory.appendingPathComponent("alias.md")
        try Data("notes".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)

        let direct = try DocumentIdentityProbe.observe(file)
        let throughAlias = try DocumentIdentityProbe.observe(alias)

        XCTAssertEqual(direct.identity, throughAlias.identity)
        XCTAssertEqual(direct.canonicalURL, throughAlias.canonicalURL)
        XCTAssertNotEqual(direct.displayURL, throughAlias.displayURL)
    }
}
