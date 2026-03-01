import Foundation

/// A saved workspace session for save/restore.
struct WorkspaceSession: Identifiable, Codable {
    let id: String
    var name: String
    var savedAt: Date
    var layout: SplitNode?
    var panes: [SavedPane]
    var activePaneId: String
    var runningMcpServers: [String]?

    struct SavedPane: Codable {
        let id: String
        var activeTabIndex: Int
        var tabs: [SavedTab]
    }

    struct SavedTab: Codable {
        let id: String
        let type: PaneType
        var profileId: String?
        var cwd: String?
    }

    // MARK: - Session List Persistence

    private static let sessionsKey = "soprano-sessions"
    private static let lastSessionKey = "soprano-last-session"

    static func loadAll() -> [WorkspaceSession] {
        guard let data = UserDefaults.standard.data(forKey: sessionsKey),
              let sessions = try? JSONDecoder().decode([WorkspaceSession].self, from: data)
        else {
            return []
        }
        return sessions
    }

    static func saveAll(_ sessions: [WorkspaceSession]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        UserDefaults.standard.set(data, forKey: sessionsKey)
    }

    // MARK: - Last Session Persistence

    static func loadLast() -> WorkspaceSession? {
        guard let data = UserDefaults.standard.data(forKey: lastSessionKey),
              let session = try? JSONDecoder().decode(WorkspaceSession.self, from: data)
        else {
            return nil
        }
        return session
    }

    static func saveLast(_ session: WorkspaceSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: lastSessionKey)
    }

    static func clearLast() {
        UserDefaults.standard.removeObject(forKey: lastSessionKey)
    }
}
