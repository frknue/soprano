import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

struct WorkLogTests {
    private func item(_ id: String, _ kind: TurnItemKind, status: TurnItemStatus = .completed) -> TurnItem {
        TurnItem(id: id, kind: kind, status: status, startedAt: Date(timeIntervalSince1970: 0))
    }

    private func entry(_ id: String, _ kind: TurnItemKind, status: TurnItemStatus = .completed) -> WorkLogEntry {
        WorkLog.entry(for: item(id, kind, status: status))!
    }

    private func read(_ id: String) -> WorkLogEntry {
        entry(id, .toolCall(ToolCall(name: "Read", category: .read, title: "Read \(id).swift")))
    }

    private func command(_ id: String, _ line: String = "swift build", status: TurnItemStatus = .completed) -> WorkLogEntry {
        entry(id, .command(CommandExecution(command: line)), status: status)
    }

    private func edit(_ id: String, _ paths: [String]) -> WorkLogEntry {
        entry(id, .fileChange(paths.map { FileChange(path: $0, kind: .update) }))
    }

    @Test func commandsAndEditsLeadTheSummaryInTheOrderTheyHappened() {
        #expect(WorkLog.summary([read("a"), command("c"), read("b")]) == "Read 2 files and ran 1 command")
        #expect(WorkLog.summary([command("c1"), command("c2")]) == "Ran 2 commands")
        let web = entry("w", .webSearch(query: "cookies"))
        #expect(WorkLog.summary([web]) == "Searched the web 1 time")
    }

    @Test func aSummaryNamesTwoKindsAndCountsTheRest() {
        let entries = [edit("e1", ["A.swift", "B.swift"]), edit("e2", ["C.swift"]), command("c"), entry("w", .webSearch(query: "q"))]
        #expect(WorkLog.summary(entries) == "Changed 3 files, ran 1 command, and performed 1 other action")
    }

    @Test func editsCountDistinctFiles() {
        #expect(WorkLog.summary([edit("e1", ["A.swift"]), edit("e2", ["A.swift"])]) == "Changed 1 file")
    }

    @Test func reasoningOnlyGroupsReadThought() {
        let thought = entry("r", .reasoning(text: "Looking around."))
        #expect(WorkLog.summary([thought]) == "Thought")
        #expect(WorkLog.summary([thought, entry("r2", .reasoning(text: "More."))]) == "Thought (×2)")
        #expect(WorkLog.summary([thought, command("c")]) == "Ran 1 command")
        #expect(WorkLog.summaryIcon([thought]) == TimelineIcon.workReasoning)
        #expect(WorkLog.summaryIcon([read("a"), command("c")]) == TimelineIcon.workMixed)
        #expect(WorkLog.summaryIcon([read("a"), read("b")]) == TimelineIcon.workRead)
    }

    @Test func entriesUseTheWorkLogWording() {
        #expect(command("c", "rg -n foo\n  Sources").label == "Ran command")
        #expect(command("c", status: .running).label == "Running command")
        #expect(command("c", "rg -n foo\n  Sources").detail == "rg -n foo Sources")
        #expect(edit("e", ["Sources/App.swift"]).label == "Changed Sources/App.swift")
        #expect(edit("e", ["A.swift", "B.swift"]).label == "Changed 2 files")
        #expect(entry("w", .webSearch(query: "timing")).label == "Searched the web")
        #expect(entry("t", .toolCall(ToolCall(name: "github.create_issue", category: .mcp, title: ""))).label == "github.create_issue")
        #expect(entry("r", .reasoning(text: "x"), status: .running).label == "Thinking")
        let approval = ApprovalRequest(id: "a", kind: .command, detail: "rm -rf build", decision: .decline)
        #expect(entry("a", .approval(approval)).label == "Approval requested")
        #expect(entry("a", .approval(approval)).note == "Declined")
        #expect(WorkLog.entry(for: item("m", .assistantMessage(text: "hi", isFinal: true))) == nil)
    }

    @Test func emptyReasoningNeverShows() {
        #expect(!entry("r", .reasoning(text: "  \n")).isVisible)
        #expect(entry("r", .reasoning(text: "Thinking about it")).isVisible)
    }

    @Test func commandOutputIncludesTheCommandAndAFailingExitCode() {
        let failed = entry("c", .command(CommandExecution(command: "swift test", output: "boom\n", exitCode: 1)), status: .failed)
        #expect(failed.body == "$ swift test\nboom\n\nExit code 1")
        #expect(failed.isFailed)
        #expect(failed.canExpand)
    }

    @Test func liveLabelsNameTheRunningProgram() {
        #expect(WorkLog.liveLabel(command("c", "swift build", status: .running)) == "Running swift")
        #expect(WorkLog.liveLabel(command("c", "cd app && FOO=1 /usr/bin/make test", status: .completed)) == "Ran make")
        #expect(WorkLog.liveLabel(entry("r", .reasoning(text: ""), status: .running)) == "Thinking")
    }

    @Test func theThoughtLineIsTheBoldHeadingOrTheFirstSentence() {
        #expect(WorkLog.thoughtLine("**Tracing the redirect.** The loop likely comes from…") == "Tracing the redirect.")
        #expect(WorkLog.thoughtLine("**Tracing the redirect**\nThe loop likely comes from…") == "Tracing the redirect")
        #expect(WorkLog.thoughtLine("Check `SessionStore` first. Then the [router](x).") == "Check SessionStore first.")
        #expect(WorkLog.thoughtLine("- a *list* item without an end") == "a list item without an end")
    }

    @Test func theTaskTitleCountsDoneStepsAndNamesTheCurrentOne() {
        let steps = [
            TodoStep(id: "1", text: "Inventory", status: .completed),
            TodoStep(id: "2", text: "Draft", status: .inProgress),
            TodoStep(id: "3", text: "Ship", status: .pending),
        ]
        #expect(WorkLog.todoTitle(steps) == "Tasks 1/3 · Draft")
        #expect(WorkLog.todoTitle(steps.map { TodoStep(id: $0.id, text: $0.text, status: .completed) }) == "Tasks 3/3")
    }
}
