import Foundation

/// Runtime state of a running agent process.
final class AgentInstance: Identifiable {
    let id: String
    let profileId: String
    var status: AgentStatus
    var startedAt: Date?
    var exitCode: Int32?
    var processId: Int32?
    var restartCount: Int
    var needsAttention: Bool
    var conversation: AgentConversation?
    /// What its CLI was started with for an automation run: the first
    /// prompt, model, and autonomy. Never persisted — a restored agent resumes
    /// its conversation and must not get its prompt a second time.
    var launch: AgentLaunch?
    /// The automation run this agent works for; nil for agents started by hand.
    var automationRunId: String?
    /// Why a `.waiting` agent waits; nil in every other status.
    var waitingReason: AgentWaitingReason?
    /// The last thing the agent said in an event, in full (capped): the
    /// reply an automation run keeps when the CLI writes no transcript.
    var lastMessage: String?

    init(id: String, profileId: String, launch: AgentLaunch? = nil, automationRunId: String? = nil) {
        self.id = id
        self.profileId = profileId
        self.status = .starting
        self.startedAt = Date()
        self.exitCode = nil
        self.restartCount = 0
        self.needsAttention = false
        self.launch = launch
        self.automationRunId = automationRunId
    }
}

/// What Soprano adds to an agent CLI's command line when it starts the agent
/// for someone who isn't there.
struct AgentLaunch: Equatable, Sendable {
    var prompt: String
    var model: String?
    /// Skip the CLI's approval prompts: nobody is there to answer them.
    var skipsApprovals: Bool
}

/// What an agent waiting on a person waits for. Soprano shows all three as
/// NEEDS INPUT; an automation run tells a finished turn, which completes the
/// run, from a prompt that blocks the agent until someone answers.
enum AgentWaitingReason: String, Codable, Sendable {
    /// The turn is done and the reply is in.
    case turnEnded = "turn"
    /// A tool call waits for approval.
    case approval
    /// The agent asked something mid-turn and waits for the answer.
    case question

    /// Whether the agent can't go on until someone answers.
    var blocks: Bool { self != .turnEnded }
}

enum AgentStatus: String, Codable {
    case idle
    case starting
    case running
    case waiting
    case error
    case stopped

    var displayLabel: String {
        switch self {
        case .idle: return "READY"
        case .starting: return "STARTING"
        case .running: return "WORKING"
        case .waiting: return "NEEDS INPUT"
        case .error: return "ERROR"
        case .stopped: return "STOPPED"
        }
    }
}
