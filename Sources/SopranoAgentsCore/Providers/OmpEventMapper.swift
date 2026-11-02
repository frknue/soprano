import Foundation

/// A dialog omp asks the host to render (`extension_ui_request` with `select`, `confirm`,
/// `input`, `editor` or `ask`), kept until it is answered or withdrawn.
public struct OmpUIRequest: Sendable, Hashable {
    public enum Method: String, Sendable, Hashable {
        case select
        case confirm
        case input
        case editor
        case ask
    }

    public var id: String
    public var method: Method
    public var title: String
    /// `select` labels (approval selects included).
    public var options: [String]
    /// Raw `ask` questions (`{id, question, header?, options:[{label, description?}], multi?}`).
    public var questions: [JSONValue]

    /// A `select` whose title starts with "Allow tool:" (omp's tool approval prompt).
    public var isApproval: Bool { method == .select && title.hasPrefix("Allow tool:") }

    /// The tool an approval is for ("Allow tool: write\n…" → "write").
    public var approvalTool: String? {
        guard isApproval else { return nil }
        let head = title.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return head.dropFirst("Allow tool:".count).trimmingCharacters(in: .whitespaces)
    }

    /// Parses a dialog request; nil for presentation-only methods (`notify`, `setStatus`,
    /// `setWidget`, `setTitle`, `set_editor_text`, `open_url`) and `cancel`.
    public init?(_ frame: JSONValue) {
        guard frame["type"]?.stringValue == "extension_ui_request",
              let id = frame["id"]?.stringValue,
              let method = frame["method"]?.stringValue.flatMap(Method.init(rawValue:)) else { return nil }
        self.id = id
        self.method = method
        title = frame["title"]?.stringValue ?? ""
        options = (frame["options"]?.arrayValue ?? []).compactMap(\.stringValue)
        questions = frame["questions"]?.arrayValue ?? []
    }

    /// The question id used for single-question dialogs (select/confirm/input/editor).
    public static let singleQuestionID = "answer"
}

/// Translates omp `--mode rpc-ui` frames (with `set_event_filter {messageUpdates:"delta"}`)
/// into `ProviderEvent`s.
///
/// No I/O. Item ids are `<prefix><messageId>:<contentIndex>` for text/thinking (the session
/// bumps `prefix` after each process restart, since omp numbers `msg-N` per process) and the
/// `toolCallId` for tools.
///
/// - `message_update` `text_delta` → `assistantDelta`; `thinking_delta` → `reasoningDelta`;
///   `text_end` / `thinking_end` → the completed item with omp's full `content`.
/// - `message_end` of an assistant message with `usage` → `tokenUsage` (input + output +
///   cacheRead + cacheWrite). One with `stopReason:"stop"` (no tool call) also marks its text
///   final: the run answered, though omp may still wrap up (advisor review, stop hooks) or run
///   again before `prompt_result`.
/// - `message_end` of an advisor review (`role:"custom"`, `customType:"advisor"`,
///   `details.notes[{note, severity, advisor}]`) → an `advisory` item.
/// - `tool_execution_start|update|end {toolCallId, toolName, args, intent, partialResult,
///   result{content, details}, isError}` → items: bash → command (cumulative output, exit code
///   from `details.exitCode`, else 0 on success), write/edit/apply_patch/ast_edit → file change
///   (edit `details.diff` "-N|old"/"+N|new" lines converted to a unified hunk; without one, the
///   code the arguments carry, `OmpEditPreview`), read → read tool call,
///   grep/glob/find/ast_grep → search, web_search → web search, task → subagent, todo →
///   "Updated tasks", ask → nothing (its dialog is the user-input item), others → tool call
///   titled by `intent`.
/// - `message_update` `toolcall_start|delta|end` of a write/edit/apply_patch call → the running
///   file-change item (id = the tool call id) with the code streamed so far, before omp runs it:
///   the partial argument JSON is closed (`OmpEditPreview.partialObject`) and re-read on a new line
///   (then every 1/64 of its size as it grows). A call waits until the earlier calls of its
///   message ran, so its item never lands above theirs.
/// - `extension_ui_request`: approval selects (`Allow tool: …`) → `approvalRequested`; other
///   selects, `confirm`, `input`, `editor`, `ask` → `userInputRequested`; `cancel` →
///   `requestResolved(targetId)`; `notify` → notice. Status/widget/title/editor-text are ignored.
/// - `auto_compaction_end` → "Context compacted"; `auto_retry_start` → retry notice.
/// - `manual_compaction_end` (the `compact` command or a `/compact …` prompt) → "Context
///   compacted", the skip reason ("Already compacted"), "Compaction cancelled", or an error
///   item; remembered as `compactionEnd` for the session's compaction turn.
/// - `available_commands_update` → `commands` (`OmpProtocol.commands`).
/// - `command_output` (a builtin slash command's result, e.g. `/usage`, `/session`) → one final
///   assistant message per turn, every output of the command appended (`commandOutputText`).
/// - `prompt_result` → the last assistant text marked final, then `turnCompleted`
///   (`completed`; `aborted`/`interrupted`/`cancelled` → interrupted; else failed with
///   `error.message`). With `sessionSettled:false` background work (async bash/task/eval jobs)
///   can still wake the agent, so a completed or failed outcome is held: `turnYielded` now,
///   `turnCompleted` at the following `session_settled` (or `releaseAwaitingSettlement`). A run
///   that work wakes (`agent_start`, `turn_start`, streamed text) first reports `turnResumed`
///   and streams into the same turn; its terminal `agent_end` yields again. An async job's own
///   `tool_execution_update`s (progress on the call that started it) do not resume. An aborted
///   prompt completes at once.
public struct OmpEventMapper: Sendable {
    private struct Tool: Sendable {
        var name: String
        var args: JSONValue
        var intent: String?
        var startedAt: Date
        var output: String
        var isFinished = false
    }

