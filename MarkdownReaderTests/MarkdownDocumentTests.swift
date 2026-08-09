import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import MarkdownReader

final class MarkdownDocumentTests: XCTestCase {
    func testMarkdownContentTypeIdentifier() {
        XCTAssertEqual(UTType.markdownDocument.identifier, "net.daringfireball.markdown")
        XCTAssertTrue(UTType.markdownDocument.conforms(to: .plainText))
    }

    func testDecodesUTF8AndUTF16() throws {
        let text = "# Héllo 🌿"
        XCTAssertEqual(try MarkdownTextDecoder.decode(Data(text.utf8)), text)
        XCTAssertEqual(try MarkdownTextDecoder.decode(text.data(using: .utf16)!), text)
    }

    func testDecodesSparseTerminalControlsAsVisibleInertText() throws {
        let source = "# Terminal\n\n`ok\u{1B}[31m </code><script>\u{0C} page\u{7F}`"

        let decoded = try MarkdownTextDecoder.decode(Data(source.utf8))
        let decodedUTF16 = try MarkdownTextDecoder.decode(try XCTUnwrap(source.data(using: .utf16)))
        let rendered = MarkdownRenderer.render(source: decoded, documentURL: nil)

        XCTAssertEqual(decodedUTF16, decoded)
        XCTAssertTrue(decoded.contains("␛[31m"))
        XCTAssertTrue(decoded.contains("␌"))
        XCTAssertTrue(decoded.contains("␡"))
        XCTAssertFalse(decoded.unicodeScalars.contains(where: MarkdownTextSafety.isUnsafeControl))
        XCTAssertTrue(rendered.bodyHTML.contains("␛[31m"))
        XCTAssertTrue(rendered.bodyHTML.contains("␌"))
        XCTAssertTrue(rendered.bodyHTML.contains("␡"))
        XCTAssertTrue(rendered.bodyHTML.contains("&lt;/code&gt;&lt;script&gt;"))
        XCTAssertFalse(rendered.bodyHTML.contains("<script>"))
        XCTAssertFalse(rendered.bodyHTML.unicodeScalars.contains(where: MarkdownTextSafety.isUnsafeControl))
    }

    func testRendererSanitizesResidualControlsWhenDecoderIsBypassed() {
        let rendered = MarkdownRenderer.render(
            source: "`before\u{1B}</code><script>\u{0C}after`",
            documentURL: nil
        )

        XCTAssertTrue(rendered.bodyHTML.contains("␛"))
        XCTAssertTrue(rendered.bodyHTML.contains("␌"))
        XCTAssertFalse(rendered.bodyHTML.contains("<script>"))
        XCTAssertFalse(rendered.bodyHTML.unicodeScalars.contains(where: MarkdownTextSafety.isUnsafeControl))
    }

    func testRejectsBinaryAndControlHeavyInput() {
        XCTAssertThrowsError(try MarkdownTextDecoder.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])))
        XCTAssertThrowsError(try MarkdownTextDecoder.decode(Data([0x00, 0x01, 0x02, 0x03])))
        XCTAssertThrowsError(try MarkdownTextDecoder.decode(Data([0x41, 0x00, 0x42, 0x00])))
        XCTAssertThrowsError(try MarkdownTextDecoder.decode(Data([0x01, 0x02, 0x03, 0x04, 0x41])))
    }

    func testRejectsUnreasonablyLargeDocuments() {
        let oversized = Data(repeating: 0x20, count: MarkdownTextDecoder.maximumBytes + 1)
        XCTAssertThrowsError(try MarkdownTextDecoder.decode(oversized))
    }
}
