# cmux-Style Pane List Sidebar — Design

Date: 2026-07-19
Status: approved (scope: rich pane list replacing activity bar; row detail: git branch; launcher: header/footer)

## Goal

Replace the VSCode-style sidebar (48pt icon activity bar + expandable 200pt
detail panels) with a cmux-style persistent pane list: a single always-visible
220pt sidebar listing every open pane with live status and git branch, toggled
entirely on/off with ⌘E. Soprano keeps its single-layout model — rows focus
panes; there is no workspace switching.

Reference: cmux (https://github.com/manaflow-ai/cmux) shows per-workspace rows
with branch/PR/cwd/ports/notifications. This design adopts the persistent-list
form and the git branch detail only. Ports, PR status, cwd display, and a
notification system are explicitly out of scope (notifications would be a
follow-up project of their own).

## Layout & visibility (MainContentViewController)

- Keep the constraint-based layout and the existing 0.15s ease-in-out width
  animation. The sidebar width constraint now toggles between 0 (hidden) and
  220pt (shown); the 48/248 collapsed/expanded states are removed.
- ⌘E ("Toggle Sidebar", existing binding id `toggle-sidebar`) flips visibility.
  Hidden means the tiling area spans the full window width.
- Inside `SidebarView`, all content lives in an inner container pinned to the
  leading edge with a fixed 220pt width. Collapsing the outer constraint to 0
  clips the content (`masksToBounds` is already set) instead of fighting the
  inner constraints.
- Visibility persists across launches in a `soprano-sidebar-visible`
  UserDefaults bool (default: visible). `MainContentViewController` owns this
  state; `SidebarView.onExpandedChanged` and `activeSection` are deleted.

## Sidebar structure (rewritten SidebarView)

Three vertical zones:

1. **Header** — "PANES" label (10pt bold monospace, `textMuted`, matching the
   current detail-header voice) with a `+` button at the trailing edge. The
   `+` button pops an `NSMenu`: one item per agent profile from
   `DefaultAgents.all` excluding `terminal` (Claude Code, Codex, OpenCode, …),
   a separator, then "Terminal". Selection calls the existing
   `agentManager.spawnAgent(profileId)` / `spawnTerminal()`.
2. **Row list** — vertical scroll view of pane rows, same ordering as today
   (numeric suffix of pane id), rebuilt on `AgentManager` observer
   notifications and on theme changes.
3. **Footer** — slim bar separated by a hairline: a sessions icon (clock
   SF Symbol) and a settings gear. The sessions icon pops an `NSMenu` listing
   saved sessions (click = `sessionManager.loadSession(id)`), a separator, and
   "Save Session As…" which prompts for a name with an `NSAlert` + text field
   and calls `saveSession(name:)`. The gear calls the existing
   `onSettingsRequested` callback.

Deleted: the activity bar, section icon buttons, `SidebarSection` enum, and the
Agents/Panes/Sessions detail panels (the menus above replace the Agents and
Sessions panels; the row list replaces the Panes panel).

## Pane rows

One row view class (replacing `SidebarActionRowView` and `SidebarPaneRowView`),
two lines:

- **Line 1**: status dot (existing `paneStatusColor` logic: agent status →
  muted/yellow/success/danger/gray; terminal → accent) + active-tab title
  (12pt medium, truncating tail) + tab-count badge when a pane has >1 tabs +
  close `×` button.
- **Line 2** (10pt, `textMuted`, indented to align with the title): `⎇ <branch>`
  for the active tab's repo, truncating tail. The line is omitted entirely
  (row shrinks to single-line height) when no branch is known.

Interactions, unchanged from today: clicking the row focuses the pane
(`focusPane`), `×` closes it (`closePane`), the active pane's row is
highlighted with `bgRaised`. Clicks on the close button must not also trigger
row selection (keep the existing `mouseDown` + interactive-subview hit test).

## GitBranchMonitor (new, Controllers/)

Main-thread-only `final class GitBranchMonitor: @unchecked Sendable`, created
in `AppDelegate` alongside the other managers and passed to `SidebarView`.

API:

- `func branch(for cwd: String) -> String?` — cached lookup.
- `var onChange: (() -> Void)?` — fired when any watched branch changes;
  the sidebar subscribes and refreshes rows.
- `func setWatchedPaths(_ paths: [String])` — the sidebar passes the set of
  effective spawn cwds for current panes (`tab.cwd`, falling back to the
  profile's cwd, then to the app process's cwd — which is what ghostty
  spawns inherit when workingDirectory is unset) after each rebuild; the
  monitor adds/removes watchers to match.

Internals:

- Repo resolution: walk up from the cwd until a `.git` entry is found (stop at
  filesystem root). A `.git` **directory** → `HEAD` inside it. A `.git`
  **file** → parse the `gitdir: <path>` pointer and use `HEAD` there
  (worktrees — the common case for parallel agent checkouts; relative gitdir
  paths resolve against the `.git` file's directory).
- Branch parsing: `ref: refs/heads/<name>` → `<name>`; anything else
  (detached HEAD) → first 7 characters of the SHA.
- Watching: `DispatchSource.makeFileSystemObjectSource` on the `HEAD` fd for
  `.write/.delete/.rename`; on an event, re-read, update the cache, notify,
  and re-open the fd (git replaces `HEAD` atomically via rename, which
  invalidates the old descriptor). Events are handled on the main queue.
- No subprocesses and no polling. If a watcher cannot be established, the
  branch is still re-read on every sidebar rebuild (each `AgentManager`
  notification) as a degraded fallback.

## Error handling & edge cases

- Nil cwd, non-repo path, unreadable/garbled `HEAD` → `branch(for:)` returns
  nil; the row shows no branch line. All failures are silent.
- Repo deleted while running → watcher fires delete; cache entry cleared;
  branch line disappears on next refresh.
- Multiple panes sharing one repo share one watcher (keyed by resolved HEAD
  path).
- cwd is the spawn-time directory only; if the shell `cd`s to a different repo
  the branch shown is the launch repo's. Live OSC 7 pwd tracking is a possible
  follow-up, out of scope here.
- Branch/title overflow: truncate; fixed 220pt width, not user-resizable
  (possible follow-up).

## Verification

No test framework is configured. Build with
`PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build`, then a manual pass via
`./run.sh`:

1. ⌘E hides/shows the sidebar with animation; state survives relaunch.
2. `+` menu spawns each agent profile and a terminal.
3. Row click focuses; `×` closes; active row highlighted; badge on multi-tab
   panes.
4. A pane launched in a repo shows `⎇ <branch>`; `git checkout -b` in that repo
   updates the row without restarting; a pane in a worktree shows the
   worktree's branch; a pane in a non-repo directory shows no branch line.
5. Footer: sessions menu loads a saved session; "Save Session As…" saves;
   gear opens settings.
6. Theme switching repaints the sidebar.
