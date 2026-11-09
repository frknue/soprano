# soprano-ipc — API report from IpcPort

I've built `crates/soprano-ipc` (only that crate changed). `cargo test -p soprano-ipc` passes (54 tests) and clippy reports nothing for this crate. The CLI paths now go over a per-instance local socket instead of macOS distributed notifications. The Linux- and Windows-only code has not been compiled: only the macOS target is installed here.

## 1. Public API
- **`cli`**
  - `run_cli(args: &[String], env: &HashMap<String,String>) -> CliOutcome`, where `CliOutcome` is `Exit(i32)` or `StartApp`.
  - Dispatch order is the same as Swift `main.swift`: markdown → browser → agent-event → navigate-pane / navigation-passthrough → `LaunchDispatch`.
  - `run_cli_with(args, env, &mut dyn CliHost)` lets tests swap in their own stdio, cwd, executable path, stdin, hook owner, tmux and transport. `SystemHost` is the real one.
  - `endpoint_from_environment(env) -> Option<Endpoint>` uses `SOPRANO_SOCKET`, falls back to the endpoint derived from `SOPRANO_APP_PID`, and returns `None` when `SOPRANO_APP_PID` is missing or empty.
  - Constants `SOCKET_ENV = "SOPRANO_SOCKET"` and `APP_PID_ENV`.
- **`transport`**
  - `Endpoint` (`new`, `as_str`, `Display`) and `endpoint_for_pid(impl Display) -> Endpoint`.
  - `IpcServer::start(Endpoint) -> io::Result<(IpcServer, Receiver<Incoming>)>` and `server.endpoint()`. Dropping the server stops it and removes the socket.
  - `Incoming { request: Request, reply: Option<Replier> }` and `Replier::send(self, &Response) -> io::Result<()>`.
  - `send(&Endpoint, &Request) -> io::Result<Option<Response>>` and `send_with_timeout(.., Duration)`. `REPLY_TIMEOUT` is 15 s.
- **`protocol`**: `Request`, `Response` (`success(..)` / `failure(..)`), `AgentEvent`, `AgentEventState` (`from_raw`, `raw_value`, `agent_status`, `default_body`), `NavigationDirection`, `PassthroughMode`, `Request::expects_reply()`.
- **`agent_event`**: `agent_event_request(args, env, stdin_fn, hook_owner_fn) -> Option<Request>`, `agent_message`, `agent_message_text`, `waiting_reason`, `summarize`, `MESSAGE_LIMIT` (180), `FULL_MESSAGE_LIMIT` (8192), `hook_owner_process_id(start, app_pid, lookup)`, `current_hook_owner_process_id`, and `process::{parent_id, parent_and_name}`.
- **`alert`**: `AgentAlert::{new(state, reason), title(name), body(agent, tab, window, session)}` and `stripping_status_glyphs`.
- **`navigation`**
  - Request building and handling: `navigation_request`, `handle(args, env, tmux_navigator, post)`, `navigate_within_tmux`.
  - `TerminalTarget { pane_id, tab_id }`.
  - `PaneNavigationClaimRegistry` (`enable`, `disable`, `has_claims`, `synchronize(&HashSet<TerminalTarget>, generation: u64)`). This is app-side state in Swift; it lives here as a plain struct for the keys crate and the app.
- **`markdown`**: `MarkdownCommandRequest::parse(args, env, cwd) -> Result<Option<_>, MarkdownCommandError>` (fields `path: PathBuf`, `opens_new_pane`), `validate_readable_file`, `HELP`.
- **`browser`**: `BrowserCommandRequest::parse(args, env, cwd) -> Result<Option<_>, String>`, `HELP`.
- **`launch`**: `LaunchDispatch::{StartApp, Help, UsageError}::decide(args, env, runs_owning_app)`, `runs_owning_app(exe, env)`, `USAGE`.
- **`caller_cwd`**: `resolve(env, cwd) -> PathBuf`.

### Wire format
Each connection carries one JSON line from the CLI, plus one reply line for markdown and browser requests. Requests are tagged by `"type"` with camelCase fields; responses look like `{"status":"ok","output":…}` or `{"status":"error","error":…}`.

### Request variants and what the app must do
| Variant (fields) | Replaces | App handler |
|---|---|---|
| `AgentEvent(AgentEvent{pane_id, tab_id, state, notify, title, body, profile_id?, process_id?, message?, reason?, conversation?})`, one-way | `com.soprano.agent-event.<pid>` | Run `AgentNotificationManager.handle(AgentEventPayload)` unchanged. `reason` is only set on `needs-input` events. |
| `NavigatePane{pane_id, tab_id, direction}`, one-way | `com.soprano.navigate-pane.<pid>` (`direction`) | If the target is the active terminal target, call `navigate_to_pane(direction)`; otherwise ignore it. |
| `NavigationPassthrough{pane_id, tab_id, mode, source}`, one-way | same notification (`passthrough` / `source`) | `registry.enable` or `registry.disable(source, target)`. On every model change call `synchronize(valid targets, workspace_restore_generation)`. |
| `OpenMarkdown{path, opens_new_pane, caller_pane_id?, caller_tab_id?}`, reply | `markdown-request` / `markdown-response` | Same logic as Swift `MarkdownCommandController.open` (details below). On success reply `success(pane_id)`. |
| `Browser{command, arguments, target_pane_id?, caller_pane_id?, caller_tab_id?}`, reply | `browser-request` / `browser-response` | Same logic as Swift `BrowserAutomationController` (details below). Reply `success(output)` or `failure(error message)`. |

