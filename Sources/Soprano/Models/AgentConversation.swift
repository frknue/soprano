import Foundation

/// The agent's own conversation identity, independent of Soprano's pane and session IDs.
struct AgentConversation: Codable, Equatable {
    let id: String
    var cwd: String? = nil

    static func supports(profileId: String) -> Bool {
        ["codex", "claude-code", "opencode"].contains(profileId)
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func fromPayload(_ payload: String) -> AgentConversation? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Codex notify uses thread-id; lifecycle hooks use session_id;
        // OpenCode's plugin forwards sessionID. Never use a generic event id.
        guard let id = ["session_id", "thread-id", "thread_id", "sessionID"]
            .compactMap({ object[$0] as? String }).first(where: validID)
        else { return nil }
        let cwd = (object["cwd"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
        return AgentConversation(id: id, cwd: cwd)
    }

    /// Replace launch-time conversation selectors so --continue/--last cannot
    /// send two panes in the same directory to the same conversation.
    func resumeArguments(profileId: String, arguments: [String]) -> [String] {
        let valuedSelectors: Set<String>
        let switches: Set<String>
        switch profileId {
        case "codex":
            valuedSelectors = ["resume", "fork"]
            switches = ["--last", "--all", "--include-non-interactive"]
        case "claude-code":
            valuedSelectors = ["--resume", "-r", "--session-id"]
            switches = ["--continue", "-c", "--fork-session"]
        case "opencode":
            valuedSelectors = ["--session", "-s"]
            switches = ["--continue", "-c", "--fork"]
        default:
            return arguments
        }

        var remaining: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if valuedSelectors.contains(argument) {
                index += 1
                if index < arguments.count, !arguments[index].hasPrefix("-") { index += 1 }
            } else if switches.contains(argument)
                || valuedSelectors.contains(where: { argument.hasPrefix("\($0)=") }) {
                index += 1
            } else {
                remaining.append(argument)
                index += 1
            }
        }
        switch profileId {
        case "codex": return ["resume", id] + remaining
        case "claude-code": return ["--resume", id] + remaining
        case "opencode": return ["--session", id] + remaining
        default: return remaining
        }
    }
}
