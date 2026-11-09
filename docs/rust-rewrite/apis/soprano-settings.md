# soprano-settings — API report from SettingsUi

`soprano-settings` is finished. `cargo test -p soprano-settings` passes 61 tests, `cargo clippy -p soprano-settings --all-targets` gives no warnings, `cargo fmt` is applied, and the `settings_demo` example compiles; I didn't run it. I couldn't cross-check Linux or Windows: both `cargo check --target` runs fail on the `ring` dependency, which soprano-accounts pulls in and needs a C cross-compiler.

## Public API

**`SettingsView`** (gpui entity; emits `SettingsEvent`; `Focusable`)
- `SettingsView::new(store: ConfigStore, accounts: Rc<dyn soprano_accounts::AccountsSource>, notifications: Rc<dyn NotificationStatusProvider>, window: &mut Window, cx: &mut Context<Self>) -> Self`. It opens on General and takes the keyboard.
- `enum SettingsEvent { Close, OpenSettingsFile { error: Option<String> } }`
  - `Close` fires on Esc, the × button or a click outside the card.
  - `OpenSettingsFile` fires after the view has called `ConfigStore::open_in_editor()` itself; `error` says why it failed, for you to show.
- `current_tab()`, `switch_tab(SettingsTab, window, cx)`. Opening Accounts calls `refresh(false)`, matching Swift.
- `shortcut_query(cx) -> String`, `set_shortcut_query(&str, window, cx)`.
- `captures_keys() -> bool`: true while a key recorder is active. Your keybinding resolver must step aside then (`KeyContext::keys_captured`).
- `notification_authorization_changed(cx)`: call it when the OS permission changes; it re-reads the provider.
- `reload(window, cx)`: re-reads the store. It also runs on its own: store and account observers wake a task on the window, so updates land on the main thread. Observers are removed when the entity is released.
- `is_confirming() -> bool`: the remove-account dialog is open.
- Render the entity over the workspace: it draws the 35 % backdrop and a card at most 1280×960, 32 px from each window edge, with popover fill, border, radius 8 and shadow.
- Constants and helper: `NAV_WIDTH` (240), `PAGE_MAX_WIDTH` (768), `CARD_MAX_WIDTH`, `CARD_MAX_HEIGHT`, `CARD_MARGIN`, `page_width(card_width) -> f32`.

**Notification permission**
- `trait NotificationStatusProvider: 'static { fn authorization(&self) -> Option<NotificationAuthorization>; }`. `Option<NotificationAuthorization>` implements it for a fixed answer.
- `enum NotificationAuthorization { Authorized, Denied, NotDetermined, Unavailable }` maps 1:1 to soprano-notify's `Authorization`.
- `open_notification_settings()` opens System Settings ▸ Notifications on macOS and `ms-settings:notifications` on Windows. Linux has no settings page, so it does nothing and the row's text says where to look instead.
- Also public: `NotificationPlatform`, `NotificationStatusRow::{new, for_platform}`, `StatusTone`.

**`AccountUsagePopover`** (emits `UsagePopoverEvent::ManageAccounts` and `DismissEvent`)
- `AccountUsagePopover::new(accounts: Rc<dyn AccountsSource>, window, cx)`, `snapshot()`.
- It is a 340 px card that follows the accounts live. Esc or a click outside emits `DismissEvent`; positioning it is up to you.
- Also exported: `usage_percent_color`, `usage_bar_color`.

**Page logic you can use without a window:** `SettingsTab` and the modules `general`, `shortcuts`, `agents`, `about` and `notifications`. They hold the `settings.json` key constants, `Toggle`, `committed_integer`, `recorded_prefix_key`, add/remove project directory, `shortcut_groups`, `ChordRecorder`, `set_agent_field`, `add_agent`, `remove_agent_entry`, and the quick-reference, links and license notices.

## What each page does
- **Every control writes exactly one key** through `ConfigStore::write`, using the Swift key names. A row whose value differs from the default shows a reset button that calls `ConfigStore::remove`.
- **General:**
  - `settings.json` problems are listed first, as "Line N: …".
  - Theme, appearance, the four switches and Restore workspace.
  - Notifications: Play a sound, plus the permission line with the OS settings button.
  - Project directories: the list shows what the file says, unreachable ones are marked "Not found", and a typed path or Browse… adds one via `cx.prompt_for_paths`.
  - Prefix key recorder: click it, or focus it and press Space; Esc keeps the current key and a Shift symbol is refused.
  - Prefix timeout and resize step: clamped, written on Enter or when you leave the field.
- **Keyboard Shortcuts:** search field, groups, keycaps, a "Customized" tooltip, disabled bindings shown as "Off", and the conflict or chord problems shown on the bindings they name. Esc in the search field clears the query first.
- **Agent Profiles:** the Swift rows (color dot, name, `settings.json` badge, description, command, ready/error patterns) plus edit fields and an Add Agent row.
- **Accounts:** built entirely from soprano-accounts' `AccountsPage`. Remove asks first through soprano-ui's `Dialog`.
- **About:** version from `app_version()`, runtime, the settings file with Open / Show in Finder / Reload, links, license notices with a View button for each bundled license file, and the quick reference.

## Swift ported
- **Files:** `SettingsWindowController`, `SettingsHeaderView`, all five `Settings/*` files and `AccountUsagePopover`.
- **Tests:** `SettingsAccountsPageTests` (all of its behaviour), the view parts of `SettingsWindowTransitionTests` (all three Esc behaviours and the page-column width), `SettingsConfigWritingTests` (every control-to-key case, including Shift being refused, the syntax-error banner and the unknown theme), the view parts of `NotificationSettingsTests`, and the window-bar switch from `WindowBarSettingsTests`.
- **Not ported separately:** `SettingsKeycapTests` already lives in soprano-config; `SettingsEditingTests` only checks AppKit field wiring and is covered by the Enter/leave-field behaviour.

## Where it differs from Swift, and why
- **New behaviour the brief asked for:**
  - **Rebinding shortcuts:** click a binding's keycaps and press new keys; it writes `keybindings.bindings.<id>`. Esc cancels, Backspace writes `null` (off), and pressing ⌃A first records a prefix binding.
  - **Editing agent profiles:** each edit rewrites the `agents` list with that one entry changed. Clearing the last patched field of a built-in agent removes its entry.
  - **About page:** links and license notices are new.
- **Linux and Windows:**
  - Off macOS a recorded Ctrl+Shift chord is saved as `cmd`, following the agreed key table. Ctrl+Shift+Alt is read as `cmd+shift`, although `ctrl+cmd+shift` also shows as Ctrl+Shift+Alt.
  - Text that names the OS changes per OS ("Windows is blocking…", Ctrl captions instead of ⌃).
- **Look:**
  - The theme picker opens soprano-ui's `ContextMenu` at the click, so Folio keeps its separator; soprano-ui's `Select` has none.
  - The usage card shows "Claude" rather than "CLAUDE", because Soprano uses no uppercase eyebrows.
  - The problem mark on an account is an outlined diamond (a rotated square icon), because GPUI divs can't rotate.
  - Success text is the green `working` token and warnings the yellow `approval` token.

## Commands run
- `CARGO_TARGET_DIR=target/agent-soprano-settings cargo test -p soprano-settings` → 61 passed (this build also compiles `settings_demo`).
- `CARGO_TARGET_DIR=target/agent-soprano-settings cargo clippy -p soprano-settings --all-targets` → no warnings.
- `cargo build -p soprano-settings --examples` → finished.
- `cargo fmt -p soprano-settings` → applied.
- `cargo check --target x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc` → both stop at `ring`'s build script, which needs a C cross-compiler.