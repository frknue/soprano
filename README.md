# Soprano

Native macOS tiling terminal multiplexer for AI coding agents. Built with Swift + AppKit + [libghostty](https://github.com/ghostty-org/ghostty).

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
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift run
```

Or directly:

```bash
.build/debug/Soprano
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

### Creating an .app bundle

To create a proper macOS application bundle:

```bash
# Build release binary
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build -c release

# Create bundle structure
mkdir -p Soprano.app/Contents/MacOS
mkdir -p Soprano.app/Contents/Resources

# Copy binary
cp .build/release/Soprano Soprano.app/Contents/MacOS/

# Create Info.plist
cat > Soprano.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Soprano</string>
    <key>CFBundleIdentifier</key>
    <string>com.soprano.app</string>
    <key>CFBundleName</key>
    <string>Soprano</string>
    <key>CFBundleVersion</key>
    <string>0.2.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
</dict>
</plist>
EOF
```

Then open or move `Soprano.app` to `/Applications`:

```bash
open Soprano.app
# or
cp -r Soprano.app /Applications/
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
| `Ctrl+A` → `Shift+H/J/K/L` | Resize panes |
| `Ctrl+A` → `S` / `V` | Split horizontal / vertical |
| `Ctrl+A` → `Q` / `X` | Close / kill pane |
| `Ctrl+A` → `T` / `N` / `P` / `W` | New tab / next / prev / close tab |
| `⌘1` / `⌘2` / `⌘3` | Launch Codex / Claude / OpenCode |
| `⌘T` | New terminal |
| `⌘B` | New browser pane |
| `⌘P` | Command palette |
| `⌘,` | Settings |
| `⌘E` | Toggle sidebar |
| `⇧⌘S` | Save session |
| `⌘W` | Close active pane |
| `⌘=` / `⌘-` / `⌘0` | Zoom in / out / reset |

## License

Private.
