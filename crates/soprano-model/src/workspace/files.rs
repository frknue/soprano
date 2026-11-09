//! Markdown reader, editor and diff tabs: where files open, preview tabs, and following files
//! that move.

use std::path::Path;

use super::{TabSpec, TerminalTarget, Workspace, WorkspaceChange};
use crate::file_url;
use crate::pane::{PaneContentKind, PaneState, PaneTab, PaneType};

impl Workspace {
    // MARK: - Markdown readers

    /// Opens `file` in a Markdown reader in a new pane beside the active one.
    pub fn spawn_markdown(&mut self, file: &Path, preview_owner_pane_id: Option<&str>) -> Option<String> {
        if !self.can_add_pane(&self.active_window_id) {
            return None;
        }
        let pane_id = self.next_pane_id();
        let tab =
            self.create_file_tab(file, PaneContentKind::MARKDOWN, preview_owner_pane_id.map(str::to_owned));
        self.insert_pane(PaneState::new(&pane_id, vec![tab])).then_some(pane_id)
    }

    /// Shows a reusable reader in the caller's pane while retaining its terminal tabs. Returns
    /// the reader's tab id, or `None` when the pane is gone or has no room for another tab.
    pub fn preview_markdown(&mut self, file: &Path, pane_id: &str) -> Option<String> {
        let pane = self.panes.get(pane_id)?;
        let window_id = self.window_id_containing_pane(pane_id)?;
        let tab_id = match self.markdown_preview_target(pane_id) {
            Some(target) => {
                self.update_file_document(pane_id, &target.tab_id, file);
                target.tab_id
            }
            None => {
                if pane.tabs.len() >= PaneState::MAX_TABS_PER_PANE {
                    return None;
                }
                let tab = self.create_file_tab(file, PaneContentKind::MARKDOWN, Some(pane_id.to_owned()));
                let tab_id = tab.id.clone();
                self.panes.get_mut(pane_id)?.tabs.push(tab);
                tab_id
            }
        };
        self.show_tab(&tab_id, pane_id, &window_id);
        Some(tab_id)
    }

    /// The reusable reader tab `owner_pane_id` holds for itself.
    pub fn markdown_preview_target(&self, owner_pane_id: &str) -> Option<TerminalTarget> {
        let tab =
            self.panes.get(owner_pane_id)?.tabs.iter().find(|tab| {
                tab.is_markdown() && tab.preview_owner_pane_id.as_deref() == Some(owner_pane_id)
            })?;
        Some(TerminalTarget::new(owner_pane_id, &tab.id))
    }

    /// Makes `tab_id` the visible, focused tab of its pane, bringing its window and layout tab
    /// to the front. A maximized caller keeps its size.
    fn show_tab(&mut self, tab_id: &str, pane_id: &str, window_id: &str) {
        if self.maximized_pane_id.as_deref().is_some_and(|maximized| maximized != pane_id) {
            self.exit_maximize();
        }
        let (window_changed, layout_tab_changed) = self.bring_pane_forward(window_id, pane_id);
        if let Some(pane) = self.panes.get_mut(pane_id) {
            pane.active_tab_index = pane.tab_index(tab_id).unwrap_or(0);
        }
        self.notify_model(window_changed || layout_tab_changed);
    }

    fn create_file_tab(
        &mut self,
        file: &Path,
        content_kind: &str,
        preview_owner_pane_id: Option<String>,
    ) -> PaneTab {
        let path = file_url::standardized_path(file);
        Self::create_pane_tab(
            self.next_tab_id(),
            TabSpec {
                pane_type: PaneType::Browser,
                cwd: Some(file_url::parent_directory(&path)),
                url: Some(file_url::file_url_string(&path)),
                title: Some(PaneContentKind::title(&path, content_kind)),
                content_kind: Some(content_kind.to_owned()),
                preview_owner_pane_id,
                ..TabSpec::default()
            },
        )
    }

    // MARK: - Editor and diff tabs

    /// Opens `file` in an editor tab and shows it, like Orca's editor tabs, without covering
    /// what the focused pane shows:
    ///
    /// - Files go to `pane_id`, else the window's file pane (see [`Self::file_pane`]), else a
    ///   new split beside the focused pane, which then becomes the file pane for the files that
    ///   follow.
    /// - A file already open in that pane gets its tab focused; opening it as permanent turns
    ///   a preview tab into a regular one.
    /// - A preview replaces the pane's existing preview tab, so browsing files does not pile up
    ///   tabs.
    /// - A file pane without room for another tab gets the file in a new split.
    pub fn open_editor(
        &mut self,
        file: &Path,
        preview: bool,
        pane_id: Option<&str>,
    ) -> Option<TerminalTarget> {
        self.open_file_tab(file, PaneContentKind::EDITOR, preview, pane_id)
    }

