import Foundation

/// The status pill a thread shows in the sidebar, in priority order.
public enum ThreadStatus: Sendable, Hashable {
    /// Waiting on an approval decision.
    case approval
    /// Waiting on answers to agent questions.
    case input
    /// A turn is running; `since` drives the live duration.
    case working(since: Date)
    /// The last turn failed and the user has not looked since.
    case failed
    /// The last turn finished after the user's last visit.
    case done
    /// Nothing to report: the sidebar shows a relative time.
    case idle

    public static func of(_ thread: AgentThread) -> ThreadStatus {
        if let turn = thread.activeTurn {
            if turn.pendingApproval != nil { return .approval }
            if turn.pendingUserInput != nil { return .input }
            return .working(since: turn.startedAt)
        }
        guard let last = thread.turns.last else { return .idle }
        // A yielded turn is done for the user while background work runs.
        let finishedAt = last.endedAt ?? last.startedAt
        let unseen = (thread.lastVisitedAt ?? .distantPast) < finishedAt
        let status = last.isYielded ? last.yieldedStatus : last.status
        switch status {
        case .failed: return unseen ? .failed : .idle
        case .completed: return unseen ? .done : .idle
        case .interrupted, .running: return .idle
        }
    }

    public var label: String? {
        switch self {
        case .approval: "Approval"
        case .input: "Input"
        case .working: "Working"
        case .failed: "Failed"
        case .done: "Done"
        case .idle: nil
        }
    }

    public var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    /// Needs the user (approval or input).
    public var needsAttention: Bool {
        self == .approval || self == .input
    }
}

/// The sidebar sections of the thread inbox, top to bottom. Unpinned, unsettled threads group by
/// what their agent is doing or how its last turn ended; reading a thread never moves it.
public enum InboxSection: String, Sendable, Hashable, CaseIterable {
    case pinned
    case working
    /// Waiting on an approval or answers.
    case blocked
    case failed
    case done
    /// No turn yet, or the last one was interrupted.
    case idle
    case settled

    public var title: String {
        switch self {
        case .pinned: "Pinned"
        case .working: "Working"
        case .blocked: "Blocked"
        case .failed: "Failed"
        case .done: "Done"
        case .idle: "Idle"
        case .settled: "Settled"
        }
    }

    /// Archived threads belong to no section (Settings › Archive lists them).
    public static func of(_ thread: AgentThread) -> InboxSection? {
        if thread.archivedAt != nil { return nil }
        if thread.pinnedAt != nil { return .pinned }
        if thread.settledAt != nil { return .settled }
        if let turn = thread.activeTurn {
            return turn.pendingApproval != nil || turn.pendingUserInput != nil ? .blocked : .working
        }
        guard let last = thread.turns.last else { return .idle }
        // A yielded turn is over for the user while background work runs.
        switch last.isYielded ? last.yieldedStatus : last.status {
        case .failed: return .failed
        case .completed: return .done
        case .interrupted, .running: return .idle
        }
    }
}

public enum DurationText {
    /// Live working duration: `Ns` under a minute, `Nm` under an hour, else `Hh Mm`.
    public static func compact(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    /// Turn duration ("Worked for 1m 12s"): `Nms` under 1 s, `N.Ns` under 10 s, `Ns` under a minute,
    /// else `1h 2m 3s` with zero parts left out.
    public static func turn(_ interval: TimeInterval) -> String {
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

    /// Sidebar relative time: "now", "Nm", "Nh", "Nd".
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}
