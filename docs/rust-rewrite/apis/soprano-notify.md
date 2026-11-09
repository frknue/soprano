# soprano-notify — API report from NotifyPort

I've built `crates/soprano-notify`, ported from the app side of `AgentNotificationManager.swift`. `cargo test -p soprano-notify` passes (42 tests), clippy is clean on macOS, and the crate also checks and lints clean for Linux and Windows. The OS backends have only been compiled: no banner was shown on any OS, and nothing in the tests runs the Linux or Windows code.

## Public API (`soprano_notify::*`)

**Constructors**
```rust
NotificationManager::new(identity: &AppIdentity, state: StateStore,
    sound: impl Fn() -> bool + Send + 'static,
    on_banner_clicked: impl Fn(BannerClick) + Send + Sync + 'static) -> Self
NotificationManager::with_backend(backend: Option<Arc<dyn NotificationBackend>>, state: StateStore,
    sound: impl Fn() -> bool + Send + 'static) -> Self
fn can_post(&self) -> bool
```
- `sound` is read for every banner. Pass something like `move || config_store.settings().notification_sound`, so an edit applies to the next banner.
- `on_banner_clicked` runs on the OS's thread. The shell should hop to the UI thread, activate the app (`cx.activate(true)`), then:
  - `BannerClick::Tab(target)` → call `click.focus(&mut ws)`, which runs `focus_tab(pane, tab, false)`.
  - `BannerClick::AutomationRun(run_id)` → open that run in Automations.
- Create the manager early in startup so the macOS delegate is set before a click arrives.

**Authorization (for Settings)**
```rust
fn authorization(&self) -> Option<Authorization>        // Authorized | Denied | NotDetermined | Unavailable
fn on_authorization_changed(&self, f: impl Fn(Authorization) + Send + Sync + 'static)  // any thread, only on change
fn request_authorization_if_needed(&self)                // call once at launch
fn refresh_authorization(&self)                          // call when Settings appears
pub const AUTHORIZATION_KEY = "soprano-notification-authorization"
Authorization::{raw_value, from_raw}                     // "authorized", "denied", "notDetermined", "unavailable"
```
These map one-to-one onto `soprano_settings::NotificationAuthorization`. Opening the OS settings page stays in `soprano_settings::open_notification_settings()`.

