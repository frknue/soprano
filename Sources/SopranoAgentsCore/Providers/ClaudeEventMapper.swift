import Foundation

/// How a `can_use_tool` control request is presented.
public enum ClaudePermissionPrompt: Sendable, Hashable {
    case approval(ApprovalRequest)
    /// `AskUserQuestion`: answered with `ClaudeProtocol.questionResult`.
    case question(UserInputRequest)
    /// `ExitPlanMode`: the plan item comes from the `tool_use` block; deny right away.
    case exitPlan
}

/// Translates Claude Code stream-json lines into `ProviderEvent`s.
///
/// No I/O. State: the session id and cwd from `system/init`, a block counter per message id
/// (the CLI emits one `assistant` line per content block, in order, so the n-th block of a
/// message is stream index n), tool inputs by `tool_use` id (results only carry the id), the
/// turn's last text block (marked final when `result` arrives) and the turn's todo item.
///
/// - `system/init` → `conversationID` (when it changes); `system/compact_boundary` → notice.
/// - `stream_event` `text_delta` / `thinking_delta` → deltas on item `<message id>:<index>`.
/// - `assistant` text / thinking / `tool_use` blocks → items (same ids as the deltas; tool
///   items use the `tool_use` id). Bash → command; Edit/MultiEdit/Write/NotebookEdit → file
///   change; Read/Glob/Grep/LS → read/search tool call; WebFetch/WebSearch → web search;
///   TodoWrite → todo list; Task/Agent → subagent; `mcp__server__tool` → MCP; ExitPlanMode →
///   plan; AskUserQuestion → none (it becomes a user-input request); others → tool call.
/// - `user` `tool_result` → the tool item completed with its output (`is_error` → failed, or
///   declined when the user denied it).
/// - `result` → token usage, the last text marked final, `turnCompleted` (`success` →
///   completed, otherwise failed with the result text).
/// - Messages of subagents (`parent_tool_use_id` set), `rate_limit_event` and control
///   messages produce nothing.
public struct ClaudeEventMapper: Sendable {
    private struct ToolUse: Sendable {
        var name: String
        var input: JSONValue
        var startedAt: Date
    }

    public private(set) var sessionID: String?
    public private(set) var cwd: String?
    /// `uuid` of the last top-level `assistant` line (the `--resume-session-at` anchor).
    public private(set) var lastAssistantUUID: String?
    private var blockCounts: [String: Int] = [:]
    private var streamMessageID: String?
    private var tools: [String: ToolUse] = [:]
    private var declinedTools: Set<String> = []
    private var lastText: TurnItem?
    private var todoItemID: String?
    private var lastUsage: JSONValue?

    /// `sessionID`: the id the session already announced (no second `conversationID`).
    public init(cwd: String? = nil, sessionID: String? = nil) {
        self.cwd = cwd
        self.sessionID = sessionID
    }

    /// The user denied this tool; its error result becomes `declined`.
    public mutating func markDeclined(toolUseID: String) {
        declinedTools.insert(toolUseID)
    }

    /// After a rollback: the conversation now ends at `assistantUUID`.
    public mutating func rewound(to assistantUUID: String?) {
        lastAssistantUUID = assistantUUID
        resetTurn()
    }

    public mutating func map(_ message: JSONValue) -> [ProviderEvent] {
        switch message["type"]?.stringValue {
        case "system":
            return mapSystem(message)
        case "stream_event":
            guard isTopLevel(message) else { return [] }
            return mapStreamEvent(message)
        case "assistant":
            guard isTopLevel(message) else { return [] }
            return mapAssistant(message)
        case "user":
            guard isTopLevel(message) else { return [] }
            return mapToolResults(message)
        case "result":
            return mapResult(message)
        default:
            return []
        }
    }

    // MARK: - Messages

    private mutating func mapSystem(_ message: JSONValue) -> [ProviderEvent] {
        switch message["subtype"]?.stringValue {
        case "init":
            if let cwd = message["cwd"]?.nonEmptyString { self.cwd = cwd }
            guard let id = message["session_id"]?.nonEmptyString, id != sessionID else { return [] }
            sessionID = id
            return [.conversationID(id)]
        case "compact_boundary":
            let id = message["uuid"]?.stringValue ?? "compact:\(UUID().uuidString)"
            return [.itemUpdated(TurnItem(id: id, kind: .notice(text: "Context compacted"), status: .completed, completedAt: Date()))]
        default:
            return []
        }
    }

