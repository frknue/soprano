import AppKit
import Testing
@testable import SopranoAgentsCore

struct CodexEventMapperTests {
    private static func traceLines() throws -> [JSONValue] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/codex-turn.jsonl")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try JSONValue.parse(String($0)) }
    }

    /// Replays the recorded app-server output through the mapper like `CodexSession` does.
    private static func replay() throws -> [ProviderEvent] {
        var mapper = CodexEventMapper()
        var events: [ProviderEvent] = []
        for message in try traceLines() {
            guard let method = message["method"]?.stringValue else { continue }
            let params = message["params"] ?? .null
            if let id = JSONRPCID(message["id"]) {
                if let event = mapper.serverRequest(method: method, params: params, rpcID: id) { events.append(event) }
            } else {
                events += mapper.map(method: method, params: params)
            }
        }
        return events
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

    @Test func theRecordedTurnBecomesCommentaryThenCommandThenFinalAnswer() throws {
        let items = Self.latestItems(try Self.replay())

        #expect(items.count == 3)
        #expect(items[0].kind == .assistantMessage(text: "I’ll run the command now.\n", isFinal: false))
        #expect(items[0].status == .completed)
        guard case let .command(command) = items[1].kind else {
            Issue.record("expected a command item, got \(items[1].kind)")
            return
        }
        #expect(command.command == "echo probe > p.txt")
        #expect(command.cwd == "/private/tmp/sa-codex")
        #expect(command.exitCode == 0)
        #expect(items[1].status == .completed)
        #expect(items[1].completedAt != nil)
        #expect(items[2].kind == .assistantMessage(text: "done", isFinal: true))
    }

    @Test func streamedDeltasRebuildEachMessageAndKnowWhichOneIsFinal() throws {
        var texts: [String: String] = [:]
        var finality: [String: Set<Bool>] = [:]
        for case let .assistantDelta(itemID, delta, isFinal) in try Self.replay() {
            texts[itemID, default: ""] += delta
            finality[itemID, default: []].insert(isFinal)
        }
        #expect(texts["msg_0d8d914e91ae5b11016ae484da9e288191b24ddf5ae55ea614"] == "I’ll run the command now.\n")
        #expect(texts["msg_0d8d914e91ae5b11016ae484dd64f081919284a1e6c59dd1d4"] == "done")
        #expect(finality["msg_0d8d914e91ae5b11016ae484da9e288191b24ddf5ae55ea614"] == [false])
        #expect(finality["msg_0d8d914e91ae5b11016ae484dd64f081919284a1e6c59dd1d4"] == [true])
    }

    @Test func theCommandApprovalShowsTheUnwrappedCommandWithAnIdDistinctFromTheItem() throws {
        let approvals = try Self.replay().compactMap { event -> ApprovalRequest? in
            if case let .approvalRequested(request) = event { return request }
            return nil
        }
        #expect(approvals == [ApprovalRequest(id: "approval:exec-970daeb1-f687-47e3-bf75-b24960b46c57", kind: .command, detail: "echo probe > p.txt")])
    }

    @Test func theTurnStartsWithItsIdReportsContextUsageAndCompletes() throws {
        let events = try Self.replay()
        #expect(events.first == .turnStarted(providerTurnID: "01a18ca6-e733-70a3-9bb4-8a07a273e4e3"))
        let usage = events.compactMap { event -> TokenUsage? in
            if case let .tokenUsage(usage) = event { return usage }
            return nil
        }
        #expect(usage.last == TokenUsage(usedTokens: 25740, contextWindow: 475000))
        #expect(events.last == .turnCompleted(outcome: .completed, error: nil))
    }

    /// `codex-skills-compact.jsonl`: after `thread/compact/start`, Codex 0.166 runs the
    /// compaction as a turn of its own.
    @Test func aCompactionRunsAsATurnWithANoticeAndTheNewContextFill() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/codex-skills-compact.jsonl")
        var mapper = CodexEventMapper()
        let events = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try JSONValue.parse(String($0)) }.flatMap { message -> [ProviderEvent] in
            guard let method = message["method"]?.stringValue, message["id"] == nil else { return [] }
            return mapper.map(method: method, params: message["params"] ?? .null)
        }

        #expect(events.count == 4)
        #expect(events.first == .turnStarted(providerTurnID: "01a18ef4-ecfb-72b0-8bc7-2e5915d39ffa"))
        #expect(Self.latestItems(events).map(\.kind) == [.notice(text: "Context compacted")])
        #expect(events.contains(.tokenUsage(TokenUsage(usedTokens: 29_619, contextWindow: 475_000))))
        #expect(events.last == .turnCompleted(outcome: .completed, error: nil))
    }

    @Test func commandOutputStreamedBeforeACompletionWithoutAggregatedOutputIsKept() {
        var mapper = CodexEventMapper()
        _ = mapper.map(method: "item/commandExecution/outputDelta", params: ["itemId": "c1", "delta": "line 1\n"])
        _ = mapper.map(method: "item/commandExecution/outputDelta", params: ["itemId": "c1", "delta": "line 2\n"])
        let events = mapper.map(method: "item/completed", params: ["item": [
            "type": "commandExecution", "id": "c1", "command": "make", "cwd": "/repo", "status": "failed",
            "aggregatedOutput": nil, "exitCode": 2, "durationMs": 40,
        ]])
        guard case let .itemUpdated(item)? = events.first, case let .command(command) = item.kind else {
            Issue.record("expected a command item")
            return
        }
        #expect(command.output == "line 1\nline 2\n")
        #expect(command.exitCode == 2)
        #expect(item.status == .failed)
    }

    @Test func fileChangeApprovalsNameTheFilesOfTheirItem() {
        var mapper = CodexEventMapper()
        _ = mapper.map(method: "item/started", params: ["item": [
            "type": "fileChange", "id": "patch-1", "status": "inProgress",
            "changes": [
                ["path": "Sources/App.swift", "kind": ["type": "update", "move_path": nil], "diff": "@@ -1 +1 @@\n-a\n+b"],
                ["path": "README.md", "kind": ["type": "add"], "diff": "+hi"],
            ],
        ]])
        let event = mapper.serverRequest(method: "item/fileChange/requestApproval", params: ["itemId": "patch-1", "turnId": "t"], rpcID: .string("req-7"))
        guard case let .approvalRequested(request)? = event else {
            Issue.record("expected an approval")
            return
        }
        #expect(request.kind == .fileChange)
        #expect(request.detail == "Sources/App.swift, README.md")
        #expect(request.id == "approval:patch-1")
    }

    @Test func planUpdatesBecomeOneTodoListPerTurn() {
        var mapper = CodexEventMapper()
        let events = mapper.map(method: "turn/plan/updated", params: [
            "turnId": "t1", "explanation": "Two steps",
            "plan": [["step": "Read code", "status": "completed"], ["step": "Fix bug", "status": "inProgress"]],
        ])
        guard case let .itemUpdated(item)? = events.first, events.count == 1 else {
            Issue.record("expected one todo item, got \(events)")
            return
        }
        #expect(item.id == "turn-plan:t1")
        #expect(item.status == .running)
        #expect(item.kind == .todoList(
            steps: [TodoStep(id: "step-0", text: "Read code", status: .completed), TodoStep(id: "step-1", text: "Fix bug", status: .inProgress)],
            explanation: "Two steps"
        ))
    }

    @Test func userInputRequestsKeepQuestionIdsOptionsAndTheOtherFlag() {
        var mapper = CodexEventMapper()
        let event = mapper.serverRequest(method: "item/tool/requestUserInput", params: [
            "itemId": "ask-1", "turnId": "t",
            "questions": [["id": "db", "header": "Database", "question": "Which one?", "isOther": true, "isSecret": false,
                           "options": [["label": "Postgres", "description": "Relational"], ["label": "SQLite", "description": ""]]]],
        ], rpcID: .number(3))
        #expect(event == .userInputRequested(UserInputRequest(id: "input:ask-1", questions: [
            UserInputQuestion(id: "db", header: "Database", question: "Which one?",
                              options: [UserInputOption(label: "Postgres", description: "Relational"), UserInputOption(label: "SQLite")],
                              allowsMultiple: false, allowsOther: true),
        ])))
    }

    @Test func unknownServerRequestsAreNotMapped() {
        var mapper = CodexEventMapper()
        #expect(mapper.serverRequest(method: "attestation/generate", params: [:], rpcID: .number(1)) == nil)
    }

    @Test func interruptedAndFailedTurnsCarryTheirOutcomeAndError() {
        var mapper = CodexEventMapper()
        #expect(mapper.map(method: "turn/completed", params: ["turn": ["id": "t", "status": "interrupted", "error": nil]]) == [.turnCompleted(outcome: .interrupted, error: nil)])
        #expect(mapper.map(method: "turn/completed", params: ["turn": ["id": "t", "status": "failed", "error": ["message": "Usage limit reached"]]]) == [.turnCompleted(outcome: .failed, error: "Usage limit reached")])
    }

    @Test func shellWrappersAreUnwrappedButPlainCommandsAreKept() {
        #expect(CodexEventMapper.displayCommand("/bin/zsh -lc 'echo probe > p.txt'") == "echo probe > p.txt")
        #expect(CodexEventMapper.displayCommand("/bin/bash -lc 'echo it'\\''s'") == "echo it's")
        #expect(CodexEventMapper.displayCommand("bash -c \"grep \\\"x\\\" a\"") == "grep \"x\" a")
        #expect(CodexEventMapper.displayCommand("git status") == "git status")
        #expect(CodexEventMapper.displayCommand("/bin/zsh -lc 'a' 'b'") == "'a' 'b'")
    }
}
