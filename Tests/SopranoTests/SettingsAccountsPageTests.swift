import AppKit
import Testing
@testable import Soprano

/// An accounts source that records what Settings asks of it.
@MainActor
final class SettingsFakeAccounts: SettingsAccountsSource {
    var snapshot: AccountsSnapshot
    private(set) var calls: [String] = []
    private var observers: [String: @MainActor (AccountsSnapshot) -> Void] = [:]

    init(_ snapshot: AccountsSnapshot) {
        self.snapshot = snapshot
    }

    func publish(_ next: AccountsSnapshot) {
        snapshot = next
        for handler in observers.values { handler(next) }
    }

    func addObserver(id: String, handler: @escaping @MainActor (AccountsSnapshot) -> Void) { observers[id] = handler }
    func removeObserver(id: String) { observers[id] = nil }
    func refresh(force: Bool) { calls.append("refresh force=\(force)") }
    func addAccount(to list: AccountListID) { calls.append("add \(list.provider.rawValue)/\(list.tool.rawValue)") }
    func reauthenticate(accountId: String, in list: AccountListID) { calls.append("reauthenticate \(accountId)") }
    func cancelLogin() { calls.append("cancel") }
    func select(accountId: String?, in list: AccountListID) { calls.append("select \(accountId ?? "default") in \(list.provider.rawValue)/\(list.tool.rawValue)") }
    func remove(accountId: String, from list: AccountListID) { calls.append("remove \(accountId)") }
    func dismissError(in list: AccountListID) { calls.append("dismiss \(list.tool.rawValue)") }

    /// omp's Claude list with a preferred login, Claude Code on its system
    /// default, omp's Codex list on automatic, and an unreadable Codex CLI.
    static func demoSnapshot(now: Date = Date()) -> AccountsSnapshot {
        func row(_ email: String, org: String?, plan: String, _ windows: [(String, Double, TimeInterval)]) -> AccountRow {
            AccountRow(
                id: email,
                identity: AccountIdentity(email: email),
                organizationName: org,
                plan: plan,
                usage: AccountUsage(
                    windows: windows.map { UsageWindow(label: $0.0, usedFraction: $0.1, resetsAt: now.addingTimeInterval($0.2)) },
                    fetchedAt: now
                )
            )
        }
        let ada = row("ada@example.com", org: "Ada's Workshop", plan: "max", [("5h", 0.09, 14_040), ("7d", 0.06, 494_400)])
        let grace = row("grace@example.com", org: "Analytical Engines", plan: "team", [("5h", 0.72, 2_820), ("7d", 0.93, 187_200), ("7d opus", 0.41, 187_200)])
        let adaCodex = row("ada@example.com", org: nil, plan: "plus", [("5h", 0.75, 4_320), ("7d", 0.38, 525_600)])
        var snapshot = AccountsSnapshot()
        snapshot.lists[.ompClaude] = AccountList(id: .ompClaude, accounts: [ada, grace], selectedAccountId: "grace@example.com")
        snapshot.lists[.claudeCode] = AccountList(id: .claudeCode, systemDefault: ada, accounts: [grace])
        snapshot.lists[.ompCodex] = AccountList(id: .ompCodex, accounts: [adaCodex])
        snapshot.lists[.codexCLI] = AccountList(id: .codexCLI, unavailableReason: "The codex CLI was not found on PATH.")
        snapshot.lastRefresh = now.addingTimeInterval(-240)
        return snapshot
    }
}

