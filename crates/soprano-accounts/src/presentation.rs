//! What the accounts UI shows, as plain data: the Settings ▸ Accounts page,
//! the status bar's usage segment and the usage card it opens. The views only
//! lay these out and send `PageAction`s back.

use crate::controller::{AccountsController, SnapshotObserver};
use crate::models::{
    AccountList, AccountListId, AccountProvider, AccountRow, AccountTool, AccountsSnapshot, Timestamp,
    UsageSeverity, UsageWindow, seconds_between, usage_format,
};

/// What Settings ▸ Accounts and the usage card read and act through:
/// `AccountsController` in the app, a fake in tests.
pub trait AccountsSource {
    fn snapshot(&self) -> AccountsSnapshot;
    fn add_observer(&self, id: &str, handler: SnapshotObserver);
    fn remove_observer(&self, id: &str);
    fn refresh(&self, force: bool);
    fn add_account(&self, list: AccountListId);
    fn reauthenticate(&self, account_id: &str, list: AccountListId);
    fn cancel_login(&self);
    fn select(&self, account_id: Option<&str>, list: AccountListId);
    fn remove(&self, account_id: &str, list: AccountListId);
    fn dismiss_error(&self, list: AccountListId);
}

impl AccountsSource for AccountsController {
    fn snapshot(&self) -> AccountsSnapshot {
        AccountsController::snapshot(self)
    }
    fn add_observer(&self, id: &str, handler: SnapshotObserver) {
        AccountsController::add_observer(self, id, handler);
    }
    fn remove_observer(&self, id: &str) {
        AccountsController::remove_observer(self, id);
    }
    fn refresh(&self, force: bool) {
        AccountsController::refresh(self, force);
    }
    fn add_account(&self, list: AccountListId) {
        AccountsController::add_account(self, list);
    }
    fn reauthenticate(&self, account_id: &str, list: AccountListId) {
        AccountsController::reauthenticate(self, account_id, list);
    }
    fn cancel_login(&self) {
        AccountsController::cancel_login(self);
    }
    fn select(&self, account_id: Option<&str>, list: AccountListId) {
        AccountsController::select(self, account_id, list);
    }
    fn remove(&self, account_id: &str, list: AccountListId) {
        AccountsController::remove(self, account_id, list);
    }
    fn dismiss_error(&self, list: AccountListId) {
        AccountsController::dismiss_error(self, list);
    }
}

// MARK: - Actions

/// What a button on the page does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PageAction {
    Refresh {
        force: bool,
    },
    AddAccount(AccountListId),
    Reauthenticate {
        list: AccountListId,
        account_id: String,
    },
    /// nil: the System default (CLIs) or automatic balancing (omp).
    Select {
        list: AccountListId,
        account_id: Option<String>,
    },
    /// Asks first (`perform` returns the `Confirmation`); its confirm button
    /// performs `Remove`.
    ConfirmRemove {
        list: AccountListId,
        account_id: String,
        email: String,
    },
    Remove {
        list: AccountListId,
        account_id: String,
    },
    CancelLogin,
    /// Opens the sign-in URL in the default browser.
    OpenSignInPage(String),
    DismissError(AccountListId),
    /// The usage card's "Manage Accounts…": the host opens Settings ▸ Accounts.
    ManageAccounts,
}

/// A destructive confirmation dialog the view shows before an action.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Confirmation {
    pub title: String,
    pub message: &'static str,
    pub confirm_title: &'static str,
    pub is_destructive: bool,
    /// Performed when the user confirms.
    pub action: PageAction,
}

