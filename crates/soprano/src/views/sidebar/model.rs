//! What the sidebar shows, worked out from the workspace without GPUI: the window list (window
//! rows, then each expanded window's panes tab by tab with the gaps between them), the agents
//! grouped by what they need, the pane-hint caps and the trailing slot each row shows
//! (`SidebarView.rebuildRows`, `paneHintCaps`, the rows' `hoverStateDidChange`).

use std::time::SystemTime;

use soprano_agents::dashboard::{AgentDashboardSection, AgentDashboardSnapshot, DashboardEntryStatus};
use soprano_model::{
    AgentDashboardEntry, AgentInstance, PaneState, PaneTab, PaneType, Workspace, terminal_title,
};
use soprano_text::context_line::ContextLine;
use soprano_types::{AgentCatalog, AgentStatus};
use soprano_ui::keycaps::{KeyPlatform, chord_cap};
use soprano_ui::status::{StatusClock, StatusPillSpec, TabBadge};

/// Rows sit 1 px apart. Panes that share a layout tab stay that close, a new tab starts a
/// little further down, and a new window further still, so the list groups itself without a
/// label on every row (`SidebarView.rowGap` / `tabGap` / `windowGap`).
pub const ROW_GAP: f32 = 1.0;
pub const TAB_GAP: f32 = 5.0;
pub const WINDOW_GAP: f32 = 10.0;

/// Which hints the held keys reveal (`isControlKeyHeld`, `typedPaneHint`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Hints {
    pub control_held: bool,
    /// The letters of a longer pane hint typed so far.
    pub typed: String,
}

impl Hints {
    /// Holding Control shows the pane hints; a started hint keeps them up.
    pub fn shows_pane_hints(&self) -> bool {
        self.control_held || !self.typed.is_empty()
    }

    /// Window numbers show while Control is held and no pane hint is started.
    pub fn shows_window_numbers(&self) -> bool {
        self.control_held && self.typed.is_empty()
    }
}

/// The caps for what is left of a pane hint after `typed`, or `None` when the hint does not go
/// on from it: `⌃⇧B`, or `⌃⇧Z` `B`, which reads `B` once `Z` is typed. Off macOS the hint chord
/// is Alt+Shift (Control+Shift is how `cmd` bindings are pressed there).
pub fn pane_hint_caps(hint: &str, typed: &str, platform: KeyPlatform) -> Option<Vec<String>> {
    if hint.chars().count() <= typed.chars().count() || !hint.starts_with(typed) {
        return None;
    }
    let letters: Vec<String> = hint[typed.len()..].chars().map(|c| c.to_uppercase().collect()).collect();
    if !typed.is_empty() {
        return Some(letters);
    }
    let first = match platform {
        KeyPlatform::Mac => format!("⌃⇧{}", letters[0]),
        KeyPlatform::Other => format!("Alt+Shift+{}", letters[0]),
    };
    Some(std::iter::once(first).chain(letters[1..].iter().cloned()).collect())
}

/// A pane hint's tooltip: `Ctrl+Shift+Z, then B`.
pub fn pane_hint_tooltip(caps: &[String]) -> String {
    caps.iter().map(|cap| cap.replace("⌃⇧", "Ctrl+Shift+")).collect::<Vec<_>>().join(", then ")
}

/// A window's jump cap (`⌃3`, `Ctrl+3`).
pub fn window_number_cap(number: usize, platform: KeyPlatform) -> String {
    chord_cap(true, false, false, &number.to_string(), platform)
}

/// What sits at a row's right end: the jump hint while hints show, else the close button under
/// the pointer, else the row's status (pill or badges).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrailingSlot {
    Hint,
    Close,
    Status,
}

pub fn trailing_slot(shows_hint: bool, hovered: bool) -> TrailingSlot {
    if shows_hint {
        TrailingSlot::Hint
    } else if hovered {
        TrailingSlot::Close
    } else {
        TrailingSlot::Status
    }
}

/// What a pane row shows as its icon.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PaneKind {
    Agent(String),
    Chat(String),
    Terminal,
    Diff,
    Document,
    Browser,
}

/// Documents are browser-type tabs, so they are told apart first (`SidebarView.rowKind`).
pub fn pane_kind(tab: Option<&PaneTab>) -> PaneKind {
    let Some(tab) = tab else { return PaneKind::Terminal };
    let profile = || tab.agent.as_ref().map(|agent| agent.profile_id.clone()).unwrap_or_default();
    if tab.is_chat() {
        return PaneKind::Chat(profile());
    }
    if tab.agent.is_some() {
        return PaneKind::Agent(profile());
    }
    if tab.is_diff() {
        return PaneKind::Diff;
    }
    if tab.is_markdown() || tab.is_editor() || tab.is_file_preview() {
        return PaneKind::Document;
    }
    if tab.pane_type == PaneType::Browser {
        return PaneKind::Browser;
    }
    PaneKind::Terminal
}

