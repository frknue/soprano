# Integration notes (lead)

Cleanups to do once the parallel crates land:

- `PaneNavigationClaimRegistry` is in both soprano-ipc (`navigation`) and soprano-keys (`claims`).
  Keep keys' (it implements `PassthroughClaims`); delete ipc's and its tests.
- Pane hints on Linux/Windows are Alt+Shift+letter (`Platform::is_pane_shortcut_chord`), because
  Ctrl+Shift+letter is every ⌘-letter shortcut there. Document in README.
- ⌘L (toggle right sidebar) has no default chord on Linux/Windows (collides with Ctrl+Shift+L,
  next window). Document; maybe give it an explicit non-mac default.
- Zig: ghostty's `translate_c` dependency (codeberg archive URL) hangs; prefetch through
  `zig fetch git+https://codeberg.org/vancluever/translate-c.git#<commit>` inside `ghostty/`.
- IPC: `send` fails fast when the app is not running (Swift waited 15 s); same message.
- Windows: `crates/soprano` needs a Windows-only `winresource` build-dependency + `build.rs`
  embedding an `.ico` made from `resources/icons/app-icon.png`; `resources/bin/omp` is bash, so
  Windows needs an `omp.cmd` launcher.
- Commit `Cargo.lock` (CI uses `--locked`).
- Cutover: README/AGENTS still describe Info.plist versioning, `build-ghostty.sh`, Ghostty resource
  search; delete `Support/Licenses/LICENSE-swift-cmark`, `Support/ghostty-version.txt`.
- soprano-git ranges are byte offsets (Swift used UTF-16).
- soprano-browser toolbar uses gpui-component theme colors directly (soprano-ui was not ready): switch it to soprano-ui tokens/widgets (ask BrowserUi once UiKit is done).
- Cross-compiling C deps (bundled SQLite etc.) for Linux/Windows checks works with zig cc wrappers as CC_<target>/AR_<target> (AccountsPort did this).
