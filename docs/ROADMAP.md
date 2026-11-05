# Roadmap

Geplante Arbeit, die noch nicht gebaut ist.

## Linux (Omarchy)

Furkan wechselt später auf Omarchy (Arch Linux, Hyprland, Wayland). Jede App der Familie läuft
heute nur auf macOS: programmatisches AppKit, `platforms: [.macOS(...)]` in `Package.swift`,
macOS-Frameworks, `.app`-Paketierung und Signatur. Jedes Repo hat eine eigene Linux-Aufgabe
(siehe Tabelle).

### Zuerst eine Entscheidung für die ganze Familie

- [ ] Das Linux-UI-Toolkit einmal für die ganze Familie wählen (GTK 4 über eine Swift-Bindung oder
  etwas anderes). Jede App synct Chrome und Theme aus Soprano (`scripts/sync-soprano-chrome.sh`),
  also beginnt die Linux-Chrome-Schicht hier, und das Sync-Skript muss sie mitnehmen.
- [ ] Swift-Toolchain auf Arch über `swiftly`; ein Linux-CI-Job pro Repo, sobald sein Core baut.
- [ ] Reihenfolge: zuerst die reinen Foundation-Cores (günstig, auf Linux testbar), dann die UIs.

### Soprano selbst

Etwa 54.000 Zeilen, fast alles AppKit; kein eigenes Core-Target.

- [ ] Terminal: GhosttyKit (`ghostty_surface_*`, `ghostty_app_*`) rendert mit Metal und
  IOSurface. Ghostty läuft auf Linux als eigene GTK-App; zuerst prüfen, ob libghosttys
  Embedding-API einen Nicht-macOS-Host (OpenGL) unterstützt oder ob der Linux-Port Ghostty
  anders einbettet.
- [ ] `WKWebView` (19 Stellen): WebKitGTK.
- [ ] `UNUserNotificationCenter`: freedesktop-Notifications (mako auf Omarchy).
- [ ] Carbon, CoreServices, UniformTypeIdentifiers, CryptoKit (→ swift-crypto), `Darwin`-Importe:
  ersetzen oder hinter `#if canImport` legen.
- [ ] Globale Hotkeys: Bindings in `hyprland.conf`, die einen `soprano`-Befehl aufrufen (unter
  Wayland darf keine App Tasten abgreifen).

### Pro Repo

| Repo | Aufgabe | Kurzfassung |
|---|---|---|
| soprano-agents | `docs/BACKLOG.md` #11 | Core fast portabel (`os.Logger`, `posix_spawn`, `URLSession.bytes`); UI neu bauen |
| soprano-cast | `docs/ROADMAP.md` → Linux | Portieren oder Walker erweitern; Hotkeys über Hyprland-Bindings, `.desktop`-Suche, Hyprland-IPC |
| soprano-desktop | `docs/ROADMAP.md` → Linux | Wird zu Omarchy-Themes; Generatoren für Ghostty/VS Code/bat/Neovim/fzf wiederverwenden |
| soprano-files | `docs/ROADMAP.md` → Linux | inotify, eigene Vorschauen, `xdg-open`, freedesktop-Papierkorb; Standard-Ordneransicht über `xdg-mime` |
| soprano-git | `docs/ROADMAP.md` → Linux | Core (git-CLI) baut fast unverändert; UI neu bauen |
| soprano-mix | `docs/ROADMAP.md` → Linux | CoreAudio → PipeWire (Streams pro App eingebaut); Waybar-Modul |
| soprano-tab | `docs/ROADMAP.md` → Linux | Hyprland-IPC, Vorschaubilder per Toplevel-Export, Switcher als Layer-Shell-Fläche |
| soprano-web | `docs/ROADMAP.md` → Linux | WebKitGTK; kein `WKWebExtension`, Passwörter brauchen einen neuen Plan |
