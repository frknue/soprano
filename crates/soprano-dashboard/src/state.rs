//! The dashboard's presentation rules without GPUI (`AgentDashboardViewController.swift`):
//! how an agent is named and described, the list's sections and selection, and what the
//! detail view shows, enables and says for the selected agent.

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use soprano_agents::{AgentDashboardSection, AgentDashboardSnapshot, DashboardEntryStatus, Date};
use soprano_model::AgentDashboardEntry;
use soprano_text::context_line::ContextLine;
use soprano_types::TerminalTarget;
use soprano_types::{AgentStatus, AgentWaitingReason};
use soprano_ui::status::StatusPillSpec;

/// One agent on the dashboard: the workspace's entry (with its notable branch filled in) and
/// why it waits, which the entry does not carry.
#[derive(Clone, Debug, PartialEq)]
pub struct DashboardEntry {
    pub entry: AgentDashboardEntry,
    pub waiting_reason: Option<AgentWaitingReason>,
}

impl DashboardEntryStatus for DashboardEntry {
    fn status(&self) -> AgentStatus {
        self.entry.status
    }

    fn needs_attention(&self) -> bool {
        self.entry.needs_attention
    }
}

impl DashboardEntry {
    pub fn id(&self) -> String {
        self.entry.id()
    }

    pub fn target(&self) -> TerminalTarget {
        self.entry.target()
    }

    pub fn status(&self) -> AgentStatus {
        self.entry.status
    }

    /// What the agent works on, as the sidebar names it.
    pub fn title(&self) -> String {
        self.entry.title()
    }

    /// `[machine ·] omp · folder · ⎇ branch`, the line under the title.
    pub fn context(&self, home: &Path) -> ContextLine {
        let mut line = ContextLine::for_title(
            &self.title(),
            Some(&self.entry.profile_name),
            self.entry.cwd.as_deref(),
            self.entry.branch.clone(),
            0,
            &home.to_string_lossy(),
        );
        if let Some(machine) = &self.entry.machine {
            line.context.insert(0, machine.clone());
        }
        line
    }

    /// The status pill; an idle agent reads Ready.
    pub fn pill(&self) -> StatusPillSpec {
        StatusPillSpec::of(self.entry.status, self.waiting_reason, None).unwrap_or(StatusPillSpec::READY)
    }

    /// The working directory with the home folder as `~`; on a machine, `machine:folder` as
    /// written there.
    pub fn abbreviated_path(&self, home: &Path) -> Option<String> {
        match (&self.entry.machine, self.entry.cwd.as_deref()) {
            (Some(machine), Some(cwd)) => Some(format!("{machine}:{cwd}")),
            (Some(machine), None) => Some(machine.clone()),
            (None, cwd) => cwd.map(|cwd| soprano_platform::paths::abbreviate_home_in(Path::new(cwd), home)),
        }
    }

    /// The row's tooltip: title, agent and session, location, path and the open hint.
    pub fn row_tooltip(&self, home: &Path) -> String {
        let description = [Some(self.entry.profile_name.clone()), self.entry.session_name.clone()]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" · ");
        [
            Some(self.title()),
            Some(description),
            Some(self.entry.location()),
            self.abbreviated_path(home),
            Some("Double-click to open agent".to_owned()),
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join("\n")
    }

    /// `title, agent, status, location`.
    pub fn accessibility_label(&self) -> String {
        format!(
            "{}, {}, {}, {}",
            self.title(),
            self.entry.profile_name,
            self.entry.status.display_label(),
            self.entry.location()
        )
    }

    /// The detail location line's tooltip: location and path.
    pub fn location_tooltip(&self, home: &Path) -> String {
        [Some(self.entry.location()), self.abbreviated_path(home)]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// `Reply to Codex…`.
    pub fn reply_placeholder(&self) -> String {
        format!("Reply to {}…", self.entry.profile_name)
    }
}

/// `Monitoring 2 agents across 1 window`, the header's subtitle.
pub fn monitoring_subtitle(agent_count: usize, window_count: usize) -> String {
    let agent_noun = if agent_count == 1 { "agent" } else { "agents" };
    let window_noun = if window_count == 1 { "window" } else { "windows" };
    format!("Monitoring {agent_count} {agent_noun} across {window_count} {window_noun}")
}

pub fn date(time: SystemTime) -> Date {
    Date::from(time)
}

/// How long an agent has been running: `38s`, `4m 12s`, `2h 7m`, `stopped`.
pub fn elapsed_text(status: AgentStatus, started_at: Option<SystemTime>, now: SystemTime) -> String {
    soprano_agents::elapsed_text(status, started_at.map(date), date(now))
}

/// The list: agents under Needs you / Working / Ready / Stopped, and the selection, which
/// survives refreshes while its agent is listed and otherwise falls to the first agent.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct AgentList {
    sections: Vec<(AgentDashboardSection, Vec<DashboardEntry>)>,
    selected: Option<String>,
}

