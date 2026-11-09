//! The Files card (`FileExplorerView.swift`, `FileExplorerRows.swift`): the focused pane's
//! project as a lazily loaded tree with git decorations, a name filter, inline create and
//! rename, Trash-backed delete, drag and drop, and undo.
//!
//! The root follows the pane the app reports through [`FilesPanel::set_working_directory`]:
//! the git working tree containing its directory, or the directory itself outside a
//! repository. Nothing is read, watched, or run while the panel is inactive.

use std::cell::RefCell;
use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::{Duration, Instant};

use futures::StreamExt;
use futures::channel::mpsc;
use gpui::{
    AnyWindowHandle, App, ClickEvent, ClipboardItem, Context, DragMoveEvent, Entity, ExternalDragPayload,
    ExternalPaths, FileDragPaths, FocusHandle, Focusable, FontWeight, IntoElement, KeyDownEvent, MouseButton,
    MouseDownEvent, ParentElement, Pixels, Point, Render, ScrollStrategy, SharedString, Styled, Subscription,
    Task, UniformListScrollHandle, Window, div, prelude::*, uniform_list,
};
use gpui_component::input::{Escape, Input, InputEvent, InputState};
use soprano_files::listing::{self, committed_name, filter_tokens, stem_range};
use soprano_files::operations::OperationError;
use soprano_files::root::{
    absolute_path, child_path, external_git_directory, parent_path, real_path, relative_path_in_roots,
};
use soprano_files::tree::{
    DropOperation, ENUMERATED_FILE_LIMIT, FilterNode, build_filter_tree, copied_paths, drop_folder,
    drop_operation, enumerate_files, route_events, top_level_selection,
};
use soprano_files::{
    ExplorerPreferences, ExplorerRoot, FileExplorerOperations, FileExplorerTree, FileSystemWatcher,
    VisibilityRules, explorer_root,
};
use soprano_git::GitStatusSnapshot;
use soprano_platform::StateStore;
use soprano_ui::fonts::size;
use soprano_ui::{
    ActiveSopranoTheme, ContextMenu, IconName, MenuItem, SopranoTheme, file_type_icon, folder_icon, icon,
};

use crate::chords::{self, Chord};
use crate::refresh::RefreshGate;
use crate::selection::Selection;
use crate::{ExplorerDrag, SidebarEvent, file_clipboard, open_in, ui};

/// What an inline new-item row creates.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum EntryKind {
    File,
    Folder,
}

/// The id of the inline new-item row inside `folder` (never a real name).
fn placeholder_id(folder: &str) -> String {
    child_path(folder, "\u{1}new-item")
}

/// One row on screen.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Row {
    /// Root-relative path (the placeholder's id for the new-item row).
    id: String,
    name: SharedString,
    depth: usize,
    is_directory: bool,
    is_symlink: bool,
    is_expanded: bool,
    is_loading: bool,
    placeholder: Option<EntryKind>,
}

struct RootState {
    root: ExplorerRoot,
    /// The root fully resolved through symlinks, which file watchers report.
    real_root: Option<PathBuf>,
    external_git_directory: Option<PathBuf>,
    tree: FileExplorerTree,
}

impl RootState {
    fn absolute(&self, relative: &str) -> PathBuf {
        absolute_path(&self.root.path, relative)
    }

    /// Both forms of the root, for matching absolute paths.
    fn roots(&self) -> Vec<&Path> {
        std::iter::once(self.root.path.as_path()).chain(self.real_root.as_deref()).collect()
    }

    fn relative(&self, path: &Path) -> Option<String> {
        relative_path_in_roots(&soprano_platform::paths::normalize(path), &self.roots())
    }
}

enum EditTarget {
    Rename { id: String, original: String, path: PathBuf },
    Create { folder: String, kind: EntryKind },
}

struct Editing {
    target: EditTarget,
    input: Entity<InputState>,
    /// Whether the name field has the keyboard; only then does finishing hand it back to
    /// the tree.
    has_focus: bool,
    _subscription: Subscription,
}

enum OperationEvent {
    DirectoriesChanged(Vec<PathBuf>),
    UndoFailure(String),
    ItemMoved(PathBuf, PathBuf),
}

/// What the tree area shows instead of rows.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Status {
    Message(String),
    Loading,
    LoadError(String),
}

/// A row being dragged over, with when the hover started (opens folders after 0.5 s).
struct DragHover {
    folder: String,
    _timer: Task<()>,
}

pub struct FilesPanel {
    focus_handle: FocusHandle,
    window_handle: AnyWindowHandle,
    prefs: ExplorerPreferences,
    operations: FileExplorerOperations,
    operation_events: Rc<RefCell<Vec<OperationEvent>>>,
    is_active: bool,
    desired_root: Option<ExplorerRoot>,
    last_working_directory: Option<String>,
    state: Option<RootState>,
    generation: u64,
    remembered_expansions: HashMap<PathBuf, BTreeSet<String>>,
    restore_expansions: BTreeSet<String>,
    git_status: GitStatusSnapshot,
    git_gate: RefreshGate,
    git_timer: Option<Task<()>>,
    watcher: Option<FileSystemWatcher>,
    _watch_task: Option<Task<()>>,
    pending_reloads: BTreeSet<String>,
    pending_selection: Vec<String>,
    pending_reveal: Option<(String, EntryKind)>,
    editing: Option<Editing>,
    display_refresh_deferred: bool,
    dragging: bool,
    drag_hover: Option<DragHover>,
    in_flight_loads: usize,
    manual_refreshing: bool,
    manual_refresh_spinner: bool,
    filter_input: Entity<InputState>,
    filter_tokens: Vec<String>,
    filter_files: Option<Vec<String>>,
    filter_generation: u64,
    filter_root: Option<FilterNode>,
    filter_collapsed: HashSet<String>,
    filter_timer: Option<Task<()>>,
    rows: Vec<Row>,
    selection: Selection,
    type_select: (String, Option<Instant>),
    scroll: UniformListScrollHandle,
    focus_tree_on_render: bool,
    context_menu: Option<(Entity<ContextMenu>, Subscription)>,
    _subscriptions: Vec<Subscription>,
}

impl FilesPanel {
    pub fn new(store: StateStore, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let operation_events = Rc::new(RefCell::new(Vec::new()));
        let operations = make_operations(&operation_events);

        let filter_input = cx.new(|cx| InputState::new(window, cx).placeholder("Search files"));
        let subscriptions =
            vec![
                cx.subscribe_in(&filter_input, window, |this, input, event: &InputEvent, window, cx| {
                    match event {
                        InputEvent::Change => {
                            let query = input.read(cx).value().to_string();
                            this.set_filter_query(&query, cx);
                        }
                        InputEvent::PressEnter { .. } => this.focus_tree(window, cx),
                        _ => {}
                    }
                }),
                // Catches git changes nothing under the watched paths reflects, such as a
                // commit made in another clone of a submodule.
                cx.observe_window_activation(window, |this, window, cx| {
                    if window.is_window_active() && this.is_active {
                        this.schedule_git_refresh(false, cx);
                    }
                }),
            ];
        open_in::warm_up();
        Self {
            focus_handle: cx.focus_handle(),
            window_handle: window.window_handle(),
            prefs: ExplorerPreferences::load(store),
            operations,
            operation_events,
            is_active: false,
            desired_root: None,
            last_working_directory: None,
            state: None,
            generation: 0,
            remembered_expansions: HashMap::new(),
            restore_expansions: BTreeSet::new(),
            git_status: GitStatusSnapshot::empty(),
            git_gate: RefreshGate::default(),
            git_timer: None,
            watcher: None,
            _watch_task: None,
            pending_reloads: BTreeSet::new(),
            pending_selection: Vec::new(),
            pending_reveal: None,
            editing: None,
            display_refresh_deferred: false,
            dragging: false,
            drag_hover: None,
            in_flight_loads: 0,
            manual_refreshing: false,
            manual_refresh_spinner: false,
            filter_input,
            filter_tokens: Vec::new(),
            filter_files: None,
            filter_generation: 0,
            filter_root: None,
            filter_collapsed: HashSet::new(),
            filter_timer: None,
            rows: Vec::new(),
            selection: Selection::default(),
            type_select: (String::new(), None),
            scroll: UniformListScrollHandle::new(),
            focus_tree_on_render: false,
            context_menu: None,
            _subscriptions: subscriptions,
        }
    }

    // MARK: - Public state

    pub fn is_active(&self) -> bool {
        self.is_active
    }

    /// The folder shown, if any.
    pub fn root(&self) -> Option<&Path> {
        self.state.as_ref().map(|state| state.root.path.as_path())
    }

    pub fn is_git_repository(&self) -> bool {
        self.state.as_ref().is_some_and(|state| state.root.is_git_repository)
    }

    pub fn git_status(&self) -> &GitStatusSnapshot {
        &self.git_status
    }

    /// The relative paths of the rows on screen, top to bottom.
    pub fn visible_paths(&self) -> Vec<String> {
        self.rows.iter().filter(|row| row.placeholder.is_none()).map(|row| row.id.clone()).collect()
    }

    /// The selected relative paths in row order.
    pub fn selected_paths(&self) -> Vec<String> {
        self.selection.in_order(self.rows.iter().map(|row| row.id.as_str()))
    }

    pub fn operations(&self) -> &FileExplorerOperations {
        &self.operations
    }

    /// Whether the keyboard is in the panel: the tree, the filter, or an inline name field.
    pub fn contains_focus(&self, window: &Window, cx: &App) -> bool {
        self.focus_handle.contains_focused(window, cx)
            || self.filter_input.read(cx).focus_handle(cx).is_focused(window)
            || self
                .editing
                .as_ref()
                .is_some_and(|editing| editing.input.read(cx).focus_handle(cx).is_focused(window))
    }

