//! The dashboard's presentation rules without GPUI: how a thread is named and described, the
//! inbox's sections, search, folding and selection, what a new thread can start with, and what
//! the chat column enables and says for the selected thread.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use soprano_agents::{AgentDashboardSection, AgentDashboardSnapshot, DashboardEntryStatus};
use soprano_model::{AgentDashboardEntry, chat_supports};
use soprano_platform::StateStore;
use soprano_types::{AgentCatalog, AgentProfile, AgentStatus, AgentWaitingReason, TerminalTarget};
use soprano_ui::status::StatusPillSpec;

/// One thread in the inbox: an agent tab of the workspace (with its notable branch filled in),
/// why it waits, the project it works in and since when it is in its status.
#[derive(Clone, Debug, PartialEq)]
pub struct DashboardEntry {
    pub entry: AgentDashboardEntry,
    pub waiting_reason: Option<AgentWaitingReason>,
    /// The project's folder name: what the monogram and the line over the title show.
    pub project: String,
    /// When the agent entered its status, as far as the app saw: Working counts from it, an
    /// idle thread shows how long ago it was.
    pub since: SystemTime,
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

    /// The status pill ("Working 2m", Approval, Input, Failed, Done, Starting, Stopped); none
    /// for an idle thread, which shows a relative time instead.
    pub fn pill(&self) -> Option<StatusPillSpec> {
        let working_since = (self.entry.status == AgentStatus::Running).then_some(self.since);
        StatusPillSpec::of(self.entry.status, self.waiting_reason, working_since)
    }

    /// A thread with nothing for the person steps back in the list: one that works on its own
    /// or sits idle, unless it is the open one or asks for attention.
    pub fn is_receded(&self, selected: bool) -> bool {
        !selected
            && !self.entry.needs_attention
            && matches!(
                self.entry.status,
                AgentStatus::Running | AgentStatus::Starting | AgentStatus::Idle | AgentStatus::Stopped
            )
    }

    /// Whether the card has a line under the title: the machine it runs on or its branch.
    pub fn has_meta(&self) -> bool {
        self.entry.machine.is_some() || self.entry.branch.is_some()
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

    /// The row's tooltip: title, agent and session, location, path, branch and the open hint.
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
            self.entry.branch.as_ref().map(|branch| format!("⎇ {branch}")),
            Some("Double-click to open it in its window".to_owned()),
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join("\n")
    }

