# Agent Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` to execute this plan task by task.
> Every implementation task uses `superpowers:test-driven-development`.

**Goal:** Implement
`docs/superpowers/specs/2026-07-26-agent-observability-design.md` — a
timestamped agent record, a targeted observer channel, the attention inbox, the
elapsed clock, Codex turn-payload parsing, and the two adjacent defects that
block later agent-driven work.

**Architecture:** `AgentManager` stays the state owner. Add fields to
`AgentInstance` (which is non-`Codable` and therefore free of the persistence
format), and add an `agentObservers` channel alongside the existing
`terminalLifecycleObservers`. Views subscribe and update text in place. No new
IPC transport, no new pane type, no change to `SplitNode`.

**Tech stack:** Swift 6, AppKit, SwiftPM/swift-testing, libghostty C API.

## Global Constraints

- Build and test with Homebrew Swift:
  `PATH="/opt/homebrew/opt/swift/bin:$PATH"`.
- Do not run `swift run`, `run.sh`, or `dev.sh` without `--build-only`, and do
  not launch either application bundle. Launching panes can trigger macOS
  permission prompts through the user's shell startup files.
- Tests use swift-testing (`import Testing`, `@Test`, `#expect`), one
  `struct …Tests` per file. Never `import Foundation` beside `import Testing`;
  `import AppKit` instead.
- **A subscriber to `agentObservers` must never call `refresh()`,
  `rebuildRows`, or `setWatchedPaths`.** Violating this reintroduces the
  full-sidebar teardown the channel exists to avoid.
- `notifyChange()` remains for layout and membership changes only.
- Any new keybinding id must exist in `DefaultKeybindings` or the
  `settings.json` merge cannot see it, and must be documented in
  `ConfigFile.template`.
- Failure to parse an agent-supplied payload must degrade to current behavior,
  never cost a notification or a status update.
- Preserve unrelated worktree changes; each task commits on its own.
- After all verification succeeds, run `./install.sh` as the final mutation.

---

### Task 1: Stop one bad tab from destroying the saved workspace

**Files:**

- Modify: `Sources/Soprano/Models/PaneState.swift`
- Modify: `Sources/Soprano/Models/WorkspaceSession.swift`
- Modify: `Sources/Soprano/App/AppDelegate.swift`
- Modify: `Tests/SopranoTests/SessionPersistenceTests.swift`

**Requirements:**

- Decode an unrecognized `PaneType` raw value as `.terminal` instead of
  throwing (`PaneState.swift:20-25`), so one unknown tab costs one tab rather
  than the whole session — `loadLast` decodes with `try?` and returns `nil` on
  any error.
- Keep the previous snapshot under a second `UserDefaults` key on each save, and
  fall back to it when the primary snapshot fails to decode.
- Debounce `saveLast` off the existing `AgentManager` observer at roughly two
  seconds, on layout changes only, so a force-quit does not lose the room.
  `saveLast` currently has one call site, `AppDelegate.swift`.

- [ ] Write tests: an unknown pane type restores the remaining panes; a
      corrupt primary snapshot restores from the fallback key; the debounce
      coalesces a burst of layout changes into one write.
- [ ] Run the focused tests and confirm they fail.
- [ ] Implement.
- [ ] Run the focused tests, then full `swift test`; confirm success.
- [ ] Run `swift build`; inspect the complete result.
- [ ] Add the `Fixed` changelog entries. Commit the task.

---

### Task 2: Stop browser automation from stealing focus and reshaping the layout

**Files:**

- Modify: `Sources/Soprano/Controllers/BrowserAutomationCommand.swift`
- Modify: `Sources/Soprano/Controllers/AgentManager.swift`
- Modify: `Tests/SopranoTests/BrowserIntegrationTests.swift`
- Modify: `README.md`

**Requirements:**

- Decode `callerPaneId` and `callerTabId` in
  `BrowserAutomationNotificationPayload.init` (`:206-221`); `BrowserCommand`
  already writes both at `:145-149` and they are currently dropped.
- Do not call `focusTab` before dispatching a command. Focus becomes opt-in
  behind a `--focus` flag, and remains implicit only for `browser open` issued
  from the focused pane.
- Give `insertPane` (`AgentManager.swift:1179`) an explicit anchor pane and a
  `moveFocus: Bool` instead of always splitting at `activePaneId`, so a
  background agent's `browser open` splits next to *its own* pane and leaves
  focus alone.
- Document `--focus` in the browser CLI help text and README.

- [ ] Write tests: a read-only verb from an unfocused pane leaves
      `activePaneId` unchanged; `open` from a background pane anchors its split
      to the caller; `--focus` still focuses.
- [ ] Run the focused tests and confirm they fail.
- [ ] Implement.
- [ ] Run the focused tests, then full `swift test`; confirm success.
- [ ] Run `swift build`; inspect the complete result.
- [ ] Add the `Fixed` changelog entry. Commit the task.

---

### Task 3: Timestamped agent record

