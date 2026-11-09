//! Spawning, splitting, focusing, resizing and maximizing panes, and their tabs.

use std::path::Path;

use soprano_types::AgentCatalog;

use super::{TabSpec, TerminalTarget, Workspace, WorkspaceChange};
use crate::agent_instance::AgentInstance;
use crate::pane::{PaneContentKind, PaneState, PaneTab, PaneType};
use crate::split_node::{NavigationDirection, SplitBranchSide, SplitDirection, SplitNode};

impl Workspace {
    // MARK: - Pane spawning

    /// Opens a pane beside the active one with `profile_id`'s agent, as a chat when `chat` is
    /// set and the agent supports one. An unknown profile or `terminal` opens a shell. `None`
    /// when the visible tab is full; no id is used up then.
    pub fn spawn_agent(&mut self, profile_id: &str, cwd: Option<&str>, chat: bool) -> Option<String> {
        if !self.can_add_pane(&self.active_window_id) {
            return None;
        }
        let cwd = cwd.map(str::to_owned).or_else(|| self.active_working_directory());
        let pane_id = self.next_pane_id();
        let tab_id = self.next_tab_id();
        let tab = match AgentCatalog::shared().profile(profile_id).filter(|profile| profile.id != "terminal")
        {
            Some(profile) => Self::create_pane_tab(
                tab_id,
                TabSpec {
                    pane_type: PaneType::Agent,
                    profile_id: Some(profile.id),
                    cwd,
                    content_kind: chat.then(|| PaneContentKind::CHAT.to_owned()),
                    ..TabSpec::default()
                },
            ),
            None => Self::create_pane_tab(tab_id, TabSpec { cwd, ..TabSpec::default() }),
        };
        self.insert_pane(PaneState::new(&pane_id, vec![tab])).then_some(pane_id)
    }

    pub fn spawn_terminal(&mut self, cwd: Option<&str>) -> Option<String> {
        self.spawn_agent("terminal", cwd, false)
    }

    /// Opens a terminal running `<launcher> web` (omp's web UI) beside the active pane.
    pub fn spawn_omp_web(&mut self, launcher: &Path) -> Option<String> {
        if !self.can_add_pane(&self.active_window_id) {
            return None;
        }
        let pane_id = self.next_pane_id();
        let mut tab = PaneTab::new(self.next_tab_id(), PaneType::Terminal, "omp web");
        tab.cwd = self.active_working_directory();
        tab.startup_command = Some(vec![launcher.to_string_lossy().into_owned(), "web".into()]);
        self.insert_pane(PaneState::new(&pane_id, vec![tab])).then_some(pane_id)
    }

    pub fn spawn_browser(&mut self, url: Option<&str>) -> Option<String> {
        if !self.can_add_pane(&self.active_window_id) {
            return None;
        }
        let pane_id = self.next_pane_id();
        let mut tab = PaneTab::new(self.next_tab_id(), PaneType::Browser, "Browser");
        tab.url = url.map(str::to_owned);
        self.insert_pane(PaneState::new(&pane_id, vec![tab])).then_some(pane_id)
    }

    // MARK: - Pane splitting

