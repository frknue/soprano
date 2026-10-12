import Foundation

/// Reads omp's session files (`~/.omp/agent/sessions/<cwd>/<id>.jsonl`).
/// Every record after the header hangs off its parent, so rewinding starts a
/// new branch; records that show nothing still stay as nodes so the branch
/// walk can pass through them.
struct OmpSessionDecoder: AgentTranscriptDecoding {
    /// From the session header; tool paths are shown relative to it.
    private(set) var cwd: String?

    init() {}

    mutating func entry(forLine line: Data) -> AgentTranscriptEntry? {
        guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = record["type"] as? String
        else { return nil }

        if type == "session" {
            cwd = record["cwd"] as? String
            return nil
        }
        // Records outside the tree, such as `title`, carry no id.
        guard let id = record["id"] as? String else { return nil }

        var entry = AgentTranscriptEntry(id: id, parentId: record["parentId"] as? String)
        let timestamp = AgentTimeline.date(from: record["timestamp"])
        switch type {
        case "message":
            if let message = record["message"] as? [String: Any] {
                decode(message, id: id, timestamp: timestamp, into: &entry)
            }
        case "compaction":
            entry.items = [AgentTimelineItem(
                id: id, timestamp: timestamp, kind: .notice("Context compacted", isError: false)
            )]
        default:
            break
        }
        return entry
    }

    private func decode(
        _ message: [String: Any], id: String, timestamp: Date?, into entry: inout AgentTranscriptEntry
    ) {
        switch message["role"] as? String {
        case "user":
            // omp marks messages it injects itself; only what the person typed is a prompt.
            if let attribution = message["attribution"] as? String, attribution != "user" { return }
            let text = Self.promptText(message["content"])
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            entry.items = [AgentTimelineItem(id: id, timestamp: timestamp, kind: .prompt(text))]
        case "assistant":
            entry.items = assistantItems(message, id: id, timestamp: timestamp)
        case "toolResult":
            guard let callId = message["toolCallId"] as? String else { return }
            entry.results[callId] = result(message, finishedAt: timestamp)
        default:
            // `developer` carries system reminders, which must never show.
            break
        }
    }

