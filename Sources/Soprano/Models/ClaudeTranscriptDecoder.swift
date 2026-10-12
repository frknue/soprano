import Foundation

/// Reads Claude Code's session transcript (`~/.claude/projects/<slug>/<session>.jsonl`).
///
/// Every record carrying a `uuid` is a node of the conversation tree, even
/// when it shows nothing, because a rewind starts a new branch from any of
/// them and the timeline must follow the newest leaf. Records without one
/// (titles, modes, file-history snapshots, …) are session bookkeeping.
struct ClaudeTranscriptDecoder: AgentTranscriptDecoding {
    /// The session's working directory, so file tools show repo-relative paths.
    private(set) var cwd: String?

    init() {}

    mutating func entry(forLine line: Data) -> AgentTranscriptEntry? {
        guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
        if let cwd = record["cwd"] as? String, !cwd.isEmpty {
            self.cwd = cwd
        }
        // Subagent chains interleave with the main one; letting them in would
        // make a subagent's last message the leaf and hide the conversation.
        if record["isSidechain"] as? Bool == true { return nil }
        guard let uuid = record["uuid"] as? String else { return nil }

        // Compaction restarts the chain with a null parent and keeps the link
        // in `logicalParentUuid`; following it keeps pre-compaction history.
        var entry = AgentTranscriptEntry(
            id: uuid,
            parentId: record["parentUuid"] as? String ?? record["logicalParentUuid"] as? String
        )
        let timestamp = AgentTimeline.date(from: record["timestamp"])

        switch record["type"] as? String {
        case "system":
            if let notice = Self.systemNotice(record) {
                entry.items = [AgentTimelineItem(id: uuid, timestamp: timestamp, kind: notice)]
            }
        case "user":
            decodeUser(record, uuid: uuid, timestamp: timestamp, into: &entry)
        case "assistant":
            decodeAssistant(record, uuid: uuid, timestamp: timestamp, into: &entry)
        default:
            break
        }
        return entry
    }

    // MARK: - System

