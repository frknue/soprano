# Soprano Agents

**Soprano's chat window for coding agents.**

Soprano Agents gives the `omp` CLI (oh-my-pi) a native home inside Soprano, colored by
Soprano's theme: a thread inbox on the left, a centered chat lane with a floating
composer, collapsible work logs, approvals and questions inline, per-turn diffs
from hidden git checkpoints, worktrees, a terminal drawer and a diff panel on the right. It is
part of the Soprano app, Swift 6 / AppKit rather than a web view, and it talks to `omp`
directly: there is no server.

Open it in Soprano with `⇧⌘A`, **Commands ▸ Soprano Agents** or `⌘P` → *Soprano Agents*;
`⇧⌘T` (**Window ▸ Terminals**) goes back to the terminal window. It used to be a separate app,
*Soprano Agents.app*; see [Coming from the standalone app](#coming-from-the-standalone-app).

## Requirements

- The `omp` CLI ([oh-my-pi](https://github.com/can1357/oh-my-pi)) with at least one model
  provider logged in (`omp login`). Soprano Agents runs `omp --mode rpc-ui`, omp's host-UI
  protocol, so omp's tool approvals and its `ask` tool show up inline. Every model omp knows (its
  `/model` list across Anthropic, OpenAI, Copilot, OpenRouter, …) is in the model picker;
  "configured" is whatever omp itself defaults to.
- `git` for checkpoints, diffs and worktrees; `gh` for creating pull requests.

Apps started from the Dock get a minimal `PATH`, so Soprano Agents also looks in
`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.bun/bin` and `~/.cargo/bin`. If `omp`
lives elsewhere, set its path in **Settings › Providers** (`threads.providers.ompPath`). The same
page shows omp's version and health.

## Coming from the standalone app

- Threads, projects and attachments stay where the standalone app kept them, so every
  thread, its attachments and its checkpoints carry over.
- The first time the window opens, Soprano copies `~/.config/soprano-agents/settings.json`
  into the `threads` object of Soprano's settings.json (its project folders into Soprano's
  `projectDirectories` when Soprano has none) and leaves the old file alone.
- Accounts are Soprano's: the account button and **Settings › Accounts** show the same
  logins as the terminal window.
- `/Applications/Soprano Agents.app` is no longer updated; delete it once Soprano has your
  threads.

## Using it

1. Open a project (`⇧⌘K`: your projects plus the subfolders of the project folders in
   **Settings › General**, e.g. `~/git/private`; **Choose Folder…** for any other) or start
   without one (`⌃⌘N`).
2. Pick a model (`⇧⌘M`), permissions (`⇧⌘A`) and workspace (`⇧⌘X`: current checkout or a
   new worktree), type, and press Return.
3. While the agent works, sending again steers the running turn (or queues, per
   **Settings › General › Follow-up behavior**); `⌘↩` does the other one.
4. Approve or decline commands and file changes inline; answer the agent's questions in the
   composer.
5. Open a turn's diff from its changed-files card, or the whole thread's with `⌘D`. "Edit from
   here" rewinds the thread (and optionally the files) to before that turn.
6. The right panel (`⌘L`) keeps tabs per thread, as in T3 Code: Diff, Files (`⇧⌘F`: browse and
   search the thread's workspace; ignored files stay out) with a read-only, syntax-colored tab per
   opened file — Markdown files open in Soprano's reader (links to other files open their tab,
   `⇧⌘V` or the eye button shows the source) —, and terminals (`⇧⌘J`) next to the bottom
   drawer's. `+` adds a surface; with every tab closed, "Open a surface" offers Terminal (`T`),
   Files (`F`) and Diff (`D`).
7. The ring next to Send shows how full the context window is; click it to compact the
   conversation (or send `/compact`). Type `/` at the start of a line for omp's commands and
   skills: ↑/↓ choose, Enter or Tab insert, Esc closes.
8. Several Claude and Codex accounts for omp, as in Soprano: the account button at the bottom of
   the sidebar (tinted near a limit; `⌘U` for details) and **Settings › Accounts** to add logins
   and let omp prefer one or balance across them.
9. Statistics (`⇧⌘U`, or the chart button next to Settings), as in T3 Code's Usage page: omp's
   tokens and estimated API-equivalent cost over 24h, 7d, 30d, 90d or all time, with a chart per
   hour, day, week or month and breakdowns by model (click one to filter), project and agent. It reads
   omp's own usage records (`omp stats`), so every omp session on this Mac counts.

`⌘K` (or `⌘P`) opens the command palette, Soprano's own: every action with its shortcut, threads,
projects and settings pages. When the app is in the background, finished, failed and
waiting threads post a notification, and the Dock icon counts threads waiting for you.

## Keyboard shortcuts

Every shortcut can be changed in **Settings › Keybindings** (Record, Off, Reset) or in
`settings.json` under `threads.keybindings`. They apply while the Soprano Agents window is in
front; the terminal window keeps its own. Shortcuts marked *not terminal* don't fire while a
terminal (in the drawer or a right-panel tab) has focus.

| Action | Shortcut | Where |
|---|---|---|
| Command Palette | `⌘K`, `⌘P` | everywhere |
| Show Terminals (Soprano's terminal window) | `⇧⌘T` | everywhere |
| Open Project… | `⇧⌘K` | everywhere |
| Settings | `⌘,` | everywhere |
| Toggle Sidebar | `⌘E` | everywhere |
| Toggle Thread Details | `⇧⌘B` | not terminal |
| Toggle Terminal Drawer | `⌘J` | everywhere |
| Toggle Right Panel | `⌘L` | everywhere |
| New Thread | `⌘N`, `⇧⌘O` | not terminal |
| New Thread in Current Project | `⇧⌘N` | not terminal |
| New Thread Without a Project | `⌃⌘N` | not terminal |
| Previous / Next Thread | `⇧⌘[` / `⇧⌘]` | everywhere |
| Go to Thread 1–9 | `⌃1` … `⌃9` | everywhere |
| Settle Thread | `⇧⌘S` | not terminal |
| Pin Thread | `⇧⌘P` | not terminal |
| Rename Thread | `F2` | sidebar |
| Copy Thread Reference | `⇧⌘C` | not terminal |
| Find in Thread | `⌘F` | sidebar, timeline, composer |
| Jump to Latest | `⌘↓` | timeline |
| Toggle Detailed Work Log | `⇧⌘D` | not terminal |
| Focus Composer | `⇧⌘L` | everywhere |
| Model Picker | `⇧⌘M` | not terminal |
| Reasoning Effort | `⇧⌘E` | not terminal |
| Permissions | `⇧⌘A` | not terminal |
| Workspace | `⇧⌘X` | not terminal |
| Branch | `⇧⌘G` | not terminal |
| Steer or Queue (the other one) | `⌘↩` | composer |
| Toggle Diff | `⌘D` | not terminal |
| Toggle Files | `⇧⌘F` | not terminal |
| New Terminal in Right Panel | `⇧⌘J` | everywhere |
| Close Tab | `⌘W` | right panel |
| Find in Panel (find bar in a file tab — a Markdown preview switches to its source —, search in Files, else Find in Thread) | `⌘F` | right panel |
| Toggle Markdown Preview (a Markdown file tab's reader or source) | `⇧⌘V` | right panel |
| New Terminal | `⌘N` | terminal (drawer or right-panel tab) |
| Close Terminal | `⌘W` | terminal (drawer or right-panel tab) |
| Open in Editor | `⌘O` | everywhere |
| Open in Soprano Git | `⌃A` → `G` | everywhere |
| Show Usage | `⌘U` | everywhere |
| Statistics | `⇧⌘U` | everywhere |

Unbound by default (bind them in Settings): Open settings.json, Archive / Delete
Thread, Search Threads, Filter Threads by Project, Expand / Collapse All Work, Interrupt, Commit,
Push, Create PR, Toggle Split Diff View, Toggle Diff File Tree, Maximize Right Panel, Search Files,
Compact Conversation, Manage Accounts, Refresh Usage.

`⌃A` starts a prefix chord (`prefix+p` = `⌃A`, then `P`); the prefix key and its timeout are
settings. Chords with `⌥` are left alone so they keep typing characters on layouts that need
them.

## Settings

Settings live in Soprano's `~/.config/soprano/settings.json` (JSON with comments; honors
`XDG_CONFIG_HOME`, and `SOPRANO_CONFIG` overrides the full path), in the object under `threads`.
Saved changes apply immediately, and bad values are ignored with a warning shown on
**Settings › General**. The settings screen (`⌘,`) writes the same file, keeping your comments.
Two settings are Soprano's own: the theme (`theme` and `appearance`, shared by every window) and
the project folders (`projectDirectories`, also used by Soprano's Open Project…).

| Key under `threads` | Default | |
|---|---|---|
| `agents.defaultModel` | omp's configured model | model id `provider/id`, e.g. `anthropic/claude-opus-5-5` |
| `agents.defaultRuntimeMode` | `"full-access"` | `approval-required`, `auto-accept-edits`, `auto`, `full-access` |
| `providers.ompPath` | found on `PATH` | path to the `omp` executable |
| `textGeneration.model` / `.titles` | omp's configured model / `true` | titles, commit messages, branch names, generated with omp |
| `worktrees.directory` | `~/.soprano-agents/worktrees` | new worktrees go to `<directory>/<repo>/<branch>` |
| `worktrees.branchPrefix` | `"soprano"` | `soprano/fix-login-error` |
| `chat.followUp` | `"steer"` | `steer` or `queue` |
| `chat.width` | `"normal"` | `normal`, `wide`, `full` |
| `chat.workLog` | `"detailed"` | `detailed` (every step, edits as diffs, code as it is written) or `minimal`; `⇧⌘D` toggles |
| `notifications.enabled` / `.sound` | `true` / `true` | background notifications |
| `editor.app` | first installed | `cursor`, `vscode`, `zed`, `xcode`, `finder`, … |
| `keybindings.prefixKey` / `.prefixTimeoutMs` | `"a"` / `1500` | prefix chord |
| `keybindings.bindings` | `{}` | `"<command id>": "cmd+shift+p"`, `["j", "prefix+p"]`, or `null` to unbind |

## Data

- Threads, projects and attachments: `~/Library/Application Support/Soprano Agents/`
  (`threads/`, `projects.json`, `attachments/`, and `scratch/<thread>` as the working folder of
  threads without a project), the folder the standalone app used. Threads store attachment
  and scratch paths absolutely, so the folder keeps that name. Development builds of Soprano use
  `Soprano Agents Dev`; `SOPRANO_AGENTS_DATA_DIR` overrides the location.
- Checkpoints: hidden refs `refs/soprano-agents/checkpoints/<thread>/<turn>` in each project's
  repository. They never touch your index, HEAD or branches.
- Worktrees: `~/.soprano-agents/worktrees/<repository>/<branch>` unless configured otherwise.
- An agent, terminal or project script only ever runs in its thread's folder. If that folder is
  gone (a deleted worktree, a moved project), it refuses with "Workspace not found" instead of
  running anywhere else.
- Window size and panel widths: Soprano's `UserDefaults`; whether the window was open when
  Soprano quit, so it reopens on the next launch.

## License

MIT. See [LICENSE](../../LICENSE).