**Files:**

- Modify: `Sources/Soprano/Models/AgentInstance.swift`
- Modify: `Sources/Soprano/Controllers/AgentManager.swift`
- Create: `Tests/SopranoTests/AgentRecordTests.swift`

**Requirements:**

- Add `statusSince`, `lastEventAt`, `sessionId`, `task`, `lastMessage`, and a
  `recentEvents` ring capped at 20 to `AgentInstance`.
- Stamp `statusSince` inside the accepted-transition branch of
  `updateAgentStatus` (`AgentManager.swift:637-649`) — once per accepted
  transition, not once per event. Update `lastEventAt` on every event.
- Preserve the existing early return: an unchanged status with unchanged
  attention must still be a no-op.
- Leave `startedAt` semantics alone; `statusSince` is the per-status clock and
  `startedAt` remains the launch clock.
- Confirm no persistence change is required: `AgentInstance` is non-`Codable`
  and `snapshotWorkspace` writes only `profileId` from it.

- [ ] Write tests: a status change stamps `statusSince`; a repeat event does
      not; an attention-only change stamps; the event ring caps at 20 and drops
      oldest; a workspace round trip is byte-identical to before.
- [ ] Run the focused tests and confirm they fail.
- [ ] Implement.
- [ ] Run the focused tests, then full `swift test`; confirm success.
- [ ] Run `swift build`; inspect the complete result.
- [ ] Commit the task. No changelog entry — nothing user-visible yet.

---

### Task 4: Targeted agent observer channel

**Files:**

- Modify: `Sources/Soprano/Controllers/AgentManager.swift`
- Modify: `Sources/Soprano/Views/PaneHeaderView.swift`
- Modify: `Sources/Soprano/Views/SidebarView.swift`
- Modify: `Sources/Soprano/Views/StatusBarView.swift`
- Create: `Tests/SopranoTests/AgentObserverChannelTests.swift`

**Requirements:**

- Add `agentObservers` and `notifyAgentChange(_:_:)` modeled on
  `terminalLifecycleObservers` (`:53`) and `notifyTerminalLifecycle` (`:1248`),
  including the same add/remove-by-id lifecycle.
- Introduce `AgentDelta` naming what changed (`status`, `elapsed`, `message`),
  so a subscriber can ignore deltas it does not render.
- Subscribe `PaneHeaderView`, `SidebarPaneRowView`, and `StatusBarView`;
  each resolves its own view for the target and assigns `.stringValue` in place.
- `updateAgentStatus` emits a delta **in addition to** `notifyChange()` for now;
  removing the `notifyChange()` call from that path is out of scope.
- Verify no subscriber calls `refresh()`, `rebuildRows`, or `setWatchedPaths`.

- [ ] Write tests: a delta reaches only the registered observer for the target;
      a removed observer stops receiving; a status change on pane A does not
      deliver a delta addressed to pane B; an observer that throws does not
      prevent delivery to the others.
- [ ] Run the focused tests and confirm they fail.
- [ ] Implement.
- [ ] Run the focused tests, then full `swift test`; confirm success.
- [ ] Run `swift build`; inspect the complete result.
- [ ] Commit the task. No changelog entry.

---

### Task 5: Parse the Codex turn payload

**Files:**

- Modify: `Sources/Soprano/Controllers/AgentNotificationManager.swift`
- Modify: `Sources/Soprano/Terminal/TerminalSurfaceView.swift`
- Create: `Tests/SopranoTests/CodexTurnPayloadTests.swift`
- Modify: `Support/AgentHooks/codex-hooks.json` if the wrapper contract changes

**Requirements:**

- Keep the trailing non-flag argument in
  `AgentEventCommand.notificationEnvelope` instead of skipping it
  (`AgentNotificationManager.swift:99-103`) and forward it as `payload`.
- Decode with one `JSONSerialization` call: `last-assistant-message` becomes the
  notification body and `lastMessage`; `input-messages` seeds `task`;
  `thread-id` becomes `sessionId`.
- The hardcoded `"Response ready"` body at `TerminalSurfaceView.swift:92`
  becomes the fallback, not the value.
- Absent, malformed, oversized, or unexpectedly-typed payloads fall back to
  current behavior silently. Truncate `lastMessage` before it reaches a
  notification body.
- Confirm first that the `codex` shell wrapper on `PATH` does not reshape argv
  in a way that moves the payload off the last position.

- [ ] Write tests: a well-formed payload produces the agent's message as the
      body; a malformed payload falls back to `Response ready`; a missing
      payload behaves exactly as today; an oversized message is truncated;
      `thread-id` lands in `sessionId`.
- [ ] Run the focused tests and confirm they fail.
- [ ] Implement.
- [ ] Run the focused tests, then full `swift test`; confirm success.
- [ ] Run `swift build`; inspect the complete result.
- [ ] Add the `Changed` changelog entry. Commit the task.

---

### Task 6: Attention inbox

**Files:**

