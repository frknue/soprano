I found 14 issues in `crates/soprano-term`. One is P1 and only hits Windows keyboard layouts that use AltGr; the most important macOS ones are a screen that can freeze after synchronized output and no backpressure on PTY output. `CARGO_TARGET_DIR=target/review-term cargo test -p soprano-term` passes: 95 unit tests and 6 integration tests. The tests don't cover any of the problems below, and no Windows build was run (cross-compiling from macOS isn't possible).

## Findings, most severe first

**1. [P1, Windows] Characters typed with AltGr reach the program as control codes**
- **Rust:** `keys.rs:86-91` only marks Alt as consumed, and only for non-ASCII text. Ctrl is never marked consumed.
- **References:**
  - GPUI on Windows reports AltGr as `control + alt` with `key_char` set and `prefer_character_input = true` (`gpui-pre-windows events.rs:1650-1715`). A handled key-down also skips `TranslateMessage`, so no `WM_CHAR` follows (`platform.rs:1183-1190`).
  - Ghostty's `ctrlSeq` (`ghostty/src/input/key_encode.zig:708-760`) turns a single UTF-8 byte plus an unconsumed Ctrl into a C0 byte, with an ESC prefix when Alt is also unconsumed.
- **Consequence:** on a German keyboard, AltGr+Q sends `ESC NUL` instead of `@`. The same happens to `{ } [ ] \ | ~`. AltGr+E (`€`, non-ASCII) sends `^E`.
- **Fix:** in `key_down`, when `event.prefer_character_input` is set, call `cx.propagate()` and return, so the text arrives through `replace_text_in_range`. The other option is to mark Ctrl and Alt as consumed when both are held and `key_char` is printable.

**2. [P2] A synchronized-output hold that is never released freezes the pane, and every output batch redraws**
- **Rust:** `view.rs:349-364` (`ingest`) calls `cx.notify()` after every batch. Nothing wakes the view at the hold deadline. `Vt::shows_change` (`vt.rs:2103`) and `render_hold_deadline` (`vt.rs:2182`) are never called.
- **References:**
  - Herdr `terminal.rs:557-575` sets a timer for the deadline and redraws only when `shows_change()` is true.
  - `terminal.h:1820-1827` says the embedder must time out holds itself.
- **Consequence:** if a program dies inside mode 2026 (an agent killed with Ctrl-C mid-frame), `frame()` keeps drawing the captured frame. It recovers only when some later repaint lands after 1 s. Unfocused or dashboard panes, and panes with a hidden or steady cursor, stay frozen until input arrives. Separately, output that changes only the title (agent spinners) still repaints the whole window.
- **Fix:** port Herdr's `_render_hold` timer, and call `cx.notify()` only when `shows_change()` is true.

**3. [P2] Output turns have no time limit, and the PTY has no backpressure**
- **Rust:**
  - `view.rs:313-324` drains the queue into a `Vec` within the 6 ms window and then processes the whole batch. The deadline limits collecting, not parsing.
  - `engine.rs:102,111-115` uses an unbounded channel, reading 64 KiB at a time.
- **Reference:** Herdr `terminal.rs:24-44` (`output_turn`) is a lazy iterator, so the deadline limits processing. Its core also gives flow-control credits.
- **Consequence:** running `cat` on a huge file, or `yes`, can block the UI thread for very large batches, and memory grows without limit when output outpaces parsing.
- **Fix:** process messages lazily under the deadline (port `output_turn`), and use `async_channel::bounded(N)` so `send_blocking` stalls the reader and the PTY pushes back on the program.

**4. [P2] Dropping a `Terminal` types newline + EOF into the PTY**
- **Rust:** `engine.rs:100` uses `take_writer()`. The writer thread drops it when `Terminal` drops (on close, or on `restart`).
- **References:** portable-pty `unix.rs:393-403` (`Drop for UnixMasterWriter`) writes `\n` and `VEOF`. Ghostty's `killPid` (`termio/Exec.zig:1170-1215`) only signals.
- **Consequence:** the SIGHUP goes to the shell first, and its foreground job gets HUP only later, so the job can read `\n^D` before it dies. A half-typed line in python, psql or a REPL then runs.
- **Fix:** on unix, write through a `File` made from `dup(master.as_raw_fd())`, or `mem::forget` the portable-pty writer.

**5. [P2] An exited terminal keeps reporting a running command**
- **Rust:** `engine.rs:190-203` doesn't clear `running_command` on `Exited`. `view.rs:506` only checks `destroyed`.
- **Reference:** Swift `TerminalSurfaceView.swift:705-710` uses `!ghostty_surface_needs_confirm_quit`, which is false once the child has exited (`Surface.zig:982`).
- **Consequence:** if the shell dies during a command (with `wait_after_command`), the running indicator stays on.
- **Fix:** on `Exited`, set `running_command` to false and emit `RunningCommandChanged(false)`.

**6. [P2] `CommandFinished` fires on every OSC 133;D, even without a 133;C**
- **Rust:** `engine.rs:259-261`.
- **Reference:** Ghostty ignores a D that has no C before it (`Surface.zig:1179-1181`).
- **Consequence:** shells that send D at the first prompt, on an empty Enter, or on Ctrl-C trigger spurious agent "finished" handling (`content.rs:471-478`).
- **Fix:** track `command_started`; set it on `OutputStart`, and on `CommandEnd` emit only if it is set, then clear it.

**7. [P2, host] Clipboard prompts outlive a closed or restarted terminal**
- **Rust:** `view.rs:812-833` (`destroy`) only clears the view's own map. `ClipboardConfirmationCoordinator::cancel_requests` has no caller outside its tests.
- **Reference:** Swift `TerminalSurfaceView.swift:2070-2072` cancels them on destroy.
- **Consequence:** the dialog stays up, queued prompts for the dead pane still appear, and answering them does nothing.
- **Fix:** have the host call `cancel_requests(entity_id)` on destroy or restart, for example via a `Destroyed` event.