    private static func systemNotice(_ record: [String: Any]) -> AgentTimelineItem.Kind? {
        let subtype = record["subtype"] as? String ?? ""
        let content = (record["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if subtype == "compact_boundary" {
            return .notice("Conversation compacted", isError: false)
        }
        if record["level"] as? String == "error" || subtype.contains("error") {
            return .notice(content.isEmpty ? subtype : content, isError: true)
        }
        if subtype == "local_command", let command = slashCommand(in: content) {
            return .notice(command, isError: false)
        }
        return nil
    }

    // MARK: - User

    private func decodeUser(
        _ record: [String: Any],
        uuid: String,
        timestamp: Date?,
        into entry: inout AgentTranscriptEntry
    ) {
        // Meta records are context Claude Code injects (skill bodies, caveats),
        // not something the person typed.
        if record["isMeta"] as? Bool == true { return }
        guard let message = record["message"] as? [String: Any] else { return }

        if let text = message["content"] as? String {
            if let kind = Self.userTextKind(text) {
                entry.items = [AgentTimelineItem(id: uuid, timestamp: timestamp, kind: kind)]
            }
            return
        }
        guard let parts = message["content"] as? [[String: Any]] else { return }

        var texts: [String] = []
        var toolResults: [(id: String, result: AgentToolResult)] = []
        for part in parts {
            switch part["type"] as? String {
            case "text":
                if let text = part["text"] as? String { texts.append(text) }
            case "image":
                texts.append("[image]")
            case "tool_result":
                guard let callId = part["tool_use_id"] as? String else { continue }
                let result = AgentToolResult(
                    state: part["is_error"] as? Bool == true ? .failed : .succeeded,
                    output: AgentTimeline.excerpt(Self.toolResultText(part["content"])),
                    finishedAt: timestamp
                )
                toolResults.append((callId, result))
            default:
                continue
            }
        }

        // `toolUseResult` describes the single tool this record answers, so it
        // can only refine the result when there is exactly one.
        if toolResults.count == 1, let structured = record["toolUseResult"] as? [String: Any] {
            Self.refine(&toolResults[0].result, with: structured)
        }
        for (callId, result) in toolResults {
            entry.results[callId] = result
        }

        let joined = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if let kind = Self.promptKind(joined) {
            entry.items = [AgentTimelineItem(id: uuid, timestamp: timestamp, kind: kind)]
        }
    }

    /// What a plain-string user message shows. Claude Code stores slash
    /// commands, bash mode, and their output as tagged strings.
    private static func userTextKind(_ text: String) -> AgentTimelineItem.Kind? {
        if let command = slashCommand(in: text) {
            return .prompt(command)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for outputTag in ["<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>",
                          "<bash-stdout>", "<bash-stderr>"]
            where trimmed.hasPrefix(outputTag) {
            return nil
        }
        if let command = tagContent("bash-input", in: trimmed) {
            return .prompt("! " + command.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return promptKind(trimmed)
    }

    private static func promptKind(_ text: String) -> AgentTimelineItem.Kind? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("[Request interrupted by user") {
            return .notice("Interrupted", isError: false)
        }
        return .prompt(trimmed)
    }

    /// "/name args" from a `<command-name>` tagged string.
    private static func slashCommand(in text: String) -> String? {
        guard let rawName = tagContent("command-name", in: text) else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let command = name.hasPrefix("/") ? name : "/" + name
        let arguments = (tagContent("command-args", in: text) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return arguments.isEmpty ? command : command + " " + arguments
    }

    private static func tagContent(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    /// The text of a `tool_result` content, which is a string or an array of
    /// parts; images and tool references have nothing to show as output.
    private static func toolResultText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]] else { return nil }
        let texts = parts.compactMap { part -> String? in
            guard part["type"] as? String == "text" else { return nil }
            return part["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// Replaces the model-facing result text with what the tool actually did:
    /// the edit's patch, the created file, or the command's own output.
    private static func refine(_ result: inout AgentToolResult, with structured: [String: Any]) {
        if let hunks = structured["structuredPatch"] as? [[String: Any]], !hunks.isEmpty {
            let lines = hunks.flatMap { hunk -> [String] in
                let header = "@@ -\(intValue(hunk["oldStart"])),\(intValue(hunk["oldLines"]))"
                    + " +\(intValue(hunk["newStart"])),\(intValue(hunk["newLines"])) @@"
                return [header] + (hunk["lines"] as? [String] ?? [])
            }
            result.diff = AgentTimeline.diffExcerpt(lines.joined(separator: "\n"))
            result.output = nil
            return
        }
        if structured["type"] as? String == "create", let content = structured["content"] as? String {
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            let body = content.hasSuffix("\n") ? lines.dropLast() : lines[...]
            result.diff = AgentTimeline.diffExcerpt(body.map { "+" + $0 }.joined(separator: "\n"))
            result.output = nil
            return
        }
        if structured["stdout"] is String || structured["stderr"] is String {
            let streams = [structured["stdout"] as? String, structured["stderr"] as? String]
                .compactMap { $0?.trimmingCharacters(in: .newlines) }
                .filter { !$0.isEmpty }
            result.output = AgentTimeline.excerpt(streams.joined(separator: "\n"))
            if structured["interrupted"] as? Bool == true {
                result.state = .interrupted
            }
        }
    }

    private static func intValue(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    // MARK: - Assistant

    private func decodeAssistant(
        _ record: [String: Any],
        uuid: String,
        timestamp: Date?,
        into entry: inout AgentTranscriptEntry
    ) {
        let parts = (record["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []

        if record["isApiErrorMessage"] as? Bool == true {
            let text = parts
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = text.isEmpty ? (record["error"] as? String ?? "API error") : text
            entry.items = [AgentTimelineItem(id: uuid, timestamp: timestamp, kind: .notice(message, isError: true))]
            return
        }

        for (index, part) in parts.enumerated() {
            let itemId = parts.count > 1 ? "\(uuid)#\(index)" : uuid
            switch part["type"] as? String {
            case "thinking":
                let text = (part["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                entry.items.append(AgentTimelineItem(id: itemId, timestamp: timestamp, kind: .thinking(text)))
            case "redacted_thinking":
                entry.items.append(AgentTimelineItem(id: itemId, timestamp: timestamp, kind: .thinking("")))
            case "text":
                let text = (part["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                entry.items.append(AgentTimelineItem(id: itemId, timestamp: timestamp, kind: .reply(text)))
            case "tool_use":
                guard let callId = part["id"] as? String, let name = part["name"] as? String else { continue }
                let call = Self.toolCall(name: name, input: part["input"] as? [String: Any] ?? [:], cwd: cwd)
                entry.items.append(AgentTimelineItem(id: callId, timestamp: timestamp, kind: .tool(call)))
            case "server_tool_use":
                guard let callId = part["id"] as? String, let name = part["name"] as? String,
                      name != "advisor"
                else { continue }
                let input = part["input"] as? [String: Any] ?? [:]
                let call = name == "web_search"
                    ? Self.toolCall(name: "WebSearch", input: input, cwd: cwd)
                    : Self.toolCall(name: name, input: input, cwd: cwd)
                entry.items.append(AgentTimelineItem(id: callId, timestamp: timestamp, kind: .tool(call)))
            case "web_search_tool_result":
                guard let callId = part["tool_use_id"] as? String else { continue }
                entry.results[callId] = AgentToolResult(state: .succeeded, finishedAt: timestamp)
            default:
                continue
            }
        }
    }

    // MARK: - Tool display

    /// Name, one-line summary, and fuller detail for a tool call, picked per
    /// Claude Code tool so the row says what the call touches.
    static func toolCall(name: String, input: [String: Any], cwd: String?) -> AgentToolCall {
        func string(_ key: String) -> String? {
            guard let value = input[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        func path(_ key: String) -> String {
            string(key).map { AgentTimeline.displayPath($0, relativeTo: cwd) } ?? ""
        }

        switch name {
        case "Bash":
            let command = string("command") ?? ""
            let summary = string("description").map { AgentTimeline.firstLine($0) }
                ?? AgentTimeline.firstLine(command)
            let detail = command.contains("\n") || command != summary ? command : nil
            return AgentToolCall(name: name, summary: summary, detail: detail?.isEmpty == true ? nil : detail)
        case "Read", "Edit", "MultiEdit", "Write":
            return AgentToolCall(name: name, summary: path("file_path"))
        case "NotebookEdit":
            return AgentToolCall(name: name, summary: path("notebook_path"))
        case "Grep":
            let pattern = string("pattern") ?? ""
            let scope = string("path").map { " in " + AgentTimeline.displayPath($0, relativeTo: cwd) } ?? ""
            return AgentToolCall(name: name, summary: AgentTimeline.firstLine(pattern + scope))
        case "Glob":
            return AgentToolCall(name: name, summary: AgentTimeline.firstLine(string("pattern") ?? ""))
        case "WebFetch":
            return AgentToolCall(name: name, summary: string("url") ?? "")
        case "WebSearch", "ToolSearch":
            return AgentToolCall(name: name, summary: AgentTimeline.firstLine(string("query") ?? ""))
        case "Task", "Agent":
            let description = string("description") ?? ""
            let summary = string("subagent_type").map { description + " (\($0))" } ?? description
            return AgentToolCall(name: name, summary: AgentTimeline.firstLine(summary))
        case "TodoWrite":
            let count = (input["todos"] as? [Any])?.count ?? 0
            return AgentToolCall(name: name, summary: "Update todos (\(count))")
        case "Skill":
            return AgentToolCall(name: name, summary: string("skill") ?? string("command") ?? "")
        default:
            break
        }

        if name.hasPrefix("mcp__") {
            let qualified = name.dropFirst("mcp__".count)
            let label: String
            if let separator = qualified.range(of: "__") {
                label = "\(qualified[..<separator.lowerBound]) · \(qualified[separator.upperBound...])"
            } else {
                label = String(qualified)
            }
            let preferred = ["query", "prompt", "url", "path", "file_path", "title", "description", "task_id"]
                .lazy.compactMap(string).first
            return AgentToolCall(
                name: label,
                summary: preferred.map { AgentTimeline.firstLine($0) } ?? firstShortString(in: input)
            )
        }
        return AgentToolCall(name: name, summary: firstShortString(in: input))
    }

    /// The first short string argument, so unknown tools still say something.
    private static func firstShortString(in input: [String: Any]) -> String {
        for key in input.keys.sorted() {
            guard let value = input[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.count <= 200, !trimmed.contains("\n") {
                return AgentTimeline.firstLine(trimmed)
            }
        }
        return ""
    }
}
