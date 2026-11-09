# soprano-agents-and-chat — API report from ConversationPort

Both crates are done and pass: `cargo test -p soprano-agents -p soprano-chat` runs 111 tests with 0 failures, and clippy with `--all-targets` reports no warnings after `cargo fmt`. The Linux and Windows cross-checks could not run, because the bundled SQLite C code doesn't build on this Mac for other targets. So the Windows-only code in `rpc.rs` has not been compiled.

## 1. Public API

### soprano-agents (no gpui)
Deps: soprano-types, soprano-platform, serde_json, chrono, notify 8, rusqlite 0.37 (`bundled`), regex.

- **`timeline`**
  - `Date = chrono::DateTime<Utc>`.
  - `AgentTranscriptFormat { ClaudeCode, Codex, Omp, OpenCode }`, with `::from_profile_id(&str)`.
  - `AgentTimeline { items }`: `from_entries(&[AgentTranscriptEntry])`, `from_entries_with_limit`, `running_tool()`. Limit constants `ITEM_LIMIT=400`, `OUTPUT_*`, `DIFF_LINE_LIMIT`.
  - `AgentTimelineItem { id, timestamp: Option<Date>, kind }`, with `tool_call()` and `is_prompt()`.
  - `TimelineItemKind::{Prompt, Reply, Thinking, Tool(AgentToolCall), Notice{text, is_error}}`.
  - `AgentToolCall { name, summary, detail, state, output, diff, finished_at }`: `new(name, summary)`, `apply(&AgentToolResult)`.
  - `ToolCallState::{Running, Succeeded, Failed, Interrupted}`.
  - `AgentToolResult`; `AgentTranscriptEntry { id, parent_id, items, results: BTreeMap, dropped_item_ids }`.
  - `trait AgentTranscriptDecoding: Send { fn entry_for_line(&mut self, &[u8]) -> Option<AgentTranscriptEntry> }`.
  - Helpers: `display_path`, `first_line`, `excerpt`, `diff_excerpt`, `parse_date`, `date_from_millis`, `date_from_value`.
- **Decoders:**
  - `ClaudeTranscriptDecoder::new()` and `CodexRolloutDecoder::new()`.
  - `OmpSessionDecoder::new(cwd)`, which also exposes `tool_call(&Object)` and `result(&Object, Option<Date>)`.
  - `OpenCodeMessageDecoder { cwd }` with `entry(id, kind, data, &[PartRow])` for 2.x and `legacy_entry(id, data, &[Vec<u8>])` for 1.x.
- **`store`**
  - `AgentTranscriptSource::new(profile_id, Option<&AgentConversation>)` and `.make_reader(home)`.
  - `trait AgentTranscriptReader { source(), read_appended() -> Option<AgentTimeline>, watched_path() }`.
  - `TranscriptFollower` (constants `INITIAL_WINDOW`, `ENTRY_LIMIT`, …).
  - `AgentTranscriptLocator::transcript_path(format, id, home)`.
  - **`AgentTranscriptStore`**:
    - Constructors `new()` / `with_home(PathBuf)`.
    - `set_on_change(Fn(&str))`, which runs on the store's worker thread.
    - `start_polling(Duration)` (`DEFAULT_POLL_INTERVAL` = 1s).
    - `track(HashMap<entryId, Source>)`, `refresh()`, `timeline(id)`, `is_tracking(id)`.
- **`opencode_reader`:** `OpenCodeTranscriptReader::new(source, home)` and `with_environment(…)`.
- **`chat_turns`** (the shared turn model)
  - Types: `ChatThread { preamble, turns, queue }`, `Turn`, `TurnItem`, `TurnItemKind`, `TurnItemStatus`, `TurnStatus`, `TurnCommand`, `FileChange` + `FileChangeKind`, `ToolCall` + `ToolCategory`, `ApprovalRequest`, `ApprovalKind`, `ApprovalDecision`, `ApprovalOption`, `UserInput*`, `UserMessage`, `ChangedFileStat`.
  - `trait ApprovalOptions` on `[ApprovalOption]`: `approve_option` / `decline_option` / `more_options`.
  - Functions: `diff_line_count(&str)`, `turn_duration_text(f64)`.
  - On `Turn`: `changed_files()`, `pending_approval()`, `duration_seconds(now)`.