impl AgentList {
    /// Takes a new set of entries (in workspace order; sorted by urgency here). Returns whether
    /// the selection moved to a different agent.
    pub fn update(&mut self, entries: Vec<DashboardEntry>) -> bool {
        let snapshot = AgentDashboardSnapshot::new(entries);
        self.sections = AgentDashboardSection::group(&snapshot.entries);
        let previous = self.selected.take();
        let selected = match previous.as_ref() {
            Some(id) if self.index_of(id).is_some() => previous.clone(),
            _ => self.entries().next().map(DashboardEntry::id),
        };
        self.selected = selected;
        previous != self.selected
    }

    pub fn sections(&self) -> &[(AgentDashboardSection, Vec<DashboardEntry>)] {
        &self.sections
    }

    /// Every agent in list order.
    pub fn entries(&self) -> impl Iterator<Item = &DashboardEntry> {
        self.sections.iter().flat_map(|(_, entries)| entries.iter())
    }

    pub fn len(&self) -> usize {
        self.sections.iter().map(|(_, entries)| entries.len()).sum()
    }

    pub fn is_empty(&self) -> bool {
        self.sections.is_empty()
    }

    pub fn entry(&self, id: &str) -> Option<&DashboardEntry> {
        self.entries().find(|entry| entry.id() == id)
    }

    pub fn index_of(&self, id: &str) -> Option<usize> {
        self.entries().position(|entry| entry.id() == id)
    }

    pub fn selected_id(&self) -> Option<&str> {
        self.selected.as_deref()
    }

    pub fn selected(&self) -> Option<&DashboardEntry> {
        self.selected.as_deref().and_then(|id| self.entry(id))
    }

    pub fn selected_index(&self) -> Option<usize> {
        self.selected.as_deref().and_then(|id| self.index_of(id))
    }

    /// Selects a listed agent; false when `id` is not listed.
    pub fn select(&mut self, id: &str) -> bool {
        if self.index_of(id).is_none() {
            return false;
        }
        self.selected = Some(id.to_owned());
        true
    }

    /// Moves the selection by `delta` rows, stopping at the ends. False on an empty list.
    pub fn move_selection(&mut self, delta: i32) -> bool {
        let count = self.len();
        if count == 0 {
            return false;
        }
        let current = self.selected_index().unwrap_or(0) as i64;
        let next = (current + i64::from(delta)).clamp(0, count as i64 - 1) as usize;
        let next_id = self.entries().nth(next).map(DashboardEntry::id);
        self.selected = next_id;
        true
    }
}

/// Whether the detail shows the conversation: a chat always (it has no terminal), else an
/// agent with a readable transcript until T switches to the terminal.
pub fn shows_timeline(entry: Option<&DashboardEntry>, has_transcript: bool, prefers_terminal: bool) -> bool {
    entry.is_some_and(|entry| entry.entry.is_chat) || (has_transcript && !prefers_terminal)
}

/// Whether the newest turn is still going ("Working for", Thinking). An agent that waits on
/// the person shows its turn finished.
pub fn is_agent_working(status: Option<AgentStatus>) -> bool {
    matches!(status, Some(AgentStatus::Running | AgentStatus::Starting))
}

/// What the timeline says before the transcript has a turn.
pub fn timeline_empty_text(has_entry: bool) -> &'static str {
    if has_entry { "Waiting for the agent's first message…" } else { "Choose an agent to follow its work." }
}

/// The activity line when the transcript says nothing: the status in words.
pub fn fallback_activity(status: Option<AgentStatus>) -> &'static str {
    match status {
        Some(AgentStatus::Idle) => "Ready for a prompt",
        Some(AgentStatus::Starting) => "Starting",
        Some(AgentStatus::Running) => "Working",
        Some(AgentStatus::Waiting) => "Waiting for input",
        Some(AgentStatus::Error) => "Stopped with an error",
        Some(AgentStatus::Stopped) => "Stopped",
        None => "",
    }
}

/// Replies go to a running, idle, waiting or failed agent whose terminal is up.
pub fn can_reply(entry: Option<&DashboardEntry>, terminal_available: bool) -> bool {
    terminal_available
        && entry.is_some_and(|entry| {
            matches!(
                entry.entry.status,
                AgentStatus::Running | AgentStatus::Idle | AgentStatus::Waiting | AgentStatus::Error
            )
        })
}

