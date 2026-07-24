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
        var focusedKeys: [String] = []

        let handled = KeybindingManager.handlePaneShortcut(
            key: "d",
            terminalClaimsControlKeys: true
        ) { key in
            focusedKeys.append(key)
            return true
        }

        #expect(!handled)
        #expect(focusedKeys.isEmpty)
    }

    @Test func unclaimedControlShiftKeysActivatePaneHints() {
        var focusedKeys: [String] = []

        let handled = KeybindingManager.handlePaneShortcut(
            key: "d",
            terminalClaimsControlKeys: false
        ) { key in
            focusedKeys.append(key)
            return true
        }

        #expect(handled)
        #expect(focusedKeys == ["d"])
    }

    @Test func repeatedPrefixForwardsLiteralControlA() {
        #expect(!KeybindingManager.shouldForwardPrefixKey(in: .normal))
        #expect(KeybindingManager.shouldForwardPrefixKey(in: .prefix))
    }
}