    /// The header's location chip tooltip: where the tab is, its folder, and what a click does.
    pub fn location_tooltip(&self, home: &Path) -> String {
        [
            Some(self.entry.location()),
            self.abbreviated_path(home),
            Some("Click to open it in its window".into()),
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join("\n")
    }

    /// Whether the search text finds this thread: in its title, project, agent or branch.
    pub fn matches(&self, query: &str) -> bool {
        let needle = query.trim().to_lowercase();
        if needle.is_empty() {
            return true;
        }
        [
            Some(self.title()),
            Some(self.project.clone()),
            Some(self.entry.profile_name.clone()),
            self.entry.branch.clone(),
        ]
        .into_iter()
        .flatten()
        .any(|text| text.to_lowercase().contains(&needle))
    }
}

/// One line of the inbox.
#[derive(Clone, Debug, PartialEq)]
pub enum ListRow<'a> {
    /// "Working 3 ⌄".
    Header { section: AgentDashboardSection, count: usize, folded: bool },
    /// A thread as a card: project and status over the title, its branch under it.
    Card(&'a DashboardEntry),
    /// A stopped thread on one line.
    Slim(&'a DashboardEntry),
}

/// The inbox: threads under Needs you / Working / Ready / Stopped, the search that narrows
/// them, which sections are folded, and the open thread. The selection survives refreshes
/// while its agent exists and otherwise falls to the first thread.
#[derive(Clone, Debug, PartialEq)]
pub struct AgentList {
    /// Every thread, most urgent first.
    entries: Vec<DashboardEntry>,
    selected: Option<String>,
    query: String,
    folded: HashSet<AgentDashboardSection>,
}

impl Default for AgentList {
    /// Stopped threads start folded away, like a shelf.
    fn default() -> Self {
        Self {
            entries: Vec::new(),
            selected: None,
            query: String::new(),
            folded: HashSet::from([AgentDashboardSection::Stopped]),
        }
    }
}

impl AgentList {
    /// Takes a new set of entries (in workspace order; sorted by urgency here). Returns whether
    /// the selection moved to a different agent.
    pub fn update(&mut self, entries: Vec<DashboardEntry>) -> bool {
        self.entries = AgentDashboardSnapshot::new(entries).entries;
        let previous = self.selected.take();
        self.selected = match previous.as_ref() {
            Some(id) if self.entry(id).is_some() => previous.clone(),
            _ => self.entries.first().map(DashboardEntry::id),
        };
        previous != self.selected
    }

    /// The threads the search leaves, under their sections; empty sections are left out.
    pub fn sections(&self) -> Vec<(AgentDashboardSection, Vec<&DashboardEntry>)> {
        AgentDashboardSection::ALL
            .into_iter()
            .filter_map(|section| {
                let members: Vec<&DashboardEntry> = self
                    .entries
                    .iter()
                    .filter(|entry| {
                        AgentDashboardSection::of(*entry) == section && entry.matches(&self.query)
                    })
                    .collect();
                (!members.is_empty()).then_some((section, members))
            })
            .collect()
    }

    /// Every thread in urgency order, whatever the search and the folds hide.
    pub fn entries(&self) -> impl Iterator<Item = &DashboardEntry> {
        self.entries.iter()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn entry(&self, id: &str) -> Option<&DashboardEntry> {
        self.entries.iter().find(|entry| entry.id() == id)
    }

    pub fn selected_id(&self) -> Option<&str> {
        self.selected.as_deref()
    }

    pub fn selected(&self) -> Option<&DashboardEntry> {
        self.selected.as_deref().and_then(|id| self.entry(id))
    }

    pub fn query(&self) -> &str {
        &self.query
    }

    pub fn is_searching(&self) -> bool {
        !self.query.trim().is_empty()
    }

    /// Narrows the list to threads matching `query`; the open thread stays open.
    pub fn set_query(&mut self, query: &str) {
        self.query = query.to_owned();
    }

    pub fn is_folded(&self, section: AgentDashboardSection) -> bool {
        self.folded.contains(&section)
    }

    pub fn toggle_fold(&mut self, section: AgentDashboardSection) {
        if !self.folded.remove(&section) {
            self.folded.insert(section);
        }
    }

    /// The list top to bottom. A search shows its matches as cards without headers; otherwise
    /// each section has its header, a folded one keeps only the open thread, and stopped
    /// threads take one line each.
    pub fn rows(&self) -> Vec<ListRow<'_>> {
        let searching = self.is_searching();
        let mut rows = Vec::new();
        for (section, members) in self.sections() {
            if searching {
                rows.extend(members.into_iter().map(ListRow::Card));
                continue;
            }
            let folded = self.is_folded(section);
            rows.push(ListRow::Header { section, count: members.len(), folded });
            let slim = section == AgentDashboardSection::Stopped;
            for entry in members {
                if folded && self.selected.as_deref() != Some(entry.id().as_str()) {
                    continue;
                }
                rows.push(if slim { ListRow::Slim(entry) } else { ListRow::Card(entry) });
            }
        }
        rows
    }

    /// The threads the list shows, top to bottom: what ↑/↓ move through.
    pub fn visible(&self) -> Vec<&DashboardEntry> {
        self.rows()
            .into_iter()
            .filter_map(|row| match row {
                ListRow::Card(entry) | ListRow::Slim(entry) => Some(entry),
                ListRow::Header { .. } => None,
            })
            .collect()
    }

    /// The open thread's position among [`Self::rows`]; `None` while the search hides it.
    pub fn selected_row(&self) -> Option<usize> {
        let selected = self.selected.as_deref()?;
        self.rows().iter().position(|row| match row {
            ListRow::Card(entry) | ListRow::Slim(entry) => entry.id() == selected,
            ListRow::Header { .. } => false,
        })
    }

    /// Selects a thread; false when there is no such agent.
    pub fn select(&mut self, id: &str) -> bool {
        if self.entry(id).is_none() {
            return false;
        }
        self.selected = Some(id.to_owned());
        true
    }

    /// Moves the selection by `delta` shown threads, stopping at the ends; from a thread the
    /// list hides, to the first or last shown. False when the list shows none.
    pub fn move_selection(&mut self, delta: i32) -> bool {
        let visible: Vec<String> = self.visible().into_iter().map(DashboardEntry::id).collect();
        if visible.is_empty() {
            return false;
        }
        let last = visible.len() as i64 - 1;
        let current = self.selected.as_ref().and_then(|id| visible.iter().position(|shown| shown == id));
        let next = match current {
            Some(current) => (current as i64 + i64::from(delta)).clamp(0, last),
            None if delta < 0 => last,
            None => 0,
        };
        self.selected = Some(visible[next as usize].clone());
        true
    }
}

/// What a new thread starts with: an agent, in its terminal or as a chat.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentChoice {
    pub profile_id: String,
    pub chat: bool,
}

impl AgentChoice {
    /// Where the last choice is kept (app state).
    pub const STATE_KEY: &'static str = "soprano-agents-thread-agent";

