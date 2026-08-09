import Foundation

/// A small, deterministic syntax highlighter for reader previews.
///
/// The returned string is safe to place directly inside a `<code>` element. Every
/// source scalar passes through HTML escaping; the only markup this type emits is
/// a fixed set of `<span class="syntax-*">` wrappers.
enum SyntaxHighlighter {
    static let maximumHighlightBytes = 256 * 1024
    static let maximumHighlightLines = 4_000

    static func highlight(_ source: String, language: String?) -> String {
        guard isWithinHighlightBudget(source),
              let language = HighlightLanguage(infoString: language) else {
            return escapeHTML(source)
        }

        let scalars = Array(source.unicodeScalars)
        switch language {
        case .json, .jsonc:
            var scanner = JSONScanner(scalars: scalars, allowsComments: language == .jsonc)
            return scanner.render()
        case .markup:
            var scanner = MarkupScanner(scalars: scalars)
            return scanner.render()
        case .css:
            var scanner = CSSScanner(scalars: scalars)
            return scanner.render()
        case .markdown:
            var scanner = MarkdownScanner(scalars: scalars)
            return scanner.render()
        case .yaml:
            var scanner = YAMLScanner(scalars: scalars)
            return scanner.render()
        default:
            guard let profile = LexicalProfiles.profile(for: language) else {
                return escapeHTML(source)
            }
            var scanner = GenericScanner(scalars: scalars, profile: profile)
            return scanner.render()
        }
    }

    private static func isWithinHighlightBudget(_ source: String) -> Bool {
        guard source.utf8.count <= maximumHighlightBytes else { return false }

        var lineCount = 1
        var pendingCarriageReturn = false
        for scalar in source.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                lineCount += 1
                pendingCarriageReturn = false
            case 0x0D:
                if pendingCarriageReturn { lineCount += 1 }
                pendingCarriageReturn = true
            default:
                if pendingCarriageReturn {
                    lineCount += 1
                    pendingCarriageReturn = false
                }
            }
            if lineCount > maximumHighlightLines { return false }
        }
        if pendingCarriageReturn { lineCount += 1 }
        return lineCount <= maximumHighlightLines
    }
}

private enum HighlightLanguage: Equatable {
    case swift
    case javascript
    case typescript
    case json
    case jsonc
    case python
    case shell
    case markup
    case css
    case sql
    case markdown
    case yaml
    case c
    case cpp
    case objectiveC
    case csharp
    case rust
    case go
    case java
    case kotlin

    init?(infoString: String?) {
        guard var candidate = infoString?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init),
              !candidate.isEmpty else {
            return nil
        }

        if candidate.hasPrefix("language-") {
            candidate.removeFirst("language-".count)
        }
        if candidate.hasPrefix("{.") {
            candidate.removeFirst(2)
            candidate = String(candidate.prefix { $0 != "," && $0 != "}" })
        } else if candidate.hasPrefix(".") {
            candidate.removeFirst()
        }
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))

        switch candidate {
        case "swift": self = .swift
        case "javascript", "js", "jsx", "mjs", "cjs", "node": self = .javascript
        case "typescript", "ts", "tsx": self = .typescript
        case "json": self = .json
        case "jsonc", "json5": self = .jsonc
        case "python", "py", "py3", "python3": self = .python
        case "shell", "sh", "bash", "zsh", "fish", "console": self = .shell
        case "html", "htm", "xml", "xhtml", "svg": self = .markup
        case "css", "scss", "sass", "less": self = .css
        case "sql", "postgres", "postgresql", "mysql", "sqlite", "plsql": self = .sql
        case "markdown", "md", "mdown", "mkd": self = .markdown
        case "yaml", "yml": self = .yaml
        case "c", "h": self = .c
        case "cpp", "c++", "cc", "cxx", "hpp", "hxx": self = .cpp
        case "objective-c", "objc", "objective-c++", "objcpp", "mm": self = .objectiveC
        case "csharp", "c#", "cs": self = .csharp
        case "rust", "rs": self = .rust
        case "go", "golang": self = .go
        case "java": self = .java
        case "kotlin", "kt", "kts": self = .kotlin
        default: return nil
        }
    }
}

private enum SyntaxTokenKind: Equatable {
    case keyword
    case type
    case literal
    case number
    case string
    case comment
    case tag
    case attribute
    case variable
    case directive

    var cssClass: String {
        switch self {
        case .keyword: "syntax-keyword"
        case .type: "syntax-type"
        case .literal: "syntax-literal"
        case .number: "syntax-number"
        case .string: "syntax-string"
        case .comment: "syntax-comment"
        case .tag: "syntax-tag"
        case .attribute: "syntax-attribute"
        case .variable: "syntax-variable"
        case .directive: "syntax-directive"
        }
    }
}

private struct HighlightBuffer {
    private struct Chunk {
        let kind: SyntaxTokenKind?
        var escapedText: String
    }

    private let scalars: [UnicodeScalar]
    private var chunks: [Chunk] = []

    init(scalars: [UnicodeScalar]) {
        self.scalars = scalars
        chunks.reserveCapacity(max(8, scalars.count / 8))
    }

    mutating func emit(_ range: Range<Int>, as kind: SyntaxTokenKind? = nil) {
        guard !range.isEmpty else { return }
        let escaped = escapeHTML(scalars, range: range)
        if let lastIndex = chunks.indices.last, chunks[lastIndex].kind == kind {
            chunks[lastIndex].escapedText += escaped
        } else {
            chunks.append(Chunk(kind: kind, escapedText: escaped))
        }
    }

    func rendered() -> String {
        var result = ""
        result.reserveCapacity(chunks.reduce(0) { $0 + $1.escapedText.count + ($1.kind == nil ? 0 : 43) })
        for chunk in chunks {
            if let kind = chunk.kind {
                result += "<span class=\"\(kind.cssClass)\">"
                result += chunk.escapedText
                result += "</span>"
            } else {
                result += chunk.escapedText
            }
        }
        return result
    }
}

private struct ScalarPattern {
    let scalars: [UnicodeScalar]

