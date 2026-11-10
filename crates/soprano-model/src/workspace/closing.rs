//! Closing sessions, windows, layout tabs, panes and pane tabs, with the two-phase
//! confirmation that replaces Swift's synchronous `closeConfirmation` closure.
//!
//! Every close first gathers the tabs about to go and asks the host's predicate (set with
//! [`Workspace::set_close_confirmation`]). When it wants a confirmation the close does nothing
//! and returns [`CloseOutcome::NeedsConfirmation`] carrying those tabs and the request; once the
//! user agreed, [`Workspace::force_close`] performs it. Closes nested inside an approved one
//! (a pane's last tab taking the pane, a pane taking its window) are not asked again.

use super::Workspace;
use crate::session::WorkspaceSession;
use soprano_types::TerminalTarget;

/// A close the host can replay with [`Workspace::force_close`].
#[derive(Clone, Debug, PartialEq)]
pub enum CloseRequest {
    Session(String),
    Window(String),
    Pane(String),
    LayoutTab(String),
    /// One tab of a pane ([`Workspace::remove_tab_from_pane`]).
    PaneTab(TerminalTarget),
    /// A finished automation run's tab ([`Workspace::close_automation_run`]).
    AutomationRun(TerminalTarget),
    /// The terminal surface's process ended ([`Workspace::handle_terminal_close`]).
    TerminalClosed(TerminalTarget),
    /// Restoring replaces every open tab ([`Workspace::restore_workspace`]).
    RestoreWorkspace(Box<WorkspaceSession>),
}

/// What a close did.
#[derive(Clone, Debug, PartialEq)]
pub enum CloseOutcome {
    /// The close (or restore) was carried out.
    Closed,
    /// Nothing was closed: the target was not found, or the request needed no close.
    Unchanged,
    /// The host's predicate wants the user to confirm closing `targets` first; nothing
    /// changed. Pass `request` to [`Workspace::force_close`] once they agreed.
    NeedsConfirmation { targets: Vec<TerminalTarget>, request: CloseRequest },
}

impl Workspace {
    /// Performs `request` without asking, after the user confirmed it.
    pub fn force_close(&mut self, request: CloseRequest) -> CloseOutcome {
        self.perform_close(request, true)
    }

    fn perform_close(&mut self, request: CloseRequest, force: bool) -> CloseOutcome {
        match request {
            CloseRequest::Session(id) => self.close_session_with(&id, force),
            CloseRequest::Window(id) => self.close_window_with(&id, force),
            CloseRequest::Pane(id) => self.close_pane_with(&id, force),
            CloseRequest::LayoutTab(id) => self.close_layout_tab_with(&id, force),
            CloseRequest::PaneTab(target) => {
                self.remove_tab_from_pane_with(&target.pane_id, &target.tab_id, force)
            }
            CloseRequest::AutomationRun(target) => self.close_automation_run_with(&target, force),
            CloseRequest::TerminalClosed(target) => self.handle_terminal_close_with(&target, force),
            CloseRequest::RestoreWorkspace(session) => self.restore_workspace_with(*session, force),
        }
    }

