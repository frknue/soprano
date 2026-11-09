# soprano-config — API report from ConfigPort

> `ConfigPort` is running a newer turn. The output below is from its PREVIOUS run (published 6.0s ago), not the current one. Live progress: `history://ConfigPort`; its next result auto-delivers to its owner.The `soprano-config` crate is ported and done: `cargo test -p soprano-config` passes 182 tests (0 failures, 5 repeat runs all green), clippy has no warnings, and it also builds clean for Linux and Windows targets. The changelog test passes now that you bumped the workspace version to 0.6.0.

## 1. Public API (everything is re-exported from the crate root)

**`jsonc`** — reads comment- and trailing-comma-tolerant JSON, and writes single keys without disturbing the rest of the file
- `strict_json(&str) -> Result<String, ParseError>`
- `decode<T: DeserializeOwned>(&str) -> Result<T, DecodeError>`
- `setting(&serde_json::Value, &[&str], &str) -> Result<String, ParseError>` (`Value::Null` writes JSON `null`)
- `removing(&[&str], &str) -> Result<String, ParseError>`
- `ParseError { message, line, column }` displays as "msg (line L, column C)".
- `DecodeError::{Syntax(ParseError), Shape { path, message }}`

**`config_file`**
- `PATH_ENVIRONMENT_KEY` (`"SOPRANO_CONFIG"`)
- `config_path()` and `config_path_from(env_fn, home)`: `SOPRANO_CONFIG` > `XDG_CONFIG_HOME/soprano/settings.json` > `~/.config/soprano/settings.json`, on every OS.
- `config_directory()`, `display_path(&Path)`, `abbreviating_home(&str)`, `exists`
- `read(&Path) -> io::Result<Option<String>>`
- `write(&str, &Path)`: atomic, and writes through symlink chains (up to 8 hops) instead of replacing the link.
- `resolving_symlink`, `create_if_missing(&AppSettings, &KeyBindingConfig, &Path) -> io::Result<String>`
- `template(..)` / `template_for(.., KeyPlatform)`

**`config`**
- `SopranoConfig` (all keys optional, serde camelCase, same key names as Swift), with `resolved() -> ResolvedConfig` and `resolved_with(&AppSettings, &KeyBindingConfig, &[AgentProfile])`.
- Section types: `NotificationsConfig`, `StatusBarConfig`, `KeybindingsConfig`, `AgentConfig`, `BindingOverride::{Chord, Disabled}`.
- `ResolvedConfig { settings, keybindings, agents, automations, issues, customized_binding_ids, disabled_binding_ids, configured_agent_ids }`, with `defaults()` and `install_agents()`. `install_agents()` puts the merged agent list into `AgentCatalog::shared()`.
- `ConfigIssue { severity: Severity::{Error, Warning}, message, line }` with `id()`.
- Also: `Limits`, `expand_path`, `install_agents(&AgentCatalog, &[AgentProfile])`, `default_name`, `default_color`.

**`store::ConfigStore`** — a cloneable handle, safe across threads
- Constructors: `new(path)` (installs agents into the shared catalog), `with_catalog(path, Arc<AgentCatalog>)`, `for_app()`.
- Startup: `start(watching, &AppSettings, &KeyBindingConfig)` and `start_with_state(watching, &StateStore)`. The second seeds first-run values from the `soprano-app-settings` and `soprano-keybindings` keys.
- Reading: `reload_from_disk()`, `text()`, `config()`, `resolved()`, `settings()`, `keybindings()`, `issues()`, `file_issues()`, `snapshot()`, `display_path()`, `file_path()`.
- Writing: `write(impl Into<Value>, &[&str]) -> bool`, `remove(&[&str]) -> bool`.
- Observers: `add_observer(id, Fn(&ConfigSnapshot) + Send + Sync)` and `remove_observer(id)`. Callbacks run on the thread that made the change, with the store's lock released.
- Also: `stop_watching()`, `open_in_editor()`, `reveal_in_file_manager()` (both return `Result<(), String>`).

