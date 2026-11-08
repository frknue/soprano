import Foundation

// Port of Soprano Agents' `TimelineRows.swift`: the chat's turns as the rows
// the timeline shows.

/// What the person opened or closed in the timeline. Ids are turn, group and item ids.
///
/// `turns`, `groups` and `diffs` hold what the person toggled away from the work log's default:
/// closed in the minimal work log, open in the detailed one (`detailed`). Read them through
/// `isTurnOpen` / `isGroupOpen` / `isDiffOpen`.
struct TimelineExpansion: Hashable, Sendable {
    /// Finished turns whose "Worked for …" fold was toggled.
    var turns: Set<String> = []
    /// Work groups (and live work rows) that were toggled.
    var groups: Set<String> = []
    /// Work entries showing their output.
    var entries: Set<String> = []
    /// Long user messages shown in full.
    var messages: Set<String> = []
    /// Changed-files cards: turn id → closed folder paths.
    var closedFolders: [String: Set<String>] = [:]
    /// File diffs (`FileDiffRowModel.id`) that were toggled.
    var diffs: Set<String> = []
    /// The detailed work log: folds, work groups and file diffs open by default.
    var detailed = true

    func isTurnOpen(_ turnID: String) -> Bool { turns.contains(turnID) != detailed }
    func isGroupOpen(_ groupID: String) -> Bool { groups.contains(groupID) != detailed }
    func isDiffOpen(_ diffID: String) -> Bool { diffs.contains(diffID) != detailed }

    /// Opens or closes `id` in a set read against the default (`turns`, `groups`, `diffs`).
    mutating func set(_ id: String, open: Bool, in keyPath: WritableKeyPath<TimelineExpansion, Set<String>>) {
        if open != detailed { self[keyPath: keyPath].insert(id) } else { self[keyPath: keyPath].remove(id) }
    }
}

struct UserRowModel: Hashable, Sendable {
    var message: UserMessage
    /// The turn this message started; nil for steers.
    var turnID: String?
    var expanded: Bool
}

struct FoldRowModel: Hashable, Sendable {
    var turnID: String
    var label: String
    var date: Date?
    var expanded: Bool
}

struct ChangedFilesModel: Hashable, Sendable {
    var turnID: String
    var files: [ChangedFileStat]
    var closedFolders: Set<String>

    var additions: Int { files.reduce(0) { $0 + $1.additions } }
    var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
}

struct AssistantRowModel: Hashable, Sendable {
    var itemID: String
    var text: String
    var isStreaming: Bool
    /// A complete answer, or the finished turn's last message: copy button and timestamp below it.
    var showMeta: Bool
    var date: Date?
    var changedFiles: ChangedFilesModel?
}

struct WorkGroupRowModel: Hashable, Sendable {
    var groupID: String
    var summary: String
    var icon: String
    var failed: Bool
    var expanded: Bool
    var date: Date?
}

struct WorkEntryRowModel: Hashable, Sendable {
    var entry: WorkLogEntry
    /// Replaces the entry's own label.
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

/// One file an edit or write touched: a header line ("Edited Sources/App.swift  +12 −3") that
/// opens its diff. A running call shows the code as the model writes it.
struct FileDiffRowModel: Hashable, Sendable {
    /// The item id and the file's index in it: the row's expansion key.
    var id: String
    var change: FileChange
    var status: TurnItemStatus
    var date: Date?
    var expanded: Bool
    /// Part of an expanded group (no own vertical padding).
    var grouped: Bool

    var isActive: Bool { status.isActive }
    var canExpand: Bool { !(change.diff ?? "").isEmpty }

