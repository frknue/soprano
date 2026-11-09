I found 25 places where the Rust port behaves differently from the Swift, in all three crates. The two most serious: on Linux the settings watcher reloads `settings.json` in an endless loop, and any automation evaluated during the repeated hour when clocks go back stops running for good. All the tests in the three crates pass (`CARGO_TARGET_DIR=target/review-cli cargo test -p soprano-config -p soprano-launch -p soprano-ipc`: 182, 41, 13, 28 and 28, no failures). This was a read-only review; I edited nothing.

The parts you asked me to prioritise are correct: agent command lines and environment, `settings.json` parsing and writing, and CLI output and exit codes. I checked each finding against both sources. The watcher, cron and Ghostty-order findings I also checked against the library source (notify 8.2.2, chrono 0.4.45, `ghostty/src/termio/Exec.zig`).

## High

**1. Linux: the settings watcher reloads itself forever** (soprano-config, `watcher.rs:55-59` vs `ConfigFile.swift` `armFileSource`/`armDirectorySource`)
- Rust forwards every notify event (`if result.is_ok() { send(Message::Event) }`). notify's inotify backend watches with `WatchMask::OPEN` (`inotify.rs:429`) and reports it as `EventKind::Access(Open)`.
- Each reload's `config_file::read` opens `settings.json`, which raises an open event, which schedules the next reload 120 ms later. That is about 8 reads a second, permanently.
- While the file has a syntax error, the "unchanged" early return is skipped, so observers and the UI are notified at that rate too.
- Swift only listened for write, extend, delete, rename, link and revoke. macOS (FSEvents) and Windows are not affected, which is why tests miss it.
- **Fix:** drop `EventKind::Access(_)` in the callback. Ideally also only forward events for the settings file, its link target, or the watched folders.

**2. Cron: no next run during the repeated hour** (soprano-config, `cron.rs:118` vs `CronSchedule.swift:155-157`)
- `date.with_second(0)?.with_nanosecond(0)?` goes through chrono's `map_local`, which calls `from_local_datetime(..).single()` and returns `None` for an ambiguous local time. Swift's `dateInterval(of: .minute)` always succeeds.
- `soprano-automations/src/scheduling.rs:72/90` saves `next_run_at: next()`, and line 76 keeps the saved value from then on. An automation that runs or is edited during that hour gets `None` stored and never runs again until it is edited. A nightly `0 2 * * *` in Europe/Berlin is the typical case.
- `latest_occurrence` (`cron.rs:~157`) also stops early, so a run can be wrongly marked Missed.
- **Fix:** floor on the instant: `let s = date.timestamp(); zone.timestamp_opt(s - s.rem_euclid(60), 0).single()?`.

**3. Non-UTF-8 arguments or environment panic the binary** (`crates/soprano/src/main.rs:23-24`, plus `soprano-launch/src/spec.rs:79` and `command_runner.rs:177`)
- `std::env::args()` and `std::env::vars()` panic on any value that isn't valid Unicode. Swift's `CommandLine.arguments` and `ProcessInfo.environment` never trap.
- One Latin-1 variable or filename crashes app start, every `agent-event` hook, every pane launch and every CLI run.
- The same pattern appears in `soprano-accounts/src/command.rs:196` and `soprano-agents/src/opencode_reader.rs:97`.
- **Fix:** use `args_os()`/`vars_os()` and convert lossily (or skip bad entries), and widen `run_cli`'s signature to allow that.

## Medium

**4. The profile's `env` no longer wins over the terminal variables** (soprano-launch, `spec.rs:417-422`)
- Rust merges the profile and pane env first, then runs `apply_terminal_environment` and `apply_shell_integration`, which overwrite `TERM`, `COLORTERM`, `TERM_PROGRAM_VERSION`, `GHOSTTY_SHELL_FEATURES` and `ZDOTDIR`.
- Ghostty applied Swift's `env_vars` last (`Exec.zig:817-821`, after `TERM` at 644/661 and shell integration).
- A profile with `env: {TERM: "xterm-256color"}` now gets `xterm-ghostty`. A profile `ZDOTDIR` is moved into `GHOSTTY_ZSH_ZDOTDIR` instead of being used.
- **Fix:** build the base env, add Ghostty's variables and shell integration (reading the base env's `ZDOTDIR`, `ENV` and `HISTFILE`), then apply `self.env` last.

