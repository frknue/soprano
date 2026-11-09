I found no bugs in the automation run lifecycle or the settings.json writes. The problems are in the editor and page keyboard handling, in the explorer, and in the shell: `crates/soprano` never creates the automations controller or page, so automations can't run in the app yet. All tests pass: soprano-automations 40 unit + 18 controller, soprano-automations-ui 29, soprano-explorer 30 (`CARGO_TARGET_DIR=target/review-automations cargo test -p soprano-automations -p soprano-automations-ui -p soprano-explorer`). I edited nothing. I did the automations review myself; two read-only helper agents reviewed the explorer, and I spot-checked several of their findings against the source (noted below).

## Outside these crates, but it decides whether any of this works
- **Nothing in `crates/soprano` uses the automations crates.** `AutomationController`, `AutomationsPage` and `AutomationsPageEvent` have no callers. Nothing calls `tick` (Swift: every 30 s, on wake and on settings changes), `drain`, `workspace_changed` or `retry_waiting_terminals`. No automation ever runs, and the page can't be opened.
- **The page refreshes only when the controller entity is notified.** Swift's settings.json observer reloaded the page at once. When the shell is wired up, it must call `cx.notify()` on the controller entity after `tick`/`drain`/`workspace_changed` and after settings.json changes. Otherwise a hand edit shows up only on the 30 s refresh.

## soprano-automations (controller, scheduling, worktrees, store)
No findings. I compared every part with the Swift side by side:
- **Lifecycle:**
  - due, missed (grace + 60 s slack, only the latest occurrence runs), "Run #N was still working.", the folder check, reused agents (with their precheck and the deleted-meanwhile check), and the 180 s start timeout;
  - waiting for a display, failing open runs on launch and on session restore, and the Done / Needs input / Failed transitions with their banner titles and bodies;
  - the final reply read from the transcript, falling back to the agent's last message and then the visible text.
- **Worktree cleanup:** the run's own branch and folder are removed only when the window closes unviewed and `git status --porcelain --untracked-files=all` is empty and `HEAD` equals the base commit. A worktree whose run never started is discarded only when the automation was deleted while the run was being prepared or its window couldn't open. Nothing else is ever deleted, which matches Swift.
- **Other checks:**
  - settings.json writes (`config_object` at `automations.<id>`; Pause writes `enabled:false`; Resume removes the key);
  - the JSON format of `automations.json` (ISO dates, sorted keys, 100-run pruning);
  - precheck process-group kill and output tail;
  - Claude trust lock and writing through a symlinked config;
  - the data folder is the same `Application Support/<id>` the Swift app used.

## soprano-automations-ui

1. **P2 — ⌘Return in the Prompt field adds a newline instead of saving.**
   - Rust: `editor.rs:124` creates a plain `TextareaState`, and `editor.rs:408-418` waits for ⌘Return in `on_key_down`.
   - In GPUI, key bindings run before key-down listeners. The textarea maps cmd-enter to its `Enter{secondary}` action, inserts a newline and stops there.
   - In one-line fields the same action passes the key on and emits `PressEnter`, so `submit` runs twice. That's harmless, but it's the same root cause.
   - Swift: `AutomationEditorPanel.swift:788-800` ("⌘Return saves from any control, the prompt included").
   - Fix: on the editor root, use `.capture_action(|this, a: &gpui_component::input::Enter, …| if a.secondary { this.submit(..) } else { cx.propagate() })`, and drop the ⌘Return branch from `on_key`.

2. **P3 — ↑/↓ do nothing while the search field has the keyboard.**
   - Rust: `page.rs:343-350` handles arrows in a `capture_key_down`. But the input's `MoveUp`/`MoveDown` actions run first, and in a one-line field they return without passing the key on.
   - Swift: `AutomationListView.swift:303-318` moves the selection from the search field, as in Orca.
   - Fix: `capture_action::<MoveUp/MoveDown>` on the page root while `in_search`. Call `cx.propagate()` when the editor, a dialog or the menu is open, or when the search field doesn't have focus.

3. **P3 — J/K and the arrows don't scroll the selection into view.**
   - Rust: `page.rs` `move_selection` and the return to a run from its report change the selection without scrolling. Run history holds up to 100 rows, so the selection moves off screen.
   - Swift: `AutomationListView.swift:279-286` and `AutomationDetailView.swift:269-276` call `scrollToVisible`.
   - Fix: give each row a tracked scroll target, or compute its offset and scroll the existing `ScrollHandle` after each move.

4. **P3 — Tab in the Prompt field indents instead of moving to the next field.**
   - Rust: the input's `tab` binding is `IndentInline`.
   - Swift: `AutomationEditorPanel.swift:803-811` (`insertTab` → `selectNextKeyView`).
   - Fix: a capture action for `IndentInline`/`OutdentInline` on the prompt that moves focus with `window.focus_next()`/`focus_prev()`.

5. **P3 — The list's last-run pill has no tooltip.**
   - Rust: in `page.rs` `render_list_row` the pill has none. Swift's `AutomationListView.swift:637` sets `lastRunPill.toolTip = lastRun.message`, which is how the list says why a run was skipped or failed.

6. **P3 — Each repaint copies the whole resolved config many times.**
   - Rust: `controller.rs:209-221` `automations()` and `automation(id)` clone the whole resolved config, and `next_run_date` does it again per automation.
   - A single list render does this O(N) times. The page repaints on every workspace change (`page.rs:131` `observe(&workspace)`).
   - Fix: give the controller a borrowed or `Arc` view of the automations, and look each one up once per render.

