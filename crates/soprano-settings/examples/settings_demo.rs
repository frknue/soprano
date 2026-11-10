//! The Settings card over a throwaway settings.json, with demo accounts, machines and project
//! folders: `cargo run -p soprano-settings --example settings_demo`.
//!
//! `-- --snapshot /abs/dir [--size 1280x860] [--appearance dark|light] [--click PAGE:X,Y]…`
//! writes every page (and each screenful below its fold) as PNGs into the folder and quits, for
//! visual QA without looking at the screen. `--click 4:600,250` clicks there on the fourth
//! page before it is written.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;

use gpui::{
    App, AppContext as _, AsyncWindowContext, Bounds, Context, Entity, IntoElement, ParentElement, Render,
    Styled, Window, WindowBounds, WindowOptions, div, point, px, size,
};
use gpui_component::Root;
use soprano_accounts::chrono::{Duration, Utc};
use soprano_accounts::models::{
    AccountIdentity, AccountList, AccountListId, AccountRow, AccountUsage, AccountsSnapshot, UsageWindow,
};
use soprano_accounts::{AccountsSource, SnapshotObserver};
use soprano_config::{AppSettings, ConfigStore, DefaultKeybindings};
use soprano_launch::MachineCheck;
use soprano_settings::{NotificationAuthorization, SettingsEvent, SettingsTab, SettingsView};
use soprano_types::Machine;
use soprano_ui::snapshot::{self, Args};
use soprano_ui::{ActiveSopranoTheme, SopranoAssets};

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

/// The window's content: the app's canvas with Settings over it, zoomed like the app's root.
struct DemoRoot {
    settings: Entity<SettingsView>,
}

impl Render for DemoRoot {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        cx.soprano_theme().apply_to_window(window);
        div().relative().size_full().bg(cx.soprano_theme().canvas).child(self.settings.clone())
    }
}

/// The clicks `--click PAGE:X,Y` asks for: made on that page (counted from 1) before it is
/// written.
fn clicks(args: &Args) -> Vec<(usize, f32, f32)> {
    args.rest
        .iter()
        .map(|(flag, value)| {
            assert_eq!(flag, "--click", "unknown option {flag}");
            let (page, at) = value.split_once(':').expect("--click PAGE:X,Y");
            let (x, y) = at.split_once(',').expect("--click PAGE:X,Y");
            (
                page.parse().expect("--click page"),
                x.parse().expect("--click x"),
                y.parse().expect("--click y"),
            )
        })
        .collect()
}

/// A settings.json that puts every kind of row on screen: two machines, two project folders
/// (one of them missing), a patched and a declared agent, and a rebound, a switched-off and a
/// conflicting shortcut.
fn seed_settings(directory: &Path) {
    let projects = directory.join("projects");
    std::fs::create_dir_all(&projects).expect("the demo folder is writable");
    let text = serde_json::json!({
        "projectDirectories": [projects.display().to_string(), "/Volumes/archive/clients"],
        "machines": [
            { "name": "vps", "destination": "ada@vps.example", "sshArgs": ["-p", "2222"], "directory": "~/work" },
            { "name": "pi" },
        ],
        "agents": [
            { "id": "claude-code", "args": ["--model", "opus"] },
            { "id": "aider", "name": "Aider", "command": "aider", "launchKey": "cmd+5" },
        ],
        "keybindings": {
            "bindings": { "new-tab": "ctrl+k", "next-window": "ctrl+k", "split-vertical": null },
        },
    });
    std::fs::write(directory.join("settings.json"), format!("{text:#}\n"))
        .expect("settings.json is writable");
}

/// Machine checks that never run `ssh`.
fn demo_machine_check(machine: &Machine) -> MachineCheck {
    match machine.name.as_str() {
        "pi" => MachineCheck::Unreachable {
            message: "ssh: connect to host pi port 22: Operation timed out".into(),
        },
        _ => MachineCheck::Ready { tmux: Some("tmux 3.4".into()), system: "Linux".into() },
    }
}

