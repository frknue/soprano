I found one real port bug, in `soprano-model`. `soprano-keys` matches the Swift; its only differences are the Linux/Windows ones already listed in `apis/soprano-keys.md`. Tests pass: `CARGO_TARGET_DIR=target/review-model cargo test -p soprano-model -p soprano-keys` ran 148 model tests and 21 + 36 keys tests, all green (the keys report says 35 integration tests; 36 ran).

## Finding

### 1. File-tab URLs are written differently from Swift's, so restored Swift tabs stop matching (P2, confidence 0.85)
- **Crate:** soprano-model
- **Rust:** `crates/soprano-model/src/file_url.rs:21-25` (`file_url_string`). It's used for matching at `workspace/files.rs:141` and `:154` (`open_file_tab` compares `tab.url` to it), at `files.rs:274-277` (`update_file_document`), and in `relocate_file_tabs` (`files.rs` around lines 236-245), which uses `path.strip_prefix(&old_path)`.
- **Swift:** `Controllers/AgentManager.swift:609-618` (`openFileTab`: `standardizedURL.absoluteString`, then `$0.url == url`), and `:1578-1581` (`updateFileDocument`).
- **What differs (I ran both locally):**
  - **Characters `[ ] ^ |`:** Foundation's `URL(fileURLWithPath:).standardizedFileURL.absoluteString` percent-encodes them. For `/tmp/a[1]^|b.md` it gives `file:///tmp/a%5B1%5D%5E%7Cb.md`. The `url` crate leaves all four as they are: its `SPECIAL_PATH_SEGMENT` set (url-2.5.8 `parser.rs:20-42`, `lib.rs:2952-2975`) doesn't include them.
  - **Accented letters:** Foundation turns the path into decomposed Unicode (NFD). `café` becomes `cafe%CC%81`, and `lastPathComponent` and `.path` come back decomposed too ("Präsentation.md" grew from 15 to 16 characters). The Rust code encodes the bytes exactly as it gets them, which is usually precomposed (`%C3%A9`).
- **What the user sees:**
  - Next.js route folders like `app/[id]/page.tsx` and German names like `Präsentation.md` are common.
  - After restoring a Swift-saved workspace, opening such a file again gives a second tab instead of focusing the existing one, because `files.rs:154` doesn't match.
  - A preview tab for such a file is never reused, and opening it as permanent doesn't turn the old preview into a regular tab.
  - Renaming or moving a folder with an accent in its path doesn't update the restored tabs: the stored path is decomposed, the incoming `old_path` is usually precomposed, so `strip_prefix` fails. Those tabs keep pointing at the old location.
  - Even in Rust alone, paths that arrive in different Unicode forms (file picker, terminal cwd, file-system events) no longer compare equal, which Foundation's normalization used to guarantee.
- **The porting report's note** ("percent-encoding may differ slightly, but stored URLs decode correctly") misses that these strings are compared, not only decoded.
- **Suggested fix:** compare file tabs by path, not by URL string. Decode with `path_from_file_url`, put both sides into the same Unicode form (e.g. `unicode-normalization` NFC) and compare in `open_file_tab`, `update_file_document` and `relocate_file_tabs`. Optionally, on macOS, also make `file_url_string` write what Foundation writes (decomposed Unicode, plus encoding `[ ] ^ |`) so newly saved URLs keep matching.

## Clean areas (what I compared side by side)

**soprano-model, Workspace / AgentManager**
- **Id generation:** start value and the order ids are taken in session, window, layout-tab, pane, tab, split, automation-window and file-tab creation.
- **Close paths:** session (including replacing the last session with "Session 1"), window (keeping the session usable, `lastActiveWindowId` repair), pane, layout tab, pane tab, terminal close and automation-run close. Close confirmation is asked once and not again for closes nested inside it. Readiness generations are cancelled.
- **Focus and navigation:** `set_active_window` and last-window tracking, `focus_pane`/`focus_tab`/`show_tab`, maximize and exit-maximize, `navigate_to_pane`/`resize_pane`/`set_layout`, `insert_pane` with its fallback split, `split_pane` cloning, and editor/diff/Markdown file-pane routing.
- **Agent lifecycle and attention:** stop/restart, the exit/return-to-shell paths, status updates and waiting reasons, attaching agents, recording conversations, readiness generations, attention handling and running-command targets.
- **Snapshot and restore:** clamping, rebuilding layout tabs from depth-layer workspaces, deduplicating titles, repairing sessions, `nextId`, and the oldest no-windows format.
- **Hints and dashboard:** pane hints and dashboard ordering.

**soprano-model, persistence and models**
- **Swift-saved JSON:** `{"leaf":{"_0":…}}`, `splitPercentage` clamped on decode, camelCase keys, missing optional fields, `savedAt` as seconds since 2001 (distantPast survives), `TerminalSessionState`, `AgentConversation`, and the PaneType, AgentStatus and waiting-reason raw values all decode.
- **Other files:** SplitNode geometry, `WorkspaceWindowState`, `PaneState`, `TerminalTitle` (prompt pattern, omp brand, decorations), `AgentInstance`, `SessionManager`, and the process check in `process.rs` (pids ≤ 0 are already filtered out upstream).

**soprano-keys**
- **Event handling order:** typed pane hint, then prefix key and literal prefix, then prefix bindings, then direct bindings. That includes navigation passthrough, the menu-only bindings, focused content keeping its own chords (Option counted, as in Swift), the zoom-in alias and the Tab/back-tab key.
- **Pane hints and timers:** the pane-hint chord and its steps, both timeouts, and the change notifications.
- **Command table and claims:** the claim registry with `synchronize`, the `BindingCommand` table, `launched_agent_id` and `split_direction` all behave the same.