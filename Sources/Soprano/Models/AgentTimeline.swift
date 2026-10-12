import Foundation

/// The agent CLIs whose own transcript the dashboard can read. Each keeps its
/// conversation as JSON Lines in a different shape.
enum AgentTranscriptFormat: String, Sendable, CaseIterable {
    case claudeCode
    case codex
    case omp

    init?(profileId: String) {
        switch profileId {
        case "claude-code": self = .claudeCode
        case "codex": self = .codex
        case "omp": self = .omp
        default: return nil
        }
    }
}

/// One thing that happened in an agent's conversation, the same for every CLI.
struct AgentTimelineItem: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        /// What the person sent.
        case prompt(String)
        /// The agent's prose, as Markdown.
        case reply(String)
        /// Visible reasoning; empty when the CLI stored only an encrypted form.
        case thinking(String)
        case tool(AgentToolCall)
        /// Compaction, interruption, API errors, and similar markers.
        case notice(String, isError: Bool)
    }

    let id: String
    var timestamp: Date?
    var kind: Kind

    init(id: String, timestamp: Date? = nil, kind: Kind) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
    }

    var toolCall: AgentToolCall? {
        if case .tool(let call) = kind { return call }
        return nil
    }

    var isPrompt: Bool {
        if case .prompt = kind { return true }
        return false
    }
}

struct AgentToolCall: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case running
        case succeeded
        case failed
        /// A newer prompt arrived before any result: the turn was cut short.
        case interrupted
    }

    /// Short tool label: "Bash", "Edit", "Read", "cua_repl.js".
    var name: String
    /// One line saying what the call does: the command, the file, the query.
    var summary: String
    /// The full input when it says more than `summary`, such as a multi-line command.
    var detail: String? = nil
    var state: State = .running
    /// What the tool printed, already shortened with `AgentTimeline.excerpt`.
    var output: String? = nil
    /// Unified-diff lines (`+`, `-`, space, `@@`) for file edits.
    var diff: String? = nil
    var finishedAt: Date? = nil

    mutating func apply(_ result: AgentToolResult) {
        state = result.state
        output = result.output ?? output
        diff = result.diff ?? diff
        summary = result.summary ?? summary
        finishedAt = result.finishedAt ?? finishedAt
    }
}

/// The finishing half of a tool call, written by a later transcript record.
struct AgentToolResult: Equatable, Sendable {
    var state: AgentToolCall.State
    var output: String? = nil
    var diff: String? = nil
    /// Replaces the call's summary when the result names the subject better.
    var summary: String? = nil
    var finishedAt: Date? = nil
}

/// One transcript line reduced to what the timeline needs.
struct AgentTranscriptEntry: Equatable, Sendable {
    /// Position in the conversation tree for CLIs that branch when a person
    /// rewinds (Claude Code, omp). Nil for linear transcripts and for records
    /// outside the tree.
    var id: String? = nil
    var parentId: String? = nil
    var items: [AgentTimelineItem] = []
    /// Results keyed by the id of the tool call item they finish.
    var results: [String: AgentToolResult] = [:]
    /// Provisional items this record supersedes.
    var droppedItemIds: [String] = []
}

/// Reads one CLI's transcript a line at a time. Decoders keep whatever later
/// lines need, such as the session's working directory.
protocol AgentTranscriptDecoding: Sendable {
    /// The entry one JSON line contributes, or nil for lines the timeline
    /// neither shows nor needs for branch tracking. Malformed lines are nil.
    mutating func entry(forLine line: Data) -> AgentTranscriptEntry?
}

/// The visible conversation of one agent, newest last.
struct AgentTimeline: Equatable, Sendable {
    /// Items kept per agent; older ones fall off the front.
    static let itemLimit = 400
    /// Characters kept from one tool's output.
    static let outputCharacterLimit = 4_000
    /// Lines kept from one tool's output before the middle is elided.
    static let outputLineLimit = 40
    /// Diff lines kept per tool call.
    static let diffLineLimit = 400

    var items: [AgentTimelineItem]

    init(items: [AgentTimelineItem] = []) {
        self.items = items
    }

