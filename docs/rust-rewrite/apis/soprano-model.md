# soprano-model — API report from ModelPort

`soprano-model` is finished and has no gpui dependency. All 148 tests pass and clippy is clean on macOS, Linux and Windows. Nothing is left as a TODO. Some Swift tests are view tests and were skipped (listed in §2). Three Swift features are handled by the host instead of the model (see §3).

## 1. Public API

**Modules:** `split_node`, `pane`, `window`, `session`, `session_manager`, `terminal_title`, `agent_instance`, `file_url`, `workspace`. The main types are re-exported at the crate root. Dependencies: soprano-types, soprano-platform, serde, serde_json, `url`, `unicode-general-category`, `libc` (Unix only), `windows-sys` (Windows only).

**Layout tree (`split_node`)**
- `SplitNode::{Leaf(String), Split(Box<SplitBranch>)}`, built with `leaf(id)` and `split(dir, first, second, pct)`.
- `SplitBranch { direction, first, second, split_percentage }`. The percentage is always kept within 10–90.
- `SplitDirection::{Horizontal, Vertical}`, `SplitBranchSide::{First, Second}`, `NavigationDirection::{Left, Right, Up, Down}` (with `from_raw`).
- `PaneFrame { min_x, min_y, max_x, max_y }` with `UNIT` and `span_across`.
- Queries: `leaf_ids`, `insert_leaf_ids`, `ordered_leaf_ids`, `leaf_count`, `contains_leaf`, `first_leaf() -> &str`, `path_to`, `node_at`, `split_percentage_at`, `leaf_frames(PaneFrame)`.
- Changes: `inserting_split`, `removing`, `adjacent_pane`, `wrapping_pane`, `setting_split_percentage`, `adjusting_split`.

**Panes (`pane`)**
- `PaneType::{Agent, Browser, Terminal}`. Decoding an unknown type fails, as in Swift.
- `PaneContentKind::{MARKDOWN, EDITOR, DIFF, STAGED_DIFF, CHAT}` and `title(&Path, kind)`.
- `chat_supports(profile_id)`: only `omp` can open as a chat.
- `PaneTab { id, pane_type, title, agent, cwd, url, content_kind, preview_owner_pane_id, startup_command }` with `is_markdown/is_editor/is_diff/is_file_preview/is_web_browser/is_chat`, `effective_working_directory`, `search_terms`.
- `PaneState { id, tabs, active_tab_index }` with `MAX_TABS_PER_PANE = 10`, `active_tab(_mut)`, `clamped_active_index`, `tab`, `tab_index`.

**Windows (`window`)**
- `LayoutTab { id, layout, active_pane_id }`.
- `TerminalSessionState { id, name, active_window_id, last_active_window_id }` with `DEFAULT_ID`.
- `WorkspaceWindowState { id, session_id, title, is_title_custom, is_sidebar_collapsed }`. Its tab list is private and never empty; read it with `tabs()`, `active_tab_index()`, `active_tab()`, `layout()`, `active_pane_id()`.
- Window methods: `pane_ids`, `ordered_pane_ids`, `is_empty`, `contains_pane`, `tab_index_containing_pane`, `tab_index_of`, `activate_tab(_containing_pane|_offset)`, `append_tab`, `remove_tab`, `insert_split`, `remove_pane`, `set_split_percentage`, `adjust_split`.

**Other modules**
- `AgentInstance`: all fields public, plus `new` and `with_launch`.
- `terminal_title`: `display`, `display_in` (explicit home folder), `folder_name(_in)`, `without_decorations`, `shell_location`.
- `file_url`: `standardized_path`, `file_url_string`, `path_from_file_url`.

