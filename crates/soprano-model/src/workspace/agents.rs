//! Agent lifecycle, status and attention, conversations, and running commands.

use std::collections::HashSet;
use std::time::SystemTime;

use soprano_types::{AgentCatalog, AgentConversation, AgentProfile, AgentStatus, AgentWaitingReason};

use super::{AgentReadinessGeneration, TerminalLifecycleAction, Workspace, WorkspaceEvent};
use crate::agent_instance::AgentInstance;
use crate::pane::{PaneTab, PaneType};
use soprano_types::TerminalTarget;

impl Workspace {
    // MARK: - Lookup

    pub fn agent(&self, pane_id: &str, tab_id: &str) -> Option<&AgentInstance> {
        self.tab(pane_id, tab_id)?.agent.as_ref()
    }

    /// Direct access to an agent's runtime fields the host keeps (process id, last message,
    /// automation run). Records no change; call [`Self::reload_agent_profiles`] or a status
    /// update when views must refresh.
    pub fn agent_mut(&mut self, pane_id: &str, tab_id: &str) -> Option<&mut AgentInstance> {
        self.tab_mut(pane_id, tab_id)?.agent.as_mut()
    }

    /// The profile of the agent in `pane_id`'s active tab, when that tab is an agent tab.
    pub fn agent_profile(&self, pane_id: &str) -> Option<AgentProfile> {
        let tab = self.panes.get(pane_id)?.active_tab()?;
        if tab.pane_type != PaneType::Agent {
            return None;
        }
        AgentCatalog::shared().profile(&tab.agent.as_ref()?.profile_id)
    }

    fn agent_tab_agent_mut(&mut self, target: &TerminalTarget) -> Option<&mut AgentInstance> {
        let tab = self.tab_mut(&target.pane_id, &target.tab_id)?;
        if tab.pane_type != PaneType::Agent {
            return None;
        }
        tab.agent.as_mut()
    }

    fn active_tab_target(&self, pane_id: &str) -> Option<TerminalTarget> {
        let tab_id = self.panes.get(pane_id)?.active_tab()?.id.clone();
        Some(TerminalTarget::new(pane_id, tab_id))
    }

    // MARK: - Lifecycle

    /// Restarts the agent of `pane_id`'s active tab.
    pub fn restart_agent_in_pane(&mut self, pane_id: &str) {
        if let Some(target) = self.active_tab_target(pane_id) {
            self.restart_agent(&target);
        }
    }

    /// Marks the agent tab's agent starting again and asks the host to restart its surface.
    pub fn restart_agent(&mut self, target: &TerminalTarget) {
        if self.agent_tab_agent_mut(target).is_none() {
            return;
        }
        self.cancel_agent_readiness_generation(target);
        if let Some(agent) = self.agent_tab_agent_mut(target) {
            agent.status = AgentStatus::Starting;
            agent.needs_attention = false;
            agent.exit_code = None;
            agent.process_id = None;
            agent.started_at = Some(SystemTime::now());
            agent.restart_count += 1;
        }
        self.events.push(WorkspaceEvent::Terminal(TerminalLifecycleAction::Restart(target.clone())));
        self.notify_model(false);
    }

    /// Stops the agent of `pane_id`'s active tab.
    pub fn stop_agent_in_pane(&mut self, pane_id: &str) {
        if let Some(target) = self.active_tab_target(pane_id) {
            self.stop_agent(&target);
        }
    }

    /// Marks the agent tab's agent stopped and asks the host to stop its surface.
    pub fn stop_agent(&mut self, target: &TerminalTarget) {
        self.cancel_agent_readiness_generation(target);
        let Some(agent) = self.agent_tab_agent_mut(target) else { return };
        if agent.status == AgentStatus::Stopped {
            return;
        }
        agent.status = AgentStatus::Stopped;
        agent.needs_attention = false;
        self.events.push(WorkspaceEvent::Terminal(TerminalLifecycleAction::Stop(target.clone())));
        self.notify_model(false);
    }

    /// The terminal also reports commands run by an ordinary shell. An agent whose process is
    /// known detaches only once that process is gone, so a prior command's delayed completion
    /// cannot hide one that still runs. An agent reported from the shell itself (a `codex`
    /// wrapper's `agent-event ready`) names no process until its first turn ends; it ran as
    /// the shell's foreground command, so the prompt returning means it quit.
    pub fn agent_command_did_finish(&mut self, target: &TerminalTarget, exit_code: Option<i32>) {
        let Some(tab) = self.tab(&target.pane_id, &target.tab_id) else { return };
        let Some(agent) = &tab.agent else { return };
        if tab.pane_type == PaneType::Agent {
            self.agent_returned_to_shell(target, exit_code);
        } else if let Some(process_id) = agent.process_id {
            if !crate::process::process_exists(process_id) {
                self.agent_process_did_exit(target, exit_code);
            }
        } else {
            self.agent_process_did_exit(target, exit_code);
        }
    }

