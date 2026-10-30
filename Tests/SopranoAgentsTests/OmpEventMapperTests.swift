import AppKit
import Testing
@testable import SopranoAgentsCore

/// `OmpEventMapper` against a live omp 18.14 `--mode rpc-ui` trace (`set_event_filter` delta,
/// `--approval-mode always-ask`, claude-haiku-5-5): ask → write → edit → bash, then the user's
/// auto-double-check extension runs a second pass before `prompt_result`.
struct OmpEventMapperTests {
    private static func trace() throws -> [JSONValue] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/omp-ask-write-edit-bash.jsonl")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try JSONValue.parse(String($0)) }
    }

    private static func replay() throws -> [ProviderEvent] {
        var mapper = OmpEventMapper(cwd: "/tmp/demo", contextWindow: 100_000)
        return try trace().flatMap { mapper.map($0) }
    }

    private static func latestItems(_ events: [ProviderEvent]) -> [TurnItem] {
        var order: [String] = []
        var items: [String: TurnItem] = [:]
        for case let .itemUpdated(item) in events {
            if items[item.id] == nil { order.append(item.id) }
            items[item.id] = item
        }
        return order.compactMap { items[$0] }
    }

    private static func item(_ id: String, in events: [ProviderEvent]) -> TurnItem? {
        latestItems(events).first { $0.id == id }
    }

    // MARK: - Recorded trace

    @Test func theTraceEndsWithTheFinalAnswerThenACompletedTurn() throws {
        let events = try Self.replay()

        #expect(events.last == .turnCompleted(outcome: .completed, error: nil))
        guard case let .itemUpdated(final)? = events.dropLast().last else {
            Issue.record("expected the final answer before the turn completion")
            return
        }
        #expect(final.id == "msg-16:1")
        #expect(final.kind == .assistantMessage(text: "done", isFinal: true))
        #expect(final.status == .completed)
        #expect(events.filter { if case .turnCompleted = $0 { true } else { false } }.count == 1)
    }

    @Test func assistantTextStreamsAsDeltasOnMessageAndContentIndex() throws {
        let events = try Self.replay()
        let deltas = events.compactMap { event -> String? in
            if case let .assistantDelta(itemID, delta, false) = event, itemID == "msg-10:0" { return delta }
            return nil
        }

        #expect(deltas.joined() == "done")
        #expect(events.contains { if case let .reasoningDelta(itemID, _) = $0 { itemID == "msg-12:0" } else { false } })
        if case .reasoning = Self.item("msg-12:0", in: events)?.kind {} else { Issue.record("thinking_end should complete the reasoning item") }
    }

    @Test func theAskToolBecomesOneUserInputRequestAndNoToolItem() throws {
        let events = try Self.replay()
        let requests = events.compactMap { event -> UserInputRequest? in
            if case let .userInputRequested(request) = event { return request }
            return nil
        }

        #expect(requests == [UserInputRequest(id: "15ba93dd12d63fcb", questions: [
            UserInputQuestion(id: "color", header: "", question: "Which color do you prefer?", options: [UserInputOption(label: "red"), UserInputOption(label: "blue")], allowsMultiple: false, allowsOther: true),
        ])])
        #expect(Self.item("toolu_01Le3csjVbKtYriafak2YYkr", in: events) == nil)
    }

    @Test func approvalSelectsBecomeApprovalsWithTheirOfferedDecisions() throws {
        let approvals = try Self.replay().compactMap { event -> ApprovalRequest? in
            if case let .approvalRequested(request) = event { return request }
            return nil
        }

        #expect(approvals.map(\.id) == ["15ba93de9b163fcc", "15ba93dff3d63fcd", "15ba93e180163fce", "15ba93eca4563fd2"])
        #expect(approvals.map(\.kind) == [.fileChange, .fileChange, .command, .command])
        #expect(approvals[0].detail == "Path: /tmp/demo/color.txt\nContent:\nblue")
        #expect(approvals[1].detail == "File: color.txt")
        #expect(approvals[2].detail == "Command: cat color.txt")
        #expect(approvals.allSatisfy { $0.options == [.cancel, .decline, .acceptForSession, .accept] && $0.reason == nil })
    }

    @Test func toolExecutionsBecomeCompletedItems() throws {
        let events = try Self.replay()
        let write = try #require(Self.item("toolu_0148z2qAHYzePrKK6zQ7cVpG", in: events))
        let edit = try #require(Self.item("toolu_01UTHhuJMbSx6h49UfBR1Qon", in: events))
        let bash = try #require(Self.item("toolu_01LsbcaUNi98HXJkjuQmWruR", in: events))

        #expect(write.kind == .fileChange([FileChange(path: "color.txt", kind: .update)]))
        #expect(edit.kind == .fileChange([FileChange(path: "color.txt", kind: .update, diff: "@@ -1,1 +1,1 @@\n-blue\n+blue sky")]))
        guard case let .command(command) = bash.kind else {
            Issue.record("bash should be a command")
            return
        }
        #expect(command.command == "cat color.txt")
        #expect(command.cwd == "/tmp/demo")
        #expect(command.output == "blue sky\n")
        #expect(command.exitCode == 0)
        #expect([write, edit, bash].allSatisfy { $0.status == .completed })
    }

    @Test func theRunningEditNamesItsFileBeforeTheResultArrives() throws {
        let events = try Self.replay()
        let first = events.first { if case let .itemUpdated(item) = $0 { item.id == "toolu_01UTHhuJMbSx6h49UfBR1Qon" } else { false } }

        if case let .itemUpdated(item)? = first {
            #expect(item.kind == .fileChange([FileChange(path: "color.txt", kind: .update)]))
            #expect(item.status == .running)
        }
    }

    @Test func assistantUsageReportsTokensAgainstTheContextWindow() throws {
        let usages = try Self.replay().compactMap { event -> TokenUsage? in
            if case let .tokenUsage(usage) = event { return usage }
            return nil
        }

        #expect(usages.first == TokenUsage(usedTokens: 52_386, contextWindow: 100_000))
        #expect(usages.last == TokenUsage(usedTokens: 55_166, contextWindow: 100_000))
    }

    @Test func extensionNotificationsBecomeNotices() throws {
        let item = Self.item("notify:15ba93e89b563fd0", in: try Self.replay())

        #expect(item?.kind == .notice(text: "auto-double-check: second pass before finishing"))
    }

    // MARK: - Recorded commands and compaction (omp 18.14, claude-haiku-5-5)

    /// `omp-commands-compact.jsonl`: the `get_available_commands` response, the
    /// `available_commands_update` pushed once the MCP prompts loaded (one command per source),
    /// `get_state` after a turn, then `compact` twice: committed (then `get_state`), then skipped
    /// ("Already compacted", answered with a failure).
    private static func commandsTrace() throws -> [JSONValue] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/omp-commands-compact.jsonl")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try JSONValue.parse(String($0)) }
    }

    @Test func pushedCommandUpdatesListEveryCommandWithItsKindHintAndBadge() throws {
        var mapper = OmpEventMapper(cwd: "/tmp/demo")
        let events = try Self.commandsTrace().prefix(2).flatMap { mapper.map($0) }

        guard case let .commands(commands)? = events.first, events.count == 1 else {
            Issue.record("expected one commands event, got \(events)")
            return
        }
        #expect(commands.map(\.insertText) == ["/compact ", "/model ", "/context ", "/skill:diagnosing-bugs ", "/skill:tdd ", "/review-with ", "/green ", "/init ", "/demo:trace_crash "])
        #expect(commands.map(\.source) == ["Built-in", "Built-in", "Built-in", "Skill", "Skill", "Extension", "Custom", "Custom", "MCP"])
        #expect(commands.filter { $0.kind == .skill }.map(\.name) == ["skill:diagnosing-bugs", "skill:tdd"])
        #expect(commands[0] == ProviderCommand(
            name: "compact", kind: .command, description: "Compact the conversation",
            argumentHint: "[soft|remote|snapcompact] [focus]", source: "Built-in", insertText: "/compact "
        ))
        #expect(commands[1].argumentHint == nil)
    }

    @Test func manualCompactionsBecomeNoticesAndRememberHowTheyEnded() throws {
        var mapper = OmpEventMapper(cwd: "/tmp/demo")
        var ends: [OmpEventMapper.CompactionEnd?] = []
        var events: [ProviderEvent] = []
        for frame in try Self.commandsTrace() {
            events += mapper.map(frame)
            if frame["type"] == "manual_compaction_end" { ends.append(mapper.compactionEnd) }
        }

        let notices = Self.latestItems(events).map(\.kind)
        #expect(notices == [.notice(text: "Context compacted"), .notice(text: "Already compacted")])
        #expect(ends == [.compacted, .skipped("Already compacted")])
    }

    @Test func cancelledAndFailedCompactionsAreShownAsSuch() {
        var mapper = OmpEventMapper(cwd: "/repo")
        let cancelled = mapper.map(["type": "manual_compaction_end", "aborted": true, "errorMessage": "Compaction cancelled"])
        let cancelEnd = mapper.compactionEnd
        _ = mapper.map(["type": "manual_compaction_start"])
        let cleared = mapper.compactionEnd
        let failed = mapper.map(["type": "manual_compaction_end", "aborted": false, "errorMessage": "context too large to summarize"])

        #expect(Self.latestItems(cancelled).map(\.kind) == [.notice(text: "Compaction cancelled")])
        #expect(cancelEnd == .cancelled && cleared == nil)
        #expect(Self.latestItems(failed).map(\.kind) == [.error(message: "Compaction failed: context too large to summarize")])
        #expect(mapper.compactionEnd == .failed("context too large to summarize"))
    }

    // MARK: - Synthetic frames

    private static func map(_ frames: [JSONValue]) -> [ProviderEvent] {
        var mapper = OmpEventMapper(cwd: "/repo")
        return frames.flatMap { mapper.map($0) }
    }

    private static func ui(_ method: String, _ fields: [String: JSONValue]) -> JSONValue {
        var frame = fields
        frame["type"] = "extension_ui_request"
        frame["id"] = "ui-1"
        frame["method"] = .string(method)
        return .object(frame)
    }

    @Test func aFailedCommandKeepsItsExitCode() {
        let events = Self.map([
            ["type": "tool_execution_start", "toolCallId": "t1", "toolName": "bash", "args": ["command": "false"]],
            ["type": "tool_execution_end", "toolCallId": "t1", "toolName": "bash", "isError": true,
             "result": ["content": [["type": "text", "text": "Command exited with code 1"]], "details": ["exitCode": 1]]],
        ])

        guard case let .itemUpdated(item)? = events.last, case let .command(command) = item.kind else {
            Issue.record("expected a command item")
            return
        }
        #expect(item.status == .failed)
        #expect(command.exitCode == 1)
    }

    @Test func aDeclinedApprovalMarksItsToolDeclined() {
        var mapper = OmpEventMapper(cwd: "/repo")
        _ = mapper.map(["type": "tool_execution_start", "toolCallId": "t1", "toolName": "bash", "args": ["command": "rm -rf x"]])
        _ = mapper.map(Self.ui("select", ["title": "Allow tool: bash\nCommand: rm -rf x", "options": ["Approve", "Deny"]]))
        mapper.markDeclined(requestID: "ui-1")
        let events = mapper.map(["type": "tool_execution_end", "toolCallId": "t1", "toolName": "bash", "isError": true,
                                 "result": ["content": [["type": "text", "text": "Denied by user"]]]])

        guard case let .itemUpdated(item)? = events.last else {
            Issue.record("expected an item")
            return
        }
        #expect(item.status == .declined)
    }

    @Test func streamedBashOutputArrivesAsDeltas() {
        let events = Self.map([
            ["type": "tool_execution_start", "toolCallId": "t1", "toolName": "bash", "args": ["command": "ls"]],
            ["type": "tool_execution_update", "toolCallId": "t1", "partialResult": ["content": [["type": "text", "text": "a\n"]]]],
            ["type": "tool_execution_update", "toolCallId": "t1", "partialResult": ["content": [["type": "text", "text": "a\nb\n"]]]],
        ])

        #expect(Array(events.dropFirst()) == [.commandOutputDelta(itemID: "t1", delta: "a\n"), .commandOutputDelta(itemID: "t1", delta: "b\n")])
    }

    @Test func toolsGetTitlesByKind() {
        let events = Self.map([
            ["type": "tool_execution_start", "toolCallId": "r", "toolName": "read", "args": ["path": "/repo/Sources/App.swift"]],
            ["type": "tool_execution_start", "toolCallId": "g", "toolName": "grep", "args": ["pattern": "TODO", "path": "/repo/Sources"]],
            ["type": "tool_execution_start", "toolCallId": "w", "toolName": "web_search", "args": ["query": "swift testing"]],
            ["type": "tool_execution_start", "toolCallId": "s", "toolName": "task", "args": ["tasks": [["name": "Scout"]]]],
            ["type": "tool_execution_start", "toolCallId": "t", "toolName": "todo", "args": [:]],
            ["type": "tool_execution_start", "toolCallId": "e", "toolName": "eval", "args": ["code": "1"], "intent": "Computing one"],
        ])
        let titles = Self.latestItems(events).map { item -> String in
            switch item.kind {
            case let .toolCall(call): "\(call.category.rawValue): \(call.title)"
            case let .webSearch(query): "web: \(query)"
            default: "?"
            }
        }

        #expect(titles == ["read: Read Sources/App.swift", "search: Searched TODO in Sources", "web: swift testing", "subagent: Subagent: Scout", "other: Updated tasks", "other: Computing one"])
    }

    @Test func dialogsBecomeQuestions() {
        let events = Self.map([
            Self.ui("confirm", ["title": "Proceed?", "message": "Really"]),
            Self.ui("input", ["title": "Name?"]),
            Self.ui("select", ["title": "Pick one", "options": ["a", "b"]]),
            Self.ui("ask", ["questions": [["id": "q", "header": "Tools", "question": "Which?", "multi": true,
                                           "options": [["label": "git", "description": "VCS"]]]]]),
        ])
        let questions = events.compactMap { event -> UserInputQuestion? in
            if case let .userInputRequested(request) = event { return request.questions.first }
            return nil
        }

        #expect(questions.map(\.options.count) == [2, 0, 2, 1])
        #expect(questions[0].options.map(\.label) == ["Yes", "No"])
        #expect(questions[1].allowsOther && !questions[0].allowsOther && !questions[2].allowsOther)
        #expect(questions[3] == UserInputQuestion(id: "q", header: "Tools", question: "Which?", options: [UserInputOption(label: "git", description: "VCS")], allowsMultiple: true, allowsOther: true))
    }

    @Test func cancelWithdrawsARequestAndPresentationRequestsAreIgnored() {
        let events = Self.map([
            Self.ui("cancel", ["targetId": "ui-0"]),
            Self.ui("setStatus", ["statusKey": "k"]),
            Self.ui("setWidget", ["widgetKey": "k"]),
            Self.ui("setTitle", ["title": "t"]),
            Self.ui("set_editor_text", ["text": "t"]),
        ])

        #expect(events == [.requestResolved(id: "ui-0")])
    }

    @Test func promptResultStatusesMapToTurnOutcomes() {
        #expect(Self.map([["type": "prompt_result", "status": "aborted"]]) == [.turnCompleted(outcome: .interrupted, error: nil)])
        #expect(Self.map([["type": "prompt_result", "status": "error", "error": ["message": "rate limited"]]]) == [.turnCompleted(outcome: .failed, error: "rate limited")])
    }

    @Test func compactionAndRetriesBecomeNotices() {
        let events = Self.map([
            ["type": "auto_compaction_end"],
            ["type": "auto_retry_start", "attempt": 2, "maxAttempts": 3, "errorMessage": "overloaded"],
        ])

        #expect(Self.latestItems(events).map(\.kind) == [.notice(text: "Context compacted"), .notice(text: "Retrying (attempt 2 of 3): overloaded")])
    }

    @Test func slashCommandOutputKeepsMarkdownAndFencesAlignedText() {
        let markdown = Self.map([["type": "command_output", "text": "## [18.13.2]\n\n- Added `ctx.sessionModes`\n"]])
        let line = Self.map([["type": "command_output", "text": "Fast mode enabled."]])
        let columns = Self.map([["type": "command_output", "text": "MCP\n  /mcp list    List servers"]])

        #expect(Self.latestItems(markdown).map(\.kind) == [.assistantMessage(text: "## [18.13.2]\n\n- Added `ctx.sessionModes`", isFinal: true)])
        #expect(Self.latestItems(line).map(\.kind) == [.assistantMessage(text: "Fast mode enabled.", isFinal: true)])
        #expect(Self.latestItems(columns).map(\.kind) == [.assistantMessage(text: "```\nMCP\n  /mcp list    List servers\n```", isFinal: true)])
    }

    @Test func ompDisplayDiffsBecomeUnifiedHunks() {
        #expect(OmpEventMapper.unifiedDiff(" 3|a\n-4|b\n+4|c\n 5|d\n...\n-9|x") == "@@ -3,3 +3,3 @@\n a\n-b\n+c\n d\n@@ -9,1 +8,0 @@\n-x")
    }
}
