import AppKit
import Testing
@testable import Soprano

struct AccountUsageParsingTests {
    /// The shape `omp usage --json` prints, preceded by the stderr-free noise a
    /// prompt theme can put on stdout during shell start-up.
    private static let ompUsage = """
        [gitstatus] warming up
        {
          "generatedAt": 1791498135730,
          "reports": [
            {
              "provider": "anthropic",
              "fetchedAt": 1791498129907,
              "limits": [
                { "id": "anthropic:5h", "label": "Claude 5 Hour",
                  "scope": { "provider": "anthropic", "windowId": "5h", "shared": true },
                  "window": { "id": "5h", "label": "5 Hour", "durationMs": 18000000, "resetsAt": 1791511800000 },
                  "amount": { "used": 9, "limit": 100, "usedFraction": 0.09, "unit": "percent" } },
                { "id": "anthropic:7d:fable", "label": "Claude 7 Day (Fable)",
                  "scope": { "provider": "anthropic", "windowId": "7d", "tier": "fable" },
                  "window": { "id": "7d", "label": "7 Day", "resetsAt": 1791993600000 },
                  "amount": { "used": 0, "limit": 100, "usedFraction": 0, "unit": "percent" } },
                { "id": "anthropic:extra", "label": "Claude Extra Usage",
                  "scope": { "provider": "anthropic" },
                  "window": { "id": "month", "label": "Month" },
                  "amount": { "used": 12.5, "limit": 50, "unit": "usd" } }
              ],
              "metadata": { "email": "Ada@Example.com", "accountId": "acct-1", "orgId": "org-1", "orgName": "Ada's Organization" }
            },
            {
              "provider": "openai-codex",
              "fetchedAt": 1791498085858,
              "limits": [
                { "id": "openai-codex:primary", "label": "7 days",
                  "scope": { "provider": "openai-codex", "windowId": "7d", "shared": true },
                  "window": { "id": "7d", "label": "7 days", "resetsAt": 1791959189000 },
                  "amount": { "used": 15, "limit": 100, "usedFraction": 0.15, "unit": "percent" } }
              ],
              "metadata": { "planType": "prolite", "email": "eric@example.com", "accountId": "ws-9", "orgId": "ws-9" }
            },
            {
              "provider": "zai",
              "limits": [],
              "metadata": { "email": "someone@example.com" }
            }
          ],
          "accountsWithoutUsage": [
            { "provider": "anthropic", "email": "second@example.com", "orgId": "org-2", "orgName": "Second" }
          ],
          "disabledCredentials": []
        }
        """

    @Test func ompUsageYieldsEveryClaudeAndCodexAccountWithPercentWindowsOnly() throws {
        let accounts = try OmpAccountManager.parseUsage(Data(Self.ompUsage.utf8))

        #expect(accounts.map(\.email) == ["Ada@Example.com", "eric@example.com", "second@example.com"])

        let ada = try #require(accounts.first)
        #expect(ada.provider == .claude)
        #expect(ada.identity == AccountIdentity(email: "Ada@Example.com", organizationId: "org-1"))
        #expect(ada.usage?.windows.map(\.label) == ["5h", "7d fable"])
        #expect(ada.usage?.windows.first?.usedFraction == 0.09)
        #expect(ada.usage?.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_791_511_800))

        let eric = accounts[1]
        #expect(eric.provider == .codex)
        #expect(eric.plan == "prolite")
        #expect(eric.identity.organizationId == "ws-9")

        // omp could not fetch this one's usage, but it is still a login to list.
        #expect(accounts[2].usage == nil)
        #expect(accounts[2].orgName == "Second")
    }

