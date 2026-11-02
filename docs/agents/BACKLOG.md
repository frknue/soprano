# Backlog

Geplante Features nach Priorität, aus der Recherche vom 2026-10-31 („Was sollten wir ergänzen,
damit die Entwicklung besser läuft?“). Jeder Eintrag nennt das Problem, den Umfang und wo man
anfängt. Aufwand: S = Stunden, M = ein bis zwei Tage, L = mehr. `docs/ROADMAP.md` listet, was
bewusst nicht gebaut wird; ein Eintrag, der gestrichen wird, wandert dorthin.

## Warum diese
- Von den letzten 300 Prompts in Terminal-omp-Sessions (25.–31. Okt.; Prompts aus dieser App
  werden dort nicht erfasst) sind 43 Ship-Schritte („commit and push“, „merge and install“,
  „take it live“, „deploy“), 18 „continue“ / „what's next“, 11 „what's the state“ / „did we
  finish this?“, 17 Slack- oder Asana-Entwürfe und 11 enthalten Screenshots.
- Zum Zeitpunkt der Recherche kannte die App 5 Projekte, aktiv genutzt wurden 16;
  valkental-int, ab_tool, dotfiles, soprano-web und datora liefen nur in Terminal-omp
  (soprano-web ist inzwischen in der App).
- omp sendet Events, die die App verwirft (`OmpEventMapper.swift` fällt auf
  `default: return []` durch), und bietet RPC-Befehle, die die App nie sendet. Referenz:
  `omp://rpc.md`.

## Aufgaben

### 1. In den Base-Branch mergen und aufräumen (M)
- [ ] Worktree-Threads bekommen „Merge to base“: den Branch des Threads lokal in seinen
  Base-Branch mergen, pullen, Worktree und Branch entfernen, Thread als erledigt ablegen.
- [ ] Optionales Post-Merge-Skript pro Projekt (z. B. `./scripts/install.sh`).
- [ ] Projekt-Flag „Mergen geht live“, das vor dem Merge nachfragt (Valkental-Theme-Repos: ein
  Merge nach `main` ist live).
- [ ] Editor für Projektskripte in den Einstellungen. Heute wird `ProjectScript` nur in
  `DemoFixtures` erzeugt, die Run-Zeile der Detailkarte bleibt bei echten Projekten verborgen.
- [ ] `runOnWorktreeCreate`-Skripte beim Anlegen eines Worktrees ausführen. Das Flag existiert
  (`Models/Threads.swift`), hängt aber nur „ (setup)“ an den Eintrag im Skriptmenü.
- Einstieg: `GitStackedAction` (`Git/GitService.swift`), `ThreadDetailsCardController.swift`,
  `LiveGitService+Branches.swift` (`createWorktree`).

### 2. Live-Checkliste (M)
- [ ] omps Todo-Phasen (`get_state.todoPhases`, Ergebnisse des `todo`-Tools, `todo_reminder`,
  `todo_auto_clear`) als Checkliste pro Thread zeigen: Phasen, Aufgaben, in Arbeit / blockiert.
- [ ] In der App bearbeiten über `set_todos`.
- Heute ist das `todo`-Tool nur eine Zeile „Updated tasks“ (`OmpEventMapper.swift`).

### 3. Link-Karte (S)
- [ ] Preview-, Live-, PR- und Asana-URLs aus den Turns eines Threads in einer Karte pro Thread
  sammeln.
- [ ] Jeden Link im passenden AI-Browser öffnen (`~/.omp/ai-browser/ai-browser show <account>
  <url>` öffnet dort einen Tab; `ai-browser url <account>` gibt nur den CDP-Endpunkt aus).
- Ein Browser-Bereich in der App ist ein späterer, größerer Schritt (L).

### 4. Review-Kommentare im Diff (M)
- [ ] Diff-Zeilen kommentieren und die Kommentare gesammelt als eine Nachricht an den Agenten
  schicken.
- [ ] Dateien als gesehen markieren; eine Datei taucht wieder auf, wenn sie sich erneut ändert.
- Gibt es in Conductor, der Codex-App und Claude Desktop. Das Diff-Panel ist heute nur lesbar.

