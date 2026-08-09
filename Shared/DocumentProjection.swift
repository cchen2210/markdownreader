import CryptoKit
import Foundation
import Markdown

/// The byte coordinate used by durable selectors. Offsets are zero based and
/// ranges are half open in a UTF-8 view of canonical text.
struct UTF8ByteRange: Codable, Equatable, Hashable, Sendable {
    let lowerBound: Int
    let upperBound: Int

    init(_ lowerBound: Int, _ upperBound: Int) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    var count: Int { upperBound - lowerBound }
    var isEmpty: Bool { lowerBound == upperBound }

    func overlaps(_ other: UTF8ByteRange) -> Bool {
        lowerBound < other.upperBound && other.lowerBound < upperBound
    }

    func contains(_ other: UTF8ByteRange) -> Bool {
        lowerBound <= other.lowerBound && other.upperBound <= upperBound
    }
}

struct UTF16CodeUnitRange: Codable, Equatable, Hashable, Sendable {
    let lowerBound: Int
    let upperBound: Int

    init(_ lowerBound: Int, _ upperBound: Int) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    var count: Int { upperBound - lowerBound }
}

enum ProjectedSourceEncoding: String, Codable, Equatable, Sendable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
}

enum ProjectedSourceBOM: String, Codable, Equatable, Sendable {
    case none
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
}

struct ProjectionSourceMetadata: Codable, Equatable, Sendable {
    /// SHA-256 of the exact coordinated bytes, including any BOM.
    let revisionHash: String
    let byteCount: Int
    let encoding: ProjectedSourceEncoding
    let byteOrderMark: ProjectedSourceBOM
}

enum SemanticBlockKind: String, Codable, CaseIterable, Sendable {
    case paragraph
    case heading
    case listItem
    case blockQuote
    case codeBlock
    case tableCell
    case rawHTML
}

enum ProjectionUnsupportedReason: String, Codable, Equatable, Sendable {
    case complexListItem
    case complexBlockQuote
    case rawHTML
    case inlineHTML
    case footnoteStructure
    case unsupportedInlineMarkup
    case unavailableDOMMapping

    var explanation: String {
        switch self {
        case .complexListItem:
            "This list item contains nested block structure. Remember a simpler single-block passage."
        case .complexBlockQuote:
            "This quotation contains nested block structure. Remember a simpler single-block passage."
        case .rawHTML, .inlineHTML:
            "Selections containing raw HTML cannot be remembered safely."
        case .footnoteStructure:
            "Selections containing a footnote marker cannot be remembered in this release."
        case .unsupportedInlineMarkup:
            "This selection contains Markdown structure that cannot be mapped safely."
        case .unavailableDOMMapping:
            "This selection does not map to a Unicode boundary. Select the passage again."
        }
    }
}

enum ProjectionCapability: Codable, Equatable, Sendable {
    case supported
    case supportedExcept([ProjectionUnsupportedReason])
    case unsupported(ProjectionUnsupportedReason)

    var permitsAnySelection: Bool {
        if case .unsupported = self { return false }
        return true
    }
}

enum ProjectionTextRunKind: String, Codable, Equatable, Sendable {
    case text
    case softBreak
    case hardBreak
    case inlineCode
    case footnoteReference
    case inlineHTML
    case unsupported
}

struct HeadingBreadcrumb: Codable, Equatable, Hashable, Sendable {
    let level: Int
    let title: String
}

/// A source range in the UTF-8 view of the decoded Markdown string. This is not
/// a file-byte range for UTF-16 input and is intentionally named accordingly.
struct DecodedSourceUTF8Span: Codable, Equatable, Hashable, Sendable {
    let range: UTF8ByteRange
}

struct ProjectionTextRun: Codable, Equatable, Sendable {
    /// Globally unique only within one projection (`run-0`, `run-1`, ...).
    let id: String
    let blockID: String
    let kind: ProjectionTextRunKind
    /// Text represented by the DOM hook. Soft breaks are one space and hard
    /// breaks are one newline.
    let domText: String
    let domUTF16RangeInBlock: UTF16CodeUnitRange
    /// Nil only when NFC composition crosses the run boundary. Selection
    /// mapping still works for valid interior boundaries via the block text.
    let canonicalUTF8RangeInBlock: UTF8ByteRange?
    let sourceUTF8Span: DecodedSourceUTF8Span?
    let unsupportedReason: ProjectionUnsupportedReason?
}

struct HeadingSection: Codable, Equatable, Sendable {
    let id: String
    let headingPath: [HeadingBreadcrumb]
    let headingLevel: Int?
    let lowerBlockOrdinal: Int
    let upperBlockOrdinal: Int

    func contains(blockOrdinal: Int) -> Bool {
        lowerBlockOrdinal <= blockOrdinal && blockOrdinal < upperBlockOrdinal
    }
}

struct SemanticBlock: Codable, Equatable, Sendable {
    /// Deterministic only within a projection (`block-0`, `block-1`, ...).
    let id: String
    let kind: SemanticBlockKind
    let ordinal: Int
    let headingLevel: Int?
    let headingPath: [HeadingBreadcrumb]
    let headingSectionID: String
    let canonicalText: String
    let canonicalUTF8RangeInDocument: UTF8ByteRange
    let sourceUTF8Span: DecodedSourceUTF8Span?
    let fingerprint: String
    let captureCapability: ProjectionCapability
    let highlightCapability: ProjectionCapability
    let textRuns: [ProjectionTextRun]