    init(_ value: String) {
        scalars = Array(value.unicodeScalars)
    }
}

private struct DelimitedRule {
    let opening: ScalarPattern
    let closing: ScalarPattern
    let allowsNewlines: Bool
    let supportsBackslashEscapes: Bool
    let doubledClosingEscapes: Bool
    let allowsNesting: Bool

    init(
        _ opening: String,
        _ closing: String? = nil,
        allowsNewlines: Bool = false,
        supportsBackslashEscapes: Bool = true,
        doubledClosingEscapes: Bool = false,
        allowsNesting: Bool = false
    ) {
        self.opening = ScalarPattern(opening)
        self.closing = ScalarPattern(closing ?? opening)
        self.allowsNewlines = allowsNewlines
        self.supportsBackslashEscapes = supportsBackslashEscapes
        self.doubledClosingEscapes = doubledClosingEscapes
        self.allowsNesting = allowsNesting
    }
}

private struct LexicalProfile {
    let keywords: Set<String>
    let types: Set<String>
    let literals: Set<String>
    let lineComments: [ScalarPattern]
    let blockComments: [DelimitedRule]
    let strings: [DelimitedRule]
    let caseInsensitiveIdentifiers: Bool
    let hashDirectives: Bool
    let atDirectives: Bool
    let dollarVariables: Bool
    let requiresPlausibleSingleQuotedCharacter: Bool

    init(
        keywords: Set<String>,
        types: Set<String>,
        literals: Set<String>,
        lineComments: [ScalarPattern],
        blockComments: [DelimitedRule],
        strings: [DelimitedRule],
        caseInsensitiveIdentifiers: Bool,
        hashDirectives: Bool,
        atDirectives: Bool,
        dollarVariables: Bool,
        requiresPlausibleSingleQuotedCharacter: Bool = false
    ) {
        self.keywords = keywords
        self.types = types
        self.literals = literals
        self.lineComments = lineComments
        self.blockComments = blockComments
        self.strings = strings
        self.caseInsensitiveIdentifiers = caseInsensitiveIdentifiers
        self.hashDirectives = hashDirectives
        self.atDirectives = atDirectives
        self.dollarVariables = dollarVariables
        self.requiresPlausibleSingleQuotedCharacter = requiresPlausibleSingleQuotedCharacter
    }
}

private enum LexicalProfiles {
    static func profile(for language: HighlightLanguage) -> LexicalProfile? {
        switch language {
        case .swift: swift
        case .javascript: javascript
        case .typescript: typescript
        case .python: python
        case .shell: shell
        case .sql: sql
        case .c: c
        case .cpp: cpp
        case .objectiveC: objectiveC
        case .csharp: csharp
        case .rust: rust
        case .go: go
        case .java: java
        case .kotlin: kotlin
        case .json, .jsonc, .markup, .css, .markdown, .yaml: nil
        }
    }

    private static let cLineComments = [ScalarPattern("//")]
    private static let cBlockComments = [DelimitedRule("/*", "*/", allowsNewlines: true, supportsBackslashEscapes: false)]
    private static let cStrings = [
        DelimitedRule("\""),
        DelimitedRule("'")
    ]

    static let swift = LexicalProfile(
        keywords: words("actor associatedtype borrowing break case catch class consuming continue convenience copy default defer deinit didSet distributed do dynamic else enum extension fallthrough fileprivate final for func get guard if import indirect infix init in inout internal is isolated lazy let macro mutating nonisolated open operator optional override package postfix precedencegroup prefix private protocol public repeat required rethrows return set some static struct subscript switch throws try typealias unowned var weak where while willSet"),
        types: words("Any AnyObject Array Bool Character Dictionary Double Error Float Int Int8 Int16 Int32 Int64 Never Optional Result Set String UInt UInt8 UInt16 UInt32 UInt64 URL Void"),
        literals: words("false nil self Self super true"),
        lineComments: cLineComments,
        blockComments: [DelimitedRule("/*", "*/", allowsNewlines: true, supportsBackslashEscapes: false, allowsNesting: true)],
        strings: [
            DelimitedRule("\"\"\"", allowsNewlines: true),
            DelimitedRule("\""),
            DelimitedRule("`")
        ],
        caseInsensitiveIdentifiers: false,
        hashDirectives: true,
        atDirectives: true,
        dollarVariables: false
    )

    static let javascript = LexicalProfile(
        keywords: words("async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch throw try typeof var void while with yield"),
        types: words("Array BigInt Boolean Date Error Function Map Number Object Promise RegExp Set String Symbol WeakMap WeakSet"),
        literals: words("false Infinity NaN null this true undefined"),
        lineComments: cLineComments,
        blockComments: cBlockComments,
        strings: [DelimitedRule("\""), DelimitedRule("'"), DelimitedRule("`", allowsNewlines: true)],
        caseInsensitiveIdentifiers: false,
        hashDirectives: false,
        atDirectives: true,
        dollarVariables: true
    )

    static let typescript = LexicalProfile(
        keywords: javascript.keywords.union(words("abstract as asserts any bigint boolean constructor declare enum implements infer interface is keyof module namespace never number object private protected public readonly require satisfies string symbol type unique unknown using")),
        types: javascript.types.union(words("Record Partial Required Readonly Pick Omit Exclude Extract NonNullable Parameters ReturnType InstanceType")),
        literals: javascript.literals,
        lineComments: cLineComments,
        blockComments: cBlockComments,
        strings: javascript.strings,
        caseInsensitiveIdentifiers: false,
        hashDirectives: false,
        atDirectives: true,
        dollarVariables: true
    )

    static let python = LexicalProfile(
        keywords: words("and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return try while with yield"),
        types: words("bool bytes complex dict float frozenset int list memoryview object range set slice str tuple type"),
        literals: words("False None NotImplemented True Ellipsis self cls"),
        lineComments: [ScalarPattern("#")],
        blockComments: [],
        strings: [
            DelimitedRule("\"\"\"", allowsNewlines: true),
            DelimitedRule("'''", allowsNewlines: true),
            DelimitedRule("\""),
            DelimitedRule("'")
        ],
        caseInsensitiveIdentifiers: false,
        hashDirectives: false,
        atDirectives: true,
        dollarVariables: false
    )

