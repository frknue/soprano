# Changelog

All notable changes to Soprano Agents are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- omp (oh-my-pi) threads, the new default provider: Soprano Agents drives `omp --mode rpc-ui`, so
  omp's tool approvals (Approve, Approve for this session, Deny) and its `ask` questions appear
  inline; every model omp knows is in the model picker (search with several words, e.g.
  `opus openrouter`), with omp's thinking levels as Reasoning. Set `providers.ompPath` if `omp`
  is not on `PATH`.
- Codex (`codex app-server`) and Claude Code (`claude -p` stream-json) threads in one app, colored
  by Soprano's themes in light and dark (`theme`: `soprano` to follow Soprano, or a Soprano theme
  id; `folio` follows macOS). The terminal drawer uses the theme's terminal colors.
- Thread inbox sidebar: search (titles, branches, messages), project filter, Add project, New
  thread (⌘N, ⇧⌘N, ⌃⌘N), Pinned and Active cards with live status pills (Working, Approval,
  Input, Failed, Done), Working and Settled shelves, inline rename (double-click or F2), thread
  menu (pin, settle, rename, regenerate title, mark unread, copy, archive, delete), ⇧⌘[ / ⇧⌘]
  and ⌘1–⌘9 navigation with hints while ⌘ is held, ⇧⌘S settle, ⇧⌘P pin, ⇧⌘C copy reference.
- Message timeline: user bubbles with "Edit from here" (rewind the thread, optionally the files),
  Markdown answers with code blocks and tables, "Worked for …" folds over each turn's work log, a
  live "Working for" row, inline approvals, plan and task cards, changed-files cards that open
  the diff, queued messages, and Find in Thread (⌘F). ⌘↓ jumps to the latest message.
- Composer: attachments (paperclip, paste, drop), model picker (⇧⌘M), reasoning effort and Fast
  Mode (⇧⌘E), permissions Supervised / Auto-accept edits / Auto / Full access (⇧⌘A), Build/Plan
  (⇧⇥), steer or queue while the agent works (⌘↩ does the other one, `chat.followUp`), Stop,
  approval and question answering, and prompt history with ↑.
- New threads start in the current checkout or a new git worktree (⇧⌘X) from a chosen branch
  (⇧⌘G); worktree branches get a generated name and threads a generated title
  (`textGeneration`, `worktrees.directory`, `worktrees.branchPrefix`).
- Every turn is checkpointed in hidden git refs, so each turn's diff and the whole thread's diff
  are available without touching your index or commits.
- Right panel Diff (⌘D): the whole thread, the latest turn, any turn or uncommitted changes,
  stacked or split, with line wrapping, whitespace toggle, collapsible files, a file tree and
  Maximize panel.
- Terminal drawer (⌘J): login-shell terminals per thread in the thread's working directory; ⌘N
  adds one, ⌘W closes one, drag the top edge to resize.
- Thread details card (⇧⌘B): open the workspace in your editor (⌘O, `editor.app`), run project
  scripts in the terminal, copy the branch name, commit / push / create a PR with generated
  messages and the "Commit changes" dialog, and open uncommitted changes.
- Command palette (⌘K): actions with their shortcuts, recent threads, projects and settings
  pages, fuzzy search, `>` for actions only, "New thread in..." per project.
- Settings screen (⌘,): General, Providers, Text generation, Worktrees, Notifications,
  Keybindings (record, turn off or reset any shortcut), Archive and About; every change is
  written to `~/.config/soprano-agents/settings.json`.
- Notifications when a thread completes, fails, or needs approval or input while the app is in
  the background (`notifications.enabled`, `notifications.sound`), and a Dock badge counting
  threads waiting for you.
- App icon: a speech bubble with typing dots.

### Fixed

- The composer's buttons (attach, model, reasoning/permissions, send) and its text area take clicks again; the composer's outline was swallowing them.
