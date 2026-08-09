import CryptoKit
import XCTest
@testable import MarkdownReader

final class DocumentProjectionTests: XCTestCase {
    func testEmitsSupportedBlocksAndDeterministicRunIDsInReadingOrder() throws {
        let source = """
        # Heading

        Paragraph with *emphasis*, [a link](https://example.test), and `code`.

        - list item

        > quoted text

        ```swift
        let value = 1
        ```

        | A | B |
        |---|---|
        | C | D |

        <aside>literal</aside>
        """
        let projection = try makeProjection(source)

        XCTAssertEqual(
            projection.blocks.map(\.kind),
            [
                .heading, .paragraph, .listItem, .blockQuote, .codeBlock,
                .tableCell, .tableCell, .tableCell, .tableCell, .rawHTML
            ]
        )
        XCTAssertEqual(
            projection.blocks.map(\.id),
            (0..<projection.blocks.count).map { "block-\($0)" }
        )
        XCTAssertEqual(
            projection.blocks.flatMap(\.textRuns).map(\.id),
            (0..<projection.blocks.flatMap(\.textRuns).count).map { "run-\($0)" }
        )
        XCTAssertEqual(projection.blocks[1].canonicalText, "Paragraph with emphasis, a link, and code.")
        XCTAssertEqual(projection.blocks[4].canonicalText, "let value = 1\n")
        XCTAssertEqual(projection.blocks[5...8].map(\.canonicalText), ["A", "B", "C", "D"])
        XCTAssertEqual(
            projection.blocks.last?.captureCapability,
            .unsupported(.rawHTML)
        )
    }

    func testCanonicalRulesNormalizeNFDCRLFAndBreakKinds() throws {
        let decomposed = "Cafe\u{301}"
        let source = "First soft\r\nline with \(decomposed) and emoji 🧑🏽‍💻.  \r\nHard."
        let projection = try makeProjection(source)
        let block = try XCTUnwrap(projection.blocks.first)

        XCTAssertEqual(block.canonicalText, "First soft line with Café and emoji 🧑🏽‍💻.\nHard.")
        XCTAssertEqual(block.textRuns.filter { $0.kind == .softBreak }.map(\.domText), [" "])
        XCTAssertEqual(block.textRuns.filter { $0.kind == .hardBreak }.map(\.domText), ["\n"])
        XCTAssertEqual(projection.canonicalRulesVersion, 1)
        XCTAssertEqual(projection.canonicalText, block.canonicalText)
    }

    func testCanonicalDocumentPositionsUseUTF8AndTwoNewlineSeparator() throws {
        let projection = try makeProjection("é\n\n🧠 idea")
        XCTAssertEqual(projection.blocks.count, 2)
        XCTAssertEqual(
            projection.blocks[0].canonicalUTF8RangeInDocument,
            UTF8ByteRange(0, "é".utf8.count)
        )
        XCTAssertEqual(
            projection.blocks[1].canonicalUTF8RangeInDocument,
            UTF8ByteRange("é".utf8.count + 2, "é\n\n🧠 idea".utf8.count)
        )
        XCTAssertEqual(projection.canonicalText, "é\n\n🧠 idea")
    }

    func testDOMUTF16SelectionMapsToCanonicalUTF8AcrossStyledRuns() throws {
        let revision = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let projection = try makeProjection(
            "Start **Café 🧠** end",
            renderRevision: revision
        )
        let block = try XCTUnwrap(projection.blocks.first)
        XCTAssertEqual(block.canonicalText, "Start Café 🧠 end")
        let cafeRun = try XCTUnwrap(block.textRuns.first { $0.domText == "Café 🧠" })
        let request = DOMProjectionSelection(
            sourceRevisionHash: projection.source.revisionHash,
            renderRevision: revision,
            projectionVersion: projection.version,
            blockID: block.id,
            start: DOMProjectionPoint(runID: cafeRun.id, utf16Offset: 0),
            end: DOMProjectionPoint(runID: cafeRun.id, utf16Offset: cafeRun.domText.utf16.count),
            selectedVisibleText: "Cafe\u{301} 🧠"
        )

        let selection = try projection.selection(fromDOM: request)

        XCTAssertEqual(
            CanonicalMarkdownText.substring(
                block.canonicalText,
                utf8Range: selection.canonicalUTF8RangeInBlock
            ),
            "Café 🧠"
        )
        XCTAssertEqual(selection.runIDs, [cafeRun.id])
    }

