# Changelog

All notable changes to Soprano Agents are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- omp (oh-my-pi) threads, colored by Soprano's themes in light and dark (`theme`: `soprano` to
  follow Soprano, or a Soprano theme id; `folio` follows macOS): Soprano Agents drives
  `omp --mode rpc-ui`, so omp's tool approvals (Approve, Approve for this session, Deny) and its
  `ask` questions appear inline; every model omp knows is in the model picker (search with several
  words, e.g. `opus openrouter`), with omp's thinking levels as Reasoning. Set
  `providers.ompPath` if `omp` is not on `PATH`.
- Thread inbox sidebar: search (titles, branches, messages), project filter, Add project, New
  thread (⌘N, ⇧⌘N, ⌃⌘N), collapsible Pinned, Working, Blocked, Failed, Done and Idle sections
  at the top with live status pills (Working, Approval, Input, Failed, Done; reading a thread
  never moves it), the Settled shelf at the bottom, inline rename (double-click or F2), thread
  menu (pin, settle, rename, regenerate title, mark unread, copy, archive, delete), ⇧⌘[ / ⇧⌘]
  and ⌃1–⌃9 navigation (as in Soprano) with hints while ⌃ is held, ⇧⌘S settle, ⇧⌘P pin,
  ⇧⌘C copy reference.
- Message timeline: user bubbles with "Edit from here" (rewind the thread, optionally the files),
  Markdown answers with code blocks and tables, "Worked for …" folds over each turn's work log, a
  live "Working for" row, inline approvals, changed-files cards that open the diff, queued
  messages, and Find in Thread (⌘F). ⌘↓ jumps to the latest message.
- See the code while the agent works: every edit and write shows inline as a colored diff with
  line numbers and syntax colors, and a write or edit appears line by line while the model is
  still typing it. The detailed work log (default) keeps every step and each turn's work open;
  ⇧⌘D, or Settings → General → Work log (`chat.workLog`: `detailed` / `minimal`), switches to
  the minimal one-line view. Each file's button next to its diff opens it in the Diff panel.
- Composer: attachments (paperclip, paste, drop), model picker (⇧⌘M), reasoning effort (⇧⌘E),
  permissions Supervised / Auto-accept edits / Auto / Full access (⇧⌘A), steer or queue while the
  agent works (⌘↩ does the other one, `chat.followUp`), Stop, approval and question answering
  (a message sent while an approval waits declines it and steers the agent), and prompt history
  with ↑.
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
- Markdown files (`.md`, `.markdown`) open in the Files tab as a rendered reader, as in
  Soprano's Markdown reader: New York text in a centered column, headings, code blocks, tables,
  task lists and the repository's own images. Links to other files open their tab (at the linked
  heading), `#heading` links scroll, web links open in the browser. The eye button or
  Toggle Markdown Preview (`⇧⌘V`) switches to the source; `⌘F` shows the source with its find bar.
  Markdown files over 128 KB open as source.
- A context meter next to Send shows how full the thread's context window is, read exactly from
  omp after every turn; click it for the token count and "Compact conversation" (also Compact
  Conversation in the command palette, or send `/compact`). omp's result appears as a notice in
  the timeline.
- Typing `/` at the start of a line in the composer lists omp's commands and `/skill:` skills:
  ↑/↓ choose, Enter or Tab insert, Esc closes.
- Subagents: when omp's agent starts helper agents (its `task` tool), they appear under their
  thread in the sidebar, opened by a "⌄ ⚙ N" dropdown on the thread's row (open on its own while
  one runs), each with its status, what it is doing and its run time. Click one to follow its
  work in the timeline, message it from the composer (it gets the message at its next step) or
  stop it with Stop; its menu also copies its name, assignment and transcript path.
- Accounts, as in Soprano: sign in to several Claude and Codex accounts for omp in Settings →
  Accounts, and let omp prefer one or balance across them; new threads start with the preferred
  account.
- Account button at the bottom of the sidebar, tinted from 70 % and red from 90 % of a limit;
  hover it for usage, click it or press ⌘U for each account's 5-hour and weekly limits and their resets.
- Statistics (⇧⌘U, or the chart button next to Settings in the sidebar), like T3 Code's Usage
  page: omp's requests, tokens and estimated API-equivalent cost over 24h, 7d, 30d, 90d or all
  time, as Cost or Tokens, with cache savings, a stacked chart per hour, day, week or month (hover a bar
  for its numbers) and breakdowns by model, project and agent; click a model to filter the board.
  Inside it, Esc closes, C / T switch Cost / Tokens and 1–5 pick the period.
- Terminal drawer (⌘J): login-shell terminals per thread in the thread's working directory, in
  the theme's terminal colors; ⌘N adds one, ⌘W closes one, drag the top edge to resize.
- Thread details card (⇧⌘B): open the workspace in your editor (⌘O, `editor.app`), run project
  scripts in the terminal, copy the branch name, commit / push / create a PR with generated
  messages and the "Commit changes" dialog, and open uncommitted changes.
- Command palette (⌘K or ⌘P), Soprano's own: every action with a one-line description and its
  shortcut, threads, projects and settings pages.