    var canonicalUTF8Count: Int { canonicalText.utf8.count }
}

struct DOMProjectionPoint: Codable, Equatable, Sendable {
    let runID: String
    /// Offset in the run's UTF-16 DOM text, matching JavaScript DOM Range.
    let utf16Offset: Int
}

struct DOMProjectionSelection: Codable, Equatable, Sendable {
    let sourceRevisionHash: String
    let renderRevision: UUID
    let projectionVersion: Int
    let blockID: String
    let start: DOMProjectionPoint
    let end: DOMProjectionPoint
    let selectedVisibleText: String
}

struct DOMProjectionReadingPosition: Codable, Equatable, Sendable {
    let sourceRevisionHash: String
    let renderRevision: UUID
    let projectionVersion: Int
    let blockID: String
    let point: DOMProjectionPoint
    let fallbackScrollFraction: Double
}

struct ProjectionReadingPosition: Equatable, Sendable {
    let blockID: String
    let blockFingerprint: String
    let canonicalUTF8OffsetInBlock: Int64
    let canonicalUTF8OffsetInDocument: Int64
    let headingPath: [HeadingBreadcrumb]
}

struct ProjectionReadingRestoreTarget: Equatable, Sendable {
    let blockID: String
    let point: DOMProjectionPoint
}

struct ProjectionSelection: Codable, Equatable, Sendable {
    let sourceRevisionHash: String
    let renderRevision: UUID
    let projectionVersion: Int
    let blockID: String
    let canonicalUTF8RangeInBlock: UTF8ByteRange
    let selectedVisibleText: String
    let runIDs: [String]
}

enum DocumentProjectionError: Error, Equatable, LocalizedError {
    case sourceTooLarge(Int)
    case unsupportedEncoding
    case invalidByteOrderMark
    case sourceSnapshotMismatch
    case staleSourceRevision
    case staleRenderRevision
    case staleProjectionVersion
    case unknownBlock(String)
    case unknownRun(String)
    case runBelongsToAnotherBlock(String)
    case reversedSelection
    case emptySelection
    case offsetOutsideRun(String)
    case nonScalarDOMBoundary(String)
    case nonScalarCanonicalBoundary
    case selectedTextMismatch
    case unsupportedSelection(ProjectionUnsupportedReason)
    case overlappingSelection

    var errorDescription: String? {
        switch self {
        case .sourceTooLarge:
            "This document is too large to build Reading Memory anchors."
        case .unsupportedEncoding, .invalidByteOrderMark:
            "Reading Memory supports UTF-8 and BOM-marked UTF-16 Markdown."
        case .sourceSnapshotMismatch:
            "The rendered text does not match the coordinated document bytes. Reload the document and select it again."
        case .staleSourceRevision, .staleRenderRevision, .staleProjectionVersion:
            "The document changed after the passage was selected. Select it again."
        case .unknownBlock, .unknownRun, .runBelongsToAnotherBlock,
             .reversedSelection, .offsetOutsideRun, .nonScalarDOMBoundary,
             .nonScalarCanonicalBoundary:
            "The selected passage could not be mapped safely. Select it again."
        case .emptySelection:
            "Select a passage before remembering it."
        case .selectedTextMismatch:
            "The selected text changed before it could be remembered. Select it again."
        case let .unsupportedSelection(reason):
            reason.explanation
        case .overlappingSelection:
            "This passage overlaps an existing memory. Open that memory instead."
        }
    }
}

enum CanonicalMarkdownText {
    static let rulesVersion = 1

    /// V1: CRLF becomes LF and visible text is normalized to NFC. Soft and
    /// hard break handling happens in the AST projector before this function.
    static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .precomposedStringWithCanonicalMapping
    }

    static func substring(_ text: String, utf8Range: UTF8ByteRange) -> String? {
        guard let indices = scalarBoundaryIndices(in: text, range: utf8Range) else { return nil }
        return String(text[indices.lowerBound..<indices.upperBound])
    }

    static func isScalarBoundary(_ offset: Int, in text: String) -> Bool {
        guard offset >= 0, offset <= text.utf8.count else { return false }
        let utf8Index = text.utf8.index(text.utf8.startIndex, offsetBy: offset)
        return String.Index(utf8Index, within: text) != nil
    }

    static func utf8Offset(forUTF16Offset offset: Int, in value: String) -> Int? {
        guard offset >= 0, offset <= value.utf16.count else { return nil }
        let utf16Index = value.utf16.index(value.utf16.startIndex, offsetBy: offset)
        guard let stringIndex = String.Index(utf16Index, within: value) else { return nil }
        return value.utf8.distance(from: value.utf8.startIndex, to: stringIndex)
    }

    /// NFC does not compose across extended grapheme-cluster boundaries. This
    /// table makes the overwhelmingly common DOM/canonical mapping linear in
    /// block size instead of repeatedly normalizing every run prefix.
    static func normalizationBoundaries(
        in value: String
    ) -> [(domUTF16Offset: Int, canonicalUTF8Offset: Int)] {
        var boundaries = [(domUTF16Offset: 0, canonicalUTF8Offset: 0)]
        boundaries.reserveCapacity(value.count + 1)
        var domOffset = 0
        var canonicalOffset = 0
        for character in value {
            let fragment = String(character)
            domOffset += fragment.utf16.count
            canonicalOffset += normalize(fragment).utf8.count
            boundaries.append((domOffset, canonicalOffset))
        }
        return boundaries
    }

    private static func scalarBoundaryIndices(
        in text: String,
        range: UTF8ByteRange
    ) -> (lowerBound: String.Index, upperBound: String.Index)? {
        guard range.lowerBound >= 0,
              range.upperBound >= range.lowerBound,
              range.upperBound <= text.utf8.count else { return nil }
        let lowerUTF8 = text.utf8.index(text.utf8.startIndex, offsetBy: range.lowerBound)
        let upperUTF8 = text.utf8.index(text.utf8.startIndex, offsetBy: range.upperBound)
        guard let lower = String.Index(lowerUTF8, within: text),
              let upper = String.Index(upperUTF8, within: text) else { return nil }
        return (lower, upper)
    }
}