    static let shell = LexicalProfile(
        keywords: words("case coproc do done elif else esac fi for function if in select then time until while"),
        types: words("alias bg bind break builtin caller cd command compgen complete declare dirs disown echo enable eval exec exit export false fc fg getopts hash help history jobs kill let local logout mapfile popd printf pushd pwd read readarray readonly return set shift shopt source suspend test times trap true type typeset ulimit umask unalias unset wait"),
        literals: words("false true"),
        lineComments: [ScalarPattern("#")],
        blockComments: [],
        strings: [DelimitedRule("\""), DelimitedRule("'", supportsBackslashEscapes: false), DelimitedRule("`")],
        caseInsensitiveIdentifiers: false,
        hashDirectives: false,
        atDirectives: false,
        dollarVariables: true
    )

    static let sql = LexicalProfile(
        keywords: words("add all alter analyze and any as asc begin between by cascade case check column commit constraint create cross database default delete desc distinct drop else end except exists explain false fetch foreign from full grant group having if in index inner insert intersect into is join key left like limit not null offset on or order outer primary references returning revoke right rollback row select set table then transaction trigger true union unique update using values view when where with"),
        types: words("bigint binary bit blob boolean char date datetime decimal double float int integer interval json numeric real smallint text time timestamp uuid varchar"),
        literals: words("false null true unknown"),
        lineComments: [ScalarPattern("--")],
        blockComments: cBlockComments,
        strings: [
            DelimitedRule("'", supportsBackslashEscapes: false, doubledClosingEscapes: true),
            DelimitedRule("\"", supportsBackslashEscapes: false, doubledClosingEscapes: true),
            DelimitedRule("[", "]", supportsBackslashEscapes: false)
        ],
        caseInsensitiveIdentifiers: true,
        hashDirectives: false,
        atDirectives: true,
        dollarVariables: true
    )

    static let c = LexicalProfile(
        keywords: words("_Alignas _Alignof _Atomic _Generic _Noreturn _Static_assert _Thread_local auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while"),
        types: words("bool char double float int int16_t int32_t int64_t int8_t long ptrdiff_t short signed size_t uint16_t uint32_t uint64_t uint8_t unsigned void wchar_t"),
        literals: words("false NULL true"),
        lineComments: cLineComments,
        blockComments: cBlockComments,
        strings: cStrings,
        caseInsensitiveIdentifiers: false,
        hashDirectives: true,
        atDirectives: false,
        dollarVariables: false
    )

    static let cpp = LexicalProfile(
        keywords: c.keywords.union(words("alignas alignof and and_eq asm bitand bitor catch class compl concept consteval constexpr constinit const_cast co_await co_return co_yield decltype delete dynamic_cast explicit export friend mutable namespace new noexcept not not_eq operator or or_eq private protected public reinterpret_cast requires static_assert static_cast template this thread_local throw try typeid typename using virtual xor xor_eq")),
        types: c.types.union(words("array auto deque exception map optional pair set shared_ptr span string string_view tuple unique_ptr unordered_map unordered_set variant vector weak_ptr")),
        literals: c.literals.union(words("nullptr")),
        lineComments: cLineComments,
        blockComments: cBlockComments,
        strings: cStrings,
        caseInsensitiveIdentifiers: false,
        hashDirectives: true,
        atDirectives: false,
        dollarVariables: false
    )

    static let objectiveC = LexicalProfile(
        keywords: cpp.keywords.union(words("id instancetype selector")),
        types: cpp.types.union(words("NSArray NSData NSDictionary NSError NSNumber NSObject NSSet NSString NSURL")),
        literals: cpp.literals.union(words("YES NO Nil nil")),
        lineComments: cLineComments,
        blockComments: cBlockComments,
        strings: cStrings,
        caseInsensitiveIdentifiers: false,
        hashDirectives: true,
        atDirectives: true,
        dollarVariables: false
    )

    static let csharp = LexicalProfile(
        keywords: words("abstract as async await base break case catch checked class const continue default delegate do else enum event explicit extern finally fixed for foreach goto if implicit in interface internal is lock namespace new operator out override params private protected public readonly record ref return sealed sizeof stackalloc static struct switch this throw try typeof unchecked unsafe using virtual void volatile while yield"),
        types: words("bool byte char decimal double dynamic float int long nint nuint object sbyte short string uint ulong ushort var"),
        literals: words("false null true"),
        lineComments: cLineComments,
        blockComments: cBlockComments,
        strings: [DelimitedRule("\"\"\"", allowsNewlines: true), DelimitedRule("\""), DelimitedRule("'")],
        caseInsensitiveIdentifiers: false,
        hashDirectives: true,
        atDirectives: true,
        dollarVariables: true
    )

    static let rust = LexicalProfile(
        keywords: words("as async await break const continue crate dyn else enum extern fn for if impl in let loop macro match mod move mut pub ref return self Self static struct super trait type union unsafe use where while yield"),
        types: words("bool char f32 f64 i128 i16 i32 i64 i8 isize str String u128 u16 u32 u64 u8 usize Vec Option Result Box"),
        literals: words("false None Some true"),
        lineComments: cLineComments,
        blockComments: [DelimitedRule("/*", "*/", allowsNewlines: true, supportsBackslashEscapes: false, allowsNesting: true)],
        strings: [DelimitedRule("\""), DelimitedRule("'")],
        caseInsensitiveIdentifiers: false,
        hashDirectives: true,
        atDirectives: false,
        dollarVariables: false,
        requiresPlausibleSingleQuotedCharacter: true
    )

