//! Live sessions and logical windows.

use std::path::Path;

use soprano_types::{AgentCatalog, AgentLaunch, AgentProfile, TerminalTarget};

use super::{Place, TabSpec, Workspace};
use crate::agent_instance::AgentInstance;
use crate::pane::{PaneState, PaneType};
use crate::split_node::SplitNode;
use crate::window::{LayoutTab, TerminalSessionState, WorkspaceWindowState};

impl Workspace {
    // MARK: - Live sessions

    /// Every session, in creation order.
    pub fn ordered_sessions(&self) -> Vec<&TerminalSessionState> {
        let mut sessions: Vec<_> = self.terminal_sessions.values().collect();
        sessions.sort_by(|lhs, rhs| {
            let key = |session: &TerminalSessionState| Self::parse_id_number(&session.id).unwrap_or(u64::MAX);
            key(lhs).cmp(&key(rhs)).then_with(|| lhs.id.cmp(&rhs.id))
        });
        sessions
    }

    /// The active session's windows, in creation order.
    pub fn active_session_windows(&self) -> Vec<&WorkspaceWindowState> {
        self.ordered_windows_in(self.active_session_id())
    }

    /// `session_id`'s windows, in creation order.
    pub fn ordered_windows_in(&self, session_id: &str) -> Vec<&WorkspaceWindowState> {
        self.sorted_windows().into_iter().filter(|window| window.session_id == session_id).collect()
    }

    fn ordered_window_ids_in(&self, session_id: &str) -> Vec<String> {
        self.ordered_windows_in(session_id).into_iter().map(|window| window.id.clone()).collect()
    }

    /// Opens a session named `name` (trimmed; blank names are refused) with one window in
    /// `cwd`, else the active terminal's directory when it is on this computer, and switches
    /// to it.
    pub fn create_session(&mut self, name: &str, cwd: Option<&str>) -> Option<String> {
        let trimmed = name.trim();
        if trimmed.is_empty() {
            return None;
        }
        let place = self.local_place(cwd);
        let session_id = self.next_session_id();
        self.terminal_sessions
            .insert(session_id.clone(), TerminalSessionState::new(&session_id, trimmed, ""));
        self.create_window_in(&session_id, place, None, true);
        Some(session_id)
    }

    pub fn activate_session(&mut self, session_id: &str) {
        let Some(window_id) =
            self.terminal_sessions.get(session_id).map(|session| session.active_window_id.clone())
        else {
            return;
        };
        self.activate_window(&window_id);
    }

    pub fn rename_session(&mut self, session_id: &str, name: &str) {
        let trimmed = name.trim();
        let Some(session) = self.terminal_sessions.get_mut(session_id) else { return };
        if trimmed.is_empty() {
            return;
        }
        session.name = trimmed.to_owned();
        self.notify_model(false);
    }

    // MARK: - Windows

    /// Opens a window in the active session holding one terminal, or a chat with
    /// `chat_profile_id`, in `cwd`, else where the active tab is.
    pub fn create_window(&mut self, cwd: Option<&str>, chat_profile_id: Option<&str>) -> Option<String> {
        let session_id = self.active_session_id().to_owned();
        let place = self.place(cwd);
        self.create_window_in(&session_id, place, chat_profile_id, true)
    }

    pub(super) fn create_window_in(
        &mut self,
        session_id: &str,
        place: Place,
        chat_profile_id: Option<&str>,
        activate: bool,
    ) -> Option<String> {
        if !self.terminal_sessions.contains_key(session_id) {
            return None;
        }
        let window_id = self.next_window_id();
        let pane_id = self.make_pane(place, chat_profile_id);
        let suggested =
            Self::suggested_window_title(self.panes.get(&pane_id).and_then(|pane| pane.active_tab()));
        let title = self.unique_automatic_window_title(&suggested, None, Some(session_id));
        let layout_tab_id = self.next_layout_tab_id();
        self.windows.insert(
            window_id.clone(),
            WorkspaceWindowState::new(
                &window_id,
                session_id,
                title,
                vec![LayoutTab {
                    id: layout_tab_id,
                    layout: Some(SplitNode::leaf(&pane_id)),
                    active_pane_id: pane_id,
                }],
                0,
            ),
        );
        if activate {
            self.set_active_window(&window_id);
            self.maximized_pane_id = None;
        } else if let Some(session) = self.terminal_sessions.get_mut(session_id) {
            session.active_window_id = window_id.clone();
        }
        self.notify_model(true);
        Some(window_id)
    }

