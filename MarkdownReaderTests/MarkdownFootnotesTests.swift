import XCTest
@testable import MarkdownReader

final class MarkdownFootnotesTests: XCTestCase {
    func testExtractsDefinitionsAndPreservesMarkdownContent() throws {
        let source = """
        Before[^details].

        [^details]: First paragraph with **strong text**.

            - one
            - two

        After.
        """

        let output = MarkdownFootnotes.process(source)
        let definition = try XCTUnwrap(output.definitions.first)

        XCTAssertEqual(output.definitions.count, 1)
        XCTAssertEqual(definition.identifier, "details")
        XCTAssertEqual(
            definition.markdown,
            "First paragraph with **strong text**.\n\n- one\n- two"
        )
        XCTAssertTrue(output.bodySource.contains("Before[^details]."))
        XCTAssertTrue(output.bodySource.contains("After."))
        XCTAssertFalse(output.bodySource.contains("[^details]:"))
        XCTAssertFalse(output.bodySource.contains("- one"))
        XCTAssertEqual(output.bodySource.components(separatedBy: "\n").count, source.components(separatedBy: "\n").count)
    }

    func testEmptyDeclarationLineDoesNotAddLeadingBlankToDefinition() throws {
        let output = MarkdownFootnotes.process("""
        Text[^note].

        [^note]:
            Continued content.
        """)

        XCTAssertEqual(try XCTUnwrap(output.definitions.first).markdown, "Continued content.")
    }

    func testDefinitionsAndReferencesInsideFencesRemainLiteral() {
        let source = """
        ```markdown
        [^fake]: not a definition
        [^real]
        ```

        Outside[^REAL].

        [^real]: actual note
        """

        let output = MarkdownFootnotes.process(source)

        XCTAssertEqual(output.definitions.map(\.normalizedIdentifier), ["real"])
        XCTAssertEqual(output.references.count, 1)
        XCTAssertEqual(output.references.first?.span.line, 6)
        XCTAssertTrue(output.bodySource.contains("[^fake]: not a definition"))
        XCTAssertTrue(output.bodySource.contains("[^real]\n```"))
    }

    func testRepeatedReferencesAreNumberedByFirstUseAndCaseFolded() throws {
        let source = """
        First[^Second], then [^FIRST], [^second], and [^first].

        [^first]: first definition
        [^SECOND]: second definition
        """

        let output = MarkdownFootnotes.process(source)
        let firstDefinition = try XCTUnwrap(output.definitions.first)
        let secondDefinition = try XCTUnwrap(output.definitions.last)

        XCTAssertEqual(output.references.map(\.noteNumber), [1, 2, 1, 2])
        XCTAssertEqual(output.references.map(\.occurrence), [1, 1, 2, 2])
        XCTAssertEqual(firstDefinition.noteNumber, 2)
        XCTAssertEqual(secondDefinition.noteNumber, 1)
        XCTAssertEqual(output.referencedDefinitions.map(\.normalizedIdentifier), ["second", "first"])
        XCTAssertEqual(output.references[0].referenceID, "fnref-7365636f6e64")
        XCTAssertEqual(output.references[2].referenceID, "fnref-7365636f6e64-2")
        XCTAssertEqual(output.references[0].safeID, output.references[2].safeID)
    }

    func testReferenceSpansUseOneBasedUTF8ColumnsAndLeaveBodyUntouched() throws {
        let source = "é [^NOTE] tail\n\n[^note]: body"
        let output = MarkdownFootnotes.process(source)
        let reference = try XCTUnwrap(output.references.first)

        XCTAssertEqual(reference.span, .init(line: 1, lowerUTF8Column: 4, upperUTF8Column: 11))
        XCTAssertTrue(output.bodySource.hasPrefix("é [^NOTE] tail"))
    }

    func testSkipsCodeLinksImagesRawHTMLAndEscapedReferences() {
        let source = """
        `[^note]`

        [label](https://example.test/[^note])

        ![alt [^note]](image.png)

        <!-- [^note] -->

        \\[^note] and *[^note]*

        [^note]: body
        """

        let output = MarkdownFootnotes.process(source)

        XCTAssertEqual(output.references.count, 1)
        XCTAssertEqual(output.references.first?.span.line, 9)
    }

    func testUndefinedReferencesAndLinkDefinitionsStayLiteral() {
        let source = """
        Unknown[^missing].
        [label]: https://example.test/[^known]

        [^known]: note
        """

        let output = MarkdownFootnotes.process(source)

        XCTAssertTrue(output.references.isEmpty)
        XCTAssertTrue(output.bodySource.contains("[^missing]"))
        XCTAssertTrue(output.bodySource.contains("https://example.test/[^known]"))
    }

    func testFirstCaseEquivalentDefinitionWinsAndDuplicatesAreRemoved() throws {
        let source = """
        Use[^NOTE].

        [^Note]: first
        [^ note ]: second
        """

        let output = MarkdownFootnotes.process(source)

        XCTAssertEqual(output.definitions.count, 1)
        XCTAssertEqual(try XCTUnwrap(output.definitions.first).markdown, "first")
        XCTAssertFalse(output.bodySource.contains("[^Note]:"))
        XCTAssertFalse(output.bodySource.contains("[^ note ]:"))
    }

