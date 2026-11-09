# soprano-git-and-files — API report from GitFilesPort

Both crates are ported and their tests pass: 31 in `soprano-git` and 38 in `soprano-files`. Clippy shows no warnings in either crate, and both build cleanly for Linux and Windows. Nothing is left as a stub or TODO.

## 1. Public API

### soprano-git (no gpui; runs the `git` CLI)
- **`status`**
  - `GitFileStatus` {Modified, Added, Deleted, Renamed, Untracked, Copied}, with `letter()`, `priority()`, `propagates_to_folders()`, `from_status_character(char)` and `dominant(Option<Self>, Self)`.
  - `GitStatusSnapshot` {`file_statuses`, `folder_statuses`: HashMap<String, GitFileStatus>, `ignored_paths`: HashSet<String>}, with `empty()`, `new(&[(String, GitFileStatus)], HashSet<String>)`, `status(rel, is_dir)`, `is_ignored(rel)`, `parse_status(&[u8])` and `parse_ignored(&[u8])`.
- **`changes`**
  - `GitChangeArea` {Conflicts, Unstaged, Staged, Untracked}, ordered, with `title()` and `ALL`.
  - `GitChange` {path, original_path, status, area, lines_added, lines_deleted}, with `new`, `name()`, `directory()` and `letter()`.
  - `GitLineCounts`.
  - `GitChangeList` {branch, changes}, with `parse_status`, `parse_numstat`, `apply_line_counts`, `line_count(&[u8]) -> Option<usize>` and `changes_in(area)`.
  - `GitDiffLine` {kind: `GitDiffLineKind`, old_number, new_number, text}.
  - `GitFileDiff` {Text(Vec), Binary, NoChanges, EmptyFile{is_new}, TooLarge, Unavailable}, with `parse(&[u8])`.
  - `GitDiffRow`/`GitDiffRowKind` (with Filler) and `GitDiffLayout` {rows, change_starts}, with `inline(&[GitDiffLine])`, `side_by_side(..) -> (old, new)` and `changed_ranges(old, new) -> Option<(Range, Range)>`.
  - `GitDiffHighlights<K>` {old, new: Vec<Vec<GitDiffToken<K>>>}, with `compute(lines, Option<impl Fn(&str) -> Vec<(Range<usize>, K)>>)` and `MAXIMUM_LENGTH`.
- **`reader`**
  - `executable() -> Option<&'static Path>`
  - `snapshot(root) -> GitStatusSnapshot`
  - `ignored_paths(root)`
  - `changes(root) -> Option<GitChangeList>`
  - `diff(root, rel, staged) -> GitFileDiff`
  - `list_files(root) -> Option<Vec<String>>`
  - Constants: `MAXIMUM_DIFF_BYTES` (8 MB), `MAXIMUM_COUNTED_UNTRACKED_FILES` (500), `MAXIMUM_COUNTED_FILE_BYTES` (2 MB).
- **`branch`**
  - `GitBranchMonitor`, with `new()`, `set_on_change(Fn() + Send + Sync)`, `branch(cwd)`, `notable_branch(cwd)` and `set_watched_paths(&[String])`.
  - Free functions: `remote_default_branch(head)`, `resolve_head_path(path)`, `repository_root(path) -> Option<PathBuf>`, `parse_head(head)` and `standardize(path)`.
  - Constant: `CONVENTIONAL_DEFAULT_BRANCHES`.
- **`launcher`**
  - `Plan` {Open{repository, application}, NoWorkingDirectory, NotInstalled, NotARepository(String)}.
  - `is_available()`, `plan(Option<&str>, impl FnOnce() -> Option<PathBuf>)`, `installed_application()`, `explanation(&Plan)`, `open(Option<&str>, impl FnOnce(String))` and `BUNDLE_IDENTIFIER`.
- **`natural`**: `natural_compare` and `natural_compare_then_exact`, Finder's natural name order.