**`Workspace` (was `AgentManager`), by area**
- **Change log:** `new()` (session-1 / window-1 / pane-1 / tab-2 / layout-1, ids continue from 2), `take_changes() -> Vec<WorkspaceChange>`, `take_events() -> Vec<WorkspaceEvent>`, `has_pending_changes`, `layout_generation`, `workspace_restore_generation`, `set_close_confirmation`, `reload_agent_profiles`.
- **Reading state:** `panes()`, `pane`, `tab`, `windows()`, `window`, `terminal_sessions()`, `active_window_id`, `active_window`, `active_session_id`, `active_session`, `active_pane_id`, `layout`, `maximized_pane_id`, `running_command_targets`, `pane_count`, `window_count`, `active_working_directory`, `window_containing_pane`, `window_containing_layout_tab`, `ordered_windows`, `can_add_pane`.
- **Sessions:** `ordered_sessions`, `active_session_windows`, `ordered_windows_in`, `create_session(name, cwd)`, `activate_session`, `rename_session`, `close_session`.
- **Windows:** `create_window(cwd, chat_profile_id)`, `activate_window`, `activate_last_window`, `activate_previous_window`, `activate_next_window`, `activate_window_number`, `toggle_sidebar_window_collapsed`, `collapse_all_sidebar_windows`, `rename_window`, `reset_window_title`, `close_window`.
  - Automatic titles are unique within the session ("X (2)").
- **Layout tabs:** `create_layout_tab(cwd, chat)`, `activate_layout_tab`, `activate_next_layout_tab`, `activate_previous_layout_tab`, `close_layout_tab`, `close_active_layout_tab`, `layout_tab_title`.
- **Panes:** `MAX_PANES_PER_TAB = 20`, `spawn_agent(profile, cwd, chat)`, `spawn_terminal`, `spawn_browser`, `spawn_omp_web(&Path)`, `split_pane(dir, pane)`, `close_pane`, `focus_pane`, `navigate_to_pane`, `set_split_percentage`, `resize_pane(dir, tick)`, `set_layout`, `toggle_maximize`.
  - When a tab is full these return `None` without using up an id.
- **Pane tabs:** `add_tab_to_pane(pane, type, profile, content_kind)`, `remove_tab_from_pane`, `switch_tab`, `next_tab`, `prev_tab`, `focus_tab(pane, tab, reveal_in_sidebar)`, `rename_tab`, `update_working_directory`, `update_browser_url`.
- **Files (editor, diff, Markdown):** `open_editor(path, preview, pane)`, `open_diff(path, staged, preview, pane)`, `open_markdown`, `spawn_markdown`, `preview_markdown`, `markdown_preview_target`, `file_pane`, `keep_editor_tab`, `relocate_file_tabs(old, new)`, `update_file_document`.
- **Agents:** `agent`, `agent_mut` (records no change), `agent_profile`, `stop_agent`, `stop_agent_in_pane`, `restart_agent`, `restart_agent_in_pane`, `handle_terminal_close`, `agent_command_did_finish`, `agent_process_did_exit`, `agent_returned_to_shell`, `update_agent_status(pane, tab, status, needs_attention, waiting_reason)`, `update_agent_status_in_pane`, `clear_attention`, `attach_agent_if_needed`, `record_agent_conversation`, `begin_agent_readiness_generation`, `mark_agent_ready_if_starting`, `ready_agent_count`, `attention_count`.
- **Running commands:** `set_running_command_targets(HashSet)`, `is_running_command`, `RUNNING_COMMAND_LABEL`.
- **Automation runs:** `AUTOMATION_SESSION_NAME`, `open_automation_window(title, profile, cwd, run_id, launch, conversation)`, `close_automation_run`.
- **What the UI renders:**
  - `ordered_panes(window)`, `first_tab_matching(window, query)` (window search).
  - `pane_shortcut_assignments() -> Vec<PaneShortcut{key, pane_id}>` and `pane_hints(count)`: hint letters `bdefgimnopqrstuvwxyz`, two letters past 20 panes.
  - `agent_dashboard_entries()` in visual order, and `agent_dashboard_entry(target)`.
  - `window_activity(window)` and `layout_tab_activity(layout_tab)` return an `ActivitySummary` with `most_urgent_agent`, `agents_summary`, `running_commands_summary`, and `describe("Window 1: X")`, which produces the Swift tooltip text.
  - `active_location() -> ActiveLocation` with `.text()`, e.g. `Session 1  /  Soprano  /  Claude · Tab 2`. This keeps the Swift `  /  ` separator, not the `›` from the brief.
