import AppKit
import Testing
@testable import SopranoAgents

struct MarkdownDocumentTests {
    @Test func fencedCodeKeepsItsLanguageAndLosesTheClosingNewline() {
        let blocks = MarkdownDocument.parse("```swift\nlet a = 1\n```\n\n```\nplain\n```")
        #expect(blocks == [.code(language: "swift", code: "let a = 1"), .code(language: nil, code: "plain")])
    }

    @Test func taskListItemsCarryTheirCheckboxAndOrderedListsTheirStart() {
        let tasks = MarkdownDocument.parse("- [x] done\n- [ ] open\n- plain")
        guard case let .list(ordered, _, items) = tasks.first else {
            Issue.record("expected a list, got \(tasks)")
            return
        }
        #expect(!ordered)
        #expect(items.map(\.checkbox) == [true, false, nil])
        #expect(items[0].blocks == [.paragraph([.text("done")])])

        let numbered = MarkdownDocument.parse("3. three\n4. four")
        guard case let .list(isOrdered, start, numberedItems) = numbered.first else {
            Issue.record("expected an ordered list, got \(numbered)")
            return
        }
        #expect(isOrdered)
        #expect(start == 3)
        #expect(numberedItems.count == 2)
    }

    @Test func nestedListsStayInsideTheirItem() {
        let blocks = MarkdownDocument.parse("- outer\n  - inner")
        guard case let .list(_, _, items) = blocks.first, items.count == 1 else {
            Issue.record("expected one outer item, got \(blocks)")
            return
        }
        #expect(items[0].blocks.count == 2)
        if case let .list(_, _, inner) = items[0].blocks[1] {
            #expect(inner.first?.blocks == [.paragraph([.text("inner")])])
        } else {
            Issue.record("expected a nested list, got \(items[0].blocks)")
        }
    }

    @Test func tablesKeepHeaderRowsAndColumnAlignment() {
        let blocks = MarkdownDocument.parse("| Test | Result |\n|:---|---:|\n| `a` | passed |\n| b | failed |")
        guard case let .table(table) = blocks.first else {
            Issue.record("expected a table, got \(blocks)")
            return
        }
        #expect(table.alignments == [.left, .right])
        #expect(table.header == [[.text("Test")], [.text("Result")]])
        #expect(table.rows == [[[.code("a")], [.text("passed")]], [[.text("b")], [.text("failed")]]])
    }

    @Test func inlineMarkupNestsAndLinksKeepTheirDestination() {
        let blocks = MarkdownDocument.parse("Use **bold _and_ more**, ~~old~~, `code` and [docs](https://example.com).")
        #expect(blocks == [.paragraph([
            .text("Use "),
            .strong([.text("bold "), .emphasis([.text("and")]), .text(" more")]),
            .text(", "),
            .strikethrough([.text("old")]),
            .text(", "),
            .code("code"),
            .text(" and "),
            .link(destination: "https://example.com", [.text("docs")]),
            .text("."),
        ])])
    }

    @Test func userMessagesKeepTheirLineBreaks() {
        #expect(MarkdownDocument.parse("one\ntwo") == [.paragraph([.text("one"), .softBreak, .text("two")])])
        #expect(MarkdownDocument.parse("one\ntwo", lineBreaks: true) == [.paragraph([.text("one"), .lineBreak, .text("two")])])
    }

    @Test func rawHTMLStaysVisibleAsSource() {
        #expect(MarkdownDocument.parse("<div>hi</div>") == [.html("<div>hi</div>")])
    }

    @Test func plainTextReadsLikeTheRenderedLine() {
        let inlines: [MarkdownInline] = [.text("a "), .strong([.text("b")]), .softBreak, .code("c"), .image(source: "x.png", alt: "pic")]
        #expect(MarkdownDocument.plainText(of: inlines) == "a b cpic")
    }
}
