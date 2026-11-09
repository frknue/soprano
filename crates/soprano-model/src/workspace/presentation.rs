//! Read-only views over the workspace the UI renders: pane order and hints, window search,
//! the Agent Dashboard entries (`AgentManager+Dashboard.swift`), tab badges and the status bar
//! location.

use std::time::SystemTime;

use soprano_types::{AgentCatalog, AgentConversation, AgentStatus, AgentWaitingReason};

use super::{TerminalTarget, Workspace};
use crate::pane::{PaneState, PaneTab};
use crate::terminal_title;
use crate::window::WorkspaceWindowState;

/// A pane and the letters that jump to it (`⌃⇧` + key).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PaneShortcut {
    pub key: String,
    pub pane_id: String,
}

/// One agent tab as presented by the global monitoring dashboard.
#[derive(Clone, Debug, PartialEq)]
pub struct AgentDashboardEntry {
    pub pane_id: String,
    pub tab_id: String,
    pub tab_title: String,
    pub window_title: String,
    pub profile_id: String,
    pub profile_name: String,
    pub status: AgentStatus,
    pub needs_attention: bool,
    pub started_at: Option<SystemTime>,
    pub cwd: Option<String>,
    pub session_name: Option<String>,
    /// The agent's own conversation, which locates the transcript the dashboard renders as a
    /// timeline.
    pub conversation: Option<AgentConversation>,
    /// A chat tab: it has no terminal, and replies go to its session.
    pub is_chat: bool,
    /// The branch the agent works on when it is not its repository's default; the dashboard
    /// fills it in from the shared branch monitor.
    pub branch: Option<String>,
}

impl AgentDashboardEntry {
    /// `pane-3:tab-4`.
    pub fn id(&self) -> String {
        format!("{}:{}", self.pane_id, self.tab_id)
    }

    pub fn target(&self) -> TerminalTarget {
        TerminalTarget::new(&self.pane_id, &self.tab_id)
    }

    /// What the agent works on, as the sidebar names it: its task title without the CLI's
    /// brand and spinner, or its name before it has one.
    pub fn title(&self) -> String {
        terminal_title::display(&self.tab_title, self.cwd.as_deref(), Some(&self.profile_name))
    }

    /// `session ▸ window ▸ title`, for tooltips.
    pub fn location(&self) -> String {
        [self.session_name.clone(), Some(self.window_title.clone()), Some(self.title())]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" ▸ ")
    }
}

/// The agents and running commands under one window or layout tab, for its badges and
/// tooltip. Stopped agents are left out.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ActivitySummary {
    /// Status (and waiting reason) of each open agent, in pane and tab order.
    pub agents: Vec<(AgentStatus, Option<AgentWaitingReason>)>,
    pub running_commands: usize,
}

impl ActivitySummary {
    /// Badge order, most urgent first.
    pub const URGENCY_ORDER: [AgentStatus; 5] = [
        AgentStatus::Error,
        AgentStatus::Waiting,
        AgentStatus::Running,
        AgentStatus::Starting,
        AgentStatus::Idle,
    ];

    /// The first agent in [`Self::URGENCY_ORDER`]: the one the agent badge shows.
    pub fn most_urgent_agent(&self) -> Option<(AgentStatus, Option<AgentWaitingReason>)> {
        Self::URGENCY_ORDER
            .iter()
            .find_map(|status| self.agents.iter().find(|(agent_status, _)| agent_status == status).copied())
    }

    /// `2 agents: 1 working, 1 ready` for tooltips; `None` without agents.
    pub fn agents_summary(&self) -> Option<String> {
        if self.agents.is_empty() {
            return None;
        }
        let noun = if self.agents.len() == 1 { "agent" } else { "agents" };
        let counts: Vec<String> = Self::URGENCY_ORDER
            .iter()
            .filter_map(|status| {
                let count = self.agents.iter().filter(|(agent_status, _)| agent_status == status).count();
                (count > 0).then(|| format!("{count} {}", status.display_label().to_lowercase()))
            })
            .collect();
        Some(format!("{} {noun}: {}", self.agents.len(), counts.join(", ")))
    }

    /// `2 commands running` for tooltips; `None` when none is.
    pub fn running_commands_summary(&self) -> Option<String> {
        match self.running_commands {
            0 => None,
            1 => Some("1 command running".into()),
            count => Some(format!("{count} commands running")),
        }
    }

