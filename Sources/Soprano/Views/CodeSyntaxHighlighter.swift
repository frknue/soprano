import Foundation

// Syntax coloring for the file editor and the dashboard's fenced code. A
// single linear scan over UTF-16 code units, so ranges map directly onto
// NSRange and multi-line comments and strings come out right; no AppKit here,
// the caller maps token kinds to theme colors.

enum SyntaxTokenKind: Equatable, Sendable {
    case keyword
    case string
    case comment
    case number
    case type
    case function
    /// Decorators, annotations, preprocessor lines, shell variables, CSS at-rules.
    case attribute
    /// JSON and YAML keys, TOML/INI names, markup attributes.
    case key
    case tag
    case heading
    case inserted
    case deleted
}

struct SyntaxToken: Equatable, Sendable {
    let range: NSRange
    let kind: SyntaxTokenKind
}

/// How a language is scanned. Everything is optional so each entry in the
/// table below only states what sets it apart.
struct CodeLanguage: Equatable, Sendable {
    enum Style: Equatable, Sendable {
        /// Identifiers, keywords, strings, numbers, comments.
        case code
        /// `key: value` / `key = value` lines (YAML, TOML, INI, .env).
        case keyValue
        /// HTML, XML, SVG, plists.
        case markup
        case markdown
        case diff
    }

    let id: String
    var style: Style = .code
    var keywords: Set<String> = []
    var caseInsensitiveKeywords = false
    var lineComments: [String] = []
    var blockComment: (open: String, close: String)? = nil
    var quotes: Set<Character> = ["\"", "'"]
    /// Quotes whose strings may span lines (JavaScript template literals,
    /// Go raw strings).
    var multilineQuotes: Set<Character> = []
    /// Quotes inside which a backslash is just a character (Go raw strings,
    /// shell single quotes).
    var rawQuotes: Set<Character> = []
    /// `"""` (and `'''` where `'` is a quote) open multi-line strings.
    var tripleQuotes = false
    /// `'` delimits a character literal; an unclosed one is a Rust lifetime
    /// or a generic tick, not the start of a string.
    var singleQuoteIsCharacter = false
    var capitalizedTypes = true
    /// `@name` decorators and annotations.
    var atAttributes = false
    /// `$name` and `${…}` variables.
    var dollarVariables = false
    /// `#include` style lines.
    var preprocessor = false
    /// A string directly followed by `:` is an object key.
    var stringKeys = false

    static func == (lhs: CodeLanguage, rhs: CodeLanguage) -> Bool {
        lhs.id == rhs.id
    }
}

enum CodeSyntaxHighlighter {
    static func tokens(in text: String, language: CodeLanguage) -> [SyntaxToken] {
        var scanner = Scanner(units: Array(text.utf16), language: language)
        switch language.style {
        case .code, .keyValue:
            scanner.scanCode()
        case .markup:
            scanner.scanMarkup()
        case .markdown:
            scanner.scanMarkdown()
        case .diff:
            scanner.scanDiff()
        }
        return scanner.tokens
    }

    // MARK: - Scanner

    private struct Scanner {
        let units: [UInt16]
        let language: CodeLanguage
        var tokens: [SyntaxToken] = []
        private let lineComments: [[UInt16]]
        private let blockOpen: [UInt16]
        private let blockClose: [UInt16]
        private let quotes: Set<UInt16>
        private let multilineQuotes: Set<UInt16>
        private let rawQuotes: Set<UInt16>

        init(units: [UInt16], language: CodeLanguage) {
            self.units = units
            self.language = language
            lineComments = language.lineComments.map { Array($0.utf16) }
            blockOpen = language.blockComment.map { Array($0.open.utf16) } ?? []
            blockClose = language.blockComment.map { Array($0.close.utf16) } ?? []
            quotes = Set(language.quotes.compactMap { $0.utf16.first })
            multilineQuotes = Set(language.multilineQuotes.compactMap { $0.utf16.first })
            rawQuotes = Set(language.rawQuotes.compactMap { $0.utf16.first })
        }

        // MARK: Code

