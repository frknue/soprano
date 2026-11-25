//! Antigravity CLI (`agy`) logins: several stored by Soprano, one in use for the whole machine.
//!
//! `agy` stores its Google OAuth login in the OS keyring (`service = "gemini"`,
//! `account = "antigravity"`), encoded with `zalando/go-keyring`'s `go-keyring-base64:` prefix
//! around a JSON document:
//! `{"token": {"access_token": …, "refresh_token": …, "expiry": …}, "auth_method": …, "id_token_email": …}`.
//!
//! Switching writes the chosen login's raw keyring blob into that item. The login `agy` had
//! before Soprano first switched it is saved as the System default and put back when that row
//! is chosen. Before every switch Soprano reconciles the live keyring back to the active
//! account so rotated refresh tokens are never lost.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use chrono::Utc;

use crate::error::{AccountResult, AgyAccountError};
use crate::files::{self, JsonObject, json_object};
use crate::models::{AccountIdentity, AccountList, AccountListId, AccountRow, Timestamp};
use crate::secrets::SecretStore;
use crate::state::{AccountStateStore, ManagedAccountRecord, ManagedAccountsState};
use crate::usage_api::{self, UsageCredential};
use soprano_launch::command_runner::{CancelToken, CommandRunner, LineHandler, RunOptions, first_url};

/// `agy`'s own keyring service (`zalando/go-keyring`).
pub const LIVE_SERVICE: &str = "gemini";
/// `agy`'s own keyring account name.
pub const LIVE_ACCOUNT: &str = "antigravity";
/// Soprano's secret-store service: one item per managed Antigravity account plus System default.
pub const MANAGED_SERVICE: &str = "Soprano Antigravity Accounts";
pub const SYSTEM_DEFAULT_SLOT: &str = "system-default";
pub const SYSTEM_DEFAULT_ROW_ID: &str = "system-default";
const GO_KEYRING_BASE64_PREFIX: &str = "go-keyring-base64:";

/// Decoded metadata from an Antigravity CLI keyring entry, alongside the raw secret string so
/// switching preserves any extra fields `agy` stores.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct AgyKeyringLogin {
    pub raw_secret: String,
    pub identity: AccountIdentity,
    pub plan: Option<String>,
    pub access_token: Option<String>,
    pub refresh_token: Option<String>,
    pub expiry: Option<Timestamp>,
}

impl AgyKeyringLogin {
    /// Decodes either a `go-keyring-base64:<b64>` blob (what `agy` writes) or plain JSON.
    pub fn parse(raw: &str) -> Option<Self> {
        let json_text = if let Some(encoded) = raw.strip_prefix(GO_KEYRING_BASE64_PREFIX) {
            let bytes = BASE64.decode(encoded.trim()).ok()?;
            String::from_utf8(bytes).ok()?
        } else {
            raw.to_owned()
        };
        let object = json_object(&json_text)?;
        let email = files::string(Some(&object), "id_token_email")
            .or_else(|| files::string(Some(&object), "email"))
            .filter(|email| !email.is_empty())?;
        let token = files::object(Some(&object), "token");
        let access_token = files::string(token, "access_token").map(str::to_owned);
        let refresh_token = files::string(token, "refresh_token").map(str::to_owned);
        let expiry = token.and_then(|token| token.get("expiry")).and_then(usage_api::date);
        let plan = files::string(Some(&object), "auth_method").filter(|m| !m.is_empty()).map(str::to_owned);
        Some(Self {
            raw_secret: raw.to_owned(),
            identity: AccountIdentity::new(email, None),
            plan,
            access_token,
            refresh_token,
            expiry,
        })
    }

    fn valid_access_token(&self, now: &Timestamp) -> Option<String> {
        let token = self.access_token.as_ref().filter(|t| !t.is_empty())?;
        if self.expiry.is_some_and(|expiry| expiry <= *now) {
            return None;
        }
        Some(token.clone())
    }

