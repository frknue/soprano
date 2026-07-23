# Task 3 Report: Target-specific terminal stop, restart, and close

## Result

Implemented exact `(paneId, tabId)` terminal lifecycle routing across
`AgentManager`, `SplitTreeView`, `TerminalSurfaceView`, and the Ghostty close
callback.

- `TerminalTarget` is hashable and `TerminalLifecycleAction` carries an exact
  target for stop/restart work.
- Existing `restartAgent(paneId:)` and `stopAgent(paneId:)` remain active-tab
  conveniences; both resolve the active tab once and delegate to exact-target
  methods.
- Agent state is updated before synchronous lifecycle delivery. Stop destroys
  only the cached target surface; restart resets state and then recreates only
  the cached target surface.
- Restarting an uncached target constructs it once with surface creation
  enabled. Selecting an explicitly stopped uncached agent constructs its view
  with surface creation disabled.
- Ghostty close notifications now include `tabId`. The internal
  `handleTerminalClose(target:)` routes inactive closes without consulting the
  pane's active tab: agent tabs become stopped, while regular terminal tabs are
  removed.
- Surface teardown clears the Swift `surface` property before calling
  `ghostty_surface_free`, making reentrant callbacks and repeated destruction
  no-ops.

## TDD evidence

### RED

The test file was added before any production edit.

Command:

```sh
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift test --filter TerminalLifecycle
```

Exit status: `1`.

Exact relevant output:

```text
error: emit-module command failed with exit code 1 (use -v to see invocation)
Tests/SopranoTests/TerminalLifecycleTests.swift:223:26: error: cannot find type 'TerminalTarget' in scope
Tests/SopranoTests/TerminalLifecycleTests.swift:17:23: error: cannot find type 'TerminalLifecycleAction' in scope
Tests/SopranoTests/TerminalLifecycleTests.swift:19:17: error: value of type 'AgentManager' has no member 'addTerminalLifecycleObserver'
Tests/SopranoTests/TerminalLifecycleTests.swift:28:26: error: incorrect argument label in call (have 'target:', expected 'paneId:')
Tests/SopranoTests/TerminalLifecycleTests.swift:73:17: error: value of type 'AgentManager' has no member 'handleTerminalClose'
Tests/SopranoTests/TerminalLifecycleTests.swift:194:22: error: extra arguments at positions #3, #4, #5 in call
Sources/Soprano/Views/SplitTreeView.swift:35:5: note: 'init(agentManager:themeManager:)' declared here
error: fatalError
```

This was the intended RED: the exact-target model/action APIs, internal close
handler, and injectable surface lifecycle seam did not exist.

### Focused GREEN

Command:

```sh
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift test --filter TerminalLifecycle
```

Exit status: `0`.

Exact result output:

```text
Build complete! (2.34s)
✔ Test inactiveRegularTerminalCloseRemovesOnlyTheSuppliedTab() passed after 0.001 seconds.
✔ Test activeTabConveniencesResolveAndEmitTheExactTarget() passed after 0.001 seconds.
✔ Test exactStopAndRestartEmitTheirTargetAfterUpdatingOnlyThatAgent() passed after 0.001 seconds.
✔ Test inactiveAgentCloseStopsOnlyTheSuppliedTab() passed after 0.001 seconds.
✔ Suite TerminalLifecycleTests passed after 0.001 seconds.
✔ Test restartOfUncachedTargetConstructsAndStartsItExactlyOnce() passed after 0.045 seconds.
✔ Test stoppedUncachedAgentDoesNotStartWhenItBecomesVisible() passed after 0.054 seconds.
✔ Test stopAndRestartOperateOnlyOnTheCachedTargetSurface() passed after 0.054 seconds.
✔ Suite SplitTreeTerminalLifecycleTests passed after 0.054 seconds.
✔ Test run with 7 tests in 2 suites passed after 0.054 seconds.
```

The focused link step also emitted the repository/toolchain's existing macOS
deployment and missing Ghostty debug-symbol warnings; there were no compile or
test errors.

## Tests added

`Tests/SopranoTests/TerminalLifecycleTests.swift` uses only model/action and
injected surface-lifecycle spies. It does not initialize Ghostty or launch an
`NSWindow`.

