import AppKit
import Testing
@testable import Soprano

@MainActor
struct AgentTimelineActivityTests {
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
        let title = Typography.ui(Typography.rowSize, weight: .medium)
        let line = activity.attributed(
            font: Typography.ui(Typography.rowSize),
            titleFont: title,
            codeFont: Typography.mono(Typography.smallSize),
            color: .labelColor,
            codeColor: .labelColor
        )
        #expect(line.string == activity.text)
        #expect(font(of: "Bash", in: line) == title)
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
        let meta = Typography.ui(Typography.smallSize)
        label.attributedStringValue = activity.attributed(
            font: meta,
            titleFont: meta,
            codeFont: Typography.mono(Typography.tinySize),
            color: .labelColor,
            codeColor: .labelColor,
            compact: true
        )
        let cell = try #require(label.cell)
        let drawn = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 200, height: 1_000))

        #expect(drawn.height == label.intrinsicContentSize.height)
    }

    private func font(of text: String, in rendered: NSAttributedString) -> NSFont? {
        let range = (rendered.string as NSString).range(of: text)
        guard range.location != NSNotFound else { return nil }
        return rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
    }
}