    public var cwd: String?
    /// Context window of the live model (`get_state` `model.contextWindow`).
    public var contextWindow: Int?
    /// Prepended to text/thinking item ids.
    public var itemPrefix: String
    private var texts: [String: String] = [:]
    private var lastText: (id: String, text: String)?
    private var tools: [String: Tool] = [:]
    private var approvalTools: [String: String] = [:]
    private var declinedTools: Set<String> = []
    /// Write/edit calls the model is still streaming, by `<messageId>:<contentIndex>`.
    private var streamingCalls: [String: StreamingCall] = [:]
    /// Every tool call of a streaming message in order (`<prefix><messageId>` → tool call ids).
    private var messageCalls: [String: [String]] = [:]

    private struct StreamingCall: Sendable {
        var toolCallID: String
        var name: String
        var messageKey: String
        var json = ""
        /// UTF-8 length of `json` (counting a String is linear).
        var bytes = 0
        /// `bytes` at the last emitted preview.
        var emittedBytes = 0

        /// Re-read the arguments on a new line or 256 more bytes while small; as they grow, only
        /// after another 1/64 of their size, so a long write costs O(n log n), not O(n²).
        func isDue(newLine: Bool) -> Bool {
            let growth = bytes - emittedBytes
            let step = bytes / 64
            return growth >= max(256, step) || (newLine && growth >= step)
        }
    }

    /// Tools whose arguments carry code (`OmpEditPreview`).
    private static let codeTools: Set<String> = ["write", "edit", "apply_patch"]
    private var noticeCount = 0
    /// How the last manual compaction ended (`manual_compaction_end`); cleared per turn.
    public private(set) var compactionEnd: CompactionEnd?
    private var commandOutputCount = 0
    /// The turn's slash-command output so far: later `command_output` frames extend it.
    private var commandOutput: (id: String, text: String)?
    /// The yielded prompt's outcome while omp waits out background work (`sessionSettled:false`).
    private var heldOutcome: (outcome: ProviderTurnOutcome, error: String?)?
    /// A run woken by background work streams while the outcome is held.
    private var isBackgroundRunActive = false

    /// Frames that only arrive while the agent runs: after a yield they mean background work
    /// woke it. (Not tool updates: an async job reports progress on its call while nothing runs.)
    private static let runFrames: Set<String> = ["agent_start", "turn_start", "message_update"]

    /// The end of a manual compaction.
    public enum CompactionEnd: Sendable, Hashable {
        /// `result` committed.
        case compacted
        /// `skipped:true`: nothing to compact (`errorMessage`, e.g. "Already compacted").
        case skipped(String)
        /// `aborted:true`.
        case cancelled
        /// Failed with `errorMessage`.
        case failed(String)

        init(_ frame: JSONValue) {
            if frame["aborted"]?.boolValue == true {
                self = .cancelled
            } else if frame["skipped"]?.boolValue == true {
                self = .skipped(frame["errorMessage"]?.nonEmptyString ?? "Nothing to compact")
            } else if frame["result"]?.objectValue != nil {
                self = .compacted
            } else {
                self = .failed(frame["errorMessage"]?.nonEmptyString ?? "omp did not compact the conversation.")
            }
        }
    }