    fn is_expired(&self, now: &Timestamp) -> bool {
        self.expiry.is_some_and(|expiry| expiry <= *now)
    }

    fn same_tokens(&self, other: &Self) -> bool {
        self.access_token == other.access_token && self.refresh_token == other.refresh_token
    }
}

pub(crate) struct AgyAccountManager {
    store: AccountStateStore,
    /// Where `agy` keeps its live login (`service = "gemini"`, `account = "antigravity"`).
    live_keyring: Arc<dyn SecretStore>,
    /// Soprano's stored Antigravity logins (`MANAGED_SERVICE`).
    managed: Arc<dyn SecretStore>,
    runner: CommandRunner,
    queue: Mutex<()>,
}

impl AgyAccountManager {
    pub fn new(
        store: AccountStateStore,
        live_keyring: Arc<dyn SecretStore>,
        managed: Arc<dyn SecretStore>,
        runner: CommandRunner,
    ) -> Self {
        Self { store, live_keyring, managed, runner, queue: Mutex::new(()) }
    }

    fn serial(&self) -> MutexGuard<'_, ()> {
        self.queue.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn state(&self) -> ManagedAccountsState {
        self.store.state().agy_cli
    }

    fn update(&self, change: impl FnOnce(&mut ManagedAccountsState)) {
        self.store.update(|state| change(&mut state.agy_cli));
    }

    // MARK: - Listing

    pub fn list(&self) -> AccountList {
        let _serial = self.serial();
        let mut list = AccountList::new(AccountListId::AGY_CLI);
        let live = self.read_live().and_then(|live| {
            self.reconcile(live.as_ref())?;
            Ok(live)
        });
        match live {
            Ok(live) => list.system_default = Some(self.system_default_row(live.as_ref())),
            Err(error) => list.unavailable_reason = Some(error.to_string()),
        }
        let state = self.state();
        list.accounts = state.accounts.iter().map(row).collect();
        list.selected_account_id = state.active_account_id;
        list
    }

    /// Valid access tokens for usage lookups: the live login (silently refreshing it through
    /// `agy models` if its 1-hour Google access token has expired) and each inactive stored login
    /// whose access token is still valid.
    pub fn usage_credentials(&self) -> Vec<UsageCredential> {
        let mut credentials = Vec::new();
        let now = Utc::now();
        let state = self.state();

        let mut live = self.read_live().ok().flatten();
        if let Some(current) = live.as_ref()
            && current.is_expired(&now)
            && current.refresh_token.is_some()
        {
            self.refresh_live_token();
            if let Ok(refreshed) = self.read_live() {
                let _ = self.reconcile(refreshed.as_ref());
                live = refreshed;
            }
        }
        let now = Utc::now();
        if let Some(live) = live.as_ref()
            && let Some(token) = live.valid_access_token(&now)
        {
            let row_id = state.active_account_id.clone().unwrap_or_else(|| SYSTEM_DEFAULT_ROW_ID.into());
            credentials.push(UsageCredential {
                row_id,
                identity: live.identity.clone(),
                access_token: token,
                account_id: None,
            });
        }
        for record in &state.accounts {
            if state.active_account_id.as_deref() == Some(record.id.as_str()) {
                continue;
            }
            let Ok(Some(stored)) = self.read_stored(&record.id) else { continue };
            let Some(token) = stored.valid_access_token(&now) else { continue };
            credentials.push(UsageCredential {
                row_id: record.id.clone(),
                identity: record.identity.clone(),
                access_token: token,
                account_id: None,
            });
        }
        credentials
    }

    /// Nudges `agy` to refresh its expired OAuth access token in the OS keyring. Fails silently
    /// if `agy` is not installed or offline.
    fn refresh_live_token(&self) {
        let arguments = ["agy", "models"].map(String::from);
        let options = RunOptions::with_timeout(Duration::from_secs(15));
        let _ = self.runner.run_cli(&arguments, &BTreeMap::new(), options);
    }