impl PageAction {
    /// Sends the action to `source`. `ConfirmRemove` sends nothing and returns
    /// the dialog to show; `ManageAccounts` is the host's to handle.
    pub fn perform(&self, source: &dyn AccountsSource) -> Option<Confirmation> {
        match self {
            Self::Refresh { force } => source.refresh(*force),
            Self::AddAccount(list) => source.add_account(*list),
            Self::Reauthenticate { list, account_id } => source.reauthenticate(account_id, *list),
            Self::Select { list, account_id } => source.select(account_id.as_deref(), *list),
            Self::ConfirmRemove { list, account_id, email } => {
                return Some(Confirmation {
                    title: format!("Remove {email}?"),
                    message: removal_explanation(list.tool),
                    confirm_title: "Remove",
                    is_destructive: true,
                    action: Self::Remove { list: *list, account_id: account_id.clone() },
                });
            }
            Self::Remove { list, account_id } => source.remove(account_id, *list),
            Self::CancelLogin => source.cancel_login(),
            Self::OpenSignInPage(url) => {
                let _ = soprano_platform::system::open_default(url);
            }
            Self::DismissError(list) => source.dismiss_error(*list),
            Self::ManageAccounts => {}
        }
        None
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ButtonVariant {
    Default,
    Primary,
    Ghost,
    DestructiveOutline,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Button {
    pub title: &'static str,
    pub variant: ButtonVariant,
    pub is_enabled: bool,
    /// "plus" for Add Account.
    pub symbol: Option<&'static str>,
    pub action: PageAction,
}

impl Button {
    fn new(title: &'static str, action: PageAction) -> Self {
        Self { title, variant: ButtonVariant::Default, is_enabled: true, symbol: None, action }
    }

    fn variant(mut self, variant: ButtonVariant) -> Self {
        self.variant = variant;
        self
    }

    fn enabled(mut self, is_enabled: bool) -> Self {
        self.is_enabled = is_enabled;
        self
    }
}

// MARK: - Settings ▸ Accounts

pub const ACCOUNTS_INTRO: &str = "Sign in to several Claude and Codex accounts. omp balances across its accounts; Claude Code and the Codex CLI use the one you choose.";

/// The page, built from one snapshot. Rebuild it on every snapshot the
/// source publishes while the page is open.
#[derive(Debug, Clone, PartialEq)]
pub struct AccountsPage {
    /// "Refresh" / "Refreshing…" (disabled while refreshing).
    pub refresh: Button,
    /// "Updated 4m ago".
    pub updated: String,
    pub intro: &'static str,
    pub sections: Vec<AccountListSection>,
}

/// One list: "Claude · omp", its note, an error, its rows and its footer.
#[derive(Debug, Clone, PartialEq)]
pub struct AccountListSection {
    pub list: AccountListId,
    pub title: String,
    pub note: &'static str,
    /// "Something went wrong" with the message and a Dismiss button.
    pub error: Option<SectionError>,
    pub body: SectionBody,
    pub footer: SectionFooter,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SectionError {
    pub title: &'static str,
    pub message: String,
    pub dismiss: Button,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SectionBody {
    /// "Unavailable" with the reason.
    Unavailable(String),
    /// The default row (Automatic / System default) first, then each login.
    Rows(Vec<EntryRow>),
    /// "Loading accounts…" / "Accounts not loaded yet."
    Placeholder(&'static str),
}

/// A login row: title, Active/Preferred badge, detail line, problem and buttons.
#[derive(Debug, Clone, PartialEq)]
pub struct EntryRow {
    pub title: String,
    pub is_selected: bool,
    pub badge: Option<&'static str>,
    pub detail: String,
    pub problem: Option<String>,
    pub buttons: Vec<Button>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SectionFooter {
    /// The running sign-in for this list.
    Pending { text: String, description: &'static str, buttons: Vec<Button> },
    /// "Add Account", disabled while any sign-in runs.
    Add(Button),
}

impl AccountsPage {
    pub fn build(snapshot: &AccountsSnapshot, now: &Timestamp) -> Self {
        let refresh = Button::new(
            if snapshot.is_refreshing { "Refreshing…" } else { "Refresh" },
            PageAction::Refresh { force: true },
        )
        .enabled(!snapshot.is_refreshing);
        Self {
            refresh,
            updated: refresh_text(snapshot, now),
            intro: ACCOUNTS_INTRO,
            sections: AccountListId::ALL.iter().map(|id| section(*id, snapshot, now)).collect(),
        }
    }

    /// Opening the page refreshes, without forcing.
    pub fn on_open(source: &dyn AccountsSource) {
        source.refresh(false);
    }
}

/// "Updated 4m ago": recomputed on every rebuild, which each refresh
/// triggers, so it never needs a timer of its own.
pub fn refresh_text(snapshot: &AccountsSnapshot, now: &Timestamp) -> String {
    if snapshot.is_refreshing {
        return "Updating…".into();
    }
    let Some(last) = snapshot.last_refresh else { return "Not updated yet".into() };
    let seconds = seconds_between(&last, now).max(0.0);
    if seconds < 60.0 {
        return "Updated just now".into();
    }
    let minutes = (seconds / 60.0) as i64;
    if minutes < 60 {
        return format!("Updated {minutes}m ago");
    }
    let hours = minutes / 60;
    if hours < 24 {
        return format!("Updated {hours}h ago");
    }
    format!("Updated {}d ago", hours / 24)
}

pub fn section_title(list: AccountListId) -> String {
    format!("{} · {}", list.provider.display_name(), list.tool.display_name())
}

pub fn list_note(tool: AccountTool) -> &'static str {
    match tool {
        AccountTool::Omp => {
            "omp uses every account and fails over when one runs out. New omp panes try the preferred account first."
        }
        AccountTool::ClaudeCode => {
            "Choosing an account signs Claude Code in with it on this Mac; running claude sessions switch too. System default is the login Claude Code had before."
        }
        AccountTool::CodexCli => {
            "New codex panes use the chosen account; running panes keep theirs. History, config and skills stay shared."
        }
    }
}

pub fn removal_explanation(tool: AccountTool) -> &'static str {
    match tool {
        AccountTool::Omp => "omp signs this account out on this Mac.",
        AccountTool::ClaudeCode => {
            "Soprano forgets this login. If it is active, Claude Code goes back to the System default."
        }
        AccountTool::CodexCli => {
            "Soprano deletes this account's sign-in. If it is active, new codex panes use the System default."
        }
    }
}

fn section(id: AccountListId, snapshot: &AccountsSnapshot, now: &Timestamp) -> AccountListSection {
    let error = snapshot.errors.get(&id).map(|message| SectionError {
        title: "Something went wrong",
        message: message.clone(),
        dismiss: Button::new("Dismiss", PageAction::DismissError(id)).variant(ButtonVariant::Ghost),
    });
    let list = snapshot.lists.get(&id);
    let body = match list {
        Some(list) if list.unavailable_reason.is_some() => {
            SectionBody::Unavailable(list.unavailable_reason.clone().unwrap_or_default())
        }
        Some(list) => {
            let mut rows = vec![default_row(list, now)];
            rows.extend(list.accounts.iter().map(|account| account_row(account, list, snapshot, now)));
            SectionBody::Rows(rows)
        }
        None => SectionBody::Placeholder(if snapshot.is_refreshing {
            "Loading accounts…"
        } else {
            "Accounts not loaded yet."
        }),
    };
    AccountListSection {
        list: id,
        title: section_title(id),
        note: list_note(id.tool),
        error,
        body,
        footer: footer(id, list, snapshot),
    }
}

/// "Automatic" for omp, "System default" for the CLIs: the choice that
/// leaves the tool to its own login.
fn default_row(list: &AccountList, now: &Timestamp) -> EntryRow {
    let is_selected = list.selected_account_id.is_none();
    let is_omp = list.id.tool == AccountTool::Omp;
    let (title, detail, problem) = if is_omp {
        ("Automatic", "Balance by usage".to_owned(), None)
    } else {
        match &list.system_default {
            Some(system_default) => {
                let email = &system_default.identity.email;
                let mut parts = if email.is_empty() { Vec::new() } else { vec![email.clone()] };
                parts.extend(detail_parts(system_default, now));
                ("System default", parts.join("  ·  "), system_default.problem.clone())
            }
            None => ("System default", "Not signed in".to_owned(), None),
        }
    };
    let mut buttons = Vec::new();
    if !is_selected {
        buttons.push(Button::new(
            if is_omp { "Automatic" } else { "Use" },
            PageAction::Select { list: list.id, account_id: None },
        ));
    }
    EntryRow {
        title: title.to_owned(),
        is_selected,
        badge: is_selected.then_some("Active"),
        detail,
        problem,
        buttons,
    }
}

fn account_row(
    account: &AccountRow,
    list: &AccountList,
    snapshot: &AccountsSnapshot,
    now: &Timestamp,
) -> EntryRow {
    let is_omp = list.id.tool == AccountTool::Omp;
    let is_selected = list.selected_account_id.as_deref() == Some(account.id.as_str());
    let mut buttons = Vec::new();
    if !is_selected {
        buttons.push(Button::new(
            if is_omp { "Prefer" } else { "Use" },
            PageAction::Select { list: list.id, account_id: Some(account.id.clone()) },
        ));
    }
    // One browser sign-in at a time, across every list.
    buttons.push(
        Button::new(
            "Re-authenticate",
            PageAction::Reauthenticate { list: list.id, account_id: account.id.clone() },
        )
        .enabled(snapshot.pending_login.is_none()),
    );
    buttons.push(
        Button::new(
            "Remove",
            PageAction::ConfirmRemove {
                list: list.id,
                account_id: account.id.clone(),
                email: account.identity.email.clone(),
            },
        )
        .variant(ButtonVariant::DestructiveOutline),
    );
    EntryRow {
        title: account.identity.email.clone(),
        is_selected,
        badge: is_selected.then_some(if is_omp { "Preferred" } else { "Active" }),
        detail: detail_parts(account, now).join("  ·  "),
        problem: account.problem.clone(),
        buttons,
    }
}

/// Organization, plan and usage. Windows are joined with a wider gap than
/// the " · " inside each one, so "5h 9% · 3h 54m" still reads as a unit.
fn detail_parts(account: &AccountRow, now: &Timestamp) -> Vec<String> {
    // omp names a personal ChatGPT workspace after its plan, so org and plan
    // can be the same word; say it once.
    let mut parts: Vec<String> = Vec::new();
    for part in [&account.organization_name, &account.plan].into_iter().flatten() {
        if !part.is_empty() && !parts.iter().any(|existing| existing.to_lowercase() == part.to_lowercase()) {
            parts.push(part.clone());
        }
    }
    match &account.usage {
        Some(usage) if !usage.windows.is_empty() => parts.push(
            usage
                .windows
                .iter()
                .map(|window| usage_format::window(window, now))
                .collect::<Vec<_>>()
                .join("  ·  "),
        ),
        _ => parts.push("No usage data".into()),
    }
    parts
}

/// The running sign-in for this list, or the button that starts one.
fn footer(id: AccountListId, list: Option<&AccountList>, snapshot: &AccountsSnapshot) -> SectionFooter {
    if let Some(pending) = snapshot.pending_login.as_ref().filter(|pending| pending.list == id) {
        let email = pending.account_id.as_deref().and_then(|account_id| {
            list?.accounts.iter().find(|row| row.id == account_id).map(|row| row.identity.email.clone())
        });
        let text = match email {
            Some(email) => format!("Waiting for sign-in in your browser to re-authenticate {email}…"),
            None => "Waiting for sign-in in your browser…".to_owned(),
        };
        let mut buttons = Vec::new();
        if let Some(url) = &pending.sign_in_url {
            buttons.push(Button::new("Open Sign-in Page", PageAction::OpenSignInPage(url.clone())));
        }
        buttons.push(Button::new("Cancel", PageAction::CancelLogin).variant(ButtonVariant::Ghost));
        return SectionFooter::Pending {
            text,
            description: if pending.sign_in_url.is_none() {
                "Finish signing in in the browser window that opened."
            } else {
                "If no browser window opened, open the sign-in page yourself."
            },
            buttons,
        };
    }
    // One browser sign-in at a time, across every list.
    let mut add = Button::new("Add Account", PageAction::AddAccount(id))
        .variant(ButtonVariant::Primary)
        .enabled(snapshot.pending_login.is_none());
    add.symbol = Some("plus");
    SectionFooter::Add(add)
}

// MARK: - Status bar

/// One provider in the status bar: "Claude 18% · 3h 5m". The UI colors the
/// provider name and the reset muted and the percentage by `severity`.
#[derive(Debug, Clone, PartialEq)]
pub struct StatusUsageSegment {
    pub provider: AccountProvider,
    /// "Claude"
    pub name: &'static str,
    pub fraction: f64,
    /// "18%"
    pub percent: String,
    pub severity: UsageSeverity,
    /// "3h 5m", when the window's reset is known and ahead.
    pub reset: Option<String>,
}

impl StatusUsageSegment {
    /// "Claude 18% · 3h 5m"
    pub fn text(&self) -> String {
        match &self.reset {
            Some(reset) => format!("{} {} · {reset}", self.name, self.percent),
            None => format!("{} {}", self.name, self.percent),
        }
    }
}

/// Separates providers in the status bar (drawn in the border color).
pub const STATUS_USAGE_SEPARATOR: &str = "  |  ";

/// Each provider's tightest window of its headline account
/// (`AccountsSnapshot::headline`); empty when no provider has usage yet, and
/// the usage segment is hidden.
pub fn status_usage(snapshot: &AccountsSnapshot, now: &Timestamp) -> Vec<StatusUsageSegment> {
    AccountProvider::ALL
        .into_iter()
        .filter_map(|provider| {
            let (_, usage) = snapshot.headline(provider)?;
            let window = usage.tightest()?;
            Some(StatusUsageSegment {
                provider,
                name: provider.display_name(),
                fraction: window.used_fraction,
                percent: usage_format::percent(window.used_fraction),
                severity: UsageSeverity::of(window.used_fraction),
                reset: usage_format::time_until(window.resets_at.as_ref(), now),
            })
        })
        .collect()
}

/// `Claude 9% · 4h 12m  |  Codex 75% · 5d 8h`; nil when no provider has usage yet.
pub fn status_usage_text(snapshot: &AccountsSnapshot, now: &Timestamp) -> Option<String> {
    let segments = status_usage(snapshot, now);
    (!segments.is_empty()).then(|| {
        segments.iter().map(StatusUsageSegment::text).collect::<Vec<_>>().join(STATUS_USAGE_SEPARATOR)
    })
}

/// The status bar's tooltip on the usage segment.
pub const STATUS_USAGE_TOOLTIP: &str = "Account usage — click for details";

// MARK: - Usage card

/// The status bar's usage card: per provider an eyebrow, each list's caption
/// ("omp · automatic") and its logins with one line per usage window, then
/// Refresh and Manage Accounts….
///
/// ```text
/// CLAUDE
/// omp · automatic
/// ○ ada@example.com
///   5h      ▬▭▭▭▭    9%  3h 54m
///   7d      ▬▭▭▭▭    6%  5d 17h
/// ──────────────────────────────
/// [Refresh]  [Manage Accounts…]
/// ```
#[derive(Debug, Clone, PartialEq)]
pub struct UsageCard {
    pub providers: Vec<UsageCardProvider>,
    /// "No accounts yet." when no list has a login.
    pub empty_text: Option<&'static str>,
    /// "Refresh" / "Refreshing…" (disabled while refreshing); forces a refresh.
    pub refresh: Button,
    pub manage_accounts: Button,
}

#[derive(Debug, Clone, PartialEq)]
pub struct UsageCardProvider {
    pub provider: AccountProvider,
    /// "CLAUDE"
    pub eyebrow: String,
    pub lists: Vec<UsageCardList>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct UsageCardList {
    pub list: AccountListId,
    /// "omp · automatic" until a login is preferred, then the tool's name.
    pub caption: String,
    pub rows: Vec<UsageCardRow>,
}

/// A login on one line, then one line per usage window. The chosen login has
/// a filled mark, the others a ring; a login with a problem shows the error
/// diamond.
#[derive(Debug, Clone, PartialEq)]
pub struct UsageCardRow {
    /// "System default — " before the name when set (drawn muted).
    pub is_system_default: bool,
    /// The email, or the problem when the login has no email.
    pub name: String,
    pub is_selected: bool,
    pub has_problem: bool,
    pub tooltip: String,
    /// Empty: show "no usage data".
    pub windows: Vec<UsageCardLine>,
}

pub const USAGE_CARD_SYSTEM_DEFAULT_PREFIX: &str = "System default — ";
pub const USAGE_CARD_NO_USAGE: &str = "no usage data";

/// One window: its label, a bar filled to `fraction`, the percentage in the
/// severity color, and the time until it resets.
#[derive(Debug, Clone, PartialEq)]
pub struct UsageCardLine {
    pub label: String,
    pub fraction: f64,
    pub percent: String,
    pub severity: UsageSeverity,
    pub reset: Option<String>,
}

impl UsageCard {
    pub fn build(snapshot: &AccountsSnapshot, now: &Timestamp) -> Self {
        let mut providers: Vec<UsageCardProvider> = Vec::new();
        for id in AccountListId::ALL {
            let Some(list) = snapshot.lists.get(&id) else { continue };
            if list.accounts.is_empty() && list.system_default.is_none() {
                continue;
            }
            if providers.last().is_none_or(|last| last.provider != id.provider) {
                providers.push(UsageCardProvider {
                    provider: id.provider,
                    eyebrow: id.provider.display_name().to_uppercase(),
                    lists: Vec::new(),
                });
            }
            let mut rows = Vec::new();
            if let Some(system_default) = &list.system_default {
                rows.push(card_row(system_default, list.selected_account_id.is_none(), true, now));
            }
            for account in &list.accounts {
                let is_selected = list.selected_account_id.as_deref() == Some(account.id.as_str());
                rows.push(card_row(account, is_selected, false, now));
            }
            if let Some(provider) = providers.last_mut() {
                provider.lists.push(UsageCardList { list: id, caption: caption(list), rows });
            }
        }
        Self {
            empty_text: providers.is_empty().then_some("No accounts yet."),
            providers,
            refresh: Button::new(
                if snapshot.is_refreshing { "Refreshing…" } else { "Refresh" },
                PageAction::Refresh { force: true },
            )
            .enabled(!snapshot.is_refreshing),
            manage_accounts: Button::new("Manage Accounts…", PageAction::ManageAccounts),
        }
    }
}

/// "omp · automatic" until a login is preferred, then the tool's name.
pub fn caption(list: &AccountList) -> String {
    if list.id.tool == AccountTool::Omp && list.selected_account_id.is_none() {
        format!("{} · automatic", list.id.tool.display_name())
    } else {
        list.id.tool.display_name().to_owned()
    }
}

fn card_row(row: &AccountRow, is_selected: bool, is_system_default: bool, now: &Timestamp) -> UsageCardRow {
    let problem = row.problem.clone().filter(|problem| !problem.is_empty());
    let email = &row.identity.email;
    let tooltip = match (&problem, &row.organization_name) {
        (Some(problem), _) => problem.clone(),
        (None, Some(organization)) => format!("{email} · {organization}"),
        (None, None) => email.clone(),
    };
    UsageCardRow {
        is_system_default,
        name: if email.is_empty() { row.problem.clone().unwrap_or_default() } else { email.clone() },
        is_selected,
        has_problem: problem.is_some(),
        tooltip,
        windows: row
            .usage
            .as_ref()
            .map(|usage| usage.windows.iter().map(|window| card_line(window, now)).collect())
            .unwrap_or_default(),
    }
}

fn card_line(window: &UsageWindow, now: &Timestamp) -> UsageCardLine {
    UsageCardLine {
        label: window.label.clone(),
        fraction: window.used_fraction,
        percent: usage_format::percent(window.used_fraction),
        severity: UsageSeverity::of(window.used_fraction),
        reset: usage_format::time_until(window.resets_at.as_ref(), now),
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::BTreeMap;

    use chrono::Duration;

    use super::*;
    use crate::models::{AccountIdentity, AccountUsage, PendingLogin, timestamp_from_seconds};

    /// An accounts source that records what the page asks of it.
    struct FakeAccounts {
        snapshot: RefCell<AccountsSnapshot>,
        calls: RefCell<Vec<String>>,
        observers: RefCell<BTreeMap<String, SnapshotObserver>>,
    }

    impl FakeAccounts {
        fn new(snapshot: AccountsSnapshot) -> Self {
            Self {
                snapshot: RefCell::new(snapshot),
                calls: RefCell::default(),
                observers: RefCell::default(),
            }
        }

        fn last_call(&self) -> Option<String> {
            self.calls.borrow().last().cloned()
        }

        fn list_name(list: AccountListId) -> String {
            format!("{}/{}", list.provider.raw_value(), list.tool.raw_value())
        }
    }

    impl AccountsSource for FakeAccounts {
        fn snapshot(&self) -> AccountsSnapshot {
            self.snapshot.borrow().clone()
        }
        fn add_observer(&self, id: &str, handler: SnapshotObserver) {
            self.observers.borrow_mut().insert(id.into(), handler);
        }
        fn remove_observer(&self, id: &str) {
            self.observers.borrow_mut().remove(id);
        }
        fn refresh(&self, force: bool) {
            self.calls.borrow_mut().push(format!("refresh force={force}"));
        }
        fn add_account(&self, list: AccountListId) {
            self.calls.borrow_mut().push(format!("add {}", Self::list_name(list)));
        }
        fn reauthenticate(&self, account_id: &str, _: AccountListId) {
            self.calls.borrow_mut().push(format!("reauthenticate {account_id}"));
        }
        fn cancel_login(&self) {
            self.calls.borrow_mut().push("cancel".into());
        }
        fn select(&self, account_id: Option<&str>, list: AccountListId) {
            self.calls.borrow_mut().push(format!(
                "select {} in {}",
                account_id.unwrap_or("default"),
                Self::list_name(list)
            ));
        }
        fn remove(&self, account_id: &str, _: AccountListId) {
            self.calls.borrow_mut().push(format!("remove {account_id}"));
        }
        fn dismiss_error(&self, list: AccountListId) {
            self.calls.borrow_mut().push(format!("dismiss {}", list.tool.raw_value()));
        }
    }

    fn now() -> Timestamp {
        timestamp_from_seconds(1_800_000_000.0).unwrap()
    }

    fn row(email: &str, org: Option<&str>, plan: &str, windows: &[(&str, f64, i64)]) -> AccountRow {
        AccountRow {
            id: email.into(),
            identity: AccountIdentity::new(email, None),
            organization_name: org.map(str::to_owned),
            plan: Some(plan.into()),
            usage: Some(AccountUsage {
                windows: windows
                    .iter()
                    .map(|(label, fraction, seconds)| UsageWindow {
                        label: (*label).into(),
                        used_fraction: *fraction,
                        resets_at: Some(now() + Duration::seconds(*seconds)),
                    })
                    .collect(),
                fetched_at: now(),
            }),
            ..AccountRow::default()
        }
    }

    /// omp's Claude list with a preferred login, Claude Code on its system
    /// default, omp's Codex list on automatic, and an unreadable Codex CLI.
    fn demo_snapshot() -> AccountsSnapshot {
        let ada = row(
            "ada@example.com",
            Some("Ada's Workshop"),
            "max",
            &[("5h", 0.09, 14_040), ("7d", 0.06, 494_400)],
        );
        let grace = row(
            "grace@example.com",
            Some("Analytical Engines"),
            "team",
            &[("5h", 0.72, 2_820), ("7d", 0.93, 187_200), ("7d opus", 0.41, 187_200)],
        );
        let ada_codex = row("ada@example.com", None, "plus", &[("5h", 0.75, 4_320), ("7d", 0.38, 525_600)]);
        let mut snapshot = AccountsSnapshot::default();
        snapshot.lists.insert(
            AccountListId::OMP_CLAUDE,
            AccountList {
                accounts: vec![ada.clone(), grace.clone()],
                selected_account_id: Some("grace@example.com".into()),
                ..AccountList::new(AccountListId::OMP_CLAUDE)
            },
        );
        snapshot.lists.insert(
            AccountListId::CLAUDE_CODE,
            AccountList {
                system_default: Some(ada),
                accounts: vec![grace],
                ..AccountList::new(AccountListId::CLAUDE_CODE)
            },
        );
        snapshot.lists.insert(
            AccountListId::OMP_CODEX,
            AccountList { accounts: vec![ada_codex], ..AccountList::new(AccountListId::OMP_CODEX) },
        );
        snapshot.lists.insert(
            AccountListId::CODEX_CLI,
            AccountList {
                unavailable_reason: Some("The codex CLI was not found on PATH.".into()),
                ..AccountList::new(AccountListId::CODEX_CLI)
            },
        );
        snapshot.last_refresh = Some(now() - Duration::seconds(240));
        snapshot
    }

    /// The login rows titled `title`, in page order.
    fn rows<'a>(page: &'a AccountsPage, title: &str) -> Vec<&'a EntryRow> {
        page.sections
            .iter()
            .flat_map(|section| match &section.body {
                SectionBody::Rows(rows) => rows.iter().collect(),
                _ => Vec::new(),
            })
            .filter(|row| row.title == title)
            .collect()
    }

    fn all_buttons(page: &AccountsPage) -> Vec<&Button> {
        let mut buttons = vec![&page.refresh];
        for section in &page.sections {
            if let SectionBody::Rows(rows) = &section.body {
                buttons.extend(rows.iter().flat_map(|row| row.buttons.iter()));
            }
            match &section.footer {
                SectionFooter::Pending { buttons: footer, .. } => buttons.extend(footer.iter()),
                SectionFooter::Add(add) => buttons.push(add),
            }
        }
        buttons
    }

    #[test]
    fn opening_the_accounts_page_refreshes_without_forcing() {
        let accounts = FakeAccounts::new(demo_snapshot());
        AccountsPage::on_open(&accounts);
        assert_eq!(*accounts.calls.borrow(), ["refresh force=false"]);
    }

    #[test]
    fn the_preferred_omp_login_is_badged_and_offers_no_prefer_button() {
        let accounts = FakeAccounts::new(demo_snapshot());
        let page = AccountsPage::build(&accounts.snapshot(), &now());

        // omp's Claude list is first; Claude Code lists grace as well.
        let grace = rows(&page, "grace@example.com")[0];
        assert_eq!(grace.badge, Some("Preferred"));
        assert!(!grace.buttons.iter().any(|button| button.title == "Prefer"));
        assert!(
            grace
                .buttons
                .iter()
                .any(|b| b.title == "Remove" && b.variant == ButtonVariant::DestructiveOutline)
        );

        let ada = rows(&page, "ada@example.com")[0];
        assert_eq!(ada.badge, None);
        let prefer = ada.buttons.iter().find(|button| button.title == "Prefer").unwrap();
        prefer.action.perform(&accounts);
        assert_eq!(accounts.last_call().as_deref(), Some("select ada@example.com in claude/omp"));
    }

    #[test]
    fn the_cli_lists_offer_their_system_default_and_the_unreadable_one_says_why() {
        let page = AccountsPage::build(&demo_snapshot(), &now());

        let system_default = rows(&page, "System default")[0];
        assert_eq!(system_default.badge, Some("Active"));
        assert!(system_default.detail.starts_with("ada@example.com"));
        assert!(system_default.detail.contains("5h 9%"));
        assert_eq!(
            system_default.detail,
            "ada@example.com  ·  Ada's Workshop  ·  max  ·  5h 9% · 3h 54m  ·  7d 6% · 5d 17h"
        );
        let codex = page.sections.iter().find(|section| section.list == AccountListId::CODEX_CLI).unwrap();
        assert_eq!(codex.body, SectionBody::Unavailable("The codex CLI was not found on PATH.".into()));
        assert_eq!(codex.title, "Codex · Codex CLI");
        assert_eq!(page.updated, "Updated 4m ago");
    }

    #[test]
    fn a_running_sign_in_disables_add_account_and_offers_cancel_on_its_list() {
        let mut snapshot = demo_snapshot();
        snapshot.pending_login = Some(PendingLogin {
            list: AccountListId::OMP_CODEX,
            account_id: None,
            sign_in_url: Some("https://example.com/login".into()),
        });
        let accounts = FakeAccounts::new(snapshot);
        let page = AccountsPage::build(&accounts.snapshot(), &now());

        let adds: Vec<&Button> =
            all_buttons(&page).into_iter().filter(|b| b.title == "Add Account").collect();
        assert!(!adds.is_empty());
        assert!(adds.iter().all(|add| !add.is_enabled));
        let codex = page.sections.iter().find(|section| section.list == AccountListId::OMP_CODEX).unwrap();
        let SectionFooter::Pending { text, .. } = &codex.footer else { panic!("no pending footer") };
        assert_eq!(text, "Waiting for sign-in in your browser…");
        assert!(all_buttons(&page).iter().any(|button| button.title == "Open Sign-in Page"));
        assert!(all_buttons(&page).iter().filter(|b| b.title == "Re-authenticate").all(|b| !b.is_enabled));

        let cancel = all_buttons(&page).into_iter().find(|button| button.title == "Cancel").unwrap();
        cancel.action.perform(&accounts);
        assert_eq!(accounts.last_call().as_deref(), Some("cancel"));
    }

    #[test]
    fn a_snapshot_change_rerenders_the_open_accounts_page() {
        let accounts = FakeAccounts::new(demo_snapshot());
        let page = AccountsPage::build(&accounts.snapshot(), &now());
        assert_eq!(rows(&page, "grace@example.com")[0].badge, Some("Preferred"));

        let mut next = accounts.snapshot();
        if let Some(list) = next.lists.get_mut(&AccountListId::OMP_CLAUDE) {
            list.selected_account_id = None;
        }
        let page = AccountsPage::build(&next, &now());

        let automatic = rows(&page, "Automatic")[0];
        assert_eq!(automatic.badge, Some("Active"));
        assert_eq!(rows(&page, "grace@example.com")[0].badge, None);
    }

    #[test]
    fn removing_a_login_asks_first_and_explains_what_happens() {
        let accounts = FakeAccounts::new(demo_snapshot());
        let page = AccountsPage::build(&accounts.snapshot(), &now());
        let grace = rows(&page, "grace@example.com")[1];
        let remove = grace.buttons.iter().find(|button| button.title == "Remove").unwrap();

        let confirmation = remove.action.perform(&accounts).unwrap();
        assert!(accounts.calls.borrow().is_empty());
        assert_eq!(confirmation.title, "Remove grace@example.com?");
        assert_eq!(confirmation.message, removal_explanation(AccountTool::ClaudeCode));

        assert_eq!(confirmation.action.perform(&accounts), None);
        assert_eq!(accounts.last_call().as_deref(), Some("remove grace@example.com"));
    }

    #[test]
    fn the_refresh_text_ages_in_minutes_hours_and_days() {
        let mut snapshot = AccountsSnapshot::default();
        assert_eq!(refresh_text(&snapshot, &now()), "Not updated yet");
        snapshot.last_refresh = Some(now() - Duration::seconds(30));
        assert_eq!(refresh_text(&snapshot, &now()), "Updated just now");
        snapshot.last_refresh = Some(now() - Duration::seconds(3 * 3600));
        assert_eq!(refresh_text(&snapshot, &now()), "Updated 3h ago");
        snapshot.last_refresh = Some(now() - Duration::seconds(50 * 3600));
        assert_eq!(refresh_text(&snapshot, &now()), "Updated 2d ago");
        snapshot.is_refreshing = true;
        assert_eq!(refresh_text(&snapshot, &now()), "Updating…");
    }

    #[test]
    fn the_status_bar_shows_each_providers_tightest_window_with_its_reset() {
        let snapshot = demo_snapshot();
        let segments = status_usage(&snapshot, &now());

        // Claude: omp's preferred grace, whose 7d window is tightest.
        assert_eq!(segments[0].text(), "Claude 93% · 2d 4h");
        assert_eq!(segments[0].severity, UsageSeverity::Danger);
        // Codex: omp's only login.
        assert_eq!(segments[1].text(), "Codex 75% · 1h 12m");
        assert_eq!(segments[1].severity, UsageSeverity::Warning);
        assert_eq!(
            status_usage_text(&snapshot, &now()).as_deref(),
            Some("Claude 93% · 2d 4h  |  Codex 75% · 1h 12m")
        );
        assert_eq!(status_usage_text(&AccountsSnapshot::default(), &now()), None);
    }

    #[test]
    fn the_usage_card_groups_lists_by_provider_with_captions_and_marks() {
        let card = UsageCard::build(&demo_snapshot(), &now());

        assert_eq!(
            card.providers.iter().map(|p| p.eyebrow.as_str()).collect::<Vec<_>>(),
            ["CLAUDE", "CODEX"]
        );
        let claude = &card.providers[0];
        assert_eq!(
            claude.lists.iter().map(|l| l.caption.as_str()).collect::<Vec<_>>(),
            ["omp", "Claude Code"]
        );
        assert!(claude.lists[0].rows[1].is_selected);
        let system_default = &claude.lists[1].rows[0];
        assert!(system_default.is_system_default && system_default.is_selected);
        assert_eq!(system_default.tooltip, "ada@example.com · Ada's Workshop");
        assert_eq!(system_default.windows[0].reset.as_deref(), Some("3h 54m"));
        // The unreadable Codex CLI list has no logins to show.
        assert_eq!(card.providers[1].lists.len(), 1);
        assert_eq!(card.providers[1].lists[0].caption, "omp · automatic");
        assert_eq!(
            UsageCard::build(&AccountsSnapshot::default(), &now()).empty_text,
            Some("No accounts yet.")
        );
    }
}
