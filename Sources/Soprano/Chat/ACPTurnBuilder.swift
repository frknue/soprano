import Foundation

/// How a chat tab reads an agent's tool calls. omp's ACP mode sends its own
/// tool names, arguments and results, which say what each call is; any other
/// agent is read from the protocol's generic kind, title and content.
enum ACPToolStyle: Equatable, Sendable {
    case omp
    case generic
}

/// Folds an Agent Client Protocol session's `session/update` notifications
/// into the chat's turns (`ChatThread`): each prompt starts a turn; streamed
/// reply and thinking chunks join per message into its items, tool calls
/// update their item in place, approvals and questions are recorded where
/// they happened. Agents echo a prompt only while `session/load` replays
/// history: a replayed user message starts a turn, and replayed turns carry
/// no times.
struct ACPTurnBuilder: Equatable, Sendable {
    let cwd: String?
    let toolStyle: ACPToolStyle
    /// Set while `session/load` replays history. Clearing it ends the last
    /// replayed turn.
    var isReplaying = false {
        didSet {
            if oldValue, !isReplaying { endReplayedTurn() }
        }
    }

    private(set) var thread = ChatThread()
    private var tools: [String: Tool] = [:]
    /// The streamed item the next chunk of the same kind and message continues.
    private var openChunk: (kind: ChunkKind, key: String?, itemId: String)?
    private var nextLocalId = 1

    private enum ChunkKind: Equatable, Sendable {
        case prompt
        case reply
        case thinking
    }

    /// What a tool call said about itself so far: the call carries the name
    /// and arguments, updates carry the output.
    private struct Tool: Equatable, Sendable {
        var name: String?
        var kind: String?
        var title: String?
        var args: JSONValue = .null
        var rawOutput: JSONValue?
        var content: [JSONValue] = []
    }

    init(cwd: String?, toolStyle: ACPToolStyle) {
        self.cwd = cwd
        self.toolStyle = toolStyle
    }

    static func == (lhs: ACPTurnBuilder, rhs: ACPTurnBuilder) -> Bool {
        lhs.thread == rhs.thread && lhs.isReplaying == rhs.isReplaying
    }

    // MARK: - Turns

    /// A prompt this chat sent: starts a turn.
    mutating func addPrompt(_ text: String, at date: Date) {
        closeChunk(at: date)
        thread.turns.append(Turn(
            id: localId("turn"),
            userMessage: UserMessage(id: localId("message"), text: text, createdAt: date),
            startedAt: date
        ))
    }

    /// A message steered into the running turn; a new turn when none runs.
    mutating func addSteer(_ text: String, at date: Date) {
        guard let index = activeTurnIndex else { return addPrompt(text, at: date) }
        closeChunk(at: date)
        thread.turns[index].steers.append(UserMessage(id: localId("steer"), text: text, createdAt: date))
    }

    /// Stop was pressed: the turn says "Stopping…" until it ends.
    mutating func markStopRequested(at date: Date) {
        guard let index = activeTurnIndex else { return }
        thread.turns[index].stopRequestedAt = date
    }

    /// Ends the running turn: what was still streaming is complete, tool
    /// calls still running were cut short, and a turn that did not end
    /// normally says why (`failure`, or the stop reason).
    mutating func finishTurn(stopReason: String?, failure: String? = nil, at date: Date) {
        closeChunk(at: date)
        guard let index = activeTurnIndex else { return }
        var turn = thread.turns[index]
        for item in turn.items.indices where turn.items[item].status.isActive {
            turn.items[item].status = .interrupted
            turn.items[item].completedAt = date
        }
        let reason: String? = switch stopReason {
        case "max_tokens": "The reply reached the model's output limit."
        case "max_turn_requests": "The turn reached its request limit."
        case "refusal": "The model refused to continue."
        default: nil
        }
        if let message = failure ?? reason {
            turn.status = .failed
            turn.failureMessage = message
        } else {
            turn.status = stopReason == "cancelled" ? .interrupted : .completed
        }
        turn.completedAt = date
        turn.stopRequestedAt = nil
        Self.markAnswer(in: &turn)
        thread.turns[index] = turn
    }

