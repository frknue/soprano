import Foundation

/// Translates `codex app-server` notifications and server requests into `ProviderEvent`s.
///
/// No I/O; the only state is what later messages need from earlier ones: agent-message phases
/// (deltas carry no phase), streamed command output (completed items may omit
/// `aggregatedOutput`), file-change paths (file approvals carry only the item id) and a counter
/// for error item ids.
///
/// `ThreadItem` mapping: `userMessage`/`hookPrompt` ignored; `agentMessage` → assistant message
/// (`phase:"final_answer"` = final); `reasoning` → reasoning (summary parts joined by a blank
/// line, empty ones skipped); `commandExecution` → command (shell wrapper `/bin/zsh -lc '…'`
/// unwrapped); `fileChange` → file change; `mcpToolCall` → MCP tool call; `dynamicToolCall` →
/// tool call; `collabAgentToolCall` → subagent tool call; `webSearch` → web search; `plan` →
/// plan; `contextCompaction` → "Context compacted" notice. `turn/plan/updated` becomes the todo
/// list item `turn-plan:<turnId>`.
public struct CodexEventMapper: Sendable {
    private var finalMessageIDs: Set<String> = []
    private var commandOutput: [String: String] = [:]
    private var fileChangePaths: [String: [String]] = [:]
    private var errorCount = 0

    public init() {}

    // MARK: - Notifications

    public mutating func map(method: String, params: JSONValue) -> [ProviderEvent] {
        switch method {
        case "turn/started":
            return [.turnStarted(providerTurnID: params["turn"]?["id"]?.stringValue)]
        case "item/started", "item/completed":
            guard let item = params["item"] else { return [] }
            return mapItem(item, completed: method == "item/completed").map { [.itemUpdated($0)] } ?? []
        case "item/agentMessage/delta":
            guard let itemID = params["itemId"]?.stringValue, let delta = params["delta"]?.stringValue else { return [] }
            return [.assistantDelta(itemID: itemID, delta: delta, isFinal: finalMessageIDs.contains(itemID))]
        case "item/reasoning/summaryTextDelta":
            guard let itemID = params["itemId"]?.stringValue, let delta = params["delta"]?.stringValue else { return [] }
            return [.reasoningDelta(itemID: itemID, delta: delta)]
        case "item/reasoning/summaryPartAdded":
            guard let itemID = params["itemId"]?.stringValue, (params["summaryIndex"]?.intValue ?? 0) > 0 else { return [] }
            return [.reasoningDelta(itemID: itemID, delta: "\n\n")]
        case "item/commandExecution/outputDelta":
            guard let itemID = params["itemId"]?.stringValue, let delta = params["delta"]?.stringValue else { return [] }
            commandOutput[itemID, default: ""] += delta
            return [.commandOutputDelta(itemID: itemID, delta: delta)]
        case "item/plan/delta":
            guard let itemID = params["itemId"]?.stringValue, let delta = params["delta"]?.stringValue else { return [] }
            return [.planDelta(itemID: itemID, delta: delta)]
        case "turn/plan/updated":
            return mapPlanUpdate(params).map { [.itemUpdated($0)] } ?? []
        case "thread/tokenUsage/updated":
            guard let usage = params["tokenUsage"], let used = usage["last"]?["totalTokens"]?.intValue else { return [] }
            return [.tokenUsage(TokenUsage(usedTokens: used, contextWindow: usage["modelContextWindow"]?.intValue))]
        case "error":
            // Retried errors are transient ("Reconnecting…"); the turn goes on.
            guard params["willRetry"]?.boolValue != true,
                  let message = params["error"]?["message"]?.nonEmptyString else { return [] }
            errorCount += 1
            let turnID = params["turnId"]?.stringValue ?? "thread"
            return [.itemUpdated(TurnItem(id: "error:\(turnID):\(errorCount)", kind: .error(message: message), status: .failed, completedAt: Date()))]
        case "turn/completed":
            let turn = params["turn"]
            let outcome: ProviderTurnOutcome = switch turn?["status"]?.stringValue {
            case "interrupted": .interrupted
            case "failed": .failed
            default: .completed
            }
            commandOutput.removeAll()
            return [.turnCompleted(outcome: outcome, error: turn?["error"]?["message"]?.nonEmptyString)]
        default:
            return []
        }
    }

    // MARK: - Server requests

