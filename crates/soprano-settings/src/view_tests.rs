//! View behavior, headless (`SettingsWindowTransitionTests`, `SettingsAccountsPageTests`, the
//! view parts of `SettingsConfigWritingTests` and `NotificationSettingsTests`).

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::rc::Rc;
use std::sync::Arc;

use gpui::{Entity, TestAppContext, VisualTestContext};
use soprano_accounts::chrono::{Duration, Utc};
use soprano_accounts::models::{
    AccountIdentity, AccountList, AccountListId, AccountRow, AccountUsage, AccountsSnapshot, UsageWindow,
};
use soprano_accounts::presentation::PageAction;
use soprano_accounts::{AccountsSource, SnapshotObserver};
use soprano_config::{AppSettings, ConfigStore, DefaultKeybindings, Severity, config_file};
use soprano_types::{AgentCatalog, DefaultAgents};

use crate::notifications::NotificationAuthorization;
use crate::usage_popover::{AccountUsagePopover, UsagePopoverEvent};
use crate::view::{Recording, SettingsEvent, SettingsView};
use crate::{NotificationStatusProvider, SettingsTab};

/// An accounts source that records what Settings asks of it.
#[derive(Default)]
struct FakeAccounts {
    snapshot: RefCell<AccountsSnapshot>,
    calls: RefCell<Vec<String>>,
    observers: RefCell<BTreeMap<String, SnapshotObserver>>,
}

impl FakeAccounts {
    fn new(snapshot: AccountsSnapshot) -> Rc<Self> {
        Rc::new(Self { snapshot: RefCell::new(snapshot), ..Self::default() })
    }

    fn publish(&self, next: AccountsSnapshot) {
        *self.snapshot.borrow_mut() = next.clone();
        let observers: Vec<SnapshotObserver> = self.observers.borrow().values().cloned().collect();
        for observer in observers {
            observer(&next);
        }
    }

    fn calls(&self) -> Vec<String> {
        self.calls.borrow().clone()
    }

    fn record(&self, call: String) {
        self.calls.borrow_mut().push(call);
    }
}

fn list_name(list: AccountListId) -> String {
    format!("{}/{}", list.provider.raw_value(), list.tool.raw_value())
}

impl AccountsSource for FakeAccounts {
    fn snapshot(&self) -> AccountsSnapshot {
        self.snapshot.borrow().clone()
    }
    fn add_observer(&self, id: &str, handler: SnapshotObserver) {
        self.observers.borrow_mut().insert(id.to_owned(), handler);
    }
    fn remove_observer(&self, id: &str) {
        self.observers.borrow_mut().remove(id);
    }
    fn refresh(&self, force: bool) {
        self.record(format!("refresh force={force}"));
    }
    fn add_account(&self, list: AccountListId) {
        self.record(format!("add {}", list_name(list)));
    }
    fn reauthenticate(&self, account_id: &str, _: AccountListId) {
        self.record(format!("reauthenticate {account_id}"));
    }
    fn cancel_login(&self) {
        self.record("cancel".into());
    }
    fn select(&self, account_id: Option<&str>, list: AccountListId) {
        self.record(format!("select {} in {}", account_id.unwrap_or("default"), list_name(list)));
    }
    fn remove(&self, account_id: &str, _: AccountListId) {
        self.record(format!("remove {account_id}"));
    }
    fn dismiss_error(&self, list: AccountListId) {
        self.record(format!("dismiss {}", list.tool.raw_value()));
    }
}

