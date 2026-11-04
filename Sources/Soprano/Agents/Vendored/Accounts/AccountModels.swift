import Foundation

/// A subscription Soprano can hold several logins for.
enum AccountProvider: String, CaseIterable, Codable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// The provider id omp stores this subscription's OAuth logins under.
    var ompProviderId: String {
        switch self {
        case .claude: return "anthropic"
        case .codex: return "openai-codex"
        }
    }

    init?(ompProviderId: String) {
        guard let provider = Self.allCases.first(where: { $0.ompProviderId == ompProviderId }) else {
            return nil
        }
        self = provider
    }
}

/// The program an account list feeds.
enum AccountTool: String, CaseIterable, Codable, Sendable {
    /// omp keeps every login of a provider and balances across them.
    case omp
    /// The `claude` CLI: one login at a time, switched for the whole Mac.
    case claudeCode
    /// The `codex` CLI: one login per `CODEX_HOME`, chosen when a pane starts.
    case codexCLI

    var displayName: String {
        switch self {
        case .omp: return "omp"
        case .claudeCode: return "Claude Code"
        case .codexCLI: return "Codex CLI"
        }
    }
}

/// One account list on screen: a tool's logins for one provider.
struct AccountListID: Hashable, Sendable {
    let tool: AccountTool
    let provider: AccountProvider

    static let ompClaude = AccountListID(tool: .omp, provider: .claude)
    static let ompCodex = AccountListID(tool: .omp, provider: .codex)
    static let claudeCode = AccountListID(tool: .claudeCode, provider: .claude)
    static let codexCLI = AccountListID(tool: .codexCLI, provider: .codex)

    /// Display order. omp leads each provider because most panes run it.
    static let all: [AccountListID] = [.ompClaude, .claudeCode, .ompCodex, .codexCLI]
}

/// Who a login belongs to. The organization is part of it: one email can hold
/// a personal and a team subscription, and those are separate accounts with
/// separate limits.
struct AccountIdentity: Hashable, Codable, Sendable {
    var email: String
    /// Claude: the organization UUID. Codex: the ChatGPT account (workspace) id.
    var organizationId: String?

    /// Emails compare case-insensitively; the organization exactly.
    var key: String { "\(email.lowercased())|\(organizationId ?? "")" }

    /// Same person and, when both sides know it, the same organization.
    func matches(_ other: AccountIdentity) -> Bool {
        guard email.caseInsensitiveCompare(other.email) == .orderedSame else { return false }
        guard let organizationId, let otherOrganizationId = other.organizationId else { return true }
        return organizationId == otherOrganizationId
    }
}

/// One rate-limit window, such as the 5-hour or the weekly limit.
struct UsageWindow: Equatable, Codable, Sendable {
    /// Short label: "5h", "7d", "7d opus".
    var label: String
    /// Share of the window used: 0…1, above 1 when a plan allows overage.
    var usedFraction: Double
    var resetsAt: Date?
}

/// The provider's rate-limit report for one account.
struct AccountUsage: Equatable, Codable, Sendable {
    var windows: [UsageWindow]
    var fetchedAt: Date

    /// The window closest to its limit: the one that stops work first.
    var tightest: UsageWindow? {
        windows.max { $0.usedFraction < $1.usedFraction }
    }
}

/// A login in an account list.
struct AccountRow: Identifiable, Equatable, Sendable {
    /// The managed account id (Claude Code, Codex CLI) or the identity key (omp).
    var id: String
    var identity: AccountIdentity
    var organizationName: String?
    /// The subscription tier as the provider names it ("max", "pro", "team").
    var plan: String?
    var addedAt: Date?
    var usage: AccountUsage?
    /// Something the user has to act on, such as a login that expired.
    var problem: String?
}

/// A tool's logins for one provider.
struct AccountList: Equatable, Sendable {
    let id: AccountListID
    /// Why the list could not be read (CLI missing, store unreadable); nil when it loaded.
    var unavailableReason: String?
    /// The login the tool uses on its own: Claude Code's or the Codex CLI's
    /// sign-in. Always nil for omp, whose default is automatic balancing.
    var systemDefault: AccountRow?
    var accounts: [AccountRow] = []
    /// The chosen account; nil selects the system default (CLIs) or automatic
    /// balancing (omp).
    var selectedAccountId: String?

    var selectedAccount: AccountRow? {
        selectedAccountId.flatMap { id in accounts.first { $0.id == id } }
    }
}

/// A sign-in running in the background.
struct PendingLogin: Equatable, Sendable {
    let list: AccountListID
    /// The account being re-authenticated; nil when adding one.
    let accountId: String?
    /// The authorization URL the CLI printed, for when the browser did not open.
    var signInURL: URL?
}

/// Everything the accounts UI renders.
struct AccountsSnapshot: Equatable, Sendable {
    var lists: [AccountListID: AccountList] = [:]
    var pendingLogin: PendingLogin?
    /// The last failed action per list, cleared by the next action on it.
    var errors: [AccountListID: String] = [:]
    var isRefreshing = false
    var lastRefresh: Date?

    /// The usage a status line should show for `provider`: omp's preferred
    /// account, else omp's account with the most headroom (the one omp's
    /// balancing reaches for), else the CLI's active login.
    func headline(for provider: AccountProvider) -> (row: AccountRow, usage: AccountUsage)? {
        let ompList = lists[AccountListID(tool: .omp, provider: provider)]
        if let preferred = ompList?.selectedAccount, let usage = preferred.usage {
            return (preferred, usage)
        }
        let measured = (ompList?.accounts ?? []).compactMap { row in row.usage.map { (row, $0) } }
        if let roomiest = measured.min(by: {
            ($0.1.tightest?.usedFraction ?? 0) < ($1.1.tightest?.usedFraction ?? 0)
        }) {
            return roomiest
        }
        let cliList = lists[provider == .claude ? .claudeCode : .codexCLI]
        if let active = cliList?.selectedAccount ?? cliList?.systemDefault, let usage = active.usage {
            return (active, usage)
        }
        return nil
    }
}

/// Text for usage figures, shared by Settings and the status bar.
enum UsageFormat {
    /// "9%"
    static func percent(_ fraction: Double) -> String {
        "\(Int((max(0, fraction) * 100).rounded()))%"
    }

    /// Time until `date`: "47m", "3h 54m", "5d 17h". Nil when unknown or past.
    static func timeUntil(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// One window: "5h 9%", with the reset when known: "5h 9% · 3h 54m".
    static func window(_ window: UsageWindow, now: Date = Date()) -> String {
        let base = "\(window.label) \(percent(window.usedFraction))"
        guard let reset = timeUntil(window.resetsAt, now: now) else { return base }
        return "\(base) · \(reset)"
    }

    /// Every window of a report: "5h 9% · 7d 10%".
    static func summary(_ usage: AccountUsage) -> String {
        usage.windows.map { "\($0.label) \(percent($0.usedFraction))" }.joined(separator: " · ")
    }
}
