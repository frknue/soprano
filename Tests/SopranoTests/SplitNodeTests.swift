import Testing
@testable import Soprano

struct SplitNodeTests {
    @Test func wrapQueryUsesOppositeBoundaryForEveryDirectionInNestedTree() {
        let layout = nestedLayout

        #expect(layout.wrappingPane(from: "a", direction: .left) == "d")
        #expect(layout.wrappingPane(from: "a", direction: .up) == "d")
        #expect(layout.wrappingPane(from: "d", direction: .right) == "a")
        #expect(layout.wrappingPane(from: "d", direction: .down) == "a")
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