/// omp's Claude list with a preferred login, Claude Code on its system default, omp's Codex
/// list on automatic, and an unreadable Codex CLI.
fn demo_snapshot() -> AccountsSnapshot {
    let now = Utc::now();
    let row = |email: &str, plan: &str, windows: &[(&str, f64, i64)]| AccountRow {
        id: email.to_owned(),
        identity: AccountIdentity::new(email, None),
        plan: Some(plan.to_owned()),
        usage: Some(AccountUsage {
            windows: windows
                .iter()
                .map(|(label, fraction, seconds)| UsageWindow {
                    label: (*label).to_owned(),
                    used_fraction: *fraction,
                    resets_at: Some(now + Duration::seconds(*seconds)),
                })
                .collect(),
            fetched_at: now,
        }),
        ..AccountRow::default()
    };
    let ada = row("ada@example.com", "max", &[("5h", 0.09, 14_040), ("7d", 0.06, 494_400)]);
    let grace = row("grace@example.com", "team", &[("5h", 0.72, 2_820), ("7d", 0.93, 187_200)]);
    let mut lists = HashMap::new();
    let mut omp = AccountList::new(AccountListId::OMP_CLAUDE);
    omp.accounts = vec![ada.clone(), grace.clone()];
    omp.selected_account_id = Some(grace.id.clone());
    lists.insert(AccountListId::OMP_CLAUDE, omp);
    let mut claude = AccountList::new(AccountListId::CLAUDE_CODE);
    claude.system_default = Some(ada);
    claude.accounts = vec![grace];
    lists.insert(AccountListId::CLAUDE_CODE, claude);
    let mut codex = AccountList::new(AccountListId::CODEX_CLI);
    codex.unavailable_reason = Some("The codex CLI was not found on PATH.".to_owned());
    lists.insert(AccountListId::CODEX_CLI, codex);
    AccountsSnapshot { lists, last_refresh: Some(now - Duration::minutes(4)), ..AccountsSnapshot::default() }
}

/// A switchable notification permission.
struct Permission(RefCell<Option<NotificationAuthorization>>);

impl NotificationStatusProvider for Permission {
    fn authorization(&self) -> Option<NotificationAuthorization> {
        *self.0.borrow()
    }
}

struct Harness {
    view: Entity<SettingsView>,
    store: ConfigStore,
    accounts: Rc<FakeAccounts>,
    permission: Rc<Permission>,
    events: Rc<RefCell<Vec<SettingsEvent>>>,
    _directory: tempfile::TempDir,
}

fn open(cx: &mut TestAppContext) -> (Harness, &mut VisualTestContext) {
    cx.update(soprano_ui::init_for_tests);
    let directory = tempfile::tempdir().expect("temp dir");
    let store = ConfigStore::with_catalog(
        directory.path().join("settings.json"),
        Arc::new(AgentCatalog::new(DefaultAgents::all())),
    );
    store.start(false, &AppSettings::default(), &DefaultKeybindings::config());
    let accounts = FakeAccounts::new(demo_snapshot());
    let permission = Rc::new(Permission(RefCell::new(None)));
    let (view, cx) = cx.add_window_view({
        let store = store.clone();
        let accounts: Rc<dyn AccountsSource> = accounts.clone();
        let permission: Rc<dyn NotificationStatusProvider> = permission.clone();
        move |window, cx| SettingsView::new(store, accounts, permission, window, cx)
    });
    let events = Rc::new(RefCell::new(Vec::new()));
    cx.update({
        let events = events.clone();
        let view = view.clone();
        move |_, cx| {
            cx.subscribe(&view, move |_, event: &SettingsEvent, _| events.borrow_mut().push(event.clone()))
                .detach();
        }
    });
    cx.run_until_parked();
    (Harness { view, store, accounts, permission, events, _directory: directory }, cx)
}

fn file_text(store: &ConfigStore) -> String {
    std::fs::read_to_string(store.file_path()).unwrap_or_default()
}

// MARK: - Closing (SettingsWindowTransitionTests)

#[gpui::test]
fn esc_closes_the_screen(cx: &mut TestAppContext) {
    let (h, cx) = open(cx);
    cx.simulate_keystrokes("escape");
    assert_eq!(*h.events.borrow(), vec![SettingsEvent::Close]);
}

#[gpui::test]
fn esc_while_recording_the_prefix_ends_the_recording_and_keeps_settings_open(cx: &mut TestAppContext) {
    let (h, cx) = open(cx);
    h.view.update_in(cx, |view, window, cx| view.begin_prefix_recording(window, cx));
    assert!(h.view.read_with(cx, |view, _| view.captures_keys()));

    cx.simulate_keystrokes("escape");
    assert!(h.events.borrow().is_empty());
    assert!(!h.view.read_with(cx, |view, _| view.captures_keys()));
    assert_eq!(h.store.keybindings().prefix_key, "a");

    // Not recording, the same Esc reaches the card and closes Settings.
    cx.simulate_keystrokes("escape");
    assert_eq!(*h.events.borrow(), vec![SettingsEvent::Close]);
}

