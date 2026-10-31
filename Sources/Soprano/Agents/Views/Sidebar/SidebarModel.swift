import AppKit
import SopranoAgentsCore

/// One thread as the sidebar shows it (card or slim row). Built from engine state; views only
/// render it.
struct SidebarThreadRow: Equatable {
    let threadID: String
    let title: String
    let projectID: String?
    let projectTitle: String?
    let branch: String?
    let isWorktree: Bool
    /// Lines added/removed by the last turn's checkpoint; nil when there is nothing to show.
    let diff: DiffStat?
    let provider: ProviderKind
    let status: ThreadStatus
    /// "Nm" times count from here (latest user message, else last update).
    let activityDate: Date
    let settledAt: Date?
    let isPinned: Bool
    let isSettled: Bool
    let isSelected: Bool
    /// Read and idle (or working in the background): drawn muted as a receded row.
    let recedes: Bool
    let isGeneratingTitle: Bool
    /// The thread's subagents (the card's disclosure); nil when it has none.
    let subagents: SubagentSummary?

    struct SubagentSummary: Equatable {
        let count: Int
        let running: Int
        /// Its subagent rows are listed under the card.
        let expanded: Bool
    }

    struct DiffStat: Equatable {
        let additions: Int
        let deletions: Int
    }

    /// Settled rows show when they were settled; everything else the last activity.
    var timestamp: Date { isSettled ? (settledAt ?? activityDate) : activityDate }
}

/// A subagent row under its thread's card.
struct SidebarSubagentRow: Equatable {
    let threadID: String
    let subagentID: String
    /// The provider's name ("Reader"); shown.
    let name: String
    let agent: String
    /// What it is doing while it runs (latest intent), else its description or assignment.
    let detail: String?
    let status: SubagentStatus
    /// Start of its latest run; running rows count from here.
    let since: Date
    let isSelected: Bool
    /// Last subagent of its thread (the tree line ends here).
    let isLast: Bool
}

/// A row of the sidebar list, top to bottom.
enum SidebarItem: Equatable {
    /// Pinned, Active and Working threads (78 pt cards).
    case card(SidebarThreadRow)
    /// Settled threads (36 pt rows).
    case slim(SidebarThreadRow)
    /// A thread's subagent, listed under its card while the card's disclosure is open (the
    /// selected subagent always).
    case subagent(SidebarSubagentRow)
    /// "Working 2 ›" / "Settled 43 ›" shelf header.
    case shelf(InboxSection, count: Int, expanded: Bool)
    /// "Show 25 more" under the visible part of the Settled shelf.
    case showMore(Int)
    /// Flexible gap that pushes the shelves to the bottom of the list (`mt-auto`).
    case spacer
    case empty(SidebarEmptyState)

    var thread: SidebarThreadRow? {
        switch self {
        case let .card(row), let .slim(row): row
        default: nil
        }
    }

    /// Identity for incremental reloads: same id = same view kind showing the same thing.
    var identity: String {
        switch self {
        case let .card(row): "card:\(row.threadID)"
        case let .slim(row): "slim:\(row.threadID)"
        case let .shelf(section, _, _): "shelf:\(section.rawValue)"
        case let .subagent(row): "subagent:\(row.threadID):\(row.subagentID)"
        case .showMore: "more"
        case .spacer: "spacer"
        case let .empty(state): "empty:\(state.message)"
        }
    }
}

enum SidebarEmptyState: Equatable {
    /// "No projects yet" + "Add project".
    case noProjects
    case noThreads(String)
    /// Search without matches.
    case noResults

    var message: String {
        switch self {
        case .noProjects: "No projects yet"
        case let .noThreads(message): message
        case .noResults: "No threads found"
        }
    }
}

/// Status slot of a row: a status pill.
struct SidebarStatusPill: Equatable {
    let label: String
    let symbol: String
    let tone: ThreadStatusTone
    /// Live duration counts from here ("Working 12s").
    let since: Date?

    static func of(_ status: ThreadStatus) -> SidebarStatusPill? {
        switch status {
        case let .working(since): SidebarStatusPill(label: "Working", symbol: Icon.circleDashed, tone: .working, since: since)
        case .approval: SidebarStatusPill(label: "Approval", symbol: Icon.shieldQuestion, tone: .approval, since: nil)
        case .input: SidebarStatusPill(label: "Input", symbol: Icon.messageQuestion, tone: .input, since: nil)
        case .failed: SidebarStatusPill(label: "Failed", symbol: Icon.circleAlert, tone: .failed, since: nil)
        case .done: SidebarStatusPill(label: "Done", symbol: Icon.circleCheck, tone: .done, since: nil)
        case .idle: nil
        }
    }

    /// "Working 12s", "Approval".
    func text(now: Date) -> String {
        guard let since else { return label }
        return "\(label) \(DurationText.compact(now.timeIntervalSince(since)))"
    }
}

