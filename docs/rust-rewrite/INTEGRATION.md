# Known differences from the Swift app

Intentional or platform-forced differences that remain after the port. Per-crate details are in
`apis/<crate>.md`; parity reviews and their fixes in `reviews/`.

- **Look:** Herdr's layout and tokens (`HERDR-UI.md`, `SHELL-MAP.md`), derived from Soprano's
  themes. Fonts are the bundled Geist and JetBrains Mono on every OS.
- **Keyboard on Linux/Windows:** `cmd` is Ctrl+Shift, `cmd+shift` Ctrl+Shift+Alt, `ctrl+cmd`
  Ctrl+Alt; pane hints are Alt+Shift+letter. ⌘L (toggle right sidebar) has no default there
  because it lands on Ctrl+Shift+L (next window); the first binding wins, as in Swift.
- **Terminal:** libghostty-vt rendered by GPUI instead of a full libghostty surface. Only the
  Ghostty config keys a vt renderer can honor are read (font, cursor, scrollback, clipboard,
  paste protection, padding, shell integration); ligatures are off.
- **IPC:** a per-instance local socket (`SOPRANO_SOCKET`) replaces distributed notifications;
  a CLI call to an app that isn't running fails at once with the same message instead of
  waiting 15 s.
- **Text offsets:** ranges are UTF-8 byte offsets; limits that Swift counted in UTF-16 units
  still count UTF-16 units.
- **Browser:** wry's web views; screenshots work on macOS only, and a failed page load is not
  reported by wry.
- **Reader:** an image inside a sentence sits on its own line (GPUI text can't flow images).
- **Wake from sleep:** detected from wall-clock gaps between 1 s samples on every OS.
- **Windows:** no terminfo; toasts register a Start-menu shortcut with the app id at launch;
  `resources/bin/omp.cmd` is the omp launcher.
- **Untested on real Linux/Windows hardware:** Linux-only tests (non-UTF-8 file names, the
  freedesktop trash) and all Windows code were only compiled or clippy-checked from macOS; CI
  runs them on ubuntu-latest and windows-latest.

## Toolchain notes

- Ghostty's `translate_c` dependency comes from Codeberg, whose archive endpoint hangs;
  `scripts/prefetch-zig-deps.sh` fetches it through git into Zig's global cache.
- Cross-checking crates with C dependencies (bundled SQLite, `ring`) from macOS works with
  `zig cc` wrappers as `CC_<target>`/`AR_<target>`. GPUI's Windows build script and the
  WebKitGTK/X11 build scripts can't be cross-built from macOS.

## Sibling apps

Soprano Agents, Cast, Files, Git, Desktop, Mix and Tab sync shared Swift files (`Chrome.swift`,
`Theme.swift`, `JSONCText.swift`, `CommandPalettePanel.swift`, …) from
`~/git/private/soprano/Sources/Soprano` with their `scripts/sync-soprano-chrome.sh`. Those
files no longer exist on this branch; point those scripts at a checkout of tag `v0.6.0`
(or port the sibling apps onto `soprano-ui`).
