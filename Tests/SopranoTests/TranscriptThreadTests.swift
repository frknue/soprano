import AppKit
import Testing
@testable import Soprano

@MainActor
struct TranscriptThreadTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func eachPromptStartsATurnAndAFinishedTurnsLastReplyIsItsAnswer() throws {
        let timeline = AgentTimeline(items: [
            item("p1", 0, .prompt("Fix the build")),
            item("r1", 5, .reply("Looking at it.")),
            item("c1", 10, .tool(AgentToolCall(name: "Bash", summary: "swift build", state: .succeeded, output: "ok", finishedAt: start.addingTimeInterval(40)))),
            item("r2", 72, .reply("Fixed.")),
            item("p2", 100, .prompt("Now the tests")),
            item("t2", 103, .thinking("Running the suite.")),
        ])

        let thread = ChatThread(transcript: timeline, isRunning: true)

        #expect(thread.turns.map(\.userMessage.text) == ["Fix the build", "Now the tests"])
        let first = thread.turns[0]
        #expect(first.status == .completed)
        #expect(first.startedAt == start)
        #expect(first.completedAt == start.addingTimeInterval(72))
        #expect(first.items.map(\.id) == ["r1", "c1", "r2"])
        #expect(first.items[0].kind == .assistantMessage(text: "Looking at it.", isFinal: false))
        #expect(first.items[2].kind == .assistantMessage(text: "Fixed.", isFinal: true))
        #expect(first.items[1].kind == .command(TurnCommand(command: "swift build", output: "ok", exitCode: 0)))
        // The agent still works on the newest turn.
        #expect(thread.turns[1].status == .running)
        #expect(thread.turns[1].completedAt == nil)
        #expect(thread.turns[1].items.map(\.kind) == [.reasoning(text: "Running the suite.")])

        let rows = TimelineBuilder.rows(for: thread, emptyText: "", expansion: TimelineExpansion(detailed: false))
        #expect(rows.contains { $0.id == "fold:p1" })
        if case let .fold(model)? = rows.first(where: { $0.id == "fold:p1" })?.content {
            #expect(model.label == "Worked for 1m 12s")
        }
        #expect(rows.contains { $0.id == "working:p2" })
    }

    @Test func theCLIsToolNamesReadAsCommandsEditsReadsSearchesAndTheRest() {
        func kind(_ call: AgentToolCall) -> TurnItemKind { ChatThread.kind(of: call) }

        #expect(kind(AgentToolCall(name: "Run", summary: "cargo test", detail: "cd x && cargo test", state: .failed))
            == .command(TurnCommand(command: "cd x && cargo test", output: "", exitCode: 1)))
        #expect(kind(AgentToolCall(name: "Edit", summary: "Sources/App.swift", diff: "@@ -1 +1 @@\n-a\n+b"))
            == .fileChange([FileChange(path: "Sources/App.swift", kind: .update, diff: "@@ -1 +1 @@\n-a\n+b")]))
        #expect(kind(AgentToolCall(name: "Write", summary: "notes.txt", diff: "+one"))
            == .fileChange([FileChange(path: "notes.txt", kind: .update, diff: "+one", isFullContent: true)]))
        #expect(kind(AgentToolCall(name: "Read", summary: "README.md"))
            == .toolCall(ToolCall(name: "Read", category: .read, title: "Read README.md")))
        #expect(kind(AgentToolCall(name: "Grep", summary: "TODO in Sources"))
            == .toolCall(ToolCall(name: "Grep", category: .search, title: "Searched TODO in Sources")))
        #expect(kind(AgentToolCall(name: "WebSearch", summary: "swift testing")) == .webSearch(query: "swift testing"))
        #expect(kind(AgentToolCall(name: "Task", summary: "Audit the repo"))
            == .toolCall(ToolCall(name: "Task", category: .subagent, title: "Subagent: Audit the repo")))
        #expect(kind(AgentToolCall(name: "Todo", summary: "3 todos"))
            == .toolCall(ToolCall(name: "Todo", category: .other, title: "Todo 3 todos")))
    }

    @Test func aCodexChangeToSeveralFilesBecomesOneDiffPerFile() {
        let call = AgentToolCall(
            name: "Edit",
            summary: "a.swift +1 more",
            diff: "diff a.swift\n@@ -1 +1 @@\n-a\n+b\ndiff b.swift\n@@ -2 +2 @@\n-c\n+d"
        )

        #expect(ChatThread.kind(of: call) == .fileChange([
            FileChange(path: "a.swift", kind: .update, diff: "@@ -1 +1 @@\n-a\n+b"),
            FileChange(path: "b.swift", kind: .update, diff: "@@ -2 +2 @@\n-c\n+d"),
        ]))
        // A git-style diff of one file is not split.
        let git = AgentToolCall(name: "Edit", summary: "a.swift", diff: "diff --git a/a.swift b/a.swift\n@@ -1 +1 @@\n-a\n+b")
        #expect(ChatThread.kind(of: git) == .fileChange([FileChange(path: "a.swift", kind: .update, diff: git.diff)]))
    }

    @Test func workBeforeTheFirstKeptPromptOpensATurnWithoutAMessageAndNoticesStayAbove() {
        let timeline = AgentTimeline(items: [
            item("n1", 0, .notice("Context compacted", isError: false)),
            item("r0", 1, .reply("…and that finishes the refactor.")),
            item("p1", 5, .prompt("Ship it")),
        ])

        let thread = ChatThread(transcript: timeline, isRunning: false)

        #expect(thread.preamble.map(\.kind) == [.notice(text: "Context compacted")])
        #expect(thread.turns.map(\.userMessage.text) == ["", "Ship it"])
        let rows = TimelineBuilder.rows(for: thread, emptyText: "")
        #expect(!rows.contains { $0.id == "user:transcript-head" })
        #expect(rows.contains { $0.id == "assistant:r0" })
    }

    private func item(_ id: String, _ seconds: TimeInterval, _ kind: AgentTimelineItem.Kind) -> AgentTimelineItem {
        AgentTimelineItem(id: id, timestamp: start.addingTimeInterval(seconds), kind: kind)
    }
}
