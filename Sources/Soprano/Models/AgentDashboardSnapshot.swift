import Foundation

/// One agent tab as presented by the global monitoring dashboard.
struct AgentDashboardEntry: Identifiable {
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
}

/// A point-in-time, presentation-ready view of every attached agent.
///
/// This deliberately contains no mutable state. AgentManager remains the source
/// of truth and the dashboard rebuilds this snapshot after ordinary model
/// notifications.
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