    /// `prefix — 1 agent: 1 working — 1 command running`: a tab's tooltip and accessibility
    /// label, e.g. with prefix `Window 1: Editor` or `Tab 2: server`.
    pub fn describe(&self, prefix: &str) -> String {
        let mut description = prefix.to_owned();
        for summary in [self.agents_summary(), self.running_commands_summary()].into_iter().flatten() {
            description.push_str(" — ");
            description.push_str(&summary);
        }
        description
    }
}

/// The focused location, for the status bar: `Session 1  /  Soprano  /  Claude · Tab 2`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActiveLocation {
    pub session_name: String,
    pub window_title: String,
    /// The focused pane's active tab's title.
    pub pane_title: Option<String>,
    /// 1-based, only when the window has more than one layout tab.
    pub tab_number: Option<usize>,
}

impl ActiveLocation {
    /// The plain text the status bar shows.
    pub fn text(&self) -> String {
        let mut text = format!("{}  /  {}", self.session_name, self.window_title);
        if let Some(pane_title) = &self.pane_title {
            text.push_str("  /  ");
            text.push_str(pane_title);
        }
        if let Some(number) = self.tab_number {
            text.push_str(&format!(" · Tab {number}"));
        }
        text
    }
}

impl Workspace {
    // MARK: - Pane order and hints

    /// The window's panes, tab by tab, each tab in on-screen order.
    pub fn ordered_panes(&self, window_id: &str) -> Vec<&PaneState> {
        self.windows
            .get(window_id)
            .map(|window| window.ordered_pane_ids().iter().filter_map(|id| self.panes.get(id)).collect())
            .unwrap_or_default()
    }

    /// The first tab in `window_id`, in on-screen pane order and then tab order, whose search
    /// terms contain `query` case-insensitively. `None` for a blank query or no match.
    pub fn first_tab_matching(&self, window_id: &str, query: &str) -> Option<TerminalTarget> {
        let needle = query.trim().to_lowercase();
        if needle.is_empty() {
            return None;
        }
        self.ordered_panes(window_id).into_iter().find_map(|pane| {
            pane.tabs
                .iter()
                .find(|tab| tab.search_terms().iter().any(|term| term.to_lowercase().contains(&needle)))
                .map(|tab| TerminalTarget::new(&pane.id, &tab.id))
        })
    }

    /// Every pane of the session's windows, top to bottom, with its hint.
    pub fn pane_shortcut_assignments(&self) -> Vec<PaneShortcut> {
        let pane_ids: Vec<String> = self
            .active_session_windows()
            .into_iter()
            .flat_map(|window| self.ordered_panes(&window.id).into_iter().map(|pane| pane.id.clone()))
            .collect();
        Self::pane_hints(pane_ids.len())
            .into_iter()
            .zip(pane_ids)
            .map(|(key, pane_id)| PaneShortcut { key, pane_id })
            .collect()
    }

    /// `count` pane hints in list order, the way Vimium labels links: single letters while
    /// they last; past that, the last letters become the first key of two-letter hints (three
    /// past 400 panes), so every pane gets one and no hint starts another.
    pub fn pane_hints(count: usize) -> Vec<String> {
        const KEYS: &str = "bdefgimnopqrstuvwxyz";
        let letters: Vec<String> = KEYS.chars().map(String::from).collect();
        if count <= letters.len() {
            return letters.into_iter().take(count).collect();
        }
        // `capacity` hints of `length` letters exist; enough for `count`.
        let mut length = 1;
        let mut capacity = letters.len();
        while capacity < count {
            length += 1;
            capacity *= letters.len();
        }
        let mut shorter = vec![String::new()];
        for _ in 1..length {
            shorter = shorter
                .iter()
                .flat_map(|prefix| letters.iter().map(move |letter| format!("{prefix}{letter}")))
                .collect();
        }
        // Keep as many one-letter-shorter hints as still leave room for the rest; each of the
        // others becomes the start of `letters.len()` hints.
        let kept = (capacity - count) / (letters.len() - 1);
        let expanded = shorter[kept..]
            .iter()
            .flat_map(|prefix| letters.iter().map(move |letter| format!("{prefix}{letter}")));
        shorter[..kept].iter().cloned().chain(expanded).take(count).collect()
    }

    // MARK: - Agent Dashboard

