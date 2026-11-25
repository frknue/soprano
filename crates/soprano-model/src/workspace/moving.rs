//! Moving panes and layout tabs: beside another pane, into another layout tab, to another
//! window or into one of their own. Panes and their tabs keep their ids, so their terminals,
//! agents and documents carry on undisturbed; only the layouts change. Everything stays inside
//! one session, and a window or layout tab left without panes goes away.

use super::Workspace;
use crate::split_node::{PaneEdge, SplitNode};
use crate::window::{LayoutTab, WorkspaceWindowState};

impl Workspace {
    /// Whether [`Self::move_pane_beside`] would move anything: another pane of the same
    /// session, in a layout tab with room for it (or already in that tab).
    pub fn can_move_pane_beside(&self, pane_id: &str, target_pane_id: &str) -> bool {
        if pane_id == target_pane_id || !self.panes.contains_key(pane_id) {
            return false;
        }
        let (Some(source), Some(target)) =
            (self.window_id_containing_pane(pane_id), self.window_id_containing_pane(target_pane_id))
        else {
            return false;
        };
        let same_layout_tab = source == target && {
            let window = &self.windows[&source];
            window.tab_index_containing_pane(pane_id) == window.tab_index_containing_pane(target_pane_id)
        };
        self.same_session(&source, &target)
            && (same_layout_tab
                || self.layout_tab_leaf_count(&target, target_pane_id) < Self::MAX_PANES_PER_TAB)
    }

    /// Moves `pane_id` beside `target_pane_id` on `edge`, from wherever it is in the
    /// session, and focuses it there. False when nothing moved
    /// ([`Self::can_move_pane_beside`]).
    pub fn move_pane_beside(&mut self, pane_id: &str, target_pane_id: &str, edge: PaneEdge) -> bool {
        if !self.can_move_pane_beside(pane_id, target_pane_id) {
            return false;
        }
        let (Some(source), Some(target)) =
            (self.window_id_containing_pane(pane_id), self.window_id_containing_pane(target_pane_id))
        else {
            return false;
        };
        self.exit_maximize();
        self.detach_pane(&source, pane_id);
        let placed = self.windows.get_mut(&target).is_some_and(|window| {
            window.insert_beside(target_pane_id, &SplitNode::leaf(pane_id), edge, pane_id)
        });
        debug_assert!(placed, "the target pane is still in its window");
        self.finish_move(&source, &target, pane_id);
        true
    }

    /// Whether [`Self::move_pane_to_layout_tab`] would move anything.
    pub fn can_move_pane_to_layout_tab(&self, pane_id: &str, layout_tab_id: &str) -> bool {
        self.pane_to_join_in(pane_id, layout_tab_id)
            .is_some_and(|target_pane| self.can_move_pane_beside(pane_id, &target_pane))
    }

    /// Moves `pane_id` into `layout_tab_id`, right of the pane focused there.
    pub fn move_pane_to_layout_tab(&mut self, pane_id: &str, layout_tab_id: &str) -> bool {
        let Some(target_pane) = self.pane_to_join_in(pane_id, layout_tab_id) else { return false };
        self.move_pane_beside(pane_id, &target_pane, PaneEdge::Right)
    }

    /// The pane `pane_id` lands beside in `layout_tab_id`: the one focused there, unless the
    /// pane already is in that tab.
    fn pane_to_join_in(&self, pane_id: &str, layout_tab_id: &str) -> Option<String> {
        self.window_containing_layout_tab(layout_tab_id)
            .and_then(|window| window.tab_index_of(layout_tab_id).map(|index| &window.tabs()[index]))
            .filter(|tab| !tab.layout.as_ref().is_some_and(|layout| layout.contains_leaf(pane_id)))
            .map(|tab| tab.active_pane_id.clone())
    }

    /// Gives `pane_id` a layout tab of its own at the end of `window_id`'s row (its own
    /// window when `None`) and shows it there. `None` when nothing moved: the pane already is
    /// a tab of its own in that window, or the window is in another session.
    pub fn move_pane_to_new_layout_tab(&mut self, pane_id: &str, window_id: Option<&str>) -> Option<String> {
        let source = self.window_id_containing_pane(pane_id)?;
        let target = window_id.map_or_else(|| source.clone(), str::to_owned);
        if !self.windows.contains_key(&target)
            || !self.same_session(&source, &target)
            || (source == target && self.layout_tab_leaf_count(&source, pane_id) == 1)
        {
            return None;
        }
        self.exit_maximize();
        self.detach_pane(&source, pane_id);
        let layout_tab_id = self.next_layout_tab_id();
        let tab = LayoutTab {
            id: layout_tab_id.clone(),
            layout: Some(SplitNode::leaf(pane_id)),
            active_pane_id: pane_id.to_owned(),
        };
        if let Some(window) = self.windows.get_mut(&target) {
            window.append_tab(tab);
        }
        self.finish_move(&source, &target, pane_id);
        Some(layout_tab_id)
    }

