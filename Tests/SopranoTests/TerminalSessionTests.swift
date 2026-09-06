import AppKit
import Testing
@testable import Soprano

struct TerminalSessionTests {
    @Test func windowNavigationAndNumberShortcutsStayInsideTheCurrentSession() throws {
        let manager = AgentManager()
        let firstSessionId = manager.activeSessionId
        let firstWindowId = manager.activeWindowId
        let secondWindowId = try #require(manager.createWindow())
        let otherSessionId = try #require(manager.createSession(name: "Other project"))
        let otherWindowId = manager.activeWindowId

        manager.activateNextWindow()
        manager.activatePreviousWindow()
        manager.activateWindow(number: 2)
        manager.activateLastWindow()
        #expect(manager.activeWindowId == otherWindowId)
        #expect(manager.activeSessionId == otherSessionId)

        manager.activateSession(firstSessionId)
        #expect(manager.activeWindowId == secondWindowId)
        manager.activateNextWindow()
        #expect(manager.activeWindowId == firstWindowId)
        manager.activatePreviousWindow()
        #expect(manager.activeWindowId == secondWindowId)
        manager.activateWindow(number: 1)
        #expect(manager.activeWindowId == firstWindowId)
        manager.activateWindow(number: 3)
        #expect(manager.activeWindowId == firstWindowId)
        #expect(manager.activeSessionId == firstSessionId)
    }

    @Test func eachSessionRemembersItsOwnCurrentAndPreviousWindow() throws {
        let manager = AgentManager()
        let firstSessionId = manager.activeSessionId
        let firstWindowId = manager.activeWindowId
        let secondWindowId = try #require(manager.createWindow())
        let otherSessionId = try #require(manager.createSession(name: "Other"))
        let otherFirstWindowId = manager.activeWindowId
        let otherSecondWindowId = try #require(manager.createWindow())

        manager.activateSession(firstSessionId)
        manager.activateLastWindow()
        #expect(manager.activeWindowId == firstWindowId)
        manager.activateLastWindow()
        #expect(manager.activeWindowId == secondWindowId)
        manager.activateSession(otherSessionId)
        #expect(manager.activeWindowId == otherSecondWindowId)
        manager.activateLastWindow()
        #expect(manager.activeWindowId == otherFirstWindowId)
    }

    @Test func switchingSessionsPreservesDepthAndFocusingAnExactPaneSwitchesItsSession() throws {
        let manager = AgentManager()
        let firstSessionId = manager.activeSessionId
        let rootPaneId = manager.activePaneId
        let innerTabId = try #require(manager.goIn(rootPaneId))
        let innerPaneId = manager.activePaneId
        let innerPane = try #require(manager.panes[innerPaneId])
        let firstLayout = manager.layout
        let otherSessionId = try #require(manager.createSession(name: "Other"))
        let otherPaneId = manager.activePaneId

        #expect(manager.activeDepth == 0)
        #expect(manager.paneShortcutAssignments.map(\.paneId) == [otherPaneId])
        manager.focusTab(paneId: innerPaneId, tabId: innerTabId)
        #expect(manager.activeSessionId == firstSessionId)
        #expect(manager.activeDepth == 1)
        #expect(manager.layout == firstLayout)
        #expect(manager.panes[innerPaneId] === innerPane)
        manager.activateSession(otherSessionId)
        #expect(manager.activePaneId == otherPaneId)
    }

    @Test func newWindowsInheritTheCurrentDirectoryAndBelongToTheSelectedSession() throws {
        let manager = AgentManager()
        let sessionId = try #require(manager.createSession(name: "  Project  ", cwd: "/tmp/project"))
        let windowId = try #require(manager.createWindow())

        #expect(manager.activeSession?.name == "Project")
        #expect(manager.windows[windowId]?.sessionId == sessionId)
        #expect(manager.activeWorkingDirectory == "/tmp/project")
        #expect(manager.activeSessionWindows.count == 2)
        #expect(manager.orderedWindows.count == 3)
        #expect(manager.createSession(name: " \n ") == nil)
        #expect(manager.terminalSessions.count == 2)
        manager.renameSession(sessionId, to: "  Renamed  ")
        #expect(manager.activeSession?.name == "Renamed")
    }

    @Test func closingTheLastWindowKeepsItsSessionAndLeavesOtherSessionsAlone() throws {
        let manager = AgentManager()
        let firstSessionId = manager.activeSessionId
        let firstWindowId = manager.activeWindowId
        let otherSessionId = try #require(manager.createSession(name: "Other"))
        let otherWindowId = manager.activeWindowId
        var observedSessions: [String] = []
        manager.addObserver(id: "session-test") { [weak manager] in
            if let manager { observedSessions.append(manager.activeSessionId) }
        }

        manager.closeWindow(firstWindowId)
        #expect(manager.activeWindowId == otherWindowId)
        #expect(observedSessions.allSatisfy { $0 == otherSessionId })
        let replacementWindow = try #require(manager.orderedWindows(in: firstSessionId).first)
        #expect(replacementWindow.id != firstWindowId)
        manager.activateSession(firstSessionId)
        #expect(manager.activeWindowId == replacementWindow.id)

        manager.closeWindow(replacementWindow.id)
        #expect(manager.activeSessionId == firstSessionId)
        #expect(manager.activeSessionWindows.count == 1)
        #expect(manager.windows[otherWindowId] != nil)
    }