    /// The event for a server request, or nil when the method is unsupported (answer with a
    /// JSON-RPC error). Approval ids are `approval:<approvalId ?? itemId>` and user-input ids
    /// `input:<itemId>`, so they never collide with the item they gate; `rpcID` is the fallback.
    public mutating func serverRequest(method: String, params: JSONValue, rpcID: JSONRPCID) -> ProviderEvent? {
        let itemID = params["itemId"]?.stringValue
        let approvalID = "approval:" + (params["approvalId"]?.nonEmptyString ?? itemID ?? "rpc-\(rpcID)")
        let reason = params["reason"]?.nonEmptyString
        switch method {
        case "item/commandExecution/requestApproval":
            let command = params["command"]?.nonEmptyString.map(Self.displayCommand)
            return .approvalRequested(ApprovalRequest(id: approvalID, kind: .command, detail: command ?? reason ?? "Run a command", reason: command == nil ? nil : reason))
        case "item/fileChange/requestApproval":
            let paths = itemID.flatMap { fileChangePaths[$0] } ?? []
            let detail = paths.isEmpty ? (params["grantRoot"]?.nonEmptyString ?? reason ?? "Apply file changes") : paths.joined(separator: ", ")
            return .approvalRequested(ApprovalRequest(id: approvalID, kind: .fileChange, detail: detail, reason: paths.isEmpty && params["grantRoot"] == nil ? nil : reason))
        case "item/permissions/requestApproval":
            let permissions = params["permissions"] ?? .null
            let writes = permissions["fileSystem"]?["write"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let reads = permissions["fileSystem"]?["read"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let kind: ApprovalKind = !writes.isEmpty ? .fileChange : (!reads.isEmpty ? .fileRead : .permission)
            let paths = writes.isEmpty ? reads : writes
            let detail = paths.isEmpty ? (reason ?? "Grant additional permissions") : paths.joined(separator: ", ")
            return .approvalRequested(ApprovalRequest(
                id: approvalID, kind: kind, detail: detail, reason: paths.isEmpty ? nil : reason,
                options: [.decline, .acceptForSession, .accept]
            ))
        case "item/tool/requestUserInput":
            let questions = (params["questions"]?.arrayValue ?? []).compactMap { question -> UserInputQuestion? in
                guard let id = question["id"]?.stringValue else { return nil }
                let options = (question["options"]?.arrayValue ?? []).compactMap { option -> UserInputOption? in
                    option["label"]?.stringValue.map { UserInputOption(label: $0, description: option["description"]?.nonEmptyString) }
                }
                return UserInputQuestion(
                    id: id,
                    header: question["header"]?.stringValue ?? "",
                    question: question["question"]?.stringValue ?? "",
                    options: options,
                    allowsMultiple: false,
                    allowsOther: question["isOther"]?.boolValue ?? options.isEmpty
                )
            }
            return .userInputRequested(UserInputRequest(id: "input:" + (itemID ?? "rpc-\(rpcID)"), questions: questions))
        default:
            return nil
        }
    }

    // MARK: - Items

    mutating func mapItem(_ item: JSONValue, completed: Bool) -> TurnItem? {
        guard let id = item["id"]?.stringValue, let type = item["type"]?.stringValue else { return nil }
        let startedAt = Self.date(item["startedAtMs"]) ?? Date()
        let completedAt = completed ? (Self.date(item["completedAtMs"]) ?? Date()) : nil
        func make(_ kind: TurnItemKind, _ status: TurnItemStatus) -> TurnItem {
            TurnItem(id: id, kind: kind, status: status, startedAt: startedAt, completedAt: status.isActive ? nil : completedAt)
        }
        let lifecycle: TurnItemStatus = completed ? .completed : .running

        switch type {
        case "agentMessage":
            let isFinal = item["phase"]?.stringValue == "final_answer"
            if isFinal { finalMessageIDs.insert(id) }
            return make(.assistantMessage(text: item["text"]?.stringValue ?? "", isFinal: isFinal), lifecycle)
        case "reasoning":
            let parts = (item["summary"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty }
            guard !parts.isEmpty else { return nil }
            return make(.reasoning(text: parts.joined(separator: "\n\n")), lifecycle)
        case "commandExecution":
            let streamed = commandOutput[id]
            if completed { commandOutput[id] = nil }
            let command = CommandExecution(
                command: Self.displayCommand(item["command"]?.stringValue ?? ""),
                cwd: item["cwd"]?.stringValue,
                output: item["aggregatedOutput"]?.stringValue ?? streamed ?? "",
                exitCode: item["exitCode"]?.intValue,
                durationMs: item["durationMs"]?.intValue
            )
            return make(.command(command), Self.status(item["status"]?.stringValue, completed: completed))
        case "fileChange":
            let changes = (item["changes"]?.arrayValue ?? []).compactMap(Self.fileChange)
            fileChangePaths[id] = changes.map(\.path)
            return make(.fileChange(changes), Self.status(item["status"]?.stringValue, completed: completed))
        case "mcpToolCall":
            let server = item["server"]?.stringValue ?? "mcp"
            let tool = item["tool"]?.stringValue ?? "tool"
            let output = item["error"]?["message"]?.stringValue ?? Self.mcpResultText(item["result"])
            let call = ToolCall(name: "\(server).\(tool)", category: .mcp, title: "\(server): \(tool)", input: Self.inputText(item["arguments"]), output: output)
            return make(.toolCall(call), Self.status(item["status"]?.stringValue, completed: completed))
        case "dynamicToolCall":
            let tool = item["tool"]?.stringValue ?? "tool"
            let name = item["namespace"]?.nonEmptyString.map { "\($0).\(tool)" } ?? tool
            let output = (item["contentItems"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            var status = Self.status(item["status"]?.stringValue, completed: completed)
            if item["success"]?.boolValue == false { status = .failed }
            let call = ToolCall(name: name, category: .other, title: name, input: Self.inputText(item["arguments"]), output: output.isEmpty ? nil : output)
            return make(.toolCall(call), status)
        case "collabAgentToolCall":
            let tool = item["tool"]?.stringValue ?? "agent"
            let prompt = item["prompt"]?.nonEmptyString
            let title = prompt.map { "Subagent: " + ($0.split(whereSeparator: \.isNewline).first.map(String.init) ?? $0) } ?? "Subagent \(tool)"
            let call = ToolCall(name: tool, category: .subagent, title: title, input: prompt)
            return make(.toolCall(call), Self.status(item["status"]?.stringValue, completed: completed))
        case "webSearch":
            let action = item["action"]
            let query = item["query"]?.nonEmptyString ?? action?["query"]?.nonEmptyString ?? action?["url"]?.nonEmptyString ?? ""
            return make(.webSearch(query: query), lifecycle)
        case "plan":
            return make(.plan(markdown: item["text"]?.stringValue ?? ""), lifecycle)
        case "contextCompaction":
            guard completed else { return nil }
            return make(.notice(text: "Context compacted"), .completed)
        default:
            return nil
        }
    }

    private func mapPlanUpdate(_ params: JSONValue) -> TurnItem? {
        guard let turnID = params["turnId"]?.stringValue else { return nil }
        let steps = (params["plan"]?.arrayValue ?? []).enumerated().compactMap { index, step -> TodoStep? in
            guard let text = step["step"]?.stringValue else { return nil }
            let status: TodoStep.Status = switch step["status"]?.stringValue {
            case "completed": .completed
            case "inProgress": .inProgress
            default: .pending
            }
            return TodoStep(id: "step-\(index)", text: text, status: status)
        }
        let done = !steps.isEmpty && steps.allSatisfy { $0.status == .completed }
        return TurnItem(
            id: "turn-plan:\(turnID)",
            kind: .todoList(steps: steps, explanation: params["explanation"]?.nonEmptyString),
            status: done ? .completed : .running,
            completedAt: done ? Date() : nil
        )
    }

    // MARK: - Helpers

    /// `/bin/zsh -lc 'echo probe > p.txt'` → `echo probe > p.txt`. Other commands unchanged.
    public static func displayCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        for shell in ["zsh", "bash", "sh"] {
            for flag in ["-lc", "-c"] {
                for prefix in ["/bin/\(shell) \(flag) ", "/usr/bin/\(shell) \(flag) ", "\(shell) \(flag) "] where trimmed.hasPrefix(prefix) {
                    return unquoteShellWord(String(trimmed.dropFirst(prefix.count)))
                }
            }
        }
        return trimmed
    }

    /// Undoes one level of POSIX single/double quoting (`'it'\''s'` → `it's`).
    static func unquoteShellWord(_ word: String) -> String {
        guard word.first == "'" || word.first == "\"" else { return word }
        var result = ""
        var quote: Character?
        var iterator = word.makeIterator()
        while let character = iterator.next() {
            switch (quote, character) {
            case (nil, "'"), (nil, "\""):
                quote = character
            case ("'", "'"), ("\"", "\""):
                quote = nil
            case ("\"", "\\"):
                if let next = iterator.next() {
                    if !"\"\\$`".contains(next) { result.append("\\") }
                    result.append(next)
                }
            case (nil, "\\"):
                if let next = iterator.next() { result.append(next) }
            case (nil, " "):
                return word // more than one word: keep the original
            default:
                result.append(character)
            }
        }
        return result
    }

    static func status(_ native: String?, completed: Bool) -> TurnItemStatus {
        switch native {
        case "completed": .completed
        case "failed": .failed
        case "declined": .declined
        case "inProgress": completed ? .completed : .running
        default: completed ? .completed : .running
        }
    }

    static func fileChange(_ change: JSONValue) -> FileChange? {
        guard let path = change["path"]?.stringValue else { return nil }
        let kindType = change["kind"]?["type"]?.stringValue
        let movePath = change["kind"]?["move_path"]?.nonEmptyString
        let kind: FileChange.Kind = switch kindType {
        case "add": .add
        case "delete": .delete
        default: movePath == nil ? .update : .move
        }
        return FileChange(path: path, kind: kind, movePath: movePath, diff: change["diff"]?.nonEmptyString)
    }

    static func mcpResultText(_ result: JSONValue?) -> String? {
        guard let result, !result.isNull else { return nil }
        let texts = (result["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
        if !texts.isEmpty { return texts.joined(separator: "\n") }
        if let structured = result["structuredContent"], !structured.isNull { return structured.prettyJSONString() }
        return nil
    }

    static func inputText(_ value: JSONValue?) -> String? {
        guard let value, !value.isNull else { return nil }
        if case let .object(object) = value, object.isEmpty { return nil }
        return value.prettyJSONString()
    }

    static func date(_ milliseconds: JSONValue?) -> Date? {
        milliseconds?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}
