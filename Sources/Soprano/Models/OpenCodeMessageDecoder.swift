import Foundation

/// Maps OpenCode's stored messages to timeline entries. OpenCode keeps a
/// session in SQLite instead of JSON Lines: 2.x writes one `session_message`
/// row per message, its assistant content inline or in `session_part` rows,
/// and 1.x one `message` row whose content lives in `part` rows. Both arrive
/// here as the rows' JSON, so the mapping needs no database.
struct OpenCodeMessageDecoder: Sendable {
    /// One `session_part` row: the content item's `type` column and its JSON,
    /// which leaves the type out.
    struct PartRow: Equatable, Sendable {
        var type: String
        var data: Data
    }

    /// The session's directory; tool paths are shown relative to it.
    var cwd: String?

    init(cwd: String? = nil) {
        self.cwd = cwd
    }

    // MARK: - OpenCode 2.x

    /// The entry for one 2.x `session_message` row. An assistant row's `parts`,
    /// in ordinal order, replace its inline `content` when there are any.
    func entry(id: String, type: String, data: Data, parts: [PartRow] = []) -> AgentTranscriptEntry {
        guard let message = Self.object(data) else { return AgentTranscriptEntry() }
        let timestamp = Self.date(Self.dictionary(message["time"])["created"])
        var items: [AgentTimelineItem] = []

        switch type {
        case "user":
            let files = message["files"] as? [[String: Any]] ?? []
            let placeholders = files.map { Self.placeholder(mime: $0["mime"] as? String, name: $0["name"] as? String) }
            if let text = Self.prompt([message["text"] as? String ?? ""] + placeholders) {
                items = [AgentTimelineItem(id: id, timestamp: timestamp, kind: .prompt(text))]
            }
        case "assistant":
            var content = message["content"] as? [[String: Any]] ?? []
            if !parts.isEmpty {
                content = parts.compactMap { part in
                    guard var item = Self.object(part.data) else { return nil }
                    item["type"] = part.type
                    return item
                }
            }
            for (index, item) in content.enumerated() {
                if let timelineItem = contentItem(item, messageId: id, index: index, timestamp: timestamp) {
                    items.append(timelineItem)
                }
            }
            if let error = message["error"] as? [String: Any] {
                // Pressing Esc aborts the step; that is an interruption, not a failure.
                let notice: AgentTimelineItem.Kind = error["type"] as? String == "aborted"
                    ? .notice("Interrupted", isError: false)
                    : .notice(Self.nonEmpty(error["message"]) ?? Self.nonEmpty(error["type"]) ?? "Error", isError: true)
                items.append(AgentTimelineItem(id: "\(id)#error", timestamp: timestamp, kind: notice))
            }
        case "idle":
            switch message["outcome"] as? String {
            case "interrupted":
                items = [AgentTimelineItem(id: id, timestamp: timestamp, kind: .notice("Interrupted", isError: false))]
            case "failed":
                let text = Self.nonEmpty(Self.dictionary(message["error"])["message"]) ?? "Failed"
                items = [AgentTimelineItem(id: id, timestamp: timestamp, kind: .notice(text, isError: true))]
            default:
                break
            }
        case "compaction":
            let kind: AgentTimelineItem.Kind
            if message["status"] as? String == "failed" {
                let reason = Self.nonEmpty(Self.dictionary(message["error"])["message"])
                kind = .notice(reason.map { "Context compaction failed: \($0)" } ?? "Context compaction failed", isError: true)
            } else {
                kind = .notice("Context compacted", isError: false)
            }
            items = [AgentTimelineItem(id: id, timestamp: timestamp, kind: kind)]
        case "shell":
            items = [AgentTimelineItem(id: id, timestamp: timestamp, kind: .tool(shellCall(message)))]
        default:
            // `synthetic` and `system` are injected rather than typed; skills
            // and agent, model and location switches have nothing to show.
            break
        }
        return AgentTranscriptEntry(items: items)
    }