    /// A notice or error: in the running turn, else the last one, else before
    /// the first.
    mutating func addNotice(_ text: String, isError: Bool, at date: Date? = nil) {
        closeChunk(at: date)
        let item = TurnItem(
            id: localId("notice"),
            kind: isError ? .error(message: text) : .notice(text: text),
            status: .completed,
            startedAt: date,
            completedAt: date
        )
        if thread.turns.isEmpty {
            thread.preamble.append(item)
        } else {
            thread.turns[thread.turns.count - 1].items.append(item)
        }
    }

    // MARK: - Approvals and questions

    mutating func addApproval(_ request: ApprovalRequest, at date: Date) {
        closeChunk(at: date)
        appendToActiveTurn(TurnItem(id: request.id, kind: .approval(request), status: .pending, startedAt: date), at: date)
    }

    mutating func resolveApproval(_ id: String, decision: ApprovalDecision, at date: Date) {
        update(itemId: id) { item in
            guard case var .approval(request) = item.kind else { return }
            request.decision = decision
            item.kind = .approval(request)
            item.status = decision == .decline || decision == .cancel ? .declined : .completed
            item.completedAt = date
        }
    }

    mutating func addUserInput(_ request: UserInputRequest, at date: Date) {
        closeChunk(at: date)
        appendToActiveTurn(TurnItem(id: request.id, kind: .userInput(request), status: .pending, startedAt: date), at: date)
    }

    /// Records the answers, or a dismissal when `answers` is nil.
    mutating func resolveUserInput(_ id: String, answers: [String: [String]]?, at date: Date) {
        update(itemId: id) { item in
            guard case var .userInput(request) = item.kind else { return }
            request.answers = answers
            request.dismissed = answers == nil
            item.kind = .userInput(request)
            item.status = answers == nil ? .declined : .completed
            item.completedAt = date
        }
    }

    // MARK: - Updates

    /// Applies one `update` object. False when it changes nothing visible.
    @discardableResult
    mutating func apply(_ update: JSONValue, at date: Date) -> Bool {
        let timestamp: Date? = isReplaying ? nil : date
        switch update["sessionUpdate"]?.string {
        case "user_message_chunk":
            return appendChunk(.prompt, update, at: timestamp)
        case "agent_message_chunk":
            return appendChunk(.reply, update, at: timestamp)
        case "agent_thought_chunk":
            return appendChunk(.thinking, update, at: timestamp)
        case "tool_call":
            return startTool(update, at: timestamp)
        case "tool_call_update":
            return updateTool(update, at: timestamp)
        default:
            return false
        }
    }

    // MARK: - Messages

    private mutating func appendChunk(_ kind: ChunkKind, _ update: JSONValue, at date: Date?) -> Bool {
        let text = Self.text(of: update["content"])
        guard !text.isEmpty else { return false }
        let key = update["messageId"]?.string

        if kind == .prompt {
            return appendUserChunk(text, key: key, at: date)
        }
        if let open = openChunk, open.kind == kind, open.key == key, appendText(text, toItem: open.itemId) {
            return true
        }
        closeChunk(at: date)
        let id = localId(kind == .reply ? "reply" : "thinking")
        let itemKind: TurnItemKind = kind == .reply ? .assistantMessage(text: text, isFinal: false) : .reasoning(text: text)
        appendToActiveTurn(TurnItem(id: id, kind: itemKind, status: .running, startedAt: date), at: date)
        openChunk = (kind, key, id)
        return true
    }

