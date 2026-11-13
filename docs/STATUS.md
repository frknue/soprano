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
- 2026-11-12: Furkans Fehlerbericht „unusable, flackert, verschwindet“ behoben (`880a651` auf
  `main`, installiert). Ursache: omp schreibt selbst OSC 133 (`A/B/C/D;0`) in sein Terminal;
  `Workspace::agent_command_did_finish` hielt das `D` für „Agent beendet“ und machte den Tab zum
  Terminal, bis der nächste Hook ihn wieder anhängte. Jetzt beendet eine Kommando-Ende-Marke
  nichts, solange der gemeldete Agent-Prozess lebt (Regressionstest in
  `workspace/tests/agents.rs`). Dashboard: nie leere Chat-Spalte (Entwurf mit fokussiertem
  Composer), `refresh` überspringt unveränderte Einträge (omp setzt den Titel ~10×/s), leere
  Timeline sagt „is starting…/is working…“. In Soprano Dev nachgestellt und geprüft (zwei
  omp-Threads, Karte bleibt von Starting bis Done, beide Tabs im Hauptfenster). Dev-Werkzeug:
  `debug-snapshot|debug-* --agents` zielt auf das Agents-Fenster; Snapshots zeichnen vorher
  einen frischen Frame.
- 2026-11-12: Modell- und Thinking-Auswahl im Agent Dashboard wie in Soprano Agents (Furkans
  Entscheidung: omp-Threads laufen über ACP). `Workspace::open_thread` öffnet omp als Chat-Tab
  (`omp acp`), die anderen Agenten weiter im Terminal mit Prompt auf der Kommandozeile; die
  Wahl „omp · Chat“ im Agent-Menü gibt es nicht mehr. Composer-Chips Modell (`⇧⌘M`, `Picker`
  nach Provider gruppiert) und Thinking (`⇧⌘E`, Menü): im Entwurf aus einer Wegwerf-Konversation
  gelesen (`ContentHost::thread_options_probe`: `omp acp --session-dir <temp>`, damit nichts
  in omps Sitzungsverlauf landet; nach Modellwechsel erneut, weil das Modell die Stufen
  bestimmt), beim Start über `AgentChatSession::set_opening_options` vor dem ersten Prompt
  gesetzt, im laufenden Thread per `DashboardEvent::SetOption`. Letzte Wahl pro Agent in
  `soprano-agents-thread-options`. In Soprano Dev geprüft: Chips erscheinen ~1,5 s nach dem
  Öffnen, Haiku 4.5 gewählt und gestartet, im laufenden Thread auf Sonnet 5.5 gewechselt (die
  Antwort nennt `anthropic/claude-sonnet-5-5`), keine Reste in `~/.omp/agent/sessions`.
- 2026-11-12: Absturz „Soprano schließt sich“ behoben (Furkan: Thread im Dashboard gestartet,
  Dashboard zu, zum Tab gewechselt; launchd: `exited due to exit(101)`, kein Crash-Report, weil
  ein Rust-Panic kein Signal ist). Ursache: `WorkLogLine` (soprano-chat-ui `widgets.rs`) blendete
  die Uhrzeit per `.hidden()` + `group_hover(.flex())` ein. Den Hover einer Gruppe kennt GPUI
  erst beim Malen; ein Element, das dort von `display: none` auf sichtbar wechselt, malt Kinder
  ohne Prepaint → Panic „must call prepaint before paint“, sobald der Zeiger über einer
  Work-Log-Zeile mit Uhrzeit steht. Betraf jeden Chat-Tab (`⌘I`) seit dem Rewrite; seit
  omp-Threads Chats sind, trifft man es sofort. Jetzt `invisible()`/`visible()` (Platz bleibt
  reserviert). Regressionstest in `soprano-chat-ui/src/view_tests.rs` (Zeiger fährt die
  Konversation ab). Regel: mit `group_hover` nie `display` umschalten, nur Sichtbarkeit,
  Deckkraft oder Farbe. Neu: `crates/soprano/src/crash_log.rs` schreibt jeden Panic mit
  Backtrace nach `<Datenordner>/panic.log`.
- 2026-11-12: omp-Chats (und damit Dashboard-Threads) fragten vor jedem Kommando nach Freigabe,
  obwohl omp im Terminal nichts fragt. Ursache: `omp acp` fragt vor jedem `execute`-Tool, solange
  der Freigabemodus nicht ausdrücklich gesetzt ist, auch wenn `tools.approvalMode` (Standard
  `yolo`) nichts verlangt (mit `--approval-mode=yolo` oder dem Wert in `config.yml`: 0
  Anfragen; ohne: 2 bei drei Tool-Aufrufen). Jetzt startet `ChatLaunch` (soprano-launch
  `chat.rs`) den ACP-Server über `sh -c` mit `--approval-mode=$(omp config get
  tools.approvalMode)`; ein Chat fragt damit genau dann, wenn omp im Terminal fragen würde.
  `--approval-mode`/`--auto-approve` in den `args` des Agenten gehen vor, ebenso ein
  `--config`-Overlay, das `tools: approvalMode:` setzt (mit `yaml-rust2` gelesen; ein gepunkteter
  Schlüssel `tools.approvalMode` zählt nicht, omp liest ihn nicht: gemessen 1 Anfrage; `omp
  config get` liest Overlays nicht, und das Flag würde das Overlay überstimmen: gemessen 1 → 0
  Anfragen); mit `--profile` wird der Modus
  dieses Profils gelesen. In Soprano Dev geprüft: Thread mit drei bash-Aufrufen läuft ohne
  Rückfrage bis Done (`ps`: `omp acp --approval-mode=yolo`). PowerShell-Variante nur als Text
  getestet.
