import Testing
@testable import Soprano

struct PaneNavigationClaimRegistryTests {
    @Test func claimsAreScopedToTheExactPaneAndTab() {
        let firstTab = TerminalTarget(paneId: "pane-1", tabId: "tab-1")
        let secondTab = TerminalTarget(paneId: "pane-1", tabId: "tab-2")
        var registry = PaneNavigationClaimRegistry()

        registry.enable(source: "nvim", for: firstTab)

        #expect(registry.hasClaims(for: firstTab))
        #expect(!registry.hasClaims(for: secondTab))
    }

    @Test func duplicateSameSourceClaimsRequireMatchingDisables() {
        let target = TerminalTarget(paneId: "pane-1", tabId: "tab-1")
        var registry = PaneNavigationClaimRegistry()

        registry.enable(source: "nvim", for: target)
        registry.enable(source: "nvim", for: target)
        registry.disable(source: "nvim", for: target)

        #expect(registry.hasClaims(for: target))

        registry.disable(source: "nvim", for: target)
        #expect(!registry.hasClaims(for: target))
    }

    @Test func unmatchedDisableDoesNotRemoveAnotherSourceClaim() {
        let target = TerminalTarget(paneId: "pane-1", tabId: "tab-1")
        var registry = PaneNavigationClaimRegistry()

        registry.enable(source: "nvim", for: target)
        registry.disable(source: "tmux", for: target)

        #expect(registry.hasClaims(for: target))
    }

    @Test func synchronizationPrunesClaimsForRemovedTabs() {
        let removedTarget = TerminalTarget(paneId: "pane-1", tabId: "tab-1")
        let survivingTarget = TerminalTarget(paneId: "pane-1", tabId: "tab-2")
        var registry = PaneNavigationClaimRegistry()
        registry.enable(source: "nvim", for: removedTarget)
        registry.enable(source: "tmux", for: survivingTarget)

        registry.synchronize(
            validTargets: [survivingTarget],
            workspaceRestoreGeneration: 0
        )

        #expect(!registry.hasClaims(for: removedTarget))
        #expect(registry.hasClaims(for: survivingTarget))
    }

    @Test func synchronizationClearsSameTargetClaimsAfterWorkspaceReplacement() {
        let target = TerminalTarget(paneId: "pane-1", tabId: "tab-1")
        var registry = PaneNavigationClaimRegistry()
        registry.synchronize(validTargets: [target], workspaceRestoreGeneration: 0)
        registry.enable(source: "nvim", for: target)

        registry.synchronize(validTargets: [target], workspaceRestoreGeneration: 1)

        #expect(!registry.hasClaims(for: target))
    }

    @Test func ordinaryControlKeysNeverActivatePaneHints() {
        #expect(!KeybindingManager.isPaneShortcutChord([]))
        #expect(!KeybindingManager.isPaneShortcutChord(.control))
        #expect(!KeybindingManager.isPaneShortcutChord(.shift))
        #expect(KeybindingManager.isPaneShortcutChord([.control, .shift]))
        #expect(!KeybindingManager.isPaneShortcutChord([.control, .shift, .option]))
        #expect(!KeybindingManager.isPaneShortcutChord([.control, .shift, .command]))
    }

    @Test func claimedTerminalControlKeysBypassPaneHints() {
        let step = KeybindingManager.paneHintStep(
            typed: "",
            key: "d",
            terminalClaimsControlKeys: true,
            assignments: [(key: "d", paneId: "pane-1")]
        )
        #expect(step == .passThrough)
    }

    @Test func unclaimedControlShiftKeysActivatePaneHints() {
        let step = KeybindingManager.paneHintStep(
            typed: "",
            key: "D",
            terminalClaimsControlKeys: false,
            assignments: [(key: "d", paneId: "pane-1")]
        )
        #expect(step == .focus(paneId: "pane-1"))
    }

    @Test func aTwoLetterHintWaitsForItsSecondLetterAndAnythingElseFallsThrough() {
        let assignments = [(key: "b", paneId: "pane-1"), (key: "zb", paneId: "pane-2"), (key: "zd", paneId: "pane-3")]
        func step(_ typed: String, _ key: String) -> KeybindingManager.PaneHintStep {
            KeybindingManager.paneHintStep(typed: typed, key: key, terminalClaimsControlKeys: false, assignments: assignments)
        }
        #expect(step("", "z") == .pending("z"))
        #expect(step("z", "d") == .focus(paneId: "pane-3"))
        #expect(step("z", "b") == .focus(paneId: "pane-2"))
        // A letter that continues no hint, or one no hint starts with, is the
        // terminal's again.
        #expect(step("z", "x") == .passThrough)
        #expect(step("", "x") == .passThrough)
        #expect(step("", "b") == .focus(paneId: "pane-1"))
    }

    @Test func repeatedPrefixForwardsLiteralControlA() {
        #expect(!KeybindingManager.shouldForwardPrefixKey(in: .normal))
        #expect(KeybindingManager.shouldForwardPrefixKey(in: .prefix))
    }
}