- **`transcript_thread`:** `ChatThread::from_transcript(&AgentTimeline, is_running)` and `ChatThread::kind_of(&AgentToolCall)`.
- **`omp_edit_preview`:** `omp_edit_changes(tool, &JsonValue, &dyn Fn(&str)->String) -> Vec<FileChange>`.
- **`activity`:** `AgentTimelineActivity::current(Option<&AgentTimeline>, AgentStatus, now)`, which carries `glyph/title/code/detail/elapsed/tone` and `text()`. Also `activity_duration(f64)`.
- **`dashboard`**
  - `AgentDashboardEntry` (the minimal input struct; the caller fills a precomputed `title`), with `id()` and `location()`.
  - `trait DashboardEntryStatus` (`status`, `needs_attention`), so another entry type can be used through a newtype.
  - `AgentDashboardSnapshot::<E>::new(Vec<E>)`: sorts by urgency and gives `total_count` / `working_count` / `needs_input_count` / `error_count`.
  - `AgentDashboardSection::{NeedsYou, Working, Ready, Stopped}` with `of`, `title`, `group(&[E]) -> Vec<(Section, Vec<E>)>`.
  - `elapsed_text(status, started_at, now)`.
- **`json`:** `JsonValue = serde_json::Value`, plus `JsonValueExt` (`non_empty_string`, `int`).

### soprano-chat (no gpui; depends on soprano-agents and re-exports `chat_turns::*`, `JsonValue`, `omp_edit_changes`)
- **`rpc`**
  - `JsonRpcError { code, message }`, with `closed()`, `is_closed()`, `METHOD_NOT_FOUND`, `INTERNAL_ERROR`.
  - `PeerEvent::{Notification, Request{id, method, params}, Response{id: u64, result}, Exit{status, stderr}}`.
  - `PeerSink::new(peer_id, Sender<(u64, PeerEvent)>, Option<waker>)`.
  - `trait JsonRpcPeer { start(sink), request(method, params) -> Result<u64, JsonRpcError>, notify, reply(id, result), terminate(), has_exited() }`.
  - `JsonRpcConnection::new(argv, cwd, env)` / `with_grace_period(…)`, plus `wait_for_exit()` and `process_id()`.
- **`turn_builder`**
  - `AcpTurnBuilder::new(cwd, AcpToolStyle::{Omp, Generic})`.
  - Methods: `apply(&Value, Date) -> bool`, `add_prompt`, `add_steer`, `mark_stop_requested`, `finish_turn(stop_reason, failure, date)`, `add_notice`, `add/resolve_approval`, `add/resolve_user_input`, `set_replaying`, `thread()`.
  - Free functions: `unified_diff`, `acp_unified_diff`, `relative_path`, `argument_path`, `text_of`, `content_text`, `input_text`.
- **`session`**
  - `LaunchSpec { argv, cwd, env }`.
  - `AgentChatLaunch::new(&AgentProfile, LaunchSpec)`, with `supports(id)` and `chat_profiles()`.
  - **`AgentChatSession`**:
    - Construct with `new(launch)` for a real process, or `with_peer_factory(launch, Box<FnMut>)` for tests.
    - Callbacks: `set_on_change`, `set_on_event(FnMut(&AgentChatEvent))`, `set_waker(Fn + Send + Sync)`.
    - Driving: after the waker fires, the owner calls `process_events()` or `wait_and_process_events(timeout)`.
    - Lifecycle: `start(Option<&str>)`, `stop`, `restart(fallback)`.
    - Prompts: `send`, `steer`, `cancel`, `compact`, `remove_queued_prompt(id)`, `remove_queued_prompt_at`, `send_queued_prompt_now(id)`, `queued_prompts`.
    - Settings: `set_config_option(id, value)` covers model, thinking level and mode.
    - Interactions: `choose_permission_option(id)`, `answer_question(Map)`, `decline_question`.
    - Getters: `phase`, `interaction`, `config_options`, `plan`, `commands`, `context_usage`, `session_id`, `can_compact`, `is_running`, `thread()`.
  - `AgentChatEvent::{Status{status, waiting_reason, notify, message}, Conversation{id, cwd}, Title}`.
  - Supporting types: `ChatPhase`, `ChatInteraction`, `AgentChatPermission`, `AgentChatQuestion` (`new` / `user_input_request` / `content` / `answers`), `AgentChatConfigOption`, `AgentChatPlanEntry`, `AgentChatCommand`.

## 2. Ported files and tests