    /// Opens the git diff of `file` the way [`Self::open_editor`] opens files: its staged and
    /// working-tree changes are separate tabs, and a preview diff and a preview file replace
    /// each other, as in Orca.
    pub fn open_diff(
        &mut self,
        file: &Path,
        staged: bool,
        preview: bool,
        pane_id: Option<&str>,
    ) -> Option<TerminalTarget> {
        let kind = if staged { PaneContentKind::STAGED_DIFF } else { PaneContentKind::DIFF };
        self.open_file_tab(file, kind, preview, pane_id)
    }

    /// Opens `file` in a Markdown reader tab of `pane_id`, the way [`Self::open_editor`] opens
    /// files; a full pane gets it in a new split.
    pub fn open_markdown(&mut self, file: &Path, pane_id: &str) -> Option<TerminalTarget> {
        self.open_file_tab(file, PaneContentKind::MARKDOWN, false, Some(pane_id))
    }

    fn open_file_tab(
        &mut self,
        file: &Path,
        content_kind: &str,
        preview: bool,
        pane_id: Option<&str>,
    ) -> Option<TerminalTarget> {
        let path = file_url::standardized_path(file);
        // Compared by path, not URL string: Swift wrote decomposed, differently escaped URLs.
        let comparable = file_url::comparable_path(&path);
        let pane_id = match pane_id.map(str::to_owned).or_else(|| self.file_pane(&self.active_window_id)) {
            Some(id) if self.panes.contains_key(&id) => id,
            _ => return self.spawn_file_tab(&path, content_kind, preview),
        };
        let Some(window_id) = self.window_id_containing_pane(&pane_id) else {
            return self.spawn_file_tab(&path, content_kind, preview);
        };

        let pane = self.panes.get(&pane_id)?;
        let existing = pane.tabs.iter().position(|tab| {
            tab.pane_type == PaneType::Browser
                && tab.content_kind.as_deref() == Some(content_kind)
                && tab.url.as_deref().and_then(file_url::comparable_path_from_url).as_ref()
                    == Some(&comparable)
        });
        let tab_id = match existing {
            Some(index) => {
                let pane = self.panes.get_mut(&pane_id)?;
                if !preview {
                    pane.tabs[index].preview_owner_pane_id = None;
                }
                pane.tabs[index].id.clone()
            }
            None => {
                let tab = self.create_file_tab(&path, content_kind, preview.then(|| pane_id.clone()));
                let tab_id = tab.id.clone();
                let pane = self.panes.get_mut(&pane_id)?;
                let preview_index = pane
                    .tabs
                    .iter()
                    .position(|tab| {
                        tab.is_file_preview()
                            && tab.preview_owner_pane_id.as_deref() == Some(pane_id.as_str())
                    })
                    .filter(|_| preview);
                if let Some(index) = preview_index {
                    // A new tab id gives the new file its own view; the old preview's view is
                    // discarded with its tab.
                    pane.tabs[index] = tab;
                } else if pane.tabs.len() < PaneState::MAX_TABS_PER_PANE {
                    let at = (pane.clamped_active_index() + 1).min(pane.tabs.len());
                    pane.tabs.insert(at, tab);
                } else {
                    return self.spawn_file_tab(&path, content_kind, preview);
                }
                tab_id
            }
        };
        self.show_tab(&tab_id, &pane_id, &window_id);
        Some(TerminalTarget::new(pane_id, tab_id))
    }

    /// Where files open in `window_id`: the focused pane when it holds only files (editor,
    /// diff, and Markdown reader tabs), else the first such pane in the active layout tab.
    /// `None` when there is none, so the next file gets its own split.
    pub fn file_pane(&self, window_id: &str) -> Option<String> {
        let window = self.windows.get(window_id)?;
        let is_file_pane = |pane_id: &str| {
            self.panes.get(pane_id).is_some_and(|pane| {
                !pane.tabs.is_empty()
                    && pane.tabs.iter().all(|tab| tab.is_editor() || tab.is_diff() || tab.is_markdown())
            })
        };
        let visible = window.layout().map(|layout| layout.ordered_leaf_ids()).unwrap_or_default();
        let active = window.active_pane_id();
        if visible.iter().any(|id| id == active) && is_file_pane(active) {
            return Some(active.to_owned());
        }
        visible.into_iter().find(|id| is_file_pane(id))
    }

