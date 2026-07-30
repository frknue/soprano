import AppKit

/// Adds lightweight, theme-aware structure to the dashboard's plain terminal text.
///
/// libghostty's public text-reading API returns characters and geometry, but not the
/// terminal cells' foreground colors or font attributes. This highlighter therefore
/// preserves the returned text exactly and derives presentation from durable textual
/// signals: prompts, Markdown structure, paths, diagnostics, diffs, and fenced code.
enum AgentOutputHighlighter {
    static func highlight(
        _ text: String,
        theme: AppTheme,
        font: NSFont = .monospacedSystemFont(ofSize: 11, weight: .regular)
    ) -> NSAttributedString {
        let output = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: theme.colors.textPrimary,
            ]
        )
        guard !text.isEmpty else { return output }

        let source = text as NSString
        var cursor = 0
        var fence: (delimiter: String, language: String)?
        var inDiff = false

        while cursor < source.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: cursor, length: 0)
            )

            let lineRange = NSRange(
                location: lineStart,
                length: contentsEnd - lineStart
            )
            let line = source.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let marker = fenceMarker(in: trimmed) {
                styleFenceMarker(
                    marker,
                    line: line,
                    lineRange: lineRange,
                    output: output,
                    theme: theme,
                    font: font
                )
                if fence?.delimiter == marker.delimiter {
                    fence = nil
                } else if fence == nil {
                    fence = (
                        delimiter: marker.delimiter,
                        language: normalizedLanguage(marker.language)
                    )
                }
                inDiff = false
            } else if let fence {
                styleCodeLine(
                    line,
                    lineRange: lineRange,
                    language: fence.language,
                    output: output,
                    theme: theme,
                    font: font
                )
            } else {
                if beginsDiff(trimmed) {
                    inDiff = true
                } else if inDiff, trimmed.isEmpty {
                    inDiff = false
                }

                styleTerminalLine(
                    line,
                    lineRange: lineRange,
                    inDiff: inDiff,
                    output: output,
                    theme: theme,
                    font: font
                )
            }

            cursor = max(lineEnd, cursor + 1)
        }

        return output
    }

    private static func styleTerminalLine(
        _ line: String,
        lineRange: NSRange,
        inDiff: Bool,
        output: NSMutableAttributedString,
        theme: AppTheme,
        font: NSFont
    ) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let semibold = NSFont.monospacedSystemFont(
            ofSize: font.pointSize,
            weight: .semibold
        )

        if matches(Patterns.divider, line: line) {
            output.addAttribute(
                .foregroundColor,
                value: theme.colors.textMuted,
                range: lineRange
            )
        } else if matches(Patterns.heading, line: line) {
            output.addAttributes(
                [
                    .font: semibold,
                    .foregroundColor: theme.colors.accentStrong,
                ],
                range: lineRange
            )
        } else if inDiff
            && (trimmed.hasPrefix("@@") || trimmed.hasPrefix("diff --git "))
        {
            output.addAttributes(
                [
                    .font: semibold,
                    .foregroundColor: theme.colors.cyan,
                ],
                range: lineRange
            )
            return
        } else if inDiff && trimmed.hasPrefix("+") {
            output.addAttribute(
                .foregroundColor,
                value: theme.colors.success,
                range: lineRange
            )
            return
        } else if inDiff && trimmed.hasPrefix("-") {
            output.addAttribute(
                .foregroundColor,
                value: theme.colors.danger,
                range: lineRange
            )
            return
        } else {
            apply(
                Patterns.prompt,
                to: line,
                lineRange: lineRange,
                output: output,
                attributes: [
                    .font: semibold,
                    .foregroundColor: theme.colors.accentStrong,
                ]
            )
            apply(
                Patterns.bullet,
                to: line,
                lineRange: lineRange,
                output: output,
                attributes: [
                    .font: semibold,
                    .foregroundColor: theme.colors.accent,
                ]
            )
            apply(
                Patterns.quote,
                to: line,
                lineRange: lineRange,
                output: output,
                attributes: [
                    .foregroundColor: theme.colors.textMuted,
                ]
            )
        }

        styleCommonTokens(
            line,
            lineRange: lineRange,
            output: output,
            theme: theme,
            font: font
        )
    }

    private static func styleCommonTokens(
        _ line: String,
        lineRange: NSRange,
        output: NSMutableAttributedString,
        theme: AppTheme,
        font: NSFont
    ) {
        let semibold = NSFont.monospacedSystemFont(
            ofSize: font.pointSize,
            weight: .semibold
        )

        apply(
            Patterns.path,
            to: line,
            lineRange: lineRange,
            output: output,
            attributes: [.foregroundColor: theme.colors.cyan]
        )
        apply(
            Patterns.file,
            to: line,
            lineRange: lineRange,
            output: output,
            attributes: [.foregroundColor: theme.colors.cyan]
        )
        apply(
            Patterns.url,
            to: line,
            lineRange: lineRange,
            output: output,
            attributes: [
                .foregroundColor: theme.colors.blue,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        )
        apply(
            Patterns.flag,
            to: line,
            lineRange: lineRange,
            output: output,
            attributes: [.foregroundColor: theme.colors.cyan]
        )
        apply(
            Patterns.error,
            to: line,
            lineRange: lineRange,
            output: output,
            attributes: [
                .font: semibold,
                .foregroundColor: theme.colors.danger,
            ]
        )
        apply(
            Patterns.warning,
            to: line,
            lineRange: lineRange,
            output: output,
            attributes: [
                .font: semibold,
                .foregroundColor: theme.colors.yellow,
            ]
        )
        apply(
            Patterns.success,
            to: line,
            lineRange: lineRange,
            output: output,
            attributes: [
                .font: semibold,
                .foregroundColor: theme.colors.success,
            ]
        )
        apply(
            Patterns.inlineCode,
            to: line,
            lineRange: lineRange,
            output: output,
            attributes: [
                .font: semibold,
                .foregroundColor: theme.colors.cyan,
                .backgroundColor: theme.colors.bgOverlay.withAlphaComponent(0.55),
            ]
        )
    }

    private static func styleFenceMarker(
        _ marker: (delimiter: String, language: String),
        line: String,
        lineRange: NSRange,
        output: NSMutableAttributedString,
        theme: AppTheme,
        font: NSFont
    ) {
        output.addAttributes(
            [
                .font: NSFont.monospacedSystemFont(
                    ofSize: font.pointSize,
                    weight: .semibold
                ),
                .foregroundColor: theme.colors.textMuted,
            ],
            range: lineRange
        )

        guard !marker.language.isEmpty else { return }
        let languageRange = (line as NSString).range(of: marker.language)
        guard languageRange.location != NSNotFound else { return }
        output.addAttribute(
            .foregroundColor,
            value: theme.colors.accent,
            range: offset(languageRange, by: lineRange.location)
        )
    }

    private static func styleCodeLine(
        _ line: String,
        lineRange: NSRange,
        language: String,
        output: NSMutableAttributedString,
        theme: AppTheme,
        font: NSFont
    ) {
        if language == "diff" {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("+") {
                output.addAttribute(
                    .foregroundColor,
                    value: theme.colors.success,
                    range: lineRange
                )
            } else if trimmed.hasPrefix("-") {
                output.addAttribute(
                    .foregroundColor,
                    value: theme.colors.danger,
                    range: lineRange
                )
            } else if trimmed.hasPrefix("@@") {
                output.addAttribute(
                    .foregroundColor,
                    value: theme.colors.cyan,
                    range: lineRange
                )
            }
            return
        }

        let semibold = NSFont.monospacedSystemFont(
            ofSize: font.pointSize,
            weight: .semibold
        )
        if let keywordExpression = Patterns.keywordExpressions[language]
            ?? Patterns.keywordExpressions["generic"]
        {
            apply(
                keywordExpression,
                to: line,
                lineRange: lineRange,
                output: output,
                attributes: [
                    .font: semibold,
                    .foregroundColor: theme.colors.accentStrong,
                ]
            )
        }

        apply(
            Patterns.functionCall,
            to: line,
            lineRange: lineRange,
            output: output,
            attributes: [.foregroundColor: theme.colors.blue]
        )
        apply(
            Patterns.number,
            to: line,
            lineRange: lineRange,
            output: output,
            attributes: [.foregroundColor: theme.colors.yellow]
        )
        apply(
            Patterns.stringLiteral,
            to: line,
            lineRange: lineRange,
            output: output,
            attributes: [.foregroundColor: theme.colors.success]
        )
        if language == "json" {
            apply(
                Patterns.jsonKey,
                to: line,
                lineRange: lineRange,
                output: output,
                attributes: [.foregroundColor: theme.colors.blue]
            )
        }

        for commentPattern in Patterns.commentExpressions(for: language) {
            apply(
                commentPattern,
                to: line,
                lineRange: lineRange,
                output: output,
                attributes: [.foregroundColor: theme.colors.textMuted]
            )
        }
    }

    private static func fenceMarker(
        in trimmedLine: String
    ) -> (delimiter: String, language: String)? {
        for delimiter in ["```", "~~~"] where trimmedLine.hasPrefix(delimiter) {
            let language = String(trimmedLine.dropFirst(delimiter.count))
                .trimmingCharacters(in: .whitespaces)
            return (delimiter, language)
        }
        return nil
    }

    private static func normalizedLanguage(_ language: String) -> String {
        switch language.lowercased() {
        case "js", "jsx", "javascript": return "javascript"
        case "ts", "tsx", "typescript": return "typescript"
        case "py", "python": return "python"
        case "rb", "ruby": return "ruby"
        case "sh", "bash", "zsh", "shell": return "shell"
        case "yml", "yaml": return "yaml"
        case "rs", "rust": return "rust"
        case "c++", "cpp", "cc": return "cpp"
        case "objective-c", "objc": return "objc"
        case "patch", "diff": return "diff"
        default: return language.lowercased()
        }
    }

    private static func keywords(for language: String) -> [String] {
        switch language {
        case "swift":
            return [
                "actor", "as", "async", "await", "break", "case", "catch",
                "class", "continue", "default", "defer", "do", "else", "enum",
                "extension", "false", "fileprivate", "for", "func", "guard", "if",
                "import", "in", "init", "internal", "is", "let", "nil", "open",
                "operator", "private", "protocol", "public", "repeat", "rethrows",
                "return", "self", "static", "struct", "subscript", "super", "switch",
                "throw", "throws", "true", "try", "typealias", "var", "where", "while",
            ]
        case "javascript", "typescript":
            return [
                "async", "await", "break", "case", "catch", "class", "const",
                "continue", "default", "delete", "do", "else", "enum", "export",
                "extends", "false", "finally", "for", "function", "if", "implements",
                "import", "in", "instanceof", "interface", "let", "new", "null",
                "private", "protected", "public", "readonly", "return", "static",
                "super", "switch", "this", "throw", "true", "try", "type", "typeof",
                "undefined", "var", "void", "while", "yield",
            ]
        case "python":
            return [
                "False", "None", "True", "and", "as", "assert", "async", "await",
                "break", "class", "continue", "def", "del", "elif", "else", "except",
                "finally", "for", "from", "global", "if", "import", "in", "is",
                "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try",
                "while", "with", "yield",
            ]
        case "shell":
            return [
                "case", "do", "done", "elif", "else", "esac", "export", "fi",
                "for", "function", "if", "in", "local", "readonly", "return",
                "set", "then", "unset", "while",
            ]
        case "ruby":
            return [
                "begin", "break", "case", "class", "def", "do", "else", "elsif",
                "end", "ensure", "false", "for", "if", "in", "module", "next",
                "nil", "redo", "rescue", "retry", "return", "self", "super", "then",
                "true", "unless", "until", "when", "while", "yield",
            ]
        case "json", "yaml":
            return ["false", "null", "true"]
        case "rust":
            return [
                "as", "async", "await", "break", "const", "continue", "crate",
                "dyn", "else", "enum", "extern", "false", "fn", "for", "if",
                "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub",
                "ref", "return", "self", "static", "struct", "super", "trait", "true",
                "type", "unsafe", "use", "where", "while",
            ]
        default:
            return ["false", "nil", "null", "true"]
        }
    }

    private enum Patterns {
        static let divider = expression(#"^\s*[-─━═_]{4,}\s*$"#)
        static let heading = expression(#"^\s*#{1,6}\s+"#)
        static let prompt = expression(#"^\s*(?:›|❯|\$)\s+"#)
        static let bullet = expression(#"^\s*(?:[•◦▪▸]|[-*+]|\d+[.)])\s+"#)
        static let quote = expression(#"^\s*[>│]\s?"#)
        static let path = expression(
            #"(?<![A-Za-z0-9_])(?:~|\.{1,2}|/)?(?:[A-Za-z0-9_.@+-]+/)+[A-Za-z0-9_.@+~-]+(?::\d+(?::\d+)?)?"#
        )
        static let file = expression(
            #"\b[A-Za-z0-9_-]+\.(?:swift|m|mm|c|h|cpp|cc|hpp|js|jsx|ts|tsx|py|rb|rs|go|java|kt|sh|bash|zsh|fish|json|jsonc|yaml|yml|toml|md|markdown|html|css|scss|sql|plist)(?::\d+(?::\d+)?)?\b"#,
            options: [.caseInsensitive]
        )
        static let url = expression(
            #"\bhttps?://[^\s<>()]+"#,
            options: [.caseInsensitive]
        )
        static let flag = expression(
            #"(?<![A-Za-z0-9_])--?[A-Za-z][A-Za-z0-9-]*"#
        )
        static let error = expression(
            #"\b(?:error|errors|failed|failure|fatal|denied|panic)\b"#,
            options: [.caseInsensitive]
        )
        static let warning = expression(
            #"\b(?:warning|warnings|warn|waiting|attention)\b"#,
            options: [.caseInsensitive]
        )
        static let success = expression(
            #"\b(?:passed|pass|success|succeeded|complete|completed|done|ready|green)\b"#,
            options: [.caseInsensitive]
        )
        static let inlineCode = expression(#"`[^`\n]+`"#)
        static let functionCall = expression(
            #"\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()"#
        )
        static let number = expression(
            #"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#
        )
        static let stringLiteral = expression(
            #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#
        )
        static let jsonKey = expression(
            #""(?:\\.|[^"\\])*"(?=\s*:)"#
        )
        static let hashComment = expression(#"#.*$"#)
        static let sqlComment = expression(#"--.*$"#)
        static let slashComment = expression(#"//.*$"#)
        static let blockComment = expression(#"/\*.*?\*/"#)

        static let keywordExpressions: [String: NSRegularExpression] = {
            let languages = [
                "swift", "javascript", "python", "shell", "ruby",
                "json", "yaml", "rust", "generic",
            ]
            var output: [String: NSRegularExpression] = [:]
            for language in languages {
                let alternatives = AgentOutputHighlighter.keywords(for: language)
                    .map { NSRegularExpression.escapedPattern(for: $0) }
                    .joined(separator: "|")
                output[language] = expression("\\b(?:\(alternatives))\\b")
            }
            output["typescript"] = output["javascript"]
            return output
        }()

        static func commentExpressions(
            for language: String
        ) -> [NSRegularExpression] {
            switch language {
            case "python", "ruby", "shell", "yaml", "toml":
                return [hashComment]
            case "sql":
                return [sqlComment]
            case "json":
                return []
            default:
                return [slashComment, blockComment]
            }
        }

        private static func expression(
            _ pattern: String,
            options: NSRegularExpression.Options = []
        ) -> NSRegularExpression {
            // These patterns are compile-time constants covered by focused tests.
            try! NSRegularExpression(pattern: pattern, options: options)
        }
    }

    private static func beginsDiff(_ trimmedLine: String) -> Bool {
        trimmedLine.hasPrefix("diff --git ")
            || trimmedLine.hasPrefix("--- a/")
            || trimmedLine.hasPrefix("+++ b/")
            || trimmedLine.hasPrefix("@@")
    }

    private static func matches(
        _ expression: NSRegularExpression,
        line: String
    ) -> Bool {
        return expression.firstMatch(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length)
        ) != nil
    }

    private static func apply(
        _ expression: NSRegularExpression,
        to line: String,
        lineRange: NSRange,
        output: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let localRange = NSRange(location: 0, length: (line as NSString).length)
        for match in expression.matches(in: line, range: localRange) {
            output.addAttributes(
                attributes,
                range: offset(match.range, by: lineRange.location)
            )
        }
    }

    private static func offset(_ range: NSRange, by location: Int) -> NSRange {
        NSRange(location: range.location + location, length: range.length)
    }
}
