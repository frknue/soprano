import AppKit
import Testing
@testable import Soprano

@MainActor
struct AgentTimelineRendererTests {
    private let colors = ThemeManager(themeId: "folio-paper").currentTheme.colors

    @Test func thePromptCardIsInkOnThePanelInARoundedBoxWithoutAccent() throws {
        let timeline = AgentTimeline(entries: [
            AgentTranscriptEntry(items: [AgentTimelineItem(id: "p1", kind: .prompt("Fix the build"))]),
        ])

        let output = AgentTimelineRenderer(colors: colors).render(timeline, detailed: false, isAgentActive: true)

        #expect(output.turnStarts == [0])
        #expect(color(of: "You", in: output.text)?.isEqual(colors.textPrimary) == true)
        #expect(color(of: "Fix the build", in: output.text)?.isEqual(colors.textPrimary) == true)
        let block = try #require(paragraphStyle(of: "Fix the build", in: output.text)?.textBlocks.first as? RoundedTextBlock)
        #expect(block.backgroundColor?.isEqual(colors.bgPanel) == true)
        #expect(block.radius == Chrome.Radius.card)
        #expect(paragraphStyle(of: "You", in: output.text)?.textBlocks.first === block)
    }

    @Test func toolLinesShowTheStateGlyphNameSubjectAndADiffstatInStatusColors() throws {
        let call = AgentToolCall(
            name: "Update",
            summary: "SidebarView.swift",
            state: .succeeded,
            diff: "@@ -430,2 +430,3 @@\n rebuild()\n+collapse()\n "
        )
        let timeline = AgentTimeline(entries: [
            AgentTranscriptEntry(items: [AgentTimelineItem(id: "c1", kind: .tool(call))]),
        ])

        let text = AgentTimelineRenderer(colors: colors).render(timeline, detailed: false, isAgentActive: true).text

        #expect(color(of: "✓", in: text)?.isEqual(colors.success) == true)
        #expect(color(of: "Update", in: text)?.isEqual(colors.textPrimary) == true)
        #expect(font(of: "SidebarView.swift", in: text)?.isFixedPitch == true)
        #expect(color(of: "+1", in: text)?.isEqual(colors.success) == true)
        #expect(color(of: "−0", in: text)?.isEqual(colors.textMuted) == true)
        let accents = [colors.accent, colors.accentStrong]
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            #expect(!accents.contains { $0.isEqual(value as? NSColor) })
        }
    }

    @Test func diffRowsSitInOneHairlineBoxWithLineNumbersAndAddDeleteWashes() throws {
        let call = AgentToolCall(
            name: "Edit",
            summary: "App.swift",
            state: .succeeded,
            diff: "@@ -10,2 +10,2 @@\n context\n-old line\n+new line"
        )
        let timeline = AgentTimeline(entries: [
            AgentTranscriptEntry(items: [AgentTimelineItem(id: "c1", kind: .tool(call))]),
        ])

        let text = AgentTimelineRenderer(colors: colors).render(timeline, detailed: false, isAgentActive: true).text

        #expect(text.string.contains("\t10\t\tcontext\n"))
        #expect(text.string.contains("\t11\t−\told line\n"))
        #expect(text.string.contains("\t11\t+\tnew line\n"))
        #expect(!text.string.contains("@@"))
        #expect((attribute(.timelineRowWash, of: "new line", in: text) as? NSColor)?.isEqual(colors.diffAdd) == true)
        #expect((attribute(.timelineRowWash, of: "old line", in: text) as? NSColor)?.isEqual(colors.diffDelete) == true)
        #expect(attribute(.timelineRowWash, of: "context", in: text) == nil)
        let rows = ["context", "old line", "new line"].map {
            paragraphStyle(of: $0, in: text)?.textBlocks.last as? RoundedTextBlock
        }
        let box = try #require(rows.first ?? nil)
        #expect(rows.allSatisfy { $0 === box })
        #expect(box.edge?.isEqual(colors.borderSubtle) == true)
        #expect(box.radius == Chrome.Radius.control)
    }

    @Test func anAnswerIsHeadedByTheAgentAndKeepsEachRunOfToolCallsInOneCard() throws {
        let timeline = AgentTimeline(entries: [
            AgentTranscriptEntry(items: [AgentTimelineItem(id: "p1", kind: .prompt("Fix the build"))]),
            AgentTranscriptEntry(items: [
                AgentTimelineItem(id: "c1", kind: .tool(AgentToolCall(name: "Read", summary: "Package.swift", state: .succeeded))),
                AgentTimelineItem(id: "t1", kind: .thinking("Check the target")),
                AgentTimelineItem(id: "c2", kind: .tool(AgentToolCall(
                    name: "Edit",
                    summary: "App.swift",
                    state: .succeeded,
                    diff: "@@ -1,1 +1,1 @@\n-old line\n+new line"
                ))),
                AgentTimelineItem(id: "r1", kind: .reply("Fixed it.")),
                AgentTimelineItem(id: "c3", kind: .tool(AgentToolCall(name: "Bash", summary: "swift build", state: .succeeded))),
            ]),
        ])

        let text = AgentTimelineRenderer(colors: colors)
            .render(timeline, detailed: false, isAgentActive: true, agentName: "Claude Code")
            .text

        // One name per answer, in ink, between the prompt and the first call.
        #expect(text.string.components(separatedBy: "Claude Code").count == 2)
        #expect(color(of: "Claude Code", in: text)?.isEqual(colors.textPrimary) == true)
        let name = try #require(range(of: "Claude Code", in: text))
        #expect(try #require(range(of: "Fix the build", in: text)).location < name.location)
        #expect(name.location < (try #require(range(of: "Package.swift", in: text))).location)

        let card = try #require(paragraphStyle(of: "Package.swift", in: text)?.textBlocks.first as? RoundedTextBlock)
        #expect(card.radius == Chrome.Radius.card)
        #expect(card.edge?.isEqual(colors.borderSubtle) == true)
        #expect(paragraphStyle(of: "Check the target", in: text)?.textBlocks.first === card)
        #expect(paragraphStyle(of: "App.swift", in: text)?.textBlocks.first === card)
        // The diff box nests inside the card.
        let diffBlocks = try #require(paragraphStyle(of: "new line", in: text)?.textBlocks)
        #expect(diffBlocks.first === card)
        #expect((diffBlocks.last as? RoundedTextBlock)?.radius == Chrome.Radius.control)
        // A reply ends the card; the next call opens a new one.
        #expect(paragraphStyle(of: "Fixed it.", in: text)?.textBlocks.isEmpty == true)
        let nextCard = paragraphStyle(of: "swift build", in: text)?.textBlocks.first
        #expect(nextCard != nil && nextCard !== card)
    }

    @Test func aDiffInsideAToolCardWashesItsRowsOnlyInsideTheDiffBox() throws {
        let call = AgentToolCall(name: "Edit", summary: "App.swift", state: .succeeded, diff: "@@ -1,1 +1,1 @@\n-old line\n+new line")
        let timeline = AgentTimeline(entries: [
            AgentTranscriptEntry(items: [AgentTimelineItem(id: "c1", kind: .tool(call))]),
        ])
        let text = AgentTimelineRenderer(colors: colors).render(timeline, detailed: false, isAgentActive: true).text
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        textView.backgroundColor = colors.bgBase
        textView.textStorage?.setAttributedString(text)
        let layoutManager = try #require(textView.layoutManager)
        layoutManager.ensureLayout(for: try #require(textView.textContainer))
        let row = try #require(range(of: "new line", in: text))
        let line = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: row.location), effectiveRange: nil)
        let rep = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / textView.bounds.width
        func pixel(x: CGFloat) -> NSColor? {
            let origin = textView.textContainerOrigin
            return rep.colorAt(x: Int((origin.x + x) * scale), y: Int((origin.y + line.midY) * scale))?.usingColorSpace(.sRGB)
        }
        let base = try #require(colors.bgBase.usingColorSpace(.sRGB))
        func isBase(_ color: NSColor?) -> Bool {
            guard let color else { return false }
            return abs(color.redComponent - base.redComponent) < 0.02
                && abs(color.greenComponent - base.greenComponent) < 0.02
                && abs(color.blueComponent - base.blueComponent) < 0.02
        }
        // In the card's padding, left of the diff box, the add row shows the page.
        #expect(isBase(pixel(x: 16)))
        // Inside the diff box's code column, the row is washed.
        #expect(!isBase(pixel(x: 200)))
    }

    @Test func aRunningCallIsTheActivityWithItsCommandAndElapsedTime() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let call = AgentToolCall(name: "Bash", summary: "swift test")
        let timeline = AgentTimeline(entries: [
            AgentTranscriptEntry(items: [AgentTimelineItem(id: "p1", kind: .prompt("Test it"))]),
            AgentTranscriptEntry(items: [AgentTimelineItem(id: "c1", timestamp: start, kind: .tool(call))]),
        ])

        let activity = try #require(AgentTimelineActivity.current(
            in: timeline,
            status: .running,
            now: start.addingTimeInterval(38)
        ))

        #expect(activity.text == "▶ Bash · swift test · 38s")
        #expect(activity.tone == .working)
        let line = activity.attributed(
            font: ChromeFont.label,
            titleFont: ChromeFont.labelStrong,
            codeFont: ChromeFont.mono,
            color: colors.success,
            codeColor: colors.success
        )
        #expect(line.string == activity.text)
        #expect(font(of: "Bash", in: line) == ChromeFont.labelStrong)
        #expect(font(of: "swift test", in: line)?.isFixedPitch == true)
    }

    @Test func aLongActivityLaysOutOnOneTruncatedLineInANarrowRowLabel() throws {
        let activity = AgentTimelineActivity(
            title: "Asks",
            detail: "I deployed dbeb77e to abtool: your #33 plus my #32. The selftest passes on the server, "
                + "the dashboard API answers 200, and the server's main matches origin.",
            tone: .waiting
        )
        // Configured like the dashboard row's activity label.
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.attributedStringValue = activity.attributed(
            font: ChromeFont.meta,
            titleFont: ChromeFont.meta,
            codeFont: ChromeFont.monoSmall,
            color: colors.textPrimary,
            codeColor: colors.textPrimary,
            compact: true
        )
        let cell = try #require(label.cell)
        let drawn = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 200, height: 1_000))

        #expect(drawn.height == label.intrinsicContentSize.height)
    }

    private func range(of text: String, in rendered: NSAttributedString) -> NSRange? {
        let range = (rendered.string as NSString).range(of: text)
        return range.location == NSNotFound ? nil : range
    }

    private func attribute(_ key: NSAttributedString.Key, of text: String, in rendered: NSAttributedString) -> Any? {
        range(of: text, in: rendered).flatMap { rendered.attribute(key, at: $0.location, effectiveRange: nil) }
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