    /// A user message the agent sent: replayed history, or a message the
    /// agent itself added while working.
    private mutating func appendUserChunk(_ text: String, key: String?, at date: Date?) -> Bool {
        if let open = openChunk, open.kind == .prompt, open.key == key, let last = thread.turns.indices.last {
            if thread.turns[last].userMessage.id == open.itemId {
                thread.turns[last].userMessage.text += text
                return true
            }
            if let steer = thread.turns[last].steers.lastIndex(where: { $0.id == open.itemId }) {
                thread.turns[last].steers[steer].text += text
                return true
            }
        }
        closeChunk(at: date)
        let id = localId("message")
        if !isReplaying, let index = activeTurnIndex {
            thread.turns[index].steers.append(UserMessage(id: id, text: text, createdAt: date))
        } else {
            endReplayedTurn()
            thread.turns.append(Turn(id: localId("turn"), userMessage: UserMessage(id: id, text: text, createdAt: date), startedAt: date))
        }
        openChunk = (.prompt, key, id)
        return true
    }

    private mutating func appendText(_ text: String, toItem id: String) -> Bool {
        var appended = false
        update(itemId: id) { item in
            switch item.kind {
            case let .assistantMessage(existing, isFinal):
                item.kind = .assistantMessage(text: existing + text, isFinal: isFinal)
                appended = true
            case let .reasoning(existing):
                item.kind = .reasoning(text: existing + text)
                appended = true
            default:
                break
            }
        }
        return appended
    }

    /// The streamed message or thought is complete once anything else arrives.
    private mutating func closeChunk(at date: Date?) {
        guard let open = openChunk else { return }
        openChunk = nil
        guard open.kind != .prompt else { return }
        update(itemId: open.itemId) { item in
            guard item.status.isActive else { return }
            item.status = .completed
            item.completedAt = date
        }
    }

    /// The text of one content block; an image only as a marker.
    static func text(of content: JSONValue?) -> String {
        guard let content else { return "" }
        switch content["type"]?.string {
        case "text": return content["text"]?.string ?? ""
        case "image": return "[image]"
        case "resource_link": return content["title"]?.string ?? content["name"]?.string ?? content["uri"]?.string ?? ""
        case "resource": return content["resource"]?["text"]?.string ?? ""
        default: return ""
        }
    }

    // MARK: - Tool calls

    private mutating func startTool(_ update: JSONValue, at date: Date?) -> Bool {
        guard let id = update["toolCallId"]?.string else { return false }
        closeChunk(at: date)
        var tool = tools[id] ?? Tool()
        tool.name = update["name"]?.string ?? tool.name
        tool.kind = update["kind"]?.string ?? tool.kind
        tool.title = update["title"]?.nonEmptyString ?? tool.title
        if let args = update["rawInput"] { tool.args = args }
        if let output = update["rawOutput"] { tool.rawOutput = output }
        if let content = update["content"]?.array { tool.content = content }
        tools[id] = tool
        let status = Self.status(update["status"]?.string) ?? .running
        guard let kind = itemKind(for: tool, status: status) else { return false }
        if item(id) != nil {
            self.update(itemId: id) { item in
                item.kind = kind
                item.status = status
            }
        } else {
            appendToActiveTurn(TurnItem(
                id: id, kind: kind, status: status, startedAt: date,
                completedAt: status.isActive ? nil : date
            ), at: date)
        }
        return true
    }

    private mutating func updateTool(_ update: JSONValue, at date: Date?) -> Bool {
        guard let id = update["toolCallId"]?.string, var tool = tools[id], let current = item(id) else { return false }
        closeChunk(at: date)
        tool.title = update["title"]?.nonEmptyString ?? tool.title
        if let args = update["rawInput"] { tool.args = args }
        if let output = update["rawOutput"] { tool.rawOutput = output }
        if let content = update["content"]?.array { tool.content = content }
        tools[id] = tool
        let status = Self.status(update["status"]?.string) ?? current.status
        guard let kind = itemKind(for: tool, status: status) else { return false }
        self.update(itemId: id) { item in
            item.kind = kind
            item.status = status
            if !status.isActive { item.completedAt = date }
        }
        return true
    }

