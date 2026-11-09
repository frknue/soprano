//! The Settings card over a throwaway settings.json, with demo accounts:
//! `cargo run -p soprano-settings --example settings_demo`.

use std::collections::HashMap;
use std::rc::Rc;

use gpui::{App, AppContext as _, Bounds, WindowBounds, WindowOptions, px, size};
use gpui_component::Root;
use soprano_accounts::chrono::{Duration, Utc};
use soprano_accounts::models::{
    AccountIdentity, AccountList, AccountListId, AccountRow, AccountUsage, AccountsSnapshot, UsageWindow,
};
use soprano_accounts::{AccountsSource, SnapshotObserver};
use soprano_config::{AppSettings, ConfigStore, DefaultKeybindings};
use soprano_settings::{NotificationAuthorization, SettingsEvent, SettingsView};
use soprano_ui::{AppearancePreference, SopranoAssets};

/// Accounts that answer with one fixed snapshot and print what they are asked to do.
struct DemoAccounts {
    snapshot: AccountsSnapshot,
}

impl AccountsSource for DemoAccounts {
    fn snapshot(&self) -> AccountsSnapshot {
        self.snapshot.clone()
    }
    fn add_observer(&self, _: &str, _: SnapshotObserver) {}
    fn remove_observer(&self, _: &str) {}
    fn refresh(&self, force: bool) {
        println!("refresh force={force}");
    }
    fn add_account(&self, list: AccountListId) {
        println!("add account to {list:?}");
    }
    fn reauthenticate(&self, account_id: &str, _: AccountListId) {
        println!("re-authenticate {account_id}");
    }
    fn cancel_login(&self) {
        println!("cancel login");
    }
    fn select(&self, account_id: Option<&str>, list: AccountListId) {
        println!("select {account_id:?} in {list:?}");
    }
    fn remove(&self, account_id: &str, _: AccountListId) {
        println!("remove {account_id}");
    }
    fn dismiss_error(&self, list: AccountListId) {
        println!("dismiss error in {list:?}");
    }
}

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

fn main() {
    let directory = std::env::temp_dir().join(format!("soprano-settings-demo-{}", std::process::id()));
    let store = ConfigStore::new(directory.join("settings.json"));
    store.start(true, &AppSettings::default(), &DefaultKeybindings::config());
    println!("settings.json: {}", store.file_path().display());

    gpui_platform::application().with_assets(SopranoAssets::from_resources_dir()).run(move |cx: &mut App| {
        soprano_ui::init(cx, &store.settings().theme_id, AppearancePreference::System);
        let bounds = Bounds::centered(None, size(px(1280.), px(860.)), cx);
        cx.open_window(
            WindowOptions { window_bounds: Some(WindowBounds::Windowed(bounds)), ..WindowOptions::default() },
            |window, cx| {
                let accounts: Rc<dyn AccountsSource> = Rc::new(DemoAccounts { snapshot: demo_snapshot() });
                let notifications = Rc::new(Some(NotificationAuthorization::Authorized));
                let view = cx.new(|cx| SettingsView::new(store.clone(), accounts, notifications, window, cx));
                cx.subscribe(&view, |_, event: &SettingsEvent, cx| match event {
                    SettingsEvent::Close => cx.quit(),
                    SettingsEvent::OpenSettingsFile { error } => {
                        if let Some(error) = error {
                            eprintln!("could not open settings.json: {error}");
                        }
                    }
                })
                .detach();
                cx.new(|cx| Root::new(view, window, cx))
            },
        )
        .expect("the demo window opens");
        cx.activate(true);
    });
}
