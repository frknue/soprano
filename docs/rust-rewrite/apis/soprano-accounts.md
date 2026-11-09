# soprano-accounts — API report from AccountsPort

> `AccountsPort` is running a newer turn. The output below is from its PREVIOUS run (published 13.7s ago), not the current one. Live progress: `history://AccountsPort`; its next result auto-delivers to its owner.I've ported `soprano-accounts` with no gpui dependency. All 73 tests pass on macOS and clippy shows no warnings. Clippy is also clean for `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc`. One catch: the acceptance command doesn't run in the shared worktree right now. Another agent's `crates/soprano-explorer` has a `Cargo.toml` but no `src/lib.rs`, so cargo fails to load the workspace manifest. I ran every check in an isolated copy of the workspace instead: same root `Cargo.toml` and `Cargo.lock`, with only `soprano-accounts` and `soprano-platform` as members.

## 1. Public API

Dates are `Timestamp = chrono::DateTime<Utc>`, and `chrono` is re-exported, so hosts pass `chrono::Utc::now()`.

**`AccountsController`** is a cheap clonable handle (`Arc` inside). Work runs on background threads and each change goes to observers as a whole snapshot.
- `new(store: StateStore) -> Self`: uses the real homes, the OS secret store and `AccountLaunchState::shared()`. Create one, keep it for the app's lifetime, and call `start()` once.
- `start()` writes the omp overlay, publishes the launch state and runs a forced refresh.
- `snapshot() -> AccountsSnapshot`, `add_observer(id: &str, SnapshotObserver)`, `remove_observer(id)`.
  - `SnapshotObserver = Arc<dyn Fn(&AccountsSnapshot) + Send + Sync>`. It is called on the thread that changed the snapshot (usually a background thread), so the UI has to forward it to its own thread.
- `refresh(force: bool)`: without `force`, a call within 30 s of the last refresh is skipped.
- `refresh_due(now) -> bool`: starts a forced refresh when the last one is at least 5 minutes old (`POLL_INTERVAL_SECONDS = 300.0`) or there was none. The host calls it on a timer while the app is in front, and when the app becomes active.
- `add_account(list)`, `reauthenticate(account_id, list)`, `cancel_login()`: only one sign-in runs at a time; a cancelled one reports no error.
- `select(Option<&str>, list)`, `remove(account_id, list)`, `dismiss_error(list)`.
- `wait_until_idle(Duration) -> bool`, for tests and shutdown.

**Models:**
- `AccountListId { tool, provider }` with `OMP_CLAUDE`, `CLAUDE_CODE`, `OMP_CODEX`, `CODEX_CLI`, and `ALL` in display order.
- `AccountProvider` (`display_name`, `omp_provider_id`) and `AccountTool`.
- `AccountsSnapshot { lists, pending_login, errors, is_refreshing, last_refresh }` with `headline(provider) -> Option<(&AccountRow, &AccountUsage)>`.
- `AccountList` (`selected_account()`), `AccountRow`, `AccountIdentity` (`key()`, `matches()`), `AccountUsage` (`tightest()`), `UsageWindow`, `PendingLogin`.
- `usage_format::{percent, time_until, window, summary}`.
- `UsageSeverity::of(fraction)` returns `Normal`, `Warning` (from 70 %) or `Danger` (from 90 %); the UI maps these to theme colours.

**Settings ▸ Accounts page** (`presentation`):
- `AccountsPage::build(&snapshot, &now)` returns the refresh button, the "Updated 4m ago" text, the intro and four `AccountListSection`s. Each section has a title, note, optional error with a Dismiss button, a `SectionBody` (`Unavailable`, `Rows(Vec<EntryRow>)` or `Placeholder`) and a `SectionFooter` (`Pending {text, description, buttons}` or `Add(Button)`).
- `AccountsPage::on_open(&dyn AccountsSource)` refreshes without forcing.
- `Button { title, variant, is_enabled, symbol, action: PageAction }`.
- `PageAction::perform(&dyn AccountsSource) -> Option<Confirmation>`: `ConfirmRemove` returns the removal dialog, `OpenSignInPage` opens the browser, and `ManageAccounts` is left for the host.
- `AccountsSource` is the trait the page acts through: `AccountsController` implements it, and tests can use a fake.

**Status bar and usage card:**
- `status_usage(&snapshot, &now) -> Vec<StatusUsageSegment {provider, name, fraction, percent, severity, reset}>`, with `.text()` giving `Claude 18% · 3h 5m`.
- `status_usage_text(...)` joins the providers with `"  |  "`, giving `Claude 93% · 2d 4h  |  Codex 75% · 1h 12m`, or `None` when there is no usage yet.
- `UsageCard::build(&snapshot, &now)` returns, per provider, the eyebrow, each list's caption (`omp · automatic`) and its rows. Each row has its mark state, tooltip and one `UsageCardLine` per window: label, fraction, percent, severity and reset — this is where the 5-hour and weekly windows appear.

**Launch:** `AccountLaunchState::shared() -> Arc<_>` and `adjustments(profile_id) -> Adjustments { environment: BTreeMap, arguments: Vec }`.
- `codex`: syncs the links, then sets `CODEX_HOME`.
- `omp`: passes `--config <overlay>` only once the file exists.
- Every other agent: no changes.
- LaunchPort takes these same two fields from the caller, so the app copies them across field-for-field.

