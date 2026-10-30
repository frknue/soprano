import AppKit

/// The one owner of account state the UI reads: it runs the three tools'
/// managers, merges their lists with usage, runs sign-ins one at a time, and
/// publishes what new agent panes need into `AccountLaunchState`.
@MainActor
final class AccountsController {
    static let shared = AccountsController()

    /// Background refresh cadence while Soprano is the active app; omp caches
    /// usage for five minutes, so polling faster would only re-read its cache.
    private static let pollInterval: TimeInterval = 300
    /// A non-forced refresh within this long of the last one does nothing.
    private static let minimumRefreshInterval: TimeInterval = 30

    private(set) var snapshot = AccountsSnapshot() {
        didSet {
            guard snapshot != oldValue else { return }
            for handler in observers.values { handler(snapshot) }
        }
    }

    private var observers: [String: @MainActor (AccountsSnapshot) -> Void] = [:]
    private let store: AccountStateStore
    private let paths: AccountPaths
    private let launchState: AccountLaunchState
    private let claude: ClaudeCodeAccountManager
    private let codex: CodexAccountManager
    private let omp: OmpAccountManager

    private var refreshTask: Task<Void, Never>?
    /// A forced refresh asked for while one ran: the running one may have read
    /// the lists before the change that asked for it.
    private var refreshAgain = false
    private var loginTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var isStarted = false
    /// Usage fetched straight from a provider, by "<list>|<row id>", so a
    /// refresh does not ask again for logins omp does not cover.
    private var directUsage: [String: (fetchedAt: Date, usage: AccountUsage?)] = [:]

    init(
        store: AccountStateStore = AccountStateStore(),
        paths: AccountPaths = .live,
        runner: CommandRunner = CommandRunner(),
        keychain: KeychainCLI = KeychainCLI(),
        launchState: AccountLaunchState = .shared
    ) {
        self.store = store
        self.paths = paths
        self.launchState = launchState
        claude = ClaudeCodeAccountManager(store: store, keychain: keychain, runner: runner, paths: paths)
        codex = CodexAccountManager(store: store, runner: runner, paths: paths)
        omp = OmpAccountManager(store: store, runner: runner, paths: paths)
    }

    /// Called once at launch: makes the omp overlay exist before any omp
    /// pane starts with it, then loads every list.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        try? omp.writeOverlay()
        publishLaunchState()
        refresh(force: true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        startPolling()
    }

    func addObserver(id: String, handler: @escaping @MainActor (AccountsSnapshot) -> Void) {
        observers[id] = handler
    }

    func removeObserver(id: String) {
        observers.removeValue(forKey: id)
    }

    // MARK: - Refresh

