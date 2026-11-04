import AppKit
import Testing
@testable import Soprano

@MainActor
struct TerminalAgentsBoardTests {
    private func window(source: TerminalAgentsSource? = TerminalAgentFixtures.source()) throws -> (AgentsWindowController, WorkspaceState) {
        let built = try DemoFixtures.build("demo")
        let state = WorkspaceState()
        state.select(built.selection)
        let controller = AgentsWindowController(
            engine: built.engine,
            state: state,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            persistsFrame: false,
            terminalAgents: source
        )
        _ = controller.window
        return (controller, state)
    }

    @Test func theTerminalAgentsBoardAndTheStatisticsBoardNeverShowTogether() {
        let state = WorkspaceState()
        state.setStatisticsVisible(true)

        state.setTerminalAgentsVisible(true)
        #expect(state.isTerminalAgentsVisible && !state.isStatisticsVisible)

        state.setStatisticsVisible(true)
        #expect(state.isStatisticsVisible && !state.isTerminalAgentsVisible)

        state.showTerminalAgents(selecting: "pane-2:tab-3")
        #expect(state.isTerminalAgentsVisible && !state.isStatisticsVisible)
    }

    @Test func choosingAThreadOrDraftClosesTheBoardButTheAppsOwnSelectionsDoNot() {
        let state = WorkspaceState()
        state.select(.thread("a"))

        state.setTerminalAgentsVisible(true)
        state.select(.thread("a"))
        #expect(!state.isTerminalAgentsVisible)

        state.setTerminalAgentsVisible(true)
        state.select(.draft(projectID: nil))
        #expect(!state.isTerminalAgentsVisible)

        state.setTerminalAgentsVisible(true)
        state.select(.thread("b"), closingOverlays: false)
        #expect(state.isTerminalAgentsVisible)
    }

    @Test func openingAChatSurfaceClosesTheBoardAndItsToggleShowsTheSurface() {
        let state = WorkspaceState()
        state.select(.thread("a"))
        state.setTerminalAgentsVisible(true)
        #expect(state.toggledVisibility(true))

        state.setTerminalVisible(true)
        #expect(!state.isTerminalAgentsVisible)

        state.setTerminalAgentsVisible(true)
        state.showDiff(.thread)
        #expect(!state.isTerminalAgentsVisible)
        #expect(state.isRightPanelVisible)
    }

    @Test func clickingATerminalsRowOpensTheBoardOnThatAgent() throws {
        let built = try DemoFixtures.build("demo")
        let source = try #require(built.terminalAgents)
        let state = WorkspaceState()
        state.select(built.selection)
        let sidebar = SidebarViewController(engine: built.engine, state: state, terminalAgents: source)
        _ = sidebar.view
        let codex = try #require(source.entries.first { $0.profileId == "codex" })
        let row = try #require(sidebar.items.first { $0 == .terminalAgent(SidebarTerminalRow(entry: codex)) })
        guard case let .terminalAgent(model) = row else { return }

        sidebar.openTerminalAgent(model.entryID)

        #expect(state.isTerminalAgentsVisible)
        #expect(state.pendingTerminalAgentSelection == codex.id)
    }

    @Test func theBoardEmbedsTheDashboardWhileOpenAndTakesItsSelection() throws {
        let (controller, state) = try window()
        let board = controller.workspace.terminalAgents
        let codex = try #require(board.source?.entries.first { $0.profileId == "codex" })

        state.showTerminalAgents(selecting: codex.id)

        let dashboard = try #require(board.dashboard)
        #expect(dashboard.view.isDescendant(of: board.view))
        #expect(state.pendingTerminalAgentSelection == nil)
        #expect(controller.workspace.chat.view.isHidden)
        #expect(board.hasFocus)

        dashboard.onDismiss?()

        #expect(!state.isTerminalAgentsVisible)
        #expect(board.dashboard == nil)
        let responder = try #require(controller.window?.firstResponder as? NSView)
        #expect(responder.isDescendant(of: controller.workspace.chat.composer.view))
    }

    @Test func theTerminalsSectionFollowsThePaneAgents() async throws {
        let built = try DemoFixtures.build("demo")
        let manager = AgentManager()
        let source = TerminalAgentsSource(
            agentManager: manager,
            makeDashboard: { AgentDashboardViewController(agentManager: manager, themeManager: $0) },
            openInTerminal: { _ in }
        )
        let state = WorkspaceState()
        state.select(built.selection)
        let sidebar = SidebarViewController(engine: built.engine, state: state, terminalAgents: source)
        _ = sidebar.view
        #expect(!sidebar.items.contains(.terminalsShelf(count: 1, expanded: true)))

        // Changes reach the sidebar on the next turn of the main queue, a burst once.
        let pane = try #require(manager.spawnAgent("codex", cwd: "/tmp/app"))
        #expect(await EngineHarness.eventually { sidebar.items.first == .terminalsShelf(count: 1, expanded: true) })

        let tab = try #require(manager.panes[pane]?.activeTab?.id)
        manager.updateAgentStatus(paneId: pane, tabId: tab, status: .waiting)
        #expect(await EngineHarness.eventually {
            guard sidebar.items.count > 1, case let .terminalAgent(row) = sidebar.items[1] else { return false }
            return row.status == .needsInput
        })
    }

    @Test func theToggleCommandNeedsTerminalAgents() throws {
        let command = try #require(SidebarCommands.all.first { $0.id == "terminals.toggle" })
        let (without, _) = try window(source: nil)
        #expect(!command.isEnabled(without.commandContext()))

        let (controller, state) = try window()
        #expect(command.isEnabled(controller.commandContext()))
        command.perform(controller.commandContext())
        #expect(state.isTerminalAgentsVisible)
        command.perform(controller.commandContext())
        #expect(!state.isTerminalAgentsVisible)
    }

    @Test func closingTheWindowClosesTheBoardSoItsDashboardStopsWorking() throws {
        let (controller, state) = try window()
        state.setTerminalAgentsVisible(true)

        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window))

        #expect(!state.isTerminalAgentsVisible)
    }

    @Test func retitledPlainTerminalsAreIgnoredAndAnAgentsBurstOfTitlesArrivesOnce() async throws {
        let manager = AgentManager()
        let agentPane = try #require(manager.spawnAgent("codex", cwd: "/tmp/projects/storefront"))
        let agentTab = try #require(manager.panes[agentPane]?.activeTab?.id)
        let shellPane = try #require(manager.spawnTerminal(cwd: "/tmp/projects/storefront"))
        let shellTab = try #require(manager.panes[shellPane]?.activeTab?.id)
        let source = TerminalAgentsSource(agentManager: manager, makeDashboard: { _ in
            AgentDashboardViewController(agentManager: manager, themeManager: ThemeManager(themeId: AppTheme.folioId))
        }, openInTerminal: { _ in })
        let owner = NSObject()
        var changes = 0
        source.addObserver(owner) { changes += 1 }

        for title in ["⠋ npm test", "⠙ npm test", "⠹ npm test"] {
            manager.renameTab(shellPane, tabId: shellTab, to: title)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(changes == 0)

        for title in ["⠋ Fix the checkout", "⠙ Fix the checkout", "⠹ Fix the checkout"] {
            manager.renameTab(agentPane, tabId: agentTab, to: title)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(changes == 1)
    }
}
