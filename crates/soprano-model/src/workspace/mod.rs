//! The workspace model (`Controllers/AgentManager.swift` + `AgentManager+Dashboard.swift`):
//! sessions → logical windows → layout tabs → split panes → pane tabs, with focus, maximize,
//! agents, and save/restore.
//!
//! The Swift observer closures are replaced by two drained queues: mutations push
//! [`WorkspaceChange`]s (take them with [`Workspace::take_changes`]) and exact-target terminal
//! work pushes [`WorkspaceEvent`]s ([`Workspace::take_events`]). The synchronous close
//! confirmation is replaced by a two-phase API: closes return
//! [`CloseOutcome::NeedsConfirmation`] when the host's predicate asks for it, and
//! [`Workspace::force_close`] performs the close once the user agreed.

mod agents;
mod closing;
mod files;
mod panes;
mod persistence;
mod presentation;
mod sessions;

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;

use soprano_types::{AgentCatalog, TerminalTarget};

use crate::agent_instance::AgentInstance;
use crate::file_url;
use crate::pane::{PaneContentKind, PaneState, PaneTab, PaneType, Remote, chat_supports};
use crate::split_node::SplitNode;
use crate::window::{LayoutTab, TerminalSessionState, WorkspaceWindowState};

pub use closing::{CloseOutcome, CloseRequest};
pub use presentation::{ActiveLocation, ActivitySummary, AgentDashboardEntry, PaneShortcut};

/// A token for one Codex surface's readiness fallback. Monotonic values prevent an older
/// surface's fallback from completing a restarted or same-id replacement agent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentReadinessGeneration {
    pub target: TerminalTarget,
    value: u64,
}

/// Exact-target terminal work for the host's surface layer, separate from model updates.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TerminalLifecycleAction {
    Stop(TerminalTarget),
    Restart(TerminalTarget),
}

impl TerminalLifecycleAction {
    pub fn target(&self) -> &TerminalTarget {
        match self {
            Self::Stop(target) | Self::Restart(target) => target,
        }
    }
}

/// What changed, as Swift's `AgentManagerChange` plus the layout flag of `notifyChange`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WorkspaceChange {
    /// Anything in the model; views refresh what they show.
    Model,
    /// A model change that also changed which layout is on screen or its topology (a window,
    /// layout tab or pane appeared, went or came to the front; maximize toggled). Bumps
    /// [`Workspace::layout_generation`].
    Layout,
    TabTitle(TerminalTarget),
    TabWorkingDirectory(TerminalTarget),
    BrowserUrl(TerminalTarget),
    /// A Markdown reader, editor or diff tab now shows a different file (followed a link, or
    /// the file was renamed or moved).
    Document(TerminalTarget),
}

impl WorkspaceChange {
    pub fn layout_changed(&self) -> bool {
        matches!(self, Self::Layout)
    }
}

/// Work the model asks the host to do.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WorkspaceEvent {
    Terminal(TerminalLifecycleAction),
}

/// Asked before tabs close, with every tab about to go: `true` means the host must confirm
/// first (an editor with unsaved changes).
pub type CloseConfirmation = Box<dyn Fn(&[TerminalTarget]) -> bool + Send + Sync>;

/// Central model for pane/tab/agent lifecycle and tiling layout.
pub struct Workspace {
    panes: BTreeMap<String, PaneState>,
    windows: BTreeMap<String, WorkspaceWindowState>,
    terminal_sessions: BTreeMap<String, TerminalSessionState>,
    active_window_id: String,
    /// Pane rendered full-size instead of the split tree. Transient view state — never
    /// persisted in sessions.
    maximized_pane_id: Option<String>,
    /// Terminal tabs whose shell is running a command (a dev server, a build, an editor)
    /// instead of waiting at its prompt. Runtime state sampled from the surfaces by the host;
    /// never persisted.
    running_command_targets: HashSet<TerminalTarget>,
    next_id: u64,
    next_agent_readiness_generation: u64,
    active_agent_readiness_generations: HashMap<TerminalTarget, u64>,
    /// Advances whenever the layout topology changed (vs just focus/status).
    layout_generation: u64,
    /// Advances after a workspace has been successfully restored so views can discard cached
    /// terminal surfaces even when restored ids collide.
    workspace_restore_generation: u64,
    close_confirmation: Option<CloseConfirmation>,
    changes: Vec<WorkspaceChange>,
    events: Vec<WorkspaceEvent>,
}