        mutating func scanCode() {
            var index = 0
            var atLineStart = true
            while index < units.count {
                let unit = units[index]
                if unit == Unit.newline {
                    atLineStart = true
                    index += 1
                    continue
                }
                if unit == Unit.space || unit == Unit.tab || unit == Unit.carriageReturn {
                    index += 1
                    continue
                }
                let lineStart = atLineStart
                atLineStart = false

                if language.style == .keyValue, lineStart, let next = scanKeyValueLineStart(at: index) {
                    index = next
                    continue
                }
                if !blockOpen.isEmpty, matches(blockOpen, at: index) {
                    let end = find(blockClose, from: index + blockOpen.count).map { $0 + blockClose.count }
                        ?? units.count
                    add(index, end, .comment)
                    index = end
                    continue
                }
                if let prefix = lineComments.first(where: { matches($0, at: index) }),
                   prefix != [Unit.hash] || isCommentHash(at: index)
                {
                    let end = endOfLine(from: index)
                    add(index, end, .comment)
                    index = end
                    continue
                }
                if language.preprocessor, lineStart, unit == Unit.hash {
                    let end = identifierEnd(from: index + 1)
                    add(index, end, .attribute)
                    index = max(end, index + 1)
                    continue
                }
                if quotes.contains(unit) || multilineQuotes.contains(unit) {
                    index = scanString(at: index)
                    continue
                }
                if isDigit(unit), index == 0 || !isIdentifierPart(units[index - 1]) {
                    var end = index + 1
                    while end < units.count {
                        let next = units[end]
                        if isIdentifierPart(next) {
                            end += 1
                        } else if next == Unit.dot, end + 1 < units.count, isDigit(units[end + 1]) {
                            end += 1
                        } else {
                            break
                        }
                    }
                    add(index, end, .number)
                    index = end
                    continue
                }
                if language.atAttributes, unit == Unit.at,
                   index + 1 < units.count, isIdentifierStart(units[index + 1])
                {
                    let end = identifierEnd(from: index + 1)
                    add(index, end, .attribute)
                    index = end
                    continue
                }
                if language.dollarVariables, unit == Unit.dollar, index + 1 < units.count {
                    let next = units[index + 1]
                    if next == Unit.openBrace {
                        let end = find([Unit.closeBrace], from: index + 2, stopAtNewline: true).map { $0 + 1 }
                            ?? endOfLine(from: index)
                        add(index, end, .attribute)
                        index = end
                        continue
                    }
                    if isIdentifierStart(next) || isDigit(next) {
                        let end = identifierEnd(from: index + 1)
                        add(index, end, .attribute)
                        index = end
                        continue
                    }
                }
                if isIdentifierStart(unit) {
                    let end = identifierEnd(from: index)
                    classifyIdentifier(index, end)
                    index = end
                    continue
                }
                index += 1
            }
        }

        private mutating func classifyIdentifier(_ start: Int, _ end: Int) {
            let word = String(utf16CodeUnits: Array(units[start..<end]), count: end - start)
            let keyword = language.caseInsensitiveKeywords ? word.lowercased() : word
            if language.keywords.contains(keyword) {
                add(start, end, .keyword)
                return
            }
            var next = end
            while next < units.count, units[next] == Unit.space || units[next] == Unit.tab {
                next += 1
            }
            if next < units.count, units[next] == Unit.openParen {
                add(start, end, .function)
            } else if language.capitalizedTypes, isUppercase(units[start]), end - start > 1 {
                add(start, end, .type)
            }
        }

        /// Scans the string starting at `start` and returns the index after it.
        private mutating func scanString(at start: Int) -> Int {
            let quote = units[start]
            if language.tripleQuotes, start + 2 < units.count,
               units[start + 1] == quote, units[start + 2] == quote
            {
                let close = [quote, quote, quote]
                let end = find(close, from: start + 3).map { $0 + 3 } ?? units.count
                add(start, end, .string)
                return end
            }

            if quote == Unit.singleQuote, language.singleQuoteIsCharacter {
                // One character or one escape; anything else (`'a` lifetimes,
                // `<'a>` generics, stray ticks) is not a literal.
                guard let end = characterLiteralEnd(from: start) else { return start + 1 }
                add(start, end, .string)
                return end
            }

            let multiline = multilineQuotes.contains(quote)
            let raw = rawQuotes.contains(quote)
            var index = start + 1
            while index < units.count {
                let unit = units[index]
                if unit == Unit.backslash, !raw {
                    index += 2
                    continue
                }
                if unit == Unit.newline, !multiline {
                    break
                }
                index += 1
                if unit == quote {
                    break
                }
            }
            index = min(index, units.count)
            var kind = SyntaxTokenKind.string
            if language.stringKeys {
                var next = index
                while next < units.count, units[next] == Unit.space || units[next] == Unit.tab {
                    next += 1
                }
                if next < units.count, units[next] == Unit.colon {
                    kind = .key
                }
            }
            add(start, index, kind)
            return index
        }

