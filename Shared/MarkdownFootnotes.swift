import Foundation
import Markdown

/// Extracts footnote definitions from Markdown without emitting HTML or inserting
/// sentinel text into the document. References remain byte-for-byte unchanged in
/// ``Output/bodySource`` and are described by source ranges for the HTML visitor.
enum MarkdownFootnotes {
    static let maximumSourceBytes = 10 * 1024 * 1024
    static let maximumDefinitions = 512
    static let maximumReferences = 4_096
    static let maximumIdentifierBytes = 256
    static let maximumDefinitionBytes = 64 * 1024
    static let maximumTotalDefinitionBytes = 2 * 1024 * 1024

    enum Limit: String, Hashable, Sendable {
        case sourceBytes
        case definitionCount
        case referenceCount
        case identifierBytes
        case definitionBytes
        case totalDefinitionBytes
    }

    /// A one-line, half-open source range. Lines and UTF-8 columns are one-based,
    /// matching swift-markdown's `SourceLocation` convention.
    struct SourceSpan: Equatable, Hashable, Sendable {
        let line: Int
        let lowerUTF8Column: Int
        let upperUTF8Column: Int
    }

    struct Definition: Equatable, Sendable {
        /// The first spelling used by the definition, with surrounding whitespace removed.
        let identifier: String
        /// Case-folded and whitespace-collapsed identifier used for matching.
        let normalizedIdentifier: String
        /// An ASCII-only identifier suitable for an HTML `id` attribute.
        let safeID: String
        /// Definition content after removing the declaration and one continuation indent.
        let markdown: String
        /// One-based definition order in the source.
        let sourceOrder: Int
        /// One-based first-reference order, or `nil` when never referenced.
        let noteNumber: Int?
    }

    struct Reference: Equatable, Sendable {
        let normalizedIdentifier: String
        let safeID: String
        /// One-based first-reference order shared by repeated references.
        let noteNumber: Int
        /// One-based occurrence count for this definition.
        let occurrence: Int
        /// `fnref-…` for the first reference and `fnref-…-N` thereafter.
        let referenceID: String
        let span: SourceSpan
    }

    struct Output: Equatable, Sendable {
        /// Markdown with accepted footnote definition blocks replaced by blank lines.
        /// Reference spelling and all non-definition source remain unchanged.
        let bodySource: String
        /// Unique accepted definitions in source order. The first case-insensitive
        /// definition wins; later duplicates are removed from the body.
        let definitions: [Definition]
        /// Recognized references in document order. Undefined, excluded, and
        /// over-limit references remain literal source and do not appear here.
        let references: [Reference]
        let limitsReached: Set<Limit>

        var referencedDefinitions: [Definition] {
            definitions
                .filter { $0.noteNumber != nil }
                .sorted { ($0.noteNumber ?? .max) < ($1.noteNumber ?? .max) }
        }

        func definition(for reference: Reference) -> Definition? {
            definitions.first { $0.normalizedIdentifier == reference.normalizedIdentifier }
        }
    }

    static func process(_ source: String) -> Output {
        guard source.utf8.count <= maximumSourceBytes else {
            return Output(
                bodySource: source,
                definitions: [],
                references: [],
                limitsReached: [.sourceBytes]
            )
        }

        var extraction = extractDefinitions(from: source)
        let exclusions = excludedRanges(in: extraction.bodySource)
        let references = collectReferences(
            in: extraction.bodySource,
            definitions: extraction.definitions,
            exclusions: exclusions,
            limitsReached: &extraction.limitsReached
        )

        var numberByIdentifier: [String: Int] = [:]
        for reference in references where numberByIdentifier[reference.normalizedIdentifier] == nil {
            numberByIdentifier[reference.normalizedIdentifier] = reference.noteNumber
        }

        let definitions = extraction.definitions.enumerated().map { index, definition in
            Definition(
                identifier: definition.identifier,
                normalizedIdentifier: definition.normalizedIdentifier,
                safeID: definition.safeID,
                markdown: definition.markdown,
                sourceOrder: index + 1,
                noteNumber: numberByIdentifier[definition.normalizedIdentifier]
            )
        }

        return Output(
            bodySource: extraction.bodySource,
            definitions: definitions,
            references: references,
            limitsReached: extraction.limitsReached
        )
    }
}

// MARK: - Definition extraction

private extension MarkdownFootnotes {
    struct SourceLine {
        let content: String
        let terminator: String

        var complete: String { content + terminator }
    }

    struct ParsedDefinition {
        let identifier: String
        let normalizedIdentifier: String
        let safeID: String
        let markdown: String
    }

