# soprano-keys — API report from KeysPort

`soprano-keys` is finished and passes its checks: 56 tests pass, clippy is clean, `cargo fmt --check` is clean and docs build with no warnings. Main never answered my question about pane hints on Linux/Windows, so they currently use Alt+Shift+letter (see section 3).

## 1. Public API
The crate depends only on `soprano-types`, with no gpui. Everything below is re-exported at the crate root.

**`event`**
- `enum Platform { MacOs, Linux, Windows }` with:
  - `current()`
  - `binding_modifiers(ctrl, meta, shift) -> Modifiers`: the physical keys a binding needs on that OS.
  - `adds_shift(&KeyBinding) -> bool`
  - `is_pane_shortcut_chord(Modifiers) -> bool`
- `struct Modifiers { ctrl, alt, shift, cmd }`
- `struct KeyEvent { key, base_key: Option<String>, ctrl, alt, shift, cmd, is_repeat }`
  - `key` follows AppKit's `charactersIgnoringModifiers`: Shift is applied and letters may be either case. Keys without a character use names: `tab`, `escape`, `enter`, `space`, `backspace`, `delete`, `left`, `right`, `up`, `down`, `home`, `end`, `pageup`, `pagedown`, `f1`…`f35`.
  - `base_key` is the key without Shift (GPUI `Keystroke::key`).
  - Builders: `new`, `with_ctrl`, `with_alt`, `with_shift`, `with_cmd`, `with_base_key`, `repeated`. Also `modifiers()`, `binding_key()`, `base_binding_key()`.
- `fn binding_key(&str) -> String` lowercases the key and turns named keys into the characters `settings.json` stores (`"\t"`, `"\u{F703}"`). The back-tab character maps to `"\t"`.
- `const ESCAPE`

**`resolver`**
- `KeybindingResolver::new(config: KeyBindingConfig, platform)`
- `handle(&KeyEvent, &KeyContext) -> KeyOutcome`
- `apply_config(config)`: clears a half-typed prefix chord.
- `modifiers_changed(Modifiers)` and `app_resigned_active()`
- `copy_mode_changed(KeybindingState)`
- `next_deadline() -> Option<Instant>` and `tick(now) -> bool`: the host runs the timers. `handle` also expires any timer the host hasn't fired yet.
- `drain_changes() -> Vec<ResolverChange>`
- Getters: `state()` (Normal/Prefix), `display_state()` (status-bar mode, including copy modes), `is_control_key_held()`, `typed_pane_hint()`, `config()`, `platform()`
- `struct KeyContext<'a> { focused_content, keys_captured, active_target: Option<TerminalTarget>, claims: &dyn PassthroughClaims, pane_hints: &[PaneHintAssignment], now }`, with `KeyContext::new(now)` for defaults.
- `enum ResolverChange { State(KeybindingState), ControlKeyHeld(bool), TypedPaneHint(String) }`
- `fn should_forward_prefix_key(state) -> bool` and `const PANE_NAVIGATION_BINDING_IDS`

**`command`**
- `BindingCommand::from_binding_id(id, &AgentCatalog) -> Option<BindingCommand>`: the Swift `executeBinding` table as data.
- `fn launched_agent_id(id, &AgentCatalog) -> Option<String>`
- `fn split_direction(id) -> Option<SplitDirection>`
- `fn dispatches_through_main_menu(id) -> bool`
- `enum FocusedContent { Terminal, Browser, Editor, Automations, Other }` with `owns_chord(key, Modifiers)`
- `enum SplitDirection`

**`claims`**
- `struct TerminalTarget { pane_id, tab_id }`
- `trait PassthroughClaims { fn has_claims(&self, &TerminalTarget) -> bool }`, implemented for `()` and the registry.
- `PaneNavigationClaimRegistry`: `enable`, `disable`, `synchronize(&HashSet<TerminalTarget>, generation: i64)`, and `handle_request(target, passthrough, source, direction, active) -> Option<NavigationDirection>`.
- `enum NavigationDirection` with `parse`, `as_str`, `is_horizontal`.

**`hints`**
- `PaneHintAssignment { key, pane_id }`
- `enum PaneHintStep { PassThrough, Pending(String), Focus(String) }`
- `fn pane_hint_step(typed, key, terminal_claims_control_keys, &[PaneHintAssignment])`

### Every outcome `handle` can return
- `PassThrough`: the host delivers the key to the focused terminal or view.
- `Consumed`: a key after the prefix matched no binding, or Esc dropped a started hint.
- `EnterPrefix`
- `LiteralPrefix`: ⌃A ⌃A; the host delivers this Ctrl+A to the terminal.
- `Action(binding_id)`
- `MenuAction(binding_id)`: only `command-palette` and `open-project`. On macOS the host delivers the event to the native menu; a host without that menu shortcut runs the action itself.
- `FocusPaneHint(pane_id)`
- `PaneHintPending(typed)`

