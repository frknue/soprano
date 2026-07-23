# Soprano Audit Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` to execute this plan task by task.
> Every implementation task uses `superpowers:test-driven-development`.

**Goal:** Resolve all defects in
`docs/superpowers/specs/2026-07-23-soprano-audit-fixes-design.md`.

**Architecture:** Keep `AgentManager` as the state owner, `SplitTreeView` as
the terminal-view owner, and `TerminalSurfaceView` as the libghostty surface
host. Add target-specific lifecycle events, a cold-restore generation,
path-addressed split synchronization, process/tab-scoped external events, and
small pure helpers that make the behavior testable without launching the app.

**Tech stack:** Swift 6, AppKit, SwiftPM/XCTest, libghostty C API, POSIX shell.

## Global Constraints

- Build and test with Homebrew Swift:
  `PATH="/opt/homebrew/opt/swift/bin:$PATH"`.
- Do not run `swift run`, `run.sh`, `dev.sh` without `--build-only`, or launch
  either Soprano application bundle.
- Do not modify the vendored Ghostty submodule.
- Treat `(paneId, tabId)` as the required identity for terminal-specific
  lifecycle, agent, and navigation events.
- A named-session restore creates fresh terminal surfaces; ordinary layout,
  focus, and tab changes preserve existing terminal surfaces.
- Clipboard state supplied by libghostty must be completed exactly once before
  its surface is freed.
- Model and rendered split percentages share 10...90 bounds.
- Preserve existing user settings and unrelated worktree changes.
- After all verification succeeds, run `./install.sh` as the final mutation.

---

### Task 1: Add the regression-test target and fix split/pane model invariants

**Files:**

- Modify: `Package.swift`
- Modify: `Sources/Soprano/Models/SplitNode.swift`
- Modify: `Sources/Soprano/Controllers/AgentManager.swift`
- Create: `Tests/SopranoTests/SplitNodeTests.swift`
- Create: `Tests/SopranoTests/AgentManagerPaneTests.swift`

**Requirements:**

- Add `SopranoTests` depending on the `Soprano` executable target.
- Add a pure split-percentage setter addressed by `[SplitBranchSide]` and
  clamp all split percentages to 10...90.
- Add a pure directional wrap query. Left/up wrap to the opposite
  right/bottom boundary; right/down wrap to the opposite left/top boundary.
- Make `navigateToPane` use direct adjacency and then the wrap query.
- Make `spawnAgent` and `spawnTerminal` return optional IDs and return `nil`
  without allocating/inserting at `maxPanes`.
- Apply the same capacity guard to `splitPane`.
- Make insertion success explicit rather than silently returning a generated
  but unused ID.
- Preserve `sourceTab.cwd` in both terminal and agent splits. Do not clone a
  manually attached agent from a terminal tab.

- [ ] Write tests for nested-tree wrap behavior in all four directions,
      singleton/unknown-source behavior, path-addressed percentage updates,
      clamping, pane-cap failures, truthful optional spawn results, and split
      working-directory preservation.
- [ ] Run the focused tests and confirm they fail for the audited behavior.
- [ ] Implement the minimum model/controller changes.
- [ ] Run the focused tests and full `swift test`; confirm success.
- [ ] Run `swift build`; inspect the complete result.
- [ ] Commit the task.

---

### Task 2: Invalidate restored terminals and synchronize split resizing

**Files:**

- Modify: `Sources/Soprano/Controllers/AgentManager.swift`
- Modify: `Sources/Soprano/Views/SplitTreeView.swift`
- Modify: `Tests/SopranoTests/SplitNodeTests.swift`
- Create: `Tests/SopranoTests/WorkspaceRestoreTests.swift`
- Create: `Tests/SopranoTests/ThemedSplitViewTests.swift`

**Requirements:**

- Add `workspaceRestoreGeneration`, incremented only after a successful
  `restoreWorkspace`.
- Have `SplitTreeView` detect generation changes before normal cache pruning
  and synchronizing. Destroy and remove every cached terminal content view so
  restored tab IDs cannot reuse old PTYs/configuration.
- Keep ordinary pane containers and terminal caches alive for non-restore
  updates.
- Build split views with their exact `SplitNode` branch path.
- Add an `AgentManager` absolute split-percentage update method.
- Keyboard resize must update visible divider geometry without rebuilding
  terminal surfaces.
