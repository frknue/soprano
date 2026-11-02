import Foundation
import SopranoAgentsCore

/// What the user opened or closed in the timeline. Ids are turn, group and item ids, unique
/// across threads, so one value serves the whole window.
///
/// `turns`, `groups` and `diffs` hold what the user toggled away from the work log's default:
/// closed in the minimal work log, open in the detailed one (`detailed`). Read them through
/// `isTurnOpen` / `isGroupOpen` / `isDiffOpen`.
struct TimelineExpansion: Hashable, Sendable {
    /// Finished turns whose "Worked for …" fold the user toggled.
    var turns: Set<String> = []
    /// Finished turns whose checks (advisor reviews, double-checks after the first answer) are open.
    var checks: Set<String> = []
    /// Work groups (and live work rows) the user toggled.
    var groups: Set<String> = []
    /// Work entries showing their output.
    var entries: Set<String> = []
    /// Long user messages shown in full.
    var messages: Set<String> = []
    /// Changed-files cards: turn id → closed folder paths.
    var closedFolders: [String: Set<String>] = [:]
    /// File diffs (`FileDiffRowModel.id`) the user toggled.
    var diffs: Set<String> = []
    /// The detailed work log (`chat.workLog`): folds, work groups and file diffs open by default.
    var detailed = false

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
    /// The turn this message started; nil for steers (they cannot be edited from).
    var turnID: String?
    var canEdit: Bool
    var expanded: Bool
    /// Offers "Edit from here" (a subagent's runs cannot be rewound).
    var editable = true
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
    /// A final answer once it is complete (every one of the turn's runs: a double-check or advisor
    /// pass answers again), or the finished turn's last message: copy button and timestamp below it.
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

/// One file an edit or write touched: a header line ("Edited Sources/App.swift  +12 −3") that
/// opens its diff. A running call shows the code as the model writes it.
struct FileDiffRowModel: Hashable, Sendable {
    /// The item id and the file's index in it: the row's expansion key.
    var id: String
    var change: FileChange
    var status: TurnItemStatus
    var date: Date
    var expanded: Bool
    /// Part of an expanded group (no own vertical padding).
    var grouped: Bool

    var isActive: Bool { status.isActive }
    var canExpand: Bool { !(change.diff ?? "").isEmpty }

    /// "Editing App.swift", "Created App.swift", "Edit failed: App.swift".
    var label: String {
        let path = change.movePath.map { "\(change.path) → \($0)" } ?? change.path
        let verb: String = switch (status, change.kind) {
        case (.pending, .add), (.running, .add): "Writing"
        case (.pending, _), (.running, _): "Editing"
        case (.failed, _): "Edit failed:"
        case (.declined, _): "Declined"
        case (.interrupted, _): "Stopped editing"
        case (.completed, .add): "Created"
        case (.completed, .delete): "Deleted"
        case (.completed, .move): "Moved"
        case (.completed, .update): "Edited"
        }
        return "\(verb) \(path)"
    }
}

struct ApprovalRowModel: Hashable, Sendable {
    var request: ApprovalRequest
}

/// One advisor note under the agent's work: who flagged it, how serious, the note.
struct AdvisoryRowModel: Hashable, Sendable {
    var note: AdvisorNote
    var date: Date
}

/// One check that woke the agent after a finished turn's first answer (an advisor review, omp's
/// auto-double-check) and how the agent's reply to it opens.
struct CheckPassModel: Hashable, Sendable {
    /// "Final reviewer", "Double-check"; several when they woke the agent together.
    var sources: [String]
    /// The most serious advisor note; nil when no advisor took part.
    var severity: AdvisorNote.Severity?
    /// The reply's opening prose (`TimelineBuilder.openingProse`); nil when the agent did not reply.
    var outcome: String?
    /// The first advisor note's opening prose, shown when the agent did not reply.
    var note: String?
}

/// "2 checks after this answer" under a finished turn's first answer: one line per check while
/// closed; open, the checks' notes, replies and work follow it.
struct ChecksRowModel: Hashable, Sendable {
    var turnID: String
    var passes: [CheckPassModel]
    var expanded: Bool
}

enum TimelineRowContent: Hashable, Sendable {
    case user(UserRowModel)
    case fold(FoldRowModel)
    case working(startedAt: Date, stopping: Bool)
    case assistant(AssistantRowModel)
    case workGroup(WorkGroupRowModel)
    case workEntry(WorkEntryRowModel)
    case fileDiff(FileDiffRowModel)
    case liveWork(LiveWorkRowModel)
    case thinking
    case approval(ApprovalRowModel)
    case error(message: String, date: Date)
    case notice(text: String)
    case advisory(AdvisoryRowModel)
    case checks(ChecksRowModel)
    /// "Background work still running…" under a yielded turn.
    case backgroundWork
    case changedFiles(ChangedFilesModel)
    case queued(UserMessage)
    case empty