### Binding ids it can emit
Any `id` in the config. These are the ones `BindingCommand` knows:
- **Windows:** `select-window-<n>`, `previous-window`, `next-window`, `previous-window-direct`, `next-window-direct`, `last-window`, `new-window`, `new-window-current-directory`, `rename-window`, `close-window`, `find-window`
- **Agents:** `launch-<agent>` (only when the agent is in the catalog), `new-chat`, `agent-dashboard`
- **Panes:** `split-horizontal`, `split-vertical`, `nav-left`, `nav-down`, `nav-up`, `nav-right`, `resize-left`, `resize-down`, `resize-up`, `resize-right`, `close-pane`, `kill-pane`, `close-active`, `maximize-pane`, `new-terminal`, `new-browser`
- **Copy mode:** `copy-mode`, `copy-mode-right-bracket`
- **Sessions:** `new-session`, `find-session`, `save-session`
- **Tabs:** `new-tab`, `new-tab-direct`, `close-tab`, `next-tab`, `previous-tab`
- **Pane tabs:** `new-pane-tab`, `new-pane-tab-direct`, `next-pane-tab`, `next-pane-tab-direct`, `prev-pane-tab`, `prev-pane-tab-direct`, `close-pane-tab`, `close-pane-tab-direct`
- **App:** `command-palette`, `open-project`, `open-in-soprano-git`, `toggle-sidebar`, `toggle-right-sidebar`, `toggle-explorer`, `toggle-source-control`, `open-settings`
- **Zoom:** `zoom-in`, `zoom-out`, `zoom-reset`

## 2. What was ported
`Controllers/KeybindingManager.swift` became `src/{event,claims,hints,command,resolver}.rs`. The default table is copied into the test fixture at `tests/support/mod.rs`.

**Tests ported:** 21 unit tests and 35 integration tests in `tests/resolver.rs`.
- `PaneNavigationClaimRegistryTests`: all 10.
- `PaneTabShortcutTests`: all 3, rewritten as outcome checks plus the binding-id → command mapping.
- `KeybindingPassthroughTests`: 2 of 4.
- `DefaultKeybindingsTests`, resolver parts: main-menu dispatch, split direction, the Ctrl+Shift+Tab key, ⌃1–9, prefix P/N/⇧L/</>/[/]/C, ⌘T and ⌃Tab, and every default binding resolving to its own id.
- `EditorTabTests.focusedPanesKeepOnlyTheChordsTheyOwn` and the `launch-aider` case from `ConfigStoreTests`.
- I also added tests for timeouts, config reload, the zoom alias, Option being ignored, passthrough claims, pane hints (including timeout and Esc), held Control, copy-mode display, and the Linux/Windows chords.

**Skipped:**
- `KeybindingPassthroughTests`, two tests:
  - The recording Prefix-key field (`SettingsViewController`, AppKit).
  - Menu shortcuts inside a dialog (`NSMenu` key handling).
- `DefaultKeybindingsTests`: the binding-data and `mergedConfig` migration tests belong to soprano-config.
- `CommandPaletteSearchTests` / `CommandPaletteDismissTests`: they don't test key routing.

**Left to other crates:** carrying out commands (`AgentManager`), hint generation (`paneHints` / `pane_shortcut_assignments`), and the IPC listener.

## 3. Cross-platform decisions and deviations
- **Shortcut mapping on Linux/Windows:** `cmd` is Ctrl+Shift, `cmd+shift` is Ctrl+Shift+Alt, `ctrl+cmd` is Ctrl+Alt, `ctrl+cmd+shift` is Ctrl+Shift+Alt. Plain Ctrl chords stay Ctrl. ConfigPort agreed this table and uses the same one for display. Super is ignored the way Option is ignored on macOS.
- **Bindings with an added Shift:** where the mapping adds a Shift the binding doesn't have, the key is compared against `base_key`, so ⌘1 pressed as Ctrl+Shift+1 still matches even though it reports `!`.
- **Shortcut collisions:** some shortcuts land on the same physical keys. For example ⌘L and the Ctrl+Shift+L window shortcut are both Ctrl+Shift+L. The first binding in the table wins, as in Swift, so the ⌘L shortcut (Toggle Right Sidebar) has no default chord on Linux/Windows.
- **Ctrl+= zooms in on Linux/Windows:** the ⌘= / ⌘+ zoom alias ignores Shift, so Ctrl+= also zooms in there.
- **Pane hints on Linux/Windows (needs your call):** ⌃⇧letter is the same chord as every ⌘letter shortcut there, so hints use Alt+Shift+letter. Holding Alt+Shift also counts as "Control held" for showing the hints. If you want something else, the change is in one place, `Platform::is_pane_shortcut_chord` / `reveals_hints`.
- **Prefix key and Alt:** on Linux/Windows, Ctrl+Alt+A is not the prefix, because Alt is part of the `cmd` chords there. macOS keeps Swift's behaviour of ignoring Option.
- **Focused-content checks:** off macOS, the check for chords a browser, editor or Automations page keeps for itself uses the matched binding's own modifiers, because the physical keys are ambiguous there.
- **Copy mode:** Swift's terminal fed copy mode straight to the status bar. Here that goes through `copy_mode_changed`, and `display_state()` is whichever mode was reported last, as before.
- **Timers:** the host runs them via `next_deadline()` / `tick(now)` instead of `Timer`.
- **Windows that capture all keys:** `keys_captured` replaces the AppKit window checks (`leavesKeysAlone`).
- **Mirror enums:** `NavigationDirection` and `SplitDirection` are small local copies of the soprano-model types, so this crate doesn't depend on that one.

## 4. Verification
Run in the worktree:
- `CARGO_TARGET_DIR=target/agent-soprano-keys cargo test -p soprano-keys`: 21 unit and 35 integration tests passed, 0 failed.
- `CARGO_TARGET_DIR=target/agent-soprano-keys cargo clippy -p soprano-keys --all-targets -- -D warnings`: clean.
- `cargo fmt -p soprano-keys --check`: clean.
- `CARGO_TARGET_DIR=target/agent-soprano-keys cargo doc -p soprano-keys --no-deps`: 0 warnings.