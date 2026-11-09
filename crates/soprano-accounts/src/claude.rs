//! Claude Code logins: several stored by Soprano, one in use for the whole
//! machine.
//!
//! Claude Code reads its login from the Keychain item `Claude Code-credentials`
//! (filed under the user name) on a Mac, and from `~/.claude/.credentials.json`
//! on Linux and Windows (and on a Mac without a usable Keychain); it names the
//! account in `oauthAccount` in `~/.claude.json`. Switching writes the chosen
//! login's `claudeAiOauth` into that store — keeping MCP tokens and anything
//! else stored beside it — and its `oauthAccount` into `~/.claude.json`.
//! Running sessions pick the new login up on their next credential read.
//!
//! The login Claude Code had before Soprano first switched it is saved as the
//! System default and put back when that row is chosen. Claude Code refreshes
//! (and so rotates) tokens on its own; before every switch Soprano copies the
//! live tokens back to the account they belong to, proven by `oauthAccount` or
//! by asking Anthropic whose token it is.
//!
//! Soprano's own copies of the logins live in the OS secret store (service
//! `Soprano Claude Code Accounts`, one item per account plus the System
//! default).

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex, MutexGuard};
use std::time::Duration;

use chrono::Utc;
use regex::Regex;
use serde_json::Value;
use sha2::{Digest, Sha256};
use unicode_normalization::UnicodeNormalization;

use crate::codex::create_private_directory;
use crate::command::{CancelToken, CommandRunner, LineHandler, RunOptions, first_url};
use crate::error::{AccountResult, ClaudeAccountError};
use crate::files::{self, JsonObject, json_object, json_object_at, json_string};
use crate::models::{
    AccountIdentity, AccountList, AccountListId, AccountRow, Timestamp, timestamp_from_seconds,
};
use crate::secrets::SecretStore;
use crate::state::{AccountPaths, AccountStateStore, ManagedAccountRecord, ManagedAccountsState};
use crate::usage_api::{UsageCredential, number};

/// Soprano's secret-store service: one item per managed account, plus the System default.
pub const MANAGED_SERVICE: &str = "Soprano Claude Code Accounts";
/// Claude Code's own Keychain item (macOS).
pub const LIVE_SERVICE: &str = "Claude Code-credentials";
pub const SYSTEM_DEFAULT_SLOT: &str = "system-default";
pub const SYSTEM_DEFAULT_ROW_ID: &str = "system-default";

/// Asks Anthropic who an access token belongs to.
pub(crate) type ProfileLookup = Arc<dyn Fn(&str) -> Option<AccountIdentity> + Send + Sync>;

pub(crate) struct ClaudeCodeAccountManager {
    store: AccountStateStore,
    /// Where Claude Code keeps its login besides the plaintext file: the
    /// Keychain (macOS); nil where Claude Code only uses the file.
    live_keychain: Option<Arc<dyn SecretStore>>,
    /// Soprano's stored logins.
    managed: Arc<dyn SecretStore>,
    runner: CommandRunner,
    paths: AccountPaths,
    profile: ProfileLookup,
    keychain_user: String,
    /// Every read-back and switch runs alone: two interleaved could write one
    /// account's tokens into another's slot.
    queue: Mutex<()>,
}

/// What Claude Code is signed in with now. `blob` is the whole credential
/// item, so a switch can keep everything but `claudeAiOauth`;
/// `keychain_secret` is that item as stored, nil when there is none.
struct LiveLogin {
    blob: JsonObject,
    oauth_account: Option<JsonObject>,
    keychain_secret: Option<String>,
}

impl LiveLogin {
    fn oauth(&self) -> Option<&JsonObject> {
        files::object(Some(&self.blob), "claudeAiOauth")
    }
}

struct StoredLogin {
    oauth: Option<JsonObject>,
    oauth_account: Option<JsonObject>,
}

struct CapturedLogin {
    oauth: JsonObject,
    oauth_account: JsonObject,
    identity: AccountIdentity,
    organization_name: Option<String>,
    plan: Option<String>,
}

static VALID_KEYCHAIN_USER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new("^[a-zA-Z0-9._-]+$").expect("valid pattern"));

/// The Keychain account Claude Code files its item under: the user name, or a
/// fixed fallback for names it rejects (SSO user names with "@").
pub fn keychain_user() -> String {
    let user = std::env::var("USER").or_else(|_| std::env::var("USERNAME")).unwrap_or_default();
    if VALID_KEYCHAIN_USER.is_match(&user) { user } else { "claude-code-user".into() }
}

/// The item Claude Code 2.1+ uses when `CLAUDE_CONFIG_DIR` points at
/// `config_directory`: the service suffixed with sha256(NFC(path))[0..<8].
pub fn scoped_service(config_directory: &str) -> String {
    let normalized: String = config_directory.nfc().collect();
    let digest = Sha256::digest(normalized.as_bytes());
    let hex: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
    format!("{LIVE_SERVICE}-{}", &hex[..8])
}

impl ClaudeCodeAccountManager {
    pub fn new(
        store: AccountStateStore,
        live_keychain: Option<Arc<dyn SecretStore>>,
        managed: Arc<dyn SecretStore>,
        runner: CommandRunner,
        paths: AccountPaths,
        profile: ProfileLookup,
    ) -> Self {
        Self {
            store,
            live_keychain,
            managed,
            runner,
            paths,
            profile,
            keychain_user: keychain_user(),
            queue: Mutex::new(()),
        }
    }

