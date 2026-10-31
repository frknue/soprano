import AppKit
import Testing
@testable import SopranoAgents

@MainActor
struct UsageTextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theIndicatorShowsEachProvidersTightestHeadlineWindow() {
        let snapshot = AccountFixtures.demo(now: now)
        // Claude: omp is automatic, so the account with the most headroom (ada, 9%) leads;
        // Codex: omp's only Codex login (75%) does.
        #expect(UsageText.indicator(snapshot) == "Claude 9% · Codex 75%")
        #expect(UsageText.headlines(snapshot).map(\.severity) == [.normal, .warning])
    }

    @Test func aPreferredOmpAccountLeadsTheIndicatorEvenWhenItIsTighter() {
        var snapshot = AccountFixtures.demo(now: now)
        snapshot.lists[.ompClaude]?.selectedAccountId = "grace@example.com|org-grace"
        #expect(UsageText.indicator(snapshot) == "Claude 93% · Codex 75%")
        #expect(UsageText.headlines(snapshot).first?.severity == .critical)
    }

    @Test func theIndicatorHidesWithoutUsage() {
        #expect(UsageText.indicator(AccountsSnapshot()) == nil)
        #expect(UsageText.indicator(AccountFixtures.empty(now: now)) == nil)
        #expect(UsageText.tooltip(AccountsSnapshot(), now: now) == nil)
    }

    @Test func theCLIListsTheVendoredControllerStillLoadsNeverReachTheIndicator() {
        var snapshot = AccountFixtures.empty(now: now)
        let usage = AccountUsage(windows: [UsageWindow(label: "5h", usedFraction: 0.5, resetsAt: nil)], fetchedAt: now)
        snapshot.lists[.codexCLI] = AccountList(
            id: .codexCLI,
            systemDefault: AccountRow(id: "system-default", identity: AccountIdentity(email: "ada@example.com"), usage: usage)
        )
        #expect(UsageText.indicator(snapshot) == nil)
    }

    @Test func severityTurnsWarningAtSeventyAndCriticalAtNinetyPercent() {
        #expect(UsageSeverity(fraction: 0.69) == .normal)
        #expect(UsageSeverity(fraction: 0.7) == .warning)
        #expect(UsageSeverity(fraction: 0.89) == .warning)
        #expect(UsageSeverity(fraction: 0.9) == .critical)
        #expect(UsageSeverity(fraction: 1.4) == .critical)
    }

    @Test func theTooltipListsEveryWindowWithItsReset() {
        let tooltip = UsageText.tooltip(AccountFixtures.demo(now: now), now: now)
        #expect(tooltip == """
        Claude · ada@example.com
        5h 9% · resets in 3h 54m
        7d 6% · resets in 5d 17h

        Codex · ada@example.com
        5h 75% · resets in 1h 12m
        7d 38% · resets in 6d 2h

        Click for details
        """)
    }

    @Test func listCaptionsSayWhenOmpBalancesAutomatically() {
        let snapshot = AccountFixtures.demo(now: now)
        #expect(snapshot.lists[.ompClaude].map(UsageText.caption(for:)) == "omp · automatic")
        #expect(snapshot.lists[.ompCodex].map(UsageText.caption(for:)) == "omp · automatic")
        var preferred = snapshot.lists[.ompClaude]
        preferred?.selectedAccountId = "ada@example.com|org-ada"
        #expect(preferred.map(UsageText.caption(for:)) == "omp")
    }

    @Test func theRefreshLineSaysHowLongAgoAccountsWereRead() {
        var snapshot = AccountsSnapshot()
        #expect(UsageText.refreshed(snapshot, now: now) == "Not updated yet")
        snapshot.lastRefresh = now.addingTimeInterval(-20)
        #expect(UsageText.refreshed(snapshot, now: now) == "Updated just now")
        snapshot.lastRefresh = now.addingTimeInterval(-4 * 60)
        #expect(UsageText.refreshed(snapshot, now: now) == "Updated 4m ago")
        snapshot.lastRefresh = now.addingTimeInterval(-3 * 3600)
        #expect(UsageText.refreshed(snapshot, now: now) == "Updated 3h ago")
        snapshot.isRefreshing = true
        #expect(UsageText.refreshed(snapshot, now: now) == "Updating…")
    }

    @Test func accountDetailsNameOrganizationAndPlanOnceThenUsage() {
        let snapshot = AccountFixtures.demo(now: now)
        let grace = snapshot.lists[.ompClaude]?.accounts.last
        #expect(grace.map { UsageText.detailParts($0, now: now) } == [
            "Analytical Engines", "team", "5h 72% · 47m  ·  7d 93% · 2d 4h  ·  7d opus 41% · 2d 4h",
        ])
        let samePlan = AccountRow(id: "x", identity: AccountIdentity(email: "x@example.com"), organizationName: "Plus", plan: "plus")
        #expect(UsageText.detailParts(samePlan, now: now) == ["Plus", "No usage data"])
    }
}