    func testReadingPositionRoundTripsBlockLocalUnicodeOffsetToDOMPoint() throws {
        let projection = try makeProjection("Before **Café 🧠** after")
        let block = try XCTUnwrap(projection.blocks.first)
        let run = try XCTUnwrap(block.textRuns.first { $0.domText == "Café 🧠" })
        let utf16Offset = (run.domText as NSString).range(of: "🧠").location
        let request = DOMProjectionReadingPosition(
            sourceRevisionHash: projection.source.revisionHash,
            renderRevision: projection.renderRevision,
            projectionVersion: projection.version,
            blockID: block.id,
            point: DOMProjectionPoint(runID: run.id, utf16Offset: utf16Offset),
            fallbackScrollFraction: 0.4
        )

        let saved = try projection.readingPosition(fromDOM: request)
        let restored = try XCTUnwrap(
            projection.readingRestoreTarget(
                blockID: saved.blockID,
                canonicalUTF8OffsetInBlock: saved.canonicalUTF8OffsetInBlock
            )
        )

        XCTAssertEqual(restored.blockID, block.id)
        XCTAssertEqual(restored.point, request.point)
        XCTAssertEqual(
            saved.canonicalUTF8OffsetInDocument,
            Int64(block.canonicalUTF8RangeInDocument.lowerBound) + saved.canonicalUTF8OffsetInBlock
        )
    }

    func testReadingRestoreRejectsInvalidCanonicalBoundary() throws {
        let projection = try makeProjection("🧠")
        let block = try XCTUnwrap(projection.blocks.first)

        XCTAssertNil(
            projection.readingRestoreTarget(
                blockID: block.id,
                canonicalUTF8OffsetInBlock: 1
            )
        )
    }

    func testDOMSelectionRejectsStaleRevisionAndMidSurrogateBoundary() throws {
        let projection = try makeProjection("A 🧠 B")
        let block = try XCTUnwrap(projection.blocks.first)
        let run = try XCTUnwrap(block.textRuns.first)
        let stale = DOMProjectionSelection(
            sourceRevisionHash: "wrong",
            renderRevision: projection.renderRevision,
            projectionVersion: projection.version,
            blockID: block.id,
            start: DOMProjectionPoint(runID: run.id, utf16Offset: 0),
            end: DOMProjectionPoint(runID: run.id, utf16Offset: 1),
            selectedVisibleText: "A"
        )
        XCTAssertThrowsError(try projection.selection(fromDOM: stale)) {
            XCTAssertEqual($0 as? DocumentProjectionError, .staleSourceRevision)
        }

        let emojiUTF16Start = (run.domText as NSString).range(of: "🧠").location
        let splitSurrogate = DOMProjectionSelection(
            sourceRevisionHash: projection.source.revisionHash,
            renderRevision: projection.renderRevision,
            projectionVersion: projection.version,
            blockID: block.id,
            start: DOMProjectionPoint(runID: run.id, utf16Offset: emojiUTF16Start + 1),
            end: DOMProjectionPoint(runID: run.id, utf16Offset: emojiUTF16Start + 2),
            selectedVisibleText: "🧠"
        )
        XCTAssertThrowsError(try projection.selection(fromDOM: splitSurrogate)) {
            XCTAssertEqual(
                $0 as? DocumentProjectionError,
                .nonScalarDOMBoundary(run.id)
            )
        }
    }

    func testSourceHashUsesExactBytesAndTracksBOMAndEncoding() throws {
        let utf8Bytes = Data("same\r\ntext".utf8)
        let lfBytes = Data("same\ntext".utf8)
        let utf8Projection = try DocumentProjection.build(sourceData: utf8Bytes)
        let lfProjection = try DocumentProjection.build(sourceData: lfBytes)

        XCTAssertEqual(utf8Projection.canonicalText, lfProjection.canonicalText)
        XCTAssertNotEqual(utf8Projection.source.revisionHash, lfProjection.source.revisionHash)
        XCTAssertEqual(utf8Projection.source.encoding, .utf8)
        XCTAssertEqual(utf8Projection.source.byteOrderMark, .none)
        XCTAssertEqual(
            utf8Projection.source.revisionHash,
            SHA256.hash(data: utf8Bytes).map { String(format: "%02x", $0) }.joined()
        )

        var utf16 = Data([0xFF, 0xFE])
        utf16.append("Memory".data(using: .utf16LittleEndian)!)
        let utf16Projection = try DocumentProjection.build(sourceData: utf16)
        XCTAssertEqual(utf16Projection.canonicalText, "Memory")
        XCTAssertEqual(utf16Projection.source.encoding, .utf16LittleEndian)
        XCTAssertEqual(utf16Projection.source.byteOrderMark, .utf16LittleEndian)
    }

