import AppKit
import Testing
@testable import SopranoAgentsCore

struct ClaudeEventMapperTests {
    private static func trace(_ name: String) throws -> [JSONValue] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).jsonl")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try JSONValue.parse(String($0)) }
    }

    private static func replay(_ name: String) throws -> [ProviderEvent] {
        var mapper = ClaudeEventMapper()
        return try trace(name).flatMap { mapper.map($0) }
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

    private static func mapAll(_ messages: [JSONValue], cwd: String? = "/repo") -> [ProviderEvent] {
        var mapper = ClaudeEventMapper(cwd: cwd)
        return messages.flatMap { mapper.map($0) }
    }

    private static func assistant(_ id: String, _ blocks: [JSONValue], uuid: String = "a-uuid") -> JSONValue {
        ["type": "assistant", "parent_tool_use_id": nil, "uuid": .string(uuid), "message": ["id": .string(id), "content": .array(blocks)]]
    }

    private static func toolResult(_ id: String, _ content: JSONValue, isError: Bool = false, extra: JSONValue = nil) -> JSONValue {
        ["type": "user", "parent_tool_use_id": nil,
         "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": .string(id), "content": content, "is_error": .bool(isError)]]],
         "tool_use_result": extra]
    }

    // MARK: - Recorded traces

    @Test func theBashTraceBecomesACompletedCommandThenTheFinalAnswer() throws {
        let events = try Self.replay("claude-bash-turn")
        let items = Self.latestItems(events)

        #expect(events.first == .conversationID("c4b2f294-6dee-4b51-b3c8-5ef537d1bfa8"))
        #expect(events.filter { if case .conversationID = $0 { true } else { false } }.count == 1)
        #expect(items.map(\.id) == ["toolu_01LSFfQTScdoUb6bY8T3gXEi", "msg_011CgYNYxrp8fnk1RWQHhVCS:1"])
        #expect(items[0].kind == .command(CommandExecution(command: "ls", output: "a.txt\nerr.txt\nin.jsonl\nout.jsonl")))
        #expect(items[0].status == .completed)
        #expect(items[1].kind == .assistantMessage(text: "Done", isFinal: true))
        #expect(events.last == .turnCompleted(outcome: .completed, error: nil))
    }

    @Test func theCommandIsShownRunningBeforeItsResultArrives() throws {
        let commandStates = try Self.replay("claude-bash-turn").compactMap { event -> TurnItemStatus? in
            if case let .itemUpdated(item) = event, case .command = item.kind { return item.status }
            return nil
        }
        #expect(commandStates == [.running, .completed])
    }

    @Test func textDeltasStreamIntoTheSameItemTheAssistantMessageCompletes() throws {
        let events = try Self.replay("claude-bash-turn")
        let deltas = events.compactMap { event -> String? in
            if case let .assistantDelta(itemID, delta, _) = event, itemID == "msg_011CgYNYxrp8fnk1RWQHhVCS:1" { return delta }
            return nil
        }
        #expect(deltas.joined() == "Done")
        // The signature-only thinking block has no text and must not produce an empty row.
        #expect(!events.contains { if case .reasoningDelta = $0 { true } else { false } })
        #expect(!Self.latestItems(events).contains { if case .reasoning = $0.kind { true } else { false } })
    }

    @Test func theWriteApprovalTraceAsksForAFileChangeApprovalOnTheRelativePath() throws {
        let request = try #require(try Self.trace("claude-write-approval").first { $0["type"] == "control_request" })
        let prompt = ClaudeEventMapper.permissionPrompt(requestID: request["request_id"]?.stringValue ?? "", request: request["request"] ?? .null, cwd: "/tmp/demo")
        #expect(prompt == .approval(ApprovalRequest(id: "c637a159-7e8b-4a9f-9fc0-dcb892a13dc7", kind: .fileChange, detail: "b.txt")))
    }

    @Test func theWriteTraceProducesACreatedFileWithItsDiffAndAFinalAnswer() throws {
        let events = try Self.replay("claude-write-approval")
        let items = Self.latestItems(events)
        #expect(items.count == 2)
        #expect(items[0].kind == .fileChange([FileChange(path: "b.txt", kind: .add, diff: "@@ -0,0 +1,1 @@\n+hello")]))
        #expect(items[0].status == .completed)
        #expect(items[1].kind == .assistantMessage(text: "hello", isFinal: true))
        #expect(events.last == .turnCompleted(outcome: .completed, error: nil))
        // The host's own control_response echoed in the trace produces nothing.
        #expect(!events.contains { if case .approvalRequested = $0 { true } else { false } })
    }

    @Test func theTurnReportsContextUsageFromTheLastAssistantMessage() throws {
        let usage = try Self.replay("claude-bash-turn").compactMap { event -> TokenUsage? in
            if case let .tokenUsage(usage) = event { return usage }
            return nil
        }
        // Last assistant message: 2 input + 8603 cache creation + 36988 cache read + 2 output.
        #expect(usage.first?.usedTokens == 45595)
    }

    // MARK: - Synthetic messages

    @Test func deniedToolsEndDeclinedAndOtherErrorsEndFailed() {
        var mapper = ClaudeEventMapper(cwd: "/repo")
        _ = mapper.map(Self.assistant("m1", [
            ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "rm -rf build"]],
            ["type": "tool_use", "id": "t2", "name": "Bash", "input": ["command": "false"]],
        ]))
        mapper.markDeclined(toolUseID: "t1")
        let declined = mapper.map(Self.toolResult("t1", "User declined tool execution.", isError: true))
        let failed = mapper.map(Self.toolResult("t2", "Exit code 1", isError: true))
        #expect(Self.latestItems(declined).first?.status == .declined)
        #expect(Self.latestItems(failed).first?.status == .failed)
    }

    @Test func searchAndReadToolsGetReadableTitlesRelativeToTheWorkspace() {
        let events = Self.mapAll([Self.assistant("m1", [
            ["type": "tool_use", "id": "r", "name": "Read", "input": ["file_path": "/repo/Sources/x.swift"]],
            ["type": "tool_use", "id": "g", "name": "Grep", "input": ["pattern": "foo", "path": "/repo/Sources"]],
            ["type": "tool_use", "id": "f", "name": "Glob", "input": ["pattern": "**/*.md"]],
            ["type": "tool_use", "id": "w", "name": "WebSearch", "input": ["query": "swift testing"]],
            ["type": "tool_use", "id": "m", "name": "mcp__github__create_issue", "input": ["title": "Bug"]],
        ])])
        let titles = Self.latestItems(events).map { item -> String in
            switch item.kind {
            case let .toolCall(call): "\(call.category.rawValue): \(call.title)"
            case let .webSearch(query): "web: \(query)"
            default: "other"
            }
        }
        #expect(titles == [
            "read: Read Sources/x.swift",
            "search: Searched \"foo\" in Sources",
            "search: Searched files \"**/*.md\"",
            "web: swift testing",
            "mcp: github: create_issue",
        ])
    }

    @Test func todoWritesUpdateOneTodoListPerTurn() {
        let events = Self.mapAll([
            Self.assistant("m1", [["type": "tool_use", "id": "todo-a", "name": "TodoWrite", "input": ["todos": [
                ["content": "Read code", "status": "in_progress", "activeForm": "Reading"],
                ["content": "Fix bug", "status": "pending", "activeForm": "Fixing"],
            ]]]]),
            Self.toolResult("todo-a", "Todos have been modified successfully."),
            Self.assistant("m2", [["type": "tool_use", "id": "todo-b", "name": "TodoWrite", "input": ["todos": [
                ["content": "Read code", "status": "completed", "activeForm": "Reading"],
                ["content": "Fix bug", "status": "completed", "activeForm": "Fixing"],
            ]]]]),
        ])
        let items = Self.latestItems(events)
        #expect(items.count == 1)
        #expect(items.first?.id == "todo-a")
        #expect(items.first?.status == .completed)
        #expect(items.first?.kind == .todoList(steps: [
            TodoStep(id: "todo-0", text: "Read code", status: .completed),
            TodoStep(id: "todo-1", text: "Fix bug", status: .completed),
        ], explanation: nil))
    }

    @Test func exitPlanModeBecomesAPlanThatItsDenialDoesNotOverwrite() {
        let events = Self.mapAll([
            Self.assistant("m1", [["type": "tool_use", "id": "p1", "name": "ExitPlanMode", "input": ["plan": "# Plan\n- step"]]]),
            Self.toolResult("p1", "The client captured your proposed plan.", isError: true),
        ])
        let items = Self.latestItems(events)
        #expect(items.map(\.kind) == [.plan(markdown: "# Plan\n- step")])
        #expect(items.first?.status == .completed)
        let prompt = ClaudeEventMapper.permissionPrompt(requestID: "r", request: ["subtype": "can_use_tool", "tool_name": "ExitPlanMode", "input": ["plan": "x"]], cwd: nil)
        #expect(prompt == .exitPlan)
    }

    @Test func askUserQuestionBecomesQuestionsKeyedByTheirText() {
        let prompt = ClaudeEventMapper.permissionPrompt(requestID: "req-1", request: [
            "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "tool_use_id": "t",
            "input": ["questions": [["question": "Which database?", "header": "DB", "multiSelect": true,
                                     "options": [["label": "Postgres", "description": "Relational"], ["label": "SQLite", "description": "File"]]]]],
        ], cwd: nil)
        #expect(prompt == .question(UserInputRequest(id: "req-1", questions: [
            UserInputQuestion(id: "Which database?", header: "DB", question: "Which database?",
                              options: [UserInputOption(label: "Postgres", description: "Relational"), UserInputOption(label: "SQLite", description: "File")],
                              allowsMultiple: true, allowsOther: true),
        ])))
    }

    @Test func approvalKindsAndDetailsFollowTheTool() {
        func approval(_ tool: String, _ input: JSONValue, description: JSONValue = nil) -> ApprovalRequest? {
            let prompt = ClaudeEventMapper.permissionPrompt(requestID: "r", request: ["tool_name": .string(tool), "input": input, "description": description], cwd: "/repo")
            if case let .approval(request) = prompt { return request }
            return nil
        }
        #expect(approval("Bash", ["command": "npm test", "description": "Run tests"]).map { [$0.kind.rawValue, $0.detail, $0.reason ?? ""] } == ["command", "npm test", "Run tests"])
        #expect(approval("Edit", ["file_path": "/repo/a.swift"]).map { [$0.kind.rawValue, $0.detail] } == ["fileChange", "a.swift"])
        #expect(approval("Grep", ["pattern": "TODO", "path": "/repo/src"]).map { [$0.kind.rawValue, $0.detail] } == ["fileRead", "TODO in src"])
        #expect(approval("WebFetch", ["url": "https://example.com"]).map { [$0.kind.rawValue, $0.detail] } == ["other", "WebFetch: https://example.com"])
    }

    @Test func errorResultsFailTheTurnWithTheirMessage() {
        let events = Self.mapAll([["type": "result", "subtype": "error_during_execution", "is_error": true, "errors": ["API Error: 529 overloaded"]]])
        #expect(events == [.turnCompleted(outcome: .failed, error: "API Error: 529 overloaded")])
    }

    @Test func subagentMessagesAreIgnored() {
        let events = Self.mapAll([[
            "type": "assistant", "parent_tool_use_id": "toolu_task",
            "message": ["id": "m9", "content": [["type": "text", "text": "inner"]]],
        ]])
        #expect(events.isEmpty)
    }
}
