import Foundation
import SopranoAgentsCore

/// What the user opened or closed in the timeline. Ids are turn, group and item ids, unique
/// across threads, so one value serves the whole window.
struct TimelineExpansion: Hashable, Sendable {
    /// Finished turns whose "Worked for …" fold is open.
    var turns: Set<String> = []
    /// Work groups (and live work rows) showing their entries.
    var groups: Set<String> = []
    /// Work entries showing their output.
    var entries: Set<String> = []
    /// Long user messages shown in full.
    var messages: Set<String> = []
    /// Plans shown in full.
    var plans: Set<String> = []
    /// Changed-files cards: turn id → closed folder paths.
    var closedFolders: [String: Set<String>] = [:]
}

struct UserRowModel: Hashable, Sendable {
    var message: UserMessage
    /// The turn this message started; nil for steers (they cannot be edited from).
    var turnID: String?
    var canEdit: Bool
    var expanded: Bool
}

struct FoldRowModel: Hashable, Sendable {
    var turnID: String
    var label: String
    var date: Date
    var expanded: Bool
}

struct ChangedFilesModel: Hashable, Sendable {
    var turnID: String
    var turnOrdinal: Int
    var files: [ChangedFileStat]
    var closedFolders: Set<String>

    var additions: Int { files.reduce(0) { $0 + $1.additions } }
    var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
}

struct AssistantRowModel: Hashable, Sendable {
    var itemID: String
    var text: String
    var isStreaming: Bool
    /// The turn's answer once the turn finished: copy button and timestamp below it.
    var showMeta: Bool
    var date: Date
    var changedFiles: ChangedFilesModel?
}

struct WorkGroupRowModel: Hashable, Sendable {
    var groupID: String
    var summary: String
    var icon: String
    var failed: Bool
    var expanded: Bool
    var date: Date
}

struct WorkEntryRowModel: Hashable, Sendable {
    var entry: WorkLogEntry
    /// Replaces the entry's own label (single-entry groups use the group wording).
    var displayLabel: String?
    /// Part of an expanded group (no own vertical padding).
    var grouped: Bool
    var expanded: Bool
}

struct LiveWorkRowModel: Hashable, Sendable {
    var groupID: String
    var entry: WorkLogEntry
    /// Latest reasoning line, shown above the live row (up to 4 lines).
    var thought: String?
    var expanded: Bool
    /// A tool is still running (or the last one succeeded): the label shimmers.
    var active: Bool
}

struct ApprovalRowModel: Hashable, Sendable {
    var request: ApprovalRequest
}

struct PlanRowModel: Hashable, Sendable {
    var itemID: String
    var markdown: String
    var expanded: Bool

    var title: String { MarkdownDocument.firstHeading(in: markdown) ?? "Proposed plan" }
    /// Plans collapse when over 900 characters or 20 lines.
    var canCollapse: Bool { markdown.count > 900 || markdown.split(separator: "\n", omittingEmptySubsequences: false).count > 20 }
}

struct TodoRowModel: Hashable, Sendable {
    var itemID: String
    var steps: [TodoStep]
    var explanation: String?
}

enum TimelineRowContent: Hashable, Sendable {
    case user(UserRowModel)
    case fold(FoldRowModel)
    case working(startedAt: Date)
    case assistant(AssistantRowModel)
    case workGroup(WorkGroupRowModel)
    case workEntry(WorkEntryRowModel)
    case liveWork(LiveWorkRowModel)
    case thinking
    case approval(ApprovalRowModel)
    case plan(PlanRowModel)
    case todo(TodoRowModel)
    case error(message: String, date: Date)
    case notice(text: String)
    case changedFiles(ChangedFilesModel)
    case queued(UserMessage)
    case empty

    /// Rows of the work log: adjacent ones sit flush.
    var isWorkLog: Bool {
        switch self {
        case .workGroup, .workEntry, .liveWork, .thinking, .approval: true
        default: false
        }
    }
}