struct DocumentProjection: Sendable {
    static let currentVersion = 1
    static let currentSelectorVersion = 1
    static let maximumSourceBytes = 10 * 1024 * 1024

    let version: Int
    let canonicalRulesVersion: Int
    let renderRevision: UUID
    let source: ProjectionSourceMetadata
    let canonicalText: String
    let blocks: [SemanticBlock]
    let headingSections: [HeadingSection]

    static func build(
        sourceData: Data,
        documentURL: URL? = nil,
        renderRevision: UUID = UUID(),
        expectedDisplaySource: String? = nil
    ) throws -> DocumentProjection {
        guard sourceData.count <= maximumSourceBytes else {
            throw DocumentProjectionError.sourceTooLarge(sourceData.count)
        }

        let decoded = try DecodedProjectionSource(data: sourceData)
        // Keep the AST's visible text byte-for-byte aligned with the existing
        // safe renderer while retaining the hash of the original file bytes.
        let displaySource = MarkdownTextSafety.sanitizedForDisplay(decoded.text)
        if let expectedDisplaySource, displaySource != expectedDisplaySource {
            throw DocumentProjectionError.sourceSnapshotMismatch
        }
        let footnotes = MarkdownFootnotes.process(displaySource)
        let document = Document(parsing: footnotes.bodySource, source: documentURL)
        let sourceIndex = DecodedSourceIndex(footnotes.bodySource)
        var collector = ProjectionBlockCollector(
            sourceIndex: sourceIndex,
            footnotes: footnotes
        )
        collector.collect(document)

        let metadata = ProjectionSourceMetadata(
            revisionHash: SHA256.hexDigest(sourceData),
            byteCount: sourceData.count,
            encoding: decoded.encoding,
            byteOrderMark: decoded.bom
        )
        return collector.finish(
            renderRevision: renderRevision,
            source: metadata
        )
    }

    func block(id: String) -> SemanticBlock? {
        blocks.first { $0.id == id }
    }

    func section(id: String) -> HeadingSection? {
        headingSections.first { $0.id == id }
    }

    func selection(fromDOM request: DOMProjectionSelection) throws -> ProjectionSelection {
        guard request.sourceRevisionHash == source.revisionHash else {
            throw DocumentProjectionError.staleSourceRevision
        }
        guard request.renderRevision == renderRevision else {
            throw DocumentProjectionError.staleRenderRevision
        }
        guard request.projectionVersion == version else {
            throw DocumentProjectionError.staleProjectionVersion
        }
        guard let block = block(id: request.blockID) else {
            throw DocumentProjectionError.unknownBlock(request.blockID)
        }
        guard block.captureCapability.permitsAnySelection else {
            if case let .unsupported(reason) = block.captureCapability {
                throw DocumentProjectionError.unsupportedSelection(reason)
            }
            throw DocumentProjectionError.unsupportedSelection(.unsupportedInlineMarkup)
        }

        let start = try canonicalOffset(for: request.start, in: block)
        let end = try canonicalOffset(for: request.end, in: block)
        guard start <= end else { throw DocumentProjectionError.reversedSelection }
        guard start != end else { throw DocumentProjectionError.emptySelection }
        let range = UTF8ByteRange(start, end)
        guard let expected = CanonicalMarkdownText.substring(block.canonicalText, utf8Range: range) else {
            throw DocumentProjectionError.nonScalarCanonicalBoundary
        }

        let intersectingRuns = block.textRuns.filter { run in
            guard let runRange = run.canonicalUTF8RangeInBlock else { return true }
            return runRange.overlaps(range)
        }
        if let reason = intersectingRuns.compactMap(\.unsupportedReason).first {
            throw DocumentProjectionError.unsupportedSelection(reason)
        }
        let supplied = CanonicalMarkdownText.normalize(request.selectedVisibleText)
        guard supplied == expected else {
            throw DocumentProjectionError.selectedTextMismatch
        }

        return ProjectionSelection(
            sourceRevisionHash: source.revisionHash,
            renderRevision: renderRevision,
            projectionVersion: version,
            blockID: block.id,
            canonicalUTF8RangeInBlock: range,
            selectedVisibleText: request.selectedVisibleText,
            runIDs: intersectingRuns.map(\.id)
        )
    }