**`watcher::ConfigFileWatcher`**
- `start(path, debounce, rearm_interval, Fn())`, `start_default(path, Fn())`, `stop()`; it also stops when dropped.

**`key_chord`**
- `KeyChord { mode, key, ctrl, meta, shift }` with `new(mode, key, ctrl, meta, shift)`, `parse`, `from_binding`, `canonical_string`, `display_string`, `display_string_for(KeyPlatform)`, `applied(&KeyBinding)`, `platform_modifiers(KeyPlatform) -> PlatformModifiers`.
- `KeyPlatform::{Mac, Other}` with `current()`.
- Keycaps: `keycaps` / `keycaps_for(binding, prefix_key, platform) -> Vec<String>`, `settings_keycap_alternatives(_for)`, `prefix_legend(_for)`, `is_shifted_symbol`.

**`DefaultKeybindings`**
- `config()` and `config_for(KeyPlatform)`: all 66 bindings with id, label, description and category; `default_keys` is rendered for the platform.
- `merged_config(&saved)` (legacy migration), `load(&StateStore)`, `STATE_KEY`.

**Other**
- `AppSettings` (serde, every field defaults when missing) with `default_settings()`, `load(&StateStore)` and `STATE_KEY`.
- `AppearancePreference` (`ALL`, `raw_value`, `from_raw`).
- `KNOWN_THEME_IDS` (the 10 ids from `Theme.swift`), `FOLIO_THEME_ID`, `is_known_theme_id`.
- `AppVersion::{UNBUNDLED, current(), resolve(Option<&str>)}`.
- `Automation` (`AGENT_IDS`, `is_valid_id`, `make_id`, `config_object() -> Value`, `cadence()`), `AutomationEntry`, `AutomationWorkspace`, `AutomationSession`, `resolve_automations`.
- `CronSchedule::parse`, `next_occurrence` / `latest_occurrence` (generic over chrono time zones), `CronParseError`.
- `AutomationCadence` (`from_schedule`, `expression`, `summary`, `time`).

## 2. Ported files and tests

| Swift | Rust |
|---|---|
| `Config/JSONCText.swift` | `jsonc.rs` |
| `Config/ConfigFile.swift` (file + watcher) | `config_file.rs`, `watcher.rs` |
| `Config/SopranoConfig.swift` | `config.rs` |
| `Config/ConfigStore.swift` | `store.rs` |
| `Config/KeyChord.swift`, plus `MainWindowController.keycaps` and `SettingsKeycaps` | `key_chord.rs` |
| `Config/DefaultKeybindings.swift` | `default_keybindings.rs` |
| `Models/AppSettings.swift`, theme ids from `Theme.swift` | `app_settings.rs` |
| `Automations/Automation.swift` (`Automation` and its settings entry) | `automation.rs` |
| `Automations/CronSchedule.swift` | `cron.rs` |
| `Utilities/AppVersion.swift` | `app_version.rs` |

I ported `CronSchedule.swift` as well, because an automation entry's `schedule` is validated by parsing it, and the config tests check its error messages. The scheduling and runner files stay with soprano-automations.

**Tests ported** (182 in total, with a few added for Linux/Windows display, keycaps and paths)
- All of JSONCText (15), KeyChord (12), CommandPaletteKeycap (7) and SettingsKeycap (4).
- DefaultKeybindings: 22 config-side tests; the five "gains a new binding" cases are folded into one test.
- SopranoConfig (34), AutomationConfig (7), CronSchedule (13), NotificationSettings (8), WindowBarSettings config parts (4), ConfigFileHomeAbbreviation (2), AppVersion (3 + 1), ChangelogVersion (2).
- ConfigStore: 19, including the watcher tests for atomic saves, a replaced config directory and a re-pointed symlink.
- SettingsConfigWriting: the file-writing logic of 9 tests (theme, the on/off switches, appearance, uptime, prefix key, project directory, clamped timeout, syntax-error issue, issue reporting).

