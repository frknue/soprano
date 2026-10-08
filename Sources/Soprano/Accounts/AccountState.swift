import Foundation

/// Where account data lives on disk.
struct AccountPaths: Sendable {
    /// The user's home: Claude Code and the Codex CLI keep their own login under it.
    var home: URL
    /// Soprano's account data: managed Codex homes and the omp preference overlay.
    var supportDirectory: URL

    var claudeConfigDirectory: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    /// Claude Code's global config, which carries the signed-in `oauthAccount`.
    var claudeGlobalConfigFile: URL { home.appendingPathComponent(".claude.json") }
    var codexDefaultHome: URL { home.appendingPathComponent(".codex", isDirectory: true) }
    var codexAccountsDirectory: URL {
        supportDirectory.appendingPathComponent("codex-accounts", isDirectory: true)
    }
    /// Passed to every omp agent pane with `--config`; holds the preferred accounts.
    var ompOverlayFile: URL { supportDirectory.appendingPathComponent("omp-accounts.yml") }

    static let live: AccountPaths = {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        // Dev and installed builds have their own bundle ids, so neither one
        // touches the other's managed homes.
        let name = Bundle.main.bundleIdentifier ?? "Soprano"
        return AccountPaths(
            home: fileManager.homeDirectoryForCurrentUser,
            supportDirectory: applicationSupport.appendingPathComponent(name, isDirectory: true)
        )
    }()
}

/// A login Soprano manages for Claude Code or the Codex CLI.
struct ManagedAccountRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var identity: AccountIdentity
    var organizationName: String?
    var plan: String?
    var createdAt: Date
    var lastAuthenticatedAt: Date
}

/// One CLI's managed logins and which of them is in use.
struct ManagedAccountsState: Codable, Equatable, Sendable {
    var accounts: [ManagedAccountRecord] = []
    /// nil: the CLI uses its own login ("System default").
    var activeAccountId: String?
    /// Who the CLI's own login belonged to when Soprano last switched away
    /// from it, so the System default row can still name it.
    var systemDefault: ManagedAccountRecord?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decodeIfPresent([ManagedAccountRecord].self, forKey: .accounts) ?? []
        activeAccountId = try container.decodeIfPresent(String.self, forKey: .activeAccountId)
        systemDefault = try container.decodeIfPresent(ManagedAccountRecord.self, forKey: .systemDefault)
    }

    var activeAccount: ManagedAccountRecord? {
        activeAccountId.flatMap { id in accounts.first { $0.id == id } }
    }
}

/// The account omp should try first for one provider.
struct OmpPreference: Codable, Equatable, Sendable {
    /// Exactly as omp reports them: omp's account policies compare as written.
    var email: String
    var orgId: String?
    /// Only recognizes the row; the policy selects by email and org.
    var accountId: String?
}

/// Account bookkeeping. Credentials never live here: Claude Code logins are in
/// the Keychain, Codex logins in their managed homes, omp logins in omp.
struct AccountState: Codable, Equatable, Sendable {
    var claudeCode = ManagedAccountsState()
    var codexCLI = ManagedAccountsState()
    /// omp provider id → preferred account; absent means automatic balancing.
    var ompPreferred: [String: OmpPreference] = [:]

    init() {}

    /// Decoded by hand so a payload written before a key existed still loads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claudeCode = try container.decodeIfPresent(ManagedAccountsState.self, forKey: .claudeCode) ?? .init()
        codexCLI = try container.decodeIfPresent(ManagedAccountsState.self, forKey: .codexCLI) ?? .init()
        ompPreferred = try container.decodeIfPresent([String: OmpPreference].self, forKey: .ompPreferred) ?? [:]
    }
}

/// Persists `AccountState` in UserDefaults, like the rest of Soprano's app state.
@MainActor
final class AccountStateStore {
    private static let key = "soprano-accounts"
    private let defaults: UserDefaults
    private(set) var state: AccountState

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AccountState.self, from: data) {
            state = decoded
        } else {
            state = AccountState()
        }
    }

    func update(_ change: (inout AccountState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