    func readingPosition(fromDOM request: DOMProjectionReadingPosition) throws -> ProjectionReadingPosition {
        guard request.sourceRevisionHash == source.revisionHash else {
            throw DocumentProjectionError.staleSourceRevision
        }
        guard request.renderRevision == renderRevision else {
            throw DocumentProjectionError.staleRenderRevision
        }
        guard request.projectionVersion == version else {
            throw DocumentProjectionError.staleProjectionVersion
        }
        guard let block = block(id: request.blockID) else {
            throw DocumentProjectionError.unknownBlock(request.blockID)
        }
        let localOffset = try canonicalOffset(for: request.point, in: block)
        let globalOffset = block.canonicalUTF8RangeInDocument.lowerBound + localOffset
        guard globalOffset <= block.canonicalUTF8RangeInDocument.upperBound else {
            throw DocumentProjectionError.offsetOutsideRun(request.point.runID)
        }
        return ProjectionReadingPosition(
            blockID: block.id,
            blockFingerprint: block.fingerprint,
            canonicalUTF8OffsetInBlock: Int64(localOffset),
            canonicalUTF8OffsetInDocument: Int64(globalOffset),
            headingPath: block.headingPath
        )
    }

    /// Maps a durable block-local canonical byte offset back to the exact DOM
    /// run point for the current render. Returning nil is intentional: callers
    /// then fall back to the block start or the fractional position rather
    /// than guessing across a Unicode or renderer boundary.
    func readingRestoreTarget(
        blockID: String,
        canonicalUTF8OffsetInBlock storedOffset: Int64
    ) -> ProjectionReadingRestoreTarget? {
        guard storedOffset >= 0,
              storedOffset <= Int64(Int.max),
              let block = block(id: blockID) else { return nil }
        let canonicalOffset = Int(storedOffset)
        guard canonicalOffset <= block.canonicalUTF8Count,
              CanonicalMarkdownText.isScalarBoundary(canonicalOffset, in: block.canonicalText),
              let domOffset = domUTF16Offset(
                  forCanonicalUTF8Offset: canonicalOffset,
                  in: block
              ) else { return nil }

        let run: ProjectionTextRun?
        if domOffset == block.textRuns.last?.domUTF16RangeInBlock.upperBound {
            run = block.textRuns.last
        } else {
            run = block.textRuns.first { candidate in
                candidate.domUTF16RangeInBlock.lowerBound <= domOffset
                    && domOffset < candidate.domUTF16RangeInBlock.upperBound
            }
        }
        guard let run else { return nil }
        return ProjectionReadingRestoreTarget(
            blockID: block.id,
            point: DOMProjectionPoint(
                runID: run.id,
                utf16Offset: domOffset - run.domUTF16RangeInBlock.lowerBound
            )
        )
    }

    private func canonicalOffset(
        for point: DOMProjectionPoint,
        in block: SemanticBlock
    ) throws -> Int {
        guard let run = block.textRuns.first(where: { $0.id == point.runID }) else {
            if blocks.lazy.flatMap(\.textRuns).contains(where: { $0.id == point.runID }) {
                throw DocumentProjectionError.runBelongsToAnotherBlock(point.runID)
            }
            throw DocumentProjectionError.unknownRun(point.runID)
        }
        guard point.utf16Offset >= 0, point.utf16Offset <= run.domText.utf16.count else {
            throw DocumentProjectionError.offsetOutsideRun(point.runID)
        }

        let absoluteDOMOffset = run.domUTF16RangeInBlock.lowerBound + point.utf16Offset
        let domText = block.textRuns.map(\.domText).joined()
        guard let rawIndex = stringIndex(atUTF16Offset: absoluteDOMOffset, in: domText) else {
            throw DocumentProjectionError.nonScalarDOMBoundary(point.runID)
        }
        let prefix = String(domText[..<rawIndex])
        let canonicalOffset = CanonicalMarkdownText.normalize(prefix).utf8.count
        guard CanonicalMarkdownText.isScalarBoundary(canonicalOffset, in: block.canonicalText) else {
            throw DocumentProjectionError.nonScalarCanonicalBoundary
        }
        return canonicalOffset
    }

    private func domUTF16Offset(
        forCanonicalUTF8Offset target: Int,
        in block: SemanticBlock
    ) -> Int? {
        let domText = block.textRuns.map(\.domText).joined()
        if let boundary = CanonicalMarkdownText.normalizationBoundaries(in: domText)
            .first(where: { $0.canonicalUTF8Offset == target }) {
            return boundary.domUTF16Offset
        }

        // A valid byte boundary may sit inside one extended grapheme cluster.
        // Walk Unicode scalars only for that uncommon case.
        var utf16Offset = 0
        var scalarIndex = domText.unicodeScalars.startIndex
        while true {
            guard let index = scalarIndex.samePosition(in: domText) else { return nil }
            let prefix = String(domText[..<index])
            let canonicalOffset = CanonicalMarkdownText.normalize(prefix).utf8.count
            if canonicalOffset == target { return utf16Offset }
            if canonicalOffset > target || scalarIndex == domText.unicodeScalars.endIndex {
                return nil
            }
            let scalar = domText.unicodeScalars[scalarIndex]
            utf16Offset += scalar.utf16.count
            scalarIndex = domText.unicodeScalars.index(after: scalarIndex)
        }
    }