    /// Moves the keyboard into the tree, onto the first row if nothing is selected. Only
    /// keyboard paths call this: a click selects its own row.
    pub fn focus_tree(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        window.focus(&self.focus_handle, cx);
        if self.selection.is_empty()
            && let Some(first) = self.rows.first()
        {
            let id = first.id.clone();
            self.selection.select(&id);
        }
        cx.notify();
    }

    // MARK: - Activation

    /// Starts or stops reading, watching and git polling (sidebar open and showing Files).
    pub fn set_active(&mut self, active: bool, cx: &mut Context<Self>) {
        if active == self.is_active {
            return;
        }
        self.is_active = active;
        if active {
            match self.desired_root.clone() {
                Some(root) if Some(&root) != self.state.as_ref().map(|state| &state.root) => {
                    self.set_root(root, cx)
                }
                _ if self.state.is_some() => {
                    self.start_watching(cx);
                    self.refresh_all(cx);
                }
                _ => {}
            }
        } else {
            if self.editing.is_some() {
                self.finish_editing(true, cx);
            }
            self.watcher = None;
            self._watch_task = None;
            self.git_timer = None;
            self.git_gate.cancel();
        }
        cx.notify();
    }

    /// The working directory of the focused pane's tab; `None` for tabs without one
    /// (browser, Markdown), which keep the current root.
    pub fn set_working_directory(&mut self, cwd: Option<&str>, cx: &mut Context<Self>) {
        let Some(cwd) = cwd else { return };
        // Resolving the root walks the disk; the same directory resolves the same way.
        if self.last_working_directory.as_deref() == Some(cwd) {
            return;
        }
        self.last_working_directory = Some(cwd.to_owned());
        let root = explorer_root(cwd);
        self.desired_root = Some(root.clone());
        let unchanged = self.state.as_ref().is_some_and(|state| state.root == root);
        if self.is_active && !unchanged {
            self.set_root(root, cx);
        }
        cx.notify();
    }

    fn set_root(&mut self, root: ExplorerRoot, cx: &mut Context<Self>) {
        if self.editing.is_some() {
            self.finish_editing(true, cx);
        }
        if let Some(old) = self.state.take() {
            self.remembered_expansions.insert(old.root.path.clone(), old.tree.expanded_paths().clone());
        }
        self.generation += 1;
        let real_root = real_path(&root.path);
        let external = if root.is_git_repository { external_git_directory(&root.path) } else { None };
        self.restore_expansions = self.remembered_expansions.get(&root.path).cloned().unwrap_or_default();
        self.state = Some(RootState {
            tree: FileExplorerTree::new(root.path.clone()),
            root,
            real_root,
            external_git_directory: external,
        });
        self.git_status = GitStatusSnapshot::empty();
        self.git_gate.cancel();
        self.git_timer = None;
        self.pending_reloads.clear();
        self.pending_selection.clear();
        self.pending_reveal = None;
        self.display_refresh_deferred = false;
        self.in_flight_loads = 0;
        self.finish_manual_refresh();
        // A new root starts with an empty undo history.
        self.operations = make_operations(&self.operation_events);
        self.clear_filter(cx);
        self.filter_files = None;
        self.selection.clear();
        self.rebuild_rows();
        self.load_folder("", cx);
        self.start_watching(cx);
        self.schedule_git_refresh(true, cx);
    }

    // MARK: - Loading

