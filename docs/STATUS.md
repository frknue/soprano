# Status: Rust-Rewrite

Auf `main` in `~/git/private/soprano` (der Rewrite-Branch `feat/rust-rewrite` ist gemergt und gelöscht).

## Ziel

Soprano komplett in Rust neu, lauffähig auf macOS, Linux und Windows, Oberfläche im Stil von
Herdr (GPUI), alles andere wie die Swift-App: Funktionen, Tastenkürzel, CLI, Umgebungsvariablen,
`settings.json`, Agent-Hooks, gespeicherte Workspaces, Benachrichtigungen.

## Erledigt

- 27 Crates unter `crates/` (Karte: `docs/rust-rewrite/PLAN.md`, Architektur: `AGENTS.md`).
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
- 2026-11-11: Statistik-Board aus Soprano Agents übernommen (`⇧⌘U`, Sidebar-Zeile „Statistics“,
  Commands-Menü, Palette): omp-Nutzung aus `~/.omp/stats.db` (Modell in
  `soprano_agents::usage`, Board im neuen Crate `soprano-statistics`, App-Seite in
  `crates/soprano/src/statistics.rs`). Öffnen und Refresh starten `omp stats --summary` über die
  Login-Shell, Periodenwechsel liest nur. Projekte heißen nach dem Ordner eines offenen Tabs,
  sonst nach omps Ordnernamen. Sichtprüfung über `statistics_demo -- --snapshot <ordner>` (hell
  860×900, dunkel, Dracula ohne Nutzung); Abfrage einmal lesend gegen die echte `stats.db`
  geprüft (153k Zeilen, „All“ in 0,2 s).
- 2026-11-11: Agent Dashboard wie Soprano Agents, als eigenes OS-Fenster (auf `main`,
  installiert): `⇧⌘D` öffnet, holt nach vorn, schließt (auch `⌘W`,
  `Esc` in der Liste); Rahmen in `soprano-agents-window-frame`. Thread-Inbox (Karten mit
  Projekt-Monogramm, Status-Pill, Titel, Aktivität; Suche `/`; Abschnitte klappbar, Stopped als
  Regal), 52-px-Kopf `projekt / titel`, Chat-Lane, schwebender Composer, kein Terminal mehr.
  Neuer Thread (`N`, `⌘N`, Stift): Projekt- und Agent-Wahl, landet über
  `Workspace::open_thread` als Tab im Fenster des Projekts, sonst in einem neuen Fenster, ohne
  das Hauptfenster umzuschalten. Code: `crates/soprano-dashboard` (View neu),
  `crates/soprano/src/agents_window.rs`, `main_view.rs` (Tasten des Agents-Fensters laufen nicht
  durch den Resolver, nur der Dashboard-Akkord). Sichtprüfung über
  `dashboard_demo -- --snapshot <ordner>` (dunkel 1100×780, hell 840×620, Dracula ohne Agenten).
- 2026-11-12: Furkans Fehlerbericht „unusable, flackert, verschwindet“ behoben (uncommittet auf
  `main`, installiert). Ursache: omp schreibt selbst OSC 133 (`A/B/C/D;0`) in sein Terminal;
  `Workspace::agent_command_did_finish` hielt das `D` für „Agent beendet“ und machte den Tab zum
  Terminal, bis der nächste Hook ihn wieder anhängte. Jetzt beendet eine Kommando-Ende-Marke
  nichts, solange der gemeldete Agent-Prozess lebt (Regressionstest in
  `workspace/tests/agents.rs`). Dashboard: nie leere Chat-Spalte (Entwurf mit fokussiertem
  Composer), `refresh` überspringt unveränderte Einträge (omp setzt den Titel ~10×/s), leere
  Timeline sagt „is starting…/is working…“, „omp · Chat“ aus Neuer Thread entfernt (Threads sind
  Terminal-Agenten). In Soprano Dev nachgestellt und geprüft (zwei omp-Threads, Karte bleibt von
  Starting bis Done, beide Tabs im Hauptfenster). Dev-Werkzeug: `debug-snapshot|debug-* --agents`
  zielt auf das Agents-Fenster; Snapshots zeichnen vorher einen frischen Frame.

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
- Agents-Fenster: in Soprano Dev über `debug-* --agents` geprüft (Öffnen per `⇧⌘D`, neuer
  Thread mit omp, `⌘W`). Noch ungeprüft: Nach-vorn/Schließen per `⇧⌘D` aus beiden Fenstern mit
  echter Tastatur, Ampel-Position (20, 19), Verschieben am 52-px-Band, das Menü „Agent
  Dashboard“ bei aktivem Agents-Fenster, „Choose Folder…“, Threads mit Codex/Claude Code/
  OpenCode. Banner richten sich weiter nur nach dem Hauptfenster (Agents-Fenster vorn zählt als
  „nicht aktiv“). Zwei Threads im selben Ordner können in verschiedenen Fenstern landen, wenn
  das erste Terminal sein Verzeichnis erst nach dem ersten Thread meldet.
  Linux/Windows: natives Titelband statt eigener Fensterknöpfe, nicht gebaut.
- Settings-Redesign: in der laufenden App noch nicht angesehen (nur Snapshots der Demo).
  Textfelder rücken app-weit etwa 20 px ein (`TextInput` plus Padding von gpui-component); nicht
  angefasst, weil es Dialoge, Picker, Browser-Adresszeile und Editor-Suche mitverschiebt.
- Statistik-Board: in der laufenden App noch nicht angesehen (nur Demo-Snapshots und Tests);
  `omp stats --summary` über die Login-Shell nicht live ausgelöst.
