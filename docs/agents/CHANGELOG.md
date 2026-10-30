# Changelog

All notable changes to Soprano Agents are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Command palette (`⌘K`): actions with their shortcuts, recent threads, projects and settings pages, fuzzy search with highlighted matches, `>` for actions only, "New thread in..." per project, `⌘1`–`⌘9` to pick a row.
- Settings screen (`⌘,`): General, Providers, Text generation, Worktrees, Notifications, Keybindings (record, turn off or reset any shortcut), Archive (unarchive or delete threads) and About; every change is written to `~/.config/soprano-agents/settings.json`.
- Notifications when a thread completes, fails, or needs approval or input while the app is in the background (`notifications.enabled`, `notifications.sound`), and a Dock badge counting threads waiting for you.
- T3 Code–style confirmation dialogs (Return confirms, Esc cancels).
- App icon: a speech bubble with typing dots.