    pub fn activate_window(&mut self, window_id: &str) {
        if !self.set_active_window(window_id) {
            return;
        }
        self.maximized_pane_id = None;
        self.notify_model(true);
    }

    /// Switches to the session's previously active window.
    pub fn activate_last_window(&mut self) {
        let Some(last) = self.active_session().and_then(|session| session.last_active_window_id.clone())
        else {
            return;
        };
        self.activate_window(&last);
    }

    pub fn activate_previous_window(&mut self) {
        self.activate_window_offset(-1);
    }

    pub fn activate_next_window(&mut self) {
        self.activate_window_offset(1);
    }

    /// Activates the session's `number`th window (1-based); out-of-range numbers do nothing.
    pub fn activate_window_number(&mut self, number: usize) {
        let windows = self.ordered_window_ids_in(self.active_session_id());
        if number >= 1 && number <= windows.len() {
            self.activate_window(&windows[number - 1]);
        }
    }

    fn activate_window_offset(&mut self, offset: isize) {
        let windows = self.ordered_window_ids_in(self.active_session_id());
        if windows.len() <= 1 {
            return;
        }
        let Some(current) = windows.iter().position(|id| *id == self.active_window_id) else { return };
        let next = (current as isize + offset).rem_euclid(windows.len() as isize) as usize;
        self.activate_window(&windows[next]);
    }

    pub fn toggle_sidebar_window_collapsed(&mut self, window_id: &str) {
        let Some(window) = self.windows.get_mut(window_id) else { return };
        window.is_sidebar_collapsed = !window.is_sidebar_collapsed;
        self.notify_model(false);
    }

    /// Collapses every window group the sidebar lists for the active session.
    pub fn collapse_all_sidebar_windows(&mut self) {
        let expanded: Vec<String> = self
            .active_session_windows()
            .into_iter()
            .filter(|window| !window.is_sidebar_collapsed)
            .map(|window| window.id.clone())
            .collect();
        if expanded.is_empty() {
            return;
        }
        for id in expanded {
            if let Some(window) = self.windows.get_mut(&id) {
                window.is_sidebar_collapsed = true;
            }
        }
        self.notify_model(false);
    }

    /// Gives a window a custom title (trimmed; blank or unchanged titles are ignored).
    pub fn rename_window(&mut self, window_id: &str, title: &str) {
        let trimmed = title.trim();
        let Some(window) = self.windows.get_mut(window_id) else { return };
        if trimmed.is_empty() || window.title == trimmed {
            return;
        }
        window.title = trimmed.to_owned();
        window.is_title_custom = true;
        self.notify_model(false);
    }

    /// Gives a window back its automatic title, named after its first pane's first tab.
    pub fn reset_window_title(&mut self, window_id: &str) {
        let Some(tab) = self
            .windows
            .get(window_id)
            .and_then(|window| window.tabs().first())
            .and_then(|tab| tab.layout.as_ref())
            .and_then(|layout| self.panes.get(layout.first_leaf()))
            .and_then(|pane| pane.tabs.first())
        else {
            return;
        };
        let suggested = Self::suggested_window_title(Some(tab));
        let title = self.unique_automatic_window_title(&suggested, Some(window_id), None);
        if let Some(window) = self.windows.get_mut(window_id) {
            window.title = title;
            window.is_title_custom = false;
        }
        self.notify_model(false);
    }

    // MARK: - Automation runs

