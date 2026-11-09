//! Logical windows and their layout tabs (`Models/WorkspaceWindowState.swift`) and the live
//! sessions that group them (`Models/TerminalSessionState.swift`).

use std::collections::HashSet;

use serde::{Deserialize, Serialize};

use crate::split_node::{SplitBranchSide, SplitDirection, SplitNode};

/// One tab of a logical window: a complete split layout of its own. Hidden tabs keep their
/// panes, and so their terminals, alive.
#[derive(Clone, Debug, PartialEq)]
pub struct LayoutTab {
    pub id: String,
    pub layout: Option<SplitNode>,
    pub active_pane_id: String,
}

/// A live group of windows. Switching groups leaves their terminals running.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalSessionState {
    pub id: String,
    pub name: String,
    pub active_window_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_active_window_id: Option<String>,
}

impl TerminalSessionState {
    pub const DEFAULT_ID: &'static str = "session-1";

    pub fn new(id: impl Into<String>, name: impl Into<String>, active_window_id: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            active_window_id: active_window_id.into(),
            last_active_window_id: None,
        }
    }
}

/// A logical terminal window: an ordered row of tabs, each holding its own split layout. Only
/// the active tab's layout is on screen.
#[derive(Clone, Debug, PartialEq)]
pub struct WorkspaceWindowState {
    pub id: String,
    pub session_id: String,
    pub title: String,
    pub is_title_custom: bool,
    pub is_sidebar_collapsed: bool,
    /// Never empty: closing a window's last tab closes the window instead.
    tabs: Vec<LayoutTab>,
    active_tab_index: usize,
}

impl WorkspaceWindowState {
    /// A window in `session_id` showing `tabs` (never empty) with `active_tab_index` clamped.
    pub fn new(
        id: impl Into<String>,
        session_id: impl Into<String>,
        title: impl Into<String>,
        tabs: Vec<LayoutTab>,
        active_tab_index: usize,
    ) -> Self {
        assert!(!tabs.is_empty(), "A window always has at least one tab");
        let active_tab_index = active_tab_index.min(tabs.len() - 1);
        Self {
            id: id.into(),
            session_id: session_id.into(),
            title: title.into(),
            is_title_custom: false,
            is_sidebar_collapsed: false,
            tabs,
            active_tab_index,
        }
    }

    pub fn tabs(&self) -> &[LayoutTab] {
        &self.tabs
    }

    pub fn active_tab_index(&self) -> usize {
        self.active_tab_index
    }

    pub fn active_tab(&self) -> &LayoutTab {
        &self.tabs[self.active_tab_index]
    }

    /// The active tab's split layout.
    pub fn layout(&self) -> Option<&SplitNode> {
        self.tabs[self.active_tab_index].layout.as_ref()
    }

    pub fn set_layout(&mut self, layout: Option<SplitNode>) {
        self.tabs[self.active_tab_index].layout = layout;
    }

    /// The focused pane of the active tab.
    pub fn active_pane_id(&self) -> &str {
        &self.tabs[self.active_tab_index].active_pane_id
    }

    pub fn set_active_pane_id(&mut self, pane_id: impl Into<String>) {
        self.tabs[self.active_tab_index].active_pane_id = pane_id.into();
    }

    /// Every pane in every tab.
    pub fn pane_ids(&self) -> HashSet<String> {
        let mut ids = HashSet::new();
        for tab in &self.tabs {
            if let Some(layout) = &tab.layout {
                layout.insert_leaf_ids(&mut ids);
            }
        }
        ids
    }

    /// Every pane, tab by tab, in each tab's on-screen order.
    pub fn ordered_pane_ids(&self) -> Vec<String> {
        self.tabs.iter().filter_map(|tab| tab.layout.as_ref()).flat_map(SplitNode::ordered_leaf_ids).collect()
    }

    /// True once the last pane of the last tab has gone.
    pub fn is_empty(&self) -> bool {
        self.tabs.iter().all(|tab| tab.layout.is_none())
    }

    pub fn contains_pane(&self, pane_id: &str) -> bool {
        self.tab_index_containing_pane(pane_id).is_some()
    }

    pub fn tab_index_containing_pane(&self, pane_id: &str) -> Option<usize> {
        self.tabs
            .iter()
            .position(|tab| tab.layout.as_ref().is_some_and(|layout| layout.contains_leaf(pane_id)))
    }

