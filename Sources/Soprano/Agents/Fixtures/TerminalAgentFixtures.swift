import Foundation

/// Sample agents in Soprano's terminal panes for the snapshot harness and tests: a model
/// `AgentManager` (no terminals, no processes) with a working Codex, a Claude Code that needs
/// input, and a ready omp, in two windows. Their terminals show canned text and accept replies.
@MainActor
enum TerminalAgentFixtures {
    static func source() -> TerminalAgentsSource {
        let manager = AgentManager()
        manager.renameWindow(manager.activeWindowId, to: "app")
        spawn(manager, "codex", cwd: "/Users/demo/code/app", task: "Fix the flaky checkout test", status: .running)

        if let siteWindow = manager.createWindow(cwd: "/Users/demo/code/site") {
            manager.renameWindow(siteWindow, to: "site")
        }
        spawn(manager, "claude-code", cwd: "/Users/demo/code/site", task: "Migrate the blog to Astro 5", status: .waiting, needsAttention: true)
        spawn(manager, "omp", cwd: "/Users/demo/code/site", task: "Audit image sizes", status: .idle)

        return TerminalAgentsSource(
            agentManager: manager,
            // The dashboard holds the model; it lives as long as the source.
            makeDashboard: { theme in
                AgentDashboardViewController(
                    agentManager: manager,
                    themeManager: theme,
                    title: "Terminal Agents",
                    terminalStateProvider: { target in
                        let profile = manager.agentDashboardEntry(for: target)?.profileId ?? ""
                        return TerminalInteractionState(isAvailable: true, visibleText: screens[profile] ?? "")
                    },
                    promptSender: { _, _ in true }
                )
            },
            openInTerminal: { target in
                manager.focusTab(paneId: target.paneId, tabId: target.tabId, revealInSidebar: true)
            }
        )
    }

    /// What each agent's terminal shows.
    private static let screens: [String: String] = [
        "codex": """
        › Fix the flaky checkout test

        • Reading Tests/CheckoutTests/CheckoutFlowTests.swift
        • Running swift test --filter CheckoutFlowTests (3 of 5 passed)
        """,
        "claude-code": """
        > Migrate the blog to Astro 5

        ● The content collections API changed. Rewrite the 42 posts' frontmatter now,
          or keep the legacy loader for this release?

          1. Rewrite the frontmatter
          2. Keep the legacy loader
        """,
        "omp": """
        π Audit image sizes

        Done: 12 images over 500 KB, listed in docs/image-audit.md.
        """,
    ]

    private static func spawn(
        _ manager: AgentManager,
        _ profileID: String,
        cwd: String,
        task: String,
        status: AgentStatus,
        needsAttention: Bool = false
    ) {
        guard let paneID = manager.spawnAgent(profileID, cwd: cwd),
              let tabID = manager.panes[paneID]?.activeTab?.id else { return }
        manager.renameTab(paneID, tabId: tabID, to: task)
        manager.updateAgentStatus(paneId: paneID, tabId: tabID, status: .starting)
        manager.updateAgentStatus(paneId: paneID, tabId: tabID, status: status, needsAttention: needsAttention)
    }
}