    func testRendererRequiresTheDisplaySourceToMatchExactBytesAndAcceptsUTF8BOM() throws {
        XCTAssertThrowsError(
            try DocumentProjection.build(
                sourceData: Data("bytes snapshot".utf8),
                expectedDisplaySource: "different snapshot"
            )
        ) {
            XCTAssertEqual($0 as? DocumentProjectionError, .sourceSnapshotMismatch)
        }

        let mismatched = MarkdownRenderer.render(
            source: "different snapshot",
            sourceData: Data("bytes snapshot".utf8),
            documentURL: nil
        )
        XCTAssertNil(mismatched.projection)

        var bomBytes = Data([0xEF, 0xBB, 0xBF])
        bomBytes.append(Data("# Heading".utf8))
        let withBOM = MarkdownRenderer.render(
            source: "\u{FEFF}# Heading",
            sourceData: bomBytes,
            documentURL: nil
        )
        let projection = try XCTUnwrap(withBOM.projection)
        XCTAssertEqual(projection.source.byteOrderMark, .utf8)
        XCTAssertEqual(projection.blocks.map(\.kind), [.heading])
        XCTAssertEqual(projection.canonicalText, "Heading")
    }

    func testHeadingPathsAndSectionsEndAtEqualOrHigherHeading() throws {
        let projection = try makeProjection("""
        Intro.

        # One

        One body.

        ## Child

        Child body.

        # Two

        Two body.
        """)
        XCTAssertEqual(projection.blocks.map(\.headingPath), [
            [],
            [.init(level: 1, title: "One")],
            [.init(level: 1, title: "One")],
            [.init(level: 1, title: "One"), .init(level: 2, title: "Child")],
            [.init(level: 1, title: "One"), .init(level: 2, title: "Child")],
            [.init(level: 1, title: "Two")],
            [.init(level: 1, title: "Two")]
        ])
        let one = try XCTUnwrap(projection.headingSections.first { $0.id == "section-1" })
        XCTAssertEqual(one.lowerBlockOrdinal, 1)
        XCTAssertEqual(one.upperBlockOrdinal, 5)
        let child = try XCTUnwrap(projection.headingSections.first { $0.id == "section-3" })
        XCTAssertEqual(child.lowerBlockOrdinal, 3)
        XCTAssertEqual(child.upperBlockOrdinal, 5)
    }

    func testUnsupportedComplexAndFootnoteSelectionsFailExplicitly() throws {
        let list = try makeProjection("- Parent\n  - Nested")
        XCTAssertEqual(
            list.blocks.first?.captureCapability,
            .unsupported(.complexListItem)
        )

        let quote = try makeProjection("> first\n>\n> second")
        XCTAssertEqual(
            quote.blocks.first?.captureCapability,
            .unsupported(.complexBlockQuote)
        )

        let footnote = try makeProjection("Passage[^note].\n\n[^note]: detail")
        let block = try XCTUnwrap(footnote.blocks.first)
        let footnoteRun = try XCTUnwrap(block.textRuns.first { $0.kind == .footnoteReference })
        let request = DOMProjectionSelection(
            sourceRevisionHash: footnote.source.revisionHash,
            renderRevision: footnote.renderRevision,
            projectionVersion: footnote.version,
            blockID: block.id,
            start: .init(runID: footnoteRun.id, utf16Offset: 0),
            end: .init(runID: footnoteRun.id, utf16Offset: footnoteRun.domText.utf16.count),
            selectedVisibleText: footnoteRun.domText
        )
        XCTAssertThrowsError(try footnote.selection(fromDOM: request)) {
            XCTAssertEqual(
                $0 as? DocumentProjectionError,
                .unsupportedSelection(.footnoteStructure)
            )
        }
    }