**Focus (replaces Swift's first-responder check)**
```rust
fn app_did_become_active(&mut self, ws: &mut Workspace)   // clears the focused tab's mark and banners
fn app_did_resign_active(&mut self)
fn surface_did_focus(&mut self, ws: &mut Workspace, target: TerminalTarget)   // terminal or chat surface
fn surface_did_lose_focus(&mut self, target: &TerminalTarget)
fn workspace_did_change(&mut self, ws: &mut Workspace, changes: &[WorkspaceChange])  // pass the drained changes
fn focused_target(&self) -> Option<TerminalTarget>
```
A tab counts as focused only when the app is active and that surface has keyboard focus. The app starts as active.

**Events**
```rust
fn handle_agent_event(&mut self, ws: &mut Workspace, event: AgentEvent)       // Request::AgentEvent from soprano-ipc
fn handle_agent_event_at(&mut self, ws: &mut Workspace, event: AgentEvent, now: Instant)
fn handle_terminal_notification(&mut self, ws: &mut Workspace, n: TerminalNotification)  // { target, title, body } from OSC 9/777
fn terminal_command_did_finish(&mut self, ws: &mut Workspace, target: &TerminalTarget, exit_code: Option<i32>)  // OSC 133;D
fn terminal_child_did_exit(&mut self, ws: &mut Workspace, target: &TerminalTarget, exit_code: Option<i32>)
fn tick(&mut self, now: Instant, ws: &mut Workspace)     // every 1–2 s
fn deliver_automation_notification(&self, title: &str, body: &str, run_id: &str)
NotificationManager::location_subtitle(session, window, tab) -> Option<String>   // "a ▸ b ▸ c"
```
- Banners are posted only for tabs that are not focused, one per tab under the id `soprano-<pane>-<tab>`, so the next one replaces the last.
- An agent banner's title says what the agent wants (`AgentAlert`) and its body is the tab title. A plain terminal's notification keeps its own title and body, with `session ▸ window ▸ pane` as the subtitle.

**Lower-level types:** `NotificationBackend` (a trait so tests can fake the OS), `Banner`, `BannerClick::from_user_info`, `SystemAuthorization`, `ClickHandler`, `system_backend(identity, on_click)`.

## Which `WorkspaceChange`s it produces
It only calls existing `Workspace` methods:
- **Status, attention, conversation, attach and detach** (`attach_agent_if_needed`, `update_agent_status`, `record_agent_conversation`, `agent_returned_to_shell`, `agent_command_did_finish`, `agent_process_did_exit`, `clear_attention`) → `WorkspaceChange::Model`.
- **`BannerClick::focus`** (`focus_tab`) → `Model`, or `Layout` when another window or layout tab comes forward.
- **Process id and last message** are written through `agent_mut`, which records no change. That matches Swift.
- **No `WorkspaceEvent`s.**

## OS backends (one file each in `src/platform/`)
- **macOS:** `UNUserNotificationCenter` through objc2. Builds that are not a bundled `.app` with a bundle id get no backend: banners stay silently off and Settings shows "unavailable".
  - Banners carry the same user-info keys as Swift (`paneId`, `tabId`, `automationRunId`), so a click on a banner the Swift app delivered still opens its tab.
  - Banners also show while the app is in front (banner and sound), as in Swift.
- **Linux:** `notify-rust` over D-Bus. A running notification server counts as authorized; no server means unavailable.
  - A tab's next banner reuses the previous one's server id, so it replaces it. Focusing the tab closes its banner.
  - The location line goes at the top of the body, because the freedesktop spec has no subtitle. Markup is escaped when the server renders markup.
- **Windows:** toasts built directly with the `windows` crate, not `notify-rust`/`winrt-notification`. Those two can't set a toast's tag and group or remove it from Action Center, and the brief needs both for "replace, never stack" and for withdrawing banners on focus.
  - The app id is used as the AppUserModelID; the installer's Start menu shortcut has to carry that id or Windows won't show the toasts.
  - Windows' per-app notification switch is the permission: on → authorized, off → denied.

## Tests ported
- **`AgentConversationTests`**: the codex/claude routing test, the manual omp dashboard test, both badge-clears-when-the-hook-owner-exits tests, the dedicated-agent-tab-becomes-terminal test, and the duplicate-status conversation test.
- **`ExternalEventRoutingTests` and `TerminalSessionTests`**: the location subtitle tests.
- **`TerminalLifecycleTests`**: the exit and hook parts, driven through events.
- **Status transitions and waiting reasons**: per-state dashboard status, "Done" stays until the next prompt, and reasons from `AgentWaitingReasonTests`.
- **`NotificationSettingsTests`**: the authorization flow. The sound-setting tests already live in soprano-config.
- **New**: banner rules, focus clearing, the post-then-focus race, automation runs, terminal notifications, click decoding, `tick`, and one Linux body-text test.
- **`RunningCommandIndicatorTests`** has nothing about notifications, so nothing came from it.

## Deviations
- **`tick` polls agent processes, which Swift never did.** Swift only detached an agent when the shell reported the command finished. `tick` also detaches an agent in a plain terminal tab once the process its hooks named is gone, so the badge clears even without shell integration, which may be missing on Windows. It skips dedicated agent tabs and agents with no known process.
- **Terminal bells (BEL) are not handled.** Swift posts nothing for a bell, so there is no entry point for it.
- **Delivered-banner bookkeeping uses a mutex instead of a hop to the main thread.** The behavior is the same: a banner whose tab got focus before posting finished is withdrawn at once.

## Commands
- `CARGO_TARGET_DIR=target/agent-soprano-notify cargo test -p soprano-notify` → 42 passed.
- `cargo clippy -p soprano-notify --all-targets` → clean.
- `cargo clippy --target x86_64-unknown-linux-gnu -p soprano-notify --all-targets` → clean.
- `cargo clippy --target x86_64-pc-windows-msvc -p soprano-notify --all-targets` → clean.
- `cargo fmt -p soprano-notify --check` → OK.