    private static func status(_ status: String?) -> TurnItemStatus? {
        switch status {
        case "pending": .pending
        case "in_progress": .running
        case "completed": .completed
        case "failed": .failed
        default: nil
        }
    }

    /// The turn item a tool call reads as. Nil for calls the chat shows
    /// otherwise (omp's `ask`: its question).
    private func itemKind(for tool: Tool, status: TurnItemStatus) -> TurnItemKind? {
        if toolStyle == .omp, let name = tool.name {
            return ompItemKind(name: name, tool: tool, status: status)
        }
        return genericItemKind(tool, status: status)
    }

    /// omp's tools as Soprano Agents reads them (`OmpEventMapper.toolItem`).
    private func ompItemKind(name: String, tool: Tool, status: TurnItemStatus) -> TurnItemKind? {
        let args = tool.args
        let output = Self.contentText(tool.rawOutput?["content"])
        let path = args["path"]?.nonEmptyString
        switch name {
        case "bash":
            let details = tool.rawOutput?["details"]
            return .command(TurnCommand(
                command: args["command"]?.string ?? tool.title ?? "",
                output: output ?? "",
                exitCode: details?["exitCode"]?.int ?? (status == .completed ? 0 : nil)
            ))
        case "write", "edit", "apply_patch", "ast_edit":
            return .fileChange(ompFileChanges(name: name, tool: tool, status: status))
        case "read":
            return .toolCall(ToolCall(name: name, category: .read, title: "Read \(relative(path ?? ""))", input: Self.inputText(args), output: output))
        case "grep", "glob", "find", "ast_grep":
            let pattern = args["pattern"]?.nonEmptyString ?? args["query"]?.nonEmptyString ?? args["pat"]?.nonEmptyString
            var title: String
            if let pattern {
                title = "Searched \(pattern)"
                if let path { title += " in \(relative(path))" }
            } else {
                title = "Searched \(relative(path ?? "."))"
            }
            return .toolCall(ToolCall(name: name, category: .search, title: title, input: Self.inputText(args), output: output))
        case "web_search":
            return .webSearch(query: args["query"]?.string ?? tool.title ?? "")
        case "task":
            let names = (args["tasks"]?.array ?? []).compactMap { $0["name"]?.nonEmptyString }
            let label = tool.title ?? (names.isEmpty ? nil : names.joined(separator: ", "))
            return .toolCall(ToolCall(name: name, category: .subagent, title: label.map { "Subagent: \($0)" } ?? "Subagent", input: Self.inputText(args), output: output))
        case "todo":
            return .toolCall(ToolCall(name: name, category: .other, title: "Updated tasks", input: Self.inputText(args), output: output))
        case "ask":
            return nil
        default:
            return .toolCall(ToolCall(name: name, category: .other, title: tool.title ?? name, input: Self.inputText(args), output: output))
        }
    }

    /// The files an omp edit or write touched: what its result reports, else
    /// (still running, or a write, which reports no diff) the code its
    /// arguments carry. A failed call changed nothing.
    private func ompFileChanges(name: String, tool: Tool, status: TurnItemStatus) -> [FileChange] {
        let changes = tool.rawOutput.map { reportedChanges(name: name, tool: tool, result: $0) } ?? []
        guard status != .failed, status != .declined, changes.allSatisfy({ $0.diff == nil }) else { return changes }
        let preview = OmpEditPreview.changes(tool: name, args: tool.args, relative: relative)
        guard let first = preview.first else { return changes }
        if preview.count == 1, changes.count == 1, !changes[0].path.isEmpty {
            var change = changes[0]
            change.diff = first.diff
            change.isFullContent = first.isFullContent
            return [change]
        }
        return preview
    }