    pub fn tab_index_of(&self, layout_tab_id: &str) -> Option<usize> {
        self.tabs.iter().position(|tab| tab.id == layout_tab_id)
    }

    /// Brings the tab at `index` to the front. Returns whether the visible tab changed.
    pub fn activate_tab(&mut self, index: usize) -> bool {
        if index >= self.tabs.len() || index == self.active_tab_index {
            return false;
        }
        self.active_tab_index = index;
        true
    }

    /// Brings the tab holding `pane_id` to the front.
    pub fn activate_tab_containing_pane(&mut self, pane_id: &str) -> bool {
        match self.tab_index_containing_pane(pane_id) {
            Some(index) => self.activate_tab(index),
            None => false,
        }
    }

    /// Brings the tab `offset` places away to the front, wrapping around the ends of the row.
    pub fn activate_tab_offset(&mut self, offset: isize) -> bool {
        let count = self.tabs.len() as isize;
        if count <= 1 {
            return false;
        }
        let index = (self.active_tab_index as isize + offset).rem_euclid(count);
        self.activate_tab(index as usize)
    }

    /// Adds `tab` at the end of the row and brings it to the front.
    pub fn append_tab(&mut self, tab: LayoutTab) {
        self.tabs.push(tab);
        self.active_tab_index = self.tabs.len() - 1;
    }

    /// Removes the tab at `index` and returns the panes it held. Removing the active tab shows
    /// its right neighbor, or the new last tab. The last tab is never removed; closing it
    /// closes the window.
    pub fn remove_tab(&mut self, index: usize) -> HashSet<String> {
        if self.tabs.len() <= 1 || index >= self.tabs.len() {
            return HashSet::new();
        }
        let removed = self.tabs.remove(index);
        if index < self.active_tab_index {
            self.active_tab_index -= 1;
        } else {
            self.active_tab_index = self.active_tab_index.min(self.tabs.len() - 1);
        }
        removed.layout.map(|layout| layout.leaf_ids()).unwrap_or_default()
    }

    /// Splits `pane_id` in whichever tab holds it and focuses the new pane there.
    pub fn insert_split(&mut self, pane_id: &str, new_pane_id: &str, direction: SplitDirection) -> bool {
        let Some(index) = self.tab_index_containing_pane(pane_id) else { return false };
        let Some(updated) = self.tabs[index]
            .layout
            .as_ref()
            .and_then(|layout| layout.inserting_split(pane_id, new_pane_id, direction))
        else {
            return false;
        };
        self.tabs[index].layout = Some(updated);
        self.tabs[index].active_pane_id = new_pane_id.to_owned();
        true
    }

    /// Removes `pane_id` from its tab without bringing that tab to the front. A tab left
    /// without panes goes too, unless it is the last one: an empty window is for the caller to
    /// close.
    pub fn remove_pane(&mut self, pane_id: &str) {
        let Some(index) = self.tab_index_containing_pane(pane_id) else { return };
        let Some(layout) = &self.tabs[index].layout else { return };
        match layout.removing(pane_id) {
            None => {
                self.tabs[index].layout = None;
                self.remove_tab(index);
            }
            Some(updated) => {
                let first = updated.first_leaf().to_owned();
                self.tabs[index].layout = Some(updated);
                if self.tabs[index].active_pane_id == pane_id {
                    self.tabs[index].active_pane_id = first;
                }
            }
        }
    }

    /// Sets the active tab's split percentage at `path`. Returns whether it changed.
    pub fn set_split_percentage(&mut self, path: &[SplitBranchSide], percentage: f64) -> bool {
        let Some(layout) = self.layout() else { return false };
        let updated = layout.setting_split_percentage(path, percentage);
        if &updated == layout {
            return false;
        }
        self.set_layout(Some(updated));
        true
    }

    /// Adjusts the active tab's split percentage at `path`. Returns whether it changed.
    pub fn adjust_split(&mut self, path: &[SplitBranchSide], delta: f64) -> bool {
        let Some(layout) = self.layout() else { return false };
        let updated = layout.adjusting_split(path, delta);
        if &updated == layout {
            return false;
        }
        self.set_layout(Some(updated));
        true
    }
}