    static let go = LexicalProfile(
        keywords: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var"),
        types: words("bool byte complex128 complex64 error float32 float64 int int16 int32 int64 int8 rune string uint uint16 uint32 uint64 uint8 uintptr"),
        literals: words("false iota nil true"),
        lineComments: cLineComments,
        blockComments: cBlockComments,
        strings: [DelimitedRule("\""), DelimitedRule("'"), DelimitedRule("`", allowsNewlines: true, supportsBackslashEscapes: false)],
        caseInsensitiveIdentifiers: false,
        hashDirectives: false,
        atDirectives: false,
        dollarVariables: false
    )

    static let java = LexicalProfile(
        keywords: words("abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import instanceof interface native new package private protected public return static strictfp super switch synchronized this throw throws transient try volatile while"),
        types: words("boolean byte char double float int long short String Object Integer Long Double Float Boolean Character List Map Set Optional"),
        literals: words("false null true"),
        lineComments: cLineComments,
        blockComments: cBlockComments,
        strings: [DelimitedRule("\"\"\"", allowsNewlines: true), DelimitedRule("\""), DelimitedRule("'")],
        caseInsensitiveIdentifiers: false,
        hashDirectives: false,
        atDirectives: true,
        dollarVariables: false
    )

    static let kotlin = LexicalProfile(
        keywords: words("actual abstract annotation as break by catch class companion const constructor continue crossinline data delegate do dynamic else enum expect external field file final finally for fun get if import in infix init inline inner interface internal is lateinit noinline object open operator out override package param private property protected public receiver reified return sealed set setparam super suspend tailrec this throw try typealias typeof val var vararg when where while"),
        types: words("Any Boolean Byte Char Double Float Int Long Nothing Number Short String Unit Array List Map Set MutableList MutableMap MutableSet"),
        literals: words("false null this true"),
        lineComments: cLineComments,
        blockComments: [DelimitedRule("/*", "*/", allowsNewlines: true, supportsBackslashEscapes: false, allowsNesting: true)],
        strings: [DelimitedRule("\"\"\"", allowsNewlines: true), DelimitedRule("\""), DelimitedRule("'")],
        caseInsensitiveIdentifiers: false,
        hashDirectives: false,
        atDirectives: true,
        dollarVariables: true
    )
}

private struct GenericScanner {
    let scalars: [UnicodeScalar]
    let profile: LexicalProfile
    private var index = 0
    private var output: HighlightBuffer

    init(scalars: [UnicodeScalar], profile: LexicalProfile) {
        self.scalars = scalars
        self.profile = profile
        output = HighlightBuffer(scalars: scalars)
    }

    mutating func render() -> String {
        while index < scalars.count {
            if let prefix = firstMatching(profile.lineComments, at: index) {
                let end = consumeLine(from: index + prefix.scalars.count)
                output.emit(index..<end, as: .comment)
                index = end
                continue
            }
            if let rule = firstMatching(profile.blockComments, at: index) {
                let end = consumeDelimited(rule, from: index)
                output.emit(index..<end, as: .comment)
                index = end
                continue
            }
            if let rule = firstMatching(profile.strings, at: index) {
                if profile.requiresPlausibleSingleQuotedCharacter,
                   rule.opening.scalars.count == 1,
                   rule.opening.scalars.first?.value == 0x27,
                   !isPlausibleSingleQuotedCharacter(at: index) {
                    output.emit(index..<(index + 1))
                    index += 1
                    continue
                }
                let end = consumeDelimited(rule, from: index)
                output.emit(index..<end, as: .string)
                index = end
                continue
            }
            if isASCIIDigit(scalars[index]) || (isScalar(".", at: index) && index + 1 < scalars.count && isASCIIDigit(scalars[index + 1])) {
                let end = consumeNumber(from: index, in: scalars)
                output.emit(index..<end, as: .number)
                index = end
                continue
            }
            if profile.hashDirectives, isScalar("#", at: index), index + 1 < scalars.count, isIdentifierStart(scalars[index + 1]) {
                let end = consumeIdentifier(from: index + 1, in: scalars)
                output.emit(index..<end, as: .directive)
                index = end
                continue
            }
            if profile.atDirectives, isScalar("@", at: index), index + 1 < scalars.count, isIdentifierStart(scalars[index + 1]) {
                let end = consumeIdentifier(from: index + 1, in: scalars)
                output.emit(index..<end, as: .directive)
                index = end
                continue
            }
            if profile.dollarVariables, isScalar("$", at: index) {
                let end = consumeVariable(from: index)
                if end > index + 1 {
                    output.emit(index..<end, as: .variable)
                    index = end
                    continue
                }
            }
            if isIdentifierStart(scalars[index]) {
                let end = consumeIdentifier(from: index, in: scalars)
                let identifier = scalarString(scalars, range: index..<end)
                let lookup = profile.caseInsensitiveIdentifiers ? identifier.lowercased() : identifier
                let kind: SyntaxTokenKind?
                if profile.keywords.contains(lookup) {
                    kind = .keyword
                } else if profile.types.contains(lookup) {
                    kind = .type
                } else if profile.literals.contains(lookup) {
                    kind = .literal
                } else {
                    kind = nil
                }
                output.emit(index..<end, as: kind)
                index = end
                continue
            }

            output.emit(index..<(index + 1))
            index += 1
        }
        return output.rendered()
    }

    private func firstMatching(_ patterns: [ScalarPattern], at position: Int) -> ScalarPattern? {
        patterns.first { matches($0.scalars, in: scalars, at: position) }
    }

    private func firstMatching(_ rules: [DelimitedRule], at position: Int) -> DelimitedRule? {
        rules.first { matches($0.opening.scalars, in: scalars, at: position) }
    }

    private func consumeLine(from start: Int) -> Int {
        var cursor = start
        while cursor < scalars.count, !isLineBreak(scalars[cursor]) {
            cursor += 1
        }
        return cursor
    }

    private func isPlausibleSingleQuotedCharacter(at start: Int) -> Bool {
        let content = start + 1
        guard content < scalars.count, !isLineBreak(scalars[content]) else { return false }
        if scalars[content].value != 0x5C {
            return content + 1 < scalars.count && scalars[content + 1].value == 0x27
        }

        // Rust escape forms are bounded in practice (`\n`, `\xNN`, `\u{...}`).
        // Requiring a nearby terminator prevents lifetimes such as `'a` and
        // `<'a, 'b>` from swallowing the rest of the signature.
        let limit = min(scalars.count, content + 16)
        var cursor = content + 1
        while cursor < limit, !isLineBreak(scalars[cursor]) {
            if scalars[cursor].value == 0x27 { return true }
            cursor += 1
        }
        return false
    }