**Also exported:** `AccountStateStore` (key `soprano-accounts`), `AccountState`, `AccountPaths`, `CodexAuth`, `CodexHomeLinker`, `files::*`, the `usage_api` parsers and fetchers, the `SecretStore` trait and `KeyringStore`, and the error types (`AccountError` and the per-tool errors).

## 2. Ported files
- `AccountModels` → `models.rs`
- `AccountState` → `state.rs`. Dates are stored as Swift reference-date doubles, so state imported from the Swift app's UserDefaults loads as it was.
- `AccountFiles` → `files.rs`
- `AccountLaunchState` → `launch.rs`
- `AccountsController` → `controller.rs`
- `ClaudeCodeAccountManager` → `claude.rs`
- `CodexAccountManager` → `codex.rs`
- `OmpAccountManager` → `omp.rs` (SQLite through `rusqlite`)
- `UsageAPI` → `usage_api.rs` (`ureq` 3, blocking)
- `KeychainCLI` → `secrets.rs`
- `CommandRunner` → `command.rs`, private to this crate; only `CommandError` is public.
- The page, card and status-bar logic → `presentation.rs`

**Tests ported** (all Swift cases in each file):

| Swift file | Cases | Notes |
|---|---|---|
| `AccountUsageParsingTests` | 6 | |
| `AccountUsageSeverityTests` | 3 | test severity levels instead of colours |
| `AccountStorageTests` | 3 | |
| `ClaudeCodeAccountSwitchingTests` | 9 | |
| `CodexAccountTests` | 7 | |
| `OmpAccountStoreTests` | 6 | |
| `SettingsAccountsPageTests` | 5 | run against the page model instead of AppKit views |
| `AccountLaunchTests` | 3 | adjustments logic only; the `TerminalConfig` assertions belong to soprano-launch |

There are also new tests for the controller, the command runner, files, the usage card and the status bar. No tests are touched the real keychain or home folder: secret stores are in memory, paths are temporary, and the shells and CLIs are fake scripts.

**Skipped:** the AppKit layout parts of the Settings tests (finding views in the hierarchy, the 50 ms main-queue rebuild delay).

## 3. Cross-platform decisions and deviations
- **Claude Code's own login:** on macOS it goes through the Keychain via `security`, as before. On Linux and Windows it uses `~/.claude/.credentials.json`. There the file is created if missing, written all-or-nothing, and deleted again if a switch fails partway.
- **Soprano's stored Claude logins** use `keyring` on every OS, with the same service name (`Soprano Claude Code Accounts`) and account names. On a Mac the items the Swift app created through `security` may trigger one Keychain access prompt the first time.
- **CLIs:** on Unix they run through `$SHELL -lic` with the same `\x1E` marker. Windows has no login shell, so they run through `cmd.exe /D /S /C` with the environment set on the process; `cmd`'s "not found" code 9009 is treated like 127.
- **Codex homes on Windows:** folders are linked with junctions, and files with symlinks, falling back to hard links and then copies. Copies get folded back like any file Codex rewrote. Links to deleted entries are only cleaned up for symlinks and junctions.
- **File permissions:** the `0600`/`0700` modes apply on Unix; Windows files inherit the folder's access rules.
- **Concurrency:** Swift's `async`/`AsyncSerialQueue` became a mutex per manager plus std threads. Cancelling stops the CLI with SIGTERM, then SIGKILL after 3 s (a hard kill on Windows). Cleanup after a cancelled sign-in always runs.
- **App activation and polling:** there is no `NSApp` observer or timer in this crate; the host calls `refresh_due(now)` instead.
- **Not ported:** Swift's `AccountsController.shared`. A second `StateStore` on the same file would overwrite the app's own, so the app creates one controller with its own store.
- **Wording:** the Settings note texts still say "on this Mac", copied verbatim from Swift.

## 4. Verification
- `cargo test -p soprano-accounts` (macOS) with `CARGO_TARGET_DIR=target/agent-soprano-accounts`: 73 passed, run 5 times with no flakes.
- `cargo clippy -p soprano-accounts --all-targets`: no warnings.
- `cargo fmt -p soprano-accounts`: no changes.
- `cargo clippy --target x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc` (`-p soprano-accounts --all-targets`, `CARGO_TARGET_DIR=target/agent-soprano-accounts-cross`): no warnings.
  - The C dependencies (bundled SQLite, `ring`, vendored libdbus) were compiled for these targets with `zig cc` wrappers set as `CC_<target>`/`AR_<target>`.
  - This only proves the code compiles for those targets; no tests ran there.

All of the above ran in the isolated workspace copy. Once `soprano-explorer` has a `src/lib.rs`, rerun `CARGO_TARGET_DIR=target/agent-soprano-accounts cargo test -p soprano-accounts` in the real worktree to confirm.

Dependencies I added: `chrono`, `regex`, `sha2`, `unicode-normalization`, `base64`, `uuid`, `rusqlite` 0.37 (bundled), `ureq` 3, `keyring` 3, `thiserror`, plus `libc` on Unix and `junction` on Windows.