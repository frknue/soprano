//! Panes and their tabs (`Models/PaneState.swift`).

use std::path::Path;

use serde::{Deserialize, Serialize};
use soprano_types::AgentCatalog;

use crate::agent_instance::AgentInstance;
use crate::file_url;

/// Specializations of a browser-backed or agent tab, stored as a string (`contentKind`) rather
/// than as new `PaneType` cases so older builds still decode the workspace.
pub struct PaneContentKind;

impl PaneContentKind {
    /// A Markdown reader.
    pub const MARKDOWN: &'static str = "markdown";
    /// A file open in Soprano's code editor.
    pub const EDITOR: &'static str = "editor";
    /// A file's working-tree changes: the index against the working tree.
    pub const DIFF: &'static str = "diff";
    /// A file's staged changes: HEAD against the index.
    pub const STAGED_DIFF: &'static str = "staged-diff";
    /// An agent tab shown as a chat instead of a terminal. Kept on an agent tab rather than as
    /// a `PaneType` so older builds decode the workspace and reopen the conversation in the
    /// agent's terminal.
    pub const CHAT: &'static str = "chat";

    /// The tab title for `file` shown as `content_kind`, after Orca's "name (diff)" and
    /// "name (staged diff)".
    pub fn title(file: &Path, content_kind: &str) -> String {
        let name = file_url::last_component(file);
        match content_kind {
            Self::DIFF => format!("{name} (diff)"),
            Self::STAGED_DIFF => format!("{name} (staged diff)"),
            _ => name,
        }
    }
}

/// Agents a chat tab can run, by profile id: those whose CLI serves the Agent Client Protocol
/// on stdio (Swift `AgentChatLaunch.supports(profileId:)`).
pub fn chat_supports(profile_id: &str) -> bool {
    profile_id == "omp"
}

/// The type of content in a pane tab. Decoding an unknown type fails, as in Swift.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PaneType {
    Agent,
    Browser,
    Terminal,
}

/// A single tab within a pane.
#[derive(Clone, Debug, PartialEq)]
pub struct PaneTab {
    pub id: String,
    pub pane_type: PaneType,
    pub title: String,
    pub agent: Option<AgentInstance>,
    pub cwd: Option<String>,
    /// Last committed browser location. Used to restore browser tabs without coupling session
    /// persistence to the live web view.
    pub url: Option<String>,
    /// Optional specialization for browser-backed content (see [`PaneContentKind`]).
    pub content_kind: Option<String>,
    /// Terminal pane that owns this reusable preview tab. Older workspaces may keep it in a
    /// separate pane. `None` readers are standalone panes opened from the UI or with
    /// `markdown --new`.
    pub preview_owner_pane_id: Option<String>,
    /// Initial terminal command. Restored workspaces open an ordinary shell instead.
    pub startup_command: Option<Vec<String>>,
}

impl PaneTab {
    /// A tab with only id, type and title set.
    pub fn new(id: impl Into<String>, pane_type: PaneType, title: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            pane_type,
            title: title.into(),
            agent: None,
            cwd: None,
            url: None,
            content_kind: None,
            preview_owner_pane_id: None,
            startup_command: None,
        }
    }

    fn content_kind_is(&self, kind: &str) -> bool {
        self.content_kind.as_deref() == Some(kind)
    }

    pub fn is_markdown(&self) -> bool {
        self.pane_type == PaneType::Browser && self.content_kind_is(PaneContentKind::MARKDOWN)
    }

    /// Stored as a specialized browser tab, like the Markdown reader, so older builds can
    /// still decode a workspace with one (they show it as a page).
    pub fn is_editor(&self) -> bool {
        self.pane_type == PaneType::Browser && self.content_kind_is(PaneContentKind::EDITOR)
    }

    /// A git diff of a file, staged or not.
    pub fn is_diff(&self) -> bool {
        self.pane_type == PaneType::Browser
            && (self.content_kind_is(PaneContentKind::DIFF)
                || self.content_kind_is(PaneContentKind::STAGED_DIFF))
    }

    /// An editor or diff tab the next preview open replaces, like Orca's preview tabs.
    pub fn is_file_preview(&self) -> bool {
        (self.is_editor() || self.is_diff()) && self.preview_owner_pane_id.is_some()
    }

    /// A real web page, as opposed to browser-backed file content.
    pub fn is_web_browser(&self) -> bool {
        self.pane_type == PaneType::Browser && self.content_kind.is_none()
    }

    /// An agent driven over the Agent Client Protocol and shown as a chat.
    pub fn is_chat(&self) -> bool {
        self.pane_type == PaneType::Agent && self.content_kind_is(PaneContentKind::CHAT)
    }

    /// The directory the tab's process actually started in: explicit tab cwd, else the
    /// profile's cwd, else the app process's cwd (the terminal inherits it when no working
    /// directory is set). Browser-backed tabs have none.
    pub fn effective_working_directory(&self) -> Option<String> {
        if self.pane_type == PaneType::Browser {
            return None;
        }
        if let Some(cwd) = &self.cwd {
            return Some(cwd.clone());
        }
        if let Some(profile_cwd) = self
            .agent
            .as_ref()
            .and_then(|agent| AgentCatalog::shared().profile(&agent.profile_id))
            .and_then(|p| p.cwd)
        {
            return Some(profile_cwd);
        }
        std::env::current_dir().ok().map(|dir| dir.to_string_lossy().into_owned())
    }

    /// What window search (⌘F) matches the tab by: title, directory, page, and the attached
    /// agent's name.
    pub fn search_terms(&self) -> Vec<String> {
        let agent_name = self
            .agent
            .as_ref()
            .and_then(|agent| AgentCatalog::shared().profile(&agent.profile_id))
            .map(|p| p.name);
        [Some(self.title.clone()), self.cwd.clone(), self.url.clone(), agent_name]
            .into_iter()
            .flatten()
            .collect()
    }
}

/// A pane in one tab's split layout, containing one or more logical tabs.
#[derive(Clone, Debug, PartialEq)]
pub struct PaneState {
    pub id: String,
    pub tabs: Vec<PaneTab>,
    pub active_tab_index: usize,
}

impl PaneState {
    pub const MAX_TABS_PER_PANE: usize = 10;

    pub fn new(id: impl Into<String>, tabs: Vec<PaneTab>) -> Self {
        Self { id: id.into(), tabs, active_tab_index: 0 }
    }

    pub fn active_tab(&self) -> Option<&PaneTab> {
        self.tabs.get(self.clamped_active_index())
    }

    pub fn active_tab_mut(&mut self) -> Option<&mut PaneTab> {
        let index = self.clamped_active_index();
        self.tabs.get_mut(index)
    }

    pub fn clamped_active_index(&self) -> usize {
        self.active_tab_index.min(self.tabs.len().saturating_sub(1))
    }

    pub fn tab(&self, tab_id: &str) -> Option<&PaneTab> {
        self.tabs.iter().find(|tab| tab.id == tab_id)
    }

    pub fn tab_index(&self, tab_id: &str) -> Option<usize> {
        self.tabs.iter().position(|tab| tab.id == tab_id)
    }
}