#[gpui::test]
fn esc_in_the_shortcut_filter_clears_the_query_before_closing(cx: &mut TestAppContext) {
    let (h, cx) = open(cx);
    h.view.update_in(cx, |view, window, cx| {
        view.switch_tab(SettingsTab::KeyboardShortcuts, window, cx);
        view.set_shortcut_query("split", window, cx);
    });
    cx.simulate_keystrokes("escape");
    assert!(h.events.borrow().is_empty());
    assert_eq!(h.view.read_with(cx, |view, cx| view.shortcut_query(cx)), "");

    cx.simulate_keystrokes("escape");
    assert_eq!(*h.events.borrow(), vec![SettingsEvent::Close]);
}

#[gpui::test]
fn switching_pages_keeps_one_page_on_screen(cx: &mut TestAppContext) {
    let (h, cx) = open(cx);
    for tab in SettingsTab::ALL {
        h.view.update_in(cx, |view, window, cx| view.switch_tab(tab, window, cx));
        cx.run_until_parked();
        assert_eq!(h.view.read_with(cx, |view, _| view.current_tab()), tab);
    }
}

// MARK: - Writing (SettingsConfigWritingTests, view parts)

#[gpui::test]
fn recording_a_prefix_key_writes_it_and_shows_it_as_a_control_chord(cx: &mut TestAppContext) {
    let (h, cx) = open(cx);
    h.view.update_in(cx, |view, window, cx| view.begin_prefix_recording(window, cx));
    cx.simulate_keystrokes("b");
    assert_eq!(h.store.keybindings().prefix_key, "b");
    assert!(file_text(&h.store).contains("\"prefixKey\": \"b\""));
    assert!(!h.view.read_with(cx, |view, _| view.captures_keys()));
}

#[gpui::test]
fn a_prefix_key_that_needs_shift_is_refused_and_the_recording_goes_on(cx: &mut TestAppContext) {
    let (h, cx) = open(cx);
    h.view.update_in(cx, |view, window, cx| view.begin_prefix_recording(window, cx));
    cx.simulate_keystrokes("shift-1");
    assert_eq!(h.store.keybindings().prefix_key, "a");
    assert!(h.view.read_with(cx, |view, _| view.recording == Some(Recording::Prefix)));
    // A shifted letter is still that letter.
    cx.simulate_keystrokes("shift-b");
    assert_eq!(h.store.keybindings().prefix_key, "b");
}

#[gpui::test]
fn recording_a_shortcut_rebinds_it_by_id(cx: &mut TestAppContext) {
    let (h, cx) = open(cx);
    h.view.update_in(cx, |view, window, cx| {
        view.switch_tab(SettingsTab::KeyboardShortcuts, window, cx);
        view.begin_binding_recording("new-tab", window, cx);
    });
    assert!(h.view.read_with(cx, |view, _| view.captures_keys()));
    cx.simulate_keystrokes("ctrl-k");
    assert!(file_text(&h.store).contains("\"new-tab\": \"ctrl+k\""), "{}", file_text(&h.store));
    assert!(h.store.resolved().customized_binding_ids.contains("new-tab"));
    assert!(!h.view.read_with(cx, |view, _| view.captures_keys()));
}

#[gpui::test]
fn backspace_while_recording_turns_the_shortcut_off(cx: &mut TestAppContext) {
    let (h, cx) = open(cx);
    h.view.update_in(cx, |view, window, cx| {
        view.switch_tab(SettingsTab::KeyboardShortcuts, window, cx);
        view.begin_binding_recording("new-tab", window, cx);
    });
    cx.simulate_keystrokes("backspace");
    assert!(h.store.resolved().disabled_binding_ids.contains("new-tab"));
}

#[gpui::test]
fn adding_or_removing_a_project_directory_keeps_the_typed_field(cx: &mut TestAppContext) {
    let (h, cx) = open(cx);
    let folder = h._directory.path().join("project");
    std::fs::create_dir(&folder).expect("folder");
    let path = folder.display().to_string();
    h.view.update_in(cx, |view, window, cx| view.add_project_directory(&path, window, cx));
    cx.run_until_parked();
    assert_eq!(h.store.settings().project_directories, vec![soprano_config::expand_path(&path)]);

    h.view.update_in(cx, |view, window, cx| view.remove_project_directory(0, window, cx));
    cx.run_until_parked();
    assert!(h.store.settings().project_directories.is_empty());
}