### 5. Terminal-omp-Sessions importieren (M–L)
- [ ] Eine omp-Session-Datei übernehmen, die nicht von der App gestartet wurde
  (`get_messages`, `open_session` / `switch_session`), damit alle Projekte in einer Inbox mit
  Status, Badges und Diffs erscheinen.
- Heute kommt `providerThreadID` nur aus Sessions, die die App selbst gestartet hat.

### 6. Automationen (M)
- [ ] Geplante Prompts auf einem Projekt oder Thread (lokaler Checkout oder Worktree) mit eigener
  Inbox für Läufe und ungelesenen Läufen. Beispiele: täglicher ab_tool-Check, Pre-Sale-Check,
  einen PR beobachten.
- Gewünscht am 2026-10-29. Gibt es in der Codex-App, Claude Desktop und Conductor.

### 7. Nebenfrage (M)
- [ ] Dem laufenden Thread eine Frage stellen, ohne ihn zu steuern: `btw`, `btw_cancel`,
  `get_btw_history`, Events `btw_delta`, `btw_record`. Antwort in einem Popover zeigen.

### 8. omps eigene Warteschlange (M)
- [ ] Mit `prompt.streamingBehavior:"followUp"` / `follow_up` statt der App-Warteschlange
  (`AgentEngine+Turns.swift`) einreihen; Chips aus `queue_update`; „Jetzt senden“ über
  `promote_queued_message`; Entfernen über `remove_queued_message`.
- [ ] Stopp über `abort_and_restore_queue` legt den wartenden Text zurück in den Composer.
- [ ] Optionale Einstellungen: `set_steering_mode`, `set_follow_up_mode`, `set_interrupt_mode`.

### 9. Ziel-Leiste (M)
- [ ] Ziel, Token-Budget, Pause / Fortsetzen / Verwerfen über `goal {op}`; `goal_updated` und
  `get_state.goal` folgen.
- Ziele laufen über RPC nur dann von selbst weiter, wenn `goal.continuationModes` `"rpc"`
  enthält (`omp://rpc.md`).

### 10. Kleine Fixes (je S)
- [ ] Modellwechsel: `model_changed`, `thinking_level_changed`, `retry_fallback_applied`,
  `retry_fallback_succeeded` verarbeiten, damit die Auswahlfelder stimmen; „auf X
  ausgewichen“ anzeigen.
- [ ] `notice` (z. B. fehlgeschlagenes Speichern der Session), `extension_error` und
  `config_warnings_changed` in der Timeline zeigen. Alle werden heute verworfen.
- [ ] Kosten-Chip pro Thread und pro Turn (`get_session_stats`; die Antwortform ist in `rpc.md`
  nicht dokumentiert, zuerst eine echte Antwort prüfen).
- [ ] Ein Zustand „Compacting“, der bis zum Ende von omps Compaction bleibt: der heutige
  verschwindet, sobald der `compact`-Befehl geschrieben ist, ein getipptes `/compact` setzt ihn
  nie, und `auto_compaction_start` wird ignoriert. `manual_compaction_start/end` und
  `auto_compaction_start/end` nutzen.
- [ ] „An neuen Thread übergeben“ aus der Kontextanzeige (`handoff` → `savedPath`).
- [ ] Titel mit `set_session_name` an omp übertragen, damit `omp --resume` dieselben Namen zeigt.
- [ ] Den Mac wach halten, solange Agenten laufen (`ProcessInfo.beginActivity`; heute macht das
  nichts).
- [ ] Von git ignorierte Dateien (`.env`, CLI-Konfiguration) in neue Worktrees kopieren, z. B.
  anhand einer `.worktreeinclude`-Liste.

## Nicht geplant
- Sprache, Diktat, Ghost-Text-Vervollständigung, Best-of-N-Läufe, Container, Session-Baum: wenig
  Nutzen für diesen Workflow.
- Panels für Hintergrundjobs, MCP-Status und LSP-Diagnosen: omps RPC hat dafür keine Befehle.
- Plan- und Loop-Modus: omps RPC hat keinen Schalter dafür. `ctx.sessionModes` (omp 18.13.2) ist
  für TUI-Erweiterungen gedacht; ob es unter `rpc-ui` funktioniert, ist unbestätigt.