    /// Opens an automation run's agent in a window of its own in the Automations session,
    /// creating the session when missing, without switching to it: the run works in the
    /// background and its window is there when someone opens it. `conversation` resumes a
    /// closed run instead of starting a new one; a resumed run is the person's agent again, so
    /// it has no `run_id` and its banners are ordinary ones.
    pub fn open_automation_window(
        &mut self,
        title: &str,
        profile_id: &str,
        cwd: &str,
        run_id: Option<String>,
        launch: soprano_types::AgentLaunch,
        conversation: Option<soprano_types::AgentConversation>,
    ) -> Option<super::TerminalTarget> {
        let profile = soprano_types::AgentCatalog::shared()
            .profile(profile_id)
            .filter(|profile| profile.id != "terminal")?;
        let session_id = match self
            .ordered_sessions()
            .into_iter()
            .find(|session| session.name == Self::AUTOMATION_SESSION_NAME)
            .map(|session| session.id.clone())
        {
            Some(id) => id,
            None => {
                let id = self.next_session_id();
                self.terminal_sessions
                    .insert(id.clone(), TerminalSessionState::new(&id, Self::AUTOMATION_SESSION_NAME, ""));
                id
            }
        };
        let pane_id = self.next_pane_id();
        let tab_id = self.next_tab_id();
        let mut agent = crate::AgentInstance::with_launch(&tab_id, &profile.id, Some(launch), run_id);
        agent.conversation = conversation;
        let mut tab = crate::PaneTab::new(&tab_id, crate::PaneType::Agent, title);
        tab.agent = Some(agent);
        tab.cwd = Some(cwd.to_owned());
        self.panes.insert(pane_id.clone(), crate::PaneState::new(&pane_id, vec![tab]));
        let window_id = self.next_window_id();
        let window_title = self.unique_automatic_window_title(title, None, Some(&session_id));
        let layout_tab_id = self.next_layout_tab_id();
        let mut window = WorkspaceWindowState::new(
            &window_id,
            &session_id,
            window_title,
            vec![LayoutTab {
                id: layout_tab_id,
                layout: Some(SplitNode::leaf(&pane_id)),
                active_pane_id: pane_id.clone(),
            }],
            0,
        );
        window.is_title_custom = true;
        self.windows.insert(window_id.clone(), window);
        let session_has_no_window = self
            .terminal_sessions
            .get(&session_id)
            .is_some_and(|session| !self.windows.contains_key(&session.active_window_id));
        if session_has_no_window && let Some(session) = self.terminal_sessions.get_mut(&session_id) {
            session.active_window_id = window_id;
        }
        self.notify_model(true);
        Some(super::TerminalTarget::new(pane_id, tab_id))
    }

    // MARK: - Threads

    /// Opens an agent, in its terminal, in `cwd` as a thread of its project (the Agents
    /// window's New Thread): a tab of its own at the end of the row of the window that already
    /// works on the project, else a new window named after it in the active session. `prompt`
    /// is the agent's first message. Nothing on screen changes: the tab waits behind the
    /// visible one, and the active window stays. `None`, with nothing opened, for an unknown
    /// profile, `terminal`, or an agent that cannot be handed the message ([`thread_launch`]).
    pub fn open_thread(
        &mut self,
        profile_id: &str,
        cwd: &str,
        prompt: Option<&str>,
    ) -> Option<TerminalTarget> {
        let profile =
            AgentCatalog::shared().profile(profile_id).filter(|profile| profile.id != "terminal")?;
        let launch = thread_launch(&profile, prompt).ok()?;
        let pane_id = self.next_pane_id();
        let tab_id = self.next_tab_id();
        let mut tab = Self::create_pane_tab(
            tab_id.clone(),
            TabSpec {
                pane_type: PaneType::Agent,
                profile_id: Some(profile.id.clone()),
                cwd: Some(cwd.to_owned()),
                ..TabSpec::default()
            },
        );
        if launch.is_some() {
            tab.agent = Some(AgentInstance::with_launch(&tab_id, &profile.id, launch, None));
        }
        let suggested = Self::suggested_window_title(Some(&tab));
        self.panes.insert(pane_id.clone(), PaneState::new(&pane_id, vec![tab]));
        let layout_tab = LayoutTab {
            id: self.next_layout_tab_id(),
            layout: Some(SplitNode::leaf(&pane_id)),
            active_pane_id: pane_id.clone(),
        };
        match self.window_working_on(&Self::project_root(cwd)) {
            Some(window_id) => self.windows.get_mut(&window_id)?.add_tab(layout_tab),
            None => {
                let session_id = self.active_session_id().to_owned();
                let window_id = self.next_window_id();
                let title = self.unique_automatic_window_title(&suggested, None, Some(&session_id));
                self.windows.insert(
                    window_id.clone(),
                    WorkspaceWindowState::new(&window_id, &session_id, title, vec![layout_tab], 0),
                );
            }
        }
        self.notify_model(true);
        Some(TerminalTarget::new(pane_id, tab_id))
    }

    /// The window a thread in `cwd` would join ([`Self::open_thread`]); `None` when it would
    /// open a window of its own. Walks the disk.
    pub fn window_for_thread(&self, cwd: &str) -> Option<&WorkspaceWindowState> {
        self.window_working_on(&Self::project_root(cwd)).and_then(|id| self.windows.get(&id))
    }

