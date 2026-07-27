# Soprano

Native macOS tiling terminal multiplexer for AI coding agents: Swift 6 + AppKit
(fully programmatic, no storyboards/xibs) rendering terminals through
[libghostty](https://github.com/ghostty-org/ghostty)'s C API. Built with SPM,
shipped as a hand-packaged `.app` bundle via `scripts/package-app.sh`.

## Commands

Homebrew Swift is required — the system CLT Swift has broken SPM. Prefix every
direct Swift command with the Homebrew toolchain:

```bash
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build            # debug build / type-check
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build -c release
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift test
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift test --filter SplitNodeTests
./scripts/dev.sh [--build-only]   # package + launch isolated Soprano Dev.app (user-driven only)
./scripts/install.sh              # release build → /Applications/Soprano.app
bash Tests/Signing/LocalCodeSigningTests.sh   # signing-identity helper tests (mutates user keychain list)
```

The `ld: warning: building for macOS-14.0 …` and `could not find symbol
'_ImGui…'` link warnings are expected on every build; ignore them.

There is no linter or formatter configured. Match surrounding style.

## Build and verification

- Verify source changes with `swift build`, and run `swift test` when touching
  anything a test covers. Do not launch the Soprano GUI during automated
  verification; launching terminal panes can trigger macOS permission prompts
  through the user's shell startup files.
- `./scripts/dev.sh` builds, packages, and launches the isolated `Soprano Dev.app` with
  bundle identifier `com.soprano.dev`. It is for user-driven GUI testing. Agents
  must not run it unless the user explicitly requests a launch. Use
  `./scripts/dev.sh --build-only` only when the development bundle itself needs testing.

## Installing completed changes

- After completing and successfully verifying a task that changes the app or its
  packaging, run `./scripts/install.sh` as the final step unless the user asks not to.
- The user has explicitly authorized this installation. The script builds the
  release configuration and replaces `/Applications/Soprano.app`, but does not
  terminate or launch Soprano. The running instance remains untouched and the
  installed update is used on the next launch.
- Do not use `sudo` if installation fails. Report the permission problem instead.
- Documentation-only or read-only tasks do not require installation.

## Changelog and versioning

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the
project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

- After finishing a user-visible change, add a line under `## [Unreleased]` in the
  matching group — `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security` —
  creating the group if it is missing and keeping the groups in that order.
- Write for the person using the app, not for the diff: one line describing the effect,
  naming the keybinding, CLI subcommand, or setting when there is one.
- Skip the changelog when nothing user-visible changed: refactors, test-only work,
  internal documentation, and the plans and specs under `docs/`.
- Never add a version heading as part of feature work. Day-to-day changes only ever touch
  `## [Unreleased]`; releases are cut deliberately.

### Cutting a release

Scale for this app:

- **major** — a workspace or session format older builds cannot read, or a documented
  keybinding or CLI subcommand removed.
- **minor** — new panes, keybindings, CLI subcommands, agent integrations, or settings.
- **patch** — fixes and polish that add no new surface.

1. Rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` and add a fresh, empty
   `## [Unreleased]` above it.
2. Bump `CFBundleShortVersionString` **and** `CFBundleVersion` in `Support/Info.plist`.
   That plist is the single source of truth — `AppVersion` reads it at runtime, so no
   Swift file carries the number. `ChangelogVersionTests` fails if the two drift apart.
3. `swift build && swift test`, then `./scripts/install.sh`.
4. Commit as `release: vX.Y.Z` and push tag `vX.Y.Z`.
5. `.github/workflows/release.yml` builds arm64 and x86_64, creates an ad-hoc-signed
   universal DMG, and publishes the DMG, checksum, and generated cask to GitHub Releases.
   The updater in `frknue/homebrew-tap` imports the latest cask. See
   `docs/RELEASING.md`.

## Architecture

`Sources/Soprano/` — single executable target:

- `main.swift` — dispatches CLI subcommands **before** starting `NSApplication`.
  `BrowserCommand`, `AgentEventCommand`, and `PaneNavigationCommand` each claim
  the invocation and exit. The app binary doubles as the `$SOPRANO_BIN` CLI that
  panes use to drive the running instance, so new subcommands hook in here.
- `Models/` — plain `Codable` value types. `SplitNode` is the recursive layout
  tree (every pane geometry question is answered here, not in views);
  `WorkspaceSession` / `WorkspaceWindowState` are the persistence formats.
- `Controllers/` — `AgentManager` is the central mutable state owner (panes,
  tabs, depth layers, splits) and the largest source of coupling.
  `SessionManager` persists/restores workspaces, `KeybindingManager` resolves the
  `Ctrl+A` prefix chords, `AgentNotificationManager` maps agent lifecycle hooks
  to pane status + notifications.
- `Terminal/` — `TerminalSurfaceView` wraps a libghostty surface (keyboard
  routing, drag-and-drop, env export, copy mode); `GhosttyAppManager` owns the
  single global `ghostty_app_t`.
- `Views/` — `SplitTreeView` renders a `SplitNode`; browser panes are WebKit.
- `Config/` — built-in defaults (agent profiles, keybindings, themes) **and** the
  user configuration layer. `ConfigStore` is the runtime authority for every
  user-facing setting: it loads `~/.config/soprano/settings.json`, resolves it
  over the built-in defaults (`SopranoConfig.resolved()`), publishes the result,
  and writes changes back through `JSONCText` so comments and key order survive.
  `AgentCatalog` is the merged agent registry every other file reads;
  `KeyChord` converts between chord text and `KeyBinding` fields.
- `Sources/GhosttyKit/` — modulemap + `ghostty.h` only, both tracked so a clone can
  compile before anyone builds libghostty. Regenerate the header with
  `scripts/build-ghostty.sh`; never hand-edit it and never copy it in on its own.

`Support/Info.plist` and `Support/AgentHooks/*.json` are copied into the bundle
by `scripts/package-app.sh`; changes to the launcher hooks belong there and in
`AgentManager`. `scripts/create-release-dmg.sh` accepts only a universal app. It
supports Developer ID notarization when credentials exist and an explicit
`SOPRANO_UNNOTARIZED_RELEASE=1` fallback for free, ad-hoc-signed releases.

## Adding a user-facing setting

`settings.json` is the source of truth; `UserDefaults` is not. To add a setting:

1. Add the (optional) key to `SopranoConfig` and apply it in `resolved()`,
   reporting bad values as a `ConfigIssue` rather than failing — a typo must
   never stop the app from launching.
2. Document it in `ConfigFile.template`, which is what a new user actually reads.
3. Have the settings screen write it with `configStore.write(_:at:)`; never
   persist UI state on the side.
4. Re-apply it in `MainWindowController.applyConfigChange()` so an edit made in
   the file lands live.

Window geometry, sidebar width, and saved workspaces stay in `UserDefaults` —
they are app state, not configuration.

## Conventions

- Tests use **swift-testing** (`import Testing`, `@Test`, `#expect`), not XCTest,
  with long sentence-style test names. One `struct …Tests` per file in
  `Tests/SopranoTests/`.
- Types that persist state accept an injectable `UserDefaults` (`init(defaults:
  UserDefaults = .standard)`) so tests never touch real preferences. Follow this
  when adding persisted state.
- Shell scripts: `#!/bin/bash`, `set -euo pipefail`, absolute-path validation on
  any env-var-provided directory, `trap cleanup EXIT` for temp dirs.
- Commits: short imperative subject, `fix:` / `feat:` prefixes common but not
  universal.
- Keep `README.md` in sync when changing keybindings, CLI subcommands, or
  packaging behavior — it is the user-facing reference. User-visible changes also
  get a `CHANGELOG.md` entry; see **Changelog and versioning** above.

## Gotchas

- `lib/libghostty.a` is **gitignored** (141 MB, over GitHub's file limit). A fresh
  clone must build it with `scripts/build-ghostty.sh`, which needs **full Xcode**
  for the Metal toolchain — Command Line Tools alone cannot build it — plus Zig
  at least the `minimum_zig_version` in `ghostty/build.zig.zon` (0.15.2 today).
- **Never copy libghostty artifacts by hand.** `scripts/build-ghostty.sh` builds the
  submodule and refreshes `lib/libghostty.a`, `Sources/GhosttyKit/include/ghostty.h`,
  and `Support/ghostty-version.txt` together. Updating only some of them is how a
  header ends up describing a different struct layout than the library actually has —
  that compiles, links, and corrupts memory at runtime with no diagnostic. Pass a ref
  to move ghostty: `scripts/build-ghostty.sh v1.3.1`, then `git add ghostty` so the
  submodule pin records what you built.
- `Support/ghostty-version.txt` is the recorded ghostty version for the checkout, and
  `GhosttyVersionTests` fails when the linked library disagrees with it. That test is
  the only thing standing in for the version tracking git cannot do on an untracked
  141 MB binary — if it fails, rebuild rather than editing the file.
- Packaging needs Ghostty **runtime resources** (themes, shell-integration,
  terminfo). `package-app.sh` searches `SOPRANO_GHOSTTY_RESOURCES_DIR`,
  `ghostty/zig-out/share/ghostty`, `GHOSTTY_RESOURCES_DIR`, then
  `/Applications/Ghostty.app`. It hard-fails if none is complete. These are found
  independently of the linked library, so it prints which source it used and warns
  when the versions differ; `SOPRANO_STRICT_GHOSTTY_RESOURCES=1` turns that into a
  failure. Soprano exports `GHOSTTY_RESOURCES_DIR` into every pane pointing at its
  own bundle, so packaging from inside a Soprano pane would otherwise copy resources
  from the installed app back into the new one forever — candidates inside a
  `com.soprano.*` bundle are refused for that reason.
- Native notifications require a real `.app` bundle. `swift run` and
  `.build/debug/Soprano` work for debugging but silently disable them.
- `swift test` links the CLT-bundled `Testing.framework` via `unsafeFlags` in
  `Package.swift`; that path is hardcoded to
  `/Library/Developer/CommandLineTools/…`.
- Never `import Foundation` next to `import Testing` in a test file: that activates
  the `_Testing_Foundation` cross-import overlay, which the CLT framework builds for
  macOS 26 while this package targets macOS 14, and every test file then fails to
  compile. Test files `import AppKit` instead and get Foundation types through it.
- Dev and installed apps use distinct bundle IDs (`com.soprano.dev` vs
  `com.soprano.app`), so preferences, sessions, and notification permissions do
  not carry over between them.
- `_archive/` (gitignored) holds dead Tauri/React/Rust code — reference only,
  never a build input.