    /// Every tab of `pane_ids`, pane by pane.
    pub(super) fn targets_in_panes<'a>(
        &self,
        pane_ids: impl IntoIterator<Item = &'a String>,
    ) -> Vec<TerminalTarget> {
        pane_ids
            .into_iter()
            .filter_map(|pane_id| self.panes.get(pane_id))
            .flat_map(|pane| pane.tabs.iter().map(|tab| TerminalTarget::new(&pane.id, &tab.id)))
            .collect()
    }

    /// `Some(NeedsConfirmation)` when the host wants `targets` confirmed before they close.
    pub(super) fn confirmation_needed(
        &self,
        targets: Vec<TerminalTarget>,
        force: bool,
        request: impl FnOnce() -> CloseRequest,
    ) -> Option<CloseOutcome> {
        if force || targets.is_empty() {
            return None;
        }
        let confirmation = self.close_confirmation.as_ref()?;
        confirmation(&targets).then(|| CloseOutcome::NeedsConfirmation { targets, request: request() })
    }

    // MARK: - Sessions

    /// Closes a session with all its windows. The last session is replaced by a fresh
    /// `Session 1`, so there is always one to work in.
    pub fn close_session(&mut self, session_id: &str) -> CloseOutcome {
        self.close_session_with(session_id, false)
    }

    fn close_session_with(&mut self, session_id: &str, force: bool) -> CloseOutcome {
        if !self.terminal_sessions.contains_key(session_id) {
            return CloseOutcome::Unchanged;
        }
        let window_ids = self.ordered_window_ids_in_session(session_id);
        let pane_ids: Vec<String> = window_ids
            .iter()
            .filter_map(|id| self.windows.get(id))
            .flat_map(|w| w.ordered_pane_ids())
            .collect();
        if let Some(outcome) = self.confirmation_needed(self.targets_in_panes(&pane_ids), force, || {
            CloseRequest::Session(session_id.to_owned())
        }) {
            return outcome;
        }
        let was_active = self.active_session_id() == session_id;
        for pane_id in &pane_ids {
            self.cancel_agent_readiness_generations_in(pane_id);
            self.panes.remove(pane_id);
        }
        for window_id in &window_ids {
            self.windows.remove(window_id);
        }
        self.terminal_sessions.remove(session_id);
        if self.terminal_sessions.is_empty() {
            self.create_session("Session 1", None);
            return CloseOutcome::Closed;
        }
        if was_active
            && let Some(next_window) =
                self.ordered_sessions().first().map(|session| session.active_window_id.clone())
        {
            self.active_window_id = next_window;
            self.maximized_pane_id = None;
        }
        self.notify_model(true);
        CloseOutcome::Closed
    }

    fn ordered_window_ids_in_session(&self, session_id: &str) -> Vec<String> {
        self.ordered_windows_in(session_id).into_iter().map(|window| window.id.clone()).collect()
    }

    // MARK: - Windows

    /// Closes a window with every pane in it. A session's last window is replaced by a fresh
    /// one, which keeps the session usable without jumping into another session.
    pub fn close_window(&mut self, window_id: &str) -> CloseOutcome {
        self.close_window_with(window_id, false)
    }

    fn close_window_with(&mut self, window_id: &str, force: bool) -> CloseOutcome {
        let Some(window) = self.windows.get(window_id) else { return CloseOutcome::Unchanged };
        let pane_ids = window.ordered_pane_ids();
        let session_id = window.session_id.clone();
        if let Some(outcome) = self.confirmation_needed(self.targets_in_panes(&pane_ids), force, || {
            CloseRequest::Window(window_id.to_owned())
        }) {
            return outcome;
        }
        for pane_id in &pane_ids {
            self.cancel_agent_readiness_generations_in(pane_id);
            self.panes.remove(pane_id);
        }
        self.windows.remove(window_id);
        if let Some(session) = self.terminal_sessions.get_mut(&session_id)
            && session.last_active_window_id.as_deref() == Some(window_id)
        {
            session.last_active_window_id = None;
        }

        let remaining = self.ordered_window_ids_in_session(&session_id);
        let Some(first_remaining) = remaining.first().cloned() else {
            // Keep the session usable without jumping into another session.
            let activate = self.active_window_id == window_id;
            self.create_window_in(&session_id, super::Place::default(), None, activate);
            return CloseOutcome::Closed;
        };

        if let Some(session) = self.terminal_sessions.get_mut(&session_id)
            && session.active_window_id == window_id
        {
            session.active_window_id = first_remaining.clone();
            if session.last_active_window_id.as_deref() == Some(first_remaining.as_str()) {
                session.last_active_window_id = None;
            }
        }
        if self.active_window_id == window_id {
            self.active_window_id = first_remaining;
        }
        self.maximized_pane_id = None;
        self.notify_model(true);
        CloseOutcome::Closed
    }

    // MARK: - Panes

    /// Closes `pane_id` with all of its tabs. The last pane of a layout tab takes that tab with
    /// it, and the last pane of a window the window.
    pub fn close_pane(&mut self, pane_id: &str) -> CloseOutcome {
        self.close_pane_with(pane_id, false)
    }

    fn close_pane_with(&mut self, pane_id: &str, force: bool) -> CloseOutcome {
        if !self.panes.contains_key(pane_id) {
            return CloseOutcome::Unchanged;
        }
        let Some(window_id) = self.window_id_containing_pane(pane_id) else { return CloseOutcome::Unchanged };
        let pane_ids = [pane_id.to_owned()];
        if let Some(outcome) = self.confirmation_needed(self.targets_in_panes(&pane_ids), force, || {
            CloseRequest::Pane(pane_id.to_owned())
        }) {
            return outcome;
        }

        self.exit_maximize();
        self.cancel_agent_readiness_generations_in(pane_id);
        self.panes.remove(pane_id);
        let is_empty = match self.windows.get_mut(&window_id) {
            Some(window) => {
                window.remove_pane(pane_id);
                window.is_empty()
            }
            None => false,
        };
        if is_empty {
            // Approved with this pane: the window's close is not asked again.
            self.close_window_with(&window_id, true);
        } else {
            self.notify_model(true);
        }
        CloseOutcome::Closed
    }

    // MARK: - Layout tabs

    /// Closes `layout_tab_id` with every pane in it. A window's last tab takes the window with
    /// it.
    pub fn close_layout_tab(&mut self, layout_tab_id: &str) -> CloseOutcome {
        self.close_layout_tab_with(layout_tab_id, false)
    }

    pub fn close_active_layout_tab(&mut self) -> CloseOutcome {
        let Some(layout_tab_id) = self.active_window().map(|window| window.active_tab().id.clone()) else {
            return CloseOutcome::Unchanged;
        };
        self.close_layout_tab(&layout_tab_id)
    }

    fn close_layout_tab_with(&mut self, layout_tab_id: &str, force: bool) -> CloseOutcome {
        let Some(window) = self.window_containing_layout_tab(layout_tab_id) else {
            return CloseOutcome::Unchanged;
        };
        let Some(index) = window.tab_index_of(layout_tab_id) else { return CloseOutcome::Unchanged };
        let window_id = window.id.clone();
        if window.tabs().len() <= 1 {
            return self.close_window_with(&window_id, force);
        }
        let pane_ids =
            window.tabs()[index].layout.as_ref().map(|layout| layout.ordered_leaf_ids()).unwrap_or_default();
        if let Some(outcome) = self.confirmation_needed(self.targets_in_panes(&pane_ids), force, || {
            CloseRequest::LayoutTab(layout_tab_id.to_owned())
        }) {
            return outcome;
        }

        if self.maximized_pane_id.as_ref().is_some_and(|id| pane_ids.contains(id)) {
            self.maximized_pane_id = None;
        }
        if let Some(window) = self.windows.get_mut(&window_id) {
            window.remove_tab(index);
        }
        for pane_id in &pane_ids {
            self.cancel_agent_readiness_generations_in(pane_id);
            self.panes.remove(pane_id);
        }
        self.notify_model(true);
        CloseOutcome::Closed
    }

    // MARK: - Pane tabs

    /// Closes one tab of a pane. A pane's last tab takes the pane with it.
    pub fn remove_tab_from_pane(&mut self, pane_id: &str, tab_id: &str) -> CloseOutcome {
        self.remove_tab_from_pane_with(pane_id, tab_id, false)
    }

    fn remove_tab_from_pane_with(&mut self, pane_id: &str, tab_id: &str, force: bool) -> CloseOutcome {
        let Some(pane) = self.panes.get(pane_id) else { return CloseOutcome::Unchanged };
        let Some(index) = pane.tab_index(tab_id) else { return CloseOutcome::Unchanged };
        if pane.tabs.len() == 1 {
            return self.close_pane_with(pane_id, force);
        }
        let target = TerminalTarget::new(pane_id, tab_id);
        if let Some(outcome) =
            self.confirmation_needed(vec![target.clone()], force, || CloseRequest::PaneTab(target.clone()))
        {
            return outcome;
        }
        self.cancel_agent_readiness_generation(&target);

        let Some(pane) = self.panes.get_mut(pane_id) else { return CloseOutcome::Unchanged };
        pane.tabs.remove(index);
        if index < pane.active_tab_index {
            pane.active_tab_index -= 1;
        } else if index == pane.active_tab_index {
            pane.active_tab_index = pane.active_tab_index.saturating_sub(1);
        }
        pane.active_tab_index = pane.clamped_active_index();
        self.notify_model(false);
        CloseOutcome::Closed
    }

    /// Routes the terminal's close request by the surface's immutable pane/tab ids: an agent
    /// tab's agent stops (the tab stays, restartable); any other tab closes.
    pub fn handle_terminal_close(&mut self, target: &TerminalTarget) -> CloseOutcome {
        self.handle_terminal_close_with(target, false)
    }

    fn handle_terminal_close_with(&mut self, target: &TerminalTarget, force: bool) -> CloseOutcome {
        let Some(tab) = self.tab(&target.pane_id, &target.tab_id) else { return CloseOutcome::Unchanged };
        if tab.pane_type != crate::PaneType::Agent {
            return self.remove_tab_from_pane_with(&target.pane_id, &target.tab_id, force);
        }
        if !tab.agent.as_ref().is_some_and(|agent| agent.status != soprano_types::AgentStatus::Stopped) {
            return CloseOutcome::Unchanged;
        }
        self.cancel_agent_readiness_generation(target);
        if let Some(agent) = self.agent_mut(&target.pane_id, &target.tab_id) {
            agent.status = soprano_types::AgentStatus::Stopped;
            agent.needs_attention = false;
        }
        self.notify_model(false);
        CloseOutcome::Unchanged
    }

    // MARK: - Automation runs

    /// Closes a finished run's agent tab. Panes or tabs someone added beside it stay; a window
    /// holding only the run closes with it, and the last run window takes the Automations
    /// session along while that session is in the background, rather than leaving an empty
    /// shell window behind.
    pub fn close_automation_run(&mut self, target: &TerminalTarget) -> CloseOutcome {
        self.close_automation_run_with(target, false)
    }

    fn close_automation_run_with(&mut self, target: &TerminalTarget, force: bool) -> CloseOutcome {
        let Some(window) = self.window_containing_pane(&target.pane_id) else {
            return CloseOutcome::Unchanged;
        };
        let only_the_run = window.pane_ids().len() == 1
            && self.panes.get(&target.pane_id).is_some_and(|pane| pane.tabs.len() == 1);
        if !only_the_run {
            return self.remove_tab_from_pane_with(&target.pane_id, &target.tab_id, force);
        }
        let window_id = window.id.clone();
        let session_id = window.session_id.clone();
        let is_background_automation_session = session_id != self.active_session_id()
            && self
                .terminal_sessions
                .get(&session_id)
                .is_some_and(|s| s.name == Self::AUTOMATION_SESSION_NAME)
            && self.ordered_windows_in(&session_id).len() == 1;
        if is_background_automation_session {
            self.close_session_with(&session_id, force)
        } else {
            self.close_window_with(&window_id, force)
        }
    }
}