/// Inputs of one sidebar render besides the engine's threads and projects.
struct SidebarListOptions: Equatable {
    /// The selected thread, or the selected subagent's thread.
    var selectedThreadID: String?
    /// The selected subagent; its thread's card is then not selected.
    var selectedSubagentID: String?
    /// Empty = all projects.
    var projectFilter: Set<String> = []
    var searchText = ""
    var expandedShelves: Set<InboxSection> = []
    /// Settled rows shown while the Settled shelf is open.
    var settledLimit = SidebarListModel.settledInitialCount
    /// Subagent disclosures the user opened (true) or closed (false) per thread; others are open
    /// while a subagent runs.
    var subagentDisclosure: [String: Bool] = [:]
}

/// Builds the sidebar rows: Pinned and Active cards, then the
/// Working and Settled shelves pushed to the bottom. Searching replaces the list with matches.
enum SidebarListModel {
    static let settledInitialCount = 10
    static let settledPageCount = 25

    static func build(threads: [AgentThread], projects: [Project], options: SidebarListOptions) -> [SidebarItem] {
        let projectsByID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let scoped = threads.filter { thread in
            guard InboxSection.of(thread) != nil else { return false }
            guard !options.projectFilter.isEmpty else { return true }
            return thread.projectID.map(options.projectFilter.contains) ?? false
        }

        let query = options.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let found = scoped
                .filter { matches($0, query: query) }
                .sorted { $0.activityDate > $1.activityDate }
            guard !found.isEmpty else { return [.empty(.noResults)] }
            return found.flatMap { thread -> [SidebarItem] in
                [.card(row(for: thread, projects: projectsByID, options: options))] + subagentRows(of: thread, options: options)
            }
        }

        var pinned: [AgentThread] = []
        var active: [AgentThread] = []
        var working: [AgentThread] = []
        var settled: [AgentThread] = []
        for thread in scoped {
            switch InboxSection.of(thread) {
            case .pinned: pinned.append(thread)
            case .active: active.append(thread)
            case .working: working.append(thread)
            case .settled: settled.append(thread)
            case nil: break
            }
        }

        guard pinned.count + active.count + working.count + settled.count > 0 else {
            return [.empty(emptyState(projects: projects, filter: options.projectFilter))]
        }

        pinned.sort { ($0.pinnedAt ?? .distantPast, $0.id) < ($1.pinnedAt ?? .distantPast, $1.id) }
        active.sort(by: newestActivityFirst)
        working.sort { workingSince($0) > workingSince($1) }
        settled.sort { ($0.settledAt ?? $0.activityDate) > ($1.settledAt ?? $1.activityDate) }

        func card(_ thread: AgentThread) -> [SidebarItem] {
            [.card(row(for: thread, projects: projectsByID, options: options))] + subagentRows(of: thread, options: options)
        }
        func slim(_ thread: AgentThread) -> [SidebarItem] {
            [.slim(row(for: thread, projects: projectsByID, options: options))] + subagentRows(of: thread, options: options)
        }
        /// A closed shelf still shows the open thread.
        func visible(_ threads: [AgentThread], in section: InboxSection) -> [AgentThread] {
            options.expandedShelves.contains(section) ? threads : threads.filter { $0.id == options.selectedThreadID }
        }