    private func contentItem(
        _ item: [String: Any], messageId: String, index: Int, timestamp: Date?
    ) -> AgentTimelineItem? {
        let itemId = "\(messageId)#\(index)"
        switch item["type"] as? String {
        case "text":
            guard let text = Self.nonEmpty(item["text"]) else { return nil }
            return AgentTimelineItem(id: itemId, timestamp: timestamp, kind: .reply(text))
        case "reasoning":
            // Empty when the provider returned only encrypted reasoning.
            return AgentTimelineItem(id: itemId, timestamp: timestamp, kind: .thinking(item["text"] as? String ?? ""))
        case "tool":
            guard let callId = item["id"] as? String else { return nil }
            let state = Self.dictionary(item["state"])
            let time = Self.dictionary(item["time"])
            let metadata = Self.dictionary(state["metadata"])
            let callState: AgentToolCall.State
            switch state["status"] as? String {
            case "completed": callState = Self.exitedNonZero(metadata) ? .failed : .succeeded
            case "error": callState = .failed
            default: callState = .running
            }
            let content = (state["content"] as? [[String: Any]] ?? [])
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
            let error = Self.dictionary(state["error"])["message"] as? String
            return AgentTimelineItem(
                id: callId,
                timestamp: Self.date(time["created"]) ?? timestamp,
                kind: .tool(toolCall(
                    name: item["name"] as? String ?? "tool",
                    // A streaming call's input is still a partial JSON string.
                    input: Self.dictionary(state["input"]),
                    metadata: metadata,
                    state: callState,
                    output: [content, error ?? ""].filter { !$0.isEmpty }.joined(separator: "\n"),
                    finishedAt: Self.date(time["completed"])
                ))
            )
        default:
            return nil
        }
    }

    /// A command the person ran from OpenCode's prompt with `!`.
    private func shellCall(_ message: [String: Any]) -> AgentToolCall {
        let command = message["command"] as? String ?? ""
        let summary = AgentTimeline.firstLine(command)
        let exit = (message["exit"] as? NSNumber)?.intValue
        let state: AgentToolCall.State
        switch message["status"] as? String {
        case "exited": state = (exit ?? 0) == 0 ? .succeeded : .failed
        case "timeout", "killed": state = .failed
        default: state = .running
        }
        let output: String?
        if let text = message["output"] as? String {
            output = text
        } else {
            let object = Self.dictionary(message["output"])
            output = object["text"] as? String ?? object["content"] as? String
        }
        return AgentToolCall(
            name: "Shell",
            summary: summary,
            detail: command.isEmpty || command == summary ? nil : command,
            state: state,
            output: AgentTimeline.excerpt(output),
            finishedAt: Self.date(Self.dictionary(message["time"])["completed"])
        )
    }

    // MARK: - OpenCode 1.x

    /// The entry for one 1.x `message` row and its `part` rows in id order.
    func legacyEntry(id: String, data: Data, parts: [Data]) -> AgentTranscriptEntry {
        guard let message = Self.object(data) else { return AgentTranscriptEntry() }
        let timestamp = Self.date(Self.dictionary(message["time"])["created"])
        let parts = parts.compactMap(Self.object)
        var items: [AgentTimelineItem] = []

        switch message["role"] as? String {
        case "user":
            var lines: [String] = []
            var compacted = false
            for part in parts {
                switch part["type"] as? String {
                case "text" where part["synthetic"] as? Bool != true:
                    lines.append(part["text"] as? String ?? "")
                case "file":
                    lines.append(Self.placeholder(mime: part["mime"] as? String, name: part["filename"] as? String))
                case "compaction":
                    compacted = true
                default:
                    continue
                }
            }
            if let text = Self.prompt(lines) {
                items.append(AgentTimelineItem(id: id, timestamp: timestamp, kind: .prompt(text)))
            }
            if compacted {
                items.append(AgentTimelineItem(
                    id: "\(id)#compaction", timestamp: timestamp, kind: .notice("Context compacted", isError: false)
                ))
            }
        case "assistant":
            // A compaction's summary is written as an assistant message.
            let isSummary = message["summary"] as? Bool == true
            for (index, part) in parts.enumerated() {
                let itemId = "\(id)#\(index)"
                switch part["type"] as? String {
                case "text":
                    guard !isSummary, part["synthetic"] as? Bool != true,
                          let text = Self.nonEmpty(part["text"])
                    else { continue }
                    items.append(AgentTimelineItem(id: itemId, timestamp: timestamp, kind: .reply(text)))
                case "reasoning":
                    items.append(AgentTimelineItem(
                        id: itemId, timestamp: timestamp, kind: .thinking(part["text"] as? String ?? "")
                    ))
                case "tool":
                    items.append(legacyToolItem(part, fallbackId: itemId, timestamp: timestamp))
                default:
                    continue
                }
            }
            if let error = message["error"] as? [String: Any] {
                if error["name"] as? String == "MessageAbortedError" {
                    items.append(AgentTimelineItem(
                        id: "\(id)#error", timestamp: timestamp, kind: .notice("Interrupted", isError: false)
                    ))
                } else {
                    let text = Self.nonEmpty(Self.dictionary(error["data"])["message"])
                        ?? Self.nonEmpty(error["name"]) ?? "Error"
                    items.append(AgentTimelineItem(id: "\(id)#error", timestamp: timestamp, kind: .notice(text, isError: true)))
                }
            }
        default:
            break
        }
        return AgentTranscriptEntry(items: items)
    }