    private func reportedChanges(name: String, tool: Tool, result: JSONValue) -> [FileChange] {
        let details = result["details"]
        if let perFile = details?["perFileResults"]?.array, !perFile.isEmpty {
            return perFile.compactMap { file in
                guard let path = file["path"]?.nonEmptyString else { return nil }
                return FileChange(
                    path: relative(path),
                    kind: Self.changeKind(file["op"]?.string),
                    movePath: file["move"]?.nonEmptyString.map(relative),
                    diff: file["diff"]?.nonEmptyString.flatMap(Self.unifiedDiff)
                )
            }
        }
        guard let path = details?["path"]?.nonEmptyString ?? details?["resolvedPath"]?.nonEmptyString ?? Self.argumentPath(tool.args)
        else { return [] }
        var kind = Self.changeKind(details?["op"]?.string)
        if name == "write", details?["op"] == nil {
            let text = (Self.contentText(result["content"]) ?? "").lowercased()
            kind = text.contains("created") || text.contains("new file") ? .add : .update
        }
        let movePath = details?["move"]?.nonEmptyString.map(relative)
        return [FileChange(
            path: relative(path),
            kind: movePath == nil ? kind : .move,
            movePath: movePath,
            diff: details?["diff"]?.nonEmptyString.flatMap(Self.unifiedDiff)
        )]
    }

    /// Any other agent's tool call, from the protocol's kind, title and content.
    private func genericItemKind(_ tool: Tool, status: TurnItemStatus) -> TurnItemKind {
        let title = tool.title ?? ""
        let output = tool.content.compactMap { block -> String? in
            guard block["type"]?.string == "content" else { return nil }
            let text = Self.text(of: block["content"])
            return text.isEmpty ? nil : text
        }.joined(separator: "\n")
        switch tool.kind {
        case "execute":
            return .command(TurnCommand(command: tool.args["command"]?.string ?? title, output: output))
        case "edit", "delete", "move":
            var changes: [FileChange] = []
            for block in tool.content where block["type"]?.string == "diff" {
                guard let path = block["path"]?.nonEmptyString else { continue }
                let old = block["oldText"]?.string
                let new = block["newText"]?.string ?? ""
                changes.append(FileChange(
                    path: relative(path),
                    kind: old == nil ? .add : (new.isEmpty ? .delete : .update),
                    diff: ACPDiff.unified(old: old ?? "", new: new)
                ))
            }
            return .fileChange(changes)
        case "read":
            return .toolCall(ToolCall(name: "read", category: .read, title: title.isEmpty ? "Read file" : title, output: output.isEmpty ? nil : output))
        case "search":
            return .toolCall(ToolCall(name: "search", category: .search, title: title, output: output.isEmpty ? nil : output))
        default:
            return .toolCall(ToolCall(name: tool.kind ?? "tool", category: .other, title: title, output: output.isEmpty ? nil : output))
        }
    }

    // MARK: - Helpers

    /// The turn new items go to: the running one; else the last; else a new
    /// turn with no message of its own (the agent started working by itself).
    private mutating func appendToActiveTurn(_ item: TurnItem, at date: Date?) {
        if thread.turns.isEmpty {
            thread.turns.append(Turn(
                id: localId("turn"), userMessage: UserMessage(id: localId("message"), text: "", createdAt: date), startedAt: date
            ))
        }
        thread.turns[thread.turns.count - 1].items.append(item)
    }

    private var activeTurnIndex: Int? {
        guard let last = thread.turns.indices.last, thread.turns[last].isRunning else { return nil }
        return last
    }

    private func item(_ id: String) -> TurnItem? {
        for turn in thread.turns.reversed() {
            if let item = turn.items.last(where: { $0.id == id }) { return item }
        }
        return nil
    }

    private mutating func update(itemId id: String, _ change: (inout TurnItem) -> Void) {
        for turn in thread.turns.indices.reversed() {
            guard let index = thread.turns[turn].items.lastIndex(where: { $0.id == id }) else { continue }
            change(&thread.turns[turn].items[index])
            return
        }
    }

