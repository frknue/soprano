# soprano-automations — API report from AutomationsPort

Both crates are built: `soprano-automations` (the logic, no gpui) and `soprano-automations-ui` (the GPUI page). `cargo test` passes for both (58 tests in the logic crate, 29 in the UI crate), clippy is clean on all targets, and both are formatted. The Linux and Windows cross-checks could not run, because `soprano-agents` pulls in a bundled SQLite that needs a C cross-compiler this Mac doesn't have. Nothing was committed and no GUI was launched.

## soprano-automations

**`AutomationHost`** — the trait the shell implements. It is passed into each call as `&mut dyn AutomationHost`, so the shell can build it per call over `Entity<Workspace>` and its terminal registry.
- **Required:**
  - `workspace(&self) -> &Workspace`
  - `workspace_mut(&mut self) -> &mut Workspace`
  - `start_terminal(&mut self, &TerminalTarget) -> bool` — false means no display is awake, so the run waits.
  - `send_prompt_to(&mut self, &TerminalTarget, prompt: &str) -> bool`
  - `visible_text(&self, &TerminalTarget) -> Option<String>`
  - `display_is_awake(&self) -> bool`
  - `notify(&mut self, title: &str, body: &str, run_id: &str)` — the banner names the automation; clicking it should call `AutomationsPage::show_run`.
- **Provided defaults, built on the model's automation API (overridable):**
  - `open_run_window(title, profile_id, cwd, run_id: Option<String>, AgentLaunch, Option<AgentConversation>) -> Option<TerminalTarget>` — uses `open_automation_window`.
  - `close_window(&TerminalTarget)` — uses `close_automation_run` and forces it if confirmation is needed.
  - `focus_tab`, `tab_exists`, `agent(&TerminalTarget) -> Option<&AgentInstance>`, `set_agent_run_id(&TerminalTarget, Option<String>)`.
  - `is_window_opened_by_user(&TerminalTarget) -> bool` — the tab is the active tab of the active pane.
  - `workspace_restore_generation() -> u64`

**`AutomationController`**
- `new(AutomationStore, ConfigStore, AutomationEnvironment, &mut dyn AutomationHost)` — fails runs left open by the last quit.
- Reading:
  - `automations()`, `taken_ids()`, `automation(id)`
  - `runs(id)` (newest first), `run(run_id)`, `last_run(id)`
  - `next_run_date(id) -> Option<DateTime<Utc>>`
  - `is_live(&run, &dyn AutomationHost)`
  - `revision() -> u64`, `store()`, `store_mut()`, `config()`, `clock()`
  - `run_title(name, number)`
- Writing:
  - `save(&Automation) -> bool` — writes `config_object()` into settings.json.
  - `set_enabled(id, bool) -> bool`
  - `delete(host, id) -> bool`
  - `run_now(host, id)`
  - `open_run(host, run_id) -> bool` — focuses the live tab, or resumes the conversation in a new window.
- **What the host must call:**
  - `tick(host, now)` every `CHECK_INTERVAL` (30 s), on wake from sleep, and after settings.json changes.
  - `workspace_changed(host)` after every workspace model change.
  - `drain(host)` whenever `environment.wake` fires.
  - `retry_waiting_terminals(host)` every `DISPLAY_RETRY_INTERVAL` (15 s) while `is_waiting_for_display()` is true.
- Also: `open_code_has_private_server`, `open_code_primary_agents`, `final_reply(profile_id, &conversation, home)`, and the constants `START_TIMEOUT_SECONDS`, `WAITING_FOR_DISPLAY_MESSAGE`, `MISSED_MESSAGE`.

**`AutomationEnvironment`** `{ clock: Arc<dyn Clock>, worktree_directory, claude_config: Option<PathBuf>, home, shell, wake: Arc<dyn Fn() + Send + Sync> }`, with `for_app(&AppIdentity, wake)`.

**Other modules**
- `Clock` (`now`, `time_zone -> chrono_tz::Tz`), with `SystemClock` and `FixedClock`.
- `AutomationStore`:
  - `new(Option<PathBuf>)`, `default_file(&AppIdentity)` → `<data dir>/automations.json`. The file uses the Swift format: ISO dates, sorted keys.
  - Keeps the last 100 finished runs per automation.
  - Methods: `schedules`, `all_runs`, `run`, `runs`, `last_run`, `open_runs`, `next_run_number`, `set_schedule`, `insert`, `update`, `remove_all`, `revision`.
- `AutomationRun` with `RunStatus`, `RunTrigger` and `RunWorktree`; `target()`, `duration()`, `trimmed_output()`.
- `tracking::{Observation, Change, change}`.
- `scheduling::{ScheduleState, Decision, signature, next_occurrence, evaluate}`.
- `worktree::{create, is_untouched, remove, branch_name, default_directory, git, Checkout, WorktreeFailure}` — worktrees go under `<data dir>/worktrees/<repo>/` on branch `automation/<id>-<yyyyMMdd-HHmm>`.
- `precheck::{run, PrecheckOutcome}`.
- `claude_trust::{trust, config_path, default_config_path}`.

**Swift ported:** AutomationController, AutomationRun, AutomationRunTracking, AutomationScheduling, AutomationStore, AutomationWorkspace (worktree, Git, AutomationPrecheck, ClaudeWorkspaceTrust).

