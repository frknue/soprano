# soprano-term — API report from TermEngine

`crates/soprano-term` is built: a headless terminal engine (libghostty-vt plus an in-process PTY) and a GPUI `TerminalView`. Build, examples, tests and clippy are clean on macOS, and a Linux cross-check passes. Windows could not be checked from macOS, and the demo was built but not run.

## 1. Public API

**Engine (`engine.rs`), no window needed:**
- `TerminalLaunch { argv: Vec<String>, cwd: Option<PathBuf>, env: BTreeMap<String,String>, initial_input: Option<String>, wait_after_command: bool }` — same fields as `soprano_launch::LaunchSpec`.
  - An empty `argv` starts the login shell; an empty `env` inherits this process's environment; `cwd: None` means the home folder.
- `TerminalSize { cols, rows, cell_width, cell_height }`; cell sizes are in device pixels.
- `Terminal::spawn(launch, &TerminalSettings, TerminalSize) -> anyhow::Result<Terminal>`. Methods:
  - `receiver()`, `handle(PtyMessage)`, `pump()`, `pump_until(timeout, predicate)`, `take_events()`
  - `write(&[u8])`, `answer_clipboard_read(&Osc52Read, Option<&str>)`, `resize(TerminalSize)`, `size()`
  - `child_pid()`, `foreground_pid()`, `foreground_process_name()`, `foreground_cwd()`
  - `is_running_command()`, `exit_status()`, `has_exited()`, `waits_for_key_to_close()`, `kill()`, `vt()` / `vt_mut()`
- The PTY uses three threads (read, write, wait). Writes never block the UI thread. The exit is reported after the last output, or after 300 ms.

**`TerminalEvent`**, emitted by the view entity:
- `TitleChanged(String)`, `WorkingDirectoryChanged(String)` (OSC 7 decoded to a local path), `DesktopNotification{title, body}`, `Bell`
- `CommandFinished{exit_code}`, `RunningCommandChanged(bool)`, `ChildExited{exit_code}`, `CloseRequested`
- `ClipboardWrite{location, text}` and `ClipboardReadRequested(Osc52Read)` — the view handles these itself; only a headless `Terminal` reports them.
- `ClipboardConfirmationRequested(ClipboardRequest{id, kind, content})`, `AgentInputSubmitted`, `CopyModeStateChanged(KeybindingState)`, `FocusRequested`, `Focused`

**`TerminalView`** (`view.rs`, implements `EventEmitter<TerminalEvent>`, `Focusable`, `EntityInputHandler`):
- **Construction:** `new(launch, settings, window, cx) -> Result<Self>`, `spawn(launch, settings, window, &mut App) -> Result<Entity<Self>>` (added for AppShell), `from_terminal(...)`.
- **Input:** `write(&[u8])`, `paste(&str, cx)` (checks `ghostty_paste_is_safe` and asks first when unsafe), `paste_from_clipboard`, `paste_selection_clipboard`, `insert_text`, `submit_text(&str, cx) -> bool`, `send_key(&Keystroke, cx)`, `drop_payload(&DropPayload, window, cx)`.
- **Selection:** `copy_selection(cx) -> bool`, `select_all`, `clear_selection`, `has_selection`, `selection_text`, `clear_screen`.
- **Scrolling and search:** `scroll(lines)`, `scroll_to_top` / `scroll_to_bottom`, `scroll_pages`, `search(query)`, `search_next` / `search_previous`, `clear_search`, `search_progress`.
- **Copy mode:** `enter_copy_mode(cx) -> bool`, `cancel_copy_mode`, `is_in_copy_mode`.
- **Screen text:** `visible_text() -> Option<String>`, `screen_text(scrollback_lines) -> ScreenText { text, spans: Vec<StyleSpan> }`, `interaction_state()`.
- **Host hooks:** `set_key_interceptor(Option<KeyInterceptor>)` where `KeyInterceptor = Box<dyn Fn(&KeyDownEvent, &mut Window, &mut App) -> bool>`; returning `true` keeps the key, and its release, from the program. `resolve_clipboard_request(id, allowed, cx)`.
- **Settings and lifecycle:** `set_settings`, `set_theme`, `change_font_size(delta)`, `reset_font_size(configured)`, `destroy(cx)` (safe to call twice), `restart(launch, cx)`, plus getters: `title`, `working_directory`, `child_pid`, `foreground_process_name`, `foreground_cwd`, `is_running_command`, `has_exited`, `grid_size`, `with_terminal`.
- **Key bindings:** `actions!(terminal, [Copy, Paste, SelectAll, ClearScreen, ScrollToTop, ScrollToBottom, ScrollPageUp, ScrollPageDown])` in key context `"Terminal"`. `default_key_bindings()` gives Cmd chords on macOS and Ctrl+Shift / Shift chords elsewhere.

**Other modules:**
- `settings`: `TerminalSettings` (font family/size, theme, padding, cursor style and blink, scrollback, mouse hide, copy-on-select, clipboard read/write policy, paste protection, selection clear on copy, option-as-alt), with `from_user_config(theme)` and `apply_ghostty_config(&GhosttyConfig)`. `GhosttyConfig::{default_files, load_default_files, load_file, parse}`. Defaults: JetBrains Mono 13, padding 14×12.
- `theme`: `TerminalTheme { background, foreground, cursor, cursor_text, selection_background, palette: [Color; 16] }`, `unfocused_cursor()`, `FAINT_OPACITY`.
- `clipboard`: `ClipboardConfirmationCoordinator::new(presenter) -> Rc<_>` with `enqueue(surface_id, kind, content, resolve)` and `cancel_requests(surface_id)`; the `ClipboardConfirmationPresenter` / `ClipboardConfirmationPresentation` traits; `ClipboardConfirmationPrompt` with its titles, messages and button labels.
- `copy_mode`, `input_metadata`, `interaction`, `drop_content` (`shell_escape`, `text_from`), `keys`, `links`, `osc`, `os`, `vt` (`Vt`, `ScreenText`, `StyleSpan`, `paste_encode`, `paste_is_safe`).