impl Default for Workspace {
    fn default() -> Self {
        Self::new()
    }
}

impl Workspace {
    /// Bounds one tab's split layout. Other tabs and windows keep their own capacity, so a
    /// crowded layout cannot silently disable pane creation everywhere else.
    pub const MAX_PANES_PER_TAB: usize = 20;
    /// The session automation runs open in.
    pub const AUTOMATION_SESSION_NAME: &'static str = "Automations";
    /// Status label of a terminal running a command, beside the agents' own.
    pub const RUNNING_COMMAND_LABEL: &'static str = "RUNNING";

    /// One session holding one window with one terminal.
    pub fn new() -> Self {
        let window_id = "window-1";
        let pane_id = "pane-1";
        let tab = PaneTab::new("tab-2", PaneType::Terminal, "Terminal 1");
        let title = Self::suggested_window_title(Some(&tab));
        let mut panes = BTreeMap::new();
        panes.insert(pane_id.to_owned(), PaneState::new(pane_id, vec![tab]));
        let mut windows = BTreeMap::new();
        windows.insert(
            window_id.to_owned(),
            WorkspaceWindowState::new(
                window_id,
                TerminalSessionState::DEFAULT_ID,
                title,
                vec![LayoutTab {
                    id: "layout-1".into(),
                    layout: Some(SplitNode::leaf(pane_id)),
                    active_pane_id: pane_id.into(),
                }],
                0,
            ),
        );
        let mut terminal_sessions = BTreeMap::new();
        terminal_sessions.insert(
            TerminalSessionState::DEFAULT_ID.to_owned(),
            TerminalSessionState::new(TerminalSessionState::DEFAULT_ID, "Session 1", window_id),
        );
        Self {
            panes,
            windows,
            terminal_sessions,
            active_window_id: window_id.to_owned(),
            maximized_pane_id: None,
            running_command_targets: HashSet::new(),
            next_id: 2,
            next_agent_readiness_generation: 0,
            active_agent_readiness_generations: HashMap::new(),
            layout_generation: 0,
            workspace_restore_generation: 0,
            close_confirmation: None,
            changes: Vec::new(),
            events: Vec::new(),
        }
    }

    // MARK: - Change log

    /// Every change since the last call, oldest first.
    pub fn take_changes(&mut self) -> Vec<WorkspaceChange> {
        std::mem::take(&mut self.changes)
    }

    /// Every terminal lifecycle request since the last call, oldest first.
    pub fn take_events(&mut self) -> Vec<WorkspaceEvent> {
        std::mem::take(&mut self.events)
    }

    pub fn has_pending_changes(&self) -> bool {
        !self.changes.is_empty()
    }

    pub fn layout_generation(&self) -> u64 {
        self.layout_generation
    }

    pub fn workspace_restore_generation(&self) -> u64 {
        self.workspace_restore_generation
    }

    /// Sets the predicate consulted before tabs close (see [`CloseConfirmation`]).
    pub fn set_close_confirmation(&mut self, confirmation: Option<CloseConfirmation>) {
        self.close_confirmation = confirmation;
    }

    /// Redraws everything that renders an agent profile. Called after `settings.json` changes
    /// an agent's name, color, or icon: the panes themselves are untouched, but every view
    /// that resolves a profile from the catalog is now showing stale values.
    pub fn reload_agent_profiles(&mut self) {
        self.notify_model(false);
    }

    fn notify(&mut self, change: WorkspaceChange) {
        if change.layout_changed() {
            self.layout_generation += 1;
        }
        self.changes.push(change);
    }

    fn notify_model(&mut self, layout_changed: bool) {
        self.notify(if layout_changed { WorkspaceChange::Layout } else { WorkspaceChange::Model });
    }

    // MARK: - Reading the model

    pub fn panes(&self) -> &BTreeMap<String, PaneState> {
        &self.panes
    }

    pub fn pane(&self, pane_id: &str) -> Option<&PaneState> {
        self.panes.get(pane_id)
    }

    pub fn tab(&self, pane_id: &str, tab_id: &str) -> Option<&PaneTab> {
        self.panes.get(pane_id)?.tab(tab_id)
    }

