//! The explorer's tree model: lazily loaded folders, expansion state, visibility rules,
//! the filtered tree, keyboard selection, drag-and-drop rules, and file-watcher event
//! routing. UI-independent: the view renders [`FileExplorerTree::visible_rows`] and calls
//! back in with user actions.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::Duration;

use soprano_git::GitStatusSnapshot;

use crate::listing::{self, FileExplorerEntry};
use crate::root::{child_path, parent_path, relative_path, relative_path_in_roots};

/// Name-filter results are capped so a one-letter query in a huge
/// repository cannot build an unbounded tree.
pub const FILTER_RESULT_LIMIT: usize = 5_000;
/// Files listed for the filter outside git.
pub const ENUMERATED_FILE_LIMIT: usize = 50_000;

/// One file or folder in the explorer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileExplorerNode {
    pub name: String,
    /// Root-relative; `""` for the root.
    pub relative_path: String,
    pub path: PathBuf,
    pub is_directory: bool,
    pub is_symlink: bool,
    /// Child relative paths in display order; `None` until the folder is loaded.
    pub children: Option<Vec<String>>,
    pub load_error: Option<String>,
    is_loading: bool,
    reload_requested: bool,
}

impl FileExplorerNode {
    fn new(path: PathBuf, relative_path: String, is_directory: bool, is_symlink: bool) -> Self {
        let name = relative_path.rsplit('/').next().unwrap_or("").to_owned();
        Self {
            name,
            relative_path,
            path,
            is_directory,
            is_symlink,
            children: None,
            load_error: None,
            is_loading: false,
            reload_requested: false,
        }
    }

    pub fn is_loading(&self) -> bool {
        self.is_loading
    }
}

/// What hides rows: the dotfile and ignored-file toggles and the git decorations.
#[derive(Clone, Copy)]
pub struct VisibilityRules<'a> {
    pub shows_dotfiles: bool,
    pub shows_ignored_files: bool,
    pub is_git_repository: bool,
    pub git_status: &'a GitStatusSnapshot,
}

impl VisibilityRules<'_> {
    fn shows(&self, node: &FileExplorerNode) -> bool {
        if !self.shows_dotfiles && listing::is_hidden_name(&node.name) {
            return false;
        }
        let hides_ignored = !self.shows_ignored_files && self.is_git_repository;
        !(hides_ignored && self.git_status.is_ignored(&node.relative_path))
    }
}

/// One visible row: a node and its indentation depth (0 for the root's children).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VisibleRow {
    pub relative_path: String,
    pub depth: usize,
}

/// The lazily loaded tree under one root.
#[derive(Clone, Debug)]
pub struct FileExplorerTree {
    root: PathBuf,
    nodes: HashMap<String, FileExplorerNode>,
    expanded_paths: BTreeSet<String>,
}

