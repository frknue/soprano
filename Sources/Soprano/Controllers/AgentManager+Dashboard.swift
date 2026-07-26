import Foundation

extension AgentManager {
    /// Builds the dashboard in stable visual workspace order before its entries
    /// are urgency-sorted by AgentDashboardSnapshot.
    func agentDashboardSnapshot() -> AgentDashboardSnapshot {
        let entries = orderedWindows.flatMap { terminalWindow in
            orderedPanes(in: terminalWindow.id).flatMap { pane in
                pane.tabs.compactMap { tab -> AgentDashboardEntry? in
                    guard let agent = tab.agent else { return nil }
                    let profile = AgentCatalog.profile(for: agent.profileId)
                    let cwd = tab.cwd
                        ?? profile?.cwd
                        ?? FileManager.default.currentDirectoryPath
                    return AgentDashboardEntry(
                        paneId: pane.id,
                        tabId: tab.id,
                        tabTitle: tab.title,
                        windowTitle: terminalWindow.title,
                        profileId: agent.profileId,
                        profileName: profile?.name ?? tab.title,
                        status: agent.status,
                        needsAttention: agent.needsAttention,
                        startedAt: agent.startedAt,
                        cwd: cwd
                    )
                }
            }
        }
        return AgentDashboardSnapshot(entries: entries)
    }
}
