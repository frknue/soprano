# Soprano

Native macOS tiling terminal multiplexer for AI coding agents. Built with Swift + AppKit + [libghostty](https://github.com/ghostty-org/ghostty).

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
installed app. Pass `--build-only` to create the bundle without launching it.
The legacy `run.sh` command forwards to `dev.sh`.

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
| `Ctrl+Shift+H/L` | Switch to previous / next logical window |
| `Ctrl+1…9` | Select logical window 1–9 |
| `Ctrl+A` → `Shift+H/J/K/L` | Resize panes |
| `Ctrl+A` → `S` / `V` | Split horizontal / vertical |
| `Ctrl+A` → `Q` / `X` | Close / kill pane |
| `Ctrl+A` → `T` / `N` / `P` / `W` | New tab / next / prev / close tab |
| `⌘1` / `⌘2` / `⌘3` | Launch Codex / Claude / OpenCode |
| `⌘T` | New terminal |
| `⌘B` | New browser pane |
| `⌘P` | Command palette |
| `⇧⌘P` | Search configured projects or choose a directory |
| `⌘,` | Settings |
| `⌘E` | Toggle sidebar |
| `⇧⌘S` | Save session |
| `⌘W` | Close active pane |
| `⌘=` / `⌘-` / `⌘0` | Zoom in / out / reset |

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
tmux boundary it targets the originating Soprano process and pane using the
environment exported by each terminal surface.

Integrations explicitly enable key passthrough while active:

```bash
"$SOPRANO_BIN" navigation-passthrough enable nvim
"$SOPRANO_BIN" navigation-passthrough disable nvim
```

Without an active passthrough claim, Soprano handles `Ctrl+H/J/K/L` directly so
pane navigation always has a working fallback.

## License

Private.