impl FileExplorerTree {
    pub fn new(root: PathBuf) -> Self {
        let mut nodes = HashMap::new();
        nodes.insert(String::new(), FileExplorerNode::new(root.clone(), String::new(), true, false));
        Self { root, nodes, expanded_paths: BTreeSet::new() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn node(&self, relative_path: &str) -> Option<&FileExplorerNode> {
        self.nodes.get(relative_path)
    }

    /// Starts loading a folder: returns the directory to list (off the UI thread, with
    /// [`listing::entries`]), or `None` when a load is already running — that load is
    /// then repeated once it finishes.
    pub fn begin_load(&mut self, relative_path: &str) -> Option<PathBuf> {
        let node = self.nodes.get_mut(relative_path)?;
        if !node.is_directory {
            return None;
        }
        if node.is_loading {
            node.reload_requested = true;
            return None;
        }
        node.is_loading = true;
        Some(node.path.clone())
    }

    /// Applies a finished listing. Existing child nodes with the same name and kind are
    /// kept (with their loaded children); folders that disappeared drop out of the
    /// expanded set. Returns true when the folder must be loaded again because another
    /// reload was requested meanwhile.
    pub fn finish_load(
        &mut self,
        relative_path: &str,
        result: Result<Vec<FileExplorerEntry>, String>,
    ) -> bool {
        let Some(node) = self.nodes.get_mut(relative_path) else { return false };
        node.is_loading = false;
        let reload = std::mem::take(&mut node.reload_requested);
        match result {
            Ok(entries) => {
                node.load_error = None;
                let parent_path = node.path.clone();
                let old_children = node.children.take().unwrap_or_default();
                let mut children = Vec::with_capacity(entries.len());
                let mut kept = HashSet::new();
                for entry in entries {
                    let child = child_path(relative_path, &entry.name);
                    let reused = self.nodes.get(&child).is_some_and(|n| {
                        n.is_directory == entry.is_directory && n.is_symlink == entry.is_symlink
                    });
                    if !reused {
                        self.remove_subtree(&child);
                        self.nodes.insert(
                            child.clone(),
                            FileExplorerNode::new(
                                parent_path.join(&entry.name),
                                child.clone(),
                                entry.is_directory,
                                entry.is_symlink,
                            ),
                        );
                    }
                    kept.insert(child.clone());
                    children.push(child);
                }
                for old in old_children.iter().filter(|old| !kept.contains(*old)) {
                    self.expanded_paths.retain(|path| path != old && !path.starts_with(&format!("{old}/")));
                    self.remove_subtree(old);
                }
                if let Some(node) = self.nodes.get_mut(relative_path) {
                    node.children = Some(children);
                }
            }
            Err(error) => {
                node.load_error = Some(error);
                if !relative_path.is_empty() && node.children.is_none() {
                    node.children = Some(Vec::new());
                }
            }
        }
        reload
    }

    /// Loads a folder synchronously (begin + list + finish), repeating as requested.
    pub fn load(&mut self, relative_path: &str) {
        while let Some(directory) = self.begin_load(relative_path) {
            let result = listing::entries(&directory).map_err(|error| error.to_string());
            if !self.finish_load(relative_path, result) {
                break;
            }
        }
    }

    fn remove_subtree(&mut self, relative_path: &str) {
        let Some(node) = self.nodes.remove(relative_path) else { return };
        for child in node.children.unwrap_or_default() {
            self.remove_subtree(&child);
        }
    }

    /// The root and every folder loaded so far: what a full refresh re-reads.
    pub fn loaded_folders(&self) -> Vec<String> {
        let mut folders: Vec<String> = self
            .nodes
            .values()
            .filter(|node| node.is_directory && (node.relative_path.is_empty() || node.children.is_some()))
            .map(|node| node.relative_path.clone())
            .collect();
        folders.sort();
        folders
    }

    // MARK: Expansion

    pub fn is_expanded(&self, relative_path: &str) -> bool {
        self.expanded_paths.contains(relative_path)
    }

    pub fn expanded_paths(&self) -> &BTreeSet<String> {
        &self.expanded_paths
    }

    /// Marks a folder open; returns true when it still needs loading.
    pub fn expand(&mut self, relative_path: &str) -> bool {
        let Some(node) = self.nodes.get(relative_path).filter(|node| node.is_directory) else { return false };
        let needs_load = node.children.is_none();
        self.expanded_paths.insert(relative_path.to_owned());
        needs_load
    }

    pub fn collapse(&mut self, relative_path: &str) {
        self.expanded_paths.remove(relative_path);
    }

    pub fn collapse_subtree(&mut self, relative_path: &str) {
        let prefix = format!("{relative_path}/");
        self.expanded_paths.retain(|path| path != relative_path && !path.starts_with(&prefix));
    }

    pub fn collapse_all(&mut self) {
        self.expanded_paths.clear();
    }

    /// Keeps a renamed or moved folder (and the folders inside it) open.
    pub fn move_expanded_paths(&mut self, old_path: &str, new_path: &str) {
        let prefix = format!("{old_path}/");
        self.expanded_paths = std::mem::take(&mut self.expanded_paths)
            .into_iter()
            .map(|path| {
                if path == old_path {
                    new_path.to_owned()
                } else if let Some(rest) = path.strip_prefix(&prefix) {
                    format!("{new_path}/{rest}")
                } else {
                    path
                }
            })
            .collect();
    }

    // MARK: Visibility

    pub fn visible_children(
        &self,
        relative_path: &str,
        rules: &VisibilityRules<'_>,
    ) -> Vec<&FileExplorerNode> {
        let Some(children) = self.nodes.get(relative_path).and_then(|node| node.children.as_ref()) else {
            return Vec::new();
        };
        children.iter().filter_map(|child| self.nodes.get(child)).filter(|node| rules.shows(node)).collect()
    }

    /// Every row on screen, top to bottom: the root's visible children and, under each
    /// expanded loaded folder, its own.
    pub fn visible_rows(&self, rules: &VisibilityRules<'_>) -> Vec<VisibleRow> {
        let mut rows = Vec::new();
        self.append_rows("", 0, rules, &mut rows);
        rows
    }

    fn append_rows(
        &self,
        folder: &str,
        depth: usize,
        rules: &VisibilityRules<'_>,
        rows: &mut Vec<VisibleRow>,
    ) {
        for child in self.visible_children(folder, rules) {
            rows.push(VisibleRow { relative_path: child.relative_path.clone(), depth });
            if child.is_directory && self.is_expanded(&child.relative_path) {
                self.append_rows(&child.relative_path, depth + 1, rules, rows);
            }
        }
    }

    /// ← on the lead row: collapse it if it is an open folder, else select its parent.
    pub fn collapse_or_select_parent(&self, lead: &str) -> KeyAction {
        let Some(node) = self.nodes.get(lead) else { return KeyAction::None };
        if node.is_directory && self.is_expanded(lead) {
            return KeyAction::Collapse(lead.to_owned());
        }
        let parent = parent_path(lead);
        if parent.is_empty() { KeyAction::None } else { KeyAction::Select(parent.to_owned()) }
    }

    /// → on the lead row: open a closed folder, else select its first visible child.
    pub fn expand_or_select_first_child(&self, lead: &str, rules: &VisibilityRules<'_>) -> KeyAction {
        let Some(node) = self.nodes.get(lead).filter(|node| node.is_directory) else {
            return KeyAction::None;
        };
        if !self.is_expanded(lead) {
            return KeyAction::Expand(node.relative_path.clone());
        }
        self.visible_children(lead, rules)
            .first()
            .map_or(KeyAction::None, |first| KeyAction::Select(first.relative_path.clone()))
    }
}

/// What an arrow key does to the tree.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum KeyAction {
    None,
    Collapse(String),
    Expand(String),
    Select(String),
}

/// The selection with descendants of other selected folders dropped, so
/// acting on a folder and its contents does not act twice.
pub fn top_level_selection(selected: &[(String, bool)]) -> Vec<String> {
    let folders: HashSet<&str> =
        selected.iter().filter(|(_, is_directory)| *is_directory).map(|(path, _)| path.as_str()).collect();
    selected
        .iter()
        .filter(|(path, _)| {
            let mut parent = parent_path(path);
            while !parent.is_empty() {
                if folders.contains(parent) {
                    return false;
                }
                parent = parent_path(parent);
            }
            true
        })
        .map(|(path, _)| path.clone())
        .collect()
}

// MARK: - Keyboard Selection

/// Orca jumps a tenth of the list per page key.
pub fn page_step(row_count: usize) -> isize {
    (row_count / 10).max(1) as isize
}

/// The rows selected after moving by `delta` (arrows, Page Up/Down) from the last selected
/// row; with `extending`, the range from the first selected row (the anchor). Returns the
/// new selection and the row to scroll to, or `None` for an empty list.
pub fn move_selection_by(
    selected: &BTreeSet<usize>,
    delta: isize,
    row_count: usize,
    extending: bool,
) -> Option<(BTreeSet<usize>, usize)> {
    let current = match selected.last() {
        Some(last) => *last as isize,
        None if delta > 0 => -1,
        None => row_count as isize,
    };
    move_selection_to(selected, current + delta, row_count, extending)
}

/// Home/End-style moves to an absolute row, clamped to the list.
pub fn move_selection_to(
    selected: &BTreeSet<usize>,
    row: isize,
    row_count: usize,
    extending: bool,
) -> Option<(BTreeSet<usize>, usize)> {
    if row_count == 0 {
        return None;
    }
    let target = row.clamp(0, row_count as isize - 1) as usize;
    let selection = match selected.first() {
        Some(anchor) if extending => (target.min(*anchor)..=target.max(*anchor)).collect(),
        _ => BTreeSet::from([target]),
    };
    Some((selection, target))
}

/// The text "Copy Path" (absolute) or "Copy Relative Path" puts on the clipboard: one
/// path per line. Each item is (absolute path, root-relative path).
pub fn copied_paths(items: &[(PathBuf, String)], relative: bool) -> String {
    items
        .iter()
        .map(|(absolute, rel)| if relative { rel.clone() } else { absolute.to_string_lossy().into_owned() })
        .collect::<Vec<_>>()
        .join("\n")
}

// MARK: - Drag and Drop

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DropOperation {
    None,
    Copy,
    Move,
}

/// The folder a drop over `proposed` lands in: a folder itself, a file's parent, or the
/// root (`""`) for empty space.
pub fn drop_folder(proposed: Option<(&str, bool)>) -> String {
    match proposed {
        Some((path, true)) => path.to_owned(),
        Some((path, false)) => parent_path(path).to_owned(),
        None => String::new(),
    }
}

/// What dropping `sources` on `folder` does. Neither a move nor a copy can put a folder
/// inside itself. Drags from outside the explorer copy; inside it they move, or copy
/// with ⌥ (Alt) held; a move that changes nothing is refused.
pub fn drop_operation(
    folder: &Path,
    sources: &[PathBuf],
    from_explorer: bool,
    copy_modifier: bool,
) -> DropOperation {
    if sources.is_empty() {
        return DropOperation::None;
    }
    let folder = soprano_platform::paths::normalize(folder);
    let enters_itself =
        sources.iter().any(|source| folder.starts_with(soprano_platform::paths::normalize(source)));
    if enters_itself {
        return DropOperation::None;
    }
    if !from_explorer || copy_modifier {
        return DropOperation::Copy;
    }
    let moves_anything = sources.iter().any(|source| {
        source.parent().map(soprano_platform::paths::normalize).as_deref() != Some(folder.as_path())
    });
    if moves_anything { DropOperation::Move } else { DropOperation::None }
}

// MARK: - Filter

/// One node of the filtered tree; folders are created for the matches' ancestors.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FilterNode {
    pub name: String,
    pub relative_path: String,
    pub is_directory: bool,
    pub children: Vec<FilterNode>,
}