    fn serial(&self) -> MutexGuard<'_, ()> {
        self.queue.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn state(&self) -> ManagedAccountsState {
        self.store.state().claude_code
    }

    fn update(&self, change: impl FnOnce(&mut ManagedAccountsState)) {
        self.store.update(|state| change(&mut state.claude_code));
    }

    fn credentials_file(&self) -> PathBuf {
        self.paths.claude_credentials_file()
    }

    // MARK: - Listing

    pub fn list(&self) -> AccountList {
        let _serial = self.serial();
        let mut list = AccountList::new(AccountListId::CLAUDE_CODE);
        let live = self.read_live().and_then(|live| {
            self.reconcile(&live)?;
            Ok(live)
        });
        match live {
            Ok(live) => list.system_default = Some(self.system_default_row(&live)),
            Err(error) => list.unavailable_reason = Some(error.to_string()),
        }
        let state = self.state();
        list.accounts = state.accounts.iter().map(row).collect();
        list.selected_account_id = state.active_account_id;
        list
    }

    /// Tokens that are still valid, for usage lookups: the live login (whoever
    /// is active) and each stored login that is not.
    pub fn usage_credentials(&self) -> Vec<UsageCredential> {
        let mut credentials = Vec::new();
        let now = Utc::now();
        let state = self.state();
        if let Ok(live) = self.read_live()
            && let Some(token) = valid_access_token(live.oauth(), &now)
            && let Some(identity) = identity(live.oauth_account.as_ref())
        {
            let row_id = state.active_account_id.clone().unwrap_or_else(|| SYSTEM_DEFAULT_ROW_ID.into());
            credentials.push(UsageCredential { row_id, identity, access_token: token, account_id: None });
        }
        for record in &state.accounts {
            if state.active_account_id.as_deref() == Some(record.id.as_str()) {
                continue;
            }
            let Ok(Some(stored)) = self.read_stored(&record.id) else { continue };
            let Some(token) = valid_access_token(stored.oauth.as_ref(), &now) else { continue };
            credentials.push(UsageCredential {
                row_id: record.id.clone(),
                identity: record.identity.clone(),
                access_token: token,
                account_id: None,
            });
        }
        credentials
    }

    // MARK: - Actions

    /// Signs in a new account in the browser and makes it the active one.
    pub fn add_account(
        &self,
        on_sign_in_url: LineHandler,
        cancel: &CancelToken,
    ) -> AccountResult<ManagedAccountRecord> {
        let login = self.sign_in(on_sign_in_url, cancel)?;
        let _serial = self.serial();
        self.commit_new_account(login)
    }

    pub fn reauthenticate(
        &self,
        account_id: &str,
        on_sign_in_url: LineHandler,
        cancel: &CancelToken,
    ) -> AccountResult<()> {
        if !self.state().accounts.iter().any(|record| record.id == account_id) {
            return Err(ClaudeAccountError::UnknownAccount.into());
        }
        let login = self.sign_in(on_sign_in_url, cancel)?;
        let _serial = self.serial();
        self.commit_reauthentication(account_id, login)
    }

    /// Signs Claude Code in with `account_id`, or puts its own login back (nil).
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

    fn commit_new_account(&self, login: CapturedLogin) -> AccountResult<ManagedAccountRecord> {
        if self.state().accounts.iter().any(|record| record.identity.matches(&login.identity)) {
            return Err(ClaudeAccountError::Duplicate(login.identity.email).into());
        }
        let now = Utc::now();
        let record = ManagedAccountRecord {
            id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            identity: login.identity,
            organization_name: login.organization_name,
            plan: login.plan,
            created_at: now,
            last_authenticated_at: now,
        };
        self.write_stored(&record.id, Some(&login.oauth), Some(&login.oauth_account))?;
        self.update(|state| state.accounts.push(record.clone()));
        self.select_now(Some(&record.id))?;
        Ok(record)
    }

    fn commit_reauthentication(&self, account_id: &str, login: CapturedLogin) -> AccountResult<()> {
        let Some(record) = self.state().accounts.into_iter().find(|record| record.id == account_id) else {
            return Err(ClaudeAccountError::UnknownAccount.into());
        };
        if !login.identity.matches(&record.identity) {
            return Err(ClaudeAccountError::WrongAccount {
                expected: record.identity.email,
                signed_in: login.identity.email,
            }
            .into());
        }
        self.write_stored(account_id, Some(&login.oauth), Some(&login.oauth_account))?;
        self.update(|state| {
            if let Some(record) = state.accounts.iter_mut().find(|record| record.id == account_id) {
                record.last_authenticated_at = Utc::now();
                if login.plan.is_some() {
                    record.plan = login.plan.clone();
                }
                if login.organization_name.is_some() {
                    record.organization_name = login.organization_name.clone();
                }
            }
        });
        if self.state().active_account_id.as_deref() == Some(account_id) {
            let live = self.read_live()?;
            self.write_live(Some(&login.oauth), Some(&login.oauth_account), &live)?;
        }
        Ok(())
    }