Checked and matching:
- the list, empty state, the four templates word for word, the search fields, the subtitle and "all paused";
- the state and run pills, including "Input" for Needs input;
- tiles, the failed-run notice, the runs card, Open Run vs Resume Conversation, Reveal Worktree, "Removed, the run changed nothing.", "No report" / "No report yet";
- Esc stepping back (and clearing the search first), ⌘N, J/K, Return and Space;
- delete confirmation text and the write-failure texts;
- editor validation notes, the default id, "Untitled automation", reuse being off for worktree runs, unusual grace/timeout values getting their own options, and the folder list order.

## soprano-explorer (and the shell code that handles its events)

**P1**
- **Opening a change or file leaves the keyboard in the sidebar** (I checked this one).
  - Rust: `main_view.rs:931-944` calls `sync_keyboard_focus`, which returns early when the sidebar has focus (`main_view.rs:1281-1287`).
  - Swift: `SourceControlView.swift` `open(...)` calls `onReturnFocus` → `returnKeyboardFocusToPanes()`.
  - Fix: when `focus` is set and the open succeeded, call `return_keyboard_focus_to_panes`.
- **Both panels follow an editor or diff tab's folder** (I checked this one).
  - Rust: `main_view.rs:974` uses `active_working_directory()`, which is the raw `cwd` (`soprano-model/src/workspace/mod.rs:306`). File tabs are given their parent folder as `cwd` (`workspace/files.rs:81`).
  - Swift: `FileExplorerView.swift:208-210` and `SourceControlView.swift:154-157` use `effectiveWorkingDirectory`, which is nil for these tabs.
  - What the user sees: opening a file in a folder that isn't a git repository moves the explorer into that file's folder, and a nested repository takes over Changes.
  - Fix: use `Tab::effective_working_directory()` (`pane.rs:133`).

**P2**
- **Shift+↑ / Shift+PageUp can't grow the selection past two rows** (I checked this one).
  - Rust: `soprano-files/src/tree.rs:363` moves from `selected.last()`, and `:383` anchors at `selected.first()`. Starting from {5}, Shift+↑ gives {4,5}, then {4}, then {4,5} again.
  - Swift uses NSOutlineView's own behaviour (`FileExplorerRows.swift:178`).
  - Fix: keep an explicit anchor and lead row in `Selection`, and move from the lead.
- **Switching apps in the middle of a rename commits the half-typed name.**
  - Rust: `files.rs:1246` commits on `InputEvent::Blur`. GPUI sends Blur when the window loses activation. This came from the helper's trace through the gpui source; I only confirmed the line.
  - Swift commits only when the field really loses focus (`controlTextDidEndEditing`).
  - For a new item, this creates the file under the partial name. Fix: ignore Blur while `!window.is_window_active()`.
- **Finishing an edit always pulls focus back into the tree.**
  - Rust: `files.rs:1256` always sets `focus_tree_on_render`, including after a click elsewhere, `set_active(false)` or `set_root`.
  - Swift returns focus only `if editorHadFocus` (`FileExplorerView.swift:1168-1174`).
- **No message when there's no room for the tab.**
  - Rust: `main_view.rs:933` and `:940` drop the `None` that `open_editor`/`open_diff` return, and `NO_ROOM_MESSAGE` is never used.
  - Swift shows a toast with that message.
- **Large selections make every frame slow.**
  - Rust: `files.rs:1914` calls `drag_items` for every visible row on every render. With the linear `Selection::contains`, that is O(rows × selected) per row, so ⌘A over 5,000 filter results freezes the UI.
  - Fix: keep the selection in a set, and compute the drag items once per render.

**P3**
- Spring-loading opens a folder the pointer has already left; the timer isn't cleared on leave (`files.rs:1352-1372`).
- Drop targets that would be refused still highlight (`files.rs:1962-1967`).
- Reveal in Finder with several items runs `open -R` once per item instead of selecting them all at once (`files.rs:1039-1046`).
- Ending any inline edit resets the folders collapsed in the filter results (`files.rs:1302`).
- On Linux, names that aren't valid UTF-8 can't be renamed, trashed or opened, because paths are rebuilt from the lossy string.
- On Linux/Windows, trashing lists the whole trash twice on the UI thread (`soprano-files/src/trash.rs:56-66`).
- Double-clicking the resize edge doesn't clamp the width to the window (`sidebar.rs:203-206`).
- The available width goes stale after a window resize.
- `sync_right_sidebar` walks the disk on every workspace update, including title changes (`main_view.rs:1014`).
- Right-clicking a change selects the row (`changes.rs:601-603`).
- `ChangesPanel::app_did_become_active` has no callers.

Checked and matching in the explorer:
- **File operations:** error texts, undo/redo, name validation, case-only rename, never replacing an existing item, " copy N" naming, refusing a move into itself, and trash/restore. None of them can lose data where Swift wouldn't.
- **Drops:** drops on a file go to its parent; Finder drags and ⌥ drags copy; internal drags move; drops are refused while editing.
- **Keys:** the tree's key map, and the filter field's Esc, ↓ and Enter.
- **Menus and strings:** context menu items and their order; the empty-state texts in both panels.
- **Source control:** there is no staging, discard or commit on either side, so there is no discard risk. Grouping and order are Conflicts, Changes, Staged, Untracked.
- **Live updates:** the refresh gate drops stale results; the watcher routes `.git` and external git directory events.
- **GPUI usage:** no entity is updated from a background thread, and tasks and subscriptions are dropped when replaced.