/// The line under the reply field.
pub fn reply_hint(entry: Option<&DashboardEntry>, terminal_available: bool) -> &'static str {
    let Some(entry) = entry else { return "" };
    if !terminal_available {
        return if entry.entry.is_chat {
            "Restart the agent before replying."
        } else {
            "Open the agent to initialize its terminal."
        };
    }
    match entry.entry.status {
        AgentStatus::Starting => "Waiting for the agent to become ready.",
        AgentStatus::Stopped => "Restart the agent before replying.",
        AgentStatus::Running | AgentStatus::Idle | AgentStatus::Waiting | AgentStatus::Error => {
            "Press Return to send this single-line reply."
        }
    }
}

/// The hint after a reply the terminal did not take.
pub const SEND_FAILED: &str = "Could not send to this terminal.";

/// What the terminal card shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TerminalText {
    /// The terminal's visible text, highlighted.
    Output(String),
    /// A muted note in the UI font.
    Message(&'static str),
}

impl TerminalText {
    /// `terminal` is the visible text, `None` while the terminal is not available.
    pub fn new(has_entry: bool, terminal: Option<&str>) -> Self {
        match terminal {
            _ if !has_entry => Self::Message("Select an agent to see its current terminal."),
            None => Self::Message("This terminal is not currently available."),
            Some("") => Self::Message("No terminal output yet."),
            Some(text) => Self::Output(text.to_owned()),
        }
    }

    pub fn text(&self) -> &str {
        match self {
            Self::Output(text) => text,
            Self::Message(text) => text,
        }
    }
}

/// Which toolbar controls work for the selected agent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Controls {
    pub timeline_segment: bool,
    pub terminal_segment: bool,
    pub details: bool,
    pub open: bool,
    pub stop: bool,
    pub restart: bool,
    pub reply: bool,
}

impl Controls {
    pub fn new(
        entry: Option<&DashboardEntry>,
        has_transcript: bool,
        prefers_terminal: bool,
        terminal_available: bool,
    ) -> Self {
        let is_chat = entry.is_some_and(|entry| entry.entry.is_chat);
        let status = entry.map(|entry| entry.entry.status);
        Self {
            timeline_segment: has_transcript || is_chat,
            terminal_segment: !is_chat,
            details: shows_timeline(entry, has_transcript, prefers_terminal),
            open: entry.is_some(),
            stop: status.is_some_and(|status| status != AgentStatus::Stopped),
            restart: status.is_some_and(|status| status != AgentStatus::Starting),
            reply: can_reply(entry, terminal_available),
        }
    }
}