    /// Opens a window holding only `pane_id`, named after it, and shows it. `None` when the
    /// pane is all its window holds.
    pub fn move_pane_to_new_window(&mut self, pane_id: &str) -> Option<String> {
        let source = self.window_id_containing_pane(pane_id)?;
        if self.windows[&source].pane_ids().len() == 1 {
            return None;
        }
        self.exit_maximize();
        self.detach_pane(&source, pane_id);
        let layout_tab_id = self.next_layout_tab_id();
        let tab = LayoutTab {
            id: layout_tab_id,
            layout: Some(SplitNode::leaf(pane_id)),
            active_pane_id: pane_id.to_owned(),
        };
        let target = self.insert_window_beside(&source, tab);
        self.finish_move(&source, &target, pane_id);
        Some(target)
    }

    /// Moves `layout_tab_id` to `index` in `window_id`'s row (its end when `None`) and shows
    /// it: a reorder within its own window, else a move to another window of its session. A
    /// window left without tabs closes. False when nothing moved.
    pub fn move_layout_tab(&mut self, layout_tab_id: &str, window_id: &str, index: Option<usize>) -> bool {
        let Some(source) = self.window_containing_layout_tab(layout_tab_id).map(|window| window.id.clone())
        else {
            return false;
        };
        if !self.windows.contains_key(window_id) || !self.same_session(&source, window_id) {
            return false;
        }
        self.exit_maximize();
        if source == window_id {
            let Some(window) = self.windows.get_mut(&source) else { return false };
            let Some(from) = window.tab_index_of(layout_tab_id) else { return false };
            let to = index.unwrap_or(usize::MAX);
            let reordered = window.move_tab(from, to);
            self.set_active_window(&source);
            self.notify_model(true);
            return reordered;
        }
        let Some(tab) = self.take_layout_tab(&source, layout_tab_id) else { return false };
        if let Some(window) = self.windows.get_mut(window_id) {
            window.insert_tab(index.unwrap_or(usize::MAX), tab);
        }
        self.set_active_window(window_id);
        self.retire_if_empty(&source);
        self.notify_model(true);
        true
    }

    /// Opens a window holding only `layout_tab_id`, named after its focused pane, and shows
    /// it. `None` when the tab is its window's only one.
    pub fn move_layout_tab_to_new_window(&mut self, layout_tab_id: &str) -> Option<String> {
        let source = self.window_containing_layout_tab(layout_tab_id)?;
        if source.tabs().len() <= 1 {
            return None;
        }
        let source = source.id.clone();
        self.exit_maximize();
        let tab = self.take_layout_tab(&source, layout_tab_id)?;
        let target = self.insert_window_beside(&source, tab);
        self.set_active_window(&target);
        self.notify_model(true);
        Some(target)
    }

    /// Whether [`Self::merge_layout_tab`] would move anything: a target pane in another layout
    /// tab of the same session, with room there for every pane of `layout_tab_id`.
    pub fn can_merge_layout_tab(&self, layout_tab_id: &str, target_pane_id: &str) -> bool {
        let Some(source_window) = self.window_containing_layout_tab(layout_tab_id) else { return false };
        let Some(layout) = source_window
            .tab_index_of(layout_tab_id)
            .and_then(|index| source_window.tabs()[index].layout.as_ref())
        else {
            return false;
        };
        let Some(target) = self.window_id_containing_pane(target_pane_id) else { return false };
        !layout.contains_leaf(target_pane_id)
            && self.same_session(&source_window.id, &target)
            && self.layout_tab_leaf_count(&target, target_pane_id) + layout.leaf_count()
                <= Self::MAX_PANES_PER_TAB
    }

