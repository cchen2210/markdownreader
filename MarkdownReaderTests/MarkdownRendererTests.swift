import XCTest
@testable import MarkdownReader

final class MarkdownRendererTests: XCTestCase {
    func testRendersCommonMarkdownAndGFMStructure() {
        let source = """
        # Project Notes

        ## Status

        - [x] Parsed
        - [ ] Reviewed

        | Item | State |
        |:-----|------:|
        | Reader | Ready |

        ```swift
        let answer = 42
        ```
        """

        let rendered = MarkdownRenderer.render(source: source, documentURL: nil)

        XCTAssertEqual(rendered.outline.map(\.title), ["Project Notes", "Status"])
        XCTAssertEqual(rendered.outline.map(\.id), ["project-notes", "status"])
        XCTAssertTrue(rendered.bodyHTML.contains("<input type=\"checkbox\" disabled aria-label=\"Completed task\" checked>"))
        XCTAssertTrue(rendered.bodyHTML.contains("<table>"))
        XCTAssertTrue(rendered.bodyHTML.contains("class=\"language-swift\""))
        XCTAssertTrue(rendered.bodyHTML.contains("class=\"syntax-keyword\">let</span>"))
        XCTAssertTrue(rendered.bodyHTML.contains("class=\"syntax-number\">42</span>"))
    }

    func testEscapesRawHTMLAndCodePayloads() {
        let source = """
        <script>alert('owned')</script>

        ```html
        </code><img src=x onerror=alert(1)>
        ```

        Inline <iframe src="https://example.com"></iframe> markup.
        """

        let rendered = MarkdownRenderer.render(source: source, documentURL: nil)

        XCTAssertFalse(rendered.bodyHTML.contains("<script>"))
        XCTAssertFalse(rendered.bodyHTML.contains("<iframe"))
        XCTAssertFalse(rendered.bodyHTML.contains("<img src=x onerror="))
        XCTAssertTrue(rendered.bodyHTML.contains("&lt;script&gt;"))
        XCTAssertTrue(rendered.bodyHTML.contains("&lt;/code&gt;"))
        XCTAssertTrue(rendered.bodyHTML.contains("&lt;img"))
        XCTAssertTrue(rendered.bodyHTML.contains("class=\"syntax-tag\""))
        XCTAssertTrue(rendered.bodyHTML.contains("&lt;iframe"))
    }

    func testDangerousLinksNeverReachGeneratedHTML() {
        let rendered = MarkdownRenderer.render(
            source: "[bad](JaVaScRiPt:alert(1)) [web](https://example.com)",
            documentURL: nil
        )
        let html = HTMLDocumentBuilder.build(rendered: rendered, title: "Test", style: .standard)

        XCTAssertFalse(html.localizedCaseInsensitiveContains("javascript:alert"))
        XCTAssertFalse(html.contains("https://example.com"))
        XCTAssertEqual(Set(rendered.linkTargets.values), ["JaVaScRiPt:alert(1)", "https://example.com"])
        XCTAssertTrue(html.contains("mdreader-link://open/\(rendered.resourceToken)/link-0"))
        XCTAssertTrue(html.contains("script-src 'none'"))
        XCTAssertTrue(html.contains("connect-src 'none'"))
    }

    func testStandaloneAndPreviewHTMLRestoreOnlySafeLinks() {
        let rendered = MarkdownRenderer.render(
            source: "[web](https://example.com/?a=1&b=2) [bad](javascript:alert(1)) [local](guide.md)",
            documentURL: nil
        )
        let html = HTMLDocumentBuilder.buildPreview(rendered: rendered, title: "Test", style: .standard)

        XCTAssertTrue(html.contains("href=\"https://example.com/?a=1&amp;b=2\""))
        XCTAssertTrue(html.contains("href=\"guide.md\""))
        XCTAssertTrue(html.contains("href=\"#blocked-link\""))
        XCTAssertFalse(html.contains("mdreader-link://"))
        XCTAssertFalse(html.localizedCaseInsensitiveContains("javascript:alert"))
    }