    /// Every way to start a thread with the agents of the catalog.
    pub fn all() -> Vec<Self> {
        Self::for_profiles(&AgentCatalog::shared().all())
    }

    /// Every way to start a thread with `profiles`: an agent in its terminal when Soprano can
    /// hand it the thread's first message as it starts, and as a chat where it serves one.
    /// The shell is not an agent, and a custom agent or one behind a launch script would
    /// start without the message.
    pub fn for_profiles(profiles: &[AgentProfile]) -> Vec<Self> {
        profiles
            .iter()
            .filter(|profile| profile.id != "terminal")
            .flat_map(|profile| {
                let choice = |chat| Self { profile_id: profile.id.clone(), chat };
                let terminal = profile.takes_launch_prompt().then(|| choice(false));
                let chat = chat_supports(&profile.id).then(|| choice(true));
                terminal.into_iter().chain(chat)
            })
            .collect()
    }

    /// The agent's name; `omp` when the catalog no longer lists it.
    pub fn profile_name(&self) -> String {
        AgentCatalog::shared().profile(&self.profile_id).map_or_else(|| self.profile_id.clone(), |p| p.name)
    }

    /// `Claude Code`, `omp · Chat`.
    pub fn label(&self) -> String {
        if self.chat { format!("{} · Chat", self.profile_name()) } else { self.profile_name() }
    }

    /// The choice a draft opens with: the last one made while it can still be made, else omp
    /// in its terminal, else the first agent there is.
    pub fn initial(store: &StateStore) -> Option<Self> {
        let all = Self::all();
        let remembered = store
            .get::<(String, bool)>(Self::STATE_KEY)
            .map(|(profile_id, chat)| Self { profile_id, chat })
            .filter(|choice| all.contains(choice));
        let omp = Self { profile_id: "omp".into(), chat: false };
        remembered.or_else(|| all.contains(&omp).then_some(omp)).or_else(|| all.into_iter().next())
    }

    pub fn remember(&self, store: &StateStore) {
        store.set(Self::STATE_KEY, &(self.profile_id.as_str(), self.chat));
    }
}

/// A folder a new thread can work in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProjectChoice {
    pub name: String,
    pub path: String,
}