fn agent_name(tab: &PaneTab) -> Option<String> {
    tab.agent
        .as_ref()
        .and_then(|agent| AgentCatalog::shared().profile(&agent.profile_id))
        .map(|profile| profile.name)
}

/// Browser, Markdown, editor and diff tabs are named after their page or file already; a
/// terminal's or agent's title is tidied by `TerminalTitle` (`sidebarTitle(for:)`).
pub fn sidebar_title(pane: &PaneState, home: &str) -> String {
    let Some(tab) = pane.active_tab() else { return "Pane".into() };
    if tab.pane_type == PaneType::Browser {
        return tab.title.clone();
    }
    terminal_title::display_in(
        &tab.title,
        tab.effective_working_directory().as_deref(),
        agent_name(tab).as_deref(),
        home,
    )
}

/// The line under a pane's title: the machine it runs on, the agent (when its title is its
/// task) and folder, a non-default branch, "N tabs" (`PaneContextLine`). A tab on a machine
/// shows the folder it started in and no branch: this computer's disk knows neither.
pub fn context_line(
    pane: &PaneState,
    title: &str,
    branch: &dyn Fn(&str) -> Option<String>,
    home: &str,
) -> ContextLine {
    let Some(tab) = pane.active_tab() else { return ContextLine::default() };
    let machine = tab.remote.as_ref().map(|remote| remote.machine.clone());
    let cwd = if machine.is_some() { tab.cwd.clone() } else { tab.effective_working_directory() };
    let mut line = ContextLine::for_title(
        title,
        agent_name(tab).as_deref(),
        cwd.as_deref(),
        cwd.as_deref().filter(|_| machine.is_none()).and_then(branch),
        pane.tabs.len(),
        home,
    );
    if let Some(machine) = machine {
        line.context.insert(0, machine);
    }
    line
}

/// An agent's pill, timed by the clock, and the moment it entered its status (rows show the
/// time since then when there is no pill).
fn agent_pill(
    agent: &AgentInstance,
    clock: &mut StatusClock,
    now: SystemTime,
) -> (Option<StatusPillSpec>, SystemTime) {
    let since = clock.since(&agent.id, agent.status, agent.started_at, now);
    let pill = StatusPillSpec::of(
        agent.status,
        agent.waiting_reason,
        (agent.status == AgentStatus::Running).then_some(since),
    );
    (pill, since)
}

/// A window header.
#[derive(Clone, Debug, PartialEq)]
pub struct WindowRow {
    pub id: String,
    pub title: String,
    /// 1-9: its avatar number and `⌃N` jump.
    pub number: Option<usize>,
    pub pane_count: usize,
    /// Agent tabs asking for attention.
    pub attention_count: usize,
    pub agent_badge: Option<TabBadge>,
    pub running_badge: Option<TabBadge>,
    pub expanded: bool,
    pub active: bool,
    pub is_title_custom: bool,
    pub shows_number_hint: bool,
}

impl WindowRow {
    /// `3 panes, 1 agent ready` (the count's tooltip).
    pub fn counts_tooltip(&self) -> String {
        let panes = format!("{} pane{}", self.pane_count, if self.pane_count == 1 { "" } else { "s" });
        if self.attention_count > 0 {
            let s = if self.attention_count == 1 { "" } else { "s" };
            format!("{panes}, {} agent{s} ready", self.attention_count)
        } else {
            panes
        }
    }
}