    /// Puts every pane of `layout_tab_id` beside `target_pane_id` on `edge`, its split layout
    /// intact, and shows the result. The emptied tab closes, and its window with it when it
    /// was the last. False when nothing moved ([`Self::can_merge_layout_tab`]).
    pub fn merge_layout_tab(&mut self, layout_tab_id: &str, target_pane_id: &str, edge: PaneEdge) -> bool {
        if !self.can_merge_layout_tab(layout_tab_id, target_pane_id) {
            return false;
        }
        let Some(source_window) = self.window_containing_layout_tab(layout_tab_id) else { return false };
        let Some(source_tab) =
            source_window.tab_index_of(layout_tab_id).map(|index| &source_window.tabs()[index])
        else {
            return false;
        };
        let Some(layout) = source_tab.layout.clone() else { return false };
        let focus = source_tab.active_pane_id.clone();
        let source = source_window.id.clone();
        let Some(target) = self.window_id_containing_pane(target_pane_id) else { return false };
        self.exit_maximize();
        self.take_layout_tab(&source, layout_tab_id);
        let placed = self
            .windows
            .get_mut(&target)
            .is_some_and(|window| window.insert_beside(target_pane_id, &layout, edge, &focus));
        debug_assert!(placed, "the target pane is still in its window");
        self.finish_move(&source, &target, &focus);
        true
    }

    /// Whether [`Self::merge_layout_tab_into`] would move anything.
    pub fn can_merge_layout_tab_into(&self, layout_tab_id: &str, into_layout_tab_id: &str) -> bool {
        self.focused_pane_of(into_layout_tab_id)
            .is_some_and(|target_pane| self.can_merge_layout_tab(layout_tab_id, &target_pane))
    }

    /// [`Self::merge_layout_tab`] beside the pane focused in `into_layout_tab_id`, on its right.
    pub fn merge_layout_tab_into(&mut self, layout_tab_id: &str, into_layout_tab_id: &str) -> bool {
        let Some(target_pane) = self.focused_pane_of(into_layout_tab_id) else { return false };
        self.merge_layout_tab(layout_tab_id, &target_pane, PaneEdge::Right)
    }

    fn focused_pane_of(&self, layout_tab_id: &str) -> Option<String> {
        self.window_containing_layout_tab(layout_tab_id)
            .and_then(|window| window.tab_index_of(layout_tab_id).map(|index| &window.tabs()[index]))
            .map(|tab| tab.active_pane_id.clone())
    }

    // MARK: - Helpers

    fn same_session(&self, window_id: &str, other_window_id: &str) -> bool {
        match (self.windows.get(window_id), self.windows.get(other_window_id)) {
            (Some(window), Some(other)) => window.session_id == other.session_id,
            _ => false,
        }
    }

    /// How many panes share `pane_id`'s layout tab in `window_id`.
    fn layout_tab_leaf_count(&self, window_id: &str, pane_id: &str) -> usize {
        self.windows
            .get(window_id)
            .and_then(|window| {
                let index = window.tab_index_containing_pane(pane_id)?;
                window.tabs()[index].layout.as_ref().map(SplitNode::leaf_count)
            })
            .unwrap_or(0)
    }

    /// Takes `pane_id` out of its layout, keeping the pane. A layout tab it leaves empty goes;
    /// a window it leaves empty stays until [`Self::finish_move`].
    fn detach_pane(&mut self, window_id: &str, pane_id: &str) {
        if let Some(window) = self.windows.get_mut(window_id) {
            window.remove_pane(pane_id);
        }
    }

    /// Takes `layout_tab_id` out of `window_id`'s row. `None` for a window's only tab.
    fn take_layout_tab(&mut self, window_id: &str, layout_tab_id: &str) -> Option<LayoutTab> {
        let window = self.windows.get_mut(window_id)?;
        let index = window.tab_index_of(layout_tab_id)?;
        if window.tabs().len() > 1 {
            return window.take_tab(index);
        }
        let tab = window.tabs()[index].clone();
        window.set_layout(None);
        Some(tab)
    }

    /// Adds a window to `beside`'s session holding `tab`, named after its focused pane.
    fn insert_window_beside(&mut self, beside: &str, tab: LayoutTab) -> String {
        let session_id = self.windows[beside].session_id.clone();
        let suggested = Self::suggested_window_title(
            self.panes.get(&tab.active_pane_id).and_then(|pane| pane.active_tab()),
        );
        let title = self.unique_automatic_window_title(&suggested, None, Some(&session_id));
        let window_id = self.next_window_id();
        self.windows.insert(
            window_id.clone(),
            WorkspaceWindowState::new(&window_id, session_id, title, vec![tab], 0),
        );
        window_id
    }

    /// Shows the moved pane in `target` and closes `source` when the move emptied it.
    fn finish_move(&mut self, source: &str, target: &str, focus: &str) {
        self.bring_pane_forward(target, focus);
        self.retire_if_empty(source);
        self.notify_model(true);
    }

    fn retire_if_empty(&mut self, window_id: &str) {
        if self.windows.get(window_id).is_some_and(WorkspaceWindowState::is_empty) {
            // A move keeps another window in the session, so one always remains.
            self.retire_window(window_id);
        }
    }
}