/// The tree the name filter shows: every listed file matching all `tokens`, minus
/// deleted, hidden-dotfile and hidden-ignored files, at most [`FILTER_RESULT_LIMIT`],
/// each folder sorted folders-first in natural order.
pub fn build_filter_tree(files: &[String], tokens: &[String], rules: &VisibilityRules<'_>) -> FilterNode {
    let mut root = FilterNode {
        name: String::new(),
        relative_path: String::new(),
        is_directory: true,
        children: vec![],
    };
    let mut matches = 0;
    for path in files {
        if matches >= FILTER_RESULT_LIMIT {
            break;
        }
        if !listing::filter_matches(path, tokens)
            || rules.git_status.file_statuses.get(path) == Some(&soprano_git::GitFileStatus::Deleted)
            || (!rules.shows_dotfiles && listing::is_dotfile(path))
            || (!rules.shows_ignored_files && rules.git_status.is_ignored(path))
        {
            continue;
        }
        matches += 1;
        let segments: Vec<&str> = path.split('/').filter(|segment| !segment.is_empty()).collect();
        let Some((file, folders)) = segments.split_last() else { continue };
        let mut parent = &mut root;
        for segment in folders {
            let folder_path = child_path(&parent.relative_path, segment);
            let index = match parent.children.iter().position(|c| c.is_directory && c.name == *segment) {
                Some(index) => index,
                None => {
                    parent.children.push(FilterNode {
                        name: (*segment).to_owned(),
                        relative_path: folder_path,
                        is_directory: true,
                        children: vec![],
                    });
                    parent.children.len() - 1
                }
            };
            parent = &mut parent.children[index];
        }
        parent.children.push(FilterNode {
            name: (*file).to_owned(),
            relative_path: path.clone(),
            is_directory: false,
            children: vec![],
        });
    }
    sort_filter_tree(&mut root);
    root
}