**8. [P3] Unsafe-paste check skips bracketed pastes that contain `ESC[201~`**
- **Rust:** `view.rs:558-560`.
- **Reference:** Ghostty `Surface.zig:6256-6262` always treats an embedded end marker as unsafe.
- **Consequence:** the user is not asked. The encoder still neutralizes the marker, so this is a missing prompt, not an injection.
- **Fix:** treat `text.contains("\x1b[201~")` as unsafe before the bracketed-safe shortcut.

**9. [P3] Copy-mode gaps against Swift**
- **Mouse-tracking programs:** in copy mode, clicking over vim or htop doesn't move the copy cursor. `view.rs:1318-1320` only clears the selection; Swift `TerminalSurfaceView.swift:1613-1625` always updates the copy-mode selection.
- **Leaving mid-drag:** `finish_copy_mode` (`view.rs:913`) doesn't end an active drag (`selecting` and the autoscroll task). After Esc, `y` or Enter during a drag, the selection keeps growing, and copy-on-select fires on release. Swift calls `releaseTrackedLeftMouseButton` (`:1193`). Fix: call `release_tracked_left_button()` there.
- **Yank ignores the setting:** the yank clears the selection even with `selection-clear-on-copy = false` (`view.rs:~919`; Swift `:1199`).
- **Cursor drifts with the viewport:** `copy_cursor` (`view.rs:938-940`) is viewport-relative. After scrolling or new output during `v`, the selection end jumps. In Swift, Ghostty anchors it to the content.

**10. [P3] `submit_text` keeps empty pieces when splitting lines**
- **Rust:** `view.rs:610`.
- **Reference:** Swift `TerminalSurfaceView.swift:2126-2129` (`split(whereSeparator: \.isNewline)`).
- **Consequence:** `"a\r\nb"` becomes `"a  b"`, with two spaces.
- **Fix:** split on all newline characters and filter out empty pieces.

**11. [P3] `Drop` can send SIGHUP to a reused PID**
- **Rust:** `engine.rs:369-371` (`Drop`) calls `kill()`, which signals whenever `exit_status` is `None`. After `destroy()`, `ingest` returns early (`view.rs:350`), so `Exited` is never handled. Meanwhile the waiter thread has already reaped the child.
- **Consequence:** when the destroyed view drops later, the signal goes to a PID the system may have reused.
- **Fix:** have the waiter thread set a shared `AtomicBool` after `wait()` returns, and check it in `kill()`.

**12. [P3] `push_graphemes` ignores `GHOSTTY_OUT_OF_SPACE`**
- **Rust:** `vt.rs:2574-2578`.
- **Reference:** `grid_ref.h:148-158`: on out-of-space, `len` is the required size and the buffer is not filled.
- **Consequence:** a cell with more than 16 code points (combining-mark abuse, long emoji sequences) adds 16 NULs to `screen_text` and to link text.
- **Fix:** resize the buffer and retry, as `kitty_virtual_cell` already does.

**13. [P3] F13–F24 are dropped**
- **Rust:** `keys.rs:255-260` only maps F1–F12.
- **References:** GPUI reports `f13`–`f24`, and Ghostty has `GHOSTTY_KEY_F13..F25` (`key/event.h:253-265`).
- **Fix:** extend the range.

**14. [P3] Key releases leak to programs that didn't get the press**
- **Rust:** `view.rs:1099` and `input_metadata.rs:105-108`. An intercepted key without Cmd or Ctrl returns `PassThrough` without being recorded. Bindings handled as GPUI actions (Cmd+C, Cmd+V, Cmd+K) never touch the router.
- **Consequence:** programs using kitty keyboard flag 2 get release events without a press, which breaks the `KeyInterceptor` doc contract.
- **Fix:** record a press as handled outside the terminal for every intercepted or action-handled key.

## Checked and found clean
- **FFI with libghostty-vt:**
  - `Vt::drop` frees the search before the terminal, and the gesture is freed with the terminal; boxed `Shared` keeps a stable address for the callbacks.
  - Callback strings are copied immediately, and the clipboard-write reply happens inside the callback.
  - The PNG decoder allocates with `ghostty_alloc`, and its decode is bounded by the png crate's default limits.
  - Search and selection grid refs are converted before any mutation, and calling the render-state update from the hold callback is what the header prescribes.
  - Graphemes are read with the correct buffer size, and ownership of the paste encode buffers is correct.
- **PTY lifecycle:**
  - The waiter thread reaps the child, so no zombies.
  - Nothing is joined, so closing never hangs.
  - Exit is reported after the last output, or after 300 ms; that also covers ConPTY keeping its pipe open until `ClosePseudoConsole`.
  - Resize updates the VT, sends `TIOCSWINSZ` and the mode-2048 reports.
- **UTF-8 and sequences split across reads:** handled by the VT parser, the OSC 52 read scanner and the win32-input-mode watcher.
- **OSC 7 decoding:** decodes correctly.
- **Key and mouse encoding:**
  - The legacy and kitty key tables match Ghostty.
  - Option-as-Alt on macOS works.
  - Dead keys and IME go through GPUI's input context first (`gpui-pre-macos window.rs:2699-2800`).
  - Mouse reports with fractional cells are correct, and alternate scroll and focus reports are correct.
  - Bracketed paste encoding is correct.
- **Swift parity:**
  - Copy-mode key map: every key matches.
  - Clipboard coordinator: queue, cancel and re-entrancy match.
  - Drop escaping rules: match.
  - Key-equivalent router state machine: matches.
  - Mouse button, focus tracker and destruction gate: match.