    /// "Editing App.swift", "Wrote App.swift", "Edit failed: App.swift".
    var label: String {
        let path = change.movePath.map { "\(change.path) → \($0)" } ?? change.path
        let wrote = change.isFullContent == true
        let verb: String = switch (status, change.kind) {
        case (.pending, .add), (.running, .add): "Writing"
        case (.pending, _), (.running, _): wrote ? "Writing" : "Editing"
        case (.failed, _): wrote ? "Write failed:" : "Edit failed:"
        case (.declined, _): "Declined"
        case (.interrupted, _): wrote ? "Stopped writing" : "Stopped editing"
        case (.completed, .add): "Created"
        case (.completed, .delete): "Deleted"
        case (.completed, .move): "Moved"
        case (.completed, .update): wrote ? "Wrote" : "Edited"
        }
        return "\(verb) \(path)"
    }
}

struct ApprovalRowModel: Hashable, Sendable {
    var request: ApprovalRequest
}

enum TimelineRowContent: Hashable, Sendable {
    case user(UserRowModel)
    case fold(FoldRowModel)
    case working(startedAt: Date?, stopping: Bool)
    case assistant(AssistantRowModel)
    case workGroup(WorkGroupRowModel)
    case workEntry(WorkEntryRowModel)
    case fileDiff(FileDiffRowModel)
    case liveWork(LiveWorkRowModel)
    case thinking
    case approval(ApprovalRowModel)
    case error(message: String, date: Date?)
    case notice(text: String)
    case changedFiles(ChangedFilesModel)
    case queued(UserMessage)
    /// The empty chat: what it says while the agent starts or waits for the first message.
    case empty(String)

    /// Rows of the work log: adjacent ones sit flush.
    var isWorkLog: Bool {
        switch self {
        case .workGroup, .workEntry, .fileDiff, .liveWork, .thinking, .approval: true
        default: false
        }
    }
}

/// One row of the timeline: a stable id (reuse, scroll anchoring) and its content.
struct TimelineRow: Hashable, Identifiable, Sendable {
    var id: String
    var content: TimelineRowContent
    /// Space under the row, per row kind.
    var bottomSpacing: CGFloat = 0
}

/// Thread → timeline rows:
///
/// - Each turn: the user message, then "Working for" while it runs ("Stopping…" once Stop was
///   pressed, without "Thinking"), or a "Worked for …" fold when it finished (it hides
///   commentary and work, never an answer or a card).
/// - Consecutive tool items form a work group: one summary row ("Read 2 files and ran 1 command"),
///   or a single entry row when the group holds one tool call. A file change shows as one diff
///   row per file (`FileDiffRowModel`).
/// - The detailed work log (`TimelineExpansion.detailed`) opens folds, groups and diffs by
///   default; a running turn's trailing group then shows like any open group, its running step
///   shimmering. Collapsing that group gives the minimal live row.
/// - "Thinking" ends a running turn that shows no live tool, waits on nobody and has not just
///   answered.
/// - The turn's answer carries the changed-files card, computed from its edits.
/// - Steers sit at the time they were sent; queued messages close the thread.
enum TimelineBuilder {
    static func rows(for thread: ChatThread, emptyText: String, expansion: TimelineExpansion = TimelineExpansion()) -> [TimelineRow] {
        var rows: [TimelineRow] = []
        for item in thread.preamble {
            switch item.kind {
            case let .error(message): rows.append(TimelineRow(id: "error:\(item.id)", content: .error(message: message, date: item.startedAt)))
            case let .notice(text): rows.append(TimelineRow(id: "notice:\(item.id)", content: .notice(text: text)))
            default: break
            }
        }
        if thread.turns.isEmpty, thread.queue.isEmpty, rows.isEmpty {
            return [TimelineRow(id: "empty", content: .empty(emptyText))]
        }
        for turn in thread.turns {
            appendTurn(turn, expansion: expansion, to: &rows)
        }
        for queued in thread.queue {
            rows.append(TimelineRow(id: "queued:\(queued.id)", content: .queued(queued)))
        }
        applySpacing(&rows)
        return rows
    }