/// One row of the timeline: a stable id (reuse, scroll anchoring, find) and its content.
struct TimelineRow: Hashable, Identifiable, Sendable {
    var id: String
    var content: TimelineRowContent
    /// Space under the row, per row kind.
    var bottomSpacing: CGFloat = 0
}

/// Thread → timeline rows (from this app's turn model):
///
/// - Each turn: the user message, then "Working for" while it runs, or a "Worked for …" fold when
///   it finished (closed by default; it hides everything but the answer and the cards).
/// - Consecutive tool items form a work group: one summary row ("Read 2 files and ran 1 command"),
///   or a single entry row when the group holds one tool call.
/// - A running turn's trailing tools become one live row; "Thinking" ends a running turn that
///   shows no live tool and waits on nobody.
/// - Steers sit at the time they were sent; queued messages close the thread.
enum TimelineBuilder {
    static func rows(for thread: AgentThread?, expansion: TimelineExpansion = TimelineExpansion()) -> [TimelineRow] {
        guard let thread else { return [] }
        var rows: [TimelineRow] = []
        if thread.turns.isEmpty, thread.queue.isEmpty {
            return [TimelineRow(id: "empty", content: .empty)]
        }
        for turn in thread.turns {
            appendTurn(turn, of: thread, expansion: expansion, to: &rows)
        }
        for queued in thread.queue {
            rows.append(TimelineRow(id: "queued:\(queued.id)", content: .queued(queued.message)))
        }
        applySpacing(&rows)
        return rows
    }

    /// Fold label: "Worked for 3m 12s", "You stopped after 12s".
    static func foldLabel(for turn: Turn) -> String {
        let duration = DurationText.turn(turn.duration(now: turn.completedAt ?? turn.startedAt))
        return turn.status == .interrupted ? "You stopped after \(duration)" : "Worked for \(duration)"
    }

    // MARK: - Turns

    private enum Piece {
        case item(TurnItem)
        case steer(UserMessage)
    }

