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
}