    // MARK: - Actions

    pub fn add_account(
        &self,
        on_sign_in_url: LineHandler,
        cancel: &CancelToken,
    ) -> AccountResult<ManagedAccountRecord> {
        let previous = self.prepare_live_for_sign_in()?;
        let login = match self.run_sign_in(on_sign_in_url, cancel) {
            Ok(login) => login,
            Err(error) => {
                self.restore_live(previous.as_deref());
                return Err(error);
            }
        };
        let _serial = self.serial();
        match self.commit_new_account(login, previous.as_deref()) {
            Ok(record) => Ok(record),
            Err(error) => {
                self.restore_live(previous.as_deref());
                Err(error)
            }
        }
    }

    pub fn reauthenticate(
        &self,
        account_id: &str,
        on_sign_in_url: LineHandler,
        cancel: &CancelToken,
    ) -> AccountResult<()> {
        if !self.state().accounts.iter().any(|record| record.id == account_id) {
            return Err(AgyAccountError::UnknownAccount.into());
        }
        let previous = self.prepare_live_for_sign_in()?;
        let login = match self.run_sign_in(on_sign_in_url, cancel) {
            Ok(login) => login,
            Err(error) => {
                self.restore_live(previous.as_deref());
                return Err(error);
            }
        };
        let _serial = self.serial();
        match self.commit_reauthentication(account_id, login, previous.as_deref()) {
            Ok(()) => Ok(()),
            Err(error) => {
                self.restore_live(previous.as_deref());
                Err(error)
            }
        }
    }

    /// Signs `agy` in with `account_id`, or puts its own login back (`None`).
    pub fn select(&self, account_id: Option<&str>) -> AccountResult<()> {
        let _serial = self.serial();
        self.select_now(account_id)
    }

    pub fn remove(&self, account_id: &str) -> AccountResult<()> {
        let _serial = self.serial();
        if self.state().active_account_id.as_deref() == Some(account_id) {
            self.select_now(None)?;
        }
        self.managed.delete(MANAGED_SERVICE, account_id)?;
        self.update(|state| state.accounts.retain(|record| record.id != account_id));
        Ok(())
    }

    fn prepare_live_for_sign_in(&self) -> AccountResult<Option<String>> {
        let _serial = self.serial();
        let raw = self.live_keyring.read(LIVE_SERVICE, LIVE_ACCOUNT)?;
        let parsed = raw.as_deref().and_then(AgyKeyringLogin::parse);
        self.reconcile(parsed.as_ref())?;
        Ok(raw)
    }

    fn restore_live(&self, previous: Option<&str>) {
        match previous {
            Some(secret) => {
                let _ = self.live_keyring.write(LIVE_SERVICE, LIVE_ACCOUNT, secret);
            }
            None => {
                let _ = self.live_keyring.delete(LIVE_SERVICE, LIVE_ACCOUNT);
            }
        }
    }

    fn run_sign_in(
        &self,
        on_sign_in_url: LineHandler,
        cancel: &CancelToken,
    ) -> AccountResult<AgyKeyringLogin> {
        let on_line: LineHandler = Arc::new(move |line: &str| {
            if let Some(url) = first_url(line) {
                on_sign_in_url(&url);
            }
        });
        let options = RunOptions {
            keep_stdin_open: true,
            on_output_line: Some(on_line),
            cancel: Some(cancel.clone()),
            ..RunOptions::with_timeout(Duration::from_secs(600))
        };
        let arguments = ["agy", "acp", "--login"].map(String::from);
        let result = self.runner.run_cli(&arguments, &BTreeMap::new(), options)?;
        if !result.succeeded() {
            return Err(AgyAccountError::LoginFailed(result.failure_message_running("agy")).into());
        }
        let secret =
            self.live_keyring.read(LIVE_SERVICE, LIVE_ACCOUNT)?.ok_or(AgyAccountError::NoCredentials)?;
        AgyKeyringLogin::parse(&secret).ok_or_else(|| AgyAccountError::NoIdentity.into())
    }