    func testBareWebAndEmailAddressesBecomeLinksWithoutNestingOrTouchingCode() {
        let rendered = MarkdownRenderer.render(
            source: "Visit https://swift.org/docs, www.example.com, or reader@example.com. `https://code.example` [https://named.example](https://destination.example).",
            documentURL: nil
        )

        XCTAssertEqual(
            Set(rendered.linkTargets.values),
            [
                "https://swift.org/docs",
                "http://www.example.com",
                "mailto:reader@example.com",
                "https://destination.example",
            ]
        )
        XCTAssertEqual(rendered.bodyHTML.components(separatedBy: "class=\"autolink\"").count - 1, 3)
        XCTAssertTrue(rendered.bodyHTML.contains("<code><span data-memory-run="))
        XCTAssertTrue(rendered.bodyHTML.contains(">https://code.example</span></code>"))
        XCTAssertFalse(rendered.bodyHTML.contains("<a href=\"mdreader-link://open/\(rendered.resourceToken)/link-3\"><a"))
        XCTAssertTrue(rendered.bodyHTML.contains(">https://named.example</span></a>"))
    }

    func testRendersFootnotesWithMarkdownRepeatedReferencesAndBacklinks() {
        let rendered = MarkdownRenderer.render(
            source: """
            Body[^note] and again[^note].

            [^note]: **Strong note** with https://example.com and <script>alert(1)</script>.
            """,
            documentURL: nil
        )

        XCTAssertTrue(rendered.bodyHTML.contains("<sup class=\"footnote-ref\"><a href=\"#fn-6e6f7465\" id=\"fnref-6e6f7465\""))
        XCTAssertTrue(rendered.bodyHTML.contains("id=\"fnref-6e6f7465-2\""))
        XCTAssertTrue(rendered.bodyHTML.contains("<section class=\"footnotes\" role=\"doc-endnotes\"><ol>"))
        XCTAssertTrue(rendered.bodyHTML.contains("<li id=\"fn-6e6f7465\" value=\"1\">"))
        XCTAssertTrue(rendered.bodyHTML.contains("<strong>Strong note</strong>"))
        XCTAssertEqual(rendered.bodyHTML.components(separatedBy: "class=\"footnote-backref\"").count - 1, 2)
        XCTAssertFalse(rendered.bodyHTML.contains("[^note]:"))
        XCTAssertFalse(rendered.bodyHTML.contains("<script>"))
        XCTAssertTrue(rendered.bodyHTML.contains("&lt;script&gt;"))
        XCTAssertTrue(rendered.linkTargets.values.contains("https://example.com"))
    }

    func testFootnoteRangeMappingPreservesEscapesSmartPunctuationAndEmphasis() {
        let rendered = MarkdownRenderer.render(
            source: """
            "Quoted" \\[^n], then *[^n]*.

            [^n]: Note.
            """,
            documentURL: nil
        )

        XCTAssertEqual(rendered.bodyHTML.components(separatedBy: "<sup class=\"footnote-ref\">").count - 1, 1)
        XCTAssertTrue(rendered.bodyHTML.contains("[^n]"))
        XCTAssertTrue(rendered.bodyHTML.contains("<em><span data-memory-run="))
        XCTAssertTrue(rendered.bodyHTML.contains("<sup class=\"footnote-ref\">"))
        XCTAssertTrue(rendered.bodyHTML.contains("“Quoted”"))
    }

    func testFootnoteIDsCannotCollideWithHeadingIDs() {
        let rendered = MarkdownRenderer.render(
            source: """
            # fn-6e6f7465

            Text[^note].

            [^note]: Note.
            """,
            documentURL: nil
        )

        XCTAssertEqual(rendered.outline.first?.id, "fn-6e6f7465-2")
        XCTAssertTrue(rendered.bodyHTML.contains("<li id=\"fn-6e6f7465\""))
        XCTAssertTrue(rendered.bodyHTML.contains("href=\"#fn-6e6f7465\""))
    }