### soprano-files
- **`listing`**
  - `FileExplorerEntry`, `ALWAYS_HIDDEN_NAMES`, `entries(dir) -> io::Result<Vec<_>>`, `sort`, `compare` and `is_dotfile(rel)`.
  - `filter_tokens(query)` and `filter_matches(rel, tokens)` for find-files.
  - `duplicate_name(name, exists)`, `stem_range(name)` and `committed_name(input, original)` (inline rename/create commit rule).
- **`root`**
  - `ExplorerRoot` {path, is_git_repository} and `explorer_root(cwd)`.
  - `external_git_directory(root)`, `real_path`, `relative_path(path, root)`, `relative_path_in_roots`, `parent_path` and `child_path`.
  - `ExplorerPreferences`, with `load(StateStore)`, `shows_ignored_files()`, `shows_dotfiles(root)`, `toggle_dotfiles(root)` and `toggle_ignored_files()`. It persists under `soprano-explorer-show-ignored` and `soprano-explorer-hidden-dotfile-roots`.
- **`tree`**
  - `FileExplorerTree`:
    - **Loading:** `new(root)`, `node(rel)`, `begin_load(rel) -> Option<PathBuf>`, `finish_load(rel, Result<Vec<Entry>, String>) -> bool` (true means load again), `load(rel)` (synchronous) and `loaded_folders()`.
    - **Expansion:** `expand`, `collapse`, `collapse_subtree`, `collapse_all` and `move_expanded_paths`.
    - **Display and arrow keys:** `visible_children(rel, &VisibilityRules)`, `visible_rows(&rules) -> Vec<VisibleRow{relative_path, depth}>`, `collapse_or_select_parent` and `expand_or_select_first_child`, which return a `KeyAction`.
  - `VisibilityRules` {shows_dotfiles, shows_ignored_files, is_git_repository, git_status}.
  - Selection and clipboard: `top_level_selection`, `page_step`, `move_selection_by`, `move_selection_to` and `copied_paths(items, relative)`.
  - Drag and drop: `drop_folder` and `drop_operation(folder, sources, from_explorer, copy_modifier) -> DropOperation`.
  - Filter: `build_filter_tree(files, tokens, &rules) -> FilterNode`, `enumerate_files(root, limit)`, `FILTER_RESULT_LIMIT` and `ENUMERATED_FILE_LIMIT`.
  - Watching: `route_events(paths, roots, external_git_dir, &snapshot) -> EventRouting` and `git_refresh_delay(immediately, since_last)`.
- **`operations`**
  - `FileExplorerOperations`, built with `new()` (system trash) or `with_trash(Box<dyn TrashBin>)`.
  - Operations: `create_file`, `create_folder`, `rename`, `move_items -> Vec<(source, target)>`, `copy_items`, `duplicate` and `trash`.
  - Undo: `undo()`, `redo()`, `can_undo()`, `can_redo()`, `undo_action_name()` and `redo_action_name()`.
  - Callbacks: `on_directories_changed`, `on_undo_failure` and `on_item_moved`.
  - `OperationError` (its `Display` strings match the Swift ones), plus `is_valid_name` and `outermost`.
- **`trash`**: `TrashBin` trait, `SystemTrash`, `DirectoryTrash { directory }` and `TrashedItem`.
- **`watcher`**: `FileSystemWatcher::new(paths, latency, FnMut(Vec<PathBuf>, needs_rescan: bool)) -> Option<Self>`, plus `stop()`, `paths()` and `DEFAULT_LATENCY` (150 ms).

## 2. What was ported
- `GitChanges.swift` → `changes.rs`
- `GitStatusReader.swift` → `reader.rs`
- The `GitFileStatus` and `GitStatusSnapshot` parts of `FileExplorerModel.swift` → `soprano-git/status.rs`
- `GitBranchMonitor.swift` → `branch.rs`
- `SopranoGitLauncher.swift` → `launcher.rs`
- The rest of `FileExplorerModel.swift` → `listing.rs`
- `FileExplorerOperations.swift` → `operations.rs` and `trash.rs`
- `FileSystemWatcher.swift` → `watcher.rs`
- Logic taken from `FileExplorerView.swift` and `FileExplorerRows.swift` → `root.rs` and `tree.rs`: root resolution, preferences, lazy loading, visibility, filter tree, keyboard selection, arrow keys, drop rules, copy paths, event routing and refresh delay.