    /// Every agent tab in stable visual workspace order (windows in creation order, panes tab
    /// by tab on screen, tabs in order), before the dashboard sorts them by urgency.
    pub fn agent_dashboard_entries(&self) -> Vec<AgentDashboardEntry> {
        self.sorted_windows()
            .into_iter()
            .flat_map(|window| {
                self.ordered_panes(&window.id).into_iter().flat_map(move |pane| {
                    pane.tabs.iter().filter_map(move |tab| self.dashboard_entry(tab, pane, window))
                })
            })
            .collect()
    }

    /// The dashboard entry for one tab, or `None` when the tab holds no agent. A title or
    /// directory change touches only its own tab, so the dashboard follows those without
    /// rebuilding the whole snapshot.
    pub fn agent_dashboard_entry(&self, target: &TerminalTarget) -> Option<AgentDashboardEntry> {
        let pane = self.panes.get(&target.pane_id)?;
        let tab = pane.tab(&target.tab_id)?;
        let window = self.window_containing_pane(&target.pane_id)?;
        self.dashboard_entry(tab, pane, window)
    }

    fn dashboard_entry(
        &self,
        tab: &PaneTab,
        pane: &PaneState,
        window: &WorkspaceWindowState,
    ) -> Option<AgentDashboardEntry> {
        let agent = tab.agent.as_ref()?;
        let profile = AgentCatalog::shared().profile(&agent.profile_id);
        let cwd = tab
            .cwd
            .clone()
            .or_else(|| profile.as_ref().and_then(|profile| profile.cwd.clone()))
            .or_else(|| std::env::current_dir().ok().map(|dir| dir.to_string_lossy().into_owned()));
        Some(AgentDashboardEntry {
            pane_id: pane.id.clone(),
            tab_id: tab.id.clone(),
            tab_title: tab.title.clone(),
            window_title: window.title.clone(),
            profile_id: agent.profile_id.clone(),
            profile_name: profile.map_or_else(|| tab.title.clone(), |profile| profile.name),
            status: agent.status,
            needs_attention: agent.needs_attention,
            started_at: agent.started_at,
            cwd,
            session_name: self.terminal_sessions.get(&window.session_id).map(|session| session.name.clone()),
            conversation: agent.conversation.clone(),
            is_chat: tab.is_chat(),
            branch: None,
        })
    }

    // MARK: - Badges

    /// The open agents and running commands in every tab of `window_id` (its window tab's
    /// badges).
    pub fn window_activity(&self, window_id: &str) -> ActivitySummary {
        self.activity(self.ordered_panes(window_id))
    }

    /// The open agents and running commands in one layout tab (its tab's badges).
    pub fn layout_tab_activity(&self, layout_tab_id: &str) -> ActivitySummary {
        let panes = self
            .window_containing_layout_tab(layout_tab_id)
            .and_then(|window| window.tab_index_of(layout_tab_id).map(|index| &window.tabs()[index]))
            .and_then(|tab| tab.layout.as_ref())
            .map(|layout| layout.ordered_leaf_ids().iter().filter_map(|id| self.panes.get(id)).collect())
            .unwrap_or_default();
        self.activity(panes)
    }

    fn activity(&self, panes: Vec<&PaneState>) -> ActivitySummary {
        let mut summary = ActivitySummary::default();
        for pane in panes {
            for tab in &pane.tabs {
                if let Some(agent) = tab.agent.as_ref().filter(|agent| agent.status != AgentStatus::Stopped) {
                    summary.agents.push((agent.status, agent.waiting_reason));
                }
                if self.is_running_command(tab, &pane.id) {
                    summary.running_commands += 1;
                }
            }
        }
        summary
    }

    // MARK: - Status bar

    /// `session / window / pane` for the focused location, with the active tab when the window
    /// has more than one. `None` when nothing is open.
    pub fn active_location(&self) -> Option<ActiveLocation> {
        let window = self.active_window()?;
        Some(ActiveLocation {
            session_name: self
                .active_session()
                .map_or_else(|| "Session".to_owned(), |session| session.name.clone()),
            window_title: window.title.clone(),
            pane_title: self
                .panes
                .get(self.active_pane_id())
                .and_then(PaneState::active_tab)
                .map(|tab| tab.title.clone()),
            tab_number: (window.tabs().len() > 1).then(|| window.active_tab_index() + 1),
        })
    }
}
