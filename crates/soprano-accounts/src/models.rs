//! The account lists the UI renders, and the text for usage figures.

use std::collections::HashMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// A point in time. Every date in this crate is UTC.
pub type Timestamp = DateTime<Utc>;

/// `seconds` since 1970 as a timestamp; nil for values chrono cannot represent.
pub fn timestamp_from_seconds(seconds: f64) -> Option<Timestamp> {
    if !seconds.is_finite() {
        return None;
    }
    let whole = seconds.floor();
    let nanos = ((seconds - whole) * 1_000_000_000.0).round().clamp(0.0, 999_999_999.0) as u32;
    DateTime::from_timestamp(whole as i64, nanos)
}

/// Seconds since 1970, with fractions.
pub fn seconds_since_epoch(date: &Timestamp) -> f64 {
    date.timestamp() as f64 + f64::from(date.timestamp_subsec_nanos()) / 1_000_000_000.0
}

/// Seconds from `earlier` to `later` (negative when `later` is earlier).
pub(crate) fn seconds_between(earlier: &Timestamp, later: &Timestamp) -> f64 {
    seconds_since_epoch(later) - seconds_since_epoch(earlier)
}

/// A subscription Soprano can hold several logins for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AccountProvider {
    Claude,
    Codex,
}

impl AccountProvider {
    pub const ALL: [AccountProvider; 2] = [AccountProvider::Claude, AccountProvider::Codex];

    /// The Swift raw value: `claude`, `codex`.
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Claude => "Claude",
            Self::Codex => "Codex",
        }
    }

    /// The provider id omp stores this subscription's OAuth logins under.
    pub fn omp_provider_id(self) -> &'static str {
        match self {
            Self::Claude => "anthropic",
            Self::Codex => "openai-codex",
        }
    }

    pub fn from_omp_provider_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|provider| provider.omp_provider_id() == id)
    }
}

/// The program an account list feeds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AccountTool {
    /// omp keeps every login of a provider and balances across them.
    Omp,
    /// The `claude` CLI: one login at a time, switched for the whole machine.
    ClaudeCode,
    /// The `codex` CLI: one login per `CODEX_HOME`, chosen when a pane starts.
    CodexCli,
}

impl AccountTool {
    pub const ALL: [AccountTool; 3] = [AccountTool::Omp, AccountTool::ClaudeCode, AccountTool::CodexCli];

    /// The Swift raw value: `omp`, `claudeCode`, `codexCLI`.
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Omp => "omp",
            Self::ClaudeCode => "claudeCode",
            Self::CodexCli => "codexCLI",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Omp => "omp",
            Self::ClaudeCode => "Claude Code",
            Self::CodexCli => "Codex CLI",
        }
    }
}

/// One account list on screen: a tool's logins for one provider.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct AccountListId {
    pub tool: AccountTool,
    pub provider: AccountProvider,
}

impl AccountListId {
    pub const OMP_CLAUDE: Self = Self { tool: AccountTool::Omp, provider: AccountProvider::Claude };
    pub const OMP_CODEX: Self = Self { tool: AccountTool::Omp, provider: AccountProvider::Codex };
    pub const CLAUDE_CODE: Self = Self { tool: AccountTool::ClaudeCode, provider: AccountProvider::Claude };
    pub const CODEX_CLI: Self = Self { tool: AccountTool::CodexCli, provider: AccountProvider::Codex };

    /// Display order. omp leads each provider because most panes run it.
    pub const ALL: [AccountListId; 4] =
        [Self::OMP_CLAUDE, Self::CLAUDE_CODE, Self::OMP_CODEX, Self::CODEX_CLI];

    pub const fn new(tool: AccountTool, provider: AccountProvider) -> Self {
        Self { tool, provider }
    }
}

/// Who a login belongs to. The organization is part of it: one email can hold
/// a personal and a team subscription, and those are separate accounts with
/// separate limits.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct AccountIdentity {
    pub email: String,
    /// Claude: the organization UUID. Codex: the ChatGPT account (workspace) id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub organization_id: Option<String>,
}

impl AccountIdentity {
    pub fn new(email: impl Into<String>, organization_id: Option<String>) -> Self {
        Self { email: email.into(), organization_id }
    }