    private static func appendTurn(_ turn: Turn, of thread: AgentThread, expansion: TimelineExpansion, to rows: inout [TimelineRow]) {
        let isRunning = turn.status == .running
        rows.append(TimelineRow(id: "user:\(turn.userMessage.id)", content: .user(UserRowModel(
            message: turn.userMessage,
            turnID: turn.id,
            canEdit: !thread.isRunning,
            expanded: expansion.messages.contains(turn.userMessage.id)
        ))))

        let terminalID = turn.items.last { if case .assistantMessage = $0.kind { return true } else { return false } }?.id
        let terminalIndex = terminalID.flatMap { id in turn.items.firstIndex { $0.id == id } } ?? turn.items.count

        // Which items the closed fold hides.
        var hidden: Set<String> = []
        if !isRunning, turn.status != .failed {
            for (index, item) in turn.items.enumerated() where hidesInFold(item, index: index, terminalIndex: terminalIndex, terminalID: terminalID) {
                hidden.insert(item.id)
            }
        }
        let foldOpen = expansion.turns.contains(turn.id)
        if isRunning {
            rows.append(TimelineRow(id: "working:\(turn.id)", content: .working(startedAt: turn.startedAt)))
        } else if !hidden.isEmpty {
            rows.append(TimelineRow(id: "fold:\(turn.id)", content: .fold(FoldRowModel(
                turnID: turn.id, label: foldLabel(for: turn), date: turn.startedAt, expanded: foldOpen
            ))))
        }

        let checkpointFiles = turn.checkpoint.flatMap { $0.status == .ready && !$0.files.isEmpty ? $0.files : nil }
        let changedFiles = checkpointFiles.map {
            ChangedFilesModel(turnID: turn.id, turnOrdinal: turn.ordinal, files: $0, closedFolders: expansion.closedFolders[turn.id] ?? [])
        }
        var placedChangedFiles = false

        let pieces = interleave(turn.items.filter { foldOpen || !hidden.contains($0.id) }, steers: turn.steers)
        var group: [WorkLogEntry] = []
        var hasLiveActivity = false
        var waitsOnUser = false

        func flushGroup(trailing: Bool) {
            guard !group.isEmpty else { return }
            defer { group = [] }
            let groupID = "group:\(group[0].id)"
            let expanded = expansion.groups.contains(groupID)
            if trailing, isRunning, let last = group.last, !last.isFailed {
                let running = group.last { $0.isActive }
                let thought = group.last { $0.kind == .reasoning && !($0.detail ?? "").isEmpty }?.detail
                let active = running != nil || last.status == .completed
                hasLiveActivity = hasLiveActivity || active
                rows.append(TimelineRow(id: "live:\(turn.id)", content: .liveWork(LiveWorkRowModel(
                    groupID: groupID, entry: running ?? last, thought: thought, expanded: expanded, active: active
                ))))
                if expanded { appendEntries(group, expansion: expansion, to: &rows) }
                return
            }
            if group.count == 1, group[0].isToolLike {
                let entry = group[0]
                rows.append(TimelineRow(id: "entry:\(entry.id)", content: .workEntry(WorkEntryRowModel(
                    entry: entry,
                    displayLabel: entry.action == .edit && entry.changedFiles.count > 1 ? WorkLog.summary(group) : nil,
                    grouped: false,
                    expanded: expansion.entries.contains(entry.id)
                ))))
                return
            }
            let toolEntries = group.filter(\.isToolLike)
            rows.append(TimelineRow(id: groupID, content: .workGroup(WorkGroupRowModel(
                groupID: groupID,
                summary: WorkLog.summary(group),
                icon: WorkLog.summaryIcon(group),
                failed: toolEntries.last?.isFailed ?? false,
                expanded: expanded,
                date: group[0].startedAt
            ))))
            if expanded { appendEntries(group, expansion: expansion, to: &rows) }
        }

        for piece in pieces {
            switch piece {
            case let .steer(message):
                flushGroup(trailing: false)
                rows.append(TimelineRow(id: "user:\(message.id)", content: .user(UserRowModel(
                    message: message, turnID: nil, canEdit: false, expanded: expansion.messages.contains(message.id)
                ))))
            case let .item(item):
                switch item.kind {
                case let .assistantMessage(text, _):
                    flushGroup(trailing: false)
                    let isTerminal = item.id == terminalID && !isRunning
                    var files: ChangedFilesModel?
                    if isTerminal, let changedFiles {
                        files = changedFiles
                        placedChangedFiles = true
                    }
                    rows.append(TimelineRow(id: "assistant:\(item.id)", content: .assistant(AssistantRowModel(
                        itemID: item.id,
                        text: text,
                        isStreaming: item.status.isActive && isRunning,
                        showMeta: isTerminal,
                        date: item.completedAt ?? item.startedAt,
                        changedFiles: files
                    ))))
                case let .plan(markdown):
                    flushGroup(trailing: false)
                    rows.append(TimelineRow(id: "plan:\(item.id)", content: .plan(PlanRowModel(
                        itemID: item.id, markdown: markdown, expanded: expansion.plans.contains(item.id)
                    ))))
                case let .todoList(steps, explanation):
                    flushGroup(trailing: false)
                    rows.append(TimelineRow(id: "todo:\(item.id)", content: .todo(TodoRowModel(itemID: item.id, steps: steps, explanation: explanation))))
                case let .error(message):
                    flushGroup(trailing: false)
                    rows.append(TimelineRow(id: "error:\(item.id)", content: .error(message: message, date: item.startedAt)))
                case let .notice(text):
                    flushGroup(trailing: false)
                    rows.append(TimelineRow(id: "notice:\(item.id)", content: .notice(text: text)))
                case let .approval(request) where request.decision == nil:
                    flushGroup(trailing: false)
                    if isRunning { waitsOnUser = true }
                    rows.append(TimelineRow(id: "approval:\(item.id)", content: .approval(ApprovalRowModel(request: request))))
                case let .userInput(request):
                    flushGroup(trailing: false)
                    if isRunning, request.answers == nil, !request.dismissed { waitsOnUser = true }
                    if let entry = WorkLog.entry(for: item) {
                        rows.append(TimelineRow(id: "entry:\(item.id)", content: .workEntry(WorkEntryRowModel(
                            entry: entry, displayLabel: nil, grouped: false, expanded: expansion.entries.contains(item.id)
                        ))))
                    }
                default:
                    if let entry = WorkLog.entry(for: item), entry.isVisible {
                        group.append(entry)
                    }
                }
            }
        }
        flushGroup(trailing: true)

        if turn.status == .failed, let failure = turn.failureMessage,
           !turn.items.contains(where: { if case .error = $0.kind { return true } else { return false } }) {
            rows.append(TimelineRow(id: "failure:\(turn.id)", content: .error(message: failure, date: turn.completedAt ?? turn.startedAt)))
        }
        if let changedFiles, !placedChangedFiles, !isRunning {
            rows.append(TimelineRow(id: "files:\(turn.id)", content: .changedFiles(changedFiles)))
        }
        if isRunning, !hasLiveActivity, !waitsOnUser {
            rows.append(TimelineRow(id: "thinking:\(turn.id)", content: .thinking))
        }
    }

