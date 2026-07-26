import AppKit
import Testing
@testable import Soprano

struct SessionPersistenceTests {
    @Test func namedSessionRoundTripPreservesCustomTabTitles() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sourceManager = AgentManager()
        let paneId = sourceManager.activePaneId
        let terminalTabId = try #require(sourceManager.panes[paneId]?.activeTab?.id)
        sourceManager.renameTab(paneId, tabId: terminalTabId, to: "Build logs")
        let agentTabId = try #require(
            sourceManager.addTabToPane(paneId, type: .agent, profileId: "codex")
        )
        sourceManager.renameTab(paneId, tabId: agentTabId, to: "Review agent")

        let writer = SessionManager(agentManager: sourceManager, defaults: defaults)
        writer.saveSession(name: "  Release workspace  ")

        let restoredManager = AgentManager()
        let reader = SessionManager(agentManager: restoredManager, defaults: defaults)
        let savedSession = try #require(reader.sessions.first)
        #expect(savedSession.name == "Release workspace")

        reader.loadSession(savedSession.id)

        let restoredPane = try #require(restoredManager.panes[paneId])
        #expect(restoredPane.tabs.map(\.title) == ["Build logs", "Review agent"])
        #expect(restoredPane.tabs[1].agent?.profileId == "codex")
    }

    @Test func lastSessionPersistenceRoundTripsAWorkspaceSnapshot() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sourceManager = AgentManager()
        let paneId = sourceManager.activePaneId
        let tabId = try #require(sourceManager.panes[paneId]?.activeTab?.id)
        sourceManager.renameTab(paneId, tabId: tabId, to: "Persistent title")

        WorkspaceSession.saveLast(
            sourceManager.snapshotWorkspace(),
            defaults: defaults
        )
        let persistedSession = try #require(
            WorkspaceSession.loadLast(defaults: defaults)
        )
        let restoredManager = AgentManager()
        restoredManager.restoreWorkspace(persistedSession)

        #expect(restoredManager.panes[paneId]?.activeTab?.title == "Persistent title")
    }

    @Test func lastSessionSwitchTogglesBetweenTheTwoMostRecentlyActiveWorkspaces() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = AgentManager()
        let paneId = manager.activePaneId
        let tabId = try #require(manager.panes[paneId]?.activeTab?.id)
        manager.renameTab(paneId, tabId: tabId, to: "Saved workspace")

        let sessionManager = SessionManager(agentManager: manager, defaults: defaults)
        sessionManager.saveSession(name: "Saved")
        let savedSessionId = try #require(sessionManager.sessions.first?.id)

        manager.renameTab(paneId, tabId: tabId, to: "Current workspace")
        sessionManager.loadSession(savedSessionId)
        #expect(manager.panes[paneId]?.activeTab?.title == "Saved workspace")

        sessionManager.switchToLastSession()
        #expect(manager.panes[paneId]?.activeTab?.title == "Current workspace")

        sessionManager.switchToLastSession()
        #expect(manager.panes[paneId]?.activeTab?.title == "Saved workspace")
    }

    @Test func lastSessionSwitchDoesNothingUntilAWorkspaceHasBeenLeft() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = AgentManager()
        let initialGeneration = manager.workspaceRestoreGeneration
        let sessionManager = SessionManager(agentManager: manager, defaults: defaults)

        sessionManager.switchToLastSession()

        #expect(manager.workspaceRestoreGeneration == initialGeneration)
    }

    @Test func legacySavedTabsWithoutTitlesStillRestoreWithGeneratedTitles() throws {
        let legacyData = Data(
            #"{"id":"tab-9","type":"terminal","cwd":"/tmp/legacy-project"}"#.utf8
        )
        let legacyTab = try JSONDecoder().decode(
            WorkspaceSession.SavedTab.self,
            from: legacyData
        )
        #expect(legacyTab.title == nil)

        let session = WorkspaceSession(
            id: "legacy",
            name: "Legacy",
            savedAt: .distantPast,
            layout: .leaf("pane-8"),
            panes: [
                .init(id: "pane-8", activeTabIndex: 0, tabs: [legacyTab]),
            ],
            activePaneId: "pane-8"
        )
        let restoredManager = AgentManager()
        restoredManager.restoreWorkspace(session)

        #expect(restoredManager.panes["pane-8"]?.activeTab?.title == "legacy-project")
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "SessionPersistenceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