    fn load_folder(&mut self, relative: &str, cx: &mut Context<Self>) {
        let Some(state) = self.state.as_mut() else { return };
        let Some(directory) = state.tree.begin_load(relative) else { return };
        self.in_flight_loads += 1;
        let generation = self.generation;
        let relative = relative.to_owned();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move { listing::entries(&directory).map_err(|error| error.to_string()) })
                .await;
            this.update(cx, |this, cx| this.finish_load(generation, &relative, result, cx)).ok();
        })
        .detach();
        self.rebuild_rows();
    }

    fn finish_load(
        &mut self,
        generation: u64,
        relative: &str,
        result: Result<Vec<listing::FileExplorerEntry>, String>,
        cx: &mut Context<Self>,
    ) {
        if generation != self.generation {
            return;
        }
        let Some(state) = self.state.as_mut() else { return };
        self.in_flight_loads = self.in_flight_loads.saturating_sub(1);
        let reload = state.tree.finish_load(relative, result);
        // Folders that were open the last time this root showed open again, and open
        // folders that are new nodes (renamed, moved, replaced) list their contents.
        let mut to_load = Vec::new();
        if let Some(children) = state.tree.node(relative).and_then(|node| node.children.clone()) {
            for child in children {
                if self.restore_expansions.remove(&child) {
                    state.tree.expand(&child);
                }
                let unloaded = state
                    .tree
                    .node(&child)
                    .is_some_and(|node| node.is_directory && node.children.is_none() && !node.is_loading());
                if unloaded && state.tree.is_expanded(&child) {
                    to_load.push(child);
                }
            }
        }
        for folder in to_load {
            self.load_folder(&folder, cx);
        }
        self.rebuild_rows();
        if !self.is_filtering() {
            self.apply_pending_selection();
        }
        if self.pending_reveal.is_some() {
            self.with_window(cx, |this, window, cx| this.continue_reveal(window, cx));
        }
        self.finish_manual_refresh_if_idle();
        if reload {
            self.load_folder(relative, cx);
        }
        cx.notify();
    }

    /// Runs `f` with this panel's window, outside the current update.
    fn with_window(
        &self,
        cx: &mut Context<Self>,
        f: impl FnOnce(&mut Self, &mut Window, &mut Context<Self>) + 'static,
    ) {
        let handle = self.window_handle;
        cx.spawn(async move |this, cx| {
            handle
                .update(cx, |_, window, cx| {
                    this.update(cx, |this, cx| f(this, window, cx)).ok();
                })
                .ok();
        })
        .detach();
    }

    fn rules(&self) -> Option<VisibilityRules<'_>> {
        let state = self.state.as_ref()?;
        Some(VisibilityRules {
            shows_dotfiles: self.prefs.shows_dotfiles(&state.root.path),
            shows_ignored_files: self.prefs.shows_ignored_files(),
            is_git_repository: state.root.is_git_repository,
            git_status: &self.git_status,
        })
    }

    fn is_filtering(&self) -> bool {
        !self.filter_tokens.is_empty()
    }

    // MARK: - Rows

    /// Rebuilds the rows on screen. While a name is typed inline the rows stay as they
    /// are (so the edited row cannot vanish under the caret) until editing ends.
    fn rebuild_rows(&mut self) {
        if self.editing.is_some() {
            self.display_refresh_deferred = true;
            return;
        }
        self.rows = self.compute_rows(None);
        let ids: Vec<&str> = self.rows.iter().map(|row| row.id.as_str()).collect();
        self.selection.retain_present(&ids);
    }

    fn compute_rows(&self, placeholder: Option<(&str, EntryKind)>) -> Vec<Row> {
        let mut rows = Vec::new();
        let Some(state) = self.state.as_ref() else { return rows };
        if self.is_filtering() {
            if let Some(root) = &self.filter_root {
                self.append_filter_rows(root, 0, &mut rows);
            }
            return rows;
        }
        let Some(rules) = self.rules() else { return rows };
        for visible in state.tree.visible_rows(&rules) {
            let Some(node) = state.tree.node(&visible.relative_path) else { continue };
            rows.push(Row {
                id: node.relative_path.clone(),
                name: node.name.clone().into(),
                depth: visible.depth,
                is_directory: node.is_directory,
                is_symlink: node.is_symlink,
                is_expanded: node.is_directory && state.tree.is_expanded(&node.relative_path),
                is_loading: node.is_loading() && node.children.is_none(),
                placeholder: None,
            });
        }
        if let Some((folder, kind)) = placeholder {
            // The new-item row goes last among the folder's rows, one level in.
            let (index, depth) = if folder.is_empty() {
                (rows.len(), 0)
            } else {
                let Some(position) = rows.iter().position(|row| row.id == folder) else { return rows };
                let depth = rows[position].depth + 1;
                let prefix = format!("{folder}/");
                let end = rows[position + 1..]
                    .iter()
                    .position(|row| !row.id.starts_with(&prefix))
                    .map_or(rows.len(), |offset| position + 1 + offset);
                (end, depth)
            };
            rows.insert(
                index,
                Row {
                    id: placeholder_id(folder),
                    name: SharedString::default(),
                    depth,
                    is_directory: kind == EntryKind::Folder,
                    is_symlink: false,
                    is_expanded: false,
                    is_loading: false,
                    placeholder: Some(kind),
                },
            );
        }
        rows
    }

    fn append_filter_rows(&self, folder: &FilterNode, depth: usize, rows: &mut Vec<Row>) {
        for child in &folder.children {
            let expanded = child.is_directory && !self.filter_collapsed.contains(&child.relative_path);
            rows.push(Row {
                id: child.relative_path.clone(),
                name: child.name.clone().into(),
                depth,
                is_directory: child.is_directory,
                is_symlink: false,
                is_expanded: expanded,
                is_loading: false,
                placeholder: None,
            });
            if expanded {
                self.append_filter_rows(child, depth + 1, rows);
            }
        }
    }

    fn row_ids(&self) -> Vec<&str> {
        self.rows.iter().map(|row| row.id.as_str()).collect()
    }

    fn row(&self, id: &str) -> Option<&Row> {
        self.rows.iter().find(|row| row.id == id)
    }

    fn scroll_to(&self, index: usize) {
        self.scroll.scroll_to_item(index, ScrollStrategy::Nearest);
    }

    /// The selection minus the new-item row, in row order, as (relative, is folder).
    fn selected_items(&self) -> Vec<(String, bool)> {
        self.rows
            .iter()
            .filter(|row| row.placeholder.is_none() && self.selection.contains(&row.id))
            .map(|row| (row.id.clone(), row.is_directory))
            .collect()
    }

    fn absolute(&self, relative: &str) -> Option<PathBuf> {
        self.state.as_ref().map(|state| state.absolute(relative))
    }

    // MARK: - Watching

    fn start_watching(&mut self, cx: &mut Context<Self>) {
        let Some(state) = self.state.as_ref() else { return };
        let mut paths = vec![state.root.path.clone()];
        paths.extend(state.external_git_directory.clone());
        let (sender, mut receiver) = mpsc::unbounded::<(Vec<PathBuf>, bool)>();
        self.watcher =
            FileSystemWatcher::new(paths, soprano_files::watcher::DEFAULT_LATENCY, move |paths, rescan| {
                sender.unbounded_send((paths, rescan)).ok();
            });
        self._watch_task = Some(cx.spawn(async move |this, cx| {
            while let Some((paths, rescan)) = receiver.next().await {
                if this.update(cx, |this, cx| this.handle_file_system_events(&paths, rescan, cx)).is_err() {
                    break;
                }
            }
        }));
    }

    fn handle_file_system_events(&mut self, paths: &[PathBuf], needs_rescan: bool, cx: &mut Context<Self>) {
        if !self.is_active {
            return;
        }
        let Some(state) = self.state.as_ref() else { return };
        if needs_rescan {
            self.refresh_all(cx);
            return;
        }
        let routing =
            route_events(paths, &state.roots(), state.external_git_directory.as_deref(), &self.git_status);
        self.pending_reloads.extend(routing.reload_paths);
        self.flush_pending_reloads(cx);
        if routing.changed_working_tree || routing.changed_git_directory {
            self.schedule_git_refresh(false, cx);
        }
        if routing.changed_working_tree && self.is_filtering() {
            self.schedule_filter_reload(false, cx);
        }
    }

    /// Reloads folders queued by the watcher or by operations. Held back while a name is
    /// typed or a drag is in flight, so the rows under the pointer and the caret stay put.
    fn flush_pending_reloads(&mut self, cx: &mut Context<Self>) {
        if self.editing.is_some() || self.dragging {
            return;
        }
        let paths = std::mem::take(&mut self.pending_reloads);
        for path in paths {
            let loaded = self.state.as_ref().and_then(|state| state.tree.node(&path)).is_some_and(|node| {
                node.is_directory && (node.relative_path.is_empty() || node.children.is_some())
            });
            if loaded {
                self.load_folder(&path, cx);
            }
        }
    }

    /// Reloads the root and every folder loaded so far, and re-reads git.
    fn refresh_all(&mut self, cx: &mut Context<Self>) {
        let Some(state) = self.state.as_ref() else { return };
        for folder in state.tree.loaded_folders() {
            self.load_folder(&folder, cx);
        }
        self.schedule_git_refresh(true, cx);
        if self.is_filtering() {
            self.schedule_filter_reload(true, cx);
        }
    }

    // MARK: - Git

    fn schedule_git_refresh(&mut self, immediately: bool, cx: &mut Context<Self>) {
        if !self.is_active || !self.is_git_repository() || soprano_git::reader::executable().is_none() {
            return;
        }
        let Some(delay) = self.git_gate.schedule(immediately, Instant::now()) else { return };
        self.git_timer = Some(cx.spawn(async move |this, cx| {
            if !delay.is_zero() {
                cx.background_executor().timer(delay).await;
            }
            this.update(cx, |this, cx| this.run_git_refresh(cx)).ok();
        }));
    }

    fn run_git_refresh(&mut self, cx: &mut Context<Self>) {
        let root = match self.state.as_ref() {
            Some(state) if self.is_active && state.root.is_git_repository => state.root.path.clone(),
            _ => {
                self.git_gate.cancel();
                return;
            }
        };
        self.git_gate.begin(Instant::now());
        let generation = self.generation;
        cx.spawn(async move |this, cx| {
            let snapshot =
                cx.background_executor().spawn(async move { soprano_git::reader::snapshot(&root) }).await;
            this.update(cx, |this, cx| this.finish_git_refresh(snapshot, generation, cx)).ok();
        })
        .detach();
    }

    fn finish_git_refresh(&mut self, snapshot: GitStatusSnapshot, generation: u64, cx: &mut Context<Self>) {
        let again = self.git_gate.finish();
        if generation != self.generation {
            self.schedule_git_refresh(true, cx);
            self.finish_manual_refresh_if_idle();
            return;
        }
        if snapshot != self.git_status {
            let ignored_changed = snapshot.ignored_paths != self.git_status.ignored_paths;
            self.git_status = snapshot;
            if ignored_changed && !self.prefs.shows_ignored_files() {
                self.reload_visibility();
            }
            cx.notify();
        }
        self.finish_manual_refresh_if_idle();
        if again {
            self.schedule_git_refresh(false, cx);
        }
    }

    // MARK: - Filter

    /// The "Search files" query: every word must appear in the path, in any case.
    pub fn set_filter_query(&mut self, query: &str, cx: &mut Context<Self>) {
        let tokens = filter_tokens(query);
        if tokens == self.filter_tokens {
            return;
        }
        let was_filtering = self.is_filtering();
        self.filter_tokens = tokens;
        if self.filter_tokens.is_empty() {
            self.filter_root = None;
            self.filter_generation += 1;
            self.filter_timer = None;
            if was_filtering {
                self.rebuild_rows();
            }
        } else if !was_filtering {
            // Show the last listing at once, but re-read it: files may have come and gone
            // since the previous search.
            if self.filter_files.is_some() {
                self.rebuild_filter_tree();
            } else {
                self.rebuild_rows();
            }
            self.schedule_filter_reload(true, cx);
        } else if self.filter_files.is_some() {
            self.rebuild_filter_tree();
        }
        cx.notify();
    }

    fn clear_filter(&mut self, cx: &mut Context<Self>) {
        if !self.filter_input.read(cx).value().is_empty() {
            self.with_window(cx, |this, window, cx| {
                this.filter_input.update(cx, |input, cx| input.set_value("", window, cx));
            });
        }
        self.set_filter_query("", cx);
    }

    fn schedule_filter_reload(&mut self, immediately: bool, cx: &mut Context<Self>) {
        self.filter_timer = Some(cx.spawn(async move |this, cx| {
            if !immediately {
                cx.background_executor().timer(Duration::from_millis(300)).await;
            }
            this.update(cx, |this, cx| this.load_filter_files(cx)).ok();
        }));
    }

    fn load_filter_files(&mut self, cx: &mut Context<Self>) {
        let Some(state) = self.state.as_ref() else { return };
        self.filter_generation += 1;
        let generation = self.filter_generation;
        let root = state.root.path.clone();
        let is_git = state.root.is_git_repository;
        cx.spawn(async move |this, cx| {
            let files = cx
                .background_executor()
                .spawn(async move {
                    is_git
                        .then(|| soprano_git::reader::list_files(&root))
                        .flatten()
                        .unwrap_or_else(|| enumerate_files(&root, ENUMERATED_FILE_LIMIT))
                })
                .await;
            this.update(cx, |this, cx| {
                if generation == this.filter_generation && this.is_filtering() {
                    this.filter_files = Some(files);
                    this.rebuild_filter_tree();
                    cx.notify();
                }
            })
            .ok();
        })
        .detach();
    }

    fn rebuild_filter_tree(&mut self) {
        if self.editing.is_some() {
            self.display_refresh_deferred = true;
            return;
        }
        let Some(files) = self.filter_files.as_ref() else { return };
        let Some(rules) = self.rules() else { return };
        let root = build_filter_tree(files, &self.filter_tokens, &rules);
        self.filter_root = Some(root);
        self.filter_collapsed.clear();
        self.rebuild_rows();
    }

    /// Re-reads every visible folder's rows after the visibility rules or the ignored set
    /// changed.
    fn reload_visibility(&mut self) {
        if self.editing.is_some() {
            self.display_refresh_deferred = true;
            return;
        }
        if self.is_filtering() {
            self.rebuild_filter_tree();
        } else {
            self.rebuild_rows();
        }
    }

    // MARK: - Status

    fn status(&self) -> Option<Status> {
        let Some(state) = self.state.as_ref() else {
            return Some(Status::Message("Focus a terminal pane to browse its files".to_owned()));
        };
        if self.is_filtering() {
            return match &self.filter_root {
                _ if self.filter_files.is_none() => Some(Status::Loading),
                Some(root) if !root.children.is_empty() => None,
                _ => Some(Status::Message("No files match this filter".to_owned())),
            };
        }
        let root = state.tree.node("")?;
        if let (Some(error), None) = (&root.load_error, &root.children) {
            return Some(Status::LoadError(format!("Could not load files for this workspace: {error}")));
        }
        if root.children.is_none() {
            return Some(Status::Loading);
        }
        self.rows.is_empty().then(|| Status::Message("No files in this workspace".to_owned()))
    }

    fn retry(&mut self, cx: &mut Context<Self>) {
        self.load_folder("", cx);
        cx.notify();
    }

    fn manual_refresh(&mut self, cx: &mut Context<Self>) {
        self.manual_refreshing = true;
        self.refresh_all(cx);
        // Only swap in the busy glyph for refreshes long enough to notice.
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_millis(200)).await;
            this.update(cx, |this, cx| {
                if this.manual_refreshing {
                    this.manual_refresh_spinner = true;
                    cx.notify();
                }
            })
            .ok();
        })
        .detach();
        self.finish_manual_refresh_if_idle();
    }

    fn finish_manual_refresh_if_idle(&mut self) {
        if self.manual_refreshing && self.in_flight_loads == 0 && !self.git_gate.is_in_flight() {
            self.finish_manual_refresh();
        }
    }

    fn finish_manual_refresh(&mut self) {
        self.manual_refreshing = false;
        self.manual_refresh_spinner = false;
    }

    // MARK: - Expansion

    fn set_expanded(&mut self, id: &str, expanded: bool, cx: &mut Context<Self>) {
        if self.is_filtering() {
            if expanded {
                self.filter_collapsed.remove(id);
            } else {
                self.filter_collapsed.insert(id.to_owned());
            }
            self.rebuild_rows();
            cx.notify();
            return;
        }
        let Some(state) = self.state.as_mut() else { return };
        if expanded {
            if state.tree.expand(id) {
                self.load_folder(id, cx);
            }
        } else {
            state.tree.collapse(id);
        }
        self.rebuild_rows();
        cx.notify();
    }

    /// Opens or closes the folder at `id` (relative path).
    pub fn toggle_folder(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(row) = self.row(id).filter(|row| row.is_directory && row.placeholder.is_none()) else {
            return;
        };
        let expanded = row.is_expanded;
        self.set_expanded(id, !expanded, cx);
    }

    /// Collapse All: does nothing while the filter shows results.
    fn collapse_all(&mut self, cx: &mut Context<Self>) {
        if self.is_filtering() {
            return;
        }
        if let Some(state) = self.state.as_mut() {
            state.tree.collapse_all();
        }
        self.restore_expansions.clear();
        self.rebuild_rows();
        cx.notify();
    }

    fn collapse_subtree(&mut self, id: &str, cx: &mut Context<Self>) {
        if let Some(state) = self.state.as_mut() {
            state.tree.collapse_subtree(id);
        }
        self.rebuild_rows();
        cx.notify();
    }

    fn can_collapse_all(&self) -> bool {
        !self.is_filtering()
            && self.state.as_ref().is_some_and(|state| !state.tree.expanded_paths().is_empty())
    }

    // MARK: - Selection

    fn apply_pending_selection(&mut self) {
        if self.pending_selection.is_empty() {
            return;
        }
        let Some(state) = self.state.as_mut() else { return };
        if !self.pending_selection.iter().all(|path| state.tree.node(path).is_some()) {
            return;
        }
        let paths = std::mem::take(&mut self.pending_selection);
        // Reveal: open the folders above each new item first.
        for path in &paths {
            let mut ancestors = Vec::new();
            let mut parent = parent_path(path);
            while !parent.is_empty() {
                ancestors.push(parent.to_owned());
                parent = parent_path(parent);
            }
            for folder in ancestors.into_iter().rev() {
                state.tree.expand(&folder);
            }
        }
        self.rebuild_rows();
        let ids = self.row_ids();
        let mut selection = self.selection.clone();
        selection.select_all_of(&paths, &ids);
        let first = paths.first().and_then(|path| ids.iter().position(|id| id == path));
        self.selection = selection;
        if let Some(index) = first {
            self.scroll_to(index);
        }
    }

    // MARK: - Actions

    fn activate(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(row) = self.row(id).filter(|row| row.placeholder.is_none()).cloned() else { return };
        if row.is_directory {
            self.toggle_folder(id, cx);
        } else if let Some(path) = self.absolute(id) {
            cx.emit(SidebarEvent::OpenFile { path, preview: true, focus: true });
        }
    }

    fn trash_selection(&mut self, cx: &mut Context<Self>) {
        let items = self.selected_items();
        let paths: Vec<PathBuf> = top_level_selection(&items)
            .iter()
            .filter(|id| !id.is_empty())
            .filter_map(|id| self.absolute(id))
            .collect();
        if paths.is_empty() {
            return;
        }
        let result = self.operations.trash(&paths);
        self.report(result.map(|_| ()), cx);
        self.drain_operation_events(cx);
    }

    fn copy_paths(&mut self, relative: bool, cx: &mut Context<Self>) {
        let items: Vec<(PathBuf, String)> = self
            .selected_items()
            .into_iter()
            .filter_map(|(id, _)| self.absolute(&id).map(|path| (path, id)))
            .collect();
        if items.is_empty() {
            return;
        }
        cx.write_to_clipboard(ClipboardItem::new_string(copied_paths(&items, relative)));
    }

    fn copy_files(&mut self, cx: &mut Context<Self>) {
        let paths: Vec<PathBuf> =
            self.selected_items().into_iter().filter_map(|(id, _)| self.absolute(&id)).collect();
        if paths.is_empty() {
            return;
        }
        if !file_clipboard::copy_files(&paths) {
            let text = paths.iter().map(|path| path.to_string_lossy()).collect::<Vec<_>>().join("\n");
            cx.write_to_clipboard(ClipboardItem::new_string(text));
        }
    }

    fn duplicate(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(path) = self.absolute(id) else { return };
        match self.operations.duplicate(&path) {
            Ok(copy) => {
                if let Some(relative) = self.state.as_ref().and_then(|state| state.relative(&copy)) {
                    self.pending_selection = vec![relative];
                }
            }
            Err(error) => self.show_error(&error, cx),
        }
        self.drain_operation_events(cx);
    }

    fn reveal_selection(&mut self, cx: &mut Context<Self>) {
        let paths: Vec<PathBuf> =
            self.selected_items().into_iter().filter_map(|(id, _)| self.absolute(&id)).collect();
        if let Err(error) = crate::reveal::reveal(&paths) {
            cx.emit(SidebarEvent::ShowError(error.to_string()));
        }
    }

    /// ⌘Z in the tree.
    pub fn undo(&mut self, cx: &mut Context<Self>) {
        self.operations.undo();
        self.drain_operation_events(cx);
    }

    /// ⇧⌘Z in the tree.
    pub fn redo(&mut self, cx: &mut Context<Self>) {
        self.operations.redo();
        self.drain_operation_events(cx);
    }

    /// Renames the item at `path` (an absolute path in the shown root) to `name`.
    pub fn rename(
        &mut self,
        path: &Path,
        name: &str,
        cx: &mut Context<Self>,
    ) -> Result<PathBuf, OperationError> {
        let result = self.operations.rename(path, name);
        self.drain_operation_events(cx);
        result
    }

    fn report(&mut self, result: Result<(), OperationError>, cx: &mut Context<Self>) {
        if let Err(error) = result {
            self.show_error(&error, cx);
        }
    }

    fn show_error(&mut self, error: &OperationError, cx: &mut Context<Self>) {
        cx.emit(SidebarEvent::ShowError(error.to_string()));
    }

    fn drain_operation_events(&mut self, cx: &mut Context<Self>) {
        let events = std::mem::take(&mut *self.operation_events.borrow_mut());
        let mut directories_changed = false;
        for event in events {
            match event {
                OperationEvent::DirectoriesChanged(directories) => {
                    directories_changed = true;
                    if let Some(state) = self.state.as_ref() {
                        self.pending_reloads.extend(directories.iter().filter_map(|dir| state.relative(dir)));
                    }
                }
                OperationEvent::UndoFailure(message) => cx.emit(SidebarEvent::ShowError(message)),
                OperationEvent::ItemMoved(from, to) => {
                    // Rename, move, undo and redo alike: an open folder stays open.
                    if let Some(state) = self.state.as_mut()
                        && let (Some(old), Some(new)) = (state.relative(&from), state.relative(&to))
                    {
                        state.tree.move_expanded_paths(&old, &new);
                        self.selection.rename(&old, &new);
                    }
                    cx.emit(SidebarEvent::ItemMoved { from, to });
                }
            }
        }
        if directories_changed {
            self.flush_pending_reloads(cx);
            self.schedule_git_refresh(false, cx);
            if self.is_filtering() {
                self.schedule_filter_reload(true, cx);
            }
        }
        cx.notify();
    }

    // MARK: - Inline create and rename

    /// The folder new items go into when `id` is the context: the folder itself, or a
    /// file's parent.
    fn containing_folder(&self, id: &str) -> String {
        match self.row(id) {
            Some(row) if row.is_directory => id.to_owned(),
            _ => parent_path(id).to_owned(),
        }
    }

    fn begin_create(&mut self, kind: EntryKind, folder: String, window: &mut Window, cx: &mut Context<Self>) {
        if self.editing.is_some() || self.state.is_none() {
            return;
        }
        // A folder picked from filter results may never have been loaded in the real
        // tree; the filter clears and the path opens down to it.
        if self.is_filtering() {
            self.filter_input.update(cx, |input, cx| input.set_value("", window, cx));
            self.set_filter_query("", cx);
        }
        self.pending_reveal = Some((folder, kind));
        self.continue_reveal(window, cx);
    }

    /// Walks `pending_reveal` down the real tree, opening each folder and waiting for
    /// listings that are not loaded yet (each finished load calls back here), then puts
    /// the new-item row into the target folder.
    fn continue_reveal(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some((path, kind)) = self.pending_reveal.clone() else { return };
        let Some(state) = self.state.as_mut() else { return };
        let Some(root) = state.tree.node("") else { return };
        if root.children.is_none() {
            if root.load_error.is_some() {
                self.pending_reveal = None;
            } else if !root.is_loading() {
                self.load_folder("", cx);
            }
            return;
        }
        let mut folder = String::new();
        for segment in path.split('/').filter(|segment| !segment.is_empty()) {
            let child = child_path(&folder, segment);
            let Some(node) = state.tree.node(&child).filter(|node| node.is_directory) else {
                self.pending_reveal = None;
                return;
            };
            let loaded = node.children.is_some();
            let loading = node.is_loading();
            state.tree.expand(&child);
            if !loaded {
                if !loading {
                    self.load_folder(&child, cx);
                }
                self.rebuild_rows();
                return;
            }
            folder = child;
        }
        self.pending_reveal = None;
        self.insert_placeholder(kind, folder, window, cx);
    }

    fn insert_placeholder(
        &mut self,
        kind: EntryKind,
        folder: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.editing.is_some() {
            return;
        }
        if !folder.is_empty()
            && let Some(state) = self.state.as_mut()
        {
            state.tree.expand(&folder);
        }
        self.rebuild_rows();
        let rows = self.compute_rows(Some((&folder, kind)));
        let id = placeholder_id(&folder);
        let Some(index) = rows.iter().position(|row| row.id == id) else { return };
        self.rows = rows;
        self.selection.select(&id);
        self.scroll_to(index);
        self.begin_editing(EditTarget::Create { folder, kind }, "", None, window, cx);
    }

    fn begin_rename(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        if self.editing.is_some() || id.is_empty() {
            return;
        }
        let Some(row) = self.row(id).filter(|row| row.placeholder.is_none()).cloned() else { return };
        let Some(path) = self.absolute(id) else { return };
        let Some(index) = self.rows.iter().position(|candidate| candidate.id == id) else { return };
        self.selection.select(id);
        self.scroll_to(index);
        let original = row.name.to_string();
        let range = stem_range(&original);
        self.begin_editing(
            EditTarget::Rename { id: id.to_owned(), original: original.clone(), path },
            &original,
            Some(range),
            window,
            cx,
        );
    }

    fn begin_editing(
        &mut self,
        target: EditTarget,
        text: &str,
        selection: Option<std::ops::Range<usize>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let text = text.to_owned();
        let input = cx.new(|cx| {
            let mut input = InputState::new(window, cx);
            input.set_value(text.clone(), window, cx);
            if let Some(range) = selection {
                input.set_selected_range(range, cx);
            }
            input
        });
        input.update(cx, |input, cx| input.focus(window, cx));
        let subscription =
            cx.subscribe_in(&input, window, |this, _, event: &InputEvent, window, cx| match event {
                InputEvent::PressEnter { .. } => this.finish_editing(true, cx),
                InputEvent::Focus => {
                    if let Some(editing) = this.editing.as_mut() {
                        editing.has_focus = true;
                    }
                }
                // Clicking elsewhere commits the name; switching to another app does not.
                InputEvent::Blur if window.is_window_active() => {
                    if let Some(editing) = this.editing.as_mut() {
                        editing.has_focus = false;
                    }
                    this.finish_editing(true, cx);
                }
                _ => {}
            });
        self.editing = Some(Editing { target, input, has_focus: true, _subscription: subscription });
        cx.notify();
    }

    fn finish_editing(&mut self, commit: bool, cx: &mut Context<Self>) {
        let Some(editing) = self.editing.take() else { return };
        let text = editing.input.read(cx).value().to_string();
        // The keyboard returns to the tree only from the field itself (Return, Esc).
        if editing.has_focus {
            self.focus_tree_on_render = true;
        }
        match editing.target {
            EditTarget::Create { folder, kind } => {
                if commit
                    && let Some(name) = committed_name(&text, None)
                    && let Some(directory) = self.absolute(&folder)
                {
                    let result = match kind {
                        EntryKind::File => self.operations.create_file(&name, &directory),
                        EntryKind::Folder => self.operations.create_folder(&name, &directory),
                    };
                    match result {
                        Ok(created) => {
                            let created_name = created
                                .file_name()
                                .map(|name| name.to_string_lossy().into_owned())
                                .unwrap_or(name);
                            self.pending_selection = vec![child_path(&folder, &created_name)];
                            if kind == EntryKind::File {
                                cx.emit(SidebarEvent::OpenFile {
                                    path: created,
                                    preview: false,
                                    focus: false,
                                });
                            }
                        }
                        Err(error) => self.show_error(&error, cx),
                    }
                }
            }
            EditTarget::Rename { id, original, path } => {
                if commit && let Some(name) = committed_name(&text, Some(&original)) {
                    match self.operations.rename(&path, &name) {
                        Ok(renamed) => {
                            let new_name = renamed
                                .file_name()
                                .map(|name| name.to_string_lossy().into_owned())
                                .unwrap_or(name);
                            self.pending_selection = vec![child_path(parent_path(&id), &new_name)];
                        }
                        Err(error) => self.show_error(&error, cx),
                    }
                }
            }
        }
        // Changes held back while typing apply now; otherwise the rows (and folders the
        // user collapsed in filter results) stay as they are.
        if std::mem::take(&mut self.display_refresh_deferred) {
            self.reload_visibility();
        } else {
            self.rebuild_rows();
        }
        self.drain_operation_events(cx);
        self.flush_pending_reloads(cx);
        self.apply_pending_selection();
        cx.notify();
    }

    // MARK: - Drag and drop

    fn drop_paths(
        &mut self,
        folder: String,
        sources: Vec<PathBuf>,
        from_explorer: bool,
        copy_modifier: bool,
        cx: &mut Context<Self>,
    ) {
        if self.editing.is_some() {
            return;
        }
        let Some(target) = self.absolute(&folder) else { return };
        let targets: Vec<PathBuf> = match drop_operation(&target, &sources, from_explorer, copy_modifier) {
            DropOperation::None => return,
            DropOperation::Move => match self.operations.move_items(&sources, &target) {
                Ok(moved) => moved.into_iter().map(|(_, target)| target).collect(),
                Err(error) => {
                    self.show_error(&error, cx);
                    Vec::new()
                }
            },
            DropOperation::Copy => match self.operations.copy_items(&sources, &target) {
                Ok(copied) => copied,
                Err(error) => {
                    self.show_error(&error, cx);
                    Vec::new()
                }
            },
        };
        if let Some(state) = self.state.as_mut() {
            self.pending_selection = targets.iter().filter_map(|path| state.relative(path)).collect();
        }
        if !folder.is_empty() {
            self.set_expanded(&folder, true, cx);
        }
        self.drag_hover = None;
        self.drain_operation_events(cx);
        self.rebuild_rows();
    }

    /// Hovering a drag over a collapsed folder for half a second opens it.
    fn drag_hovered(&mut self, folder: String, cx: &mut Context<Self>) {
        let expanded = self.row(&folder).is_none_or(|row| row.is_expanded);
        if folder.is_empty() || expanded {
            self.drag_hover = None;
            return;
        }
        if self.drag_hover.as_ref().is_some_and(|hover| hover.folder == folder) {
            return;
        }
        let target = folder.clone();
        let timer = cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_millis(500)).await;
            this.update(cx, |this, cx| {
                if this.drag_hover.as_ref().is_some_and(|hover| hover.folder == target) {
                    this.drag_hover = None;
                    this.set_expanded(&target, true, cx);
                }
            })
            .ok();
        });
        self.drag_hover = Some(DragHover { folder, _timer: timer });
    }

    /// The pointer left `folder` during a drag: it no longer springs open.
    fn drag_left(&mut self, folder: &str) {
        if self.drag_hover.as_ref().is_some_and(|hover| hover.folder == folder) {
            self.drag_hover = None;
        }
    }

    fn drag_ended(&mut self, cx: &mut Context<Self>) {
        self.dragging = false;
        self.drag_hover = None;
        self.flush_pending_reloads(cx);
    }

    /// What a drag starting on a selected row carries: the selection's top-level items.
    /// Computed once per frame, not per row.
    fn selection_drag_items(&self) -> Vec<(PathBuf, bool)> {
        let selected = self.selected_items();
        let top: HashSet<String> = top_level_selection(&selected).into_iter().collect();
        selected
            .into_iter()
            .filter(|(id, _)| top.contains(id))
            .filter_map(|(id, is_dir)| self.absolute(&id).map(|path| (path, is_dir)))
            .collect()
    }

    /// The items a drag starting on `id` carries: the selection when `id` is in it.
    fn drag_items(&self, id: &str, selection_items: &[(PathBuf, bool)]) -> Vec<(PathBuf, bool)> {
        if self.selection.contains(id) {
            return selection_items.to_vec();
        }
        self.row(id)
            .and_then(|row| self.absolute(&row.id).map(|path| (path, row.is_directory)))
            .into_iter()
            .collect()
    }

    /// Whether dropping `sources` on `folder` would do anything (refused targets don't
    /// highlight).
    fn accepts_drop(&self, folder: &str, sources: &[PathBuf], from_explorer: bool, copy: bool) -> bool {
        self.editing.is_none()
            && self.absolute(folder).is_some_and(|target| {
                drop_operation(&target, sources, from_explorer, copy) != DropOperation::None
            })
    }

    // MARK: - Clicks

    fn row_clicked(&mut self, id: &str, event: &ClickEvent, window: &mut Window, cx: &mut Context<Self>) {
        let Some(row) = self.row(id).cloned() else { return };
        if row.placeholder.is_some() {
            return;
        }
        if event.click_count() >= 2 {
            // A second click keeps the preview opened by the first.
            if !row.is_directory
                && let Some(path) = self.absolute(id)
            {
                cx.emit(SidebarEvent::OpenFile { path, preview: false, focus: true });
            }
            return;
        }
        let modifiers = event.modifiers();
        let ids = self.row_ids().into_iter().map(str::to_owned).collect::<Vec<_>>();
        let ids: Vec<&str> = ids.iter().map(String::as_str).collect();
        // ⌘ and ⇧ clicks only change the selection.
        if chords::is_toggle_click(&modifiers) {
            self.selection.toggle(id);
        } else if modifiers.shift {
            self.selection.extend_to(id, &ids);
        } else {
            self.selection.select(id);
            if row.is_directory {
                self.toggle_folder(id, cx);
            } else if let Some(path) = self.absolute(id) {
                cx.emit(SidebarEvent::OpenFile { path, preview: true, focus: true });
            }
        }
        window.focus(&self.focus_handle, cx);
        cx.notify();
    }

    fn empty_space_clicked(&mut self, event: &ClickEvent, window: &mut Window, cx: &mut Context<Self>) {
        window.focus(&self.focus_handle, cx);
        // Double-clicking empty space creates a file at the top of the project.
        if event.click_count() >= 2 && self.state.is_some() {
            self.begin_create(EntryKind::File, String::new(), window, cx);
        } else {
            self.selection.clear();
        }
        cx.notify();
    }

    // MARK: - Context menu

    fn open_context_menu(
        &mut self,
        clicked: Option<String>,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.state.is_none() || self.editing.is_some() {
            return;
        }
        let items = self.context_menu_items(clicked, cx);
        let menu = ContextMenu::new(position, items, window, cx);
        let subscription = cx.subscribe(&menu, |this, _, _: &gpui::DismissEvent, cx| {
            this.context_menu = None;
            cx.notify();
        });
        self.context_menu = Some((menu, subscription));
        cx.notify();
    }

    fn context_menu_items(&mut self, clicked: Option<String>, cx: &mut Context<Self>) -> Vec<MenuItem> {
        let this = cx.entity().downgrade();
        let action = move |f: fn(&mut Self, &mut Window, &mut Context<Self>)| {
            let this = this.clone();
            move |window: &mut Window, cx: &mut App| {
                this.update(cx, |panel, cx| f(panel, window, cx)).ok();
            }
        };
        let mut items = Vec::new();
        let clicked = clicked.filter(|id| self.row(id).is_some_and(|row| row.placeholder.is_none()));
        let Some(clicked) = clicked else {
            items.push(Self::create_item(EntryKind::File, String::new(), cx));
            items.push(Self::create_item(EntryKind::Folder, String::new(), cx));
            return items;
        };
        // Right-clicking outside the selection acts on just that row.
        if !self.selection.contains(&clicked) {
            self.selection.select(&clicked);
        }
        let nodes = self.selected_items();
        let single = (nodes.len() == 1).then(|| nodes[0].clone());
        let plural = nodes.len() > 1;
        let folder = self.containing_folder(&clicked);
        items.push(Self::create_item(EntryKind::File, folder.clone(), cx));
        items.push(Self::create_item(EntryKind::Folder, folder, cx));
        items.push(MenuItem::separator());
        if nodes.len() == 1 {
            items.push(
                MenuItem::new("Copy")
                    .icon(IconName::Copy)
                    .shortcut(Chord::CMD.label("C"))
                    .on_select(action(|this, _, cx| this.copy_files(cx))),
            );
        }
        items.push(
            MenuItem::new(if plural { "Copy Paths" } else { "Copy Path" })
                .shortcut(Chord::CMD_OPTION.label("C"))
                .on_select(action(|this, _, cx| this.copy_paths(false, cx))),
        );
        items.push(
            MenuItem::new(if plural { "Copy Relative Paths" } else { "Copy Relative Path" })
                .shortcut(Chord::CMD_SHIFT_OPTION.label("C"))
                .on_select(action(|this, _, cx| this.copy_paths(true, cx))),
        );
        if let Some((id, is_directory)) = single.clone() {
            let path = self.absolute(&id).unwrap_or_default();
            let entity = cx.entity().downgrade();
            if !is_directory {
                let (this, target) = (entity.clone(), id.clone());
                items.push(MenuItem::new("Duplicate").on_select(move |_, cx: &mut App| {
                    this.update(cx, |panel, cx| panel.duplicate(&target, cx)).ok();
                }));
            } else {
                let (this, directory) = (entity.clone(), path.clone());
                items.push(MenuItem::new("Open in Terminal").icon(IconName::Terminal).on_select(
                    move |_, cx: &mut App| {
                        this.update(cx, |_, cx| {
                            cx.emit(SidebarEvent::OpenInTerminal { directory: directory.clone() })
                        })
                        .ok();
                    },
                ));
            }
            if !is_directory {
                let (this, file) = (entity.clone(), path.clone());
                items.push(MenuItem::new("Open").on_select(move |_, cx: &mut App| {
                    this.update(cx, |_, cx| {
                        cx.emit(SidebarEvent::OpenFile { path: file.clone(), preview: false, focus: true })
                    })
                    .ok();
                }));
                let (this, file) = (entity.clone(), path.clone());
                items.push(MenuItem::new("Open with Default App").icon(IconName::ExternalLink).on_select(
                    move |_, cx: &mut App| {
                        if let Err(error) = soprano_platform::system::open_default(&file.to_string_lossy()) {
                            this.update(cx, |_, cx| cx.emit(SidebarEvent::ShowError(error.to_string()))).ok();
                        }
                    },
                ));
                if is_markdown(&path) {
                    let (this, file) = (entity.clone(), path.clone());
                    items.push(MenuItem::new("Open Markdown Preview").on_select(move |_, cx: &mut App| {
                        this.update(cx, |_, cx| {
                            cx.emit(SidebarEvent::OpenMarkdownPreview { path: file.clone() })
                        })
                        .ok();
                    }));
                }
            }
            if is_directory && !self.is_filtering() && self.row(&id).is_some_and(|row| row.is_expanded) {
                let (this, target) = (entity.clone(), id.clone());
                items.push(MenuItem::new("Collapse Folder").on_select(move |_, cx: &mut App| {
                    this.update(cx, |panel, cx| panel.collapse_subtree(&target, cx)).ok();
                }));
            }
        }
        items.push(
            MenuItem::new(soprano_platform::system::reveal_label())
                .on_select(action(|this, _, cx| this.reveal_selection(cx))),
        );
        items.push(MenuItem::separator());
        if let Some((id, _)) = single {
            let this = cx.entity().downgrade();
            items.push(
                MenuItem::new("Rename")
                    .icon(IconName::SquarePen)
                    .shortcut(if cfg!(target_os = "macos") { "↩" } else { "Enter" })
                    .on_select(move |window, cx: &mut App| {
                        this.update(cx, |panel, cx| panel.begin_rename(&id, window, cx)).ok();
                    }),
            );
        }
        items.push(
            MenuItem::new("Delete")
                .icon(IconName::Trash)
                .shortcut(Chord::CMD.label("⌫"))
                .on_select(action(|this, _, cx| this.trash_selection(cx))),
        );
        items
    }

    fn create_item(kind: EntryKind, folder: String, cx: &mut Context<Self>) -> MenuItem {
        let this = cx.entity().downgrade();
        let (title, glyph) = match kind {
            EntryKind::File => ("New File", IconName::FilePlus),
            EntryKind::Folder => ("New Folder", IconName::FolderPlus),
        };
        MenuItem::new(title).icon(glyph).on_select(move |window, cx: &mut App| {
            this.update(cx, |panel, cx| panel.begin_create(kind, folder.clone(), window, cx)).ok();
        })
    }

    /// The ⋯ menu: dotfiles, ignored files, and "Open in" the installed applications.
    fn open_more_menu(&mut self, position: Point<Pixels>, window: &mut Window, cx: &mut Context<Self>) {
        let Some(state) = self.state.as_ref() else { return };
        let root = state.root.path.clone();
        let is_git = state.root.is_git_repository;
        let this = cx.entity().downgrade();
        let mut items =
            vec![MenuItem::new("Show Dotfiles").checked(self.prefs.shows_dotfiles(&root)).on_select({
                let this = this.clone();
                let root = root.clone();
                move |_, cx: &mut App| {
                    this.update(cx, |panel, cx| {
                        panel.prefs.toggle_dotfiles(&root);
                        panel.reload_visibility();
                        cx.notify();
                    })
                    .ok();
                }
            })];
        if is_git {
            let this = this.clone();
            items.push(
                MenuItem::new("Show Git Ignored Files").checked(self.prefs.shows_ignored_files()).on_select(
                    move |_, cx: &mut App| {
                        this.update(cx, |panel, cx| {
                            panel.prefs.toggle_ignored_files();
                            panel.reload_visibility();
                            cx.notify();
                        })
                        .ok();
                    },
                ),
            );
        }
        let applications = open_in::installed_applications();
        if !applications.is_empty() {
            items.push(MenuItem::separator());
            items.push(MenuItem::header("Open in"));
            for application in applications {
                let this = this.clone();
                let root = root.clone();
                items.push(MenuItem::new(application.name.clone()).on_select(move |_, cx: &mut App| {
                    if application.open(&root).is_err() {
                        this.update(cx, |_, cx| {
                            cx.emit(SidebarEvent::ShowError("Could not open workspace folder.".to_owned()))
                        })
                        .ok();
                    }
                }));
            }
        }
        let menu = ContextMenu::new(position, items, window, cx);
        let subscription = cx.subscribe(&menu, |this, _, _: &gpui::DismissEvent, cx| {
            this.context_menu = None;
            cx.notify();
        });
        self.context_menu = Some((menu, subscription));
        cx.notify();
    }

    // MARK: - Keyboard

    fn key_down(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        // Keys typed into the filter or an inline name belong to those fields.
        if !self.focus_handle.is_focused(window) || self.editing.is_some() {
            return;
        }
        let keystroke = &event.keystroke;
        let modifiers = &keystroke.modifiers;
        let plain = chords::is_plain(modifiers);
        let shift_only = modifiers.shift && !modifiers.control && !modifiers.alt && !modifiers.platform;
        let ids: Vec<String> = self.rows.iter().map(|row| row.id.clone()).collect();
        let ids: Vec<&str> = ids.iter().map(String::as_str).collect();
        let lead = self.selection.lead().map(str::to_owned);
        let mut scroll_target = None;
        match keystroke.key.as_str() {
            // Finder-style rename.
            "enter" if plain => {
                let selected = self.selected_items();
                if let [(id, _)] = selected.as_slice() {
                    let id = id.clone();
                    self.begin_rename(&id, window, cx);
                }
            }
            "space" if plain => {
                if let Some(lead) = lead {
                    self.activate(&lead, cx);
                }
            }
            "escape" => cx.emit(SidebarEvent::FocusPane),
            "backspace" if Chord::CMD.matches(modifiers) => self.trash_selection(cx),
            "delete" if plain => self.trash_selection(cx),
            "left" if plain => {
                if let Some(lead) = lead {
                    self.collapse_or_select_parent(&lead, cx);
                }
            }
            "right" if plain => {
                if let Some(lead) = lead {
                    self.expand_or_select_first_child(&lead, cx);
                }
            }
            "up" if plain || shift_only => scroll_target = self.selection.move_by(-1, modifiers.shift, &ids),
            "down" if plain || shift_only => scroll_target = self.selection.move_by(1, modifiers.shift, &ids),
            "home" => scroll_target = self.selection.move_to(0, modifiers.shift, &ids),
            "end" => scroll_target = self.selection.move_to(ids.len() as isize - 1, modifiers.shift, &ids),
            "pageup" => {
                scroll_target =
                    self.selection.move_by(-Selection::page_step(ids.len()), modifiers.shift, &ids)
            }
            "pagedown" => {
                scroll_target = self.selection.move_by(Selection::page_step(ids.len()), modifiers.shift, &ids)
            }
            "c" if Chord::CMD.matches(modifiers) => self.copy_files(cx),
            "c" if Chord::CMD_OPTION.matches(modifiers) => self.copy_paths(false, cx),
            "c" if Chord::CMD_SHIFT_OPTION.matches(modifiers) => self.copy_paths(true, cx),
            "a" if Chord::CMD.matches(modifiers) => {
                let all: Vec<String> = ids.iter().map(|id| (*id).to_owned()).collect();
                self.selection.select_all_of(&all, &ids);
            }
            "z" if Chord::CMD.matches(modifiers) => self.undo(cx),
            "z" if Chord::CMD_SHIFT.matches(modifiers) => self.redo(cx),
            key if (plain || shift_only)
                && keystroke.key_char.as_ref().is_some_and(|c| !c.trim().is_empty()) =>
            {
                let typed = keystroke.key_char.clone().unwrap_or_else(|| key.to_owned());
                scroll_target = self.type_select(&typed);
            }
            _ => return,
        }
        if let Some(index) = scroll_target {
            self.scroll_to(index);
        }
        cx.stop_propagation();
        cx.notify();
    }

    /// Type-select: typed letters jump to the first row whose name starts with them.
    fn type_select(&mut self, typed: &str) -> Option<usize> {
        let now = Instant::now();
        let (buffer, last) = &mut self.type_select;
        if last.is_none_or(|last| now.duration_since(last) > Duration::from_secs(1)) {
            buffer.clear();
        }
        buffer.push_str(&typed.to_lowercase());
        *last = Some(now);
        let prefix = buffer.clone();
        let index = self.rows.iter().position(|row| row.name.to_lowercase().starts_with(&prefix))?;
        let id = self.rows[index].id.clone();
        self.selection.select(&id);
        Some(index)
    }

    /// ←: closes an open folder, else selects the row's parent.
    fn collapse_or_select_parent(&mut self, lead: &str, cx: &mut Context<Self>) {
        let Some(row) = self.row(lead).cloned() else { return };
        if row.is_directory && row.is_expanded {
            self.set_expanded(lead, false, cx);
            return;
        }
        let parent = parent_path(lead).to_owned();
        if let Some(index) = self.rows.iter().position(|row| row.id == parent) {
            self.selection.select(&parent);
            self.scroll_to(index);
        }
    }

    /// →: opens a closed folder, else selects its first child.
    fn expand_or_select_first_child(&mut self, lead: &str, cx: &mut Context<Self>) {
        let Some(index) = self.rows.iter().position(|row| row.id == lead) else { return };
        let row = self.rows[index].clone();
        if !row.is_directory || row.placeholder.is_some() {
            return;
        }
        if !row.is_expanded {
            self.set_expanded(lead, true, cx);
            return;
        }
        if let Some(child) = self.rows.get(index + 1).filter(|child| child.depth == row.depth + 1) {
            let id = child.id.clone();
            self.selection.select(&id);
            self.scroll_to(index + 1);
        }
    }
}

