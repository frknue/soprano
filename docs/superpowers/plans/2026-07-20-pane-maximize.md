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
- **Do NOT launch the GUI (`.build/debug/Soprano`, `swift run`, `./run.sh`) during verification** — it spawns login shells that trigger repeated macOS "Ghostty would like to access data from other apps" prompts (see CLAUDE.md). Verify the logic with a standalone `swiftc` harness (Step 6); the visual checks are handed to the user as a manual checklist (Step 7). `$SCRATCH` = `/private/tmp/claude-501/-Users-furkanulker-git-private-soprano/33105055-4294-4ee0-82c5-5eb20ce13c03/scratchpad`.

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

- [ ] **Step 6: Standalone logic verification (no GUI, no prompt)**

Write `$SCRATCH/maximize-test/main.swift` — it drives `AgentManager` directly (no NSEvent, no ghostty, no shell). `AgentManager.init()` starts with one pane (`pane-1`). Helpers below spawn/split by calling the real public methods and read `maximizedPaneId`, `layout`, `panes`, `activePaneId`.

```swift
import Foundation

var failures = 0
func check(_ cond: Bool, _ label: String) {
    print((cond ? "PASS " : "FAIL ") + label)
    if !cond { failures += 1 }
}

// 1. Single pane: toggleMaximize is a no-op.
let m1 = AgentManager()
m1.toggleMaximize()
check(m1.maximizedPaneId == nil, "single pane: maximize is no-op")

// 2. Two panes: maximize sets the active pane; toggle clears it.
let m2 = AgentManager()
m2.spawnTerminal()                       // insertPane -> 2 panes, active = new pane
let active = m2.activePaneId
m2.toggleMaximize()
check(m2.maximizedPaneId == active, "two panes: maximize sets active pane")
check(m2.panes.count == 2, "maximize does not drop panes")
m2.toggleMaximize()
check(m2.maximizedPaneId == nil, "second toggle restores")

// 3. Auto-exit on split.
let m3 = AgentManager()
m3.spawnTerminal()
m3.toggleMaximize()
check(m3.maximizedPaneId != nil, "precondition: maximized")
_ = m3.splitPane(direction: .vertical, paneId: m3.activePaneId)
check(m3.maximizedPaneId == nil, "split auto-exits maximize")
check(m3.panes.count == 3, "split still applied after auto-exit")

// 4. Auto-exit on navigation.
let m4 = AgentManager()
m4.spawnTerminal()
m4.toggleMaximize()
m4.navigateToPane(direction: .left)
check(m4.maximizedPaneId == nil, "navigation auto-exits maximize")

// 5. Auto-exit on focusPane (sidebar row click path).
let m5 = AgentManager()
m5.spawnTerminal()
let other = m5.panes.keys.first { $0 != m5.activePaneId }!
m5.toggleMaximize()
m5.focusPane(other)
check(m5.maximizedPaneId == nil, "focusPane auto-exits maximize")
check(m5.activePaneId == other, "focusPane still moved focus")

// 6. Auto-exit on close.
let m6 = AgentManager()
m6.spawnTerminal()
m6.toggleMaximize()
m6.closePane(m6.activePaneId)
check(m6.maximizedPaneId == nil, "closePane auto-exits maximize")

// 7. Not persisted: a snapshot taken while maximized restores un-maximized.
let m7 = AgentManager()
m7.spawnTerminal()
m7.toggleMaximize()
let snap = m7.snapshotWorkspace()
let m7b = AgentManager()
m7b.restoreWorkspace(snap)
check(m7b.maximizedPaneId == nil, "restore is never maximized")

if failures > 0 { print("\(failures) FAILURES"); exit(1) }
print("ALL PASS")
```

Compile with the model + controller sources (Foundation/AppKit only — no GUI, no PTY, so no permission prompt) and run:

```bash
SCRATCH=/private/tmp/claude-501/-Users-furkanulker-git-private-soprano/33105055-4294-4ee0-82c5-5eb20ce13c03/scratchpad
cd /Users/furkanulker/git/private/soprano
mkdir -p "$SCRATCH/maximize-test"
# (write main.swift above first)
/opt/homebrew/opt/swift/bin/swiftc -sdk "$(xcrun --show-sdk-path)" \
    Sources/Soprano/Controllers/AgentManager.swift \
    Sources/Soprano/Models/SplitNode.swift \
    Sources/Soprano/Models/PaneState.swift \
    Sources/Soprano/Models/AgentInstance.swift \
    Sources/Soprano/Models/WorkspaceSession.swift \
    Sources/Soprano/Models/AgentProfile.swift \
    Sources/Soprano/Config/DefaultAgents.swift \
    Sources/Soprano/Utilities/NSColor+Hex.swift \
    "$SCRATCH/maximize-test/main.swift" \
    -o "$SCRATCH/maximize-test/harness"
"$SCRATCH/maximize-test/harness"
```

Expected: 11 `PASS` lines and `ALL PASS`, exit 0. If the compile pulls a file that transitively imports a GUI-only symbol, add that source file to the list — do NOT switch to launching the app. The harness lives in the scratchpad and is NOT committed.

- [ ] **Step 7: Record the manual visual checklist**

The rendering and status-bar-text behavior is visual and needs the running app, which is left to the user (launching it in an agent loop spams TCC prompts — see CLAUDE.md). In your report, include this checklist verbatim for the user to run via `./run.sh`:

1. Split once (Ctrl+A S), then Ctrl+A M → one pane fills the tiling area; status bar reads `2 panes · MAXIMIZED` in the accent color; sidebar still lists both panes.
2. Ctrl+A M again → both panes visible; status bar back to plain `2 panes`.
3. While maximized, Ctrl+A S → three panes visible (maximize auto-exited, split applied).
4. While maximized, click the other pane's sidebar row → layout restored, that pane focused.

- [ ] **Step 8: Commit**

```bash
git add Sources/Soprano/Controllers/AgentManager.swift \
    Sources/Soprano/Views/SplitTreeView.swift \
    Sources/Soprano/Controllers/KeybindingManager.swift \
    Sources/Soprano/App/MainWindowController.swift \
    Sources/Soprano/Views/StatusBarView.swift
git commit -m "feat: implement pane maximize toggle (prefix+M)"
```