        /// The end of a character literal opening at `start` (`'x'`, `'é'`,
        /// `'\n'`, `'\u{1F600}'`), or nil when the tick opens none.
        private func characterLiteralEnd(from start: Int) -> Int? {
            let first = start + 1
            guard first < units.count, units[first] != Unit.newline, units[first] != Unit.singleQuote else {
                return nil
            }
            if units[first] == Unit.backslash {
                var index = first + 2
                while index < units.count, index - start <= 12, units[index] != Unit.newline {
                    if units[index] == Unit.singleQuote {
                        return index + 1
                    }
                    index += 1
                }
                return nil
            }
            let width = UTF16.isLeadSurrogate(units[first]) ? 2 : 1
            let close = first + width
            return close < units.count && units[close] == Unit.singleQuote ? close + 1 : nil
        }

        /// A YAML/TOML/INI line start: `[section]`, `- ` list markers and
        /// `key:` / `key =` names. Returns where scanning resumes, or nil when
        /// the line starts with something else.
        private mutating func scanKeyValueLineStart(at start: Int) -> Int? {
            var index = start
            if units[index] == Unit.openBracket {
                let end = find([Unit.closeBracket], from: index + 1, stopAtNewline: true).map { $0 + 1 }
                    ?? endOfLine(from: index)
                add(index, end, .heading)
                return end
            }
            if units[index] == Unit.dash, index + 1 < units.count, units[index + 1] == Unit.space {
                index += 2
                while index < units.count, units[index] == Unit.space {
                    index += 1
                }
            }
            guard index < units.count, !quotes.contains(units[index]) else {
                return index == start ? nil : index
            }
            var end = index
            while end < units.count {
                let unit = units[end]
                if unit == Unit.newline || unit == Unit.hash || unit == Unit.semicolon && index == end {
                    break
                }
                if unit == Unit.equals {
                    break
                }
                if unit == Unit.colon,
                   end + 1 >= units.count
                    || units[end + 1] == Unit.space
                    || units[end + 1] == Unit.newline
                    || units[end + 1] == Unit.carriageReturn
                {
                    break
                }
                end += 1
            }
            guard end < units.count, end > index,
                  units[end] == Unit.colon || units[end] == Unit.equals
            else {
                return index == start ? nil : index
            }
            var keyEnd = end
            while keyEnd > index, units[keyEnd - 1] == Unit.space || units[keyEnd - 1] == Unit.tab {
                keyEnd -= 1
            }
            add(index, keyEnd, .key)
            return end + 1
        }

        // MARK: Markup

        mutating func scanMarkup() {
            let commentOpen = Array("<!--".utf16)
            let commentClose = Array("-->".utf16)
            let cdataOpen = Array("<![CDATA[".utf16)
            let cdataClose = Array("]]>".utf16)
            var index = 0
            while index < units.count {
                if matches(commentOpen, at: index) {
                    let end = find(commentClose, from: index + 4).map { $0 + 3 } ?? units.count
                    add(index, end, .comment)
                    index = end
                    continue
                }
                if matches(cdataOpen, at: index) {
                    let end = find(cdataClose, from: index + 9).map { $0 + 3 } ?? units.count
                    add(index, end, .string)
                    index = end
                    continue
                }
                guard units[index] == Unit.lessThan, index + 1 < units.count else {
                    index += 1
                    continue
                }
                var nameStart = index + 1
                if [Unit.slash, Unit.question, Unit.bang].contains(units[nameStart]) {
                    nameStart += 1
                }
                guard nameStart < units.count, isIdentifierStart(units[nameStart]) else {
                    index += 1
                    continue
                }
                let nameEnd = markupNameEnd(from: nameStart)
                add(nameStart, nameEnd, .tag)
                index = scanMarkupAttributes(from: nameEnd)
            }
        }

        private mutating func scanMarkupAttributes(from start: Int) -> Int {
            var index = start
            while index < units.count {
                let unit = units[index]
                if unit == Unit.greaterThan {
                    return index + 1
                }
                if unit == Unit.lessThan {
                    return index
                }
                if unit == Unit.doubleQuote || unit == Unit.singleQuote {
                    let end = find([unit], from: index + 1).map { $0 + 1 } ?? units.count
                    add(index, end, .string)
                    index = end
                    continue
                }
                if isIdentifierStart(unit) {
                    let end = markupNameEnd(from: index)
                    add(index, end, .key)
                    index = end
                    continue
                }
                index += 1
            }
            return index
        }