    pub fn windows(&self) -> &BTreeMap<String, WorkspaceWindowState> {
        &self.windows
    }

    pub fn window(&self, window_id: &str) -> Option<&WorkspaceWindowState> {
        self.windows.get(window_id)
    }

    pub fn terminal_sessions(&self) -> &BTreeMap<String, TerminalSessionState> {
        &self.terminal_sessions
    }

    pub fn active_window_id(&self) -> &str {
        &self.active_window_id
    }

    pub fn active_window(&self) -> Option<&WorkspaceWindowState> {
        self.windows.get(&self.active_window_id)
    }

    pub fn active_session_id(&self) -> &str {
        self.active_window().map_or(TerminalSessionState::DEFAULT_ID, |window| window.session_id.as_str())
    }

    pub fn active_session(&self) -> Option<&TerminalSessionState> {
        self.terminal_sessions.get(self.active_session_id())
    }

    /// The focused pane of the active window's visible tab; empty when there is none.
    pub fn active_pane_id(&self) -> &str {
        self.active_window().map_or("", WorkspaceWindowState::active_pane_id)
    }

    /// The active window's visible layout: its active tab's.
    pub fn layout(&self) -> Option<&SplitNode> {
        self.active_window().and_then(WorkspaceWindowState::layout)
    }

    pub fn maximized_pane_id(&self) -> Option<&str> {
        self.maximized_pane_id.as_deref()
    }

    pub fn running_command_targets(&self) -> &HashSet<TerminalTarget> {
        &self.running_command_targets
    }

    pub fn pane_count(&self) -> usize {
        self.panes.len()
    }

    pub fn window_count(&self) -> usize {
        self.windows.len()
    }

    /// The active pane's active tab's directory.
    pub fn active_working_directory(&self) -> Option<String> {
        self.panes.get(self.active_pane_id())?.active_tab()?.cwd.clone()
    }

    /// The machine of `pane_id`/`tab_id`'s program; `None` on this computer.
    pub fn remote_of_tab(&self, pane_id: &str, tab_id: &str) -> Option<&Remote> {
        self.tab(pane_id, tab_id)?.remote.as_ref()
    }

    /// The machine `pane_id`'s visible tab runs on; `None` on this computer.
    pub fn machine_of_pane(&self, pane_id: &str) -> Option<&str> {
        Some(self.panes.get(pane_id)?.active_tab()?.remote.as_ref()?.machine.as_str())
    }

    /// Where a new terminal opens: `cwd` on this computer, else where the active tab is (its
    /// folder, and its machine).
    fn place(&self, cwd: Option<&str>) -> Place {
        if let Some(cwd) = cwd {
            return Place { cwd: Some(cwd.to_owned()), machine: None };
        }
        let tab = self.panes.get(self.active_pane_id()).and_then(PaneState::active_tab);
        Place {
            cwd: tab.and_then(|tab| tab.cwd.clone()),
            machine: tab.and_then(|tab| tab.remote.as_ref()).map(|remote| remote.machine.clone()),
        }
    }

    /// [`Self::place`] on this computer: a remote tab's folder is not one here.
    fn local_place(&self, cwd: Option<&str>) -> Place {
        let place = self.place(cwd);
        if place.machine.is_some() { Place::default() } else { place }
    }

    pub fn window_containing_pane(&self, pane_id: &str) -> Option<&WorkspaceWindowState> {
        self.windows.values().find(|window| window.contains_pane(pane_id))
    }

    pub fn window_containing_layout_tab(&self, layout_tab_id: &str) -> Option<&WorkspaceWindowState> {
        self.windows.values().find(|window| window.tab_index_of(layout_tab_id).is_some())
    }

    /// Every window of every session, in creation order.
    pub fn ordered_windows(&self) -> Vec<&WorkspaceWindowState> {
        self.sorted_windows()
    }

    /// Whether the window's visible tab has room for another pane.
    pub fn can_add_pane(&self, window_id: &str) -> bool {
        self.windows
            .get(window_id)
            .is_some_and(|window| window.layout().map_or(0, SplitNode::leaf_count) < Self::MAX_PANES_PER_TAB)
    }

