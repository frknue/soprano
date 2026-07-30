# Changelog

All notable changes to Soprano are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The number
in each released heading matches `CFBundleShortVersionString` in `Support/Info.plist`,
which is the single source of truth for the version shown in **Settings ▸ About**.

## [Unreleased]

### Added

- The Agent Dashboard now shows the selected agent's live terminal and can reply
  without leaving the dashboard, with **Open**, **Stop**, and **Restart** actions for
  Codex, Claude Code, OpenCode, and custom terminal agents.

## [0.5.0] - 2026-07-30

### Added

- **Settings ▸ General ▸ Appearance** can hide the macOS window bar and its controls,
  letting panes use the full window; the standard bar remains visible by default.

## [0.4.0] - 2026-07-29

### Added

- A live GitHub-flavored Markdown reader, opened from **Open Markdown…**,
  `soprano <file.md>`, or `soprano markdown <file>`, reloads as files change, follows
  local document links, and restores with the workspace without modifying shell
  configuration.

### Changed

- Pane headers now show the focused z-depth as a highlighted `DEPTH n` badge, and the
  status bar spells out the active depth instead of abbreviating it.

### Fixed

- Pane creation in one window is no longer blocked when other windows collectively
  reach 20 panes; each logical window now has its own capacity.

## [0.3.1] - 2026-07-28

### Fixed

- Homebrew and disk-image installations now open successfully instead of crashing while
  loading Soprano's bundled terminal configuration.

## [0.3.0] - 2026-07-27

### Added

- Universal release disk images and a Homebrew cask for
  `brew install --cask frknue/tap/soprano`; until the project has Apple Developer
  membership, macOS requires a one-time **Open Anyway** approval.
- **Settings ▸ General ▸ Notifications**: a *Play a sound* toggle, and a line reporting
  whether macOS is actually allowing banners. When permission has been refused it says so
  and offers **Open System Settings** — macOS only ever prompts once, so an app that has
  been denied cannot ask again and previously just went quiet with no explanation.

- Soprano is now open source under the MIT license. The packaged app carries its own
  `LICENSE` plus Ghostty's in `Soprano.app/Contents/Resources/`.

- Soprano is configured by `~/.config/soprano/settings.json` (honors `XDG_CONFIG_HOME`;
  `SOPRANO_CONFIG` overrides the path). The file is created on first launch, seeded with
  your existing settings, and documents itself in comments. Saving it applies
  immediately — no restart.
- Custom agents: define your own launcher under `agents` — command, args, env, cwd or a
  `launchScript`, color, and a `launchKey` shortcut — or reuse a built-in id to patch
  that profile. Custom agents appear in the sidebar **+** menu and in
  **Settings ▸ Agent Profiles** like built-in ones.
- Rebind any shortcut by action id under `keybindings.bindings` (`"new-browser":
  "cmd+shift+b"`), or set one to `null` to turn it off. **Settings ▸ Keyboard Shortcuts**
  lists every id and marks the ones you changed.
- **Commands ▸ Open settings.json**, an *Open settings.json* command in `⌘P`, and
  Open/Reveal/Reload buttons in **Settings ▸ General**.
- `⌘F` opens a window switcher that searches window titles and nested pane details,
  prioritizing window-title matches.
- Agent Dashboard: monitor live agent states across every logical window, see working,
  input-needed, and error totals, and jump directly to an agent from the sidebar chart
  button, **Commands** menu, or the configurable `⇧⌘D` shortcut; navigate with `J` / `K`
  or the arrow keys, open with `Return`, and close with `Esc`.
- `⌃A ⇧L` jumps to the most recently active logical window and toggles back when pressed
  again.
- Dracula, Solarized Dark, Nord, Tokyo Night, and Atom One Dark themes.

### Changed

- Development, installation, and legacy run scripts now live together under `scripts/`.
- Notifications are **silent by default**. A pane that wants you already shows a banner,
  an unread ring, and a status, and a chime on every finished turn gets old fast. Turn it
  back on in **Settings ▸ General ▸ Notifications** or with `notifications.sound` in
  `settings.json`.
- Notifications now quote what the agent actually said — *Needs input — Drop the legacy
  column? [y/n]* — instead of a fixed phrase like *Approval or input required*. Codex,
  Claude Code, and OpenCode each hand their payload over differently and all three are
  read; when one carries no readable message the previous wording is still used.
- Pane resizing now uses `⌃A H/J/K/L` without Shift; pane-tab cycling moves to
  `⌃A <` / `⌃A >`.
- The settings screen now edits `settings.json` directly rather than a private
  preferences store, preserving your comments and key order, and it reflects edits made
  to the file while it is open.
- **Settings ▸ About** reports the version declared by the packaged bundle instead of a
  hardcoded string, and shows `dev` for unbundled `swift run` launches.

### Fixed

- Collapsed window groups in the sidebar now stay collapsed after Soprano restarts or
  their saved session is reopened.
- Claude Code's *idle prompt* notifications now reach Soprano. The launch-scoped hook
  matched only permission prompts, so an agent that simply finished and sat waiting never
  fired one — the most common reason a pane wants you.