        private func markupNameEnd(from start: Int) -> Int {
            var end = start
            while end < units.count {
                let unit = units[end]
                guard isIdentifierPart(unit) || unit == Unit.dash || unit == Unit.colon || unit == Unit.dot else {
                    break
                }
                end += 1
            }
            return end
        }

        // MARK: Markdown

        mutating func scanMarkdown() {
            let backtick = UInt16(UInt8(ascii: "`"))
            let tilde = UInt16(UInt8(ascii: "~"))
            var index = 0
            var fence: UInt16?
            while index < units.count {
                let lineEnd = endOfLine(from: index)
                var content = index
                while content < lineEnd, content - index < 4, units[content] == Unit.space {
                    content += 1
                }
                let fenceMarker = content + 2 < lineEnd
                    && (units[content] == backtick || units[content] == tilde)
                    && units[content + 1] == units[content]
                    && units[content + 2] == units[content]
                    ? units[content]
                    : nil

                if let open = fence {
                    add(index, lineEnd, .string)
                    if fenceMarker == open {
                        fence = nil
                    }
                } else if let fenceMarker {
                    fence = fenceMarker
                    add(index, lineEnd, .string)
                } else if content < lineEnd, units[content] == Unit.hash, isHeading(from: content, to: lineEnd) {
                    add(content, lineEnd, .heading)
                } else {
                    if content + 1 < lineEnd,
                       [Unit.dash, Unit.asterisk, Unit.plus].contains(units[content]),
                       units[content + 1] == Unit.space
                    {
                        add(content, content + 1, .keyword)
                    } else if content < lineEnd, units[content] == Unit.greaterThan {
                        add(content, content + 1, .keyword)
                    }
                    scanInlineCode(from: content, to: lineEnd, backtick: backtick)
                }
                index = lineEnd + 1
            }
        }

        private func isHeading(from start: Int, to end: Int) -> Bool {
            var index = start
            while index < end, units[index] == Unit.hash {
                index += 1
            }
            let level = index - start
            return level <= 6 && (index == end || units[index] == Unit.space)
        }

        private mutating func scanInlineCode(from start: Int, to end: Int, backtick: UInt16) {
            var index = start
            while index < end {
                guard units[index] == backtick else {
                    index += 1
                    continue
                }
                guard let close = find([backtick], from: index + 1, stopAtNewline: true), close < end else {
                    return
                }
                add(index, close + 1, .string)
                index = close + 1
            }
        }

        // MARK: Diff

        mutating func scanDiff() {
            var index = 0
            while index < units.count {
                let end = endOfLine(from: index)
                if matches(Array("+++".utf16), at: index) || matches(Array("---".utf16), at: index)
                    || matches(Array("diff ".utf16), at: index) || matches(Array("index ".utf16), at: index)
                {
                    add(index, end, .heading)
                } else if matches(Array("@@".utf16), at: index) {
                    add(index, end, .keyword)
                } else if index < units.count, units[index] == Unit.plus {
                    add(index, end, .inserted)
                } else if index < units.count, units[index] == Unit.dash {
                    add(index, end, .deleted)
                }
                index = end + 1
            }
        }

        // MARK: Helpers