/// A pane under its window.
#[derive(Clone, Debug, PartialEq)]
pub struct PaneRow {
    pub pane_id: String,
    pub tab_id: Option<String>,
    pub kind: PaneKind,
    pub title: String,
    pub meta: ContextLine,
    pub pill: Option<StatusPillSpec>,
    /// An agent's status start: the time since shows when it has no pill.
    pub since: Option<SystemTime>,
    /// An agent that needs nothing from you (running, starting, idle, stopped) recedes unless
    /// its row is focused; waiting and failed agents stand out.
    pub recedes: bool,
    pub hint_caps: Option<Vec<String>>,
    pub shows_hint: bool,
    /// The focused pane of the active window.
    pub focused: bool,
    pub in_active_window: bool,
    /// The guide runs from the window title to the last pane.
    pub first_in_window: bool,
    pub last_in_window: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub enum RowModel {
    Window(WindowRow),
    Pane(PaneRow),
}

#[derive(Clone, Debug, PartialEq)]
pub struct ListRow {
    /// Space above the row.
    pub gap: f32,
    pub row: RowModel,
}

/// The inputs the list reads besides the workspace.
pub struct ListInput<'a> {
    pub hints: &'a Hints,
    pub platform: KeyPlatform,
    pub now: SystemTime,
    pub home: &'a str,
    /// The branch monitor's notable branch for a working directory.
    pub branch: &'a dyn Fn(&str) -> Option<String>,
}

/// The active session's windows, each expanded one followed by its panes tab by tab.
pub fn window_list(ws: &Workspace, input: &ListInput<'_>, clock: &mut StatusClock) -> Vec<ListRow> {
    let shortcut_by_pane: std::collections::HashMap<String, String> =
        ws.pane_shortcut_assignments().into_iter().map(|s| (s.pane_id, s.key)).collect();
    let shows_hints = input.hints.shows_pane_hints();
    let mut rows: Vec<ListRow> = Vec::new();
    for (index, window) in ws.active_session_windows().into_iter().enumerate() {
        let active = window.id == ws.active_window_id();
        let expanded = shows_hints || !window.is_sidebar_collapsed;
        let pane_ids = window.pane_ids();
        let activity = ws.window_activity(&window.id);
        let attention_count = pane_ids
            .iter()
            .filter_map(|id| ws.pane(id))
            .map(|pane| {
                pane.tabs.iter().filter(|tab| tab.agent.as_ref().is_some_and(|a| a.needs_attention)).count()
            })
            .sum();
        rows.push(ListRow {
            gap: if rows.is_empty() { 0.0 } else { WINDOW_GAP },
            row: RowModel::Window(WindowRow {
                id: window.id.clone(),
                title: window.title.clone(),
                number: (index < 9).then_some(index + 1),
                pane_count: pane_ids.len(),
                attention_count,
                agent_badge: TabBadge::agents(&activity.agents),
                running_badge: TabBadge::running_commands(activity.running_commands),
                expanded,
                active,
                is_title_custom: window.is_title_custom,
                shows_number_hint: input.hints.shows_window_numbers() && index < 9,
            }),
        });
        if !expanded {
            continue;
        }
        let first_pane = rows.len();
        for layout_tab in window.tabs() {
            let ids = layout_tab.layout.as_ref().map(|layout| layout.ordered_leaf_ids()).unwrap_or_default();
            let mut first_in_tab = true;
            for pane in ids.iter().filter_map(|id| ws.pane(id)) {
                let after_pane = matches!(rows.last().map(|r| &r.row), Some(RowModel::Pane(_)));
                let gap = if first_in_tab && after_pane { TAB_GAP } else { ROW_GAP };
                first_in_tab = false;
                rows.push(ListRow {
                    gap,
                    row: RowModel::Pane(pane_row(ws, pane, active, &shortcut_by_pane, input, clock)),
                });
            }
        }
        let last = rows.len();
        if last > first_pane {
            if let RowModel::Pane(row) = &mut rows[first_pane].row {
                row.first_in_window = true;
            }
            if let RowModel::Pane(row) = &mut rows[last - 1].row {
                row.last_in_window = true;
            }
        }
    }
    rows
}

fn pane_row(
    ws: &Workspace,
    pane: &PaneState,
    in_active_window: bool,
    shortcut_by_pane: &std::collections::HashMap<String, String>,
    input: &ListInput<'_>,
    clock: &mut StatusClock,
) -> PaneRow {
    let tab = pane.active_tab();
    let title = sidebar_title(pane, input.home);
    let meta = context_line(pane, &title, input.branch, input.home);
    let agent = tab.and_then(|tab| tab.agent.as_ref());
    let (pill, since) = match agent {
        Some(agent) => {
            let (pill, since) = agent_pill(agent, clock, input.now);
            (pill, Some(since))
        }
        None => {
            let runs = pane.tabs.iter().any(|tab| ws.is_running_command(tab, &pane.id));
            (runs.then_some(StatusPillSpec::RUNNING), None)
        }
    };
    let hint_caps = shortcut_by_pane
        .get(&pane.id)
        .and_then(|key| pane_hint_caps(key, &input.hints.typed, input.platform));
    PaneRow {
        pane_id: pane.id.clone(),
        tab_id: tab.map(|tab| tab.id.clone()),
        kind: pane_kind(tab),
        title,
        meta,
        pill,
        since,
        recedes: agent.is_some_and(|a| agent_recedes(a.status)),
        shows_hint: input.hints.shows_pane_hints() && hint_caps.is_some(),
        hint_caps,
        focused: in_active_window && pane.id == ws.active_pane_id(),
        in_active_window,
        first_in_window: false,
        last_in_window: false,
    }
}

