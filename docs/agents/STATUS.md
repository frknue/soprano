# Status

Goal: Soprano Agents, a native macOS T3 Code look-alike for omp (default), Codex and Claude Code
in the Soprano family (`~/git/private/soprano-agents`, local only, no GitHub remote yet).

## Done
- All modules built and merged: providers (omp `--mode rpc-ui`, Codex app-server, Claude
  stream-json + control protocol), engine (sessions, steering, queue, approvals, questions, checkpoints, revert, diffs,
  titles, branch names, git actions), JSON store, git (checkpoints in hidden refs, worktrees,
  status, commit/push/PR via gh), sidebar, chat header, timeline, composer, right-panel diff,
  terminal drawer (SwiftTerm), thread details card, palette, settings screen, dialogs,
  notifications, icon.
- `swift test`: 389 tests. Offscreen snapshots of every fixture in light and dark.
- Live end-to-end smoke (real CLIs, throwaway repos): Codex thread in a new worktree with an
  approval, checkpoint, turn diff, generated title and branch rename, revert with file restore;
  Claude thread in the project root with a file-change approval, a second turn, and reload from
  disk; omp thread (claude-haiku-5-5 via omp) in a new worktree with file-change and command
  approvals, checkpoint diff, omp-generated title and branch, a full-access relaunch on the same
  session file, Edit from here with file restore (omp `navigate_tree`), and reload + resume.

## Next
- First real GUI session (not launched by agents): check the terminal drawer's colors (the
  offscreen harness renders SwiftTerm's background white), the composer blur, and window focus.
- Known gaps: `docs/ROADMAP.md`; slice-level gaps (no diff search, no pull action in the engine,
  code blocks wrap instead of scrolling, Claude rollback cut only sticks after the next message).

## Open decisions
- Publish to GitHub (`frknue/soprano_agents`) and add a release workflow like the siblings.