    fn select_now(&self, account_id: Option<&str>) -> AccountResult<()> {
        let live = self.read_live()?;
        self.reconcile(&live)?;
        let state = self.state();
        if account_id == state.active_account_id.as_deref() {
            return Ok(());
        }
        match account_id {
            Some(account_id) => {
                let Some(record) = state.accounts.iter().find(|record| record.id == account_id) else {
                    return Err(ClaudeAccountError::UnknownAccount.into());
                };
                let Some(stored) = self.read_stored(account_id)? else {
                    return Err(ClaudeAccountError::MissingCredentials(record.identity.email.clone()).into());
                };
                if state.active_account_id.is_none() {
                    self.save_system_default(&live)?;
                }
                self.write_live(stored.oauth.as_ref(), stored.oauth_account.as_ref(), &live)?;
                self.update(|state| state.active_account_id = Some(account_id.to_owned()));
            }
            None => {
                // Without a saved System default there is nothing to put back;
                // leave Claude Code signed in rather than signing it out.
                if let Some(snapshot) = self.read_stored(SYSTEM_DEFAULT_SLOT)? {
                    self.write_live(snapshot.oauth.as_ref(), snapshot.oauth_account.as_ref(), &live)?;
                }
                self.update(|state| state.active_account_id = None);
            }
        }
        Ok(())
    }

    // MARK: - Live login

    fn read_live(&self) -> AccountResult<LiveLogin> {
        let secret = match &self.live_keychain {
            Some(keychain) => keychain.read(LIVE_SERVICE, &self.keychain_user)?,
            None => None,
        };
        let blob = match &secret {
            Some(secret) => json_object(secret).unwrap_or_default(),
            None => json_object_at(&self.credentials_file())?.unwrap_or_default(),
        };
        let config = json_object_at(&self.paths.claude_global_config_file())?;
        let oauth_account = files::object(config.as_ref(), "oauthAccount").cloned();
        Ok(LiveLogin { blob, oauth_account, keychain_secret: secret })
    }

    /// Puts `oauth` (nil: signed out) and `oauth_account` where Claude Code reads them.
    ///
    /// All or nothing: `oauthAccount` is how `reconcile` tells whose tokens
    /// are live, so a failure after the credential store changed puts the old
    /// stores back — else the next read-back would file the new account's
    /// tokens under the old one and lose its refresh token.
    fn write_live(
        &self,
        oauth: Option<&JsonObject>,
        oauth_account: Option<&JsonObject>,
        live: &LiveLogin,
    ) -> AccountResult<()> {
        let user = &self.keychain_user;
        let secret = json_string(&replacing_oauth(&live.blob, oauth));
        // Claude Code reads a config-scoped item instead when CLAUDE_CONFIG_DIR
        // is set; keep the one for ~/.claude current when it exists.
        let scoped = scoped_service(&self.paths.claude_config_directory().to_string_lossy());
        let scoped_secret = match &self.live_keychain {
            Some(keychain) => keychain.read(&scoped, user)?,
            None => None,
        };
        // The plaintext copy Claude Code falls back to without a Keychain — and
        // the only store where there is none.
        let credentials_file = self.credentials_file();
        let file_blob = json_object_at(&credentials_file)?;
        let file_data = match file_blob {
            Some(_) => Some(fs::read(&credentials_file)?),
            None => None,
        };

        let attempt = || -> AccountResult<()> {
            if let Some(keychain) = &self.live_keychain {
                keychain.write(LIVE_SERVICE, user, &secret)?;
                if let Some(scoped_secret) = &scoped_secret {
                    let scoped_blob = json_object(scoped_secret).unwrap_or_default();
                    keychain.write(&scoped, user, &json_string(&replacing_oauth(&scoped_blob, oauth)))?;
                }
            }
            if let Some(file_blob) = &file_blob {
                let data = files::json_data(&replacing_oauth(file_blob, oauth), false);
                files::write(&data, &credentials_file, 0o600)?;
            } else if self.live_keychain.is_none() && oauth.is_some() {
                if let Some(parent) = credentials_file.parent() {
                    create_private_directory(parent)?;
                }
                let data = files::json_data(&replacing_oauth(&live.blob, oauth), false);
                files::write(&data, &credentials_file, 0o600)?;
            }
            self.write_oauth_account(oauth_account)
        };
        let Err(error) = attempt() else { return Ok(()) };

        if let Some(keychain) = &self.live_keychain {
            match &live.keychain_secret {
                Some(previous) => {
                    let _ = keychain.write(LIVE_SERVICE, user, previous);
                }
                None => {
                    let _ = keychain.delete(LIVE_SERVICE, user);
                }
            }
            if let Some(scoped_secret) = &scoped_secret {
                let _ = keychain.write(&scoped, user, scoped_secret);
            }
        }
        match &file_data {
            Some(data) => {
                let _ = files::write(data, &credentials_file, 0o600);
            }
            None if self.live_keychain.is_none() => {
                let _ = fs::remove_file(&credentials_file);
            }
            None => {}
        }
        Err(error)
    }

    fn write_oauth_account(&self, oauth_account: Option<&JsonObject>) -> AccountResult<()> {
        let path = self.paths.claude_global_config_file();
        let mut config = json_object_at(&path)?.unwrap_or_default();
        if config.is_empty() && oauth_account.is_none() {
            return Ok(());
        }
        match oauth_account {
            Some(account) => {
                config.insert("oauthAccount".into(), Value::Object(account.clone()));
            }
            None => {
                config.remove("oauthAccount");
            }
        }
        files::write(&files::json_data(&config, true), &path, 0o600)?;
        Ok(())
    }

