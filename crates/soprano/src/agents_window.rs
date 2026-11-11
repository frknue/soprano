//! The Agents window: the Agent Dashboard in an OS window of its own beside the main one.
//! `⇧⌘D` opens it, brings it forward, and closes it while it is in front. The main view owns
//! the handle and answers the dashboard's events; where the window was is app state.

use std::cell::Cell;
use std::collections::HashSet;
use std::rc::Rc;
use std::time::Duration;

use gpui::{
    App, AppContext as _, Context, Entity, Focusable as _, IntoElement, ParentElement, Render, Styled,
    Subscription, Task, WeakEntity, Window, WindowHandle, div,
};
use gpui_component::Root;
use soprano_dashboard::{AgentDashboard, DashboardHost, ProjectChoice};
use soprano_model::{PaneType, Workspace};
use soprano_platform::StateStore;
use soprano_ui::{ActiveSopranoTheme, SopranoTheme};

use crate::{palette, sizing, window_chrome};

/// Where the window's frame is kept.
pub const FRAME_KEY: &str = "soprano-agents-window-frame";
/// The size it first opens at (Soprano Agents').
const DEFAULT_SIZE: (f64, f64) = (1100.0, 780.0);
/// How long the window must stay put before its frame is saved.
const FRAME_SAVE_DELAY: Duration = Duration::from_millis(500);

/// The window's root: the dashboard, themed with the app.
struct AgentsWindow {
    dashboard: Entity<AgentDashboard>,
    state: StateStore,
    /// Cleared when the window, and this view with it, goes away.
    open: Rc<Cell<bool>>,
    frame_save: Option<Task<()>>,
    _subscriptions: Vec<Subscription>,
}

impl Drop for AgentsWindow {
    fn drop(&mut self) {
        self.open.set(false);
    }
}

impl Render for AgentsWindow {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        cx.soprano_theme().apply_to_window(window);
        div().size_full().child(self.dashboard.clone())
    }
}

/// The open Agents window, as the main view holds it.
pub struct AgentsWindowHandle {
    pub window: WindowHandle<Root>,
    /// Held weakly: the dashboard goes with its window, also when the window's own close
    /// button closes it.
    pub dashboard: WeakEntity<AgentDashboard>,
    open: Rc<Cell<bool>>,
}

impl AgentsWindowHandle {
    /// False once the window has gone: its own close button, or [`close`].
    pub fn is_open(&self) -> bool {
        self.open.get()
    }
}

/// Opens the window over `workspace` where it last was, else in the middle of `display` (the
/// visible frame of the screen the main window is on), and gives the inbox the keyboard.
pub fn open(
    workspace: Entity<Workspace>,
    host: DashboardHost,
    state: &StateStore,
    display: sizing::Frame,
    cx: &mut App,
) -> anyhow::Result<AgentsWindowHandle> {
    let frame = sizing::load_frame_at(state, FRAME_KEY, &window_chrome::visible_frames(cx))
        .unwrap_or_else(|| sizing::centered_frame(display, DEFAULT_SIZE.0, DEFAULT_SIZE.1));
    let open = Rc::new(Cell::new(true));
    let mut dashboard = WeakEntity::new_invalid();
    let window = cx.open_window(window_chrome::agents_window_options(frame), |window, cx| {
        let view = cx.new(|cx| AgentDashboard::new(workspace, host, window, cx));
        dashboard = view.downgrade();
        let dashboard = view;
        let view = cx.new(|cx| {
            let subscriptions = vec![
                cx.observe_window_bounds(window, |this: &mut AgentsWindow, window, cx| {
                    this.frame_save = Some(cx.spawn_in(window, async move |this, cx| {
                        cx.background_executor().timer(FRAME_SAVE_DELAY).await;
                        this.update_in(cx, |this, window, _| save_frame(window, &this.state)).ok();
                    }));
                }),
                cx.observe_global::<SopranoTheme>(|_, cx| cx.notify()),
                SopranoTheme::observe_system_appearance(window),
            ];
            AgentsWindow {
                dashboard: dashboard.clone(),
                state: state.clone(),
                open: open.clone(),
                frame_save: None,
                _subscriptions: subscriptions,
            }
        });
        // The close button: keep where the window was.
        let closing = state.clone();
        window.on_window_should_close(cx, move |window, _| {
            save_frame(window, &closing);
            true
        });
        let focus = dashboard.focus_handle(cx);
        window.focus(&focus, cx);
        cx.new(|cx| Root::new(view, window, cx))
    })?;
    Ok(AgentsWindowHandle { window, dashboard, open })
}

/// Closes the window, keeping where it was.
pub fn close(window: &mut Window, state: &StateStore) {
    save_frame(window, state);
    window.remove_window();
}

fn save_frame(window: &Window, state: &StateStore) {
    if !window.is_fullscreen() {
        sizing::save_frame_at(state, FRAME_KEY, window_chrome::current_frame(window));
    }
}

/// The folders a new thread is offered: the projects the workspace's terminals and agents
/// work in on this computer, in window order, then the subfolders of the `projectDirectories`
/// that are not open yet.
pub fn project_choices(workspace: &Workspace, roots: &[String]) -> Vec<ProjectChoice> {
    let mut seen = HashSet::new();
    let mut choices = Vec::new();
    let working = workspace
        .ordered_windows()
        .into_iter()
        .flat_map(|window| workspace.ordered_panes(&window.id))
        .flat_map(|pane| pane.tabs.iter())
        .filter(|tab| tab.pane_type != PaneType::Browser && tab.remote.is_none())
        .filter_map(|tab| tab.cwd.as_deref())
        .map(|cwd| Workspace::project_root(cwd).to_string_lossy().into_owned());
    let listed = palette::projects(roots).into_iter().map(|project| project.path);
    for path in working.chain(listed) {
        if seen.insert(path.clone()) {
            choices.push(ProjectChoice::at(path));
        }
    }
    choices
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_projects_come_first_once_each_and_listed_ones_follow() {
        let roots = tempfile::tempdir().expect("temp");
        for name in ["alpha", "beta"] {
            std::fs::create_dir_all(roots.path().join(name).join(".git")).expect("project");
        }
        std::fs::create_dir(roots.path().join("beta").join("sub")).expect("sub");
        let elsewhere = tempfile::tempdir().expect("temp");
        let path = |folder: &std::path::Path| {
            soprano_model::file_url::standardized_path(folder).to_string_lossy().into_owned()
        };
        let mut workspace = Workspace::new();
        // Two tabs inside beta (one in a subfolder), one in a folder outside the roots, and a
        // terminal on a machine, whose folder is not one here.
        workspace.spawn_terminal(Some(&path(&roots.path().join("beta").join("sub")))).expect("pane");
        workspace.spawn_agent("omp", Some(&path(&roots.path().join("beta"))), false).expect("pane");
        workspace.spawn_terminal(Some(&path(elsewhere.path()))).expect("pane");
        workspace.spawn_terminal_on("vps").expect("pane");

        let choices = project_choices(&workspace, &[roots.path().to_string_lossy().into_owned()]);

        let paths: Vec<&str> = choices.iter().map(|choice| choice.path.as_str()).collect();
        let (alpha, beta) = (path(&roots.path().join("alpha")), path(&roots.path().join("beta")));
        let outside = path(elsewhere.path());
        assert_eq!(paths, [beta.as_str(), outside.as_str(), alpha.as_str()]);
    }
}