        var items = pinned.flatMap(card) + active.flatMap(card)
        items.append(.spacer)
        if !working.isEmpty {
            items.append(.shelf(.working, count: working.count, expanded: options.expandedShelves.contains(.working)))
            items += visible(working, in: .working).flatMap(card)
        }
        let settledExpanded = options.expandedShelves.contains(.settled)
        items.append(.shelf(.settled, count: settled.count, expanded: settledExpanded))
        if settledExpanded {
            let limit = max(0, options.settledLimit)
            var shown = Array(settled.prefix(limit))
            // The open thread stays visible even past the page.
            if let selected = settled.dropFirst(limit).first(where: { $0.id == options.selectedThreadID }) {
                shown.append(selected)
            }
            items += shown.flatMap(slim)
            let hidden = settled.count - shown.count
            if hidden > 0 { items.append(.showMore(min(hidden, settledPageCount))) }
        } else {
            items += visible(settled, in: .settled).flatMap(slim)
        }
        return items
    }

    /// Thread ids in list order (previous/next and ⌃1…⌃9 follow it).
    static func threadOrder(_ items: [SidebarItem]) -> [String] {
        items.compactMap { $0.thread?.threadID }
    }

    static func row(for thread: AgentThread, projects: [String: Project], options: SidebarListOptions) -> SidebarThreadRow {
        let status = ThreadStatus.of(thread)
        let selected = thread.id == options.selectedThreadID && options.selectedSubagentID == nil
        let checkpoint = thread.turns.last?.checkpoint
        let diff: SidebarThreadRow.DiffStat? = checkpoint.flatMap { checkpoint in
            guard checkpoint.status == .ready, checkpoint.additions + checkpoint.deletions > 0 else { return nil }
            return SidebarThreadRow.DiffStat(additions: checkpoint.additions, deletions: checkpoint.deletions)
        }
        return SidebarThreadRow(
            threadID: thread.id,
            title: thread.title,
            projectID: thread.projectID,
            projectTitle: projects[thread.projectID ?? ""]?.title,
            branch: thread.branch,
            isWorktree: thread.worktreePath != nil,
            diff: diff,
            provider: thread.modelSelection.provider,
            status: status,
            activityDate: thread.activityDate,
            settledAt: thread.settledAt,
            isPinned: thread.pinnedAt != nil,
            isSettled: thread.settledAt != nil,
            isSelected: selected,
            recedes: recedes(status: status, selected: selected),
            isGeneratingTitle: thread.isGeneratingTitle,
            subagents: thread.subagents.isEmpty ? nil : SidebarThreadRow.SubagentSummary(
                count: thread.subagents.count,
                running: thread.subagents.filter(\.isRunning).count,
                expanded: subagentsExpanded(thread, options: options)
            )
        )
    }

    /// The card's disclosure: as the user left it, else open while a subagent runs.
    static func subagentsExpanded(_ thread: AgentThread, options: SidebarListOptions) -> Bool {
        options.subagentDisclosure[thread.id] ?? thread.subagents.contains(where: \.isRunning)
    }

    /// Subagent rows under a thread's card or slim row: all of them while its disclosure is open,
    /// else only the selected one.
    static func subagentRows(of thread: AgentThread, options: SidebarListOptions) -> [SidebarItem] {
        let selectedID = thread.id == options.selectedThreadID ? options.selectedSubagentID : nil
        let shown = subagentsExpanded(thread, options: options)
            ? thread.subagents
            : thread.subagents.filter { $0.id == selectedID }
        return shown.enumerated().map { index, subagent in
            let detail = subagent.isRunning
                ? subagent.lastIntent ?? subagent.description ?? subagent.assignment
                : subagent.description ?? subagent.assignment ?? subagent.lastIntent
            return .subagent(SidebarSubagentRow(
                threadID: thread.id,
                subagentID: subagent.id,
                name: subagent.name,
                agent: subagent.agent,
                detail: detail.map(firstLine),
                status: subagent.status,
                since: subagent.turns.last?.startedAt ?? subagent.startedAt,
                isSelected: subagent.id == selectedID,
                isLast: index == shown.count - 1
            ))
        }
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// Read rows that need nothing step back.
    static func recedes(status: ThreadStatus, selected: Bool) -> Bool {
        if selected { return false }
        switch status {
        case .working, .idle: return true
        case .approval, .input, .failed, .done: return false
        }
    }

    /// Title, branch, or any message text contains `query` (case- and diacritic-insensitive).
    static func matches(_ thread: AgentThread, query: String) -> Bool {
        func has(_ text: String?) -> Bool {
            guard let text else { return false }
            return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        if has(thread.title) || has(thread.branch) { return true }
        for turn in thread.turns {
            if has(turn.userMessage.text) { return true }
            if turn.steers.contains(where: { has($0.text) }) { return true }
            for item in turn.items {
                if case let .assistantMessage(text, _) = item.kind, has(text) { return true }
            }
        }
        return thread.queue.contains { has($0.message.text) }
    }

    static func emptyState(projects: [Project], filter: Set<String>) -> SidebarEmptyState {
        if projects.isEmpty { return .noProjects }
        let scoped = projects.filter { filter.contains($0.id) }
        if scoped.count > 1 { return .noThreads("No threads in these projects yet") }
        if let only = scoped.first { return .noThreads("No threads in \(only.title) yet") }
        return .noThreads("No threads yet")
    }

    private static func newestActivityFirst(_ lhs: AgentThread, _ rhs: AgentThread) -> Bool {
        if lhs.activityDate != rhs.activityDate { return lhs.activityDate > rhs.activityDate }
        return lhs.id < rhs.id
    }

    private static func workingSince(_ thread: AgentThread) -> Date {
        thread.activeTurn?.startedAt ?? thread.activityDate
    }
}

/// Diff counts: exact under 1000, then "1.2k".
enum DiffCountText {
    static func format(_ count: Int) -> String {
        guard count >= 1000 else { return "\(count)" }
        let thousands = Double(count) / 1000
        return thousands >= 10 ? "\(Int(thousands))k" : String(format: "%.1fk", thousands).replacingOccurrences(of: ".0k", with: "k")
    }
}

/// The project monogram: two glyphs and a color derived from the name.
enum ProjectIdentity {
    static func monogram(_ name: String) -> String {
        let normalized = name.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = normalized
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { !$0.isEmpty }
        guard let firstWord = words.first, let first = firstWord.first else { return "PR" }
        let second = firstWord.dropFirst().first(where: \.isNumber)
            ?? (words.count > 1 ? words.last?.first : firstWord.last)
            ?? first
        return String(String([first, second]).uppercased().prefix(2))
    }

    /// Index into `Palette.projectIconColors` (`(index * 31 + codePoint) % count` over the lowercased name).
    static func colorIndex(_ name: String, count: Int) -> Int {
        let normalized = name.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = normalized.isEmpty ? "project" : normalized.lowercased()
        var index = 0
        for scalar in seed.unicodeScalars {
            index = (index * 31 + Int(scalar.value)) % count
        }
        return index
    }
}
