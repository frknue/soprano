import Testing
@testable import Soprano

struct TerminalMouseButtonStateTests {
    @Test func movementWithNoPhysicalButtonReleasesAStaleTerminalPress() {
        var state = TerminalMouseButtonState()
        state.pressLeftButton()

        let releasedStalePress = state.reconcile(pressedMouseButtons: 0)
        #expect(releasedStalePress)
        #expect(!state.isLeftButtonPressed)
    }

    @Test func movementDuringARealDragKeepsTheTerminalPressActive() {
        var state = TerminalMouseButtonState()
        state.pressLeftButton()

        let releasedRealDrag = state.reconcile(pressedMouseButtons: 1)
        #expect(!releasedRealDrag)
        #expect(state.isLeftButtonPressed)
    }

    @Test func releasingOrLosingFocusOnlyReportsAnExistingPressOnce() {
        var state = TerminalMouseButtonState()

        let initialRelease = state.releaseLeftButton()
        #expect(!initialRelease)
        state.pressLeftButton()
        let releaseAfterPress = state.releaseLeftButton()
        let repeatedRelease = state.releaseLeftButton()
        #expect(releaseAfterPress)
        #expect(!repeatedRelease)
    }
}