- Exact stop/restart update only the supplied agent and deliver after the new
  model state is installed.
- Existing active-tab convenience methods emit the resolved exact target.
- A close from an inactive agent tab stops only that agent.
- A close from an inactive regular terminal removes only that tab.
- Duplicate close events are no-ops.
- Cached stop/restart touches only the supplied surface; repeated stop does not
  destroy twice.
- Selecting an uncached stopped agent constructs a view without starting a
  surface.
- Restarting an uncached stopped agent constructs and starts it exactly once.

## Full verification

Full suite command:

```sh
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift test
```

Exit status: `0`.

Exact result output:

```text
Building for debugging...
[0/4] Write swift-version-F267FA2F636F94C.txt
Build complete! (0.05s)
✔ Suite SplitNodeTests passed after 0.001 seconds.
✔ Suite TerminalLifecycleTests passed after 0.001 seconds.
✔ Suite AgentManagerPaneTests passed after 0.001 seconds.
✔ Suite WorkspaceRestoreTests passed after 0.001 seconds.
✔ Suite SplitTreeTerminalLifecycleTests passed after 0.049 seconds.
✔ Suite ThemedSplitViewTests passed after 0.049 seconds.
✔ Test run with 22 tests in 6 suites passed after 0.049 seconds.
```

Build command:

```sh
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build
```

Exit status: `0`.

Exact output:

```text
[0/1] Planning build
Building for debugging...
[0/3] Write swift-version-F267FA2F636F94C.txt
Build complete! (0.07s)
```

`git diff --check` also exited successfully with no output.

## Files

- `Sources/Soprano/Controllers/AgentManager.swift`
  - Added exact target/action model types, lifecycle observers, exact stop and
    restart APIs, active-tab convenience delegation, and internal close
    routing.
- `Sources/Soprano/Views/SplitTreeView.swift`
  - Executes lifecycle work against the exact tab cache entry and supports
    test-only injected view/start/destroy/restart spies.
  - Gates initial surface creation on stopped agent status.
- `Sources/Soprano/Terminal/TerminalSurfaceView.swift`
  - Added optional initial surface startup and nil-before-free idempotent
    teardown.
- `Sources/Soprano/Terminal/GhosttyAppManager.swift`
  - Added `tabId` to close callback notification payloads.
- `Tests/SopranoTests/TerminalLifecycleTests.swift`
  - Added seven exact-target model, close-routing, and surface lifecycle tests.

## Self-review

- Confirmed stop ordering is model `stopped` -> lifecycle surface destruction
  -> ordinary change notification.
- Confirmed restart ordering is model reset (`starting`, cleared attention and
  exit code, new start time, incremented restart count) -> exact surface
  recreation/construction -> ordinary change notification.
- Confirmed uncached restart does not call the restart closure after factory
  construction, preventing a create-then-recreate double launch.
- Confirmed no close path reads `PaneState.activeTab`; both notification parsing
  and the internal handler use the supplied pane/tab IDs.
- Confirmed attached agents in regular terminal tabs retain terminal-close
  semantics because routing is based on `PaneType`, matching persistence and
  split behavior.
- Confirmed surface teardown copies the old pointer, clears the stored pointer,
  and only then frees it, so a teardown callback observes `nil`.
- Confirmed lifecycle and ordinary state observers are removed by
  `SplitTreeView.deinit`.
- Confirmed existing `MainWindowController` call sites continue to use the
  preserved active-tab convenience methods.
- Confirmed the Ghostty submodule was not modified.

## Concerns

- No GUI was launched, so actual PTY exit behavior was not exercised manually.
  Automated coverage deliberately replaces terminal views with lifecycle spies
  and therefore neither initializes Ghostty nor launches windows.
- The existing Codex ready fallback remains tied to one-time view construction,
  not each surface generation. A cached restart therefore relies on Codex
  lifecycle/input events to advance from `starting`, and a stopped cold view
  still owns a guarded delayed callback. A follow-up should make that fallback
  generation-aware per actual surface start; it is separate from exact-target
  stop/restart/close routing.
- The focused rebuild emitted existing toolchain/linker warnings about macOS
  deployment versions and missing Ghostty debug symbols. The final cached full
  suite and build completed without errors.
- Per the task constraints, `dev.sh` and `install.sh` were not run.
