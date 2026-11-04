import AppKit

/// Account snapshots for the snapshot harness (`--accounts`) and UI tests: nothing here runs a
/// CLI, reads the Keychain or calls a usage API.
@MainActor
enum AccountFixtures {
    nonisolated static let scenarios = ["none", "demo", "empty", "pending"]

    /// `none`: never loaded (no usage, the page says "not loaded"); `demo`: two
    /// Claude logins and one Codex login in omp; `empty`: loaded, nobody signed in; `pending`:
    /// `demo` with an omp Claude sign-in waiting and a failed omp Codex action.
    static func snapshot(_ name: String, now: Date = Date()) throws -> AccountsSnapshot {
        switch name {
        case "none": return AccountsSnapshot()
        case "demo": return demo(now: now)
        case "empty": return empty(now: now)
        case "pending":
            var snapshot = demo(now: now)
            snapshot.pendingLogin = PendingLogin(
                list: .ompClaude,
                accountId: nil,
                signInURL: URL(string: "https://claude.ai/oauth/authorize?client_id=demo")
            )
            snapshot.errors[.ompCodex] = "omp sign-in failed: the browser closed before the login finished."
            return snapshot
        default:
            throw SnapshotCommand.CaptureError(description: "--accounts must be one of \(scenarios.joined(separator: ", "))")
        }
    }

    static func demo(now: Date = Date()) -> AccountsSnapshot {
        func window(_ label: String, _ fraction: Double, resetsIn seconds: TimeInterval) -> UsageWindow {
            UsageWindow(label: label, usedFraction: fraction, resetsAt: now.addingTimeInterval(seconds))
        }
        let ada = AccountIdentity(email: "ada@example.com", organizationId: "org-ada")
        let grace = AccountIdentity(email: "grace@example.com", organizationId: "org-grace")

        let adaClaude = AccountUsage(windows: [
            window("5h", 0.09, resetsIn: 3 * 3600 + 54 * 60),
            window("7d", 0.06, resetsIn: 5 * 86400 + 17 * 3600),
        ], fetchedAt: now)
        let graceClaude = AccountUsage(windows: [
            window("5h", 0.72, resetsIn: 47 * 60),
            window("7d", 0.93, resetsIn: 2 * 86400 + 4 * 3600),
            window("7d opus", 0.41, resetsIn: 2 * 86400 + 4 * 3600),
        ], fetchedAt: now)
        let adaCodex = AccountUsage(windows: [
            window("5h", 0.75, resetsIn: 1 * 3600 + 12 * 60),
            window("7d", 0.38, resetsIn: 6 * 86400 + 2 * 3600),
        ], fetchedAt: now)

        var snapshot = AccountsSnapshot()
        snapshot.lists[.ompClaude] = AccountList(
            id: .ompClaude,
            accounts: [
                AccountRow(id: ada.key, identity: ada, organizationName: "Ada's Workshop", plan: "max", usage: adaClaude),
                AccountRow(id: grace.key, identity: grace, organizationName: "Analytical Engines", plan: "team", usage: graceClaude),
            ]
        )
        snapshot.lists[.ompCodex] = AccountList(
            id: .ompCodex,
            accounts: [AccountRow(id: ada.key, identity: ada, plan: "plus", usage: adaCodex)]
        )
        snapshot.lastRefresh = now.addingTimeInterval(-4 * 60)
        return snapshot
    }

    static func empty(now: Date = Date()) -> AccountsSnapshot {
        var snapshot = AccountsSnapshot()
        for id in AccountListID.shown {
            snapshot.lists[id] = AccountList(id: id)
        }
        snapshot.lastRefresh = now.addingTimeInterval(-30)
        return snapshot
    }
}