    /// The window a new thread of the project at `root` joins: one with a terminal or agent
    /// on this computer in that project — the active window first, then the active session's
    /// windows, then the others'. Automation runs keep their session to themselves.
    fn window_working_on(&self, root: &Path) -> Option<String> {
        let active_session = self.active_session_id();
        let automations = self
            .terminal_sessions
            .values()
            .find(|session| session.name == Self::AUTOMATION_SESSION_NAME)
            .map(|session| session.id.as_str());
        let works_there = |window: &WorkspaceWindowState| {
            self.ordered_panes(&window.id).into_iter().flat_map(|pane| pane.tabs.iter()).any(|tab| {
                tab.pane_type != PaneType::Browser
                    && tab.remote.is_none()
                    && tab.cwd.as_deref().is_some_and(|cwd| Self::project_root(cwd) == root)
            })
        };
        let mut windows = self.sorted_windows();
        windows.retain(|window| Some(window.session_id.as_str()) != automations);
        windows
            .sort_by_key(|window| (window.id != self.active_window_id, window.session_id != active_session));
        windows.into_iter().find(|window| works_there(window)).map(|window| window.id.clone())
    }

    // MARK: - Layout tabs

    /// Opens a tab at the end of the active window's row holding one fresh terminal, or a chat
    /// with `chat_profile_id`, started in `cwd`, else the active terminal's directory, and
    /// shows it.
    pub fn create_layout_tab(&mut self, cwd: Option<&str>, chat_profile_id: Option<&str>) -> Option<String> {
        if !self.windows.contains_key(&self.active_window_id) {
            return None;
        }
        let place = self.place(cwd);
        let pane_id = self.make_pane(place, chat_profile_id);
        let layout_tab_id = self.next_layout_tab_id();
        let window = self.windows.get_mut(&self.active_window_id)?;
        window.append_tab(LayoutTab {
            id: layout_tab_id.clone(),
            layout: Some(SplitNode::leaf(&pane_id)),
            active_pane_id: pane_id,
        });
        self.maximized_pane_id = None;
        self.notify_model(true);
        Some(layout_tab_id)
    }

    /// Shows `layout_tab_id`, switching to its window when another is active.
    pub fn activate_layout_tab(&mut self, layout_tab_id: &str) {
        let Some(window_id) =
            self.window_containing_layout_tab(layout_tab_id).map(|window| window.id.clone())
        else {
            return;
        };
        let window_changed = self.set_active_window(&window_id);
        let Some(window) = self.windows.get_mut(&window_id) else { return };
        let Some(index) = window.tab_index_of(layout_tab_id) else { return };
        let layout_tab_changed = window.activate_tab(index);
        if window_changed || layout_tab_changed {
            self.show_active_layout_tab(&window_id);
        }
    }

    pub fn activate_next_layout_tab(&mut self) {
        self.activate_layout_tab_offset(1);
    }

    pub fn activate_previous_layout_tab(&mut self) {
        self.activate_layout_tab_offset(-1);
    }

    /// Moves through the active window's tabs, wrapping at either end.
    fn activate_layout_tab_offset(&mut self, offset: isize) {
        let window_id = self.active_window_id.clone();
        let Some(window) = self.windows.get_mut(&window_id) else { return };
        if window.activate_tab_offset(offset) {
            self.show_active_layout_tab(&window_id);
        }
    }

    /// A maximized pane belongs to the tab that was on screen, and the revealed tab's focused
    /// pane counts as seen.
    fn show_active_layout_tab(&mut self, window_id: &str) {
        self.maximized_pane_id = None;
        if let Some(pane_id) = self.windows.get(window_id).map(|window| window.active_pane_id().to_owned()) {
            self.clear_attention_without_notification(&pane_id);
        }
        self.notify_model(true);
    }

    /// The title a layout tab shows: its focused pane's active tab's, else `Tab`.
    pub fn layout_tab_title(&self, tab: &LayoutTab) -> String {
        self.panes
            .get(&tab.active_pane_id)
            .and_then(|pane| pane.active_tab())
            .map_or_else(|| "Tab".to_owned(), |tab| tab.title.clone())
    }
}

/// How a thread's agent gets its first message: on its command line (`Ok(Some(_))`); a thread
/// without one starts bare (`Ok(None)`). `Err` when the agent cannot be handed one that way:
/// it would start without the message and nobody would know.
pub(super) fn thread_launch(profile: &AgentProfile, prompt: Option<&str>) -> Result<Option<AgentLaunch>, ()> {
    let Some(prompt) = prompt.map(str::trim).filter(|prompt| !prompt.is_empty()) else {
        return Ok(None);
    };
    if !profile.takes_launch_prompt() {
        return Err(());
    }
    Ok(Some(AgentLaunch { prompt: prompt.to_owned(), ..AgentLaunch::default() }))
}
