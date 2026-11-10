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
    App, AppContext as _, AsyncWindowContext, Bounds, Context, Entity, IntoElement, MouseButton,
    MouseDownEvent, MouseMoveEvent, MouseUpEvent, ParentElement, PlatformInput, Render, ScrollDelta,
    ScrollEvent, Styled, Window, WindowBounds, WindowOptions, div, point, px, size,
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
use soprano_ui::{ActiveSopranoTheme, AppearancePreference, SopranoAssets};

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

/// What the command line asked for.
struct Options {
    snapshot: Option<PathBuf>,
    /// Clicks made on a page (counted from 1) before it is written.
    clicks: Vec<(usize, f32, f32)>,
    width: f32,
    height: f32,
    appearance: AppearancePreference,
}

impl Options {
    fn parse() -> Self {
        let mut options = Self {
            snapshot: None,
            clicks: Vec::new(),
            width: 1280.,
            height: 860.,
            appearance: AppearancePreference::System,
        };
        let mut args = std::env::args().skip(1);
        while let Some(flag) = args.next() {
            let value = args.next().unwrap_or_else(|| panic!("{flag} needs a value"));
            match flag.as_str() {
                "--snapshot" => {
                    let path = PathBuf::from(value);
                    assert!(path.is_absolute(), "--snapshot needs an absolute folder");
                    options.snapshot = Some(path);
                }
                "--click" => {
                    let (page, at) = value.split_once(':').expect("--click PAGE:X,Y");
                    let (x, y) = at.split_once(',').expect("--click PAGE:X,Y");
                    options.clicks.push((
                        page.parse().expect("--click page"),
                        x.parse().expect("--click x"),
                        y.parse().expect("--click y"),
                    ));
                }
                "--size" => {
                    let (width, height) = value.split_once('x').expect("--size WIDTHxHEIGHT");
                    options.width = width.parse().expect("--size width");
                    options.height = height.parse().expect("--size height");
                }
                "--appearance" => {
                    options.appearance = match value.as_str() {
                        "dark" => AppearancePreference::Dark,
                        "light" => AppearancePreference::Light,
                        _ => panic!("--appearance dark|light"),
                    }
                }
                _ => panic!("unknown option {flag}"),
            }
        }
        options
    }
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

/// Lets pending work land (machine checks answer from the background executor), then draws the
/// window: one that is not on screen gets no frames of its own. Twice, because the first draw
/// measures what the second one places.
async fn redraw(cx: &mut AsyncWindowContext) {
    for _ in 0..2 {
        cx.background_executor().timer(std::time::Duration::from_millis(60)).await;
        let _ = cx.update(|window, cx| window.draw(cx).clear(cx));
    }
}

/// Writes each page, then each further screenful of it until scrolling changes nothing.
async fn write_snapshots(
    settings: Entity<SettingsView>,
    directory: PathBuf,
    clicks: Vec<(usize, f32, f32)>,
    cx: &mut AsyncWindowContext,
) {
    std::fs::create_dir_all(&directory).expect("the snapshot folder is writable");
    for (index, tab) in SettingsTab::ALL.into_iter().enumerate() {
        let _ = settings.update_in(cx, |view, window, cx| view.switch_tab(tab, window, cx));
        redraw(cx).await;
        for &(_, x, y) in clicks.iter().filter(|(page, ..)| *page == index + 1) {
            let _ = cx.update(|window, cx| {
                let position = point(px(x), px(y));
                let modifiers = window.modifiers();
                let button = MouseButton::Left;
                window.dispatch_event(
                    PlatformInput::MouseMove(MouseMoveEvent { position, pressed_button: None, modifiers }),
                    cx,
                );
                window.dispatch_event(
                    PlatformInput::MouseDown(MouseDownEvent {
                        button,
                        position,
                        modifiers,
                        click_count: 1,
                        first_mouse: false,
                    }),
                    cx,
                );
                window.dispatch_event(
                    PlatformInput::MouseUp(MouseUpEvent { button, position, modifiers, click_count: 1 }),
                    cx,
                );
            });
            redraw(cx).await;
        }
        let mut previous = None;
        for screen in 0..12 {
            redraw(cx).await;
            let image = match cx.update(|window, _| window.render_to_image()) {
                Ok(Ok(image)) => image,
                Ok(Err(error)) => {
                    eprintln!("Cannot render the window: {error:#}");
                    std::process::exit(1);
                }
                Err(_) => return,
            };
            if previous.as_ref() == Some(&image) {
                break;
            }
            let name = tab.title().to_lowercase().replace(' ', "-");
            let path = directory.join(format!("{}-{name}-{screen}.png", index + 1));
            image.save(&path).expect("the snapshot is writable");
            println!("{}", path.display());
            previous = Some(image);
            let _ = cx.update(|window, cx| {
                let viewport = window.viewport_size();
                let position = point(viewport.width * 0.6, viewport.height * 0.5);
                let modifiers = window.modifiers();
                window.dispatch_event(
                    PlatformInput::MouseMove(MouseMoveEvent { position, pressed_button: None, modifiers }),
                    cx,
                );
                window.dispatch_event(
                    PlatformInput::Scroll(ScrollEvent {
                        position,
                        delta: ScrollDelta::Pixels(point(px(0.), -(viewport.height * 0.7))),
                        modifiers,
                        ..ScrollEvent::default()
                    }),
                    cx,
                );
            });
        }
    }
    let _ = cx.update(|_, cx| cx.quit());
}

fn main() {
    let options = Options::parse();
    let directory = std::env::temp_dir().join(format!("soprano-settings-demo-{}", std::process::id()));
    seed_settings(&directory);
    let store = ConfigStore::new(directory.join("settings.json"));
    store.start(true, &AppSettings::default(), &DefaultKeybindings::config());
    println!("settings.json: {}", store.file_path().display());

    // An example's executable sits one folder deeper than the app's, so name the checkout's
    // resources (fonts, icons) outright.
    let resources = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../resources");
    gpui_platform::application().with_assets(SopranoAssets::new(resources.clone())).run(
        move |cx: &mut App| {
            soprano_ui::init(cx, &store.settings().theme_id, options.appearance);
            soprano_ui::fonts::register_fonts_from(&resources.join("fonts"), cx)
                .expect("the bundled fonts load");
            let bounds = Bounds::centered(None, size(px(options.width), px(options.height)), cx);
            let snapshot = options.snapshot.clone();
            let clicks = options.clicks.clone();
            let interactive = snapshot.is_none();
            cx.open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(bounds)),
                    ..WindowOptions::default()
                },
                |window, cx| {
                    let accounts: Rc<dyn AccountsSource> =
                        Rc::new(DemoAccounts { snapshot: demo_snapshot() });
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
                            .spawn(cx, async move |cx| write_snapshots(settings, directory, clicks, cx).await)
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
        },
    );
}
