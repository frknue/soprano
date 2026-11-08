import Foundation

// The chat's conversation as turns, ported from Soprano Agents' turn model
// (`SopranoAgentsCore/Models/{Threads,TurnItems}.swift`): each message the
// person sends starts a turn, and everything the agent does until it ends —
// prose, reasoning, commands, edits, other tools, approvals, questions —
// lands in that turn's items in arrival order. `ACPTurnBuilder` folds an
// agent's ACP `session/update`s into it; the chat tab renders it.
//
// Times are optional: a conversation reopened with `session/load` replays
// its history without them.

enum TurnItemStatus: String, Sendable, Hashable {
    case pending
    case running
    case completed
    case failed
    /// The person declined it (approval).
    case declined
    /// The turn ended while the item ran.
    case interrupted

    var isActive: Bool { self == .pending || self == .running }
}

/// One entry of a turn's activity log.
struct TurnItem: Sendable, Hashable, Identifiable {
    var id: String
    var kind: TurnItemKind
    var status: TurnItemStatus
    var startedAt: Date?
    var completedAt: Date?

    init(id: String, kind: TurnItemKind, status: TurnItemStatus = .running, startedAt: Date? = nil, completedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

enum TurnItemKind: Sendable, Hashable {
    /// Assistant prose (Markdown). `isFinal`: the turn's answer; false: commentary between tools.
    case assistantMessage(text: String, isFinal: Bool)
    /// Reasoning ("Thinking").
    case reasoning(text: String)
    /// Shell command. `output` grows while it runs.
    case command(TurnCommand)
    /// File edits (one call may touch several files).
    case fileChange([FileChange])
    /// Any other tool: read, search, subagents, the rest.
    case toolCall(ToolCall)
    case webSearch(query: String)
    case approval(ApprovalRequest)
    case userInput(UserInputRequest)
    case error(message: String)
    /// Informational divider ("Context compacted").
    case notice(text: String)
}

struct TurnCommand: Sendable, Hashable {
    var command: String
    var output: String
    var exitCode: Int?

    init(command: String, output: String = "", exitCode: Int? = nil) {
        self.command = command
        self.output = output
        self.exitCode = exitCode
    }
}

struct FileChange: Sendable, Hashable {
    enum Kind: String, Sendable, Hashable {
        case add
        case delete
        case update
        case move
    }

    var path: String
    var kind: Kind
    /// Destination of a move.
    var movePath: String?
    /// Unified diff of this file when the agent reports one.
    var diff: String?
    /// `diff` is the file's whole new content (a write), not a change against the old file.
    var isFullContent: Bool?

    init(path: String, kind: Kind, movePath: String? = nil, diff: String? = nil, isFullContent: Bool? = nil) {
        self.path = path
        self.kind = kind
        self.movePath = movePath
        self.diff = diff
        self.isFullContent = isFullContent
    }
}

struct ToolCall: Sendable, Hashable {
    enum Category: String, Sendable, Hashable {
        /// Read a file.
        case read
        /// grep / glob / find.
        case search
        case subagent
        case other
    }

    /// The agent's tool name ("read", "grep", "lsp").
    var name: String
    var category: Category
    /// One-line label for the work log ("Read Sources/App.swift").
    var title: String
    /// Pretty-printed input, shown when the row opens.
    var input: String?
    var output: String?
}

enum ApprovalKind: String, Sendable, Hashable {
    case command
    case fileChange
    case fileRead
    case other

    var title: String {
        switch self {
        case .command: "Command approval"
        case .fileChange: "File change approval"
        case .fileRead: "File read approval"
        case .other: "Approval"
        }
    }

    /// The kind of a tool the agent asks to run, by its ACP `kind`.
    static func of(acpKind: String?) -> ApprovalKind {
        switch acpKind {
        case "execute": .command
        case "edit", "delete", "move": .fileChange
        case "read", "search": .fileRead
        default: .other
        }
    }
}

/// How the person answered an approval.
enum ApprovalDecision: String, Sendable, Hashable {
    case accept
    case acceptForSession
    case decline
    case cancel

    /// The decision an ACP permission option kind stands for.
    static func of(optionKind: String) -> ApprovalDecision {
        switch optionKind {
        case "allow_always": .acceptForSession
        case "allow_once": .accept
        default: optionKind.hasPrefix("allow") ? .accept : .decline
        }
    }
}

/// The agent wants permission. Lives in the activity log as `.approval`; `decision` is set once answered.
struct ApprovalRequest: Sendable, Hashable, Identifiable {
    var id: String
    var kind: ApprovalKind
    /// What is being approved: the command line or the tool's title.
    var detail: String
    /// Why the agent asks, when it says.
    var reason: String?
    /// The answers the agent offers.
    var options: [ApprovalOption] = []
    var decision: ApprovalDecision?
}

/// One answer an ACP permission request offers.
struct ApprovalOption: Sendable, Hashable {
    let id: String
    let name: String
    /// `allow_once`, `allow_always`, `reject_once` or `reject_always`.
    let kind: String

    var allows: Bool { kind.hasPrefix("allow") }
}

extension [ApprovalOption] {
    /// What Approve picks: allow once, else any allow.
    var approveOption: ApprovalOption? {
        first { $0.kind == "allow_once" } ?? first(where: \.allows)
    }

    /// What Decline picks: reject once, else any reject.
    var declineOption: ApprovalOption? {
        first { $0.kind == "reject_once" } ?? first { !$0.allows }
    }

    /// Every other answer ("Always allow"), for the More menu.
    var moreOptions: [ApprovalOption] {
        let approve = approveOption
        let decline = declineOption
        return filter { $0 != approve && $0 != decline }
    }
}

struct UserInputOption: Sendable, Hashable {
    var label: String
    var description: String?
}

struct UserInputQuestion: Sendable, Hashable, Identifiable {
    var id: String
    /// Short chip text ("Fix approach").
    var header: String
    var question: String
    var options: [UserInputOption]
    var allowsMultiple: Bool
    /// A typed answer is allowed besides the options.
    var allowsOther: Bool
}

/// The agent asks structured questions.
struct UserInputRequest: Sendable, Hashable, Identifiable {
    var id: String
    var questions: [UserInputQuestion]
    /// Question id → chosen labels or typed text; nil until answered.
    var answers: [String: [String]]?
    var dismissed = false
}

/// What the person sent to start, or steer, a turn.
struct UserMessage: Sendable, Hashable, Identifiable {
    var id: String
    var text: String
    var createdAt: Date?
}

enum TurnStatus: String, Sendable, Hashable {
    case running
    case completed
    case interrupted
    case failed
}

/// One run of the agent, started by a message.
struct Turn: Sendable, Hashable, Identifiable {
    var id: String
    var userMessage: UserMessage
    var status: TurnStatus = .running
    var failureMessage: String?
    var startedAt: Date?
    var completedAt: Date?
    /// Activity log in arrival order.
    var items: [TurnItem] = []
    /// Messages steered into the turn while it ran.
    var steers: [UserMessage] = []
    /// When the person pressed Stop; the turn says "Stopping…" until it ends.
    var stopRequestedAt: Date?

    var isRunning: Bool { status == .running }

    /// Wall time of the turn ("Worked for 3m 12s"); nil for a replayed turn.
    func duration(now: Date = Date()) -> TimeInterval? {
        guard let startedAt else { return nil }
        return (completedAt ?? now).timeIntervalSince(startedAt)
    }

    var pendingApproval: ApprovalRequest? {
        for item in items.reversed() {
            if case let .approval(request) = item.kind, request.decision == nil { return request }
        }
        return nil
    }

    /// Files the turn's finished edits changed, with the lines their diffs add and remove.
    var changedFiles: [ChangedFileStat] {
        var order: [String] = []
        var stats: [String: ChangedFileStat] = [:]
        for item in items where item.status == .completed {
            guard case let .fileChange(changes) = item.kind else { continue }
            for change in changes {
                let path = change.movePath ?? change.path
                guard !path.isEmpty else { continue }
                let counts = DiffLineCount.of(change.diff ?? "")
                if stats[path] == nil {
                    order.append(path)
                    stats[path] = ChangedFileStat(path: path, additions: 0, deletions: 0)
                }
                stats[path]?.additions += counts.additions
                stats[path]?.deletions += change.isFullContent == true ? 0 : counts.deletions
            }
        }
        return order.compactMap { stats[$0] }
    }
}

struct ChangedFileStat: Sendable, Hashable, Identifiable {
    var id: String { path }
    var path: String
    var additions: Int
    var deletions: Int
}

/// Lines a unified diff adds and removes (hunk headers and file headers aside).
enum DiffLineCount {
    static func of(_ diff: String) -> (additions: Int, deletions: Int) {
        var additions = 0
        var deletions = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { additions += 1 } else if line.hasPrefix("-") { deletions += 1 }
        }
        return (additions, deletions)
    }
}

/// The chat's conversation: notices from before the first turn, the turns,
/// and the messages waiting for the running turn.
struct ChatThread: Sendable, Hashable {
    /// Notices with no turn to belong to ("Could not reopen the conversation").
    var preamble: [TurnItem] = []
    var turns: [Turn] = []
    var queue: [UserMessage] = []

    /// The turn the agent works on.
    var activeTurn: Turn? {
        guard let last = turns.last, last.isRunning else { return nil }
        return last
    }

    var isRunning: Bool { activeTurn != nil }
}

enum DurationText {
    /// Turn duration ("Worked for 1m 12s"): `Nms` under 1 s, `N.Ns` under 10 s, `Ns` under a minute,
    /// else `1h 2m 3s` with zero parts left out.
    static func turn(_ interval: TimeInterval) -> String {
        if interval < 1 { return "\(max(0, Int(interval * 1000)))ms" }
        if interval < 10 { return String(format: "%.1fs", interval) }
        let seconds = Int(interval)
        if seconds < 60 { return "\(seconds)s" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        if rest > 0 { parts.append("\(rest)s") }
        return parts.joined(separator: " ")
    }
}