    /// A replayed turn has ended once the next one starts or the replay ends.
    private mutating func endReplayedTurn() {
        guard let last = thread.turns.indices.last, thread.turns[last].isRunning, thread.turns[last].startedAt == nil else { return }
        closeChunk(at: nil)
        var turn = thread.turns[last]
        for item in turn.items.indices where turn.items[item].status.isActive {
            turn.items[item].status = .completed
        }
        turn.status = .completed
        Self.markAnswer(in: &turn)
        thread.turns[last] = turn
    }

    /// The turn's answer: its last message, when no tool ran after it.
    private static func markAnswer(in turn: inout Turn) {
        for index in turn.items.indices.reversed() {
            switch turn.items[index].kind {
            case let .assistantMessage(text, _):
                turn.items[index].kind = .assistantMessage(text: text, isFinal: true)
                return
            case .command, .fileChange, .toolCall, .webSearch:
                return
            default:
                continue
            }
        }
    }

    private mutating func localId(_ prefix: String) -> String {
        defer { nextLocalId += 1 }
        return "local-\(prefix)-\(nextLocalId)"
    }

    private func relative(_ path: String) -> String {
        Self.relative(path, to: cwd)
    }

    /// `path` relative to `cwd` when inside it (`/tmp` and `/private/tmp` alike).
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
            let texts = blocks.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        default: return nil
        }
    }

    /// Pretty-printed tool arguments; nil for none.
    static func inputText(_ args: JSONValue) -> String? {
        if case let .object(object) = args, object.isEmpty { return nil }
        guard !args.isNull,
              let data = try? JSONSerialization.data(withJSONObject: args.any, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The file a write or edit call names: `path`, else the `[path#TAG]`
    /// header of a hashline edit's `input`.
    static func argumentPath(_ args: JSONValue) -> String? {
        if let path = args["path"]?.nonEmptyString { return path }
        guard let input = args["input"]?.string, input.hasPrefix("["),
              let close = input.firstIndex(of: "]") else { return nil }
        let header = input[input.index(after: input.startIndex)..<close]
        let path = header.split(separator: "#", maxSplits: 1).first.map(String.init) ?? String(header)
        return path.isEmpty ? nil : path
    }

    private static func changeKind(_ op: String?) -> FileChange.Kind {
        switch op {
        case "create": .add
        case "delete": .delete
        default: .update
        }
    }

    /// omp's display diff (`-12|old`, `+12|new`, ` 12|context`, `...` between
    /// hunks) as unified hunks; text already unified is kept.
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

/// A unified diff between two versions of a file's text, for agents that
/// report an edit as old and new text.
enum ACPDiff {
    /// Lines of context kept around the change.
    static let context = 3

    /// One hunk around everything that changed: unchanged leading and
    /// trailing lines are trimmed down to `context`. Nil when nothing changed.
    static func unified(old: String, new: String) -> String? {
        guard old != new else { return nil }
        let oldLines = lines(old)
        let newLines = lines(new)
        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix]
        {
            suffix += 1
        }
        let leading = min(prefix, context)
        let trailing = min(suffix, context)
        let oldStart = prefix - leading
        let oldEnd = oldLines.count - suffix + trailing
        let newEnd = newLines.count - suffix + trailing

        var result = ["@@ -\(oldStart + 1),\(oldEnd - oldStart) +\(oldStart + 1),\(newEnd - oldStart) @@"]
        result += oldLines[oldStart..<prefix].map { " " + $0 }
        result += oldLines[prefix..<(oldLines.count - suffix)].map { "-" + $0 }
        result += newLines[prefix..<(newLines.count - suffix)].map { "+" + $0 }
        result += oldLines[(oldLines.count - suffix)..<oldEnd].map { " " + $0 }
        return result.joined(separator: "\n")
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
