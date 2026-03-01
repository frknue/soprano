# AGENTS.md — Soprano

Soprano is a native macOS desktop app for orchestrating AI coding agents (Codex, Claude Code, OpenCode, OpenClaw) in a tiling terminal layout. Swift + AppKit frontend with libghostty for terminal rendering.

## Build & Run Commands

```bash
# Debug build
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build

# Run (debug)
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift run
# or directly:
.build/debug/Soprano

# Release build
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build -c release

# Rebuild libghostty (from ghostty/ directory)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer zig build -Dapp-runtime=none -Demit-xcframework=false -Doptimize=ReleaseFast
```

**Important**: System CLT Swift has broken SPM — must use Homebrew Swift (`/opt/homebrew/opt/swift/bin`).

### Testing

No test framework is currently configured. If adding tests, use built-in `swift test` with `XCTest` or the Swift Testing framework.

### Linting & Formatting

No SwiftLint or swift-format is configured. Swift strict concurrency checking is enabled via swift-tools-version 6.0.

## Project Structure

```
soprano/
├── Package.swift                     # SPM package (swift-tools-version: 6.0, macOS 14+)
├── lib/libghostty.a                  # Pre-built ghostty static library (135MB)
├── Sources/
│   ├── Soprano/
│   │   ├── main.swift                # Entry point (NSApp setup + activation policy)
│   │   ├── App/
│   │   │   ├── AppDelegate.swift     # NSApplicationDelegate, creates all managers
│   │   │   ├── MainWindowController.swift  # NSWindowController, KeybindingDelegate, palette wiring
│   │   │   └── MainContentViewController.swift  # Sidebar + split tree + status bar layout
│   │   ├── Models/
│   │   │   ├── AgentProfile.swift    # Static agent definition (command, args, patterns)
│   │   │   ├── AgentInstance.swift   # Runtime agent state (status, PID)
│   │   │   ├── PaneState.swift       # Pane model (tabs, active tab, type)
│   │   │   ├── SplitNode.swift       # Binary tree tiling model (221 lines)
│   │   │   ├── KeyBinding.swift      # Keybinding model + config
│   │   │   ├── McpServerConfig.swift # MCP server config + runtime instance
│   │   │   ├── AppSettings.swift     # App preferences (theme, restore, project dirs)
│   │   │   └── WorkspaceSession.swift # Session save/restore model
│   │   ├── Controllers/
│   │   │   ├── AgentManager.swift    # Pane/tab/agent lifecycle, observer pattern (~535 lines)
│   │   │   ├── KeybindingManager.swift # NSEvent monitor, prefix mode, action dispatch
│   │   │   ├── McpManager.swift      # Process-based MCP server lifecycle
│   │   │   ├── SessionManager.swift  # Named session save/load/delete
│   │   │   └── ThemeManager.swift    # Theme switching + change notifications
│   │   ├── Views/
│   │   │   ├── SplitTreeView.swift   # Binary tree tiling with PaneContainerView caching (~415 lines)
│   │   │   ├── SidebarView.swift     # Activity bar + expandable panels (~690 lines)
│   │   │   ├── PaneHeaderView.swift  # Header bar with multi-tab support
│   │   │   ├── StatusBarView.swift   # Bottom bar: brand + mode indicator + pane count
│   │   │   ├── CommandPalettePanel.swift  # NSPanel command palette with fuzzy search
│   │   │   ├── SettingsWindowController.swift  # Tabbed settings window (~1350 lines)
│   │   │   └── BrowserPaneView.swift # WKWebView browser pane with nav bar
│   │   ├── Config/
│   │   │   ├── DefaultAgents.swift   # 5 built-in agent profiles
│   │   │   ├── DefaultKeybindings.swift # 30+ keybindings with UserDefaults persistence
│   │   │   ├── DefaultMcpServers.swift  # MCP server config persistence
│   │   │   └── Theme.swift           # AppTheme, ThemeColors, TerminalColors, 2 themes
│   │   ├── Terminal/
│   │   │   ├── GhosttyAppManager.swift  # Singleton, ghostty init/config/callbacks/tick
│   │   │   └── TerminalSurfaceView.swift # NSView + CAMetalLayer, surface lifecycle (~400 lines)
│   │   └── Utilities/
│   │       └── NSColor+Hex.swift     # Hex string to NSColor conversion
│   └── GhosttyKit/
│       ├── module.modulemap          # System library module map for libghostty
│       └── include/ghostty.h         # libghostty C API header (1170 lines)
├── ghostty/                          # Ghostty source (for rebuilding libghostty)
└── _archive/                         # Old Tauri/React/Rust code (reference only)
```

## Code Style — Swift

