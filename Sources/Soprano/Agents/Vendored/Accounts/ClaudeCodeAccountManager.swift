import CryptoKit
import Foundation

enum ClaudeAccountError: LocalizedError {
    case loginFailed(String)
    case noCredentials
    case noIdentity
    case duplicate(String)
    case wrongAccount(expected: String, signedIn: String)
    case missingCredentials(String)
    case unknownAccount

    var errorDescription: String? {
        switch self {
        case .loginFailed(let message):
            return "Claude sign-in failed: \(message)"
        case .noCredentials:
            return "Claude Code finished signing in, but Soprano could not find the login it stored."
        case .noIdentity:
            return "Claude Code finished signing in, but did not say which account it signed in to."
        case .duplicate(let email):
            return "\(email) is already added."
        case .wrongAccount(let expected, let signedIn):
            return "Signed in as \(signedIn), not \(expected). Sign in to \(expected) in the browser and try again."
        case .missingCredentials(let email):
            return "Soprano no longer has the login for \(email). Re-authenticate it."
        case .unknownAccount:
            return "That account is no longer in the list."
        }
    }
}

/// Claude Code logins: several stored by Soprano, one in use for the whole Mac.
///
/// Claude Code reads its login from the Keychain item `Claude Code-credentials`
/// (filed under the user name) and names the account in `oauthAccount` in
/// `~/.claude.json`. Switching writes the chosen login's `claudeAiOauth` into
/// that item — keeping MCP tokens and anything else stored beside it — and its
/// `oauthAccount` into `~/.claude.json`. Running sessions pick the new login up
/// on their next credential read.
///
/// The login Claude Code had before Soprano first switched it is saved as the
/// System default and put back when that row is chosen. Claude Code refreshes
/// (and so rotates) tokens on its own; before every switch Soprano copies the
/// live tokens back to the account they belong to, proven by `oauthAccount` or
/// by asking Anthropic whose token it is.
@MainActor
final class ClaudeCodeAccountManager {
    /// Soprano's Keychain items: one per managed account, plus the System default.
    static let managedService = "Soprano Claude Code Accounts"
    static let liveService = "Claude Code-credentials"
    static let systemDefaultSlot = "system-default"
    static let systemDefaultRowId = "system-default"

    private let store: AccountStateStore
    private let keychain: KeychainCLI
    private let runner: CommandRunner
    private let paths: AccountPaths
    private let profile: @Sendable (String) async -> AccountIdentity?
    /// Every read-back and switch runs alone: two interleaved at their awaits
    /// could write one account's tokens into another's slot.
    private let queue = AsyncSerialQueue()

    init(
        store: AccountStateStore,
        keychain: KeychainCLI = KeychainCLI(),
        runner: CommandRunner = CommandRunner(),
        paths: AccountPaths = .live,
        profile: @escaping @Sendable (String) async -> AccountIdentity? = { token in
            try? await UsageAPI.claudeProfile(accessToken: token)
        }
    ) {
        self.store = store
        self.keychain = keychain
        self.runner = runner
        self.paths = paths
        self.profile = profile
    }

    private var state: ManagedAccountsState { store.state.claudeCode }

    private func update(_ change: (inout ManagedAccountsState) -> Void) {
        store.update { change(&$0.claudeCode) }
    }

    // MARK: - Keychain names

    /// The Keychain account Claude Code files its item under: the user name,
    /// or a fixed fallback for names it rejects (SSO user names with "@").
    static var keychainUser: String {
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let isValid = user.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil
        return isValid ? user : "claude-code-user"
    }