## 2. Swift files ported, and tests

| Swift | Rust |
|---|---|
| `TerminalCopyMode.swift` | `copy_mode.rs`, with the key handling in `view.rs` |
| `TerminalInputMetadata.swift` | `input_metadata.rs` |
| `TerminalDropContent.swift` | `drop_content.rs` |
| `TerminalInteractionState.swift`, plus `TerminalMouseButtonState`, `TerminalCommandActivity`, `SurfaceDestructionGate` and focus sync from `TerminalSurfaceView.swift` | `interaction.rs` |
| `ClipboardConfirmationCoordinator.swift` (queue and prompt logic) | `clipboard.rs` |
| The `GhosttyAppManager.swift` config, callbacks and clipboard callbacks | `settings.rs`, `engine.rs`, `osc.rs`, `view.rs` |
| The terminal parts of `TerminalSurfaceView.swift` | `view.rs`, `keys.rs` |
| Herdr's `vt.rs`, `terminal.rs`, `sprites.rs`, `win32_keys.rs`, `links.rs` | adapted, each file starting with the attribution line |

Swift tests ported:
- `TerminalCopyModeTests`: 8 of 8.
- `TerminalDropContentTests`: 3 of 3 (pasteboards replaced by `DropPayload`).
- `TerminalInputMetadataTests`: 16 of 16.
- `TerminalMouseButtonStateTests`: 3 of 3.
- `ClipboardConfirmationCoordinatorTests`: 7 of 10.
- `TerminalSurfaceFocusTests`: 6 of 6, as logic tests on `SurfaceFocusTracker`.
- `RunningCommandIndicatorTests`: the activity test (1).
- `SurfaceDestructionGateTests`: 1 of 1.
- `TerminalThemeTests`: the unfocused-cursor test.

There are also new tests for OSC parsing, the Ghostty config, links (Ghostty's URL cases), key encoding, the vt wrapper, and scrolling/mouse. The integration test `tests/headless_terminal.rs` (6 tests) runs real processes headlessly, including `/bin/sh -c 'printf hello'` read back from the grid.

Skipped:
- 3 AppKit dialog-presenter tests: the dialog belongs to the host app.
- The remaining `TerminalThemeTests` (catalog, folio resolution, Ghostty palette lines): they test `AppTheme`, which is soprano-config's.
- The other `RunningCommandIndicatorTests`, and `TerminalLifecycleTests`: sidebar, tab bar and AgentManager UI.

## 3. Decisions and deviations

**Clipboard and paste**
- **OSC 52 reads:** libghostty-vt has to answer a read inside its callback, which can't wait for the user. So reads are found in the output by `Osc52ReadScanner` and answered later by writing the reply to the PTY.
- **OSC 52 writes:** these follow `clipboard-write`: allow (the default) writes directly, ask goes through `ClipboardConfirmationRequested`. This matches Swift with the default Ghostty config.
- **Paste protection:** Ghostty's rule, extended to read the `clipboard-*`, `selection-clear-on-copy` and `macos-option-as-alt` keys from the Ghostty config.
- **Copy-on-select:** writes the Linux primary selection; on other platforms it uses an in-process selection clipboard that middle-click pastes from.

**Copy mode**
- Selections are set directly through libghostty-vt rather than through Swift's synthetic mouse clicks and binding actions.
- The keys and edge behavior are the same.
- The copy-mode cursor uses the terminal theme's cursor and selection colors instead of the app's caret and text-selection colors.

**Keyboard**
- GPUI doesn't report which Option key is down, so `macos-option-as-alt = left/right` applies to either side.
- GPUI has no key codes, so `KeyEquivalentRouter` is generic over the key and the view uses GPUI key names.

**Rendering**
- Ligatures are off so every character stays in its own cell; Ghostty has them on by default.
- Herdr's bundled Nerd Font icon fitting was not ported.
- Cell height is the font's ascent plus descent; Herdr multiplied by 1.15.

**Process and OS**
- Foreground process name and folder come from `proc_name` / `proc_pidinfo` on macOS and `/proc` on Linux; on Windows they return `None`, since ConPTY has no foreground process group.
- `TERM` and the shell-integration environment are left to soprano-launch.
- The wait-after-command message reads "[Process exited. Press any key to close the terminal.]"; the next key emits `CloseRequested`.

**Other**
- `ClearScreen` sends a form feed only when the shell is not running a command.
- Mouse-hide-while-typing sets GPUI's app-wide `CursorHideMode` when the terminal gains focus.

## 4. Verification

All commands used `CARGO_TARGET_DIR=target/agent-soprano-term`:
- `cargo build -p soprano-term --examples`: finished; `examples/term_demo.rs` builds.
- `cargo test -p soprano-term`: 94 unit tests and 6 integration tests passed.
- `cargo clippy -p soprano-term --all-targets`: no warnings.
- `cargo fmt -p soprano-term`: applied.
- Linux cross-check (`--target x86_64-unknown-linux-gnu`, separate target dir `agent-soprano-term-cross`): no errors.
- Windows cross-check (`--target x86_64-pc-windows-msvc`): could not run. gpui-pre's own build script fails cross-compiling from macOS before reaching this crate.