    /// Direct access to a pane for tests. Records no change.
    #[cfg(test)]
    pub(crate) fn pane_mut(&mut self, pane_id: &str) -> Option<&mut PaneState> {
        self.panes.get_mut(pane_id)
    }

    fn window_id_containing_pane(&self, pane_id: &str) -> Option<String> {
        self.window_containing_pane(pane_id).map(|window| window.id.clone())
    }

    fn set_active_pane_id(&mut self, pane_id: &str) {
        if let Some(window) = self.windows.get_mut(&self.active_window_id) {
            window.set_active_pane_id(pane_id);
        }
    }

    // MARK: - Id generation

    fn next_numbered_id(&mut self, prefix: &str) -> String {
        self.next_id += 1;
        format!("{prefix}-{}", self.next_id)
    }

    fn next_pane_id(&mut self) -> String {
        self.next_numbered_id("pane")
    }

    fn next_tab_id(&mut self) -> String {
        self.next_numbered_id("tab")
    }

    fn next_window_id(&mut self) -> String {
        self.next_numbered_id("window")
    }

    fn next_layout_tab_id(&mut self) -> String {
        self.next_numbered_id("layout")
    }

    fn next_session_id(&mut self) -> String {
        self.next_numbered_id("session")
    }

    /// The number in an id such as `pane-12`. Parsed by hand rather than with a pattern:
    /// every view that lists windows sorts them with this on each model change.
    fn parse_id_number(id: &str) -> Option<u64> {
        let digits =
            ["session-", "window-", "pane-", "tab-"].iter().find_map(|prefix| id.strip_prefix(prefix))?;
        if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        digits.parse().ok()
    }

    fn sorted_windows(&self) -> Vec<&WorkspaceWindowState> {
        let mut windows: Vec<_> = self.windows.values().collect();
        windows.sort_by(|lhs, rhs| {
            let key = |window: &WorkspaceWindowState| Self::parse_id_number(&window.id).unwrap_or(u64::MAX);
            key(lhs).cmp(&key(rhs)).then_with(|| lhs.id.cmp(&rhs.id))
        });
        windows
    }

    // MARK: - Focus helpers

    /// Makes `window_id` the active window, remembering the session's previous one. Returns
    /// whether it changed.
    fn set_active_window(&mut self, window_id: &str) -> bool {
        let Some(session_id) = self.windows.get(window_id).map(|window| window.session_id.clone()) else {
            return false;
        };
        if self.active_window_id == window_id {
            return false;
        }
        let previous =
            self.terminal_sessions.get(&session_id).map(|session| session.active_window_id.clone());
        self.active_window_id = window_id.to_owned();
        if let Some(previous) = previous {
            if previous != window_id {
                let last = self
                    .windows
                    .get(&previous)
                    .is_some_and(|window| window.session_id == session_id)
                    .then_some(previous);
                if let Some(session) = self.terminal_sessions.get_mut(&session_id) {
                    session.last_active_window_id = last;
                }
            }
            if let Some(session) = self.terminal_sessions.get_mut(&session_id) {
                session.active_window_id = window_id.to_owned();
            }
        }
        true
    }

    /// Restores the full layout before a topology-affecting operation so nothing operates
    /// blind on hidden panes. Notifies immediately — callers notify again after their own
    /// mutation, which is harmless.
    fn exit_maximize(&mut self) {
        if self.maximized_pane_id.take().is_some() {
            self.notify_model(true);
        }
    }

    /// Clears the attention mark of `pane_id`'s active tab without notifying. Returns whether
    /// it was set.
    fn clear_attention_without_notification(&mut self, pane_id: &str) -> bool {
        let Some(agent) = self
            .panes
            .get_mut(pane_id)
            .and_then(PaneState::active_tab_mut)
            .and_then(|tab| tab.agent.as_mut())
        else {
            return false;
        };
        if !agent.needs_attention {
            return false;
        }
        agent.needs_attention = false;
        true
    }

    /// Brings `pane_id`'s window and layout tab to the front and focuses the pane there.
    /// Returns `(window_changed, layout_tab_changed)`.
    fn bring_pane_forward(&mut self, window_id: &str, pane_id: &str) -> (bool, bool) {
        let window_changed = self.active_window_id != window_id;
        self.set_active_window(window_id);
        let Some(window) = self.windows.get_mut(window_id) else { return (window_changed, false) };
        let layout_tab_changed = window.activate_tab_containing_pane(pane_id);
        window.set_active_pane_id(pane_id);
        (window_changed, layout_tab_changed)
    }