impl ProjectChoice {
    /// The folder at `path`, named after itself.
    pub fn at(path: impl Into<String>) -> Self {
        let path = path.into();
        let name = Path::new(&path)
            .file_name()
            .map_or_else(|| path.clone(), |name| name.to_string_lossy().into_owned());
        Self { name, path }
    }
}

/// Where a new thread's tab goes, under the draft's headline.
pub fn draft_destination(window_title: Option<&str>) -> String {
    match window_title {
        Some(title) => format!("Opens as a tab of “{title}”"),
        None => "Opens in a new window".to_owned(),
    }
}

/// What the composer asks for.
pub const PLACEHOLDER: &str = "Ask anything";

/// Whether the newest turn is still going ("Working for", Thinking). An agent that waits on
/// the person shows its turn finished.
pub fn is_agent_working(status: Option<AgentStatus>) -> bool {
    matches!(status, Some(AgentStatus::Running | AgentStatus::Starting))
}

/// What the timeline says while it has no turn to show: an invitation where the conversation
/// can be followed, else where to follow it.
pub fn timeline_empty_text(entry: &DashboardEntry, has_conversation: bool) -> String {
    if has_conversation {
        "Send a message to start the conversation.".to_owned()
    } else if entry.entry.conversation.is_none() {
        format!("{} has not started a conversation yet.", entry.entry.profile_name)
    } else {
        format!("{}'s conversation cannot be read here. Open it in its window.", entry.entry.profile_name)
    }
}

/// Messages go to a running, idle, waiting or failed agent that can take them.
pub fn can_reply(entry: Option<&DashboardEntry>, accepts_replies: bool) -> bool {
    accepts_replies
        && entry.is_some_and(|entry| {
            matches!(
                entry.entry.status,
                AgentStatus::Running | AgentStatus::Idle | AgentStatus::Waiting | AgentStatus::Error
            )
        })
}

/// Why the composer cannot send to the thread; empty when it can.
pub fn composer_hint(entry: Option<&DashboardEntry>, accepts_replies: bool) -> &'static str {
    let Some(entry) = entry else { return "" };
    match entry.entry.status {
        AgentStatus::Stopped => "Restart the agent to message it.",
        AgentStatus::Starting if accepts_replies => "Waiting for the agent to become ready.",
        _ if !accepts_replies && entry.entry.is_chat => "Restart the agent to message it.",
        _ if !accepts_replies => "Open the agent in its window to start it.",
        _ => "",
    }
}

/// The hint after a message the agent did not take.
pub const SEND_FAILED: &str = "Could not send to this agent.";

/// Which header controls work for the selected thread.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Controls {
    /// The detailed work log (thinking, full commands and output).
    pub details: bool,
    pub open: bool,
    pub stop: bool,
    pub restart: bool,
    pub reply: bool,
}

impl Controls {
    pub fn new(entry: Option<&DashboardEntry>, has_conversation: bool, accepts_replies: bool) -> Self {
        let status = entry.map(|entry| entry.entry.status);
        Self {
            details: entry.is_some() && has_conversation,
            open: entry.is_some(),
            stop: status.is_some_and(|status| status != AgentStatus::Stopped),
            restart: status.is_some_and(|status| status != AgentStatus::Starting),
            reply: can_reply(entry, accepts_replies),
        }
    }
}