    private func consumeDelimited(_ rule: DelimitedRule, from start: Int) -> Int {
        var cursor = start + rule.opening.scalars.count
        var depth = 1
        while cursor < scalars.count {
            if rule.supportsBackslashEscapes, scalars[cursor].value == 0x5C {
                cursor += min(2, scalars.count - cursor)
                continue
            }
            if !rule.allowsNewlines, isLineBreak(scalars[cursor]) {
                return cursor
            }
            if rule.allowsNesting, matches(rule.opening.scalars, in: scalars, at: cursor) {
                depth += 1
                cursor += rule.opening.scalars.count
                continue
            }
            if matches(rule.closing.scalars, in: scalars, at: cursor) {
                if rule.doubledClosingEscapes,
                   matches(rule.closing.scalars, in: scalars, at: cursor + rule.closing.scalars.count) {
                    cursor += rule.closing.scalars.count * 2
                    continue
                }
                depth -= 1
                cursor += rule.closing.scalars.count
                if depth == 0 { return cursor }
                continue
            }
            cursor += 1
        }
        return cursor
    }

    private func consumeVariable(from start: Int) -> Int {
        var cursor = start + 1
        guard cursor < scalars.count else { return cursor }
        if isScalar("{", at: cursor) {
            cursor += 1
            while cursor < scalars.count, !isScalar("}", at: cursor), !isLineBreak(scalars[cursor]) {
                cursor += 1
            }
            if cursor < scalars.count, isScalar("}", at: cursor) { cursor += 1 }
            return cursor
        }
        if isIdentifierStart(scalars[cursor]) || isASCIIDigit(scalars[cursor]) || "?@!#$*-".unicodeScalars.contains(scalars[cursor]) {
            cursor += 1
            while cursor < scalars.count, isIdentifierContinue(scalars[cursor]) {
                cursor += 1
            }
        }
        return cursor
    }

    private func isScalar(_ value: Character, at position: Int) -> Bool {
        guard position < scalars.count, let expected = value.unicodeScalars.first else { return false }
        return scalars[position] == expected
    }
}

private struct JSONScanner {
    let scalars: [UnicodeScalar]
    let allowsComments: Bool
    private var index = 0
    private var output: HighlightBuffer

    init(scalars: [UnicodeScalar], allowsComments: Bool) {
        self.scalars = scalars
        self.allowsComments = allowsComments
        output = HighlightBuffer(scalars: scalars)
    }

    mutating func render() -> String {
        let lineComment = ScalarPattern("//")
        let blockComment = DelimitedRule("/*", "*/", allowsNewlines: true, supportsBackslashEscapes: false)
        let stringRule = DelimitedRule("\"")

        while index < scalars.count {
            if allowsComments, matches(lineComment.scalars, in: scalars, at: index) {
                var end = index + lineComment.scalars.count
                while end < scalars.count, !isLineBreak(scalars[end]) { end += 1 }
                output.emit(index..<end, as: .comment)
                index = end
                continue
            }
            if allowsComments, matches(blockComment.opening.scalars, in: scalars, at: index) {
                let end = consumeSimpleDelimited(blockComment, scalars: scalars, start: index)
                output.emit(index..<end, as: .comment)
                index = end
                continue
            }
            if matches(stringRule.opening.scalars, in: scalars, at: index) {
                let end = consumeSimpleDelimited(stringRule, scalars: scalars, start: index)
                var lookahead = end
                while lookahead < scalars.count, isHorizontalWhitespace(scalars[lookahead]) { lookahead += 1 }
                output.emit(index..<end, as: lookahead < scalars.count && scalars[lookahead].value == 0x3A ? .attribute : .string)
                index = end
                continue
            }
            if isASCIIDigit(scalars[index]) || scalars[index].value == 0x2D {
                let end = consumeNumber(from: index, in: scalars)
                if end > index + (scalars[index].value == 0x2D ? 1 : 0) {
                    output.emit(index..<end, as: .number)
                    index = end
                    continue
                }
            }
            if isIdentifierStart(scalars[index]) {
                let end = consumeIdentifier(from: index, in: scalars)
                let value = scalarString(scalars, range: index..<end)
                output.emit(index..<end, as: ["true", "false", "null"].contains(value) ? .literal : nil)
                index = end
                continue
            }
            output.emit(index..<(index + 1))
            index += 1
        }
        return output.rendered()
    }
}

private struct MarkupScanner {
    let scalars: [UnicodeScalar]
    private var index = 0
    private var output: HighlightBuffer

    init(scalars: [UnicodeScalar]) {
        self.scalars = scalars
        output = HighlightBuffer(scalars: scalars)
    }

