# Status: Rust-Rewrite

Branch `feat/rust-rewrite` (Worktree `~/git/private/soprano.worktrees/rust-rewrite`).

## Ziel

Soprano komplett in Rust neu, lauffähig auf macOS, Linux und Windows, Oberfläche im Stil von
Herdr (GPUI), alles andere wie die Swift-App: Funktionen, Tastenkürzel, CLI, Umgebungsvariablen,
`settings.json`, Agent-Hooks, gespeicherte Workspaces, Benachrichtigungen.

## Erledigt

- 26 Crates unter `crates/` (Karte: `docs/rust-rewrite/PLAN.md`, Architektur: `AGENTS.md`).
  Terminal über libghostty-vt (Ghostty-Submodul auf Herdrs Pin, Zig 0.16), UI über `gpui-pre`
  + `gpui-component`, Look aus `docs/rust-rewrite/HERDR-UI.md` und `SHELL-MAP.md`.
- Jede Swift-Datei portiert, Swift-Tests als Rust-Tests übernommen; Paritäts-Reviews pro Bereich
  in `docs/rust-rewrite/reviews/`, alle Befunde behoben.
- Swift-Quellen gelöscht (in der Git-Historie, letzter Swift-Stand: Commit `7eac737`); Gespeichertes aus den
  `UserDefaults` der Swift-App wird beim ersten Start übernommen.
- Packaging und CI für alle drei Systeme (`scripts/`, `.github/workflows/`), `docs/RELEASING.md`.
- README, AGENTS.md, CHANGELOG (`[Unreleased]`) aktualisiert.
- Sichtprüfung per `debug-snapshot` (Dev-Build): Palette, Settings, Dashboard, Automations,
  Splits, Browser, Files/Changes, Editor, Markdown, Chat, Dialoge, Menüs; Befunde behoben.
- Am 2026-11-09 nach `main` gepusht und nach `/Applications/Soprano.app` installiert.

## Offen

- Furkan arbeitet ab jetzt mit der Rust-App und meldet Fehler von dort.
- Prompt-Reste beim Verschmälern, wenn die erste Prompt-Zeile (ohne OSC-133-Marke, rechter
  Prompt füllt die Zeile) umbricht; Ghostty löscht nur ab der markierten Zeile (nur im Code
  gelesen, nicht mit der Swift-App verglichen).
- Klick auf die Files/Changes-Umschalter wurde nur per Debug-Klick geprüft und traf auf dem
  Retina-Display nicht; mit echter Maus prüfen.
- Linux und Windows real testen; bisher nur Kompilier-/Clippy-Checks von macOS aus, CI läuft auf
  `ubuntu-latest` und `windows-latest`.
- Geschwister-Apps (Agents, Cast, Files, Git, Desktop, Mix, Tab) synchronisieren Swift-Dateien
  aus `Sources/Soprano`; ihre `sync-soprano-chrome.sh` auf Commit `7eac737` zeigen lassen oder
  auf `soprano-ui` umstellen.
- Bekannte Abweichungen: `docs/rust-rewrite/INTEGRATION.md`.
