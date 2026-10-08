import Foundation

extension AgentManager {
    /// Builds the dashboard in stable visual workspace order before its entries
    /// are urgency-sorted by AgentDashboardSnapshot.
    func agentDashboardSnapshot() -> AgentDashboardSnapshot {
        let entries = orderedWindows.flatMap { terminalWindow in
            orderedPanes(in: terminalWindow.id).flatMap { pane in
                pane.tabs.compactMap { tab in
                    dashboardEntry(for: tab, in: pane, window: terminalWindow)
                }
            }
        }
        return AgentDashboardSnapshot(entries: entries)
    }

    /// The dashboard entry for one tab, or nil when the tab holds no agent.
    /// A title or directory change touches only its own tab, so the dashboard
    /// follows those without rebuilding the whole snapshot.
    func agentDashboardEntry(for target: TerminalTarget) -> AgentDashboardEntry? {
        guard let pane = panes[target.paneId],
              let tab = pane.tabs.first(where: { $0.id == target.tabId }),
              let terminalWindow = window(containingPane: target.paneId)
        else { return nil }
        return dashboardEntry(for: tab, in: pane, window: terminalWindow)
    }

    private func dashboardEntry(
        for tab: PaneTab,
        in pane: PaneState,
        window terminalWindow: WorkspaceWindowState
    ) -> AgentDashboardEntry? {
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
            cwd: cwd,
            sessionName: terminalSessions[terminalWindow.sessionId]?.name,
            isWindowTitleCustom: terminalWindow.isTitleCustom,
            profileIcon: profile?.icon ?? AgentDashboardEntry.fallbackProfileIcon
        )
    }
}