    mutating func render() -> String {
        let commentOpen = ScalarPattern("<!--")
        let commentClose = ScalarPattern("-->")
        let cdataOpen = ScalarPattern("<![CDATA[")
        let cdataClose = ScalarPattern("]]>")

        while index < scalars.count {
            if matches(commentOpen.scalars, in: scalars, at: index) {
                let end = consumeUntil(commentClose.scalars, from: index + commentOpen.scalars.count)
                output.emit(index..<end, as: .comment)
                index = end
                continue
            }
            if matches(cdataOpen.scalars, in: scalars, at: index) {
                let end = consumeUntil(cdataClose.scalars, from: index + cdataOpen.scalars.count)
                output.emit(index..<end, as: .comment)
                index = end
                continue
            }
            guard scalars[index].value == 0x3C else {
                let start = index
                while index < scalars.count, scalars[index].value != 0x3C { index += 1 }
                output.emit(start..<index)
                continue
            }

            output.emit(index..<(index + 1), as: .tag)
            index += 1
            if index < scalars.count, [0x2F, 0x21, 0x3F].contains(scalars[index].value) {
                output.emit(index..<(index + 1), as: .tag)
                index += 1
            }
            if index < scalars.count, isMarkupNameStart(scalars[index]) {
                let end = consumeMarkupName(from: index)
                output.emit(index..<end, as: .tag)
                index = end
            }

            while index < scalars.count, scalars[index].value != 0x3E {
                if isLineBreak(scalars[index]) || isHorizontalWhitespace(scalars[index]) || scalars[index].value == 0x2F {
                    output.emit(index..<(index + 1))
                    index += 1
                    continue
                }
                if scalars[index].value == 0x22 || scalars[index].value == 0x27 {
                    let delimiter = scalars[index]
                    let start = index
                    index += 1
                    while index < scalars.count {
                        if scalars[index].value == 0x5C {
                            index += min(2, scalars.count - index)
                        } else if scalars[index] == delimiter {
                            index += 1
                            break
                        } else {
                            index += 1
                        }
                    }
                    output.emit(start..<index, as: .string)
                    continue
                }
                if scalars[index].value == 0x3D {
                    output.emit(index..<(index + 1))
                    index += 1
                    continue
                }
                if isMarkupNameStart(scalars[index]) {
                    let end = consumeMarkupName(from: index)
                    output.emit(index..<end, as: .attribute)
                    index = end
                    continue
                }
                output.emit(index..<(index + 1))
                index += 1
            }
            if index < scalars.count {
                output.emit(index..<(index + 1), as: .tag)
                index += 1
            }
        }
        return output.rendered()
    }

    private func consumeUntil(_ closing: [UnicodeScalar], from start: Int) -> Int {
        var cursor = start
        while cursor < scalars.count {
            if matches(closing, in: scalars, at: cursor) { return cursor + closing.count }
            cursor += 1
        }
        return cursor
    }

    private func consumeMarkupName(from start: Int) -> Int {
        var cursor = start + 1
        while cursor < scalars.count, isMarkupNameContinue(scalars[cursor]) { cursor += 1 }
        return cursor
    }
}

private struct CSSScanner {
    let scalars: [UnicodeScalar]
    private var index = 0
    private var output: HighlightBuffer

    init(scalars: [UnicodeScalar]) {
        self.scalars = scalars
        output = HighlightBuffer(scalars: scalars)
    }

    mutating func render() -> String {
        let comment = DelimitedRule("/*", "*/", allowsNewlines: true, supportsBackslashEscapes: false)
        let singleQuote = DelimitedRule("'")
        let doubleQuote = DelimitedRule("\"")

        while index < scalars.count {
            if matches(comment.opening.scalars, in: scalars, at: index) {
                let end = consumeSimpleDelimited(comment, scalars: scalars, start: index)
                output.emit(index..<end, as: .comment)
                index = end
                continue
            }
            if let stringRule = [singleQuote, doubleQuote].first(where: { matches($0.opening.scalars, in: scalars, at: index) }) {
                let end = consumeSimpleDelimited(stringRule, scalars: scalars, start: index)
                output.emit(index..<end, as: .string)
                index = end
                continue
            }
            if scalars[index].value == 0x40, index + 1 < scalars.count, isIdentifierStart(scalars[index + 1]) {
                let end = consumeCSSIdentifier(from: index + 1)
                output.emit(index..<end, as: .directive)
                index = end
                continue
            }
            if isASCIIDigit(scalars[index]) || (scalars[index].value == 0x2E && index + 1 < scalars.count && isASCIIDigit(scalars[index + 1])) {
                let end = consumeNumber(from: index, in: scalars)
                output.emit(index..<end, as: .number)
                index = end
                continue
            }
            if isIdentifierStart(scalars[index]) || (scalars[index].value == 0x2D && index + 1 < scalars.count) {
                let end = consumeCSSIdentifier(from: index)
                var lookahead = end
                while lookahead < scalars.count, isHorizontalWhitespace(scalars[lookahead]) { lookahead += 1 }
                let value = scalarString(scalars, range: index..<end).lowercased()
                let kind: SyntaxTokenKind?
                if lookahead < scalars.count, scalars[lookahead].value == 0x3A {
                    kind = .attribute
                } else if ["important", "inherit", "initial", "none", "revert", "unset", "var"].contains(value) {
                    kind = .literal
                } else {
                    kind = nil
                }
                output.emit(index..<end, as: kind)
                index = end
                continue
            }
            output.emit(index..<(index + 1))
            index += 1
        }
        return output.rendered()
    }

    private func consumeCSSIdentifier(from start: Int) -> Int {
        var cursor = start
        while cursor < scalars.count {
            let scalar = scalars[cursor]
            if isIdentifierContinue(scalar) || scalar.value == 0x2D || scalar.value == 0x5C {
                cursor += 1
            } else {
                break
            }
        }
        return max(cursor, start + 1)
    }
}

private struct YAMLScanner {
    let scalars: [UnicodeScalar]
    private var index = 0
    private var atLineStart = true
    private var output: HighlightBuffer

    init(scalars: [UnicodeScalar]) {
        self.scalars = scalars
        output = HighlightBuffer(scalars: scalars)
    }

