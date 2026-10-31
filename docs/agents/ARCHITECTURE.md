# Soprano Agents architecture

Soprano Agents is a native macOS GUI for the `omp` coding agent (oh-my-pi) in the Soprano family,
colored by Soprano's themes: a thread inbox on the left, a centered chat lane with a floating
composer, collapsible work logs, per-turn diffs from hidden git checkpoints, a terminal drawer and
a right panel. Swift 6 + programmatic AppKit (no SwiftUI, no storyboards), SPM, macOS 14+. The app
talks to the `omp` CLI directly; there is no server process.

## Toolchain

```bash
export DEVELOPER_DIR=/Library/Developer/CommandLineTools PATH="/opt/homebrew/opt/swift/bin:$PATH"
swift build
swift test
.build/debug/SopranoAgents snapshot --out /tmp/shot.png --fixture demo [--appearance dark]
```

`ld: warning: building for macOS-14.0 …` link warnings are expected.

## Modules and ownership

| Path | Module | Contents |
|---|---|---|
| `Sources/SopranoAgentsCore/Models/` | Contract | Domain types: `Project`, `AgentThread`, `Turn`, `TurnItem(Kind)`, approvals, user input, `ModelSelection`, `ProviderStatus`, `ThreadStatus`/`InboxSection`, `DurationText`, `JSONValue`. Foundation only. |
| `Sources/SopranoAgentsCore/Providers/ProviderSession.swift` | Contract | `ProviderDriver`, `ProviderSession`, `ProviderEvent`, `SessionConfig`, `TurnInput`. |
| `Sources/SopranoAgentsCore/Providers/` (rest) | Providers | `LineProcess` (stdio JSON-lines transport), the omp driver, session, RPC client and event mapper, model catalog, `generateJSON`. |
| `Sources/SopranoAgentsCore/Engine/` | Engine | `AgentEngine` (state owner, observers, inbox lifecycle), `AgentEngine+Turns.swift` (sessions, sending, steering, queue, approvals, checkpoints, revert, diffs, titles, git actions), `AgentEngine+Files.swift` (workspace files) and `AgentEngine+Usage.swift` (usage history for the statistics board). `EngineTypes.swift` is contract. |
| `Sources/SopranoAgentsCore/Files/` | Files | `WorkspaceFileService` (contract), `WorkspaceFileContent`, `WorkspaceFilePath` (the one escape check), `LiveWorkspaceFileService`. |
| `Sources/SopranoAgentsCore/Usage/UsageStatistics.swift` | Contract | `UsageStatisticsService`, `UsagePeriod` (buckets), `UsageGroup`, `UsageTotals`, metric/part enums. |
| `Sources/SopranoAgentsCore/Usage/` (rest) | Usage | `UsageHistory` / `UsageSummary` (bucketing, model filter, breakdowns), `UsageFolderName` (omp's session folder names), `OmpUsageStatistics` (`omp stats` sync + read-only `stats.db` query). |
| `Sources/SopranoAgentsCore/Store/` | Engine | `JSONFileThreadStore`. |
| `Sources/SopranoAgentsCore/Git/GitService.swift` | Contract | `GitService`, `SourceControlWriter`, status/branch/action value types. |
| `Sources/SopranoAgentsCore/Git/` (rest) | Git | `GitRunner` (the only place that spawns git), `LiveGitService` (checkpoints, diffs, status, branches, worktrees, commit/push/PR via `gh`), parsers. |
| `Sources/SopranoAgents/Theme/` | Shared kit | `Palette` + `PaletteCenter`, `Typography`, `Metrics`, `Radius`, `Icon`, `PaletteView`, `InteractiveView`, `GhostIconButton`, `TextButton`, `KbdView`. |
| `Sources/SopranoAgents/Shell/`, `App/`, `Views/Palette/`, `Views/Settings/`, `Notifications/`, `Commands/AppCommand.swift`, `ShellCommands.swift` | Shell | App delegate, menus, window, workspace layout, `WorkspaceState`, settings (`SettingsCenter`, resolver, template), keymap + router, `Dialogs`, command palette, settings screen, notifications, snapshot harness. |
| `Sources/SopranoAgents/Views/Sidebar/`, `Views/Chat/ChatHeaderView.swift`, `SidebarCommands.swift` | Sidebar | Thread inbox (with subagent rows under their thread's card, `SubagentActions`), chat header + title-bar toggles. |
| `Sources/SopranoAgents/Views/Timeline/`, `TimelineCommands.swift` | Timeline | Message timeline, Markdown renderer, work log, cards. |
| `Sources/SopranoAgents/Views/Composer/`, `ComposerCommands.swift` | Composer | Composer, pickers, context meter + card, `/` command menu, draft hero + context strip. |
| `Sources/SopranoAgents/Views/Panels/`, `PanelCommands.swift` | Panels | Right panel (tabs, launcher; Diff, Files explorer, file viewer and terminal surfaces), terminal drawer, `ThreadTerminalStore` (every terminal of the window), Thread details card (editor, scripts, branch, git actions). |
| `Sources/SopranoAgents/Views/Accounts/`, `Views/Settings/SettingsAccountsPage.swift`, `Commands/AccountCommands.swift`, `Fixtures/AccountFixtures.swift` | Accounts | `AccountsSource` / `AccountsCenter` (the UI's only door to accounts), sidebar account button, usage card, Settings → Accounts, account fixtures. |
| `Sources/SopranoAgents/Views/Statistics/`, `Commands/StatisticsCommands.swift`, `Fixtures/FixtureUsageStatistics.swift` | Statistics | Statistics board (header, periods, Cost/Tokens, tiles, stacked chart, model/project/agent breakdowns), `StatisticsFormat`, fixture usage history. |
| `Sources/SopranoAgents/Fixtures/` | Shell | `DemoFixtures` scenarios + `FixtureGitService` and `FixtureWorkspaceFiles` for snapshots and UI tests. |
| `Sources/SopranoAgents/Vendored/` | — | Copied from Soprano by `scripts/sync-soprano-chrome.sh`, including `Vendored/Accounts/` (Soprano's accounts layer: `AccountsController` and its account managers, `AccountLaunchState`, `UsageAPI`). **Never edit.** |

Modules talk only through the contracts: views read `AgentEngine` state and call its methods;
UI state goes through `WorkspaceState`; commands through `CommandRegistry`. A view never talks to
a provider and never spawns git: read-only git queries (status, branches) go through
`engine.environment.git`, every write through an engine method. The only processes the UI layer
starts itself are terminal shells (SwiftTerm, drawer and right-panel tabs) and `NSWorkspace` opens (editor, Finder, URLs).

## Seams

### `AgentEngine` (Core/Engine)
`@MainActor`, the single owner of projects, threads, provider sessions and provider statuses.
Views read `projects`, `threads`, `thread(_:)`, `project(_:)`, `status(of:)`, `settings` and observe
`EngineEvent` with `engine.addObserver(self) { [weak self] event in … }`:

- `.projectsChanged`, `.threadListChanged` (add/remove, title, section, status pill, branch),
  `.threadChanged(threadID:)` (turns/queue/settings), `.itemChanged(threadID:turnID:itemID:)`
  (streaming deltas: re-render just that row), `.providersChanged`, `.commandsChanged` (re-read
  the command lists), `.subagentChanged(threadID:subagentID:)` (a subagent's runs or items,
  streaming too), `.subagentListChanged(threadID:)` (a subagent added, or its status or activity
  line changed: the sidebar).
- Mutations: `addProject`, `removeProject`, `rename`, `setPinned`, `setSettled`, `setArchived`,
  `markVisited`, `markUnread`, `setModelSelection`, `setRuntimeMode`,
  `launchThread`, `send`, `interrupt`, `respond`, `answer`, `dismissUserInput`, `sendQueuedNow`,
  `cancelQueued`, `revert`, `turnDiff`, `regenerateTitle`, `deleteThread`, `gitStatus`,
  `runGitAction`, `importAttachment`, `refreshProviders`, `shutdown`, `canCompact`, `compact`,
  `rememberCommands`, `steerSubagent`, `cancelSubagent`. Reads: `subagent(_:_:)`,
  `workingDirectory(of:)`, `workspaceKeys`, `workspaceLocation`,
  `workspaceFiles`, `readWorkspaceFile`, `workspaceFileURL` (all by `WorkspaceRef`: `.thread(id)`
  or `.draft(projectID:)`, the project root a "Current checkout" thread will use; `key` is the
  UI's per-workspace dictionary key), `commands(forThread:)`, `commands(forDraft:projectID:)`,
  `usageHistory(_:sync:)`, `usageFolderTitles()`.
  Contracts in the doc comments of `AgentEngine.swift`, `AgentEngine+Turns.swift`,
  `AgentEngine+Files.swift`, `AgentEngine+Workspace.swift`, `AgentEngine+Commands.swift` and
  `AgentEngine+Usage.swift`.

Engine behavior:
- Workspace: an agent only ever runs in the thread's working directory. Projectless threads get
  `<data>/scratch/<id>` created; any other missing folder (deleted worktree, moved or removed
  project) fails the turn with `EngineError.workspaceMissing` before anything spawns, and the
  provider sessions refuse a missing cwd too. A new-worktree thread owns its planned worktree
  path from launch, so during setup or after a failed setup nothing falls back to the project root.
- Turns recovered after a crash cancel their pending approvals and questions.
- One `ProviderSession` per thread, created lazily on first send (resumes `providerThreadID`
  after relaunch), closed on delete/shutdown. Provider events fold into the open turn
  (`AgentThread.openTurn`, the last turn while `.running`): `itemUpdated` replaces by id, deltas
  append, approvals/user input become items, `turnCompleted` finishes the turn and starts the
  next queued message. Items arriving without an open turn are dropped, except an `advisory`,
  which joins the last turn.
- Yielded turns: `turnYielded(outcome, error)` (see omp below) sets `Turn.yieldedAt`
  (persisted; a failed yield also sets `failureMessage`): the answer is final, so
  `AgentThread.activeTurn`/`isRunning` skip the turn (no Working pill, Stop, "Working for" row,
  steering or approval bar; Edit from here and archive allowed), its live items settle, its
  checkpoint is captured, and a queued message starts after a completed yield. The turn stays
  open: `turnResumed` (background work woke the agent) clears `yieldedAt`, sets `resumedAt`
  (answers before it stop counting as the last word for the timeline's "Thinking"; cleared when
  the turn ends) and the run streams into it; `turnCompleted` ends it at
  `completedAt = yieldedAt` (or now after a resumed run).
  Anything that starts new work first ends the yielded turn (`releaseYieldedTurn`): `send`,
  `sendQueuedNow`, the queue, `compact`, `revert` call `ProviderSession.releaseYieldedTurn()`
  (default no-op), wait up to `EngineRuntime.yieldReleaseTimeout` (5 s) for its
  `turnCompleted`, else end it locally with its yielded outcome (`Turn.yieldedStatus`); then the
  message starts a new turn (never a steer, never interrupted). Session end, app quit and crash
  recovery also end a yielded turn with its yielded outcome. The timeline shows a yielded turn
  as finished plus a muted "Background work still running…" row (`.backgroundWork`).
- Checkpoints: before turn N, if `CheckpointRef.ref(thread, N-1)` is missing, capture it; after
  turn N ends (completed or interrupted), capture `ref(thread, N)` and store
  `TurnCheckpoint(files:)` from `changedFiles(ref(N-1), ref(N))`. Not a repo → status `.missing`.
- Turn diff N = `diff(ref(N-1), ref(N))`; thread diff = `diff(ref(0), ref(last))`.
- Revert to before turn N: interrupt guard, provider `rollback(beforeTurn:providerTurnID:)` for
  the earliest turn ≥ N that has a `providerTurnID` (none → no provider call, the conversation
  already ends there), optional `restoreCheckpoint(ref(N-1))`, delete refs ≥ N, drop turns ≥ N,
  return turn N's user message.
- Titles: first message → title seed (first 50 chars + "...") immediately, then
  `textGenerationModel` via `ProviderDriver.generateJSON` with the title prompt in
  `TextGeneration`.
- New worktree: branch `<branchPrefix>/<8 hex>` from the base branch at
  `<worktreesDirectory>/<repo>/<branch with / → ->`, renamed in the background to a generated name
  (`<branchPrefix>/<fragment>`).
- Persistence: every change goes through `ThreadStore` (JSON file per thread under
  `<data>/threads/`, projects in `<data>/projects.json`, atomic, coalesced writes). Streaming
  deltas are not written on every token; the store coalesces.
- Data root: `AppPaths.dataDirectory()` = `~/Library/Application Support/<bundle name>`
  (`SOPRANO_AGENTS_DATA_DIR` overrides). Attachments in `<data>/attachments/<uuid>/<name>`
  (passed to sessions as an additional directory); scratch threads work in `<data>/scratch/<thread>`.
- Workspace files (`EngineEnvironment.files`, default `LiveWorkspaceFileService`): in a git repo
  `ls-files -z --cached --others --exclude-standard` (ignored files stay out, deleted ones are
  dropped); elsewhere a walk skipping `.git`, `node_modules`, `.build`, `DerivedData` (≤ 20 000
  files). Reads resolve symlinks and refuse anything outside the working directory; text up to
  2 MiB, images by extension up to 20 MiB, NUL or invalid UTF-8 = binary.
- Context: every `tokenUsage` event sets the latest turn's usage and `AgentThread.contextUsage`
  (persisted; `TokenUsage.fraction` = used / window). An "Edit from here" rewind sets it to the
  last kept turn's usage.
- Compaction: text that is exactly `/compact` (no attachments) runs as a compaction turn via
  `ProviderSession.compact()`. It needs a conversation and an idle thread, or `.queue`; messages
  sent during it are queued. The provider's notice (or error) lands in that turn.
- Commands: `ProviderEvent.commands([ProviderCommand])` lists are deduplicated by `insertText`,
  sorted (commands A–Z, then skills A–Z), kept per thread, and remembered per provider and
  workspace for drafts (a worktree thread's list also counts for its project; all scratch threads
  share one). Text starting with `/` reaches the provider with its first characters intact.
- Subagents: `ProviderEvent.subagent(id:, SubagentEvent)` folds into `AgentThread.subagents`
  (persisted, start order; `AgentEngine+Subagents.swift`): `.updated` merges reported facts
  (agent, assignment, model, latest intent, status; a status other than running ends its open
  run), `.runStarted(message:)` appends a run (`Turn`, the waking message as its user message),
  `.message` adds a steer to the open run, item and delta events fold into the open run like a
  thread's, `.runEnded` ends it. `steerSubagent` / `cancelSubagent` need a running subagent and
  the thread's live session (the message shows up when the subagent reports it). The session's
  end aborts running subagents; a crash-recovered thread loads them aborted. Identity: the
  provider's id (`Subagent.name`) is unique only within one omp session, so an event goes to the
  latest subagent of that name unless its reported transcript or starting tool call differs from
  the known one; then it gets a new entry (`Subagent.id` "Reader#2", `providerID` "Reader").
  Views select and address subagents by `id`; messages and Stop reach omp by `name`. "Edit from
  here" drops the subagents its rewound turns started.

### Providers (Core/Providers)
`ProviderDriver` creates `ProviderSession`s, probes the CLI (`probe()` → version, health,
models), and runs one-shot `generateJSON`. `OmpDriver` is the only implementation and
`ProviderKind` has the single case `.omp`; the seam keeps the engine testable against a fake driver.

**omp** (oh-my-pi) — `omp --mode rpc-ui --cwd <cwd> --approval-mode <mode>
[--model <provider/id>] [--thinking <level>] [--resume <session file>]`, one process per thread
(path from `EngineSettings.ompPath` or PATH; never `--no-ui`, which makes approvals fail closed).
omp's RPC (docs: `omp://rpc.md`) is JSONL, not JSON-RPC: commands `{id?, type, …}`, responses
`{type:"response", id, command, success, data|error}`, events in between. Handshake: wait for
`ready`, `negotiate_protocol {protocolVersion:2}` (large frames then arrive as base64
`rpc_chunk` sequences, reassembled by `OmpFrameDecoder`), `set_ask_dialog {enabled:true}` (a
build that rejects it keeps the `select`/`editor` fallback),
`set_event_filter {messageUpdates:"delta"}`, `get_state` (its `sessionFile` is the thread's
`providerThreadID`; a saved file that no longer exists starts fresh). Model slugs are
`provider/id`; `default` (`ModelSelection.ompDefaultModel`) means omp's configured model (no
`--model`; after a `--resume`, which restores the session's saved model, `set_model` to the model
a throwaway `omp --mode rpc --no-session` in the thread's folder reports). Model, thinking and
fast-mode changes go to the live process (`set_model {provider, modelId}`, `set_thinking_level`,
`set_fast_mode`); a runtime-mode change relaunches with `--resume`. Runtime mode → approval mode: approval-required → `always-ask`, auto-accept-edits →
`write`, auto → `always-ask-cached`, full-access → `yolo`. Turns: `prompt {message, images?,
streamingBehavior:"steer"}` (attachment paths listed in the text; "steer" only matters when a
background job's run is live, where a plain `prompt` is refused); the turn ends at `prompt_result`
with the same id (extension runs such as auto-double-check happen before it), `completed` /
`aborted|interrupted|cancelled` → interrupted / else failed, or at the prompt's own ack when it
carries `agentInvoked:false` (a builtin slash command that ran locally; `OmpClient` also hands
that ack to the frame stream, so it ends the turn behind the command's `command_output` frames,
which become one final assistant message: Markdown kept, other multi-line text fenced, ANSI
escapes dropped; output after a prompt's ack, from builtins omp runs in the background such as
`/compact` and `/handoff`, is dropped while idle or during an agent turn, but frames carry no
prompt id, so one that arrives while a later slash command awaits its ack joins that command's
output). When the turn ends the session reads
`get_entries` and reports, via `turnStarted`, the first entry on the current branch after the
previous turn's tip (re-read at start and after a rewind) as the turn's `providerTurnID`: position,
not text, since omp rewrites skill invocations, templates and `^model` mentions. A turn whose start
cannot be located (entries unreadable, tip off the branch) gets `omp-unresolved`, which rollback
refuses instead of guessing; a turn that added nothing (local command) gets no id. A completed or failed `prompt_result`
with `sessionSettled:false` (async bash/task/eval jobs still running) yields the turn
(`turnYielded`, then `get_state` for the context fill) and holds the prompt: its dialogs and
interrupt stay live, a run those jobs wake (`agent_start`, `turn_start` or streamed text; not
the job's own `tool_execution_update`s on its call) reports `turnResumed` and streams into the
turn, and that run's terminal `agent_end` yields again. `session_settled` ends the held prompt
with its outcome (anchor, context fill, `turnCompleted`). `releaseYieldedTurn()` does the same
right away without sending anything to omp (the jobs keep running; a later `session_settled`
finds no held prompt and is ignored; runs they wake after that stream into whatever turn is
open, or are dropped). Settlement, Stop and release share one guarded ending, so a late anchor
never lands on the next turn. Stop ends the turn at once: an aborted `prompt_result`, any
`prompt_result` after Stop was pressed, or Stop while only background work is left (`abort`
does not stop background jobs). Steer = `steer`; from a non-yielded `prompt_result` on (while
the anchor and context fill are read) the session refuses steers (`noActiveTurn`) and the engine
queues the message, which starts the next turn once this one completes. Stop marks the turn
`stopRequestedAt` ("Stopping…") until it ends. Frames are parsed like `JSON.parse`: lone
surrogate escapes become U+FFFD instead of dropping the frame. Interrupt = `abort`. Host UI
arrives as `extension_ui_request`: a `select` titled `Allow tool:
<tool>\n<details>` is an approval (accept → `Approve Once` or `Approve`, acceptForSession → the
`… for this session` label or `Approve File`, decline → `Deny`, cancel → `cancelled:true`, all
answered as `extension_ui_response {id, value}`); other `select`, `confirm`, `input`, `editor` and
`ask` become user-input requests (answers `value`, `confirmed`, `answers[{id, selectedOptions,
customInput?}]`, dismissed → `cancelled:true`); `cancel {targetId}` withdraws one; `notify` is a
notice; dialogs arriving after the turn ended are cancelled. Events (`OmpEventMapper`):
`message_update` text/thinking deltas (item ids `<messageId>:<contentIndex>`, prefixed after a
relaunch), `tool_execution_start|update|end` → bash → command, write/edit/ast_edit → fileChange
(edit diffs converted from omp's line-numbered format), read/grep/glob/find → toolCall, web_search
→ webSearch, task → subagent, todo → "Updated tasks", ask → none, others → toolCall titled by
`intent`; assistant `usage` → token usage; an assistant `message_end` with `stopReason:"stop"`
marks its text final (the timeline drops "Thinking" under it and keeps every final answer out of
the closed fold; a resume keeps the flag, `Turn.resumedAt` brings "Thinking" back); an
advisor review (`message_end` of `role:"custom"`, `customType:"advisor"`, `details.notes[{note,
severity, advisor}]`) → `advisory` (one timeline row per note, never folded; one arriving after
the turn ended joins the latest turn); compaction/retry → notices. Subagents: `set_subagent_subscription {level:"events"}` after the
handshake (`try?`: older builds show none); `OmpSubagentMapper` folds `subagent_lifecycle`
(status), `subagent_progress` (assignment, `lastIntent`, `resolvedModelIdentity`; repeats are
dropped) and `subagent_event` (the subagent's own session events: `agent_start` opens a run,
reported with the first `user` or `custom` message; `irc:incoming` messages read "From <agent>:
…", advisor reviews become one `advisory` (never opening a run: a pending run is named "Advisor
review", an idle subagent's review joins its last run), other custom messages notices; assistant
messages get a synthesized `messageId`
since subagent events carry none, then go through a per-subagent `OmpEventMapper`; tool
updates after a tool's end are dropped; `agent_end` ends the run, `stopReason` aborted →
interrupted, error → failed). `steer_subagent {subagentId, message}`, `cancel_subagent
{subagentId}`. A restart or the process's end reports running subagents aborted. Rollback before a turn: `get_entries`, the
turn's entry (its `providerTurnID`; turns recorded as `prompt-N` count user-authored, non-steering
user messages), then `fork {entryId}` of the last `message` entry before it on the current
branch, or `new_session` when none; the new `sessionFile` becomes the conversation id.
`navigate_tree` is not used: it only moves the leaf in memory and the next `--resume` restores
the old tip. No Plan mode (omp's RPC has no plan-mode switch). Probe:
`omp --version` plus a short-lived `omp --mode rpc --no-session --no-extensions --no-skills
--no-rules --no-lsp` for `get_state` and `get_available_models` (≈730 models: first `default`
named "<model> · configured", then "<name> · <provider>", effort = "off" + `thinking.efforts`).
The composer's model list shows the first 80 matches of a multi-word search plus a "N more" row.
Traces: `Tests/SopranoAgentsTests/Fixtures/omp-ask-write-edit-bash.jsonl`, `omp-builtin-yield.jsonl`
(`/context`, then an async bash job that yields, wakes the agent and settles), `omp-subagent.jsonl`
(a detached `sonic` subagent steered mid-run that gets a background-job notice and completes).

Context, compaction and commands:
- omp: `get_available_commands` after the handshake, then `available_commands_update`
  (`{name, source, aliases?, description?, input?{hint}, subcommands?}`); skills are
  `skill:<name>`; badges builtin → Built-in, skill → Skill, extension → Extension, mcp_prompt →
  MCP, custom/file → Custom. After each turn `get_state` → `contextUsage {tokens, contextWindow}`.
  `compact` is sent without a waiter (its response then arrives after `manual_compaction_end`),
  which gives the notice (committed / skip reason / cancelled) or an error; then `get_state` and
  `get_entries` (the compaction entry becomes the turn id). A skip ("Already compacted") is a
  failed response but the turn completes.
- Traces: `omp-commands-compact.jsonl`.

Text generation: `omp -p --no-session --no-tools --no-extensions --no-skills --no-rules
--no-context-files --no-lsp [--model <provider/id>] --thinking low` (prompt plus schema on stdin,
first JSON object of stdout). 180 s timeout.

### Accounts (`Vendored/Accounts`, `Views/Accounts`)
Soprano's accounts layer is vendored unchanged. `AccountsController.shared.start()` runs only in
`AppDelegate`, before the engine is built: it writes omp's preference overlay into
`AccountLaunchState`. The app lists only omp's Claude and Codex logins (`AccountListID.ompClaude`,
`.ompCodex`, in that order); the controller's other lists stay unused. Views read and act only
through `AccountsCenter.source` (`AccountsSource`: snapshot, observers, refresh, add,
reauthenticate, cancel, select, remove, dismiss); the app installs the controller, tests and the
snapshot harness use `FixtureAccountsSource`, so no account CLI, Keychain read or usage request
runs there. Launch seam: drivers and sessions take `launchAdjustments: @Sendable () ->
ProviderLaunchAdjustments` (environment over the app's, arguments before the provider's) and read
it on every spawn (sessions, probes, text generation). `EngineFactory` injects
`AccountLaunchBridge.ompAdjustments(state:)`: omp gets `--config <Application Support>/<bundle
id>/omp-accounts.yml` once a preference exists. The account list is in UserDefaults
`soprano-accounts` (separate from Soprano's); Keychain items and omp's logins are shared with
Soprano.

### Usage statistics (Core/Usage)
`EngineEnvironment.usage: UsageStatisticsService` reads the agent's recorded usage;
`OmpUsageStatistics` is the live one. omp keeps one row per model request (tokens, API-equivalent
cost per token kind, agent kind, session folder) in `~/.omp/stats.db` (`PI_CONFIG_DIR` moves
`~/.omp` under home, joined as omp joins it), ingested from its session files by `omp stats`.
`sync()` runs `omp stats --summary` (120 s timeout, output ignored); `groups(since:granularity:)`
opens the database read-only and sums `messages` since the period's start per local hour (24h;
keyed by the epoch second the local hour starts, so a clock change's repeated hour stays two) or
local day, provider/model, `agent_type` and `folder` (`stop_reason = 'error'` = failed;
unpriced as omp counts it: tokens, zero cost, `xai-oauth` or `cost_unpriced`; cache savings =
`cost_no_cache_input` − the cached prompt cost of the rows that report it). No database = no
history; a missing table or column is `UsageStatisticsError.database`.
`engine.usageHistory(period, sync:)` reads even when the sync failed (`UsageHistory.syncError`)
and returns a `UsageHistory` whose `summary(model:)` folds the groups into chart buckets
(`UsagePeriod.buckets`: the last 24 hours as 25 hourly bars, the first holding the part of its hour inside the window; 7 / 30 / 90 calendar days ending today, All weekly from the first
request, monthly beyond 26 weeks), totals and model / folder / agent breakdowns; the model filter
narrows everything except the model list. `usageFolderTitles()` maps the stats folders of project
roots and thread working directories to project titles. `UsageFolderName.encode` follows omp:
the `realpath` of the directory (`/tmp` → `/private/tmp`), named `-tmp-<relative>` under the
temporary directory, `-<relative>` under home, else `--<absolute>--` (`/ \ :` → `-`), which
omp-stats stores with a leading `--` and every later `--` as `/` (`/private-tmp-x/`). The
snapshot harness and tests use `FixtureUsageStatistics` / scratch databases; nothing reads the
user's `stats.db` there.

### Git (Core/Git)
`LiveGitService: GitService`. All git through `GitRunner` (`git --no-pager -c core.quotepath=false
-c color.ui=never -C <cwd> …`, `GIT_TERMINAL_PROMPT=0`, extended PATH). Checkpoints never touch the
user's index or HEAD: temp index `GIT_INDEX_FILE=<git-common-dir>/soprano-agents-index-<uuid>`
(copied from the real index when HEAD exists, `read-tree --reset HEAD`), `add -A -- .`,
`write-tree`, `commit-tree <tree> [-p HEAD] -m "soprano-agents checkpoint <ref>"`, `update-ref
<ref> <commit>`, committer/author "Soprano Agents" <soprano-agents@users.noreply.github.com>.
Diffs: `git diff --no-color --no-ext-diff --no-textconv -M [--ignore-all-space] <a>^{commit}
<b>^{commit}` (numstat for `changedFiles`). Restore: `git restore --source <commit> --worktree
--staged -- .`, `git clean -fd -- .`, `git reset --quiet -- .`. `status` (changed files with line
counts) and `workingTreeDiff` stage into the same kind of scratch index, so untracked files count
and `.gitignore` is respected. `DiffParser.parse(_:)` turns a patch into `FileDiff`s for the right
panel. Worktrees live at `<dir>/<repo>/<branch with / → ->` (names over 40 characters: 23 + `-` +
16 hex of SHA-256), branched `--no-track` from the base, which is recorded as
`branch.<b>.soprano-agents-merge-base` (the PR base). Commit/push/PR is a stacked
action flow (push = `git push -- <remote> HEAD:refs/heads/<b>` + upstream config); PRs via
`gh pr create`; open PR lookup via `gh pr view --json` (4 s deadline, failures ignored).

### `WorkspaceState` (Shell)
UI state: `selection` (`.draft(projectID:)`, `.thread(id)` or `.subagent(threadID:subagentID:)`:
the timeline shows the subagent's runs via `Subagent.timelineThread`, not editable; the composer
messages it (Stop stops it; model, permissions and attachments hide); the header reads `project /
thread / Reader · sonic`, the thread title opens the thread; `selectedThreadID` is the owning
thread, `selectedSubagentID` the subagent) and its `workspace` (`WorkspaceRef`;
nil for a projectless draft, which has no folder), panel visibility (sidebar, thread details card,
terminal drawer, right panel, statistics board), the right-panel tabs per workspace key (`RightPanelSurface`:
`.diff`, `.files`, `.file(path)`, `.terminal(sessionID)`; `rightPanelSurfaces`, the active
`rightPanelSurface` — nil = "Open a surface" launcher —, `showRightPanel(_:)`,
`closeRightPanelTab(_:key:)`, `pruneRightPanelTabs(keeping:)`, `moveDraftTabs(projectID:to:)`),
diff scope + focused path, sidebar project filter and search text, and `restoreComposer(with:)` /
`takeComposerRestore()` ("Edit from here" hands the user message back to the composer). Observe
`Change` (`.selection`, `.panels`, `.filter`, `.composerRestore`); a selection switch changes the
active tab too. `isStatisticsVisible` (`setStatisticsVisible`) closes on `select` (also of the
selected thread; selections the app makes itself, a launched draft becoming its thread or a
removed thread or project falling back to a draft, pass `closingStatistics: false`) and whenever
the terminal, right panel, a diff or the thread details open. Toggle commands for a surface
under the board (⌘J, ⌘L, ⇧⌘B, ⌘D, ⇧⌘F, Maximize) show it instead of hiding it
(`toggledVisibility`). Composer and timeline commands that show or focus something in the chat
column (Focus Composer, the pickers, Compact, Find in Thread, Jump to Latest, Expand / Collapse
All) get it through `WorkspaceViewController.revealChat()`, which closes the board first. A board
that had focus hands it to the composer, or to a maximized right panel, when it closes; while it
shows, `ComposerViewController.focusEditor()` does nothing, so background selections keep the
keyboard on the board.

### Regions (view controllers)
`WorkspaceViewController` lays out sidebar | chat column | right panel (resizable rails, widths
in an injectable `UserDefaults`). `ChatViewController` stacks header (52 pt), timeline, the
floating composer (centered, ≤ 736 pt, 20 pt above the terminal drawer; vertically centered for
drafts), the terminal drawer, and the Thread details card (top-right, 280 pt). The header's
location chip (right-aligned before the title-bar toggles) shows `WorkspaceLocation.title`
(`repo/sub/folder`, the `~` path outside git, "Scratch") and the branch, tooltip with kind and
full path, click toggles the thread details; it reloads on workspace, folder, branch or running
changes and app activation, squeezes to 160 pt before the breadcrumb, and hides below that.
`RightPanelViewController` hosts the tab strip ("+" = native menu: Terminal, Files, Diff), the
launcher (`T`/`F`/`D` while it has focus; Terminal and Files need a workspace, so only a
projectless draft disables them) and one controller per surface kind: `DiffSurfaceViewController`
(drafts always show Uncommitted), `FilesSurfaceViewController` (explorer, search, context menu),
`FileViewerViewController` (breadcrumbs, line numbers, syntax colors, images),
`TerminalSurfaceViewController` (focus region `.terminal`). Terminals, Files and the drawer work
in a project draft (the project root); when the draft starts a "Current checkout" thread, its
tabs and running terminals move to that thread (`ComposerViewController.onDraftLaunched`).

Region controllers keep `init(engine:state:)`, except `RightPanelViewController`, which also takes
the drawer's `ThreadTerminalStore`: one store owns every terminal of the window (sessions per
workspace key with a `.drawer`/`.panel` placement and shared "Terminal N" numbering, SwiftTerm
views, shells), so a panel terminal's exit, a deleted thread or project and app quit end shells
in one place. Contracts the
container relies on: `TimelineViewController.bottomInset` (space the composer covers),
`ComposerViewController.onHeightChange` and `focusEditor()`, `ChatViewController.terminalDrawerHeight`.
Region controllers that take keyboard focus adopt `FocusRegionController`.

The composer footer shows a context meter (`ContextMeterView`, 16 pt ring left of send/stop) for
`thread.contextUsage`: a muted full track under a foreground arc below 70%, `warning` from 70%, `error` from 90%, hidden for drafts and
unknown usage, tooltip `Context: 62.4k / 200k tokens (31%)`. Clicking it opens a child-window card
(`ContextMeterCardContent`) with the usage bar, `62.4k of 200k tokens used · 31%` and "Compact
conversation" (`engine.compact`, enabled by `engine.canCompact`; failures are alerts). The `/`
command menu (`SlashCommandMenuContent`) is a passive `ComposerPopover` (never key; clicks on the
composer pass through) anchored above the composer at its width. It opens while the caret is in a
line-start token starting with `/` (`SlashToken`), lists
`engine.commands(forThread:)` / `commands(forDraft:projectID:)` plus the app's `/compact` row when
the thread can compact and the provider has none, filtered by `SlashCommandFilter` (name prefix,
then name substring, then description substring), and re-lists on `.commandsChanged`. The editor
keeps focus and hands ↑/↓, Enter, Tab and Escape to the menu first (`menuKeyHandler`): Enter/Tab
replace the token with `insertText` (keeping what follows), Escape hides the menu until the caret
leaves the token, Enter never sends while it shows (with nothing to pick it closes the menu). It
closes on send, focus loss, thread switch and when another of the app's windows becomes key
(palette, dialog, settings); app deactivation keeps it. Text the composer sets itself never opens
it; the editor has inline predictions and text completion off.

The sidebar footer ends with the account button after the gear and the statistics button
(`AccountButton`, `person.crop.circle`): muted while every headline Claude and Codex login's
tightest window is below 70%, `warning` from 70%, `error` from 90%; its tooltip lists each
headline login's windows and resets. Clicking it or `usage.open` toggles the usage card
(child window): per provider, per account list, each login with its 5h/7d bars, percent and
reset, plus Refresh and "Manage Accounts…" (Settings → Accounts).

The statistics board (`StatisticsViewController`, toggled by `statistics.toggle` and the chart
button next to the sidebar's gear) covers the chat column and the right panel, which stay
loaded underneath; it takes key focus (Esc closes, `C` / `T` Cost / Tokens, `1`–`5` the period)
without being a focus region, so window shortcuts keep working. Header: "Statistics", period
control (24h · 7d · 30d · 90d · All, default 7d), Refresh, Close; a sidebar toggle while the
sidebar is hidden. Content (≤ 960 pt): Cost / Tokens, a model-filter chip, four tiles (Cost:
estimated cost, cache savings, requests, per request; Tokens: total, input, output, cache read),
the stacked chart (cache read, cache write, input, output; hover shows the bar in the title
line), Models (share bar, requests, cache hit rate, value; click filters), Projects (top 8 plus
"N more") and Agents, and a footnote. Opening and Refresh sync omp's history, a period switch
only reads (or takes over a running sync). A failed read shows an error with Retry above the
last data of the same period (another period's data is dropped); a failed sync shows a notice
above what was recorded before it.

### Commands (`Commands/AppCommand.swift`)
Every user action is an `AppCommand` registered once at launch from its module's
`…Commands.all` (`ShellCommands`, `SidebarCommands`, `TimelineCommands`, `ComposerCommands`,
`PanelCommands`, `AccountCommands`, `StatisticsCommands`). Commands are the single source for key bindings, the palette, menus and
buttons, and the snapshot harness runs them with `--perform <id>`. `CommandContext` carries
`engine`, `state`, `workspace`, `window`, `focus`, `isTextInput`, and `thread` (selected).

### Settings (`Shell/AppEnvironment.swift`, `SettingsResolution.swift`, `SettingsFile.swift`)
`~/.config/soprano-agents/settings.json` (JSONC, `SOPRANO_AGENTS_CONFIG` overrides), live
reloaded; bad values become warnings. Keys: `theme`, `agents.{defaultModel, defaultRuntimeMode}`,
`providers.ompPath`, `textGeneration.{model, titles}`, `worktrees.{directory, branchPrefix}`, `projects.directories`,
`chat.{followUp, width}`, `notifications.{enabled, sound}`, `editor.app`,
`keybindings.{prefixKey, prefixTimeoutMs, bindings}`. `AppSettings.engineSettings` feeds
`AgentEngine.settings`. Window geometry, panel
widths and per-thread UI state stay in `UserDefaults`.

## Keyboard model

The router is an `NSEvent` local monitor (Soprano's model): ⌃A prefix mode, scopes by
`FocusRegion` (`sidebar`, `timeline`, `composer`, `terminal`, `rightPanel`, `settings`), chords
without ⌘/⌃ never fire in text input, ⌥ chords pass through (German layouts), a region-scoped
binding beats a global one. Shortcuts that would need ⌥ use ⌃⌘ instead.

### Default bindings

| Command id | Title | Scope | Keys | Owner |
|---|---|---|---|---|
| `palette.open` | Command Palette | global | `cmd+k`, `cmd+p` | Shell |
| `settings.open` | Settings | global | `cmd+,` | Shell |
| `settings.openFile` | Open settings.json | global | — | Shell |
| `view.toggleSidebar` | Toggle Sidebar | global | `cmd+e` | Shell |
| `view.toggleThreadDetails` | Toggle Thread Details | not terminal | `cmd+shift+b` | Shell |
| `view.toggleTerminal` | Toggle Terminal Drawer | global | `cmd+j` | Shell |
| `view.toggleRightPanel` | Toggle Right Panel | global | `cmd+l` | Shell |
| `chat.new` | New Thread | not terminal | `cmd+n`, `cmd+shift+o` | Sidebar |
| `chat.newLocal` | New Thread in Current Project | not terminal | `cmd+shift+n` | Sidebar |
| `chat.newWithoutProject` | New Thread Without a Project | not terminal | `cmd+ctrl+n` | Sidebar |
| `project.open` | Open Project… | global | `cmd+shift+k` | Sidebar |
| `thread.previous` / `thread.next` | Previous / Next Thread | global | `cmd+shift+[` / `cmd+shift+]` | Sidebar |
| `thread.jump.1`…`9` | Go to Thread N | global | `ctrl+1`…`ctrl+9` | Sidebar |
| `thread.settle` | Settle Thread | not terminal | `cmd+shift+s` | Sidebar |
| `thread.pin` | Pin Thread | not terminal | `cmd+shift+p` | Sidebar |
| `thread.rename` | Rename Thread | sidebar | — (F2 in the sidebar list, hard-coded: `KeyChord` has no function keys) | Sidebar |
| `thread.archive` / `thread.delete` | Archive / Delete Thread | — | — | Sidebar |
| `thread.copyReference` | Copy Thread Reference | not terminal | `cmd+shift+c` | Sidebar |
| `sidebar.search` | Search Threads | global | — | Sidebar |
| `sidebar.filterProjects` | Filter Threads by Project | global | — | Sidebar |
| `chat.find` | Find in Thread | sidebar, timeline, composer | `cmd+f` | Timeline |
| `timeline.jumpToLatest` | Jump to Latest | timeline | `cmd+down` | Timeline |
| `timeline.expandAll` / `timeline.collapseAll` | Expand / Collapse All Work | — | — | Timeline |
| `composer.focus` | Focus Composer | global | `cmd+shift+l` | Composer |
| `modelPicker.toggle` | Model Picker | not terminal | `cmd+shift+m` | Composer |
| `composer.effort` | Reasoning Effort | not terminal | `cmd+shift+e` | Composer |
| `composer.mode` | Permissions | not terminal | `cmd+shift+a` | Composer |
| `composer.workspace` | Workspace | not terminal | `cmd+shift+x` | Composer |
| `composer.branch` | Branch | not terminal | `cmd+shift+g` | Composer |
| `composer.sendAlternate` | Steer or Queue (opposite) | composer | `cmd+enter` | Composer |
| `thread.stop` | Interrupt | global | — | Composer |
| `thread.compact` | Compact Conversation | — | — | Composer |
| `diff.toggle` | Toggle Diff | not terminal | `cmd+d` | Panels |
| `files.toggle` | Toggle Files | not terminal | `cmd+shift+f` | Panels |
| `files.search` | Search Files | — | — | Panels |
| `rightPanel.newTerminal` | New Terminal in Right Panel | global | `cmd+shift+j` | Panels |
| `rightPanel.closeTab` | Close Tab | rightPanel | `cmd+w` | Panels |
| `rightPanel.find` | Find in Panel (file tab: find bar; Files: search; else Find in Thread) | rightPanel | `cmd+f` | Panels |
| `terminal.new` | New Terminal (drawer, or a panel tab when one has focus) | terminal | `cmd+n` | Panels |
| `terminal.close` | Close Terminal (drawer, or the focused panel tab) | terminal | `cmd+w` | Panels |
| `editor.openFavorite` | Open in Editor | global | `cmd+o` | Panels |
| `git.openInSopranoGit` | Open in Soprano Git (the workspace's repository root, as in Soprano) | global | `prefix+g` | Panels |
| `git.commit` / `git.push` / `git.createPR` | Commit / Push / Create PR | — | — | Panels |
| `diff.toggleLayout` / `diff.toggleFileTree` | Toggle Split Diff View / Diff File Tree | — | — | Panels |
| `rightPanel.toggleMaximized` | Maximize Right Panel | — | — | Panels |
| `usage.open` | Show Usage | global | `cmd+u` | Accounts |
| `accounts.manage` | Manage Accounts… | global | — | Accounts |
| `usage.refresh` | Refresh Usage | global | — | Accounts |
| `statistics.toggle` | Statistics | global | `cmd+shift+u` | Statistics |

"not terminal" = scopes `[sidebar, timeline, composer, rightPanel]` (plus nil focus handled by the
router as global). A right-panel terminal tab is focus region `terminal`, like the drawer.

## Layout and visual design


```
┌ sidebar 256 (208…) ┬ chat column (≥ 640) ──────────────────────────────┬ right panel 540 (360…70%) ┐
│ [traffic lights]   │ header 52: project / Title ⌄ ▢ repo ⑂ br [▤][▭][◫] │ tabs [Diff][Files][x.swift]+│
│ Search  [⫶][📁][✎] │   lane ≤ 736 centered                ┌ details ┐   │                             │
│ Pinned / Active    │   user bubble right (≤ 80%, r16)    │ card 280 │   │                             │
│ cards (78)         │   Worked for 3m 12s ›               └──────────┘   │                             │
│ …                  │   assistant markdown 14/1.625                      │                             │
│ Working 1 ›        │   N changed files card                             │                             │
│ Settled 43 ›       │   ┌ composer r16, glass ┐                          │                             │
│ [⚙][▥][◎]          │ terminal drawer 280 (180…75%)                      │                             │
└────────────────────┴────────────────────────────────────────────────────┴─────────────────────────────┘
```

- Colors only from `PaletteCenter.shared.palette`, which `Palette(soprano:)` derives from the
  Soprano theme in force (`theme: "soprano"` by default, following Soprano's own theme and
  appearance; `folio` follows macOS light/dark). Terminals (drawer and panel tabs) use the theme's terminal
  palette, project monograms its accent hues. Views subclass `PaletteView` and re-color in
  `applyPalette(_:)`.
- Fonts from `Typography`: system font (14 body, 13 detail rows, 12 meta/pills, 11 kbd), SF Mono
  13 for code, diffs and command output. The terminal is 12 pt in an installed "… Nerd Font Mono"
  family (JetBrains Mono first), else Powerlevel10k's "MesloLGS NF", so prompt icons and powerline
  separators render; without either, SF Mono with Symbols Nerd Font Mono as fallback when
  installed (regular cells only: SwiftTerm derives bold/italic without it). Icons are SF Symbols (`Icon` names
  them by role), 16 pt in 28 pt ghost buttons.
- Radii from `Radius`: composer, bubbles, dialogs, details card 16; buttons, menus,
  popovers, code blocks, changed-files card 8; sidebar cards 6.
- Status pills (sidebar): Working (info, `circle.dashed`, live duration), Approval (warning),
  Input (indigo), Failed (error), Done (success), else relative time ("now", "5m", "3h", "2d").
- Subagents (sidebar): a card with subagents shows its meta line with a disclosure "⌄ ⚙ N"
  (running/total while one runs, info-tinted); a slim row shows it before its time. Open (by
  default while one runs, else after a click) it lists 30 pt rows under the thread, indented
  18 pt with a tree guide: status glyph (running `circle.dashed` info, done `checkmark.circle`,
  failed, stopped `stop.circle`), name, "agent · latest intent" (else description or
  assignment), live run time. A selected subagent stays listed under a closed disclosure; its
  row, not the thread's, is highlighted, and its thread stays unread until opened itself.
- Motion: opacity/scale fades ≤ 200 ms, none under Reduce Motion; streaming text appears without
  animation.
- Floating surfaces that must appear in snapshots (palette, model picker, menus of the composer,
  branch picker, thread details popovers, context card, `/` command menu, usage card) are child windows of the main window
  (`window.addChildWindow(_:ordered:)`), not `NSPopover`. Context menus are native `NSMenu`.

## Verification harness

`SopranoAgents snapshot --out <png> [--fixture demo|running|stopping|approval|input|failed|background|answered|rechecked|subagents|subagent|draft|empty]
[--size 1440x900] [--appearance light|dark] [--theme <id>] [--hide-sidebar] [--details]
[--terminal] [--right-panel] [--diff thread|turn:<n>|uncommitted] [--open-file <path>]… [--perform <command id>]…
[--settings general|providers|accounts|text-generation|worktrees|notifications|keybindings|archive|about]
[--accounts none|demo|empty|pending]
[--dialog confirm|choose|prompt|alert] [--type "<text>"] [--keys "<chord> …"] [--hover <label>]
[--click <label>]… [--wait <seconds>]` builds the real window offscreen on a `DemoFixtures` scenario and writes a PNG
of it and its child windows. `--perform` runs any registered command (open the palette, the model
picker, `files.toggle`, `files.search`, `rightPanel.newTerminal`, …); `--open-file` opens a
workspace-relative file tab; `--settings` opens the settings screen on a page; `--dialog` presents a sample
`Dialogs` dialog; `--type` inserts text into the first responder (of the topmost overlay when one
shows); `--keys` replays chords through the router (or into the topmost overlay); `--hover` sets
the hover state of the `InteractiveView` with that accessibility label or tooltip; `--click` sends
a real mouse down/up at its center through the window, so whatever the window hit-tests there
(including a view drawn over the control) gets the click, as it would live. Clicks in the
titlebar strip start a window drag offscreen instead; use them below the header. Agents verify
UI with it and `read` the PNG; they do not launch the GUI.

The demo fixture's thread reports 124k of 200k context tokens and the engine remembers an omp
command list for it and the `app` project: `--perform composer.focus --type "/re"` opens the
filtered `/` menu, `--click "Context: 124k / 200k tokens (62%)"` the context card, and
`--fixture failed --perform composer.focus --type "/"` the empty state. `--fixture background`
adds and selects an omp thread whose turn yielded while a background job runs (finished turn,
an advisor's Concern, "Background work still running…" row, Send instead of Stop);
`--fixture answered` one whose final answer arrived while omp still wraps up the turn (Working,
Stop, no "Thinking" row); `--fixture rechecked` a finished turn that answered twice (an advisor
note and omp's auto-double-check woke the agent): the closed fold keeps both answers with their
copy rows, the note and notice between them, and the changed files under the last;
`--fixture stopping` the running thread after Stop was pressed ("Stopping…", dimmed Stop).
`--fixture subagents` adds and selects a thread whose yielded turn started two subagents
(running Reader, finished Scout: card disclosure "1/2" open, two subagent rows); `--fixture
subagent` selects Reader (its run with a steer, "Message Reader", Stop).
`--accounts` installs an
`AccountFixtures` snapshot before the window is built (default `none`: no usage): `demo`
has two Claude logins and one Codex login in omp with 5h/7d windows at 9 %, 72 %/93 % and
75 %/38 %; `pending` adds a waiting omp Claude sign-in and a failed action on the Codex list.
`--perform usage.open` opens the usage card; `--click "Accounts"` clicks the account button.
Every fixture engine reads `FixtureUsageStatistics` (≈ 120 days of working hours on the demo
projects plus a `-Downloads-experiments` folder; Opus main and subagents, a Sonnet advisor,
GPT-6.1 Sol and an unpriced OpenRouter model): `--perform statistics.toggle` opens the board on
7d, then `--keys "t"` switches to Tokens, `--click "Period All"` (or `24h`, `30d`, …) picks a
period and `--click "claude-opus-5-5"` filters to that model.

Modal surfaces (settings screen, `Dialogs`) are `OverlayWindow`s: borderless
child windows covering the main window with a dimmed backdrop and one card. Their keys
go to the overlay's `keyHandler` before menus and fields; while the settings screen records a
shortcut it routes every key through `KeyboardRouter.capture`.

The command palette and Open Project… (`Views/Palette/`) are Soprano's `CommandPalettePanel`
(vendored), one per window (`MainWindowController.palette`): a child panel under the titlebar
over a scrim, rows of icon, title over `AppCommand.description`, keycaps; substring search on
title, then description, then search text. `PaletteItems` builds the rows (commands, threads by
last use, projects, settings rows; or projects, the subfolders of `projects.directories` that are
no project yet, Choose Folder…); a chosen row runs after the panel closed. While it is key, only
`palette.open` / `project.open` reach the menu (close, or switch to projects). The harness types
into it with `--type` and sends it `--keys`.

## Tests

swift-testing (`import Testing`, `@Test`, `#expect`), one `struct …Tests` per file, sentence-style
names. Test files `import AppKit` (never `Foundation`) plus `@testable import SopranoAgents` /
`SopranoAgentsCore`. Provider parsing is tested against the recorded traces in
`Tests/SopranoAgentsTests/Fixtures/`; engine logic against a fake `ProviderDriver` and
`FixtureGitService`-style fakes; git against real temp repositories with an isolated config
(`HOME=<tmp>`, `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=<tmp>/gitconfig`). Tests never start a
real agent CLI and never touch the user's repositories, settings or app data.
