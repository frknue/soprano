# Soprano

Native macOS tiling terminal multiplexer for AI coding agents. Built with Swift + AppKit + [libghostty](https://github.com/ghostty-org/ghostty).

Files, folders, URLs, and macOS screenshot thumbnails can be dragged directly
onto a terminal to insert their shell-safe paths.

## Agent notifications

Every Soprano terminal exports pane metadata for lifecycle hooks. The built-in
agent launchers configure those hooks without changing your global configuration:

- Codex uses its external turn notifier plus OSC approval notifications.
- Claude Code receives launch-scoped `SessionStart`, `UserPromptSubmit`, `Stop`,
  and permission hooks.
- OpenCode receives a launch-scoped plugin through `OPENCODE_CONFIG_CONTENT`.

### Agents started from a terminal

To recognize agents started directly, through an alias, or from a script, merge
the supplied lifecycle hooks into the corresponding user configuration:

- Codex: merge [`Support/AgentHooks/codex-hooks.json`](Support/AgentHooks/codex-hooks.json)
  into `$CODEX_HOME/hooks.json` (normally `~/.codex/hooks.json`). Start Codex
  once, open `/hooks`, and trust the new command hooks.
- Claude Code: merge the `hooks` entries from
  [`Support/AgentHooks/claude-settings.json`](Support/AgentHooks/claude-settings.json)
  into `~/.claude/settings.json`.

Preserve existing hook groups when merging. The commands no-op outside Soprano,
and the first lifecycle event automatically associates the current terminal tab
with the reported agent. This works for any launcher whose underlying agent
process inherits the Soprano terminal environment.

When a background agent finishes, macOS shows a notification and the pane gets a
blue unread ring. The pane header and status bar expose `STARTING`, `WORKING`,
`READY`, `NEEDS INPUT`, `ERROR`, and `STOPPED` states. Focusing the relevant tab
clears its unread marker. A completed turn remains at `NEEDS INPUT` until the
next prompt is submitted. macOS asks for notification permission the first time
an agent needs attention.

## Prerequisites

- macOS 14+ (Sonoma)
- [Homebrew Swift](https://formulae.brew.sh/formula/swift) 6.2+ (system CLT Swift has broken SPM)
- [Zig](https://ziglang.org/download/) 0.13+ (for building libghostty)
- Xcode (with Metal Toolchain installed)

```bash
brew install swift
brew install zig
xcodebuild -downloadComponent MetalToolchain
```

## Building libghostty

Soprano depends on a pre-built `libghostty.a` static library. The ghostty source is included as a submodule/directory in `ghostty/`.

```bash
cd ghostty
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  zig build -Dapp-runtime=none -Demit-xcframework=false -Doptimize=ReleaseFast
```

Then copy the built artifacts into the project:

```bash
mkdir -p lib
cp ghostty/zig-out/lib/libghostty.a lib/
cp ghostty/zig-out/include/ghostty.h Sources/GhosttyKit/include/
```

> You only need to rebuild libghostty when updating the ghostty source. The `lib/libghostty.a` file is checked in for convenience.

## Development

### Build (debug)

```bash
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build
```

### Run

```bash
./dev.sh
```

`dev.sh` builds and launches `.build/debug/Soprano Dev.app`. The development app
uses the separate `com.soprano.dev` bundle identifier, so its preferences,
window state, sessions, and notification permission remain isolated from the
installed app. Both app bundles include the same Ghostty runtime resources, so
themes and terminal behavior do not depend on the environment used to launch
them. Packaging uses `ghostty/zig-out/share` when available, then an exported
`GHOSTTY_RESOURCES_DIR`, and finally the resources from an installed
`/Applications/Ghostty.app`. Set `SOPRANO_GHOSTTY_RESOURCES_DIR` to override the
resource source explicitly. Pass `--build-only` to create the bundle without
launching it. The legacy `run.sh` command forwards to `dev.sh`.

A real application bundle is required by macOS for native notifications.
`swift run` and the raw `.build/debug/Soprano` executable are still useful for
debugging, but native notifications are disabled for those unbundled launches.

To run the unbundled executable:

```bash
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift run
```

### Type-check only

```bash
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build 2>&1 | head -20
```

## Production Build

### Release binary

```bash
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build -c release
```

The optimized binary is at `.build/release/Soprano`.

### Install the release app

Build and install `/Applications/Soprano.app` without stopping or launching the
application:

```bash
./install.sh
```

The updated version is used the next time Soprano launches. To install into a
different applications directory, set `SOPRANO_INSTALL_DIR`:

```bash
SOPRANO_INSTALL_DIR="$HOME/Applications" ./install.sh
```

## Project Structure

```
soprano/
├── Package.swift                 # SPM package (swift-tools-version: 6.0, macOS 14+)
├── lib/libghostty.a              # Pre-built ghostty static library (135MB)
├── Sources/
│   ├── Soprano/
│   │   ├── main.swift            # Entry point
│   │   ├── App/                  # AppDelegate, MainWindowController, MainContentViewController
│   │   ├── Models/               # Data types (AgentProfile, PaneState, SplitNode, etc.)
│   │   ├── Controllers/          # AgentManager, KeybindingManager, SessionManager, ThemeManager
│   │   ├── Views/                # All AppKit views (SplitTreeView, SidebarView, CommandPalette, etc.)
│   │   ├── Config/               # Default configs, themes, keybindings
│   │   ├── Terminal/             # GhosttyAppManager, TerminalSurfaceView
│   │   └── Utilities/            # NSColor+Hex extension
│   └── GhosttyKit/
│       ├── module.modulemap      # System library module map
│       └── include/ghostty.h     # libghostty C API header
├── ghostty/                      # Ghostty source (for rebuilding libghostty)
└── _archive/                     # Old Tauri/React/Rust code (reference)
```

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Ctrl+H/J/K/L` | Navigate panes (left/down/up/right) |
| `Ctrl+A` → `Ctrl+A` | Send a literal `Ctrl+A` to the terminal |
| `Ctrl+A` → `P` / `N` | Switch to previous / next logical window |
| `Ctrl+Shift+H/L` | Switch to previous / next logical window |
| `Ctrl+1…9` | Select logical window 1–9 |
| `Ctrl+Shift+letter shown in sidebar` | Select the matching pane across logical windows |
| `Ctrl+A` → `Shift+H/J/K/L` | Resize panes |
| `Ctrl+A` → `-` / `|` | Split horizontal / vertical |
| `Ctrl+A` → `Q` | Close the active pane |
| `Ctrl+A` → `X` | Close the active depth layer, or kill the pane at `Z0` |
| `Ctrl+A` → `[` / `]` | Enter Vim-style terminal copy mode |
| `Ctrl+A` → `C` | New logical window in the current directory |
| `Ctrl+A` → `I` / `O` | Go one complete layout in / out on the window z-axis |
| `Ctrl+A` → `T` / `Shift+N` / `Shift+P` / `W` | New tab / next / prev / close tab |
| `⌘1` / `⌘2` / `⌘3` | Launch Codex / Claude / OpenCode |
| `⌘T` | New terminal |
| `⌘B` | New browser pane |
| `⌘L` | Focus the active browser address bar |
| `⌘[` / `⌘]` / `⌘R` | Browser back / forward / reload |
| `⌘P` | Command palette |
| `⇧⌘P` | Search configured projects or choose a directory |
| `⌘,` | Settings |
| `⌘E` | Toggle sidebar |
| `⇧⌘S` | Save session as… |
| `⌘W` | Close active pane |
| `⌘=` / `⌘-` / `⌘0` | Zoom in / out / reset |

Holding Control reveals the window and pane hints in the sidebar. Pane hints
include `⇧` because they require Control+Shift; unmodified alphabetic Control
chords remain available to the terminal.

### In-app browser

`⌘B`, the sidebar add menu, and **Open Browser** in the command palette split a
native WebKit browser to the right of the active pane. Browser URLs and page
titles are saved with workspace sessions. Bare local development addresses
such as `localhost:5173` use HTTP; normal hostnames use HTTPS, and other text is
sent to web search.

Every terminal exports `SOPRANO_BIN`, so agents can drive a browser in the same
Soprano process with an agent-browser-style CLI:

```bash
"$SOPRANO_BIN" browser open http://localhost:5173
"$SOPRANO_BIN" browser snapshot --interactive
"$SOPRANO_BIN" browser click @e1
"$SOPRANO_BIN" browser fill '#email' user@example.com
"$SOPRANO_BIN" browser eval 'document.title'
```

Snapshots assign ephemeral element refs (`e1`, `e2`, …); use them as selectors
with an `@` prefix until the next snapshot or navigation. Commands target the
focused browser by default. Pass `--pane pane-7` immediately after `browser` to
select a specific pane. Run `"$SOPRANO_BIN" browser --help` for navigation,
state inspection, input, getter, and screenshot commands.

### Window depth

Each pane can own a private inner workspace on the window's z-axis. Going in
opens that workspace full-screen with a fresh terminal while the complete outer
layout stays alive behind it. Splits and tabs created there belong only to that
pane's branch. Going out restores the outer layout; entering the same pane again
restores its inner splits, tabs, and live terminal surfaces. Sibling panes keep
independent branches and are never changed by another pane's Go In operation.
Use `Ctrl+A` then `I` / `O`, the `‹ Z0 ›` controls in any pane header, or
**Go In** / **Go Out** in the command palette. Sidebar panes are labeled with
their window depth and can be selected directly.

### Terminal copy mode

Copy mode starts at the terminal cursor and keeps navigation keys out of the
running shell or TUI. Move with `h/j/k/l` or the arrow keys, use `0`/`$` for
line boundaries, `H/M/L` for viewport positions, `gg`/`G` for scrollback
boundaries, and `Ctrl+U/D` or `Ctrl+B/F` for paging. Press `v` to begin a
character selection or `Shift+V` to select whole lines, then `y` or Enter to
copy it to the macOS clipboard and exit. Escape, `q`, or `Ctrl+C` cancels.

### Nested pane navigation

Soprano handles `Ctrl+H/J/K/L` directly by default. Integrated editors and
nested multiplexers claim the keys while active, allowing fuzzy finders,
completion menus, and other terminal interfaces to use them normally. Those
integrations bubble navigation to the outer Soprano layout only after reaching
their own boundary:

```bash
"$SOPRANO_BIN" navigate-pane left   # left, down, up, or right
```

The command selects an adjacent tmux pane first when invoked inside tmux. At a
tmux boundary it targets the originating Soprano process, pane, and tab using
the environment exported by each terminal surface. This keeps nested
navigation and passthrough claims isolated to the exact terminal tab that
issued them, even when several Soprano instances or tabs share a pane.

Integrations explicitly enable key passthrough while active:

```bash
"$SOPRANO_BIN" navigation-passthrough enable nvim
"$SOPRANO_BIN" navigation-passthrough disable nvim
```

Without an active passthrough claim, Soprano handles `Ctrl+H/J/K/L` directly so
pane navigation always has a working fallback.

## License

Private.
