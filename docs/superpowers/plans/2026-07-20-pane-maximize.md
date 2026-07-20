# Pane Maximize Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Prefix → M toggle the active pane full-size (tmux-zoom semantics) per `docs/superpowers/specs/2026-07-20-pane-maximize-design.md` — it is currently an empty delegate stub.

**Architecture:** `AgentManager` gains transient `maximizedPaneId` state with `toggleMaximize()` and an internal `exitMaximize()` called by every layout-mutating operation. `SplitTreeView.rebuildLayout()` renders a single-leaf effective layout while maximized; orphan pruning already reads the real layout so hidden panes' containers/PTYs survive untouched. `StatusBarView` shows an accent-colored `· MAXIMIZED` suffix. The dead `keybindingToggleMaximize` delegate member is deleted; `KeybindingManager` calls the manager directly like the split/close cases.

**Tech Stack:** Swift 6 / AppKit, SPM. No test framework — verification is a clean build plus a driver-based GUI cycle.

## Global Constraints

- Build ALWAYS with Homebrew Swift: `PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build`.
- Code conventions (CLAUDE.md): 4-space indent; trailing commas in multi-line structures; observer pattern via `notifyChange()`.
- Maximize state is transient: `snapshotWorkspace()` and saved sessions must NOT include it (no Codable changes anywhere).
- `pruneOrphanedContainers()` must keep using `agentManager.layout` — pruning against the effective layout would destroy hidden panes' PTYs.
- Exit rules (spec): `toggleMaximize` no-ops with fewer than 2 panes; `insertPane`, `splitPane`, `closePane`, `focusPane`, `navigateToPane`, `resizePane`, `setLayout`, `restoreWorkspace` all restore the full layout before applying. Tab operations do NOT exit maximize.
- Verification helpers `driver`/`allwin` exist in `$SCRATCH` = `/private/tmp/claude-501/-Users-furkanulker-git-private-soprano/33105055-4294-4ee0-82c5-5eb20ce13c03/scratchpad`. Key codes: a=0, s=1, m=46, l=37. Kill instances with `pkill -x Soprano` between launches.

---

### Task 1: Maximize toggle end-to-end

**Files:**
- Modify: `Sources/Soprano/Controllers/AgentManager.swift`
- Modify: `Sources/Soprano/Views/SplitTreeView.swift:111-129` (`rebuildLayout`)
- Modify: `Sources/Soprano/Controllers/KeybindingManager.swift:8,169-170`
- Modify: `Sources/Soprano/App/MainWindowController.swift:243`
- Modify: `Sources/Soprano/Views/StatusBarView.swift:78-93`

**Interfaces:**
- Consumes: existing `notifyChange(layoutChanged:)`, `layoutGeneration`, `panes`, `activePaneId`, `layout` in `AgentManager`; `agentManager.maximizedPaneId` read by the two views.
- Produces: `AgentManager.maximizedPaneId: String?` (private(set)) and `func toggleMaximize()` — public API for the keybinding and views. Nothing else consumes this later.

- [ ] **Step 1: AgentManager — state, toggle, exit hook**

In `Sources/Soprano/Controllers/AgentManager.swift`, add below `private(set) var layout: SplitNode?`:

```swift
    /// Pane rendered full-size instead of the split tree (nil = normal).
    /// Transient view state — never persisted in sessions.
    private(set) var maximizedPaneId: String?
```

Add a new section before `// MARK: - Agent Lifecycle`:

```swift
    // MARK: - Maximize

    func toggleMaximize() {
        if maximizedPaneId != nil {
            maximizedPaneId = nil
            notifyChange(layoutChanged: true)
            return
        }
        guard panes.count > 1, panes[activePaneId] != nil else { return }
        maximizedPaneId = activePaneId
        notifyChange(layoutChanged: true)
    }

    /// Restore the full layout before a topology-affecting operation so
    /// nothing operates blind on hidden panes. Notifies immediately —
    /// callers notify again after their own mutation, which is harmless.
    private func exitMaximize() {
        guard maximizedPaneId != nil else { return }
        maximizedPaneId = nil
        notifyChange(layoutChanged: true)
    }
```

Insert `exitMaximize()` immediately AFTER the initial guard (never before — early-returns must not exit maximize) in each of:

- `splitPane(direction:paneId:)` — after the `guard let sourcePane ... else { return nil }`
- `closePane(_:)` — after `guard panes[paneId] != nil else { return }`
- `focusPane(_:)` — after `guard panes[paneId] != nil, activePaneId != paneId else { return }`
- `navigateToPane(direction:)` — after `guard let currentLayout = layout else { return }`
- `resizePane(direction:tickPercent:)` — after the `guard let currentLayout ... else { return }`
- `setLayout(_:)` — first line of the body
- `insertPane(_:)` — after `guard panes.count < Self.maxPanes else { return }`

In `restoreWorkspace(_:)`, add `maximizedPaneId = nil` directly before the final `notifyChange(layoutChanged: true)` (no `exitMaximize()` here — the restore already rebuilds everything; avoid a double notify mid-restore).

- [ ] **Step 2: SplitTreeView — effective layout**