    /// Splits `pane_id`, opening a copy of its active tab beside it: the same agent profile
    /// (as a fresh agent), page, or a shell in the same directory. A terminal's manually
    /// attached agent is not cloned. `None` when that layout tab is full.
    pub fn split_pane(&mut self, direction: SplitDirection, pane_id: &str) -> Option<String> {
        let source = self.panes.get(pane_id)?.active_tab()?.clone();
        let window_id = self.window_id_containing_pane(pane_id)?;
        let window = self.windows.get(&window_id)?;
        let layout_tab_index = window.tab_index_containing_pane(pane_id)?;
        if window.tabs()[layout_tab_index].layout.as_ref().map_or(0, SplitNode::leaf_count)
            >= Self::MAX_PANES_PER_TAB
        {
            return None;
        }
        self.set_active_window(&window_id);
        if let Some(window) = self.windows.get_mut(&window_id) {
            window.activate_tab(layout_tab_index);
            window.set_active_pane_id(pane_id);
        }
        self.exit_maximize();

        let new_pane_id = self.next_pane_id();
        let new_tab_id = self.next_tab_id();
        let mut new_tab = PaneTab::new(&new_tab_id, source.pane_type, &source.title);
        new_tab.cwd = source.cwd.clone();
        match (source.pane_type, &source.agent) {
            (PaneType::Agent, Some(agent)) => {
                new_tab.agent = Some(AgentInstance::new(&new_tab_id, &agent.profile_id));
                new_tab.content_kind = source.is_chat().then(|| PaneContentKind::CHAT.to_owned());
            }
            (PaneType::Browser, _) => {
                new_tab.url = source.url.clone();
                new_tab.content_kind = source.content_kind.clone();
            }
            _ => new_tab.pane_type = PaneType::Terminal,
        }
        self.panes.insert(new_pane_id.clone(), PaneState::new(&new_pane_id, vec![new_tab]));

        let inserted = self
            .windows
            .get_mut(&window_id)
            .is_some_and(|window| window.insert_split(pane_id, &new_pane_id, direction));
        if !inserted {
            self.panes.remove(&new_pane_id);
            return None;
        }
        self.set_active_pane_id(&new_pane_id);
        self.notify_model(true);
        Some(new_pane_id)
    }

    // MARK: - Navigation

    /// Focuses `pane_id`, bringing its window and layout tab to the front, and marks its
    /// active tab seen. Focusing the already focused pane only clears its attention mark.
    pub fn focus_pane(&mut self, pane_id: &str) {
        if !self.panes.contains_key(pane_id) {
            return;
        }
        let Some(window_id) = self.window_id_containing_pane(pane_id) else { return };
        let pane_is_visible =
            self.windows.get(&window_id).and_then(|w| w.layout()).is_some_and(|l| l.contains_leaf(pane_id));
        if self.active_window_id == window_id && pane_is_visible && self.active_pane_id() == pane_id {
            if self.clear_attention_without_notification(pane_id) {
                self.notify_model(false);
            }
            return;
        }
        self.exit_maximize();
        let (window_changed, layout_tab_changed) = self.bring_pane_forward(&window_id, pane_id);
        self.clear_attention_without_notification(pane_id);
        self.notify_model(window_changed || layout_tab_changed);
    }

    /// Focuses one pane tab. `reveal_in_sidebar` unfolds the window group the sidebar lists it
    /// under, for jumps from outside the sidebar such as the Agent Dashboard; clicks inside a
    /// pane leave the sidebar as it is.
    pub fn focus_tab(&mut self, pane_id: &str, tab_id: &str, reveal_in_sidebar: bool) {
        let Some(index) = self.panes.get(pane_id).and_then(|pane| pane.tab_index(tab_id)) else { return };
        let Some(window_id) = self.window_id_containing_pane(pane_id) else { return };

        let mut unfolded = false;
        if let Some(window) = self.windows.get_mut(&window_id)
            && reveal_in_sidebar
            && window.is_sidebar_collapsed
        {
            window.is_sidebar_collapsed = false;
            unfolded = true;
        }
        let is_already_focused = self.active_window_id == window_id
            && self.windows.get(&window_id).is_some_and(|window| {
                window.layout().is_some_and(|layout| layout.contains_leaf(pane_id))
                    && window.active_pane_id() == pane_id
            })
            && self.panes.get(pane_id).is_some_and(|pane| pane.active_tab_index == index);
        if is_already_focused {
            let cleared = self.clear_attention_without_notification(pane_id);
            if cleared || unfolded {
                self.notify_model(false);
            }
            return;
        }
        self.exit_maximize();
        let (window_changed, layout_tab_changed) = self.bring_pane_forward(&window_id, pane_id);
        if let Some(pane) = self.panes.get_mut(pane_id) {
            pane.active_tab_index = index;
        }
        self.clear_attention_without_notification(pane_id);
        self.notify_model(window_changed || layout_tab_changed);
    }

