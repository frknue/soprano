# Soprano Rust rewrite — plan and contract

Goal: replace the Swift/AppKit app with a Rust workspace that runs on macOS, Linux and
Windows, looks like Herdr (<https://github.com/herdrdev/herdr-app>), and otherwise behaves
exactly like the Swift app: same features, keybindings, CLI subcommands, environment
variables, `settings.json` format, agent integrations, persistence keys, notifications, and
file locations.

The Swift sources were the spec during the port and are deleted from the tree; they live in
git history (last Swift release: tag `v0.6.0`). The per-crate API notes in `apis/` and the
parity reviews in `reviews/` cite Swift files by path at that state.

## Stack

| Concern | Choice | Why |
|---|---|---|
| UI | `gpui-pre` =0.3.12 (Zed's GPUI) + `gpui-component` =0.9.1 | Herdr's toolkit; GPU-rendered on all three OSes; gpui-component brings input/code editor, tree, list, dialogs, popovers, menus, markdown, diff, notifications |
| Terminal emulation | libghostty-vt (the `ghostty` submodule pinned to `291fd050`, Herdr's pin) via `crates/ghostty-sys` | Same engine as before, cross-platform; Herdr renders it in GPUI the same way |
| PTY | `portable-pty` | ConPTY on Windows, openpty elsewhere |
| Web view | `gpui-webview` 0.9.1 (wry: WKWebView / WebView2 / WebKitGTK) | Browser panes |
| Markdown | `pulldown-cmark` (GFM tables, task lists) | Reader pane, chat answers |
| Syntax colors | port of `CodeSyntaxHighlighter.swift` (same token rules, theme colors) | Identical coloring |
| File watching | `notify` | Explorer, editor reloads, config reloads, git refresh |
| IPC CLI ↔ app | `interprocess` local sockets (Unix socket / Windows named pipe), JSON lines | Replaces macOS `DistributedNotificationCenter` |
| Notifications | `notify-rust` (Linux/Windows), `UNUserNotificationCenter` via objc2 on macOS | Native banners |
| Secrets | `keyring` | Replaces the Keychain CLI where Soprano stores logins |

Toolchain: stable Rust ≥ 1.99 (`rust-toolchain.toml`), Zig 0.16 for libghostty-vt
(`brew install zig@0.16`; `crates/ghostty-sys/build.rs` finds the Homebrew keg or `$ZIG`).

```bash
cargo build                # debug build (com.soprano.dev identity)
cargo test                 # all crates
cargo test -p soprano-model split_node
cargo run -p soprano       # launches the dev app — only when the user asks for a launch
```

## Crates

Dependency order is top to bottom; a crate depends only on crates above it.

| Crate | Ports (Swift) | gpui? |
|---|---|---|
| `ghostty-sys` | libghostty-vt bindings (adapted from Herdr, Apache-2.0) | no |
| `soprano-platform` | app identity (release/dev), data/resource paths, `StateStore` (replaces `UserDefaults`, same `soprano-*` keys, imports the Swift app's defaults on first Mac start), user shell, open/reveal/trash | no |
| `soprano-config` | `Config/*` (JSONCText, ConfigFile, SopranoConfig, ConfigStore, KeyChord, DefaultKeybindings, DefaultAgents, AgentCatalog, Theme palettes as data), `Models/AgentProfile`, `KeyBinding`, `AppSettings`, `Automations/Automation.swift` (the config entry type), `Utilities/AppVersion` | no |
| `soprano-git` | `GitChanges`, `GitStatusReader`, `GitBranchMonitor`, `SopranoGitLauncher` | no |
| `soprano-files` | `FileExplorerModel`, `FileExplorerOperations`, `FileSystemWatcher` | no |
| `soprano-ipc` | CLI side of `MarkdownCommand`, `BrowserAutomationCommand` (`BrowserCommand`), `PaneNavigationCommand`, `AgentEventCommand`, `LaunchDispatch`, `CallerWorkingDirectory`; the socket transport and the app-side listener | no |
| `soprano-model` | `Models/*` layout and workspace types (SplitNode, PaneState, WorkspaceWindowState, WorkspaceSession, TerminalSessionState, TerminalTitle, AgentInstance/AgentStatus), `AgentManager` (+Dashboard) as `Workspace`, `SessionManager`, `KeybindingManager` state machine | no |
| `soprano-agents` | transcript decoders (Claude, Codex, omp, OpenCode), `AgentTimeline`, `AgentConversation`, `AgentDashboardSnapshot`, `AgentTranscriptStore`, `OpenCodeTranscriptReader`, `AgentNotificationManager` logic (status state machine, banner text), `ChatTurns`, `TranscriptThread` | no |
| `soprano-chat` | `Chat/*`: `JSONRPCConnection`, `JSONValue`, `AgentChatSession` (ACP), `ACPTurnBuilder`, `OmpEditPreview` | no |
| `soprano-accounts` | `Accounts/*` | no |
| `soprano-automations` | `Automations/*` except the config type | no |
| `soprano-term` | `Terminal/*`: libghostty-vt terminal + PTY + GPUI terminal element (adapted from Herdr's `terminal.rs`/`vt.rs`), copy mode, input encoding, clipboard confirmation, drops, shell integration, env export | yes |
| `soprano-ui` | Herdr-style design system: theme tokens from Soprano palettes, typography, icons, shared widgets (status pill, monogram, keycap, buttons, rows, dialogs, menus) | yes |
| `soprano` (bin) | `main.rs` CLI dispatch, the app: window, sidebar, tab rows, split tree, pane header, status bar, command palette, settings, dashboard, chat views, explorer, source control, editor, diff, Markdown reader, browser pane, automations UI | yes |

`resources/` holds what the Swift app shipped in `Sources/Soprano/Resources` and
`Support/AgentHooks` (hook templates, OpenCode/omp plugins, zsh integration, copy-mode
config), plus fonts, icons, and Ghostty's shell-integration scripts.

## Conventions

- Port behavior, not AppKit structure. Non-UI logic ports 1:1 into the non-gpui crates with
  the same names in Rust style (`AgentManager.createWindow` → `Workspace::create_window`).
- Every Swift test that covers ported logic is ported as a Rust test with the same intent and
  a sentence-style snake_case name (`fn closing_the_last_pane_of_a_tab_closes_the_tab()`).
  Tests of AppKit view details are replaced by tests of the equivalent logic where one exists.
- Persisted state goes through `soprano_platform::StateStore` under the Swift key names;
  types that persist accept a `StateStore` so tests use `StateStore::in_memory()`.
- `settings.json` stays the source of truth; formats and key names are unchanged.
- Environment exported to panes is unchanged (`SOPRANO_BIN`, `SOPRANO_PANE_ID`,
  `SOPRANO_TAB_ID`, `SOPRANO_APP_PID`, …) plus `SOPRANO_SOCKET` (the IPC endpoint).
- Platform differences: gate per OS only where the OS really differs; keep it in one small
  module per concern (or in `soprano-platform`), not `#[cfg]` spread through shared code.
- Errors: `anyhow` in app code, typed errors where callers branch on them. No panics on bad
  user data (a malformed `settings.json` never stops the app).
- No `unwrap()` on I/O or parsing of external data. `expect` only for invariants.
- Concurrency: GPUI's executors in UI crates; non-UI crates are synchronous or use std
  threads + channels, so they test without an app.
- Style: `cargo fmt` (max width 110, see `rustfmt.toml`), `cargo clippy` clean.

## UI: Herdr's look, Soprano's model

Soprano's model is session → logical windows → layout tabs → split panes → pane tabs. Herdr's
regions carry it:

| Herdr region | Soprano content |
|---|---|
| Brand row (traffic lights, name, search, sidebar toggle) | session selector (`Session 1 ⌄`), `⌘F` window search, `⌘E` sidebar toggle |
| Sidebar "Spaces" list | the active session's logical windows; under each, its panes grouped by tab (titles, agent status pills, running-command marks, `⌃⇧` pane hints, window number hints while Control is held), `+` menu |
| Sidebar "Agents" list | agents across all windows, grouped Needs you / Working / Ready / Stopped; opens the Agent Dashboard |
| Sidebar footer | Settings, Automations, Agent Dashboard |
| Top tab row | the active window's layout tabs (badges, `+`, close); window tabs row above it when `hideWindowTabs` is false; right end: `+`, Files, Changes toggles |
| Pane chrome (rounded, bordered, accent focus ring, 30px header) | pane header: agent/terminal icon, title, cwd, status pill, pane tabs, `+` menu, close |
| Right panel (Files / Changes) | File explorer / Source control |
| Status bar | location `session › window › pane · Tab n`, needs-you count, account usage, uptime, `⌘P Commands`, prefix indicator |
| Picker | command palette, session/window/project pickers |

Exact measurements, colors and type: `docs/rust-rewrite/HERDR-UI.md`. Colors come from the
active Soprano theme (Folio Paper/Ink and the seven dark themes) mapped onto Herdr's token
roles.
