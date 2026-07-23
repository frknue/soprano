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
}