    /// Emails compare case-insensitively; the organization exactly.
    pub fn key(&self) -> String {
        format!("{}|{}", self.email.to_lowercase(), self.organization_id.as_deref().unwrap_or(""))
    }

    /// Same person and, when both sides know it, the same organization.
    pub fn matches(&self, other: &AccountIdentity) -> bool {
        if self.email.to_lowercase() != other.email.to_lowercase() {
            return false;
        }
        match (&self.organization_id, &other.organization_id) {
            (Some(mine), Some(theirs)) => mine == theirs,
            _ => true,
        }
    }
}

/// One rate-limit window, such as the 5-hour or the weekly limit.
#[derive(Debug, Clone, PartialEq)]
pub struct UsageWindow {
    /// Short label: "5h", "7d", "7d opus".
    pub label: String,
    /// Share of the window used: 0…1, above 1 when a plan allows overage.
    pub used_fraction: f64,
    pub resets_at: Option<Timestamp>,
}

/// The provider's rate-limit report for one account.
#[derive(Debug, Clone, PartialEq)]
pub struct AccountUsage {
    pub windows: Vec<UsageWindow>,
    pub fetched_at: Timestamp,
}

impl AccountUsage {
    /// The window closest to its limit: the one that stops work first. On a
    /// tie the earlier window wins.
    pub fn tightest(&self) -> Option<&UsageWindow> {
        let mut best: Option<&UsageWindow> = None;
        for window in &self.windows {
            if best.is_none_or(|current| current.used_fraction < window.used_fraction) {
                best = Some(window);
            }
        }
        best
    }
}

/// A login in an account list.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct AccountRow {
    /// The managed account id (Claude Code, Codex CLI) or the identity key (omp).
    pub id: String,
    pub identity: AccountIdentity,
    pub organization_name: Option<String>,
    /// The subscription tier as the provider names it ("max", "pro", "team").
    pub plan: Option<String>,
    pub added_at: Option<Timestamp>,
    pub usage: Option<AccountUsage>,
    /// Something the user has to act on, such as a login that expired.
    pub problem: Option<String>,
}

/// A tool's logins for one provider.
#[derive(Debug, Clone, PartialEq)]
pub struct AccountList {
    pub id: AccountListId,
    /// Why the list could not be read (CLI missing, store unreadable); nil when it loaded.
    pub unavailable_reason: Option<String>,
    /// The login the tool uses on its own: Claude Code's or the Codex CLI's
    /// sign-in. Always nil for omp, whose default is automatic balancing.
    pub system_default: Option<AccountRow>,
    pub accounts: Vec<AccountRow>,
    /// The chosen account; nil selects the system default (CLIs) or automatic
    /// balancing (omp).
    pub selected_account_id: Option<String>,
}

impl AccountList {
    pub fn new(id: AccountListId) -> Self {
        Self {
            id,
            unavailable_reason: None,
            system_default: None,
            accounts: Vec::new(),
            selected_account_id: None,
        }
    }

    pub fn selected_account(&self) -> Option<&AccountRow> {
        let id = self.selected_account_id.as_deref()?;
        self.accounts.iter().find(|row| row.id == id)
    }
}

/// A sign-in running in the background.
#[derive(Debug, Clone, PartialEq)]
pub struct PendingLogin {
    pub list: AccountListId,
    /// The account being re-authenticated; nil when adding one.
    pub account_id: Option<String>,
    /// The authorization URL the CLI printed, for when the browser did not open.
    pub sign_in_url: Option<String>,
}

/// Everything the accounts UI renders.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct AccountsSnapshot {
    pub lists: HashMap<AccountListId, AccountList>,
    pub pending_login: Option<PendingLogin>,
    /// The last failed action per list, cleared by the next action on it.
    pub errors: HashMap<AccountListId, String>,
    pub is_refreshing: bool,
    pub last_refresh: Option<Timestamp>,
}

