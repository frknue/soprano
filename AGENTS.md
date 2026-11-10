# Soprano

Tiling terminal multiplexer for AI coding agents on macOS, Linux and Windows: a Rust
workspace with a GPUI interface in Herdr's look (`gpui-pre` + `gpui-component`) and terminals
from Ghostty's terminal core, libghostty-vt (`ghostty` submodule, built by
`crates/ghostty-sys` with Zig). The Swift/AppKit app it replaces is in git history; its
behavior is the spec for everything except the look.

## Commands

```bash
./scripts/prefetch-zig-deps.sh                  # once per ghostty pin: Codeberg deps via git
cargo build                                     # debug build (com.soprano.dev identity)
cargo test                                      # whole workspace
cargo test -p soprano-model closing             # one crate, filtered
cargo clippy --workspace --all-targets -- -D warnings
cargo fmt --all
./scripts/dev.sh [--build-only]                 # macOS: package + launch Soprano Dev.app (user-driven only)
./scripts/install.sh                            # macOS: release build → /Applications/Soprano.app
./scripts/install-linux.sh                      # Linux: release build → ~/.local
```

Zig 0.16 is required (`brew install zig@0.16`; `ghostty-sys` finds the keg-only formula, or
set `ZIG`). Cross-check cfg'd code from a Mac with
`cargo clippy --target x86_64-unknown-linux-gnu|x86_64-pc-windows-msvc -p <crate>`; crates
with C dependencies need `zig cc` wrappers as `CC_<target>`/`AR_<target>`.

## Build and verification

- Verify changes with `cargo build` and the affected crates' tests; run the workspace tests
  before handing off. Do not launch the app during automated verification: panes run the
  user's shell startup files and can trigger OS permission prompts.
- `./scripts/dev.sh` (macOS) builds, packages and launches `Soprano Dev.app`
  (`com.soprano.dev`). Agents run it only when the user asks for a launch;
  `--build-only` when the bundle itself needs testing.
- The Dev bundle is built with `--features visual-snapshot` (never release/install builds):
  `SOPRANO_SOCKET=<socket> <Dev binary> debug-snapshot /abs/out.png` writes its main window as a PNG;
  `debug-keys|debug-modifiers|debug-type|debug-click|debug-move|debug-scroll` inject input into it.
- After completing and verifying a task that changes the app or its packaging, run
  `./scripts/install.sh` as the final step unless the user asks not to. The user has
  authorized it: it replaces `/Applications/Soprano.app` and never stops or launches a
  running instance. Never use `sudo`; report a permission problem instead.
  Documentation-only or read-only tasks skip installation.

## GitHub development workflow

`main` is the only long-lived branch and stays releasable. Use short-lived branches named
`feat/<topic>`, `fix/<topic>`, `docs/<topic>`, `chore/<topic>` or `refactor/<topic>`;
preserve the current branch and any user work in the worktree. Merge with a squash merge
and delete the branch; the PR title becomes the commit subject (short, imperative, `feat:` /
`fix:` when it fits). CI (`.github/workflows/ci.yml`: fmt, clippy, tests on all three OSes)
is the merge gate; never merge while it fails. Mutate GitHub (commit, push, PR, merge, tag)
only when the user asked for that remote action. Fast path once authorized:

```bash
git push -u origin HEAD
gh pr create --fill
gh pr merge --auto --squash --delete-branch
```

## Changelog and versioning

`CHANGELOG.md` follows Keep a Changelog; versions follow SemVer. After a user-visible
change, add one line under `## [Unreleased]` in its group (`Added`, `Changed`,
`Deprecated`, `Removed`, `Fixed`, `Security`, in that order), written for the person using
the app and naming the keybinding, CLI subcommand or setting. Skip it for refactors, tests
and internal docs. Never add a version heading during feature work.

Releases: major = a workspace/session format older builds cannot read, or a documented
keybinding or CLI subcommand removed; minor = new panes, keybindings, subcommands, agent
integrations or settings; patch = fixes. The version lives only in the root `Cargo.toml`
(`[workspace.package] version`); `scripts/package-app.sh` writes it into `Info.plist`, and
a soprano-config test fails if `CHANGELOG.md` gets ahead of it. Steps: `docs/RELEASING.md`.

## Architecture

Crates in `crates/`, lowest first; non-UI crates have no gpui dependency and test without
an app:

- `soprano-types` (agent profiles/status, keybinding types, `Color`) and `soprano-platform`
  (app identity, data/resource paths, `StateStore` for app state, shell, open/reveal/trash).
- `soprano-config`: `settings.json` (`ConfigStore` is the runtime authority; `jsonc` writes
  keys preserving comments), default keybindings, `KeyChord` display, automation entries,
  cron. `soprano-keys`: the keybinding resolver (prefix chords, pane hints, passthrough).