    // MARK: - Reconciliation

    /// Keeps Soprano's copy of the active login in step with Claude Code.
    ///
    /// When the live tokens differ from the stored ones, Claude Code either
    /// refreshed them — they are the active account's newest tokens and must
    /// be kept, since the stored refresh token is now spent — or someone signed
    /// Claude Code in to another account, which then becomes the System default.
    fn reconcile(&self, live: &LiveLogin) -> AccountResult<()> {
        let Some(active) = self.state().active_account().cloned() else { return Ok(()) };
        let stored = self.read_stored(&active.id)?;

        let Some(live_oauth) = live.oauth() else {
            // Signed out under us (`claude auth logout`): that is Claude Code's own state now.
            self.save_system_default(live)?;
            self.update(|state| state.active_account_id = None);
            return Ok(());
        };
        if same_tokens(Some(live_oauth), stored.as_ref().and_then(|stored| stored.oauth.as_ref())) {
            return Ok(());
        }

        if identity(live.oauth_account.as_ref()).is_some_and(|claimed| claimed.matches(&active.identity)) {
            return self.write_stored(&active.id, Some(live_oauth), live.oauth_account.as_ref());
        }
        // `oauthAccount` names someone else; only the token itself can say who it is.
        let Some(token) = valid_access_token(Some(live_oauth), &Utc::now()) else { return Ok(()) };
        let Some(owner) = (self.profile)(&token) else { return Ok(()) };
        if owner.matches(&active.identity) {
            let stored_account = stored.as_ref().and_then(|stored| stored.oauth_account.as_ref());
            self.write_stored(&active.id, Some(live_oauth), stored_account.or(live.oauth_account.as_ref()))?;
            if let Some(oauth_account) = stored_account {
                self.write_oauth_account(Some(oauth_account))?;
            }
        } else {
            self.save_system_default(live)?;
            self.update(|state| state.active_account_id = None);
        }
        Ok(())
    }

    // MARK: - Soprano's stored logins

    /// Saves Claude Code's own login, to put back when System default is chosen.
    fn save_system_default(&self, live: &LiveLogin) -> AccountResult<()> {
        self.write_stored(SYSTEM_DEFAULT_SLOT, live.oauth(), live.oauth_account.as_ref())?;
        let record = record(live.oauth_account.as_ref(), live.oauth());
        self.update(|state| state.system_default = record);
        Ok(())
    }

    fn read_stored(&self, account: &str) -> AccountResult<Option<StoredLogin>> {
        let Some(secret) = self.managed.read(MANAGED_SERVICE, account)? else { return Ok(None) };
        let Some(object) = json_object(&secret) else { return Ok(None) };
        Ok(Some(StoredLogin {
            oauth: files::object(Some(&object), "claudeAiOauth").cloned(),
            oauth_account: files::object(Some(&object), "oauthAccount").cloned(),
        }))
    }

    fn write_stored(
        &self,
        account: &str,
        oauth: Option<&JsonObject>,
        oauth_account: Option<&JsonObject>,
    ) -> AccountResult<()> {
        let mut object = JsonObject::new();
        object.insert("claudeAiOauth".into(), oauth.cloned().map_or(Value::Null, Value::Object));
        object.insert("oauthAccount".into(), oauth_account.cloned().map_or(Value::Null, Value::Object));
        self.managed.write(MANAGED_SERVICE, account, &json_string(&object))?;
        Ok(())
    }

    // MARK: - Sign-in

    /// Runs `claude auth login` against a throwaway config directory, so the
    /// login lands in that directory's own credential store and never touches
    /// the one Claude Code is using; Soprano copies it out and deletes the rest
    /// — also when the sign-in is cancelled or fails.
    fn sign_in(&self, on_sign_in_url: LineHandler, cancel: &CancelToken) -> AccountResult<CapturedLogin> {
        let directory = std::env::temp_dir()
            .join(format!("soprano-claude-login-{}", uuid::Uuid::new_v4().to_string().to_uppercase()));
        create_private_directory(&directory)?;
        // Claude Code hashes the path it is given into the Keychain item name;
        // the temporary directory lives behind the /var → /private/var link on
        // a Mac, so give it the resolved path and look up that same name.
        let config_directory = files::resolving_symlinks(&directory).to_string_lossy().into_owned();
        let scoped = scoped_service(&config_directory);
        let environment = BTreeMap::from([
            ("CLAUDE_CONFIG_DIR".to_owned(), config_directory.clone()),
            ("CLAUDE_SECURESTORAGE_CONFIG_DIR".to_owned(), config_directory),
        ]);

        let result = self.capture_login(&directory, &scoped, &environment, on_sign_in_url, cancel);
        if let Some(keychain) = &self.live_keychain {
            let _ = keychain.delete(&scoped, &self.keychain_user);
        }
        let _ = fs::remove_dir_all(&directory);
        result
    }