    private func stringIndex(atUTF16Offset offset: Int, in value: String) -> String.Index? {
        guard offset >= 0, offset <= value.utf16.count else { return nil }
        let index = value.utf16.index(value.utf16.startIndex, offsetBy: offset)
        return String.Index(index, within: value)
    }
}

// MARK: - Source decoding

private struct DecodedProjectionSource {
    let text: String
    let encoding: ProjectedSourceEncoding
    let bom: ProjectedSourceBOM

    init(data: Data) throws {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            let payload = data.dropFirst(3)
            guard let text = String(data: payload, encoding: .utf8) else {
                throw DocumentProjectionError.invalidByteOrderMark
            }
            self.init(text: text, encoding: .utf8, bom: .utf8)
            return
        }
        if data.starts(with: [0xFF, 0xFE]) {
            guard let text = String(data: data, encoding: .utf16LittleEndian) else {
                throw DocumentProjectionError.invalidByteOrderMark
            }
            self.init(
                text: text.first == "\u{FEFF}" ? String(text.dropFirst()) : text,
                encoding: .utf16LittleEndian,
                bom: .utf16LittleEndian
            )
            return
        }
        if data.starts(with: [0xFE, 0xFF]) {
            guard let text = String(data: data, encoding: .utf16BigEndian) else {
                throw DocumentProjectionError.invalidByteOrderMark
            }
            self.init(
                text: text.first == "\u{FEFF}" ? String(text.dropFirst()) : text,
                encoding: .utf16BigEndian,
                bom: .utf16BigEndian
            )
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw DocumentProjectionError.unsupportedEncoding
        }
        self.init(text: text, encoding: .utf8, bom: .none)
    }

    private init(
        text: String,
        encoding: ProjectedSourceEncoding,
        bom: ProjectedSourceBOM
    ) {
        self.text = text
        self.encoding = encoding
        self.bom = bom
    }
}

private struct DecodedSourceIndex {
    let source: String
    let lineStartUTF8Offsets: [Int]

    init(_ source: String) {
        self.source = source
        let bytes = Array(source.utf8)
        var starts = [0]
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0D {
                index += 1
                if index < bytes.count, bytes[index] == 0x0A { index += 1 }
                starts.append(index)
            } else if bytes[index] == 0x0A {
                index += 1
                starts.append(index)
            } else {
                index += 1
            }
        }
        lineStartUTF8Offsets = starts
    }

    func span(for range: SourceRange?) -> DecodedSourceUTF8Span? {
        guard let range,
              let lower = offset(for: range.lowerBound),
              let upper = offset(for: range.upperBound),
              lower <= upper else { return nil }
        return DecodedSourceUTF8Span(range: UTF8ByteRange(lower, upper))
    }

    func exactSpan(for range: SourceRange?, visibleText: String) -> DecodedSourceUTF8Span? {
        guard let span = span(for: range),
              let sourceSlice = CanonicalMarkdownText.substring(
                  source,
                  utf8Range: span.range
              ),
              sourceSlice == visibleText else { return nil }
        return span
    }

    private func offset(for location: SourceLocation) -> Int? {
        let lineIndex = location.line - 1
        guard lineStartUTF8Offsets.indices.contains(lineIndex), location.column >= 1 else { return nil }
        let value = lineStartUTF8Offsets[lineIndex] + location.column - 1
        guard value <= source.utf8.count else { return nil }
        return value
    }
}

// MARK: - AST projection

private struct DraftTextRun {
    let kind: ProjectionTextRunKind
    let domText: String
    let sourceUTF8Span: DecodedSourceUTF8Span?
    let unsupportedReason: ProjectionUnsupportedReason?
}

private struct DraftBlock {
    let kind: SemanticBlockKind
    let headingLevel: Int?
    let headingPath: [HeadingBreadcrumb]
    let domText: String
    let sourceUTF8Span: DecodedSourceUTF8Span?
    let capability: ProjectionCapability
    let runs: [DraftTextRun]
}

private struct ProjectionBlockCollector {
    let sourceIndex: DecodedSourceIndex
    let footnotes: MarkdownFootnotes.Output
    private(set) var drafts: [DraftBlock] = []
    private var headingPath: [HeadingBreadcrumb] = []

    init(sourceIndex: DecodedSourceIndex, footnotes: MarkdownFootnotes.Output) {
        self.sourceIndex = sourceIndex
        self.footnotes = footnotes
    }

    mutating func collect(_ document: Document) {
        for child in document.children {
            collectTopLevel(child)
        }
    }

