//! `AppDelegate.applicationDidFinishLaunching`: settings first, accounts, theme, the workspace
//! (restored when `restoreLastSession`), notifications, the CLI socket, then the main window.
//! Closing the main window quits, whatever else is open; quitting saves the window frame and
//! the workspace.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use gpui::{App, AppContext, Entity};
use gpui_component::Root;
use soprano_accounts::AccountsController;
use soprano_config::ConfigStore;
use soprano_git::GitBranchMonitor;
use soprano_launch::LaunchContext;
use soprano_launch::{ShellFeatures, ShellIntegrationConfig, ShellIntegrationMode};
use soprano_model::{SessionManager, Workspace, WorkspaceSession};
use soprano_notify::NotificationManager;
use soprano_platform::{AppIdentity, StateStore};
use soprano_term::TerminalSettings;
use soprano_ui::SopranoAssets;

use crate::content::{ContentHost, PtyTerminals, terminal_theme};
use crate::main_view::{MainView, Startup, theme_appearance};
use crate::services::Services;
use crate::shell::{Command, Shell};
use crate::workspace::WorkspaceHandle;
use crate::{ipc, menus, sizing, window_chrome};

pub fn run() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .try_init();
    let identity = AppIdentity::current();
    let state = StateStore::for_app(&identity);

    // Load settings.json (creating it on first run) before anything reads a setting.
    let config = ConfigStore::for_app();
    config.start_with_state(true, &state);
    // Before any pane starts: omp panes load the account overlay, codex panes need the chosen
    // CODEX_HOME.
    let accounts = AccountsController::new(state.clone());
    accounts.start();

    let ipc = ipc::start_server();
    let socket = ipc.as_ref().map(|(server, _)| server.endpoint().as_str().to_owned());

    gpui_platform::application().with_assets(SopranoAssets::from_resources_dir()).run(move |cx: &mut App| {
        let settings = config.settings();
        let keybindings = config.keybindings();
        soprano_ui::init(cx, &settings.theme_id, theme_appearance(settings.appearance));
        cx.bind_keys(soprano_term::default_key_bindings());
        // Tab and Shift-Tab belong to terminals and the dashboard, not Root's focus traversal.
        cx.bind_keys(crate::keyboard::tab_passthrough_bindings());
        soprano_browser::bind_keys(cx);
        let editor_keys = soprano_editor::editor::key_bindings(cx);
        let diff_keys = soprano_editor::diff_view::key_bindings(cx);
        let reader_keys = soprano_editor::reader::key_bindings(cx);
        cx.bind_keys(editor_keys);
        cx.bind_keys(diff_keys);
        cx.bind_keys(reader_keys);
        // Quit asks about unsaved editor changes first (the main view knows them).
        let main_window: Rc<RefCell<Option<gpui::WindowHandle<Root>>>> = Rc::default();
        let quit_window = main_window.clone();
        cx.on_action(move |_: &menus::Quit, cx| {
            let Some(window) = *quit_window.borrow() else { return cx.quit() };
            let asked = window.update(cx, |root, window, cx| {
                if let Ok(view) = root.view().clone().downcast::<MainView>() {
                    view.update(cx, |view, cx| view.request_quit(window, cx));
                }
            });
            if asked.is_err() {
                cx.quit();
            }
        });
        // The Agent Dashboard menu item while the Agents window is in front: the main view is
        // not in that window, so the action reaches it from here.
        let dashboard_window = main_window.clone();
        cx.on_action(move |_: &menus::AgentDashboard, cx| {
            let Some(window) = *dashboard_window.borrow() else { return };
            window
                .update(cx, |root, window, cx| {
                    if let Ok(view) = root.view().clone().downcast::<MainView>() {
                        view.update(cx, |view, cx| view.run(Command::ToggleDashboard, window, cx));
                    }
                })
                .ok();
        });
        menus::install(&keybindings, cx);

        let mut workspace = Workspace::new();
        if settings.restore_last_session
            && let Some(session) = WorkspaceSession::load_last(&state)
        {
            workspace.restore_workspace(session);
        }
        workspace.take_changes();
        workspace.take_events();
        let workspace = WorkspaceHandle::new(workspace, cx);

        let (click_sender, banner_clicks) = async_channel::unbounded();
        let sound_config = config.clone();
        let notifications = NotificationManager::new(
            &identity,
            state.clone(),
            move || sound_config.settings().notification_sound,
            move |click| {
                let _ = click_sender.send_blocking(click);
            },
        );
        notifications.request_authorization_if_needed();
        let notifications = Rc::new(RefCell::new(notifications));

        let (config_sender, config_changes) = async_channel::unbounded();
        config.add_observer("soprano-main-window", move |snapshot| {
            let _ = config_sender.send_blocking(snapshot.clone());
        });

        let branches = Arc::new(GitBranchMonitor::new());
        let services = Services {
            state: state.clone(),
            config: config.clone(),
            accounts: accounts.clone(),
            branches,
            sessions: cx.new(|_| SessionManager::new(state.clone())),
        };
        let machines = config.resolved().machines;
        let shell = cx.new(|_| {
            let mut shell = Shell::new(state.clone(), settings.clone(), keybindings.clone());
            shell.machines = machines;
            shell
        });

        sizing::import_appkit_frame(&state, window_chrome::primary_display_height(cx));
        let frame = sizing::load_frame(&state, &window_chrome::visible_frames(cx))
            .unwrap_or_else(|| sizing::initial_frame(window_chrome::main_visible_frame(cx)));
        let startup = Startup { ipc, banner_clicks, config_changes };
        let ghostty = soprano_term::GhosttyConfig::load_default_files();
        let launch_context = LaunchContext::current(socket.clone(), shell_integration(&ghostty));
        let opened = cx.open_window(window_chrome::main_window_options(frame), move |window, cx| {
            let theme = terminal_theme(soprano_ui::SopranoTheme::global(cx).theme());
            let mut terminal_settings = TerminalSettings { theme, ..TerminalSettings::default() };
            terminal_settings.apply_ghostty_config(&ghostty);
            let content = cx.new(|cx| {
                let documents = cx.new(|_| soprano_editor::EditorDocuments::new());
                let mut host = ContentHost::new(
                    workspace.clone(),
                    shell.clone(),
                    Rc::new(PtyTerminals),
                    launch_context,
                    terminal_settings,
                    documents,
                    state.clone(),
                    window,
                    cx,
                );
                host.start_sampling(cx);
                host
            });
            let view: Entity<MainView> = cx.new(|cx| {
                MainView::new(workspace, shell, services, content, notifications, startup, window, cx)
            });
            let should_close = view.downgrade();
            window.on_window_should_close(cx, move |window, cx| {
                // Closing the main window quits: unsaved editor changes are asked about first,
                // and the window stays until the question is answered.
                should_close
                    .update(cx, |view, cx| {
                        if view.has_unsaved_documents(cx) {
                            view.request_quit(window, cx);
                            return false;
                        }
                        view.save_last_workspace_if_needed(window, cx);
                        true
                    })
                    .unwrap_or(true)
            });
            cx.new(|cx| Root::new(view, window, cx))
        });
        let window = match opened {
            Ok(window) => window,
            Err(error) => {
                tracing::error!("cannot open the main window: {error:#}");
                cx.quit();
                return;
            }
        };
        *main_window.borrow_mut() = Some(window);
        // The main window is the app: when it closes, the Agents window goes with it.
        cx.on_window_closed(move |cx, closed| {
            if closed == window.window_id() {
                cx.quit();
            }
        })
        .detach();
        cx.on_app_quit(move |cx| {
            window
                .update(cx, |root, window, cx| {
                    if let Ok(view) = root.view().clone().downcast::<MainView>() {
                        view.update(cx, |view, cx| view.save_last_workspace_if_needed(window, cx));
                    }
                })
                .ok();
            async {}
        })
        .detach();
        cx.activate(true);
    });
}

