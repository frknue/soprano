import AppKit
import Testing
@testable import Soprano

struct LayoutTabTests {
    @Test func aNewTabOpensAFreshTerminalInTheActiveDirectoryAndSwitchingBackRestoresTheLayout() throws {
        let manager = AgentManager()
        let rootPaneId = manager.activePaneId
        let rootTabId = try #require(manager.panes[rootPaneId]?.activeTab?.id)
        manager.updateWorkingDirectory(paneId: rootPaneId, tabId: rootTabId, to: "/tmp/tab-project")
        let siblingPaneId = try #require(manager.splitPane(direction: .horizontal, paneId: rootPaneId))
        manager.focusPane(rootPaneId)
        let firstLayout = try #require(manager.layout)

        let layoutTabId = try #require(manager.createLayoutTab())
        let newPaneId = manager.activePaneId

        let window = try #require(manager.windows[manager.activeWindowId])
        #expect(window.tabs.map(\.id).last == layoutTabId)
        #expect(window.activeTab.id == layoutTabId)
        #expect(manager.layout == .leaf(newPaneId))
        #expect(manager.panes[newPaneId]?.activeTab?.type == .terminal)
        #expect(manager.panes[newPaneId]?.activeTab?.cwd == "/tmp/tab-project")

        manager.activatePreviousLayoutTab()
        #expect(manager.layout == firstLayout)
        #expect(manager.activePaneId == rootPaneId)
        #expect(manager.panes[siblingPaneId] != nil)

        manager.activateNextLayoutTab()
        #expect(manager.activePaneId == newPaneId)
        #expect(manager.paneCount == 3)
    }

    @Test func nextAndPreviousTabWrapAroundTheRowAndDoNothingWithOneTab() throws {
        let manager = AgentManager()
        let firstPaneId = manager.activePaneId
        var changes = 0
        manager.addObserver(id: "single-tab") { changes += 1 }
        manager.activateNextLayoutTab()
        manager.activatePreviousLayoutTab()
        manager.removeObserver(id: "single-tab")
        #expect(changes == 0)
        #expect(manager.activePaneId == firstPaneId)

        _ = try #require(manager.createLayoutTab())
        let secondPaneId = manager.activePaneId
        _ = try #require(manager.createLayoutTab())
        let thirdPaneId = manager.activePaneId

        manager.activateNextLayoutTab()
        #expect(manager.activePaneId == firstPaneId)
        manager.activatePreviousLayoutTab()
        #expect(manager.activePaneId == thirdPaneId)
        manager.activatePreviousLayoutTab()
        #expect(manager.activePaneId == secondPaneId)
    }

    @Test func splitsAndClosesStayInsideTheirTab() throws {
        let manager = AgentManager()
        let rootPaneId = manager.activePaneId
        _ = try #require(manager.createLayoutTab())
        let tabPaneId = manager.activePaneId
        let splitPaneId = try #require(manager.splitPane(direction: .vertical, paneId: tabPaneId))

        #expect(manager.layout?.orderedLeafIds == [tabPaneId, splitPaneId])
        let window = try #require(manager.windows[manager.activeWindowId])
        #expect(window.tabs[0].layout == .leaf(rootPaneId))

        manager.closePane(splitPaneId)
        #expect(manager.layout == .leaf(tabPaneId))
        #expect(window.tabs.count == 2)
    }

    @Test func focusingAPaneOrPaneTabInABackgroundTabBringsThatTabToTheFront() throws {
        let manager = AgentManager()
        let rootPaneId = manager.activePaneId
        let otherWindowId = try #require(manager.createWindow())
        let otherPaneId = manager.activePaneId
        _ = try #require(manager.createLayoutTab())
        let generation = manager.layoutGeneration

        manager.focusPane(otherPaneId)
        #expect(manager.activeWindowId == otherWindowId)
        #expect(manager.windows[otherWindowId]?.activeTabIndex == 0)
        #expect(manager.layout == .leaf(otherPaneId))
        #expect(manager.layoutGeneration > generation)

        let rootTabId = try #require(manager.panes[rootPaneId]?.activeTab?.id)
        manager.focusTab(paneId: rootPaneId, tabId: rootTabId)
        #expect(manager.activePaneId == rootPaneId)
        #expect(manager.layout == .leaf(rootPaneId))
    }