    // MARK: - Window titles

    fn unique_automatic_window_title(
        &self,
        base: &str,
        excluding: Option<&str>,
        session_id: Option<&str>,
    ) -> String {
        let owner = session_id
            .map(str::to_owned)
            .or_else(|| excluding.and_then(|id| self.windows.get(id)).map(|window| window.session_id.clone()))
            .unwrap_or_else(|| self.active_session_id().to_owned());
        let existing: Vec<&str> = self
            .windows
            .values()
            .filter(|window| Some(window.id.as_str()) != excluding && window.session_id == owner)
            .map(|window| window.title.as_str())
            .collect();
        Self::unique_title_among(base, &existing)
    }

    fn unique_title_among(base: &str, existing: &[&str]) -> String {
        let normalized: HashSet<String> = existing.iter().map(|title| title.to_lowercase()).collect();
        if !normalized.contains(&base.to_lowercase()) {
            return base.to_owned();
        }
        let mut suffix = 2;
        while normalized.contains(&format!("{base} ({suffix})").to_lowercase()) {
            suffix += 1;
        }
        format!("{base} ({suffix})")
    }

    /// The project folder the tab works in (the nearest enclosing git repository's name, else
    /// its own folder's), else the agent's name, else the kind of tab.
    fn suggested_window_title(tab: Option<&PaneTab>) -> String {
        let profile = tab
            .and_then(|tab| tab.agent.as_ref())
            .and_then(|agent| AgentCatalog::shared().profile(&agent.profile_id));
        let cwd = tab
            .and_then(|tab| tab.cwd.clone())
            .or_else(|| profile.as_ref().and_then(|profile| profile.cwd.clone()))
            .or_else(|| std::env::current_dir().ok().map(|dir| dir.to_string_lossy().into_owned()))
            .unwrap_or_default();
        if let Some(name) = Self::project_directory_name(&cwd) {
            return name;
        }
        if let Some(profile) = profile {
            return profile.name;
        }
        match tab.map(|tab| tab.pane_type) {
            Some(PaneType::Agent) => "Agent".into(),
            Some(PaneType::Browser) => "Browser".into(),
            Some(PaneType::Terminal) | None => "Terminal".into(),
        }
    }

    fn project_directory_name(path: &str) -> Option<String> {
        let original = file_url::standardized_path(&soprano_platform::paths::expand_tilde(path));
        let mut directory: &Path = &original;
        loop {
            if directory.join(".git").exists()
                && let Some(name) = directory.file_name()
            {
                return Some(name.to_string_lossy().into_owned());
            }
            match directory.parent() {
                Some(parent) if parent != directory => directory = parent,
                _ => break,
            }
        }
        original.file_name().map(|name| name.to_string_lossy().into_owned()).filter(|name| !name.is_empty())
    }