    /// Folds transcript entries into the conversation a person sees: only the
    /// branch ending at the newest tree record, results merged into their
    /// calls, provisional items dropped, and calls left without a result when
    /// a new prompt arrived marked interrupted.
    init(entries: [AgentTranscriptEntry], limit: Int = AgentTimeline.itemLimit) {
        let visible = Self.currentBranch(of: entries)
        var items: [AgentTimelineItem] = []
        var indexById: [String: Int] = [:]
        var dropped = Set<String>()

        for entry in visible {
            for item in entry.items {
                if item.isPrompt {
                    for index in items.indices {
                        guard var call = items[index].toolCall, call.state == .running else { continue }
                        call.state = .interrupted
                        items[index].kind = .tool(call)
                    }
                }
                if let index = indexById[item.id] {
                    items[index] = item
                } else {
                    indexById[item.id] = items.count
                    items.append(item)
                }
            }
            for (callId, result) in entry.results {
                guard let index = indexById[callId], var call = items[index].toolCall else { continue }
                call.apply(result)
                items[index].kind = .tool(call)
            }
            dropped.formUnion(entry.droppedItemIds)
        }

        if !dropped.isEmpty {
            items.removeAll { dropped.contains($0.id) }
        }
        if items.count > limit {
            items.removeFirst(items.count - limit)
        }
        self.items = items
    }

    /// The newest tool call still waiting for its result.
    var runningTool: AgentTimelineItem? {
        items.last { $0.toolCall?.state == .running }
    }

    /// Entries on the branch that ends at the newest tree record, in file
    /// order, plus side branches without a prompt: Claude Code hangs the
    /// second of two parallel tool calls and its result off the first call, so
    /// they leave the path to the leaf without being abandoned. A side branch
    /// that holds a prompt is what a rewind left behind and stays hidden.
    /// Records outside the tree always stay.
    private static func currentBranch(of entries: [AgentTranscriptEntry]) -> [AgentTranscriptEntry] {
        guard let leaf = entries.last(where: { $0.id != nil })?.id,
              entries.contains(where: { $0.parentId != nil })
        else { return entries }

        var parentById: [String: String] = [:]
        var childrenById: [String: [String]] = [:]
        var hasPrompt = Set<String>()
        for entry in entries {
            guard let id = entry.id else { continue }
            parentById[id] = entry.parentId
            if let parentId = entry.parentId {
                childrenById[parentId, default: []].append(id)
            }
            if entry.items.contains(where: \.isPrompt) {
                hasPrompt.insert(id)
            }
        }

        var branch = Set<String>()
        var cursor: String? = leaf
        while let id = cursor, branch.insert(id).inserted {
            cursor = parentById[id]
        }

        var visible = branch
        for id in branch {
            for child in childrenById[id] ?? [] where !branch.contains(child) {
                var subtree = Set<String>()
                var pending = [child]
                var abandoned = false
                while let node = pending.popLast(), !abandoned {
                    guard !visible.contains(node), subtree.insert(node).inserted else { continue }
                    abandoned = hasPrompt.contains(node)
                    pending.append(contentsOf: childrenById[node] ?? [])
                }
                if !abandoned {
                    visible.formUnion(subtree)
                }
            }
        }
        return entries.filter { entry in
            entry.id.map(visible.contains) ?? true
        }
    }
}

// MARK: - Text helpers shared by the decoders

extension AgentTimeline {
    /// `path` relative to `cwd` when it lies inside it, else with `~` for home.
    static func displayPath(_ path: String, relativeTo cwd: String?) -> String {
        if let cwd, !cwd.isEmpty {
            let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
            if path.hasPrefix(base), path.count > base.count {
                return String(path.dropFirst(base.count))
            }
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    /// The first non-empty line of `text`, trimmed and cut to `limit` characters.
    static func firstLine(_ text: String, limit: Int = 160) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    /// Tool output short enough to show: long output keeps its head and its
    /// tail (where errors land), and anything still too long is cut. Nil when
    /// nothing but whitespace was printed.
    static func excerpt(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > outputLineLimit {
            let head = outputLineLimit / 4
            let tail = outputLineLimit - head
            let elided = lines.count - head - tail
            lines = Array(lines.prefix(head)) + ["⋯ \(elided) more lines ⋯"] + Array(lines.suffix(tail))
        }
        var result = lines.joined(separator: "\n")
        if result.count > outputCharacterLimit {
            result = String(result.prefix(outputCharacterLimit)) + "\n⋯"
        }
        return result
    }

    /// A diff cut to `diffLineLimit` lines.
    static func diffExcerpt(_ diff: String?) -> String? {
        guard let diff else { return nil }
        let trimmed = diff.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return nil }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > diffLineLimit else { return trimmed }
        return (lines.prefix(diffLineLimit) + ["⋯ \(lines.count - diffLineLimit) more lines ⋯"])
            .joined(separator: "\n")
    }

    /// ISO 8601 timestamps as the CLIs write them, with or without fractions.
    static func date(from value: Any?) -> Date? {
        if let milliseconds = value as? Double {
            return Date(timeIntervalSince1970: milliseconds / 1_000)
        }
        guard let string = value as? String else { return nil }
        return fractionalDateFormatter.date(from: string) ?? plainDateFormatter.date(from: string)
    }

    nonisolated(unsafe) private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plainDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
