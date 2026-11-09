//! Workspace save/restore (`snapshotWorkspace`, `restoreWorkspace`).

use std::collections::{BTreeMap, HashMap, HashSet};

use soprano_types::AgentConversation;

use super::{CloseOutcome, CloseRequest, TabSpec, Workspace};
use crate::pane::{PaneState, PaneTab, PaneType};
use crate::session::{ReferenceDate, SavedLayoutTab, SavedPane, SavedTab, SavedWindow, WorkspaceSession};
use crate::split_node::SplitNode;
use crate::window::{LayoutTab, TerminalSessionState, WorkspaceWindowState};

impl Workspace {
    /// Every live session, window, layout tab, pane and tab, as the `last` snapshot.
    pub fn snapshot_workspace(&self) -> WorkspaceSession {
        let panes = self
            .panes
            .values()
            .map(|pane| SavedPane {
                id: pane.id.clone(),
                active_tab_index: pane.active_tab_index as i64,
                tabs: pane
                    .tabs
                    .iter()
                    .map(|tab| SavedTab {
                        id: tab.id.clone(),
                        pane_type: tab.pane_type,
                        profile_id: tab.agent.as_ref().map(|agent| agent.profile_id.clone()),
                        cwd: tab.cwd.clone(),
                        url: tab.url.clone(),
                        title: Some(tab.title.clone()),
                        content_kind: tab.content_kind.clone(),
                        preview_owner_pane_id: tab.preview_owner_pane_id.clone(),
                        conversation: tab.agent.as_ref().and_then(|agent| agent.conversation.clone()),
                    })
                    .collect(),
            })
            .collect();
        let windows = self
            .sorted_windows()
            .into_iter()
            .map(|window| SavedWindow {
                id: window.id.clone(),
                session_id: Some(window.session_id.clone()),
                title: window.title.clone(),
                is_title_custom: Some(window.is_title_custom),
                is_sidebar_collapsed: Some(window.is_sidebar_collapsed),
                layout: window.layout().cloned(),
                active_pane_id: window.active_pane_id().to_owned(),
                tabs: Some(
                    window
                        .tabs()
                        .iter()
                        .map(|tab| SavedLayoutTab {
                            layout: tab.layout.clone(),
                            active_pane_id: tab.active_pane_id.clone(),
                        })
                        .collect(),
                ),
                active_tab_index: Some(window.active_tab_index() as i64),
                depth_layers: None,
                active_depth_layer_index: None,
                active_depth: None,
            })
            .collect();

        WorkspaceSession {
            id: "last".into(),
            name: "Last Session".into(),
            saved_at: ReferenceDate::now(),
            layout: self.layout().cloned(),
            panes,
            active_pane_id: self.active_pane_id().to_owned(),
            windows: Some(windows),
            active_window_id: Some(self.active_window_id.clone()),
            terminal_sessions: Some(self.ordered_sessions().into_iter().cloned().collect()),
        }
    }

    /// Replaces the whole workspace with `session`. Asks first (see [`CloseOutcome`]):
    /// restoring replaces every open tab. `Closed` means it was restored; `Unchanged` that the
    /// snapshot held nothing restorable.
    pub fn restore_workspace(&mut self, session: WorkspaceSession) -> CloseOutcome {
        self.restore_workspace_with(session, false)
    }