/// The list index of each window's header, for revealing it.
/// Whether an agent's row recedes (`SidebarView`: running, starting, idle and stopped agents
/// need nothing from you; waiting and failed ones stand out).
pub fn agent_recedes(status: AgentStatus) -> bool {
    matches!(status, AgentStatus::Running | AgentStatus::Starting | AgentStatus::Idle | AgentStatus::Stopped)
}

pub fn window_row_index(rows: &[ListRow], window_id: &str) -> Option<usize> {
    rows.iter().position(|row| matches!(&row.row, RowModel::Window(w) if w.id == window_id))
}

/// Whether Collapse All has anything to collapse.
pub fn can_collapse_all(ws: &Workspace) -> bool {
    ws.active_session_windows().iter().any(|window| !window.is_sidebar_collapsed)
}

/// Every working directory a tab on this computer runs in: the branch monitor watches their
/// HEADs (`watchedCwds`).
pub fn watched_cwds(ws: &Workspace) -> Vec<String> {
    let mut cwds: Vec<String> = ws
        .panes()
        .values()
        .flat_map(|pane| pane.tabs.iter().filter(|tab| tab.remote.is_none()))
        .filter_map(PaneTab::effective_working_directory)
        .collect();
    cwds.sort();
    cwds.dedup();
    cwds
}

/// Remembers which window the list last revealed, so it scrolls only when the active window
/// changes; refreshes and reselecting the same window leave a manual scroll alone.
#[derive(Debug, Default)]
pub struct RevealTracker {
    displayed: Option<String>,
}

impl RevealTracker {
    /// True when `active` differs from the window revealed last (which it becomes).
    pub fn needs_reveal(&mut self, active: &str) -> bool {
        if self.displayed.as_deref() == Some(active) {
            return false;
        }
        self.displayed = Some(active.to_owned());
        true
    }
}

/// One agent in the Agents list.
#[derive(Clone, Debug, PartialEq)]
pub struct AgentRow {
    pub pane_id: String,
    pub tab_id: String,
    pub kind: PaneKind,
    pub name: String,
    /// The folder it works in.
    pub detail: Option<String>,
    pub pill: Option<StatusPillSpec>,
    pub since: Option<SystemTime>,
    pub idle: bool,
    pub focused: bool,
    /// `session ▸ window ▸ title`.
    pub location: String,
}

#[derive(Clone)]
struct Entry(AgentDashboardEntry);

impl DashboardEntryStatus for Entry {
    fn status(&self) -> AgentStatus {
        self.0.status
    }

    fn needs_attention(&self) -> bool {
        self.0.needs_attention
    }
}

