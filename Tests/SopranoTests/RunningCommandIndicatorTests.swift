import AppKit
import Testing
@testable import Soprano

@MainActor
struct RunningCommandIndicatorTests {
    @Test func aTerminalCountsAsRunningOnlyOnceItsShellHasShownAPrompt() {
        var activity = TerminalCommandActivity()
        // No shell integration yet, or an agent run as the pane's command.
        let beforeAnyPrompt = activity.isRunningCommand(atPrompt: false)
        let atFirstPrompt = activity.isRunningCommand(atPrompt: true)
        let duringCommand = activity.isRunningCommand(atPrompt: false)
        let atNextPrompt = activity.isRunningCommand(atPrompt: true)
        #expect([beforeAnyPrompt, atFirstPrompt, duringCommand, atNextPrompt] == [false, false, true, false])
    }

    @Test func aRunningCommandLightsItsPaneRowLayoutTabAndHeaderUntilAnAgentOrItsEndTakesOver() throws {
        let manager = AgentManager()
        let serverPaneId = manager.activePaneId
        let serverTabId = try #require(manager.panes[serverPaneId]?.activeTab?.id)
        let server = TerminalTarget(paneId: serverPaneId, tabId: serverTabId)
        var runningTabIds: Set<String> = []
        let splitTree = SplitTreeView(
            agentManager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            terminalViewFactory: { target, _, _ in
                let view = NSView()
                view.identifier = NSUserInterfaceItemIdentifier(target.tabId)
                return view
            },
            terminalIsRunningCommand: { view in
                runningTabIds.contains(view.identifier?.rawValue ?? "")
            }
        )
        _ = try #require(manager.createLayoutTab())
        let otherPaneId = manager.activePaneId
        let otherTabId = try #require(manager.panes[otherPaneId]?.activeTab?.id)
        let sidebar = makeSidebar(manager: manager)
        let tabBar = LayoutTabBarView(
            agentManager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark")
        )
        tabBar.frame = NSRect(x: 0, y: 0, width: 800, height: LayoutTabBarView.height)
        let serverLayoutTab = try #require(layoutTabs(in: tabBar).first)

        runningTabIds = [serverTabId]
        splitTree.sampleRunningCommands()
        #expect(manager.runningCommandTargets == [server])
        #expect(paneBadgeTexts(in: sidebar) == ["RUNNING · TAB 1", "TAB 2"])
        #expect(commandBadge(in: serverLayoutTab) != nil)
        #expect(serverLayoutTab.toolTip?.hasSuffix("1 command running") == true)
        #expect(headerTexts(paneId: serverPaneId, manager: manager).contains("RUNNING"))
        #expect(!headerTexts(paneId: otherPaneId, manager: manager).contains("RUNNING"))

        manager.attachAgentIfNeeded(paneId: serverPaneId, tabId: serverTabId, profileId: "codex")
        #expect(paneBadgeTexts(in: sidebar) == ["STARTING · TAB 1", "TAB 2"])
        #expect(commandBadge(in: serverLayoutTab) == nil)

        manager.agentProcessDidExit(target: server)
        #expect(paneBadgeTexts(in: sidebar) == ["RUNNING · TAB 1", "TAB 2"])

        runningTabIds = []
        splitTree.sampleRunningCommands()
        #expect(paneBadgeTexts(in: sidebar) == ["TAB 1", "TAB 2"])
        #expect(commandBadge(in: serverLayoutTab) == nil)

        runningTabIds = [otherTabId]
        splitTree.sampleRunningCommands()
        manager.removeTabFromPane(otherPaneId, tabId: otherTabId)
        splitTree.sampleRunningCommands()
        #expect(manager.runningCommandTargets.isEmpty)
    }

    @Test func onlyThePaneTabRunningACommandCarriesItsLampInTheTabStrip() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let idleTabId = try #require(manager.panes[paneId]?.activeTab?.id)
        let serverTabId = try #require(manager.addTabToPane(paneId, type: .terminal))
        manager.setRunningCommandTargets([TerminalTarget(paneId: paneId, tabId: serverTabId)])
        let header = PaneHeaderView(
            paneId: paneId,
            agentManager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark")
        )

        let titles = descendants(of: header, as: NSButton.self)
            .filter { $0.identifier?.rawValue != "pane-close-button" }
            .map(\.attributedTitle.string)
        let idleTitle = try #require(manager.panes[paneId]?.tabs.first { $0.id == idleTabId }?.title)
        let serverTitle = try #require(manager.panes[paneId]?.tabs.first { $0.id == serverTabId }?.title)
        #expect(titles == [idleTitle, "● \(serverTitle)"])
        // The server tab is active, so the header's own lamp reports it too.
        #expect(headerTexts(paneId: paneId, manager: manager).contains("RUNNING"))
    }

    private func makeSidebar(manager: AgentManager) -> SidebarView {
        let sidebar = SidebarView(
            agentManager: manager,
            sessionManager: SessionManager(agentManager: manager),
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            gitBranchMonitor: GitBranchMonitor()
        )
        sidebar.frame = NSRect(x: 0, y: 0, width: SidebarWidthStore.left.defaultWidth, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    private func paneBadgeTexts(in sidebar: NSView) -> [String] {
        descendants(of: sidebar, as: NSTextField.self)
            .filter { $0.identifier?.rawValue == "pane-layout-tab-badge" }
            .map(\.stringValue)
    }

    private func layoutTabs(in view: NSView) -> [NSButton] {
        descendants(of: view, as: NSButton.self).filter {
            $0.identifier?.rawValue.hasPrefix("layout-tab-layout-") == true
        }
    }

    private func commandBadge(in view: NSView) -> NSView? {
        descendants(of: view, as: NSView.self).first {
            $0.identifier?.rawValue == "layout-tab-command-badge" && !$0.isHidden
        }
    }

    private func headerTexts(paneId: String, manager: AgentManager) -> [String] {
        let header = PaneHeaderView(
            paneId: paneId,
            agentManager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark")
        )
        return descendants(of: header, as: NSTextField.self)
            .filter { !$0.isHidden }
            .map(\.stringValue)
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            let current = (subview as? T).map { [$0] } ?? []
            return current + descendants(of: subview, as: type)
        }
    }
}