    private func legacyToolItem(_ part: [String: Any], fallbackId: String, timestamp: Date?) -> AgentTimelineItem {
        let state = Self.dictionary(part["state"])
        let time = Self.dictionary(state["time"])
        let metadata = Self.dictionary(state["metadata"])
        let callState: AgentToolCall.State
        switch state["status"] as? String {
        case "completed": callState = Self.exitedNonZero(metadata) ? .failed : .succeeded
        case "error": callState = .failed
        default: callState = .running
        }
        let output = [state["output"] as? String ?? "", state["error"] as? String ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return AgentTimelineItem(
            id: Self.nonEmpty(part["callID"]) ?? Self.nonEmpty(part["id"]) ?? fallbackId,
            timestamp: Self.date(time["start"]) ?? timestamp,
            kind: .tool(toolCall(
                name: part["tool"] as? String ?? "tool",
                input: Self.dictionary(state["input"]),
                metadata: metadata,
                state: callState,
                output: output,
                finishedAt: Self.date(time["end"])
            ))
        )
    }

    // MARK: - Tool calls

    private static let editingTools: Set<String> = ["edit", "write", "patch", "apply_patch"]

    private func toolCall(
        name: String,
        input: [String: Any],
        metadata: [String: Any],
        state: AgentToolCall.State,
        output: String,
        finishedAt: Date?
    ) -> AgentToolCall {
        var call = describe(name: name, input: input)
        call.state = state
        call.output = AgentTimeline.excerpt(output)
        call.finishedAt = finishedAt
        if Self.editingTools.contains(name), let change = fileChange(metadata) {
            call.diff = change.diff
            call.output = nil
            if let paths = change.paths { call.summary = paths }
        }
        return call
    }

    private func describe(name: String, input: [String: Any]) -> AgentToolCall {
        // 2.x tools take `path`; sessions migrated from 1.x keep `filePath`.
        let path = (Self.nonEmpty(input["path"]) ?? Self.nonEmpty(input["filePath"])).map(display)
        func searched(_ label: String) -> AgentToolCall {
            let pattern = input["pattern"] as? String ?? ""
            return AgentToolCall(name: label, summary: path.map { "\(pattern) in \($0)" } ?? pattern)
        }

        switch name {
        case "shell", "bash":
            let command = input["command"] as? String ?? ""
            let summary = AgentTimeline.firstLine(command)
            return AgentToolCall(name: "Bash", summary: summary, detail: command.isEmpty || command == summary ? nil : command)
        case "read":
            return AgentToolCall(name: "Read", summary: path ?? "")
        case "edit":
            return AgentToolCall(name: "Edit", summary: path ?? "")
        case "write":
            return AgentToolCall(name: "Write", summary: path ?? "")
        case "patch", "apply_patch":
            let patchPath = (input["patchText"] as? String).flatMap(Self.firstPatchPath).map(display)
            return AgentToolCall(name: "Edit", summary: patchPath ?? "")
        case "glob":
            return searched("Glob")
        case "grep":
            return searched("Grep")
        case "webfetch":
            return AgentToolCall(name: "WebFetch", summary: Self.nonEmpty(input["url"]) ?? "")
        case "websearch":
            return AgentToolCall(name: "WebSearch", summary: Self.nonEmpty(input["query"]).map { AgentTimeline.firstLine($0) } ?? "")
        case "subagent", "task":
            return AgentToolCall(name: "Task", summary: Self.nonEmpty(input["description"]).map { AgentTimeline.firstLine($0) } ?? "")
        case "todowrite":
            let count = (input["todos"] as? [Any])?.count ?? 0
            return AgentToolCall(name: "Todo", summary: count == 1 ? "1 todo" : "\(count) todos")
        case "question":
            let questions = input["questions"] as? [[String: Any]] ?? []
            let question = questions.lazy.compactMap { Self.nonEmpty($0["question"]) }.first
            return AgentToolCall(name: "Ask", summary: question.map { AgentTimeline.firstLine($0) } ?? "")
        case "skill":
            // 1.x names the skill, 2.x passes its id.
            return AgentToolCall(name: "Skill", summary: Self.nonEmpty(input["name"]) ?? Self.nonEmpty(input["id"]) ?? "")
        default:
            // MCP tools arrive as `<server>_<tool>`.
            return AgentToolCall(name: name, summary: Self.summary(ofArguments: input))
        }
    }

    private static func summary(ofArguments arguments: [String: Any]) -> String {
        for key in ["title", "description", "query", "path", "filePath", "url", "command"] {
            if let value = nonEmpty(arguments[key]) { return AgentTimeline.firstLine(value) }
        }
        let short = arguments.keys.sorted().lazy
            .compactMap { arguments[$0] as? String }
            .first { !$0.isEmpty && $0.count <= 160 && !$0.contains("\n") }
        return short.map { AgentTimeline.firstLine($0) } ?? ""
    }

    /// The first file an `apply_patch` envelope names, before its result
    /// lists every changed file.
    private static func firstPatchPath(_ patchText: String) -> String? {
        for line in patchText.split(whereSeparator: \.isNewline) {
            for marker in ["*** Add File: ", "*** Update File: ", "*** Delete File: "] where line.hasPrefix(marker) {
                return nonEmpty(String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    // MARK: - Diffs

    /// The hunks an edit, write or patch result recorded, and the files they
    /// changed. 2.x lists each file with its own patch; 1.x keeps one diff
    /// text that may cover several files, or one `filediff`.
    private func fileChange(_ metadata: [String: Any]) -> (diff: String, paths: String?)? {
        var patches: [(path: String?, patch: String)] = []
        if let files = metadata["files"] as? [[String: Any]], !files.isEmpty {
            patches = files.compactMap { file in
                guard let patch = file["patch"] as? String else { return nil }
                return (Self.nonEmpty(file["file"]) ?? Self.nonEmpty(file["filePath"]), patch)
            }
        } else if let diff = metadata["diff"] as? String {
            patches = [(nil, diff)]
        } else if let filediff = metadata["filediff"] as? [String: Any], let patch = filediff["patch"] as? String {
            patches = [(Self.nonEmpty(filediff["file"]), patch)]
        }

        var sections: [(path: String?, lines: [String])] = []
        for (path, patch) in patches {
            let parsed = Self.hunks(of: patch)
            if parsed.count == 1, let path {
                sections.append((path, parsed[0].lines))
            } else {
                sections.append(contentsOf: parsed)
            }
        }
        guard !sections.isEmpty else { return nil }

        let diff = sections.map { section -> String in
            let body = section.lines.joined(separator: "\n")
            guard sections.count > 1, let path = section.path else { return body }
            return "diff \(display(path))\n" + body
        }
        .joined(separator: "\n")
        guard let excerpt = AgentTimeline.diffExcerpt(diff) else { return nil }

        let paths = sections.compactMap(\.path).map(display)
        return (excerpt, paths.isEmpty ? nil : paths.joined(separator: ", "))
    }

    /// Splits a unified diff into its files and keeps only hunk lines: the
    /// `Index:`, `====`, `---` and `+++` headers and `\ No newline` markers go.
    /// Hunk line counts decide where a hunk ends, so a removed line that
    /// starts with `--` is never taken for a header.
    private static func hunks(of patch: String) -> [(path: String?, lines: [String])] {
        var sections: [(path: String?, lines: [String])] = []
        var lines: [String] = []
        var indexPath: String?
        var oldPath: String?
        var newPath: String?
        var oldLeft = 0
        var newLeft = 0
        // Inside a hunk whose header carries no line counts.
        var uncounted = false

        func flush() {
            if !lines.isEmpty {
                sections.append((newPath ?? oldPath ?? indexPath, lines))
            }
            lines = []
            indexPath = nil
            oldPath = nil
            newPath = nil
            uncounted = false
        }

        for rawLine in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.hasPrefix("\\") { continue }
            if oldLeft > 0 || newLeft > 0 {
                switch line.first {
                case "+": newLeft -= 1
                case "-": oldLeft -= 1
                default:
                    oldLeft -= 1
                    newLeft -= 1
                }
                lines.append(line.isEmpty ? " " : line)
                continue
            }
            if line.hasPrefix("@@") {
                lines.append(line)
                if let counts = hunkCounts(line) {
                    (oldLeft, newLeft) = counts
                    uncounted = false
                } else {
                    uncounted = true
                }
            } else if line.hasPrefix("Index: ") || line.hasPrefix("diff --git ") {
                flush()
                if line.hasPrefix("Index: ") { indexPath = headerPath(line) }
            } else if line.hasPrefix("--- ") {
                if !lines.isEmpty { flush() }
                oldPath = headerPath(line)
            } else if line.hasPrefix("+++ ") {
                newPath = headerPath(line)
            } else if uncounted, let first = line.first, first == "+" || first == "-" || first == " " {
                lines.append(line)
            }
        }
        flush()
        return sections
    }

    /// The old and new line counts of an `@@ -a,b +c,d @@` header; an omitted
    /// count means one line.
    private static func hunkCounts(_ header: String) -> (Int, Int)? {
        var old: Int?
        var new: Int?
        for token in header.split(separator: " ").dropFirst() {
            guard token != "@@" else { break }
            guard let sign = token.first, sign == "-" || sign == "+" else { return nil }
            let range = token.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard range.count <= 2, Int(range[0]) != nil else { return nil }
            let count = range.count == 2 ? Int(range[1]) : 1
            if sign == "-" { old = count } else { new = count }
        }
        guard let old, let new else { return nil }
        return (old, new)
    }

    /// The file a diff header names, without the timestamp after a tab;
    /// `/dev/null` names none.
    private static func headerPath(_ line: String) -> String? {
        let rest = line.drop { $0 != " " }.dropFirst()
        let path = rest.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return path.isEmpty || path == "/dev/null" ? nil : path
    }

    // MARK: - Helpers

    private func display(_ path: String) -> String {
        AgentTimeline.displayPath(path, relativeTo: cwd)
    }

    /// Whether a shell tool reported a non-zero exit code.
    private static func exitedNonZero(_ metadata: [String: Any]) -> Bool {
        guard let exit = metadata["exit"] as? NSNumber else { return false }
        return exit.intValue != 0
    }

    private static func placeholder(mime: String?, name: String?) -> String {
        if mime?.hasPrefix("image/") == true { return "[image]" }
        return nonEmpty(name).map { "[file \($0)]" } ?? "[file]"
    }

    /// The prompt shown for a message's typed text and attachments, or nil
    /// when nothing but whitespace was sent.
    private static func prompt(_ lines: [String]) -> String? {
        let text = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        return nonEmpty(text)
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func dictionary(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    /// OpenCode stores times as epoch milliseconds.
    private static func date(_ value: Any?) -> Date? {
        (value as? NSNumber).flatMap { AgentTimeline.date(from: $0.doubleValue) }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return string
    }
}