- Modify: `Sources/Soprano/Controllers/AgentManager.swift`
- Modify: `Sources/Soprano/Controllers/KeybindingManager.swift`
- Modify: `Sources/Soprano/Config/DefaultKeybindings.swift`
- Modify: `Sources/Soprano/Config/ConfigFile.swift`
- Modify: `Sources/Soprano/App/MainWindowController.swift`
- Modify: `Sources/Soprano/Controllers/AgentNotificationManager.swift`
- Create: `Tests/SopranoTests/AttentionInboxTests.swift`
- Modify: `README.md`

**Requirements:**

- Add a pure query returning the next pane needing attention after a given
  pane, walking `orderedWindows × orderedPanes(in:)` and wrapping — the shape of
  `activateWindow(offset:)`. **Cycle, do not age-sort.**
- Only tabs of type `.agent` enter the queue; a browser tab cannot clear its own
  flag and would pin the head of the queue permanently.
- Bind `⌃A A` to the cycle and `⇧⌘A` to a list rendered through
  `CommandPalettePanel.show(commands:)` unchanged, each row reading
  `NEEDS INPUT 6m · repo · branch`. Age appears only in the list.
- Both route through `focusPane` (`:387`), never `focusTab`.
- Register both binding ids in `DefaultKeybindings` and document them in
  `ConfigFile.template`; the config merge only sees ids present in the defaults.
- **Fix in this task:** `focusTab` → `switchTab` reveals via `activateDepth`
  (`:885`), which only sets `activeDepthLayerIndex`, so clicking a notification
  banner cannot reveal a pane nested in a collapsed depth layer. `focusPane`
  reveals correctly; commit `4e9d8d4` fixed only the sidebar path.
- **Fold in:** in `handle(_:)` (`AgentNotificationManager.swift:311`), skip
  `deliverNotification` when the target agent is already `needsAttention`.

- [ ] Write tests: cycling reaches every waiting pane and wraps; a pane blocked
      indefinitely does not starve the others; browser tabs never enter the
      queue; an empty queue is a no-op; a notification for a pane nested in a
      collapsed depth layer reveals it; a second event for an already-flagged
      pane delivers no banner.
- [ ] Run the focused tests and confirm they fail.
- [ ] Implement.
- [ ] Run the focused tests, then full `swift test`; confirm success.
- [ ] Run `swift build`; inspect the complete result.
- [ ] Add the `Added` and `Fixed` changelog entries and the README shortcut rows.
      Commit the task.

---

### Task 7: Elapsed clock

**Files:**

- Modify: `Sources/Soprano/App/MainWindowController.swift`
- Modify: `Sources/Soprano/Views/PaneHeaderView.swift`
- Modify: `Sources/Soprano/Views/SidebarView.swift`
- Create: `Tests/SopranoTests/ElapsedStatusTests.swift`

**Requirements:**

- One 5-second `DispatchSourceTimer` on the window controller — not one per
  pane, not 1 Hz. Displayed granularity is seconds below a minute and whole
  minutes above.
- Each tick precomputes the set of panes in a timed status (`.running`,
  `.waiting`) and emits `.elapsed` deltas only for those. No timer work when
  the set is empty.
- Render `WORKING 4m` in `PaneHeaderView` and append to `badgeParts` in
  `SidebarPaneRowView`, both through the Task 4 channel.
- Formatting is a pure function of `(statusSince, now)` and is tested directly.

- [ ] Write tests: the formatter's boundaries at 59 s, 60 s, and 60 min; the
      tick emits deltas only for panes in a timed status; an idle room emits
      nothing; the elapsed value derives from `statusSince`, not `startedAt`.
- [ ] Run the focused tests and confirm they fail.
- [ ] Implement.
- [ ] Run the focused tests, then full `swift test`; confirm success.
- [ ] Run `swift build`; inspect the complete result.
- [ ] Add the `Added` changelog entry. Commit the task.

---

## Final verification

- [ ] `PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build` — clean.
- [ ] `PATH="/opt/homebrew/opt/swift/bin:$PATH" swift test` — all suites pass.
- [ ] `CHANGELOG.md` `## [Unreleased]` carries one line per user-visible change,
      in `Added` / `Changed` / `Fixed` order.
- [ ] `README.md` documents `⌃A A`, `⇧⌘A`, and `browser --focus`.
- [ ] No `agentObservers` subscriber calls `refresh()`, `rebuildRows`, or
      `setWatchedPaths`.
- [ ] `./install.sh`.

## Deferred

Wave 2 (context/cost meter, session resume, `GitWorkMonitor`) and Wave 3
(`SopranoRequest`, `soprano pane list/focus/send`, layouts as files, MCP) are
recorded in the design document and are not in this plan. Both depend on Tasks 3
and 4 existing first. Resolve the design document's verification debt before
starting Wave 2 — in particular, whether `--settings` merges or replaces an
object key, which also answers whether the duplicated hooks in
`~/.claude/settings.json` are double-firing today.