- **Settings ▸ General** no longer discards edits to *Prefix Timeout* and *Resize Step*
  in locales that group digits, where the displayed `1'500` failed to parse and silently
  reverted.
- Rebinding **Command Palette**, **Open Project…**, or **Find Window…** now takes effect:
  their Commands-menu shortcuts follow `settings.json` instead of staying hardcoded.
- Changing the theme now updates open terminals (including their background and ANSI
  palette) and repaints pane backgrounds and pane-header titles.
- Reloading keybindings no longer strands the status bar in `PREFIX`, and no longer
  stops pane-navigation passthrough from tracking closed panes.
- Selecting a pane in the sidebar now reveals it when an expanded inner workspace was
  previously occupying its region.
- Selecting an exact agent tab from a notification or the Agent Dashboard now reveals
  its hidden depth branch before focusing it.
- A maximized pane now stays maximized when moving into or out of its depth workspace.
- Terminal title, working-directory, and browser URL updates no longer rebuild unrelated
  UI, and hidden terminal surfaces pause rendering to reduce multi-pane CPU and GPU use.

## [0.2.0] - 2026-07-25

First entry in this changelog. It summarizes the native Swift + AppKit application as it
stands today, reconstructed from the commit history — earlier work was never tagged or
released.

### Added

- Tiling panes backed by a recursive split tree, with symbolic `⌃A -` / `⌃A |` splits,
  prefix resizing, and `⌃A M` maximize.
- Direct `⌃H/J/K/L` pane navigation that wraps at layout boundaries.
- Logical windows with per-pane tabs, numbered `⌃1`…`⌃9` selection, contextual names, and
  rename and close shortcuts.
- Window depth: any pane can open a private inner workspace on the window's z-axis with
  `⌃A I` / `⌃A O`, keeping sibling panes visible, live, and independent.
- Built-in launchers for Codex (`⌘1`), Claude Code (`⌘2`), and OpenCode (`⌘3`) that
  install lifecycle hooks per launch without changing global agent configuration.
- Pane status reporting — `STARTING`, `WORKING`, `READY`, `NEEDS INPUT`, `ERROR`,
  `STOPPED` — in the pane header, sidebar, and status bar.
- Native macOS notifications for unfocused panes, subtitled `window ▸ pane`, with grouped
  banners, blue unread rings, and click-to-focus.
- Hook templates in `Support/AgentHooks/` so agents started from a shell, alias, or script
  are recognized too.
- libghostty terminal surfaces with full keyboard routing, sided modifier handling, and a
  clipboard confirmation policy for paste.
- Vim-style terminal copy mode (`⌃A [`) with motions, viewport and scrollback jumps,
  character and line selection, and clipboard yank.
- Drag and drop of files, folders, URLs, and macOS screenshot thumbnails into terminals as
  shell-safe paths.
- Terminal zoom controls (`⌘=` / `⌘-` / `⌘0`) and working directory inheritance for new
  panes and windows.
- Nested pane navigation through the `navigate-pane` and `navigation-passthrough` CLI
  subcommands, including tmux boundary handoff scoped to the issuing process, pane, and
  tab.
- Native WebKit browser panes (`⌘B`) with an address bar, back/forward/reload, and local
  development address handling.
- Scriptable browser automation over `"$SOPRANO_BIN" browser`, with interactive snapshots
  that assign ephemeral element refs for use as selectors.
- Sidebar pane list with per-pane git branch, spawn menu, sessions footer, Control-held
  jump hints, an active-location rail, and a resizable width that persists across launches.
- Command palette (`⌘P`), plus a project launcher and search (`⇧⌘P`) over configured
  project directories.
- Workspace persistence with restore on launch, and named sessions (`⇧⌘S`).
- Settings embedded in the main window: General, Keyboard Shortcuts, Agent Profiles, and
  About.
- Gruvbox Dark and Catppuccin Mocha themes.
- Configurable keybindings with a `⌃A` prefix, adjustable prefix timeout, and resize step.
- Packaging workflow: `dev.sh` builds and launches an isolated `com.soprano.dev` bundle,
  `install.sh` installs the release build, and both embed Ghostty's runtime resources.
- Stable local code signing identity, so macOS keeps notification permission across
  rebuilds.
- Application icon.

### Changed

- Rewritten as a native macOS application (Swift + AppKit + libghostty), replacing the
  earlier Tauri/React/Rust prototype.
- Pane selection moved behind the prefix so unmodified alphabetic Control chords stay
  available to the terminal.
- Contributor documentation consolidated into `AGENTS.md`, with `CLAUDE.md` as a symlink.
- README reorganized around evaluating and first-running the app.

### Fixed

- Keyboard focus freezes and command key-equivalent routing, including sided modifier
  release transitions.
- Terminal surfaces destroyed reentrantly, terminal caches keyed by the exact target, and
  PTY process leaks that accumulated with many panes.
- Workspace restore and split resizing, orphan panes pruned on restore, and cold restore
  cache replacement.
- Sibling panes disappearing when entering pane depth, and depth workspaces leaking into
  one another.
- Main window size preserved across settings transitions and screen-aware on first launch.
- Notification authorization requested at launch rather than on first delivery.
- Ghostty runtime resources bundled into the app, so themes and terminal behavior no
  longer depend on the launch environment.
