import AppKit
import Testing
@testable import Soprano

@MainActor
struct AgentOutputHighlighterTests {
    @Test func semanticHighlightingPreservesEveryTerminalCharacter() throws {
        let theme = ThemeManager(themeId: "gruvbox-dark").currentTheme
        let source = """
        ❯ Run swift test --filter AgentDashboard
        • Updated Sources/Soprano/Views/AgentDashboardViewController.swift:842
        warning: waiting for input
        error: build failed
        All 301 tests passed
        """

        let highlighted = AgentOutputHighlighter.highlight(source, theme: theme)

        #expect(highlighted.string == source)
        #expect(color(of: "❯", in: highlighted)?.isEqual(theme.colors.textPrimary) == true)
        #expect(color(of: "•", in: highlighted)?.isEqual(theme.colors.textMuted) == true)
        #expect(
            color(
                of: "Sources/Soprano/Views/AgentDashboardViewController.swift:842",
                in: highlighted
            )?.isEqual(theme.colors.cyan) == true
        )
        #expect(color(of: "--filter", in: highlighted)?.isEqual(theme.colors.cyan) == true)
        #expect(color(of: "warning", in: highlighted)?.isEqual(theme.colors.yellow) == true)
        #expect(color(of: "error", in: highlighted)?.isEqual(theme.colors.danger) == true)
        #expect(color(of: "passed", in: highlighted)?.isEqual(theme.colors.success) == true)
    }

    @Test func fencedSwiftCodeUsesTheSyntaxColorsAndBoldInkKeywords() throws {
        let theme = ThemeManager(themeId: "catppuccin-mocha").currentTheme
        let colors = theme.colors
        let source = """
        ```swift
        @MainActor let count: Int = 42
        print("ready")
        // keep the exact text
        ```
        """

        let highlighted = AgentOutputHighlighter.highlight(source, theme: theme)

        #expect(highlighted.string == source)
        #expect(color(of: "swift", in: highlighted)?.isEqual(colors.textPrimary) == true)
        #expect(color(of: "let", in: highlighted)?.isEqual(colors.syntaxKeyword) == true)
        let keywordFont = try #require(font(of: "let", in: highlighted))
        #expect(NSFontManager.shared.traits(of: keywordFont).contains(.boldFontMask))
        #expect(color(of: "@MainActor", in: highlighted)?.isEqual(colors.syntaxAttribute) == true)
        #expect(color(of: "Int", in: highlighted)?.isEqual(colors.syntaxType) == true)
        #expect(color(of: "42", in: highlighted)?.isEqual(colors.syntaxNumber) == true)
        #expect(color(of: "print", in: highlighted)?.isEqual(colors.syntaxFunction) == true)
        #expect(color(of: "\"ready\"", in: highlighted)?.isEqual(colors.syntaxString) == true)
        #expect(color(of: "// keep", in: highlighted)?.isEqual(colors.syntaxComment) == true)
    }

    @Test func noTerminalTextIsDrawnInTheAccent() throws {
        let theme = ThemeManager(themeId: "folio-paper").currentTheme
        let source = """
        # Summary
        ❯ swift build
        - first point
        ```swift
        struct App { func run() {} }
        ```
        """

        let highlighted = AgentOutputHighlighter.highlight(source, theme: theme)

        let accents = [theme.colors.accent, theme.colors.accentStrong]
        highlighted.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: highlighted.length)
        ) { value, _, _ in
            let color = value as? NSColor
            #expect(!accents.contains { $0.isEqual(color) })
        }
    }

    @Test func unifiedDiffColorsOnlyThePatchInsteadOfMarkdownBullets() throws {
        let theme = ThemeManager(themeId: "gruvbox-dark").currentTheme
        let source = """
        - This is an ordinary agent bullet

        diff --git a/App.swift b/App.swift
        --- a/App.swift
        +++ b/App.swift
        @@ -1,2 +1,2 @@
        -let oldValue = false
        +let newValue = true
        """

        let highlighted = AgentOutputHighlighter.highlight(source, theme: theme)

        #expect(color(of: "- This", in: highlighted)?.isEqual(theme.colors.textMuted) == true)
        #expect(color(of: "-let old", in: highlighted)?.isEqual(theme.colors.danger) == true)
        #expect(color(of: "+let new", in: highlighted)?.isEqual(theme.colors.success) == true)
        #expect(color(of: "@@", in: highlighted)?.isEqual(theme.colors.cyan) == true)
    }

    private func color(
        of text: String,
        in highlighted: NSAttributedString
    ) -> NSColor? {
        attribute(.foregroundColor, of: text, in: highlighted) as? NSColor
    }

    private func font(of text: String, in highlighted: NSAttributedString) -> NSFont? {
        attribute(.font, of: text, in: highlighted) as? NSFont
    }

    private func attribute(
        _ key: NSAttributedString.Key,
        of text: String,
        in highlighted: NSAttributedString
    ) -> Any? {
        let range = (highlighted.string as NSString).range(of: text)
        guard range.location != NSNotFound else { return nil }
        return highlighted.attribute(key, at: range.location, effectiveRange: nil)
    }
}
