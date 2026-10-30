import AppKit
import Testing
@testable import SopranoAgents

@MainActor
struct RightPanelTabsTests {
    @Test func eachThreadKeepsItsOwnTabsAndActiveTab() {
        let state = WorkspaceState()
        state.select(.thread("a"))
        state.showRightPanel(.files)
        state.showRightPanel(.file("Sources/App.swift"))

        state.select(.thread("b"))
        #expect(state.rightPanelSurfaces == [.diff])
        #expect(state.rightPanelSurface == .diff)

        state.select(.thread("a"))
        #expect(state.rightPanelSurfaces == [.diff, .files, .file("Sources/App.swift")])
        #expect(state.rightPanelSurface == .file("Sources/App.swift"))
    }

    @Test func showingAnOpenSurfaceActivatesItWithoutAddingASecondTab() {
        let state = WorkspaceState()
        state.select(.thread("a"))
        state.showRightPanel(.files)
        state.showRightPanel(.diff)
        state.showRightPanel(.files)

        #expect(state.rightPanelSurfaces == [.diff, .files])
        #expect(state.rightPanelSurface == .files)
        #expect(state.isRightPanelVisible)
    }

    @Test func closingTheActiveTabActivatesTheOneThatTakesItsPlace() {
        let state = WorkspaceState()
        state.select(.thread("a"))
        state.showRightPanel(.files)
        state.showRightPanel(.terminal("t1"))
        state.showRightPanel(.files)

        state.closeRightPanelTab(.files)
        #expect(state.rightPanelSurfaces == [.diff, .terminal("t1")])
        #expect(state.rightPanelSurface == .terminal("t1"))

        state.closeRightPanelTab(.terminal("t1"))
        #expect(state.rightPanelSurface == .diff)
    }

    @Test func closingTheLastTabLeavesThePanelOpenOnTheLauncher() {
        let state = WorkspaceState()
        state.select(.thread("a"))
        state.showRightPanel(.diff)

        state.closeRightPanelTab(.diff)

        #expect(state.rightPanelSurfaces.isEmpty)
        #expect(state.rightPanelSurface == nil)
        #expect(state.isRightPanelVisible)
    }

    @Test func showingADiffScopeBringsBackAClosedDiffTab() {
        let state = WorkspaceState()
        state.select(.thread("a"))
        state.closeRightPanelTab(.diff)

        state.showDiff(.turn(2), focus: "README.md")

        #expect(state.rightPanelSurfaces == [.diff])
        #expect(state.rightPanelSurface == .diff)
        #expect(state.diffScope == .turn(2))
    }

    @Test func aBackgroundThreadsTerminalTabClosesWithoutTouchingTheSelectedThread() {
        let state = WorkspaceState()
        state.select(.thread("a"))
        state.showRightPanel(.terminal("t1"))
        state.select(.thread("b"))
        state.showRightPanel(.files)

        state.closeRightPanelTab(.terminal("t1"), threadID: "a")

        #expect(state.rightPanelSurfaces(for: "a") == [.diff])
        #expect(state.rightPanelSurfaces == [.diff, .files])
        #expect(state.rightPanelSurface == .files)
    }

    @Test func deletedThreadsLoseTheirTabs() {
        let state = WorkspaceState()
        state.select(.thread("gone"))
        state.showRightPanel(.files)
        state.select(.thread("kept"))
        state.showRightPanel(.files)

        state.pruneRightPanelTabs(keeping: ["kept"])

        #expect(state.rightPanelSurfaces(for: "gone") == [.diff])
        #expect(state.rightPanelSurfaces(for: "kept") == [.diff, .files])
    }
}