- User divider movement must update the matching model branch and therefore
  persist in workspace snapshots.
- Suppress model/view feedback while applying a model percentage.

- [ ] Write tests for restore-generation semantics, absolute percentage
      updates, and divider percentage calculation/clamping.
- [ ] Run the focused tests and confirm the new assertions fail.
- [ ] Implement generation-based cache invalidation and two-way synchronization.
- [ ] Run focused tests, full `swift test`, and `swift build`.
- [ ] Commit the task.

---

### Task 3: Wire target-specific terminal stop, restart, and close

**Files:**

- Modify: `Sources/Soprano/Controllers/AgentManager.swift`
- Modify: `Sources/Soprano/Views/SplitTreeView.swift`
- Modify: `Sources/Soprano/Terminal/TerminalSurfaceView.swift`
- Modify: `Sources/Soprano/Terminal/GhosttyAppManager.swift`
- Create: `Tests/SopranoTests/TerminalLifecycleTests.swift`

**Requirements:**

- Define a hashable terminal target containing pane and tab IDs and a
  stop/restart lifecycle action delivered by `AgentManager`.
- Keep active-tab convenience methods for existing UI callers, but resolve the
  target once and emit the exact IDs.
- Stop destroys the target surface and leaves the agent tab stopped.
- Restart resets agent state, then recreates only the target surface.
- A surface that has been explicitly stopped must not start merely because its
  tab becomes visible.
- Ghostty close notifications include `tabId`.
- A close for an agent marks only that agent stopped; a close for a regular
  terminal removes only that tab. Never infer the pane's current active tab.
- Duplicate/late close events and repeated surface destruction are no-ops.

- [ ] Write tests with a lifecycle-action spy and multiple tabs proving that
      stop/restart/close affect only the supplied target, including a close
      from an inactive tab.
- [ ] Run the focused tests and confirm failure.
- [ ] Implement model events, view execution, exact close routing, and
      idempotent teardown.
- [ ] Run focused tests, full `swift test`, and `swift build`.
- [ ] Commit the task.

---

### Task 4: Scope external agent and pane-navigation events

**Files:**

- Modify: `Sources/Soprano/Controllers/AgentNotificationManager.swift`
- Modify: `Sources/Soprano/Controllers/PaneNavigationCommand.swift`
- Modify: `Sources/Soprano/Controllers/KeybindingManager.swift`
- Modify: `README.md`
- Create: `Tests/SopranoTests/ExternalEventRoutingTests.swift`
- Create: `Tests/SopranoTests/PaneNavigationClaimRegistryTests.swift`

**Requirements:**

- Name agent-event distributed notifications with the owning
  `SOPRANO_APP_PID`; subscribe only to the current process name.
- Treat a command with missing process/pane/tab identity as handled but do not
  publish a fallback notification.
- Include `tabId` in navigation and passthrough payloads.
- Key passthrough and bubble navigation apply only to the currently active
  `(paneId, tabId)`.
- Track passthrough sources with reference counts. Duplicate enables require
  matching disables; unmatched disables do nothing.
- Document process, pane, and tab scoping for nested navigation.

- [ ] Write parsing/name/registry tests, including two tabs in one pane and
      duplicate same-source claims.
- [ ] Run the focused tests and confirm failure.
- [ ] Implement scoped payloads, observer routing, and the registry.
- [ ] Run focused tests, full `swift test`, and `swift build`.
- [ ] Commit the task.

---

### Task 5: Commit settings edits and sign completed bundles

**Files:**

- Modify: `Sources/Soprano/Views/SettingsWindowController.swift`
- Modify: `scripts/package-app.sh`
- Create: `Tests/SopranoTests/SettingsEditingTests.swift`

**Requirements:**

- Configure only the keybinding prefix, timeout, and resize fields to send
  their existing action when editing ends.
- End editing before rebuilding controls on a settings-tab change and before
  dismissing settings.
- Do not make the project-directory Add field submit on focus loss.
- Sign the fully assembled staging bundle after all resources and Info.plist
  changes, using `${SOPRANO_CODESIGN_IDENTITY:--}`.
- Verify the staged bundle with `codesign --verify --deep --strict` before
  promotion. A signing/verification failure must leave the previous output
  bundle intact.

- [ ] Write an AppKit unit test that proves the three settings fields are
      configured for end-edit actions while the Add field behavior remains
      explicit.