    func testSafeIDsCannotInjectMarkup() throws {
        let source = "Use[^\"><script>].\n\n[^\"><SCRIPT>]: safe **Markdown**"
        let output = MarkdownFootnotes.process(source)
        let definition = try XCTUnwrap(output.definitions.first)

        XCTAssertTrue(definition.safeID.hasPrefix("fn-"))
        XCTAssertTrue(definition.safeID.dropFirst(3).allSatisfy { $0.isHexDigit })
        XCTAssertFalse(definition.safeID.contains("<"))
        XCTAssertEqual(definition.markdown, "safe **Markdown**")
        XCTAssertEqual(output.references.count, 1)
    }

    func testDefinitionAndReferenceCapsFailOpenAsLiteralMarkdown() {
        let definitions = (0...MarkdownFootnotes.maximumDefinitions)
            .map { "[^n\($0)]: note \($0)" }
            .joined(separator: "\n")
        let cappedDefinitions = MarkdownFootnotes.process(definitions)

        XCTAssertEqual(cappedDefinitions.definitions.count, MarkdownFootnotes.maximumDefinitions)
        XCTAssertTrue(cappedDefinitions.limitsReached.contains(.definitionCount))
        XCTAssertTrue(cappedDefinitions.bodySource.contains("[^n\(MarkdownFootnotes.maximumDefinitions)]:"))

        let references = Array(
            repeating: "[^note]",
            count: MarkdownFootnotes.maximumReferences + 1
        ).joined(separator: " ") + "\n\n[^note]: body"
        let cappedReferences = MarkdownFootnotes.process(references)

        XCTAssertEqual(cappedReferences.references.count, MarkdownFootnotes.maximumReferences)
        XCTAssertEqual(cappedReferences.references.last?.occurrence, MarkdownFootnotes.maximumReferences)
        XCTAssertTrue(cappedReferences.limitsReached.contains(.referenceCount))
        XCTAssertEqual(
            cappedReferences.bodySource.components(separatedBy: "[^note]").count - 1,
            MarkdownFootnotes.maximumReferences + 1
        )
    }

    func testOversizedInputsAreNotSilentlyRemoved() {
        let oversizedIdentifier = String(repeating: "a", count: MarkdownFootnotes.maximumIdentifierBytes + 1)
        let identifierSource = "Use[^\(oversizedIdentifier)].\n\n[^\(oversizedIdentifier)]: note"
        let identifierOutput = MarkdownFootnotes.process(identifierSource)

        XCTAssertTrue(identifierOutput.definitions.isEmpty)
        XCTAssertTrue(identifierOutput.limitsReached.contains(.identifierBytes))
        XCTAssertTrue(identifierOutput.bodySource.contains(": note"))

        let oversizedBody = String(repeating: "x", count: MarkdownFootnotes.maximumDefinitionBytes + 1)
        let bodySource = "[^large]: \(oversizedBody)"
        let bodyOutput = MarkdownFootnotes.process(bodySource)

        XCTAssertTrue(bodyOutput.definitions.isEmpty)
        XCTAssertTrue(bodyOutput.limitsReached.contains(.definitionBytes))
        XCTAssertEqual(bodyOutput.bodySource, bodySource)

        let oversizedSource = String(repeating: "x", count: MarkdownFootnotes.maximumSourceBytes + 1)
        let sourceOutput = MarkdownFootnotes.process(oversizedSource)

        XCTAssertEqual(sourceOutput.bodySource, oversizedSource)
        XCTAssertTrue(sourceOutput.definitions.isEmpty)
        XCTAssertTrue(sourceOutput.references.isEmpty)
        XCTAssertEqual(sourceOutput.limitsReached, [.sourceBytes])
    }

    func testCRLFAndTabContinuationArePreservedAndDedented() throws {
        let source = "Text[^n].\r\n\r\n[^n]: first\r\n\tsecond *line*\r\n"
        let output = MarkdownFootnotes.process(source)

        XCTAssertEqual(try XCTUnwrap(output.definitions.first).markdown, "first\r\nsecond *line*")
        XCTAssertTrue(output.bodySource.hasPrefix("Text[^n].\r\n"))
        XCTAssertFalse(output.bodySource.contains("second *line*"))
    }

    func testRepeatedUnmatchedReferenceOpenersStayLinear() {
        let source = String(repeating: "[^", count: 2 * 1_024 * 1_024)
        var output: MarkdownFootnotes.Output?

        let elapsed = ContinuousClock().measure {
            output = MarkdownFootnotes.process(source)
        }
        let components = elapsed.components
        let elapsedSeconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000

        XCTAssertEqual(output?.bodySource, source)
        XCTAssertTrue(output?.definitions.isEmpty == true)
        XCTAssertTrue(output?.references.isEmpty == true)
        XCTAssertLessThan(elapsedSeconds, 3, "Unmatched reference prefixes must not trigger repeated bounded rescans")
    }

    func testOverlongUnmatchedOpenerDoesNotHideLaterValidReference() throws {
        let malformedPrefix = "[^" + String(repeating: "x", count: MarkdownFootnotes.maximumIdentifierBytes)
        let source = malformedPrefix + "[^note]\n\n[^note]: body"

        let output = MarkdownFootnotes.process(source)
        let reference = try XCTUnwrap(output.references.first)

        XCTAssertEqual(output.references.count, 1)
        XCTAssertEqual(reference.normalizedIdentifier, "note")
        XCTAssertEqual(reference.span.lowerUTF8Column, malformedPrefix.utf8.count + 1)
    }
}
