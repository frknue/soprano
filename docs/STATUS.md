# Status: Rust-Rewrite

Auf `main` in `~/git/private/soprano` (der Rewrite-Branch `feat/rust-rewrite` ist gemergt und gelöscht).

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
- 2026-11-10: Maschinen (Terminals über SSH, README „Terminals on other machines“): pro Tab statt
  pro Session, `soprano <maschine>`, `⌃A ⇧M`, Settings ▸ Machines mit Verbindungsprüfung, Agenten
  melden ohne Einrichtung auf der Maschine (Stand-ins im PATH, OSC 7501 durch tmux).
- 2026-11-10: Settings neu gestaltet: Navigation auf `chrome`, Seite auf `canvas`, Gruppen als
  `background`-Karten; Theme-Kacheln statt Menü, Shortcuts einzeilig mit Zähler pro Gruppe,
  Agent-Profile aufklappbar, About mit App-Kopf. Sichtprüfung über
  `settings_demo -- --snapshot <ordner>` (hell, dunkel, 820×560, Dracula), installiert.
- 2026-11-10: Agent Dashboard im selben Stil: Liste auf `canvas` (Agent-Icon, Titel, Status-Pill,
  Laufzeit), der gewählte Agent als Pane-Karte, Toolbar bricht bei schmalem Fenster um, leeres
  Dashboard als eine Karte. Sichtprüfung über `dashboard_demo -- --snapshot <ordner>` (hell,
  dunkel, 820×400, Dracula, ohne Agenten). Die Snapshot-Hilfen liegen jetzt in
  `soprano_ui::snapshot` (Feature `snapshot`, nur Dev-Dependencies).

## Offen

- Furkan arbeitet ab jetzt mit der Rust-App und meldet Fehler von dort.
- Prompt-Reste beim Verschmälern, wenn die erste Prompt-Zeile (ohne OSC-133-Marke, rechter
  Prompt füllt die Zeile) umbricht; Ghostty löscht nur ab der markierten Zeile (nur im Code
  gelesen, nicht mit der Swift-App verglichen).
- Files/Changes-Umschalter, `+` und Session-Menü reagierten per Debug-Klick teils nicht, teils
  doch; Ursache unklar (die Buttons stoppen den Mouse-Down selbst). Mit echter Maus prüfen.
- Tab/Shift-Tab im Terminal behoben (`16eae0f`, Regressionstest in `keyboard.rs`).
- CI: macOS grün auf `124ca84`; Linux/Windows Clippy grün, Tests nicht abgewartet. Spätere
  Pushes nicht beobachtet.
- Linux und Windows real testen; bisher nur CI und Clippy-Checks von macOS aus.
- Geschwister-Apps (Agents, Cast, Files, Git, Desktop, Mix, Tab) synchronisieren Swift-Dateien
  aus `Sources/Soprano`; ihre `sync-soprano-chrome.sh` auf Commit `7eac737` zeigen lassen oder
  auf `soprano-ui` umstellen.
- Bekannte Abweichungen: `docs/rust-rewrite/INTEGRATION.md`.
- Maschinen: Settings ▸ Machines und Add Machine… in der laufenden App noch nicht angesehen;
  echte Agent-Sitzung mit Banner auf dem Mac mini und eine Maschine mit Passwort nicht getestet.
  OpenCode 2 meldet von Maschinen nichts; Dashboard zeigt dort keine Timeline.
- Settings-Redesign und Dashboard: in der laufenden App noch nicht angesehen (nur Snapshots der
  Demos). Textfelder rücken app-weit etwa 20 px ein (`TextInput` plus Padding von
  gpui-component); nicht angefasst, weil es Dialoge, Picker, Browser-Adresszeile und Editor-Suche
  mitverschiebt.