- [ ] Run the focused test and confirm failure.
- [ ] Implement the field-commit changes and run the focused/full test suite.
- [ ] Add signing and run `bash -n scripts/package-app.sh dev.sh install.sh`.
- [ ] Run `./dev.sh --build-only`, strict `codesign` verification, and
      `plutil -lint` without launching the bundle.
- [ ] Commit the task.

---

### Task 6: Enforce clipboard confirmation policy with native AppKit UI

**Files:**

- Create: `Sources/Soprano/Terminal/ClipboardConfirmationCoordinator.swift`
- Modify: `Sources/Soprano/Terminal/GhosttyAppManager.swift`
- Modify: `Sources/Soprano/Terminal/TerminalSurfaceView.swift`
- Create: `Tests/SopranoTests/ClipboardConfirmationCoordinatorTests.swift`

**Requirements:**

- Copy callback C content synchronously into owned Swift values.
- Queue native confirmation sheets on the main actor and resolve each request
  once.
- Use the request-specific title/message for paste, OSC 52 read, and OSC 52
  write, with a read-only scrollable content preview.
- Read Allow completes original content with `confirmed == true`; every denial
  path completes empty content with `confirmed == true`.
- Confirmation-required writes update the pasteboard only on Allow.
- Immediate writes retain current supported content behavior.
- Use the named `com.mitchellh.ghostty.selection` pasteboard for selection
  operations.
- Surface teardown denies and completes pending reads before
  `ghostty_surface_free`.

- [ ] Write coordinator tests with an injected presenter for FIFO ordering,
      allow/deny, dismissal, cancellation by surface, and exactly-once
      completion.
- [ ] Run focused tests and confirm failure.
- [ ] Implement the coordinator, AppKit presenter, and Ghostty callbacks.
- [ ] Run focused tests, full `swift test`, and `swift build`.
- [ ] Commit the task.

---

### Task 7: Complete Ghostty input, IME, mouse, and Edit-menu integration

**Files:**

- Modify: `Sources/Soprano/Terminal/TerminalSurfaceView.swift`
- Create: `Sources/Soprano/Terminal/TerminalInputMetadata.swift`
- Create: `Tests/SopranoTests/TerminalInputMetadataTests.swift`

**Requirements:**

- Encode scroll precision in bit 0 and Ghostty momentum in bits 1...3; do not
  mix keyboard modifiers into scroll metadata.
- Match Ghostty's precise-scroll delta scaling.
- Send mouse position before button press/release and cover initial enter,
  exit, and dragged positions.
- Adopt `NSTextInputClient`: drive `interpretKeyEvents`, committed text,
  marked-text preedit, selected/marked ranges, selection reading, and the IME
  candidate rectangle using libghostty APIs.
- Send correct modifier press/release events, including right-side modifiers,
  and avoid modifier dispatch while marked text is active.
- Install a local key-up monitor only while needed to forward
  Command-modified releases for the focused surface; remove it on teardown.
- Map `copy:`, `paste:`, and `selectAll:` to `copy_to_clipboard`,
  `paste_from_clipboard`, and `select_all`.

- [ ] Write pure metadata tests for discrete/precise scroll momentum and
      left/right modifier press/release transitions.
- [ ] Run focused tests and confirm failure.
- [ ] Port the minimum corresponding behavior from the vendored Ghostty AppKit
      implementation.
- [ ] Run focused tests, full `swift test`, and debug/release builds.
- [ ] Commit the task.

---

### Task 8: Whole-branch review, verification, and installation

**Files:**

- Review every change since the branch merge base.
- Modify only files required to resolve verified review findings.

- [ ] Run a task-independent code review against this design and plan.
- [ ] Resolve every Critical or Important finding and rerun covering tests.
- [ ] Run fresh full verification:

```bash
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift test
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build -c release
bash -n scripts/package-app.sh dev.sh install.sh
./dev.sh --build-only
codesign --verify --deep --strict --verbose=2 ".build/debug/Soprano Dev.app"
plutil -lint ".build/debug/Soprano Dev.app/Contents/Info.plist"
git diff --check
git status --short
```

- [ ] Confirm each of the thirteen audit findings has either a focused
      regression test or explicit build/package verification.
- [ ] Run `./install.sh` as the final mutation.
- [ ] Strictly verify `/Applications/Soprano.app` after installation.
