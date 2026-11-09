# packaging — API report from Packaging

Packaging, install scripts and CI now use the Rust build on macOS, Linux and Windows. I ran the macOS bundle and the Linux tree for real on this Mac and listed them below. `package-windows.ps1` and both workflows are unverified: there is no `pwsh` here, and the workflows only had a YAML parse check. `shellcheck` isn't installed, so only `bash -n` passed.

## Script usage

| Script | Usage / behavior |
|---|---|
| `scripts/package-app.sh` | `<debug\|release> <abs .app> <bundle-id> <name>`. Uses `${CARGO_TARGET_DIR:-<repo>/target}/<cfg>/soprano` as `Contents/MacOS/Soprano`. Builds `Info.plist` from `Support/Info.plist` with `plutil -replace`: executable, bundle id, name, display name, `AppIcon`, and both version keys set to the Cargo version. Signs with `sign-app.sh` and the stable local identity, then swaps the new app in, rolling back to the old one if the move fails. |
| `scripts/stage-resources.sh` (new, shared) | `<macos\|linux> <abs empty dir>`. Runs `build-web.sh` and copies the `resources/` items, `web/`, `ghostty/shell-integration` (without `.md`), compiles `terminfo/` and adds `LICENSE` + `LICENSE-ghostty`. |
| `scripts/dev.sh [--build-only]` | `cargo build -p soprano`, then packages `target/debug/Soprano Dev.app` as `com.soprano.dev`. Launches with `open -n` only without `--build-only`. |
| `scripts/install.sh` | `cargo build -p soprano --release`, then packages `${SOPRANO_INSTALL_DIR:-/Applications}/Soprano.app`. Same messages as before; never stops a running instance. |
| `scripts/run.sh` | Unchanged; forwards to `dev.sh`. |
| `scripts/package-linux.sh <abs prefix>` | Writes `bin/soprano`, `share/soprano/`, `share/applications/soprano.desktop` and hicolor PNGs at 16–512 px. Icons are resized with `magick`, then `convert`, then `sips`; with none of them it puts the full PNG in `share/pixmaps`. Only Soprano's own files are replaced, so `~/.local` is safe. `SOPRANO_BUILD_PROFILE` (default `release`) picks the build; `SOPRANO_DESKTOP_EXEC` (default `<prefix>/bin/soprano`, CI sets `soprano`) sets the desktop `Exec`. |
| `scripts/install-linux.sh` | Release build, then installs to `${SOPRANO_INSTALL_PREFIX:-$HOME/.local}`. Refreshes the desktop database and icon cache if those tools exist, and says if the prefix's `bin` isn't on `PATH`. |
| `scripts/package-windows.ps1` | `[-Configuration debug\|release] [-OutputDir abs]` (default `dist`). Produces `soprano-<v>-windows-x64.zip` containing `soprano.exe`, `resources\` and `resources\bin\soprano.cmd`. On Windows it keeps `omp-web-tray.exe` and `web\scripts\windows`; there is no terminfo. |
| `scripts/prefetch-zig-deps.sh` (new, your request) | Finds every Codeberg `/archive/<commit>.tar.gz` URL in `ghostty/**/build.zig.zon` and runs `zig fetch git+https://…#<commit>` inside `ghostty/`. Fails if the result doesn't match the pinned `.hash`. Skips packages already in the cache: Zig 0.16 stores them as `p/<hash>.tar.gz`. Handles Windows cache paths. Called from `dev.sh`, `install.sh`, `install-linux.sh` and every CI/release build job. |
| `scripts/cargo-version.sh` (new) | Prints `[workspace.package] version` (currently `0.6.0`). |

The other scripts are unchanged: `sign-app.sh`, `ensure-local-signing-identity.sh`, `create-release-dmg.sh` (notarization and `SOPRANO_UNNOTARIZED_RELEASE` logic kept), `generate-homebrew-cask.sh`, `build-web.sh`, and the omp/opencode install scripts.

**Terminfo:** the terminfo source is Zig code inside Ghostty, so there is no plain source file to run `tic` on. The new `packaging/terminfo/emit.zig` prints it with `zig run --dep terminfo -Mterminfo=ghostty/src/terminfo/main.zig` (about 3 s, no full Ghostty build), then `tic -x` compiles it.

**Self-copy guard:** since resources now come from the repo, only one case remains. `package-app.sh` refuses an executable that sits inside a `com.soprano.*` bundle, which can happen when `CARGO_TARGET_DIR` is inherited from a pane. Tested: it exits 1 with that message.

**Deleted:** `scripts/build-ghostty.sh`, `scripts/patches/`, `scripts/render-app-icon.{sh,swift}`.

**Changed:** `Support/Info.plist` no longer has the two version keys. `docs/RELEASING.md` is rewritten for the new flow: bump the version in Cargo, the new assets, the layout and toolchain notes.

## Layouts produced here (temp outputs deleted afterwards)