In `rebuildLayout()` replace:

```swift
        let view = buildView(for: layout)
```

with:

```swift
        // Maximize renders a single-leaf effective layout. Orphan pruning
        // below still uses the real layout, so hidden panes' containers
        // (and their PTYs) survive.
        let effectiveLayout: SplitNode
        if let maximizedId = agentManager.maximizedPaneId, agentManager.panes[maximizedId] != nil {
            effectiveLayout = .leaf(maximizedId)
        } else {
            effectiveLayout = layout
        }
        let view = buildView(for: effectiveLayout)
```

(`pruneOrphanedContainers()` is untouched — it already reads `agentManager.layout`.)

- [ ] **Step 3: Keybinding routing — delete the dead stub**

`Sources/Soprano/Controllers/KeybindingManager.swift`: in `executeBinding`, replace

```swift
        case "maximize-pane":
            invokeDelegate { $0.keybindingToggleMaximize() }
```

with

```swift
        case "maximize-pane":
            agentManager.toggleMaximize()
```

and delete `func keybindingToggleMaximize()` from the `KeybindingDelegate` protocol (line 8).

`Sources/Soprano/App/MainWindowController.swift`: delete the empty `func keybindingToggleMaximize() {}` from the `KeybindingDelegate` extension (line 243).

- [ ] **Step 4: StatusBarView — indicator**

Replace `refresh()` and the `paneCountLabel` line in `refreshTheme()`:

```swift
    func refreshTheme() {
        let theme = themeManager.currentTheme
        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        brandLabel.textColor = theme.colors.accent
        if modeLabel.stringValue == "PREFIX" {
            modeLabel.textColor = theme.colors.accent
        } else {
            modeLabel.textColor = theme.colors.textMuted
        }
        refresh()
    }

    private func refresh() {
        let theme = themeManager.currentTheme
        let count = agentManager.paneCount
        let base = "\(count) pane\(count == 1 ? "" : "s")"
        if agentManager.maximizedPaneId != nil {
            paneCountLabel.stringValue = "\(base) · MAXIMIZED"
            paneCountLabel.textColor = theme.colors.accent
        } else {
            paneCountLabel.stringValue = base
            paneCountLabel.textColor = theme.colors.textMuted
        }
    }
```

(The old `refreshTheme()` set `paneCountLabel.textColor` unconditionally; delegating to `refresh()` keeps the accent color across theme switches.)

- [ ] **Step 5: Build**

```bash
cd /Users/furkanulker/git/private/soprano
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build
```

Expected: `Build complete!`. A remaining reference to `keybindingToggleMaximize` anywhere is a missed call site — fix it.

- [ ] **Step 6: GUI verification (spec's 5 checks)**

```bash
SCRATCH=/private/tmp/claude-501/-Users-furkanulker-git-private-soprano/33105055-4294-4ee0-82c5-5eb20ce13c03/scratchpad
cd /Users/furkanulker/git/private/soprano
pkill -x Soprano; sleep 1
.build/debug/Soprano > /dev/null 2>&1 &
sleep 3
PID=$(pgrep -x Soprano | head -1)
WID=$("$SCRATCH/allwin" "$PID" | grep "name=Soprano" | sed -E 's/id=([0-9]+).*/\1/')
```

1. Single-pane no-op: `"$SCRATCH/driver" key "$PID" 0 ctrl; sleep 0.3; "$SCRATCH/driver" key "$PID" 46; sleep 0.5` then capture `max-0-noop.png`. Expected: unchanged single pane, status bar `1 pane` (not accented, no suffix).
2. Split then maximize: Ctrl+A `s` (`0 ctrl`, then `1`), wait 1s, then Ctrl+A `m` (`0 ctrl`, then `46`), capture `max-1-maximized.png`. Expected: ONE full-size pane in the tiling area, sidebar still lists 2 rows, status bar `2 panes · MAXIMIZED` in accent color.
3. Toggle back: Ctrl+A `m`, capture `max-2-restored.png`. Expected: both panes visible again, status bar back to plain `2 panes`.
4. Auto-exit on split: Ctrl+A `m` (maximize again), then Ctrl+A `s`, capture `max-3-autoexit-split.png`. Expected: THREE panes all visible (maximize exited, split applied), no `MAXIMIZED` suffix.
5. Auto-exit on navigation: Ctrl+A `m`, then Ctrl+L (`37 ctrl`, direct nav-right), capture `max-4-autoexit-nav.png`. Expected: all panes visible, focus moved (highlighted pane changed), no suffix.

Read every PNG against its expectation. `pkill -x Soprano` afterwards. The sidebar-row-click exit path (`focusPane`) shares the same `exitMaximize()` mechanism verified in check 5; rows aren't AX-clickable, so it is verified by code inspection plus the user's manual pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/Soprano/Controllers/AgentManager.swift \
    Sources/Soprano/Views/SplitTreeView.swift \
    Sources/Soprano/Controllers/KeybindingManager.swift \
    Sources/Soprano/App/MainWindowController.swift \
    Sources/Soprano/Views/StatusBarView.swift
git commit -m "feat: implement pane maximize toggle (prefix+M)"
```
