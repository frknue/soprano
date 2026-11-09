//! soprano-explorer: Soprano's right sidebar drawn as Herdr's Files and Changes cards.
//!
//! - [`FilesPanel`]: the focused pane's project as a lazily loaded tree with git
//!   decorations, a name filter, inline create and rename, Trash-backed delete, drag and
//!   drop, and undo (`FileExplorerView.swift`, `FileExplorerRows.swift`).
//! - [`ChangesPanel`]: the repository's changed files by area, each opening its diff
//!   (`SourceControlView.swift`); staging and committing stay in the terminal.
//! - [`RightSidebar`]: both panels, the active tab, open state and width
//!   (`RightSidebarView.swift`); the app shell owns the outer frame.
//!
//! The panels never open tabs themselves: they emit [`SidebarEvent`]s for the app.

mod changes;
mod chords;
mod file_clipboard;
mod files;
pub mod open_in;
mod refresh;
mod reveal;
mod right_sidebar;
mod selection;
pub mod sidebar;
#[cfg(test)]
mod test_support;
mod ui;

use std::path::PathBuf;

pub use changes::ChangesPanel;
pub use files::FilesPanel;
pub use right_sidebar::RightSidebar;
pub use sidebar::{PanelToggle, RightSidebarState, RightSidebarTab, SidebarWidthStore};

/// What the panels ask the app to do.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SidebarEvent {
    /// Open the file in Soprano's editor beside the focused pane: as a preview tab the
    /// next preview replaces, or a kept tab. A file with unsaved changes is never opened
    /// as a preview. With `focus`, the keyboard follows into the editor.
    OpenFile { path: PathBuf, preview: bool, focus: bool },
    /// Open the file's diff tab (titled by [`diff_tab_title`]), working tree or staged.
    OpenDiff { path: PathBuf, staged: bool, preview: bool, focus: bool },
    /// Open the Markdown reader in the window's file pane, else in a new split.
    OpenMarkdownPreview { path: PathBuf },
    /// Open a terminal pane working in `directory`.
    OpenInTerminal { directory: PathBuf },
    /// Hand the keyboard back to the focused pane (Esc in a panel).
    FocusPane,
    /// A file or folder was renamed or moved (also by undo/redo): tabs showing it, or
    /// anything under it, follow.
    ItemMoved { from: PathBuf, to: PathBuf },
    /// A failure to show as a toast.
    ShowError(String),
}

impl gpui::EventEmitter<SidebarEvent> for FilesPanel {}
impl gpui::EventEmitter<SidebarEvent> for ChangesPanel {}
impl gpui::EventEmitter<SidebarEvent> for RightSidebar {}

/// The drag payload of explorer rows. Drop targets elsewhere in the app (a terminal
/// inserts the paths) accept it with `on_drop::<ExplorerDrag>`; dragged out of the
/// window it becomes a native file drag.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExplorerDrag {
    /// Each dragged item and whether it is a folder.
    pub items: Vec<(PathBuf, bool)>,
    source: gpui::EntityId,
}

impl ExplorerDrag {
    pub fn paths(&self) -> Vec<PathBuf> {
        self.items.iter().map(|(path, _)| path.clone()).collect()
    }
}

/// The tab title of a diff: `name (diff)` or `name (staged diff)`.
pub fn diff_tab_title(name: &str, staged: bool) -> String {
    if staged { format!("{name} (staged diff)") } else { format!("{name} (diff)") }
}

/// The message Swift shows when no tab or pane can be added (for the app's toast).
pub const NO_ROOM_MESSAGE: &str = "No room for another tab or pane in this window.";
