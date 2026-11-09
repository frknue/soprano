//! Where account data lives, and the bookkeeping Soprano persists about it.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};

use serde::{Deserialize, Serialize};
use soprano_platform::{AppIdentity, StateStore, paths};

use crate::models::{AccountIdentity, Timestamp};

/// Where account data lives on disk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountPaths {
    /// The user's home: Claude Code and the Codex CLI keep their own login under it.
    pub home: PathBuf,
    /// Soprano's account data: managed Codex homes and the omp preference overlay.
    pub support_directory: PathBuf,
}

impl AccountPaths {
    pub fn new(home: impl Into<PathBuf>, support_directory: impl Into<PathBuf>) -> Self {
        Self { home: home.into(), support_directory: support_directory.into() }
    }

    /// The running app's paths. Dev and installed builds have their own data
    /// folders, so neither one touches the other's managed homes.
    pub fn live() -> Self {
        Self::new(paths::home_dir(), paths::data_dir(&AppIdentity::current()))
    }

    pub fn claude_config_directory(&self) -> PathBuf {
        self.home.join(".claude")
    }

    /// Claude Code's global config, which carries the signed-in `oauthAccount`.
    pub fn claude_global_config_file(&self) -> PathBuf {
        self.home.join(".claude.json")
    }

    /// The plaintext login Claude Code keeps where there is no Keychain
    /// (Linux, Windows) and falls back to on a Mac.
    pub fn claude_credentials_file(&self) -> PathBuf {
        self.claude_config_directory().join(".credentials.json")
    }

    pub fn codex_default_home(&self) -> PathBuf {
        self.home.join(".codex")
    }

    pub fn codex_accounts_directory(&self) -> PathBuf {
        self.support_directory.join("codex-accounts")
    }

    /// Passed to every omp agent pane with `--config`; holds the preferred accounts.
    pub fn omp_overlay_file(&self) -> PathBuf {
        self.support_directory.join("omp-accounts.yml")
    }
}

/// Dates as the Swift app's `JSONEncoder` wrote them: seconds since
/// 2001-01-01 UTC, so state imported from the Swift build keeps its dates.
pub(crate) mod reference_date {
    use serde::{Deserialize, Deserializer, Serializer, de::Error};

    use crate::models::{Timestamp, seconds_since_epoch, timestamp_from_seconds};

    /// 2001-01-01T00:00:00Z in seconds since 1970.
    const REFERENCE_DATE: f64 = 978_307_200.0;

    pub fn serialize<S: Serializer>(date: &Timestamp, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_f64(seconds_since_epoch(date) - REFERENCE_DATE)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Timestamp, D::Error> {
        let seconds = f64::deserialize(deserializer)?;
        timestamp_from_seconds(seconds + REFERENCE_DATE).ok_or_else(|| D::Error::custom("date out of range"))
    }
}

/// A login Soprano manages for Claude Code or the Codex CLI.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ManagedAccountRecord {
    pub id: String,
    pub identity: AccountIdentity,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub organization_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<String>,
    #[serde(with = "reference_date")]
    pub created_at: Timestamp,
    #[serde(with = "reference_date")]
    pub last_authenticated_at: Timestamp,
}

/// One CLI's managed logins and which of them is in use.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ManagedAccountsState {
    pub accounts: Vec<ManagedAccountRecord>,
    /// nil: the CLI uses its own login ("System default").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_account_id: Option<String>,
    /// Who the CLI's own login belonged to when Soprano last switched away
    /// from it, so the System default row can still name it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub system_default: Option<ManagedAccountRecord>,
}

impl ManagedAccountsState {
    pub fn active_account(&self) -> Option<&ManagedAccountRecord> {
        let id = self.active_account_id.as_deref()?;
        self.accounts.iter().find(|record| record.id == id)
    }
}

/// The account omp should try first for one provider.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OmpPreference {
    /// Exactly as omp reports them: omp's account policies compare as written.
    pub email: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub org_id: Option<String>,
    /// Only recognizes the row; the policy selects by email and org.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account_id: Option<String>,
}