/// File operations whose callbacks queue their events for [`FilesPanel::drain_operation_events`].
fn make_operations(events: &Rc<RefCell<Vec<OperationEvent>>>) -> FileExplorerOperations {
    let mut operations = FileExplorerOperations::new();
    let queue = events.clone();
    operations.on_directories_changed = Some(Box::new(move |directories| {
        queue.borrow_mut().push(OperationEvent::DirectoriesChanged(directories.iter().cloned().collect()));
    }));
    let queue = events.clone();
    operations.on_undo_failure = Some(Box::new(move |error| {
        queue.borrow_mut().push(OperationEvent::UndoFailure(error.to_string()));
    }));
    let queue = events.clone();
    operations.on_item_moved = Some(Box::new(move |from, to| {
        queue.borrow_mut().push(OperationEvent::ItemMoved(from.to_path_buf(), to.to_path_buf()));
    }));
    operations
}

/// `can_drop` for a row or the empty tree: explorer rows (moved, or copied with ⌥) and
/// files from outside (copied), unless the drop would do nothing.
fn accepts_drop(
    panel: &gpui::WeakEntity<FilesPanel>,
    folder: &str,
    value: &dyn std::any::Any,
    window: &mut Window,
    cx: &mut App,
) -> bool {
    let Some(panel) = panel.upgrade() else { return false };
    let id = panel.entity_id();
    let panel = panel.read(cx);
    if let Some(drag) = value.downcast_ref::<ExplorerDrag>() {
        let copy = chords::is_copy_drag(&window.modifiers());
        panel.accepts_drop(folder, &drag.paths(), drag.source == id, copy)
    } else if let Some(paths) = value.downcast_ref::<ExternalPaths>() {
        panel.accepts_drop(folder, paths.paths(), false, false)
    } else {
        false
    }
}