**Tests skipped**
- `SettingsEditingTests` (AppKit field wiring) and `MainWindowAppearanceTests` (NSWindow).
- The UI-control parts of `SettingsConfigWritingTests`: popup and switch wiring, the theme manager, the prefix recorder refusing Shift, the page not rebuilding.
- The `KeybindingManager.*` assertions in `DefaultKeybindingsTests` and `ConfigStoreTests` (dispatch, split direction, the NSEvent back-tab key). Those belong to soprano-keys.
- The `TerminalConfig.forAgent` part of two agent tests. Here they check only that args, env, cwd and launch script reach the profile.
- `ChangelogVersionTests`' check that the build number tracks the marketing version (Rust has no separate build number).
- The AppVersion "non-string version value" case (doesn't apply in Rust).

## 3. Cross-platform decisions and deviations

- **Linux/Windows keys:** `cmd` shows as Ctrl+Shift and `cmd+shift` as Ctrl+Shift+Alt. KeysPort agreed to `ctrl+cmd` → Ctrl+Alt and `ctrl+cmd+shift` → Ctrl+Shift+Alt. A `cmd` chord on a symbol that already needs Shift (such as `cmd+plus`) shows as `Ctrl+Shift++` without Alt. I asked KeysPort to match this in its key matching; they haven't replied yet.
- **`default_keys` per OS:** the strings shipped in each built-in binding are the Swift ones verbatim on macOS. On Linux/Windows they are generated from the chord; zoom-in becomes `Ctrl+Shift++ / Ctrl+Shift+=`.
- **Keycaps on Linux/Windows** use words: `Ctrl+A` then `G`, `Ctrl+Shift+Tab`, `Esc`, `Enter`, `Backspace`.
- **Template wording:** on Linux/Windows, comments that mention macOS (title bar, notification settings, "system follows macOS") and the ⌘ shortcuts are reworded, and one line explaining `cmd` is added. The macOS template is unchanged.
- **Watcher:** it uses `notify` on the config directory and on the symlink target's directory, instead of watching file descriptors. It rebuilds the watch when the directory's identity (device/inode on Unix, creation time on Windows) or the symlink target changes. It retries every 2 s only while the directory is missing; debounce is 120 ms.
- **Arrow keys** keep AppKit's private-use characters (`\u{F700}`–`\u{F703}`), so bindings stored by the Swift app still match.
- **Wrong-type errors** in `settings.json` are described from serde's message (via `serde_path_to_error`), e.g. "keybindings.prefixTimeoutMs should be a number. Nothing in the file was applied."
- **Text positions** are counted in Unicode characters rather than Swift grapheme clusters; `\r\n` still counts as one line break.
- **Cadence summaries** are English with 12-hour times ("2:00 PM") rather than following the user's locale.
- **Theme in the template** is written as an escaped JSON string; Swift wrote the raw id. The output is identical for real theme ids.

## 4. Verification

- `CARGO_TARGET_DIR=target/agent-soprano-config cargo test -p soprano-config` → 182 passed, 0 failed.
- `CARGO_TARGET_DIR=target/agent-soprano-config cargo clippy -p soprano-config --all-targets` → no warnings.
- `CARGO_TARGET_DIR=target/agent-soprano-config-cross cargo clippy --target x86_64-unknown-linux-gnu -p soprano-config --all-targets` and the same for `x86_64-pc-windows-msvc` → clean.
- `cargo fmt -p soprano-config` was applied.

I made one edit with an ad-hoc Python script instead of the edit tool: in `store.rs` it replaced a `Box::leak`ed agent catalog with `Arc` and removed a stray helper module.

Dependencies added to the crate: `notify` 8.2, `chrono` 0.4.45, `serde_path_to_error` 0.1.20, plus `tempfile` and `chrono-tz` 0.10 for tests only. `Cargo.lock` was updated by cargo. Nothing is left as a TODO or stub.