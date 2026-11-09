//! The Agent Dashboard's snapshot and grouping (`AgentDashboardSnapshot.swift`), plus the
//! elapsed runtime text its rows show.

use soprano_types::{AgentConversation, AgentStatus};

use crate::timeline::Date;

/// What the snapshot needs from one agent tab. [`AgentDashboardEntry`] implements it; the app
/// can implement it on its own entry type (such as the workspace model's) through a newtype.
pub trait DashboardEntryStatus {
    fn status(&self) -> AgentStatus;
    fn needs_attention(&self) -> bool;
}

/// One agent tab as presented by the global monitoring dashboard.
///
/// The minimal input the dashboard logic consumes. `title` is what the agent works on as the
/// sidebar names it (the workspace model computes it from the tab title, working directory and
/// agent name with its terminal-title rules), so this crate does not depend on the model.
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
    pub started_at: Option<Date>,
    pub cwd: Option<String>,
    pub session_name: Option<String>,
    /// The agent's own conversation, which locates the transcript the dashboard renders as a
    /// timeline.
    pub conversation: Option<AgentConversation>,
    /// A chat tab: it has no terminal, and replies go to its session.
    pub is_chat: bool,
    /// The branch the agent works on when it is not its repository's default.
    pub branch: Option<String>,
    /// The display title (see the type's docs); the tab title when the caller has none.
    pub title: String,
}

impl AgentDashboardEntry {
    /// `"<paneId>:<tabId>"`.
    pub fn id(&self) -> String {
        format!("{}:{}", self.pane_id, self.tab_id)
    }

    /// `session ▸ window ▸ title`, for tooltips.
    pub fn location(&self) -> String {
        [self.session_name.as_deref(), Some(self.window_title.as_str()), Some(self.title.as_str())]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" ▸ ")
    }
}

impl DashboardEntryStatus for AgentDashboardEntry {
    fn status(&self) -> AgentStatus {
        self.status
    }

    fn needs_attention(&self) -> bool {
        self.needs_attention
    }
}

/// The groups the dashboard lists agents under, most urgent first. Each covers a contiguous run
/// of the snapshot's urgency order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AgentDashboardSection {
    /// Asks for attention, waits for input, or failed.
    NeedsYou,
    Working,
    Ready,
    Stopped,
}

impl AgentDashboardSection {
    pub const ALL: [Self; 4] = [Self::NeedsYou, Self::Working, Self::Ready, Self::Stopped];

    pub fn of(entry: &impl DashboardEntryStatus) -> Self {
        if entry.needs_attention() {
            return Self::NeedsYou;
        }
        match entry.status() {
            AgentStatus::Waiting | AgentStatus::Error => Self::NeedsYou,
            AgentStatus::Running | AgentStatus::Starting => Self::Working,
            AgentStatus::Idle => Self::Ready,
            AgentStatus::Stopped => Self::Stopped,
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::NeedsYou => "Needs you",
            Self::Working => "Working",
            Self::Ready => "Ready",
            Self::Stopped => "Stopped",
        }
    }

    /// `entries`, already in urgency order, under their sections, leaving out empty ones.
    pub fn group<E: DashboardEntryStatus + Clone>(entries: &[E]) -> Vec<(Self, Vec<E>)> {
        Self::ALL
            .into_iter()
            .filter_map(|section| {
                let members: Vec<E> = entries.iter().filter(|e| Self::of(*e) == section).cloned().collect();
                (!members.is_empty()).then_some((section, members))
            })
            .collect()
    }
}

/// A point-in-time, presentation-ready view of every attached agent.
///
/// This deliberately contains no mutable state. The workspace remains the source of truth; the
/// dashboard rebuilds this snapshot after ordinary model notifications and redraws only the
/// entries that differ from the last one.
#[derive(Clone, Debug, PartialEq)]
pub struct AgentDashboardSnapshot<E = AgentDashboardEntry> {
    pub entries: Vec<E>,
}

impl<E: DashboardEntryStatus> AgentDashboardSnapshot<E> {
    /// Orders `entries` by urgency, keeping the given order within a rank.
    pub fn new(mut entries: Vec<E>) -> Self {
        // `sort_by_key` is stable, so equal ranks keep their order.
        entries.sort_by_key(urgency_rank);
        Self { entries }
    }

    pub fn total_count(&self) -> usize {
        self.entries.len()
    }

    pub fn working_count(&self) -> usize {
        self.entries
            .iter()
            .filter(|e| matches!(e.status(), AgentStatus::Starting | AgentStatus::Running))
            .count()
    }

    pub fn needs_input_count(&self) -> usize {
        self.entries.iter().filter(|e| e.status() == AgentStatus::Waiting).count()
    }

    pub fn error_count(&self) -> usize {
        self.entries.iter().filter(|e| e.status() == AgentStatus::Error).count()
    }
}

fn urgency_rank(entry: &impl DashboardEntryStatus) -> u8 {
    if entry.needs_attention() {
        return 0;
    }
    match entry.status() {
        AgentStatus::Waiting => 1,
        AgentStatus::Error => 2,
        AgentStatus::Running => 3,
        AgentStatus::Starting => 4,
        AgentStatus::Idle => 5,
        AgentStatus::Stopped => 6,
    }
}

/// The runtime a dashboard row shows: empty without a start, `stopped` for a stopped agent,
/// else `42s`, `3m 5s` or `1h 2m`.
pub fn elapsed_text(status: AgentStatus, started_at: Option<Date>, now: Date) -> String {
    let Some(started_at) = started_at else { return String::new() };
    if status == AgentStatus::Stopped {
        return "stopped".into();
    }
    let interval = (now - started_at).num_seconds().max(0);
    if interval < 60 {
        return format!("{interval}s");
    }
    if interval < 3_600 {
        return format!("{}m {}s", interval / 60, interval % 60);
    }
    format!("{}h {}m", interval / 3_600, (interval % 3_600) / 60)
}
