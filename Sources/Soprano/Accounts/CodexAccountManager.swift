import Foundation

enum CodexAccountError: LocalizedError {
    case loginFailed(String)
    case noCredentials
    case duplicate(String)
    case wrongAccount(expected: String, signedIn: String)
    case unknownAccount
    case notManaged(String)

    var errorDescription: String? {
        switch self {
        case .loginFailed(let message):
            return "Codex sign-in failed: \(message)"
        case .noCredentials:
            return "codex login finished, but no ChatGPT login was saved."
        case .duplicate(let email):
            return "\(email) is already added."
        case .wrongAccount(let expected, let signedIn):
            return "Signed in as \(signedIn), not \(expected). The previous login was kept."
        case .unknownAccount:
            return "That account is no longer in the list."
        case .notManaged(let path):
            return "\(path) is not a Soprano-managed Codex home; it was left alone."
        }
    }
}

/// What a Codex `auth.json` says about its login.
struct CodexAuth: Equatable, Sendable {
    var identity: AccountIdentity
    var plan: String?
    var accessToken: String?
    var accessTokenExpiry: Date?

    static func read(home: URL) -> CodexAuth? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")) else { return nil }
        return parse(data)
    }

    /// `{"tokens": {"id_token": <JWT>, "access_token": <JWT>, "account_id": …}}`;
    /// the id token's claims carry the email and the ChatGPT account and plan.
    static func parse(_ data: Data) -> CodexAuth? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let claims = AccountFiles.jwtClaims(idToken)
        else { return nil }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let profile = claims["https://api.openai.com/profile"] as? [String: Any]
        guard let email = (claims["email"] as? String) ?? (profile?["email"] as? String), !email.isEmpty else {
            return nil
        }
        let accountId = (tokens["account_id"] as? String) ?? (auth?["chatgpt_account_id"] as? String)
        let accessToken = tokens["access_token"] as? String
        let expiry = accessToken
            .flatMap(AccountFiles.jwtClaims)
            .flatMap { UsageAPI.number($0["exp"]) }
            .map { Date(timeIntervalSince1970: $0) }
        return CodexAuth(
            identity: AccountIdentity(email: email, organizationId: accountId),
            plan: auth?["chatgpt_plan_type"] as? String,
            accessToken: accessToken,
            accessTokenExpiry: expiry
        )
    }
}

/// Codex CLI logins. Each managed account is its own `CODEX_HOME` holding
/// just that account's `auth.json`; everything else in it links back to
/// `~/.codex`, so config, skills, prompts and every session stay shared and a
/// thread started under one account resumes under another. New codex panes
/// get the chosen account's `CODEX_HOME`; running panes keep theirs.
@MainActor
final class CodexAccountManager {
    nonisolated static let markerFile = ".soprano-managed-home"
    static let systemDefaultRowId = "system-default"

    private let store: AccountStateStore
    private let runner: CommandRunner
    private let paths: AccountPaths

    init(store: AccountStateStore, runner: CommandRunner = CommandRunner(), paths: AccountPaths = .live) {
        self.store = store
        self.runner = runner
        self.paths = paths
    }

    private var state: ManagedAccountsState { store.state.codexCLI }

    private func update(_ change: (inout ManagedAccountsState) -> Void) {
        store.update { change(&$0.codexCLI) }
    }

    func home(for accountId: String) -> URL {
        paths.codexAccountsDirectory
            .appendingPathComponent(accountId, isDirectory: true)
            .appendingPathComponent("home", isDirectory: true)
    }

    /// The `CODEX_HOME` new codex panes should use; nil for the System default.
    var activeHome: URL? {
        state.activeAccount.map { home(for: $0.id) }
    }

    // MARK: - Listing

