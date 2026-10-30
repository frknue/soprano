# Soprano Agents

**A native macOS app for coding agents, in the Soprano family.**

Soprano Agents gives the `codex` and `claude` CLIs the look and feel of
[T3 Code](https://github.com/pingdotgg/t3code): a thread inbox on the left, a centered chat lane
with a floating composer, collapsible work logs, approvals and questions inline, per-turn diffs
from hidden git checkpoints, worktrees, a terminal drawer and a diff panel on the right. It is a
Swift 6 / AppKit app, not a web view, and it talks to the agent CLIs directly: there is no server.

## Requirements

- macOS 14 or later.
- At least one agent CLI, installed and signed in:
  - **Codex**: the `codex` CLI (`codex login` once). Soprano Agents runs `codex app-server`.
  - **Claude Code**: the `claude` CLI (run `claude` once to sign in). Soprano Agents runs
    `claude -p` with the stream-json protocol.
- `git` for checkpoints, diffs and worktrees; `gh` for creating pull requests.

Apps started from the Dock get a minimal `PATH`, so Soprano Agents also looks in
`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.bun/bin` and `~/.cargo/bin`. If a CLI
lives elsewhere, set its path in **Settings › Providers** (`providers.codexPath` /
`providers.claudePath`). The same page shows each provider's version, account and health.

## Install and build

Homebrew Swift with the Command Line Tools SDK:

```bash
export DEVELOPER_DIR=/Library/Developer/CommandLineTools PATH="/opt/homebrew/opt/swift/bin:$PATH"
./scripts/install.sh            # release build → /Applications/Soprano Agents.app
swift build && swift test       # development
./scripts/dev.sh --build-only   # .build/debug/Soprano Agents Dev.app (separate data)
```

The installer never restarts a running Soprano Agents; the update applies on the next launch.

## Using it

1. Add a project (**File › Add Project…**) or start without one (`⌃⌘N`).
2. Pick a model (`⇧⌘M`), permissions (`⇧⌘A`) and workspace (`⇧⌘X`: current checkout or a
   new worktree), type, and press Return.
3. While the agent works, sending again steers the running turn (or queues, per
   **Settings › General › Follow-up behavior**); `⌘↩` does the other one.
4. Approve or decline commands and file changes inline; answer the agent's questions in the
   composer.
5. Open a turn's diff from its changed-files card, or the whole thread's with `⌘D`. "Edit from
   here" rewinds the thread (and optionally the files) to before that turn.

`⌘K` opens the command palette: every action, recent threads, projects and settings pages, with
fuzzy search; `>` lists actions only. When the app is in the background, finished, failed and
waiting threads post a notification, and the Dock icon counts threads waiting for you.

## Keyboard shortcuts

Every shortcut can be changed in **Settings › Keybindings** (Record, Off, Reset) or in
`settings.json`. Shortcuts marked *not terminal* don't fire while the terminal drawer has focus.

| Action | Shortcut | Where |
|---|---|---|
| Command Palette | `⌘K` | everywhere |
| Settings | `⌘,` | everywhere |
| Toggle Sidebar | `⌘B` | everywhere |
| Toggle Thread Details | `⇧⌘B` | not terminal |
| Toggle Terminal Drawer | `⌘J` | everywhere |
| Toggle Right Panel | `⌃⌘B` | everywhere |
| New Thread | `⌘N`, `⇧⌘O` | not terminal |
| New Thread in Current Project | `⇧⌘N` | not terminal |
| New Thread Without a Project | `⌃⌘N` | not terminal |
| Previous / Next Thread | `⇧⌘[` / `⇧⌘]` | everywhere |
| Go to Thread 1–9 | `⌘1` … `⌘9` | everywhere |
| Settle Thread | `⇧⌘S` | not terminal |
| Pin Thread | `⇧⌘P` | not terminal |
| Rename Thread | `F2` | sidebar |
| Copy Thread Reference | `⇧⌘C` | not terminal |
| Find in Thread | `⌘F` | not terminal |
| Jump to Latest | `⌘↓` | timeline |
| Focus Composer | `⌘L` | everywhere |
| Model Picker | `⇧⌘M` | not terminal |
| Reasoning Effort | `⇧⌘E` | not terminal |
| Permissions | `⇧⌘A` | not terminal |
| Workspace | `⇧⌘X` | not terminal |
| Branch | `⇧⌘G` | not terminal |
| Toggle Plan Mode | `⇧⇥` | composer |
| Steer or Queue (the other one) | `⌘↩` | composer |
| Toggle Diff | `⌘D` | not terminal |
| New Terminal | `⌘N` | terminal |
| Close Terminal | `⌘W` | terminal |
| Open in Editor | `⌘O` | everywhere |

Unbound by default (bind them in Settings): Open settings.json, Add Project, Archive / Delete
Thread, Search Threads, Interrupt, Commit, Push, Create PR.

`⌃A` starts a prefix chord (`prefix+p` = `⌃A`, then `P`); the prefix key and its timeout are
settings. Chords with `⌥` are left alone so they keep typing characters on layouts that need
them.

## Settings

Settings live in `~/.config/soprano-agents/settings.json` (JSON with comments; honors
`XDG_CONFIG_HOME`, and `SOPRANO_AGENTS_CONFIG` overrides the full path). The file is created with
every key commented on first launch, saved changes apply immediately, and bad values are ignored
with a warning shown on **Settings › General**. The settings screen (`⌘,`) writes the same file,
keeping your comments.

| Key | Default | |
|---|---|---|
| `theme` | `"t3"` | `t3` (follows macOS), `t3-light`, `t3-dark`, `soprano` (follow Soprano), or a Soprano theme id |
| `agents.defaultProvider` | `"codex"` | `codex` or `claude` |
| `agents.defaultModel` | provider default | model id |
| `agents.defaultRuntimeMode` | `"full-access"` | `approval-required`, `auto-accept-edits`, `auto`, `full-access` |
| `providers.codexPath`, `providers.claudePath` | found on `PATH` | executable paths |
| `textGeneration.provider` / `.model` / `.titles` | `codex` / provider default / `true` | titles, commit messages, branch names |
| `worktrees.directory` | `~/.soprano-agents/worktrees` | new worktrees go to `<directory>/<repo>/<branch>` |
| `worktrees.branchPrefix` | `"soprano"` | `soprano/fix-login-error` |
| `chat.followUp` | `"steer"` | `steer` or `queue` |
| `chat.width` | `"normal"` | `normal`, `wide`, `full` |
| `notifications.enabled` / `.sound` | `true` / `true` | background notifications |
| `editor.app` | first installed | `cursor`, `vscode`, `zed`, `xcode`, `finder`, … |
| `keybindings.prefixKey` / `.prefixTimeoutMs` | `"a"` / `1500` | prefix chord |
| `keybindings.bindings` | `{}` | `"<command id>": "cmd+shift+p"`, `["j", "prefix+p"]`, or `null` to unbind |

## Data

- Threads, projects and attachments: `~/Library/Application Support/Soprano Agents/`
  (`threads/`, `projects.json`, `attachments/`). The dev build uses `Soprano Agents Dev`;
  `SOPRANO_AGENTS_DATA_DIR` overrides the location.
- Checkpoints: hidden refs `refs/soprano-agents/checkpoints/<thread>/<turn>` in each project's
  repository. They never touch your index, HEAD or branches.
- Worktrees: `~/.soprano-agents/worktrees/<repository>/<branch>` unless configured otherwise.
- Window size and panel widths: the app's `UserDefaults`.

## License

MIT. See [LICENSE](LICENSE).
