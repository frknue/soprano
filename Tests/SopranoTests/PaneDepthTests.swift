import AppKit
import Testing
@testable import Soprano

struct PaneDepthTests {
    @Test func goingInCreatesAWindowLayerAndGoingBackInResumesIt() throws {
        let manager = AgentManager()
        let rootPaneId = manager.activePaneId
        let rootTabId = try #require(manager.panes[rootPaneId]?.activeTab?.id)
        manager.updateWorkingDirectory(
            paneId: rootPaneId,
            tabId: rootTabId,
            to: "/tmp/z-axis-project"
        )

        let childTabId = try #require(manager.goIn(rootPaneId))
        let childPaneId = manager.activePaneId

        #expect(childPaneId != rootPaneId)
        #expect(manager.activeDepth == 1)
        #expect(manager.panes[childPaneId]?.activeTab?.id == childTabId)
        #expect(manager.panes[childPaneId]?.activeTab?.type == .terminal)
        #expect(manager.panes[childPaneId]?.activeTab?.cwd == "/tmp/z-axis-project")

        #expect(manager.goOut(childPaneId))
        #expect(manager.activeDepth == 0)
        #expect(manager.activePaneId == rootPaneId)
        #expect(manager.panes[rootPaneId]?.activeTab?.id == rootTabId)

        #expect(manager.goIn(rootPaneId) == childTabId)
        #expect(manager.activeDepth == 1)
        #expect(manager.activePaneId == childPaneId)
        #expect(manager.paneCount == 2)
    }

    @Test func depthCanNestAndStopsAtTheOutermostLayout() throws {
        let manager = AgentManager()
        let rootPaneId = manager.activePaneId
        _ = try #require(manager.goIn(rootPaneId))
        let childPaneId = manager.activePaneId
        _ = try #require(manager.goIn(childPaneId))
        let grandchildPaneId = manager.activePaneId

        #expect(manager.activeDepth == 2)
        #expect(manager.maximumDepth == 2)

        #expect(manager.goOut(grandchildPaneId))
        #expect(manager.activePaneId == childPaneId)
        #expect(manager.activeDepth == 1)
        #expect(manager.goOut(childPaneId))
        #expect(manager.activePaneId == rootPaneId)
        #expect(manager.activeDepth == 0)
        #expect(!manager.goOut(rootPaneId))
    }

