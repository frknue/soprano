import Foundation

/// One time an automation ran, or was due and did not.
struct AutomationRun: Codable, Equatable, Sendable, Identifiable {
    enum Trigger: String, Codable, Sendable {
        case scheduled
        case manual
    }

    enum Status: String, Codable, Sendable {
        /// Its precheck, worktree, or terminal is being prepared.
        case starting
        case running
        /// The agent stopped mid-turn for an approval or an answer.
        case needsInput
        case completed
        case failed
        /// Due, but not started: the precheck said no, it was too late, its
        /// folder was gone, or the previous run was still working.
        case skipped

        var isFinal: Bool {
            switch self {
            case .completed, .failed, .skipped: true
            case .starting, .running, .needsInput: false
            }
        }

        var label: String {
            switch self {
            case .starting: "Starting"
            case .running: "Running"
            case .needsInput: "Needs input"
            case .completed: "Done"
            case .failed: "Failed"
            case .skipped: "Skipped"
            }
        }
    }

    struct Worktree: Codable, Equatable, Sendable {
        var path: String
        var branch: String
        var repository: String
        var baseCommit: String
        /// True once Soprano removed it because the run left nothing in it.
        var removed = false
    }

    let id: String
    let automationId: String
    /// 1 for an automation's first run, counting up.
    let number: Int
    let trigger: Trigger
    /// The schedule time a scheduled run was for.
    var scheduledFor: Date?
    var startedAt: Date
    var finishedAt: Date?
    var status: Status
    /// Why it was skipped or failed, or what the agent waits for.
    var message: String?
    /// The agent's final reply, Markdown.
    var output: String?
    var profileId: String
    /// Where the agent worked.
    var folder: String
    var worktree: Worktree?
    /// The agent's conversation, so a closed run can be resumed.
    var conversation: AgentConversation?
    /// The run's tab while it is open in this Soprano.
    var paneId: String?
    var tabId: String?
    /// Whether someone looked at the run's tab; an unseen run that finished
    /// closes its window.
    var viewed = false
    /// Set when the agent was seen working, so a later wait ends the turn.
    var sawWork = false

    var target: TerminalTarget? {
        guard let paneId, let tabId else { return nil }
        return TerminalTarget(paneId: paneId, tabId: tabId)
    }

    var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }

    /// Longest final reply kept with a run.
    static let outputLimit = 64 * 1024

    static func trimmedOutput(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard text.utf8.count > outputLimit else { return text }
        var cut = text.utf8.prefix(outputLimit)
        while String(cut) == nil { cut = cut.dropLast() }
        return (String(cut) ?? "") + "\n\n…"
    }
}
