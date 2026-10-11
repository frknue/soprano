import Foundation
import SQLite3

enum OmpAccountError: LocalizedError {
    case unavailable(String)
    case loginFailed(String)
    case notStored(String)
    case unsupportedStore(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return "omp: \(message)"
        case .loginFailed(let message):
            return "omp sign-in failed: \(message)"
        case .notStored(let email):
            return "omp has no login for \(email) any more."
        case .unsupportedStore(let detail):
            return "This omp version stores logins differently (\(detail)). Remove the account with /logout in omp."
        }
    }
}

/// One omp login as `omp usage --json` reports it.
struct OmpAccount: Equatable, Sendable {
    var provider: AccountProvider
    /// As omp stores it; omp's account policies compare it exactly.
    var email: String
    var accountId: String?
    var orgId: String?
    var orgName: String?
    var plan: String?
    var usage: AccountUsage?

    /// Claude: the organization UUID. Codex: omp files the ChatGPT workspace as
    /// the org, and as the account id.
    var identity: AccountIdentity {
        AccountIdentity(email: email, organizationId: orgId ?? accountId)
    }
}

/// omp's logins. omp keeps any number per provider in its own database and
/// balances across them; Soprano lists them with their usage, adds them with
/// `omp login`, removes them, and marks one preferred through a config overlay
/// every omp agent pane loads with `--config`.
@MainActor
final class OmpAccountManager {
    private let store: AccountStateStore
    private let runner: CommandRunner
    private let paths: AccountPaths
    private var agentDirectory: URL?
    /// The logins from the last successful `omp usage --json`.
    private var accounts: [OmpAccount] = []

    init(store: AccountStateStore, runner: CommandRunner = CommandRunner(), paths: AccountPaths = .live) {
        self.store = store
        self.runner = runner
        self.paths = paths
    }

    // MARK: - Listing

    /// Both providers' lists from one `omp usage --json` run (it also fetches
    /// fresh usage, which omp caches for five minutes).
    func lists() async -> [AccountList] {
        let ids: [AccountListID] = [.ompClaude, .ompCodex]
        let accounts: [OmpAccount]
        do {
            let result = try await runner.runCLI(["omp", "usage", "--json"], timeout: 90)
            guard result.succeeded else {
                throw OmpAccountError.unavailable(result.failureMessage(running: "omp"))
            }
            accounts = try Self.parseUsage(Data(result.stdout.utf8))
        } catch {
            return ids.map { id in
                var list = AccountList(id: id)
                list.unavailableReason = error.localizedDescription
                list.selectedAccountId = store.state.ompPreferred[id.provider.ompProviderId].map(Self.rowId)
                return list
            }
        }
        self.accounts = accounts
        prunePreferences(keeping: accounts)
        return ids.map { id in
            var list = AccountList(id: id)
            list.accounts = accounts.filter { $0.provider == id.provider }.map { account in
                AccountRow(
                    id: account.identity.key,
                    identity: account.identity,
                    organizationName: account.orgName,
                    plan: account.plan,
                    usage: account.usage
                )
            }
            list.selectedAccountId = store.state.ompPreferred[id.provider.ompProviderId].map(Self.rowId)
            return list
        }
    }

    /// Drops a preference whose account omp no longer has: omp rejects a
    /// policy that matches no stored login, which would fail every request.
    private func prunePreferences(keeping accounts: [OmpAccount]) {
        let stale = store.state.ompPreferred.filter { providerId, preference in
            !accounts.contains { account in
                account.provider.ompProviderId == providerId && Self.matches(account, preference)
            }
        }
        guard !stale.isEmpty else { return }
        store.update { state in
            for providerId in stale.keys { state.ompPreferred.removeValue(forKey: providerId) }
        }
        try? writeOverlay()
    }

    // MARK: - Actions

    /// `omp login <provider>`. The browser's signed-in account decides which
    /// login omp stores: the same account is refreshed in place, another one
    /// is added beside it.
    func signIn(provider: AccountProvider, onSignInURL: @escaping @Sendable (URL) -> Void) async throws {
        let result = try await runner.runCLI(
            ["omp", "login", provider.ompProviderId],
            timeout: 600,
            keepStandardInputOpen: true,
            onOutputLine: { line in
                if let url = CommandRunner.firstURL(in: line) { onSignInURL(url) }
            }
        )
        guard result.succeeded else { throw OmpAccountError.loginFailed(result.failureMessage(running: "omp")) }
    }

    /// Marks the login `rowId` preferred (nil: automatic balancing) for new
    /// omp panes; running omp panes reload the overlay and apply it to their
    /// next new session.
    func select(rowId: String?, provider: AccountProvider) throws {
        guard let rowId else {
            store.update { $0.ompPreferred.removeValue(forKey: provider.ompProviderId) }
            try writeOverlay()
            return
        }
        guard let account = account(rowId, provider: provider) else { throw OmpAccountError.notStored(rowId) }
        store.update { $0.ompPreferred[provider.ompProviderId] = Self.preference(for: account) }
        try writeOverlay()
    }