/// The shell integration the user's Ghostty config asks for: the last `shell-integration`, the
/// `shell-integration-features` values applied in order (an empty value resets), and
/// `cursor-style-blink`.
pub fn shell_integration(config: &soprano_term::GhosttyConfig) -> ShellIntegrationConfig {
    let mut integration =
        ShellIntegrationConfig { cursor_blink: config.cursor_style_blink.flatten(), ..Default::default() };
    if let Some(Some(mode)) = &config.shell_integration
        && let Some(mode) = ShellIntegrationMode::parse(mode)
    {
        integration.mode = mode;
    }
    for value in &config.shell_integration_features {
        if value.trim().is_empty() {
            integration.features = ShellFeatures::default();
        } else {
            integration.features.apply(value);
        }
    }
    integration
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ghostty_shell_integration_keys_reach_the_launch_context() {
        let mut config = soprano_term::GhosttyConfig::default();
        config.parse(
            "shell-integration = zsh\nshell-integration-features = no-cursor\ncursor-style-blink = false\n",
        );
        let integration = shell_integration(&config);
        assert_eq!(integration.mode, ShellIntegrationMode::parse("zsh").expect("mode"));
        assert!(!integration.features.cursor);
        assert_eq!(integration.cursor_blink, Some(false));
        assert_eq!(
            shell_integration(&soprano_term::GhosttyConfig::default()),
            ShellIntegrationConfig::default()
        );
    }
}