#[gpui::test]
fn editing_the_prefix_timeout_clamps_and_writes_the_nested_key(cx: &mut TestAppContext) {
    let (h, cx) = open(cx);
    h.view.update_in(cx, |view, window, cx| {
        view.timeout_input.update(cx, |state, cx| state.set_value("99999", window, cx));
        view.commit_prefix_timeout(window, cx);
    });
    assert_eq!(h.store.keybindings().prefix_timeout_ms, 5000);
    assert!(file_text(&h.store).contains("\"prefixTimeoutMs\": 5000"));
    let shown = h.view.read_with(cx, |view, cx| view.timeout_input.read(cx).value().to_string());
    assert_eq!(shown, "5000");

    // Text that is not a number reverts to the value in force.
    h.view.update_in(cx, |view, window, cx| {
        view.timeout_input.update(cx, |state, cx| state.set_value("soon", window, cx));
        view.commit_prefix_timeout(window, cx);
    });
    let shown = h.view.read_with(cx, |view, cx| view.timeout_input.read(cx).value().to_string());
    assert_eq!(shown, "5000");
}

#[gpui::test]
fn a_breakage_that_changes_no_values_still_raises_a_banner_on_the_open_screen(cx: &mut TestAppContext) {
    let (h, cx) = open(cx);
    assert!(h.view.read_with(cx, |view, _| view.snapshot.issues().is_empty()));

    config_file::write("{\n  \"theme\":\n}", h.store.file_path()).expect("write");
    h.store.reload_from_disk();
    // Values are untouched on purpose — only the issue list moved.
    assert_eq!(h.store.settings(), AppSettings::default());
    cx.run_until_parked();

    let issues = h.view.read_with(cx, |view, _| view.snapshot.issues());
    let error = issues.iter().find(|issue| issue.severity == Severity::Error).expect("an error");
    assert_eq!(error.line, Some(3));
}

#[gpui::test]
fn a_config_problem_is_shown_on_the_settings_screen_instead_of_failing_silently(cx: &mut TestAppContext) {
    let (h, cx) = open(cx);
    config_file::write("{ \"theme\": \"no-such-theme\" }", h.store.file_path()).expect("write");
    h.store.reload_from_disk();
    cx.run_until_parked();
    let issues = h.view.read_with(cx, |view, _| view.snapshot.issues());
    assert!(
        issues
            .iter()
            .any(|issue| issue.severity == Severity::Warning && issue.message.contains("no-such-theme"))
    );
}

#[gpui::test]
fn the_reset_button_removes_the_key_so_the_default_applies(cx: &mut TestAppContext) {
    let (h, cx) = open(cx);
    h.view.update_in(cx, |view, window, cx| {
        view.write(true, crate::general::STATUS_BAR_UPTIME_KEY, window, cx)
    });
    assert!(h.store.settings().status_bar_uptime);
    h.view.update_in(cx, |view, window, cx| view.reset(crate::general::STATUS_BAR_UPTIME_KEY, window, cx));
    assert!(!h.store.settings().status_bar_uptime);
    assert!(!file_text(&h.store).contains("\"uptime\""));
}

#[gpui::test]
fn the_notification_line_follows_the_permission_the_app_reports(cx: &mut TestAppContext) {
    let (h, cx) = open(cx);
    assert_eq!(h.view.read_with(cx, |view, _| view.authorization), None);
    *h.permission.0.borrow_mut() = Some(NotificationAuthorization::Denied);
    h.view.update(cx, |view, cx| view.notification_authorization_changed(cx));
    assert_eq!(h.view.read_with(cx, |view, _| view.authorization), Some(NotificationAuthorization::Denied));
}

// MARK: - Accounts (SettingsAccountsPageTests)

#[gpui::test]
fn opening_the_accounts_page_refreshes_without_forcing(cx: &mut TestAppContext) {
    let (h, cx) = open(cx);
    h.view.update_in(cx, |view, window, cx| view.switch_tab(SettingsTab::Accounts, window, cx));
    cx.run_until_parked();
    assert_eq!(h.accounts.calls(), vec!["refresh force=false"]);
}