    func testOpaqueRegistryReplacementDoesNotConfusePrefixIDs() {
        let links = (0..<15)
            .map { "[link\($0)](https://example.com/\($0))" }
            .joined(separator: " ")
        let renderedLinks = MarkdownRenderer.render(source: links, documentURL: nil)
        let preview = HTMLDocumentBuilder.buildPreview(
            rendered: renderedLinks,
            title: "Links",
            style: .standard
        )

        for index in 0..<15 {
            XCTAssertTrue(preview.contains("href=\"https://example.com/\(index)\""), "link-\(index)")
        }
        XCTAssertFalse(preview.contains("mdreader-link://"))

        let renderedImages = RenderedMarkdown(
            revision: UUID(),
            bodyHTML: "",
            outline: [],
            linkTargets: [:],
            imageAssets: [:],
            imageRoot: nil
        )
        let imageHTML = (0..<12)
            .map { "<img src=\"\(renderedImages.imageSource(for: "image-\($0)"))\">" }
            .joined()
        let replacements = Dictionary(uniqueKeysWithValues: (0..<12).map { ("image-\($0)", "replacement-\($0)") })
        let replacedImages = HTMLDocumentBuilder.replacingImageSources(
            in: imageHTML,
            rendered: renderedImages,
            replacements: replacements
        )

        for index in 0..<12 {
            XCTAssertTrue(replacedImages.contains("src=\"replacement-\(index)\""), "image-\(index)")
        }
        XCTAssertFalse(replacedImages.contains("mdreader://"))
    }

    func testEachRenderGetsAnIsolatedResourceNamespace() {
        let first = MarkdownRenderer.render(source: "[link](https://example.com) ![image](image.png)", documentURL: URL(fileURLWithPath: "/tmp/one.md"))
        let second = MarkdownRenderer.render(source: "[link](https://example.com) ![image](image.png)", documentURL: URL(fileURLWithPath: "/tmp/two.md"))

        XCTAssertNotEqual(first.resourceToken, second.resourceToken)
        XCTAssertTrue(first.bodyHTML.contains(first.resourceToken))
        XCTAssertFalse(first.bodyHTML.contains(second.resourceToken))
    }

    func testDuplicateHeadingIDsAreStableAndUnique() {
        let rendered = MarkdownRenderer.render(source: "# Setup\n## Setup\n### Setup", documentURL: nil)
        XCTAssertEqual(rendered.outline.map(\.id), ["setup", "setup-2", "setup-3"])

        let collidingSuffix = MarkdownRenderer.render(source: "# Setup\n# Setup-2\n# Setup", documentURL: nil)
        XCTAssertEqual(collidingSuffix.outline.map(\.id), ["setup", "setup-2", "setup-3"])
    }

    func testImagePathsStayInsideDocumentDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let documentURL = root.appendingPathComponent("readme.md")

        let rendered = MarkdownRenderer.render(
            source: "![inside](images/photo.png)\n![outside](../secret.png)\n![remote](https://example.com/a.png)",
            documentURL: documentURL
        )

