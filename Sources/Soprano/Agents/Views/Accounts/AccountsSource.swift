import AppKit

/// What the accounts UI reads and calls: the vendored `AccountsController` in the app, a
/// `FixtureAccountsSource` in tests and the snapshot harness. Views never reach
/// `AccountsController.shared` themselves, so nothing in a test or snapshot runs an account
/// CLI, reads the Keychain or calls a usage API.
@MainActor
protocol AccountsSource: AnyObject {
    var snapshot: AccountsSnapshot { get }
    func addObserver(id: String, handler: @escaping @MainActor (AccountsSnapshot) -> Void)
    func removeObserver(id: String)
    func refresh(force: Bool)
    func addAccount(to list: AccountListID)
    func reauthenticate(accountId: String, in list: AccountListID)
    func cancelLogin()
    func select(accountId: String?, in list: AccountListID)
    func remove(accountId: String, from list: AccountListID)
    func dismissError(in list: AccountListID)
}

extension AccountsController: AccountsSource {}

/// The accounts source the UI uses. Inert (empty, no CLIs) until the app delegate installs
/// `AccountsController.shared` at launch or the snapshot harness installs a fixture.
@MainActor
enum AccountsCenter {
    static var source: any AccountsSource = FixtureAccountsSource()
}

/// A fixed snapshot for tests and the snapshot harness. Actions change only this snapshot, the
/// way the real controller's answer would look, so clicks in a snapshot still show something.
@MainActor
final class FixtureAccountsSource: AccountsSource {
    private(set) var snapshot: AccountsSnapshot {
        didSet {
            guard snapshot != oldValue else { return }
            for handler in observers.values { handler(snapshot) }
        }
    }

    private var observers: [String: @MainActor (AccountsSnapshot) -> Void] = [:]
    /// Every action called, for tests: "refresh", "add:<list>", "select:<list>:<id|nil>", ….
    private(set) var actions: [String] = []

    init(snapshot: AccountsSnapshot = AccountsSnapshot()) {
        self.snapshot = snapshot
    }

    func addObserver(id: String, handler: @escaping @MainActor (AccountsSnapshot) -> Void) {
        observers[id] = handler
    }

    func removeObserver(id: String) {
        observers.removeValue(forKey: id)
    }

    var observerCount: Int { observers.count }

    func refresh(force: Bool) {
        actions.append(force ? "refresh:force" : "refresh")
    }

    func addAccount(to list: AccountListID) {
        actions.append("add:\(Self.name(list))")
        guard snapshot.pendingLogin == nil else { return }
        snapshot.pendingLogin = PendingLogin(list: list, accountId: nil, signInURL: nil)
    }

    func reauthenticate(accountId: String, in list: AccountListID) {
        actions.append("reauthenticate:\(Self.name(list)):\(accountId)")
        guard snapshot.pendingLogin == nil else { return }
        snapshot.pendingLogin = PendingLogin(list: list, accountId: accountId, signInURL: nil)
    }

    func cancelLogin() {
        actions.append("cancel")
        snapshot.pendingLogin = nil
    }

    func select(accountId: String?, in list: AccountListID) {
        actions.append("select:\(Self.name(list)):\(accountId ?? "nil")")
        snapshot.lists[list]?.selectedAccountId = accountId
    }

    func remove(accountId: String, from list: AccountListID) {
        actions.append("remove:\(Self.name(list)):\(accountId)")
        snapshot.lists[list]?.accounts.removeAll { $0.id == accountId }
        if snapshot.lists[list]?.selectedAccountId == accountId {
            snapshot.lists[list]?.selectedAccountId = nil
        }
    }

    func dismissError(in list: AccountListID) {
        actions.append("dismiss:\(Self.name(list))")
        snapshot.errors[list] = nil
    }

    private static func name(_ list: AccountListID) -> String {
        "\(list.tool.rawValue)-\(list.provider.rawValue)"
    }
}