    /// The prompt yielded but the session has not settled: the turn is still open.
    public var isAwaitingSettlement: Bool { heldOutcome != nil }

    /// The user stopped the turn while it waited for settlement: it ends now, as interrupted
    /// (`abort` does not wait for background jobs; a later `session_settled` is ignored).
    public mutating func interruptAwaitingSettlement() -> [ProviderEvent] {
        guard heldOutcome != nil else { return [] }
        return complete(.interrupted, error: nil)
    }

    /// The user moved on from the yielded turn: it ends now with its held outcome (the
    /// background work keeps running; a later `session_settled` is ignored).
    public mutating func releaseAwaitingSettlement() -> [ProviderEvent] {
        guard let held = heldOutcome else { return [] }
        return complete(held.outcome, error: held.error)
    }

    public init(cwd: String? = nil, contextWindow: Int? = nil, itemPrefix: String = "") {
        self.cwd = cwd
        self.contextWindow = contextWindow
        self.itemPrefix = itemPrefix
    }

    /// The user declined approval `requestID`: its tool's error result becomes `declined`.
    public mutating func markDeclined(requestID: String) {
        if let toolCallID = approvalTools[requestID] { declinedTools.insert(toolCallID) }
    }

    /// Forgets the turn's state (new turn, rollback, restart).
    public mutating func resetTurn() {
        texts.removeAll()
        lastText = nil
        tools.removeAll()
        approvalTools.removeAll()
        declinedTools.removeAll()
        streamingCalls.removeAll()
        messageCalls.removeAll()
        heldOutcome = nil
        isBackgroundRunActive = false
        compactionEnd = nil
        commandOutput = nil
    }

    public mutating func map(_ frame: JSONValue) -> [ProviderEvent] {
        guard heldOutcome != nil, !isBackgroundRunActive, let type = frame["type"]?.stringValue, Self.runFrames.contains(type) else {
            return mapFrame(frame)
        }
        // Background work woke the agent after the yield: the turn works again. Its answer so far
        // stays an answer (the engine's `Turn.resumedAt` tells the timeline it is no longer the
        // last word).
        isBackgroundRunActive = true
        return [.turnResumed] + mapFrame(frame)
    }

    private mutating func mapFrame(_ frame: JSONValue) -> [ProviderEvent] {
        switch frame["type"]?.stringValue {
        case "message_update":
            return mapMessageUpdate(frame)
        case "message_end":
            return mapMessageEnd(frame)
        case "tool_execution_start":
            return mapToolStart(frame)
        case "tool_execution_update":
            return mapToolUpdate(frame)
        case "tool_execution_end":
            return mapToolEnd(frame)
        case "extension_ui_request":
            return mapUIRequest(frame)
        case "auto_compaction_end":
            return [notice("Context compacted")]
        case "manual_compaction_start":
            compactionEnd = nil
            return []
        case "manual_compaction_end":
            let end = CompactionEnd(frame)
            compactionEnd = end
            switch end {
            case .compacted: return [notice("Context compacted")]
            case let .skipped(reason): return [notice(reason)]
            case .cancelled: return [notice("Compaction cancelled")]
            case let .failed(message):
                noticeCount += 1
                return [.itemUpdated(TurnItem(id: "\(itemPrefix)compaction-error:\(noticeCount)", kind: .error(message: "Compaction failed: \(message)"), status: .failed))]
            }
        case "available_commands_update":
            return [.commands(OmpProtocol.commands(frame["commands"]))]
        case "agent_end":
            // A woken run yielded: done again while omp waits out the rest of the work.
            guard let held = heldOutcome, isBackgroundRunActive, frame["isTerminal"]?.boolValue != false else { return [] }
            isBackgroundRunActive = false
            return [.turnYielded(outcome: held.outcome, error: held.error)]
        case "auto_retry_start":
            var text = "Retrying"
            if let attempt = frame["attempt"]?.intValue {
                text += " (attempt \(attempt)\(frame["maxAttempts"]?.intValue.map { " of \($0)" } ?? ""))"
            }
            if let message = frame["errorMessage"]?.nonEmptyString { text += ": \(message)" }
            return [notice(text)]
        case "command_output":
            return mapCommandOutput(frame)
        case "prompt_result":
            return mapPromptResult(frame)
        case "session_settled":
            return releaseAwaitingSettlement()
        default:
            return []
        }
    }