/// Writes each page, then each further screenful of it until scrolling changes nothing.
async fn write_snapshots(
    settings: Entity<SettingsView>,
    directory: PathBuf,
    clicks: Vec<(usize, f32, f32)>,
    cx: &mut AsyncWindowContext,
) -> anyhow::Result<()> {
    std::fs::create_dir_all(&directory)?;
    for (index, tab) in SettingsTab::ALL.into_iter().enumerate() {
        settings.update_in(cx, |view, window, cx| view.switch_tab(tab, window, cx))?;
        snapshot::redraw(cx).await;
        for &(_, x, y) in clicks.iter().filter(|(page, ..)| *page == index + 1) {
            cx.update(|window, cx| snapshot::click(point(px(x), px(y)), window, cx))?;
            snapshot::redraw(cx).await;
        }
        let mut previous = None;
        for screen in 0..12 {
            snapshot::redraw(cx).await;
            let frame = cx.update(|window, _| snapshot::pixels(window))??;
            if previous.as_ref() == Some(&frame) {
                break;
            }
            previous = Some(frame);
            let name = tab.title().to_lowercase().replace(' ', "-");
            let path = directory.join(format!("{}-{name}-{screen}.png", index + 1));
            cx.update(|window, _| snapshot::write_png(window, &path))??;
            cx.update(|window, cx| {
                let viewport = window.viewport_size();
                let middle = point(viewport.width * 0.6, viewport.height * 0.5);
                snapshot::scroll(middle, viewport.height * 0.7, window, cx)
            })?;
        }
    }
    Ok(())
}

fn main() {
    let args = Args::parse(1280., 860.);
    let clicks = clicks(&args);
    let directory = std::env::temp_dir().join(format!("soprano-settings-demo-{}", std::process::id()));
    seed_settings(&directory);
    let store = ConfigStore::new(directory.join("settings.json"));
    store.start(true, &AppSettings::default(), &DefaultKeybindings::config());
    println!("settings.json: {}", store.file_path().display());

    gpui_platform::application().with_assets(SopranoAssets::from_resources_dir()).run(move |cx: &mut App| {
        soprano_ui::init(cx, &store.settings().theme_id, args.appearance);
        let bounds = Bounds::centered(None, size(px(args.width), px(args.height)), cx);
        let snapshot = args.directory.clone();
        let interactive = snapshot.is_none();
        cx.open_window(
            WindowOptions { window_bounds: Some(WindowBounds::Windowed(bounds)), ..WindowOptions::default() },
            |window, cx| {
                let accounts: Rc<dyn AccountsSource> = Rc::new(DemoAccounts { snapshot: demo_snapshot() });
                let notifications = Rc::new(Some(NotificationAuthorization::Authorized));
                let view = cx.new(|cx| {
                    let mut view = SettingsView::new(store.clone(), accounts, notifications, window, cx);
                    view.set_machine_checker(Arc::new(demo_machine_check));
                    view
                });
                cx.subscribe(&view, |_, event: &SettingsEvent, cx| match event {
                    SettingsEvent::Close => cx.quit(),
                    SettingsEvent::OpenSettingsFile { error } => {
                        if let Some(error) = error {
                            eprintln!("could not open settings.json: {error}");
                        }
                    }
                })
                .detach();
                if let Some(directory) = snapshot {
                    let settings = view.clone();
                    window
                        .spawn(cx, async move |cx| {
                            let result = write_snapshots(settings, directory, clicks, cx).await;
                            snapshot::finish(result, cx);
                        })
                        .detach();
                }
                let root = cx.new(|_| DemoRoot { settings: view });
                cx.new(|cx| Root::new(root, window, cx))
            },
        )
        .expect("the demo window opens");
        if interactive {
            cx.activate(true);
        }
    });
}
