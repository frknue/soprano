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
- Swift-Quellen gelöscht (in der Git-Historie, Tag `v0.6.0`); Gespeichertes aus den
  `UserDefaults` der Swift-App wird beim ersten Start übernommen.
- Packaging und CI für alle drei Systeme (`scripts/`, `.github/workflows/`), `docs/RELEASING.md`.
- README, AGENTS.md, CHANGELOG (`[Unreleased]`) aktualisiert.

## Offen

- Sichtprüfung der laufenden App (nach Repo-Regel nur auf Furkans Wunsch starten).
- Linux und Windows real testen; bisher nur Kompilier-/Clippy-Checks von macOS aus, CI läuft auf
  `ubuntu-latest` und `windows-latest`.
- Geschwister-Apps (Agents, Cast, Files, Git, Desktop, Mix, Tab) synchronisieren Swift-Dateien
  aus `Sources/Soprano`; nach dem Merge ihre `sync-soprano-chrome.sh` auf Tag `v0.6.0` zeigen
  lassen oder auf `soprano-ui` umstellen.
- Bekannte Abweichungen: `docs/rust-rewrite/INTEGRATION.md`.

## Entscheidungen offen

- Installation nach `/Applications` (ersetzt die Swift-App) und Merge nach `main`.
