I found 7 issues in views and lifecycle, listed most severe first. The other areas I compared match Swift. The test run in your worktree doesn't compile right now (details at the end). The same command on a clean copy of the last commit gave **112 passed, 0 failed**.

## Findings

**1. P1 — Linux/Windows: the in-app close button quits without asking about unsaved files and without saving the workspace.**
- Rust: `window_chrome.rs:137` — the close button calls `window.remove_window()`. I checked GPUI 0.3.12: that call skips the `on_window_should_close` hook (`app.rs:142-155`). GPUI then drops the window and quits. The quit hook (`app.rs:174-185`) tries to update the window, finds it gone, and saves nothing.
- Swift: `MainWindowController` `windowShouldClose` → `confirmClosingAll()`; `applicationWillTerminate` → `saveLastWorkspaceIfNeeded()` (`AppDelegate.swift:96-98`).
- What the user sees: unsaved editor changes are dropped without a prompt. With `restoreLastSession` on, the last workspace is never saved, so the next launch restores an old one.
- Fix: route the button through the same path as Quit (`cx.dispatch_action(&menus::Quit)`, which calls `request_quit`). Or have `MainView` save and ask before removing the window.

**2. P2 — macOS: quitting from the Dock, or by logging out, skips the unsaved-changes question.**
- Rust: only the in-app Quit action (⌘Q, menu item) goes through `request_quit` (`app.rs` Quit handler). GPUI's macOS layer has no `applicationShouldTerminate:` (I searched `gpui-pre-macos-0.3.12/src/platform.rs`: only `applicationWillTerminate:`). A system `terminate:` goes straight to the quit hook, which saves the workspace but discards unsaved files.
- Swift: `AppDelegate.applicationShouldTerminate` returns `confirmClosingAll() ? .terminateNow : .terminateCancel` for every quit source.
- Fix: add an `applicationShouldTerminate:` method to GPUI's app delegate class (objc2 is already used in `window_chrome.rs`). It should return cancel and call `request_quit` when files are unsaved.

**3. P2 — Pages (Agent Dashboard, Automations) remove the window chrome the top row carried.**
- Rust: `main_view.rs:1875-1921` — `render_work` replaces both tab rows with the page. Those rows held the drag region, the 76 px traffic-light inset, and the Linux/Windows min/max/close buttons (`tab_rows.rs:255,363,520`). Neither page has a drag region of its own.
- Swift: `MainContentViewController.pageConstraints` keeps the page right of the traffic lights while the sidebar is hidden (`viewDidLayout` updates the inset). The native title bar stays draggable.
- What the user sees:
  - macOS, sidebar hidden: the page's top-left sits under the traffic lights, and nothing drags the window.
  - Linux/Windows: the window buttons disappear while a page is open. With the sidebar also hidden, the window can't be moved or closed with the mouse.
- Fix: render a slim top row above the page with the drag region, the inset and the window buttons. Or pad the page by `traffic_light_inset` and add the window buttons on Linux/Windows.

**4. P2 — Closing the account-usage card leaves no keyboard focus.**
- Rust: `shell.rs:144-155` — `show_popup` moves focus into the popup, but on dismiss it only clears `popup`. `ContextMenu` restores the previous focus itself (`soprano-ui/src/menu.rs:198`). `AccountUsagePopover` doesn't: Esc or a second click on the usage segment just emits `DismissEvent` (`usage_popover.rs:286-292`). `MainView` reacts to the shell change with `cx.notify()` only and doesn't call `sync_keyboard_focus`.
- Swift: the card is a child window; closing it gives the keyboard back to the main window's terminal.
- What the user sees: after Esc on the usage card, typing reaches no terminal until something changes in the workspace or you click.
- Fix: in `show_popup`, save `window.focused(cx)` and restore it on `DismissEvent`. Or have `MainView` call `sync_keyboard_focus` when the popup goes from Some to None.

**5. P3 — Working and Starting agents no longer recede in the sidebar.**
- Rust: `views/sidebar/model.rs:356` — `recedes` is set only for `Idle | Stopped`.
- Swift: `SidebarView.swift:713` — `[.running, .starting, .idle, .stopped].contains(status)`. Only Waiting and Error rows stand out.
- What the user sees: working and starting agent rows draw at full foreground, so panes that need you stand out less.
- Fix: `matches!(a.status, AgentStatus::Running | AgentStatus::Starting | AgentStatus::Idle | AgentStatus::Stopped)`.