    /// Reconciles an agent process that exited on its own. An agent tab whose pane process is
    /// gone (no shell left) stays restartable in the stopped state, while agents in a terminal
    /// are detached because it has returned to its shell.
    pub fn agent_process_did_exit(&mut self, target: &TerminalTarget, exit_code: Option<i32>) {
        if self.agent(&target.pane_id, &target.tab_id).is_none() {
            return;
        }
        self.cancel_agent_readiness_generation(target);
        let Some(tab) = self.tab_mut(&target.pane_id, &target.tab_id) else { return };
        let Some(agent) = tab.agent.as_mut() else { return };
        if tab.pane_type == PaneType::Terminal {
            let agent_name = Self::agent_name(&agent.profile_id);
            if tab.title == agent_name {
                tab.title = tab
                    .cwd
                    .as_deref()
                    .and_then(crate::file_url::last_segment)
                    .unwrap_or("Terminal")
                    .to_owned();
            }
            tab.agent = None;
        } else {
            if agent.status == AgentStatus::Stopped && agent.exit_code == exit_code {
                return;
            }
            agent.status = AgentStatus::Stopped;
            agent.needs_attention = false;
            agent.exit_code = exit_code;
        }
        self.notify_model(false);
    }

    /// The agent is gone but its pane still runs a shell: dedicated agent tabs fall back to
    /// the user's shell after the agent exits. The tab becomes an ordinary terminal, exactly
    /// like an agent that was typed into one.
    pub fn agent_returned_to_shell(&mut self, target: &TerminalTarget, exit_code: Option<i32>) {
        let Some(tab) = self.tab_mut(&target.pane_id, &target.tab_id) else { return };
        if tab.agent.is_none() {
            return;
        }
        tab.pane_type = PaneType::Terminal;
        self.agent_process_did_exit(target, exit_code);
    }

    // MARK: - Status

    /// Updates the status of `pane_id`'s active tab's agent.
    pub fn update_agent_status_in_pane(&mut self, pane_id: &str, status: AgentStatus) {
        if let Some(target) = self.active_tab_target(pane_id) {
            self.update_agent_status(&target.pane_id, &target.tab_id, status, None, None);
        }
    }

    /// Updates an agent's status, and its attention mark when `needs_attention` is given. A
    /// stopped agent stays stopped (restart it instead).
    pub fn update_agent_status(
        &mut self,
        pane_id: &str,
        tab_id: &str,
        status: AgentStatus,
        needs_attention: Option<bool>,
        waiting_reason: Option<AgentWaitingReason>,
    ) {
        let Some(agent) = self.agent_mut(pane_id, tab_id) else { return };
        if agent.status == AgentStatus::Stopped {
            return;
        }
        // A waiting agent without a stated reason finished its turn: every CLI reports that,
        // and only some say why they wait.
        let reason =
            (status == AgentStatus::Waiting).then(|| waiting_reason.unwrap_or(AgentWaitingReason::TurnEnded));
        let attention_changed = needs_attention.is_some_and(|value| agent.needs_attention != value);
        if agent.status == status && !attention_changed && agent.waiting_reason == reason {
            return;
        }
        agent.status = status;
        agent.waiting_reason = reason;
        if let Some(value) = needs_attention {
            agent.needs_attention = value;
        }
        if status == AgentStatus::Starting {
            agent.started_at = Some(SystemTime::now());
        } else {
            self.cancel_agent_readiness_generation(&TerminalTarget::new(pane_id, tab_id));
        }
        self.notify_model(false);
    }

    pub fn clear_attention(&mut self, pane_id: &str, tab_id: &str) {
        let Some(agent) = self.agent_mut(pane_id, tab_id) else { return };
        if !agent.needs_attention {
            return;
        }
        agent.needs_attention = false;
        self.notify_model(false);
    }

