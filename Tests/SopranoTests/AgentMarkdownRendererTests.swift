import AppKit
import Testing
@testable import Soprano

@MainActor
struct AgentMarkdownRendererTests {
    private let colors = ThemeManager(themeId: "gruvbox-dark").currentTheme.colors

    @Test func emphasisMarkersDisappearAndTheirTextIsBoldObliqueOrStruckThrough() {
        let rendered = AgentMarkdownRenderer.render(
            #"Make it **loud**, *slanted* and ~~gone~~."#,
            colors: colors
        )

        #expect(rendered.string == "Make it loud, slanted and gone.")
        let bold = font(of: "loud", in: rendered)
        #expect(bold.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
        let plain = font(of: "Make", in: rendered)
        #expect(plain.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == false)
        #expect((attribute(.obliqueness, of: "slanted", in: rendered) as? NSNumber)?.doubleValue == 0.15)
        #expect(attribute(.obliqueness, of: "Make", in: rendered) == nil)
        #expect(attribute(.strikethroughStyle, of: "gone", in: rendered) as? Int == NSUnderlineStyle.single.rawValue)
    }

    @Test func inlineCodeKeepsItsTextInTheStrongAccentOnARaisedBackground() {
        let rendered = AgentMarkdownRenderer.render(#"Run `swift test` now."#, colors: colors)

        #expect(rendered.string == "Run swift test now.")
        #expect(color(of: "swift test", in: rendered)?.isEqual(colors.accentStrong) == true)
        #expect((attribute(.backgroundColor, of: "swift test", in: rendered) as? NSColor)?.isEqual(colors.bgRaised) == true)
        #expect(color(of: "Run", in: rendered)?.isEqual(colors.textPrimary) == true)
        #expect(attribute(.backgroundColor, of: "Run", in: rendered) == nil)
    }

    @Test func fencedSwiftCodeKeepsItsExactTextInsideOneRaisedBlockAndColorsKeywords() {
        let markdown = #"""
        Before

        ```swift
        let answer = 42
          return answer
        ```

        After
        """#

        let rendered = AgentMarkdownRenderer.render(markdown, colors: colors)

        #expect(rendered.string == "Before\nlet answer = 42\n  return answer\nAfter")
        #expect(color(of: "let", in: rendered)?.isEqual(colors.accentStrong) == true)
        #expect(color(of: "answer", in: rendered)?.isEqual(colors.accentStrong) == false)
        let firstBlocks = paragraphStyle(of: "let answer", in: rendered)?.textBlocks ?? []
        let secondBlocks = paragraphStyle(of: "  return", in: rendered)?.textBlocks ?? []
        #expect(firstBlocks.count == 1)
        #expect(firstBlocks.first === secondBlocks.first)
        #expect(firstBlocks.first?.backgroundColor?.isEqual(colors.bgRaised) == true)
        #expect(paragraphStyle(of: "After", in: rendered)?.textBlocks.isEmpty == true)
    }

    @Test func codeInAnUnknownLanguageStaysPlainPrimaryText() {
        let rendered = AgentMarkdownRenderer.render("```nolang\nlet x = 1\n```", colors: colors)

        #expect(rendered.string == "let x = 1")
        #expect(color(of: "let", in: rendered)?.isEqual(colors.textPrimary) == true)
    }

    @Test func listsShowBulletsNumbersAndCheckboxesWithAHangingIndent() {
        let markdown = #"""
        - first
        - second
          - nested

        3. three
        4. four

        - [ ] open
        - [x] done
        """#

        let rendered = AgentMarkdownRenderer.render(markdown, colors: colors)

        #expect(rendered.string == "• first\n• second\n• nested\n3. three\n4. four\n☐ open\n☑ done")
        let item = paragraphStyle(of: "• first", in: rendered)
        let nested = paragraphStyle(of: "• nested", in: rendered)
        #expect(item.map { $0.headIndent > $0.firstLineHeadIndent } == true)
        #expect(nested.map { $0.firstLineHeadIndent >= (item?.headIndent ?? .infinity) } == true)
    }

    @Test func linksCarryTheirURLAndAreBlueAndUnderlined() {
        let rendered = AgentMarkdownRenderer.render(
            #"See [the docs](https://example.com/docs) for more."#,
            colors: colors
        )

        #expect(rendered.string == "See the docs for more.")
        #expect(attribute(.link, of: "the docs", in: rendered) as? URL == URL(string: "https://example.com/docs"))
        #expect(color(of: "the docs", in: rendered)?.isEqual(colors.blue) == true)
        #expect(attribute(.underlineStyle, of: "the docs", in: rendered) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(attribute(.link, of: "See", in: rendered) == nil)
    }

    @Test func rawHTMLIsShownLiterallyInsteadOfInterpreted() {
        let markdown = #"""
        <script>alert("x")</script>

        Inline <b>tag</b> here.
        """#

        let rendered = AgentMarkdownRenderer.render(markdown, colors: colors)

        #expect(rendered.string == #"<script>alert("x")</script>"# + "\nInline <b>tag</b> here.")
    }

    @Test func tableColumnsAlignBehindABoldHeaderAndRule() {
        let markdown = #"""
        | Name | Count |
        |------|------:|
        | a | 1 |
        | longer | 200 |
        """#

        let rendered = AgentMarkdownRenderer.render(markdown, colors: colors)
        let lines = rendered.string.components(separatedBy: "\n")

        #expect(lines == [
            "Name   │ Count",
            "───────┼──────",
            "a      │     1",
            "longer │   200",
        ])
        let header = font(of: "Name", in: rendered)
        #expect(header.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
        let cell = font(of: "longer", in: rendered)
        #expect(cell.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == false)
    }

    @Test func quotesBreaksAndRulesReadAsPlainText() {
        let markdown = "> quoted\n\nsoft\nwrap and hard  \nbreak\n\n---\n\n![a chart](x.png)"

        let rendered = AgentMarkdownRenderer.render(markdown, colors: colors)
        let lines = rendered.string.components(separatedBy: "\n")

        #expect(lines.count == 5)
        #expect(lines[0] == "▎ quoted")
        #expect(color(of: "quoted", in: rendered)?.isEqual(colors.textMuted) == true)
        #expect(lines[1] == "soft wrap and hard")
        #expect(lines[2] == "break")
        #expect(lines[3].allSatisfy { $0 == "─" })
        #expect(lines[4] == "[image: a chart]")
    }

    @Test func renderedTextNeverEndsWithANewline() {
        for markdown in ["Just text\n", "# Title\n\n", "- item\n", "```\ncode\n```\n", "> quote\n"] {
            let rendered = AgentMarkdownRenderer.render(markdown, colors: colors)
            #expect(!rendered.string.hasSuffix("\n"))
            #expect(!rendered.string.isEmpty)
        }
        #expect(AgentMarkdownRenderer.render("", colors: colors).length == 0)
    }

    private func range(of text: String, in rendered: NSAttributedString) -> NSRange? {
        let range = (rendered.string as NSString).range(of: text)
        return range.location == NSNotFound ? nil : range
    }

    private func attribute(_ key: NSAttributedString.Key, of text: String, in rendered: NSAttributedString) -> Any? {
        guard let range = range(of: text, in: rendered) else { return nil }
        return rendered.attribute(key, at: range.location, effectiveRange: nil)
    }

    private func color(of text: String, in rendered: NSAttributedString) -> NSColor? {
        attribute(.foregroundColor, of: text, in: rendered) as? NSColor
    }

    private func font(of text: String, in rendered: NSAttributedString) -> NSFont? {
        attribute(.font, of: text, in: rendered) as? NSFont
    }

    private func paragraphStyle(of text: String, in rendered: NSAttributedString) -> NSParagraphStyle? {
        attribute(.paragraphStyle, of: text, in: rendered) as? NSParagraphStyle
    }
}