    private mutating func mapStreamEvent(_ message: JSONValue) -> [ProviderEvent] {
        guard let event = message["event"] else { return [] }
        if event["type"]?.stringValue == "message_start", let id = event["message"]?["id"]?.stringValue {
            streamMessageID = id
        }
        guard event["type"]?.stringValue == "content_block_delta",
              let messageID = message["api_message_id"]?.stringValue ?? streamMessageID,
              let index = event["index"]?.intValue,
              let delta = event["delta"] else { return [] }
        let itemID = "\(messageID):\(index)"
        switch delta["type"]?.stringValue {
        case "text_delta":
            guard let text = delta["text"]?.stringValue, !text.isEmpty else { return [] }
            return [.assistantDelta(itemID: itemID, delta: text, isFinal: false)]
        case "thinking_delta":
            guard let text = delta["thinking"]?.stringValue, !text.isEmpty else { return [] }
            return [.reasoningDelta(itemID: itemID, delta: text)]
        default:
            return []
        }
    }

    private mutating func mapAssistant(_ message: JSONValue) -> [ProviderEvent] {
        guard let body = message["message"], let messageID = body["id"]?.stringValue else { return [] }
        if let uuid = message["uuid"]?.stringValue { lastAssistantUUID = uuid }
        if let usage = body["usage"], !usage.isNull { lastUsage = usage }
        var events: [ProviderEvent] = []
        for block in body["content"]?.arrayValue ?? [] {
            let index = blockCounts[messageID, default: 0]
            blockCounts[messageID] = index + 1
            let itemID = "\(messageID):\(index)"
            switch block["type"]?.stringValue {
            case "text":
                let text = block["text"]?.stringValue ?? ""
                guard !text.isEmpty else { continue }
                let item = TurnItem(id: itemID, kind: .assistantMessage(text: text, isFinal: false), status: .completed, completedAt: Date())
                lastText = item
                events.append(.itemUpdated(item))
            case "thinking":
                guard let text = block["thinking"]?.nonEmptyString else { continue }
                events.append(.itemUpdated(TurnItem(id: itemID, kind: .reasoning(text: text), status: .completed, completedAt: Date())))
            case "tool_use":
                guard let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else { continue }
                let input = block["input"] ?? [:]
                let tool = ToolUse(name: name, input: input, startedAt: Date())
                tools[id] = tool
                if let item = toolItem(id: id, tool: tool, status: .running, output: nil, result: nil) {
                    events.append(.itemUpdated(item))
                }
            default:
                continue
            }
        }
        return events
    }

    private mutating func mapToolResults(_ message: JSONValue) -> [ProviderEvent] {
        guard let content = message["message"]?["content"]?.arrayValue else { return [] }
        var events: [ProviderEvent] = []
        for block in content where block["type"]?.stringValue == "tool_result" {
            guard let id = block["tool_use_id"]?.stringValue, let tool = tools[id] else { continue }
            if ["ExitPlanMode", "AskUserQuestion", "TodoWrite"].contains(tool.name) { continue }
            let isError = block["is_error"]?.boolValue == true
            let status: TurnItemStatus = isError ? (declinedTools.contains(id) ? .declined : .failed) : .completed
            let output = Self.resultText(block["content"])
            if let item = toolItem(id: id, tool: tool, status: status, output: output, result: message["tool_use_result"]) {
                events.append(.itemUpdated(item))
            }
        }
        return events
    }

    private mutating func mapResult(_ message: JSONValue) -> [ProviderEvent] {
        var events: [ProviderEvent] = []
        if let usage = lastUsage {
            let used = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
                .compactMap { usage[$0]?.intValue }.reduce(0, +)
            let window = message["modelUsage"]?.objectValue?.values.compactMap { $0["contextWindow"]?.intValue }.max()
            if used > 0 { events.append(.tokenUsage(TokenUsage(usedTokens: used, contextWindow: window))) }
        }
        if var final = lastText, case let .assistantMessage(text, _) = final.kind {
            final.kind = .assistantMessage(text: text, isFinal: true)
            events.append(.itemUpdated(final))
        }
        let succeeded = message["subtype"]?.stringValue == "success" && message["is_error"]?.boolValue != true
        if Self.isAbortedResult(message) {
            events.append(.turnCompleted(outcome: .interrupted, error: nil))
        } else if succeeded {
            events.append(.turnCompleted(outcome: .completed, error: nil))
        } else {
            let errors = (message["errors"]?.arrayValue ?? []).compactMap(\.stringValue)
            let text = message["result"]?.nonEmptyString ?? (errors.isEmpty ? nil : errors.joined(separator: "\n"))
            events.append(.turnCompleted(outcome: .failed, error: text ?? "Claude Code ended the turn with \(message["subtype"]?.stringValue ?? "an error")."))
        }
        resetTurn()
        return events
    }