fn is_markdown(path: &Path) -> bool {
    path.extension().is_some_and(|extension| {
        let extension = extension.to_string_lossy().to_lowercase();
        extension == "md" || extension == "markdown"
    })
}

/// What a dragged explorer row looks like under the pointer: its name in a small chip.
struct DragPreview {
    label: SharedString,
}

impl Render for DragPreview {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.soprano_theme();
        div()
            .px(t.z(8.))
            .py(t.z(4.))
            .rounded(t.z(7.))
            .bg(t.popover)
            .border_1()
            .border_color(t.border)
            .text_size(t.z(size::ROW))
            .text_color(t.foreground)
            .child(self.label.clone())
    }
}

// MARK: - Rendering

impl FilesPanel {
    fn render_row(
        &self,
        index: usize,
        t: &SopranoTheme,
        focused: bool,
        selection_items: &[(PathBuf, bool)],
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let row = &self.rows[index];
        let id = row.id.clone();
        let selected = self.selection.contains(&row.id);
        let status =
            row.placeholder.is_none().then(|| self.git_status.status(&row.id, row.is_directory)).flatten();
        let ignored = row.placeholder.is_none() && self.git_status.is_ignored(&row.id);
        let editing = self.editing.as_ref().filter(|editing| match &editing.target {
            EditTarget::Rename { id, .. } => *id == row.id,
            EditTarget::Create { .. } => row.placeholder.is_some(),
        });
        let glyph = if row.is_symlink {
            soprano_ui::icons::SYMLINK_ICON
        } else if row.is_directory {
            folder_icon(row.is_expanded)
        } else {
            file_type_icon(&row.name)
        };
        let chevron: gpui::AnyElement = if row.is_directory && row.placeholder.is_none() {
            icon(if row.is_expanded { IconName::ChevronDown } else { IconName::ChevronRight })
                .size(12.)
                .color(t.dim)
                .into_any_element()
        } else {
            div().flex_none().size(t.z(12.)).into_any_element()
        };
        let fill = if selected { Some(if focused { t.selected } else { t.hover }) } else { None };
        let name: gpui::AnyElement = match editing {
            Some(editing) => div()
                .flex_1()
                .min_w_0()
                .child(Input::new(&editing.input).appearance(false).h(t.z(22.)))
                .rounded(t.z(6.))
                .border_1()
                .border_color(t.accent)
                .bg(t.background)
                .px(t.z(4.))
                .into_any_element(),
            None => div()
                .flex_1()
                .min_w_0()
                .truncate()
                .when(ignored && status.is_none(), |name| name.text_color(t.dim).italic())
                .child(row.name.clone())
                .into_any_element(),
        };
        let letter = status.map(|status| {
            div()
                .flex_none()
                .text_size(t.z(size::SMALL))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(ui::status_color(t, status, false))
                .child(status.letter())
        });
        let hover = t.hover;
        let drop_fill = t.hover;
        let drop_edge = t.input;
        let folder = drop_folder(Some((&row.id, row.is_directory)));
        let is_placeholder = row.placeholder.is_some();
        let tooltip: SharedString = row.id.clone().into();
        let mut element = div()
            .id(SharedString::from(format!("files-row-{}", row.id)))
            .flex()
            .items_center()
            .h(t.z(28.))
            .pl(t.z(8. + row.depth as f32 * 18.))
            .pr(t.z(8.))
            .gap(t.z(7.))
            .rounded(t.z(7.))
            .when_some(fill, |row, fill| row.bg(fill))
            .when(fill.is_none(), |row| row.hover(move |style| style.bg(hover)))
            .child(chevron)
            .child(icon(glyph).size(14.).color(if row.is_loading { t.dim } else { t.muted }))
            .child(name)
            .children(letter);
        if is_placeholder {
            return element.into_any_element();
        }
        let source = cx.entity_id();
        let items = self.drag_items(&row.id, selection_items);
        let label: SharedString = match items.as_slice() {
            [(path, _)] => {
                path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default().into()
            }
            items => format!("{} items", items.len()).into(),
        };
        let weak = cx.entity().downgrade();
        element = element
            .tooltip(soprano_ui::tooltip::tooltip(tooltip))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, event: &MouseDownEvent, window, cx| {
                    window.focus(&this.focus_handle, cx);
                    let _ = event;
                }),
            )
            .on_mouse_down(MouseButton::Right, {
                let id = id.clone();
                cx.listener(move |this, event: &MouseDownEvent, window, cx| {
                    cx.stop_propagation();
                    window.focus(&this.focus_handle, cx);
                    this.open_context_menu(Some(id.clone()), event.position, window, cx);
                })
            })
            .on_click({
                let id = id.clone();
                cx.listener(move |this, event: &ClickEvent, window, cx| {
                    cx.stop_propagation();
                    this.row_clicked(&id, event, window, cx);
                })
            })
            .on_drag(ExplorerDrag { items, source }, move |drag, _, _, cx| {
                weak.update(cx, |this, _| this.dragging = true).ok();
                let weak = weak.clone();
                let label = label.clone();
                let _ = drag;
                cx.new(move |cx: &mut Context<DragPreview>| {
                    cx.on_release(move |_, cx| {
                        weak.update(cx, |this, cx| this.drag_ended(cx)).ok();
                    })
                    .detach();
                    DragPreview { label }
                })
            })
            .external_drag_payload(|drag: &ExplorerDrag, _, _| {
                Some(ExternalDragPayload::Files(FileDragPaths::new(drag.items.clone())))
            })
            .can_drop({
                let weak = cx.entity().downgrade();
                let folder = folder.clone();
                move |value, window, cx| accepts_drop(&weak, &folder, value, window, cx)
            })
            .drag_over::<ExplorerDrag>(move |style, _, _, _| {
                style.bg(drop_fill).border_1().border_color(drop_edge)
            })
            .drag_over::<ExternalPaths>(move |style, _, _, _| {
                style.bg(drop_fill).border_1().border_color(drop_edge)
            })
            .on_drag_move::<ExplorerDrag>({
                let folder = folder.clone();
                cx.listener(move |this, event: &DragMoveEvent<ExplorerDrag>, _, cx| {
                    if event.bounds.contains(&event.event.position) {
                        this.drag_hovered(folder.clone(), cx);
                    } else {
                        this.drag_left(&folder);
                    }
                })
            })
            .on_drag_move::<ExternalPaths>({
                let folder = folder.clone();
                cx.listener(move |this, event: &DragMoveEvent<ExternalPaths>, _, cx| {
                    if event.bounds.contains(&event.event.position) {
                        this.drag_hovered(folder.clone(), cx);
                    } else {
                        this.drag_left(&folder);
                    }
                })
            })
            .on_drop({
                let folder = folder.clone();
                cx.listener(move |this, drag: &ExplorerDrag, window, cx| {
                    cx.stop_propagation();
                    let internal = drag.source == cx.entity_id();
                    let copy = chords::is_copy_drag(&window.modifiers());
                    this.drop_paths(folder.clone(), drag.paths(), internal, copy, cx);
                })
            })
            .on_drop(cx.listener(move |this, paths: &ExternalPaths, _, cx| {
                cx.stop_propagation();
                this.drop_paths(folder.clone(), paths.paths().to_vec(), false, false, cx);
            }));
        element.into_any_element()
    }
}