    /// Fold label: "Worked for 3m 12s", "You stopped after 12s"; "Worked" for a replayed turn.
    static func foldLabel(for turn: Turn) -> String {
        guard let duration = turn.duration(now: turn.startedAt ?? Date()).map(DurationText.turn) else {
            return turn.status == .interrupted ? "You stopped" : "Worked"
        }
        return turn.status == .interrupted ? "You stopped after \(duration)" : "Worked for \(duration)"
    }

    // MARK: - Turns

    private enum Piece {
        case item(TurnItem)
        case steer(UserMessage)
    }

    private static func appendTurn(_ turn: Turn, expansion: TimelineExpansion, to rows: inout [TimelineRow]) {
        let isRunning = turn.isRunning
        if !turn.userMessage.text.isEmpty {
            rows.append(TimelineRow(id: "user:\(turn.userMessage.id)", content: .user(UserRowModel(
                message: turn.userMessage,
                turnID: turn.id,
                expanded: expansion.messages.contains(turn.userMessage.id)
            ))))
        }

        let terminalID = turn.items.last { if case .assistantMessage = $0.kind { return true } else { return false } }?.id
        let terminalIndex = terminalID.flatMap { id in turn.items.firstIndex { $0.id == id } } ?? turn.items.count

        // Which items the closed fold hides.
        var hidden: Set<String> = []
        if !isRunning, turn.status != .failed {
            for (index, item) in turn.items.enumerated() where hidesInFold(item, index: index, terminalIndex: terminalIndex, terminalID: terminalID) {
                hidden.insert(item.id)
            }
        }
        let foldOpen = expansion.isTurnOpen(turn.id)
        if isRunning {
            rows.append(TimelineRow(id: "working:\(turn.id)", content: .working(startedAt: turn.startedAt, stopping: turn.stopRequestedAt != nil)))
        } else if !hidden.isEmpty {
            rows.append(TimelineRow(id: "fold:\(turn.id)", content: .fold(FoldRowModel(
                turnID: turn.id, label: foldLabel(for: turn), date: turn.startedAt, expanded: foldOpen
            ))))
        }

        let files = isRunning ? [] : turn.changedFiles
        let changedFiles = files.isEmpty ? nil : ChangedFilesModel(
            turnID: turn.id, files: files, closedFolders: expansion.closedFolders[turn.id] ?? []
        )
        var placedChangedFiles = false

        let pieces = interleave(turn.items.filter { foldOpen || !hidden.contains($0.id) }, steers: turn.steers)
        var group: [WorkLogEntry] = []
        var hasLiveActivity = false
        var waitsOnUser = false
        var answered = false

        func flushGroup(trailing: Bool) {
            guard !group.isEmpty else { return }
            defer { group = [] }
            let groupID = "group:\(group[0].id)"
            let expanded = expansion.isGroupOpen(groupID)
            if trailing, isRunning, let last = group.last, !last.isFailed {
                let running = group.last { $0.isActive }
                let current = running ?? last
                let detailed = expanded && expansion.detailed
                // The minimal live row shimmers with the last step too; the detailed steps shimmer
                // only while one runs, else "Thinking" shows the turn is alive.
                let active = running != nil || (!detailed && last.status == .completed)
                hasLiveActivity = hasLiveActivity || active
                if !detailed {
                    let thought = group.last { $0.kind == .reasoning && !($0.detail ?? "").isEmpty }?.detail
                    rows.append(TimelineRow(id: "live:\(turn.id)", content: .liveWork(LiveWorkRowModel(
                        groupID: groupID, entry: current, thought: thought, expanded: expanded, active: active
                    ))))
                    if expanded { appendEntries(group, grouped: true, expansion: expansion, to: &rows) }
                    return
                }
            }
            if group.count == 1, group[0].isToolLike {
                let entry = group[0]
                if !entry.fileChanges.isEmpty {
                    appendDiffs(of: entry, grouped: false, expansion: expansion, to: &rows)
                    return
                }
                rows.append(TimelineRow(id: "entry:\(entry.id)", content: .workEntry(WorkEntryRowModel(
                    entry: entry,
                    displayLabel: nil,
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
            if expanded { appendEntries(group, grouped: true, expansion: expansion, to: &rows) }
        }

        for piece in pieces {
            switch piece {
            case let .steer(message):
                flushGroup(trailing: false)
                answered = false
                rows.append(TimelineRow(id: "user:\(message.id)", content: .user(UserRowModel(
                    message: message, turnID: nil, expanded: expansion.messages.contains(message.id)
                ))))
            case let .item(item):
                answered = false
                switch item.kind {
                case let .assistantMessage(text, isFinal):
                    flushGroup(trailing: false)
                    answered = isFinal
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
                        showMeta: isTerminal || (isFinal && !item.status.isActive),
                        date: item.completedAt ?? item.startedAt,
                        changedFiles: files
                    ))))
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

        if turn.status == .failed, let failure = turn.failureMessage {
            rows.append(TimelineRow(id: "failure:\(turn.id)", content: .error(message: failure, date: turn.completedAt ?? turn.startedAt)))
        }
        if let changedFiles, !placedChangedFiles {
            rows.append(TimelineRow(id: "files:\(turn.id)", content: .changedFiles(changedFiles)))
        }
        if isRunning, !hasLiveActivity, !waitsOnUser, !answered, turn.stopRequestedAt == nil {
            rows.append(TimelineRow(id: "thinking:\(turn.id)", content: .thinking))
        }
    }

    /// The steps of a work group: a diff row per changed file, an entry row for everything else.
    private static func appendEntries(_ entries: [WorkLogEntry], grouped: Bool, expansion: TimelineExpansion, to rows: inout [TimelineRow]) {
        for entry in entries {
            if !entry.fileChanges.isEmpty {
                appendDiffs(of: entry, grouped: grouped, expansion: expansion, to: &rows)
                continue
            }
            rows.append(TimelineRow(id: "entry:\(entry.id)", content: .workEntry(WorkEntryRowModel(
                entry: entry, displayLabel: nil, grouped: grouped, expanded: expansion.entries.contains(entry.id)
            ))))
        }
    }

    private static func appendDiffs(of entry: WorkLogEntry, grouped: Bool, expansion: TimelineExpansion, to rows: inout [TimelineRow]) {
        for (index, change) in entry.fileChanges.enumerated() {
            let id = "\(entry.id):\(index)"
            rows.append(TimelineRow(id: "diff:\(id)", content: .fileDiff(FileDiffRowModel(
                id: id, change: change, status: entry.status, date: entry.startedAt,
                expanded: expansion.isDiffOpen(id), grouped: grouped
            ))))
        }
    }

    /// The closed fold hides commentary and finished work; it keeps every final answer, the last
    /// message, errors, notices, questions, pending approvals and failed work after the last message.
    private static func hidesInFold(_ item: TurnItem, index: Int, terminalIndex: Int, terminalID: String?) -> Bool {
        switch item.kind {
        case let .assistantMessage(_, isFinal):
            return !isFinal && item.id != terminalID
        case .error, .notice, .userInput:
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
        var remaining = steers.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        for item in items {
            while let steer = remaining.first, (steer.createdAt ?? .distantPast) <= (item.startedAt ?? .distantPast) {
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
            case .user, .changedFiles: 16
            case .fold, .working: 6
            case let .assistant(model): model.showMeta ? 16 : 8
            case let .workGroup(model): continues || model.expanded ? 0 : 8
            case let .liveWork(model): continues || model.expanded ? 0 : 8
            case let .workEntry(model):
                if continues { 0 } else { model.grouped ? 4 : 8 }
            case let .fileDiff(model):
                if continues { 0 } else { model.grouped ? 4 : 8 }
            case .thinking, .approval: continues ? 0 : 8
            case .error, .notice, .queued: 8
            case .empty: 0
            }
            rows[index].bottomSpacing = spacing
        }
    }
}
