import Foundation

/// One agent tab as presented by the global monitoring dashboard.
struct AgentDashboardEntry: Identifiable, Equatable {
    var id: String { "\(paneId):\(tabId)" }

    let paneId: String
    let tabId: String
    let tabTitle: String
    let windowTitle: String
    let profileId: String
    let profileName: String
    let status: AgentStatus
    let needsAttention: Bool
    let startedAt: Date?
    let cwd: String?
    var sessionName: String? = nil
    /// The agent's own conversation, which locates the transcript the
    /// dashboard renders as a timeline.
    var conversation: AgentConversation? = nil
    /// The branch the agent works on when it is not its repository's default;
    /// the dashboard fills it in from the shared `GitBranchMonitor`.
    var branch: String? = nil

    /// What the agent works on, as the sidebar names it: its task title
    /// without the CLI's brand and spinner, or its name before it has one.
    var title: String {
        TerminalTitle.display(tabTitle, workingDirectory: cwd, agentName: profileName)
    }

    /// `omp · soprano · ⎇ feat/x`, the line under the title.
    var context: PaneContextLine {
        PaneContextLine(title: title, agentName: profileName, workingDirectory: cwd, branch: branch)
    }

    /// `session ▸ window ▸ title`, for tooltips.
    var location: String {
        [sessionName, windowTitle, title].compactMap { $0 }.joined(separator: " ▸ ")
    }
}

/// The groups the dashboard lists agents under, most urgent first. Each
/// covers a contiguous run of the snapshot's urgency order.
enum AgentDashboardSection: CaseIterable, Equatable {
    /// Asks for attention, waits for input, or failed.
    case needsYou
    case working
    case ready
    case stopped

    init(entry: AgentDashboardEntry) {
        if entry.needsAttention {
            self = .needsYou
            return
        }
        switch entry.status {
        case .waiting, .error: self = .needsYou
        case .running, .starting: self = .working
        case .idle: self = .ready
        case .stopped: self = .stopped
        }
    }

    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .ready: "Ready"
        case .stopped: "Stopped"
        }
    }

    /// `entries`, already in urgency order, under their sections, leaving out
    /// empty ones.
    static func group(
        _ entries: [AgentDashboardEntry]
    ) -> [(section: AgentDashboardSection, entries: [AgentDashboardEntry])] {
        allCases.compactMap { section in
            let members = entries.filter { AgentDashboardSection(entry: $0) == section }
            return members.isEmpty ? nil : (section, members)
        }
    }
}

/// A point-in-time, presentation-ready view of every attached agent.
///
/// This deliberately contains no mutable state. AgentManager remains the source
/// of truth; the dashboard rebuilds this snapshot after ordinary model
/// notifications and redraws only the entries that differ from the last one.
struct AgentDashboardSnapshot {
    let entries: [AgentDashboardEntry]

    var totalCount: Int { entries.count }
    var workingCount: Int {
        entries.filter { $0.status == .starting || $0.status == .running }.count
    }
    var needsInputCount: Int {
        entries.filter { $0.status == .waiting }.count
    }
    var errorCount: Int {
        entries.filter { $0.status == .error }.count
    }

    init(entries: [AgentDashboardEntry]) {
        self.entries = entries.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = Self.urgencyRank(for: lhs.element)
                let rhsRank = Self.urgencyRank(for: rhs.element)
                return lhsRank == rhsRank
                    ? lhs.offset < rhs.offset
                    : lhsRank < rhsRank
            }
            .map(\.element)
    }

    private static func urgencyRank(for entry: AgentDashboardEntry) -> Int {
        if entry.needsAttention { return 0 }
        switch entry.status {
        case .waiting: return 1
        case .error: return 2
        case .running: return 3
        case .starting: return 4
        case .idle: return 5
        case .stopped: return 6
        }
    }
}