**5. A huge cron step is truncated or panics** (soprano-config, `cron.rs:188,217` vs `CronSchedule.swift:85-89,106`)
- `value as u32` turns `*/4294967296` into 0, and `step_by(0)` panics on a user-written schedule.
- `*/4294967297` becomes 1, i.e. every minute; Swift's `stride` gives just `{low}`.
- **Fix:** `usize::try_from(value).unwrap_or(usize::MAX)` and keep the step as `usize`.

**6. A duplicate key rejects the whole `settings.json`** (soprano-config, `jsonc.rs:98-110` with derived `Deserialize` in `config.rs`)
- serde fails a struct on a repeated field ("duplicate field `theme`"), so nothing in the file is applied. Swift's `JSONDecoder` does not throw on duplicates.
- Map fields (`bindings`, `automations`, `env`) take the last copy, while the writer edits the first one. A UI edit is then hidden by a later duplicate.
- **Fix:** keep the first occurrence in the JSONC layer, e.g. blank later duplicates in `strict_json` the way trailing commas are blanked. Which copy Swift keeps is from memory of swift-foundation (I believe the first); that Swift doesn't reject is certain.

**7. Windows: Soprano's CLI folder never reaches PATH** (soprano-launch, `spec.rs:402-415`)
- The code looks up `"PATH"`, but Windows names it `Path`. It falls back to the Unix `DEFAULT_PATH`, inserts a separate `PATH` key, and the env map ends up holding both `PATH` and `Path`.
- From the reviewer's reading of portable-pty, which lowercases keys on Windows, the original `Path` wins, so the CLI folder never reaches PATH. I didn't trace that last step myself.
- **Fix:** find the existing key case-insensitively and prepend to it; use no Unix default on Windows.

**8. Windows: `Resources::cli_dir` misses `bin\soprano.cmd`** (soprano-launch, `resources.rs:~97`)
- It looks only for `soprano`/`soprano.exe`, but `scripts/package-windows.ps1:108-112` ships `bin\soprano.cmd`.
- So `resources\bin` (with the bundled `omp.cmd` launcher) is never on PATH, and `omp web` in a pane runs the plain installed omp.
- **Fix:** also accept `soprano.cmd`.

**9. Linux: the Unix socket folder is trusted without checking it** (soprano-ipc, `transport.rs` `imp::prepare`)
- `/tmp/soprano-<uid>` (used when `$TMPDIR` is unset) is accepted even if it already exists, is owned by someone else, or is a symlink; the `set_permissions` error is ignored.
- Another local user can pre-create it and intercept agent events, Markdown paths and browser `eval`/`fill` traffic, and send fake replies.
- **Fix:** check with `lstat` that it is a real folder owned by `getuid()` with mode 0700; prefer `$XDG_RUNTIME_DIR`.

**10. `GHOSTTY_SHELL_FEATURES` is hardcoded** (soprano-launch, `shell_integration.rs:16,40`)
- It is always `cursor:blink,path,title`. Ghostty built it from the user's config (`Exec.zig:768-784`: `cursor-style-blink`, `shell-integration-features`, `shell-integration = none`). `soprano-term/src/settings.rs` already reads `cursor-style-blink`.
- Users with a steady cursor get a blinking one at every prompt, and `shell-integration = none` is ignored.
- **Fix:** pass those settings into `LaunchContext` and build the string the way Ghostty's `setupFeatures` does.

**11. `PWD` is not set to the pane's folder** (soprano-launch, `spec.rs` `finish`)
- Ghostty sets it (`Exec.zig:864`); Rust passes the app's own `PWD` through.
- For a folder reached through a symlink, the shell reports the resolved real path, so the saved tab folder changes.
- **Fix:** `env.insert("PWD", cwd)` last.

**12. Whole-number floats are rejected for integer keys** (soprano-config: `prefixTimeoutMs`, `graceMinutes`, `precheckTimeoutSeconds`)
- serde's `i64` rejects `1500.0`; Swift's `JSONDecoder` accepts exactly integral numbers.
- The resulting message, "…should be a number", is wrong for a value that is a number.
- **Fix:** a `deserialize_with` that accepts an integral `f64`.

**13. A UTF-8 BOM makes `settings.json` unreadable** (soprano-config, `config_file.rs:64`)
- `read_to_string` keeps U+FEFF and the parser fails at 1:1, so all settings stay at defaults and every UI write fails. Swift's String decoding drops the BOM (medium confidence).
- **Fix:** strip a leading `\u{FEFF}`.