    /// A `result` for a request Claude Code abandoned (`terminal_reason` `aborted_tools` /
    /// `aborted_streaming`), which it reports even with subtype `success`.
    static func isAbortedResult(_ message: JSONValue) -> Bool {
        let reason = message["terminal_reason"]?.stringValue
        return reason == "aborted_tools" || reason == "aborted_streaming"
    }

    private mutating func resetTurn() {
        lastText = nil
        todoItemID = nil
        lastUsage = nil
        blockCounts.removeAll()
        tools.removeAll()
        declinedTools.removeAll()
    }

    // MARK: - Tools

    private mutating func toolItem(id: String, tool: ToolUse, status: TurnItemStatus, output: String?, result: JSONValue?) -> TurnItem? {
        let input = tool.input
        let completedAt: Date? = status.isActive ? nil : Date()
        func item(_ kind: TurnItemKind, id itemID: String = id, status itemStatus: TurnItemStatus = status) -> TurnItem {
            TurnItem(id: itemID, kind: kind, status: itemStatus, startedAt: tool.startedAt, completedAt: itemStatus.isActive ? nil : completedAt ?? Date())
        }
        let path = input["file_path"]?.stringValue ?? input["notebook_path"]?.stringValue ?? input["path"]?.stringValue

        switch tool.name {
        case "Bash":
            return item(.command(CommandExecution(command: input["command"]?.stringValue ?? "", output: output ?? "")))
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            guard let path else { return nil }
            let created = result?["type"]?.stringValue == "create"
            let kind: FileChange.Kind = created ? .add : .update
            var diff = (result?["structuredPatch"]?.arrayValue).flatMap(Self.diff(fromStructuredPatch:))
            if diff == nil, tool.name == "Write", let content = input["content"]?.stringValue, created || result == nil {
                diff = Self.creationDiff(content)
            }
            return item(.fileChange([FileChange(path: relative(path), kind: kind, diff: diff)]))
        case "Read":
            return item(.toolCall(ToolCall(name: tool.name, category: .read, title: "Read \(relative(path ?? ""))", input: Self.inputText(input), output: output)))
        case "Grep", "Glob":
            let pattern = input["pattern"]?.stringValue ?? ""
            var title = tool.name == "Grep" ? "Searched \"\(pattern)\"" : "Searched files \"\(pattern)\""
            if let path, !path.isEmpty { title += " in \(relative(path))" }
            return item(.toolCall(ToolCall(name: tool.name, category: .search, title: title, input: Self.inputText(input), output: output)))
        case "LS":
            return item(.toolCall(ToolCall(name: tool.name, category: .search, title: "Listed \(relative(path ?? "."))", input: Self.inputText(input), output: output)))
        case "WebFetch":
            return item(.webSearch(query: input["url"]?.stringValue ?? ""))
        case "WebSearch":
            return item(.webSearch(query: input["query"]?.stringValue ?? ""))
        case "TodoWrite":
            let steps = (input["todos"]?.arrayValue ?? []).enumerated().compactMap { index, todo -> TodoStep? in
                guard let text = todo["content"]?.nonEmptyString else { return nil }
                let status: TodoStep.Status = switch todo["status"]?.stringValue {
                case "completed": .completed
                case "in_progress": .inProgress
                default: .pending
                }
                return TodoStep(id: "todo-\(index)", text: text, status: status)
            }
            let itemID = todoItemID ?? id
            todoItemID = itemID
            let done = !steps.isEmpty && steps.allSatisfy { $0.status == .completed }
            return item(.todoList(steps: steps, explanation: nil), id: itemID, status: done ? .completed : .running)
        case "Task", "Agent":
            let title = input["description"]?.nonEmptyString.map { "Subagent: \($0)" } ?? "Subagent"
            return item(.toolCall(ToolCall(name: tool.name, category: .subagent, title: title, input: input["prompt"]?.stringValue, output: output)))
        case "ExitPlanMode":
            return item(.plan(markdown: input["plan"]?.stringValue ?? ""), status: .completed)
        case "AskUserQuestion":
            return nil
        default:
            if tool.name.hasPrefix("mcp__") {
                let parts = tool.name.dropFirst(5).components(separatedBy: "__")
                let server = parts.first ?? "mcp"
                let name = parts.dropFirst().joined(separator: "__")
                return item(.toolCall(ToolCall(name: "\(server).\(name)", category: .mcp, title: "\(server): \(name)", input: Self.inputText(input), output: output)))
            }
            return item(.toolCall(ToolCall(name: tool.name, category: .other, title: tool.name, input: Self.inputText(input), output: output)))
        }
    }

    private func relative(_ path: String) -> String {
        Self.relative(path, to: cwd)
    }