    struct Extraction {
        let bodySource: String
        let definitions: [ParsedDefinition]
        var limitsReached: Set<Limit>
    }

    struct DefinitionHeader {
        let identifier: String
        let firstContent: String
    }

    struct LogicalDefinitionLine {
        let content: String
        let terminator: String
    }

    struct DefinitionBlock {
        let header: DefinitionHeader
        let endLineIndex: Int
        let logicalLines: [LogicalDefinitionLine]

        var markdown: String {
            var lines = logicalLines
            if lines.count > 1, lines.first?.content.isEmpty == true {
                lines.removeFirst()
            }
            guard !lines.isEmpty else { return "" }

            var result = ""
            for index in lines.indices {
                result += lines[index].content
                if index != lines.index(before: lines.endIndex) {
                    result += lines[index].terminator.isEmpty ? "\n" : lines[index].terminator
                }
            }
            return result
        }
    }

    struct Fence {
        let marker: UInt8
        let length: Int
    }

    static func extractDefinitions(from source: String) -> Extraction {
        let lines = splitLines(source)
        var body = ""
        body.reserveCapacity(source.utf8.count)
        var definitions: [ParsedDefinition] = []
        var definitionIndexByIdentifier: [String: Int] = [:]
        var totalDefinitionBytes = 0
        var limitsReached: Set<Limit> = []
        var activeFence: Fence?
        var lineIndex = 0

        while lineIndex < lines.count {
            let line = lines[lineIndex]

            if let fence = activeFence {
                body += line.complete
                if isClosingFence(line.content, matching: fence) {
                    activeFence = nil
                }
                lineIndex += 1
                continue
            }

            if let fence = openingFence(in: line.content) {
                activeFence = fence
                body += line.complete
                lineIndex += 1
                continue
            }

            guard let block = definitionBlock(startingAt: lineIndex, in: lines) else {
                body += line.complete
                lineIndex += 1
                continue
            }

            let rawIdentifier = block.header.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            let markdown = block.markdown
            let identifierIsTooLong = rawIdentifier.utf8.count > maximumIdentifierBytes
            let normalized = identifierIsTooLong ? nil : normalizedIdentifier(rawIdentifier)
            let normalizedIsTooLong = (normalized?.utf8.count ?? 0) > maximumIdentifierBytes

            if identifierIsTooLong || normalizedIsTooLong {
                limitsReached.insert(.identifierBytes)
                appendOriginalLines(block: block, from: lineIndex, lines: lines, to: &body)
                lineIndex = block.endLineIndex + 1
                continue
            }

            guard let normalized else {
                appendOriginalLines(block: block, from: lineIndex, lines: lines, to: &body)
                lineIndex = block.endLineIndex + 1
                continue
            }

            if definitionIndexByIdentifier[normalized] != nil {
                appendBlankLines(block: block, from: lineIndex, lines: lines, to: &body)
                lineIndex = block.endLineIndex + 1
                continue
            }

            let definitionBytes = markdown.utf8.count
            guard definitionBytes <= maximumDefinitionBytes else {
                limitsReached.insert(.definitionBytes)
                appendOriginalLines(block: block, from: lineIndex, lines: lines, to: &body)
                lineIndex = block.endLineIndex + 1
                continue
            }
            guard definitions.count < maximumDefinitions else {
                limitsReached.insert(.definitionCount)
                appendOriginalLines(block: block, from: lineIndex, lines: lines, to: &body)
                lineIndex = block.endLineIndex + 1
                continue
            }
            guard totalDefinitionBytes <= maximumTotalDefinitionBytes - definitionBytes else {
                limitsReached.insert(.totalDefinitionBytes)
                appendOriginalLines(block: block, from: lineIndex, lines: lines, to: &body)
                lineIndex = block.endLineIndex + 1
                continue
            }

            let parsed = ParsedDefinition(
                identifier: rawIdentifier,
                normalizedIdentifier: normalized,
                safeID: safeID(for: normalized),
                markdown: markdown
            )
            definitionIndexByIdentifier[normalized] = definitions.count
            definitions.append(parsed)
            totalDefinitionBytes += definitionBytes
            appendBlankLines(block: block, from: lineIndex, lines: lines, to: &body)
            lineIndex = block.endLineIndex + 1
        }

        return Extraction(bodySource: body, definitions: definitions, limitsReached: limitsReached)
    }

