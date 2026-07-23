import Testing
@testable import Soprano

@MainActor
struct ThemedSplitViewTests {
    @Test func splitViewRetainsItsExactBranchPath() {
        let splitView = ThemedSplitView(
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            branchPath: [.second, .first]
        )

        #expect(splitView.branchPath == [.second, .first])
    }

    @Test func dividerPercentageCalculationClampsToModelBounds() {
        #expect(ThemedSplitView.percentageForDividerPosition(
            -20,
            totalSize: 101,
            dividerThickness: 1
        ) == 10)
        #expect(ThemedSplitView.percentageForDividerPosition(
            50,
            totalSize: 101,
            dividerThickness: 1
        ) == 50)
        #expect(ThemedSplitView.percentageForDividerPosition(
            120,
            totalSize: 101,
            dividerThickness: 1
        ) == 90)
    }

    @Test func layoutResizeNotificationDoesNotChangeModelPercentage() throws {
        let manager = AgentManager()
        manager.setLayout(.split(.init(
            direction: .horizontal,
            first: .leaf("pane-1"),
            second: .leaf("pane-2"),
            splitPercentage: 50
        )))
        let splitView = configuredSplitView(manager: manager)
        splitView.subviews[0].frame.size.width = 75

        splitView.splitViewDidResizeSubviews(.init(
            name: .init("layout-resize"),
            object: splitView,
            userInfo: ["NSSplitViewLayoutResize": true]
        ))

        let savedLayout = try #require(manager.snapshotWorkspace().layout)
        #expect(splitPercentage(in: savedLayout) == 50)
    }

    @Test func dividerDragNotificationPersistsPercentage() throws {
        let manager = AgentManager()
        manager.setLayout(.split(.init(
            direction: .horizontal,
            first: .leaf("pane-1"),
            second: .leaf("pane-2"),
            splitPercentage: 50
        )))
        let splitView = configuredSplitView(manager: manager)
        splitView.subviews[0].frame.size.width = 75

        splitView.splitViewDidResizeSubviews(.init(
            name: .init("divider-drag"),
            object: splitView,
            userInfo: ["NSSplitViewDividerIndex": 0]
        ))

        let savedLayout = try #require(manager.snapshotWorkspace().layout)
        #expect(splitPercentage(in: savedLayout) == 75)
    }

    private func configuredSplitView(manager: AgentManager) -> ThemedSplitView {
        let splitView = ThemedSplitView(
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            branchPath: []
        )
        splitView.isVertical = true
        splitView.frame = .init(x: 0, y: 0, width: 101, height: 80)
        splitView.addSubview(.init(frame: .init(x: 0, y: 0, width: 50, height: 80)))
        splitView.addSubview(.init(frame: .init(x: 51, y: 0, width: 50, height: 80)))
        splitView.onDividerPercentageChanged = { path, percentage in
            manager.setSplitPercentage(at: path, to: percentage)
        }
        splitView.applyModelPercentage(50)
        return splitView
    }

    private func splitPercentage(in node: SplitNode) -> Double? {
        guard case .split(let branch) = node else { return nil }
        return branch.splitPercentage
    }
}