    /// Associates an agent started manually inside a regular terminal tab with Soprano's
    /// lifecycle model. A live supported conversation can be resumed as an agent tab on
    /// restore; unrecognized shells remain ordinary terminals.
    pub fn attach_agent_if_needed(
        &mut self,
        pane_id: &str,
        tab_id: &str,
        profile_id: &str,
    ) -> Option<&AgentInstance> {
        if profile_id == "terminal" {
            return None;
        }
        let profile = AgentCatalog::shared().profile(profile_id)?;
        let tab = self.tab_mut(pane_id, tab_id)?;
        if let Some(existing) = &tab.agent
            && (existing.profile_id == profile.id || tab.pane_type != PaneType::Terminal)
        {
            return self.agent(pane_id, tab_id);
        }
        tab.agent = Some(AgentInstance::new(tab_id, &profile.id));
        if tab.title == "Terminal" {
            tab.title = profile.name;
        }
        self.notify_model(false);
        self.agent(pane_id, tab_id)
    }

    /// Records the agent's own conversation id, so the tab resumes it on restore. Ignored for
    /// stopped agents, another profile's report, unsupported agents and malformed ids.
    pub fn record_agent_conversation(
        &mut self,
        conversation: AgentConversation,
        pane_id: &str,
        tab_id: &str,
        profile_id: Option<&str>,
    ) {
        let Some(agent) = self.agent_mut(pane_id, tab_id) else { return };
        if agent.status == AgentStatus::Stopped
            || profile_id.is_some_and(|id| id != agent.profile_id)
            || !AgentConversation::supports(&agent.profile_id)
            || !AgentConversation::valid_id(&conversation.id)
        {
            return;
        }
        let mut value = conversation;
        let same = agent.conversation.as_ref().filter(|current| current.id == value.id);
        if value.cwd.is_none() {
            value.cwd = same.and_then(|current| current.cwd.clone());
        }
        // Codex's notify payload and some hooks carry no transcript path; the file of the same
        // conversation is still the one reported earlier.
        if value.transcript_path.is_none() {
            value.transcript_path = same.and_then(|current| current.transcript_path.clone());
        }
        if agent.conversation.as_ref() == Some(&value) {
            return;
        }
        agent.conversation = Some(value);
        self.notify_model(false);
    }

    // MARK: - Codex readiness

    /// Starts a readiness fallback for a starting Codex agent; `None` for anything else.
    pub fn begin_agent_readiness_generation(
        &mut self,
        target: &TerminalTarget,
    ) -> Option<AgentReadinessGeneration> {
        let agent = self.agent(&target.pane_id, &target.tab_id)?;
        if agent.profile_id != "codex" || agent.status != AgentStatus::Starting {
            return None;
        }
        self.next_agent_readiness_generation += 1;
        let value = self.next_agent_readiness_generation;
        self.active_agent_readiness_generations.insert(target.clone(), value);
        Some(AgentReadinessGeneration { target: target.clone(), value })
    }

    /// Marks the agent ready when `generation` is still current and the agent still starting.
    pub fn mark_agent_ready_if_starting(&mut self, generation: &AgentReadinessGeneration) {
        if self.active_agent_readiness_generations.get(&generation.target) != Some(&generation.value) {
            return;
        }
        self.active_agent_readiness_generations.remove(&generation.target);
        let target = &generation.target;
        let Some(agent) = self.agent_mut(&target.pane_id, &target.tab_id) else { return };
        if agent.status != AgentStatus::Starting {
            return;
        }
        agent.status = AgentStatus::Idle;
        self.notify_model(false);
    }

    // MARK: - Running commands

    /// Replaces the terminals running a command; a change is recorded only when it differs.
    pub fn set_running_command_targets(&mut self, targets: HashSet<TerminalTarget>) {
        if targets == self.running_command_targets {
            return;
        }
        self.running_command_targets = targets;
        self.notify_model(false);
    }

    /// Whether `tab` shows as running a command. An attached agent is the command its shell
    /// runs, and the agent's own status shows instead.
    pub fn is_running_command(&self, tab: &PaneTab, pane_id: &str) -> bool {
        tab.agent.is_none() && self.running_command_targets.contains(&TerminalTarget::new(pane_id, &tab.id))
    }

    // MARK: - Counts

    pub fn ready_agent_count(&self) -> usize {
        self.all_agents().filter(|agent| agent.status == AgentStatus::Idle).count()
    }

    pub fn attention_count(&self) -> usize {
        self.all_agents().filter(|agent| agent.needs_attention).count()
    }

    fn all_agents(&self) -> impl Iterator<Item = &AgentInstance> {
        self.panes.values().flat_map(|pane| pane.tabs.iter()).filter_map(|tab| tab.agent.as_ref())
    }
}
