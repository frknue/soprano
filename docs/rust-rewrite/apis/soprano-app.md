# soprano (app shell) — report from AppShell (stopped at request budget)

| 7. Tests | about 135 tests: content cache, launch specs, IPC, palette, menus, sizing, shell, keyboard, plus 30 sidebar, 22 tab-row/status-bar and 16 pane-header tests |
| Acceptance | build: check passes. Tests: last full run was 101 passed, 7 failed; I fixed my 3 test expectations and SidebarPort fixed its own (I did not see a run of those fixes). ChromePort reports 22/22 passing, but its `agent_badges_show_the_most_urgent_status` failed in that full run and nobody has re-run it. A final `cargo test` + clippy run was still in progress at the deadline. Linux cross-check: not run |

## Architecture
- **`app.rs`** — startup.
- **`workspace.rs`** — `WorkspaceHandle { model: Entity<Workspace>, bus }`. `update()` drains `take_changes()` / `take_events()`, notifies, and publishes a `WorkspaceUpdate`.
- **`shell.rs`** — `Entity<Shell>` holds chrome state (sidebar, keybinding mode, held Control, page, popups). The `Command` enum is the single path for app-level work; every close is `Command::Close(CloseTarget)`.
- **`main_view.rs`** — window root: layout, command execution, closes, dialogs, pickers, Settings, Dashboard, toasts, keystroke interceptor, IPC handling, notification routing, clipboard prompts.
- **`content.rs`** — `ContentHost`: content entities cached by pane/tab; terminal and chat events update the workspace; running-command sampling every second; the 2.5 s Codex readiness timer. A test-only terminal factory means no test spawns a shell.
- **`views/`** — `split_tree.rs` (mine); `sidebar.rs` + `sidebar/model.rs` (SidebarPort), `tab_rows.rs` + `status_bar.rs` (ChromePort), `pane_header.rs` (PaneHeaderPort), all three delegated to sub-agents.
- **Smaller modules** — `palette.rs`, `menus.rs`, `ipc.rs`, `keyboard.rs`, `sizing.rs`, `window_chrome.rs` (the only per-OS module).

## Content crates integrated
soprano-term, -browser, -explorer, -settings, -notify, -chat-ui (+ -chat), -dashboard, -ui, plus every finished non-UI crate. **Not integrated:** soprano-editor and soprano-automations / -automations-ui.

## Open gaps
- **Unsaved-editor check on close:** the Save / Don't Save / Cancel step needs soprano-editor's `EditorDocuments`. Until it is wired, nothing ever asks before a close, and quitting does not ask about unsaved buffers.
- **Chat tabs and the dashboard:** a reply typed in the dashboard to a chat tab fails, and the dashboard shows chat tabs as unavailable; only terminal agents work there.
- **Automations:** banner clicks for an automation run open the placeholder page, and background starting of automation runs has no caller yet.

## Deviations
- Zoom (`⌘=` / `⌘-` / `⌘0`) scales the whole UI including terminal font size, per the brief; Swift only changed the terminal font.
- The saved window frame is stored in top-left coordinates under the same key, so a frame imported from the Swift app may come back clamped to the screen.
- The keymap entries behind the Commands menu exist only so the menu shows its shortcuts; the keys themselves are handled by the resolver.
- Several gpui widgets were added by the sub-agents and are covered in their reports: workspace delete in the session menu, a Close Window context-menu item, the `+` menu reading "Markdown File…", and the status bar keeping Swift's session/window/pane counts.

## Commands run
- `CARGO_TARGET_DIR=target/agent-soprano cargo check -p soprano --tests` → passes, with warnings for unused items (they belong to the Automations/editor wiring).
- `cargo test -p soprano` → 101 passed, 7 failed in the last completed run, before the fixes above.

## What to do next
1. Read the result of the final test + clippy run (job `bg_291`).
2. Integrate soprano-editor: editor, diff and Markdown reader panes; the close-confirmation predicate with the Save / Don't Save / Cancel dialog; no preview tabs for dirty files.
3. Integrate soprano-automations-ui: implement the automations host trait on the workspace + content host, start the controller, render `AutomationsPage`, and open a run from a banner click.
4. Run `cargo fmt -p soprano`, `cargo clippy -p soprano --all-targets` and `cargo check --target x86_64-unknown-linux-gnu -p soprano`.

[irc] Main → me: Lead: review notes for the app shell (docs/rust-rewrite/reviews/automations-explorer.md 'Outside these crates'): nothin…

## assistant