/// The text a reply sends: trimmed, `None` when nothing is left.
pub fn reply_text(draft: &str) -> Option<String> {
    let trimmed = draft.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

/// Where the CLIs keep their transcripts and `~` folds to.
pub fn default_home() -> PathBuf {
    soprano_platform::paths::home_dir()
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use soprano_text::context_line::ContextPart;

    use super::*;

    fn entry(tab: &str, status: AgentStatus) -> DashboardEntry {
        DashboardEntry {
            entry: AgentDashboardEntry {
                pane_id: format!("pane-{tab}"),
                tab_id: tab.into(),
                tab_title: "Codex".into(),
                window_title: "Window 1".into(),
                profile_id: "codex".into(),
                profile_name: "Codex".into(),
                status,
                needs_attention: false,
                started_at: None,
                cwd: Some("/tmp/projects/storefront".into()),
                session_name: None,
                conversation: None,
                is_chat: false,
                branch: None,
                machine: None,
            },
            waiting_reason: None,
        }
    }

    fn ids(list: &AgentList) -> Vec<String> {
        list.entries().map(|e| e.entry.tab_id.clone()).collect()
    }

    #[test]
    fn an_agent_goes_by_its_name_over_its_folder_until_it_has_a_task() {
        let home = Path::new("/Users/me");
        let mut agent = entry("a", AgentStatus::Waiting);
        assert_eq!(agent.title(), "Codex");
        assert_eq!(agent.context(home).parts(), [ContextPart::Text("storefront".into())]);

        agent.entry.tab_title = "⠙ Fix the checkout total".into();
        agent.entry.cwd = Some("/tmp/projects/payments".into());
        agent.entry.branch = Some("feat/refunds".into());
        assert_eq!(agent.title(), "Fix the checkout total");
        assert_eq!(
            agent.context(home).parts(),
            [
                ContextPart::Text("Codex".into()),
                ContextPart::Text("payments".into()),
                ContextPart::Branch("feat/refunds".into())
            ]
        );
    }

    #[test]
    fn an_agent_on_a_machine_names_it_ahead_of_its_folder_there() {
        let home = Path::new("/Users/me");
        let mut agent = entry("a", AgentStatus::Running);
        agent.entry.tab_title = "⠙ Fix the checkout total".into();
        agent.entry.machine = Some("vps".into());
        agent.entry.cwd = Some("/home/me/shop".into());
        assert_eq!(
            agent.context(home).parts(),
            [
                ContextPart::Text("vps".into()),
                ContextPart::Text("Codex".into()),
                ContextPart::Text("shop".into())
            ]
        );
        assert_eq!(agent.abbreviated_path(home).as_deref(), Some("vps:/home/me/shop"));
        agent.entry.cwd = None;
        assert_eq!(agent.abbreviated_path(home).as_deref(), Some("vps"));
    }

    #[test]
    fn a_row_tooltip_and_label_name_the_task_agent_location_and_path() {
        let agent = entry("a", AgentStatus::Waiting);
        let tooltip = agent.row_tooltip(Path::new("/Users/me"));
        assert!(tooltip.starts_with("Codex\nCodex\n"));
        assert!(tooltip.contains("/tmp/projects/storefront"));
        assert!(tooltip.ends_with("Double-click to open agent"));
        assert!(agent.accessibility_label().starts_with("Codex, Codex"));
    }

    #[test]
    fn a_waiting_agent_whose_turn_ended_reads_done_and_an_idle_one_ready() {
        let mut agent = entry("a", AgentStatus::Waiting);
        agent.waiting_reason = Some(AgentWaitingReason::TurnEnded);
        assert_eq!(agent.pill().label, "Done");
        assert_eq!(entry("b", AgentStatus::Idle).pill().label, "Ready");
    }

    #[test]
    fn the_subtitle_counts_agents_and_windows_in_singular_and_plural() {
        assert_eq!(monitoring_subtitle(1, 1), "Monitoring 1 agent across 1 window");
        assert_eq!(monitoring_subtitle(3, 2), "Monitoring 3 agents across 2 windows");
    }

    #[test]
    fn elapsed_runtime_reads_seconds_minutes_and_hours_or_stopped() {
        let start = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let at = |seconds| start + Duration::from_secs(seconds);
        assert_eq!(elapsed_text(AgentStatus::Running, Some(start), at(38)), "38s");
        assert_eq!(elapsed_text(AgentStatus::Running, Some(start), at(252)), "4m 12s");
        assert_eq!(elapsed_text(AgentStatus::Running, Some(start), at(2 * 3600 + 7 * 60)), "2h 7m");
        assert_eq!(elapsed_text(AgentStatus::Stopped, Some(start), at(9)), "stopped");
        assert_eq!(elapsed_text(AgentStatus::Running, None, at(9)), "");
    }

    #[test]
    fn status_changes_move_agents_into_urgency_order_and_keep_the_selection() {
        let mut list = AgentList::default();
        let running = |tab| entry(tab, AgentStatus::Running);
        assert!(list.update(vec![running("0"), running("1"), running("2")]));
        assert_eq!(ids(&list), ["0", "1", "2"]);
        assert_eq!(list.selected_id(), Some("pane-0:0"));

        let mut needs_you = running("2");
        needs_you.entry.status = AgentStatus::Waiting;
        assert!(!list.update(vec![running("0"), running("1"), needs_you, entry("3", AgentStatus::Starting)]));
        assert_eq!(ids(&list), ["2", "0", "1", "3"]);
        let headings: Vec<String> = list
            .sections()
            .iter()
            .map(|(section, entries)| format!("{} {}", section.title(), entries.len()))
            .collect();
        assert_eq!(headings, ["Needs you 1", "Working 3"]);
        assert_eq!(list.selected_id(), Some("pane-0:0"));
    }

    #[test]
    fn the_selection_falls_to_the_first_agent_when_its_agent_goes_away() {
        let mut list = AgentList::default();
        list.update(vec![entry("0", AgentStatus::Running), entry("1", AgentStatus::Running)]);
        assert!(list.select("pane-1:1"));
        assert!(list.update(vec![entry("0", AgentStatus::Running)]));
        assert_eq!(list.selected_id(), Some("pane-0:0"));
        assert!(list.update(Vec::new()));
        assert_eq!(list.selected_id(), None);
        assert!(!list.select("pane-0:0"));
    }

    #[test]
    fn moving_the_selection_stops_at_both_ends() {
        let mut list = AgentList::default();
        assert!(!list.move_selection(1));
        list.update(vec![entry("0", AgentStatus::Running), entry("1", AgentStatus::Running)]);
        assert!(list.move_selection(1));
        assert_eq!(list.selected_id(), Some("pane-1:1"));
        list.move_selection(5);
        assert_eq!(list.selected_id(), Some("pane-1:1"));
        list.move_selection(-9);
        assert_eq!(list.selected_id(), Some("pane-0:0"));
    }

    #[test]
    fn a_chat_always_shows_its_conversation_and_others_only_with_a_transcript() {
        let mut chat = entry("c", AgentStatus::Idle);
        chat.entry.is_chat = true;
        assert!(shows_timeline(Some(&chat), false, true));
        let agent = entry("a", AgentStatus::Idle);
        assert!(!shows_timeline(Some(&agent), false, false));
        assert!(shows_timeline(Some(&agent), true, false));
        assert!(!shows_timeline(Some(&agent), true, true));
        assert!(!shows_timeline(None, false, false));
    }

    #[test]
    fn replies_need_a_live_terminal_and_an_agent_that_is_not_starting_or_stopped() {
        for (status, can) in [
            (AgentStatus::Running, true),
            (AgentStatus::Idle, true),
            (AgentStatus::Waiting, true),
            (AgentStatus::Error, true),
            (AgentStatus::Starting, false),
            (AgentStatus::Stopped, false),
        ] {
            assert_eq!(can_reply(Some(&entry("a", status)), true), can, "{status:?}");
            assert!(!can_reply(Some(&entry("a", status)), false));
        }
        assert!(!can_reply(None, true));
    }

    #[test]
    fn the_reply_hint_explains_why_a_reply_cannot_be_sent() {
        let agent = |status| entry("a", status);
        assert_eq!(reply_hint(None, true), "");
        assert_eq!(
            reply_hint(Some(&agent(AgentStatus::Running)), false),
            "Open the agent to initialize its terminal."
        );
        let mut chat = agent(AgentStatus::Running);
        chat.entry.is_chat = true;
        assert_eq!(reply_hint(Some(&chat), false), "Restart the agent before replying.");
        assert_eq!(
            reply_hint(Some(&agent(AgentStatus::Starting)), true),
            "Waiting for the agent to become ready."
        );
        assert_eq!(
            reply_hint(Some(&agent(AgentStatus::Stopped)), true),
            "Restart the agent before replying."
        );
        assert_eq!(
            reply_hint(Some(&agent(AgentStatus::Waiting)), true),
            "Press Return to send this single-line reply."
        );
    }

    #[test]
    fn the_terminal_card_shows_the_text_or_says_why_there_is_none() {
        assert_eq!(
            TerminalText::new(false, Some("x")).text(),
            "Select an agent to see its current terminal."
        );
        assert_eq!(TerminalText::new(true, None).text(), "This terminal is not currently available.");
        assert_eq!(TerminalText::new(true, Some("")).text(), "No terminal output yet.");
        assert_eq!(TerminalText::new(true, Some("ready")), TerminalText::Output("ready".into()));
    }

    #[test]
    fn stop_needs_a_running_agent_and_restart_one_that_is_not_starting() {
        let stopped = Controls::new(Some(&entry("a", AgentStatus::Stopped)), false, false, true);
        assert!(!stopped.stop && stopped.restart && stopped.open && !stopped.reply);
        let starting = Controls::new(Some(&entry("a", AgentStatus::Starting)), false, false, true);
        assert!(starting.stop && !starting.restart);
        let none = Controls::new(None, false, false, false);
        assert!(!none.open && !none.stop && !none.restart && !none.timeline_segment && none.terminal_segment);
        let with_transcript = Controls::new(Some(&entry("a", AgentStatus::Running)), true, false, true);
        assert!(with_transcript.timeline_segment && with_transcript.details);
    }

    #[test]
    fn the_status_says_what_an_agent_without_a_transcript_does() {
        assert_eq!(fallback_activity(Some(AgentStatus::Idle)), "Ready for a prompt");
        assert_eq!(fallback_activity(Some(AgentStatus::Error)), "Stopped with an error");
        assert_eq!(fallback_activity(None), "");
        assert!(is_agent_working(Some(AgentStatus::Starting)));
        assert!(!is_agent_working(Some(AgentStatus::Waiting)));
    }

    #[test]
    fn a_reply_is_trimmed_and_an_empty_one_is_not_sent() {
        assert_eq!(reply_text("  Run the focused tests \n"), Some("Run the focused tests".into()));
        assert_eq!(reply_text(" \n "), None);
    }
}