    /// Ends the turn as `completed` without a `prompt_result` (prompt finished locally:
    /// `agentInvoked:false`).
    public mutating func finishLocally() -> [ProviderEvent] {
        map(["type": "prompt_result", "status": "completed"])
    }

    // MARK: - Messages

    private mutating func mapMessageUpdate(_ frame: JSONValue) -> [ProviderEvent] {
        guard let event = frame["assistantMessageEvent"],
              let messageID = frame["messageId"]?.stringValue,
              let index = event["contentIndex"]?.intValue else { return [] }
        let itemID = "\(itemPrefix)\(messageID):\(index)"
        switch event["type"]?.stringValue {
        case "text_delta":
            guard let delta = event["delta"]?.stringValue, !delta.isEmpty else { return [] }
            let text = texts[itemID, default: ""] + delta
            texts[itemID] = text
            lastText = (itemID, text)
            return [.assistantDelta(itemID: itemID, delta: delta, isFinal: false)]
        case "text_end":
            let text = event["content"]?.stringValue ?? texts[itemID] ?? ""
            texts[itemID] = text
            guard !text.isEmpty else { return [] }
            lastText = (itemID, text)
            return [.itemUpdated(TurnItem(id: itemID, kind: .assistantMessage(text: text, isFinal: false), status: .completed))]
        case "thinking_delta":
            guard let delta = event["delta"]?.stringValue, !delta.isEmpty else { return [] }
            return [.reasoningDelta(itemID: itemID, delta: delta)]
        case "thinking_end":
            guard let text = event["content"]?.nonEmptyString else { return [] }
            return [.itemUpdated(TurnItem(id: itemID, kind: .reasoning(text: text), status: .completed))]
        case "toolcall_start":
            let block = event["block"]
            guard let toolCallID = block?["id"]?.nonEmptyString, let name = block?["name"]?.stringValue else { return [] }
            let messageKey = "\(itemPrefix)\(messageID)"
            messageCalls[messageKey, default: []].append(toolCallID)
            guard Self.codeTools.contains(name) else { return [] }
            streamingCalls[itemID] = StreamingCall(toolCallID: toolCallID, name: name, messageKey: messageKey)
            return []
        case "toolcall_delta":
            guard var call = streamingCalls[itemID], let delta = event["delta"]?.stringValue, !delta.isEmpty else { return [] }
            call.json += delta
            call.bytes += delta.utf8.count
            defer { streamingCalls[itemID] = call }
            // A cut number or literal does not parse yet: try again on the next delta.
            guard call.isDue(newLine: delta.contains("\\n") || delta.contains("\n")),
                  let args = OmpEditPreview.partialObject(call.json) else { return [] }
            call.emittedBytes = call.bytes
            return streamedPreview(call, args: args)
        case "toolcall_end":
            guard let call = streamingCalls.removeValue(forKey: itemID) else { return [] }
            let args = event["toolCall"]?["arguments"] ?? OmpEditPreview.partialObject(call.json) ?? [:]
            return streamedPreview(call, args: args)
        default:
            return []
        }
    }

    /// The running file-change item of a call still streaming; nothing once omp runs it (the tool
    /// item takes over), while its arguments carry no code yet, or while an earlier call of the
    /// same message has not run (its item would land below this one; omp runs them in order).
    private func streamedPreview(_ call: StreamingCall, args: JSONValue) -> [ProviderEvent] {
        guard tools[call.toolCallID] == nil else { return [] }
        let earlier = (messageCalls[call.messageKey] ?? []).prefix { $0 != call.toolCallID }
        guard earlier.allSatisfy({ tools[$0] != nil }) else { return [] }
        let changes = OmpEditPreview.changes(tool: call.name, args: args) { Self.relative($0, to: cwd) }
        guard !changes.isEmpty else { return [] }
        return [.itemUpdated(TurnItem(id: call.toolCallID, kind: .fileChange(changes), status: .running))]
    }

    private mutating func mapMessageEnd(_ frame: JSONValue) -> [ProviderEvent] {
        guard let message = frame["message"] else { return [] }
        if message["role"]?.stringValue == "custom", message["customType"]?.stringValue == "advisor" {
            return mapAdvisory(message, messageID: frame["messageId"]?.stringValue)
        }
        guard message["role"]?.stringValue == "assistant" else { return [] }
        var events: [ProviderEvent] = []
        if message["stopReason"]?.stringValue == "stop", let messageID = frame["messageId"]?.stringValue,
           let last = lastText, last.id.hasPrefix("\(itemPrefix)\(messageID):") {
            events.append(.itemUpdated(TurnItem(id: last.id, kind: .assistantMessage(text: last.text, isFinal: true), status: .completed)))
        }
        if let usage = message["usage"], usage.objectValue != nil {
            let used = ["input", "output", "cacheRead", "cacheWrite"].compactMap { usage[$0]?.intValue }.reduce(0, +)
            if used > 0 { events.append(.tokenUsage(TokenUsage(usedTokens: used, contextWindow: contextWindow))) }
        }
        return events
    }