- **Persistence:** `snapshot_workspace() -> WorkspaceSession` and `restore_workspace(WorkspaceSession) -> CloseOutcome`.

**Change and event enums**
- `WorkspaceChange::{Model, Layout, TabTitle(t), TabWorkingDirectory(t), BrowserUrl(t), Document(t)}`. `Layout` replaces Swift's `layoutChanged` flag and bumps `layout_generation`.
- `WorkspaceEvent::Terminal(TerminalLifecycleAction::{Stop(t), Restart(t)})`.
- `TerminalTarget { pane_id, tab_id }`, `AgentReadinessGeneration`.

**Two-phase close**
- The host sets a predicate: `set_close_confirmation(Some(Box<dyn Fn(&[TerminalTarget]) -> bool + Send + Sync>))`. Returning `true` means "ask the user first".
- These return a `CloseOutcome`: `close_session`, `close_window`, `close_pane`, `close_layout_tab`, `close_active_layout_tab`, `remove_tab_from_pane`, `handle_terminal_close`, `close_automation_run`, `restore_workspace`, and `SessionManager::load_session`.
- `CloseOutcome` is one of:
  - `Closed`: done, or restored.
  - `Unchanged`: nothing closed.
  - `NeedsConfirmation { targets, request: CloseRequest }`: nothing changed yet.
- After the user confirms, `force_close(request)` performs it.
- `CloseRequest::{Session, Window, Pane, LayoutTab, PaneTab, AutomationRun, TerminalClosed, RestoreWorkspace(Box<WorkspaceSession>)}`.
- A close nested inside one already approved (a pane taking its window with it) is not asked again.

**Persistence types (`session`)**
- `WorkspaceSession`, `SavedWindow`, `SavedLayoutTab`, `SavedPane`, `SavedTab`, `ReferenceDate(f64)`.
- Keys, shapes and missing-value handling match Swift's Codable output: `{"leaf":{"_0":…}}`, camelCase keys, `savedAt` as seconds since 2001, empty optionals left out.
- Older formats still load: windows saved with depth layers reopen each layer as a tab (`restorable_tabs()` / `restorable_active_tab_index()`). Depth layers are read but never written.
- `WorkspaceSession::{SESSIONS_KEY, LAST_SESSION_KEY}` (`soprano-sessions`, `soprano-last-session`) with `load_all`, `save_all`, `load_last`, `save_last`, `clear_last` on `&StateStore`, and `legacy(…)`.
- `SessionManager::new(StateStore)` with `sessions`, `save_session(name, &Workspace)`, `load_session(id, &mut Workspace) -> CloseOutcome`, `delete_session`, `take_changed`.

## 2. Swift files ported and tests

- `SplitNode.swift` → `split_node.rs`
- `PaneState.swift` → `pane.rs`
- `WorkspaceWindowState.swift` + `TerminalSessionState.swift` → `window.rs`
- `WorkspaceSession.swift` → `session.rs`
- `TerminalTitle.swift` → `terminal_title.rs`
- `AgentInstance.swift` → `agent_instance.rs`
- `SessionManager.swift` → `session_manager.rs`
- `AgentManager.swift` + `AgentManager+Dashboard.swift` → `workspace/{mod, sessions, panes, files, agents, closing, persistence, presentation}.rs`

**Tests:** 148 in total.

