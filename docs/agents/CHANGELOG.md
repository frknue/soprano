# Changelog

All notable changes to Soprano Agents are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Thread inbox sidebar: search (titles, branches, messages), project filter (Shift-click picks
  several), Add project, New thread (⌘N, ⇧⌘N, ⌃⌘N), Pinned and Active cards with live status
  pills, Working and Settled shelves, inline rename (double-click or F2), thread menu (pin,
  settle, rename, regenerate title, mark unread, copy, archive, delete), ⇧⌘[ / ⇧⌘] and ⌘1–⌘9
  navigation with hints while ⌘ is held, ⇧⌘S settle, ⇧⌘P pin, ⇧⌘C copy thread reference.
- Chat header with the project / thread breadcrumb and the thread details, terminal and right
  panel toggles.
- Command palette (`⌘K`): actions with their shortcuts, recent threads, projects and settings pages, fuzzy search with highlighted matches, `>` for actions only, "New thread in..." per project, `⌘1`–`⌘9` to pick a row.
- Settings screen (`⌘,`): General, Providers, Text generation, Worktrees, Notifications, Keybindings (record, turn off or reset any shortcut), Archive (unarchive or delete threads) and About; every change is written to `~/.config/soprano-agents/settings.json`.
- Notifications when a thread completes, fails, or needs approval or input while the app is in the background (`notifications.enabled`, `notifications.sound`), and a Dock badge counting threads waiting for you.
- T3 Code–style confirmation dialogs (Return confirms, Esc cancels).
- App icon: a speech bubble with typing dots.
- Right panel Diff (⌘D): review the whole thread, the latest turn, any turn or uncommitted
  changes, stacked or split, with line wrapping, whitespace toggle, collapsible files, a file
  tree and Maximize panel.
- Terminal drawer (⌘J): login-shell terminals per thread in the thread's working directory;
  ⌘N adds one, ⌘W closes one, drag the top edge to resize.
- Thread details card (⇧⌘B): open the workspace in your editor (⌘O, `editor.app`), run project
  scripts in the terminal, copy the branch name, commit / push / create a PR with T3 Code's
  quick action and the "Commit changes" dialog, and open uncommitted changes.
- Message timeline in T3 Code's style: user bubbles with "Edit from here", Markdown answers with
  code blocks and tables, "Worked for …" folds over each turn's work log, live "Working for" row,
  inline approvals, plan and task cards, changed-files cards that open the diff, and Find in Thread
  (⌘F). ⌘↓ jumps to the latest message.
