import Foundation
import Markdown

enum MarkdownRenderer {
    static let maximumSourceBytes = 10 * 1024 * 1024
    static let maximumRenderedNodes = 50_000
    static let maximumNestingDepth = 128
    static let maximumImageOccurrences = 256
    static let maximumDistinctImages = 32
    static let maximumDeclaredImageBytes = 40 * 1024 * 1024
    static let maximumLinkTargets = 4_096
    static let maximumLinkDestinationCharacters = 2_048
    static let maximumAutolinkTextCharacters = 64 * 1_024

    static func render(source: String, documentURL: URL?) -> RenderedMarkdown {
        let revision = UUID()
        let imageRoot = documentURL?
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard source.utf8.count <= maximumSourceBytes else {
            return RenderedMarkdown(
                revision: revision,
                bodyHTML: "<p class=\"render-limit\">This document is too large to preview safely.</p>",
                outline: [],
                linkTargets: [:],
                imageAssets: [:],
                imageRoot: imageRoot
            )
        }
        let footnotes = MarkdownFootnotes.process(source)
        let document = Document(parsing: footnotes.bodySource, source: documentURL)
        var visitor = SafeHTMLVisitor(
            documentURL: documentURL,
            resourceToken: revision.uuidString.lowercased(),
            footnotes: footnotes
        )
        let bodyHTML = visitor.visit(document) + visitor.renderFootnotes()

        return RenderedMarkdown(
            revision: revision,
            bodyHTML: bodyHTML,
            outline: visitor.outline,
            linkTargets: visitor.linkTargets,
            imageAssets: visitor.imageAssets,
            imageRoot: imageRoot
        )
    }
}

private struct SafeHTMLVisitor: MarkupVisitor {
    typealias Result = String

    private let documentDirectory: URL?
    private let resourceToken: String
    private let bareLinkDetector: NSDataDetector?
    private let footnotes: MarkdownFootnotes.Output
    private let footnoteSourceLines: [[UInt8]]
    private let footnoteReferencesBySpan: [MarkdownFootnotes.SourceSpan: MarkdownFootnotes.Reference]
    private let footnoteReferencesByLine: [Int: [MarkdownFootnotes.Reference]]
    private var usedHeadingIDs: Set<String> = []
    private var nextLinkID = 0
    private var nextImageID = 0
    private var tableAlignments: [Table.ColumnAlignment?] = []
    private var tableColumn = 0
    private var inTableHead = false
    private var visitedNodeCount = 0
    private var nestingDepth = 0
    private var didEmitRenderLimit = false
    private var imageOccurrenceCount = 0
    private var imageIDByURL: [URL: String] = [:]
    private var declaredImageBytes = 0
    private var autolinkingSuppressionDepth = 0
    private var isRenderingFootnoteDefinition = false
    private var renderedFootnoteReferences: [String: [MarkdownFootnotes.Reference]] = [:]

    private(set) var outline: [OutlineEntry] = []
    private(set) var linkTargets: [String: String] = [:]
    private(set) var imageAssets: [String: URL] = [:]