    // MARK: - Permission prompts

    /// Classifies a `can_use_tool` request (`{"subtype":"can_use_tool","tool_name","input",
    /// "permission_suggestions","tool_use_id","description"?, "decision_reason"?}`). Approval kind
    /// by tool: Bash → command; Edit/Write/MultiEdit/NotebookEdit → file change;
    /// Read/Glob/Grep → file read; else other. Detail: the command, the file path (relative to
    /// `cwd`), the search pattern, the URL, else the CLI's description or the tool name.
    public static func permissionPrompt(requestID: String, request: JSONValue, cwd: String?) -> ClaudePermissionPrompt {
        let toolName = request["tool_name"]?.stringValue ?? "Tool"
        let input = request["input"] ?? [:]
        switch toolName {
        case "ExitPlanMode":
            return .exitPlan
        case "AskUserQuestion":
            let questions = (input["questions"]?.arrayValue ?? []).compactMap { question -> UserInputQuestion? in
                guard let text = question["question"]?.nonEmptyString else { return nil }
                let options = (question["options"]?.arrayValue ?? []).compactMap { option -> UserInputOption? in
                    option["label"]?.nonEmptyString.map { UserInputOption(label: $0, description: option["description"]?.nonEmptyString) }
                }
                return UserInputQuestion(
                    id: text,
                    header: question["header"]?.stringValue ?? "",
                    question: text,
                    options: options,
                    allowsMultiple: question["multiSelect"]?.boolValue ?? false,
                    allowsOther: true
                )
            }
            return .question(UserInputRequest(id: requestID, questions: questions))
        default:
            let kind: ApprovalKind = switch toolName {
            case "Bash": .command
            case "Edit", "Write", "MultiEdit", "NotebookEdit": .fileChange
            case "Read", "Glob", "Grep", "LS": .fileRead
            default: .other
            }
            let path = input["file_path"]?.nonEmptyString ?? input["notebook_path"]?.nonEmptyString
            let description = request["description"]?.nonEmptyString
            var detail: String
            if let command = input["command"]?.nonEmptyString {
                detail = command
            } else if let path {
                detail = relative(path, to: cwd)
            } else if let pattern = input["pattern"]?.nonEmptyString {
                detail = pattern
                if let searchPath = input["path"]?.nonEmptyString { detail += " in \(relative(searchPath, to: cwd))" }
            } else if let url = input["url"]?.nonEmptyString {
                detail = url
            } else {
                detail = description ?? toolName
            }
            if kind == .other, detail != toolName { detail = "\(toolName): \(detail)" }
            let reason = request["decision_reason"]?.nonEmptyString ?? (toolName == "Bash" ? input["description"]?.nonEmptyString : nil)
            return .approval(ApprovalRequest(id: requestID, kind: kind, detail: detail, reason: reason))
        }
    }

    // MARK: - Helpers

    private func isTopLevel(_ message: JSONValue) -> Bool {
        message["parent_tool_use_id"].map(\.isNull) ?? true
    }

    /// `path` relative to `cwd` when inside it (`/tmp` and `/private/tmp` treated alike).
    static func relative(_ path: String, to cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return path }
        let bases = cwd.hasPrefix("/private/") ? [cwd, String(cwd.dropFirst("/private".count))] : [cwd, "/private" + cwd]
        for base in bases {
            if path == base { return "." }
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return path
    }

    static func resultText(_ content: JSONValue?) -> String? {
        switch content {
        case let .string(text)?: return text
        case let .array(blocks)?:
            let texts = blocks.compactMap { $0["text"]?.stringValue }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        default: return nil
        }
    }

    static func inputText(_ input: JSONValue) -> String? {
        if case let .object(object) = input, object.isEmpty { return nil }
        return input.prettyJSONString()
    }

    /// Claude's `structuredPatch` hunks → unified diff hunks (`@@ -a,b +c,d @@` + lines).
    static func diff(fromStructuredPatch hunks: [JSONValue]) -> String? {
        let parts = hunks.compactMap { hunk -> String? in
            guard let lines = hunk["lines"]?.arrayValue?.compactMap(\.stringValue) else { return nil }
            let header = "@@ -\(hunk["oldStart"]?.intValue ?? 0),\(hunk["oldLines"]?.intValue ?? 0) +\(hunk["newStart"]?.intValue ?? 0),\(hunk["newLines"]?.intValue ?? 0) @@"
            return ([header] + lines).joined(separator: "\n")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// A new file's content as one all-added hunk.
    static func creationDiff(_ content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return (["@@ -0,0 +1,\(lines.count) @@"] + lines.map { "+" + $0 }).joined(separator: "\n")
    }
}