→ write(agent://Main) ⇒ ok · 1 line

## assistant

The app crate `crates/soprano` builds (`cargo check -p soprano --tests` passes), but it is not finished: the Automations page and the editor, diff and Markdown reader panes are not integrated. I stopped at the request budget.

## Wiring you asked to confirm
- **IPC server:** started at launch on `endpoint_for_pid` (`ipc.rs`, `app.rs`). Every request is handled on the UI thread in `MainView::handle_request`, and `SOPRANO_SOCKET` is passed to every pane through `LaunchContext`.
- **NotificationManager:** created at startup and asks for permission once.
  - It receives: CLI agent events, chat-tab agent events, OSC 9/777 terminal notifications, terminal focus, app activate/resign, workspace changes, and a 1 s tick.
  - A banner click brings the app forward and focuses the tab it names.
- **Browser automation:** `open`, `open-split` and `new` spawn a browser pane. Other commands find the target tab and focus it, look its view up in `BrowserRegistry` on the next turn, run `perform_automation`, and reply on the socket.
- **AutomationController / AutomationsPage: not wired.** The Automations page still shows a placeholder title, and the controller is never started. Missing pieces:
  - an implementation of soprano-automations' host trait over the workspace and the content host
  - the 30 s tick, the 15 s retry while terminals wait, and the drain on wake
  - the `workspace_changed` call after model changes
  - rendering `AutomationsPage` and handling its four events
  - opening a run when its banner is clicked

## Other gaps
- **soprano-editor:** not integrated. Editor, diff and Markdown tabs have no view, and closing a tab or quitting never asks about unsaved edits.
- **Chat tabs from the Agent Dashboard:** typing a reply to a chat tab in the dashboard fails, and the dashboard shows chat tabs as unavailable. Terminal agents work.
- **Never run on screen:** I did not launch the app, so layout, clicks, dragging and the Linux/Windows window buttons are untested beyond unit and window tests.

## Integrated
soprano-term (terminal panes, copy mode, clipboard prompts, drops), soprano-browser, soprano-explorer (Files/Changes sidebar), soprano-settings (Settings card, usage popover), soprano-notify, soprano-chat-ui with soprano-chat (chat tabs), soprano-dashboard, and soprano-ui throughout. The non-UI crates (model, keys, ipc, launch, config, accounts, git) are in use too.

## How the crate is built
- **`app.rs`:** startup order: settings.json, accounts, theme, workspace (restored when `restoreLastSession` is on), notifications, CLI socket, then the window. Closing the window or quitting saves the workspace and window frame.
- **`workspace.rs`:** the model sits inside a GPUI entity. Every change goes through `WorkspaceHandle::update`, which drains the model's change log, notifies views, and publishes what changed.
- **`shell.rs`:** shared chrome state (sidebar width and visibility, keybinding mode, held Control, the open page, popups). Its `Command` enum is the single path for app-level work; every close goes through `Command::Close`.
- **`main_view.rs`:** the window root. It does the Herdr layout, runs commands, handles closes and dialogs, the command palette and pickers, Settings, the Dashboard and toasts.
  - It also answers the CLI and routes notifications.
  - A keystroke interceptor sends every key through the keybinding resolver before any pane sees it.
- **`content.rs`:** each tab's terminal, browser or chat view, cached per pane and tab so a layout change never restarts a terminal. It turns terminal reports back into workspace updates and samples running commands every second.
- **`views/`:** I wrote the split tree. Three helper agents wrote the sidebar, the tab rows and status bar, and the pane header.
- **Smaller modules:** `palette.rs`, `menus.rs` (macOS menu bar), `ipc.rs`, `keyboard.rs`, `sizing.rs`, `window_chrome.rs` (the only per-OS module).

## Swift ported
`main.swift`, `AppDelegate`, `MainWindowController`, `MainContentViewController`, `MainWindowSizing`, `SidebarView`, `SplitTreeView`, `PaneHeaderView`, `StatusBarView`, `StatusCountBadgeView`, `LayoutTabBarView`, `WindowTabBarView`, `TabPillButton`, `MarkdownFilePicker`, the command palette and its pickers, the Commands menu, and the ThemeManager glue. `SidebarWidthStore` is reused from soprano-explorer, which already ported it; it is not copied here.

Tests ported: `MainWindowSizingTests`, `SidebarResizeTests`, the sidebar test files, `LayoutTabBarTests`, `WindowTabBarTests`, `StatusBarViewTests`, `ActiveLocationIndicatorTests`, `RunningCommandIndicatorTests`, `PaneHeaderCloseButtonTests`, the `ThemedSplitView` divider maths, and the view parts of `TerminalSession` and `WorkspaceRestore`.

## Test results
- **Last full run:** 101 passed, 7 failed.
- **Fixes since:** I fixed my three failing test expectations and the sidebar helper fixed its three, but I have not seen a run with those fixes. The tab-row helper says its 22 tests pass, yet `agent_badges_show_the_most_urgent_status` failed in that run and nobody re-ran it.
- **Final run:** `cargo test` plus clippy (job `bg_291`) was still running when I stopped.
- **Linux cross-check and formatting:** `cargo check --target x86_64-unknown-linux-gnu -p soprano` was not run, and neither was `cargo fmt -p soprano`.

## Changes from the Swift app
- **Zoom:** `⌘=`/`⌘-`/`⌘0` scales the whole UI including the terminal font, as the brief asked; Swift only changed the terminal font.
- **Window frame:** stored in GPUI's top-left coordinates under the same key, so a frame carried over from the Swift app may come back clamped to the screen.
- **Commands menu:** its key bindings exist only so the menu shows its shortcuts; the keys themselves are handled by the keybinding layer.
- **Helper agents' changes:** these are in their reports, e.g. Load/Delete for saved workspaces, the pane `+` menu reading "Markdown File…", and the status bar keeping Swift's session/window/pane counts.

## Next steps
1. Read the result of job `bg_291`.
2. Integrate soprano-editor: the three pane views, the Save / Don't Save / Cancel question before closes and quit, and never opening an edited file as a preview tab.
3. Wire the Automations controller and page as listed above.
4. Run `cargo fmt -p soprano`, `cargo clippy -p soprano --all-targets` and the Linux cross-check.

Nothing was committed.