import Foundation

/// A saved workspace session for save/restore.
struct WorkspaceSession: Identifiable, Codable {
    let id: String
    var name: String
    var savedAt: Date
    var layout: SplitNode?
    var panes: [SavedPane]
    var activePaneId: String
    var windows: [SavedWindow]? = nil
    var activeWindowId: String? = nil

    struct SavedWindow: Codable {
        let id: String
        var title: String
        var isTitleCustom: Bool? = nil
        var layout: SplitNode?
        var activePaneId: String
        /// Optional for backward compatibility with sessions saved before
        /// depth became a tree of pane-owned workspaces.
        var depthLayers: [SavedDepthLayer]? = nil
        /// Layer array index. `activeDepth` remains as a decoder fallback for
        /// sessions written by the earlier linear-stack implementation.
        var activeDepthLayerIndex: Int? = nil
        var activeDepth: Int? = nil
    }

    struct SavedDepthLayer: Codable {
        var parentPaneId: String? = nil
        var layout: SplitNode?
        var activePaneId: String
    }

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
        var url: String? = nil
        var title: String? = nil
        /// Retained only to decode sessions from the earlier pane-local depth
        /// implementation. Restored entries are migrated to regular tabs.
        var depthParentId: String? = nil
    }

    // MARK: - Session List Persistence

    private static let sessionsKey = "soprano-sessions"
    private static let lastSessionKey = "soprano-last-session"

    static func loadAll(defaults: UserDefaults = .standard) -> [WorkspaceSession] {
        guard let data = defaults.data(forKey: sessionsKey),
              let sessions = try? JSONDecoder().decode([WorkspaceSession].self, from: data)
        else {
            return []
        }
        return sessions
    }

    static func saveAll(_ sessions: [WorkspaceSession], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        defaults.set(data, forKey: sessionsKey)
    }

    // MARK: - Last Session Persistence

    static func loadLast(defaults: UserDefaults = .standard) -> WorkspaceSession? {
        guard let data = defaults.data(forKey: lastSessionKey),
              let session = try? JSONDecoder().decode(WorkspaceSession.self, from: data)
        else {
            return nil
        }
        return session
    }

    static func saveLast(_ session: WorkspaceSession, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: lastSessionKey)
    }

    static func clearLast(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: lastSessionKey)
    }
}
