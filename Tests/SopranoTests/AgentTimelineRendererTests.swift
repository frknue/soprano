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
            paragraphStyle(of: $0, in: text)?.textBlocks.first as? RoundedTextBlock
        }
        let box = try #require(rows.first ?? nil)
        #expect(rows.allSatisfy { $0 === box })
        #expect(box.edge?.isEqual(colors.borderSubtle) == true)
        #expect(box.radius == Chrome.Radius.control)
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