    /// Rows of the work log: adjacent ones sit flush.
    var isWorkLog: Bool {
        switch self {
        case .workGroup, .workEntry, .fileDiff, .liveWork, .thinking, .approval: true
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
/// - Each turn: the user message, then "Working for" while it runs ("Stopping…" once Stop was
///   pressed, without "Thinking"), or a "Worked for …" fold when
///   it finished (closed by default; it hides commentary and work, never an answer or a card). A
///   yielded turn (answer final, background work still running) shows as finished, with a
///   "Background work still running…" note at its end.
/// - A turn can answer more than once: an advisor review or omp's auto-double-check wakes the
///   agent after its answer. A completed turn that background work never woke keeps its first
///   answer (the recap) as its answer, with the changed files under it, and closes everything
///   after it behind one checks row that names each check and the opening prose of the agent's
///   reply to it (errors and failed work after the last message stay out). Open, the checks show
///   as while the turn ran: every final answer stays out of the fold.
/// - Consecutive tool items form a work group: one summary row ("Read 2 files and ran 1 command"),
///   or a single entry row when the group holds one tool call. A file change shows as one diff
///   row per file (`FileDiffRowModel`).
/// - The detailed work log (`TimelineExpansion.detailed`) opens folds, groups and diffs by
///   default; a running turn's trailing group then shows like any open group, its running step
///   shimmering and expandable (command output, an edit's diff growing while the model writes
///   it). Collapsing that group gives the minimal live row.
/// - A running turn's trailing tools become one live row; "Thinking" ends a running turn that
///   shows no live tool, waits on nobody and has not just answered (omp wraps up after the
///   final answer before it ends the turn); an answer from before background work woke the turn
///   (`Turn.resumedAt`) no longer counts.
/// - Steers sit at the time they were sent; queued messages close the thread.
enum TimelineBuilder {
    /// `editable` false: no "Edit from here" (a subagent's runs, shown as a thread).
    static func rows(for thread: AgentThread?, expansion: TimelineExpansion = TimelineExpansion(), editable: Bool = true) -> [TimelineRow] {
        guard let thread else { return [] }
        var rows: [TimelineRow] = []
        if thread.turns.isEmpty, thread.queue.isEmpty {
            return [TimelineRow(id: "empty", content: .empty)]
        }
        for turn in thread.turns {
            appendTurn(turn, of: thread, expansion: expansion, editable: editable, to: &rows)
        }
        for queued in thread.queue {
            rows.append(TimelineRow(id: "queued:\(queued.id)", content: .queued(queued.message)))
        }
        applySpacing(&rows)
        return rows
    }

    /// Fold label: "Worked for 3m 12s", "You stopped after 12s".
    static func foldLabel(for turn: Turn) -> String {
        let duration = DurationText.turn(turn.duration(now: turn.startedAt))
        return turn.status == .interrupted ? "You stopped after \(duration)" : "Worked for \(duration)"
    }

    // MARK: - Turns

    private enum Piece {
        case item(TurnItem)
        case steer(UserMessage)
    }

    private static func appendTurn(_ turn: Turn, of thread: AgentThread, expansion: TimelineExpansion, editable: Bool, to rows: inout [TimelineRow]) {
        let isRunning = turn.status == .running && !turn.isYielded
        let status = turn.isYielded ? turn.yieldedStatus : turn.status
        rows.append(TimelineRow(id: "user:\(turn.userMessage.id)", content: .user(UserRowModel(
            message: turn.userMessage,
            turnID: turn.id,
            canEdit: !thread.isRunning,
            expanded: expansion.messages.contains(turn.userMessage.id),
            editable: editable
        ))))

        let terminalID = turn.items.last { if case .assistantMessage = $0.kind { return true } else { return false } }?.id
        let terminalIndex = terminalID.flatMap { id in turn.items.firstIndex { $0.id == id } } ?? turn.items.count

        // Checks after the first answer: the closed checks row hides them. Only a completed turn
        // that background work never woke has them (stopped, failed, yielded and woken turns
        // show every answer). Errors and failed work after the last message stay out.
        let checks = turn.status == .completed && turn.wokenAt == nil ? checkSection(of: turn) : nil
        let checksOpen = expansion.checks.contains(turn.id)
        var checkHidden: Set<String> = []
        if let checks, !checksOpen {
            for index in turn.items.indices.dropFirst(checks.start) {
                let item = turn.items[index]
                switch item.kind {
                case .error: continue
                case .reasoning, .command, .fileChange, .toolCall, .webSearch:
                    if index > terminalIndex, item.status == .failed { continue }
                default: break
                }
                checkHidden.insert(item.id)
            }
        }

        // Which items the closed fold hides (work behind the checks row counts, so the fold row
        // does not come and go with the checks).
        var hidden: Set<String> = []
        if !isRunning, status != .failed {
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

        let checkpointFiles = turn.checkpoint.flatMap { $0.status == .ready && !$0.files.isEmpty ? $0.files : nil }
        let changedFiles = checkpointFiles.map {
            ChangedFilesModel(turnID: turn.id, turnOrdinal: turn.ordinal, files: $0, closedFolders: expansion.closedFolders[turn.id] ?? [])
        }
        var placedChangedFiles = false

        let pieces = interleave(turn.items.filter { !checkHidden.contains($0.id) && (foldOpen || !hidden.contains($0.id)) }, steers: turn.steers)
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
                let active = running != nil || last.status == .completed
                hasLiveActivity = hasLiveActivity || active
                // Detailed: the group shows as any open one below (its header collapses it to this
                // live row); the running step shimmers and opens like the others (command output,
                // the edit's code as it is written).
                if !(expanded && expansion.detailed) {
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
                    message: message, turnID: nil, canEdit: false, expanded: expansion.messages.contains(message.id)
                ))))
            case let .item(item):
                let previousAnswered = answered
                answered = false
                switch item.kind {
                case let .assistantMessage(text, isFinal):
                    flushGroup(trailing: false)
                    let endedBeforeResume = turn.resumedAt.map { (item.completedAt ?? item.startedAt) < $0 } ?? false
                    answered = isFinal && !endedBeforeResume
                    let isTerminal = item.id == terminalID && !isRunning
                    let showMeta = isTerminal || (isFinal && !item.status.isActive)
                    var files: ChangedFilesModel?
                    // With checks, the recap carries the turn's changed files.
                    if item.id == (checks?.recapID ?? terminalID), !isRunning, let changedFiles {
                        files = changedFiles
                        placedChangedFiles = true
                    }
                    rows.append(TimelineRow(id: "assistant:\(item.id)", content: .assistant(AssistantRowModel(
                        itemID: item.id,
                        text: text,
                        isStreaming: item.status.isActive && isRunning,
                        showMeta: showMeta,
                        date: item.completedAt ?? item.startedAt,
                        changedFiles: files
                    ))))
                    if let checks, item.id == checks.recapID {
                        rows.append(TimelineRow(id: "checks:\(turn.id)", content: .checks(ChecksRowModel(
                            turnID: turn.id, passes: checks.passes, expanded: checksOpen
                        ))))
                    }
                case let .error(message):
                    flushGroup(trailing: false)
                    rows.append(TimelineRow(id: "error:\(item.id)", content: .error(message: message, date: item.startedAt)))
                case let .notice(text):
                    flushGroup(trailing: false)
                    rows.append(TimelineRow(id: "notice:\(item.id)", content: .notice(text: text)))
                case let .advisory(notes):
                    flushGroup(trailing: false)
                    // A review is not the agent working: an answer before it stays the last word.
                    answered = previousAnswered
                    for (index, note) in notes.enumerated() {
                        rows.append(TimelineRow(id: "advisory:\(item.id):\(index)", content: .advisory(AdvisoryRowModel(note: note, date: item.startedAt))))
                    }
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

        if status == .failed, let failure = turn.failureMessage,
           !turn.items.contains(where: { if case .error = $0.kind { return true } else { return false } }) {
            rows.append(TimelineRow(id: "failure:\(turn.id)", content: .error(message: failure, date: turn.endedAt ?? turn.startedAt)))
        }
        if let changedFiles, !placedChangedFiles, !isRunning {
            rows.append(TimelineRow(id: "files:\(turn.id)", content: .changedFiles(changedFiles)))
        }
        if isRunning, !hasLiveActivity, !waitsOnUser, !answered, turn.stopRequestedAt == nil {
            rows.append(TimelineRow(id: "thinking:\(turn.id)", content: .thinking))
        }
        if turn.isYielded {
            rows.append(TimelineRow(id: "background:\(turn.id)", content: .backgroundWork))
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

    /// The closed fold hides commentary and finished work; it keeps every final answer (a
    /// second pass must not bury the first), the last message, cards, errors, notices, advisor
    /// notes, questions, pending approvals and failed work after the last message.
    private static func hidesInFold(_ item: TurnItem, index: Int, terminalIndex: Int, terminalID: String?) -> Bool {
        switch item.kind {
        case let .assistantMessage(_, isFinal):
            return !isFinal && item.id != terminalID
        case .error, .notice, .advisory, .userInput:
            return false
        case let .approval(request):
            return request.decision != nil
        case .reasoning, .command, .fileChange, .toolCall, .webSearch:
            if index > terminalIndex, item.status == .failed { return false }
            guard let entry = WorkLog.entry(for: item) else { return false }
            return entry.isVisible
        }
    }

    private struct CheckSection {
        /// The turn's first final answer.
        var recapID: String
        /// Index of the first item after the recap the checks row holds.
        var start: Int
        var passes: [CheckPassModel]
    }

    /// The checks after a turn's first final answer: from the first advisor review, or
    /// auto-double-check notice right after an answer, that follows it. nil when the user steered
    /// after the answer, the agent answered again unprompted, or nothing woke it to reply.
    /// Triggers with no reply between them form one pass; other notices (compaction, retries)
    /// are neither.
    private static func checkSection(of turn: Turn) -> CheckSection? {
        guard let recapIndex = turn.items.firstIndex(where: {
            if case .assistantMessage(_, true) = $0.kind { true } else { false }
        }) else { return nil }
        let recap = turn.items[recapIndex]
        let answeredAt = recap.completedAt ?? recap.startedAt
        guard !turn.steers.contains(where: { $0.createdAt >= answeredAt }) else { return nil }

        var start: Int?
        var passes: [CheckPassModel] = []
        var current: CheckPassModel?
        var afterAnswer = true
        func trigger(_ sources: [String], severity: AdvisorNote.Severity?, note: String? = nil, at index: Int) {
            if start == nil { start = index }
            if let pass = current, pass.outcome != nil {
                passes.append(pass)
                current = nil
            }
            var pass = current ?? CheckPassModel(sources: [])
            for source in sources where !pass.sources.contains(source) { pass.sources.append(source) }
            if let severity, severityRank(severity) > pass.severity.map(severityRank) ?? -1 { pass.severity = severity }
            if pass.note == nil { pass.note = note }
            current = pass
        }
        for index in turn.items.indices.dropFirst(recapIndex + 1) {
            let item = turn.items[index]
            switch item.kind {
            case let .advisory(notes):
                let worst = notes.map(\.severity).max { severityRank($0) < severityRank($1) }
                trigger(notes.map { $0.advisor ?? "Advisor" }, severity: worst, note: notes.first.flatMap { openingProse($0.text) }, at: index)
            case let .notice(text) where afterAnswer && isDoubleCheck(text):
                trigger(["Double-check"], severity: nil, at: index)
            case let .assistantMessage(text, isFinal):
                guard current != nil else { return nil }
                // The pass's final answer is its reply; commentary only stands in until one comes.
                if isFinal || current?.outcome == nil, let prose = openingProse(text) { current?.outcome = prose }
                afterAnswer = isFinal
            case .command, .fileChange, .toolCall, .webSearch, .approval, .userInput:
                afterAnswer = false
            case .reasoning, .error, .notice:
                break
            }
        }
        if let pass = current, pass.outcome != nil || pass.severity != nil { passes.append(pass) }
        guard let start, !passes.isEmpty else { return nil }
        return CheckSection(recapID: recap.id, start: start, passes: passes)
    }

    private static func severityRank(_ severity: AdvisorNote.Severity) -> Int {
        switch severity {
        case .nit: 0
        case .concern: 1
        case .blocker: 2
        }
    }

    /// omp's auto-double-check notice ("auto-double-check: second pass before finishing").
    private static func isDoubleCheck(_ notice: String) -> Bool {
        notice.localizedCaseInsensitiveContains("double-check")
    }

    /// About four lines of the checks row's reply column.
    private static let proseBudget = 480

    /// How a reply reads at a glance, inline Markdown removed: its prose from the top, paragraph
    /// after paragraph, until about four lines' worth (`proseBudget` characters). Headings,
    /// all-bold title lines ("**Double-check report**"), tables, fences and rules are skipped;
    /// list items read as sentences. More than the first sentence or paragraph: a correction often
    /// comes later ("I changed PR #47 after the review. … that changes my earlier conclusion", a
    /// report's "**Defects:** …" under its table). A reply without prose gives its table rows.
    static func openingProse(_ markdown: String) -> String? {
        var parts: [String] = []
        var length = 0
        var tableRows: [String] = []
        var title: String?
        var inFence = false
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence || line.isEmpty || line.allSatisfy({ "-*_= ".contains($0) }) { continue }
            if line.hasPrefix("|") {
                let cells = line.split(separator: "|").map { plainInline(String($0)) }
                    .filter { !$0.isEmpty && !$0.allSatisfy { "-: ".contains($0) } }
                if !cells.isEmpty { tableRows.append(cells.joined(separator: " · ")) }
                continue
            }
            let text = plainInline(line)
            guard !text.isEmpty else { continue }
            let isHeading = line.range(of: #"^#{1,6}(\s|$)"#, options: .regularExpression) != nil
            let isBoldTitle = line.hasPrefix("**") && line.hasSuffix("**") && line.components(separatedBy: "**").count == 3
            if isHeading || isBoldTitle {
                if title == nil { title = text }
                continue
            }
            parts.append(text)
            length += text.count + 1
            if length >= proseBudget { break }
        }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        if !tableRows.isEmpty { return tableRows.joined(separator: " / ") }
        return title
    }

    /// One Markdown line as it reads: heading, quote and list markers, links, emphasis and code
    /// ticks removed ("#47" stays: a heading marker needs a space after it).
    private static func plainInline(_ line: String) -> String {
        var text = line
        for pattern in [#"^#{1,6}\s+"#, #"^(>\s?)+"#, #"^[-*+]\s+"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for marker in ["**", "__", "`"] { text = text.replacingOccurrences(of: marker, with: "") }
        return text.trimmingCharacters(in: .whitespaces)
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
            case .error, .notice, .advisory, .queued: 8
            case let .checks(model): model.expanded ? 8 : 16
            case .backgroundWork: 16
            case .empty: 0
            }
            rows[index].bottomSpacing = spacing
        }
    }
}