    fn commit_new_account(
        &self,
        login: AgyKeyringLogin,
        previous_raw: Option<&str>,
    ) -> AccountResult<ManagedAccountRecord> {
        let state = self.state();
        if state.accounts.iter().any(|record| record.identity.matches(&login.identity)) {
            return Err(AgyAccountError::Duplicate(login.identity.email).into());
        }
        if state.active_account_id.is_none() {
            let previous_login = previous_raw.and_then(AgyKeyringLogin::parse);
            self.save_system_default(previous_login.as_ref())?;
        }
        let now = Utc::now();
        let record = ManagedAccountRecord {
            id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            identity: login.identity,
            organization_name: None,
            plan: login.plan,
            created_at: now,
            last_authenticated_at: now,
        };
        self.managed.write(MANAGED_SERVICE, &record.id, &login.raw_secret)?;
        self.update(|state| {
            state.accounts.push(record.clone());
            state.active_account_id = Some(record.id.clone());
        });
        Ok(record)
    }

    fn commit_reauthentication(
        &self,
        account_id: &str,
        login: AgyKeyringLogin,
        previous_raw: Option<&str>,
    ) -> AccountResult<()> {
        let Some(record) = self.state().accounts.into_iter().find(|record| record.id == account_id) else {
            return Err(AgyAccountError::UnknownAccount.into());
        };
        if !login.identity.matches(&record.identity) {
            return Err(AgyAccountError::WrongAccount {
                expected: record.identity.email,
                signed_in: login.identity.email,
            }
            .into());
        }
        self.managed.write(MANAGED_SERVICE, account_id, &login.raw_secret)?;
        self.update(|state| {
            if let Some(record) = state.accounts.iter_mut().find(|record| record.id == account_id) {
                record.last_authenticated_at = Utc::now();
                if login.plan.is_some() {
                    record.plan = login.plan.clone();
                }
            }
        });
        // If another account was active during re-auth, restore that active login to the keyring.
        if self.state().active_account_id.as_deref() != Some(account_id) {
            self.restore_live(previous_raw);
        }
        Ok(())
    }

    fn select_now(&self, account_id: Option<&str>) -> AccountResult<()> {
        let live = self.read_live()?;
        self.reconcile(live.as_ref())?;
        let state = self.state();
        if account_id == state.active_account_id.as_deref() {
            return Ok(());
        }
        match account_id {
            Some(account_id) => {
                let Some(record) = state.accounts.iter().find(|record| record.id == account_id) else {
                    return Err(AgyAccountError::UnknownAccount.into());
                };
                let Some(stored) = self.read_stored(account_id)? else {
                    return Err(AgyAccountError::MissingCredentials(record.identity.email.clone()).into());
                };
                if state.active_account_id.is_none() {
                    self.save_system_default(live.as_ref())?;
                }
                self.live_keyring.write(LIVE_SERVICE, LIVE_ACCOUNT, &stored.raw_secret)?;
                self.update(|state| state.active_account_id = Some(account_id.to_owned()));
            }
            None => {
                if let Some(snapshot) = self.read_stored(SYSTEM_DEFAULT_SLOT)? {
                    self.live_keyring.write(LIVE_SERVICE, LIVE_ACCOUNT, &snapshot.raw_secret)?;
                }
                self.update(|state| state.active_account_id = None);
            }
        }
        Ok(())
    }

    // MARK: - Keyring & Reconciliation

    fn read_live(&self) -> AccountResult<Option<AgyKeyringLogin>> {
        let Some(secret) = self.live_keyring.read(LIVE_SERVICE, LIVE_ACCOUNT)? else { return Ok(None) };
        Ok(AgyKeyringLogin::parse(&secret))
    }

