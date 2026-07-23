# Soprano Audit Fixes Design

**Date:** 2026-07-23

## Goal

Resolve the thirteen defects found in the July 2026 Soprano audit without
replacing the current AppKit/libghostty architecture or launching the GUI
during automated verification.

## Scope

The change covers:

1. Clipboard requests that require confirmation.
2. Stale terminal surfaces after restoring a named session.
3. Model-to-view and view-to-model split resizing.
4. Agent stop, restart, and terminal-close lifecycle behavior.
5. Invalid signatures on assembled application bundles.
6. Incorrect libghostty scroll metadata.
7. IME composition and modifier-key release handling.
8. Agent-event leakage between Soprano processes.
9. Settings edits lost when a text field stops editing.
10. Pane-navigation passthrough leaking between tabs.
11. Missing Copy, Paste, and Select All terminal responder actions.
12. Inconsistent pane-cap enforcement and false-success spawn results.
13. Non-functional directional navigation wrapping.

Small correctness fixes directly adjacent to these paths are included:
preserving a tab's working directory when splitting, updating the mouse
position before the first button event, and delivering Command-modified
key-up events to libghostty.

## Architecture

### Testable boundaries

Add a SwiftPM `SopranoTests` target that imports the executable module with
`@testable import Soprano`. Tests may construct Foundation model/controller
types and small AppKit values, but must not initialize libghostty, launch the
application, or create a GUI window.

Pure helpers will hold behavior that otherwise depends on opaque AppKit or C
types:

- split-tree percentage mutation and directional boundary selection;
- terminal target identity (`paneId` plus `tabId`);
- navigation-passthrough reference counting;
- notification payload parsing and process-scoped naming;
- settings-value normalization;
- scroll metadata and modifier transition calculation;
- clipboard confirmation queue state.

### Stable terminal identity and lifecycle

Every terminal lifecycle event is addressed to a `(paneId, tabId)` target.
`AgentManager` remains the source of model state and emits a target-specific
terminal lifecycle action after stop or restart state changes. `SplitTreeView`
owns the terminal-view cache and executes those actions against the matching
`TerminalSurfaceView`; the model does not retain AppKit views.

Ghostty close callbacks include both IDs. An agent close marks only that
agent tab stopped. A regular terminal close removes only that tab, which
closes its pane when it was the final tab. Destroying a terminal surface is
idempotent, cancels outstanding clipboard confirmations first, and nils the
surface pointer before returning.

### Cold workspace restoration

Named sessions are persisted layouts, not handles to live PTYs. A successful
`restoreWorkspace` increments a dedicated restore generation. `SplitTreeView`
observes it and destroys all cached tab surfaces before recreating content
from the restored tab type, profile, and working directory. Ordinary layout
or focus changes do not increment this generation and therefore preserve live
terminal processes.

### Bidirectional split sizing

Each rendered `ThemedSplitView` is associated with its branch path in
`SplitNode`.

- Keyboard resize updates the model and synchronizes the desired percentage
  into the existing split view.
- Divider dragging calculates a clamped percentage and writes it back to the
  exact model branch.
- Programmatic updates suppress divider callbacks to avoid feedback loops.
- Model and view use the same 10...90 percent bounds.

### Clipboard security

Soprano uses a main-actor clipboard confirmation coordinator with one active
sheet and a FIFO queue. Callback-owned C strings are copied immediately.
Pending read state is retained until exactly one completion.

- A normal read supplies pasteboard content with `confirmed == false`.
- If libghostty requests confirmation, Soprano shows a native sheet.
- Allow completes with the original content and `confirmed == true`.
- Deny, sheet dismissal, missing parent window, or surface destruction
  completes with empty content and `confirmed == true`.
- A confirmation-required write changes the pasteboard only after Allow.
- Selection clipboard operations use a dedicated named pasteboard rather than
  the system Find pasteboard.

This preserves Ghostty's unsafe multiline-paste and OSC 52 policies while
keeping those operations usable after explicit approval.

### Keyboard, IME, mouse, and Edit menu

`TerminalSurfaceView` adopts `NSTextInputClient` following the vendored
Ghostty AppKit implementation:

- `interpretKeyEvents` drives committed and marked text;
- `ghostty_surface_preedit` mirrors the active marked string;
- the IME candidate rectangle comes from `ghostty_surface_ime_point`;
- modifier transitions send press or release, including left/right variants;
- a local key-up monitor forwards Command-modified releases while this surface
  is first responder;
- scroll flags encode precision and momentum, not keyboard modifiers;
- mouse position is sent before button state;
- standard AppKit `copy:`, `paste:`, and `selectAll:` selectors map to Ghostty
  binding actions.

### External event isolation

Agent-event distributed-notification names include `SOPRANO_APP_PID`. Events
without process, pane, or tab identity are handled as no-ops and never fall
back to a global channel.

Pane-navigation notifications are already process-scoped and become
tab-scoped as well. Passthrough claims use a reference-counted registry keyed
by `(paneId, tabId)` and source, so duplicate enable/disable events and
background tabs cannot change the foreground tab's key handling.

### Settings and packaging

The prefix, timeout, and resize fields send their existing actions when
editing ends. Switching settings tabs first ends editing so the value is
committed before controls are rebuilt.

The package script signs the fully assembled staging bundle, verifies it with
`codesign --deep --strict`, and only then promotes it to the requested output
path. The default identity remains ad-hoc (`-`), with an environment override
for an intentional signing identity.

## Error handling and safety

- Capacity checks happen before IDs or panes are allocated and return `nil` on
  failure.
- Unknown notification targets, malformed payloads, unmatched passthrough
  disables, and duplicate lifecycle callbacks are harmless no-ops.
- Clipboard requests are denied rather than leaked if a window or surface is
  unavailable.
- Surface teardown and close handling are idempotent to prevent double-free.
- App bundles are never promoted when signing or signature verification fails.

## Verification

Every behavior change follows a red-green test cycle where practical.
Completion requires fresh successful runs of:

```bash
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift test
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build -c release
bash -n scripts/package-app.sh dev.sh install.sh
./dev.sh --build-only
codesign --verify --deep --strict --verbose=2 ".build/debug/Soprano Dev.app"
plutil -lint ".build/debug/Soprano Dev.app/Contents/Info.plist"
./install.sh
codesign --verify --deep --strict --verbose=2 "/Applications/Soprano.app"
```

No verification step launches Soprano.

## Non-goals

- Replacing Soprano's terminal host with Ghostty's full application layer.
- Persisting live PTY processes inside named sessions.
- Changing agent profiles, visual styling, or default keybindings.
- Distribution notarization or Developer ID provisioning.