#[gpui::test]
fn page_buttons_act_on_the_accounts_source(cx: &mut TestAppContext) {
    let (h, cx) = open(cx);
    h.view.update_in(cx, |view, window, cx| {
        view.switch_tab(SettingsTab::Accounts, window, cx);
        view.perform_account_action(
            PageAction::Select {
                list: AccountListId::OMP_CLAUDE,
                account_id: Some("ada@example.com".into()),
            },
            window,
            cx,
        );
        view.perform_account_action(PageAction::CancelLogin, window, cx);
    });
    assert_eq!(
        h.accounts.calls(),
        vec!["refresh force=false", "select ada@example.com in claude/omp", "cancel"]
    );
}

#[gpui::test]
fn removing_an_account_asks_first(cx: &mut TestAppContext) {
    let (h, cx) = open(cx);
    h.view.update_in(cx, |view, window, cx| {
        view.perform_account_action(
            PageAction::ConfirmRemove {
                list: AccountListId::OMP_CLAUDE,
                account_id: "ada@example.com".into(),
                email: "ada@example.com".into(),
            },
            window,
            cx,
        );
    });
    assert!(h.view.read_with(cx, |view, _| view.is_confirming()));
    assert!(h.accounts.calls().is_empty());
    // Esc cancels the dialog, not the screen.
    cx.simulate_keystrokes("escape");
    cx.run_until_parked();
    assert!(!h.view.read_with(cx, |view, _| view.is_confirming()));
    assert!(h.accounts.calls().is_empty());
    assert!(h.events.borrow().is_empty());
}

#[gpui::test]
fn a_snapshot_change_rerenders_the_open_accounts_page(cx: &mut TestAppContext) {
    let (h, cx) = open(cx);
    h.view.update_in(cx, |view, window, cx| view.switch_tab(SettingsTab::Accounts, window, cx));
    let mut next = h.accounts.snapshot();
    if let Some(list) = next.lists.get_mut(&AccountListId::OMP_CLAUDE) {
        list.selected_account_id = None;
    }
    h.accounts.publish(next.clone());
    cx.run_until_parked();
    assert_eq!(h.view.read_with(cx, |view, _| view.accounts_snapshot.clone()), next);
}

#[gpui::test]
fn closing_the_screen_stops_observing_the_store_and_the_accounts(cx: &mut TestAppContext) {
    let (h, cx) = open(cx);
    assert_eq!(h.accounts.observers.borrow().len(), 1);
    let Harness { view, accounts, .. } = h;
    cx.update(|window, _| window.remove_window());
    drop(view);
    cx.cx.update(|_| {});
    cx.run_until_parked();
    assert!(accounts.observers.borrow().is_empty());
}

// MARK: - Usage popover

#[gpui::test]
fn the_usage_popover_follows_the_accounts_and_hands_manage_accounts_to_the_host(cx: &mut TestAppContext) {
    cx.update(soprano_ui::init_for_tests);
    let accounts = FakeAccounts::new(demo_snapshot());
    let (popover, cx) = cx.add_window_view({
        let accounts: Rc<dyn AccountsSource> = accounts.clone();
        move |window, cx| AccountUsagePopover::new(accounts, window, cx)
    });
    let events = Rc::new(RefCell::new(Vec::new()));
    cx.update({
        let events = events.clone();
        let popover = popover.clone();
        move |_, cx| {
            cx.subscribe(&popover, move |_, event: &UsagePopoverEvent, _| events.borrow_mut().push(*event))
                .detach();
        }
    });
    let mut next = accounts.snapshot();
    next.is_refreshing = true;
    accounts.publish(next.clone());
    cx.run_until_parked();
    assert_eq!(popover.read_with(cx, |popover, _| popover.snapshot().clone()), next);

    popover.update(cx, |popover, cx| popover.perform(PageAction::ManageAccounts, cx));
    assert_eq!(*events.borrow(), vec![UsagePopoverEvent::ManageAccounts]);
    popover.update(cx, |popover, cx| popover.perform(PageAction::Refresh { force: true }, cx));
    assert_eq!(accounts.calls(), vec!["refresh force=true"]);
}

#[test]
fn the_page_column_caps_at_768_and_narrows_with_the_card() {
    use crate::view::{CARD_MARGIN, PAGE_MAX_WIDTH, page_width};
    assert_eq!(page_width(1800.0 - CARD_MARGIN * 2.0), PAGE_MAX_WIDTH);
    assert_eq!(page_width(900.0 - CARD_MARGIN * 2.0), 900.0 - 64.0 - 240.0 - 48.0);
    assert_eq!(page_width(400.0), 320.0);
}
