//! The app side of automations (`AppDelegate`'s AutomationController wiring): the
//! [`AutomationHost`] over the workspace entity and the content host, and [`drive`], the one
//! way the shell calls into the controller (tick, drain, workspace changes, retries, page
//! actions).
//!
//! The host runs while the workspace entity is leased to it, so it never touches the content
//! host's workspace-reading methods: starting a terminal is recorded and done right after the
//! lease ends ([`drive`] returns, the content host builds or restarts the view).

use std::cell::RefCell;
use std::rc::Rc;

use gpui::{App, AppContext, Entity, Window};
use soprano_automations::{AutomationController, AutomationHost};
use soprano_model::{TerminalTarget, Workspace};
use soprano_notify::NotificationManager;
use soprano_types::AgentStatus;

use crate::content::{ContentHost, PaneContent};
use crate::workspace::WorkspaceHandle;

/// Everything a controller call needs from the app.
#[derive(Clone)]
pub struct AutomationContext {
    pub controller: Entity<AutomationController>,
    pub workspace: WorkspaceHandle,
    pub content: Entity<ContentHost>,
    pub notifications: Rc<RefCell<NotificationManager>>,
}

struct AppHost<'a> {
    workspace: &'a mut Workspace,
    cx: &'a mut App,
    content: &'a Entity<ContentHost>,
    notifications: &'a Rc<RefCell<NotificationManager>>,
    display_is_awake: bool,
    starts: Vec<TerminalTarget>,
}

impl AutomationHost for AppHost<'_> {
    fn workspace(&self) -> &Workspace {
        self.workspace
    }

    fn workspace_mut(&mut self) -> &mut Workspace {
        self.workspace
    }

    fn start_terminal(&mut self, target: &TerminalTarget) -> bool {
        if !self.display_is_awake {
            return false;
        }
        self.starts.push(target.clone());
        true
    }

    fn send_prompt_to(&mut self, target: &TerminalTarget, prompt: &str) -> bool {
        let Some(PaneContent::Terminal(view)) = self.content.read(self.cx).content(target).cloned() else {
            return false;
        };
        if view.read(self.cx).has_exited() || !view.update(self.cx, |view, cx| view.submit_text(prompt, cx)) {
            return false;
        }
        self.workspace.update_agent_status(
            &target.pane_id,
            &target.tab_id,
            AgentStatus::Running,
            Some(false),
            None,
        );
        true
    }

    fn visible_text(&self, target: &TerminalTarget) -> Option<String> {
        self.content.read(self.cx).visible_terminal_text(target, self.cx)
    }

    fn display_is_awake(&self) -> bool {
        self.display_is_awake
    }

    fn notify(&mut self, title: &str, body: &str, run_id: &str) {
        self.notifications.borrow().deliver_automation_notification(title, body, run_id);
    }
}

/// Runs `f` on the controller with the app's host, notifies the controller entity (the page
/// re-renders), then starts the terminals the call asked for.
pub fn drive<R>(
    context: &AutomationContext,
    window: &mut Window,
    cx: &mut App,
    f: impl FnOnce(&mut AutomationController, &mut dyn AutomationHost) -> R,
) -> R {
    let AutomationContext { controller, workspace, content, notifications } = context;
    let display_is_awake = crate::power::display_is_awake();
    let (result, starts) = workspace.update_with(cx, |ws, cx| {
        controller.update(cx, |controller, cx| {
            let mut host =
                AppHost { workspace: ws, cx, content, notifications, display_is_awake, starts: Vec::new() };
            let result = f(controller, &mut host);
            let starts = std::mem::take(&mut host.starts);
            cx.notify();
            (result, starts)
        })
    });
    for target in starts {
        let started =
            content.update(cx, |content, cx| content.start_background_terminal(&target, window, cx));
        if !started {
            tracing::warn!("cannot start the automation terminal of {}/{}", target.pane_id, target.tab_id);
        }
    }
    result
}

/// Creates the controller (`AutomationEnvironment::for_app`, the app's automations.json),
/// failing runs the last quit left open. `wake` fires on the worker thread.
pub fn create_controller(
    identity: &soprano_platform::AppIdentity,
    config: soprano_config::ConfigStore,
    workspace: &WorkspaceHandle,
    content: &Entity<ContentHost>,
    notifications: &Rc<RefCell<NotificationManager>>,
    wake: impl Fn() + Send + Sync + 'static,
    cx: &mut App,
) -> Entity<AutomationController> {
    let environment = soprano_automations::AutomationEnvironment::for_app(identity, wake);
    let store = soprano_automations::AutomationStore::new(Some(
        soprano_automations::AutomationStore::default_file(identity),
    ));
    let display_is_awake = crate::power::display_is_awake();
    workspace.update_with(cx, |ws, cx| {
        let mut host =
            AppHost { workspace: ws, cx, content, notifications, display_is_awake, starts: Vec::new() };
        let controller = AutomationController::new(store, config, environment, &mut host);
        host.cx.new(|_| controller)
    })
}