    @Test func closingASessionRemovesOnlyItsWindowsAndAlwaysLeavesAUsableSession() throws {
        let manager = AgentManager()
        let firstSessionId = manager.activeSessionId
        let firstPaneId = manager.activePaneId
        _ = try #require(manager.createWindow())
        let otherSessionId = try #require(manager.createSession(name: "Other"))
        let otherPaneId = manager.activePaneId

        manager.closeSession(firstSessionId)
        #expect(manager.activeSessionId == otherSessionId)
        #expect(manager.panes[firstPaneId] == nil)
        #expect(Set(manager.panes.keys) == [otherPaneId])
        manager.closeSession(otherSessionId)
        #expect(manager.terminalSessions.count == 1)
        #expect(manager.activeSessionWindows.count == 1)
        #expect(manager.panes[manager.activePaneId] != nil)
        #expect(manager.panes[otherPaneId] == nil)
    }

    @Test func snapshotsRestoreAllSessionsAndTheirIndependentWindowSelection() throws {
        let manager = AgentManager()
        let firstSessionId = manager.activeSessionId
        manager.renameSession(firstSessionId, to: "Work")
        let firstWindowId = manager.activeWindowId
        let secondWindowId = try #require(manager.createWindow())
        let secondSessionId = try #require(manager.createSession(name: "Personal"))
        let personalWindowId = try #require(manager.createWindow())
        let innerTabId = try #require(manager.goIn(manager.activePaneId))
        let innerPaneId = manager.activePaneId
        let encoded = try JSONEncoder().encode(manager.snapshotWorkspace())
        let restored = AgentManager()
        restored.restoreWorkspace(try JSONDecoder().decode(WorkspaceSession.self, from: encoded))

        #expect(restored.orderedSessions.map(\.name) == ["Work", "Personal"])
        #expect(restored.activeSessionId == secondSessionId)
        #expect(restored.activeWindowId == personalWindowId)
        #expect(restored.activePaneId == innerPaneId)
        #expect(restored.panes[innerPaneId]?.activeTab?.id == innerTabId)
        #expect(restored.activeDepth == 1)
        restored.activateSession(firstSessionId)
        #expect(restored.activeWindowId == secondWindowId)
        restored.activateLastWindow()
        #expect(restored.activeWindowId == firstWindowId)
        let newSessionId = try #require(restored.createSession(name: "Third"))
        #expect(newSessionId != firstSessionId && newSessionId != secondSessionId)
    }

    @Test func olderSnapshotsMigrateAllWindowsIntoOneSession() throws {
        let manager = AgentManager()
        _ = try #require(manager.createWindow())
        var snapshot = manager.snapshotWorkspace()
        snapshot.terminalSessions = nil
        snapshot.windows = snapshot.windows?.map { window in
            var legacy = window
            legacy.sessionId = nil
            return legacy
        }
        let restored = AgentManager()
        restored.restoreWorkspace(snapshot)

        #expect(restored.terminalSessions.count == 1)
        #expect(restored.activeSessionWindows.count == 2)
        #expect(restored.activeWindowId == snapshot.activeWindowId)
        #expect(restored.panes.count == snapshot.panes.count)
    }

    @Test func namedWorkspaceSavingIncludesLiveSessions() throws {
        let suiteName = "TerminalSessionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = AgentManager()
        _ = try #require(manager.createSession(name: "Project"))
        SessionManager(agentManager: manager, defaults: defaults).saveSession(name: "Everything")
        let restored = AgentManager()
        let saved = SessionManager(agentManager: restored, defaults: defaults)
        saved.loadSession(try #require(saved.sessions.first?.id))

        #expect(restored.orderedSessions.map(\.name) == ["Session 1", "Project"])
        #expect(restored.activeSession?.name == "Project")
    }

    @Test func restoringKeepsWindowNamesIndependentAndRepairsCrossSessionHistory() throws {
        let manager = AgentManager()
        let firstSessionId = manager.activeSessionId
        let firstWindowId = manager.activeWindowId
        _ = try #require(manager.createSession(name: "Other"))
        let otherWindowId = manager.activeWindowId
        var snapshot = manager.snapshotWorkspace()
        snapshot.terminalSessions?[0].activeWindowId = otherWindowId
        snapshot.terminalSessions?[0].lastActiveWindowId = otherWindowId
        let restored = AgentManager()
        restored.restoreWorkspace(snapshot)

        #expect(restored.windows[firstWindowId]?.title == restored.windows[otherWindowId]?.title)
        restored.activateSession(firstSessionId)
        restored.activateLastWindow()
        #expect(restored.activeWindowId == firstWindowId)
        #expect(restored.activeSessionId == firstSessionId)
    }

    @Test func globalAgentLocationsIncludeTheirSession() throws {
        let manager = AgentManager()
        let firstSessionName = try #require(manager.activeSession?.name)
        _ = try #require(manager.spawnAgent("codex"))
        _ = try #require(manager.createSession(name: "Other"))
        _ = try #require(manager.spawnAgent("claude-code"))
        let entries = manager.agentDashboardSnapshot().entries
        #expect(Set(entries.compactMap(\.sessionName)) == [firstSessionName, "Other"])
        #expect(entries.allSatisfy { $0.location.hasPrefix("\($0.sessionName!) ▸ ") })
        #expect(AgentNotificationManager.locationSubtitle(
            sessionName: "Other", windowTitle: "Build", tabTitle: "Claude"
        ) == "Other ▸ Build ▸ Claude")
    }

    @Test func sessionCommandsKeepPrefixCAvailableForWindows() throws {
        let bindings = DefaultKeybindings.config.bindings
        let create = try #require(bindings.first { $0.id == "new-session" })
        let select = try #require(bindings.first { $0.id == "find-session" })
        let window = try #require(bindings.first { $0.id == "new-window-current-directory" })
        #expect(create.mode == .prefix && create.key == "c" && create.shift == true)
        #expect(select.mode == .prefix && select.key == "s" && select.shift != true)
        #expect(window.mode == .prefix && window.key == "c" && window.shift != true)
    }
}