    @Test func ompUsageWithoutAJSONDocumentIsReportedAsUnavailable() {
        #expect(throws: OmpAccountError.self) {
            try OmpAccountManager.parseUsage(Data("zsh: command not found: omp\n".utf8))
        }
    }

    @Test func claudeUsageConvertsPercentagesAndMicrosecondTimestamps() throws {
        let json = """
            {
              "five_hour": { "utilization": 16.0, "resets_at": "2026-10-09T03:00:00.123456+00:00" },
              "seven_day": { "utilization": 12, "resets_at": "2026-10-15T10:00:00Z" },
              "seven_day_opus": null
            }
            """
        let usage = try UsageAPI.parseClaudeUsage(Data(json.utf8), now: Date(timeIntervalSince1970: 0))

        #expect(usage.windows.map(\.label) == ["5h", "7d"])
        #expect(usage.windows[0].usedFraction == 0.16)
        let reset = try #require(usage.windows[0].resetsAt)
        #expect(abs(reset.timeIntervalSince1970 - 1_791_514_800) < 1)
        #expect(usage.tightest?.label == "5h")
    }

    @Test func codexUsageLabelsWindowsByTheirLengthAndReadsEpochResets() throws {
        let json = """
            {
              "plan_type": "pro",
              "rate_limit": {
                "primary_window": { "used_percent": 15, "limit_window_seconds": 604800, "reset_at": 1791959189 },
                "secondary_window": { "used_percent": 140, "limit_window_seconds": 18000, "reset_after_seconds": 60 }
              }
            }
            """
        let now = Date(timeIntervalSince1970: 1_000)
        let usage = try UsageAPI.parseCodexUsage(Data(json.utf8), now: now)

        #expect(usage.windows.map(\.label) == ["7d", "5h"])
        #expect(usage.windows[0].resetsAt == Date(timeIntervalSince1970: 1_791_959_189))
        // Percentages past 100 are clamped, as the Codex CLI shows them.
        #expect(usage.windows[1].usedFraction == 1)
        #expect(usage.windows[1].resetsAt == now.addingTimeInterval(60))
    }

    @Test func resetCountdownsRoundUpToTheMinuteAndSwitchUnitsAtHoursAndDays() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(UsageFormat.timeUntil(now.addingTimeInterval(1), now: now) == "1m")
        #expect(UsageFormat.timeUntil(now.addingTimeInterval(59 * 60), now: now) == "59m")
        #expect(UsageFormat.timeUntil(now.addingTimeInterval(60 * 60), now: now) == "1h 0m")
        #expect(UsageFormat.timeUntil(now.addingTimeInterval(3 * 3600 + 54 * 60), now: now) == "3h 54m")
        #expect(UsageFormat.timeUntil(now.addingTimeInterval(24 * 3600), now: now) == "1d 0h")
        #expect(UsageFormat.timeUntil(now.addingTimeInterval(5 * 86_400 + 17 * 3600), now: now) == "5d 17h")
        #expect(UsageFormat.timeUntil(now.addingTimeInterval(-5), now: now) == nil)
        #expect(UsageFormat.timeUntil(nil, now: now) == nil)
    }

    @Test func theStatusLineFollowsOmpsPreferredAccountThenItsRoomiestThenTheCLILogin() {
        func row(_ email: String, used: Double?) -> AccountRow {
            AccountRow(
                id: email,
                identity: AccountIdentity(email: email),
                usage: used.map {
                    AccountUsage(windows: [UsageWindow(label: "5h", usedFraction: $0)], fetchedAt: Date())
                }
            )
        }
        var omp = AccountList(id: .ompClaude)
        omp.accounts = [row("busy@x", used: 0.8), row("idle@x", used: 0.1), row("unknown@x", used: nil)]
        var cli = AccountList(id: .claudeCode)
        cli.systemDefault = row("cli@x", used: 0.5)
        var snapshot = AccountsSnapshot(lists: [.ompClaude: omp, .claudeCode: cli])

        // Automatic: the account with the most headroom, which omp reaches for.
        #expect(snapshot.headline(for: .claude)?.row.id == "idle@x")

        snapshot.lists[.ompClaude]?.selectedAccountId = "busy@x"
        #expect(snapshot.headline(for: .claude)?.row.id == "busy@x")

        snapshot.lists[.ompClaude]?.accounts = []
        #expect(snapshot.headline(for: .claude)?.row.id == "cli@x")
        #expect(snapshot.headline(for: .codex) == nil)
    }
}
