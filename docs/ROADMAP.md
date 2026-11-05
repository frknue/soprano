# Roadmap

Planned work that is not built yet.

## Linux (Omarchy)

Furkan moves to Omarchy (Arch Linux, Hyprland, Wayland) later. Every app in the family is
macOS-only today: programmatic AppKit, `platforms: [.macOS(...)]` in `Package.swift`, macOS
frameworks, `.app` packaging and signing. Each repo has its own Linux task (see the table).

### Family-wide decision first

- [ ] Pick the Linux UI toolkit once for the whole family (GTK 4 through a Swift binding, or
  another). Every app syncs its chrome and theme from Soprano (`scripts/sync-soprano-chrome.sh`),
  so the Linux chrome layer starts here and the sync script learns to carry it.
- [ ] Swift toolchain on Arch through `swiftly`; a Linux CI job per repo once its core builds.
- [ ] Order: the Foundation-only cores first (cheap, testable on Linux), then the UIs.

### Soprano itself

About 54,000 lines, almost all AppKit; no separate core target.

- [ ] Terminal: GhosttyKit (`ghostty_surface_*`, `ghostty_app_*`) renders with Metal and
  IOSurface. Ghostty runs on Linux as its own GTK app; check first whether libghostty's
  embedding API supports a non-macOS host (OpenGL) or whether the Linux port embeds Ghostty
  differently.
- [ ] `WKWebView` (19 uses): WebKitGTK.
- [ ] `UNUserNotificationCenter`: freedesktop notifications (mako on Omarchy).
- [ ] Carbon, CoreServices, UniformTypeIdentifiers, CryptoKit (→ swift-crypto), `Darwin`
  imports: replace or put behind `#if canImport`.
- [ ] Global hotkeys: binds in `hyprland.conf` calling a `soprano` command (Wayland lets no
  app grab keys).

### Per repo

| Repo | Task | Short version |
|---|---|---|
| soprano-agents | `docs/BACKLOG.md` #11 | Core nearly portable (`os.Logger`, `posix_spawn`, `URLSession.bytes`); UI rewrite |
| soprano-cast | `docs/ROADMAP.md` → Linux | Port or extend Walker; hotkeys via Hyprland binds, `.desktop` search, Hyprland IPC |
| soprano-desktop | `docs/ROADMAP.md` → Linux | Becomes Omarchy themes; reuse the Ghostty/VS Code/bat/Neovim/fzf generators |
| soprano-files | `docs/ROADMAP.md` → Linux | inotify, own previews, `xdg-open`, freedesktop trash; default folder viewer via `xdg-mime` |
| soprano-git | `docs/ROADMAP.md` → Linux | Core (git CLI) builds nearly as is; UI rewrite |
| soprano-mix | `docs/ROADMAP.md` → Linux | CoreAudio → PipeWire (per-app streams native); Waybar module |
| soprano-tab | `docs/ROADMAP.md` → Linux | Hyprland IPC, toplevel-export thumbnails, layer-shell switcher |
| soprano-web | `docs/ROADMAP.md` → Linux | WebKitGTK; no `WKWebExtension`, so passwords need a new plan |