        XCTAssertEqual(rendered.imageAssets.count, 1)
        XCTAssertEqual(rendered.imageAssets.values.first?.path, root.appendingPathComponent("images/photo.png").path)
        XCTAssertEqual(rendered.bodyHTML.components(separatedBy: "Image unavailable").count - 1, 2)
    }

    func testStandaloneHTMLHasNoReaderSchemeWhenImagesLoad() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let imageURL = root.appendingPathComponent("pixel.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!.write(to: imageURL)
        let documentURL = root.appendingPathComponent("readme.md")

        let rendered = MarkdownRenderer.render(source: "![pixel](pixel.png)", documentURL: documentURL)
        let html = HTMLDocumentBuilder.buildStandalone(rendered: rendered, title: "Test", style: .standard)

        XCTAssertFalse(html.contains("mdreader://asset/"))
        XCTAssertTrue(html.contains("data:image/png;base64,"))
    }

    func testStandaloneHTMLHasNoReaderSchemeWhenImageLoadFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let documentURL = root.appendingPathComponent("readme.md")
        let rendered = MarkdownRenderer.render(source: "![missing](missing.png)", documentURL: documentURL)

        let html = HTMLDocumentBuilder.buildStandalone(rendered: rendered, title: "Test", style: .standard)

        XCTAssertFalse(html.contains("mdreader://asset/"))
        XCTAssertTrue(html.contains("src=\"data:,\""))
    }

    func testImageLoadRejectsIntermediateSymlinkReplacement() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documentRoot = temporaryRoot.appendingPathComponent("document", isDirectory: true)
        let originalAssets = documentRoot.appendingPathComponent("assets", isDirectory: true)
        let outsideAssets = temporaryRoot.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: originalAssets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideAssets, withIntermediateDirectories: true)
        let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try pixel.write(to: originalAssets.appendingPathComponent("pixel.png"))
        try pixel.write(to: outsideAssets.appendingPathComponent("pixel.png"))

        let documentURL = documentRoot.appendingPathComponent("readme.md")
        let rendered = MarkdownRenderer.render(source: "![pixel](assets/pixel.png)", documentURL: documentURL)
        let assetURL = try XCTUnwrap(rendered.imageAssets.values.first)
        let authorizedRoot = try XCTUnwrap(rendered.imageRoot)

        try FileManager.default.removeItem(at: originalAssets)
        try FileManager.default.createSymbolicLink(at: originalAssets, withDestinationURL: outsideAssets)

        XCTAssertThrowsError(try LocalImageLoader.load(from: assetURL, within: authorizedRoot))
    }

    func testRepeatedImagesShareOneBoundedAsset() {
        let source = Array(repeating: "![pixel](pixel.png)", count: 300).joined(separator: "\n")
        let rendered = MarkdownRenderer.render(
            source: source,
            documentURL: URL(fileURLWithPath: "/tmp/readme.md")
        )

        XCTAssertEqual(rendered.imageAssets.count, 1)
        XCTAssertEqual(rendered.bodyHTML.components(separatedBy: "<img ").count - 1, MarkdownRenderer.maximumImageOccurrences)
        XCTAssertEqual(rendered.bodyHTML.components(separatedBy: "Image unavailable").count - 1, 44)
    }

    func testExplicitAppearanceControlsNativeColorScheme() {
        let rendered = MarkdownRenderer.render(source: "# Theme", documentURL: nil)
        let dark = HTMLDocumentBuilder.build(
            rendered: rendered,
            title: "Dark",
            style: RenderStyle(appearance: .dark)
        )
        let sepia = HTMLDocumentBuilder.build(
            rendered: rendered,
            title: "Sepia",
            style: RenderStyle(appearance: .sepia)
        )

        XCTAssertTrue(dark.contains("color-scheme: dark"))
        XCTAssertTrue(sepia.contains("color-scheme: light"))
        XCTAssertTrue(dark.contains("--syntax-string:#275E2D"))
        XCTAssertTrue(dark.contains("--syntax-comment:#555"))
    }

    func testWelcomeSampleExercisesLocalAssetsAndLinks() throws {
        let testBundle = Bundle(for: Self.self)
        let documentURL = try XCTUnwrap(
            testBundle.url(
                forResource: "Welcome",
                withExtension: "md",
                subdirectory: "Samples"
            )
        )
        let source = try String(contentsOf: documentURL, encoding: .utf8)
        let rendered = MarkdownRenderer.render(source: source, documentURL: documentURL)

        XCTAssertEqual(rendered.imageAssets.count, 1)
        XCTAssertNoThrow(try LocalImageLoader.load(
            from: rendered.imageAssets.values.first!,
            within: rendered.imageRoot!
        ))
        XCTAssertTrue(rendered.linkTargets.values.contains("Linked.md"))
        XCTAssertTrue(rendered.linkTargets.values.contains("https://www.swift.org/documentation/"))
    }
}