    /// Re-reads every list and its usage. Without `force`, a refresh within
    /// 30 s of the last one is skipped, so views can call this when they appear.
    func refresh(force: Bool = false) {
        guard refreshTask == nil else {
            if force { refreshAgain = true }
            return
        }
        if !force, let last = snapshot.lastRefresh,
           Date().timeIntervalSince(last) < Self.minimumRefreshInterval {
            return
        }
        snapshot.isRefreshing = true
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
        }
    }

    private func performRefresh() async {
        async let ompLists = omp.lists()
        async let claudeList = claude.list()
        var lists: [AccountListID: AccountList] = [:]
        lists[.codexCLI] = codex.list()
        lists[.claudeCode] = await claudeList
        for list in await ompLists {
            lists[list.id] = list
        }
        await attachUsage(to: &lists)

        // One assignment, so observers rebuild once per refresh.
        var next = snapshot
        next.lists = lists
        next.lastRefresh = Date()
        next.isRefreshing = false
        snapshot = next
        refreshTask = nil
        publishLaunchState()
        if refreshAgain {
            refreshAgain = false
            refresh(force: true)
        }
    }

    /// Fills CLI rows with usage: omp's report for the same account when omp
    /// has one (usage is per account, whichever tool asks), else the provider's
    /// own answer for a still-valid token, reused for five minutes.
    private func attachUsage(to lists: inout [AccountListID: AccountList]) async {
        for id in [AccountListID.claudeCode, .codexCLI] {
            guard var list = lists[id] else { continue }
            let reported = lists[AccountListID(tool: .omp, provider: id.provider)]?.accounts ?? []
            let credentials = id == .claudeCode ? await claude.usageCredentials() : codex.usageCredentials()

            func usage(for row: AccountRow) async -> AccountUsage? {
                guard !row.identity.email.isEmpty else { return nil }
                if let usage = reported.first(where: { $0.identity.matches(row.identity) })?.usage {
                    return usage
                }
                let key = "\(id.tool.rawValue)|\(row.id)"
                if let cached = directUsage[key], Date().timeIntervalSince(cached.fetchedAt) < Self.pollInterval {
                    return cached.usage
                }
                guard let credential = credentials.first(where: { $0.rowId == row.id }) else { return nil }
                let fetched: AccountUsage? = id.provider == .claude
                    ? try? await UsageAPI.claudeUsage(accessToken: credential.accessToken)
                    : try? await UsageAPI.codexUsage(accessToken: credential.accessToken, accountId: credential.accountId)
                directUsage[key] = (Date(), fetched)
                return fetched
            }

            if let systemDefault = list.systemDefault {
                list.systemDefault?.usage = await usage(for: systemDefault)
            }
            for index in list.accounts.indices {
                list.accounts[index].usage = await usage(for: list.accounts[index])
            }
            lists[id] = list
        }
    }

    // MARK: - Sign-in

    func addAccount(to list: AccountListID) {
        startSignIn(list: list, accountId: nil)
    }

    func reauthenticate(accountId: String, in list: AccountListID) {
        startSignIn(list: list, accountId: accountId)
    }

    func cancelLogin() {
        loginTask?.cancel()
    }

    /// One sign-in at a time: the CLIs listen on fixed local ports for the
    /// browser's redirect (Codex on 1455 for both `codex` and omp).
    private func startSignIn(list: AccountListID, accountId: String?) {
        guard snapshot.pendingLogin == nil else { return }
        snapshot.errors[list] = nil
        snapshot.pendingLogin = PendingLogin(list: list, accountId: accountId, signInURL: nil)

        let onSignInURL: @Sendable (URL) -> Void = { [weak self] url in
            Task { @MainActor in self?.signInURLArrived(url, for: list) }
        }
        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                switch list.tool {
                case .claudeCode:
                    if let accountId {
                        try await claude.reauthenticate(accountId, onSignInURL: onSignInURL)
                    } else {
                        try await claude.addAccount(onSignInURL: onSignInURL)
                    }
                case .codexCLI:
                    if let accountId {
                        try await codex.reauthenticate(accountId, onSignInURL: onSignInURL)
                    } else {
                        try await codex.addAccount(onSignInURL: onSignInURL)
                    }
                case .omp:
                    try await omp.signIn(provider: list.provider, onSignInURL: onSignInURL)
                }
            } catch let error as CommandError where error == .cancelled {
                // The user cancelled; nothing to report.
            } catch is CancellationError {
                // Same.
            } catch {
                snapshot.errors[list] = error.localizedDescription
            }
            snapshot.pendingLogin = nil
            loginTask = nil
            publishLaunchState()
            refresh(force: true)
        }
    }

    private func signInURLArrived(_ url: URL, for list: AccountListID) {
        // The first https URL a CLI prints is the authorization page.
        guard snapshot.pendingLogin?.list == list, snapshot.pendingLogin?.signInURL == nil else { return }
        snapshot.pendingLogin?.signInURL = url
    }

    // MARK: - Selection and removal

    func select(accountId: String?, in list: AccountListID) {
        // Show the choice at once; the refresh after it confirms or corrects it.
        snapshot.lists[list]?.selectedAccountId = accountId
        perform(on: list) { [self] in
            switch list.tool {
            case .claudeCode: try await claude.select(accountId)
            case .codexCLI: try codex.select(accountId)
            case .omp: try omp.select(rowId: accountId, provider: list.provider)
            }
        }
    }

    func remove(accountId: String, from list: AccountListID) {
        perform(on: list) { [self] in
            switch list.tool {
            case .claudeCode: try await claude.remove(accountId)
            case .codexCLI: try codex.remove(accountId)
            case .omp: try await omp.remove(rowId: accountId, provider: list.provider)
            }
        }
    }

    func dismissError(in list: AccountListID) {
        snapshot.errors[list] = nil
    }

    private func perform(on list: AccountListID, _ action: @escaping @MainActor () async throws -> Void) {
        snapshot.errors[list] = nil
        Task { [weak self] in
            do {
                try await action()
            } catch {
                self?.snapshot.errors[list] = error.localizedDescription
            }
            self?.publishLaunchState()
            self?.refresh(force: true)
        }
    }

    // MARK: - Launch state and polling

    private func publishLaunchState() {
        launchState.update(
            codexHome: codex.activeHome,
            codexSource: paths.codexDefaultHome,
            // Only with a preference: an omp too old for --config must keep
            // starting for anyone who never picks one.
            ompOverlay: store.state.ompPreferred.isEmpty ? nil : paths.ompOverlayFile
        )
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Only while Soprano is in front, like Orca: nobody reads the
                // status bar of a background app.
                if NSApp.isActive { self?.refresh(force: true) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    @objc private func applicationDidBecomeActive() {
        guard let last = snapshot.lastRefresh else {
            refresh(force: true)
            return
        }
        if Date().timeIntervalSince(last) >= Self.pollInterval {
            refresh(force: true)
        }
    }
}