    private mutating func collectTopLevel(_ markup: Markup) {
        switch markup {
        case let heading as Heading:
            let projected = inlineRuns(in: heading)
            let title = CanonicalMarkdownText.normalize(projected.map(\.domText).joined())
            headingPath.removeAll { $0.level >= heading.level }
            headingPath.append(HeadingBreadcrumb(level: heading.level, title: title))
            append(
                kind: .heading,
                headingLevel: heading.level,
                markup: heading,
                projectedRuns: projected,
                forcedCapability: nil
            )
        case let paragraph as Paragraph:
            append(kind: .paragraph, markup: paragraph, projectedRuns: inlineRuns(in: paragraph))
        case let code as CodeBlock:
            appendCodeBlock(code)
        case let list as OrderedList:
            collectList(list)
        case let list as UnorderedList:
            collectList(list)
        case let quote as BlockQuote:
            appendContainer(
                kind: .blockQuote,
                markup: quote,
                complexReason: .complexBlockQuote
            )
        case let table as Table:
            collectTable(table)
        case let html as HTMLBlock:
            appendRawHTML(html)
        default:
            // The renderer emits no selectable text for other top-level nodes.
            break
        }
    }

    private mutating func collectList(_ list: Markup) {
        for child in list.children {
            guard let item = child as? ListItem else { continue }
            appendContainer(
                kind: .listItem,
                markup: item,
                complexReason: .complexListItem
            )
        }
    }

    private mutating func collectTable(_ table: Table) {
        collectTableCells(in: table)
    }

    private mutating func collectTableCells(in markup: Markup) {
        if let cell = markup as? Table.Cell {
            append(kind: .tableCell, markup: cell, projectedRuns: inlineRuns(in: cell))
            return
        }
        for child in markup.children {
            collectTableCells(in: child)
        }
    }

    private mutating func appendCodeBlock(_ code: CodeBlock) {
        let normalizedLineEndings = code.code.replacingOccurrences(of: "\r\n", with: "\n")
        let run = DraftTextRun(
            kind: .text,
            domText: normalizedLineEndings,
            // A fenced block's AST range includes its Markdown fence; it is
            // not a byte-for-byte mapping of the visible code run.
            sourceUTF8Span: nil,
            unsupportedReason: nil
        )
        append(kind: .codeBlock, markup: code, projectedRuns: [run])
    }

    private mutating func appendRawHTML(_ html: HTMLBlock) {
        let run = DraftTextRun(
            kind: .unsupported,
            domText: html.rawHTML,
            sourceUTF8Span: sourceIndex.span(for: html.range),
            unsupportedReason: .rawHTML
        )
        append(
            kind: .rawHTML,
            markup: html,
            projectedRuns: [run],
            forcedCapability: .unsupported(.rawHTML)
        )
    }

    private mutating func appendContainer(
        kind: SemanticBlockKind,
        markup: Markup,
        complexReason: ProjectionUnsupportedReason
    ) {
        let leafRuns = descendantRuns(in: markup)
        let directBlocks = Array(markup.children)
        let isSimple = directBlocks.count == 1 && directBlocks.first is Paragraph
        append(
            kind: kind,
            markup: markup,
            projectedRuns: leafRuns,
            forcedCapability: isSimple ? nil : .unsupported(complexReason)
        )
    }

    private mutating func append(
        kind: SemanticBlockKind,
        headingLevel: Int? = nil,
        markup: Markup,
        projectedRuns: [DraftTextRun],
        forcedCapability: ProjectionCapability? = nil
    ) {
        let domText = projectedRuns.map(\.domText).joined()
        let excluded = Array(Set(projectedRuns.compactMap(\.unsupportedReason)))
            .sorted { $0.rawValue < $1.rawValue }
        let capability: ProjectionCapability
        if let forcedCapability {
            capability = forcedCapability
        } else if excluded.isEmpty {
            capability = .supported
        } else {
            capability = .supportedExcept(excluded)
        }
        drafts.append(
            DraftBlock(
                kind: kind,
                headingLevel: headingLevel,
                headingPath: headingPath,
                domText: domText,
                sourceUTF8Span: sourceIndex.span(for: markup.range),
                capability: capability,
                runs: projectedRuns
            )
        )
    }

    private func descendantRuns(in markup: Markup) -> [DraftTextRun] {
        var result: [DraftTextRun] = []
        for child in markup.children {
            if let code = child as? CodeBlock {
                result.append(
                    DraftTextRun(
                        kind: .text,
                        domText: code.code.replacingOccurrences(of: "\r\n", with: "\n"),
                        sourceUTF8Span: nil,
                        unsupportedReason: nil
                    )
                )
            } else if let html = child as? HTMLBlock {
                result.append(
                    DraftTextRun(
                        kind: .unsupported,
                        domText: html.rawHTML,
                        sourceUTF8Span: sourceIndex.span(for: html.range),
                        unsupportedReason: .rawHTML
                    )
                )
            } else if child is Paragraph || child is Heading || child is Table.Cell {
                result.append(contentsOf: inlineRuns(in: child))
            } else if child is OrderedList
                        || child is UnorderedList
                        || child is ListItem
                        || child is BlockQuote
                        || child is Table
                        || child is Table.Head
                        || child is Table.Body
                        || child is Table.Row {
                result.append(contentsOf: descendantRuns(in: child))
            }
        }
        return result
    }

