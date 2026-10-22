import Testing
@testable import Soprano

struct AgentManagerPaneTests {
    @Test func focusingTheAlreadyActiveTabDoesNotEmitAnotherModelChange() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let tabId = try #require(manager.panes[paneId]?.activeTab?.id)
        var changeCount = 0
        let observerId = "focus-active-tab-test"
        manager.addObserver(id: observerId) {
            changeCount += 1
        }
        defer {
            manager.removeObserver(id: observerId)
        }

        manager.focusTab(paneId: paneId, tabId: tabId)

        #expect(changeCount == 0)
    }

    @Test func spawnResultsAreTruthfulAndBecomeNilAtTabPaneCapacityWithoutConsumingAnID() throws {
        let manager = AgentManager()
        var createdPaneIds: [String] = []

        for _ in 1..<AgentManager.maxPanesPerTab {
            createdPaneIds.append(try #require(manager.spawnTerminal()))
        }

        #expect(manager.paneCount == AgentManager.maxPanesPerTab)
        #expect(manager.spawnTerminal() == nil)
        #expect(manager.spawnAgent("codex") == nil)
        #expect(manager.spawnBrowser() == nil)
        #expect(manager.paneCount == AgentManager.maxPanesPerTab)

        manager.closePane(createdPaneIds[0])
        #expect(manager.spawnTerminal() == "pane-41")
    }

    @Test func splitPaneReturnsNilAtTabCapacityWithoutAddingAPane() {
        let manager = AgentManager()
        for _ in 1..<AgentManager.maxPanesPerTab {
            #expect(manager.spawnTerminal() != nil)
        }

        #expect(manager.splitPane(direction: .horizontal, paneId: manager.activePaneId) == nil)
        #expect(manager.paneCount == AgentManager.maxPanesPerTab)
    }

    @Test func aFullTabDoesNotBlockPanesInANewTabOrAnotherWindow() throws {
        let manager = AgentManager()
        for _ in 1..<AgentManager.maxPanesPerTab {
            _ = try #require(manager.spawnTerminal())
        }
        let fullWindowId = manager.activeWindowId
        let fullTabPaneId = manager.activePaneId

        _ = try #require(manager.createLayoutTab())
        _ = try #require(manager.spawnTerminal())
        #expect(manager.splitPane(direction: .horizontal, paneId: fullTabPaneId) == nil)

        let secondWindowId = try #require(manager.createWindow())
        _ = try #require(
            manager.splitPane(direction: .horizontal, paneId: manager.activePaneId)
        )

        #expect(manager.windows[fullWindowId]?.paneIds.count == AgentManager.maxPanesPerTab + 2)
        #expect(manager.windows[secondWindowId]?.paneIds.count == 2)
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

    @Test func liveWorkingDirectoryIsInheritedByNewContent() throws {
        let manager = AgentManager()
        let sourcePaneId = manager.activePaneId
        let sourceTabId = try #require(manager.panes[sourcePaneId]?.activeTab?.id)

        manager.updateWorkingDirectory(
            paneId: sourcePaneId,
            tabId: sourceTabId,
            to: "/tmp/live-project"
        )

        let splitPaneId = try #require(
            manager.splitPane(direction: .horizontal, paneId: sourcePaneId)
        )
        #expect(manager.panes[splitPaneId]?.activeTab?.cwd == "/tmp/live-project")

        manager.focusTab(paneId: sourcePaneId, tabId: sourceTabId)
        let tabId = try #require(
            manager.addTabToPane(sourcePaneId, type: .terminal)
        )
        #expect(
            manager.panes[sourcePaneId]?.tabs.first(where: { $0.id == tabId })?.cwd
                == "/tmp/live-project"
        )

        manager.switchTab(sourcePaneId, index: 0)
        let agentPaneId = try #require(manager.spawnAgent("codex"))
        #expect(manager.panes[agentPaneId]?.activeTab?.cwd == "/tmp/live-project")

        manager.focusTab(paneId: sourcePaneId, tabId: sourceTabId)
        let windowId = try #require(manager.createWindow())
        #expect(manager.windows[windowId]?.activePaneId == manager.activePaneId)
        #expect(manager.panes[manager.activePaneId]?.activeTab?.cwd == "/tmp/live-project")
    }

    @Test func workingDirectoryUpdatesOnlyTheExactTerminalTab() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let firstTabId = try #require(manager.panes[paneId]?.activeTab?.id)
        let secondTabId = try #require(
            manager.addTabToPane(paneId, type: .terminal)
        )

        manager.updateWorkingDirectory(
            paneId: paneId,
            tabId: firstTabId,
            to: "/tmp/first"
        )
        manager.updateWorkingDirectory(
            paneId: "missing-pane",
            tabId: secondTabId,
            to: "/tmp/ignored"
        )

        let tabs = try #require(manager.panes[paneId]?.tabs)
        #expect(tabs.first(where: { $0.id == firstTabId })?.cwd == "/tmp/first")
        #expect(tabs.first(where: { $0.id == secondTabId })?.cwd == nil)
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

    @Test func lastWindowTogglesBetweenTheTwoMostRecentlyActiveLogicalWindows() throws {
        let manager = AgentManager()
        let secondWindowId = try #require(manager.createWindow())
        let thirdWindowId = try #require(manager.createWindow())

        manager.activateLastWindow()
        #expect(manager.activeWindowId == secondWindowId)

        manager.activateLastWindow()
        #expect(manager.activeWindowId == thirdWindowId)
    }

    @Test func focusingAPaneInAnotherWindowUpdatesTheLastWindowTarget() throws {
        let manager = AgentManager()
        let firstWindowId = manager.activeWindowId
        let firstPaneId = manager.activePaneId
        let secondWindowId = try #require(manager.createWindow())

        manager.focusPane(firstPaneId)
        #expect(manager.activeWindowId == firstWindowId)

        manager.activateLastWindow()
        #expect(manager.activeWindowId == secondWindowId)
    }

    @Test func closingTheLastWindowTargetClearsIt() throws {
        let manager = AgentManager()
        let firstWindowId = manager.activeWindowId
        let secondWindowId = try #require(manager.createWindow())

        manager.closeWindow(firstWindowId)
        manager.activateLastWindow()

        #expect(manager.activeWindowId == secondWindowId)
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

        func focus(_ key: String) -> Bool {
            guard case .focus(let paneId) = KeybindingManager.paneHintStep(
                typed: "",
                key: key,
                terminalClaimsControlKeys: false,
                assignments: manager.paneShortcutAssignments
            ) else { return false }
            manager.focusPane(paneId)
            return true
        }

        #expect(focus("d"))
        #expect(manager.activePaneId == "pane-1")

        #expect(focus("E"))
        #expect(manager.activePaneId == secondPaneId)

        #expect(!focus("a"))
        #expect(manager.activePaneId == secondPaneId)

        let firstWindowId = manager.activeWindowId
        let secondWindowId = try #require(manager.createWindow())
        let secondWindowPaneId = manager.activePaneId
        #expect(manager.paneShortcutAssignments.last?.key == "f")
        #expect(manager.paneShortcutAssignments.last?.paneId == secondWindowPaneId)

        #expect(focus("b"))
        #expect(manager.activeWindowId == firstWindowId)
        #expect(manager.activePaneId == thirdPaneId)
        #expect(manager.activeWindowId != secondWindowId)
    }

    @Test func everyPaneDownToTheLastWindowGetsAHintOnceThereAreMorePanesThanLetters() throws {
        let manager = AgentManager()
        for _ in 0..<29 {
            _ = try #require(manager.createWindow())
        }
        let paneIds = manager.activeSessionWindows.flatMap { manager.orderedPanes(in: $0.id).map(\.id) }
        let assignments = manager.paneShortcutAssignments

        #expect(paneIds.count == 30)
        #expect(assignments.map(\.paneId) == paneIds)
        // Single letters while they last; the last one turns into the first
        // key of the two-letter hints that cover the rest.
        #expect(assignments.prefix(19).map(\.key) == "bdefgimnopqrstuvwxy".map(String.init))
        #expect(assignments.dropFirst(19).map(\.key) == ["zb", "zd", "ze", "zf", "zg", "zi", "zm", "zn", "zo", "zp", "zq"])
    }

    @Test(arguments: [1, 20, 21, 45, 400, 401])
    func paneHintsAreUniqueShortestFirstAndNeverStartAnotherHint(count: Int) {
        let hints = AgentManager.paneHints(count: count)
        #expect(hints.count == count)
        #expect(Set(hints).count == count)
        #expect(hints.map(\.count) == hints.map(\.count).sorted())
        #expect(hints.last?.count == (count <= 20 ? 1 : count <= 400 ? 2 : 3))
        let byLength = Set(hints)
        #expect(hints.allSatisfy { hint in
            (1..<hint.count).allSatisfy { !byLength.contains(String(hint.prefix($0))) }
        })
    }

    @Test func windowSearchLandsOnTheFirstMatchingPaneTabEvenInABackgroundLayoutTab() throws {
        let manager = AgentManager()
        let windowId = manager.activeWindowId
        let firstLayoutTabId = try #require(manager.windows[windowId]?.activeTab.id)
        let themePane = try #require(manager.panes[manager.activePaneId])
        themePane.tabs[0].title = "theme"

        _ = try #require(manager.createLayoutTab())
        let appPane = try #require(manager.panes[manager.activePaneId])
        appPane.tabs[0].title = "logs"
        appPane.tabs.append(PaneTab(id: "b2c-tab", type: .terminal, title: "B2C app"))
        appPane.tabs.append(PaneTab(id: "b2c-later", type: .terminal, title: "b2c dev"))
        let laterPaneId = try #require(manager.splitPane(direction: .horizontal, paneId: appPane.id))
        let laterPane = try #require(manager.panes[laterPaneId])
        laterPane.tabs[0].title = "b2c shell"

        manager.activateLayoutTab(firstLayoutTabId)
        _ = try #require(manager.createWindow())

        #expect(manager.firstTab(inWindow: windowId, matching: "   ") == nil)
        #expect(manager.firstTab(inWindow: windowId, matching: "missing") == nil)
        let match = try #require(manager.firstTab(inWindow: windowId, matching: " b2c "))
        #expect(match.paneId == appPane.id)
        #expect(match.tabId == "b2c-tab")

        manager.focusTab(paneId: match.paneId, tabId: match.tabId)

        #expect(manager.activeWindowId == windowId)
        #expect(manager.activePaneId == appPane.id)
        #expect(appPane.activeTab?.id == "b2c-tab")
        #expect(manager.windows[windowId]?.layout?.containsLeaf(appPane.id) == true)
    }
}