    /// An advisor review (`role:"custom"`, `customType:"advisor"`): `details.notes[{note,
    /// severity?, advisor?}]`, else the message text as one note.
    private mutating func mapAdvisory(_ message: JSONValue, messageID: String?) -> [ProviderEvent] {
        var notes = (message["details"]?["notes"]?.arrayValue ?? []).compactMap { note -> AdvisorNote? in
            guard let text = note["note"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let severity = note["severity"]?.stringValue.flatMap(AdvisorNote.Severity.init(rawValue:)) ?? .nit
            return AdvisorNote(text: text, severity: severity, advisor: note["advisor"]?.nonEmptyString)
        }
        if notes.isEmpty, let text = Self.contentText(message["content"])?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            notes = [AdvisorNote(text: text)]
        }
        guard !notes.isEmpty else { return [] }
        noticeCount += 1
        let id = messageID.map { "\(itemPrefix)\($0)" } ?? "\(itemPrefix)advisory:\(noticeCount)"
        return [.itemUpdated(TurnItem(id: id, kind: .advisory(notes), status: .completed))]
    }

    private mutating func mapPromptResult(_ frame: JSONValue) -> [ProviderEvent] {
        let outcome: ProviderTurnOutcome
        var error: String?
        switch frame["status"]?.stringValue {
        case "completed", nil:
            outcome = .completed
        case "aborted", "interrupted", "cancelled":
            outcome = .interrupted
        default:
            outcome = .failed
            let message = frame["error"]?["message"]?.nonEmptyString ?? frame["error"]?.nonEmptyString
            error = message ?? "omp ended the turn with \(frame["status"]?.stringValue ?? "an error")."
        }
        // An aborted prompt is over for the user even while background jobs keep omp busy.
        if frame["sessionSettled"]?.boolValue == false, outcome != .interrupted {
            heldOutcome = (outcome, error)
            isBackgroundRunActive = false
            return [.turnYielded(outcome: outcome, error: error)]
        }
        return complete(outcome, error: error)
    }

    private mutating func complete(_ outcome: ProviderTurnOutcome, error: String?) -> [ProviderEvent] {
        var events: [ProviderEvent] = []
        if let last = lastText {
            events.append(.itemUpdated(TurnItem(id: last.id, kind: .assistantMessage(text: last.text, isFinal: true), status: .completed)))
        }
        events.append(.turnCompleted(outcome: outcome, error: error))
        resetTurn()
        return events
    }

    private mutating func notice(_ text: String, id: String? = nil) -> ProviderEvent {
        noticeCount += 1
        return .itemUpdated(TurnItem(id: id ?? "\(itemPrefix)notice:\(noticeCount)", kind: .notice(text: text), status: .completed))
    }

    private mutating func mapCommandOutput(_ frame: JSONValue) -> [ProviderEvent] {
        guard let text = frame["text"]?.stringValue.map(Self.strippingTerminalEscapes),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let output: (id: String, text: String)
        if let current = commandOutput {
            output = (current.id, current.text + "\n" + text)
        } else {
            commandOutputCount += 1
            output = ("\(itemPrefix)command-output:\(commandOutputCount)", text)
        }
        commandOutput = output
        return [.itemUpdated(TurnItem(id: output.id, kind: .assistantMessage(text: Self.commandOutputText(output.text), isFinal: true), status: .completed))]
    }

