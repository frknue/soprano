# Pane Maximize Toggle (Prefix → M) — Design

Date: 2026-07-20
Status: approved (approach: render-mode switch; exit rules: auto-exit on layout actions)

## Goal

Make the existing `maximize-pane` keybinding (Prefix → M, currently wired to an
empty `keybindingToggleMaximize()` stub) actually work: toggle the active pane
to fill the whole tiling area, and restore the exact split layout on the second
press. tmux-zoom semantics, single-window, transient.

## State & semantics (AgentManager)

- New `private(set) var maximizedPaneId: String?` (nil = normal).
- New `func toggleMaximize()`:
  - No-op when `panes.count < 2` (nothing to maximize over).
  - If `maximizedPaneId == nil`: set it to `activePaneId`.
  - Else: clear it.
  - Either way on change: bump `layoutGeneration`, `notifyChange()`.
- New `private func exitMaximize()` — clears `maximizedPaneId` if set (bumping
  `layoutGeneration`); called at the START of every layout-mutating operation:
  `insertPane` (covers `spawnAgent`/`spawnTerminal`), `splitPane`,
  `closePane` (any pane — this also covers the maximized pane's process dying,
  which funnels through the close path), `navigateToPane`, `resizePane`,
  `restoreWorkspace`, and session load. The operation then applies to the
  restored layout — never blind on hidden panes.
- Tab operations within the maximized pane (new/next/prev/close tab) do NOT
  exit maximize; they don't change topology.
- Not persisted: `snapshotWorkspace()` and saved sessions ignore it entirely.

## Routing (KeybindingManager / MainWindowController)

- `case "maximize-pane"` calls `agentManager.toggleMaximize()` directly, the
  same pattern as the split/close cases.
- The dead `keybindingToggleMaximize()` requirement is deleted from
  `KeybindingDelegate` and its empty implementation from
  `MainWindowController`.

## Rendering (SplitTreeView)

- `rebuildLayout()` renders an effective layout:
  `let effectiveLayout = agentManager.maximizedPaneId.map(SplitNode.leaf) ?? agentManager.layout`.
  The maximized pane's cached `PaneContainerView` is reparented full-size via
  the existing attach path (which already handles
  `ghostty_surface_set_display_id` on reparenting), and restore re-renders the
  real tree the same way.
- **Critical:** orphan pruning must keep using the REAL layout's pane IDs
  (`agentManager.layout`), never the effective layout — otherwise maximizing
  would destroy every hidden pane's container and kill their PTYs.
- Defensive: if `maximizedPaneId` names a pane that no longer exists, render
  the real layout (and the next AgentManager operation clears the stale id).

## Indicator (StatusBarView)

- While maximized, the right-side label (currently "N panes") reads
  `N panes · MAXIMIZED`, with the whole label in the accent color, so a
  full-window pane is never mistaken for a single-pane layout. On restore it
  returns to the normal `N panes` text and color. StatusBarView already
  observes AgentManager; no new wiring.

## Sidebar

- Unchanged. All panes stay listed while one is maximized; the maximized pane
  is the active/highlighted row. Clicking another row calls `focusPane` —
  which is navigation-like but does NOT change topology; decision: `focusPane`
  also exits maximize (it reveals the clicked pane), consistent with
  auto-exit-on-navigation.

## Edge cases

- Maximize with a single pane → no-op, no state change.
- Maximized pane closed (keybinding, sidebar ×, or process exit) →
  `closePane` exits maximize first, then closes; layout restores.
- Session loaded while maximized → exits first.
- Prefix → M twice quickly → clean toggle (state is a simple optional).

## Verification

No test framework. Build with Homebrew Swift, then a driver-based cycle:

1. Split once (Ctrl+A S). Ctrl+A M → screenshot: one full-size pane, status
   bar shows the maximized indicator, sidebar still lists 2 rows.
2. Ctrl+A M → screenshot: both panes visible again, indicator gone.
3. Ctrl+A M, then Ctrl+A S → screenshot: maximize auto-exited AND a third
   pane exists (split applied to restored layout).
4. Ctrl+A M, then click the hidden pane's sidebar row → layout restored,
   clicked pane focused/highlighted.
5. Single pane only: Ctrl+A M → nothing changes.
