import Foundation

/// Manages named workspace sessions — save, load, delete.
final class SessionManager: @unchecked Sendable {
    private(set) var sessions: [WorkspaceSession] = []
    private let agentManager: AgentManager
    private let defaults: UserDefaults
    private var observers: [String: () -> Void] = [:]

    init(agentManager: AgentManager, defaults: UserDefaults = .standard) {
        self.agentManager = agentManager
        self.defaults = defaults
        sessions = WorkspaceSession.loadAll(defaults: defaults)
    }

    // MARK: - Session Operations

    func saveSession(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let session = agentManager.snapshotWorkspace()
        let namedSession = WorkspaceSession(
            id: "session-\(Int(Date().timeIntervalSince1970 * 1000))",
            name: trimmed,
            savedAt: Date(),
            layout: session.layout,
            panes: session.panes,
            activePaneId: session.activePaneId,
            windows: session.windows,
            activeWindowId: session.activeWindowId
        )

        sessions.insert(namedSession, at: 0)
        persistSessions()
        notifyChange()
    }

    func loadSession(_ sessionId: String) {
        guard let session = sessions.first(where: { $0.id == sessionId }),
              !session.panes.isEmpty
        else { return }

        agentManager.restoreWorkspace(session)
    }

    func deleteSession(_ sessionId: String) {
        sessions.removeAll { $0.id == sessionId }
        persistSessions()
        notifyChange()
    }

    // MARK: - Observer Pattern

    func addObserver(id: String, handler: @escaping () -> Void) {
        observers[id] = handler
    }

    func removeObserver(id: String) {
        observers.removeValue(forKey: id)
    }

    // MARK: - Private

    private func notifyChange() {
        for (_, handler) in observers {
            handler()
        }
    }

    private func persistSessions() {
        WorkspaceSession.saveAll(sessions, defaults: defaults)
    }
}