    func list() -> AccountList {
        var list = AccountList(id: .codexCLI)
        if let auth = CodexAuth.read(home: paths.codexDefaultHome) {
            list.systemDefault = AccountRow(
                id: Self.systemDefaultRowId,
                identity: auth.identity,
                plan: auth.plan
            )
        } else {
            list.systemDefault = AccountRow(
                id: Self.systemDefaultRowId,
                identity: AccountIdentity(email: ""),
                problem: "Not signed in"
            )
        }
        list.accounts = state.accounts.map { record in
            let auth = CodexAuth.read(home: home(for: record.id))
            return AccountRow(
                id: record.id,
                identity: record.identity,
                organizationName: record.organizationName,
                plan: auth?.plan ?? record.plan,
                addedAt: record.createdAt,
                problem: auth == nil ? "Signed out; re-authenticate" : nil
            )
        }
        list.selectedAccountId = state.activeAccountId
        return list
    }

    func usageCredentials() -> [UsageCredential] {
        var homes = [(Self.systemDefaultRowId, paths.codexDefaultHome)]
        homes += state.accounts.map { ($0.id, home(for: $0.id)) }
        let now = Date()
        return homes.compactMap { rowId, home in
            guard let auth = CodexAuth.read(home: home),
                  let token = auth.accessToken,
                  auth.accessTokenExpiry.map({ $0 > now }) ?? true
            else { return nil }
            return UsageCredential(
                rowId: rowId,
                identity: auth.identity,
                accessToken: token,
                accountId: auth.identity.organizationId
            )
        }
    }

    // MARK: - Actions

    @discardableResult
    func addAccount(onSignInURL: @escaping @Sendable (URL) -> Void) async throws -> ManagedAccountRecord {
        let id = UUID().uuidString
        let home = home(for: id)
        try createHome(home, accountId: id)
        do {
            let auth = try await signIn(home: home, onSignInURL: onSignInURL)
            if state.accounts.contains(where: { $0.identity.matches(auth.identity) }) {
                throw CodexAccountError.duplicate(auth.identity.email)
            }
            let now = Date()
            let record = ManagedAccountRecord(
                id: id,
                identity: auth.identity,
                plan: auth.plan,
                createdAt: now,
                lastAuthenticatedAt: now
            )
            update { state in
                state.accounts.append(record)
                state.activeAccountId = id
            }
            return record
        } catch {
            try? deleteHome(home)
            throw error
        }
    }

    func reauthenticate(_ accountId: String, onSignInURL: @escaping @Sendable (URL) -> Void) async throws {
        guard let record = state.accounts.first(where: { $0.id == accountId }) else {
            throw CodexAccountError.unknownAccount
        }
        let home = home(for: accountId)
        try createHome(home, accountId: accountId)
        let authFile = home.appendingPathComponent("auth.json")
        let previous = try? Data(contentsOf: authFile)

        func restorePrevious() {
            if let previous {
                try? AccountFiles.write(previous, to: authFile, permissions: 0o600)
            }
        }

        let auth: CodexAuth
        do {
            auth = try await signIn(home: home, onSignInURL: onSignInURL)
        } catch {
            restorePrevious()
            throw error
        }
        guard auth.identity.matches(record.identity) else {
            restorePrevious()
            throw CodexAccountError.wrongAccount(expected: record.identity.email, signedIn: auth.identity.email)
        }
        update { state in
            guard let index = state.accounts.firstIndex(where: { $0.id == accountId }) else { return }
            state.accounts[index].lastAuthenticatedAt = Date()
            state.accounts[index].plan = auth.plan ?? state.accounts[index].plan
        }
    }

    func select(_ accountId: String?) throws {
        if let accountId, !state.accounts.contains(where: { $0.id == accountId }) {
            throw CodexAccountError.unknownAccount
        }
        update { $0.activeAccountId = accountId }
    }

    func remove(_ accountId: String) throws {
        try deleteHome(home(for: accountId))
        update { state in
            state.accounts.removeAll { $0.id == accountId }
            if state.activeAccountId == accountId { state.activeAccountId = nil }
        }
    }

    // MARK: - Homes

    private func createHome(_ home: URL, accountId: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let marker = home.appendingPathComponent(Self.markerFile)
        if !fileManager.fileExists(atPath: marker.path) {
            try Data(accountId.utf8).write(to: marker)
        }
        try CodexHomeLinker.sync(home: home, source: paths.codexDefaultHome)
    }