### Formatting
- **Indentation**: 4 spaces (Swift standard)
- **Line length**: no enforced limit, kept reasonable (~120)
- **Trailing commas**: yes, in multi-line structures
- **Braces**: opening brace on same line

### Naming Conventions
- `PascalCase`: types, protocols, enums
- `camelCase`: functions, variables, properties
- `UPPER_SNAKE_CASE`: not used (Swift convention uses `static let` with camelCase)
- File names match the primary type: `AgentManager.swift` → `class AgentManager`

### Class Patterns
- `final class` for all concrete classes (views, controllers, managers)
- `@available(*, unavailable) required init?(coder:)` on all NSView/NSViewController subclasses
- No `@MainActor` annotations on classes — use `@unchecked Sendable` + main-thread-only pattern
- Observer pattern: `addObserver(id:handler:)` with `notifyChange()` (see `AgentManager`)

### View Construction (Programmatic AppKit)
- No SwiftUI, no storyboards, no XIBs — all programmatic
- `translatesAutoresizingMaskIntoConstraints = false` on all views
- `NSLayoutConstraint.activate([...])` for layout
- `wantsLayer = true` for views needing `layer` properties
- Multi-class-per-file pattern for self-contained features (e.g., `CommandPalettePanel.swift` has panel + view controller + row view)

### Types
- `struct` for data models: `struct AgentProfile: Identifiable, Codable, Hashable`
- `final class` for stateful objects: `final class AgentManager`
- `enum` with static members for namespaced constants: `enum DefaultAgents { static let all: [...] }`
- `protocol` for delegates: `protocol KeybindingDelegate: AnyObject`

### Imports
Single `import AppKit` (or `import Foundation` for model-only files). No third-party Swift dependencies — the only external dependency is `libghostty` via C interop.

### Error Handling
- Graceful fallbacks for persistence: `guard let data = ..., let decoded = try? ... else { return .defaults }`
- No `try!` or force unwraps in production code
- Fire-and-forget for non-critical operations

### State Persistence
- Uses `UserDefaults` with `soprano-` prefixed keys
- Pattern: `static func load() -> T` / `func save()` on model structs
- `Codable` for all persisted types
- Always handle decode failures gracefully (return defaults)

## Key Architecture Decisions

- **Manager pattern**: Core state lives in manager classes (`AgentManager`, `McpManager`, `SessionManager`, `ThemeManager`) created in `AppDelegate` and threaded through constructors
- **No state library**: Pure AppKit with observer callbacks (`addObserver`/`notifyChange`)
- **Dependency threading**: `AppDelegate` → `MainWindowController` → `MainContentViewController` → views
- **Tiling layout**: Custom `SplitNode` binary tree with `SplitTreeView` rendering + `PaneContainerView` caching
- **Terminal**: `libghostty` static library via C interop — `GhosttyAppManager` singleton manages app-level state, `TerminalSurfaceView` manages per-terminal surfaces with `CAMetalLayer`
- **Keybindings**: tmux-style prefix mode (`Ctrl+A`) via `NSEvent.addLocalMonitorForEvents`, with direct shortcuts (`Cmd+P`) handled separately
- **MCP servers**: Managed as `Process` child processes in `McpManager`, health-checked via 5s timer
- **Theming**: `AppTheme` structs with `ThemeColors` + `TerminalColors`, applied via `ThemeManager.onThemeChanged` callback
- **Entry point**: Custom `main.swift` (not `@main`) to call `NSApp.setActivationPolicy(.regular)` before run loop — required for SPM binaries to appear as foreground apps

## Common Pitfalls

- **SPM binary activation**: Without `main.swift` calling `setActivationPolicy(.regular)`, the app runs as a background-only process with no visible window
- **Homebrew Swift required**: System CLT Swift 6.2 has broken SPM; must use Homebrew Swift 6.2.3+ (`PATH="/opt/homebrew/opt/swift/bin:$PATH"`)
- **libghostty build**: Requires `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and Xcode Metal Toolchain installed
- **ghostty build.zig patched**: Skip xcframework/macOS-app init when `emit_xcframework=false` to avoid iOS SDK requirement
- **`ghostty_surface_set_display_id()`**: Must be called during view reparenting or terminal appears frozen
- **Surface userdata**: Clipboard callbacks receive surface userdata, not app userdata
- **CAMetalLayer backing**: `TerminalSurfaceView.makeBackingLayer()` returns `CAMetalLayer()`
- **`layoutGeneration` counter**: In `AgentManager`, tracks topology changes vs style-only changes for efficient view updates
- **Settings window**: Single-instance pattern — `MainWindowController` stores `settingsController` reference, reuses on subsequent opens