    fn read_stored(&self, slot: &str) -> AccountResult<Option<AgyKeyringLogin>> {
        let Some(secret) = self.managed.read(MANAGED_SERVICE, slot)? else { return Ok(None) };
        Ok(AgyKeyringLogin::parse(&secret))
    }

    fn reconcile(&self, live: Option<&AgyKeyringLogin>) -> AccountResult<()> {
        let Some(active) = self.state().active_account().cloned() else { return Ok(()) };
        let stored = self.read_stored(&active.id)?;
        let Some(live) = live else {
            self.save_system_default(None)?;
            self.update(|state| state.active_account_id = None);
            return Ok(());
        };
        if stored.as_ref().is_some_and(|stored| stored.same_tokens(live)) {
            return Ok(());
        }
        if live.identity.matches(&active.identity) {
            self.managed.write(MANAGED_SERVICE, &active.id, &live.raw_secret)?;
        } else {
            self.save_system_default(Some(live))?;
            self.update(|state| state.active_account_id = None);
        }
        Ok(())
    }

    fn save_system_default(&self, live: Option<&AgyKeyringLogin>) -> AccountResult<()> {
        match live {
            Some(login) => {
                self.managed.write(MANAGED_SERVICE, SYSTEM_DEFAULT_SLOT, &login.raw_secret)?;
                let now = Utc::now();
                let record = ManagedAccountRecord {
                    id: SYSTEM_DEFAULT_ROW_ID.into(),
                    identity: login.identity.clone(),
                    organization_name: None,
                    plan: login.plan.clone(),
                    created_at: now,
                    last_authenticated_at: now,
                };
                self.update(|state| state.system_default = Some(record));
            }
            None => {
                let _ = self.managed.delete(MANAGED_SERVICE, SYSTEM_DEFAULT_SLOT);
                self.update(|state| state.system_default = None);
            }
        }
        Ok(())
    }

    fn system_default_row(&self, live: Option<&AgyKeyringLogin>) -> AccountRow {
        let state = self.state();
        if state.active_account_id.is_none() {
            match live {
                Some(login) => AccountRow {
                    id: SYSTEM_DEFAULT_ROW_ID.into(),
                    identity: login.identity.clone(),
                    plan: login.plan.clone(),
                    ..AccountRow::default()
                },
                None => AccountRow {
                    id: SYSTEM_DEFAULT_ROW_ID.into(),
                    problem: Some("Not signed in".into()),
                    ..AccountRow::default()
                },
            }
        } else {
            match state.system_default {
                Some(record) => row(&record),
                None => AccountRow {
                    id: SYSTEM_DEFAULT_ROW_ID.into(),
                    problem: Some("Not signed in".into()),
                    ..AccountRow::default()
                },
            }
        }
    }
}

fn row(record: &ManagedAccountRecord) -> AccountRow {
    AccountRow {
        id: record.id.clone(),
        identity: record.identity.clone(),
        organization_name: record.organization_name.clone(),
        plan: record.plan.clone(),
        added_at: Some(record.created_at),
        usage: None,
        problem: None,
    }
}

/// Helper for encoding a JSON keyring payload with `go-keyring-base64:` prefix (used in tests).
#[cfg(test)]
pub(crate) fn encode_go_keyring(object: &JsonObject) -> String {
    format!("{GO_KEYRING_BASE64_PREFIX}{}", BASE64.encode(files::json_string(object).as_bytes()))
}