    /// Deletes a managed home's account directory. The marker check keeps a
    /// bad id from ever pointing this at a directory Soprano did not create.
    private func deleteHome(_ home: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: home.path) else { return }
        guard fileManager.fileExists(atPath: home.appendingPathComponent(Self.markerFile).path) else {
            throw CodexAccountError.notManaged(home.path)
        }
        // Symlinks are removed as links; their ~/.codex targets are untouched.
        try fileManager.removeItem(at: home.deletingLastPathComponent())
    }

    private func signIn(home: URL, onSignInURL: @escaping @Sendable (URL) -> Void) async throws -> CodexAuth {
        let result = try await runner.runCLI(
            ["codex", "login"],
            environment: ["CODEX_HOME": home.path],
            timeout: 600,
            onOutputLine: { line in
                if let url = CommandRunner.firstURL(in: line) { onSignInURL(url) }
            }
        )
        guard result.succeeded else { throw CodexAccountError.loginFailed(result.failureMessage(running: "codex")) }
        guard let auth = CodexAuth.read(home: home) else { throw CodexAccountError.noCredentials }
        return auth
    }
}

/// Keeps a managed `CODEX_HOME` linked to `~/.codex`.
enum CodexHomeLinker {
    /// Entries that belong to one login and are never shared: the login
    /// itself, and the model list cached for that login's plan.
    static let accountEntries: Set<String> = [
        "auth.json", "models_cache.json", CodexAccountManager.markerFile, ".DS_Store",
    ]

    static func shouldShare(_ name: String) -> Bool {
        if accountEntries.contains(name) { return false }
        // SQLite finds its journals next to the real database through the
        // link, so links to them would only dangle; Codex's own temporary
        // files start with "..".
        if name.hasSuffix("-wal") || name.hasSuffix("-shm") || name.hasSuffix("-journal") { return false }
        return !name.hasPrefix("..")
    }

    /// Links every shareable entry of `source` into `home`.
    ///
    /// Codex saves some files by writing a new copy and renaming it over the
    /// old one, which replaces a link with a plain file. Such a file is folded
    /// back: the newer of the two copies wins, lands in `source`, and the link
    /// is restored, so a setting changed under one account reaches all.
    static func sync(home: URL, source: URL, fileManager: FileManager = .default) throws {
        guard let names = try? fileManager.contentsOfDirectory(atPath: source.path) else { return }
        for name in names where shouldShare(name) {
            let target = source.appendingPathComponent(name)
            let link = home.appendingPathComponent(name)
            let type = (try? fileManager.attributesOfItem(atPath: link.path))?[.type] as? FileAttributeType
            switch type {
            case nil:
                try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
            case .typeSymbolicLink?:
                if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != target.path {
                    try fileManager.removeItem(at: link)
                    try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
                }
            case .typeRegular?:
                let sharedCopy = target.resolvingSymlinksInPath()
                if modificationDate(link, fileManager) > modificationDate(sharedCopy, fileManager) {
                    let permissions = (try? fileManager.attributesOfItem(atPath: link.path))?[.posixPermissions]
                        as? NSNumber
                    try AccountFiles.write(
                        Data(contentsOf: link),
                        to: target,
                        permissions: mode_t(permissions?.uint16Value ?? 0o600)
                    )
                }
                try fileManager.removeItem(at: link)
                try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
            default:
                // A real directory Codex created here: its data, left alone.
                break
            }
        }
        // Links whose target has since been deleted.
        for name in (try? fileManager.contentsOfDirectory(atPath: home.path)) ?? [] {
            let link = home.appendingPathComponent(name)
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path),
                  !fileManager.fileExists(atPath: destination)
            else { continue }
            try? fileManager.removeItem(at: link)
        }
    }

    private static func modificationDate(_ url: URL, _ fileManager: FileManager) -> Date {
        ((try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }
}