    private static func appendEntries(_ entries: [WorkLogEntry], expansion: TimelineExpansion, to rows: inout [TimelineRow]) {
        for entry in entries {
            rows.append(TimelineRow(id: "entry:\(entry.id)", content: .workEntry(WorkEntryRowModel(
                entry: entry, displayLabel: nil, grouped: true, expanded: expansion.entries.contains(entry.id)
            ))))
        }
    }

    /// The closed fold hides commentary and finished work; it keeps the answer, cards, errors,
    /// notices, questions, pending approvals and failed work after the answer.
    private static func hidesInFold(_ item: TurnItem, index: Int, terminalIndex: Int, terminalID: String?) -> Bool {
        switch item.kind {
        case .assistantMessage:
            return item.id != terminalID
        case .plan, .todoList, .error, .notice, .userInput:
            return false
        case let .approval(request):
            return request.decision != nil
        case .reasoning, .command, .fileChange, .toolCall, .webSearch:
            if index > terminalIndex, item.status == .failed { return false }
            guard let entry = WorkLog.entry(for: item) else { return false }
            return entry.isVisible
        }
    }

    /// Items in order with each steer placed before the first item that started after it.
    private static func interleave(_ items: [TurnItem], steers: [UserMessage]) -> [Piece] {
        var pieces: [Piece] = []
        var remaining = steers.sorted { $0.createdAt < $1.createdAt }
        for item in items {
            while let steer = remaining.first, steer.createdAt <= item.startedAt {
                pieces.append(.steer(steer))
                remaining.removeFirst()
            }
            pieces.append(.item(item))
        }
        pieces += remaining.map(Piece.steer)
        return pieces
    }

    // MARK: - Spacing

    /// Row padding: user messages and cards 16, assistant prose 8 (16 under its meta
    /// row), folds 6, work-log rows 8 unless the next row continues the log (then flush; an
    /// expanded group's entries end with 4).
    private static func applySpacing(_ rows: inout [TimelineRow]) {
        for index in rows.indices {
            let next = index + 1 < rows.count ? rows[index + 1].content : nil
            let continues = next?.isWorkLog ?? false
            let spacing: CGFloat = switch rows[index].content {
            case .user, .plan, .todo, .changedFiles: 16
            case .fold, .working: 6
            case let .assistant(model): model.showMeta ? 16 : 8
            case let .workGroup(model): continues || model.expanded ? 0 : 8
            case let .liveWork(model): continues || model.expanded ? 0 : 8
            case let .workEntry(model):
                if continues { 0 } else { model.grouped ? 4 : 8 }
            case .thinking, .approval: continues ? 0 : 8
            case .error, .notice, .queued: 8
            case .empty: 0
            }
            rows[index].bottomSpacing = spacing
        }
    }
}
