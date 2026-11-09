# Releasing Soprano

Pushing a version tag runs `.github/workflows/release.yml`. The workflow builds the Rust
app natively on macOS arm64 and x86_64, Linux x86_64 and aarch64, and Windows x64 runners,
merges the two macOS executables into a universal app, applies an ad-hoc code signature,
and publishes these GitHub Release assets:

- `Soprano-X.Y.Z.dmg`
- `Soprano-X.Y.Z.dmg.sha256`
- `soprano.rb`
- `soprano-X.Y.Z-linux-x86_64.tar.gz`
- `soprano-X.Y.Z-linux-aarch64.tar.gz`
- `soprano-X.Y.Z-windows-x64.zip`

The workflow requires no Apple credentials or repository secrets. The updater in
[`frknue/homebrew-tap`](https://github.com/frknue/homebrew-tap) imports `soprano.rb`
from the latest release, making it available as:

```bash
brew install --cask frknue/tap/soprano
```

## Version

The root `Cargo.toml` `[workspace.package] version` is the single source of truth.
`scripts/cargo-version.sh` prints it; `scripts/package-app.sh` writes it into the bundle's
`CFBundleShortVersionString` and `CFBundleVersion` (`Support/Info.plist` carries no version),
and the Linux and Windows archive names carry it.

## Toolchain

Every build needs stable Rust and Zig 0.16 (libghostty-vt from the `ghostty` submodule;
`brew install zig@0.16` on macOS, or set `ZIG`). Codeberg's archive endpoint for ghostty's
Zig dependencies hangs often, so `scripts/prefetch-zig-deps.sh` puts those packages into the
global Zig cache through git first; `dev.sh`, `install.sh`, `install-linux.sh` and CI run it
before `cargo build`.

## Packaged layout

Every OS ships the same resource tree (`scripts/stage-resources.sh`; Windows:
`scripts/package-windows.ps1`): `Soprano_Soprano.bundle/`, `AgentHooks/`, `bin/omp`,
`bin/soprano`, `fonts/`, `icons/` from `resources/`, the built omp `web/` app,
`ghostty/shell-integration/` from the submodule, `terminfo/` (Ghostty's terminfo compiled
with `tic`; not on Windows), `LICENSE`, and `LICENSE-ghostty`. The font and icon notices
ship inside `fonts/` and `icons/`.

- macOS: `Soprano.app/Contents/MacOS/Soprano`, the tree in `Contents/Resources`,
  `bin/soprano` a symlink to the executable.
- Linux: `<prefix>/bin/soprano`, the tree in `<prefix>/share/soprano`,
  `share/applications/soprano.desktop`, and hicolor icons. The tarball unpacks to
  `soprano-X.Y.Z-linux-<arch>/{bin,share}`; install it with
  `tar -xzf soprano-X.Y.Z-linux-<arch>.tar.gz --strip-components=1 -C ~/.local`.
- Windows: `soprano.exe` with the tree in `resources\` beside it and `resources\bin\soprano.cmd`.

The packaging builds the editable `web/` source with `npm ci` and `npm run build` through
`scripts/build-web.sh` (Node.js 24 in CI). Each package ships the Next.js standalone
JavaScript server, assets, local launcher, and dependency closure; it does not ship Node.js
or omp. `omp web` therefore requires Node.js >= 22.19.0 and the separately installed omp CLI
on the user's machine. Image optimization is disabled and native-only web dependencies are
excluded from tracing so the same packaged server can run with either architecture's
Node.js. Packaging merges traced runtime directories with the editable source without nesting
duplicate directories, and excludes web tests; macOS and Linux also exclude Windows
executables. Root ignore rules `/lib/` and `/build/` apply only to Soprano's generated
artifacts; `web/lib/` is not ignored.

## Gatekeeper limitation

The release is ad-hoc signed but not notarized because Soprano does not have a paid
Apple Developer membership. This preserves code-signature integrity but does not give
Gatekeeper an Apple-trusted publisher identity. On first launch, users may need to open
**System Settings → Privacy & Security**, scroll to **Security**, click **Open Anyway**
for Soprano, and confirm **Open**.

Never suppress quarantine in the cask or tell users to disable Gatekeeper globally.
Keep this limitation visible in the README, GitHub release notes, and cask caveat.

## Cut a release

1. Replace `## [Unreleased]` in `CHANGELOG.md` with
   `## [X.Y.Z] - YYYY-MM-DD`, then add a new empty `## [Unreleased]` above it.
2. Set `[workspace.package] version` in the root `Cargo.toml` to `X.Y.Z`, then run
   `cargo build` so `Cargo.lock` picks up the new version.
3. Run:

   ```bash
   cargo fmt --all --check
   cargo clippy --workspace --all-targets -- -D warnings
   cargo test --workspace
   ./scripts/install.sh
   ```

4. Commit with `release: vX.Y.Z`, then push the commit and tag:

   ```bash
   git tag vX.Y.Z
   git push origin main vX.Y.Z
   ```

The release workflow rejects a tag that disagrees with `Cargo.toml` or lacks a matching
changelog heading. It publishes only after every platform builds, the tests pass, the merged
macOS executable contains arm64 and x86_64, the app and DMG carry valid ad-hoc signatures,
and Gatekeeper rejects the image as expected for an unnotarized release.