- Open Project… (⇧⌘K, also the sidebar's and the new thread screen's add-project buttons):
  the projects plus every subfolder of your project folders (`projects.directories`, Settings ›
  General › Project folders, e.g. `~/git/private`, `~/git/work`); picking a folder adds it as a
  project and starts a thread in it. Choose Folder… still opens Finder.
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
- Open in Soprano Git (⌃A then G, as in Soprano; also File menu and palette): opens the thread's
  or new thread's repository in Soprano Git, or selects its tab there if already open.
- Side questions (omp's `/btw`): send `/btw <question>` or press ⇧⌘I to ask about a thread
  without steering it, even while the agent works. The answer streams into a panel above the
  composer and never joins the conversation; a topic takes follow-ups, Stop or Esc cancels a
  running answer, Copy copies it, and the panel lists the thread's earlier side questions,
  including ones asked in omp's terminal UI.
- omp's typing aids in the composer: misspellings and grammar problems are underlined (code,
  paths and identifiers are left alone), and omp predicts the word you are typing as ghost text —
  Tab accepts it with a space, → without. Both follow omp's `spelling.*` settings.

### Changed

- ⌘E shows or hides the left sidebar and ⌘L the right panel (were ⌘B and ⌃⌘B); Focus Composer
  moves from ⌘L to ⇧⌘L.
- After Stop, the turn reads "Stopping…" and the Stop button dims until omp has actually
  stopped.

### Removed

- Codex and Claude Code as agents: omp is the only agent. Plan mode (⇧⇥) and the settings keys
  `agents.defaultProvider`, `textGeneration.provider`, `providers.codexPath` and
  `providers.claudePath` are gone. Threads saved with Codex or Claude Code no longer load; their
  files stay in the app's data folder.

### Fixed

- The Dock badge no longer counts unread Done or Failed threads you settled: they kept the badge
  up with nothing to see in the inbox. A settled thread waiting on Approval or Input still counts.
- Hover fills sit evenly around their content: the composer's effort chip ("High") no longer
  starts flush at its text, and the model and permissions chips have even space on both sides.
  The remove ✕ on image attachments keeps its backdrop after a hover, and the selected
  Stacked/Split diff toggle keeps its look while hovered.
- The window's traffic lights sit on the same line as the sidebar toggle and the "Soprano
  Agents" title instead of above them.
- Double-clicking the title bar (or Window ▸ Zoom) fills the screen again; the statistics board
  had capped how wide the window could grow.
- Clicking empty space inside Settings (or a dialog) no longer closes it; only a click on the
  dimmed backdrop outside the card does.
- Once the agent has answered, the timeline no longer shows "Thinking" under the answer while
  omp wraps up the turn (advisor review, stop hooks); it returns if the agent works again.
- omp's advisor reviews show in the timeline: each note sits under the agent's work with the
  advisor's name and its severity (Nit, Concern, Blocker) and is found by Find in Thread. A
  review that arrives after the turn ended joins that turn instead of vanishing.
- A finished turn whose answer was checked (an advisor review or omp's auto-double-check sent
  the agent back to work) ends with its first answer, the recap, and the changed files under it.
  Below it, "2 checks after this answer" lists each check (advisor and severity, or
  Double-check) with up to four lines of the agent's reply, so a correction such as "that
  changes my earlier conclusion" shows without opening it; click it to open the notes, the
  later answers and, with "Worked for …" open, their work. Before, the last check's reply ended
  the turn and the recap sat above it among the other answers. Expand All Work opens the checks
  too, and Find in Thread searches them while it has a query. Stopped or failed turns, and turns
  a background job woke, keep every answer visible.
- When omp writes a final recap after the checks (the `auto-double-check` extension's
  `auto-recap` pass), that recap ends the turn below "2 checks after this answer" and carries the
  changed files, so the last message reads as the turn's answer; before, it was hidden inside the
  closed checks.
- omp threads whose conversation holds a cut-off emoji or icon glyph no longer stall for a
  minute at the end of every turn: Stop ends the turn right away again, and replies to
  messages sent during that minute no longer go missing.
- A message sent just as the agent finishes starts a new turn instead of steering into the
  ending one, where its answer went missing.
- Selecting text in a chat message highlights exactly the selected lines; a selection over
  several lines no longer draws bands between them or skips lines.
- omp slash commands typed in the composer (`/usage`, `/session`, `/context`, `/tools`, …) now show
  their output in the thread instead of ending the turn with nothing visible.
- The composer's `/` menu lists omp's commands and skills right after launch, in drafts and in
  threads that haven't sent a message since, instead of only the app's `/compact` row.
- The composer's buttons (attach, model, reasoning/permissions, send) and its text area take clicks again; the composer's outline was swallowing them.
- Clicking a composer chip whose picker is open now closes the picker instead of reopening it.
- Scrolling a list (model picker, menus, palette, timeline) with the pointer resting on it no
  longer leaves rows highlighted after they scroll away from the pointer.
- The composer's `/` menu opens and filters instantly with omp's full command and skill list
  (140+ entries); it used to stall for about a second on every keystroke. Long pickers (models,
  branches, projects) build only the rows on screen too.
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