    private static func promptText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.compactMap { part -> String? in
            switch part["type"] as? String {
            case "text": part["text"] as? String
            case "image": "[image]"
            default: nil
            }
        }
        .joined(separator: "\n")
    }

    private func assistantItems(_ message: [String: Any], id: String, timestamp: Date?) -> [AgentTimelineItem] {
        var items: [AgentTimelineItem] = []
        let parts = message["content"] as? [[String: Any]] ?? []
        for (index, part) in parts.enumerated() {
            let itemId = "\(id)#\(index)"
            switch part["type"] as? String {
            case "thinking":
                let thinking = part["thinking"] as? String ?? ""
                items.append(AgentTimelineItem(id: itemId, timestamp: timestamp, kind: .thinking(thinking)))
            case "text":
                guard let text = part["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                items.append(AgentTimelineItem(id: itemId, timestamp: timestamp, kind: .reply(text)))
            case "toolCall":
                guard let callId = part["id"] as? String else { continue }
                items.append(AgentTimelineItem(id: callId, timestamp: timestamp, kind: .tool(toolCall(part))))
            default:
                continue
            }
        }

        switch message["stopReason"] as? String {
        case "error":
            if let error = message["errorMessage"] as? String, !error.isEmpty {
                items.append(AgentTimelineItem(
                    id: "\(id)#error", timestamp: timestamp, kind: .notice(error, isError: true)
                ))
            }
        case "aborted":
            items.append(AgentTimelineItem(
                id: "\(id)#aborted", timestamp: timestamp, kind: .notice("Interrupted", isError: false)
            ))
        default:
            break
        }
        return items
    }

    private func toolCall(_ part: [String: Any]) -> AgentToolCall {
        let name = part["name"] as? String ?? "tool"
        let arguments = part["arguments"] as? [String: Any] ?? [:]
        // The agent's own one-line description of the call.
        let intent = nonEmpty(part["intent"]) ?? nonEmpty(arguments["i"])
        let path = nonEmpty(arguments["path"]).map { AgentTimeline.displayPath($0, relativeTo: cwd) }

        switch name {
        case "bash":
            let command = arguments["command"] as? String ?? ""
            let summary = intent ?? AgentTimeline.firstLine(command)
            let detail = command.isEmpty || command == summary ? nil : command
            return AgentToolCall(name: "Bash", summary: summary, detail: detail)
        case "read":
            return AgentToolCall(name: "Read", summary: path ?? intent ?? "")
        case "edit":
            return AgentToolCall(name: "Edit", summary: intent ?? "")
        case "write":
            return AgentToolCall(name: "Write", summary: path ?? intent ?? "")
        case "grep":
            let pattern = arguments["pattern"] as? String ?? ""
            return AgentToolCall(name: "Grep", summary: path.map { "\(pattern) in \($0)" } ?? pattern)
        case "glob":
            return AgentToolCall(name: "Glob", summary: path ?? intent ?? "")
        case "eval":
            return AgentToolCall(name: "Eval", summary: nonEmpty(arguments["title"]) ?? intent ?? "")
        case "web_search":
            return AgentToolCall(name: "WebSearch", summary: nonEmpty(arguments["query"]) ?? intent ?? "")
        case "task":
            return AgentToolCall(name: "Task", summary: intent ?? "")
        case "todo":
            return AgentToolCall(name: "Todo", summary: intent ?? "")
        case "ask":
            let questions = arguments["questions"] as? [[String: Any]] ?? []
            let question = questions.lazy.compactMap { nonEmpty($0["question"]) }.first
            return AgentToolCall(
                name: "Ask", summary: question.map { AgentTimeline.firstLine($0) } ?? intent ?? ""
            )
        default:
            return AgentToolCall(name: name.prefix(1).uppercased() + name.dropFirst(), summary: intent ?? "")
        }
    }

    private func result(_ message: [String: Any], finishedAt: Date?) -> AgentToolResult {
        let details = message["details"] as? [String: Any] ?? [:]
        let exitCode = (details["exitCode"] as? NSNumber)?.intValue ?? 0
        let failed = message["isError"] as? Bool == true || exitCode != 0
        let text = (message["content"] as? [[String: Any]] ?? [])
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
        var result = AgentToolResult(
            state: failed ? .failed : .succeeded,
            output: AgentTimeline.excerpt(text),
            finishedAt: finishedAt
        )

        let toolName = message["toolName"] as? String
        if toolName == "edit" || toolName == "write",
           let diff = (details["diff"] as? String).flatMap(Self.unifiedDiff) {
            result.diff = AgentTimeline.diffExcerpt(diff)
            result.output = nil
            result.summary = changedPaths(details)
        }
        return result
    }

    /// The edited file, or every file of a multi-file edit, whose results
    /// list their paths per file instead.
    private func changedPaths(_ details: [String: Any]) -> String? {
        let paths: [String]
        if let path = nonEmpty(details["path"]) {
            paths = [path]
        } else {
            paths = (details["perFileResults"] as? [[String: Any]] ?? []).compactMap { nonEmpty($0["path"]) }
        }
        guard !paths.isEmpty else { return nil }
        return paths.map { AgentTimeline.displayPath($0, relativeTo: cwd) }.joined(separator: ", ")
    }

    /// omp numbers every diff line (` 12|kept`, `-13|old`, `+13|new`) and
    /// separates hunks with an empty line; the timeline wants plain unified
    /// lines with `@@` between hunks.
    private static func unifiedDiff(_ diff: String) -> String? {
        var lines: [String] = []
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let op = line.first, op == " " || op == "+" || op == "-",
                  let bar = line.firstIndex(of: "|"),
                  line[line.index(after: line.startIndex)..<bar].allSatisfy(\.isNumber)
            else {
                if line.isEmpty, let last = lines.last, last != "@@" { lines.append("@@") }
                continue
            }
            lines.append(String(op) + line[line.index(after: bar)...])
        }
        while lines.last == "@@" { lines.removeLast() }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return string
    }
}