    /// `Window 3`: the placeholder titles of early builds.
    fn is_generated_window_title(title: &str) -> bool {
        title
            .strip_prefix("Window ")
            .is_some_and(|digits| !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit()))
    }

    fn agent_name(profile_id: &str) -> String {
        AgentCatalog::shared().profile(profile_id).map_or_else(|| "Agent".to_owned(), |profile| profile.name)
    }

    // MARK: - Tab construction

    fn create_pane_tab(id: String, spec: TabSpec) -> PaneTab {
        let dir_name = spec.cwd.as_deref().and_then(file_url::last_segment).map(str::to_owned);
        if spec.pane_type == PaneType::Agent
            && let Some(profile) =
                spec.profile_id.as_deref().and_then(|id| AgentCatalog::shared().profile(id))
        {
            let title = spec
                .title
                .or_else(|| dir_name.map(|dir| format!("{}: {dir}", profile.name)))
                .unwrap_or_else(|| profile.name.clone());
            // A chat for an agent that cannot serve one opens its terminal.
            let is_chat =
                spec.content_kind.as_deref() == Some(PaneContentKind::CHAT) && chat_supports(&profile.id);
            let mut tab = PaneTab::new(id.clone(), PaneType::Agent, title);
            tab.agent = Some(AgentInstance::new(id, profile.id));
            tab.cwd = spec.cwd;
            tab.content_kind = is_chat.then(|| PaneContentKind::CHAT.to_owned());
            tab.remote = spec.remote;
            return tab;
        }

        if spec.pane_type == PaneType::Browser {
            let mut tab = PaneTab::new(id, PaneType::Browser, spec.title.unwrap_or_else(|| "Browser".into()));
            tab.cwd = spec.cwd;
            tab.url = spec.url;
            tab.content_kind = spec.content_kind;
            tab.preview_owner_pane_id = spec.preview_owner_pane_id;
            return tab;
        }

        let title = spec.title.or(dir_name).unwrap_or_else(|| "Terminal".into());
        let mut tab = PaneTab::new(id, PaneType::Terminal, title);
        tab.cwd = spec.cwd;
        tab.remote = spec.remote;
        tab
    }

    /// Registers a new pane holding one terminal that starts at `place`, or a chat with
    /// `chat_profile_id`'s agent there.
    fn make_pane(&mut self, place: Place, chat_profile_id: Option<&str>) -> String {
        let tab_id = self.next_tab_id();
        let remote = place.machine.map(Remote::on);
        let tab = match chat_profile_id {
            Some(profile_id) => Self::create_pane_tab(
                tab_id,
                TabSpec {
                    pane_type: PaneType::Agent,
                    profile_id: Some(profile_id.to_owned()),
                    cwd: place.cwd,
                    content_kind: Some(PaneContentKind::CHAT.to_owned()),
                    remote,
                    ..TabSpec::default()
                },
            ),
            None => Self::create_pane_tab(tab_id, TabSpec { cwd: place.cwd, remote, ..TabSpec::default() }),
        };
        let pane_id = self.next_pane_id();
        self.panes.insert(pane_id.clone(), PaneState::new(pane_id.clone(), vec![tab]));
        pane_id
    }

    /// Adds `pane` beside the active pane of the active window.
    fn insert_pane(&mut self, pane: PaneState) -> bool {
        if !self.can_add_pane(&self.active_window_id) || !self.windows.contains_key(&self.active_window_id) {
            return false;
        }
        self.exit_maximize();
        let pane_id = pane.id.clone();
        self.panes.insert(pane_id.clone(), pane);

        let active_pane_id = self.active_pane_id().to_owned();
        let Some(window) = self.windows.get_mut(&self.active_window_id) else { return false };
        let updated = match window.layout() {
            None => SplitNode::leaf(&pane_id),
            Some(layout) => layout
                .inserting_split(&active_pane_id, &pane_id, soprano_types::SplitDirection::Horizontal)
                .unwrap_or_else(|| {
                    SplitNode::split(
                        soprano_types::SplitDirection::Horizontal,
                        layout.clone(),
                        SplitNode::leaf(&pane_id),
                        50.0,
                    )
                }),
        };
        window.set_layout(Some(updated));
        window.set_active_pane_id(&pane_id);
        self.notify_model(true);
        true
    }

    fn cancel_agent_readiness_generation(&mut self, target: &TerminalTarget) {
        self.active_agent_readiness_generations.remove(target);
    }

    fn cancel_agent_readiness_generations_in(&mut self, pane_id: &str) {
        self.active_agent_readiness_generations.retain(|target, _| target.pane_id != pane_id);
    }
}

/// Where a new terminal starts: a folder (`None`: the home folder), here or on a machine.
#[derive(Clone, Debug, Default)]
struct Place {
    cwd: Option<String>,
    machine: Option<String>,
}

/// What a new pane tab holds (Swift `createPaneTab`'s parameters).
struct TabSpec {
    pane_type: PaneType,
    profile_id: Option<String>,
    cwd: Option<String>,
    url: Option<String>,
    title: Option<String>,
    content_kind: Option<String>,
    preview_owner_pane_id: Option<String>,
    /// Terminal and agent tabs only.
    remote: Option<Remote>,
}

impl Default for TabSpec {
    fn default() -> Self {
        Self {
            pane_type: PaneType::Terminal,
            profile_id: None,
            cwd: None,
            url: None,
            title: None,
            content_kind: None,
            preview_owner_pane_id: None,
            remote: None,
        }
    }
}

#[cfg(test)]
mod tests;
