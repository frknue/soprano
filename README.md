<div align="center">

<img src="app-icon.png" alt="" width="112">

# Soprano

**A native macOS tiling multiplexer for running a room full of AI coding agents.**

Codex, Claude Code, and OpenCode side by side in real GPU-rendered terminals — every
pane says what its agent is doing, and macOS tells you which one is waiting on you.

<img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white">
<img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
<img alt="AppKit, programmatic" src="https://img.shields.io/badge/AppKit-programmatic-2b6cb0">
<img alt="libghostty" src="https://img.shields.io/badge/terminal-libghostty-8f3f71">

</div>

```
┌───────────────────────┬─ Codex ────── WORKING · Z0 ─┬─ Claude Code ─ NEEDS INPUT · Z0 ─┐
│ WINDOWS               │ • editing SplitNode.swift   │ Drop the legacy column? [y/n]    │
│ ▍soprano              │ • 3 files changed           │ >                                │
│ ▍ Codex    ⎇ main     │                             │                                  │
│ ▍ Claude   ⎇ fix/ui • ├─ Terminal 1 ────────────────┴──────────────────────────────────┤
│ ▍ Browser             │ > swift test                                                   │
│  webapp               │ Executed 142 tests, 0 failures                                 │
│   Terminal ⎇ main     │ >                                                              │
├───────────────────────┴────────────────────────────────────────────────────────────────┤
│ soprano ▸ Claude Code · Z0                                     ⌘P commands   ⌃A prefix │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

## Why

One agent is easy. Four is a scheduling problem. They run asynchronously, they all
stop to ask you something eventually, and terminal tabs hide the one that is blocked.
Soprano is built around the question you actually have all day: *which agent needs me
right now?*

- **Panes report their own status.** `STARTING` · `WORKING` · `READY` · `NEEDS INPUT` ·
  `ERROR` · `STOPPED`, driven by real agent lifecycle hooks rather than output scraping.
- **Notifications name the location.** Subtitled `window ▸ pane`; clicking one activates
  Soprano and focuses that exact tab.
- **A real terminal.** Every pane is a [libghostty](https://github.com/ghostty-org/ghostty)
  surface hosted in AppKit. No Electron, no web view, no reimplemented VT parser.
- **Depth.** Any pane can open a private workspace on the window's z-axis, so one pane
  becomes a whole layout while its siblings keep running.
- **A browser your agents can drive.** `⌘B` splits a WebKit pane;
  `"$SOPRANO_BIN" browser click @e1` works from inside any terminal.
- **Layouts that come back.** The last workspace restores on launch, and `⇧⌘S` saves
  named sessions.

## Try it

Fresh clone to installed app, four steps:

```bash
# 1 · Toolchain. Homebrew Swift is required — the system CLT Swift has broken SPM.
brew install swift zig
xcodebuild -downloadComponent MetalToolchain

# 2 · Clone with the ghostty submodule
git clone --recurse-submodules https://github.com/frknue/soprano.git
cd soprano

# 3 · Build libghostty once (a few minutes, needs Xcode's Metal Toolchain)
./scripts/build-ghostty.sh

