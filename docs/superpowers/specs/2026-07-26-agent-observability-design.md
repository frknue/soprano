# Agent Observability Design

**Date:** 2026-07-26

## Goal

Give Soprano a timestamped, queryable record of what every agent in the room is
doing, and a delivery channel narrow enough to update it continuously. Then
spend that record on the question the app exists to answer — *which agent needs
me right now?* — as a key you can press rather than a number you can read.

## Problem

Every mutation in Soprano flows one direction (human → app → pane) and every
readout is a picture. Running four agents is not a rendering problem or a
navigation problem; it is attention scheduling under partial information, and
the app gives the scheduler almost nothing to schedule with.

1. **Attention has no order, age, or reason.** `AgentInstance.needsAttention` is
   a `Bool`. `AgentManager.attentionCount` (`:1173`) is rendered as inert text
   in `StatusBarView.swift:164`, and no keybinding in `KeybindingManager`
   navigates to it. Finding the agent that is waiting is a manual hunt across
   logical windows and depth layers.
2. **`WORKING` has no clock.** `startedAt` is refreshed only on `.starting`
   (`AgentManager.swift:643`). A pane ten seconds into a turn and a pane wedged
   for forty minutes render identically, so the status word cannot be trusted
   as evidence of progress.
3. **Agent-reported detail is discarded.** `AgentEventCommand` carries seven
   string keys. Codex appends its turn JSON as the final argument and
   `AgentNotificationManager.swift:99-103` skips it with the comment *"It is
   intentionally ignored here."* Every Codex banner therefore reads `Response
   ready`, a string hardcoded at `TerminalSurfaceView.swift:92`, instead of what
   the agent actually said.
4. **There is no channel that can carry per-turn detail.** `notifyChange()`
   (`AgentManager.swift:1254`) is payload-free and fires on any mutation.
   `SidebarView.refresh()` (`:350`) re-arms the git monitor at `:361` and
   `rebuildRows` reconstructs every arranged subview. Any per-second or
   per-turn state added today routes through that teardown.

(4) is the reason this is one design and not four changes. The record and the
channel must land together; nothing else in the roadmap is shippable until they
exist.

## Scope

- A timestamped, extensible `AgentInstance` record.
- A targeted observer channel (`agentObservers`) that delivers a single agent's
  delta to subscribers that update text in place.
- Parsing Codex's turn payload into that record.
- An attention inbox: cycle to the next waiting agent, and a searchable list.
- An elapsed clock in the pane header and sidebar.
- Two adjacent defects that block later work: browser automation stealing focus
  and reshaping the layout, and an unknown `PaneType` destroying the entire
  saved workspace.

## Architecture

### The record

`AgentInstance` is a plain, non-`Codable` `final class`
(`Models/AgentInstance.swift:4-22`) and `snapshotWorkspace` persists only
`profileId` from it, so the persistence format is untouched by new fields — no
migration, no format bump, no `Codable` conformance:

```swift
var statusSince: Date            // stamped on every accepted status change
var lastEventAt: Date
var sessionId: String?           // resume handle; minted or harvested at launch
var task: String?                // first line of the prompt that started the turn
var lastMessage: String?         // what the agent actually said
var recentEvents: [AgentEvent]   // fixed ring, cap 20
```

`statusSince` is stamped inside the existing early return at
`AgentManager.swift:637`, which already has exactly the right semantics: it
fires once per *accepted* transition, not once per event. `lastEventAt` updates
on every event including repeats.

### The channel

Modeled verbatim on the terminal lifecycle pair already in the same file
(`terminalLifecycleObservers` at `:53`, `notifyTerminalLifecycle` at `:1248`):

```swift
private var agentObservers: [String: (TerminalTarget, AgentDelta) -> Void] = [:]
private func notifyAgentChange(_ target: TerminalTarget, _ delta: AgentDelta)
```

`AgentDelta` names what changed (`status`, `elapsed`, `message`, `meter`) so a
subscriber can ignore deltas it does not render. Subscribers — `PaneHeaderView`,
`SidebarPaneRowView`, `StatusBarView` — resolve their own view for the target
and assign `.stringValue` in place.

**Invariant: a subscriber to `agentObservers` must never call `refresh()`,
`rebuildRows`, or `setWatchedPaths`.** That is the whole point of the channel.
`notifyChange()` remains for layout and membership changes only.

### Codex turn payload

`AgentEventCommand.notificationEnvelope` keeps the trailing non-flag argument
instead of skipping it, and passes it as `payload` in the userInfo dict.
`AgentNotificationManager` decodes it with one `JSONSerialization` call:
`last-assistant-message` becomes the notification body and `lastMessage`,
`input-messages` seeds `task`, and `thread-id` becomes `sessionId`. A payload
that is absent, malformed, or of an unrecognized type falls back to today's
behavior — parsing failure must never cost a notification.

### Attention inbox

Two surfaces, one queue:

- **`⌃A A` cycles.** Walk `orderedWindows × orderedPanes(in:)` from the position
  after `activePaneId`, wrapping, to the next pane whose active agent has
  `needsAttention`. Cycling, not age-sorting: an agent blocked on a decision you
  cannot make yet would pin itself to the head of an age-sorted queue forever
  and starve the rest. Cycling is stateless and cannot wedge.
- **`⇧⌘A` lists**, through `CommandPalettePanel.show(commands:)` unchanged, one
  row per waiting agent: `NEEDS INPUT 6m · repo · branch`. This is where age
  appears, as display-only triage.

Both route through `focusPane` (`:387`), never `focusTab`. Only tabs of type
`.agent` enter the queue: a browser tab has no agent and could never clear its
own flag, so it would sit at the head permanently.

Both binding ids must be registered in `DefaultKeybindings` — after the
`settings.json` layer, the config merge only sees ids that exist in the defaults.

### Elapsed clock

`WORKING 4m` in `PaneHeaderView`, appended to `badgeParts` in
`SidebarPaneRowView`. One 5-second `DispatchSourceTimer` on the window
controller, not one per pane and not 1 Hz: displayed granularity is seconds
below a minute and whole minutes above, so 5 s costs a fifth as much for the
same rendering. Each tick precomputes the set of panes in a timed status and
emits `.elapsed` deltas only for those.

### Adjacent defects

**Browser automation steals focus and reshapes the layout.** `BrowserCommand`
writes `callerPaneId`/`callerTabId` into userInfo
(`BrowserAutomationCommand.swift:145-149`) and
`BrowserAutomationNotificationPayload.init` (`:206-221`) drops both. The
controller then calls `focusTab` unconditionally before dispatching *every*
command, so read-only verbs (`url`, `title`, `get`, `snapshot`) steal the
keyboard. Combined with `insertPane` splitting at `activePaneId`
(`AgentManager.swift:1179`), one background agent running `browser open`
reshapes the layout around whatever the user is doing. Decode the caller, give
`insertPane` an explicit anchor and a `moveFocus` flag, and make focusing
opt-in behind `--focus`. This is a prerequisite for every later verb an agent
can call while unattended.

**One bad tab destroys the saved room.** `PaneType.init(from:)`
(`Models/PaneState.swift:20-25`) throws on an unrecognized raw value and
`WorkspaceSession.loadLast` (`:75-82`) decodes with `try?`, returning `nil` on
any error. Decoding an unknown pane type must degrade to `.terminal` with a
warning. Because `loadLast` swallows decode errors, the autosave also keeps the
previous snapshot under a second key, so a single truncated write cannot
discard the workspace.

## Non-goals

- **Answering approvals from a notification or a decision bar.** `~/.claude/settings.json`
  sets `defaultMode: "bypassPermissions"` — the interrupt is off by choice.
  Keystroke injection in particular must never ship: `sendText` writes raw bytes
  with no knowledge of the foreground process.
- **A task queue idle agents pull from.** "Done" is not an event any of the three
  agents emits; Claude Code's `Stop` fires at the end of every turn, including
  one that ended in a question. Auto-dispatch on a status transition means the
  previous turn is never reviewed.
- **A worktree manager.** Claude Code owns lane lifecycle end to end
  (`-w/--worktree`, and `--tmux` requires it) and reports `worktree.{name,path,branch}`.
  A second owner produces orphans. Lanes are already reachable with zero Swift
  through a `settings.json` agent entry carrying `"args": ["--worktree"]`.
- **A notification coalescing engine.** Agent turns are minutes long. The
  observed noise is re-notification of a pane already flagged, which one guard
  removes.
- **Session timeline / scrubback.** `ghostty_surface_read_text` has zero call
  sites; its scrollback coordinate handling is new C integration, not a reuse.

## Later waves

Recorded as direction, not scope. Each depends on the record and the channel:

- **Wave 2 — legible and remembered.** A context/cost/rate-limit meter fed by a
  `statusLine` shim (aggregating across the room what the TUI shows one pane at
  a time); resume via minted `--session-id` and `--resume`; a `GitWorkMonitor`
  keyed by repo root showing `+142 −18` for panes that are actually running.
- **Wave 3 — addressable.** `SopranoRequest` lifted out of
  `BrowserAutomationCommand`, then `soprano pane list --json` and `pane focus`,
  then `pane send` (via the selection pasteboard and `paste_from_selection`,
  never `ghostty_surface_text`, whose first newline submits a truncated prompt),
  then layouts as files, then MCP last and off by default.

## Verification debt

Confirm before building anything that depends on it:

1. Whether `--settings` **merges or replaces** an object key like `statusLine`.
   The same test reveals whether the four Soprano hooks duplicated in
   `~/.claude/settings.json` are double-firing behind the 1-second
   `EventFingerprint` dedupe at `AgentNotificationManager.swift:329`.
2. `statusLine` invocation cadence — measured, not taken from a changelog.
3. Whether Codex hooks install per launch. They live in a trust-hashed file, not
   a `-c` flag. If they cannot, Codex stays on notify plus OSC.
4. OpenCode: nothing verified. Every meter shows `—` until it is.
5. That the `codex` shell wrapper on `PATH` does not reshape argv in a way that
   moves the trailing JSON payload.

## Integration principle

Every per-launch integration Soprano installs is currently override-shaped:
`-c notify=[...]` replaces the user's Codex notifier, the injected hooks sit
alongside hand-duplicated ones, and a `statusLine` key would replace the user's
status line. Each injection point should instead **chain**: post to Soprano,
then exec whatever the user's own configuration specified. It is the difference
between hosting an agent and hijacking it.