    /// Moves focus to the pane bordering the focused one in `direction`, wrapping to the far
    /// side of its row or column when there is none.
    pub fn navigate_to_pane(&mut self, direction: NavigationDirection) {
        let Some(layout) = self.layout().cloned() else { return };
        self.exit_maximize();
        let active = self.active_pane_id().to_owned();
        if let Some(target) =
            layout.adjacent_pane(&active, direction).or_else(|| layout.wrapping_pane(&active, direction))
        {
            self.set_active_pane_id(&target);
        }
        self.notify_model(false);
    }

    // MARK: - Resizing

    /// Sets the visible layout's split at `path` to `percentage` (clamped to 10…90).
    pub fn set_split_percentage(&mut self, path: &[SplitBranchSide], percentage: f64) {
        let changed = self
            .windows
            .get_mut(&self.active_window_id)
            .is_some_and(|window| window.set_split_percentage(path, percentage));
        if changed {
            self.notify_model(false);
        }
    }

    /// Grows or shrinks the focused pane by `tick_percent` along `direction`'s axis, using the
    /// nearest enclosing split on that axis.
    pub fn resize_pane(&mut self, direction: NavigationDirection, tick_percent: f64) {
        let Some(layout) = self.layout().cloned() else { return };
        let Some(path) = layout.path_to(self.active_pane_id()) else { return };
        self.exit_maximize();

        let axis =
            if direction.is_horizontal() { SplitDirection::Horizontal } else { SplitDirection::Vertical };
        let delta = if matches!(direction, NavigationDirection::Left | NavigationDirection::Up) {
            -tick_percent
        } else {
            tick_percent
        };

        // Walk up the path to find a split with the matching axis.
        for depth in (0..path.len()).rev() {
            let ancestor = &path[..depth];
            let matches_axis = matches!(layout.node_at(ancestor), Some(SplitNode::Split(branch)) if branch.direction == axis);
            if !matches_axis {
                continue;
            }
            let adjusted = self
                .windows
                .get_mut(&self.active_window_id)
                .is_some_and(|window| window.adjust_split(ancestor, delta));
            if adjusted {
                self.notify_model(false);
            }
            return;
        }
    }

    // MARK: - Layout

    /// Replaces the visible layout, keeping focus on a pane that is in it.
    pub fn set_layout(&mut self, layout: Option<SplitNode>) {
        self.exit_maximize();
        let active = self.active_pane_id().to_owned();
        let new_active = layout
            .as_ref()
            .filter(|layout| layout.path_to(&active).is_none())
            .map(|layout| layout.first_leaf().to_owned());
        if let Some(window) = self.windows.get_mut(&self.active_window_id) {
            window.set_layout(layout);
            if let Some(pane_id) = new_active {
                window.set_active_pane_id(pane_id);
            }
        }
        self.notify_model(true);
    }

    // MARK: - Maximize

    /// Shows the focused pane full-size instead of the split tree, or ends that.
    pub fn toggle_maximize(&mut self) {
        if self.maximized_pane_id.take().is_some() {
            self.notify_model(true);
            return;
        }
        if self.layout().map_or(0, SplitNode::leaf_count) <= 1
            || !self.panes.contains_key(self.active_pane_id())
        {
            return;
        }
        self.maximized_pane_id = Some(self.active_pane_id().to_owned());
        self.notify_model(true);
    }

    // MARK: - Pane tabs

    /// Adds a tab to `pane_id` (at most [`PaneState::MAX_TABS_PER_PANE`]) in the directory of
    /// its active tab, and shows it.
    pub fn add_tab_to_pane(
        &mut self,
        pane_id: &str,
        pane_type: PaneType,
        profile_id: Option<&str>,
        content_kind: Option<&str>,
    ) -> Option<String> {
        let pane = self.panes.get(pane_id)?;
        let window_id = self.window_id_containing_pane(pane_id)?;
        if pane.tabs.len() >= PaneState::MAX_TABS_PER_PANE {
            return None;
        }
        let cwd = pane.active_tab().and_then(|tab| tab.cwd.clone());
        let tab_id = self.next_tab_id();
        let tab = Self::create_pane_tab(
            tab_id.clone(),
            TabSpec {
                pane_type,
                profile_id: profile_id.map(str::to_owned),
                cwd,
                content_kind: content_kind.map(str::to_owned),
                ..TabSpec::default()
            },
        );
        let pane = self.panes.get_mut(pane_id)?;
        pane.tabs.push(tab);
        pane.active_tab_index = pane.tabs.len() - 1;
        let (window_changed, layout_tab_changed) = self.bring_pane_forward(&window_id, pane_id);
        self.notify_model(window_changed || layout_tab_changed);
        Some(tab_id)
    }