# 4 · Build the release app into /Applications
./install.sh
```

**Requirements:** macOS 14 Sonoma or newer · full Xcode with the Metal Toolchain
(Command Line Tools alone cannot build libghostty) ·
[Homebrew Swift](https://formulae.brew.sh/formula/swift) 6.2+ ·
[Zig](https://ziglang.org/download/) 0.15.2+.

`lib/` is not tracked, so step 3 is mandatory on a fresh clone — but you only repeat it
when the ghostty submodule moves. To move it, hand the script a ref
(`./scripts/build-ghostty.sh v1.3.1`) and commit the submodule pin: it refreshes the
library, the C header, and the recorded version together, and `swift test` fails if they
ever disagree. Packaging also needs Ghostty's *runtime* resources (themes, shell
integration, terminfo); step 3 produces them, an installed `/Applications/Ghostty.app`
works too, and `SOPRANO_GHOSTTY_RESOURCES_DIR` overrides both. Packaging says which
source it used and warns when that source is a different Ghostty version than the
library Soprano links.

`install.sh` puts the Homebrew toolchain on `PATH` itself, signs the bundle with a
stable local identity so macOS keeps your notification permission across rebuilds, and
replaces `/Applications/Soprano.app` **without** stopping a running instance — the
update applies on the next launch. Install elsewhere with
`SOPRANO_INSTALL_DIR="$HOME/Applications" ./install.sh`.

### The first five minutes

| Press | And |
|---|---|
| `⌘2` | Claude Code launches in the active pane; the header takes its color and starts reporting status |
| `⌃A` then `\|` | Split vertically. `⌃A` is the tmux-style prefix; `-` splits horizontally |
| `⌘1` | Codex starts in the new pane |
| `⌃H` `⌃J` `⌃K` `⌃L` | Move between panes — no prefix needed |
| `⌘B` | A WebKit browser pane splits off to the right |
| *drag a file from Finder onto a terminal* | Its shell-safe path is inserted at the cursor |
| `⌃A` then `M` | Maximize the active pane, and again to restore it |
| `⌃A` then `I` | Dive into that pane's private inner workspace; `O` comes back out |
| *hold* `⌃` | The sidebar reveals its window and pane jump hints |
| *switch away, let an agent finish* | macOS notification titled `window ▸ pane`, plus a blue unread ring on the pane |
| `⌘P` | Command palette for everything above |

## Agents that report in

Every Soprano terminal exports pane metadata for lifecycle hooks. The built-in agent
launchers configure those hooks per launch, without changing your global configuration:

- **Codex** — its external turn notifier plus OSC approval notifications.
- **Claude Code** — launch-scoped `SessionStart`, `UserPromptSubmit`, `Stop`, and
  permission hooks.
- **OpenCode** — a launch-scoped plugin through `OPENCODE_CONFIG_CONTENT`.

When a background agent finishes, macOS shows a notification and the pane gets a blue
unread ring. The notification is subtitled `window ▸ pane` so it names the location that
wants attention, and a pane's banners group together rather than stacking. Clicking one
activates Soprano and focuses that tab. The pane header and status bar expose
`STARTING`, `WORKING`, `READY`, `NEEDS INPUT`, `ERROR`, and `STOPPED`. Focusing the
relevant tab clears its unread marker, and a completed turn stays at `NEEDS INPUT` until
the next prompt is submitted.

Soprano asks for notification permission at launch. Notifications are only sent for
panes that are not focused, so denying the prompt leaves the in-app unread ring as the
only signal. Re-enable it under **System Settings → Notifications → Soprano**.

<details>
<summary><b>Agents you start yourself — aliases, scripts, plain <code>codex</code> in a shell</b></summary>

To recognize agents started outside the built-in launchers, merge the supplied lifecycle
hooks into the corresponding user configuration:

- **Codex:** merge [`Support/AgentHooks/codex-hooks.json`](Support/AgentHooks/codex-hooks.json)
  into `$CODEX_HOME/hooks.json` (normally `~/.codex/hooks.json`). Start Codex once, open
  `/hooks`, and trust the new command hooks.
- **Claude Code:** merge the `hooks` entries from
  [`Support/AgentHooks/claude-settings.json`](Support/AgentHooks/claude-settings.json)
  into `~/.claude/settings.json`.

Preserve existing hook groups when merging. The commands no-op outside Soprano, and the
first lifecycle event automatically associates the current terminal tab with the
reported agent. This works for any launcher whose underlying agent process inherits the
Soprano terminal environment.

</details>

## Keyboard shortcuts

`⌃A` is the prefix. Every binding below — including the prefix key, its timeout, and the
resize step — is editable in **Settings → Keyboard Shortcuts** (`⌘,`).

**Panes**

| Shortcut | Action |
|---|---|
| `⌃H` / `⌃J` / `⌃K` / `⌃L` | Focus the pane left / down / up / right |
| `⌃A` → `-` / `\|` | Split horizontal / vertical |
| `⌃A` → `⇧H/J/K/L` | Resize the active pane |
| `⌃A` → `M` | Toggle maximize for the active pane |
| `⌃A` → `Q` | Close the active pane |
| `⌃A` → `X` | Close the active depth layer, or kill the pane at `Z0` |
| `⌃A` → `I` / `O` | Go one complete layout in / out on the window z-axis |
| `⌘W` | Close the active pane |

**Windows and tabs**

| Shortcut | Action |
|---|---|
| `⌃⇧H` / `⌃⇧L` | Previous / next logical window |
| `⌃A` → `P` / `N` | Previous / next logical window |
| `⌃1`…`⌃9` | Select logical window 1–9 |
| `⌃⇧` + the letter shown in the sidebar | Select the matching pane across logical windows |
| `⌘N` | New logical window |
| `⌃A` → `C` | New logical window in the active terminal's directory |
| `⇧⌘R` / `⇧⌘W` | Rename / close the active logical window |
| `⌃A` → `T` / `⇧N` / `⇧P` / `W` | New tab / next / previous / close tab |

**Agents and panes to open**

| Shortcut | Action |
|---|---|
| `⌘1` / `⌘2` / `⌘3` | Launch Codex / Claude Code / OpenCode |
| `⌘T` | New terminal pane |
| `⌘B` | New browser pane |
| `⌘L` | Focus the address bar of the focused browser pane |
| `⌘[` / `⌘]` / `⌘R` | Browser back / forward / reload |

**App**

| Shortcut | Action |
|---|---|
| `⌘P` | Command palette |
| `⇧⌘D` | Open the Agent Dashboard |
| `⌘F` | Search and switch to a logical window |
| `⇧⌘P` | Search configured projects or choose a directory |
| `⌘,` | Settings |
| `⌘E` | Toggle sidebar |
| `⇧⌘S` | Save session as… |
| `⌘=` / `⌘-` / `⌘0` | Zoom in / out / reset |
| `⌃A` → `[` / `]` | Enter Vim-style terminal copy mode |
| `⌃A` → `⌃A` | Send a literal `⌃A` to the terminal |

Holding Control reveals the window and pane hints in the sidebar. Pane hints include `⇧`
because they require Control+Shift; unmodified alphabetic Control chords remain available
to the terminal.

## Knowing where you are

The active logical window and pane are marked in three places: the sidebar draws an
accent rail down the active window and its panes and tints the focused row, the status
bar names the location as `window ▸ pane · Z<depth>`, and the focused pane carries an
accent frame while the others keep a hairline border. Panes in inactive windows are
dimmed. Sidebar rows also show each pane's current git branch, refreshed as `HEAD`
changes on disk.

Press `⌘F` to search logical windows by window title, pane or tab title, working
directory, browser URL, or agent name. Window-title matches rank ahead of matches found
only inside a split pane; selecting a result restores that window's remembered active
pane.

Open the **Agent Dashboard** from the sidebar chart button, the **Commands** menu, or the
`⇧⌘D` (`agent-dashboard`). It summarizes agents that are working, waiting for input, or
in an error state across every logical window. Entries are ordered by urgency, update
from the same lifecycle events as pane headers and notifications, show elapsed runtime
and working directory, and select the exact agent tab when opened. Use `J` / `K` or the
arrow keys to move through agents, `Return` to focus the selected agent, and `Esc` to
close the dashboard without changing the active agent.

Drag the sidebar's trailing edge to resize it between 160 and 520 points; the cursor
changes to a resize arrow over the edge and the border accents while you drag. A narrow
window caps the sidebar so at least 320 points stay available for panes. Double-click the
edge to return to the default 220, and `⌘E` still toggles the sidebar, reopening at
whatever width you last chose. The width persists across launches.

Files, folders, URLs, and macOS screenshot thumbnails can be dragged directly onto a
terminal to insert their shell-safe paths.

## Window depth

Each pane can own a private inner workspace on the window's z-axis. Going in replaces
that pane's region with a fresh terminal while every sibling remains visible and live.
Splits and tabs created there stay confined to the owning pane's region. Going out
collapses only that branch; entering the same pane again restores its inner splits, tabs,
and live terminal surfaces. Sibling panes keep independent branches and are never changed
by another pane's Go In operation.

Use `⌃A` then `I` / `O`, the `‹ Z0 ›` controls in any pane header, or **Go In** /
**Go Out** in the command palette. Sidebar panes are labeled with their window depth and
can be selected directly.

## In-app browser

`⌘B`, the sidebar add menu, and **Open Browser** in the command palette split a native
WebKit browser to the right of the active pane. Browser URLs and page titles are saved
with workspace sessions. Bare local development addresses such as `localhost:5173` use
HTTP; normal hostnames use HTTPS, and other text is sent to web search.

Every terminal exports `SOPRANO_BIN`, so agents can drive a browser in the same Soprano
process with an agent-browser-style CLI:

```bash
"$SOPRANO_BIN" browser open http://localhost:5173
"$SOPRANO_BIN" browser snapshot --interactive
"$SOPRANO_BIN" browser click @e1
"$SOPRANO_BIN" browser fill '#email' user@example.com
"$SOPRANO_BIN" browser eval 'document.title'
```

Snapshots assign ephemeral element refs (`e1`, `e2`, …); use them as selectors with an
`@` prefix until the next snapshot or navigation. Commands target the focused browser by
default. Pass `--pane pane-7` immediately after `browser` to select a specific pane. Run
`"$SOPRANO_BIN" browser --help` for navigation, state inspection, input, getter, and
screenshot commands.

## Terminal copy mode

Copy mode starts at the terminal cursor and keeps navigation keys out of the running
shell or TUI. Move with `h/j/k/l` or the arrow keys, use `0`/`$` for line boundaries,
`H/M/L` for viewport positions, `gg`/`G` for scrollback boundaries, and `Ctrl+U/D` or
`Ctrl+B/F` for paging. Press `v` to begin a character selection or `Shift+V` to select
whole lines, then `y` or Enter to copy it to the macOS clipboard and exit. Escape, `q`,
or `Ctrl+C` cancels.

## Nested pane navigation

Soprano handles `⌃H/J/K/L` directly by default. Integrated editors and nested
multiplexers claim the keys while active, allowing fuzzy finders, completion menus, and
other terminal interfaces to use them normally. Those integrations bubble navigation to
the outer Soprano layout only after reaching their own boundary:

```bash
"$SOPRANO_BIN" navigate-pane left   # left, down, up, or right
```

The command selects an adjacent tmux pane first when invoked inside tmux. At a tmux
boundary it targets the originating Soprano process, pane, and tab using the environment
exported by each terminal surface. This keeps nested navigation and passthrough claims
isolated to the exact terminal tab that issued them, even when several Soprano instances
or tabs share a pane.

Integrations explicitly enable key passthrough while active:

```bash
"$SOPRANO_BIN" navigation-passthrough enable nvim
"$SOPRANO_BIN" navigation-passthrough disable nvim
```

Without an active passthrough claim, Soprano handles `⌃H/J/K/L` directly so pane
navigation always has a working fallback.

## Settings

`⌘,` opens a four-tab settings screen: **General** (theme, restore-last-session, project
directories), **Keyboard Shortcuts**, **Agent Profiles**, and **About**.

Everything it edits lives in **`~/.config/soprano/settings.json`**, and that file — not
the UI, not `defaults` — is the source of truth. The screen is a view over it: clicking
a control rewrites one key in the file, and saving the file applies to the running app
immediately. Open it with **Commands ▸ Open settings.json**, `⌘P` → *Open settings.json*,
or the button on any settings tab.

The path follows `XDG_CONFIG_HOME` when set, and `SOPRANO_CONFIG=/path/to/file.json`
overrides it outright. The file is created on first launch, pre-seeded with whatever you
had already configured, and every key in it is optional — delete one to fall back to the
default.

```jsonc
{
  // Comments and trailing commas are allowed. The UI preserves both when it
  // writes to this file.
  // gruvbox-dark | catppuccin-mocha | dracula | solarized-dark | nord
  // tokyo-night | atom-one-dark
  "theme": "catppuccin-mocha",
  "restoreLastSession": true,
  "projectDirectories": ["~/git", "~/work"],

  "keybindings": {
    "prefixKey": "a",                   // the prefix chord is Ctrl+<prefixKey>
    "prefixTimeoutMs": 1500,            // 300–5000
    "resizeTickPercent": 5,             // 1–25

    // Rebind by action id — every id is listed in Settings ▸ Keyboard
    // Shortcuts. Modifiers: "cmd", "ctrl", "shift", "prefix".
    "bindings": {
      "new-browser": "cmd+shift+b",
      "split-vertical": "prefix+v",
      "zoom-reset": null                // null turns the shortcut off
    }
  },

  // Add your own agents. Reusing a built-in id ("codex", "claude-code",
  // "opencode") patches that profile field by field instead. Plain terminal
  // panes are not configured here — they run your login shell.
  "agents": [
    {
      "id": "aider",
      "name": "Aider",
      "command": "aider",
      "args": ["--no-auto-commits"],
      "color": "#8bd5ca",
      "launchKey": "cmd+4",
      "env": { "AIDER_DARK_MODE": "1" },
      "cwd": "~/git"
    }
  ]
}
```

A user-defined agent is a first-class one: it appears in the sidebar's **+** menu, in the
`⌘P` palette, and in **Settings ▸ Agent Profiles**, its `launchKey` becomes a real
shortcut, and its panes restore with the workspace. Instead of `command`/`args` you can
give a `launchScript` to run something multi-step (`nvm use 22 && aider`).

What it does *not* get automatically is status reporting — `WORKING` / `NEEDS INPUT`
come from lifecycle hooks, and Soprano only injects those for the three built-in
launchers. Every pane exports `SOPRANO_BIN`, `SOPRANO_PANE_ID`, and `SOPRANO_TAB_ID`, so
an agent with its own hook mechanism can report in the same way the built-ins do.

A malformed file never takes the app down: Soprano keeps the last values that worked,
and the parse error — with its line number — plus any warning about an unknown theme,
unparseable chord, or conflicting shortcut appears at the top of **Settings ▸ General**.

## Development

```bash
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build          # debug build / type-check
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift test           # swift-testing suite
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build -c release
./dev.sh                 # build, package, and launch an isolated Soprano Dev.app
./dev.sh --build-only    # same, without launching
./install.sh             # release build → /Applications/Soprano.app
```

`dev.sh` produces `.build/debug/Soprano Dev.app` under the separate `com.soprano.dev`
bundle identifier, so its preferences, window state, sessions, and notification
permission stay isolated from the installed app. Both bundles embed the same Ghostty
runtime resources, so themes and terminal behavior do not depend on how you launched
them. The legacy `run.sh` forwards to `dev.sh`.

macOS requires a real application bundle for native notifications. `swift run` and the
raw `.build/debug/Soprano` executable are still useful for debugging, but notifications
are silently disabled for those unbundled launches.

The `ld: warning: building for macOS-14.0 …` and `could not find symbol '_ImGui…'` link
warnings appear on every build and are expected.

Release history lives in [`CHANGELOG.md`](CHANGELOG.md); user-visible changes land under
`Unreleased` until a release is cut. [`AGENTS.md`](AGENTS.md) is the full contributor
briefing — architecture, conventions, and the release workflow.

<details>
<summary><b>Project layout</b></summary>

```
soprano/
├── Package.swift                 # SPM package (swift-tools-version: 6.0, macOS 14+)
├── lib/libghostty.a              # Pre-built ghostty static library (not tracked; see Try it)
├── Sources/
│   ├── Soprano/
│   │   ├── main.swift            # CLI subcommand dispatch, then NSApplication
│   │   ├── App/                  # AppDelegate, MainWindowController, MainContentViewController
│   │   ├── Models/               # SplitNode layout tree, PaneState, AgentProfile, sessions
│   │   ├── Controllers/          # AgentManager, KeybindingManager, SessionManager, ThemeManager
│   │   ├── Views/                # AppKit views (SplitTreeView, SidebarView, CommandPalette, …)
│   │   ├── Config/               # Default agents, keybindings, themes
│   │   ├── Terminal/             # GhosttyAppManager, TerminalSurfaceView, copy mode
│   │   └── Utilities/            # NSColor+Hex extension
│   └── GhosttyKit/
│       ├── module.modulemap      # System library module map
│       └── include/ghostty.h     # libghostty C API header (generated; see Try it)
├── Support/                      # Info.plist, agent hook templates, ghostty-version.txt
├── scripts/                      # build-ghostty.sh, package-app.sh, sign-app.sh, signing helper
└── ghostty/                      # Ghostty submodule (source for libghostty)
```

`SplitNode` is where every pane geometry question is answered; the views render it.
`AgentManager` owns the mutable state — panes, tabs, depth layers, splits. The app binary
doubles as the `$SOPRANO_BIN` CLI, so new subcommands hook into `main.swift`.

</details>

## License

[MIT](LICENSE).

Soprano statically links [libghostty](https://github.com/ghostty-org/ghostty) and bundles
Ghostty's runtime resources (themes, shell integration, terminfo), which are MIT licensed —
Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. Their license travels with the
packaged app in `Soprano.app/Contents/Resources/LICENSE-ghostty`.