- `soprano-model`: `Workspace` (sessions → logical windows → layout tabs → split panes →
  pane tabs; every geometry question is `SplitNode`'s) with a drained change log and
  two-phase closes; persistence formats.
- `soprano-launch` (agent/shell command lines, hooks, env; `remote.rs`: panes on a
  `machines` entry over `ssh` + a private tmux, with the helper in `src/remote/`),
  `soprano-term` (libghostty-vt + PTY + GPUI terminal view, OSC 7501 parsing), `soprano-ipc`
  (CLI subcommands, `machine`/`remote-attach`, and the app's local socket), `soprano-notify`
  (agent lifecycle → status, banners per OS).
- `soprano-agents` (transcripts, timelines, dashboard grouping), `soprano-chat` (ACP client
  for `omp acp`), `soprano-accounts`, `soprano-automations`, `soprano-git`, `soprano-files`,
  `soprano-text` (highlighter, editor documents, diff and Markdown models).
- UI crates over those: `soprano-ui` (design system: tokens derived from Soprano's themes
  with Herdr's formulas, fonts, icons, widgets, dialogs, picker), `soprano-editor`,
  `soprano-explorer`, `soprano-chat-ui`, `soprano-dashboard`, `soprano-settings`,
  `soprano-browser`, `soprano-automations-ui`.
- `soprano` (bin): `main.rs` runs `soprano_ipc::cli::run_cli` first (the binary doubles as
  `$SOPRANO_BIN`), then the app shell that wires every crate together.

`resources/` ships inside every package (agent hook templates, OpenCode/omp plugins, zsh
integration, `bin/omp` launchers, fonts, icons). `docs/rust-rewrite/` holds the Herdr look
spec (`HERDR-UI.md`), the screen map and per-crate API reports.

## Adding a user-facing setting

`settings.json` is the source of truth. Add the optional key to `SopranoConfig` and apply
it in `resolved()`, reporting bad values as a `ConfigIssue` (a typo never stops the app);
document it in the config template; have the Settings screen write it with
`ConfigStore::write`; re-apply it where the shell handles config changes. Window geometry,
sidebar widths and saved workspaces stay in `StateStore` — app state, not configuration.

## Conventions

- The look is Herdr's (`docs/rust-rewrite/HERDR-UI.md`): colors only from
  `cx.soprano_theme()` tokens, sizes through its zoom helper, fonts and icons from
  `soprano-ui`. No uppercase eyebrows or status words: sections are "Title N ⌄"; agent
  status is a status pill (Working with its duration, Approval, Input, Failed, Done, else a
  relative time). Keycaps follow K1: one cap per chord, a prefix sequence as separate caps.
  Motion is opacity-only fades ≤150 ms, none under Reduce Motion.
- Shortcuts are written with macOS keys; on Linux/Windows `cmd` is Ctrl+Shift, `cmd+shift`
  Ctrl+Shift+Alt, `ctrl+cmd` Ctrl+Alt, plain `ctrl` stays Ctrl (`soprano-keys` matches,
  `soprano-config` displays).
- OS differences live in one small module per concern (see `soprano-platform`), never as
  `#[cfg]` spread through shared code.
- Types that persist state take a `StateStore` (`StateStore::in_memory()` in tests), under
  the `soprano-*` keys the Swift app used.
- Tests: sentence-style names (`fn closing_the_last_pane_of_a_tab_closes_the_tab()`);
  GPUI views test with `TestAppContext`; tests never spawn the user's real shell or touch
  the real keychain, home or settings.
- Shell scripts: `#!/bin/bash`, `set -euo pipefail`, absolute-path validation on
  env-provided directories, `trap cleanup EXIT` for temp dirs.
- Keep `README.md` in sync when changing keybindings, CLI subcommands or packaging.

## Gotchas

- New crate: write `src/lib.rs` before `Cargo.toml`, and never point a path dependency or
  `[[example]]` at something that doesn't exist yet — any of these breaks every cargo
  command in the workspace.
- Ghostty's `translate_c` dependency comes from Codeberg, whose archive endpoint hangs;
  `scripts/prefetch-zig-deps.sh` fetches it through git into Zig's global cache.
- Moving Ghostty: check out a commit in `ghostty/`, rerun the prefetch script, rebuild, and
  commit the pin. Herdr's `crates/ghostty-sys` pin is the known-good libghostty-vt API.
- Native notifications on macOS need a real `.app` bundle; `cargo run` silently disables
  them. Windows toasts need the Start-menu shortcut `soprano-notify` creates at launch.
- Release and dev builds use distinct ids (`com.soprano.app` / `com.soprano.dev`), so their
  state, sockets and notification permissions never mix. `SOPRANO_APP_ID`,
  `SOPRANO_DATA_DIR`, `SOPRANO_RESOURCES_DIR` and `SOPRANO_CONFIG` override for tests.
