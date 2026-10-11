import Foundation

/// A workspace snapshot containing every live session for save/restore.
struct WorkspaceSession: Identifiable, Codable {
    let id: String
    var name: String
    var savedAt: Date
    var layout: SplitNode?
    var panes: [SavedPane]
    var activePaneId: String
    var windows: [SavedWindow]? = nil
    var activeWindowId: String? = nil
    /// Missing in older snapshots, whose windows belong to one default session.
    var terminalSessions: [TerminalSessionState]? = nil

    struct SavedWindow: Codable {
        let id: String
        var sessionId: String? = nil
        var title: String
        var isTitleCustom: Bool? = nil
        /// Optional for backward compatibility with sessions saved before
        /// sidebar disclosure state was persisted.
        var isSidebarCollapsed: Bool? = nil
        /// The active tab's layout and focused pane. Builds without tabs
        /// restore them as the window's only layout.
        var layout: SplitNode?
        var activePaneId: String
        /// Missing in workspaces saved before windows had tabs.
        var tabs: [SavedLayoutTab]? = nil
        var activeTabIndex: Int? = nil
        /// Window depth from builds before tabs: one complete layout per
        /// layer, which reopen as tabs in the same order. Read, never written.
        var depthLayers: [SavedLayoutTab]? = nil
        var activeDepthLayerIndex: Int? = nil
        /// The active layer of the first depth builds, which stacked layers.
        var activeDepth: Int? = nil

        /// The tabs this window reopens with, from whichever format wrote it:
        /// tabs, else depth layers, else the single layout of the oldest
        /// workspaces.
        var restorableTabs: [SavedLayoutTab] {
            tabs ?? depthLayers ?? [SavedLayoutTab(layout: layout, activePaneId: activePaneId)]
        }

        var restorableActiveTabIndex: Int {
            activeTabIndex ?? activeDepthLayerIndex ?? activeDepth ?? 0
        }
    }

    struct SavedLayoutTab: Codable {
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
        /// Optional so pre-reader sessions keep decoding, and older builds
        /// ignore this specialization while retaining the browser pane.
        var contentKind: String? = nil
        var previewOwnerPaneId: String? = nil
        /// Missing in older workspaces, which continue to start fresh agents.
        var conversation: AgentConversation? = nil
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
