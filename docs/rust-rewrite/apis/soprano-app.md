# soprano (app shell) — report from AppShell2

`crates/soprano` (bin `soprano`) integrates every content crate. `cargo test -p soprano`: 111 passed. Clippy (all targets): no warnings. Formatted.

## Architecture
- **`app.rs`** — startup: settings.json, accounts, theme, key bindings (terminal, browser, editor, diff, reader), the workspace (restored with `restoreLastSession`), notifications, the CLI socket, then the window. One `EditorDocuments<TerminalTarget>` entity per app, owned by the content host. Quit (menu/⌘Q) goes to `MainView::request_quit`; closing the main window asks first when documents are unsaved.
- **`workspace.rs`** — `WorkspaceHandle { model: Entity<Workspace>, bus }`. `update(cx, |ws| ..)` drains `take_changes()`/`take_events()`, notifies and publishes a `WorkspaceUpdate`. `update_with(cx, |ws, cx| ..)` does the same for work that also needs other entities (the automation host).
- **`shell.rs`** — chrome state and the `Command` enum; every close is `Command::Close(CloseTarget)`.
- **`main_view.rs`** — window root: layout, commands, closes (two-phase, see below), dialogs, pickers, Settings, the Dashboard and Automations pages, toasts, the keystroke interceptor, IPC, notification routing, clipboard prompts, the automation timers.
- **`content.rs`** — `ContentHost`: per pane/tab content (`PaneContent::{Terminal, Browser, Chat, Editor, Diff, Reader, Stopped, Failed}`) cached across layout rebuilds. File tabs (`is_editor`/`is_diff`/`is_markdown`) get `EditorView`/`DiffView`/`MarkdownReaderView`; diffs are `set_shown(false)` while hidden; `WorkspaceChange::Document` re-points a reader and rebuilds an editor/diff whose file changed. It mirrors which tab shows which document and which are dirty (`UnsavedEditors`) and installs the model's close-confirmation predicate from it.
- **`automations.rs`** — `AppHost` (the `AutomationHost` over the leased workspace + content host + notifications) and `drive(context, window, cx, |controller, host| ..)`, which runs a controller call, `cx.notify()`s the controller entity, then starts the terminals the call asked for (`ContentHost::start_background_terminal`, after the workspace lease ends). `create_controller` builds it with `AutomationEnvironment::for_app` and `<data dir>/automations.json`.
- **`terminate.rs`** — macOS `applicationShouldTerminate:` added to GPUI's delegate class: a system quit (Dock, logout) with unsaved files is cancelled and routed to `MainView::request_quit`.
- **`power.rs`** — the only new per-OS module: `display_is_awake()` (macOS `CGDisplayIsAsleep` over the online displays; Linux/Windows: true).
- **`views/`**, `palette.rs`, `menus.rs`, `ipc.rs`, `keyboard.rs`, `sizing.rs`, `window_chrome.rs` — unchanged roles.

## What was integrated in this round
- **soprano-editor:** editor, diff and reader as tab content; every open path ends in the model (`open_editor`/`open_diff`/`open_markdown`/`preview_markdown`/`spawn_markdown`), so explorer events, IPC `OpenMarkdown`, `soprano <file.md>`, the palette's Open Markdown… and the pane `+` menu all show these views. Editor events: title → tab title, `KeepTab` → `keep_editor_tab`, `OpenMarkdownPreview` → the file pane's reader, focus → `focus_tab`. Diff `OpenFile` → `open_editor` (toast `NO_ROOM_MESSAGE` on no room). Reader `DocumentChanged` → `update_file_document`, `OpenExternal` → browser pane for http(s), the system handler otherwise. Explorer `ItemMoved` → `EditorDocuments::relocate` + `relocate_file_tabs`. A file with unsaved changes never opens as a preview.
- **Two-phase close:** `CloseOutcome::NeedsConfirmation` (tabs, panes, layout tabs, windows, sessions, Load Workspace) → `unsaved_when_closing(targets)` → `save_question` in `DialogContent::save_changes` (Don't Save / Cancel / Save or Save All) → `resolve_unsaved`; an overwrite conflict asks "Save Anyway" and continues with the rest; a failed save shows its error and keeps everything open; then `force_close`. Quit and closing the window use `unsaved_when_closing_all`.
- **Automations:** controller created at startup; `tick` every 30 s, at startup and after every settings.json change; `drain` on each wake; `retry_waiting_terminals` every 15 s while `is_waiting_for_display`; `workspace_changed` after every workspace update; the controller entity is notified after each. `AutomationsPage` renders the Automations page (sidebar footer, palette, Commands menu) with RunNow / OpenRun (closes the page when `open_run` is true) / Delete (`show_write_failure` on false) / Dismiss. Banner clicks open the page on the run (`show_run`).
- **Agent Dashboard:** a running chat tab is available (`dashboard_text` returns `Some("")`), and `Reply` to a chat tab goes through `ChatView::submit_prompt` (`reply_failed` on false).
- **Terminal API:** every TerminalView gets the shared `ClipboardConfirmationCoordinator` (`set_clipboard_coordinator`), `Destroyed` also cancels its prompts, prompts are enqueued with `view.entity_id().as_u64()`; CommandFinished after 133;C is soprano-term's own; `LaunchContext::current(socket, shell_integration(&ghostty))`; `main` uses `run_cli_from_process()`.
- **Explorer review items:** focus returns to the panes after a successful OpenFile/OpenDiff with `focus`; the panels follow `PaneTab::effective_working_directory()` and only when it changed; the available width is updated on every window resize.

## Tests added
`file_tabs_show_the_editor_the_diff_and_the_reader`, `closing_the_only_tab_of_an_unsaved_file_asks_first`, `a_file_another_tab_still_shows_closes_without_asking`; fixed `a_stopped_agent_tab_starts_no_process_until_restarted` (it used profile id `claude`; the id is `claude-code`).

## Deviations
- Wake from sleep: `power::WakeDetector`, sampled every second, treats a wall-clock gap of more than 5 s past the interval between two samples as a wake (a timer cannot fire during sleep on any OS) and ticks automations at once, like Swift's `didWakeNotification`; a busy UI thread may cause an extra, harmless tick.
- Zoom follows Swift: ⌘= / ⌘- / ⌘0 change the active terminal's font size; the UI zoom factor stays 1.
- The window frame is saved 500 ms after moving/resizing stops and on close/quit; the Swift app's AppKit frame (`soprano-main-window-frame-v2-appkit`) is flipped to top-left once on first launch.
- Pages (Dashboard, Automations) keep a slim top row with the drag region, the sidebar toggle/traffic-light inset and the Linux/Windows window buttons.

## Commands
- `CARGO_TARGET_DIR=target/agent-soprano cargo test -p soprano` → 116 passed.
- `cargo clippy -p soprano --all-targets` → no warnings; `cargo fmt -p soprano` applied.
- `cargo build -p soprano --release` → see the final report.
- `cargo check --target x86_64-unknown-linux-gnu -p soprano` (zig cc/c++/ar wrappers, `RUST_FONTCONFIG_DLOPEN=1`) → blocked by `x11` (via soprano-browser → gpui-webview/lb-wry → gdkx11): its build script needs pkg-config for the Linux X11/GTK system libraries, and there is no Linux sysroot on this Mac.

Nothing was committed and the app was not launched.
