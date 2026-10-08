import Testing
@testable import Soprano

struct SplitNodeTests {
    @Test func orderedLeafIdsFollowVisualTreeOrder() {
        let layout = SplitNode.split(.init(
            direction: .horizontal,
            first: .leaf("pane-3"),
            second: .split(.init(
                direction: .vertical,
                first: .leaf("pane-1"),
                second: .leaf("pane-2")
            ))
        ))

        #expect(layout.orderedLeafIds == ["pane-3", "pane-1", "pane-2"])
    }

    @Test func directionalNavigationInTwoByTwoGridMovesToTheVisuallyBorderingPane() {
        let layout = nestedLayout

        #expect(layout.adjacentPane(from: "b", direction: .right) == "d")
        #expect(layout.adjacentPane(from: "a", direction: .right) == "c")
        #expect(layout.adjacentPane(from: "d", direction: .left) == "b")
        #expect(layout.adjacentPane(from: "c", direction: .left) == "a")
        #expect(layout.adjacentPane(from: "a", direction: .down) == "b")
        #expect(layout.adjacentPane(from: "d", direction: .up) == "c")
        #expect(layout.adjacentPane(from: "b", direction: .left) == nil)
    }

    @Test func directionalNavigationFollowsUnevenSplitGeometryAcrossStacks() {
        // Left column split at 70%, right column at 30%: from the bottom-left pane
        // (y 0.7–1) the pane beside it on the right is the bottom-right one (y 0.3–1).
        let layout = SplitNode.split(.init(
            direction: .horizontal,
            first: .split(.init(direction: .vertical, first: .leaf("a"), second: .leaf("b"), splitPercentage: 70)),
            second: .split(.init(direction: .vertical, first: .leaf("c"), second: .leaf("d"), splitPercentage: 30))
        ))

        #expect(layout.adjacentPane(from: "b", direction: .right) == "d")
        #expect(layout.adjacentPane(from: "a", direction: .right) == "d")
        #expect(layout.adjacentPane(from: "c", direction: .left) == "a")
    }

    @Test func wrapQueryStaysInTheSourceRowOrColumn() {
        let layout = nestedLayout

        #expect(layout.wrappingPane(from: "c", direction: .right) == "a")
        #expect(layout.wrappingPane(from: "d", direction: .right) == "b")
        #expect(layout.wrappingPane(from: "b", direction: .left) == "d")
        #expect(layout.wrappingPane(from: "b", direction: .down) == "a")
        #expect(layout.wrappingPane(from: "c", direction: .up) == "d")
    }

    @Test func wrapQueryReturnsNilForSingletonAndUnknownSources() {
        let singleton = SplitNode.leaf("only")

        #expect(singleton.wrappingPane(from: "only", direction: .left) == nil)
        #expect(nestedLayout.wrappingPane(from: "missing", direction: .right) == nil)
    }

    @Test func settingSplitPercentageUpdatesOnlyAddressedPath() {
        let layout = SplitNode.split(.init(
            direction: .horizontal,
            first: .leaf("a"),
            second: .split(.init(
                direction: .vertical,
                first: .leaf("b"),
                second: .leaf("c"),
                splitPercentage: 35
            )),
            splitPercentage: 40
        ))

        let updated = layout.settingSplitPercentage(at: [.second], to: 72.5)

        #expect(splitPercentage(in: updated, at: []) == 40)
        #expect(splitPercentage(in: updated, at: [.second]) == 72.5)
    }

    @Test func splitPercentagesClampOnCreationAndPathUpdate() {
        let layout = SplitNode.split(.init(
            direction: .horizontal,
            first: .leaf("a"),
            second: .split(.init(
                direction: .vertical,
                first: .leaf("b"),
                second: .leaf("c"),
                splitPercentage: 95
            )),
            splitPercentage: 5
        ))

        #expect(splitPercentage(in: layout, at: []) == 10)
        #expect(splitPercentage(in: layout, at: [.second]) == 90)
        #expect(splitPercentage(in: layout.settingSplitPercentage(at: [.second], to: -50), at: [.second]) == 10)
        #expect(splitPercentage(in: layout.settingSplitPercentage(at: [], to: 150), at: []) == 90)
    }

    @Test func agentManagerSetsAnAbsoluteNestedPercentageWithoutChangingTopologyGeneration() throws {
        let manager = AgentManager()
        let nestedLayout = SplitNode.split(.init(
            direction: .horizontal,
            first: .leaf("pane-1"),
            second: .split(.init(
                direction: .vertical,
                first: .leaf("pane-2"),
                second: .leaf("pane-3"),
                splitPercentage: 35
            )),
            splitPercentage: 40
        ))
        manager.setLayout(nestedLayout)
        let topologyGeneration = manager.layoutGeneration

        manager.setSplitPercentage(at: [.second], to: 125)

        let updatedLayout = try #require(manager.layout)
        #expect(splitPercentage(in: updatedLayout, at: []) == 40)
        #expect(splitPercentage(in: updatedLayout, at: [.second]) == 90)
        #expect(manager.layoutGeneration == topologyGeneration)

        let savedLayout = try #require(manager.snapshotWorkspace().layout)
        #expect(splitPercentage(in: savedLayout, at: [.second]) == 90)
    }

    private var nestedLayout: SplitNode {
        .split(.init(
            direction: .horizontal,
            first: .split(.init(
                direction: .vertical,
                first: .leaf("a"),
                second: .leaf("b")
            )),
            second: .split(.init(
                direction: .vertical,
                first: .leaf("c"),
                second: .leaf("d")
            ))
        ))
    }

    private func splitPercentage(in node: SplitNode, at path: [SplitBranchSide]) -> Double? {
        var current = node
        for side in path {
            guard case .split(let branch) = current else { return nil }
            current = side == .first ? branch.first : branch.second
        }
        guard case .split(let branch) = current else { return nil }
        return branch.splitPercentage
    }
}
