import AppKit

/// What Settings → Accounts reads and acts through (Soprano Agents'
/// `AccountsSource`): `AccountsController` in the app, a fake in tests.
@MainActor
protocol SettingsAccountsSource: AnyObject {
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

extension AccountsController: SettingsAccountsSource {}
