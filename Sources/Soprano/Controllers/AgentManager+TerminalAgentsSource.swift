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
        agentManager.addObserver(id: "TerminalAgentsSource-\(ObjectIdentifier(self).hashValue)") { [weak self, weak agentManager] change in
            switch change {
            case .model:
                self?.notifyChange()
            case let .tabTitle(target), let .tabWorkingDirectory(target):
                // Shells, browsers and editors retitle constantly; only agent tabs are listed.
                guard agentManager?.panes[target.paneId]?.tabs.first(where: { $0.id == target.tabId })?.agent != nil
                else { return }
                self?.notifyChange()
            case .browserURL, .document:
                break
            }
        }
    }
}