`/tmp/soprano-pkg-test/Soprano Dev.app` (106 MB): `codesign --verify --deep --strict` passed, Authority=Soprano Local Development.
```
Contents/Info.plist   (com.soprano.dev, "Soprano Dev", CFBundle(Short)Version 0.6.0, Executable Soprano, Icon AppIcon)
Contents/MacOS/Soprano
Contents/Resources/{AgentHooks, AppIcon.icns, LICENSE, LICENSE-ghostty, Soprano_Soprano.bundle, fonts, icons (129 files, incl. Lucide/LobeHub notices)}
Contents/Resources/bin/{omp, soprano -> ../../MacOS/Soprano}
Contents/Resources/ghostty/shell-integration/{bash, elvish, fish, nushell, zsh}
Contents/Resources/terminfo/{67/ghostty, 78/xterm-ghostty}
Contents/Resources/web/{.next/static,…, LICENSE, bin, lib, node_modules, package*.json, public, scripts/macos-launchd.mts, server.js}
```
No `*.test.mjs` or `*.exe` in the bundle.

`SOPRANO_BUILD_PROFILE=debug scripts/package-linux.sh /tmp/soprano-pkg-linux` (105 MB):
```
bin/soprano
share/applications/soprano.desktop   (Exec="/tmp/soprano-pkg-linux/bin/soprano", Icon=soprano)
share/icons/hicolor/{16,24,32,48,64,128,256,512}x…/apps/soprano.png   (48 px checked)
share/soprano/{AgentHooks, LICENSE, LICENSE-ghostty, Soprano_Soprano.bundle, fonts, icons, web}
share/soprano/bin/{omp, soprano -> ../../../bin/soprano}
share/soprano/ghostty/shell-integration/{bash, elvish, fish, nushell, zsh}
share/soprano/terminfo/{67/ghostty, 78/xterm-ghostty}
```
On real Linux, `tic` writes letter directories (`x/xterm-ghostty`), and that is what `release.yml` checks.

## CI and release

- **`ci.yml`** runs on push to `main` and on PRs, for `macos-latest`, `ubuntu-latest` and `windows-latest`. Steps:
  - checkout, then `git submodule update --init ghostty`
  - stable Rust with rustfmt/clippy, `mlugg/setup-zig@v2` 0.16.0, then the prefetch script
  - Linux: Herdr's apt list plus `libdbus-1-dev libssl-dev`, since `Cargo.lock` has `libdbus-sys` and `openssl-sys`
  - Windows: `LIBCLANG_PATH`
  - `cargo fmt --all --check`, clippy `-D warnings`, `cargo test --workspace`
  - `bash -n` on all scripts (Linux only)
- **`release.yml`** keeps `preflight → build (macOS arm64 macos-15, x86_64 macos-15-intel) → release`.
  - `preflight` now checks the tag against `cargo-version.sh` plus the changelog heading.
  - New `build-linux` jobs (x86_64 on ubuntu-22.04, aarch64 on ubuntu-22.04-arm) make the tarball; the new `build-windows` job (windows-2022) makes the zip.
  - `release` lipos the two macOS binaries into `target/release/soprano` and runs `package-app.sh` with ad-hoc `-`. It keeps `create-release-dmg.sh` with `SOPRANO_UNNOTARIZED_RELEASE=1`, the `.sha256`, the cask plus `ruby -c`, and the same release notes.
  - It publishes the DMG, `.sha256`, `soprano.rb`, `soprano-<v>-linux-{x86_64,aarch64}.tar.gz` and `soprano-<v>-windows-x64.zip`.
  - No secrets are used, as before.
  - Tests still run on the arm64 macOS job. The Metal/Xcode steps are gone because GPUI uses runtime shaders.

## What others need to do

- **For you (crates/soprano):** a Windows icon and version info need `winresource` as a Windows-only build-dependency, plus a `build.rs` that embeds `resources/icons/app-icon.png` converted to `.ico`; no `.ico` exists yet.
- **Also on Windows:** `resources/bin/omp` is a bash launcher, so it won't run there. An `omp.cmd` equivalent is still missing.
- **Commit `Cargo.lock`.** It is currently untracked, and every CI/release cargo command uses `--locked`.
- **Outside my scope:**
  - `README.md` and `AGENTS.md` still describe `Support/Info.plist` as the version source and mention `build-ghostty.sh` and Ghostty-resource search.
  - The Swift `ChangelogVersionTests` reads the version from `Support/Info.plist`, so it would now fail; CI no longer runs Swift.
  - The now-unused `Support/Licenses/LICENSE-swift-cmark` and `Support/ghostty-version.txt` are still in the tree.
- No crate-level cross-check applies; I changed no crates.

## Checks run

- `bash -n`: all 16 scripts OK.
- `cargo-version.sh` printed `0.6.0`.
- Both workflow YAML files parse.
- `plutil -lint Support/Info.plist` OK.
- `cargo build -p soprano` OK.
- `package-app.sh` OK and signed (35 s); `package-linux.sh` OK (29 s).
- Prefetch script: first run fetched translate_c (hash matched), second run used the cache.
- Bad-path and self-copy refusals: exit codes 2 and 1.