/// Every agent across the active session's windows, most urgent first, under Needs you /
/// Working / Ready / Stopped (the Agent Dashboard's grouping).
pub fn agent_groups(
    ws: &Workspace,
    clock: &mut StatusClock,
    now: SystemTime,
    home: &str,
) -> Vec<(AgentDashboardSection, Vec<AgentRow>)> {
    let session = ws.active_session_id();
    let entries: Vec<Entry> = ws
        .agent_dashboard_entries()
        .into_iter()
        .filter(|entry| ws.window_containing_pane(&entry.pane_id).is_some_and(|w| w.session_id == session))
        .map(Entry)
        .collect();
    let snapshot = AgentDashboardSnapshot::new(entries);
    let active_window = ws.active_window();
    AgentDashboardSection::group(&snapshot.entries)
        .into_iter()
        .map(|(section, entries)| {
            let rows = entries
                .into_iter()
                .map(|Entry(entry)| {
                    let tab = ws.tab(&entry.pane_id, &entry.tab_id);
                    let (pill, since) = match tab.and_then(|tab| tab.agent.as_ref()) {
                        Some(agent) => {
                            let (pill, since) = agent_pill(agent, clock, now);
                            (pill, Some(since))
                        }
                        None => (None, None),
                    };
                    let focused = active_window.is_some_and(|w| w.contains_pane(&entry.pane_id))
                        && ws.active_pane_id() == entry.pane_id
                        && ws
                            .pane(&entry.pane_id)
                            .and_then(PaneState::active_tab)
                            .is_some_and(|t| t.id == entry.tab_id);
                    AgentRow {
                        kind: pane_kind(tab),
                        name: entry.title(),
                        detail: entry.cwd.as_deref().map(|cwd| terminal_title::folder_name_in(cwd, home)),
                        pill,
                        since,
                        idle: matches!(entry.status, AgentStatus::Idle | AgentStatus::Stopped),
                        focused,
                        location: entry.location(),
                        pane_id: entry.pane_id,
                        tab_id: entry.tab_id,
                    }
                })
                .collect();
            (section, rows)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use soprano_model::WorkspaceSession;
    use soprano_platform::StateStore;
    use soprano_types::{SplitDirection, TerminalTarget};

    const HOME: &str = "/Users/me";

    fn no_branch(_: &str) -> Option<String> {
        None
    }

    fn rows_with(ws: &Workspace, hints: &Hints) -> Vec<ListRow> {
        let input = ListInput {
            hints,
            platform: KeyPlatform::Mac,
            now: SystemTime::now(),
            home: HOME,
            branch: &no_branch,
        };
        window_list(ws, &input, &mut StatusClock::default())
    }

    fn rows(ws: &Workspace) -> Vec<ListRow> {
        rows_with(ws, &Hints::default())
    }

    fn pane_rows(rows: &[ListRow]) -> Vec<&PaneRow> {
        rows.iter()
            .filter_map(|row| match &row.row {
                RowModel::Pane(pane) => Some(pane),
                RowModel::Window(_) => None,
            })
            .collect()
    }

    fn gap_before(rows: &[ListRow], pane_id: &str) -> f32 {
        rows.iter()
            .find(|row| matches!(&row.row, RowModel::Pane(p) if p.pane_id == pane_id))
            .expect("row")
            .gap
    }

    fn pill_labels(ws: &Workspace) -> Vec<&'static str> {
        pane_rows(&rows(ws)).iter().map(|row| row.pill.map_or("", |pill| pill.label)).collect()
    }

    // SidebarLayoutTabTests

    #[test]
    fn panes_sharing_a_tab_sit_closer_than_panes_in_separate_tabs() {
        let mut ws = Workspace::new();
        let first = ws.active_pane_id().to_owned();
        ws.create_layout_tab(None, None).expect("tab");
        let second = ws.active_pane_id().to_owned();
        let split = ws.split_pane(SplitDirection::Horizontal, &second).expect("split");
        let rows = rows(&ws);
        assert_eq!(gap_before(&rows, &split), ROW_GAP);
        assert_eq!(gap_before(&rows, &second), TAB_GAP);
        assert_eq!(gap_before(&rows, &first), ROW_GAP);
        assert!(pane_rows(&rows).iter().all(|row| !row.title.contains("Tab ")
            && row.meta.parts().iter().all(|part| !format!("{part:?}").contains("Tab "))));
    }

    #[test]
    fn a_new_window_starts_further_down_than_a_new_tab() {
        let mut ws = Workspace::new();
        let window = ws.create_window(None, None).expect("window");
        let rows = rows(&ws);
        let index = window_row_index(&rows, &window).expect("window row");
        assert_eq!(rows[index].gap, WINDOW_GAP);
        assert!(matches!(rows[index - 1].row, RowModel::Pane(_)));
        assert_eq!(rows[0].gap, 0.0);
        const { assert!(WINDOW_GAP > TAB_GAP) };
    }

    #[test]
    fn the_guide_runs_from_a_windows_first_pane_to_its_last() {
        let mut ws = Workspace::new();
        ws.create_layout_tab(None, None).expect("tab");
        let rows = rows(&ws);
        let panes = pane_rows(&rows);
        assert_eq!(panes.len(), 2);
        assert!(panes[0].first_in_window && !panes[0].last_in_window);
        assert!(!panes[1].first_in_window && panes[1].last_in_window);
    }

    #[test]
    fn only_the_focused_pane_of_the_active_window_is_marked() {
        let mut ws = Workspace::new();
        let first = ws.active_pane_id().to_owned();
        ws.create_window(None, None).expect("window");
        let second = ws.active_pane_id().to_owned();
        let rows = rows(&ws);
        let focused: Vec<&str> =
            pane_rows(&rows).iter().filter(|r| r.focused).map(|r| r.pane_id.as_str()).collect();
        assert_eq!(focused, [second.as_str()]);
        assert!(pane_rows(&rows).iter().any(|r| r.pane_id == first && !r.in_active_window));
    }

    // SidebarCollapseAllTests

    #[test]
    fn collapse_all_collapses_every_window_and_is_unavailable_until_one_expands_again() {
        let mut ws = Workspace::new();
        ws.create_window(None, None).expect("window");
        ws.create_window(None, None).expect("window");
        let ids: Vec<String> = ws.active_session_windows().iter().map(|w| w.id.clone()).collect();
        ws.toggle_sidebar_window_collapsed(&ids[0]);
        assert!(can_collapse_all(&ws));
        assert!(!pane_rows(&rows(&ws)).is_empty());

        ws.collapse_all_sidebar_windows();
        assert!(ids.iter().all(|id| ws.window(id).is_some_and(|w| w.is_sidebar_collapsed)));
        assert!(pane_rows(&rows(&ws)).is_empty());
        assert!(!can_collapse_all(&ws));

        ws.toggle_sidebar_window_collapsed(ids.last().expect("window"));
        assert!(can_collapse_all(&ws));
    }

    // SidebarCollapsePersistenceTests (view part)

    #[test]
    fn collapsed_windows_stay_collapsed_and_rowless_after_the_saved_workspace_is_restored() {
        let store = StateStore::in_memory();
        let mut source = Workspace::new();
        let window = source.active_window_id().to_owned();
        source.toggle_sidebar_window_collapsed(&window);
        assert!(pane_rows(&rows(&source)).is_empty());
        WorkspaceSession::save_last(&source.snapshot_workspace(), &store);

        let mut restored = Workspace::new();
        let _ = restored.restore_workspace(WorkspaceSession::load_last(&store).expect("saved"));
        assert!(restored.window(&window).is_some_and(|w| w.is_sidebar_collapsed));
        assert!(pane_rows(&rows(&restored)).is_empty());
        let header = window_row_index(&rows(&restored), &window).expect("header");
        assert!(matches!(&rows(&restored)[header].row, RowModel::Window(w) if !w.expanded));
    }

    #[test]
    fn holding_control_expands_collapsed_windows_to_show_their_hints() {
        let mut ws = Workspace::new();
        let window = ws.active_window_id().to_owned();
        ws.toggle_sidebar_window_collapsed(&window);
        let held = Hints { control_held: true, typed: String::new() };
        let rows = rows_with(&ws, &held);
        let panes = pane_rows(&rows);
        assert_eq!(panes.len(), 1);
        assert!(panes[0].shows_hint);
        assert_eq!(panes[0].hint_caps.as_deref(), Some(&["⌃⇧B".to_owned()][..]));
        assert!(matches!(&rows[0].row, RowModel::Window(w) if w.shows_number_hint && w.number == Some(1)));
    }

    // Pane hints (`paneHintCaps`)

    #[test]
    fn a_pane_hint_reads_the_chord_then_the_letters_left_after_what_was_typed() {
        assert_eq!(pane_hint_caps("b", "", KeyPlatform::Mac), Some(vec!["⌃⇧B".to_owned()]));
        assert_eq!(pane_hint_caps("zb", "", KeyPlatform::Mac), Some(vec!["⌃⇧Z".to_owned(), "B".to_owned()]));
        assert_eq!(pane_hint_caps("zb", "z", KeyPlatform::Mac), Some(vec!["B".to_owned()]));
        assert_eq!(pane_hint_caps("zb", "y", KeyPlatform::Mac), None);
        assert_eq!(pane_hint_caps("b", "b", KeyPlatform::Mac), None);
        assert_eq!(pane_hint_caps("b", "", KeyPlatform::Other), Some(vec!["Alt+Shift+B".to_owned()]));
        assert_eq!(pane_hint_tooltip(&["⌃⇧Z".to_owned(), "B".to_owned()]), "Ctrl+Shift+Z, then B");
        assert_eq!(window_number_cap(3, KeyPlatform::Mac), "⌃3");
        assert_eq!(window_number_cap(3, KeyPlatform::Other), "Ctrl+3");
    }

    #[test]
    fn a_started_hint_keeps_the_hints_up_and_hides_window_numbers() {
        let typed = Hints { control_held: false, typed: "z".into() };
        assert!(typed.shows_pane_hints());
        assert!(!typed.shows_window_numbers());
        let held = Hints { control_held: true, typed: String::new() };
        assert!(held.shows_pane_hints() && held.shows_window_numbers());
        assert!(!Hints::default().shows_pane_hints());
    }

    #[test]
    fn panes_whose_hint_does_not_go_on_from_the_typed_letters_show_their_status_instead() {
        let mut ws = Workspace::new();
        for _ in 0..21 {
            ws.spawn_terminal(Some("/tmp")).or_else(|| ws.create_window(Some("/tmp"), None));
        }
        let typed = Hints { control_held: false, typed: "z".into() };
        let rows = rows_with(&ws, &typed);
        let shown: Vec<_> = pane_rows(&rows).into_iter().filter(|row| row.shows_hint).collect();
        assert!(!shown.is_empty());
        assert!(shown.iter().all(|row| row.hint_caps.as_ref().is_some_and(|caps| caps.len() == 1)));
        assert!(pane_rows(&rows).iter().any(|row| !row.shows_hint));
    }

    // SidebarHoverTests / ChromeHoverTests: the row under the pointer swaps its status for the
    // close button; hints outrank both.

    #[test]
    fn only_a_hovered_row_shows_its_close_button_and_hints_outrank_it() {
        assert_eq!(trailing_slot(false, false), TrailingSlot::Status);
        assert_eq!(trailing_slot(false, true), TrailingSlot::Close);
        assert_eq!(trailing_slot(true, true), TrailingSlot::Hint);
        assert_eq!(trailing_slot(true, false), TrailingSlot::Hint);
    }

    // SidebarSelectionScrollTests (decision part)

    #[test]
    fn the_list_reveals_a_window_only_when_the_active_window_changes() {
        let mut tracker = RevealTracker::default();
        assert!(tracker.needs_reveal("window-1"));
        assert!(!tracker.needs_reveal("window-1"));
        assert!(tracker.needs_reveal("window-9"));
        assert!(tracker.needs_reveal("window-1"));
    }

    // RunningCommandIndicatorTests (sidebar part)

    #[test]
    fn a_running_command_lights_its_pane_row_until_an_agent_or_its_end_takes_over() {
        let mut ws = Workspace::new();
        let server_pane = ws.active_pane_id().to_owned();
        let server_tab = ws.pane(&server_pane).and_then(|p| p.active_tab()).expect("tab").id.clone();
        let server = TerminalTarget::new(&server_pane, &server_tab);
        ws.create_layout_tab(None, None).expect("tab");

        ws.set_running_command_targets([server.clone()].into_iter().collect());
        assert_eq!(pill_labels(&ws), ["Running", ""]);

        ws.attach_agent_if_needed(&server_pane, &server_tab, "codex");
        assert_eq!(pill_labels(&ws), ["Starting", ""]);

        ws.agent_process_did_exit(&server, None);
        assert_eq!(pill_labels(&ws), ["Running", ""]);

        ws.set_running_command_targets(Default::default());
        assert_eq!(pill_labels(&ws), ["", ""]);
    }

    // PerformanceOptimizationTests (sidebar part)

    #[test]
    fn tab_metadata_updates_refresh_the_pane_rows_title() {
        let mut ws = Workspace::new();
        let pane = ws.active_pane_id().to_owned();
        let tab = ws.pane(&pane).and_then(|p| p.active_tab()).expect("tab").id.clone();
        ws.rename_tab(&pane, &tab, "Live title");
        ws.update_working_directory(&pane, &tab, "/tmp/live-project");
        let rows = rows(&ws);
        assert_eq!(pane_rows(&rows)[0].pane_id, pane);
        assert_eq!(pane_rows(&rows)[0].title, "Live title");
    }

    #[test]
    fn agent_status_changes_reconfigure_their_rows() {
        let mut ws = Workspace::new();
        let first = ws.spawn_agent("codex", Some("/tmp/first"), false).expect("first");
        let second = ws.spawn_agent("claude-code", Some("/tmp/second"), false).expect("second");
        let second_tab = ws.pane(&second).and_then(|p| p.active_tab()).expect("tab").id.clone();
        ws.update_agent_status(&second, &second_tab, AgentStatus::Waiting, None, None);
        let rows = rows(&ws);
        let label = |id: &str| {
            pane_rows(&rows).into_iter().find(|r| r.pane_id == id).and_then(|r| r.pill).map(|p| p.label)
        };
        assert_eq!(label(&first), Some("Starting"));
        // A wait without a stated reason is a finished turn.
        assert_eq!(label(&second), Some("Done"));
    }

    // Titles and context lines

    #[test]
    fn an_agent_row_is_named_by_its_agent_with_its_folder_on_the_second_line() {
        let mut ws = Workspace::new();
        let pane = ws.spawn_agent("codex", Some("/tmp/shop"), false).expect("pane");
        let rows = rows(&ws);
        let row = pane_rows(&rows).into_iter().find(|r| r.pane_id == pane).expect("row");
        assert_eq!(row.kind, PaneKind::Agent("codex".into()));
        assert_eq!(row.title, "Codex");
        assert_eq!(row.meta, ContextLine::new(vec!["shop".into()], None, 1));
    }

    #[test]
    fn a_shell_in_its_default_branch_has_a_one_line_row_and_a_notable_branch_shows() {
        let mut ws = Workspace::new();
        let pane = ws.spawn_terminal(Some("/tmp/shop")).expect("pane");
        let feature = |_: &str| Some("feat/x".to_owned());
        let hints = Hints::default();
        let input = ListInput {
            hints: &hints,
            platform: KeyPlatform::Mac,
            now: SystemTime::now(),
            home: HOME,
            branch: &feature,
        };
        let rows = window_list(&ws, &input, &mut StatusClock::default());
        let row = pane_rows(&rows).into_iter().find(|r| r.pane_id == pane).expect("row").clone();
        assert_eq!(row.meta.branch.as_deref(), Some("feat/x"));
        assert!(rows_with(&ws, &hints).iter().all(|r| match &r.row {
            RowModel::Pane(p) => p.pane_id != pane || p.meta.is_empty(),
            RowModel::Window(_) => true,
        }));
    }

    #[test]
    fn window_counts_read_panes_and_ready_agents() {
        let mut row = WindowRow {
            id: "w".into(),
            title: "W".into(),
            number: Some(1),
            pane_count: 1,
            attention_count: 0,
            agent_badge: None,
            running_badge: None,
            expanded: true,
            active: true,
            is_title_custom: false,
            shows_number_hint: false,
        };
        assert_eq!(row.counts_tooltip(), "1 pane");
        row.pane_count = 3;
        row.attention_count = 2;
        assert_eq!(row.counts_tooltip(), "3 panes, 2 agents ready");
    }

    #[test]
    fn watched_directories_cover_every_tab_once() {
        let mut ws = Workspace::new();
        ws.spawn_terminal(Some("/tmp/a")).expect("pane");
        ws.spawn_terminal(Some("/tmp/a")).expect("pane");
        ws.spawn_terminal(Some("/tmp/b")).expect("pane");
        let cwds = watched_cwds(&ws);
        assert!(cwds.contains(&"/tmp/a".to_owned()) && cwds.contains(&"/tmp/b".to_owned()));
        assert_eq!(cwds.iter().filter(|c| *c == "/tmp/a").count(), 1);
    }

    #[test]
    fn only_agents_that_need_you_stand_out() {
        for status in [AgentStatus::Running, AgentStatus::Starting, AgentStatus::Idle, AgentStatus::Stopped] {
            assert!(agent_recedes(status), "{status:?}");
        }
        assert!(!agent_recedes(AgentStatus::Waiting));
        assert!(!agent_recedes(AgentStatus::Error));
    }

    // Agents section

    #[test]
    fn agents_group_by_what_they_need_and_stay_in_the_active_session() {
        let mut ws = Workspace::new();
        let working = ws.spawn_agent("codex", Some("/tmp/api"), false).expect("codex");
        let working_tab = ws.pane(&working).and_then(|p| p.active_tab()).expect("tab").id.clone();
        ws.update_agent_status(&working, &working_tab, AgentStatus::Running, None, None);
        let waiting = ws.spawn_agent("claude-code", Some("/tmp/shop"), false).expect("claude");
        let waiting_tab = ws.pane(&waiting).and_then(|p| p.active_tab()).expect("tab").id.clone();
        ws.update_agent_status(&waiting, &waiting_tab, AgentStatus::Waiting, Some(true), None);
        let groups = agent_groups(&ws, &mut StatusClock::default(), SystemTime::now(), HOME);
        let titles: Vec<&str> = groups.iter().map(|(section, _)| section.title()).collect();
        assert_eq!(titles, ["Needs you", "Working"]);
        assert_eq!(groups[0].1[0].pane_id, waiting);
        assert_eq!(groups[0].1[0].detail.as_deref(), Some("shop"));
        assert!(groups[0].1[0].focused);
        assert_eq!(groups[1].1[0].pill.map(|p| p.label), Some("Working"));

        ws.create_session("Other", None).expect("session");
        assert!(agent_groups(&ws, &mut StatusClock::default(), SystemTime::now(), HOME).is_empty());
    }
}