fn sort_filter_tree(node: &mut FilterNode) {
    node.children.sort_by(|a, b| listing::compare((&a.name, a.is_directory), (&b.name, b.is_directory)));
    node.children.iter_mut().for_each(sort_filter_tree);
}

/// Every file under `root` outside git, skipping the always-hidden folders, at most
/// `limit`. Inside a repository the filter lists files with `soprano_git::reader::list_files`.
pub fn enumerate_files(root: &Path, limit: usize) -> Vec<String> {
    let root_text = root.to_string_lossy().into_owned();
    let mut files = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(directory) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&directory) else { continue };
        let mut entries: Vec<_> = entries.flatten().collect();
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries.into_iter().rev() {
            if files.len() >= limit {
                return files;
            }
            let name = entry.file_name();
            if listing::is_always_hidden(&name.to_string_lossy()) {
                continue;
            }
            let path = entry.path();
            // Symlinked folders are not followed, so a link loop cannot run forever.
            if entry.file_type().is_ok_and(|t| t.is_dir()) {
                stack.push(path);
                continue;
            }
            if std::fs::metadata(&path).is_ok_and(|m| m.is_dir()) {
                continue;
            }
            if let Some(relative) = relative_path(&path.to_string_lossy(), &root_text) {
                files.push(relative);
            }
        }
    }
    files
}