#[allow(dead_code)]
fn _keep_json_object(_: &JsonObject) {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::secrets::MemorySecretStore;
    use serde_json::json;
    use soprano_platform::StateStore;

    fn keyring_blob(email: &str, access: &str, refresh: &str, expiry: &str) -> String {
        let obj = json!({
            "token": {
                "access_token": access,
                "token_type": "Bearer",
                "refresh_token": refresh,
                "expiry": expiry,
                "expires_in": 3599
            },
            "auth_method": "consumer",
            "id_token_email": email
        });
        encode_go_keyring(obj.as_object().unwrap())
    }

    #[test]
    fn parses_go_keyring_base64_and_plain_json_antigravity_logins() {
        let blob = keyring_blob("ada@example.com", "ya29.tok", "1//ref", "2099-01-01T00:00:00Z");
        let parsed = AgyKeyringLogin::parse(&blob).expect("parsed");
        assert_eq!(parsed.identity.email, "ada@example.com");
        assert_eq!(parsed.plan.as_deref(), Some("consumer"));
        assert_eq!(parsed.access_token.as_deref(), Some("ya29.tok"));
        assert_eq!(parsed.refresh_token.as_deref(), Some("1//ref"));
        assert!(parsed.valid_access_token(&Utc::now()).is_some());

        let expired = keyring_blob("ada@example.com", "ya29.old", "1//ref", "2020-01-01T00:00:00Z");
        let parsed_expired = AgyKeyringLogin::parse(&expired).expect("expired");
        assert!(parsed_expired.valid_access_token(&Utc::now()).is_none());
    }

    #[test]
    fn lists_live_system_default_and_switches_between_managed_accounts() {
        let store = AccountStateStore::new(StateStore::in_memory());
        let keyring = Arc::new(MemorySecretStore::default());
        let managed = Arc::new(MemorySecretStore::default());
        let default_blob =
            keyring_blob("default@gmail.com", "tok-default", "ref-default", "2099-01-01T00:00:00Z");
        keyring.write(LIVE_SERVICE, LIVE_ACCOUNT, &default_blob).unwrap();

        let manager = AgyAccountManager::new(
            store,
            Arc::clone(&keyring) as Arc<dyn SecretStore>,
            Arc::clone(&managed) as Arc<dyn SecretStore>,
            CommandRunner::new("/bin/sh"),
        );

        let initial = manager.list();
        assert_eq!(initial.system_default.as_ref().unwrap().identity.email, "default@gmail.com");
        assert_eq!(manager.usage_credentials().len(), 1);
        assert_eq!(manager.usage_credentials()[0].access_token, "tok-default");

        // Commit a second account and verify switching swaps the live keyring and preserves System default.
        let work_blob = keyring_blob("work@gmail.com", "tok-work", "ref-work", "2099-01-01T00:00:00Z");
        keyring.write(LIVE_SERVICE, LIVE_ACCOUNT, &work_blob).unwrap();
        let record = manager
            .commit_new_account(AgyKeyringLogin::parse(&work_blob).unwrap(), Some(&default_blob))
            .unwrap();
        assert_eq!(manager.list().selected_account_id.as_deref(), Some(record.id.as_str()));

        // Switch back to System default -> restores default_blob into live keyring.
        manager.select(None).unwrap();
        assert_eq!(keyring.read(LIVE_SERVICE, LIVE_ACCOUNT).unwrap().as_deref(), Some(default_blob.as_str()));
        assert_eq!(manager.list().selected_account_id, None);

        // Switch back to managed account, then simulate `agy` refreshing the live token and reconcile.
        manager.select(Some(&record.id)).unwrap();
        let refreshed_blob =
            keyring_blob("work@gmail.com", "tok-work-2", "ref-work-2", "2099-01-02T00:00:00Z");
        keyring.write(LIVE_SERVICE, LIVE_ACCOUNT, &refreshed_blob).unwrap();
        let _ = manager.list();
        assert_eq!(
            managed.read(MANAGED_SERVICE, &record.id).unwrap().as_deref(),
            Some(refreshed_blob.as_str())
        );

        // Removing the active managed account restores System default.
        manager.remove(&record.id).unwrap();
        assert_eq!(keyring.read(LIVE_SERVICE, LIVE_ACCOUNT).unwrap().as_deref(), Some(default_blob.as_str()));
        assert!(manager.list().accounts.is_empty());
    }
}