    /// Shows the pane's tab at `index` (clamped) and focuses the pane.
    pub fn switch_tab(&mut self, pane_id: &str, index: usize) {
        self.select_pane_tab(pane_id, |pane| index.min(pane.tabs.len() - 1));
    }

    /// Shows the pane's next tab, wrapping after the last.
    pub fn next_tab(&mut self, pane_id: &str) {
        self.select_pane_tab(pane_id, |pane| (pane.clamped_active_index() + 1) % pane.tabs.len());
    }

    /// Shows the pane's previous tab, wrapping before the first.
    pub fn prev_tab(&mut self, pane_id: &str) {
        self.select_pane_tab(pane_id, |pane| {
            (pane.clamped_active_index() + pane.tabs.len() - 1) % pane.tabs.len()
        });
    }

    fn select_pane_tab(&mut self, pane_id: &str, index: impl FnOnce(&PaneState) -> usize) {
        let Some(window_id) = self.window_id_containing_pane(pane_id) else { return };
        let Some(pane) = self.panes.get_mut(pane_id) else { return };
        if pane.tabs.is_empty() {
            return;
        }
        pane.active_tab_index = index(pane);
        let (window_changed, layout_tab_changed) = self.bring_pane_forward(&window_id, pane_id);
        self.clear_attention_without_notification(pane_id);
        self.notify_model(window_changed || layout_tab_changed);
    }

    /// Renames a pane tab. Line breaks become spaces; blank or unchanged titles are ignored.
    pub fn rename_tab(&mut self, pane_id: &str, tab_id: &str, title: &str) {
        let sanitized: String = title
            .chars()
            .map(|c| {
                if matches!(c, '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}') {
                    ' '
                } else {
                    c
                }
            })
            .collect();
        let sanitized = sanitized.trim();
        let Some(tab) = self.tab_mut(pane_id, tab_id) else { return };
        if sanitized.is_empty() || tab.title == sanitized {
            return;
        }
        tab.title = sanitized.to_owned();
        self.notify(WorkspaceChange::TabTitle(TerminalTarget::new(pane_id, tab_id)));
    }

    /// Records the directory the tab's shell reports.
    pub fn update_working_directory(&mut self, pane_id: &str, tab_id: &str, working_directory: &str) {
        if working_directory.is_empty() {
            return;
        }
        let Some(tab) = self.tab_mut(pane_id, tab_id) else { return };
        if tab.cwd.as_deref() == Some(working_directory) {
            return;
        }
        tab.cwd = Some(working_directory.to_owned());
        self.notify(WorkspaceChange::TabWorkingDirectory(TerminalTarget::new(pane_id, tab_id)));
    }

    /// Records a browser tab's committed location.
    pub fn update_browser_url(&mut self, pane_id: &str, tab_id: &str, url: &str) {
        if url.is_empty() {
            return;
        }
        let Some(tab) = self.tab_mut(pane_id, tab_id) else { return };
        if tab.pane_type != PaneType::Browser || tab.url.as_deref() == Some(url) {
            return;
        }
        tab.url = Some(url.to_owned());
        self.notify(WorkspaceChange::BrowserUrl(TerminalTarget::new(pane_id, tab_id)));
    }

    pub(super) fn tab_mut(&mut self, pane_id: &str, tab_id: &str) -> Option<&mut PaneTab> {
        self.panes.get_mut(pane_id)?.tabs.iter_mut().find(|tab| tab.id == tab_id)
    }
}