// MARK: - Watching

/// How a batch of file-watcher paths affects the explorer.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EventRouting {
    /// Root-relative folders to re-list (each changed path's parent, and the path itself
    /// in case it is a loaded folder that was renamed or replaced).
    pub reload_paths: BTreeSet<String>,
    /// A non-ignored working-tree path changed: re-read git and the filter listing.
    pub changed_working_tree: bool,
    /// The repository's git directory changed: re-read git.
    pub changed_git_directory: bool,
}

/// Routes watcher paths. `roots` are the root as configured and its resolved form;
/// `external_git_directory` is a linked worktree's or submodule's git directory.
pub fn route_events(
    paths: &[PathBuf],
    roots: &[&str],
    external_git_directory: Option<&Path>,
    git_status: &GitStatusSnapshot,
) -> EventRouting {
    let mut routing = EventRouting::default();
    for path in paths {
        if let Some(git_directory) = external_git_directory
            && path.starts_with(git_directory)
        {
            routing.changed_git_directory = true;
            continue;
        }
        let Some(relative) = relative_path_in_roots(&path.to_string_lossy(), roots) else { continue };
        if relative == ".git" || relative.starts_with(".git/") {
            routing.changed_git_directory = true;
            continue;
        }
        routing.reload_paths.insert(parent_path(&relative).to_owned());
        routing.reload_paths.insert(relative.clone());
        // Build output in ignored folders cannot change `git status`;
        // skipping it keeps a running build from re-reading git nonstop.
        if !git_status.is_ignored(&relative) {
            routing.changed_working_tree = true;
        }
    }
    routing
}

