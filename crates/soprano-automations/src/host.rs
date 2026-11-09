//! What runs need from the app that hosts their terminals: the workspace model, the terminal
//! surfaces, the display, and banners. The app shell implements it per call over its
//! `Entity<Workspace>` and terminal registry; tests implement it over a plain [`Workspace`].
//!
//! Only [`AutomationHost::workspace`], [`AutomationHost::workspace_mut`] and the terminal,
//! display and banner methods are required; the workspace methods have defaults built on the
//! model's automation API, which a host may override.

use soprano_model::{AgentInstance, CloseOutcome, TerminalTarget, Workspace};
use soprano_types::{AgentConversation, AgentLaunch};

pub trait AutomationHost {
    fn workspace(&self) -> &Workspace;
    fn workspace_mut(&mut self) -> &mut Workspace;

    /// Starts the run tab's terminal (its agent CLI). False when it can't start now — every
    /// display sleeps and the renderer needs one — so the run waits for a display to wake.
    fn start_terminal(&mut self, target: &TerminalTarget) -> bool;

    /// Types `prompt` into the agent and submits it, for a reuse automation's next run. False
    /// when the tab's terminal can't take it.
    fn send_prompt_to(&mut self, target: &TerminalTarget, prompt: &str) -> bool;

    /// The terminal's visible text: a run's reply when its agent reported none.
    fn visible_text(&self, target: &TerminalTarget) -> Option<String>;

    /// Whether any display is awake (see [`Self::start_terminal`]).
    fn display_is_awake(&self) -> bool;

    /// Posts a banner naming the automation; clicking it opens the run (`run_id`) on the
    /// Automations page.
    fn notify(&mut self, title: &str, body: &str, run_id: &str);

    /// Opens a run's agent in a window of its own in the Automations session without switching
    /// to it ([`Workspace::open_automation_window`]).
    fn open_run_window(
        &mut self,
        title: &str,
        profile_id: &str,
        cwd: &str,
        run_id: Option<String>,
        launch: AgentLaunch,
        conversation: Option<AgentConversation>,
    ) -> Option<TerminalTarget> {
        self.workspace_mut().open_automation_window(title, profile_id, cwd, run_id, launch, conversation)
    }

    /// Closes a finished run's window ([`Workspace::close_automation_run`]).
    fn close_window(&mut self, target: &TerminalTarget) {
        if let CloseOutcome::NeedsConfirmation { request, .. } =
            self.workspace_mut().close_automation_run(target)
        {
            // Nobody opened the run's window, so nobody is there to confirm closing it.
            self.workspace_mut().force_close(request);
        }
    }

    /// Shows the run's tab.
    fn focus_tab(&mut self, target: &TerminalTarget) {
        self.workspace_mut().focus_tab(&target.pane_id, &target.tab_id, true);
    }

    fn tab_exists(&self, target: &TerminalTarget) -> bool {
        self.workspace().tab(&target.pane_id, &target.tab_id).is_some()
    }

    fn agent(&self, target: &TerminalTarget) -> Option<&AgentInstance> {
        self.workspace().agent(&target.pane_id, &target.tab_id)
    }

    /// Marks the tab's agent as working for `run_id`, or as an ordinary agent again (`None`).
    fn set_agent_run_id(&mut self, target: &TerminalTarget, run_id: Option<String>) {
        if let Some(agent) = self.workspace_mut().agent_mut(&target.pane_id, &target.tab_id) {
            agent.automation_run_id = run_id;
        }
    }

    /// Whether someone is looking at the run's tab: it is the active tab of the focused pane.
    fn is_window_opened_by_user(&self, target: &TerminalTarget) -> bool {
        let workspace = self.workspace();
        workspace.active_pane_id() == target.pane_id
            && workspace
                .pane(&target.pane_id)
                .and_then(|pane| pane.active_tab())
                .is_some_and(|tab| tab.id == target.tab_id)
    }

    /// Bumps whenever a saved session replaced every tab ([`Workspace::workspace_restore_generation`]).
    fn workspace_restore_generation(&self) -> u64 {
        self.workspace().workspace_restore_generation()
    }
}