    func testAnchorConstructionRejectsOverlapAndCreatesImmutableManualGeneration() throws {
        let projection = try makeProjection("Keep this useful passage.")
        let initialSelection = try selection(of: "useful", in: projection)
        let memoryID = UUID()
        let initial = try projection.makeInitialAnchor(
            memoryID: memoryID,
            from: initialSelection,
            anchorID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let overlapping = ExistingResolvedPassage(
            memoryID: UUID(),
            canonicalTextPosition: initial.canonicalTextPosition
        )
        XCTAssertThrowsError(
            try projection.makeInitialAnchor(
                memoryID: UUID(),
                from: initialSelection,
                existingPassages: [overlapping]
            )
        ) {
            XCTAssertEqual($0 as? DocumentProjectionError, .overlappingSelection)
        }

        let replacementSelection = try selection(of: "passage", in: projection)
        let replacement = try projection.makeManualReattachment(
            superseding: initial,
            from: replacementSelection,
            existingPassages: [
                ExistingResolvedPassage(
                    memoryID: memoryID,
                    canonicalTextPosition: initial.canonicalTextPosition
                )
            ],
            anchorID: UUID(),
            createdAt: Date(timeIntervalSince1970: 2)
        )
        XCTAssertEqual(replacement.memoryID, initial.memoryID)
        XCTAssertEqual(replacement.supersedesAnchorID, initial.id)
        XCTAssertEqual(replacement.confirmation, .manualReattach)
        XCTAssertEqual(replacement.exactQuote, "passage")
        XCTAssertEqual(initial.exactQuote, "useful")
    }

    func testRendererDOMBlockAndRunIDsStayAlignedWithProjection() throws {
        let source = """
        # Heading

        Styled **text** over
        a soft break and a hard\\
        break.

        - Parent
          - Nested

          <aside>nested raw HTML</aside>

        > First paragraph.
        >
        > Second paragraph.

        ```swift
        let number = 1
        ```

        | A |   |
        |---|---|
        |   | D |

        Footnote[^note].

        [^note]: detail
        """
        let data = Data(source.utf8)
        let rendered = MarkdownRenderer.render(
            source: source,
            sourceData: data,
            documentURL: nil
        )
        let projection = try XCTUnwrap(rendered.projection)

        XCTAssertEqual(
            captures(pattern: #"data-memory-block=\"([^\"]+)\""#, in: rendered.bodyHTML),
            projection.blocks.map(\.id)
        )
        XCTAssertEqual(
            captures(pattern: #"data-memory-kind=\"([^\"]+)\""#, in: rendered.bodyHTML),
            projection.blocks.map { $0.kind.rawValue }
        )
        XCTAssertEqual(
            captures(pattern: #"data-memory-run=\"([^\"]+)\""#, in: rendered.bodyHTML),
            projection.blocks.flatMap(\.textRuns).map(\.id)
        )
        XCTAssertEqual(
            projection.blocks.filter { $0.kind == .tableCell }.map(\.canonicalText),
            ["A", "", "", "D"]
        )
        XCTAssertTrue(
            projection.blocks
                .first { $0.kind == .listItem }?
                .textRuns
                .contains { $0.unsupportedReason == .rawHTML } == true
        )
    }

    private func makeProjection(
        _ source: String,
        renderRevision: UUID = UUID()
    ) throws -> DocumentProjection {
        try DocumentProjection.build(
            sourceData: Data(source.utf8),
            renderRevision: renderRevision
        )
    }

    private func selection(
        of quote: String,
        in projection: DocumentProjection,
        blockOrdinal: Int = 0
    ) throws -> ProjectionSelection {
        let block = projection.blocks[blockOrdinal]
        let stringRange = try XCTUnwrap(block.canonicalText.range(of: quote))
        let lower = block.canonicalText.utf8.distance(
            from: block.canonicalText.utf8.startIndex,
            to: stringRange.lowerBound
        )
        let upper = block.canonicalText.utf8.distance(
            from: block.canonicalText.utf8.startIndex,
            to: stringRange.upperBound
        )
        return ProjectionSelection(
            sourceRevisionHash: projection.source.revisionHash,
            renderRevision: projection.renderRevision,
            projectionVersion: projection.version,
            blockID: block.id,
            canonicalUTF8RangeInBlock: UTF8ByteRange(lower, upper),
            selectedVisibleText: quote,
            runIDs: block.textRuns.map(\.id)
        )
    }

    private func captures(pattern: String, in value: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[captureRange])
        }
    }
}