    /// Signs omp out of one account, the way omp's own `/logout` does: the
    /// login is marked deleted in omp's database, and running omp processes
    /// notice on their next request.
    func remove(rowId: String, provider: AccountProvider) async throws {
        guard let account = account(rowId, provider: provider) else { throw OmpAccountError.notStored(rowId) }
        if let preference = store.state.ompPreferred[provider.ompProviderId], Self.rowId(preference) == rowId {
            try select(rowId: nil, provider: provider)
            // omp refuses to drop a login that a loaded policy still names;
            // give running panes a moment to reload the overlay first.
            try await Task.sleep(for: .milliseconds(1500))
        }
        let database = try await agentDirectoryURL().appendingPathComponent("agent.db")
        let removed = try Self.softDeleteLogin(
            databasePath: database.path,
            providerId: provider.ompProviderId,
            identity: account.identity
        )
        guard removed else { throw OmpAccountError.notStored(account.email) }
    }

    private func account(_ rowId: String, provider: AccountProvider) -> OmpAccount? {
        accounts.first { $0.provider == provider && $0.identity.key == rowId }
    }

    // MARK: - Overlay

    /// Writes the `--config` overlay from the stored preferences; untouched
    /// when nothing changed, so omp does not reload for nothing.
    func writeOverlay() throws {
        let preferences = store.state.ompPreferred.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        let text = Self.overlay(preferences: preferences)
        let url = paths.ompOverlayFile
        if let current = try? String(contentsOf: url, encoding: .utf8), current == text { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try AccountFiles.write(Data(text.utf8), to: url, permissions: 0o644)
    }

    /// omp's `auth.accountPolicies`: a positive priority puts the account
    /// ahead of its siblings while it has allowance left; when it runs out,
    /// omp fails over to the others as usual.
    nonisolated static func overlay(preferences: [(providerId: String, preference: OmpPreference)]) -> String {
        var lines = [
            "# Written by Soprano (Settings → Accounts); edits here are overwritten.",
            "# Soprano starts omp agent panes with --config pointing at this file.",
        ]
        guard !preferences.isEmpty else {
            lines.append("{}")
            return lines.joined(separator: "\n") + "\n"
        }
        lines += ["auth:", "  accountPolicies:"]
        for (providerId, preference) in preferences {
            lines.append("    - provider: \(yamlQuoted(providerId))")
            lines.append("      account:")
            lines.append("        email: \(yamlQuoted(preference.email))")
            if let orgId = preference.orgId {
                lines.append("        orgId: \(yamlQuoted(orgId))")
            }
            lines.append("      priority: 100")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private nonisolated static func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - omp's database

    private func agentDirectoryURL() async throws -> URL {
        if let agentDirectory { return agentDirectory }
        let result = try await runner.runCLI(["omp", "config", "path"], timeout: 60)
        let path = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
        guard result.succeeded, let path else {
            throw OmpAccountError.unavailable(result.failureMessage(running: "omp"))
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        agentDirectory = url
        return url
    }

    /// Marks the matching OAuth login deleted, exactly as omp's `removeById`
    /// does (`disabled_cause = 'deleted by user'`). The row's identity key is
    /// `email:<lowercased email>|org:<org id>`. Returns false when no active
    /// login matches.
    nonisolated static func softDeleteLogin(
        databasePath: String,
        providerId: String,
        identity: AccountIdentity
    ) throws -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database
        else {
            sqlite3_close(database)
            throw OmpAccountError.unavailable("could not open \(databasePath)")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5000)

        let required: Set<String> = ["id", "provider", "credential_type", "identity_key", "disabled_cause", "updated_at"]
        let columns = try strings(database, "PRAGMA table_info(auth_credentials)", column: 1)
        guard required.isSubset(of: Set(columns)) else {
            throw OmpAccountError.unsupportedStore("auth_credentials lacks \(required.subtracting(columns).sorted().joined(separator: ", "))")
        }

        var select: OpaquePointer?
        let query = """
            SELECT id, identity_key FROM auth_credentials
            WHERE provider = ? AND credential_type = 'oauth' AND disabled_cause IS NULL
            """
        guard sqlite3_prepare_v2(database, query, -1, &select, nil) == SQLITE_OK else {
            throw OmpAccountError.unsupportedStore(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(select) }
        sqlite3_bind_text(select, 1, providerId, -1, sqliteTransient)
        var matches: [Int64] = []
        while sqlite3_step(select) == SQLITE_ROW {
            guard let text = sqlite3_column_text(select, 1) else { continue }
            if identityKey(String(cString: text), matches: identity) {
                matches.append(sqlite3_column_int64(select, 0))
            }
        }
        guard matches.count == 1, let id = matches.first else {
            if matches.count > 1 {
                throw OmpAccountError.unsupportedStore("\(matches.count) logins match \(identity.email)")
            }
            return false
        }

        var update: OpaquePointer?
        let statement = """
            UPDATE auth_credentials
            SET disabled_cause = 'deleted by user', updated_at = CAST(strftime('%s','now') AS INTEGER)
            WHERE id = ? AND disabled_cause IS NULL
            """
        guard sqlite3_prepare_v2(database, statement, -1, &update, nil) == SQLITE_OK else {
            throw OmpAccountError.unsupportedStore(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(update) }
        sqlite3_bind_int64(update, 1, id)
        guard sqlite3_step(update) == SQLITE_DONE else {
            throw OmpAccountError.unavailable(String(cString: sqlite3_errmsg(database)))
        }
        return sqlite3_changes(database) == 1
    }

    /// omp identity keys are `|`-joined `kind:value` parts, e.g.
    /// `email:a@b.c|org:1234`; emails are stored lowercased.
    nonisolated static func identityKey(_ key: String, matches identity: AccountIdentity) -> Bool {
        var parts: [String: String] = [:]
        for part in key.split(separator: "|") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            parts[String(part[..<colon])] = String(part[part.index(after: colon)...])
        }
        guard parts["email"] == identity.email.lowercased() else { return false }
        guard let organizationId = identity.organizationId else { return true }
        return parts["org"] == organizationId || parts["account"] == organizationId
    }

    private nonisolated static func strings(_ database: OpaquePointer, _ query: String, column: Int32) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            throw OmpAccountError.unsupportedStore(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, column) {
                values.append(String(cString: text))
            }
        }
        return values
    }

    private nonisolated static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Parsing

    /// Every OAuth account in `omp usage --json`: those with a usage report and
    /// those omp could not fetch usage for (`accountsWithoutUsage`).
    nonisolated static func parseUsage(_ data: Data) throws -> [OmpAccount] {
        // Shell start-up noise can precede the JSON document.
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.firstIndex(of: "{"),
              let object = (try? JSONSerialization.jsonObject(with: Data(text[start...].utf8))) as? [String: Any]
        else { throw OmpAccountError.unavailable("`omp usage --json` printed no usage report.") }

        var accounts: [OmpAccount] = []
        for report in object["reports"] as? [[String: Any]] ?? [] {
            guard let providerId = report["provider"] as? String,
                  let provider = AccountProvider(ompProviderId: providerId),
                  let metadata = report["metadata"] as? [String: Any],
                  let email = metadata["email"] as? String, !email.isEmpty
            else { continue }
            let fetchedAt = UsageAPI.number(report["fetchedAt"]).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            let windows = (report["limits"] as? [[String: Any]] ?? []).compactMap(window)
            let account = OmpAccount(
                provider: provider,
                email: email,
                accountId: metadata["accountId"] as? String,
                orgId: metadata["orgId"] as? String,
                orgName: metadata["orgName"] as? String,
                plan: metadata["planType"] as? String,
                usage: windows.isEmpty ? nil : AccountUsage(windows: windows, fetchedAt: fetchedAt)
            )
            if !accounts.contains(where: { $0.provider == provider && $0.identity.key == account.identity.key }) {
                accounts.append(account)
            }
        }
        for entry in object["accountsWithoutUsage"] as? [[String: Any]] ?? [] {
            guard let providerId = entry["provider"] as? String,
                  let provider = AccountProvider(ompProviderId: providerId),
                  let email = entry["email"] as? String, !email.isEmpty
            else { continue }
            let account = OmpAccount(
                provider: provider,
                email: email,
                accountId: entry["accountId"] as? String,
                orgId: entry["orgId"] as? String,
                orgName: entry["orgName"] as? String
            )
            if !accounts.contains(where: { $0.provider == provider && $0.identity.key == account.identity.key }) {
                accounts.append(account)
            }
        }
        return accounts
    }

    /// A percentage limit as a window: "5h", "7d", or "7d fable" for a
    /// model-scoped one. Dollar-denominated limits (extra usage) are skipped.
    private nonisolated static func window(_ limit: [String: Any]) -> UsageWindow? {
        let amount = limit["amount"] as? [String: Any]
        if let unit = amount?["unit"] as? String, unit != "percent" { return nil }
        let usedFraction = UsageAPI.number(amount?["usedFraction"])
            ?? UsageAPI.number(amount?["used"]).map { $0 / 100 }
        guard let usedFraction else { return nil }
        let window = limit["window"] as? [String: Any]
        let scope = limit["scope"] as? [String: Any]
        var label = (window?["id"] as? String) ?? (window?["label"] as? String) ?? (limit["label"] as? String) ?? "limit"
        if let tier = scope?["tier"] as? String, !tier.isEmpty {
            label += " \(tier)"
        }
        return UsageWindow(
            label: label,
            usedFraction: usedFraction,
            resetsAt: UsageAPI.number(window?["resetsAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    // MARK: - Helpers

    /// The policy selector omp matches exactly: its own email and org fields.
    static func preference(for account: OmpAccount) -> OmpPreference {
        OmpPreference(email: account.email, orgId: account.orgId, accountId: account.accountId)
    }

    static func rowId(_ preference: OmpPreference) -> String {
        AccountIdentity(email: preference.email, organizationId: preference.orgId ?? preference.accountId).key
    }

    private static func matches(_ account: OmpAccount, _ preference: OmpPreference) -> Bool {
        account.email == preference.email && account.orgId == preference.orgId
    }
}
