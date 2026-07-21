import Foundation

/// Runtime state of a running agent process.
final class AgentInstance: Identifiable {
    let id: String
    let profileId: String
    var status: AgentStatus
    var startedAt: Date?
    var exitCode: Int32?
    var restartCount: Int
    var needsAttention: Bool

    init(id: String, profileId: String) {
        self.id = id
        self.profileId = profileId
        self.status = .starting
        self.startedAt = Date()
        self.exitCode = nil
        self.restartCount = 0
        self.needsAttention = false
    }
}

enum AgentStatus: String, Codable {
    case idle
    case starting
    case running
    case waiting
    case error
    case stopped
}