    static func definitionBlock(startingAt index: Int, in lines: [SourceLine]) -> DefinitionBlock? {
        guard let header = definitionHeader(in: lines[index].content) else { return nil }

        var logicalLines = [LogicalDefinitionLine(
            content: header.firstContent,
            terminator: lines[index].terminator
        )]
        var endLineIndex = index
        var cursor = index + 1

        while cursor < lines.count {
            if let continuation = continuationContent(lines[cursor].content) {
                logicalLines.append(LogicalDefinitionLine(
                    content: continuation,
                    terminator: lines[cursor].terminator
                ))
                endLineIndex = cursor
                cursor += 1
                continue
            }

            guard isBlank(lines[cursor].content) else { break }
            var nextNonBlank = cursor
            while nextNonBlank < lines.count, isBlank(lines[nextNonBlank].content) {
                nextNonBlank += 1
            }
            guard nextNonBlank < lines.count,
                  continuationContent(lines[nextNonBlank].content) != nil else {
                break
            }

            while cursor < nextNonBlank {
                logicalLines.append(LogicalDefinitionLine(
                    content: "",
                    terminator: lines[cursor].terminator
                ))
                endLineIndex = cursor
                cursor += 1
            }
        }

        return DefinitionBlock(
            header: header,
            endLineIndex: endLineIndex,
            logicalLines: logicalLines
        )
    }

    static func definitionHeader(in line: String) -> DefinitionHeader? {
        var index = line.startIndex
        var leadingSpaces = 0
        while index < line.endIndex, line[index] == " ", leadingSpaces < 4 {
            leadingSpaces += 1
            index = line.index(after: index)
        }
        guard leadingSpaces <= 3,
              index < line.endIndex,
              line[index] == "[" else { return nil }

        index = line.index(after: index)
        guard index < line.endIndex, line[index] == "^" else { return nil }
        let identifierStart = line.index(after: index)
        var closingBracket = identifierStart
        while closingBracket < line.endIndex, line[closingBracket] != "]" {
            closingBracket = line.index(after: closingBracket)
        }
        guard closingBracket < line.endIndex, closingBracket != identifierStart else { return nil }

        let colon = line.index(after: closingBracket)
        guard colon < line.endIndex, line[colon] == ":" else { return nil }

        var contentStart = line.index(after: colon)
        if contentStart < line.endIndex,
           line[contentStart] == " " || line[contentStart] == "\t" {
            contentStart = line.index(after: contentStart)
        }

        return DefinitionHeader(
            identifier: String(line[identifierStart..<closingBracket]),
            firstContent: String(line[contentStart...])
        )
    }

    static func continuationContent(_ line: String) -> String? {
        if line.hasPrefix("\t") {
            return String(line.dropFirst())
        }
        guard line.hasPrefix("    ") else { return nil }
        return String(line.dropFirst(4))
    }

    static func appendOriginalLines(
        block: DefinitionBlock,
        from start: Int,
        lines: [SourceLine],
        to body: inout String
    ) {
        for index in start...block.endLineIndex {
            body += lines[index].complete
        }
    }

    static func appendBlankLines(
        block: DefinitionBlock,
        from start: Int,
        lines: [SourceLine],
        to body: inout String
    ) {
        for index in start...block.endLineIndex {
            body += lines[index].terminator
        }
    }

    static func splitLines(_ source: String) -> [SourceLine] {
        let bytes = Array(source.utf8)
        var lines: [SourceLine] = []
        var lineStart = 0
        var index = 0

        while index < bytes.count {
            if bytes[index] == 0x0A {
                lines.append(SourceLine(
                    content: String(decoding: bytes[lineStart..<index], as: UTF8.self),
                    terminator: "\n"
                ))
                index += 1
                lineStart = index
            } else if bytes[index] == 0x0D {
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    lines.append(SourceLine(
                        content: String(decoding: bytes[lineStart..<index], as: UTF8.self),
                        terminator: "\r\n"
                    ))
                    index += 2
                } else {
                    lines.append(SourceLine(
                        content: String(decoding: bytes[lineStart..<index], as: UTF8.self),
                        terminator: "\r"
                    ))
                    index += 1
                }
                lineStart = index
            } else {
                index += 1
            }
        }

        if lineStart < bytes.count || source.isEmpty {
            lines.append(SourceLine(
                content: String(decoding: bytes[lineStart...], as: UTF8.self),
                terminator: ""
            ))
        }
        return lines
    }

    static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }
}

// MARK: - Reference discovery

private extension MarkdownFootnotes {
    struct Position: Comparable {
        let line: Int
        let utf8Column: Int

        static func < (lhs: Position, rhs: Position) -> Bool {
            lhs.line == rhs.line
                ? lhs.utf8Column < rhs.utf8Column
                : lhs.line < rhs.line
        }
    }