impl AccountsSnapshot {
    /// The usage a status line should show for `provider`: omp's preferred
    /// account, else omp's account with the most headroom (the one omp's
    /// balancing reaches for), else the CLI's active login.
    pub fn headline(&self, provider: AccountProvider) -> Option<(&AccountRow, &AccountUsage)> {
        let omp_list = self.lists.get(&AccountListId::new(AccountTool::Omp, provider));
        if let Some(preferred) = omp_list.and_then(AccountList::selected_account)
            && let Some(usage) = &preferred.usage
        {
            return Some((preferred, usage));
        }
        let fraction = |usage: &AccountUsage| usage.tightest().map_or(0.0, |window| window.used_fraction);
        let mut roomiest: Option<(&AccountRow, &AccountUsage)> = None;
        for row in omp_list.map(|list| list.accounts.as_slice()).unwrap_or_default() {
            let Some(usage) = &row.usage else { continue };
            if roomiest.is_none_or(|(_, best)| fraction(usage) < fraction(best)) {
                roomiest = Some((row, usage));
            }
        }
        if roomiest.is_some() {
            return roomiest;
        }
        let cli_id = match provider {
            AccountProvider::Claude => AccountListId::CLAUDE_CODE,
            AccountProvider::Codex => AccountListId::CODEX_CLI,
        };
        let cli_list = self.lists.get(&cli_id)?;
        let active = cli_list.selected_account().or(cli_list.system_default.as_ref())?;
        Some((active, active.usage.as_ref()?))
    }
}

/// Text for usage figures, shared by Settings and the status bar.
pub mod usage_format {
    use super::{AccountUsage, Timestamp, UsageWindow, seconds_between};

    /// "9%"
    pub fn percent(fraction: f64) -> String {
        format!("{}%", (fraction.max(0.0) * 100.0).round() as i64)
    }

    /// Time until `date`: "47m", "3h 54m", "5d 17h". Nil when unknown or past.
    pub fn time_until(date: Option<&Timestamp>, now: &Timestamp) -> Option<String> {
        let seconds = seconds_between(now, date?);
        if seconds <= 0.0 {
            return None;
        }
        let minutes = (seconds / 60.0).ceil() as i64;
        if minutes < 60 {
            return Some(format!("{minutes}m"));
        }
        let hours = minutes / 60;
        if hours < 24 {
            return Some(format!("{hours}h {}m", minutes % 60));
        }
        Some(format!("{}d {}h", hours / 24, hours % 24))
    }

    /// One window: "5h 9%", with the reset when known: "5h 9% · 3h 54m".
    pub fn window(window: &UsageWindow, now: &Timestamp) -> String {
        let base = format!("{} {}", window.label, percent(window.used_fraction));
        match time_until(window.resets_at.as_ref(), now) {
            Some(reset) => format!("{base} · {reset}"),
            None => base,
        }
    }

    /// Every window of a report: "5h 9% · 7d 10%".
    pub fn summary(usage: &AccountUsage) -> String {
        usage
            .windows
            .iter()
            .map(|window| format!("{} {}", window.label, percent(window.used_fraction)))
            .collect::<Vec<_>>()
            .join(" · ")
    }
}

/// How close a usage figure is to its limit: warning from 70 %, danger from
/// 90 %. The status bar, the usage card and Settings → Accounts turn at the
/// same points; the UI maps each level to its theme color (status bar: ink /
/// yellow / danger; card percentages: muted / warning / error).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum UsageSeverity {
    /// Room left: ink (status bar) or muted (card).
    Normal,
    /// From 70 %.
    Warning,
    /// From 90 %.
    Danger,
}