    @Test func eachOuterSplitOwnsAnIndependentFullScreenDepthBranch() throws {
        let manager = AgentManager()
        let firstRootPaneId = manager.activePaneId
        let secondRootPaneId = try #require(
            manager.splitPane(direction: .horizontal, paneId: firstRootPaneId)
        )
        manager.focusPane(firstRootPaneId)
        let secondRootTabId = try #require(
            manager.panes[secondRootPaneId]?.activeTab?.id
        )

        let firstInnerTabId = try #require(manager.goIn(firstRootPaneId))
        let firstInnerPaneId = manager.activePaneId
        #expect(manager.layout?.leafIds == [firstInnerPaneId])
        #expect(!manager.layout!.leafIds.contains(secondRootPaneId))
        let secondInnerPaneId = try #require(
            manager.splitPane(direction: .vertical, paneId: firstInnerPaneId)
        )
        let firstBranchLayout = try #require(manager.layout)
        #expect(firstBranchLayout.leafIds == [firstInnerPaneId, secondInnerPaneId])
        #expect(manager.panes[secondRootPaneId]?.activeTab?.id == secondRootTabId)

        #expect(manager.goOut(secondInnerPaneId))
        #expect(manager.layout?.orderedLeafIds == [firstRootPaneId, secondRootPaneId])

        let secondBranchTabId = try #require(manager.goIn(secondRootPaneId))
        let secondBranchPaneId = manager.activePaneId
        #expect(secondBranchPaneId != firstInnerPaneId)
        #expect(manager.layout?.leafIds == [secondBranchPaneId])

        #expect(manager.goOut(secondBranchPaneId))
        let resumedFirstBranchTabId = try #require(manager.goIn(firstRootPaneId))
        #expect(resumedFirstBranchTabId != secondBranchTabId)
        #expect(manager.layout == firstBranchLayout)
        #expect(manager.panes[firstInnerPaneId]?.activeTab?.id == firstInnerTabId)
    }

    @Test func splitBelongsToItsDepthAndEitherPaneNavigatesTheSharedStack() throws {
        let manager = AgentManager()
        let rootPaneId = manager.activePaneId
        _ = try #require(manager.goIn(rootPaneId))
        let firstInnerPaneId = manager.activePaneId
        let secondInnerPaneId = try #require(
            manager.splitPane(direction: .horizontal, paneId: firstInnerPaneId)
        )

        #expect(manager.activeDepth == 1)
        #expect(manager.layout?.leafIds == [firstInnerPaneId, secondInnerPaneId])

        #expect(manager.goOut(secondInnerPaneId))
        #expect(manager.activeDepth == 0)
        #expect(manager.layout?.leafIds == [rootPaneId])

        _ = try #require(manager.goIn(rootPaneId))
        #expect(manager.activeDepth == 1)
        #expect(manager.layout?.leafIds == [firstInnerPaneId, secondInnerPaneId])

        manager.focusPane(firstInnerPaneId)
        #expect(manager.goOut(firstInnerPaneId))
        #expect(manager.layout?.leafIds == [rootPaneId])
    }

    @Test func closingTheActiveDepthLayerRemovesItsSplitsAndInnerDescendants() throws {
        let manager = AgentManager()
        let rootPaneId = manager.activePaneId
        _ = try #require(manager.goIn(rootPaneId))
        let firstInnerPaneId = manager.activePaneId
        let secondInnerPaneId = try #require(
            manager.splitPane(direction: .vertical, paneId: firstInnerPaneId)
        )
        _ = try #require(manager.goIn(secondInnerPaneId))
        let deepestPaneId = manager.activePaneId

        #expect(manager.closeActiveDepthLayer(deepestPaneId))
        #expect(manager.activeDepth == 1)
        #expect(manager.maximumDepth == 1)
        #expect(manager.panes[deepestPaneId] == nil)
        #expect(manager.layout?.leafIds == [firstInnerPaneId, secondInnerPaneId])

        #expect(manager.closeActiveDepthLayer(firstInnerPaneId))
        #expect(manager.activeDepth == 0)
        #expect(manager.maximumDepth == 0)
        #expect(manager.panes[firstInnerPaneId] == nil)
        #expect(manager.panes[secondInnerPaneId] == nil)
        #expect(manager.layout?.leafIds == [rootPaneId])
        #expect(!manager.closeActiveDepthLayer(rootPaneId))
    }

    @Test func closingAnOuterPaneRemovesOnlyItsPrivateHiddenBranch() throws {
        let manager = AgentManager()
        let firstRootPaneId = manager.activePaneId
        let secondRootPaneId = try #require(
            manager.splitPane(direction: .horizontal, paneId: firstRootPaneId)
        )

        manager.focusPane(firstRootPaneId)
        _ = try #require(manager.goIn(firstRootPaneId))
        let firstBranchPaneId = manager.activePaneId
        #expect(manager.goOut(firstBranchPaneId))

        manager.focusPane(secondRootPaneId)
        let secondBranchTabId = try #require(manager.goIn(secondRootPaneId))
        let secondBranchPaneId = manager.activePaneId
        #expect(manager.goOut(secondBranchPaneId))

        manager.closePane(firstRootPaneId)

        #expect(manager.panes[firstRootPaneId] == nil)
        #expect(manager.panes[firstBranchPaneId] == nil)
        #expect(manager.panes[secondRootPaneId] != nil)
        #expect(manager.panes[secondBranchPaneId] != nil)
        #expect(manager.layout?.leafIds == [secondRootPaneId])
        #expect(manager.goIn(secondRootPaneId) == secondBranchTabId)
    }

    @Test func closingTheOnlyPaneInAnInnerWorkspaceReturnsToItsOwner() throws {
        let manager = AgentManager()
        let rootPaneId = manager.activePaneId
        _ = try #require(manager.goIn(rootPaneId))
        let innerPaneId = manager.activePaneId

        manager.closePane(innerPaneId)

        #expect(manager.activeDepth == 0)
        #expect(manager.activePaneId == rootPaneId)
        #expect(manager.panes[innerPaneId] == nil)
        #expect(manager.panes[rootPaneId] != nil)
    }

    @Test func prefixXRoutingClosesALayerInsideAndThePaneAtZ0() throws {
        let manager = AgentManager()
        let originalPaneId = manager.activePaneId
        _ = try #require(manager.goIn(originalPaneId))
        let childPaneId = manager.activePaneId

        KeybindingManager.closeDepthLayerOrPane(using: manager)

        #expect(manager.panes[originalPaneId] != nil)
        #expect(manager.panes[childPaneId] == nil)
        #expect(manager.activeDepth == 0)

        KeybindingManager.closeDepthLayerOrPane(using: manager)

        #expect(manager.panes[originalPaneId] == nil)
    }

    @Test func regularTabsStayInsideTheirWindowDepth() throws {
        let manager = AgentManager()
        let rootPaneId = manager.activePaneId
        _ = try #require(manager.goIn(rootPaneId))
        let innerPaneId = manager.activePaneId
        let firstTabId = try #require(manager.panes[innerPaneId]?.activeTab?.id)
        let secondTabId = try #require(
            manager.addTabToPane(innerPaneId, type: .terminal)
        )

        manager.nextTab(innerPaneId)
        #expect(manager.panes[innerPaneId]?.activeTab?.id == firstTabId)
        manager.prevTab(innerPaneId)
        #expect(manager.panes[innerPaneId]?.activeTab?.id == secondTabId)
        #expect(manager.activeDepth == 1)

        #expect(manager.goOut(innerPaneId))
        #expect(manager.activePaneId == rootPaneId)
        #expect(manager.goIn(rootPaneId) == secondTabId)
        #expect(manager.panes[innerPaneId]?.tabs.count == 2)
    }

    @Test func workspaceRoundTripPreservesDepthLayoutsAndActiveLayer() throws {
        let source = AgentManager()
        let rootPaneId = source.activePaneId
        _ = try #require(source.goIn(rootPaneId))
        let firstInnerPaneId = source.activePaneId
        let secondInnerPaneId = try #require(
            source.splitPane(direction: .horizontal, paneId: firstInnerPaneId)
        )
        source.focusPane(firstInnerPaneId)

        let restored = AgentManager()
        restored.restoreWorkspace(source.snapshotWorkspace())

        #expect(restored.activeDepth == 1)
        #expect(restored.maximumDepth == 1)
        #expect(restored.activePaneId == firstInnerPaneId)
        #expect(restored.layout?.leafIds == [firstInnerPaneId, secondInnerPaneId])
        #expect(restored.goOut(firstInnerPaneId))
        #expect(restored.layout?.leafIds == [rootPaneId])
        _ = try #require(restored.goIn(rootPaneId))
        #expect(restored.layout?.leafIds == [firstInnerPaneId, secondInnerPaneId])
    }

    @Test func legacyTabsWithoutDepthParentsRemainDecodable() throws {
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