    @Test func closingATabsLastPaneShowsItsRightNeighborAndTheLastTabTakesTheWindow() throws {
        let manager = AgentManager()
        let firstWindowId = manager.activeWindowId
        let windowId = try #require(manager.createWindow())
        let firstPaneId = manager.activePaneId
        _ = try #require(manager.createLayoutTab())
        let middlePaneId = manager.activePaneId
        _ = try #require(manager.createLayoutTab())
        let lastPaneId = manager.activePaneId
        manager.focusPane(middlePaneId)

        manager.closePane(middlePaneId)
        let window = try #require(manager.windows[windowId])
        #expect(window.tabs.count == 2)
        #expect(manager.activePaneId == lastPaneId)

        manager.closePane(lastPaneId)
        #expect(window.tabs.count == 1)
        #expect(manager.activePaneId == firstPaneId)

        manager.closeActiveLayoutTab()
        #expect(manager.windows[windowId] == nil)
        #expect(manager.activeWindowId == firstWindowId)
    }

    @Test func closingAPaneInABackgroundTabLeavesTheVisibleTabOnScreen() throws {
        let manager = AgentManager()
        let rootPaneId = manager.activePaneId
        let backgroundPaneId = try #require(manager.splitPane(direction: .horizontal, paneId: rootPaneId))
        _ = try #require(manager.createLayoutTab())
        let visiblePaneId = manager.activePaneId
        let generation = manager.layoutGeneration

        manager.closePane(backgroundPaneId)

        let window = try #require(manager.windows[manager.activeWindowId])
        #expect(window.activeTabIndex == 1)
        #expect(manager.activePaneId == visiblePaneId)
        #expect(window.tabs[0].layout == .leaf(rootPaneId))
        #expect(manager.layoutGeneration > generation)
    }

    @Test func closingATabAsksAboutEveryTabInItsPanesAndCancellingKeepsIt() throws {
        let manager = AgentManager()
        let rootPaneId = manager.activePaneId
        let layoutTabId = try #require(manager.createLayoutTab())
        let firstPaneId = manager.activePaneId
        let secondPaneId = try #require(manager.splitPane(direction: .horizontal, paneId: firstPaneId))
        let paneTabId = try #require(manager.addTabToPane(secondPaneId, type: .terminal))
        let expected = Set(
            [firstPaneId, secondPaneId].flatMap { paneId in
                manager.panes[paneId]?.tabs.map { TerminalTarget(paneId: paneId, tabId: $0.id) } ?? []
            }
        )
        #expect(expected.contains(TerminalTarget(paneId: secondPaneId, tabId: paneTabId)))
        var questions: [Set<TerminalTarget>] = []
        var allow = false
        manager.closeConfirmation = { targets in
            questions.append(Set(targets))
            return allow
        }

        manager.closeLayoutTab(layoutTabId)
        #expect(questions == [expected])
        #expect(manager.windows[manager.activeWindowId]?.tabs.count == 2)
        #expect(manager.panes[firstPaneId] != nil)

        allow = true
        manager.closeLayoutTab(layoutTabId)
        #expect(manager.windows[manager.activeWindowId]?.tabs.count == 1)
        #expect(manager.panes[firstPaneId] == nil)
        #expect(manager.panes[secondPaneId] == nil)
        #expect(manager.activePaneId == rootPaneId)
    }

    @Test func switchingTabsEndsAMaximizedPane() throws {
        let manager = AgentManager()
        let rootPaneId = manager.activePaneId
        _ = try #require(manager.splitPane(direction: .horizontal, paneId: rootPaneId))
        manager.toggleMaximize()
        #expect(manager.maximizedPaneId != nil)

        _ = try #require(manager.createLayoutTab())
        #expect(manager.maximizedPaneId == nil)

        manager.activatePreviousLayoutTab()
        manager.toggleMaximize()
        #expect(manager.maximizedPaneId != nil)
        manager.activateNextLayoutTab()
        #expect(manager.maximizedPaneId == nil)
    }

