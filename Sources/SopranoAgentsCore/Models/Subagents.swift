import Foundation

public enum SubagentStatus: String, Codable, Sendable, Hashable {
    case running
    case completed
    case failed
    /// Cancelled, or its process went away while it ran.
    case aborted
}

/// A helper agent the thread's agent started (omp's `task` tool). It works in the thread's
/// workspace beside the thread's own turns; its runs are recorded like a thread's turns: the
/// message that woke it (its assignment, a steer, a message from the parent agent) and what it
/// did. Persisted with its thread.
public struct Subagent: Codable, Sendable, Hashable, Identifiable {
    /// Unique within the thread: the provider's id ("Reader"), or "Reader#2" when the provider
    /// handed that id out again in another session (after a rewind).
    public var id: String
    /// The provider's id when it differs from `id`; see `name`.
    public var providerID: String?
    /// The agent definition it runs ("sonic", "scout").
    public var agent: String
    public var description: String?
    /// What it was asked to do.
    public var assignment: String?
    public var status: SubagentStatus
    /// Model it runs (`provider/id`), once reported.
    public var model: String?
    /// What it is doing now (its latest tool intent).
    public var lastIntent: String?
    /// The provider's transcript file of the subagent.
    public var sessionFile: String?
    /// The parent's tool call that started it.
    public var parentToolCallID: String?
    /// Runs as a background job of the parent instead of blocking its tool call.
    public var isDetached: Bool
    public var startedAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    /// One per run, oldest first; the last one is open (`.running`) while it runs.
    public var turns: [Turn]

    public init(
        id: String,
        providerID: String? = nil,
        agent: String,
        description: String? = nil,
        assignment: String? = nil,
        status: SubagentStatus = .running,
        model: String? = nil,
        lastIntent: String? = nil,
        sessionFile: String? = nil,
        parentToolCallID: String? = nil,
        isDetached: Bool = false,
        startedAt: Date = Date(),
        updatedAt: Date? = nil,
        completedAt: Date? = nil,
        turns: [Turn] = []
    ) {
        self.id = id
        self.providerID = providerID
        self.agent = agent
        self.description = description
        self.assignment = assignment
        self.status = status
        self.model = model
        self.lastIntent = lastIntent
        self.sessionFile = sessionFile
        self.parentToolCallID = parentToolCallID
        self.isDetached = isDetached
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
        self.completedAt = completedAt
        self.turns = turns
    }

    /// The provider's id: what it is called, and what messages and Stop address.
    public var name: String { providerID ?? id }

    /// `info` reports a different subagent under the same name: another transcript or another
    /// starting tool call than the ones known.
    public func isOther(than info: SubagentInfo) -> Bool {
        func differs(_ known: String?, _ reported: String?) -> Bool {
            guard let known, let reported else { return false }
            return known != reported
        }
        return differs(sessionFile, info.sessionFile) || differs(parentToolCallID, info.parentToolCallID)
    }

    public var isRunning: Bool { status == .running }

    /// The run in progress.
    public var openTurn: Turn? {
        guard let last = turns.last, last.status == .running else { return nil }
        return last
    }
}