    struct ExcludedRange {
        let lowerBound: Position
        let upperBound: Position

        func contains(_ span: SourceSpan) -> Bool {
            let spanStart = Position(line: span.line, utf8Column: span.lowerUTF8Column)
            let spanEnd = Position(line: span.line, utf8Column: span.upperUTF8Column)
            return !(spanStart < lowerBound) && !(upperBound < spanEnd)
        }
    }

    struct ExclusionCollector: MarkupWalker {
        var ranges: [ExcludedRange] = []

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) { record(codeBlock) }
        mutating func visitInlineCode(_ inlineCode: InlineCode) { record(inlineCode) }
        mutating func visitLink(_ link: Link) { record(link) }
        mutating func visitImage(_ image: Image) { record(image) }
        mutating func visitHTMLBlock(_ htmlBlock: HTMLBlock) { record(htmlBlock) }
        mutating func visitInlineHTML(_ inlineHTML: InlineHTML) { record(inlineHTML) }

        private mutating func record(_ markup: Markup) {
            guard let range = markup.range else { return }
            ranges.append(ExcludedRange(
                lowerBound: Position(
                    line: range.lowerBound.line,
                    utf8Column: range.lowerBound.column
                ),
                upperBound: Position(
                    line: range.upperBound.line,
                    utf8Column: range.upperBound.column
                )
            ))
        }
    }

    static func excludedRanges(in source: String) -> [ExcludedRange] {
        let document = Document(parsing: source)
        var collector = ExclusionCollector()
        collector.visit(document)
        return collector.ranges.sorted {
            if $0.lowerBound == $1.lowerBound {
                return $0.upperBound < $1.upperBound
            }
            return $0.lowerBound < $1.lowerBound
        }
    }

    static func collectReferences(
        in source: String,
        definitions: [ParsedDefinition],
        exclusions: [ExcludedRange],
        limitsReached: inout Set<Limit>
    ) -> [Reference] {
        let definitionsByIdentifier = Dictionary(
            uniqueKeysWithValues: definitions.map { ($0.normalizedIdentifier, $0) }
        )
        let lines = splitLines(source)
        var references: [Reference] = []
        var noteNumberByIdentifier: [String: Int] = [:]
        var occurrenceByIdentifier: [String: Int] = [:]
        var nextNoteNumber = 1
        var exclusionIndex = 0

        for (zeroBasedLine, line) in lines.enumerated() {
            let bytes = Array(line.content.utf8)
            guard !bytes.isEmpty, !isLinkReferenceDefinition(bytes) else { continue }
            var byteIndex = 0
            var nextClosingBracket: Int?
            var closingBracketSearchIndex = 0

            while byteIndex + 3 < bytes.count {
                guard bytes[byteIndex] == 0x5B, // [
                      bytes[byteIndex + 1] == 0x5E, // ^
                      !isEscaped(bytes, at: byteIndex),
                      (byteIndex == 0 || bytes[byteIndex - 1] != 0x21) else { // !
                    byteIndex += 1
                    continue
                }

                let identifierStart = byteIndex + 2
                if nextClosingBracket == nil || nextClosingBracket! < identifierStart {
                    var searchIndex = max(closingBracketSearchIndex, identifierStart)
                    while searchIndex < bytes.count, bytes[searchIndex] != 0x5D {
                        searchIndex += 1
                    }
                    nextClosingBracket = searchIndex < bytes.count ? searchIndex : nil
                    closingBracketSearchIndex = min(searchIndex + 1, bytes.count)
                }

                let bytesBeforeClosingBracket = (nextClosingBracket ?? bytes.count) - identifierStart
                let identifierBytes = min(bytesBeforeClosingBracket, maximumIdentifierBytes + 1)
                guard let closingBracket = nextClosingBracket,
                      bytesBeforeClosingBracket <= maximumIdentifierBytes + 1 else {
                    if identifierBytes > maximumIdentifierBytes {
                        limitsReached.insert(.identifierBytes)
                    }
                    byteIndex += 1
                    continue
                }
                guard closingBracket > byteIndex + 2 else {
                    byteIndex = closingBracket + 1
                    continue
                }
                if closingBracket + 1 < bytes.count, bytes[closingBracket + 1] == 0x3A { // :
                    byteIndex = closingBracket + 1
                    continue
                }

                let span = SourceSpan(
                    line: zeroBasedLine + 1,
                    lowerUTF8Column: byteIndex + 1,
                    upperUTF8Column: closingBracket + 2
                )
                while exclusionIndex < exclusions.count,
                      !(Position(line: span.line, utf8Column: span.lowerUTF8Column) < exclusions[exclusionIndex].upperBound) {
                    exclusionIndex += 1
                }
                if exclusionIndex < exclusions.count, exclusions[exclusionIndex].contains(span) {
                    byteIndex = closingBracket + 1
                    continue
                }

                let rawIdentifier = String(decoding: bytes[(byteIndex + 2)..<closingBracket], as: UTF8.self)
                guard rawIdentifier.utf8.count <= maximumIdentifierBytes,
                      let normalized = normalizedIdentifier(rawIdentifier),
                      normalized.utf8.count <= maximumIdentifierBytes,
                      let definition = definitionsByIdentifier[normalized] else {
                    byteIndex = closingBracket + 1
                    continue
                }

                guard references.count < maximumReferences else {
                    limitsReached.insert(.referenceCount)
                    byteIndex = closingBracket + 1
                    continue
                }

                let noteNumber: Int
                if let existing = noteNumberByIdentifier[normalized] {
                    noteNumber = existing
                } else {
                    noteNumber = nextNoteNumber
                    noteNumberByIdentifier[normalized] = noteNumber
                    nextNoteNumber += 1
                }
                let occurrence = (occurrenceByIdentifier[normalized] ?? 0) + 1
                occurrenceByIdentifier[normalized] = occurrence
                let referenceID = occurrence == 1
                    ? "fnref-\(definition.safeID.dropFirst(3))"
                    : "fnref-\(definition.safeID.dropFirst(3))-\(occurrence)"

                references.append(Reference(
                    normalizedIdentifier: normalized,
                    safeID: definition.safeID,
                    noteNumber: noteNumber,
                    occurrence: occurrence,
                    referenceID: referenceID,
                    span: span
                ))
                byteIndex = closingBracket + 1
            }
        }

        return references
    }

    static func isEscaped(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index > 0 else { return false }
        var backslashCount = 0
        var cursor = index
        while cursor > 0, bytes[cursor - 1] == 0x5C {
            backslashCount += 1
            cursor -= 1
        }
        return backslashCount.isMultiple(of: 2) == false
    }

    static func isLinkReferenceDefinition(_ bytes: [UInt8]) -> Bool {
        var index = 0
        while index < bytes.count, bytes[index] == 0x20, index < 4 {
            index += 1
        }
        guard index <= 3, index < bytes.count, bytes[index] == 0x5B else { return false }
        index += 1
        guard index < bytes.count, bytes[index] != 0x5E else { return false }
        while index < bytes.count, bytes[index] != 0x5D {
            index += 1
        }
        return index + 1 < bytes.count && bytes[index + 1] == 0x3A
    }
}