impl UsageSeverity {
    pub fn of(fraction: f64) -> Self {
        if fraction >= 0.9 {
            Self::Danger
        } else if fraction >= 0.7 {
            Self::Warning
        } else {
            Self::Normal
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(seconds: f64) -> Timestamp {
        timestamp_from_seconds(seconds).unwrap()
    }

    #[test]
    fn reset_countdowns_round_up_to_the_minute_and_switch_units_at_hours_and_days() {
        let now = at(0.0);
        let until = |seconds: f64| usage_format::time_until(Some(&at(seconds)), &now);
        assert_eq!(until(1.0).as_deref(), Some("1m"));
        assert_eq!(until(59.0 * 60.0).as_deref(), Some("59m"));
        assert_eq!(until(60.0 * 60.0).as_deref(), Some("1h 0m"));
        assert_eq!(until(3.0 * 3600.0 + 54.0 * 60.0).as_deref(), Some("3h 54m"));
        assert_eq!(until(24.0 * 3600.0).as_deref(), Some("1d 0h"));
        assert_eq!(until(5.0 * 86_400.0 + 17.0 * 3600.0).as_deref(), Some("5d 17h"));
        assert_eq!(until(-5.0), None);
        assert_eq!(usage_format::time_until(None, &now), None);
    }

    #[test]
    fn usage_figures_read_as_rounded_percentages_and_window_summaries() {
        let now = at(0.0);
        let window = UsageWindow { label: "5h".into(), used_fraction: 0.094, resets_at: Some(at(14_040.0)) };
        assert_eq!(usage_format::percent(-0.2), "0%");
        assert_eq!(usage_format::percent(1.234), "123%");
        assert_eq!(usage_format::window(&window, &now), "5h 9% · 3h 54m");
        let usage = AccountUsage {
            windows: vec![window, UsageWindow { label: "7d".into(), used_fraction: 0.1, resets_at: None }],
            fetched_at: now,
        };
        assert_eq!(usage_format::summary(&usage), "5h 9% · 7d 10%");
    }

    #[test]
    fn the_status_line_follows_omps_preferred_account_then_its_roomiest_then_the_cli_login() {
        let row = |email: &str, used: Option<f64>| AccountRow {
            id: email.into(),
            identity: AccountIdentity::new(email, None),
            usage: used.map(|used| AccountUsage {
                windows: vec![UsageWindow { label: "5h".into(), used_fraction: used, resets_at: None }],
                fetched_at: at(0.0),
            }),
            ..AccountRow::default()
        };
        let mut omp = AccountList::new(AccountListId::OMP_CLAUDE);
        omp.accounts = vec![row("busy@x", Some(0.8)), row("idle@x", Some(0.1)), row("unknown@x", None)];
        let mut cli = AccountList::new(AccountListId::CLAUDE_CODE);
        cli.system_default = Some(row("cli@x", Some(0.5)));
        let mut snapshot = AccountsSnapshot::default();
        snapshot.lists.insert(AccountListId::OMP_CLAUDE, omp);
        snapshot.lists.insert(AccountListId::CLAUDE_CODE, cli);
        let headline = |snapshot: &AccountsSnapshot, provider| {
            snapshot.headline(provider).map(|(row, _)| row.id.clone())
        };

        // Automatic: the account with the most headroom, which omp reaches for.
        assert_eq!(headline(&snapshot, AccountProvider::Claude).as_deref(), Some("idle@x"));

        snapshot.lists.get_mut(&AccountListId::OMP_CLAUDE).unwrap().selected_account_id =
            Some("busy@x".into());
        assert_eq!(headline(&snapshot, AccountProvider::Claude).as_deref(), Some("busy@x"));

        snapshot.lists.get_mut(&AccountListId::OMP_CLAUDE).unwrap().accounts.clear();
        assert_eq!(headline(&snapshot, AccountProvider::Claude).as_deref(), Some("cli@x"));
        assert_eq!(headline(&snapshot, AccountProvider::Codex), None);
    }

    #[test]
    fn usage_below_seventy_percent_stays_normal() {
        assert_eq!(UsageSeverity::of(0.0), UsageSeverity::Normal);
        assert_eq!(UsageSeverity::of(0.69), UsageSeverity::Normal);
    }

    #[test]
    fn usage_from_seventy_percent_turns_warning_below_ninety() {
        assert_eq!(UsageSeverity::of(0.7), UsageSeverity::Warning);
        assert_eq!(UsageSeverity::of(0.89), UsageSeverity::Warning);
    }

    #[test]
    fn usage_from_ninety_percent_turns_danger() {
        assert_eq!(UsageSeverity::of(0.9), UsageSeverity::Danger);
        assert_eq!(UsageSeverity::of(0.93), UsageSeverity::Danger);
        assert_eq!(UsageSeverity::of(1.2), UsageSeverity::Danger);
    }

    #[test]
    fn identities_match_case_insensitively_and_on_the_organization_when_both_know_it() {
        let personal = AccountIdentity::new("Ada@Example.com", Some("org-1".into()));
        assert!(personal.matches(&AccountIdentity::new("ada@example.com", None)));
        assert!(!personal.matches(&AccountIdentity::new("ada@example.com", Some("org-2".into()))));
        assert_eq!(personal.key(), "ada@example.com|org-1");
        assert_eq!(AccountProvider::from_omp_provider_id("openai-codex"), Some(AccountProvider::Codex));
        assert_eq!(AccountProvider::from_omp_provider_id("zai"), None);
    }
}