        private mutating func add(_ start: Int, _ end: Int, _ kind: SyntaxTokenKind) {
            guard end > start else { return }
            tokens.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: kind))
        }

        private func matches(_ pattern: [UInt16], at index: Int) -> Bool {
            guard !pattern.isEmpty, index + pattern.count <= units.count else { return false }
            for offset in pattern.indices where units[index + offset] != pattern[offset] {
                return false
            }
            return true
        }

        private func find(_ pattern: [UInt16], from start: Int, stopAtNewline: Bool = false) -> Int? {
            var index = start
            while index + pattern.count <= units.count {
                if stopAtNewline, units[index] == Unit.newline {
                    return nil
                }
                if matches(pattern, at: index) {
                    return index
                }
                index += 1
            }
            return nil
        }

        private func endOfLine(from start: Int) -> Int {
            var index = start
            while index < units.count, units[index] != Unit.newline {
                index += 1
            }
            return index
        }

        private func identifierEnd(from start: Int) -> Int {
            var end = start
            while end < units.count, isIdentifierPart(units[end]) {
                end += 1
            }
            return end
        }

        /// `#` only starts a comment at the start of a word, so `$#`, `a#b`
        /// and URL fragments are left alone.
        private func isCommentHash(at index: Int) -> Bool {
            guard index > 0 else { return true }
            let previous = units[index - 1]
            return previous == Unit.space || previous == Unit.tab || previous == Unit.newline
                || previous == Unit.semicolon || previous == Unit.carriageReturn
        }

        private func isDigit(_ unit: UInt16) -> Bool {
            unit >= 48 && unit <= 57
        }

        private func isUppercase(_ unit: UInt16) -> Bool {
            unit >= 65 && unit <= 90
        }

        private func isIdentifierStart(_ unit: UInt16) -> Bool {
            (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == Unit.underscore
                || (unit == Unit.dollar && !language.dollarVariables)
        }

        private func isIdentifierPart(_ unit: UInt16) -> Bool {
            isIdentifierStart(unit) || isDigit(unit)
        }
    }

    private enum Unit {
        static let newline = UInt16(UInt8(ascii: "\n"))
        static let carriageReturn = UInt16(UInt8(ascii: "\r"))
        static let space = UInt16(UInt8(ascii: " "))
        static let tab = UInt16(UInt8(ascii: "\t"))
        static let hash = UInt16(UInt8(ascii: "#"))
        static let dollar = UInt16(UInt8(ascii: "$"))
        static let at = UInt16(UInt8(ascii: "@"))
        static let dot = UInt16(UInt8(ascii: "."))
        static let dash = UInt16(UInt8(ascii: "-"))
        static let plus = UInt16(UInt8(ascii: "+"))
        static let asterisk = UInt16(UInt8(ascii: "*"))
        static let slash = UInt16(UInt8(ascii: "/"))
        static let backslash = UInt16(UInt8(ascii: "\\"))
        static let colon = UInt16(UInt8(ascii: ":"))
        static let semicolon = UInt16(UInt8(ascii: ";"))
        static let equals = UInt16(UInt8(ascii: "="))
        static let question = UInt16(UInt8(ascii: "?"))
        static let bang = UInt16(UInt8(ascii: "!"))
        static let underscore = UInt16(UInt8(ascii: "_"))
        static let singleQuote = UInt16(UInt8(ascii: "'"))
        static let doubleQuote = UInt16(UInt8(ascii: "\""))
        static let lessThan = UInt16(UInt8(ascii: "<"))
        static let greaterThan = UInt16(UInt8(ascii: ">"))
        static let openParen = UInt16(UInt8(ascii: "("))
        static let openBrace = UInt16(UInt8(ascii: "{"))
        static let closeBrace = UInt16(UInt8(ascii: "}"))
        static let openBracket = UInt16(UInt8(ascii: "["))
        static let closeBracket = UInt16(UInt8(ascii: "]"))
    }
}

// MARK: - Languages

extension CodeLanguage {
    /// The language for a file, by exact name first and then extension; nil
    /// for plain text.
    static func forFile(named name: String) -> CodeLanguage? {
        let lowerName = name.lowercased()
        if let byName = byFileName[lowerName] {
            return byName
        }
        if lowerName.hasPrefix(".env") || lowerName.hasSuffix(".env") {
            return dotenv
        }
        if lowerName.hasPrefix("dockerfile") {
            return dockerfile
        }
        guard let dot = lowerName.lastIndex(of: "."), dot != lowerName.startIndex else { return nil }
        return byExtension[String(lowerName[lowerName.index(after: dot)...])]
    }

    /// The language a fenced code block names (```` ```ts ````), or nil.
    static func named(_ name: String) -> CodeLanguage? {
        let lowerName = name.lowercased()
        return byFenceName[lowerName] ?? byExtension[lowerName]
    }

    static let swift = CodeLanguage(
        id: "swift",
        keywords: [
            "Any", "Self", "actor", "any", "as", "associatedtype", "async", "await", "break",
            "case", "catch", "class", "continue", "convenience", "default", "defer", "deinit",
            "didSet", "do", "dynamic", "else", "enum", "extension", "fallthrough", "false",
            "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in",
            "indirect", "init", "inout", "internal", "is", "isolated", "lazy", "let",
            "mutating", "nil", "nonisolated", "nonmutating", "open", "operator", "optional",
            "override", "package", "private", "protocol", "public", "repeat", "required",
            "rethrows", "return", "self", "set", "some", "static", "struct", "subscript",
            "super", "switch", "throw", "throws", "true", "try", "typealias", "unowned",
            "var", "weak", "where", "while", "willSet",
        ],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        quotes: ["\""],
        tripleQuotes: true,
        atAttributes: true,
        preprocessor: true
    )

