import AppKit
import Testing
@testable import Soprano

@MainActor
struct AgentConversationTests {
    @Test func lifecyclePayloadsCarryAnExactConversationAlongsideTheNotification() throws {
        let payloads = [
            #"{"thread-id":"codex-one","cwd":"/tmp/repo","last-assistant-message":"Done"}"#,
            #"{"session_id":"claude-two","cwd":"/tmp/repo","hook_event_name":"SessionStart"}"#,
            #"{"sessionID":"ses_three","cwd":"/tmp/repo","message":"Approval required"}"#,
        ]
        for (payload, expected) in zip(payloads, ["codex-one", "claude-two", "ses_three"]) {
            let envelope = try #require(AgentEventCommand.notificationEnvelope(
                arguments: ["soprano", "agent-event", "ready", "--message-json", payload],
                environment: environment(paneId: "pane-1", tabId: "tab-2")
            ))
            #expect(envelope.userInfo["conversationId"] == expected)
            #expect(envelope.userInfo["conversationCwd"] == "/tmp/repo")
            #expect(envelope.userInfo["paneId"] == "pane-1")
            #expect(envelope.userInfo["tabId"] == "tab-2")
        }
    }

    @Test func codexTrailingPayloadAndClaudeStandardInputBothReachTheOwningTab() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let codexTab = try #require(manager.addTabToPane(paneId, type: .agent, profileId: "codex"))
        let claudeTab = try #require(manager.addTabToPane(paneId, type: .agent, profileId: "claude-code"))
        let notifications = AgentNotificationManager(agentManager: manager)
        let codex = try #require(AgentEventCommand.notificationEnvelope(
            arguments: ["soprano", "agent-event", "needs-input", "--profile", "codex",
                        #"{"thread-id":"codex-one","cwd":"/tmp/repo"}"#],
            environment: environment(paneId: paneId, tabId: codexTab)
        ))
        let claude = try #require(AgentEventCommand.notificationEnvelope(
            arguments: ["soprano", "agent-event", "ready", "--profile", "claude-code", "--message-from-stdin"],
            environment: environment(paneId: paneId, tabId: claudeTab),
            standardInput: { Data(#"{"session_id":"claude-two","cwd":"/tmp/repo"}"#.utf8) }
        ))
        for envelope in [codex, claude] {
            notifications.handleDistributedEvent(Notification(name: envelope.name, userInfo: envelope.userInfo))
        }
        #expect(manager.agent(paneId: paneId, tabId: codexTab)?.conversation?.id == "codex-one")
        #expect(manager.agent(paneId: paneId, tabId: claudeTab)?.conversation?.id == "claude-two")
        #expect(manager.panes[paneId]?.activeTab?.id == claudeTab)
    }

    @Test func manuallyLaunchedOmpAttachesToTheShellAndReportsThroughTheDashboard() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let tabId = try #require(manager.panes[paneId]?.activeTab?.id)
        _ = try #require(manager.addTabToPane(paneId, type: .terminal))
        let notifications = AgentNotificationManager(agentManager: manager)
        let environment = environment(paneId: paneId, tabId: tabId)
        let session = #"{"session_id":"0199-aaaa","cwd":"/tmp/project"}"#

        func deliver(_ state: String, options: [String] = []) throws -> [String: String] {
            let envelope = try #require(AgentEventCommand.notificationEnvelope(
                arguments: ["soprano", "agent-event", state, "--profile", "omp"] + options + ["--message-json", session],
                environment: environment
            ))
            notifications.handleDistributedEvent(Notification(name: envelope.name, userInfo: envelope.userInfo))
            return envelope.userInfo
        }

        _ = try deliver("ready")
        #expect(manager.panes[paneId]?.tabs.first { $0.id == tabId }?.type == .terminal)
        #expect(manager.agentDashboardSnapshot().entries.first?.profileName == "omp")
        #expect(manager.agentDashboardSnapshot().entries.first?.status == .idle)
        #expect(manager.agent(paneId: paneId, tabId: tabId)?.conversation?.id == "0199-aaaa")

        _ = try deliver("running")
        #expect(manager.agentDashboardSnapshot().workingCount == 1)

        let notification = try deliver("needs-input", options: [
            "--notify", "--title", "omp", "--body", "Response ready",
            "--message-json", #"{"message":"Please confirm the deployment"}"#
        ])
        #expect(notification["notify"] == "1")
        #expect(notification["body"] == "Needs input — Please confirm the deployment")
        #expect(notification["title"] == "omp")
        #expect(AgentNotificationManager.locationSubtitle(
            windowTitle: manager.window(containingPane: paneId)?.title,
            tabTitle: manager.panes[paneId]?.tabs.first { $0.id == tabId }?.title
        )?.contains("Terminal 1") == true)
        #expect(manager.agentDashboardSnapshot().needsInputCount == 1)
        #expect(manager.agentDashboardSnapshot().entries.first?.needsAttention == true)

        _ = try deliver("running")
        #expect(manager.agentDashboardSnapshot().workingCount == 1)
        #expect(manager.agentDashboardSnapshot().entries.first?.needsAttention == false)
        #expect(NSImage(systemSymbolName: DefaultAgents.omp.icon, accessibilityDescription: "omp") != nil)

        _ = try deliver("stopped")
        #expect(manager.agentDashboardSnapshot().totalCount == 0)
        #expect(manager.panes[paneId]?.tabs.first { $0.id == tabId }?.agent == nil)
    }

    @Test func duplicateStatusMessagesStillUpdateTheConversationAfterStartingANewChat() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let tabId = try #require(manager.addTabToPane(paneId, type: .agent, profileId: "claude-code"))
        let notifications = AgentNotificationManager(agentManager: manager)
        for id in ["first-chat", "second-chat"] {
            notifications.handle(AgentEventPayload(
                paneId: paneId, tabId: tabId, profileId: "claude-code", state: .ready,
                shouldNotify: false, title: "Claude Code", body: "Ready",
                conversation: AgentConversation(id: id, cwd: "/tmp/repo")
            ))
        }
        #expect(manager.agent(paneId: paneId, tabId: tabId)?.conversation?.id == "second-chat")
    }

    @Test func quittingAndReopeningRestoresDistinctConversationsAndTheSelectedSessionAndDepth() throws {
        let suiteName = "AgentConversationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = AgentManager()
        let firstPane = source.activePaneId
        let firstTab = try #require(source.addTabToPane(firstPane, type: .agent, profileId: "codex"))
        let secondTab = try #require(source.addTabToPane(firstPane, type: .agent, profileId: "codex"))
        source.recordAgentConversation(.init(id: "codex-one", cwd: "/tmp/repo"), paneId: firstPane, tabId: firstTab)
        source.recordAgentConversation(.init(id: "codex-two", cwd: "/tmp/repo"), paneId: firstPane, tabId: secondTab)
        let sessionId = try #require(source.createSession(name: "Other project"))
        _ = try #require(source.goIn(source.activePaneId))
        let innerPane = source.activePaneId
        let innerTab = try #require(source.addTabToPane(innerPane, type: .agent, profileId: "claude-code"))
        source.recordAgentConversation(.init(id: "claude-three"), paneId: innerPane, tabId: innerTab)
        let activeWindow = source.activeWindowId

        WorkspaceSession.saveLast(source.snapshotWorkspace(), defaults: defaults)
        let restored = AgentManager()
        restored.restoreWorkspace(try #require(WorkspaceSession.loadLast(defaults: defaults)))

        #expect(restored.activeSessionId == sessionId)
        #expect(restored.activeWindowId == activeWindow)
        #expect(restored.activePaneId == innerPane)
        #expect(restored.activeDepth == 1)
        #expect(restored.panes[innerPane]?.activeTab?.id == innerTab)
        #expect(restored.agent(paneId: firstPane, tabId: firstTab)?.conversation?.id == "codex-one")
        #expect(restored.agent(paneId: firstPane, tabId: secondTab)?.conversation?.id == "codex-two")
        #expect(restored.agent(paneId: innerPane, tabId: innerTab)?.conversation?.id == "claude-three")
    }

    @Test func aRecognizedAgentInAShellResumesButAnExitedAgentLeavesAShell() throws {
        let source = AgentManager()
        let paneId = source.activePaneId
        let tabId = try #require(source.panes[paneId]?.activeTab?.id)
        source.attachAgentIfNeeded(paneId: paneId, tabId: tabId, profileId: "codex")
        source.recordAgentConversation(.init(id: "manual-chat", cwd: "/tmp/project"), paneId: paneId, tabId: tabId)
        let restored = AgentManager()
        restored.restoreWorkspace(source.snapshotWorkspace())
        #expect(restored.panes[paneId]?.activeTab?.type == .agent)
        #expect(restored.agent(paneId: paneId, tabId: tabId)?.conversation?.id == "manual-chat")

        source.agentProcessDidExit(target: TerminalTarget(paneId: paneId, tabId: tabId))
        restored.restoreWorkspace(source.snapshotWorkspace())
        #expect(restored.panes[paneId]?.activeTab?.type == .terminal)
        #expect(restored.panes[paneId]?.activeTab?.agent == nil)
    }

    @Test func restoredSurfacesAndCachedRestartsUseTheLatestConversationWithoutLaunchingTerminals() throws {
        let source = AgentManager()
        let paneId = source.activePaneId
        let tabId = try #require(source.addTabToPane(paneId, type: .agent, profileId: "codex"))
        source.recordAgentConversation(.init(id: "saved-chat"), paneId: paneId, tabId: tabId)
        let manager = AgentManager()
        manager.restoreWorkspace(source.snapshotWorkspace())
        var commands: [String] = []
        let tree = SplitTreeView(
            agentManager: manager,
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            terminalViewFactory: { _, config, _ in
                if let command = config.command { commands.append(command) }
                return NSView()
            },
            destroyTerminalView: { _ in },
            restartTerminalView: { _, config in
                if let command = config.command { commands.append(command) }
                return true
            },
            terminalViewHasLiveSurface: { _ in true },
            scheduleCodexReadiness: { _ in }
        )
        #expect(commands.last?.contains("'resume' 'saved-chat'") == true)
        manager.recordAgentConversation(.init(id: "new-chat"), paneId: paneId, tabId: tabId)
        manager.restartAgent(paneId: paneId)
        #expect(commands.last?.contains("'resume' 'new-chat'") == true)
        #expect(commands.count == 2)
        _ = tree
    }

    @Test func olderWorkspacesStillOpenFreshAgentsWithoutGuessingTheLastConversation() throws {
        let data = Data(#"{"id":"tab-2","type":"agent","profileId":"codex","cwd":"/tmp/repo"}"#.utf8)
        let tab = try JSONDecoder().decode(WorkspaceSession.SavedTab.self, from: data)
        #expect(tab.conversation == nil)
        let config = TerminalConfig.forAgent(DefaultAgents.codex, paneId: "pane-1", tabId: tab.id, conversation: tab.conversation)
        #expect(config.command?.contains("'resume'") == false)
        #expect(config.command?.contains("'--last'") == false)
    }

    @Test func resumeCommandsTargetTheSavedIDAndKeepModelOptionsAndHooks() {
        let conversation = AgentConversation(id: "saved-chat", cwd: "/tmp/original repo")
        for (profile, selector) in [(DefaultAgents.codex, "resume"), (DefaultAgents.claudeCode, "--resume"), (DefaultAgents.openCode, "--session"), (DefaultAgents.omp, "--resume")] {
            let config = TerminalConfig.forAgent(profile, cwd: "/tmp/other", paneId: "pane-1", tabId: "tab-2", conversation: conversation)
            #expect(config.command?.hasPrefix("'\(profile.command)' '\(selector)' 'saved-chat'") == true)
            #expect(config.workingDirectory == "/tmp/original repo")
            #expect(config.env["SOPRANO_RESUME_SESSION_ID"] == "saved-chat")
            #expect(config.env["SOPRANO_PANE_ID"] == "pane-1")
            #expect(config.env["SOPRANO_TAB_ID"] == "tab-2")
            if profile.id == "codex" { #expect(config.command?.contains("notify=") == true) }
            if profile.id == "claude-code" { #expect(config.command?.contains("'--settings'") == true) }
            if profile.id == "opencode" { #expect(config.env["OPENCODE_CONFIG_CONTENT"]?.contains("SopranoOpenCodePlugin") == true) }
            if profile.id == "omp" { #expect(config.command?.contains("'--extension'") == true) }
        }
        #expect(conversation.resumeArguments(profileId: "codex", arguments: ["resume", "--last", "--model", "chosen-model"]) == ["resume", "saved-chat", "--model", "chosen-model"])
        #expect(conversation.resumeArguments(profileId: "claude-code", arguments: ["--resume=old-chat", "--fork-session", "--model", "chosen-model"]) == ["--resume", "saved-chat", "--model", "chosen-model"])
        #expect(conversation.resumeArguments(profileId: "opencode", arguments: ["--continue", "--session", "old-chat", "--fork"]) == ["--session", "saved-chat"])
        #expect(conversation.resumeArguments(profileId: "omp", arguments: ["--continue", "--resume=old-chat", "--model", "chosen-model"]) == ["--resume", "saved-chat", "--model", "chosen-model"])
    }

    @Test func malformedAndUnrelatedEventIDsCannotBecomeConversationSelectors() {
        for payload in [#"{"id":"permission-123"}"#, #"{"session_id":"--last"}"#, #"{"session_id":""}"#, #"{"session_id":"a; echo bad"}"#, "not json"] {
            #expect(AgentConversation.fromPayload(payload) == nil)
        }
        #expect(AgentConversation.fromPayload(#"{"session_id":"valid","cwd":"relative/path"}"#)?.cwd == nil)
    }

    @Test func aStoppedOrDifferentAgentCannotReplaceTheSavedConversation() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let tabId = try #require(manager.addTabToPane(paneId, type: .agent, profileId: "codex"))
        manager.recordAgentConversation(.init(id: "right", cwd: "/tmp/repo"), paneId: paneId, tabId: tabId)
        manager.recordAgentConversation(.init(id: "wrong"), paneId: paneId, tabId: tabId, profileId: "claude-code")
        manager.recordAgentConversation(.init(id: "right"), paneId: paneId, tabId: tabId)
        #expect(manager.agent(paneId: paneId, tabId: tabId)?.conversation == .init(id: "right", cwd: "/tmp/repo"))
        manager.stopAgent(paneId: paneId)
        manager.recordAgentConversation(.init(id: "late"), paneId: paneId, tabId: tabId)
        #expect(manager.agent(paneId: paneId, tabId: tabId)?.conversation?.id == "right")
    }

    private func environment(paneId: String, tabId: String) -> [String: String] {
        ["SOPRANO_APP_PID": "4242", "SOPRANO_PANE_ID": paneId, "SOPRANO_TAB_ID": tabId]
    }
}