    pub(super) fn restore_workspace_with(&mut self, session: WorkspaceSession, force: bool) -> CloseOutcome {
        if session.panes.is_empty() {
            return CloseOutcome::Unchanged;
        }
        let open_panes: Vec<String> = self.panes.keys().cloned().collect();
        if let Some(outcome) = self.confirmation_needed(self.targets_in_panes(&open_panes), force, || {
            CloseRequest::RestoreWorkspace(Box::new(session.clone()))
        }) {
            return outcome;
        }

        let mut max_id: u64 = 1;
        fn bump(max_id: &mut u64, id: &str) {
            if let Some(number) = Workspace::parse_id_number(id) {
                *max_id = (*max_id).max(number);
            }
        }

        let mut new_panes: BTreeMap<String, PaneState> = BTreeMap::new();
        for saved_pane in &session.panes {
            bump(&mut max_id, &saved_pane.id);
            let mut tabs: Vec<PaneTab> = Vec::with_capacity(saved_pane.tabs.len());
            for saved_tab in &saved_pane.tabs {
                bump(&mut max_id, &saved_tab.id);
                let conversation = saved_tab.conversation.clone().filter(|conversation| {
                    AgentConversation::valid_id(&conversation.id)
                        && AgentConversation::supports(saved_tab.profile_id.as_deref().unwrap_or(""))
                });
                let pane_type = if saved_tab.pane_type == PaneType::Terminal && conversation.is_some() {
                    PaneType::Agent
                } else {
                    saved_tab.pane_type
                };
                let mut tab = Self::create_pane_tab(
                    saved_tab.id.clone(),
                    TabSpec {
                        pane_type,
                        profile_id: saved_tab.profile_id.clone(),
                        cwd: saved_tab.cwd.clone(),
                        url: saved_tab.url.clone(),
                        title: saved_tab.title.clone(),
                        content_kind: saved_tab.content_kind.clone(),
                        preview_owner_pane_id: saved_tab.preview_owner_pane_id.clone(),
                    },
                );
                if let Some(agent) = tab.agent.as_mut() {
                    agent.conversation = conversation;
                }
                tabs.push(tab);
            }
            if tabs.is_empty() {
                tabs.push(PaneTab::new(format!("tab-{}", max_id + 1), PaneType::Terminal, "Terminal"));
                max_id += 1;
            }
            let active = saved_pane.active_tab_index.clamp(0, tabs.len() as i64 - 1) as usize;
            let mut pane = PaneState::new(&saved_pane.id, tabs);
            pane.active_tab_index = active;
            new_panes.insert(saved_pane.id.clone(), pane);
        }

        let mut saved_sessions: HashMap<String, TerminalSessionState> = HashMap::new();
        for saved_session in session.terminal_sessions.iter().flatten() {
            saved_sessions.insert(saved_session.id.clone(), saved_session.clone());
            max_id = max_id.max(Self::parse_id_number(&saved_session.id).unwrap_or(0));
        }

        let mut new_windows: BTreeMap<String, WorkspaceWindowState> = BTreeMap::new();
        match session.windows.as_ref().filter(|windows| !windows.is_empty()) {
            Some(saved_windows) => {
                for saved_window in saved_windows {
                    bump(&mut max_id, &saved_window.id);
                    let saved_active_index = saved_window.restorable_active_tab_index();
                    let mut restored_tabs: Vec<LayoutTab> = Vec::new();
                    let mut active_tab_index = 0;
                    for (index, saved_tab) in saved_window.restorable_tabs().into_iter().enumerate() {
                        let Some(layout) = saved_tab.layout else { continue };
                        let Some(first_pane_id) =
                            layout.ordered_leaf_ids().into_iter().find(|id| new_panes.contains_key(id))
                        else {
                            continue;
                        };
                        // When the saved active tab cannot be restored, the nearest one before
                        // it takes the front.
                        if index as i64 <= saved_active_index {
                            active_tab_index = restored_tabs.len();
                        }
                        max_id += 1;
                        let active_pane_id = if layout.contains_leaf(&saved_tab.active_pane_id) {
                            saved_tab.active_pane_id
                        } else {
                            first_pane_id
                        };
                        restored_tabs.push(LayoutTab {
                            id: format!("layout-{max_id}"),
                            layout: Some(layout),
                            active_pane_id,
                        });
                    }
                    let Some(first_pane_id) = restored_tabs
                        .first()
                        .and_then(|tab| tab.layout.as_ref())
                        .map(|layout| layout.first_leaf().to_owned())
                    else {
                        continue;
                    };
                    let session_id =
                        saved_window.session_id.as_ref().and_then(|id| saved_sessions.get(id)).map_or_else(
                            || TerminalSessionState::DEFAULT_ID.to_owned(),
                            |session| session.id.clone(),
                        );
                    let was_generated_placeholder = Self::is_generated_window_title(&saved_window.title);
                    let is_title_custom = saved_window.is_title_custom.unwrap_or(!was_generated_placeholder);
                    let title = if is_title_custom {
                        saved_window.title.clone()
                    } else {
                        let base = if was_generated_placeholder {
                            Self::suggested_window_title(
                                new_panes.get(&first_pane_id).and_then(|pane| pane.tabs.first()),
                            )
                        } else {
                            saved_window.title.clone()
                        };
                        let existing: Vec<&str> = new_windows
                            .values()
                            .filter(|window| window.session_id == session_id)
                            .map(|window| window.title.as_str())
                            .collect();
                        Self::unique_title_among(&base, &existing)
                    };
                    let mut window = WorkspaceWindowState::new(
                        &saved_window.id,
                        session_id,
                        title,
                        restored_tabs,
                        active_tab_index,
                    );
                    window.is_title_custom = is_title_custom;
                    window.is_sidebar_collapsed = saved_window.is_sidebar_collapsed.unwrap_or(false);
                    new_windows.insert(saved_window.id.clone(), window);
                }
            }
            None => {
                let window_id = "window-1";
                let first_saved_pane = session.panes[0].id.clone();
                let layout = session.layout.clone().unwrap_or_else(|| SplitNode::leaf(&first_saved_pane));
                let first_pane_id = layout
                    .ordered_leaf_ids()
                    .into_iter()
                    .find(|id| new_panes.contains_key(id))
                    .unwrap_or(first_saved_pane);
                let active_pane_id = if layout.contains_leaf(&session.active_pane_id) {
                    session.active_pane_id.clone()
                } else {
                    first_pane_id.clone()
                };
                let title = Self::suggested_window_title(
                    new_panes.get(&first_pane_id).and_then(|pane| pane.tabs.first()),
                );
                max_id += 1;
                new_windows.insert(
                    window_id.to_owned(),
                    WorkspaceWindowState::new(
                        window_id,
                        TerminalSessionState::DEFAULT_ID,
                        title,
                        vec![LayoutTab {
                            id: format!("layout-{max_id}"),
                            layout: Some(layout),
                            active_pane_id,
                        }],
                        0,
                    ),
                );
            }
        }

        if new_windows.is_empty() {
            return CloseOutcome::Unchanged;
        }

        self.active_agent_readiness_generations.clear();
        let referenced: HashSet<String> =
            new_windows.values().flat_map(WorkspaceWindowState::pane_ids).collect();
        new_panes.retain(|id, _| referenced.contains(id));
        self.panes = new_panes;
        self.windows = new_windows;
        // Older snapshots become one session. Repair missing or stale active window references
        // within each group without dropping their windows.
        let window_order: Vec<(String, String)> = self
            .sorted_windows()
            .into_iter()
            .map(|window| (window.id.clone(), window.session_id.clone()))
            .collect();
        self.terminal_sessions = BTreeMap::new();
        for (window_id, session_id) in &window_order {
            if self.terminal_sessions.contains_key(session_id) {
                continue;
            }
            let mut restored = saved_sessions
                .get(session_id)
                .cloned()
                .unwrap_or_else(|| TerminalSessionState::new(session_id, "Session 1", window_id));
            if self.windows.get(&restored.active_window_id).map(|window| &window.session_id)
                != Some(session_id)
            {
                restored.active_window_id = window_id.clone();
            }
            if let Some(last) = &restored.last_active_window_id
                && (self.windows.get(last).map(|window| &window.session_id) != Some(session_id)
                    || *last == restored.active_window_id)
            {
                restored.last_active_window_id = None;
            }
            self.terminal_sessions.insert(session_id.clone(), restored);
        }
        self.active_window_id = session
            .active_window_id
            .filter(|id| self.windows.contains_key(id))
            .or_else(|| window_order.first().map(|(id, _)| id.clone()))
            .unwrap_or_default();
        let active_session_id = self.active_session_id().to_owned();
        if let Some(active_session) = self.terminal_sessions.get_mut(&active_session_id) {
            active_session.active_window_id = self.active_window_id.clone();
        }
        self.next_id = max_id;

        self.maximized_pane_id = None;
        // Restored ids can repeat ones in use before; their commands are gone.
        self.running_command_targets.clear();
        self.workspace_restore_generation += 1;
        self.notify_model(true);
        CloseOutcome::Closed
    }
}