**14. Observers can end up on an older snapshot** (soprano-config, `store.rs` `apply_edit`/`reload_from_disk` → `notify_observers:386`)
- The snapshot is taken after the lock is released, so a UI write and a watcher reload can deliver out of order. Observers then keep the older state until the next change. Swift ran everything on the main actor.
- **Fix:** snapshot (or record a generation number) while holding the lock and skip deliveries older than the last one.

## Low

**IPC (`transport.rs`, `agent_event.rs`, `markdown.rs`):**
- The 4 MiB line cap turns a large browser reply into an immediate "Timed out waiting for Soprano browser automation." (exit 1). An oversized request is dropped silently and the CLI waits 15 s.
- The accept loop spins at 100% CPU when accept keeps failing (e.g. out of file descriptors).
- On Windows `set_recv_timeout` does nothing, so a client that connects and never writes blocks a server thread forever.
- The 180-character banner limit counts code points, not grapheme clusters, so it can cut a flag or emoji in half; this isn't in the deviations list.
- `~user/` Markdown paths are not expanded.
- macOS `PROC_PIDTBSDINFO` is refused for processes owned by another user, where Swift's `sysctl` reads any process. The result only differs in unusual setuid chains (`PROC_PIDT_SHORTBSDINFO` is exempt from the check).

**Launch:**
- PowerShell `run_cli` and chat end with `exit $LASTEXITCODE`, which exits 0 for a CLI that isn't installed, so the "is not installed" (status 127) hint never shows (medium confidence).
- `failure_message` uses `.lines()`, which doesn't split on `\r` and other newline characters. For `50%\r100% failed: x` it returns the whole line where Swift returns `100% failed: x`.
- `first_url` returns the raw match; Swift's `URL(string:)` rejected malformed URLs.
- A relative chat `cwd` falls back to `$HOME` instead of the app's working folder.

**Config:**
- A relative `SOPRANO_CONFIG`/`XDG_CONFIG_HOME` stays relative (`config_file.rs:29-34`), and the watcher can't watch it.
- `expand_path` trims a Windows drive root: `C:\` becomes `C:`, which means the current folder on drive C.
- Writing NaN produces `null`; Swift threw an error.
- Shape-error paths and type names read differently (`agents[0].id` vs `agents.[0].id`).
- Automation sorting compares code points after lowercasing instead of `localizedStandardCompare`, so names like "Änderungen" sort after Z.
- A key-chord key token is counted in chars, not grapheme clusters, so a decomposed `é` or `❤️` is rejected.
- Cadence text such as "Daily at 2:00 PM" uses a normal space; macOS puts U+202F before PM.

## Not a regression
- **TOML quoting for Codex `notify`:** the porting report already lists the TOML-escaping difference. Swift's `JSONEncoder` escaped `/` as `\/`, which isn't a valid TOML escape, so the old notify value was probably malformed. Rust's output is valid.
- **Duplicate command runner:** `soprano_launch::CommandRunner` and `ChatLaunch` have no callers outside their own tests. `soprano-accounts/src/command.rs` is a second, already-diverging copy of the command runner, and the API report's claim that accounts and automations use `run_cli` is wrong.

## Checked and matching Swift
- **Agent launch:** per-agent argv; the whole `-lic` script (`trap true INT`, sorted account exports, `agent-event stopped`, the `unset` line, the zsh fallback); resume handling and `SOPRANO_RESUME_SESSION_ID`; and the automation flags `--model` vs `--model=`, `--dangerously-skip-permissions`, `--dangerously-bypass-approvals-and-sandbox`, `--auto-approve`, `--standalone`, `--auto`, `--prompt=` and `--`.
- **Hook configs:** the Claude `--settings` hook JSON; the Codex `-c` overrides; both OpenCode config contents; the shell quoting.
- **`settings.json` handling:** comment-preserving read and write; every limit, clamp and issue message; keybinding resolution and conflict checks; all 66 default keybindings; Automation JSON keys and defaults; the cron grammar and its messages.
- **CLI:** dispatch order; every output string; exit codes 0, 1 and 2; the usage and help text; markdown, browser and navigation parsing; `agent-event` flags, payload parsing and the hook-owner process lookup.

Two regression tests would pin the main fixes: `"0 * * * *"` evaluated from Berlin 2026-10-25 02:30 CEST should return a next run, and `*/4294967296` should give `{0}` without panicking.