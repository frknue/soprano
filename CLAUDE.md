# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

**Homebrew Swift is required** — system CLT Swift has broken SPM. Always prefix commands:

```bash
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build        # Debug build
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build -c release  # Release build
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift run           # Build + run
./run.sh                                                     # Dev script (clears window state, builds, launches)
```

No tests or linter configured. Swift 6.0 strict concurrency checking is enforced via swift-tools-version.

### Rebuilding libghostty (rarely needed)

```bash
cd ghostty
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  zig build -Dapp-runtime=none -Demit-xcframework=false -Doptimize=ReleaseFast
cp zig-out/lib/libghostty.a ../lib/
cp zig-out/include/ghostty.h ../Sources/GhosttyKit/include/
```

`ghostty/build.zig` is patched to skip xcframework / macOS-app init when `emit_xcframework=false`, avoiding the iOS SDK requirement.

## What This Is

Soprano is a native macOS tiling terminal multiplexer for orchestrating AI coding agents (Codex, Claude Code, OpenCode). Swift + AppKit + libghostty (C FFI via GhosttyKit system library target). No SwiftUI, no XIBs, no third-party Swift dependencies.

## Architecture

### Dependency Flow

`main.swift` → `AppDelegate` (creates all managers) → `MainWindowController` → `MainContentViewController` → Views

### Manager Pattern (Controllers/)

Core state lives in manager classes created in AppDelegate and passed through constructors:
- **AgentManager**: Pane/tab/agent lifecycle, layout topology, focus tracking. Exposes `layoutGeneration` counter to distinguish topology changes from style-only updates.
- **KeybindingManager**: NSEvent local monitor, tmux-style prefix mode (Ctrl+A then action key), direct shortcuts (Cmd+P).
- **SessionManager**: Named workspace save/load/delete.
- **ThemeManager**: Theme switching with `onThemeChanged` callback.

State propagation uses an observer pattern: `addObserver(id:handler:)` / `notifyChange()`.

### Tiling Layout (Models/SplitNode.swift + Views/SplitTreeView.swift)

Binary tree model (`indirect enum SplitNode: leaf | split(branch)`) rendered by SplitTreeView as nested NSSplitViews. PaneContainerView instances are cached by pane ID and survive layout rebuilds — only destroyed when a pane is actually removed.

### Terminal Integration (Terminal/)

- **GhosttyAppManager**: Singleton. Inits libghostty C API, manages app-level config, runs tick loop.
- **TerminalSurfaceView**: Per-terminal NSView backed by CAMetalLayer. Creates ghostty_surface, handles PTY, clipboard callbacks.

### Persistence

UserDefaults with `soprano-` prefixed keys. All persisted models are `Codable` with `static func load() -> T` / `func save()` pattern. Always handles decode failures by returning defaults.

## Code Conventions

- **All programmatic AppKit**: `translatesAutoresizingMaskIntoConstraints = false` + `NSLayoutConstraint.activate([...])`
- **`final class`** for all concrete classes
- **`@available(*, unavailable) required init?(coder:)`** on all NSView/NSViewController subclasses
- **`@unchecked Sendable`** instead of `@MainActor` — all classes are main-thread-only
- **`enum` with `static` members** for namespaced constants (e.g., `enum DefaultAgents`)
- **Multi-class-per-file** for self-contained features (e.g., CommandPalettePanel.swift contains panel + view controller + row view)
- **4-space indentation**, trailing commas in multi-line structures

## Key Pitfalls

- `main.swift` must call `NSApp.setActivationPolicy(.regular)` before the run loop — without this the SPM binary runs as a background-only process
- `ghostty_surface_set_display_id()` must be called during view reparenting or the terminal appears frozen
- Clipboard callbacks receive surface userdata, not app userdata
- `TerminalSurfaceView.makeBackingLayer()` returns `CAMetalLayer()` — this is required for Metal rendering
- Settings window uses a single-instance pattern stored in MainWindowController