    mutating func render() -> String {
        let singleQuote = DelimitedRule("'", supportsBackslashEscapes: false, doubledClosingEscapes: true)
        let doubleQuote = DelimitedRule("\"")

        while index < scalars.count {
            if isLineBreak(scalars[index]) {
                output.emit(index..<(index + 1))
                index += 1
                atLineStart = true
                continue
            }
            if isHorizontalWhitespace(scalars[index]) {
                output.emit(index..<(index + 1))
                index += 1
                continue
            }
            if scalars[index].value == 0x23, isCommentBoundary(before: index, in: scalars) {
                let start = index
                while index < scalars.count, !isLineBreak(scalars[index]) { index += 1 }
                output.emit(start..<index, as: .comment)
                atLineStart = false
                continue
            }
            if let rule = [singleQuote, doubleQuote].first(where: { matches($0.opening.scalars, in: scalars, at: index) }) {
                let end = consumeSimpleDelimited(rule, scalars: scalars, start: index)
                output.emit(index..<end, as: .string)
                index = end
                atLineStart = false
                continue
            }
            if atLineStart,
               (matches(Array("---".unicodeScalars), in: scalars, at: index) || matches(Array("...".unicodeScalars), in: scalars, at: index)) {
                output.emit(index..<(index + 3), as: .directive)
                index += 3
                atLineStart = false
                continue
            }
            if [0x26, 0x2A, 0x21].contains(scalars[index].value) {
                let start = index
                index += 1
                while index < scalars.count, isIdentifierContinue(scalars[index]) || [0x2D, 0x2E, 0x2F].contains(scalars[index].value) {
                    index += 1
                }
                output.emit(start..<index, as: .directive)
                atLineStart = false
                continue
            }
            if isASCIIDigit(scalars[index]) || scalars[index].value == 0x2D {
                let end = consumeNumber(from: index, in: scalars)
                if end > index + (scalars[index].value == 0x2D ? 1 : 0) {
                    output.emit(index..<end, as: .number)
                    index = end
                    atLineStart = false
                    continue
                }
            }
            if isIdentifierStart(scalars[index]) {
                let end = consumeYAMLWord(from: index)
                var lookahead = end
                while lookahead < scalars.count, isHorizontalWhitespace(scalars[lookahead]) { lookahead += 1 }
                let value = scalarString(scalars, range: index..<end).lowercased()
                let kind: SyntaxTokenKind?
                if lookahead < scalars.count, scalars[lookahead].value == 0x3A {
                    kind = .attribute
                } else if ["false", "null", "true", "yes", "no", "on", "off", "~"].contains(value) {
                    kind = .literal
                } else {
                    kind = nil
                }
                output.emit(index..<end, as: kind)
                index = end
                atLineStart = false
                continue
            }
            output.emit(index..<(index + 1))
            atLineStart = false
            index += 1
        }
        return output.rendered()
    }

    private func consumeYAMLWord(from start: Int) -> Int {
        var cursor = start + 1
        while cursor < scalars.count, isIdentifierContinue(scalars[cursor]) || scalars[cursor].value == 0x2D {
            cursor += 1
        }
        return cursor
    }
}

private struct MarkdownScanner {
    let scalars: [UnicodeScalar]
    private var index = 0
    private var atLineStart = true
    private var output: HighlightBuffer

    init(scalars: [UnicodeScalar]) {
        self.scalars = scalars
        output = HighlightBuffer(scalars: scalars)
    }

    mutating func render() -> String {
        let commentOpen = ScalarPattern("<!--")
        let commentClose = ScalarPattern("-->")

        while index < scalars.count {
            if matches(commentOpen.scalars, in: scalars, at: index) {
                var end = index + commentOpen.scalars.count
                while end < scalars.count, !matches(commentClose.scalars, in: scalars, at: end) { end += 1 }
                if end < scalars.count { end += commentClose.scalars.count }
                output.emit(index..<end, as: .comment)
                atLineStart = false
                index = end
                continue
            }
            if isLineBreak(scalars[index]) {
                output.emit(index..<(index + 1))
                index += 1
                atLineStart = true
                continue
            }
            if atLineStart {
                let markerEnd = consumeBlockMarker(from: index)
                if markerEnd > index {
                    output.emit(index..<markerEnd, as: .directive)
                    index = markerEnd
                    atLineStart = false
                    continue
                }
                // `consumeBlockMarker` already scans leading indentation. Do not
                // retry it for every space on the same line.
                atLineStart = false
            }
            if scalars[index].value == 0x60 {
                let tickCount = repeatedScalarCount(0x60, from: index)
                let start = index
                index += tickCount
                while index < scalars.count {
                    if scalars[index].value == 0x60 {
                        let observedTicks = repeatedScalarCount(0x60, from: index)
                        if observedTicks >= tickCount {
                            index += tickCount
                            break
                        }
                        // A too-short run cannot close this span. Skip it as a
                        // unit instead of rescanning each suffix of the run.
                        index += observedTicks
                    } else {
                        index += 1
                    }
                }
                output.emit(start..<index, as: .string)
                atLineStart = false
                continue
            }
            if [0x2A, 0x5F, 0x7E].contains(scalars[index].value) {
                let end = index + repeatedScalarCount(scalars[index].value, from: index)
                output.emit(index..<end, as: .directive)
                index = end
                atLineStart = false
                continue
            }
            if scalars[index].value == 0x5D, index + 1 < scalars.count, scalars[index + 1].value == 0x28 {
                output.emit(index..<(index + 2), as: .directive)
                index += 2
                let destinationStart = index
                var depth = 1
                while index < scalars.count, depth > 0, !isLineBreak(scalars[index]) {
                    if scalars[index].value == 0x5C {
                        index += min(2, scalars.count - index)
                    } else if scalars[index].value == 0x28 {
                        depth += 1
                        index += 1
                    } else if scalars[index].value == 0x29 {
                        depth -= 1
                        if depth == 0 { break }
                        index += 1
                    } else {
                        index += 1
                    }
                }
                output.emit(destinationStart..<index, as: .string)
                if index < scalars.count, scalars[index].value == 0x29 {
                    output.emit(index..<(index + 1), as: .directive)
                    index += 1
                }
                atLineStart = false
                continue
            }
            output.emit(index..<(index + 1))
            if !isHorizontalWhitespace(scalars[index]) { atLineStart = false }
            index += 1
        }
        return output.rendered()
    }