- 2026-11-12: Furkans Fehlerbericht „nach dem Login im Terminal kann ich nichts eingeben, und
  im neuen Thread kein Bild anhängen“ (auf `main`, installiert). Ursache der
  Eingabe: der schwebende Composer liegt über der Timeline, deren Mouse-Down sich nach dem
  Editor selbst den Fokus holte; nur der Entwurf (ohne Timeline darunter) nahm Klicks an, der
  Login war Zufall. Die Composer-Karte blockt jetzt die Maus für alles darunter
  (`block_mouse_except_scroll`), und das `Textarea`-Element bekommt `disabled` selbst
  (gpui-component 0.9.1 setzt den Zustand bei jedem Render aus dem Element). Anhänge:
  `crates/soprano-dashboard/src/attachments.rs` (Bild einfügen per `⌘V`, kopierte Dateien,
  Drop; Vorschaubilder und Datei-Chips mit ✕). Der Agent bekommt die Pfade ans Ende der
  Nachricht (`soprano_platform::shell::path_word`), für Terminal-Agenten wie für omp-Chats;
  eingefügte Bilder liegen in `<Datenordner>/attachments/` (TIFF/BMP als PNG), ungesendete
  werden wieder gelöscht. Sichtprüfung: `dashboard_demo -- --snapshot` (`04-composer-attachments`).

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
- Anhänge im Dashboard: nur in Tests und im Demo-Snapshot geprüft, nicht in der laufenden App
  (Einfügen eines echten Screenshots, Drop aus dem Finder). Die Zustellung ist außerhalb der
  App geprüft: ein echtes PNG unter einem Pfad mit Leerzeichen, als Nachricht „Frage\n<Pfad mit
  `\ `>“ wie das Dashboard sie baut, an `claude -p --`, `codex exec --` und `omp -p --`; alle
  drei nannten Farben und Anordnung des Bildes richtig. Nicht geprüft: derselbe Weg über das
  Terminal-TUI und über `omp acp`. omp-Chats bekommen den Pfad im Text, keine ACP-Bildblöcke. `attachments/`
  wird nie aufgeräumt. Der Chat-Tab im Hauptfenster hat dieselbe Überlagerung (Timeline nimmt
  den Fokus beim Klick in den Composer), fällt dort nicht auf, weil getippte Tasten an den
  Composer weitergehen; nicht angefasst.
- Agents-Fenster: in Soprano Dev über `debug-* --agents` geprüft (Öffnen per `⇧⌘D`, neuer
  Thread mit omp, Modell/Thinking per Tastatur, `⌘W`). Noch ungeprüft: Klick auf die Chips mit
  echter Maus, Nach-vorn/Schließen per `⇧⌘D` aus beiden Fenstern mit echter Tastatur,
  Ampel-Position (20, 19), Verschieben am 52-px-Band, das Menü „Agent Dashboard“ bei aktivem
  Agents-Fenster, „Choose Folder…“, Threads mit Codex/Claude Code/OpenCode, Freigaben
  (Approvals) eines omp-Chat-Threads (beantwortbar nur im Chat-Tab des Hauptfensters, das
  Dashboard zeigt den Status). Der Modell-Picker markiert das aktuelle Modell, wählt es aber
  nicht vor. Banner richten sich weiter nur nach dem Hauptfenster (Agents-Fenster vorn zählt
  als „nicht aktiv“). Zwei Threads im selben Ordner können in verschiedenen Fenstern landen,
  wenn das erste Terminal sein Verzeichnis erst nach dem ersten Thread meldet.
  Linux/Windows: natives Titelband statt eigener Fensterknöpfe, nicht gebaut.
- Settings-Redesign: in der laufenden App noch nicht angesehen (nur Snapshots der Demo).
  Textfelder rücken app-weit etwa 20 px ein (`TextInput` plus Padding von gpui-component); nicht
  angefasst, weil es Dialoge, Picker, Browser-Adresszeile und Editor-Suche mitverschiebt.
- Statistik-Board: in der laufenden App noch nicht angesehen (nur Demo-Snapshots und Tests);
  `omp stats --summary` über die Login-Shell nicht live ausgelöst.