    private func inlineRuns(in markup: Markup) -> [DraftTextRun] {
        var result: [DraftTextRun] = []
        for child in markup.children {
            switch child {
            case let text as Text:
                result.append(contentsOf: textRuns(for: text))
            case let softBreak as SoftBreak:
                result.append(
                    DraftTextRun(
                        kind: .softBreak,
                        domText: " ",
                        sourceUTF8Span: sourceIndex.span(for: softBreak.range),
                        unsupportedReason: nil
                    )
                )
            case let lineBreak as LineBreak:
                result.append(
                    DraftTextRun(
                        kind: .hardBreak,
                        domText: "\n",
                        sourceUTF8Span: sourceIndex.span(for: lineBreak.range),
                        unsupportedReason: nil
                    )
                )
            case let code as InlineCode:
                result.append(
                    DraftTextRun(
                        kind: .inlineCode,
                        domText: code.code,
                        // The AST range includes delimiters and is not an exact
                        // source mapping for the visible code.
                        sourceUTF8Span: nil,
                        unsupportedReason: nil
                    )
                )
            case let html as InlineHTML:
                result.append(
                    DraftTextRun(
                        kind: .inlineHTML,
                        domText: html.rawHTML,
                        sourceUTF8Span: sourceIndex.span(for: html.range),
                        unsupportedReason: .inlineHTML
                    )
                )
            case is Image:
                // A loaded image contributes no selectable DOM text. Missing
                // image placeholders are deliberately outside V1 capture.
                continue
            case is Emphasis, is Strong, is Strikethrough, is Link:
                result.append(contentsOf: inlineRuns(in: child))
            default:
                // SafeHTMLVisitor.defaultVisit intentionally emits nothing and
                // does not recurse. Match that behavior so a renderer-only
                // extension can never shift subsequent run IDs.
                continue
            }
        }
        return result
    }

    private func textRuns(for text: Text) -> [DraftTextRun] {
        guard let range = text.range,
              range.lowerBound.line == range.upperBound.line else {
            return [
                DraftTextRun(
                    kind: .text,
                    domText: text.string,
                    sourceUTF8Span: sourceIndex.exactSpan(
                        for: text.range,
                        visibleText: text.string
                    ),
                    unsupportedReason: nil
                )
            ]
        }

        let candidates = Self.footnoteCandidateRanges(in: Array(text.string.utf8))
        guard !candidates.isEmpty else {
            return [
                DraftTextRun(
                    kind: .text,
                    domText: text.string,
                    sourceUTF8Span: sourceIndex.exactSpan(
                        for: text.range,
                        visibleText: text.string
                    ),
                    unsupportedReason: nil
                )
            ]
        }

        let references = Dictionary(
            uniqueKeysWithValues: footnotes.references.map { ($0.span, $0) }
        )
        let bytes = Array(text.string.utf8)
        var cursor = 0
        var runs: [DraftTextRun] = []
        for candidate in candidates {
            let span = MarkdownFootnotes.SourceSpan(
                line: range.lowerBound.line,
                lowerUTF8Column: range.lowerBound.column + candidate.lowerBound,
                upperUTF8Column: range.lowerBound.column + candidate.upperBound
            )
            guard let reference = references[span] else { continue }
            if cursor < candidate.lowerBound {
                runs.append(
                    DraftTextRun(
                        kind: .text,
                        domText: String(decoding: bytes[cursor..<candidate.lowerBound], as: UTF8.self),
                        sourceUTF8Span: nil,
                        unsupportedReason: nil
                    )
                )
            }
            runs.append(
                DraftTextRun(
                    kind: .footnoteReference,
                    domText: String(reference.noteNumber),
                    sourceUTF8Span: nil,
                    unsupportedReason: .footnoteStructure
                )
            )
            cursor = candidate.upperBound
        }
        if cursor == 0 {
            return [
                DraftTextRun(
                    kind: .text,
                    domText: text.string,
                    sourceUTF8Span: sourceIndex.exactSpan(
                        for: text.range,
                        visibleText: text.string
                    ),
                    unsupportedReason: nil
                )
            ]
        }
        if cursor < bytes.count {
            runs.append(
                DraftTextRun(
                    kind: .text,
                    domText: String(decoding: bytes[cursor...], as: UTF8.self),
                    sourceUTF8Span: nil,
                    unsupportedReason: nil
                )
            )
        }
        return runs
    }

    private static func footnoteCandidateRanges(in bytes: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var index = 0
        while index + 3 < bytes.count {
            guard bytes[index] == 0x5B, bytes[index + 1] == 0x5E else {
                index += 1
                continue
            }
            var closing = index + 2
            while closing < bytes.count,
                  bytes[closing] != 0x5D,
                  closing - index <= MarkdownFootnotes.maximumIdentifierBytes + 2 {
                closing += 1
            }
            guard closing < bytes.count, bytes[closing] == 0x5D else {
                index += 1
                continue
            }
            ranges.append(index..<(closing + 1))
            index = closing + 1
        }
        return ranges
    }