    fn capture_login(
        &self,
        directory: &Path,
        scoped: &str,
        environment: &BTreeMap<String, String>,
        on_sign_in_url: LineHandler,
        cancel: &CancelToken,
    ) -> AccountResult<CapturedLogin> {
        let on_line: LineHandler = Arc::new(move |line: &str| {
            if let Some(url) = first_url(line) {
                on_sign_in_url(&url);
            }
        });
        let options = RunOptions {
            keep_stdin_open: true,
            on_output_line: Some(on_line),
            cancel: Some(cancel.clone()),
            ..RunOptions::default()
        };
        let result = self.runner.run_cli(
            &["claude", "auth", "login", "--claudeai"],
            environment,
            Duration::from_secs(600),
            options,
        )?;
        if !result.succeeded() {
            return Err(ClaudeAccountError::LoginFailed(result.failure_message_running("claude")).into());
        }

        let mut blob = None;
        if let Some(keychain) = &self.live_keychain
            && let Some(secret) = keychain.read(scoped, &self.keychain_user)?
        {
            blob = json_object(&secret);
        }
        if blob.is_none() {
            blob = json_object_at(&directory.join(".credentials.json")).ok().flatten();
        }
        let oauth = files::object(blob.as_ref(), "claudeAiOauth")
            .filter(|oauth| oauth.get("refreshToken").is_some_and(Value::is_string))
            .cloned()
            .ok_or(ClaudeAccountError::NoCredentials)?;

        let mut oauth_account = None;
        for name in [".claude.json", ".config.json"] {
            if oauth_account.is_some() {
                break;
            }
            let config = json_object_at(&directory.join(name)).ok().flatten();
            oauth_account = files::object(config.as_ref(), "oauthAccount").cloned();
        }
        if oauth_account.is_none() {
            oauth_account = self.status_account(environment, cancel)?;
        }
        let oauth_account = oauth_account.ok_or(ClaudeAccountError::NoIdentity)?;
        let identity = identity(Some(&oauth_account)).ok_or(ClaudeAccountError::NoIdentity)?;
        Ok(CapturedLogin {
            organization_name: files::string(Some(&oauth_account), "organizationName").map(str::to_owned),
            plan: files::string(Some(&oauth), "subscriptionType").map(str::to_owned),
            oauth,
            oauth_account,
            identity,
        })
    }

    /// `claude auth status --json` as an `oauthAccount`, for a login whose
    /// config file did not record one.
    fn status_account(
        &self,
        environment: &BTreeMap<String, String>,
        cancel: &CancelToken,
    ) -> AccountResult<Option<JsonObject>> {
        let options = RunOptions { cancel: Some(cancel.clone()), ..RunOptions::default() };
        let result = self.runner.run_cli(
            &["claude", "auth", "status", "--json"],
            environment,
            Duration::from_secs(60),
            options,
        )?;
        if !result.succeeded() {
            return Ok(None);
        }
        let Some(start) = result.stdout.find('{') else { return Ok(None) };
        let Some(status) = json_object(&result.stdout[start..]) else { return Ok(None) };
        let Some(email) = files::string(Some(&status), "email") else { return Ok(None) };
        let mut account = JsonObject::new();
        account.insert("emailAddress".into(), Value::from(email));
        if let Some(org_id) = files::string(Some(&status), "orgId") {
            account.insert("organizationUuid".into(), Value::from(org_id));
        }
        if let Some(org_name) = files::string(Some(&status), "orgName") {
            account.insert("organizationName".into(), Value::from(org_name));
        }
        Ok(Some(account))
    }

    fn system_default_row(&self, live: &LiveLogin) -> AccountRow {
        let state = self.state();
        let record = if state.active_account_id.is_none() {
            record(live.oauth_account.as_ref(), live.oauth())
        } else {
            state.system_default
        };
        match record {
            Some(record) => row(&record),
            None => AccountRow {
                id: SYSTEM_DEFAULT_ROW_ID.into(),
                problem: Some("Not signed in".into()),
                ..AccountRow::default()
            },
        }
    }
}

// MARK: - Helpers

/// `blob` with its Claude login swapped. Every other key — MCP OAuth tokens,
/// plugin secrets — belongs to this machine, not to the account.
pub(crate) fn replacing_oauth(blob: &JsonObject, oauth: Option<&JsonObject>) -> JsonObject {
    let mut updated = blob.clone();
    match oauth {
        Some(oauth) => {
            updated.insert("claudeAiOauth".into(), Value::Object(oauth.clone()));
        }
        None => {
            updated.remove("claudeAiOauth");
        }
    }
    updated
}

pub(crate) fn identity(oauth_account: Option<&JsonObject>) -> Option<AccountIdentity> {
    let email = files::string(oauth_account, "emailAddress").filter(|email| !email.is_empty())?;
    Some(AccountIdentity::new(email, files::string(oauth_account, "organizationUuid").map(str::to_owned)))
}

pub(crate) fn same_tokens(left: Option<&JsonObject>, right: Option<&JsonObject>) -> bool {
    match (left, right) {
        (Some(left), Some(right)) => {
            files::string(Some(left), "refreshToken") == files::string(Some(right), "refreshToken")
                && files::string(Some(left), "accessToken") == files::string(Some(right), "accessToken")
        }
        (None, None) => true,
        _ => false,
    }
}

/// The access token, unless `expiresAt` (epoch milliseconds) has passed.
pub(crate) fn valid_access_token(oauth: Option<&JsonObject>, now: &Timestamp) -> Option<String> {
    let token = files::string(oauth, "accessToken").filter(|token| !token.is_empty())?;
    if let Some(expires_at) = oauth.and_then(|oauth| oauth.get("expiresAt")).and_then(number)
        && timestamp_from_seconds(expires_at / 1000.0).is_some_and(|expiry| expiry <= *now)
    {
        return None;
    }
    Some(token.to_owned())
}