| Swift | Rust |
|---|---|
| `AgentTimeline.swift` | `timeline.rs` |
| `ClaudeTranscriptDecoder.swift` | `claude.rs` |
| `CodexRolloutDecoder.swift` | `codex.rs` |
| `OmpSessionDecoder.swift` | `omp.rs` |
| `OpenCodeMessageDecoder.swift` | `opencode.rs` |
| `AgentTranscriptStore.swift` | `store.rs` |
| `OpenCodeTranscriptReader.swift` | `opencode_reader.rs` |
| `ChatTurns.swift` | `chat_turns.rs` |
| `TranscriptThread.swift` | `transcript_thread.rs` |
| `OmpEditPreview.swift` | `omp_edit_preview.rs` |
| `AgentDashboardSnapshot.swift` (+ the dashboard's elapsed-text function) | `dashboard.rs` |
| Logic of `Views/AgentTimelineActivity.swift` | `activity.rs` |
| `JSONValue.swift` | `JsonValue` + `JsonValueExt` in soprano-agents |
| `JSONRPCConnection.swift` | `rpc.rs` |
| `ACPTurnBuilder.swift` | `turn_builder.rs` |
| `AgentChatSession.swift` | `session.rs` |

All decoder, reader, timeline, thread and follower tests are ported. Tests I added beyond the Swift suite: an append/partial-line follower test, a locator test, a store integration test, an omp-edit-preview test, a mode/plan/context-usage test and a JSON-RPC test that pending requests fail as closed before the exit event.

Skipped, with reason:
- **AppKit / UI details:** the font and label-truncation checks in the activity tests, and the `TimelineBuilder` rows and fold-label checks. The fold labels are covered through `turn_duration_text` and turn durations instead.
- **`AgentWaitingReasonTests`:** all of them test `AgentEventCommand` (soprano-ipc) and `TerminalConfig` (launch), which are outside these crates.
- **`AgentDashboardTests`:** only the snapshot and grouping tests are ported. The rest test `AgentManager` or views.
- **`AgentChatTabTests`:** only the status/conversation/title event sequence is ported. The others test `AgentManager` or `SplitTreeView`.
- **`theChatLaunchesTheAgentsACPServerThroughTheLoginShell`:** building the shell command line is soprano-launch's job now.

## 3. Cross-platform decisions and deviations
- **Async to callbacks:** Swift's main-actor `async` code is replaced by an event-driven session. Agent output goes onto a channel, a waker fires on a background thread, and the owner calls `process_events()` on its own thread. Responses are matched to what each request was for, and events from an old process are tagged by peer id and ignored.
- **Transcript store:** reads on a worker thread. `notify` watches the transcript's directory, including SQLite `-wal`/`-shm` files, and polling covers transcripts that don't exist yet. The change callback runs on the worker thread, so the UI must hop it onto its own executor.
- **Process termination:**
  - On Unix: SIGTERM, then SIGKILL after the grace period. The grace timer starts at `terminate()` instead of at `waitForExit`; the session always waits anyway.
  - On Windows: there is no SIGTERM for a console child, so `terminate()` kills the process immediately.
  - Exit status is the exit code, or the signal number when a signal ended the process, matching `terminationStatus`.
  - The exit event waits for stdout to close. If the agent leaves a background process holding stdout, the exit event would hang; this is not a problem with the `exec` launch.
- **Text handling:** character counts are Unicode scalars, not grapheme clusters. Paths outside the session directory are shortened to `~/…` with `soprano_platform::paths::abbreviate_home`. A stray `\` at the end of a Codex `cmd` literal is kept.
- **Placement:** `JsonValue`, the turn model and `OmpEditPreview` live in soprano-agents, because the transcript thread and the edit preview need them there; soprano-chat re-exports them. `AgentChatLaunch` takes a `LaunchSpec` instead of building a shell command.
- **Dashboard entry:** `AgentDashboardEntry` takes a precomputed `title` instead of `TerminalTitle` / `PaneContextLine`, so this crate does not depend on soprano-model. ModelPort will export its own entry type; the app can implement `DashboardEntryStatus` for it through a newtype.

## 4. Commands run
- `CARGO_TARGET_DIR=target/agent-soprano-agents cargo test -p soprano-agents -p soprano-chat`: 111 passed, 0 failed.
- `CARGO_TARGET_DIR=target/agent-soprano-agents cargo clippy -p soprano-agents -p soprano-chat --all-targets`: clean.
- `cargo fmt -p soprano-agents -p soprano-chat`: applied.
- `cargo check --target x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc` for soprano-chat: both fail inside rusqlite's bundled SQLite C build (no Linux cross-gcc and no Windows SDK headers on this Mac).