@MainActor
struct SettingsAccountsPageTests {
    private func makeController(_ accounts: SettingsFakeAccounts) -> SettingsViewController {
        let controller = SettingsViewController(
            themeManager: ThemeManager(themeId: "folio-ink"),
            settings: .defaultSettings,
            keybindingConfig: DefaultKeybindings.config,
            accounts: accounts
        )
        controller.loadViewIfNeeded()
        controller.switchTab(to: .accounts)
        return controller
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    /// The login rows titled `title`, in page order.
    private func rows(_ title: String, in view: NSView) -> [SettingsAccountEntryRowView] {
        descendants(of: view).compactMap { $0 as? SettingsAccountEntryRowView }.filter { $0.accessibilityLabel() == title }
    }

    private func buttons(in view: NSView) -> [SettingsButton] {
        descendants(of: view).compactMap { $0 as? SettingsButton }
    }

    private func labels(in view: NSView) -> [String] {
        descendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func press(_ button: SettingsButton?) {
        guard let button, let action = button.action else { return }
        NSApp.sendAction(action, to: button.target, from: button)
    }

    @Test func openingTheAccountsPageRefreshesWithoutForcing() {
        let accounts = SettingsFakeAccounts(SettingsFakeAccounts.demoSnapshot())
        _ = makeController(accounts)
        #expect(accounts.calls == ["refresh force=false"])
    }

    @Test func thePreferredOmpLoginIsBadgedAndOffersNoPreferButton() throws {
        let accounts = SettingsFakeAccounts(SettingsFakeAccounts.demoSnapshot())
        let controller = makeController(accounts)

        // omp's Claude list is first; Claude Code lists grace as well.
        let grace = try #require(rows("grace@example.com", in: controller.view).first)
        #expect(labels(in: grace).contains("Preferred"))
        #expect(!buttons(in: grace).contains { $0.title == "Prefer" })
        #expect(buttons(in: grace).contains { $0.title == "Remove" && $0.variant == .destructiveOutline })

        let ada = try #require(rows("ada@example.com", in: controller.view).first)
        #expect(!labels(in: ada).contains("Preferred"))
        press(buttons(in: ada).first { $0.title == "Prefer" })
        #expect(accounts.calls.last == "select ada@example.com in claude/omp")
    }

    @Test func theCLIListsOfferTheirSystemDefaultAndTheUnreadableOneSaysWhy() throws {
        let accounts = SettingsFakeAccounts(SettingsFakeAccounts.demoSnapshot())
        let controller = makeController(accounts)

        let systemDefault = try #require(rows("System default", in: controller.view).first)
        #expect(labels(in: systemDefault).contains("Active"))
        #expect(labels(in: systemDefault).contains { $0.hasPrefix("ada@example.com") && $0.contains("5h 9%") })
        #expect(labels(in: controller.view).contains("The codex CLI was not found on PATH."))
    }

    @Test func aRunningSignInDisablesAddAccountAndOffersCancelOnItsList() throws {
        var snapshot = SettingsFakeAccounts.demoSnapshot()
        snapshot.pendingLogin = PendingLogin(list: .ompCodex, accountId: nil, signInURL: URL(string: "https://example.com/login"))
        let accounts = SettingsFakeAccounts(snapshot)
        let controller = makeController(accounts)

        let adds = buttons(in: controller.view).filter { $0.title == "Add Account" }
        #expect(!adds.isEmpty)
        #expect(adds.allSatisfy { !$0.isEnabled })
        #expect(labels(in: controller.view).contains("Waiting for sign-in in your browser…"))
        #expect(buttons(in: controller.view).contains { $0.title == "Open Sign-in Page" })
        press(buttons(in: controller.view).first { $0.title == "Cancel" })
        #expect(accounts.calls.last == "cancel")
    }

    @Test func aSnapshotChangeRerendersTheOpenAccountsPage() async throws {
        let accounts = SettingsFakeAccounts(SettingsFakeAccounts.demoSnapshot())
        let controller = makeController(accounts)
        #expect(rows("grace@example.com", in: controller.view).first.map { labels(in: $0).contains("Preferred") } == true)

        var next = accounts.snapshot
        next.lists[.ompClaude]?.selectedAccountId = nil
        accounts.publish(next)
        // The rebuild waits for the main queue, so a button's own action can finish first.
        try await Task.sleep(for: .milliseconds(50))

        let automatic = try #require(rows("Automatic", in: controller.view).first)
        #expect(labels(in: automatic).contains("Active"))
        #expect(rows("grace@example.com", in: controller.view).first.map { labels(in: $0).contains("Preferred") } == false)
    }
}
