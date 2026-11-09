# Roadmap

Geplante Arbeit, die noch nicht gebaut ist.

## Linux (Omarchy)

Furkan wechselt später auf Omarchy (Arch Linux, Hyprland, Wayland). Soprano selbst läuft seit
dem Rust-Rewrite (GPUI, libghostty-vt) auf macOS, Linux und Windows; die übrigen Apps der
Familie laufen nur auf macOS (programmatisches AppKit). Jedes Repo hat eine eigene
Linux-Aufgabe (siehe Tabelle).

### Zuerst eine Entscheidung für die ganze Familie

- [ ] Das Linux-UI-Toolkit für die restliche Familie wählen. Soprano nutzt GPUI und
  `gpui-component`; `crates/soprano-ui` ist die gemeinsame Chrome- und Theme-Schicht, die die
  anderen Apps statt `scripts/sync-soprano-chrome.sh` übernehmen könnten.
- [ ] Reihenfolge: zuerst die reinen Cores (günstig, auf Linux testbar), dann die UIs.

### Soprano selbst

- [ ] Auf Omarchy selbst testen (Hyprland, Wayland, mako): Fensterdekoration, Zwischenablage,
  Benachrichtigungen, Browser-Pane (WebKitGTK braucht X11 oder XWayland).
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