/// Account bookkeeping. Credentials never live here: Claude Code logins are in
/// the OS secret store, Codex logins in their managed homes, omp logins in omp.
///
/// Every key is optional when decoding, so a payload written before a key
/// existed still loads.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AccountState {
    pub claude_code: ManagedAccountsState,
    #[serde(rename = "codexCLI")]
    pub codex_cli: ManagedAccountsState,
    /// omp provider id → preferred account; absent means automatic balancing.
    pub omp_preferred: BTreeMap<String, OmpPreference>,
}

/// Persists `AccountState` in the app's `StateStore` under `soprano-accounts`,
/// like the rest of Soprano's app state. Clones share one state.
#[derive(Clone)]
pub struct AccountStateStore {
    store: StateStore,
    state: Arc<Mutex<AccountState>>,
}

impl AccountStateStore {
    pub const KEY: &'static str = "soprano-accounts";

    /// Loads the saved state; a missing or unreadable payload starts empty.
    pub fn new(store: StateStore) -> Self {
        let state = store.get::<AccountState>(Self::KEY).unwrap_or_default();
        Self { store, state: Arc::new(Mutex::new(state)) }
    }

    pub fn state(&self) -> AccountState {
        self.lock().clone()
    }

    /// Applies `change` and saves the result when it differs.
    pub fn update(&self, change: impl FnOnce(&mut AccountState)) {
        let mut state = self.lock();
        let mut next = state.clone();
        change(&mut next);
        if next == *state {
            return;
        }
        self.store.set(Self::KEY, &next);
        *state = next;
    }

    fn lock(&self) -> MutexGuard<'_, AccountState> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saved_account_state_from_before_omp_preferences_still_loads() {
        let store = StateStore::in_memory();
        let older: serde_json::Value = serde_json::from_str(
            r#"{"claudeCode":{"accounts":[],"activeAccountId":null},"codexCLI":{"activeAccountId":"c1"}}"#,
        )
        .unwrap();
        store.set_raw("soprano-accounts", older);

        let accounts = AccountStateStore::new(store);

        let state = accounts.state();
        assert_eq!(state.codex_cli.active_account_id.as_deref(), Some("c1"));
        assert!(state.codex_cli.accounts.is_empty());
        assert!(state.omp_preferred.is_empty());
    }

    #[test]
    fn records_written_by_the_swift_app_keep_their_reference_date_timestamps() {
        let store = StateStore::in_memory();
        let swift: serde_json::Value = serde_json::from_str(
            r#"{"claudeCode":{"accounts":[{"id":"x","identity":{"email":"x@team.dev","organizationId":"org-x"},
                "createdAt":0,"lastAuthenticatedAt":86400.5}],"activeAccountId":"x"},
               "ompPreferred":{"anthropic":{"email":"a@b.c","orgId":"o"}}}"#,
        )
        .unwrap();
        store.set_raw("soprano-accounts", swift);

        let accounts = AccountStateStore::new(store.clone());
        let state = accounts.state();
        let record = &state.claude_code.accounts[0];
        assert_eq!(record.created_at.to_rfc3339(), "2001-01-01T00:00:00+00:00");
        assert_eq!(record.identity, AccountIdentity::new("x@team.dev", Some("org-x".into())));
        assert_eq!(state.omp_preferred["anthropic"].org_id.as_deref(), Some("o"));

        // Written back in the same shape.
        accounts.update(|state| state.codex_cli.active_account_id = Some("c".into()));
        let saved = store.get_raw("soprano-accounts").unwrap();
        assert_eq!(saved["claudeCode"]["accounts"][0]["lastAuthenticatedAt"], 86400.5);
        assert_eq!(saved["codexCLI"]["activeAccountId"], "c");
    }

    #[test]
    fn an_unchanged_update_does_not_write() {
        let store = StateStore::in_memory();
        let accounts = AccountStateStore::new(store.clone());
        accounts.update(|_| {});
        assert!(!store.contains("soprano-accounts"));
    }
}