    @Test func workspaceRoundTripRestoresEveryTabAndTheActiveOne() throws {
        let source = AgentManager()
        let rootPaneId = source.activePaneId
        _ = try #require(source.createLayoutTab())
        let firstPaneId = source.activePaneId
        let secondPaneId = try #require(source.splitPane(direction: .vertical, paneId: firstPaneId))
        source.focusPane(firstPaneId)
        _ = try #require(source.createLayoutTab())
        let lastPaneId = source.activePaneId
        source.activatePreviousLayoutTab()

        let restored = AgentManager()
        restored.restoreWorkspace(source.snapshotWorkspace())

        let window = try #require(restored.windows[restored.activeWindowId])
        #expect(window.tabs.map(\.layout) == [
            .leaf(rootPaneId),
            source.layout,
            .leaf(lastPaneId),
        ])
        #expect(window.activeTabIndex == 1)
        #expect(restored.activePaneId == firstPaneId)
        #expect(restored.layout?.orderedLeafIds == [firstPaneId, secondPaneId])
        #expect(Set(window.tabs.map(\.id)).count == 3)

        let newTabId = try #require(restored.createLayoutTab())
        #expect(!window.tabs.dropLast().map(\.id).contains(newTabId))
    }

    @Test func workspacesSavedWithWindowDepthReopenEachLayerAsATab() throws {
        let json = #"""
        {
          "id": "last", "name": "Last Session", "savedAt": 0, "activePaneId": "pane-5",
          "panes": [
            {"id": "pane-1", "activeTabIndex": 0, "tabs": [{"id": "tab-2", "type": "terminal", "cwd": "/tmp/root"}]},
            {"id": "pane-3", "activeTabIndex": 0, "tabs": [{"id": "tab-4", "type": "terminal"}]},
            {"id": "pane-5", "activeTabIndex": 0, "tabs": [{"id": "tab-6", "type": "terminal"}]},
            {"id": "pane-7", "activeTabIndex": 0, "tabs": [{"id": "tab-8", "type": "terminal"}]}
          ],
          "windows": [{
            "id": "window-9", "title": "Soprano", "isTitleCustom": true,
            "layout": {"leaf": {"_0": "pane-1"}}, "activePaneId": "pane-5",
            "depthLayers": [
              {"layout": {"leaf": {"_0": "pane-1"}}, "activePaneId": "pane-1", "isExpanded": true},
              {"parentPaneId": "pane-1", "isExpanded": true, "activePaneId": "pane-5",
               "layout": {"split": {"_0": {"direction": "horizontal", "splitPercentage": 40,
                 "first": {"leaf": {"_0": "pane-3"}}, "second": {"leaf": {"_0": "pane-5"}}}}}},
              {"parentPaneId": "pane-5", "isExpanded": false, "activePaneId": "pane-7",
               "layout": {"leaf": {"_0": "pane-7"}}}
            ],
            "activeDepthLayerIndex": 1,
            "activeDepth": 1
          }],
          "activeWindowId": "window-9"
        }
        """#
        let session = try JSONDecoder().decode(WorkspaceSession.self, from: Data(json.utf8))
        let manager = AgentManager()

        manager.restoreWorkspace(session)

        let window = try #require(manager.windows["window-9"])
        #expect(window.title == "Soprano")
        #expect(window.tabs.map { $0.layout?.orderedLeafIds ?? [] } == [
            ["pane-1"], ["pane-3", "pane-5"], ["pane-7"],
        ])
        #expect(window.tabs.map(\.activePaneId) == ["pane-1", "pane-5", "pane-7"])
        #expect(window.activeTabIndex == 1)
        #expect(manager.activePaneId == "pane-5")
        #expect(manager.paneCount == 4)

        let resaved = try JSONEncoder().encode(manager.snapshotWorkspace())
        let resavedWindow = try #require(
            JSONDecoder().decode(WorkspaceSession.self, from: resaved).windows?.first
        )
        #expect(resavedWindow.depthLayers == nil)
        #expect(resavedWindow.tabs?.count == 3)
        #expect(resavedWindow.activeTabIndex == 1)
    }
}