/// How long to wait before re-reading git: bursts (a build, a checkout) coalesce into one
/// read at most every two seconds instead of re-running `git status` per event batch.
pub fn git_refresh_delay(immediately: bool, since_last_refresh: Duration) -> Duration {
    if immediately {
        return Duration::ZERO;
    }
    Duration::from_secs(2).saturating_sub(since_last_refresh).max(Duration::from_millis(400))
}

#[cfg(test)]
mod tests {
    use super::*;
    use soprano_git::GitFileStatus;

    fn rules(snapshot: &GitStatusSnapshot) -> VisibilityRules<'_> {
        VisibilityRules {
            shows_dotfiles: true,
            shows_ignored_files: true,
            is_git_repository: true,
            git_status: snapshot,
        }
    }

    fn rows(tree: &FileExplorerTree, rules: &VisibilityRules<'_>) -> Vec<String> {
        tree.visible_rows(rules).into_iter().map(|row| row.relative_path).collect()
    }

    #[test]
    fn folders_load_lazily_and_expanded_folders_show_their_children() {
        let temp = tempfile::tempdir().expect("tempdir");
        std::fs::create_dir_all(temp.path().join("Sources")).expect("mkdir");
        std::fs::write(temp.path().join("Sources/app.swift"), "").expect("write");
        std::fs::write(temp.path().join("README.md"), "").expect("write");
        let snapshot = GitStatusSnapshot::empty();
        let mut tree = FileExplorerTree::new(temp.path().to_path_buf());

        tree.load("");
        assert_eq!(rows(&tree, &rules(&snapshot)), ["Sources", "README.md"]);
        assert!(tree.node("Sources").is_some_and(|n| n.children.is_none()));

        assert!(tree.expand("Sources"));
        tree.load("Sources");
        assert_eq!(rows(&tree, &rules(&snapshot)), ["Sources", "Sources/app.swift", "README.md"]);

        std::fs::write(temp.path().join("Sources/generated.swift"), "").expect("write");
        tree.load("Sources");
        assert_eq!(
            rows(&tree, &rules(&snapshot)),
            ["Sources", "Sources/app.swift", "Sources/generated.swift", "README.md"]
        );
    }

    #[test]
    fn a_folder_that_disappears_leaves_the_expanded_set() {
        let temp = tempfile::tempdir().expect("tempdir");
        std::fs::create_dir_all(temp.path().join("a/b")).expect("mkdir");
        let mut tree = FileExplorerTree::new(temp.path().to_path_buf());
        tree.load("");
        tree.expand("a");
        tree.load("a");
        tree.expand("a/b");

        std::fs::remove_dir_all(temp.path().join("a")).expect("rm");
        tree.load("");

        assert!(tree.expanded_paths().is_empty());
        assert!(tree.node("a/b").is_none());
    }

    #[test]
    fn a_load_requested_while_one_runs_is_repeated() {
        let temp = tempfile::tempdir().expect("tempdir");
        let mut tree = FileExplorerTree::new(temp.path().to_path_buf());
        assert!(tree.begin_load("").is_some());
        assert!(tree.begin_load("").is_none());
        assert!(tree.finish_load("", Ok(vec![])));
        assert!(tree.begin_load("").is_some());
        assert!(!tree.finish_load("", Err("denied".to_owned())));
        assert_eq!(tree.node("").and_then(|n| n.load_error.clone()).as_deref(), Some("denied"));
    }

    #[test]
    fn dotfiles_and_ignored_files_hide_by_their_toggles() {
        let temp = tempfile::tempdir().expect("tempdir");
        for file in [".env", "build.log", "main.rs"] {
            std::fs::write(temp.path().join(file), "").expect("write");
        }
        let snapshot = GitStatusSnapshot::new(&[], ["build.log".to_owned()].into());
        let mut tree = FileExplorerTree::new(temp.path().to_path_buf());
        tree.load("");

        let mut hiding = rules(&snapshot);
        hiding.shows_dotfiles = false;
        hiding.shows_ignored_files = false;
        assert_eq!(rows(&tree, &hiding), ["main.rs"]);
        hiding.is_git_repository = false;
        assert_eq!(rows(&tree, &hiding), ["build.log", "main.rs"]);
    }

    #[test]
    fn arrow_keys_collapse_select_parent_expand_and_select_first_child() {
        let temp = tempfile::tempdir().expect("tempdir");
        std::fs::create_dir_all(temp.path().join("src")).expect("mkdir");
        std::fs::write(temp.path().join("src/lib.rs"), "").expect("write");
        let snapshot = GitStatusSnapshot::empty();
        let mut tree = FileExplorerTree::new(temp.path().to_path_buf());
        tree.load("");

        assert_eq!(
            tree.expand_or_select_first_child("src", &rules(&snapshot)),
            KeyAction::Expand("src".into())
        );
        tree.expand("src");
        tree.load("src");
        assert_eq!(
            tree.expand_or_select_first_child("src", &rules(&snapshot)),
            KeyAction::Select("src/lib.rs".into())
        );
        assert_eq!(tree.collapse_or_select_parent("src/lib.rs"), KeyAction::Select("src".into()));
        assert_eq!(tree.collapse_or_select_parent("src"), KeyAction::Collapse("src".into()));
        tree.collapse("src");
        assert_eq!(tree.collapse_or_select_parent("src"), KeyAction::None);
    }

    #[test]
    fn renaming_an_open_folder_keeps_it_and_its_open_subfolders_open() {
        let mut tree = FileExplorerTree::new(PathBuf::from("/tmp"));
        tree.expanded_paths = ["Sources".to_owned(), "Sources/App".to_owned(), "Other".to_owned()].into();

        tree.move_expanded_paths("Sources", "Lib");

        assert_eq!(tree.expanded_paths().iter().collect::<Vec<_>>(), ["Lib", "Lib/App", "Other"]);
    }

    #[test]
    fn keyboard_moves_clamp_and_shift_extends_from_the_anchor() {
        let none = BTreeSet::new();
        assert_eq!(move_selection_by(&none, 1, 5, false), Some((BTreeSet::from([0]), 0)));
        assert_eq!(move_selection_by(&none, -1, 5, false), Some((BTreeSet::from([4]), 4)));
        let one = BTreeSet::from([1]);
        assert_eq!(move_selection_by(&one, 2, 5, true), Some((BTreeSet::from([1, 2, 3]), 3)));
        assert_eq!(move_selection_to(&one, 99, 5, false), Some((BTreeSet::from([4]), 4)));
        assert_eq!(move_selection_to(&one, 0, 0, false), None);
        assert_eq!(page_step(5), 1);
        assert_eq!(page_step(250), 25);
    }

    #[test]
    fn a_selected_folders_contents_are_not_acted_on_twice() {
        let selected = [
            ("src".to_owned(), true),
            ("src/a/b.rs".to_owned(), false),
            ("srcfile".to_owned(), false),
            ("docs/x.md".to_owned(), false),
        ];
        assert_eq!(top_level_selection(&selected), ["src", "srcfile", "docs/x.md"]);
    }

    #[test]
    fn copied_paths_are_absolute_or_relative_one_per_line() {
        let items = [
            (PathBuf::from("/p/a.rs"), "a.rs".to_owned()),
            (PathBuf::from("/p/b/c.rs"), "b/c.rs".to_owned()),
        ];
        assert_eq!(copied_paths(&items, false), "/p/a.rs\n/p/b/c.rs");
        assert_eq!(copied_paths(&items, true), "a.rs\nb/c.rs");
    }

    #[test]
    fn drops_move_inside_copy_from_outside_or_with_the_modifier_and_never_enter_themselves() {
        let folder = Path::new("/p/target");
        let inside = [PathBuf::from("/p/file.txt")];
        assert_eq!(drop_operation(folder, &inside, true, false), DropOperation::Move);
        assert_eq!(drop_operation(folder, &inside, true, true), DropOperation::Copy);
        assert_eq!(drop_operation(folder, &inside, false, false), DropOperation::Copy);
        assert_eq!(drop_operation(folder, &[PathBuf::from("/p/target/x")], true, false), DropOperation::None);
        assert_eq!(drop_operation(folder, &[PathBuf::from("/p")], false, false), DropOperation::None);
        assert_eq!(drop_operation(folder, &[PathBuf::from("/p/target")], true, true), DropOperation::None);
        assert_eq!(drop_operation(folder, &[], false, false), DropOperation::None);
        assert_eq!(drop_folder(Some(("a/b.txt", false))), "a");
        assert_eq!(drop_folder(Some(("a", true))), "a");
        assert_eq!(drop_folder(None), "");
    }

    #[test]
    fn the_filter_tree_keeps_matches_under_sorted_folders_and_skips_hidden_files() {
        let files: Vec<String> =
            ["src/view10.rs", "src/view2.rs", "README_view.md", ".github/view.yml", "gone_view.rs"]
                .map(String::from)
                .to_vec();
        let snapshot =
            GitStatusSnapshot::new(&[("gone_view.rs".to_owned(), GitFileStatus::Deleted)], HashSet::new());
        let mut hiding = rules(&snapshot);
        hiding.shows_dotfiles = false;

        let tree = build_filter_tree(&files, &listing::filter_tokens("VIEW"), &hiding);

        let top: Vec<&str> = tree.children.iter().map(|c| c.relative_path.as_str()).collect();
        assert_eq!(top, ["src", "README_view.md"]);
        let src: Vec<&str> = tree.children[0].children.iter().map(|c| c.relative_path.as_str()).collect();
        assert_eq!(src, ["src/view2.rs", "src/view10.rs"]);
    }

    #[test]
    fn enumerating_files_skips_always_hidden_folders() {
        let temp = tempfile::tempdir().expect("tempdir");
        std::fs::create_dir_all(temp.path().join("node_modules/x")).expect("mkdir");
        std::fs::create_dir_all(temp.path().join("src")).expect("mkdir");
        std::fs::write(temp.path().join("node_modules/x/i.js"), "").expect("write");
        std::fs::write(temp.path().join("src/a.rs"), "").expect("write");
        std::fs::write(temp.path().join("b.txt"), "").expect("write");

        let mut files = enumerate_files(temp.path(), ENUMERATED_FILE_LIMIT);
        files.sort();

        assert_eq!(files, ["b.txt", "src/a.rs"]);
        assert_eq!(enumerate_files(temp.path(), 1).len(), 1);
    }

    #[test]
    fn watcher_events_reload_parents_and_skip_git_refreshes_for_ignored_output() {
        let snapshot = GitStatusSnapshot::new(&[], ["target".to_owned()].into());
        let roots = ["/repo", "/private/repo"];
        let external = Path::new("/main/.git/worktrees/x");

        let build = route_events(&[PathBuf::from("/private/repo/target/debug/app")], &roots, None, &snapshot);
        assert_eq!(build.reload_paths.iter().collect::<Vec<_>>(), ["target/debug", "target/debug/app"]);
        assert!(!build.changed_working_tree);

        let edit = route_events(&[PathBuf::from("/repo/src/main.rs")], &roots, None, &snapshot);
        assert!(edit.changed_working_tree);
        assert!(edit.reload_paths.contains("src"));

        let git = route_events(
            &[PathBuf::from("/repo/.git/index"), PathBuf::from("/main/.git/worktrees/x/HEAD")],
            &roots,
            Some(external),
            &snapshot,
        );
        assert!(git.changed_git_directory);
        assert!(git.reload_paths.is_empty());
    }

    #[test]
    fn git_refreshes_wait_out_bursts() {
        assert_eq!(git_refresh_delay(true, Duration::ZERO), Duration::ZERO);
        assert_eq!(git_refresh_delay(false, Duration::ZERO), Duration::from_secs(2));
        assert_eq!(git_refresh_delay(false, Duration::from_secs(5)), Duration::from_millis(400));
    }
}