    init(
        documentURL: URL?,
        resourceToken: String,
        footnotes: MarkdownFootnotes.Output
    ) {
        documentDirectory = documentURL?.deletingLastPathComponent()
        self.resourceToken = resourceToken
        self.footnotes = footnotes
        footnoteSourceLines = Self.sourceLineBytes(footnotes.bodySource)
        footnoteReferencesBySpan = Dictionary(
            uniqueKeysWithValues: footnotes.references.map { ($0.span, $0) }
        )
        footnoteReferencesByLine = Dictionary(
            grouping: footnotes.references,
            by: { $0.span.line }
        )
        usedHeadingIDs = Set(footnotes.definitions.map(\.safeID))
        usedHeadingIDs.formUnion(footnotes.references.map(\.referenceID))
        bareLinkDetector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        )
    }

    mutating func defaultVisit(_ markup: Markup) -> String {
        ""
    }

    private mutating func renderChildren(_ markup: Markup) -> String {
        guard nestingDepth < MarkdownRenderer.maximumNestingDepth else {
            return renderLimitPlaceholder()
        }

        nestingDepth += 1
        defer { nestingDepth -= 1 }

        var result = ""
        for child in markup.children {
            guard visitedNodeCount < MarkdownRenderer.maximumRenderedNodes else {
                result += renderLimitPlaceholder()
                break
            }
            visitedNodeCount += 1
            result += visit(child)
        }
        return result
    }

    mutating func visitDocument(_ document: Document) -> String {
        renderChildren(document)
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        "<p>\(renderChildren(paragraph))</p>\n"
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let level = min(max(heading.level, 1), 6)
        let headingID = uniqueHeadingID(for: heading.plainText)
        let title = heading.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isRenderingFootnoteDefinition {
            outline.append(OutlineEntry(id: headingID, level: level, title: title.isEmpty ? "Untitled section" : title))
        }
        return "<h\(level) id=\"\(escapeAttribute(headingID))\">\(renderChildren(heading))</h\(level)>\n"
    }

    mutating func visitText(_ text: Text) -> String {
        guard autolinkingSuppressionDepth == 0 else {
            return escapeText(text.string)
        }
        return renderTextWithFootnotes(text)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br>\n"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>\(renderChildren(emphasis))</em>"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(renderChildren(strong))</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        "<del>\(renderChildren(strikethrough))</del>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(escapeText(inlineCode.code))</code>"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let language = safeLanguage(codeBlock.language)
        let languageClass = language.map { " class=\"language-\(escapeAttribute($0))\"" } ?? ""
        let languageLabel = language.map { "<div class=\"code-label\">\(escapeText($0))</div>" } ?? ""
        let highlightedCode = SyntaxHighlighter.highlight(codeBlock.code, language: codeBlock.language)
        return "<div class=\"code-block\">\(languageLabel)<pre tabindex=\"0\"><code\(languageClass)>\(highlightedCode)</code></pre></div>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        "<blockquote>\(renderChildren(blockQuote))</blockquote>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        let start = orderedList.startIndex == 1 ? "" : " start=\"\(orderedList.startIndex)\""
        return "<ol\(start)>\n\(renderChildren(orderedList))</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        "<ul>\n\(renderChildren(unorderedList))</ul>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        let task: String
        if let checkbox = listItem.checkbox {
            let checked = checkbox == .checked ? " checked" : ""
            let label = checkbox == .checked ? "Completed task" : "Incomplete task"
            task = "<input type=\"checkbox\" disabled aria-label=\"\(label)\"\(checked)>"
        } else {
            task = ""
        }
        return "<li\(listItem.checkbox == nil ? "" : " class=\"task-item\"")>\(task)\(renderChildren(listItem))</li>\n"
    }

    mutating func visitLink(_ link: Link) -> String {
        autolinkingSuppressionDepth += 1
        let content = renderChildren(link)
        autolinkingSuppressionDepth -= 1
        guard let destination = link.destination?.trimmingCharacters(in: .whitespacesAndNewlines),
              !destination.isEmpty,
              destination.count <= MarkdownRenderer.maximumLinkDestinationCharacters else {
            return content
        }

        let title = link.title.map { " title=\"\(escapeAttribute($0))\"" } ?? ""
        if destination.hasPrefix("#"), let fragment = safeFragment(String(destination.dropFirst())) {
            return "<a href=\"#\(escapeAttribute(fragment))\"\(title)>\(content)</a>"
        }

        guard linkTargets.count < MarkdownRenderer.maximumLinkTargets else {
            return content
        }

        let linkID = "link-\(nextLinkID)"
        nextLinkID += 1
        linkTargets[linkID] = destination
        return "<a href=\"mdreader-link://open/\(resourceToken)/\(linkID)\"\(title)>\(content)</a>"
    }

    mutating func visitImage(_ image: Image) -> String {
        let alt = image.plainText.isEmpty ? "Image" : image.plainText
        let title = image.title.map { " title=\"\(escapeAttribute($0))\"" } ?? ""
        imageOccurrenceCount += 1
        guard imageOccurrenceCount <= MarkdownRenderer.maximumImageOccurrences else {
            return imagePlaceholder(alt: alt, source: image.source)
        }
        guard let source = image.source,
              let imageURL = resolveLocalImage(source) else {
            return imagePlaceholder(alt: alt, source: image.source)
        }

        let imageID: String
        if let existingID = imageIDByURL[imageURL] {
            imageID = existingID
        } else {
            guard imageAssets.count < MarkdownRenderer.maximumDistinctImages else {
                return imagePlaceholder(alt: alt, source: source)
            }
            let fileSize = (try? imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard fileSize <= LocalImageLoader.maximumBytes,
                  declaredImageBytes <= MarkdownRenderer.maximumDeclaredImageBytes - fileSize else {
                return imagePlaceholder(alt: alt, source: source)
            }
            declaredImageBytes += fileSize
            imageID = "image-\(nextImageID)"
            nextImageID += 1
            imageIDByURL[imageURL] = imageID
            imageAssets[imageID] = imageURL
        }
        return "<img src=\"mdreader://asset/\(resourceToken)/\(imageID)\" alt=\"\(escapeAttribute(alt))\"\(title)>"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        "<pre class=\"raw-html\"><code>\(escapeText(html.rawHTML))</code></pre>\n"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        "<code class=\"raw-html-inline\">\(escapeText(inlineHTML.rawHTML))</code>"
    }

    mutating func visitTable(_ table: Table) -> String {
        let priorAlignments = tableAlignments
        tableAlignments = table.columnAlignments
        let result = "<div class=\"table-scroll\" tabindex=\"0\"><table>\n\(renderChildren(table))</table></div>\n"
        tableAlignments = priorAlignments
        return result
    }

    mutating func visitTableHead(_ tableHead: Table.Head) -> String {
        let prior = inTableHead
        inTableHead = true
        tableColumn = 0
        let result = "<thead><tr>\n\(renderChildren(tableHead))</tr></thead>\n"
        inTableHead = prior
        return result
    }

    mutating func visitTableBody(_ tableBody: Table.Body) -> String {
        "<tbody>\n\(renderChildren(tableBody))</tbody>\n"
    }

    mutating func visitTableRow(_ tableRow: Table.Row) -> String {
        tableColumn = 0
        return "<tr>\n\(renderChildren(tableRow))</tr>\n"
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) -> String {
        let tag = inTableHead ? "th" : "td"
        let alignment: String
        if tableColumn < tableAlignments.count, let value = tableAlignments[tableColumn] {
            switch value {
            case .left: alignment = " class=\"align-left\""
            case .center: alignment = " class=\"align-center\""
            case .right: alignment = " class=\"align-right\""
            }
        } else {
            alignment = ""
        }
        tableColumn += 1

        let colspan = tableCell.colspan > 1 ? " colspan=\"\(tableCell.colspan)\"" : ""
        let rowspan = tableCell.rowspan > 1 ? " rowspan=\"\(tableCell.rowspan)\"" : ""
        return "<\(tag)\(alignment)\(colspan)\(rowspan)>\(renderChildren(tableCell))</\(tag)>\n"
    }

    private mutating func uniqueHeadingID(for title: String) -> String {
        let base = slugify(title)
        if usedHeadingIDs.insert(base).inserted {
            return base
        }

        var suffix = 2
        while !usedHeadingIDs.insert("\(base)-\(suffix)").inserted {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }

    private func slugify(_ value: String) -> String {
        let folded = value.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        var result = ""
        var pendingDash = false

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !result.isEmpty { result.append("-") }
                result.unicodeScalars.append(scalar)
                pendingDash = false
            } else if !result.isEmpty {
                pendingDash = true
            }
        }
        return result.isEmpty ? "section" : result
    }

    private func safeFragment(_ value: String) -> String? {
        let decoded = value.removingPercentEncoding ?? value
        let fragment = slugify(decoded)
        return fragment.isEmpty ? nil : fragment
    }

    private func safeLanguage(_ value: String?) -> String? {
        guard let first = value?
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .first else { return nil }

        let candidate = String(first)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_+-.#")
        guard candidate.unicodeScalars.allSatisfy(allowed.contains), candidate.count <= 32 else { return nil }
        return candidate
    }

    mutating func renderFootnotes() -> String {
        let definitions = footnotes.referencedDefinitions
        guard !definitions.isEmpty else { return "" }

        var html = "<section class=\"footnotes\" role=\"doc-endnotes\"><ol>\n"
        let priorDefinitionState = isRenderingFootnoteDefinition
        isRenderingFootnoteDefinition = true
        defer { isRenderingFootnoteDefinition = priorDefinitionState }

        for definition in definitions {
            guard let noteNumber = definition.noteNumber else { continue }
            let noteDocument = Document(parsing: definition.markdown)
            let noteHTML = visit(noteDocument)
            let backReferences = renderedFootnoteReferences[definition.normalizedIdentifier] ?? []
            let backlinks = backReferences.map { reference in
                let suffix = reference.occurrence == 1 ? "" : " \(reference.occurrence)"
                return "<a class=\"footnote-backref\" href=\"#\(escapeAttribute(reference.referenceID))\" aria-label=\"Back to footnote \(noteNumber) reference \(reference.occurrence)\">↩\(suffix)</a>"
            }.joined(separator: " ")
            let backlinkBlock = backlinks.isEmpty ? "" : "<div class=\"footnote-backrefs\">\(backlinks)</div>"
            html += "<li id=\"\(escapeAttribute(definition.safeID))\" value=\"\(noteNumber)\">\(noteHTML)\(backlinkBlock)</li>\n"
        }
        html += "</ol></section>\n"
        return html
    }

    private mutating func renderTextWithFootnotes(_ text: Text) -> String {
        guard !isRenderingFootnoteDefinition,
              let range = text.range,
              range.lowerBound.line == range.upperBound.line,
              let lineReferences = footnoteReferencesByLine[range.lowerBound.line],
              lineReferences.contains(where: {
                  $0.span.lowerUTF8Column >= range.lowerBound.column
                      && $0.span.upperUTF8Column <= range.upperBound.column
              }),
              footnoteSourceLines.indices.contains(range.lowerBound.line - 1) else {
            return renderBareLinks(in: text.string)
        }

        let sourceLine = footnoteSourceLines[range.lowerBound.line - 1]
        let lowerOffset = range.lowerBound.column - 1
        let upperOffset = range.upperBound.column - 1
        guard lowerOffset >= 0,
              upperOffset >= lowerOffset,
              upperOffset <= sourceLine.count else {
            return renderBareLinks(in: text.string)
        }

        let rawSlice = Array(sourceLine[lowerOffset..<upperOffset])
        let renderedBytes = Array(text.string.utf8)
        let rawCandidates = Self.footnoteCandidateRanges(in: rawSlice)
        let renderedCandidates = Self.footnoteCandidateRanges(in: renderedBytes)
        guard rawCandidates.count == renderedCandidates.count else {
            return renderBareLinks(in: text.string)
        }

        var replacements: [(Range<Int>, MarkdownFootnotes.Reference)] = []
        for (rawCandidate, renderedCandidate) in zip(rawCandidates, renderedCandidates) {
            let span = MarkdownFootnotes.SourceSpan(
                line: range.lowerBound.line,
                lowerUTF8Column: range.lowerBound.column + rawCandidate.lowerBound,
                upperUTF8Column: range.lowerBound.column + rawCandidate.upperBound
            )
            if let reference = footnoteReferencesBySpan[span] {
                replacements.append((renderedCandidate, reference))
            }
        }
        guard !replacements.isEmpty else { return renderBareLinks(in: text.string) }

        var html = ""
        var cursor = 0
        for (candidate, reference) in replacements {
            guard candidate.lowerBound >= cursor, candidate.upperBound <= renderedBytes.count else {
                return renderBareLinks(in: text.string)
            }
            html += renderBareLinks(in: String(decoding: renderedBytes[cursor..<candidate.lowerBound], as: UTF8.self))
            html += renderFootnoteReference(reference)
            cursor = candidate.upperBound
        }
        html += renderBareLinks(in: String(decoding: renderedBytes[cursor...], as: UTF8.self))
        return html
    }

    private mutating func renderFootnoteReference(_ reference: MarkdownFootnotes.Reference) -> String {
        renderedFootnoteReferences[reference.normalizedIdentifier, default: []].append(reference)
        return "<sup class=\"footnote-ref\"><a href=\"#\(escapeAttribute(reference.safeID))\" id=\"\(escapeAttribute(reference.referenceID))\" role=\"doc-noteref\" aria-label=\"Footnote \(reference.noteNumber)\">\(reference.noteNumber)</a></sup>"
    }

    private static func footnoteCandidateRanges(in bytes: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var index = 0
        while index + 3 < bytes.count {
            guard bytes[index] == 0x5B, bytes[index + 1] == 0x5E else {
                index += 1
                continue
            }
            var closingBracket = index + 2
            while closingBracket < bytes.count,
                  bytes[closingBracket] != 0x5D,
                  closingBracket - index <= MarkdownFootnotes.maximumIdentifierBytes + 2 {
                closingBracket += 1
            }
            guard closingBracket < bytes.count, bytes[closingBracket] == 0x5D else {
                index += 1
                continue
            }
            ranges.append(index..<(closingBracket + 1))
            index = closingBracket + 1
        }
        return ranges
    }

    private static func sourceLineBytes(_ source: String) -> [[UInt8]] {
        let bytes = Array(source.utf8)
        var lines: [[UInt8]] = []
        var lineStart = 0
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                lines.append(Array(bytes[lineStart..<index]))
                index += 1
                lineStart = index
            } else if bytes[index] == 0x0D {
                lines.append(Array(bytes[lineStart..<index]))
                index += 1
                if index < bytes.count, bytes[index] == 0x0A { index += 1 }
                lineStart = index
            } else {
                index += 1
            }
        }
        if lineStart < bytes.count || source.isEmpty {
            lines.append(Array(bytes[lineStart...]))
        }
        return lines
    }

    private mutating func renderBareLinks(in value: String) -> String {
        guard value.utf16.count <= MarkdownRenderer.maximumAutolinkTextCharacters,
              value.contains(".") || value.localizedCaseInsensitiveContains("http") else {
            return escapeText(value)
        }
        guard let bareLinkDetector else {
            return escapeText(value)
        }

        let source = value as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let matches = bareLinkDetector.matches(in: value, options: [], range: fullRange)
        guard !matches.isEmpty else { return escapeText(value) }

        var html = ""
        var cursor = 0
        for match in matches {
            guard match.range.location >= cursor,
                  match.range.location + match.range.length <= source.length,
                  let destination = match.url?.absoluteString,
                  destination.count <= MarkdownRenderer.maximumLinkDestinationCharacters,
                  linkTargets.count < MarkdownRenderer.maximumLinkTargets,
                  let scheme = match.url?.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else {
                continue
            }

            let prefixRange = NSRange(location: cursor, length: match.range.location - cursor)
            html += escapeText(source.substring(with: prefixRange))

            let linkID = "link-\(nextLinkID)"
            nextLinkID += 1
            linkTargets[linkID] = destination
            let label = source.substring(with: match.range)
            html += "<a class=\"autolink\" href=\"mdreader-link://open/\(resourceToken)/\(linkID)\">\(escapeText(label))</a>"
            cursor = match.range.location + match.range.length
        }

        guard cursor > 0 else { return escapeText(value) }
        html += escapeText(source.substring(from: cursor))
        return html
    }

    private func resolveLocalImage(_ source: String) -> URL? {
        guard let documentDirectory else { return nil }

        var decoded = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty, !decoded.hasPrefix("/"), !decoded.hasPrefix("~") else { return nil }
        for _ in 0..<3 {
            guard let next = decoded.removingPercentEncoding, next != decoded else { break }
            decoded = next
        }

        guard URL(string: decoded)?.scheme == nil else { return nil }
        let candidate = URL(fileURLWithPath: decoded, relativeTo: documentDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let root = documentDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(rootPath) else { return nil }
        return candidate
    }

    private func imagePlaceholder(alt: String, source: String?) -> String {
        let filename = source.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        let detail = filename.map { " — \($0)" } ?? ""
        return "<span class=\"image-placeholder\" role=\"img\" aria-label=\"\(escapeAttribute(alt))\">Image unavailable\(escapeText(detail))</span>"
    }

    private mutating func renderLimitPlaceholder() -> String {
        guard !didEmitRenderLimit else { return "" }
        didEmitRenderLimit = true
        return "<span class=\"render-limit\">Preview shortened for safety.</span>"
    }

    private func escapeText(_ value: String) -> String {
        MarkdownTextSafety.sanitizedForDisplay(value)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func escapeAttribute(_ value: String) -> String {
        escapeText(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .filter { character in
                character == "\t" || character == "\n" || character.unicodeScalars.allSatisfy { $0.value >= 0x20 }
            }
    }
}