The error strings the app must reply with, copied from Swift:
- **`OpenMarkdown`**
  1. Re-validate that the file is readable, else reply `failure("Cannot read Markdown file: <path>")`.
  2. The owner pane is `caller_pane_id`, or the active pane if there is none. If that pane is gone, or `caller_tab_id` is not one of its tabs, reply `"The calling terminal is no longer available."`.
  3. Without `--new`: `preview_markdown` into the owner pane, or reply `"Could not open a Markdown reader (tab limit reached)."`.
  4. With `--new`: focus the caller tab (or pane), then `spawn_markdown`, or reply `"Could not create a Markdown reader (pane limit reached)."`.
- **`Browser`**
  1. `open`, `open-split` and `new` call `spawn_browser(arguments[0])`. Reply with the new pane id, or `"Could not create a browser pane (pane limit reached)."`.
  2. Otherwise resolve the target pane:
     - With `target_pane_id`: that pane's active browser tab, else its first browser tab, else `"No browser tab exists in <id>."`.
     - Without it: the active pane's active browser tab, else the first browser tab in leaf order, else ``"No browser pane exists. Run `soprano browser open [url]` first."``.
  3. Focus the target tab. If the view is missing, reply `"Browser <pane> is not currently available."`. Otherwise run the automation command.

**Startup:** start the server on `endpoint_for_pid(std::process::id())`. Export `SOPRANO_SOCKET=<endpoint>` to panes alongside `SOPRANO_APP_PID`. Read `Incoming` messages on a thread and hop to the UI thread to handle them.

## 2. Swift ported → Rust
- `LaunchDispatch.swift` → `launch.rs`
- `CallerWorkingDirectory.swift` → `caller_cwd.rs`
- `PaneNavigationCommand.swift` plus `PaneNavigationClaimRegistry` (from `KeybindingManager.swift`) → `navigation.rs`
- `MarkdownCommand.swift` (CLI side) → `markdown.rs` and `cli.rs`
- `BrowserAutomationCommand.swift` (CLI side) → `browser.rs` and `cli.rs`
- `AgentNotificationManager.swift` (`AgentEventState`, `AgentEventCommand`, `AgentAlert`) → `protocol.rs`, `agent_event.rs`, `alert.rs`
- `main.swift` → `cli.rs`
- Distributed-notification routing → `transport.rs`

Tests ported:
- `LaunchDispatch`: 5
- `CallerWorkingDirectory`: 1
- `PaneNavigationClaimRegistry`: 5. The other 5 tests in that file cover `KeybindingManager` pane hints and the prefix key, so they belong to the keys crate.
- `ExternalEventRouting`: 6
- `AgentMessageForwarding`: 11
- `AgentAlert`: 5
- `AgentConversation`, CLI side: 2 (payload carries the conversation; hook owner lookup)
- `MarkdownIntegration`: 1 parse test
- `BrowserIntegration`: 1 parse test

I also added parse and edge-case tests, a process-table check, and 13 transport and CLI round-trip tests against a live server.

Not ported here, with reasons:
- `locationSubtitle` tests: notification manager logic, which belongs to `soprano-agents`.
- The model, view and persistence tests in the Markdown and Browser test files, and all of `BrowserPaneAutomationTests`: these need the workspace model or a web view.
- The two notification-name tests are replaced by endpoint tests, because there are no notification names any more.

## 3. Cross-platform decisions and deviations
- **Socket location (Unix):** `$TMPDIR/soprano-<uid>/<pid>.sock`, falling back to `/tmp/soprano-<uid>/` if the path would exceed 103 bytes. The directory is created owner-only (0700). At startup, sockets of dead pids and our own pid's leftover are deleted.
- **Windows endpoint:** `\\.\pipe\soprano-<pid>`.
- **App not running:** Swift waited 15 s and then printed "Timed out…". Now a failed connection prints the same "Timed out…" message and exit 1 immediately.
- **Markdown path on the wire:** the request carries a file path instead of a `file://` URL.
- **Process lookup for the hook owner:** macOS uses `proc_pidinfo` (same 16-byte `p_comm` as Swift's `sysctl`). Linux reads `/proc/<pid>/stat`. Windows uses a Toolhelp snapshot, strips `.exe`, and also treats `cmd`, `powershell` and `pwsh` as shells.
- **`$PWD` check on Windows:** compares canonicalized paths, since there is no device/inode identity there.
- **`AgentAlert` glyph stripping:** Swift checks `isEmojiPresentation`. Rust uses a static table of Emoji_Presentation ranges instead, so it may differ for rare characters.
- **Message cap:** the 8192 limit counts Unicode code points, where Swift counted grapheme clusters.
- **Types defined locally:** `NavigationDirection` and `TerminalTarget` live in this crate because the frozen crates don't have them.
- **Overlap:** `AgentAlert` and the `AgentEventState` mapping are also on `soprano-agents`' list. Only one of the two copies should end up being used.

## 4. Verification
- `CARGO_TARGET_DIR=target/agent-soprano-ipc cargo test -p soprano-ipc` passed: 41 unit tests and 13 integration tests.
- `cargo clippy -p soprano-ipc --all-targets` reported no warnings for soprano-ipc. It did flag one warning in the frozen `soprano-platform` crate (`shell.rs:13`, collapsible `if`), which I left alone.
- `cargo fmt -p soprano-ipc` was applied.