**Tests ported:**
- `GitChangesTests`: 12 of 17.
- `GitBranchMonitorTests`: 5 of 5, plus a new test that a HEAD change on disk triggers `on_change`.
- `SopranoGitLauncherTests`: 5 of 5.
- `FileExplorerTests`: 22, covering the model and operations parts. The case-only-rename undo test mounts a case-sensitive APFS volume with `hdiutil` on macOS, as the Swift test does.
- New tests for the logic taken from the views.

**Skipped:**
- `GraphLaneTests`: tests theme colours only, no git logic.
- `GitChangesTests`:
  - `SurfaceDiffDocument`/`SurfaceDiffList` (3 tests): the diff view model.
  - The diff-tab tests (2): `AgentManager` behaviour.
- `FileExplorerTests`, AppKit details:
  - Row pill, cell colour, mark layout, rename-field clipping and toast tests.
  - The two live outline-view tests. Their logic is covered by tree, watcher and operations tests.

## 3. Cross-platform decisions and deviations
- **Ranges are byte offsets, not UTF-16.** This applies to `changed_ranges`, the highlight tokens and `stem_range`. They never split a character. For the emoji test, the expected range is therefore `1..5` instead of `(1, 2)`.
- **Highlighting takes a tokenizer closure.** `GitDiffHighlights` is generic so `soprano-git` doesn't depend on the editor's highlighter. Main confirmed it stays in `soprano-git`; TextPort will reuse it.
- **Finding git:** macOS keeps the Swift rules (`/usr/bin/git` is only used when developer tools exist). Linux and Windows use the first `git`/`git.exe` on `PATH`.
- **Branch monitor:**
  - It uses `notify` on HEAD's folder instead of an fd watch on the file, because git replaces HEAD by renaming it.
  - `on_change` fires on the watcher thread, so the UI has to hop to its main thread.
- **Launcher:** on macOS it finds the app with `mdfind` by bundle id, then falls back to `/Applications` and `~/Applications`. It opens with `open -a`. On Linux and Windows `is_available()` is false, `installed_application()` returns None, and `open` reports the step as unsupported.
- **Trash:** I didn't use `soprano_platform::system::move_to_trash` everywhere, because undo needs to know where the item went.
  - On macOS I call `NSFileManager.trashItem(at:resultingItemURL:)` directly through `objc2-foundation`, as the Swift app does.
  - On Linux and Windows it uses `move_to_trash`, then looks the item up with `trash::os_limited::list` and restores it with `restore_all`, refusing if something already sits at the original path.
- **Moves never replace an existing item:**
  - macOS: `renamex_np(RENAME_EXCL)`.
  - Linux: `renameat2(RENAME_NOREPLACE)`, falling back to check-then-rename where the kernel doesn't support it.
  - Windows: check-then-rename, which is not atomic.
  - Moves across volumes copy and then delete, like `FileManager.moveItem`.
- **Undo stack:** `NSUndoManager` is replaced by an explicit undo/redo stack. A new operation clears the redo stack.
- **File watcher:** FSEvents is replaced by `notify` (recursive), with my own 150 ms batching. Dropped events or errors set `needs_rescan`.
- **Paths are not resolved through symlinks**, matching `standardizedFileURL`. On Windows, `real_path` strips the `\\?\` prefix.

## 4. Verification
- `CARGO_TARGET_DIR=target/agent-soprano-git cargo test -p soprano-git -p soprano-files`: 31 and 38 passed, 0 failed.
- `CARGO_TARGET_DIR=target/agent-soprano-git cargo clippy -p soprano-git -p soprano-files --all-targets`: no warnings.
- `CARGO_TARGET_DIR=target/agent-soprano-git-cross cargo clippy --target x86_64-unknown-linux-gnu …` and the same with `--target x86_64-pc-windows-msvc`: both finish, with no warnings from my crates. The only warning is an "unneeded return" in the frozen `soprano-platform/src/shell.rs`, which I didn't touch.
- `cargo fmt -p soprano-git -p soprano-files` has been run.