    static let javascript = CodeLanguage(
        id: "javascript",
        keywords: javascriptKeywords,
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        multilineQuotes: ["`"],
        atAttributes: true
    )

    static let typescript = CodeLanguage(
        id: "typescript",
        keywords: javascriptKeywords.union([
            "abstract", "as", "asserts", "declare", "infer", "is", "keyof", "namespace",
            "never", "override", "readonly", "satisfies", "unique", "unknown",
        ]),
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        multilineQuotes: ["`"],
        atAttributes: true
    )

    static let python = CodeLanguage(
        id: "python",
        keywords: [
            "False", "None", "True", "and", "as", "assert", "async", "await", "break", "case",
            "class", "continue", "def", "del", "elif", "else", "except", "finally", "for",
            "from", "global", "if", "import", "in", "is", "lambda", "match", "nonlocal",
            "not", "or", "pass", "raise", "return", "self", "try", "while", "with", "yield",
        ],
        lineComments: ["#"],
        tripleQuotes: true,
        atAttributes: true
    )

    static let ruby = CodeLanguage(
        id: "ruby",
        keywords: [
            "BEGIN", "END", "alias", "and", "begin", "break", "case", "class", "def",
            "defined?", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in",
            "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return",
            "self", "super", "then", "true", "undef", "unless", "until", "when", "while",
            "yield",
        ],
        lineComments: ["#"],
        multilineQuotes: ["\"", "'"],
        atAttributes: true
    )

    static let shell = CodeLanguage(
        id: "shell",
        keywords: [
            "case", "declare", "do", "done", "elif", "else", "esac", "export", "fi", "for",
            "function", "if", "in", "local", "readonly", "return", "select", "set", "source",
            "then", "time", "unset", "until", "while",
        ],
        lineComments: ["#"],
        multilineQuotes: ["\"", "'"],
        rawQuotes: ["'"],
        capitalizedTypes: false,
        dollarVariables: true
    )

    static let rust = CodeLanguage(
        id: "rust",
        keywords: [
            "Self", "as", "async", "await", "break", "const", "continue", "crate", "dyn",
            "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let",
            "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "static",
            "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while",
        ],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        multilineQuotes: ["\""],
        singleQuoteIsCharacter: true
    )

