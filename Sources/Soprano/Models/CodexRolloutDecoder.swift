import Foundation

/// Reads a Codex CLI rollout (`~/.codex/sessions/…/rollout-*.jsonl`).
///
/// Codex writes the finished work twice: as model-facing `response_item`
/// records and as `item_completed` events. The events carry status, exit
/// codes and diffs, so they are the source of truth; `response_item` calls
/// only stand in while the work is still running, and the `response_item`
/// messages are skipped because they also hold injected developer and
/// AGENTS.md text nobody typed.
struct CodexRolloutDecoder: AgentTranscriptDecoding {
    /// The session's working directory, for showing paths relative to it.
    private(set) var cwd: String?

    init() {}

    mutating func entry(forLine line: Data) -> AgentTranscriptEntry? {
        guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = record["type"] as? String,
              let payload = record["payload"] as? [String: Any]
        else { return nil }
        let timestamp = AgentTimeline.date(from: record["timestamp"])

        switch type {
        case "session_meta", "turn_context":
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { self.cwd = cwd }
            return nil
        case "event_msg":
            return event(payload, at: timestamp)
        case "response_item":
            return responseItem(payload, at: timestamp)
        default:
            return nil
        }
    }

    // MARK: - Events

    private func event(_ payload: [String: Any], at timestamp: Date?) -> AgentTranscriptEntry? {
        switch payload["type"] as? String {
        case "item_completed":
            guard let item = payload["item"] as? [String: Any],
                  let id = item["id"] as? String,
                  let kind = completedKind(item)
            else { return nil }
            var timelineItem = AgentTimelineItem(id: id, timestamp: timestamp, kind: kind)
            if case .tool(var call) = kind {
                call.finishedAt = timestamp
                timelineItem.kind = .tool(call)
            }
            return AgentTranscriptEntry(items: [timelineItem])
        case "turn_aborted":
            let turn = payload["turn_id"] as? String ?? UUID().uuidString
            return AgentTranscriptEntry(items: [
                AgentTimelineItem(id: "aborted-\(turn)", timestamp: timestamp, kind: .notice("Interrupted", isError: false)),
            ])
        case "error":
            let message = (payload["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Error"
            return AgentTranscriptEntry(items: [
                AgentTimelineItem(id: "error-\(timestamp?.timeIntervalSince1970 ?? 0)-\(message.hashValue)",
                                  timestamp: timestamp, kind: .notice(message, isError: true)),
            ])
        default:
            return nil
        }
    }

    private func completedKind(_ item: [String: Any]) -> AgentTimelineItem.Kind? {
        switch item["type"] as? String {
        case "UserMessage":
            let parts = (item["content"] as? [[String: Any]] ?? []).compactMap { part -> String? in
                switch part["type"] as? String {
                case "text": return part["text"] as? String
                case "image", "local_image": return "[image]"
                default: return nil
                }
            }
            let text = parts.joined(separator: "\n")
            return text.isEmpty ? nil : .prompt(text)
        case "AgentMessage":
            let text = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : .reply(text)
        case "Reasoning":
            let text = (item["summary_text"] as? [String] ?? []).joined(separator: "\n\n")
            return text.isEmpty ? nil : .thinking(text)
        case "CommandExecution":
            return .tool(commandCall(item))
        case "FileChange":
            return fileChangeCall(item).map { .tool($0) }
        case "McpToolCall":
            return .tool(mcpCall(item))
        case "Extension":
            let kind = item["kind"] as? String ?? "Extension"
            if kind == "web.search" { return .tool(webSearchCall(item)) }
            return .tool(AgentToolCall(name: kind, summary: "", state: .succeeded))
        case "WebSearch":
            return .tool(webSearchCall(item))
        case "ContextCompaction":
            return .notice("Context compacted", isError: false)
        default:
            return nil
        }
    }

    private func commandCall(_ item: [String: Any]) -> AgentToolCall {
        let command = (item["command"] as? [String])?.last ?? item["command"] as? String ?? ""
        let parsed = (item["parsed_cmd"] as? [[String: Any]])?.first
        let name: String
        var summary: String
        switch parsed?["type"] as? String {
        case "read":
            name = "Read"
            summary = (parsed?["path"] as? String).map { AgentTimeline.displayPath($0, relativeTo: cwd) }
                ?? AgentTimeline.firstLine(command)
        case "search":
            name = "Search"
            summary = AgentTimeline.firstLine(parsed?["cmd"] as? String ?? command)
        case "list_files", "list":
            name = "List"
            summary = AgentTimeline.firstLine(parsed?["cmd"] as? String ?? command)
        default:
            name = "Run"
            summary = AgentTimeline.firstLine(command)
        }
        if summary.isEmpty { summary = AgentTimeline.firstLine(command) }
        let detail = command.contains("\n") || command != summary ? command : nil

        let exitCode = (item["exit_code"] as? NSNumber)?.intValue
        let state: AgentToolCall.State
        switch item["status"] as? String {
        case "failed": state = .failed
        case "declined", "interrupted", "cancelled": state = .interrupted
        case "in_progress": state = .running
        default: state = (exitCode ?? 0) == 0 ? .succeeded : .failed
        }
        return AgentToolCall(name: name, summary: summary, detail: detail, state: state,
                             output: AgentTimeline.excerpt(item["aggregated_output"] as? String))
    }

    private func fileChangeCall(_ item: [String: Any]) -> AgentToolCall? {
        guard let changes = item["changes"] as? [String: [String: Any]], !changes.isEmpty else { return nil }
        let paths = changes.keys.sorted()
        let first = changes[paths[0]] ?? [:]
        let name: String
        if paths.count > 1 {
            name = "Edit"
        } else {
            switch first["type"] as? String {
            case "add": name = "Add"
            case "delete": name = "Delete"
            default: name = "Edit"
            }
        }
        var summary = AgentTimeline.displayPath(paths[0], relativeTo: cwd)
        if paths.count > 1 { summary += " +\(paths.count - 1) more" }

        let diffs = paths.compactMap { path -> String? in
            guard let change = changes[path], let diff = Self.diff(for: change) else { return nil }
            guard paths.count > 1 else { return diff }
            return "diff \(AgentTimeline.displayPath(path, relativeTo: cwd))\n" + diff
        }
        let state: AgentToolCall.State
        switch item["status"] as? String {
        case "failed": state = .failed
        case "declined": state = .interrupted
        default: state = .succeeded
        }
        return AgentToolCall(name: name, summary: summary, state: state,
                             diff: AgentTimeline.diffExcerpt(diffs.isEmpty ? nil : diffs.joined(separator: "\n")))
    }

    /// Added files store their whole text in `content` instead of a diff, and
    /// deleted ones may too; both read best as all-plus or all-minus lines.
    private static func diff(for change: [String: Any]) -> String? {
        if let diff = change["unified_diff"] as? String, !diff.isEmpty { return diff }
        guard let content = change["content"] as? String, !content.isEmpty else { return nil }
        let marker = change["type"] as? String == "delete" ? "-" : "+"
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        return lines.map { marker + $0 }.joined(separator: "\n")
    }

    private func mcpCall(_ item: [String: Any]) -> AgentToolCall {
        let server = item["server"] as? String ?? ""
        let tool = item["tool"] as? String ?? ""
        let name = server.isEmpty ? tool : "\(server).\(tool)"
        let summary = Self.summary(ofArguments: item["arguments"] as? [String: Any] ?? [:],
                                   keys: ["title", "description", "query", "path"], fallbackToShortString: true)
        let result = item["result"] as? [String: Any]
        var output = (result?["content"] as? [[String: Any]] ?? [])
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
        if output.isEmpty, let error = item["error"] as? String ?? (item["error"] as? [String: Any])?["message"] as? String {
            output = error
        }
        let failed = item["status"] as? String == "failed" || result?["isError"] as? Bool == true || item["error"] is String
        return AgentToolCall(name: name, summary: summary, state: failed ? .failed : .succeeded,
                             output: AgentTimeline.excerpt(output))
    }

    private func webSearchCall(_ item: [String: Any]) -> AgentToolCall {
        let action = item["action"] as? [String: Any]
        let query = item["query"] as? String ?? action?["query"] as? String ?? ""
        return AgentToolCall(name: "WebSearch", summary: AgentTimeline.firstLine(query), state: .succeeded)
    }

    // MARK: - Response items

    private func responseItem(_ payload: [String: Any], at timestamp: Date?) -> AgentTranscriptEntry? {
        switch payload["type"] as? String {
        case "function_call", "custom_tool_call", "local_shell_call":
            guard let callId = payload["call_id"] as? String ?? payload["id"] as? String else { return nil }
            let call = provisionalCall(payload)
            return AgentTranscriptEntry(items: [AgentTimelineItem(id: callId, timestamp: timestamp, kind: .tool(call))])
        case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
            guard let callId = payload["call_id"] as? String else { return nil }
            return AgentTranscriptEntry(droppedItemIds: [callId])
        default:
            return nil
        }
    }

    private func provisionalCall(_ payload: [String: Any]) -> AgentToolCall {
        let name = payload["name"] as? String ?? ""
        switch payload["type"] as? String {
        case "custom_tool_call":
            let input = payload["input"] as? String ?? ""
            if name == "exec" {
                let command = Self.firstCmdLiteral(in: input) ?? input
                let summary = AgentTimeline.firstLine(command)
                return AgentToolCall(name: "Run", summary: summary, detail: input == summary ? nil : input)
            }
            return AgentToolCall(name: name, summary: AgentTimeline.firstLine(input))
        case "local_shell_call":
            let action = payload["action"] as? [String: Any]
            let command = (action?["command"] as? [String])?.last ?? ""
            return AgentToolCall(name: "Run", summary: AgentTimeline.firstLine(command))
        default:
            var label = name
            if var namespace = payload["namespace"] as? String, !namespace.isEmpty {
                if namespace.hasPrefix("mcp__") { namespace.removeFirst(5) }
                label = "\(namespace).\(name)"
            }
            let arguments = (payload["arguments"] as? String)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            let summary = Self.summary(ofArguments: arguments,
                                       keys: ["title", "command", "cmd", "query", "path"], fallbackToShortString: false)
            return AgentToolCall(name: label, summary: summary)
        }
    }

    private static func summary(ofArguments arguments: [String: Any], keys: [String], fallbackToShortString: Bool) -> String {
        for key in keys {
            if let value = arguments[key] as? String, !value.isEmpty { return AgentTimeline.firstLine(value) }
            if let value = arguments[key] as? [String], let last = value.last { return AgentTimeline.firstLine(last) }
        }
        guard fallbackToShortString else { return "" }
        let short = arguments.keys.sorted().lazy
            .compactMap { arguments[$0] as? String }
            .first { !$0.isEmpty && $0.count <= 160 && !$0.contains("\n") }
        return short.map { AgentTimeline.firstLine($0) } ?? ""
    }

    /// Code-mode `exec` sends JavaScript; the shell command it runs is the
    /// first `cmd: "…"` literal, which says far more than the script's first line.
    static func firstCmdLiteral(in source: String) -> String? {
        guard let range = source.range(of: #"cmd\s*:\s*(\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*')"#,
                                       options: .regularExpression)
        else { return nil }
        let match = source[range]
        guard let quoteIndex = match.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        let body = match[match.index(after: quoteIndex)..<match.index(before: match.endIndex)]
        var result = ""
        var iterator = body.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let escaped = iterator.next() else {
                result.append(character)
                continue
            }
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            default: result.append(escaped)
            }
        }
        return result
    }
}
