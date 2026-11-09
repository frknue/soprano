# soprano-explorer — API report from ExplorerUi

`crates/soprano-explorer` is done. All 30 tests in `cargo test -p soprano-explorer` pass, `cargo build -p soprano-explorer --examples` builds, clippy over all targets has no warnings, and `cargo fmt --check` is clean. The Linux cross-check is clean. The Windows cross-check couldn't run because gpui-pre's own build script fails when cross-compiling from macOS, so the Windows-only code (Open-in detection, the `clipboard-win` file clipboard) has not been compiled yet. I did not launch the demo or any GUI.

## Public API

The panels never open tabs or change the workspace themselves. They emit events and the app does the work, which fits your `Entity<Workspace>` contract: the shell only calls `set_working_directory` when the focused pane changes.

**Events**: one enum, `SidebarEvent`, emitted by `FilesPanel`, `ChangesPanel` and `RightSidebar` (which re-emits its panels' events):
- `OpenFile { path, preview, focus }`
- `OpenDiff { path, staged, preview, focus }`
- `OpenMarkdownPreview { path }`
- `OpenInTerminal { directory }`
- `FocusPane`
- `ItemMoved { from, to }`
- `ShowError(String)`, meant for the app's `ToastStack`.

**Dragging rows out**: the payload is `ExplorerDrag { pub items: Vec<(PathBuf, bool)> }` with `paths()`. Terminals accept it with `on_drop::<ExplorerDrag>`; dragged out of the window it becomes a native file drag.

**Other helpers**: `diff_tab_title(name, staged)` gives `name (diff)` / `name (staged diff)`, and `NO_ROOM_MESSAGE` holds Swift's "No room for another tab or pane in this window." text.

**`RightSidebar`** (`new(store, window, cx)`):
- Panels and state: `files()`, `changes()`, `tab()`, `is_open()`, `width()`, `frame_width()` (0 while closed).
- Inputs from the shell: `set_available_width(Option<f32>)` (window width minus the left sidebar) and `set_working_directory(Option<&str>, cx)`.
- Focus and visibility: `contains_focus`, `select_tab`, `set_open`, `toggle_open`, `toggle_explorer` (⇧⌘E), `toggle_source_control` (⇧⌘G), `focus_active_panel`, `reset_width`.
- It draws the active card plus a 6 px resize grab on its leading edge; double-clicking it resets the width.

**`FilesPanel`** (`new(store, window, cx)`):
- `set_active` and `set_working_directory(Option<&str>)`. `None` (browser or Markdown tabs) keeps the current root.
- Getters: `root()`, `is_git_repository()`, `git_status()`, `visible_paths()`, `selected_paths()`, `operations()`.
- Actions: `contains_focus`, `focus_tree`, `toggle_folder`, `set_filter_query`, `undo`, `redo`, `rename(path, name)`, `app_did_become_active`.

**`ChangesPanel`** (`new(window, cx)`): `set_active`, `set_working_directory`, `root()`, `change_list()`, `contains_focus`, `focus_list`, `app_did_become_active`.

**Pure state, no gpui** (`sidebar` module):
- `RightSidebarState`, stored under `soprano-right-sidebar-tab` / `-visible` / `-width`.
- `RightSidebarTab`.
- `SidebarWidthStore::{LEFT, RIGHT}` with `clamp`, `load`, `save`. The right sidebar is 280 wide by default, 220 minimum, 800 maximum.
- `PanelToggle`.

**Open in** (`open_in` module): `installed_applications()`, `OpenInApplication::open(folder)`, `warm_up()`.

## Swift ported
- **Views:** `RightSidebarView`, `FileExplorerView`, `FileExplorerRows`, `SourceControlView`, plus the right-sidebar parts of `MainContentViewController` and `SidebarWidthStore`. The `FileTypeIcon` table comes from soprano-ui.
- **Tests:**
  - The right-sidebar width rules from `SidebarResizeTests`, as state tests.
  - From `FileExplorerTests`: "shows the active pane's project and follows the disk", "an open folder stays open through rename, undo and redo", plus new tests for the filter, the keyboard, inline create and rename, drops, and staying idle while hidden.
  - From `SourceControlViewTests`: "follows the working tree and index", plus key and click opening and the outside-a-repository message.
- **Not ported:** `SidebarSelectionScrollTests` covers the left Windows list, not the explorer. The diff-tab test in `SourceControlViewTests` belongs to the diff view. The AppKit cell, pill and toast tests have no GPUI equivalent.

## Deviations
- **Look follows Herdr:**
  - The git letter colors are A/U green, D red, M in the "blocked" status color, R/C cyan. Swift showed M in yellow.
  - Git-ignored rows are dim italic, with no ignored mark.
  - Busy states show "Loading files…" / "Loading changes…" where Swift had a spinner.
  - The filter field is under the header, and the Changes header shows a file-count badge, the repository · branch, and the total +/−.
- **Toasts:** failures go out as `ShowError` because the toast stack sits in the window root.
- **Shortcuts on Linux/Windows:** ⌘ is Ctrl+Shift and ⇧⌘ is Ctrl+Shift+Alt, as agreed. I mapped ⌥⌘ to Ctrl+Alt so Copy Path (⌥⌘C) and Copy Relative Path (⇧⌥⌘C) don't land on the same keys.
- **Open in:**
  - macOS uses the Swift bundle-ID list, found by scanning the application folders and then Spotlight.
  - Linux offers the file manager (via `xdg-open`) plus known editors, git clients and terminals found on `PATH`.
  - Windows offers File Explorer, `PATH` programs, GitHub Desktop and Fork, and PowerShell.
  - No app icons are shown in the menu.
- **⌘C copies the files themselves:** NSPasteboard on macOS, the native file list on Windows, and `text/uri-list` through `wl-copy`/`xclip` on Linux. If none of those is available it copies the paths as text.
- **Undo history:** a new root starts a fresh operations object, because `FileExplorerOperations` has no way to clear its history.
- **Additions:** ⌘A selects all rows and typing letters jumps to a row's name (both default NSOutlineView behaviour).

Two things live outside this crate:
- **Windows paths:** soprano-files' path-relativity helpers assume `/` separators, which may break the watcher's mapping of changed paths into the tree there.
- **Preview rule for unsaved files:** the app has to make sure a file with unsaved changes is never opened as a throwaway preview, since only it knows which documents have edits.