**6. P3 — The window frame carried over from the Swift build is restored upside-down vertically.**
- Rust: `StateStore::for_app` imports `soprano-main-window-frame-v2` from the Swift `UserDefaults` (`soprano-platform/src/state.rs:31-37,106`). That value is an AppKit frame with its origin at the bottom-left, y pointing up. `sizing::load_frame` (`sizing.rs:135-139`) reads it as GPUI coordinates (top-left origin).
- Swift: `MainWindowFrameStore` saves and loads AppKit coordinates.
- What the user sees: on the first Rust launch the window jumps vertically. With a monitor above or below, it can land on the wrong display or fall back to the default frame.
- Fix: flip y during the import, using the primary screen height: `y = primary_height - (y + height)`. Or don't import that key.

**7. P3 — Every move or resize event rewrites the whole `state.json` on the main thread.**
- Rust: `main_view.rs:237-240` calls `save_window_frame` on every bounds change. `StateStore::set_raw` writes the full file synchronously each time (`state.rs:79-86`), and that file includes the saved workspaces.
- Swift: also saved on every `windowDidMove`/`windowDidResize`, but `UserDefaults` writes to disk lazily.
- What the user sees: live resizing and dragging stutter more as `state.json` grows.
- Fix: save the frame when the window closes or the app quits (already done in `save_last_workspace_if_needed`). Or delay the save until moving stops.

## Areas that match Swift
- **Sidebar:**
  - brand row with the session menu
  - window rows: number, title, badges with counts tooltip, ⌃N hint, close on hover, rename / reset name, click / double-click to collapse
  - Collapse All enable rule
  - pane rows: title, meta line, pill, hint caps, shown while Control is held or a hint is typed, close, first/tab/window gaps
  - "+" menu entries and strings
  - Saved Workspaces list
  - the Automations row and its selected state; clicking a row closes the Automations page
  - resize: clamped against the right sidebar, double-click resets, width saved on release, visibility saved
- **Tab rows:**
  - layout tab titles and badges, tooltip order (agents, then running commands)
  - middle-click and × close through the confirmation path, wheel to switch tabs
  - active tab kept in view
  - window tabs skip updates while hidden by `hideWindowTabs`
  - the sidebar toggle shows on the top row while the sidebar is hidden
- **Pane header:**
  - tabs show once a pane has more than one, with the "●" attention-first prefix and tooltips
  - `+` menu entries, disabled at 10 tabs with the same tooltip
  - close button closes only the active tab
  - status pill or RUNNING mark, and the header tint
- **Status bar:** mode pill words and tones, location runs, counts plus "maximized" and "N needs you", usage segment and card, palette and prefix hints from current bindings, uptime.
- **Split tree:** divider percentage math (clamped 10–90), the maximized pane shown alone while hidden panes keep their content.
- **Terminal lifecycle:**
  - Stop and Restart for chat and terminal, including a stopped tab that hasn't started yet
  - agent resume through the conversation in the launch, readiness timer, starting automation terminals in the background
  - close requests, command-finished and process-exit reports, copy mode cancelled when focus moves away
  - restoring a workspace replaces the cached content
- **Startup, quit and frame:** restore at launch when `restoreLastSession` is on, save on quit and on closing the window, frame rules (`initial_frame` / `is_restorable` / `clamped`) and minimum size.
- **Live theme and config changes:** theme and system appearance update the terminal palette and zoom. `config_changed` covers everything Swift's `applyConfigChange` does: theme, window bar, hide window tabs and uptime (through the shell settings), key bindings, Commands menu, agent profiles, refreshing an open Settings screen, plus a new automations tick.

## Tests
- `CARGO_TARGET_DIR=target/review-app cargo test -p soprano` in the worktree fails to compile right now. An uncommitted refactor is in progress: `soprano-types/src/layout.rs` is new, and `soprano-model`, `soprano-keys`, `soprano-ipc`, `soprano-browser` plus 9 files in `crates/soprano` are modified. The errors are unresolved `soprano_types::{NavigationDirection, SplitDirection, TerminalTarget}`. Those edits aren't mine; I didn't touch them.
- To still get a result, I extracted the last commit (`ff03856`) with `git archive` into `/tmp/soprano-review-head`, copied the `ghostty` submodule into it, and ran the same command there (same target dir): **112 passed, 0 failed**. The findings above are from reading the worktree source; the parts they cite weren't changed by that refactor.