    func finish(
        renderRevision: UUID,
        source: ProjectionSourceMetadata
    ) -> DocumentProjection {
        let sectionAssignments = Self.sectionAssignments(for: drafts)
        var blocks: [SemanticBlock] = []
        var documentText = ""
        var documentUTF8Offset = 0
        var nextRunOrdinal = 0

        for (ordinal, draft) in drafts.enumerated() {
            if ordinal > 0 {
                documentText += "\n\n"
                documentUTF8Offset += 2
            }
            let blockID = "block-\(ordinal)"
            let canonicalText = CanonicalMarkdownText.normalize(draft.domText)
            let lower = documentUTF8Offset
            let upper = lower + canonicalText.utf8.count
            let runs = Self.finalizeRuns(
                draft.runs,
                blockID: blockID,
                blockDOMText: draft.domText,
                nextRunOrdinal: &nextRunOrdinal
            )
            blocks.append(
                SemanticBlock(
                    id: blockID,
                    kind: draft.kind,
                    ordinal: ordinal,
                    headingLevel: draft.headingLevel,
                    headingPath: draft.headingPath,
                    headingSectionID: sectionAssignments.sectionIDByBlock[ordinal],
                    canonicalText: canonicalText,
                    canonicalUTF8RangeInDocument: UTF8ByteRange(lower, upper),
                    sourceUTF8Span: draft.sourceUTF8Span,
                    fingerprint: Self.fingerprint(kind: draft.kind, text: canonicalText),
                    captureCapability: draft.capability,
                    highlightCapability: draft.capability,
                    textRuns: runs
                )
            )
            documentText += canonicalText
            documentUTF8Offset = upper
        }

        return DocumentProjection(
            version: DocumentProjection.currentVersion,
            canonicalRulesVersion: CanonicalMarkdownText.rulesVersion,
            renderRevision: renderRevision,
            source: source,
            canonicalText: documentText,
            blocks: blocks,
            headingSections: sectionAssignments.sections
        )
    }

    private static func finalizeRuns(
        _ drafts: [DraftTextRun],
        blockID: String,
        blockDOMText: String,
        nextRunOrdinal: inout Int
    ) -> [ProjectionTextRun] {
        var domUTF16Offset = 0
        var runs: [ProjectionTextRun] = []
        let boundaryMap = Dictionary(
            uniqueKeysWithValues: CanonicalMarkdownText.normalizationBoundaries(
                in: blockDOMText
            ).map { ($0.domUTF16Offset, $0.canonicalUTF8Offset) }
        )
        for draft in drafts {
            let lowerDOM = domUTF16Offset
            let upperDOM = lowerDOM + draft.domText.utf16.count
            let lowerCanonical = boundaryMap[lowerDOM]
            let upperCanonical = boundaryMap[upperDOM]
            let canonicalRange: UTF8ByteRange?
            if let lowerCanonical, let upperCanonical {
                canonicalRange = UTF8ByteRange(lowerCanonical, upperCanonical)
            } else {
                canonicalRange = nil
            }
            runs.append(
                ProjectionTextRun(
                    id: "run-\(nextRunOrdinal)",
                    blockID: blockID,
                    kind: draft.kind,
                    domText: draft.domText,
                    domUTF16RangeInBlock: UTF16CodeUnitRange(lowerDOM, upperDOM),
                    canonicalUTF8RangeInBlock: canonicalRange,
                    sourceUTF8Span: draft.sourceUTF8Span,
                    unsupportedReason: draft.unsupportedReason
                )
            )
            nextRunOrdinal += 1
            domUTF16Offset = upperDOM
        }
        return runs
    }

    private static func fingerprint(kind: SemanticBlockKind, text: String) -> String {
        var payload = Data()
        appendLengthPrefixed(String(DocumentProjection.currentVersion), to: &payload)
        appendLengthPrefixed(kind.rawValue, to: &payload)
        appendLengthPrefixed(text, to: &payload)
        return SHA256.hexDigest(payload)
    }

    private static func appendLengthPrefixed(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }

    private static func sectionAssignments(
        for drafts: [DraftBlock]
    ) -> (sections: [HeadingSection], sectionIDByBlock: [String]) {
        var sections: [HeadingSection] = []
        var sectionIDByBlock = Array(repeating: "section-root", count: drafts.count)
        let firstHeading = drafts.firstIndex { $0.headingLevel != nil } ?? drafts.count
        sections.append(
            HeadingSection(
                id: "section-root",
                headingPath: [],
                headingLevel: nil,
                lowerBlockOrdinal: 0,
                upperBlockOrdinal: firstHeading
            )
        )

        for index in drafts.indices {
            guard let level = drafts[index].headingLevel else { continue }
            let upper = drafts[(index + 1)...].firstIndex {
                guard let nextLevel = $0.headingLevel else { return false }
                return nextLevel <= level
            } ?? drafts.count
            let id = "section-\(index)"
            sections.append(
                HeadingSection(
                    id: id,
                    headingPath: drafts[index].headingPath,
                    headingLevel: level,
                    lowerBlockOrdinal: index,
                    upperBlockOrdinal: upper
                )
            )
        }

        var nearestSectionID = "section-root"
        for index in drafts.indices {
            if drafts[index].headingLevel != nil {
                nearestSectionID = "section-\(index)"
            }
            sectionIDByBlock[index] = nearestSectionID
        }
        return (sections, sectionIDByBlock)
    }
}

private extension SHA256 {
    static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
