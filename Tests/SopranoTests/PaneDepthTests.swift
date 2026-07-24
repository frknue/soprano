import AppKit
import Testing
@testable import Soprano

struct PaneDepthTests {
    @Test func goingInCreatesAChildTerminalAndGoingBackInResumesIt() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let rootId = try #require(manager.panes[paneId]?.activeTab?.id)
        manager.updateWorkingDirectory(
            paneId: paneId,
            tabId: rootId,
            to: "/tmp/z-axis-project"
        )

        let childId = try #require(manager.goIn(paneId))
        let pane = try #require(manager.panes[paneId])

        #expect(pane.activeTab?.id == childId)
        #expect(pane.activeTab?.type == .terminal)
        #expect(pane.activeTab?.cwd == "/tmp/z-axis-project")
        #expect(pane.activeTab?.depthParentId == rootId)
        #expect(pane.activeDepth == 1)
        #expect(pane.rootTabs.map(\.id) == [rootId])

        manager.nextTab(paneId)
        #expect(pane.activeTab?.id == childId)
        manager.prevTab(paneId)
        #expect(pane.activeTab?.id == childId)

        #expect(manager.goOut(paneId))
        #expect(pane.activeTab?.id == rootId)
        #expect(pane.activeDepth == 0)
        #expect(pane.activeDepthBranch.map(\.id) == [rootId, childId])

        #expect(manager.goIn(paneId) == childId)
        #expect(pane.tabs.count == 2)
        #expect(pane.activeTab?.id == childId)
    }

    @Test func depthCanNestAndStopsAtTheOutermostTerminal() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let rootId = try #require(manager.panes[paneId]?.activeTab?.id)
        let childId = try #require(manager.goIn(paneId))
        let grandchildId = try #require(manager.goIn(paneId))
        let pane = try #require(manager.panes[paneId])

        #expect(pane.activeDepthPath.map(\.id) == [rootId, childId, grandchildId])
        #expect(pane.activeDepth == 2)

        #expect(manager.goOut(paneId))
        #expect(pane.activeTab?.id == childId)
        #expect(manager.goOut(paneId))
        #expect(pane.activeTab?.id == rootId)
        #expect(!manager.goOut(paneId))
    }

    @Test func closingTheActiveDepthLayerPopsOneLevelWithoutClosingThePane() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let rootId = try #require(manager.panes[paneId]?.activeTab?.id)
        let childId = try #require(manager.goIn(paneId))
        let grandchildId = try #require(manager.goIn(paneId))
        let pane = try #require(manager.panes[paneId])

        #expect(manager.closeActiveDepthLayer(paneId))
        #expect(pane.activeTab?.id == childId)
        #expect(!pane.tabs.contains { $0.id == grandchildId })
        #expect(manager.paneCount == 1)

        #expect(manager.closeActiveDepthLayer(paneId))
        #expect(pane.activeTab?.id == rootId)
        #expect(manager.paneCount == 1)

        #expect(!manager.closeActiveDepthLayer(paneId))
        #expect(manager.panes[paneId] != nil)
    }

    @Test func prefixXRoutingClosesALayerInsideAndThePaneAtZ0() throws {
        let manager = AgentManager()
        let originalPaneId = manager.activePaneId
        let childId = try #require(manager.goIn(originalPaneId))

        KeybindingManager.closeDepthLayerOrPane(using: manager)

        #expect(manager.panes[originalPaneId] != nil)
        #expect(manager.panes[originalPaneId]?.activeDepth == 0)
        #expect(!manager.panes[originalPaneId]!.tabs.contains { $0.id == childId })

        KeybindingManager.closeDepthLayerOrPane(using: manager)

        #expect(manager.panes[originalPaneId] == nil)
    }

    @Test func closingADepthLayerPopsToItsParentAndRemovesInnerDescendants() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let rootId = try #require(manager.panes[paneId]?.activeTab?.id)
        let childId = try #require(manager.goIn(paneId))
        let grandchildId = try #require(manager.goIn(paneId))

        manager.goOut(paneId)
        manager.removeTabFromPane(paneId, tabId: childId)

        let pane = try #require(manager.panes[paneId])
        #expect(pane.tabs.map(\.id) == [rootId])
        #expect(pane.activeTab?.id == rootId)
        #expect(!pane.tabs.contains { $0.id == grandchildId })
        #expect(manager.paneCount == 1)
    }

    @Test func regularTabNavigationDoesNotExposeDepthLayersAsTabs() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let firstRootId = try #require(manager.panes[paneId]?.activeTab?.id)
        let childId = try #require(manager.goIn(paneId))
        manager.goOut(paneId)
        let secondRootId = try #require(
            manager.addTabToPane(paneId, type: .terminal)
        )
        let pane = try #require(manager.panes[paneId])

        #expect(pane.rootTabs.map(\.id) == [firstRootId, secondRootId])
        #expect(pane.tabs.count == 3)

        manager.nextTab(paneId)
        #expect(pane.activeTab?.id == firstRootId)
        #expect(manager.goIn(paneId) == childId)

        manager.nextTab(paneId)
        #expect(pane.activeTab?.id == secondRootId)
        manager.prevTab(paneId)
        #expect(pane.activeTab?.id == firstRootId)
    }

    @Test func workspaceRoundTripPreservesDepthParentsAndActiveLayer() throws {
        let source = AgentManager()
        let paneId = source.activePaneId
        let rootId = try #require(source.panes[paneId]?.activeTab?.id)
        let childId = try #require(source.goIn(paneId))
        let grandchildId = try #require(source.goIn(paneId))
        source.goOut(paneId)

        let restored = AgentManager()
        restored.restoreWorkspace(source.snapshotWorkspace())
        let pane = try #require(restored.panes[paneId])

        #expect(pane.activeTab?.id == childId)
        #expect(pane.tabs.first { $0.id == childId }?.depthParentId == rootId)
        #expect(pane.tabs.first { $0.id == grandchildId }?.depthParentId == childId)
        #expect(restored.goIn(paneId) == grandchildId)
        #expect(pane.tabs.count == 3)
    }

    @Test func legacyTabsWithoutDepthParentsRemainRootTabs() throws {
        let data = Data(
            #"{"id":"tab-9","type":"terminal","cwd":"/tmp/legacy"}"#.utf8
        )
        let savedTab = try JSONDecoder().decode(
            WorkspaceSession.SavedTab.self,
            from: data
        )

        #expect(savedTab.depthParentId == nil)
    }
}