| Swift test file | Rust tests |
|---|---|
| SplitNode | 9 |
| TerminalTitle | 9 |
| AgentManagerPane, PaneTabShortcut | 21 |
| LayoutTab | 10 |
| TerminalSession, SidebarCollapseAll, window-tab model parts, automation-run model parts | 20 |
| TerminalLifecycle, AgentConversation | 22 |
| EditorTab, MarkdownIntegration, BrowserIntegration | 21 |
| AgentChatTab | 4 |
| ActiveLocation, RunningCommand, AgentDashboard, WindowTabBar, LayoutTabBar, PerformanceOptimization | 17 |
| SessionPersistence, WorkspaceRestore, SidebarCollapsePersistence, JSON shape | 12 |
| file URL and process helpers | 3 |

**Skipped (AppKit view details):**
- All of `PaneFrameTests`.
- SplitTreeView surface-cache tests and `SurfaceDestructionGateTests`. Their model parts were ported: exact targets and readiness generations.
- Editor save/⌘S and the key-chord tests.
- ACP chat session and transcript selection tests.
- Sidebar, tab bar and dashboard layout, scrolling and pixel tests.
- `TerminalCommandActivity` and `shouldRenderSurface`, which belong to the terminal crate.
- Sorting and grouping in `AgentDashboardTests`, which belong to soprano-agents.
- `DefaultKeybindings` checks.
- `AgentNotificationManager.locationSubtitle`.
- `MarkdownCommandController` parsing, link handling and rendering.

**Changed test parts:**
- `KeybindingManager.paneHintStep` is replaced by looking up the assignment directly.
- The observer that recorded the session at every notify is now a final-state check, because the change log does not snapshot state per change.
- The "detached agent object reads `.stopped`" check relied on Swift reference semantics; it now asserts the agent was detached and that a new attach starts a fresh agent.

## 3. Cross-platform decisions and deviations
- **Observers:** replaced by the `take_changes`/`take_events` queues. Lifecycle events sit in their own queue, so they are not interleaved with model changes.
- **Moved out of the model, so the model doesn't depend on soprano-ipc or the terminal:**
  - Swift's `agentEventHandler`/`reportAgentEvent`: the host sends chat agent events to the notification manager or calls `update_agent_status`.
  - The `ghosttyCloseSurface` notification: the host calls `handle_terminal_close`.
- **Process check:** Swift's `kill(pid, 0)`/`ESRCH` became `process.rs`: `kill` on Unix, `OpenProcess`/`GetExitCodeProcess` on Windows.
- **Dates:** persisted dates use `ReferenceDate`, a raw f64, so `.distantPast` survives on Windows; runtime times use `SystemTime`.
- **File URLs:** built with the `url` crate. Percent-encoding of unusual characters may differ slightly from Foundation, but stored URLs decode correctly.
- **Folder names:** taken by splitting on the platform's path separators, so `\` also counts on Windows.
- **Ordering:** maps are `BTreeMap`, and sorting ties are broken by id so the order is always the same.
- **Defined locally, may duplicate other crates:**
  - `chat_supports` (Swift `AgentChatLaunch.supports`).
  - `AgentDashboardEntry`: soprano-agents' snapshot sorts it. I told ConversationPort about this type.
  - `NavigationDirection`, which soprano-ipc also has.

## 4. Verification
- `CARGO_TARGET_DIR=target/agent-soprano-model cargo test -p soprano-model`: 148 passed, 0 failed.
- `CARGO_TARGET_DIR=target/agent-soprano-model cargo clippy -p soprano-model --all-targets`: no warnings.
- `CARGO_TARGET_DIR=target/agent-soprano-model-cross cargo clippy --target x86_64-unknown-linux-gnu -p soprano-model --all-targets` and the same with `--target x86_64-pc-windows-msvc`: no warnings.
- `cargo fmt -p soprano-model` applied.

The tests only ran on macOS; Linux and Windows were checked with clippy, not run. While other crates' manifests were briefly broken, I iterated in a temporary three-crate copy. The final commands above all ran in the real worktree.