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
  and ⌃1–⌃9 navigation (as in Soprano) with hints while ⌃ is held, ⇧⌘S settle, ⇧⌘P pin,
  ⇧⌘C copy reference.
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
- The right panel holds tabs per thread, as in T3 Code: next to Diff, a Files tab (`⇧⌘F`, or
  Search Files from the palette) browses and searches the thread's workspace (git-ignored files
  stay out) and opens files in read-only tabs with line numbers and syntax colors (images too),
  with Copy contents, Open in Editor and Reveal in Finder; Terminal tabs (`⇧⌘J`) run shells in
  the thread's working directory beside the drawer's. `+` adds a surface, `⌘W` closes the focused
  tab, `⌘F` in the panel opens a file tab's find bar or the Files search (Find in Thread
  elsewhere), tabs that don't fit scroll sideways, and with every tab closed "Open a surface"
  offers Terminal (`T`), Files (`F`) and Diff (`D`).
- A context meter next to Send shows how full the thread's context window is, read exactly from
  omp, Codex and Claude Code after every turn; click it for the token count and "Compact
  conversation" (also Compact Conversation in the command palette, or send `/compact`). The
  provider's result appears as a notice in the timeline.
- Typing `/` at the start of a line in the composer lists the provider's commands and skills (omp
  commands and `/skill:` skills, Claude Code commands and skills, Codex `$` skills): ↑/↓ choose,
  Enter or Tab insert, Esc closes. A `$skill` mention sends that skill to Codex.
- Accounts, as in Soprano: sign in to several Claude and Codex accounts in Settings → Accounts
  (omp prefers or balances, Claude Code and the Codex CLI switch to the chosen one); new Codex and
  omp threads start with the chosen account.
- Usage at the bottom of the sidebar (`Claude 9% · Codex 75%`, warning from 70 %, red from 90 %);
  click it or press ⌘U for each account's 5-hour and weekly limits and their resets.
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
- The chat header shows where the thread or new thread works: `repo/sub/folder` (the `~` path
  outside git, a worktree under its repository's name) and the branch; hover for the full path,
  click to toggle the thread details (⇧⌘B).

### Fixed

- omp slash commands typed in the composer (`/usage`, `/session`, `/context`, `/tools`, …) now show
  their output in the thread instead of ending the turn with nothing visible.
- The composer's buttons (attach, model, reasoning/permissions, send) and its text area take clicks again; the composer's outline was swallowing them.
- Clicking a composer chip whose picker is open now closes the picker instead of reopening it.
- Scrolling a list (model picker, menus, palette, timeline) with the pointer resting on it no
  longer leaves rows highlighted after they scroll away from the pointer.
- Terminals render Nerd Font icons and powerline separators (Powerlevel10k, Starship, eza): they
  use an installed "… Nerd Font Mono" family (JetBrains Mono first) or Powerlevel10k's MesloLGS
  NF instead of SF Mono, or fall back to Symbols Nerd Font Mono.
- omp threads no longer keep showing Working after the answer while a background job (an async
  bash/task, an advisor review) still runs: the turn shows as done with a muted "Background work
  still running…" note, the composer offers Send instead of Stop, and a job that wakes the agent
  shows Working again and adds to that turn. A message you send meanwhile starts a new turn
  instead of interrupting the finished one.
- A new thread in a project now has a Terminal (⇧⌘J, or "+" in the right panel), Files (⇧⌘F) and
  the terminal drawer (⌘J) in the project folder, and its Diff shows the uncommitted changes
  instead of "No patch available". Sending it as a "Current checkout" thread keeps those tabs and
  running terminals; only a new thread without a project still needs one first.
