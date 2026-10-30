# Soprano Agents architecture

Soprano Agents is a native macOS GUI for coding agents (Codex, Claude Code) in the Soprano
family. It copies the feel and look of [T3 Code](https://github.com/pingdotgg/t3code): a thread
inbox on the left, a centered chat lane with a floating composer, collapsible work logs, per-turn
diffs from hidden git checkpoints, a terminal drawer and a right panel. Swift 6 + programmatic
AppKit (no SwiftUI, no storyboards), SPM, macOS 14+. The app talks to the agent CLIs directly;
there is no server process.

The T3 Code reference spec (layout, tokens, strings, protocols) this app follows lives in
`docs/t3code-spec.md`. When this document and the spec disagree, this document wins.

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
| `Sources/SopranoAgentsCore/Providers/` (rest) | Providers | `LineProcess` (stdio JSON-lines transport), Codex app-server client + session + driver, Claude stream-json session + driver, model catalogs, `generateJSON` for both. |
| `Sources/SopranoAgentsCore/Engine/` | Engine | `AgentEngine` (state owner, observers, inbox lifecycle) and `AgentEngine+Turns.swift` (sessions, sending, steering, queue, approvals, checkpoints, revert, diffs, titles, git actions). `EngineTypes.swift` is contract. |
| `Sources/SopranoAgentsCore/Store/` | Engine | `JSONFileThreadStore`. |
| `Sources/SopranoAgentsCore/Git/GitService.swift` | Contract | `GitService`, `SourceControlWriter`, status/branch/action value types. |
| `Sources/SopranoAgentsCore/Git/` (rest) | Git | `GitRunner` (the only place that spawns git), `LiveGitService` (checkpoints, diffs, status, branches, worktrees, commit/push/PR via `gh`), parsers. |
| `Sources/SopranoAgents/Theme/` | Shared kit | `Palette` + `PaletteCenter`, `Typography`, `Metrics`, `Radius`, `Icon`, `PaletteView`, `InteractiveView`, `GhostIconButton`, `TextButton`, `KbdView`. |
| `Sources/SopranoAgents/Shell/`, `App/`, `Commands/AppCommand.swift`, `ShellCommands.swift` | Shell | App delegate, menus, window, workspace layout, `WorkspaceState`, settings (`SettingsCenter`, resolver, template), keymap + router, `Dialogs`, command palette, settings screen, notifications, snapshot harness. |
| `Sources/SopranoAgents/Views/Sidebar/`, `Views/Chat/ChatHeaderView.swift`, `SidebarCommands.swift` | Sidebar | Thread inbox, chat header + title-bar toggles. |
| `Sources/SopranoAgents/Views/Timeline/`, `TimelineCommands.swift` | Timeline | Message timeline, Markdown renderer, work log, cards. |
| `Sources/SopranoAgents/Views/Composer/`, `ComposerCommands.swift` | Composer | Composer, pickers, draft hero + context strip. |
| `Sources/SopranoAgents/Views/Panels/`, `PanelCommands.swift` | Panels | Right panel (diff), terminal drawer, Thread details card (editor, scripts, branch, git actions). |
| `Sources/SopranoAgents/Fixtures/` | Shell | `DemoFixtures` scenarios + `FixtureGitService` for snapshots and UI tests. |
| `Sources/SopranoAgents/Vendored/` | — | Copied from Soprano by `scripts/sync-soprano-chrome.sh`. **Never edit.** |

Modules talk only through the contracts: views read `AgentEngine` state and call its methods;
UI state goes through `WorkspaceState`; commands through `CommandRegistry`. A view never talks to
a provider and never spawns git: read-only git queries (status, branches) go through
`engine.environment.git`, every write through an engine method. The only processes the UI layer
starts itself are terminal-drawer shells (SwiftTerm) and `NSWorkspace` opens (editor, Finder, URLs).

## Seams

### `AgentEngine` (Core/Engine)
`@MainActor`, the single owner of projects, threads, provider sessions and provider statuses.
Views read `projects`, `threads`, `thread(_:)`, `project(_:)`, `status(of:)`, `settings` and observe
`EngineEvent` with `engine.addObserver(self) { [weak self] event in … }`:

- `.projectsChanged`, `.threadListChanged` (add/remove, title, section, status pill, branch),
  `.threadChanged(threadID:)` (turns/queue/settings), `.itemChanged(threadID:turnID:itemID:)`
  (streaming deltas: re-render just that row), `.providersChanged`.
- Mutations: `addProject`, `removeProject`, `rename`, `setPinned`, `setSettled`, `setArchived`,
  `markVisited`, `markUnread`, `setModelSelection`, `setRuntimeMode`, `setInteractionMode`,
  `launchThread`, `send`, `interrupt`, `respond`, `answer`, `dismissUserInput`, `sendQueuedNow`,
  `cancelQueued`, `revert`, `turnDiff`, `regenerateTitle`, `deleteThread`, `gitStatus`,
  `runGitAction`, `importAttachment`, `refreshProviders`, `shutdown`. Contracts in the doc comments
  of `AgentEngine.swift` and `AgentEngine+Turns.swift`.

Engine behavior:
- One `ProviderSession` per thread, created lazily on first send (resumes `providerThreadID`
  after relaunch), closed on delete/shutdown. Provider events fold into the active turn:
  `itemUpdated` replaces by id, deltas append, approvals/user input become items, `turnCompleted`
  finishes the turn and starts the next queued message.
- Checkpoints: before turn N, if `CheckpointRef.ref(thread, N-1)` is missing, capture it; after
  turn N ends (completed or interrupted), capture `ref(thread, N)` and store
  `TurnCheckpoint(files:)` from `changedFiles(ref(N-1), ref(N))`. Not a repo → status `.missing`.
- Turn diff N = `diff(ref(N-1), ref(N))`; thread diff = `diff(ref(0), ref(last))`.
- Revert to before turn N: interrupt guard, provider `rollback(beforeTurn:)`, optional
  `restoreCheckpoint(ref(N-1))`, delete refs ≥ N, drop turns ≥ N, return turn N's user message.
- Titles: first message → title seed (first 50 chars + "...") immediately, then
  `textGenerationModel` via `ProviderDriver.generateJSON` with T3 Code's title prompt.
- New worktree: branch `<branchPrefix>/<8 hex>` from the base branch at
  `<worktreesDirectory>/<repo>/<branch with / → ->`, renamed in the background to a generated name
  (`<branchPrefix>/<fragment>`).
- Persistence: every change goes through `ThreadStore` (JSON file per thread under
  `<data>/threads/`, projects in `<data>/projects.json`, atomic, coalesced writes). Streaming
  deltas are not written on every token; the store coalesces.
- Data root: `AppPaths.dataDirectory()` = `~/Library/Application Support/<bundle name>`
  (`SOPRANO_AGENTS_DATA_DIR` overrides). Attachments in `<data>/attachments/<thread>/`.

### Providers (Core/Providers)
`ProviderDriver` per kind (`CodexDriver`, `ClaudeDriver`) creates `ProviderSession`s, probes the
CLI (`probe()` → version, account, models), and runs one-shot `generateJSON`.

**Codex** — `codex app-server` (path from `EngineSettings.codexPath` or PATH; GUI apps get a
minimal PATH, so search `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.bun/bin`,
`~/.cargo/bin` too). Env `CODEX_INTERNAL_ORIGINATOR_OVERRIDE=Soprano Agents`. Newline-delimited
JSON-RPC without a `jsonrpc` field: requests `{id, method, params}`, responses `{id, result|error}`,
notifications `{method, params}`, server requests `{id, method, params}` (ids may be numbers or
strings). Handshake `initialize {clientInfo:{name:"soprano_agents", title:"Soprano Agents",
version}, capabilities:{experimentalApi:true, optOutNotificationMethods:["turn/diff/updated"]}}`
then notification `initialized`. Threads: `thread/start {cwd, model, config:{"tools.update_plan.enabled":true}}`,
`thread/resume {threadId, excludeTurns:true, cwd, model}`, `turn/start {threadId, input:[{type:"text",
text, text_elements:[]}, {type:"localImage", path}], cwd, model, effort, summary:"detailed",
approvalPolicy, sandboxPolicy, collaborationMode?}`, `turn/steer {threadId, expectedTurnId, input}`,
`turn/interrupt {threadId, turnId}`, `thread/revert {threadId, beforeTurnId}`. Runtime mode map:

| RuntimeMode | approvalPolicy | sandboxPolicy |
|---|---|---|
| approval-required | `untrusted` | `{type:"readOnly", networkAccess:false}` |
| auto-accept-edits | `on-request` | `{type:"workspaceWrite", writableRoots:[], networkAccess:false, excludeTmpdirEnvVar:false, excludeSlashTmp:false}` |
| auto | `on-request` (+ `approvalsReviewer:"auto_review"`) | workspaceWrite as above |
| full-access | `never` | `{type:"dangerFullAccess"}` |

Notifications → events: `turn/started`, `item/started|completed` (`ThreadItem` union: `userMessage`
ignored, `agentMessage` (`phase:"final_answer"` = final), `reasoning`, `commandExecution`,
`fileChange`, `mcpToolCall`, `dynamicToolCall`, `webSearch`, `plan`, `contextCompaction`),
`item/agentMessage/delta`, `item/reasoning/summaryTextDelta`, `item/commandExecution/outputDelta`,
`item/plan/delta`, `turn/plan/updated` (todo list, item id `turn-plan:<turnId>`),
`thread/tokenUsage/updated`, `error`, `turn/completed` (`completed|interrupted|failed`).
Server requests: `item/commandExecution/requestApproval` and `item/fileChange/requestApproval` →
`{decision: "accept"|"acceptForSession"|"decline"|"cancel"}`; `item/permissions/requestApproval`;
`item/tool/requestUserInput` → `{answers:{<qid>:{answers:[…]}}}`; anything else unsupported →
JSON-RPC error. TypeScript bindings: `codex app-server generate-ts --out <dir>`. A real trace is in
`Tests/SopranoAgentsTests/Fixtures/codex-turn.jsonl`.

**Claude Code** — `claude -p --input-format stream-json --output-format stream-json --verbose
--include-partial-messages --permission-prompt-tool stdio --permission-mode <mode> --model <id>
[--effort <e>] [--resume <session> | --session-id <uuid>] [--add-dir …]`. One long-lived process per
thread; each turn writes `{"type":"user","message":{"role":"user","content":[…image blocks…,
{"type":"text","text":…}]},"parent_tool_use_id":null}`. Control protocol on the same pipes:
host → CLI `{"type":"control_request","request_id","request":{"subtype":"initialize"|"interrupt"|
"set_permission_mode","mode"|"set_model","model"}}`; CLI → host `{"type":"control_request",
"request_id","request":{"subtype":"can_use_tool","tool_name","input","permission_suggestions",
"tool_use_id"}}` answered with `{"type":"control_response","response":{"subtype":"success",
"request_id","response":{"behavior":"allow","updatedInput":{…}} | {"behavior":"deny","message":…}}}`.
Steering = another user message with `"priority":"now"` while the turn runs. Permission mode map:
plan → `plan`; approval-required → `default`; auto-accept-edits → `acceptEdits`; auto → `auto`;
full-access → `bypassPermissions`. `AskUserQuestion` arrives as `can_use_tool` and becomes a user
input request (allow with `updatedInput {questions, answers}`); `ExitPlanMode` becomes a plan item
and is denied with T3 Code's message. Messages: `system/init` (session id), `stream_event`
(`text_delta`, `thinking_delta`), `assistant` (text, thinking, tool_use), `user` (tool_result),
`result` (turn end). Tool → item: Bash → command, Edit/MultiEdit/Write/NotebookEdit → fileChange,
Read/Glob/Grep/LS → toolCall read/search, WebFetch/WebSearch → webSearch, TodoWrite → todoList,
others → toolCall. Traces: `Tests/SopranoAgentsTests/Fixtures/claude-*.jsonl`.

Text generation: Codex `codex exec --ephemeral --skip-git-repo-check -s read-only --model <m>
--config model_reasoning_effort="low" --output-schema <file> --output-last-message <file> -`
(prompt on stdin); Claude `claude -p --output-format json --json-schema <schema> --model <m>
--tools "" --disable-slash-commands --permission-mode dontAsk` (prompt on stdin). 180 s timeout.

### Git (Core/Git)
`LiveGitService: GitService`. All git through `GitRunner` (`git --no-pager -c core.quotepath=false
-c color.ui=never -C <cwd> …`, `GIT_TERMINAL_PROMPT=0`, extended PATH). Checkpoints never touch the
user's index or HEAD: temp index `GIT_INDEX_FILE=<git-common-dir>/soprano-agents-index-<uuid>`
(copied from the real index when HEAD exists, `read-tree --reset HEAD`), `add -A -- .`,
`write-tree`, `commit-tree <tree> [-p HEAD] -m "soprano-agents checkpoint <ref>"`, `update-ref
<ref> <commit>`, committer/author "Soprano Agents" <soprano-agents@users.noreply.github.com>.
Diffs: `git diff --no-color --no-ext-diff --no-textconv -M [--ignore-all-space] <a>^{commit}
<b>^{commit}` (numstat for `changedFiles`). Restore: `git restore --source <commit> --worktree
--staged -- .`, `git clean -fd -- .`, `git reset --quiet -- .`. Commit/push/PR follows T3 Code's
stacked action flow; PRs via `gh pr create`; open PR lookup via `gh pr view --json`.

### `WorkspaceState` (Shell)
UI state: `selection` (`.draft(projectID:)` or `.thread(id)`), panel visibility (sidebar, thread
details card, terminal drawer, right panel), right-panel surface + diff scope + focused path,
sidebar project filter and search text, and `restoreComposer(with:)` / `takeComposerRestore()`
("Edit from here" hands the user message back to the composer). Observe `Change` (`.selection`,
`.panels`, `.filter`, `.composerRestore`).

### Regions (view controllers)
`WorkspaceViewController` lays out sidebar | chat column | right panel (resizable rails, widths
in an injectable `UserDefaults`). `ChatViewController` stacks header (52 pt), timeline, the
floating composer (centered, ≤ 736 pt, 20 pt above the terminal drawer; vertically centered for
drafts), the terminal drawer, and the Thread details card (top-right, 280 pt).

Region controllers keep `init(engine:state:)`. Contracts the container relies on:
`TimelineViewController.bottomInset` (space the composer covers), `ComposerViewController.onHeightChange`
and `focusEditor()`, `ChatViewController.terminalDrawerHeight`. Region controllers that take
keyboard focus adopt `FocusRegionController`.

### Commands (`Commands/AppCommand.swift`)
Every user action is an `AppCommand` registered once at launch from its module's
`…Commands.all` (`ShellCommands`, `SidebarCommands`, `TimelineCommands`, `ComposerCommands`,
`PanelCommands`). Commands are the single source for key bindings, the palette, menus and
buttons, and the snapshot harness runs them with `--perform <id>`. `CommandContext` carries
`engine`, `state`, `workspace`, `window`, `focus`, `isTextInput`, and `thread` (selected).

### Settings (`Shell/AppEnvironment.swift`, `SettingsResolution.swift`, `SettingsFile.swift`)
`~/.config/soprano-agents/settings.json` (JSONC, `SOPRANO_AGENTS_CONFIG` overrides), live
reloaded; bad values become warnings. Keys: `theme`, `agents.{defaultProvider, defaultModel,
defaultRuntimeMode}`, `providers.{codexPath, claudePath}`, `textGeneration.{provider, model,
titles}`, `worktrees.{directory, branchPrefix}`, `chat.{followUp, width}`,
`notifications.{enabled, sound}`, `editor.app`, `keybindings.{prefixKey, prefixTimeoutMs,
bindings}`. `AppSettings.engineSettings` feeds `AgentEngine.settings`. Window geometry, panel
widths and per-thread UI state stay in `UserDefaults`.

## Keyboard model

The router is an `NSEvent` local monitor (Soprano's model): ⌃A prefix mode, scopes by
`FocusRegion` (`sidebar`, `timeline`, `composer`, `terminal`, `rightPanel`, `settings`), chords
without ⌘/⌃ never fire in text input, ⌥ chords pass through (German layouts), a region-scoped
binding beats a global one. T3 Code's ⌥ shortcuts move to ⌃⌘.

### Default bindings

| Command id | Title | Scope | Keys | Owner |
|---|---|---|---|---|
| `palette.open` | Command Palette | global | `cmd+k` | Shell |
| `settings.open` | Settings | global | `cmd+,` | Shell |
| `settings.openFile` | Open settings.json | global | — | Shell |
| `view.toggleSidebar` | Toggle Sidebar | global | `cmd+b` | Shell |
| `view.toggleThreadDetails` | Toggle Thread Details | not terminal | `cmd+shift+b` | Shell |
| `view.toggleTerminal` | Toggle Terminal Drawer | global | `cmd+j` | Shell |
| `view.toggleRightPanel` | Toggle Right Panel | global | `cmd+ctrl+b` | Shell |
| `chat.new` | New Thread | not terminal | `cmd+n`, `cmd+shift+o` | Sidebar |
| `chat.newLocal` | New Thread in Current Project | not terminal | `cmd+shift+n` | Sidebar |
| `chat.newWithoutProject` | New Thread Without a Project | not terminal | `cmd+ctrl+n` | Sidebar |
| `project.add` | Add Project… | global | — | Sidebar |
| `thread.previous` / `thread.next` | Previous / Next Thread | global | `cmd+shift+[` / `cmd+shift+]` | Sidebar |
| `thread.jump.1`…`9` | Go to Thread N | global | `cmd+1`…`cmd+9` | Sidebar |
| `thread.settle` | Settle Thread | not terminal | `cmd+shift+s` | Sidebar |
| `thread.pin` | Pin Thread | not terminal | `cmd+shift+p` | Sidebar |
| `thread.rename` | Rename Thread | sidebar | `f2` | Sidebar |
| `thread.archive` / `thread.delete` | Archive / Delete Thread | — | — | Sidebar |
| `thread.copyReference` | Copy Thread Reference | not terminal | `cmd+shift+c` | Sidebar |
| `sidebar.search` | Search Threads | global | — | Sidebar |
| `chat.find` | Find in Thread | not terminal | `cmd+f` | Timeline |
| `timeline.jumpToLatest` | Jump to Latest | timeline | `cmd+down` | Timeline |
| `composer.focus` | Focus Composer | global | `cmd+l` | Composer |
| `modelPicker.toggle` | Model Picker | not terminal | `cmd+shift+m` | Composer |
| `composer.effort` | Reasoning Effort | not terminal | `cmd+shift+e` | Composer |
| `composer.mode` | Permissions | not terminal | `cmd+shift+a` | Composer |
| `composer.workspace` | Workspace | not terminal | `cmd+shift+x` | Composer |
| `composer.branch` | Branch | not terminal | `cmd+shift+g` | Composer |
| `composer.togglePlan` | Toggle Plan Mode | composer | `shift+tab` | Composer |
| `composer.sendAlternate` | Steer or Queue (opposite) | composer | `cmd+enter` | Composer |
| `thread.stop` | Interrupt | global | — | Composer |
| `diff.toggle` | Toggle Diff | not terminal | `cmd+d` | Panels |
| `terminal.new` | New Terminal | terminal | `cmd+n` | Panels |
| `terminal.close` | Close Terminal | terminal | `cmd+w` | Panels |
| `editor.openFavorite` | Open in Editor | global | `cmd+o` | Panels |
| `git.commit` / `git.push` / `git.createPR` | Commit / Push / Create PR | — | — | Panels |

"not terminal" = scopes `[sidebar, timeline, composer, rightPanel]` (plus nil focus handled by the
router as global) — T3 Code's `!terminalFocus`.

## Layout and visual design

T3 Code's look, from its CSS (see `docs/t3code-spec.md` §2–3):

```
┌ sidebar 256 (208…) ┬ chat column (≥ 640) ──────────────────────────────┬ right panel 540 (360…70%) ┐
│ [traffic] T3-style │ header 52: favicon project / Title ⌄   [▤][▭][◫]   │ tabs + diff surface         │
│ Search  [⫶][📁][✎] │   lane ≤ 736 centered                ┌ details ┐   │                             │
│ Pinned / Active    │   user bubble right (≤ 80%, r16)    │ card 280 │   │                             │
│ cards (78)         │   Worked for 3m 12s ›               └──────────┘   │                             │
│ …                  │   assistant markdown 14/1.625                      │                             │
│ Working 1 ›        │   N changed files card                             │                             │
│ Settled 43 ›       │   ┌ composer r16, glass ┐                          │                             │
│ [⚙]                │ terminal drawer 280 (180…75%)                      │                             │
└────────────────────┴────────────────────────────────────────────────────┴─────────────────────────────┘
```

- Colors only from `PaletteCenter.shared.palette` (T3 Code tokens; default theme `t3` follows
  macOS light/dark; Soprano themes map onto the same tokens). Views subclass `PaletteView` and
  re-color in `applyPalette(_:)`.
- Fonts from `Typography`: system font (14 body, 13 detail rows, 12 meta/pills, 11 kbd), SF Mono
  13 for code, diffs and command output, 12 in the terminal. Icons are SF Symbols (`Icon` maps
  T3 Code's lucide names), 16 pt in 28 pt ghost buttons.
- Radii from `Radius`: composer, bubbles, dialogs, plan cards, details card 16; buttons, menus,
  popovers, code blocks, changed-files card 8; sidebar cards 6.
- Status pills (sidebar): Working (info, `circle.dashed`, live duration), Approval (warning),
  Input (indigo), Failed (error), Done (success), else relative time ("now", "5m", "3h", "2d").
- Motion: opacity/scale fades ≤ 200 ms, none under Reduce Motion; streaming text appears without
  animation.
- Floating surfaces that must appear in snapshots (palette, model picker, menus of the composer,
  branch picker, thread details popovers) are child windows of the main window
  (`window.addChildWindow(_:ordered:)`), not `NSPopover`. Context menus are native `NSMenu`.

## Verification harness

`SopranoAgents snapshot --out <png> [--fixture demo|running|approval|input|plan|failed|draft|empty]
[--size 1440x900] [--appearance light|dark] [--theme <id>] [--hide-sidebar] [--details]
[--terminal] [--right-panel] [--diff thread|turn:<n>|uncommitted] [--perform <command id>]…
[--settings general|providers|text-generation|worktrees|notifications|keybindings|archive|about]
[--dialog confirm|choose|prompt|alert] [--type "<text>"] [--keys "<chord> …"] [--hover <label>]
[--wait <seconds>]` builds the real window offscreen on a `DemoFixtures` scenario and writes a PNG
of it and its child windows. `--perform` runs any registered command (open the palette, the model
picker, …); `--settings` opens the settings screen on a page; `--dialog` presents a sample
`Dialogs` dialog; `--type` inserts text into the first responder (of the topmost overlay when one
shows); `--keys` replays chords through the router (or into the topmost overlay); `--hover` sets
the hover state of the `InteractiveView` with that accessibility label or tooltip. Agents verify
UI with it and `read` the PNG; they do not launch the GUI.

Modal surfaces (command palette, settings screen, `Dialogs`) are `OverlayWindow`s: borderless
child windows covering the main window with T3 Code's dimmed backdrop and one card. Their keys
go to the overlay's `keyHandler` before menus and fields; while the settings screen records a
shortcut it routes every key through `KeyboardRouter.capture`.

## Tests

swift-testing (`import Testing`, `@Test`, `#expect`), one `struct …Tests` per file, sentence-style
names. Test files `import AppKit` (never `Foundation`) plus `@testable import SopranoAgents` /
`SopranoAgentsCore`. Provider parsing is tested against the recorded traces in
`Tests/SopranoAgentsTests/Fixtures/`; engine logic against a fake `ProviderDriver` and
`FixtureGitService`-style fakes; git against real temp repositories with an isolated config
(`HOME=<tmp>`, `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=<tmp>/gitconfig`). Tests never start a
real agent CLI and never touch the user's repositories, settings or app data.