**Tests ported:** all of AutomationRunTracking, AutomationScheduling, AutomationStore and AutomationWorkspace (git tests use temp repos), and AutomationController. The controller tests run against a real `soprano_model::Workspace`. Two extra tests cover runs waiting for a display, and save/pause/delete.

## soprano-automations-ui

**`AutomationsPage`**
- Created with `new(Entity<AutomationController>, Entity<Workspace>, window, cx)`. It only reads the workspace, to know whether a run's tab is open.
- It emits `AutomationsPageEvent::{Dismiss, RunNow{automation_id}, OpenRun{run_id}, Delete{automation_id}}`. The shell performs these, closes the page when `open_run` returns true, and calls `show_write_failure` when `delete` returns false.
- Methods:
  - `show_run(run_id)` (banner click), `show_automation`, `new_automation` (⌘N)
  - `present_editor(Option<Automation>, Option<AutomationTemplate>)`, `perform(AutomationAction, id)`
  - `handle_escape`, `go_back`, `move_selection`, `activate_selection`
  - `page()`, `selected_automation()`, `selected_run()`, `editor()`, `dialog()`, `focus_page()`
- **What the page covers:**
  - The list shows schedule, folder, next run and last run, with search, a ⋯ menu and a right-click menu (Run Now, Edit…, Pause/Resume, Delete…). When empty, it shows the four templates and a blank card.
  - An automation's page has the failed-run notice, tiles, the prompt card and run history.
  - A run's page has tiles, the message (precheck output shown as code), the worktree, and the report rendered with `soprano_editor::rich::Markdown`. Its buttons are Open Run / Resume Conversation and Reveal Worktree.
  - Keys: J/K, arrows, Return, Space, Esc stepping back, and ⌘N (Ctrl+Shift+N elsewhere).
  - It refreshes every 30 s.

**`AutomationEditor`**
- Created with `new(EditorSetup{automation, template, automations, taken_ids, project_directories, settings_path, clock})`.
- Methods: `set_on_save`, `values`, `can_save`, `shown_error`, `submit`, `is_new`. Emits `EditorClosed`.
- Every field is there; Return or ⌘Return saves, Esc cancels, and a failed save shows its error and keeps the dialog open.

**Also public:** `form` (FormValues, validation and the automation Save writes), `format`, `pill`, `content`, `selection`, `templates`.

**Swift ported:** AutomationsViewController, AutomationListView, AutomationDetailView, AutomationEditorPanel, AutomationRunDetailView, AutoUICards, AutoUIFormControls (built on soprano-ui widgets).

**AutomationsPageTests:** the save-failure, report-is-Markdown and state-pill tests are ported. The refresh test is ported as the `clock_text` rule (the page only rebuilds when a time it shows changes). From the window-frame test, the "Esc steps back from a run's report" part is ported. I added tests for J/K and Return, ⌘N and Esc in the editor, pause and Run Now, delete confirmation, and saving into settings.json. Two tests are not ported:
- the window-frame part — GPUI has no constraint-driven window resizing;
- the sidebar-click-closes-the-page test — that behavior belongs to the shell.

## Deviations
- **Prechecks don't use `soprano_launch::command_runner`, against the brief.** It has no working-directory option, and on timeout it signals only the shell and drops the output. The Swift test that a timed-out precheck also stops the processes it started would fail with it. I used a small runner instead: on Unix it kills the whole process group, on Windows it uses `taskkill /T`. It still uses soprano-launch's shell flavor and quoting. Your call whether to switch it to `CommandRunner` once that runner gains these options.
- **Time zones.** The schedule signature includes the IANA zone name. `SystemClock` reads the zone fresh on each call, so moving to another zone counts as an edit, as in Swift.
- **Background work.** It runs on one serial worker thread, like Swift's queue. Results reach the main thread through `wake` plus `drain`, instead of `DispatchQueue.main`.
- **Wording on Linux/Windows.** "Mac" becomes "computer" in the missed-run message and the grace tooltip. macOS keeps the Swift text.
- **Editor time field.** It is a text field ("9:00 AM" or "21:30") instead of a stepper. A bad entry shows "Enter a time like 9:00 AM." in the schedule note.
- **Folder select.** The "Choose a folder" option became the select's placeholder, and "Choose Folder…" opens the system folder picker. There is no separator before it (the select doesn't support one).
- **Small visual changes.** The "Skipped" pill uses the minus icon and "Paused" uses the pause icon, since soprano-ui has no circled versions. The Markdown report is selectable only in a window wrapped in gpui-component's `Root`.

## Commands
- `CARGO_TARGET_DIR=target/agent-soprano-automations cargo test -p soprano-automations -p soprano-automations-ui` → 40 + 18 + 29 passed. It had to be retried a few times while `soprano-config`, `soprano-text` and `soprano-editor` were mid-edit by their owners.
- `cargo clippy -p soprano-automations -p soprano-automations-ui --all-targets` → no warnings.
- `cargo fmt -p soprano-automations -p soprano-automations-ui` → applied.
- `cargo clippy --target x86_64-unknown-linux-gnu|x86_64-pc-windows-msvc` and `cargo check --target x86_64-unknown-linux-gnu -p soprano-automations-ui` → blocked by the `libsqlite3-sys` cross build, as above.