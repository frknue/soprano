import AppKit
import Testing
@testable import Soprano

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
        #expect(color(of: "❯", in: highlighted)?.isEqual(theme.colors.accentStrong) == true)
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

    @Test func fencedSwiftCodeHighlightsKeywordsLiteralsCallsAndComments() throws {
        let theme = ThemeManager(themeId: "catppuccin-mocha").currentTheme
        let source = """
        ```swift
        let count = 42
        print("ready")
        // keep the exact text
        ```
        """

        let highlighted = AgentOutputHighlighter.highlight(source, theme: theme)

        #expect(highlighted.string == source)
        #expect(color(of: "swift", in: highlighted)?.isEqual(theme.colors.accent) == true)
        #expect(color(of: "let", in: highlighted)?.isEqual(theme.colors.accentStrong) == true)
        #expect(color(of: "42", in: highlighted)?.isEqual(theme.colors.yellow) == true)
        #expect(color(of: "print", in: highlighted)?.isEqual(theme.colors.blue) == true)
        #expect(color(of: "\"ready\"", in: highlighted)?.isEqual(theme.colors.success) == true)
        #expect(color(of: "// keep", in: highlighted)?.isEqual(theme.colors.textMuted) == true)
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

        #expect(color(of: "- This", in: highlighted)?.isEqual(theme.colors.accent) == true)
        #expect(color(of: "-let old", in: highlighted)?.isEqual(theme.colors.danger) == true)
        #expect(color(of: "+let new", in: highlighted)?.isEqual(theme.colors.success) == true)
        #expect(color(of: "@@", in: highlighted)?.isEqual(theme.colors.cyan) == true)
    }

    private func color(
        of text: String,
        in highlighted: NSAttributedString
    ) -> NSColor? {
        let range = (highlighted.string as NSString).range(of: text)
        guard range.location != NSNotFound else { return nil }
        return highlighted.attribute(
            .foregroundColor,
            at: range.location,
            effectiveRange: nil
        ) as? NSColor
    }
}