    static let go = CodeLanguage(
        id: "go",
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else",
            "fallthrough", "false", "for", "func", "go", "goto", "if", "import", "interface",
            "iota", "map", "nil", "package", "range", "return", "select", "struct", "switch",
            "true", "type", "var",
        ],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        multilineQuotes: ["`"],
        rawQuotes: ["`"],
        singleQuoteIsCharacter: true
    )

    static let c = CodeLanguage(
        id: "c",
        keywords: cKeywords,
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        singleQuoteIsCharacter: true,
        preprocessor: true
    )

    static let cpp = CodeLanguage(
        id: "cpp",
        keywords: cKeywords.union([
            "auto", "bool", "catch", "class", "constexpr", "delete", "explicit", "false",
            "friend", "mutable", "namespace", "new", "noexcept", "nullptr", "operator",
            "override", "private", "protected", "public", "template", "this", "throw",
            "true", "try", "typename", "using", "virtual",
            // Objective-C
            "id", "nil", "self", "super", "YES", "NO",
        ]),
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        singleQuoteIsCharacter: true,
        atAttributes: true,
        preprocessor: true
    )

    static let java = CodeLanguage(
        id: "java",
        keywords: jvmKeywords,
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        tripleQuotes: true,
        singleQuoteIsCharacter: true,
        atAttributes: true
    )

    static let kotlin = CodeLanguage(
        id: "kotlin",
        keywords: jvmKeywords.union([
            "as", "by", "companion", "data", "fun", "in", "init", "inline", "internal", "is",
            "lateinit", "object", "open", "override", "sealed", "suspend", "typealias",
            "val", "var", "when",
        ]),
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        tripleQuotes: true,
        singleQuoteIsCharacter: true,
        atAttributes: true,
        dollarVariables: true
    )

    static let csharp = CodeLanguage(
        id: "csharp",
        keywords: jvmKeywords.union([
            "as", "async", "await", "base", "bool", "decimal", "delegate", "event",
            "explicit", "get", "implicit", "in", "internal", "is", "namespace", "object",
            "operator", "out", "override", "params", "readonly", "ref", "sealed", "set",
            "string", "struct", "using", "var", "virtual",
        ]),
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        singleQuoteIsCharacter: true,
        preprocessor: true
    )

    static let php = CodeLanguage(
        id: "php",
        keywords: [
            "abstract", "array", "as", "break", "case", "catch", "class", "const", "continue",
            "default", "do", "echo", "else", "elseif", "extends", "false", "final", "finally",
            "fn", "for", "foreach", "function", "if", "implements", "interface", "match",
            "namespace", "new", "null", "private", "protected", "public", "readonly", "return",
            "static", "switch", "this", "throw", "trait", "true", "try", "use", "while",
        ],
        lineComments: ["//", "#"],
        blockComment: ("/*", "*/"),
        multilineQuotes: ["\"", "'"],
        dollarVariables: true
    )

    static let sql = CodeLanguage(
        id: "sql",
        keywords: [
            "add", "all", "alter", "and", "as", "asc", "begin", "between", "by", "case",
            "check", "column", "commit", "constraint", "create", "cross", "database",
            "default", "delete", "desc", "distinct", "drop", "else", "end", "exists",
            "false", "foreign", "from", "full", "group", "having", "if", "in", "index",
            "inner", "insert", "into", "is", "join", "key", "left", "like", "limit", "not",
            "null", "offset", "on", "or", "order", "outer", "primary", "references",
            "returning", "right", "rollback", "select", "set", "table", "then", "true",
            "union", "unique", "update", "values", "view", "when", "where", "with",
        ],
        caseInsensitiveKeywords: true,
        lineComments: ["--"],
        blockComment: ("/*", "*/"),
        capitalizedTypes: false
    )

    static let lua = CodeLanguage(
        id: "lua",
        keywords: [
            "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
            "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
            "true", "until", "while",
        ],
        lineComments: ["--"],
        blockComment: ("--[[", "]]")
    )

    static let css = CodeLanguage(
        id: "css",
        keywords: ["from", "to"],
        blockComment: ("/*", "*/"),
        capitalizedTypes: false,
        atAttributes: true
    )

    /// SCSS and Less add `//` comments and `$variables` to CSS; plain CSS has
    /// neither, and an unquoted `url(http://…)` must not start a comment.
    static let scss = CodeLanguage(
        id: "scss",
        keywords: ["from", "to"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        capitalizedTypes: false,
        atAttributes: true,
        dollarVariables: true
    )

    static let json = CodeLanguage(
        id: "json",
        keywords: ["false", "null", "true"],
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        capitalizedTypes: false,
        stringKeys: true
    )

    static let yaml = CodeLanguage(
        id: "yaml",
        style: .keyValue,
        keywords: ["false", "no", "null", "off", "on", "true", "yes"],
        lineComments: ["#"],
        capitalizedTypes: false
    )

    static let toml = CodeLanguage(
        id: "toml",
        style: .keyValue,
        keywords: ["false", "true"],
        lineComments: ["#"],
        tripleQuotes: true,
        capitalizedTypes: false
    )

    static let ini = CodeLanguage(
        id: "ini",
        style: .keyValue,
        keywords: ["false", "no", "off", "on", "true", "yes"],
        lineComments: ["#", ";"],
        capitalizedTypes: false
    )

    static let dotenv = CodeLanguage(
        id: "dotenv",
        style: .keyValue,
        lineComments: ["#"],
        capitalizedTypes: false,
        dollarVariables: true
    )

    static let dockerfile = CodeLanguage(
        id: "dockerfile",
        keywords: [
            "add", "arg", "as", "cmd", "copy", "entrypoint", "env", "expose", "from",
            "healthcheck", "label", "onbuild", "run", "shell", "stopsignal", "user",
            "volume", "workdir",
        ],
        caseInsensitiveKeywords: true,
        lineComments: ["#"],
        multilineQuotes: ["\"", "'"],
        rawQuotes: ["'"],
        capitalizedTypes: false,
        dollarVariables: true
    )

    static let makefile = CodeLanguage(
        id: "makefile",
        keywords: ["define", "else", "endef", "endif", "export", "ifdef", "ifeq", "ifndef", "ifneq", "include"],
        lineComments: ["#"],
        rawQuotes: ["'"],
        capitalizedTypes: false,
        dollarVariables: true
    )

    static let markup = CodeLanguage(id: "markup", style: .markup)
    static let markdown = CodeLanguage(id: "markdown", style: .markdown)
    static let diff = CodeLanguage(id: "diff", style: .diff)

    private static let javascriptKeywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue",
        "debugger", "default", "delete", "do", "else", "enum", "export", "extends", "false",
        "finally", "for", "from", "function", "get", "if", "implements", "import", "in",
        "instanceof", "interface", "let", "new", "null", "of", "private", "protected",
        "public", "return", "set", "static", "super", "switch", "this", "throw", "true",
        "try", "type", "typeof", "undefined", "var", "void", "while", "with", "yield",
    ]

    private static let cKeywords: Set<String> = [
        "break", "case", "char", "const", "continue", "default", "do", "double", "else",
        "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register",
        "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch",
        "typedef", "union", "unsigned", "void", "volatile", "while", "NULL",
    ]

    private static let jvmKeywords: Set<String> = [
        "abstract", "boolean", "break", "byte", "case", "catch", "char", "class", "const",
        "continue", "default", "do", "double", "else", "enum", "extends", "false", "final",
        "finally", "float", "for", "if", "implements", "import", "instanceof", "int",
        "interface", "long", "new", "null", "package", "private", "protected", "public",
        "record", "return", "short", "static", "super", "switch", "this", "throw", "throws",
        "true", "try", "var", "void", "while", "yield",
    ]

    private static let byExtension: [String: CodeLanguage] = {
        let groups: [(CodeLanguage, [String])] = [
            (.swift, ["swift"]),
            (.javascript, ["js", "jsx", "mjs", "cjs"]),
            (.typescript, ["ts", "tsx", "mts", "cts"]),
            (.python, ["py", "pyi", "pyw"]),
            (.ruby, ["rb", "rake", "gemspec", "ru"]),
            (.shell, ["sh", "bash", "zsh", "fish", "ksh", "command"]),
            (.rust, ["rs"]),
            (.go, ["go"]),
            (.c, ["c", "h"]),
            (.cpp, ["cc", "cpp", "cxx", "hh", "hpp", "hxx", "m", "mm"]),
            (.java, ["java", "groovy", "gradle", "scala", "dart"]),
            (.kotlin, ["kt", "kts"]),
            (.csharp, ["cs"]),
            (.php, ["php"]),
            (.sql, ["sql"]),
            (.lua, ["lua"]),
            (.css, ["css"]),
            (.scss, ["scss", "sass", "less"]),
            (.json, ["json", "jsonc", "json5", "webmanifest"]),
            (.yaml, ["yaml", "yml"]),
            (.toml, ["toml"]),
            (.ini, ["ini", "cfg", "conf", "properties", "editorconfig", "gitconfig"]),
            (.markup, ["html", "htm", "xhtml", "xml", "svg", "plist", "vue", "svelte", "xib", "storyboard"]),
            (.markdown, ["md", "markdown", "mdx"]),
            (.diff, ["diff", "patch"]),
            (.makefile, ["mk"]),
        ]
        var table: [String: CodeLanguage] = [:]
        for (language, extensions) in groups {
            for pathExtension in extensions {
                table[pathExtension] = language
            }
        }
        return table
    }()

    private static let byFileName: [String: CodeLanguage] = [
        "makefile": .makefile,
        "gnumakefile": .makefile,
        "gemfile": .ruby,
        "rakefile": .ruby,
        "podfile": .ruby,
        "brewfile": .ruby,
        ".zshrc": .shell,
        ".zprofile": .shell,
        ".bashrc": .shell,
        ".bash_profile": .shell,
        ".profile": .shell,
        ".envrc": .shell,
        ".gitignore": .dotenv,
        ".dockerignore": .dotenv,
        ".npmrc": .ini,
        ".gitconfig": .ini,
        ".editorconfig": .ini,
        "package.resolved": .json,
        ".babelrc": .json,
        ".prettierrc": .json,
    ]

    private static let byFenceName: [String: CodeLanguage] = [
        "javascript": .javascript,
        "typescript": .typescript,
        "python": .python,
        "ruby": .ruby,
        "shell": .shell,
        "bash": .shell,
        "console": .shell,
        "rust": .rust,
        "golang": .go,
        "c++": .cpp,
        "objc": .cpp,
        "objective-c": .cpp,
        "kotlin": .kotlin,
        "csharp": .csharp,
        "html": .markup,
        "xml": .markup,
        "dockerfile": .dockerfile,
        "makefile": .makefile,
    ]
}