impl Render for FilesPanel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if std::mem::take(&mut self.focus_tree_on_render) && self.editing.is_none() {
            window.focus(&self.focus_handle, cx);
        }
        let t = cx.soprano_theme().clone();
        let focused = self.focus_handle.is_focused(window);
        let root_label = self.state.as_ref().map(|state| {
            let path = &state.root.path;
            let name = path.file_name().map(|name| name.to_string_lossy().into_owned());
            (
                name.unwrap_or_else(|| path.to_string_lossy().into_owned()),
                soprano_platform::paths::abbreviate_home(path),
            )
        });
        let has_root = self.state.is_some();
        let can_collapse = self.can_collapse_all();

        let header = ui::header(&t, "Files")
            .child(
                div()
                    .id("files-root-label")
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_right()
                    .text_size(t.z(size::META))
                    .text_color(t.dim)
                    .when_some(root_label, |label, (name, full)| {
                        label.child(name).tooltip(soprano_ui::tooltip::tooltip(full))
                    }),
            )
            .child(ui::icon_button(
                "files-collapse-all",
                IconName::Minimize2,
                "Collapse All",
                can_collapse,
                cx.listener(|this, _, _, cx| this.collapse_all(cx)),
            ))
            .child(ui::icon_button(
                "files-refresh",
                if self.manual_refresh_spinner { IconName::LoaderCircle } else { IconName::RefreshCw },
                if self.manual_refresh_spinner { "Refreshing Explorer" } else { "Refresh Explorer" },
                has_root,
                cx.listener(|this, _, _, cx| this.manual_refresh(cx)),
            ))
            .child(ui::icon_button(
                "files-more",
                IconName::Ellipsis,
                "More Explorer Actions",
                has_root,
                cx.listener(|this, event: &ClickEvent, window, cx| {
                    this.open_more_menu(event.position(), window, cx)
                }),
            ));

        let filter_empty = self.filter_input.read(cx).value().is_empty();
        let filter = div()
            .flex_none()
            .px(t.z(6.))
            .pt(t.z(6.))
            .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                if event.keystroke.key == "down" && chords::is_plain(&event.keystroke.modifiers) {
                    cx.stop_propagation();
                    this.focus_tree(window, cx);
                }
            }))
            .on_action(cx.listener(move |this, _: &Escape, window, cx| {
                cx.stop_propagation();
                if this.filter_input.read(cx).value().is_empty() {
                    cx.emit(SidebarEvent::FocusPane);
                } else {
                    this.filter_input.update(cx, |input, cx| input.set_value("", window, cx));
                    this.set_filter_query("", cx);
                }
            }))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(t.z(6.))
                    .h(t.z(28.))
                    .px(t.z(8.))
                    .rounded(t.z(8.))
                    .border_1()
                    .border_color(if self.filter_input.read(cx).focus_handle(cx).is_focused(window) {
                        t.accent
                    } else {
                        t.border
                    })
                    .child(icon(IconName::Search).size(13.).color(t.dim))
                    .child(div().flex_1().min_w_0().child(Input::new(&self.filter_input).appearance(false)))
                    .when(!filter_empty, |field| {
                        field.child(
                            soprano_ui::button::IconButton::new("files-clear-filter", IconName::X)
                                .size(soprano_ui::button::IconButtonSize::Tab)
                                .tooltip("Clear file search")
                                .on_click(cx.listener(|this, _, window, cx| {
                                    this.filter_input.update(cx, |input, cx| {
                                        input.set_value("", window, cx);
                                        input.focus(window, cx);
                                    });
                                    this.set_filter_query("", cx);
                                })),
                        )
                    }),
            );

        let body: gpui::AnyElement = match self.status() {
            Some(Status::Message(message)) => ui::empty_state(&t, &message).into_any_element(),
            Some(Status::Loading) => ui::empty_state(&t, "Loading files…").into_any_element(),
            Some(Status::LoadError(message)) => ui::empty_state(&t, &message)
                .child(
                    soprano_ui::button::Button::new("files-retry", "Retry")
                        .on_click(cx.listener(|this, _, _, cx| this.retry(cx))),
                )
                .into_any_element(),
            None => {
                let t2 = t.clone();
                uniform_list(
                    "files-rows",
                    self.rows.len(),
                    cx.processor(move |this, range: std::ops::Range<usize>, window, cx| {
                        let focused = this.focus_handle.is_focused(window);
                        let selection_items = this.selection_drag_items();
                        range
                            .map(|index| this.render_row(index, &t2, focused, &selection_items, cx))
                            .collect::<Vec<_>>()
                    }),
                )
                .track_scroll(&self.scroll)
                .size_full()
                .into_any_element()
            }
        };
        let _ = focused;

        let tree =
            div()
                .id("files-tree")
                .key_context("FilesTree")
                .track_focus(&self.focus_handle)
                .flex_1()
                .min_h_0()
                .p(t.z(6.))
                .on_key_down(cx.listener(Self::key_down))
                .on_action(cx.listener(|this, _: &Escape, _, cx| {
                    if this.editing.is_some() {
                        cx.stop_propagation();
                        this.finish_editing(false, cx);
                    }
                }))
                .on_click(cx.listener(|this, event: &ClickEvent, window, cx| {
                    this.empty_space_clicked(event, window, cx)
                }))
                .on_mouse_down(
                    MouseButton::Right,
                    cx.listener(|this, event: &MouseDownEvent, window, cx| {
                        window.focus(&this.focus_handle, cx);
                        this.open_context_menu(None, event.position, window, cx);
                    }),
                )
                .can_drop({
                    let weak = cx.entity().downgrade();
                    move |value, window, cx| accepts_drop(&weak, "", value, window, cx)
                })
                .drag_over::<ExternalPaths>(|style, _, _, _| style)
                .on_drop(cx.listener(|this, drag: &ExplorerDrag, window, cx| {
                    let internal = drag.source == cx.entity_id();
                    let copy = chords::is_copy_drag(&window.modifiers());
                    this.drop_paths(String::new(), drag.paths(), internal, copy, cx);
                }))
                .on_drop(cx.listener(|this, paths: &ExternalPaths, _, cx| {
                    this.drop_paths(String::new(), paths.paths().to_vec(), false, false, cx);
                }))
                .child(body);

        ui::card(&t)
            .child(header)
            .child(filter)
            .child(tree)
            .children(self.context_menu.as_ref().map(|(menu, _)| menu.clone()))
    }
}

#[cfg(test)]
mod tests;
