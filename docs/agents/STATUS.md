# Status

Goal: Soprano Agents, Soprano's window for the `omp` coding agent. Until 2026-11-04 it was a
separate app (`~/git/private/soprano-agents`, public at https://github.com/frknue/soprano_agents);
its history was imported into this repo (branch `feat/merge-agents`).

## Done
- All modules built: provider (omp `--mode rpc-ui`), engine (sessions, steering,
  queue, approvals, questions, checkpoints, revert, diffs,
  titles, branch names, git actions), JSON store, git (checkpoints in hidden refs, worktrees,
  status, commit/push/PR via gh), sidebar, chat header, timeline, composer, right panel (tabs per
  thread: Diff, Files explorer, read-only file tabs, Terminal tabs, "Open a surface" launcher),
  terminal drawer (SwiftTerm, sharing `ThreadTerminalStore` with the panel), thread details card,
  palette, settings screen, dialogs, notifications.
- Merge into Soprano (stages 1 and 2 of the plan): one repo with history, `SopranoAgentsCore`
  library + Agents UI in the `Soprano` module (14 colliding type names renamed, vendored copies
  deleted), one process with an Agents window (`⇧⌘A`, back with `⇧⌘T`), per-window menu bar
  (`MenuBarSwitcher`), Soprano's key monitor ignoring the Agents window, one notification delegate,
  one appearance owner, data folder pinned to `Soprano Agents` / `Soprano Agents Dev`, settings under
  `threads` in Soprano's settings.json with a one-time import, `agents-snapshot` subcommand.
- `swift test` runs both suites (about 1,300 tests) in one process.

## Next
- First real GUI session in the merged app (not launched by agents): open the Agents window,
  `⇧⌘A` / `⇧⌘T` round trip, menu bar swap, an existing thread with an attachment reopens and
  resumes, notification click opens the thread, quit while a thread runs.
- Stage 3 of the plan: Open in Terminal / Open as Chat over the omp session file (one process per
  session file), one inbox for the dashboard and the thread sidebar, thread terminals on ghostty
  instead of SwiftTerm, automations that run as threads.
- Stage 4 (optional): a thread as a pane in the split tree.
- Feature backlog: `docs/agents/BACKLOG.md`. Known gaps: `docs/agents/ROADMAP.md`.

## Open decisions
- `⌘4` keeps launching omp's terminal UI; whether it should open a thread instead.
- Retire `frknue/soprano_agents` (archive with a pointer here) once the merge is on `main`.