/// The text a message sends: trimmed, `None` when nothing is left.
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
            project: "storefront".into(),
            since: SystemTime::UNIX_EPOCH,
        }
    }

    fn ids(list: &AgentList) -> Vec<String> {
        list.entries().map(|e| e.entry.tab_id.clone()).collect()
    }

    fn shown(list: &AgentList) -> Vec<String> {
        list.rows()
            .into_iter()
            .map(|row| match row {
                ListRow::Header { section, count, folded } => {
                    format!("{} {count}{}", section.title(), if folded { " ›" } else { "" })
                }
                ListRow::Card(entry) => format!("card {}", entry.entry.tab_id),
                ListRow::Slim(entry) => format!("slim {}", entry.entry.tab_id),
            })
            .collect()
    }

    #[test]
    fn a_thread_goes_by_its_agents_name_until_it_has_a_task() {
        let mut thread = entry("a", AgentStatus::Waiting);
        assert_eq!(thread.title(), "Codex");
        thread.entry.tab_title = "⠙ Fix the checkout total".into();
        assert_eq!(thread.title(), "Fix the checkout total");
    }

    #[test]
    fn a_thread_on_a_machine_names_it_ahead_of_its_folder_there() {
        let home = Path::new("/Users/me");
        let mut thread = entry("a", AgentStatus::Running);
        assert!(!thread.has_meta());
        thread.entry.machine = Some("vps".into());
        thread.entry.cwd = Some("/home/me/shop".into());
        assert!(thread.has_meta());
        assert_eq!(thread.abbreviated_path(home).as_deref(), Some("vps:/home/me/shop"));
        thread.entry.cwd = None;
        assert_eq!(thread.abbreviated_path(home).as_deref(), Some("vps"));
    }

    #[test]
    fn a_row_tooltip_names_the_task_agent_location_path_and_branch() {
        let mut thread = entry("a", AgentStatus::Waiting);
        let tooltip = thread.row_tooltip(Path::new("/Users/me"));
        assert!(tooltip.starts_with("Codex\nCodex\n"));
        assert!(tooltip.contains("/tmp/projects/storefront"));
        assert!(tooltip.ends_with("Double-click to open it in its window"));
        thread.entry.branch = Some("feat/refunds".into());
        assert!(thread.row_tooltip(Path::new("/Users/me")).contains("\n⎇ feat/refunds\n"));
    }

    #[test]
    fn a_working_thread_counts_its_time_and_an_idle_one_has_no_pill() {
        let since = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000);
        let mut working = entry("a", AgentStatus::Running);
        working.since = since;
        assert_eq!(
            working.pill().map(|pill| pill.text(since + Duration::from_secs(125))).as_deref(),
            Some("Working 2m")
        );
        let mut done = entry("b", AgentStatus::Waiting);
        done.waiting_reason = Some(AgentWaitingReason::TurnEnded);
        assert_eq!(done.pill().map(|pill| pill.label), Some("Done"));
        assert_eq!(entry("c", AgentStatus::Idle).pill(), None);
        assert_eq!(entry("d", AgentStatus::Stopped).pill().map(|pill| pill.label), Some("Stopped"));
    }

    #[test]
    fn threads_that_work_alone_or_sit_idle_step_back_unless_open_or_asking() {
        assert!(entry("a", AgentStatus::Running).is_receded(false));
        assert!(entry("a", AgentStatus::Idle).is_receded(false));
        assert!(!entry("a", AgentStatus::Idle).is_receded(true));
        assert!(!entry("a", AgentStatus::Waiting).is_receded(false));
        assert!(!entry("a", AgentStatus::Error).is_receded(false));
        let mut asking = entry("a", AgentStatus::Idle);
        asking.entry.needs_attention = true;
        assert!(!asking.is_receded(false));
    }

    #[test]
    fn status_changes_move_threads_into_urgency_order_and_keep_the_selection() {
        let mut list = AgentList::default();
        let running = |tab| entry(tab, AgentStatus::Running);
        assert!(list.update(vec![running("0"), running("1"), running("2")]));
        assert_eq!(ids(&list), ["0", "1", "2"]);
        assert_eq!(list.selected_id(), Some("pane-0:0"));

        let mut needs_you = running("2");
        needs_you.entry.status = AgentStatus::Waiting;
        assert!(!list.update(vec![running("0"), running("1"), needs_you, entry("3", AgentStatus::Starting)]));
        assert_eq!(ids(&list), ["2", "0", "1", "3"]);
        assert_eq!(shown(&list), ["Needs you 1", "card 2", "Working 3", "card 0", "card 1", "card 3"]);
        assert_eq!(list.selected_id(), Some("pane-0:0"));
    }

    #[test]
    fn the_selection_falls_to_the_first_thread_when_its_agent_goes_away() {
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
    fn stopped_threads_start_folded_on_one_line_each_and_a_fold_keeps_the_open_thread() {
        let mut list = AgentList::default();
        list.update(vec![
            entry("0", AgentStatus::Running),
            entry("1", AgentStatus::Stopped),
            entry("2", AgentStatus::Stopped),
        ]);
        assert_eq!(shown(&list), ["Working 1", "card 0", "Stopped 2 ›"]);
        // ↓ stays on the last thread the list shows.
        list.move_selection(1);
        assert_eq!(list.selected_id(), Some("pane-0:0"));

        list.toggle_fold(AgentDashboardSection::Stopped);
        assert_eq!(shown(&list), ["Working 1", "card 0", "Stopped 2", "slim 1", "slim 2"]);
        list.select("pane-2:2");
        assert_eq!(list.selected_row(), Some(4));
        list.toggle_fold(AgentDashboardSection::Stopped);
        assert_eq!(shown(&list), ["Working 1", "card 0", "Stopped 2 ›", "slim 2"]);

        list.toggle_fold(AgentDashboardSection::Working);
        assert_eq!(shown(&list), ["Working 1 ›", "Stopped 2 ›", "slim 2"]);
    }

    #[test]
    fn a_search_lists_its_matches_as_cards_without_headers_and_keeps_the_open_thread() {
        let mut list = AgentList::default();
        let mut payments = entry("1", AgentStatus::Stopped);
        payments.project = "payments".into();
        let mut branch = entry("2", AgentStatus::Waiting);
        branch.entry.branch = Some("feat/pay-later".into());
        list.update(vec![entry("0", AgentStatus::Running), payments, branch]);
        assert_eq!(list.selected_id(), Some("pane-2:2"));
        list.select("pane-0:0");

        list.set_query(" PAY ");
        assert!(list.is_searching());
        assert_eq!(shown(&list), ["card 2", "card 1"]);
        assert_eq!(list.selected_id(), Some("pane-0:0"));
        assert_eq!(list.selected_row(), None);
        // From the hidden open thread, ↓ lands on the first match and ↑ on the last.
        list.move_selection(1);
        assert_eq!(list.selected_id(), Some("pane-2:2"));
        list.select("pane-0:0");
        list.move_selection(-1);
        assert_eq!(list.selected_id(), Some("pane-1:1"));

        list.set_query("nothing like it");
        assert!(list.rows().is_empty());
        assert!(!list.move_selection(1));
        list.set_query("");
        assert_eq!(shown(&list), ["Needs you 1", "card 2", "Working 1", "card 0", "Stopped 1 ›", "slim 1"]);
    }

    #[test]
    fn a_thread_starts_with_any_built_in_agent_in_its_terminal_and_omp_also_as_a_chat() {
        let all = AgentChoice::all();
        assert!(all.iter().all(|choice| choice.profile_id != "terminal"));
        let labels: Vec<String> = all.iter().map(AgentChoice::label).collect();
        assert_eq!(labels, ["Codex", "Claude Code", "Open Code", "omp", "omp · Chat"]);
    }

    #[test]
    fn agents_that_cannot_be_handed_a_first_message_are_not_offered_in_their_terminal() {
        use soprano_types::{AgentProfile, DefaultAgents};
        let custom = AgentProfile { id: "aider".into(), command: "aider".into(), ..DefaultAgents::codex() };
        let scripted_claude =
            AgentProfile { launch_script: Some("./start-claude.sh".into()), ..DefaultAgents::claude_code() };
        let scripted_omp = AgentProfile { launch_script: Some("./omp.sh".into()), ..DefaultAgents::omp() };
        let choices =
            AgentChoice::for_profiles(&[custom, scripted_claude, scripted_omp, DefaultAgents::codex()]);
        // omp behind a script still serves its chat, which takes the message itself.
        assert_eq!(
            choices,
            [
                AgentChoice { profile_id: "omp".into(), chat: true },
                AgentChoice { profile_id: "codex".into(), chat: false }
            ]
        );
    }

    #[test]
    fn a_draft_opens_with_omp_in_its_terminal_until_another_choice_is_remembered() {
        let store = StateStore::in_memory();
        assert_eq!(AgentChoice::initial(&store), Some(AgentChoice { profile_id: "omp".into(), chat: false }));

        let chat = AgentChoice { profile_id: "omp".into(), chat: true };
        chat.remember(&store);
        assert_eq!(AgentChoice::initial(&store), Some(chat));

        // A remembered agent that is gone gives way to the default.
        AgentChoice { profile_id: "retired".into(), chat: false }.remember(&store);
        assert_eq!(AgentChoice::initial(&store).map(|choice| choice.label()).as_deref(), Some("omp"));
    }

    #[test]
    fn the_draft_says_which_window_gets_the_tab() {
        assert_eq!(draft_destination(Some("storefront")), "Opens as a tab of “storefront”");
        assert_eq!(draft_destination(None), "Opens in a new window");
        assert_eq!(ProjectChoice::at("/tmp/projects/storefront").name, "storefront");
        assert_eq!(ProjectChoice::at("/").name, "/");
    }

    #[test]
    fn messages_need_an_agent_that_takes_them_and_is_not_starting_or_stopped() {
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
    fn the_composer_hint_explains_why_a_message_cannot_be_sent() {
        let thread = |status| entry("a", status);
        assert_eq!(composer_hint(None, true), "");
        assert_eq!(composer_hint(Some(&thread(AgentStatus::Waiting)), true), "");
        assert_eq!(
            composer_hint(Some(&thread(AgentStatus::Running)), false),
            "Open the agent in its window to start it."
        );
        let mut chat = thread(AgentStatus::Running);
        chat.entry.is_chat = true;
        assert_eq!(composer_hint(Some(&chat), false), "Restart the agent to message it.");
        assert_eq!(
            composer_hint(Some(&thread(AgentStatus::Starting)), true),
            "Waiting for the agent to become ready."
        );
        assert_eq!(
            composer_hint(Some(&thread(AgentStatus::Stopped)), true),
            "Restart the agent to message it."
        );
    }

    #[test]
    fn an_empty_timeline_invites_a_message_or_says_where_the_conversation_is() {
        let mut thread = entry("a", AgentStatus::Idle);
        assert_eq!(timeline_empty_text(&thread, true), "Send a message to start the conversation.");
        assert_eq!(timeline_empty_text(&thread, false), "Codex has not started a conversation yet.");
        thread.entry.conversation = Some(soprano_types::AgentConversation::new("c1"));
        assert_eq!(
            timeline_empty_text(&thread, false),
            "Codex's conversation cannot be read here. Open it in its window."
        );
    }

    #[test]
    fn stop_needs_a_running_agent_and_restart_one_that_is_not_starting() {
        let stopped = Controls::new(Some(&entry("a", AgentStatus::Stopped)), false, true);
        assert!(!stopped.stop && stopped.restart && stopped.open && !stopped.reply && !stopped.details);
        let starting = Controls::new(Some(&entry("a", AgentStatus::Starting)), true, true);
        assert!(starting.stop && !starting.restart && starting.details);
        let none = Controls::new(None, true, true);
        assert!(!none.open && !none.stop && !none.restart && !none.details && !none.reply);
    }

    #[test]
    fn a_message_is_trimmed_and_an_empty_one_is_not_sent() {
        assert_eq!(reply_text("  Run the focused tests \n"), Some("Run the focused tests".into()));
        assert_eq!(reply_text(" \n "), None);
        assert!(is_agent_working(Some(AgentStatus::Starting)));
        assert!(!is_agent_working(Some(AgentStatus::Waiting)));
    }
}