    /// The item Claude Code 2.1+ uses when `CLAUDE_CONFIG_DIR` points at
    /// `configDirectory`: the service suffixed with sha256(NFC(path))[0..<8].
    static func scopedService(configDirectory: String) -> String {
        let digest = SHA256.hash(data: Data(configDirectory.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(liveService)-\(hex.prefix(8))"
    }

    private var credentialsFile: URL {
        paths.claudeConfigDirectory.appendingPathComponent(".credentials.json")
    }

    // MARK: - Listing

    func list() async -> AccountList {
        (try? await queue.run { await self.listNow() }) ?? AccountList(id: .claudeCode)
    }

    private func listNow() async -> AccountList {
        var list = AccountList(id: .claudeCode)
        do {
            let live = try await readLive()
            try await reconcile(with: live)
            list.systemDefault = systemDefaultRow(live: live)
        } catch {
            list.unavailableReason = error.localizedDescription
        }
        list.accounts = state.accounts.map(Self.row)
        list.selectedAccountId = state.activeAccountId
        return list
    }

    /// Tokens that are still valid, for usage lookups: the live login (whoever
    /// is active) and each stored login that is not.
    func usageCredentials() async -> [UsageCredential] {
        var credentials: [UsageCredential] = []
        let now = Date()
        if let live = try? await readLive(),
           let oauth = live.oauth,
           let token = Self.validAccessToken(oauth, now: now),
           let identity = Self.identity(of: live.oauthAccount) {
            let rowId = state.activeAccountId ?? Self.systemDefaultRowId
            credentials.append(UsageCredential(rowId: rowId, identity: identity, accessToken: token))
        }
        for record in state.accounts where record.id != state.activeAccountId {
            guard let stored = try? await readManaged(record.id),
                  let token = Self.validAccessToken(stored.oauth, now: now)
            else { continue }
            credentials.append(UsageCredential(rowId: record.id, identity: record.identity, accessToken: token))
        }
        return credentials
    }

    // MARK: - Actions

    /// Signs in a new account in the browser and makes it the active one.
    @discardableResult
    func addAccount(onSignInURL: @escaping @Sendable (URL) -> Void) async throws -> ManagedAccountRecord {
        let login = try await signIn(onSignInURL: onSignInURL)
        return try await queue.run { try await self.commitNewAccount(login) }
    }

    func reauthenticate(_ accountId: String, onSignInURL: @escaping @Sendable (URL) -> Void) async throws {
        guard state.accounts.contains(where: { $0.id == accountId }) else {
            throw ClaudeAccountError.unknownAccount
        }
        let login = try await signIn(onSignInURL: onSignInURL)
        try await queue.run { try await self.commitReauthentication(accountId, login: login) }
    }

    /// Signs Claude Code in with `accountId`, or puts its own login back (nil).
    func select(_ accountId: String?) async throws {
        try await queue.run { try await self.selectNow(accountId) }
    }

    func remove(_ accountId: String) async throws {
        try await queue.run {
            if self.state.activeAccountId == accountId {
                try await self.selectNow(nil)
            }
            try await self.keychain.delete(service: Self.managedService, account: accountId)
            self.update { $0.accounts.removeAll { $0.id == accountId } }
        }
    }

    private func commitNewAccount(_ login: CapturedLogin) async throws -> ManagedAccountRecord {
        if state.accounts.contains(where: { $0.identity.matches(login.identity) }) {
            throw ClaudeAccountError.duplicate(login.identity.email)
        }
        let now = Date()
        let record = ManagedAccountRecord(
            id: UUID().uuidString,
            identity: login.identity,
            organizationName: login.organizationName,
            plan: login.plan,
            createdAt: now,
            lastAuthenticatedAt: now
        )
        try await writeManaged(record.id, oauth: login.oauth, oauthAccount: login.oauthAccount)
        update { $0.accounts.append(record) }
        try await selectNow(record.id)
        return record
    }

    private func commitReauthentication(_ accountId: String, login: CapturedLogin) async throws {
        guard let record = state.accounts.first(where: { $0.id == accountId }) else {
            throw ClaudeAccountError.unknownAccount
        }
        guard login.identity.matches(record.identity) else {
            throw ClaudeAccountError.wrongAccount(expected: record.identity.email, signedIn: login.identity.email)
        }
        try await writeManaged(accountId, oauth: login.oauth, oauthAccount: login.oauthAccount)
        update { state in
            guard let index = state.accounts.firstIndex(where: { $0.id == accountId }) else { return }
            state.accounts[index].lastAuthenticatedAt = Date()
            state.accounts[index].plan = login.plan ?? state.accounts[index].plan
            state.accounts[index].organizationName = login.organizationName ?? state.accounts[index].organizationName
        }
        if state.activeAccountId == accountId {
            let live = try await readLive()
            try await writeLive(oauth: login.oauth, oauthAccount: login.oauthAccount, over: live)
        }
    }

    private func selectNow(_ accountId: String?) async throws {
        let live = try await readLive()
        try await reconcile(with: live)
        guard accountId != state.activeAccountId else { return }

        if let accountId {
            guard let record = state.accounts.first(where: { $0.id == accountId }) else {
                throw ClaudeAccountError.unknownAccount
            }
            guard let stored = try await readManaged(accountId) else {
                throw ClaudeAccountError.missingCredentials(record.identity.email)
            }
            if state.activeAccountId == nil {
                try await saveSystemDefault(live)
            }
            try await writeLive(oauth: stored.oauth, oauthAccount: stored.oauthAccount, over: live)
            update { $0.activeAccountId = accountId }
        } else {
            // Without a saved System default there is nothing to put back;
            // leave Claude Code signed in rather than signing it out.
            if let snapshot = try await readSnapshot() {
                try await writeLive(oauth: snapshot.oauth, oauthAccount: snapshot.oauthAccount, over: live)
            }
            update { $0.activeAccountId = nil }
        }
    }

    // MARK: - Live login

    /// What Claude Code is signed in with now. `blob` is the whole Keychain
    /// item, so a switch can keep everything but `claudeAiOauth`.
    struct LiveLogin {
        var blob: [String: Any]
        var oauthAccount: [String: Any]?
        var oauth: [String: Any]? { blob["claudeAiOauth"] as? [String: Any] }
    }

    private func readLive() async throws -> LiveLogin {
        var blob: [String: Any] = [:]
        if let secret = try await keychain.read(service: Self.liveService, account: Self.keychainUser) {
            blob = AccountFiles.jsonObject(secret) ?? [:]
        } else if let fileBlob = try AccountFiles.jsonObject(at: credentialsFile) {
            blob = fileBlob
        }
        let config = try AccountFiles.jsonObject(at: paths.claudeGlobalConfigFile)
        return LiveLogin(blob: blob, oauthAccount: config?["oauthAccount"] as? [String: Any])
    }

    /// Puts `oauth` (nil: signed out) and `oauthAccount` where Claude Code reads them.
    private func writeLive(oauth: [String: Any]?, oauthAccount: [String: Any]?, over live: LiveLogin) async throws {
        let user = Self.keychainUser
        let secret = try AccountFiles.jsonString(Self.replacingOauth(in: live.blob, with: oauth))
        try await keychain.write(service: Self.liveService, account: user, secret: secret)

        // Claude Code reads a config-scoped item instead when CLAUDE_CONFIG_DIR
        // is set; keep the one for ~/.claude current when it exists.
        let scoped = Self.scopedService(configDirectory: paths.claudeConfigDirectory.path)
        if let scopedSecret = try await keychain.read(service: scoped, account: user) {
            let scopedBlob = AccountFiles.jsonObject(scopedSecret) ?? [:]
            let updated = try AccountFiles.jsonString(Self.replacingOauth(in: scopedBlob, with: oauth))
            try await keychain.write(service: scoped, account: user, secret: updated)
        }

        // The plaintext copy Claude Code falls back to without a Keychain.
        if let fileBlob = try AccountFiles.jsonObject(at: credentialsFile) {
            let data = try AccountFiles.jsonData(Self.replacingOauth(in: fileBlob, with: oauth))
            try AccountFiles.write(data, to: credentialsFile, permissions: 0o600)
        }

        try writeOauthAccount(oauthAccount)
    }

    private func writeOauthAccount(_ oauthAccount: [String: Any]?) throws {
        let url = paths.claudeGlobalConfigFile
        var config = try AccountFiles.jsonObject(at: url) ?? [:]
        if config.isEmpty && oauthAccount == nil { return }
        config["oauthAccount"] = oauthAccount
        try AccountFiles.write(AccountFiles.jsonData(config, pretty: true), to: url, permissions: 0o600)
    }

    /// `blob` with its Claude login swapped. Every other key — MCP OAuth
    /// tokens, plugin secrets — belongs to this Mac, not to the account.
    static func replacingOauth(in blob: [String: Any], with oauth: [String: Any]?) -> [String: Any] {
        var updated = blob
        updated["claudeAiOauth"] = oauth
        return updated
    }

    // MARK: - Reconciliation

    /// Keeps Soprano's copy of the active login in step with Claude Code.
    ///
    /// When the live tokens differ from the stored ones, Claude Code either
    /// refreshed them — they are the active account's newest tokens and must
    /// be kept, since the stored refresh token is now spent — or someone signed
    /// Claude Code in to another account, which then becomes the System default.
    private func reconcile(with live: LiveLogin) async throws {
        guard let active = state.activeAccount else { return }
        let stored = try await readManaged(active.id)

        guard let liveOauth = live.oauth else {
            // Signed out under us (`claude auth logout`): that is Claude Code's own state now.
            try await saveSystemDefault(live)
            update { $0.activeAccountId = nil }
            return
        }
        if Self.sameTokens(liveOauth, stored?.oauth) { return }

        if let claimed = Self.identity(of: live.oauthAccount), claimed.matches(active.identity) {
            try await writeManaged(active.id, oauth: liveOauth, oauthAccount: live.oauthAccount)
            return
        }
        // `oauthAccount` names someone else; only the token itself can say who it is.
        guard let token = Self.validAccessToken(liveOauth, now: Date()),
              let owner = await profile(token)
        else { return }
        if owner.matches(active.identity) {
            try await writeManaged(active.id, oauth: liveOauth, oauthAccount: stored?.oauthAccount ?? live.oauthAccount)
            if let oauthAccount = stored?.oauthAccount {
                try writeOauthAccount(oauthAccount)
            }
        } else {
            try await saveSystemDefault(live)
            update { $0.activeAccountId = nil }
        }
    }

    // MARK: - Soprano's Keychain items

    private struct StoredLogin {
        var oauth: [String: Any]?
        var oauthAccount: [String: Any]?
    }

    private func readManaged(_ accountId: String) async throws -> StoredLogin? {
        try await readStored(account: accountId)
    }

    private func writeManaged(_ accountId: String, oauth: [String: Any]?, oauthAccount: [String: Any]?) async throws {
        try await writeStored(account: accountId, oauth: oauth, oauthAccount: oauthAccount)
    }

    private func readSnapshot() async throws -> StoredLogin? {
        try await readStored(account: Self.systemDefaultSlot)
    }

    /// Saves Claude Code's own login, to put back when System default is chosen.
    private func saveSystemDefault(_ live: LiveLogin) async throws {
        try await writeStored(account: Self.systemDefaultSlot, oauth: live.oauth, oauthAccount: live.oauthAccount)
        update { $0.systemDefault = Self.record(oauthAccount: live.oauthAccount, oauth: live.oauth) }
    }

    private func readStored(account: String) async throws -> StoredLogin? {
        guard let secret = try await keychain.read(service: Self.managedService, account: account),
              let object = AccountFiles.jsonObject(secret)
        else { return nil }
        return StoredLogin(
            oauth: object["claudeAiOauth"] as? [String: Any],
            oauthAccount: object["oauthAccount"] as? [String: Any]
        )
    }

    private func writeStored(account: String, oauth: [String: Any]?, oauthAccount: [String: Any]?) async throws {
        var object: [String: Any] = [:]
        object["claudeAiOauth"] = oauth ?? NSNull()
        object["oauthAccount"] = oauthAccount ?? NSNull()
        try await keychain.write(
            service: Self.managedService,
            account: account,
            secret: AccountFiles.jsonString(object)
        )
    }

    // MARK: - Sign-in

    private struct CapturedLogin {
        var oauth: [String: Any]
        var oauthAccount: [String: Any]
        var identity: AccountIdentity
        var organizationName: String?
        var plan: String?
    }

    /// Runs `claude auth login` against a throwaway config directory, so the
    /// login lands in that directory's own Keychain item and never touches the
    /// one Claude Code is using; Soprano copies it out and deletes the rest.
    private func signIn(onSignInURL: @escaping @Sendable (URL) -> Void) async throws -> CapturedLogin {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("soprano-claude-login-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Claude Code hashes the path it is given into the Keychain item name;
        // the temporary directory lives behind the /var → /private/var link, so
        // give it the resolved path and look up that same name afterwards.
        let configDirectory = directory.resolvingSymlinksInPath().path
        let scoped = Self.scopedService(configDirectory: configDirectory)
        let environment = [
            "CLAUDE_CONFIG_DIR": configDirectory,
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": configDirectory,
        ]

        func cleanUp() async {
            try? await keychain.delete(service: scoped, account: Self.keychainUser)
            try? fileManager.removeItem(at: directory)
        }

        do {
            let result = try await runner.runCLI(
                ["claude", "auth", "login", "--claudeai"],
                environment: environment,
                timeout: 600,
                keepStandardInputOpen: true,
                onOutputLine: { line in
                    if let url = CommandRunner.firstURL(in: line) { onSignInURL(url) }
                }
            )
            guard result.succeeded else {
                throw ClaudeAccountError.loginFailed(result.failureMessage(running: "claude"))
            }

            var blob: [String: Any]?
            if let secret = try await keychain.read(service: scoped, account: Self.keychainUser) {
                blob = AccountFiles.jsonObject(secret)
            }
            if blob == nil {
                blob = try? AccountFiles.jsonObject(at: directory.appendingPathComponent(".credentials.json"))
            }
            guard let oauth = blob?["claudeAiOauth"] as? [String: Any],
                  oauth["refreshToken"] is String
            else { throw ClaudeAccountError.noCredentials }

            var oauthAccount: [String: Any]?
            for name in [".claude.json", ".config.json"] where oauthAccount == nil {
                let config = try? AccountFiles.jsonObject(at: directory.appendingPathComponent(name))
                oauthAccount = config?["oauthAccount"] as? [String: Any]
            }
            if oauthAccount == nil {
                oauthAccount = try await statusAccount(environment: environment)
            }
            guard let oauthAccount, let identity = Self.identity(of: oauthAccount) else {
                throw ClaudeAccountError.noIdentity
            }
            await cleanUp()
            return CapturedLogin(
                oauth: oauth,
                oauthAccount: oauthAccount,
                identity: identity,
                organizationName: oauthAccount["organizationName"] as? String,
                plan: oauth["subscriptionType"] as? String
            )
        } catch {
            await cleanUp()
            throw error
        }
    }

    /// `claude auth status --json` as an `oauthAccount`, for a login whose
    /// config file did not record one.
    private func statusAccount(environment: [String: String]) async throws -> [String: Any]? {
        let result = try await runner.runCLI(["claude", "auth", "status", "--json"], environment: environment, timeout: 60)
        guard result.succeeded,
              let start = result.stdout.firstIndex(of: "{"),
              let status = AccountFiles.jsonObject(String(result.stdout[start...])),
              let email = status["email"] as? String
        else { return nil }
        var account: [String: Any] = ["emailAddress": email]
        account["organizationUuid"] = status["orgId"] as? String
        account["organizationName"] = status["orgName"] as? String
        return account
    }

    // MARK: - Helpers

    static func identity(of oauthAccount: [String: Any]?) -> AccountIdentity? {
        guard let email = oauthAccount?["emailAddress"] as? String, !email.isEmpty else { return nil }
        return AccountIdentity(email: email, organizationId: oauthAccount?["organizationUuid"] as? String)
    }

    static func sameTokens(_ left: [String: Any]?, _ right: [String: Any]?) -> Bool {
        guard let left, let right else { return left == nil && right == nil }
        return left["refreshToken"] as? String == right["refreshToken"] as? String
            && left["accessToken"] as? String == right["accessToken"] as? String
    }

    /// The access token, unless `expiresAt` (epoch milliseconds) has passed.
    static func validAccessToken(_ oauth: [String: Any]?, now: Date) -> String? {
        guard let token = oauth?["accessToken"] as? String, !token.isEmpty else { return nil }
        if let expiresAt = UsageAPI.number(oauth?["expiresAt"]),
           Date(timeIntervalSince1970: expiresAt / 1000) <= now {
            return nil
        }
        return token
    }

    private static func record(oauthAccount: [String: Any]?, oauth: [String: Any]?) -> ManagedAccountRecord? {
        guard let identity = identity(of: oauthAccount) else { return nil }
        let now = Date()
        return ManagedAccountRecord(
            id: systemDefaultRowId,
            identity: identity,
            organizationName: oauthAccount?["organizationName"] as? String,
            plan: oauth?["subscriptionType"] as? String,
            createdAt: now,
            lastAuthenticatedAt: now
        )
    }

    private func systemDefaultRow(live: LiveLogin) -> AccountRow {
        let record = state.activeAccountId == nil
            ? Self.record(oauthAccount: live.oauthAccount, oauth: live.oauth)
            : state.systemDefault
        guard let record else {
            return AccountRow(
                id: Self.systemDefaultRowId,
                identity: AccountIdentity(email: ""),
                problem: "Not signed in"
            )
        }
        return Self.row(record)
    }

    private static func row(_ record: ManagedAccountRecord) -> AccountRow {
        AccountRow(
            id: record.id,
            identity: record.identity,
            organizationName: record.organizationName,
            plan: record.plan,
            addedAt: record.id == systemDefaultRowId ? nil : record.createdAt
        )
    }
}