// MARK: - Identifier and fence helpers

private extension MarkdownFootnotes {
    static let identifierLocale = Locale(identifier: "en_US_POSIX")

    static func normalizedIdentifier(_ identifier: String) -> String? {
        let folded = identifier
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: identifierLocale)
        let collapsed = folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty,
              !collapsed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return collapsed.precomposedStringWithCanonicalMapping
    }

    static func safeID(for normalizedIdentifier: String) -> String {
        let hex = Array("0123456789abcdef".utf8)
        var bytes = Array("fn-".utf8)
        bytes.reserveCapacity(3 + normalizedIdentifier.utf8.count * 2)
        for byte in normalizedIdentifier.utf8 {
            bytes.append(hex[Int(byte >> 4)])
            bytes.append(hex[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func openingFence(in line: String) -> Fence? {
        let bytes = Array(line.utf8)
        var index = 0
        while index < bytes.count, bytes[index] == 0x20, index < 4 {
            index += 1
        }
        guard index <= 3, index < bytes.count,
              bytes[index] == 0x60 || bytes[index] == 0x7E else { return nil }

        let marker = bytes[index]
        let start = index
        while index < bytes.count, bytes[index] == marker {
            index += 1
        }
        let length = index - start
        guard length >= 3 else { return nil }
        if marker == 0x60, bytes[index...].contains(0x60) {
            return nil
        }
        return Fence(marker: marker, length: length)
    }

    static func isClosingFence(_ line: String, matching fence: Fence) -> Bool {
        let bytes = Array(line.utf8)
        var index = 0
        while index < bytes.count, bytes[index] == 0x20, index < 4 {
            index += 1
        }
        guard index <= 3, index < bytes.count, bytes[index] == fence.marker else { return false }

        let start = index
        while index < bytes.count, bytes[index] == fence.marker {
            index += 1
        }
        guard index - start >= fence.length else { return false }
        return bytes[index...].allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }
}
