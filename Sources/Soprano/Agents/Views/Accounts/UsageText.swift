import AppKit

/// How close a usage figure is to its limit; the sidebar indicator, the usage card and
/// Settings → Accounts turn a limit warning-colored from 70 % and error-colored from 90 %.
enum UsageSeverity: Equatable {
    case normal
    case warning
    case critical

    init(fraction: Double) {
        if fraction >= 0.9 {
            self = .critical
        } else if fraction >= 0.7 {
            self = .warning
        } else {
            self = .normal
        }
    }

    /// Text color of a percentage.
    func color(in palette: Palette) -> NSColor {
        switch self {
        case .normal: palette.mutedForeground
        case .warning: palette.warningForeground
        case .critical: palette.errorForeground
        }
    }

    /// Fill of a usage bar.
    func barColor(in palette: Palette) -> NSColor {
        switch self {
        case .normal: palette.mutedForeground
        case .warning: palette.warning
        case .critical: palette.error
        }
    }
}

/// The figure a provider's headline shows: its headline account's tightest window.
struct UsageHeadline: Equatable {
    var provider: AccountProvider
    var row: AccountRow
    var usage: AccountUsage
    var window: UsageWindow

    var severity: UsageSeverity { UsageSeverity(fraction: window.usedFraction) }
}

/// Text for the usage indicator, the usage card and Settings → Accounts.
enum UsageText {
    /// One headline per provider with usage in omp's lists, in provider order.
    static func headlines(_ snapshot: AccountsSnapshot) -> [UsageHeadline] {
        // The vendored controller also loads the CLI lists; the headline reads omp's only.
        var shown = snapshot
        shown.lists = shown.lists.filter { AccountListID.shown.contains($0.key) }
        return AccountProvider.allCases.compactMap { provider in
            guard let headline = shown.headline(for: provider), let window = headline.usage.tightest else { return nil }
            return UsageHeadline(provider: provider, row: headline.row, usage: headline.usage, window: window)
        }
    }

    /// "Claude 9% · Codex 75%"; nil when no provider has usage.
    static func indicator(_ snapshot: AccountsSnapshot) -> String? {
        let headlines = headlines(snapshot)
        guard !headlines.isEmpty else { return nil }
        return headlines.map { "\($0.provider.displayName) \(UsageFormat.percent($0.window.usedFraction))" }
            .joined(separator: " · ")
    }

    /// The indicator with provider names muted and each percentage in its severity color.
    static func attributedIndicator(_ snapshot: AccountsSnapshot, palette: Palette, size: CGFloat = Typography.smallSize) -> NSAttributedString? {
        let headlines = headlines(snapshot)
        guard !headlines.isEmpty else { return nil }
        let muted: [NSAttributedString.Key: Any] = [.font: Typography.ui(size), .foregroundColor: palette.mutedForeground]
        let text = NSMutableAttributedString()
        for (index, headline) in headlines.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: " · ", attributes: muted)) }
            text.append(NSAttributedString(string: "\(headline.provider.displayName) ", attributes: muted))
            text.append(NSAttributedString(string: UsageFormat.percent(headline.window.usedFraction), attributes: [
                .font: Typography.tabular(size, weight: .medium),
                .foregroundColor: headline.severity.color(in: palette),
            ]))
        }
        return text
    }

    /// The indicator's tooltip: each provider's headline account and every window with its reset.
    ///
    ///     Claude · ada@example.com
    ///     5h 9% · resets in 3h 54m
    ///     7d 6% · resets in 5d 17h
    static func tooltip(_ snapshot: AccountsSnapshot, now: Date = Date()) -> String? {
        let headlines = headlines(snapshot)
        guard !headlines.isEmpty else { return nil }
        let blocks = headlines.map { headline in
            let title = headline.row.identity.email.isEmpty
                ? headline.provider.displayName
                : "\(headline.provider.displayName) · \(headline.row.identity.email)"
            let lines = headline.usage.windows.map { window in
                let base = "\(window.label) \(UsageFormat.percent(window.usedFraction))"
                return UsageFormat.timeUntil(window.resetsAt, now: now).map { "\(base) · resets in \($0)" } ?? base
            }
            return ([title] + lines).joined(separator: "\n")
        }
        return (blocks + ["Click for details"]).joined(separator: "\n\n")
    }

    /// A list's caption in the usage card: "omp · automatic" until a login is preferred, then "omp".
    static func caption(for list: AccountList) -> String {
        list.selectedAccountId == nil ? "\(list.id.tool.displayName) · automatic" : list.id.tool.displayName
    }

    /// "Updated 4m ago": recomputed on every render, which each refresh triggers.
    static func refreshed(_ snapshot: AccountsSnapshot, now: Date = Date()) -> String {
        if snapshot.isRefreshing { return "Updating…" }
        guard let lastRefresh = snapshot.lastRefresh else { return "Not updated yet" }
        let seconds = max(0, now.timeIntervalSince(lastRefresh))
        if seconds < 60 { return "Updated just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "Updated \(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "Updated \(hours)h ago" }
        return "Updated \(hours / 24)d ago"
    }

    /// Organization, plan and usage of a settings row, each part once. Windows are joined with a
    /// wider gap than the " · " inside each one, so "5h 9% · 3h 54m" still reads as a unit.
    static func detailParts(_ account: AccountRow, now: Date = Date()) -> [String] {
        var parts: [String] = []
        // omp names a personal ChatGPT workspace after its plan, so org and plan can be the
        // same word; say it once.
        for part in [account.organizationName, account.plan].compactMap({ $0 })
        where !part.isEmpty && !parts.contains(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
            parts.append(part)
        }
        if let usage = account.usage, !usage.windows.isEmpty {
            parts.append(usage.windows.map { UsageFormat.window($0, now: now) }.joined(separator: "  ·  "))
        } else {
            parts.append("No usage data")
        }
        return parts
    }

    /// Settings → Accounts: what each omp list is for.
    static let listNote = "omp uses every account and fails over when one runs out. New omp threads try the preferred account first."

    /// The confirmation text for removing an account.
    static let removalExplanation = "omp signs this account out on this Mac."
}