    /// omp writes command output for a terminal: Markdown (`/changelog`, fenced `/usage`) or
    /// column-aligned plain text (`/context`, `/tools`, `/mcp`). Markdown (a ``` fence or a `#`
    /// heading) and single lines stay as they are; other multi-line text becomes a fenced block
    /// so its line breaks and alignment survive.
    static func commandOutputText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .newlines)
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        let isMarkdown = trimmed.contains("```") || lines.contains { $0.hasPrefix("#") }
        guard !isMarkdown, lines.count > 1 else { return trimmed }
        return "```\n\(trimmed)\n```"
    }

    /// Drops ANSI CSI sequences (`ESC [ … final byte`, e.g. the colors in `/context`'s bars).
    static func strippingTerminalEscapes(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return text.replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    // MARK: - Tools

    private mutating func mapToolStart(_ frame: JSONValue) -> [ProviderEvent] {
        guard let id = frame["toolCallId"]?.stringValue, let name = frame["toolName"]?.stringValue else { return [] }
        let tool = Tool(name: name, args: frame["args"] ?? [:], intent: frame["intent"]?.nonEmptyString, startedAt: Date(), output: "")
        tools[id] = tool
        return toolItem(id: id, tool: tool, status: .running, result: nil).map { [.itemUpdated($0)] } ?? []
    }

    private mutating func mapToolUpdate(_ frame: JSONValue) -> [ProviderEvent] {
        guard let id = frame["toolCallId"]?.stringValue, var tool = tools[id] else { return [] }
        let text = Self.contentText(frame["partialResult"]?["content"]) ?? ""
        guard tool.name == "bash", text != tool.output else { return [] }
        let previous = tool.output
        tool.output = text
        tools[id] = tool
        if text.hasPrefix(previous) {
            return [.commandOutputDelta(itemID: id, delta: String(text.dropFirst(previous.count)))]
        }
        return toolItem(id: id, tool: tool, status: .running, result: nil).map { [.itemUpdated($0)] } ?? []
    }

    private mutating func mapToolEnd(_ frame: JSONValue) -> [ProviderEvent] {
        guard let id = frame["toolCallId"]?.stringValue else { return [] }
        var tool = tools[id] ?? Tool(name: frame["toolName"]?.stringValue ?? "tool", args: frame["args"] ?? [:], intent: nil, startedAt: Date(), output: "")
        let result = frame["result"] ?? [:]
        tool.output = Self.contentText(result["content"]) ?? tool.output
        tool.isFinished = true
        tools[id] = tool
        let isError = frame["isError"]?.boolValue == true
        let status: TurnItemStatus = isError ? (declinedTools.contains(id) ? .declined : .failed) : .completed
        return toolItem(id: id, tool: tool, status: status, result: result).map { [.itemUpdated($0)] } ?? []
    }

    private func toolItem(id: String, tool: Tool, status: TurnItemStatus, result: JSONValue?) -> TurnItem? {
        let args = tool.args
        let output = tool.output.isEmpty ? nil : tool.output
        func item(_ kind: TurnItemKind) -> TurnItem {
            TurnItem(id: id, kind: kind, status: status, startedAt: tool.startedAt, completedAt: status.isActive ? nil : Date())
        }
        let path = args["path"]?.nonEmptyString
        switch tool.name {
        case "bash":
            let details = result?["details"]
            var exitCode: Int?
            if let code = details?["exitCode"]?.intValue {
                exitCode = code
            } else if status == .completed {
                exitCode = 0
            }
            return item(.command(CommandExecution(
                command: args["command"]?.stringValue ?? "",
                cwd: args["cwd"]?.nonEmptyString,
                output: tool.output,
                exitCode: exitCode,
                durationMs: details?["wallTimeMs"]?.doubleValue.map { Int($0.rounded()) }
            )))
        case "write", "edit", "apply_patch", "ast_edit":
            return item(.fileChange(fileChanges(tool: tool, status: status, result: result)))
        case "read":
            return item(.toolCall(ToolCall(name: tool.name, category: .read, title: "Read \(relative(path ?? ""))", input: Self.inputText(args), output: output)))
        case "grep", "glob", "find", "ast_grep":
            let pattern = args["pattern"]?.nonEmptyString ?? args["query"]?.nonEmptyString ?? args["pat"]?.nonEmptyString
            var title: String
            if let pattern {
                title = "Searched \(pattern)"
                if let path { title += " in \(relative(path))" }
            } else {
                title = "Searched \(relative(path ?? "."))"
            }
            return item(.toolCall(ToolCall(name: tool.name, category: .search, title: title, input: Self.inputText(args), output: output)))
        case "web_search":
            return item(.webSearch(query: args["query"]?.stringValue ?? tool.intent ?? ""))
        case "task":
            let names = (args["tasks"]?.arrayValue ?? []).compactMap { $0["name"]?.nonEmptyString }
            let label = tool.intent ?? (names.isEmpty ? nil : names.joined(separator: ", "))
            return item(.toolCall(ToolCall(name: tool.name, category: .subagent, title: label.map { "Subagent: \($0)" } ?? "Subagent", input: Self.inputText(args), output: output)))
        case "todo":
            return item(.toolCall(ToolCall(name: tool.name, category: .other, title: "Updated tasks", input: Self.inputText(args), output: output)))
        case "ask":
            return nil
        default:
            return item(.toolCall(ToolCall(name: tool.name, category: .other, title: tool.intent ?? tool.name, input: Self.inputText(args), output: output)))
        }
    }

    private func fileChanges(tool: Tool, status: TurnItemStatus, result: JSONValue?) -> [FileChange] {
        let changes = reportedChanges(tool: tool, result: result)
        // A running call and a write report no diff: show the code the arguments carry. A failed
        // or declined call changed nothing.
        guard status != .failed, status != .declined, changes.allSatisfy({ $0.diff == nil }) else { return changes }
        let preview = OmpEditPreview.changes(tool: tool.name, args: tool.args, relative: relative)
        guard let first = preview.first else { return changes }
        if preview.count == 1, changes.count == 1, !changes[0].path.isEmpty {
            var change = changes[0]
            change.diff = first.diff
            change.isFullContent = first.isFullContent
            return [change]
        }
        return preview
    }

    private func reportedChanges(tool: Tool, result: JSONValue?) -> [FileChange] {
        let details = result?["details"]
        if let perFile = details?["perFileResults"]?.arrayValue, !perFile.isEmpty {
            return perFile.compactMap { file in
                guard let path = file["path"]?.nonEmptyString else { return nil }
                return FileChange(path: relative(path), kind: Self.kind(file["op"]?.stringValue), movePath: file["move"]?.nonEmptyString.map(relative), diff: file["diff"]?.nonEmptyString.flatMap(Self.unifiedDiff))
            }
        }
        let path = details?["path"]?.nonEmptyString ?? details?["resolvedPath"]?.nonEmptyString ?? Self.argumentPath(tool.args) ?? ""
        var kind = Self.kind(details?["op"]?.stringValue)
        if tool.name == "write", details?["op"] == nil {
            let text = tool.output.lowercased()
            kind = text.contains("created") || text.contains("new file") ? .add : .update
        }
        let diff = details?["diff"]?.nonEmptyString.flatMap(Self.unifiedDiff)
        let movePath = details?["move"]?.nonEmptyString.map(relative)
        return [FileChange(path: relative(path), kind: movePath == nil ? kind : .move, movePath: movePath, diff: diff)]
    }

    /// The file a write/edit call names: `path`, else the `[path#TAG]` header of a hashline
    /// edit's `input`.
    static func argumentPath(_ args: JSONValue) -> String? {
        if let path = args["path"]?.nonEmptyString { return path }
        guard let input = args["input"]?.stringValue, input.hasPrefix("["),
              let close = input.firstIndex(of: "]") else { return nil }
        let header = input[input.index(after: input.startIndex)..<close]
        let path = header.split(separator: "#", maxSplits: 1).first.map(String.init) ?? String(header)
        return path.isEmpty ? nil : path
    }

    private static func kind(_ op: String?) -> FileChange.Kind {
        switch op {
        case "create": .add
        case "delete": .delete
        default: .update
        }
    }

    // MARK: - Dialogs

    private mutating func mapUIRequest(_ frame: JSONValue) -> [ProviderEvent] {
        switch frame["method"]?.stringValue {
        case "cancel":
            guard let target = frame["targetId"]?.stringValue else { return [] }
            return [.requestResolved(id: target)]
        case "notify":
            guard let message = frame["message"]?.nonEmptyString else { return [] }
            return [notice(message, id: frame["id"]?.stringValue.map { "\(itemPrefix)notify:\($0)" })]
        default:
            guard let request = OmpUIRequest(frame) else { return [] }
            if request.isApproval {
                let tool = request.approvalTool ?? ""
                let candidates = tools.filter { $0.value.name == tool && !$0.value.isFinished && !approvalTools.values.contains($0.key) }
                if let toolCallID = candidates.min(by: { $0.value.startedAt < $1.value.startedAt })?.key {
                    approvalTools[request.id] = toolCallID
                }
                return [.approvalRequested(Self.approval(request))]
            }
            return [.userInputRequested(Self.userInput(request))]
        }
    }

    /// Approval `select` → `ApprovalRequest`: kind by tool (bash/eval → command;
    /// write/edit/ast_edit → file change; read/grep/glob/find → file read; else other), detail =
    /// the title after its first line (else the tool name), decisions offered by the labels.
    public static func approval(_ request: OmpUIRequest) -> ApprovalRequest {
        let tool = request.approvalTool ?? ""
        let kind: ApprovalKind = switch tool {
        case "bash", "eval": .command
        case "write", "edit", "apply_patch", "ast_edit": .fileChange
        case "read", "grep", "glob", "find": .fileRead
        default: .other
        }
        let lines = request.title.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let rest = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return ApprovalRequest(
            id: request.id,
            kind: kind,
            detail: rest.isEmpty ? tool : rest,
            reason: nil,
            options: OmpProtocol.approvalDecisions(options: request.options)
        )
    }

    /// Non-approval dialogs → `UserInputRequest`. `ask`: every question (id, header, text,
    /// options with descriptions, `multi` → multiple, free text allowed); `select`: one question
    /// with the labels; `confirm`: Yes/No; `input`/`editor`: free text only. Single-question
    /// dialogs use question id `OmpUIRequest.singleQuestionID`.
    public static func userInput(_ request: OmpUIRequest) -> UserInputRequest {
        let id = OmpUIRequest.singleQuestionID
        let questions: [UserInputQuestion]
        switch request.method {
        case .ask:
            questions = request.questions.enumerated().map { index, question in
                let options = (question["options"]?.arrayValue ?? []).compactMap { option -> UserInputOption? in
                    option["label"]?.nonEmptyString.map { UserInputOption(label: $0, description: option["description"]?.nonEmptyString) }
                }
                return UserInputQuestion(
                    id: question["id"]?.stringValue ?? "q\(index)",
                    header: question["header"]?.stringValue ?? "",
                    question: question["question"]?.stringValue ?? "",
                    options: options,
                    allowsMultiple: question["multi"]?.boolValue ?? false,
                    allowsOther: true
                )
            }
        case .select:
            questions = [UserInputQuestion(id: id, header: "", question: request.title, options: request.options.map { UserInputOption(label: $0) }, allowsOther: false)]
        case .confirm:
            questions = [UserInputQuestion(id: id, header: "", question: request.title, options: [UserInputOption(label: "Yes"), UserInputOption(label: "No")], allowsOther: false)]
        case .input, .editor:
            questions = [UserInputQuestion(id: id, header: "", question: request.title, options: [], allowsOther: true)]
        }
        return UserInputRequest(id: request.id, questions: questions)
    }

    // MARK: - Helpers

    private func relative(_ path: String) -> String {
        Self.relative(path, to: cwd)
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

    static func contentText(_ content: JSONValue?) -> String? {
        switch content {
        case let .string(text)?: return text
        case let .array(blocks)?:
            let texts = blocks.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        default: return nil
        }
    }

    /// Pretty-printed tool arguments; nil for an empty object.
    static func inputText(_ args: JSONValue) -> String? {
        if case let .object(object) = args, object.isEmpty { return nil }
        return args.prettyJSONString()
    }

    /// omp's display diff (`-12|old`, `+12|new`, ` 12|context`, `...` between hunks) → unified
    /// hunks (`@@ -a,b +c,d @@` + `-`/`+`/` ` lines). Text already in unified form is kept.
    static func unifiedDiff(_ diff: String) -> String? {
        if diff.hasPrefix("@@") || diff.hasPrefix("---") || diff.hasPrefix("diff ") { return diff }
        var hunks: [String] = []
        var lines: [String] = []
        var oldStart: Int?
        var newStart: Int?
        var oldCount = 0
        var newCount = 0
        func flush() {
            guard !lines.isEmpty else { return }
            let old = oldStart ?? newStart ?? 1
            let new = newStart ?? oldStart ?? 1
            hunks.append((["@@ -\(oldCount == 0 ? old - 1 : old),\(oldCount) +\(newCount == 0 ? new - 1 : new),\(newCount) @@"] + lines).joined(separator: "\n"))
            lines = []
            oldStart = nil
            newStart = nil
            oldCount = 0
            newCount = 0
        }
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            guard let marker = line.first, "+- ".contains(marker), let bar = line.firstIndex(of: "|") else {
                flush()
                continue
            }
            let number = Int(line[line.index(after: line.startIndex)..<bar].trimmingCharacters(in: .whitespaces))
            let text = String(line[line.index(after: bar)...])
            switch marker {
            case "-":
                if oldStart == nil { oldStart = number }
                oldCount += 1
            case "+":
                if newStart == nil { newStart = number }
                newCount += 1
            default:
                if oldStart == nil { oldStart = number }
                if newStart == nil { newStart = number }
                oldCount += 1
                newCount += 1
            }
            lines.append("\(marker)\(text)")
        }
        flush()
        return hunks.isEmpty ? nil : hunks.joined(separator: "\n")
    }
}
