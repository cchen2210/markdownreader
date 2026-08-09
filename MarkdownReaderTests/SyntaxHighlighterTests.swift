import XCTest
@testable import MarkdownReader

final class SyntaxHighlighterTests: XCTestCase {
    func testSwiftEscapesInjectionAndKeepsStringsAndCommentsInert() {
        let source = #"let payload = "</span><script>alert('owned')</script>" // class return <img>"#

        let html = SyntaxHighlighter.highlight(source, language: "swift")

        XCTAssertTrue(html.contains(#"<span class="syntax-keyword">let</span>"#))
        XCTAssertTrue(html.contains(#"<span class="syntax-string">&quot;&lt;/span&gt;&lt;script&gt;alert(&#39;owned&#39;)&lt;/script&gt;&quot;</span>"#))
        XCTAssertTrue(html.contains(#"<span class="syntax-comment">// class return &lt;img&gt;</span>"#))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<img>"))
        assertBalancedSpans(html)
    }

    func testCommentMarkersInsideStringsAndQuotesInsideCommentsDoNotRetokenize() {
        let source = #"const first = "/* not a comment */ // still a string"; /* "not a string" const return */ return first;"#

        let html = SyntaxHighlighter.highlight(source, language: "javascript")

        XCTAssertTrue(html.contains(#"<span class="syntax-string">&quot;/* not a comment */ // still a string&quot;</span>"#))
        XCTAssertTrue(html.contains(#"<span class="syntax-comment">/* &quot;not a string&quot; const return */</span>"#))
        XCTAssertEqual(html.components(separatedBy: #"<span class="syntax-keyword">const</span>"#).count - 1, 1)
        XCTAssertEqual(html.components(separatedBy: #"<span class="syntax-keyword">return</span>"#).count - 1, 1)
        assertBalancedSpans(html)
    }

    func testNestedBlockCommentsAreConsumedForSwiftAndRust() {
        for language in ["swift", "rust"] {
            let html = SyntaxHighlighter.highlight("/* outer /* let fn */ return */ let", language: language)

            XCTAssertTrue(html.contains(#"<span class="syntax-comment">/* outer /* let fn */ return */</span>"#), language)
            XCTAssertEqual(html.components(separatedBy: #"class="syntax-comment""#).count - 1, 1, language)
            XCTAssertEqual(html.components(separatedBy: #"class="syntax-keyword""#).count - 1, 1, language)
            assertBalancedSpans(html, file: #filePath, line: #line)
        }
    }

    func testBlockCommentTerminatorsAreNotEscapedByBackslashes() {
        for language in ["swift", "cpp", "jsonc", "css"] {
            let html = SyntaxHighlighter.highlight("/* text \\*/ let after = 2;", language: language)

            XCTAssertTrue(html.contains("/* text \\*/</span>"), language)
            XCTAssertFalse(html.contains("class=\"syntax-comment\">/* text \\*/ let after"), language)
            assertBalancedSpans(html, file: #filePath, line: #line)
        }
    }

    func testRustLifetimesRemainIdentifiersWhileCharacterLiteralsHighlight() {
        let html = SyntaxHighlighter.highlight(
            "fn choose<'a, 'b>(left: &'a str, right: &'b str) -> &'a str { let marker = 'x'; left }",
            language: "rust"
        )

        XCTAssertEqual(html.components(separatedBy: "class=\"syntax-string\"").count - 1, 1)
        XCTAssertTrue(html.contains("<span class=\"syntax-string\">&#39;x&#39;</span>"))
        XCTAssertTrue(html.contains("&#39;a"))
        XCTAssertTrue(html.contains("&#39;b"))
        assertBalancedSpans(html)
    }

    func testPythonTripleQuotedStringCanContainCommentsAndInjection() {
        let source = "\"\"\"# not a comment\n<img onerror=alert(1)>\"\"\"\ndef run(): # return <script>"

        let html = SyntaxHighlighter.highlight(source, language: "py3")

        XCTAssertTrue(html.contains(#"<span class="syntax-string">&quot;&quot;&quot;# not a comment"#))
        XCTAssertTrue(html.contains("&lt;img onerror=alert(1)&gt;"))
        XCTAssertTrue(html.contains(#"<span class="syntax-keyword">def</span>"#))
        XCTAssertTrue(html.contains(#"<span class="syntax-comment"># return &lt;script&gt;</span>"#))
        XCTAssertFalse(html.contains("<img"))
        XCTAssertFalse(html.contains("<script"))
        assertBalancedSpans(html)
    }

    func testJSONDistinguishesKeysValuesLiteralsAndNumbers() {
        let source = #"{"payload":"</span><script>","ok":true,"count":12.5,"empty":null}"#

        let html = SyntaxHighlighter.highlight(source, language: "json")

        XCTAssertTrue(html.contains(#"<span class="syntax-attribute">&quot;payload&quot;</span>"#))
        XCTAssertTrue(html.contains(#"<span class="syntax-string">&quot;&lt;/span&gt;&lt;script&gt;&quot;</span>"#))
        XCTAssertTrue(html.contains(#"<span class="syntax-literal">true</span>"#))
        XCTAssertTrue(html.contains(#"<span class="syntax-number">12.5</span>"#))
        XCTAssertTrue(html.contains(#"<span class="syntax-literal">null</span>"#))
        XCTAssertFalse(html.contains("<script>"))
        assertBalancedSpans(html)
    }

    func testJSONCommentsAreEnabledOnlyForCommentAliases() {
        let source = "{\"ok\": true} // return <script>"
        let strict = SyntaxHighlighter.highlight(source, language: "json")
        let commented = SyntaxHighlighter.highlight(source, language: "jsonc")

        XCTAssertFalse(strict.contains(#"class="syntax-comment""#))
        XCTAssertTrue(commented.contains(#"<span class="syntax-comment">// return &lt;script&gt;</span>"#))
        XCTAssertFalse(commented.contains("<script>"))
    }

    func testMarkupEscapesTagsAttributesStringsAndComments() {
        let source = #"<script data-value="</span><img src=x>">alert(1)</script><!-- <iframe> -->"#

        let html = SyntaxHighlighter.highlight(source, language: "html")

        XCTAssertTrue(html.contains(#"<span class="syntax-tag">&lt;script</span>"#))
        XCTAssertTrue(html.contains(#"<span class="syntax-attribute">data-value</span>"#))
        XCTAssertTrue(html.contains(#"<span class="syntax-string">&quot;&lt;/span&gt;&lt;img src=x&gt;&quot;</span>"#))
        XCTAssertTrue(html.contains(#"<span class="syntax-comment">&lt;!-- &lt;iframe&gt; --&gt;</span>"#))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("<img"))
        XCTAssertFalse(html.contains("<iframe"))
        assertBalancedSpans(html)
    }

    func testCSSSQLYAMLAndMarkdownReceiveUsefulTokens() {
        let css = SyntaxHighlighter.highlight("@media screen { color: red; /* <script> */ }", language: "scss")
        XCTAssertTrue(css.contains(#"<span class="syntax-directive">@media</span>"#))
        XCTAssertTrue(css.contains(#"<span class="syntax-attribute">color</span>"#))
        XCTAssertTrue(css.contains(#"<span class="syntax-comment">/* &lt;script&gt; */</span>"#))

        let sql = SyntaxHighlighter.highlight("SELECT 'return -- text' FROM users -- DROP <table>", language: "postgresql")
        XCTAssertTrue(sql.contains(#"<span class="syntax-keyword">SELECT</span>"#))
        XCTAssertTrue(sql.contains(#"<span class="syntax-string">&#39;return -- text&#39;</span>"#))
        XCTAssertTrue(sql.contains(#"<span class="syntax-comment">-- DROP &lt;table&gt;</span>"#))

        let yaml = SyntaxHighlighter.highlight("enabled: true\nmessage: \"# not comment\" # <script>", language: "yml")
        XCTAssertTrue(yaml.contains(#"<span class="syntax-attribute">enabled</span>"#))
        XCTAssertTrue(yaml.contains(#"<span class="syntax-literal">true</span>"#))
        XCTAssertTrue(yaml.contains(#"<span class="syntax-string">&quot;# not comment&quot;</span>"#))
        XCTAssertTrue(yaml.contains(#"<span class="syntax-comment"># &lt;script&gt;</span>"#))

        let markdown = SyntaxHighlighter.highlight("# Heading\nUse `<script>` and [docs](https://example.com).", language: "md")
        XCTAssertTrue(markdown.contains(#"<span class="syntax-directive">#</span>"#))
        XCTAssertTrue(markdown.contains(#"<span class="syntax-string">`&lt;script&gt;`</span>"#))
        XCTAssertTrue(markdown.contains(#"<span class="syntax-string">https://example.com</span>"#))
        XCTAssertFalse(markdown.contains("<script>"))
    }

    func testShellVariablesStringsCommentsAndKeywords() {
        let source = "if test -n $HOME; then echo \"# not comment\"; fi # <script>"

        let html = SyntaxHighlighter.highlight(source, language: "zsh")

        XCTAssertTrue(html.contains(#"<span class="syntax-keyword">if</span>"#))
        XCTAssertTrue(html.contains(#"<span class="syntax-variable">$HOME</span>"#))
        XCTAssertTrue(html.contains(#"<span class="syntax-string">&quot;# not comment&quot;</span>"#))
        XCTAssertTrue(html.contains(#"<span class="syntax-comment"># &lt;script&gt;</span>"#))
        XCTAssertFalse(html.contains("<script>"))
        assertBalancedSpans(html)
    }

    func testCommonCompiledLanguageFamiliesAndAliases() {
        let cases: [(language: String, source: String, token: String)] = [
            ("{.swift}", "func run() -> Bool { true }", "func"),
            ("language-js", "const value = true", "const"),
            ("tsx", "interface View { readonly id: string }", "interface"),
            ("c", "static int value = 1;", "static"),
            ("c++", "class Reader { public: void run(); };", "class"),
            ("objc", "@interface Reader : NSObject", "@interface"),
            ("c#", "public record Reader(string Name);", "public"),
            ("rs", "pub fn run() -> bool { true }", "pub"),
            ("golang", "func main() { defer close(ch) }", "func"),
            ("java", "public class Reader {}", "public"),
            ("kt", "data class Reader(val name: String)", "data")
        ]

        for item in cases {
            let html = SyntaxHighlighter.highlight(item.source, language: item.language)
            XCTAssertTrue(html.contains(#"class="syntax-keyword""#) || html.contains(#"class="syntax-directive""#), item.language)
            XCTAssertTrue(html.contains(item.token), item.language)
            assertBalancedSpans(html, file: #filePath, line: #line)
        }
    }

    func testUnsupportedAndMissingLanguagesUseEscapedPlainFallback() {
        let source = #"<script data-x="'">& return"#
        let expected = "&lt;script data-x=&quot;&#39;&quot;&gt;&amp; return"

        XCTAssertEqual(SyntaxHighlighter.highlight(source, language: nil), expected)
        XCTAssertEqual(SyntaxHighlighter.highlight(source, language: "brainfuck<script>"), expected)
        XCTAssertFalse(SyntaxHighlighter.highlight(source, language: "unknown").contains("<span"))
    }

    func testHardByteCapFallsBackWithoutTokenScanning() {
        let source = "let " + String(repeating: "é", count: SyntaxHighlighter.maximumHighlightBytes)

        let html = SyntaxHighlighter.highlight(source, language: "swift")

        XCTAssertTrue(source.utf8.count > SyntaxHighlighter.maximumHighlightBytes)
        XCTAssertFalse(html.contains("<span"))
        XCTAssertTrue(html.hasPrefix("let "))
    }

    func testHardLineCapFallsBackWithoutTokenScanning() {
        let source = Array(repeating: "let value = true", count: SyntaxHighlighter.maximumHighlightLines + 1)
            .joined(separator: "\n")

        let html = SyntaxHighlighter.highlight(source, language: "swift")

        XCTAssertFalse(html.contains("<span"))
        XCTAssertTrue(html.contains("let value = true"))
    }

    func testLargeMarkdownIndentAndMismatchedBacktickRunsStayBalanced() {
        let indentation = String(repeating: " ", count: 64 * 1_024)
        let ticks = String(repeating: "`", count: 16 * 1_024)
        // Prefix the run so it exercises inline-code scanning rather than the
        // fenced-code marker path used by backticks at the start of a line.
        let source = indentation + "# heading\nx" + ticks + "x" + ticks.dropLast()

        let html = SyntaxHighlighter.highlight(source, language: "markdown")

        XCTAssertTrue(html.contains("class=\"syntax-directive\""))
        XCTAssertTrue(html.contains("class=\"syntax-string\""))
        assertBalancedSpans(html)
    }

    func testUnterminatedStringsAndCommentsRemainEscapedAndBalanced() {
        let cases = [
            SyntaxHighlighter.highlight(#"let value = "</code><script>"#, language: "swift"),
            SyntaxHighlighter.highlight("/* </span><script>", language: "cpp"),
            SyntaxHighlighter.highlight("<!-- <script>", language: "xml")
        ]

        for html in cases {
            XCTAssertFalse(html.contains("<script>"))
            XCTAssertFalse(html.contains("</code>"))
            assertBalancedSpans(html, file: #filePath, line: #line)
        }
    }

    func testHighlightingIsDeterministic() {
        let source = "func café(_ value: String) -> Bool { return value == \"☕️\" }"
        let first = SyntaxHighlighter.highlight(source, language: "swift")

        for _ in 0..<10 {
            XCTAssertEqual(SyntaxHighlighter.highlight(source, language: "swift"), first)
        }
    }

    private func assertBalancedSpans(
        _ html: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let openings = html.components(separatedBy: "<span class=\"").count - 1
        let closings = html.components(separatedBy: "</span>").count - 1
        XCTAssertEqual(openings, closings, file: file, line: line)
    }
}