    private func consumeBlockMarker(from start: Int) -> Int {
        var cursor = start
        while cursor < scalars.count, isHorizontalWhitespace(scalars[cursor]) { cursor += 1 }
        let markerStart = cursor

        if cursor < scalars.count, scalars[cursor].value == 0x23 {
            while cursor < scalars.count, scalars[cursor].value == 0x23, cursor - markerStart < 6 { cursor += 1 }
            if cursor < scalars.count, isHorizontalWhitespace(scalars[cursor]) { return cursor }
        }
        cursor = markerStart
        if cursor < scalars.count, [0x3E, 0x2D, 0x2A, 0x2B].contains(scalars[cursor].value) {
            let next = cursor + 1
            if next < scalars.count, isHorizontalWhitespace(scalars[next]) { return next }
        }
        cursor = markerStart
        while cursor < scalars.count, isASCIIDigit(scalars[cursor]) { cursor += 1 }
        if cursor > markerStart, cursor + 1 < scalars.count,
           [0x2E, 0x29].contains(scalars[cursor].value), isHorizontalWhitespace(scalars[cursor + 1]) {
            return cursor + 1
        }
        cursor = markerStart
        if repeatedScalarCount(0x60, from: cursor) >= 3 || repeatedScalarCount(0x7E, from: cursor) >= 3 {
            while cursor < scalars.count, !isHorizontalWhitespace(scalars[cursor]), !isLineBreak(scalars[cursor]) { cursor += 1 }
            return cursor
        }
        return start
    }

    private func repeatedScalarCount(_ value: UInt32, from start: Int) -> Int {
        var cursor = start
        while cursor < scalars.count, scalars[cursor].value == value { cursor += 1 }
        return cursor - start
    }
}

private func consumeSimpleDelimited(_ rule: DelimitedRule, scalars: [UnicodeScalar], start: Int) -> Int {
    var cursor = start + rule.opening.scalars.count
    while cursor < scalars.count {
        if rule.supportsBackslashEscapes, scalars[cursor].value == 0x5C {
            cursor += min(2, scalars.count - cursor)
            continue
        }
        if !rule.allowsNewlines, isLineBreak(scalars[cursor]) { return cursor }
        if matches(rule.closing.scalars, in: scalars, at: cursor) {
            if rule.doubledClosingEscapes,
               matches(rule.closing.scalars, in: scalars, at: cursor + rule.closing.scalars.count) {
                cursor += rule.closing.scalars.count * 2
                continue
            }
            return cursor + rule.closing.scalars.count
        }
        cursor += 1
    }
    return cursor
}

private func matches(_ pattern: [UnicodeScalar], in scalars: [UnicodeScalar], at position: Int) -> Bool {
    guard !pattern.isEmpty, position >= 0, position <= scalars.count - pattern.count else { return false }
    for offset in pattern.indices where scalars[position + offset] != pattern[offset] {
        return false
    }
    return true
}

private func consumeIdentifier(from start: Int, in scalars: [UnicodeScalar]) -> Int {
    var cursor = start + 1
    while cursor < scalars.count, isIdentifierContinue(scalars[cursor]) { cursor += 1 }
    return cursor
}

private func consumeNumber(from start: Int, in scalars: [UnicodeScalar]) -> Int {
    var cursor = start
    var previousWasExponent = false
    if cursor < scalars.count, [0x2B, 0x2D].contains(scalars[cursor].value) { cursor += 1 }

    while cursor < scalars.count {
        let scalar = scalars[cursor]
        if isASCIIDigit(scalar) || [0x2E, 0x5F].contains(scalar.value) || isASCIIHexLetter(scalar) {
            previousWasExponent = [0x45, 0x50, 0x65, 0x70].contains(scalar.value)
            cursor += 1
        } else if [0x2B, 0x2D].contains(scalar.value), previousWasExponent {
            previousWasExponent = false
            cursor += 1
        } else {
            break
        }
    }
    return max(cursor, start + 1)
}

private func isIdentifierStart(_ scalar: UnicodeScalar) -> Bool {
    scalar.value == 0x5F || scalar.properties.isAlphabetic
}

private func isIdentifierContinue(_ scalar: UnicodeScalar) -> Bool {
    isIdentifierStart(scalar) || scalar.properties.numericType != nil || scalar.value == 0x24
}

private func isMarkupNameStart(_ scalar: UnicodeScalar) -> Bool {
    isIdentifierStart(scalar) || scalar.value == 0x3A
}

private func isMarkupNameContinue(_ scalar: UnicodeScalar) -> Bool {
    isIdentifierContinue(scalar) || [0x2D, 0x2E, 0x3A].contains(scalar.value)
}

private func isASCIIDigit(_ scalar: UnicodeScalar) -> Bool {
    (0x30...0x39).contains(scalar.value)
}

private func isASCIIHexLetter(_ scalar: UnicodeScalar) -> Bool {
    (0x41...0x46).contains(scalar.value) || (0x61...0x66).contains(scalar.value)
}

private func isLineBreak(_ scalar: UnicodeScalar) -> Bool {
    scalar.value == 0x0A || scalar.value == 0x0D
}

private func isHorizontalWhitespace(_ scalar: UnicodeScalar) -> Bool {
    scalar.value == 0x09 || scalar.value == 0x20
}

private func isCommentBoundary(before position: Int, in scalars: [UnicodeScalar]) -> Bool {
    position == 0 || isHorizontalWhitespace(scalars[position - 1])
}

private func scalarString(_ scalars: [UnicodeScalar], range: Range<Int>) -> String {
    var view = String.UnicodeScalarView()
    view.reserveCapacity(range.count)
    for index in range { view.append(scalars[index]) }
    return String(view)
}

private func words(_ value: String) -> Set<String> {
    Set(value.split(whereSeparator: { $0.isWhitespace }).map(String.init))
}

private func escapeHTML(_ source: String) -> String {
    escapeHTML(Array(source.unicodeScalars), range: 0..<source.unicodeScalars.count)
}

private func escapeHTML(_ scalars: [UnicodeScalar], range: Range<Int>) -> String {
    var result = ""
    result.reserveCapacity(range.count)
    for index in range {
        let scalar = scalars[index]
        switch scalar.value {
        case 0x26: result += "&amp;"
        case 0x3C: result += "&lt;"
        case 0x3E: result += "&gt;"
        case 0x22: result += "&quot;"
        case 0x27: result += "&#39;"
        case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F:
            result += "&#\(scalar.value);"
        default:
            result.unicodeScalars.append(scalar)
        }
    }
    return result
}
