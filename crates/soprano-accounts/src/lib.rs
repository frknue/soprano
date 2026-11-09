//! soprano-accounts: several Claude and Codex logins for omp, Claude Code and
//! the Codex CLI — listing them with their usage, signing in, switching,
//! removing — and what new agent panes need from the choice. Port of the
//! Swift app's `Accounts/*`; see docs/rust-rewrite/PLAN.md.
//!
//! - `AccountsController`: the one owner the UI talks to (snapshots, actions).
//! - `presentation`: Settings ▸ Accounts, the status bar's usage segment and
//!   the usage card, as plain data.
//! - `AccountLaunchState`: `CODEX_HOME` / omp `--config` for new panes.

mod claude;
mod codex;
mod command;
mod controller;
mod error;
pub mod files;
mod launch;
pub mod models;
mod omp;
pub mod presentation;
mod secrets;
mod state;
pub mod usage_api;

pub use claude::{LIVE_SERVICE, MANAGED_SERVICE, keychain_user, scoped_service};
pub use codex::{CodexAuth, CodexHomeLinker};
pub use command::CommandError;
pub use controller::{
    AccountsController, MINIMUM_REFRESH_INTERVAL_SECONDS, POLL_INTERVAL_SECONDS, SnapshotObserver,
};
pub use error::{AccountError, AccountResult, ClaudeAccountError, CodexAccountError, OmpAccountError};
pub use files::AccountFileError;
pub use launch::{AccountLaunchState, Adjustments};
pub use models::{
    AccountIdentity, AccountList, AccountListId, AccountProvider, AccountRow, AccountTool, AccountUsage,
    AccountsSnapshot, PendingLogin, Timestamp, UsageSeverity, UsageWindow, usage_format,
};
pub use presentation::AccountsSource;
pub use secrets::{KeyringStore, SecretStore, SecretStoreError};
pub use state::{
    AccountPaths, AccountState, AccountStateStore, ManagedAccountRecord, ManagedAccountsState, OmpPreference,
};
pub use usage_api::{UsageApiError, UsageCredential};

/// `Timestamp` is `chrono::DateTime<chrono::Utc>`; hosts pass `chrono::Utc::now()`.
pub use chrono;
