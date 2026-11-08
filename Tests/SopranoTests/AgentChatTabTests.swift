import AppKit
import Testing
@testable import Soprano

@MainActor
struct AgentChatTabTests {
    @Test func aChatOpensInAPaneATabOfAPaneALayoutTabAndAWindow() throws {
        let manager = AgentManager()
        let rootPaneId = manager.activePaneId

        let paneId = try #require(manager.spawnAgent("omp", cwd: "/work/repo", chat: true))
        #expect(manager.panes[paneId]?.activeTab?.isChat == true)
        #expect(manager.panes[paneId]?.activeTab?.title == "omp: repo")

        let tabId = try #require(manager.addTabToPane(rootPaneId, type: .agent, profileId: "omp", contentKind: PaneContentKind.chat))
        #expect(manager.panes[rootPaneId]?.tabs.first { $0.id == tabId }?.isChat == true)

        _ = try #require(manager.createLayoutTab(chatProfileId: "omp"))
        #expect(manager.panes[manager.activePaneId]?.activeTab?.isChat == true)

        _ = try #require(manager.createWindow(chatProfileId: "omp"))
        #expect(manager.panes[manager.activePaneId]?.activeTab?.isChat == true)

        let splitId = try #require(manager.splitPane(direction: .horizontal, paneId: manager.activePaneId))
        let split = try #require(manager.panes[splitId]?.activeTab)
        #expect(split.isChat)
        #expect(split.agent?.profileId == "omp")
    }

    @Test func anAgentWithoutAChatOpensItsTerminalInstead() throws {
        let manager = AgentManager()
        let paneId = try #require(manager.spawnAgent("codex", chat: true))
        let tab = try #require(manager.panes[paneId]?.activeTab)
        #expect(tab.type == .agent)
        #expect(!tab.isChat)
    }

    @Test func aRestoredChatReopensAsAChatOnItsConversation() throws {
        let source = AgentManager()
        let paneId = try #require(source.spawnAgent("omp", cwd: "/work/repo", chat: true))
        let tabId = try #require(source.panes[paneId]?.activeTab?.id)
        source.recordAgentConversation(.init(id: "01a1b56e-610b-72eb", cwd: "/work/repo"), paneId: paneId, tabId: tabId)

        let data = try JSONEncoder().encode(source.snapshotWorkspace())
        let restored = AgentManager()
        restored.restoreWorkspace(try JSONDecoder().decode(WorkspaceSession.self, from: data))
        let tab = try #require(restored.panes[paneId]?.tabs.first { $0.id == tabId })
        #expect(tab.isChat)
        #expect(tab.agent?.conversation?.id == "01a1b56e-610b-72eb")
    }

    @Test func theChatReportsStatusConversationAndTitleToItsTab() async throws {
        let manager = AgentManager()
        let rootPaneId = manager.activePaneId
        let tabId = try #require(manager.addTabToPane(rootPaneId, type: .agent, profileId: "omp", contentKind: PaneContentKind.chat))
        var events: [AgentEventPayload] = []
        manager.agentEventHandler = { event in
            events.append(event)
            manager.updateAgentStatus(paneId: event.paneId, tabId: event.tabId, status: event.state.agentStatus)
        }
        let agent = FakeACPAgent()
        var launches: [AgentChatLaunch] = []
        let tree = SplitTreeView(
            agentManager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            terminalViewFactory: { _, _, _ in NSView() },
            destroyTerminalView: { _ in },
            restartTerminalView: { _, _ in true },
            terminalViewHasLiveSurface: { _ in false },
            scheduleCodexReadiness: { _ in },
            makeChatSession: { launch in
                launches.append(launch)
                return AgentChatSession(launch: launch, makePeer: { _ in agent })
            }
        )
        let target = TerminalTarget(paneId: rootPaneId, tabId: tabId)
        for _ in 0..<200 where manager.agent(paneId: rootPaneId, tabId: tabId)?.status != .idle {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(launches.count == 1)
        #expect(manager.agent(paneId: rootPaneId, tabId: tabId)?.status == .idle)
        #expect(manager.agent(paneId: rootPaneId, tabId: tabId)?.conversation?.id == "new-session")
        #expect(tree.terminalInteractionState(for: target).isAvailable)

        // The dashboard's reply goes to the chat's session.
        #expect(tree.submitAgentPrompt("Hello", to: target))
        for _ in 0..<200 where agent.waitingPrompts == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(manager.agent(paneId: rootPaneId, tabId: tabId)?.status == .running)

        agent.send(["sessionUpdate": "session_info_update", "title": "Greet the user"])
        #expect(manager.panes[rootPaneId]?.tabs.first { $0.id == tabId }?.title == "Greet the user")

        // Stopping a chat leaves it a chat, stopped, rather than a terminal.
        manager.stopAgent(target: target)
        #expect(manager.panes[rootPaneId]?.tabs.first { $0.id == tabId }?.isChat == true)
        #expect(manager.agent(paneId: rootPaneId, tabId: tabId)?.status == .stopped)
        #expect(!tree.terminalInteractionState(for: target).isAvailable)
        #expect(events.map(\.state).contains(.running))
    }

    @Test func selectingTranscriptTextActivatesTheChatSoPaneCommandsActOnIt() async throws {
        let manager = AgentManager()
        let terminalPaneId = manager.activePaneId
        let chatPaneId = try #require(manager.spawnAgent("omp", cwd: "/work/repo", chat: true))
        let agent = FakeACPAgent()
        let tree = SplitTreeView(
            agentManager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            terminalViewFactory: { _, _, _ in NSView() },
            destroyTerminalView: { _ in },
            restartTerminalView: { _, _ in true },
            terminalViewHasLiveSurface: { _ in false },
            scheduleCodexReadiness: { _ in },
            makeChatSession: { AgentChatSession(launch: $0, makePeer: { _ in agent }) }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = tree
        defer { window.orderOut(nil) }
        let chat = try #require(Self.descendants(of: tree).compactMap { $0 as? AgentChatPaneView }.first)
        for _ in 0..<200 where chat.session.phase != .ready { try await Task.sleep(for: .milliseconds(2)) }
        chat.session.send("Explain the fix")
        for _ in 0..<200 where agent.waitingPrompts == 0 { try await Task.sleep(for: .milliseconds(2)) }
        agent.send(["sessionUpdate": "agent_message_chunk", "messageId": "m1", "content": ["type": "text", "text": "The redirect is kept."]])
        agent.endTurn()
        for _ in 0..<200 where chat.session.phase != .ready { try await Task.sleep(for: .milliseconds(2)) }
        try await Task.sleep(for: .milliseconds(100))
        tree.layoutSubtreeIfNeeded()

        manager.focusPane(terminalPaneId)
        #expect(manager.activePaneId == terminalPaneId)
        let transcript = try #require(Self.descendants(of: chat).compactMap { $0 as? MarkdownTextView }.first)
        #expect(window.makeFirstResponder(transcript))
        transcript.setSelectedRange(NSRange(location: 0, length: 3))
        for _ in 0..<100 where manager.activePaneId != chatPaneId { try await Task.sleep(for: .milliseconds(2)) }

        #expect(manager.activePaneId == chatPaneId)
        // The selection survives the pane's activation.
        #expect(window.firstResponder === transcript)
        let splitId = try #require(manager.splitPane(direction: .horizontal, paneId: manager.activePaneId))
        #expect(manager.panes[splitId]?.activeTab?.isChat == true)
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
