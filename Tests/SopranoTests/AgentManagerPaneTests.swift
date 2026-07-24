import Testing
@testable import Soprano

struct AgentManagerPaneTests {
    @Test func spawnResultsAreTruthfulAndBecomeNilAtPaneCapacityWithoutConsumingAnID() throws {
        let manager = AgentManager()
        var createdPaneIds: [String] = []

        for _ in 1..<AgentManager.maxPanes {
            createdPaneIds.append(try #require(manager.spawnTerminal()))
        }

        #expect(manager.paneCount == AgentManager.maxPanes)
        #expect(manager.spawnTerminal() == nil)
        #expect(manager.spawnAgent("codex") == nil)
        #expect(manager.paneCount == AgentManager.maxPanes)

        manager.closePane(createdPaneIds[0])
        #expect(manager.spawnTerminal() == "pane-41")
    }

    @Test func splitPaneReturnsNilAtCapacityWithoutAddingAPane() {
        let manager = AgentManager()
        for _ in 1..<AgentManager.maxPanes {
            #expect(manager.spawnTerminal() != nil)
        }

        #expect(manager.splitPane(direction: .horizontal, paneId: manager.activePaneId) == nil)
        #expect(manager.paneCount == AgentManager.maxPanes)
    }

    @Test func terminalSplitPreservesWorkingDirectoryWithoutCloningAttachedAgent() throws {
        let manager = AgentManager()
        let sourcePane = try #require(manager.panes[manager.activePaneId])
        var sourceTab = try #require(sourcePane.activeTab)
        sourceTab.cwd = "/tmp/terminal-project"
        sourceTab.agent = AgentInstance(id: "manually-attached", profileId: "codex")
        sourcePane.tabs[0] = sourceTab

        let newPaneId = try #require(manager.splitPane(direction: .horizontal, paneId: sourcePane.id))
        let splitTab = try #require(manager.panes[newPaneId]?.activeTab)

        #expect(splitTab.type.rawValue == PaneType.terminal.rawValue)
        #expect(splitTab.agent == nil)
        #expect(splitTab.cwd == "/tmp/terminal-project")
    }

    @Test func agentSplitPreservesWorkingDirectory() throws {
        let manager = AgentManager()
        let sourcePaneId = try #require(manager.spawnAgent("codex", cwd: "/tmp/agent-project"))

        let newPaneId = try #require(manager.splitPane(direction: .vertical, paneId: sourcePaneId))
        let splitTab = try #require(manager.panes[newPaneId]?.activeTab)

        #expect(splitTab.type.rawValue == PaneType.agent.rawValue)
        #expect(splitTab.agent?.profileId == "codex")
        #expect(splitTab.cwd == "/tmp/agent-project")
    }

    @Test func navigationUsesWrapWhenNoDirectAdjacentPaneExists() throws {
        let manager = AgentManager()
        let secondPaneId = try #require(manager.spawnTerminal())
        manager.setLayout(.split(.init(
            direction: .horizontal,
            first: .leaf("pane-1"),
            second: .leaf(secondPaneId)
        )))
        manager.focusPane("pane-1")

        manager.navigateToPane(direction: .left)

        #expect(manager.activePaneId == secondPaneId)
    }

    @Test func alphabeticPaneHintsUseVisualOrderAcrossLogicalWindows() throws {
        let manager = AgentManager()
        let secondPaneId = try #require(manager.spawnTerminal())
        let thirdPaneId = try #require(manager.spawnTerminal())
        manager.setLayout(.split(.init(
            direction: .horizontal,
            first: .leaf(thirdPaneId),
            second: .split(.init(
                direction: .vertical,
                first: .leaf("pane-1"),
                second: .leaf(secondPaneId)
            ))
        )))

        #expect(manager.orderedPanes(in: manager.activeWindowId).map(\.id) == [
            thirdPaneId,
            "pane-1",
            secondPaneId,
        ])
        #expect(manager.paneShortcutAssignments.map(\.key) == ["b", "d", "e"])
        #expect(manager.paneShortcutAssignments.map(\.paneId) == [
            thirdPaneId,
            "pane-1",
            secondPaneId,
        ])

        #expect(manager.focusPane(shortcutKey: "d"))
        #expect(manager.activePaneId == "pane-1")

        #expect(manager.focusPane(shortcutKey: "E"))
        #expect(manager.activePaneId == secondPaneId)

        #expect(!manager.focusPane(shortcutKey: "a"))
        #expect(manager.activePaneId == secondPaneId)

        let firstWindowId = manager.activeWindowId
        let secondWindowId = try #require(manager.createWindow())
        let secondWindowPaneId = manager.activePaneId
        #expect(manager.paneShortcutAssignments.last?.key == "f")
        #expect(manager.paneShortcutAssignments.last?.paneId == secondWindowPaneId)

        #expect(manager.focusPane(shortcutKey: "b"))
        #expect(manager.activeWindowId == firstWindowId)
        #expect(manager.activePaneId == thirdPaneId)
        #expect(manager.activeWindowId != secondWindowId)
    }
}
