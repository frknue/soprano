import AppKit
import Testing
@testable import Soprano

struct AgentTimelineTests {
    @Test func parallelToolCallsHangingOffEachOtherStayVisibleWhileARewoundTurnStaysHidden() {
        // Claude Code chains the second parallel call to the first and hangs each
        // result off its own call; the rewind replaced the prompt "p1" with "p2".
        let timeline = AgentTimeline(entries: [
            entry("p0", parent: nil, items: [prompt("p0", "First question")]),
            entry("r0", parent: "p0", items: [reply("r0", "First answer")]),
            entry("p1", parent: "r0", items: [prompt("p1", "Old wording")]),
            entry("x1", parent: "p1", items: [reply("x1", "Abandoned answer")]),
            entry("p2", parent: "r0", items: [prompt("p2", "New wording")]),
            entry("c1", parent: "p2", items: [tool("call-1", "Read")]),
            entry("c2", parent: "c1", items: [tool("call-2", "Grep")]),
            entry("res2", parent: "c2", results: ["call-2": AgentToolResult(state: .succeeded)]),
            entry("res1", parent: "c1", results: ["call-1": AgentToolResult(state: .failed)]),
            entry("r2", parent: "res1", items: [reply("r2", "Done")]),
        ])

        #expect(timeline.items.map(\.id) == ["p0", "r0", "p2", "call-1", "call-2", "r2"])
        #expect(timeline.items.compactMap(\.toolCall?.state) == [.failed, .succeeded])
    }

    @Test func callsWithoutAResultBeforeTheNextPromptReadAsInterruptedUnlessTheResultStillArrives() {
        let timeline = AgentTimeline(entries: [
            AgentTranscriptEntry(items: [prompt("p1", "Build it")]),
            AgentTranscriptEntry(items: [tool("call-1", "Bash"), tool("call-2", "Bash")]),
            AgentTranscriptEntry(items: [prompt("p2", "Stop, run the tests instead")]),
            AgentTranscriptEntry(results: ["call-2": AgentToolResult(state: .succeeded)]),
            AgentTranscriptEntry(items: [tool("call-3", "Bash")]),
        ])

        #expect(timeline.items.compactMap(\.toolCall?.state) == [.interrupted, .succeeded, .running])
        #expect(timeline.runningTool?.id == "call-3")
    }

    private func entry(
        _ id: String,
        parent: String?,
        items: [AgentTimelineItem] = [],
        results: [String: AgentToolResult] = [:]
    ) -> AgentTranscriptEntry {
        AgentTranscriptEntry(id: id, parentId: parent, items: items, results: results)
    }

    private func prompt(_ id: String, _ text: String) -> AgentTimelineItem {
        AgentTimelineItem(id: id, kind: .prompt(text))
    }

    private func reply(_ id: String, _ text: String) -> AgentTimelineItem {
        AgentTimelineItem(id: id, kind: .reply(text))
    }

    private func tool(_ id: String, _ name: String) -> AgentTimelineItem {
        AgentTimelineItem(id: id, kind: .tool(AgentToolCall(name: name, summary: "")))
    }
}