fn record(oauth_account: Option<&JsonObject>, oauth: Option<&JsonObject>) -> Option<ManagedAccountRecord> {
    let identity = identity(oauth_account)?;
    let now = Utc::now();
    Some(ManagedAccountRecord {
        id: SYSTEM_DEFAULT_ROW_ID.into(),
        identity,
        organization_name: files::string(oauth_account, "organizationName").map(str::to_owned),
        plan: files::string(oauth, "subscriptionType").map(str::to_owned),
        created_at: now,
        last_authenticated_at: now,
    })
}

fn row(record: &ManagedAccountRecord) -> AccountRow {
    AccountRow {
        id: record.id.clone(),
        identity: record.identity.clone(),
        organization_name: record.organization_name.clone(),
        plan: record.plan.clone(),
        added_at: (record.id != SYSTEM_DEFAULT_ROW_ID).then_some(record.created_at),
        usage: None,
        problem: None,
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use soprano_platform::StateStore;

    use super::*;
    use crate::secrets::MemorySecretStore;

    /// Switching Claude Code logins against in-memory stand-ins for the
    /// Keychain and the OS secret store, so no test touches either.
    struct Fixture {
        manager: ClaudeCodeAccountManager,
        store: AccountStateStore,
        keychain: Arc<MemorySecretStore>,
        managed: Arc<MemorySecretStore>,
        paths: AccountPaths,
        _root: tempfile::TempDir,
    }

    fn make_fixture_with(
        profiles: HashMap<String, AccountIdentity>,
        runner: CommandRunner,
        uses_keychain: bool,
    ) -> Fixture {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        fs::create_dir_all(home.join(".claude")).unwrap();
        let keychain = Arc::new(MemorySecretStore::default());
        let managed = Arc::new(MemorySecretStore::default());
        let paths = AccountPaths::new(home, root.path().join("support"));
        let store = AccountStateStore::new(StateStore::in_memory());
        let manager = ClaudeCodeAccountManager::new(
            store.clone(),
            uses_keychain.then(|| keychain.clone() as Arc<dyn SecretStore>),
            managed.clone(),
            runner,
            paths.clone(),
            Arc::new(move |token: &str| profiles.get(token).cloned()),
        );
        Fixture { manager, store, keychain, managed, paths, _root: root }
    }

    fn make_fixture() -> Fixture {
        make_fixture_with(HashMap::new(), CommandRunner::default(), true)
    }

    fn user() -> String {
        keychain_user()
    }

    fn live_blob(fixture: &Fixture) -> JsonObject {
        if fixture.manager.live_keychain.is_some() {
            json_object(&fixture.keychain.read(LIVE_SERVICE, &user()).unwrap().unwrap()).unwrap()
        } else {
            json_object_at(&fixture.paths.claude_credentials_file()).unwrap().unwrap()
        }
    }

    fn live_email(fixture: &Fixture) -> Option<String> {
        let config = json_object_at(&fixture.paths.claude_global_config_file()).unwrap();
        let account = files::object(config.as_ref(), "oauthAccount");
        files::string(account, "emailAddress").map(str::to_owned)
    }

    fn access_token(blob: Option<&JsonObject>) -> Option<String> {
        files::string(files::object(blob, "claudeAiOauth"), "accessToken").map(str::to_owned)
    }

    fn mcp_token(blob: &JsonObject) -> Option<String> {
        files::string(files::object(Some(blob), "mcpOAuth"), "server").map(str::to_owned)
    }

    fn stored(fixture: &Fixture, account: &str) -> Option<JsonObject> {
        fixture.managed.read(MANAGED_SERVICE, account).unwrap().as_deref().and_then(json_object)
    }

    fn write_live_secret(fixture: &Fixture, secret: &str) {
        if fixture.manager.live_keychain.is_some() {
            fixture.keychain.write(LIVE_SERVICE, &user(), secret).unwrap();
        } else {
            fs::write(fixture.paths.claude_credentials_file(), secret).unwrap();
        }
    }

    fn managed_record(id: &str, email: &str, org: &str) -> ManagedAccountRecord {
        ManagedAccountRecord {
            id: id.into(),
            identity: AccountIdentity::new(email, Some(org.into())),
            organization_name: None,
            plan: None,
            created_at: Utc::now(),
            last_authenticated_at: Utc::now(),
        }
    }

    /// Claude Code signed in as me@own.dev, with an MCP token beside the login,
    /// and one managed account x@team.dev that Soprano already stores.
    fn seed(fixture: &Fixture) {
        write_live_secret(
            fixture,
            r#"{"claudeAiOauth":{"accessToken":"own-a","refreshToken":"own-r"},"mcpOAuth":{"server":"mcp-token"}}"#,
        );
        fs::write(
            fixture.paths.claude_global_config_file(),
            r#"{"oauthAccount":{"emailAddress":"me@own.dev","organizationUuid":"org-own"},"projects":{"/p":{}}}"#,
        )
        .unwrap();
        fixture
            .managed
            .write(
                MANAGED_SERVICE,
                "x",
                r#"{"claudeAiOauth":{"accessToken":"x-a","refreshToken":"x-r"},"oauthAccount":{"emailAddress":"x@team.dev","organizationUuid":"org-x"}}"#,
            )
            .unwrap();
        fixture
            .store
            .update(|state| state.claude_code.accounts = vec![managed_record("x", "x@team.dev", "org-x")]);
    }

    #[test]
    fn choosing_an_account_signs_claude_code_in_with_it_and_keeps_everything_else_in_its_stores() {
        let fixture = make_fixture();
        seed(&fixture);
        let plaintext = fixture.paths.claude_credentials_file();
        fs::write(&plaintext, r#"{"claudeAiOauth":{"accessToken":"own-a"}}"#).unwrap();

        fixture.manager.select(Some("x")).unwrap();

        let live = live_blob(&fixture);
        assert_eq!(access_token(Some(&live)).as_deref(), Some("x-a"));
        assert_eq!(mcp_token(&live).as_deref(), Some("mcp-token"));
        assert_eq!(access_token(json_object_at(&plaintext).unwrap().as_ref()).as_deref(), Some("x-a"));
        assert_eq!(live_email(&fixture).as_deref(), Some("x@team.dev"));
        let config = json_object_at(&fixture.paths.claude_global_config_file()).unwrap().unwrap();
        assert!(config.contains_key("projects"));
        let state = fixture.store.state().claude_code;
        assert_eq!(state.active_account_id.as_deref(), Some("x"));
        assert_eq!(state.system_default.map(|record| record.identity.email).as_deref(), Some("me@own.dev"));
    }

    #[test]
    fn choosing_system_default_puts_claude_codes_own_login_back() {
        let fixture = make_fixture();
        seed(&fixture);

        fixture.manager.select(Some("x")).unwrap();
        fixture.manager.select(None).unwrap();

        let live = live_blob(&fixture);
        assert_eq!(access_token(Some(&live)).as_deref(), Some("own-a"));
        assert_eq!(mcp_token(&live).as_deref(), Some("mcp-token"));
        assert_eq!(live_email(&fixture).as_deref(), Some("me@own.dev"));
        assert_eq!(fixture.store.state().claude_code.active_account_id, None);
    }

    #[test]
    fn tokens_claude_code_refreshed_under_an_account_stay_with_that_account() {
        let fixture = make_fixture();
        seed(&fixture);
        fixture.manager.select(Some("x")).unwrap();

        // Claude Code refreshes: the stored refresh token "x-r" is now spent.
        let mut live = live_blob(&fixture);
        live.insert(
            "claudeAiOauth".into(),
            serde_json::json!({"accessToken": "x-a2", "refreshToken": "x-r2"}),
        );
        write_live_secret(&fixture, &json_string(&live));
        fixture.manager.select(None).unwrap();
        fixture.manager.select(Some("x")).unwrap();

        assert_eq!(access_token(Some(&live_blob(&fixture))).as_deref(), Some("x-a2"));
    }

    #[test]
    fn a_sign_in_made_outside_soprano_becomes_the_system_default() {
        let profiles =
            HashMap::from([("z-a".to_owned(), AccountIdentity::new("z@else.dev", Some("org-z".into())))]);
        let fixture = make_fixture_with(profiles, CommandRunner::default(), true);
        seed(&fixture);
        fixture.manager.select(Some("x")).unwrap();

        // `claude auth login` with another account, in a terminal.
        write_live_secret(&fixture, r#"{"claudeAiOauth":{"accessToken":"z-a","refreshToken":"z-r"}}"#);
        fs::write(
            fixture.paths.claude_global_config_file(),
            r#"{"oauthAccount":{"emailAddress":"z@else.dev","organizationUuid":"org-z"}}"#,
        )
        .unwrap();

        let list = fixture.manager.list();

        assert_eq!(list.selected_account_id, None);
        assert_eq!(list.system_default.map(|row| row.identity.email).as_deref(), Some("z@else.dev"));
        // The managed account keeps its own tokens, not the stranger's.
        assert_eq!(access_token(stored(&fixture, "x").as_ref()).as_deref(), Some("x-a"));
    }

    #[test]
    fn removing_the_active_account_puts_the_system_default_back_and_forgets_the_login() {
        let fixture = make_fixture();
        seed(&fixture);
        fixture.manager.select(Some("x")).unwrap();

        fixture.manager.remove("x").unwrap();

        assert_eq!(access_token(Some(&live_blob(&fixture))).as_deref(), Some("own-a"));
        assert!(fixture.store.state().claude_code.accounts.is_empty());
        assert_eq!(stored(&fixture, "x"), None);
    }

    #[cfg(unix)]
    #[test]
    fn a_switch_that_fails_halfway_puts_the_live_login_back_so_no_account_gets_anothers_tokens() {
        use std::os::unix::fs::PermissionsExt;
        let fixture = make_fixture();
        let home = fixture.paths.home.clone();
        seed(&fixture);
        fixture
            .managed
            .write(
                MANAGED_SERVICE,
                "y",
                r#"{"claudeAiOauth":{"accessToken":"y-a","refreshToken":"y-r"},"oauthAccount":{"emailAddress":"y@team.dev","organizationUuid":"org-y"}}"#,
            )
            .unwrap();
        fixture
            .store
            .update(|state| state.claude_code.accounts.push(managed_record("y", "y@team.dev", "org-y")));
        fixture.manager.select(Some("x")).unwrap();

        // ~/.claude.json cannot be replaced, so the switch to y fails after
        // the credential store already took y's tokens.
        fs::set_permissions(&home, fs::Permissions::from_mode(0o500)).unwrap();
        let result = fixture.manager.select(Some("y"));
        fs::set_permissions(&home, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(result.is_err());

        let live = live_blob(&fixture);
        assert_eq!(access_token(Some(&live)).as_deref(), Some("x-a"));
        assert_eq!(mcp_token(&live).as_deref(), Some("mcp-token"));
        let list = fixture.manager.list();
        assert_eq!(list.selected_account_id.as_deref(), Some("x"));
        assert_eq!(access_token(stored(&fixture, "x").as_ref()).as_deref(), Some("x-a"));
    }

    #[test]
    fn without_a_keychain_claude_codes_credentials_file_is_the_login_that_switches() {
        let fixture = make_fixture_with(HashMap::new(), CommandRunner::default(), false);
        seed(&fixture);

        fixture.manager.select(Some("x")).unwrap();
        let live = live_blob(&fixture);
        assert_eq!(access_token(Some(&live)).as_deref(), Some("x-a"));
        assert_eq!(mcp_token(&live).as_deref(), Some("mcp-token"));
        assert_eq!(live_email(&fixture).as_deref(), Some("x@team.dev"));

        fixture.manager.select(None).unwrap();
        assert_eq!(access_token(Some(&live_blob(&fixture))).as_deref(), Some("own-a"));
        assert_eq!(live_email(&fixture).as_deref(), Some("me@own.dev"));
        assert!(fixture.keychain.items.lock().unwrap().is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn cancelling_a_sign_in_still_deletes_the_login_claude_code_stored_for_it() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let root = tempfile::tempdir().unwrap();
        let bin = root.path().join("bin");
        fs::create_dir_all(&bin).unwrap();
        let marker = root.path().join("config-dir");
        // A `claude auth login` that files a new login in its config directory,
        // prints its sign-in URL and then waits for the browser, as the real
        // one does.
        let scripts = [
            (
                "shell",
                format!("#!/bin/bash\nexport PATH=\"{}:$PATH\"\nexec /bin/bash -c \"$2\"\n", bin.display()),
            ),
            (
                "bin/claude",
                format!(
                    "#!/bin/bash\nprintf '%s' \"$CLAUDE_CONFIG_DIR\" > '{}'\n\
                     printf '%s' '{{\"claudeAiOauth\":{{\"accessToken\":\"n-a\",\"refreshToken\":\"n-r\"}}}}' > \"$CLAUDE_CONFIG_DIR/.credentials.json\"\n\
                     echo \"Open https://claude.ai/oauth/authorize?code=true\"\nexec sleep 30\n",
                    marker.display()
                ),
            ),
        ];
        for (name, text) in scripts {
            let path = root.path().join(name);
            fs::write(&path, text).unwrap();
            crate::command::tests::make_executable(&path);
        }
        let fixture = make_fixture_with(
            HashMap::new(),
            CommandRunner::with_shell(root.path().join("shell").to_string_lossy()),
            true,
        );
        let opened = Arc::new(AtomicUsize::new(0));
        let cancel = CancelToken::default();

        let result = std::thread::scope(|scope| {
            let counter = Arc::clone(&opened);
            let sign_in = scope.spawn(|| {
                fixture.manager.add_account(
                    Arc::new(move |_: &str| {
                        counter.fetch_add(1, Ordering::SeqCst);
                    }),
                    &cancel,
                )
            });
            let deadline = std::time::Instant::now() + Duration::from_secs(15);
            while opened.load(Ordering::SeqCst) == 0 && std::time::Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(20));
            }
            assert_eq!(opened.load(Ordering::SeqCst), 1);
            let config_directory = fs::read_to_string(&marker).unwrap();
            assert!(Path::new(&config_directory).join(".credentials.json").exists());
            // Where a Mac's Claude Code files the login: the scoped Keychain item.
            fixture.keychain.write(&scoped_service(&config_directory), &user(), "{}").unwrap();

            cancel.cancel();
            let result = sign_in.join().unwrap();
            assert!(!Path::new(&config_directory).exists());
            result
        });

        assert!(result.is_err_and(|error| error.is_cancelled()));
        assert!(fixture.keychain.items.lock().unwrap().is_empty());
        assert!(fixture.store.state().claude_code.accounts.is_empty());
    }

    #[test]
    fn claude_codes_scoped_keychain_name_hashes_the_config_directory_like_claude_code_does() {
        // Claude Code 2.1: "Claude Code-credentials-" + sha256(NFC(dir)).hex[0..<8].
        assert_eq!(scoped_service("/Users/test/.claude"), "Claude Code-credentials-462977e4");
    }

    #[test]
    fn an_access_token_past_its_expiry_is_not_offered_for_usage() {
        let now = timestamp_from_seconds(1_000.0).unwrap();
        let oauth = json_object(r#"{"accessToken":"a","expiresAt":999000}"#).unwrap();
        assert_eq!(valid_access_token(Some(&oauth), &now), None);
        let fresh = json_object(r#"{"accessToken":"a","expiresAt":1001000}"#).unwrap();
        assert_eq!(valid_access_token(Some(&fresh), &now).as_deref(), Some("a"));
    }
}
