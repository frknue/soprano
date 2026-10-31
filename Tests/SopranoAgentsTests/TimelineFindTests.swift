import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

@MainActor
struct TimelineFindTests {
    @Test func matchesIgnoreCaseAndAccentsAndFollowRowOrder() {
        let rows: [(id: String, units: [String])] = [
            (id: "a", units: ["Redirect, then redirect again", "no hit"]),
            (id: "b", units: ["Café REDIRECT"]),
        ]
        let matches = TimelineFind.matches(of: "redirect", in: rows)
        #expect(matches == [
            TimelineFindMatch(rowID: "a", unit: 0, range: NSRange(location: 0, length: 8)),
            TimelineFindMatch(rowID: "a", unit: 0, range: NSRange(location: 15, length: 8)),
            TimelineFindMatch(rowID: "b", unit: 0, range: NSRange(location: 5, length: 8)),
        ])
        #expect(TimelineFind.matches(of: "cafe", in: rows).count == 1)
        #expect(TimelineFind.matches(of: "  ", in: rows).isEmpty)
    }

    @Test func theCountReadsCurrentOverTotal() {
        #expect(TimelineFind.countLabel(index: 0, total: 0) == "0/0")
        #expect(TimelineFind.countLabel(index: 1, total: 12) == "2/12")
        #expect(TimelineFind.countLabel(index: 40, total: 3) == "3/3")
    }

    @Test func findSearchesTheRenderedTextOfMessagesNotTheirMarkdownSource() throws {
        let thread = AgentThread(
            projectID: nil,
            modelSelection: ModelSelection(provider: .omp, model: "m"),
            turns: [Turn(
                ordinal: 1,
                userMessage: UserMessage(id: "u", text: "Why does **login** loop?"),
                modelSelection: ModelSelection(provider: .omp, model: "m"),
                status: .completed,
                completedAt: Date(),
                items: [
                    TurnItem(id: "c", kind: .command(CommandExecution(command: "grep login")), status: .completed),
                    TurnItem(id: "a", kind: .assistantMessage(text: "The `login` cookie\n\n```swift\nlogin()\n```", isFinal: true), status: .completed),
                ]
            )]
        )
        let rows = TimelineBuilder.rows(for: thread)
        let units = rows.map { (id: $0.id, units: TimelineFind.units(of: $0)) }
        let matches = TimelineFind.matches(of: "login", in: units)
        // The user message (bold markers gone), the answer's prose and its code block; the folded
        // command is not shown, so it is not found.
        #expect(matches.map(\.rowID) == ["user:u", "assistant:a", "assistant:a"])
        #expect(matches[0].range == NSRange(location: 9, length: 5))
        #expect(matches.map(\.unit) == [0, 0, 1])
        #expect(TimelineFind.matches(of: "**", in: units).isEmpty)
    }
}