    /// Opens a file tab in a new split beside the focused pane. A window with no room for
    /// another pane gets it as a tab of the focused pane instead.
    fn spawn_file_tab(&mut self, path: &Path, content_kind: &str, preview: bool) -> Option<TerminalTarget> {
        if !self.can_add_pane(&self.active_window_id) {
            let pane_id = self.active_pane_id().to_owned();
            let window_id = self.window_id_containing_pane(&pane_id)?;
            if self.panes.get(&pane_id)?.tabs.len() >= PaneState::MAX_TABS_PER_PANE {
                return None;
            }
            let tab = self.create_file_tab(path, content_kind, None);
            let tab_id = tab.id.clone();
            let pane = self.panes.get_mut(&pane_id)?;
            let at = (pane.clamped_active_index() + 1).min(pane.tabs.len());
            pane.tabs.insert(at, tab);
            self.show_tab(&tab_id, &pane_id, &window_id);
            return Some(TerminalTarget::new(pane_id, tab_id));
        }
        let pane_id = self.next_pane_id();
        let tab = self.create_file_tab(path, content_kind, preview.then(|| pane_id.clone()));
        let tab_id = tab.id.clone();
        self.insert_pane(PaneState::new(&pane_id, vec![tab])).then(|| TerminalTarget::new(pane_id, tab_id))
    }

    /// Turns a preview editor tab into a regular one, as editing it does.
    pub fn keep_editor_tab(&mut self, pane_id: &str, tab_id: &str) {
        let Some(tab) = self.tab_mut(pane_id, tab_id) else { return };
        if !tab.is_file_preview() {
            return;
        }
        tab.preview_owner_pane_id = None;
        self.notify(WorkspaceChange::TabTitle(TerminalTarget::new(pane_id, tab_id)));
    }

    /// Points every editor, diff, and Markdown reader tab showing `old`, or a file inside it
    /// when it is a folder, at its new location after a rename or move.
    pub fn relocate_file_tabs(&mut self, old: &Path, new: &Path) {
        let old_path = file_url::comparable_path(old);
        let new_path = file_url::standardized_path(new);
        let mut moves = Vec::new();
        for pane in self.panes.values() {
            for tab in pane.tabs.iter().filter(|tab| tab.is_editor() || tab.is_diff() || tab.is_markdown()) {
                let Some(path) = tab.url.as_deref().and_then(file_url::comparable_path_from_url) else {
                    continue;
                };
                let Ok(rest) = path.strip_prefix(&old_path) else { continue };
                let relocated =
                    if rest.as_os_str().is_empty() { new_path.clone() } else { new_path.join(rest) };
                moves.push((pane.id.clone(), tab.id.clone(), relocated));
            }
        }
        for (pane_id, tab_id, relocated) in moves {
            self.update_file_document(&pane_id, &tab_id, &relocated);
        }
    }

    /// Points a Markdown reader, editor, or diff tab at `file`.
    pub fn update_file_document(&mut self, pane_id: &str, tab_id: &str, file: &Path) {
        let path = file_url::standardized_path(file);
        let Some(tab) = self.tab_mut(pane_id, tab_id) else { return };
        if !(tab.is_markdown() || tab.is_editor() || tab.is_diff()) {
            return;
        }
        let Some(content_kind) = tab.content_kind.clone() else { return };
        let url = file_url::file_url_string(&path);
        let title = PaneContentKind::title(&path, &content_kind);
        let directory = file_url::parent_directory(&path);
        let same_path = tab.url.as_deref().and_then(file_url::comparable_path_from_url)
            == Some(file_url::comparable_path(&path));
        if same_path
            && file_url::same_text(&tab.title, &title)
            && tab.cwd.as_deref().is_some_and(|cwd| file_url::same_text(cwd, &directory))
        {
            return;
        }
        tab.url = Some(url);
        tab.title = title;
        tab.cwd = Some(directory);
        self.notify(WorkspaceChange::Document(TerminalTarget::new(pane_id, tab_id)));
    }
}
