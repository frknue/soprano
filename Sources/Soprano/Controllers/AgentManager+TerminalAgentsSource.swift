import AppKit

extension TerminalAgentsSource {
    /// The agents of `agentManager`'s panes, in the dashboard's urgency order, following its
    /// changes.
    convenience init(
        agentManager: AgentManager,
        makeDashboard: @escaping (ThemeManager) -> AgentDashboardViewController,
        openInTerminal: @escaping (TerminalTarget) -> Void
    ) {
        self.init(
            entries: { [weak agentManager] in agentManager?.agentDashboardSnapshot().entries ?? [] },
            makeDashboard: makeDashboard,
            openInTerminal: openInTerminal
        )
        agentManager.addObserver(id: "TerminalAgentsSource-\(ObjectIdentifier(self).hashValue)") { [weak self] change in
            switch change {
            case .model, .tabTitle, .tabWorkingDirectory:
                self?.notifyChange()
            case .browserURL, .document:
                break
            }
        }
    }
}
