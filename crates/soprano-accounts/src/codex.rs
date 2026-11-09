//! Codex CLI logins. Each managed account is its own `CODEX_HOME` holding
//! just that account's `auth.json`; everything else in it links back to
//! `~/.codex`, so config, skills, prompts and every session stay shared and a
//! thread started under one account resumes under another. New codex panes
//! get the chosen account's `CODEX_HOME`; running panes keep theirs.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use chrono::Utc;
use serde_json::Value;

use crate::error::{AccountResult, CodexAccountError};
use crate::files::{self, jwt_claims};
use crate::models::{
    AccountIdentity, AccountList, AccountListId, AccountRow, Timestamp, timestamp_from_seconds,
};
use crate::state::{AccountPaths, AccountStateStore, ManagedAccountRecord, ManagedAccountsState};
use crate::usage_api::{UsageCredential, number};
use soprano_launch::command_runner::{CancelToken, CommandRunner, LineHandler, RunOptions, first_url};

/// What a Codex `auth.json` says about its login.
#[derive(Debug, Clone, PartialEq)]
pub struct CodexAuth {
    pub identity: AccountIdentity,
    pub plan: Option<String>,
    pub access_token: Option<String>,
    pub access_token_expiry: Option<Timestamp>,
}

impl CodexAuth {
    pub fn read(home: &Path) -> Option<CodexAuth> {
        Self::parse(&fs::read(home.join("auth.json")).ok()?)
    }

    /// `{"tokens": {"id_token": <JWT>, "access_token": <JWT>, "account_id": …}}`;
    /// the id token's claims carry the email and the ChatGPT account and plan.
    pub fn parse(data: &[u8]) -> Option<CodexAuth> {
        let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(data) else { return None };
        let tokens = object.get("tokens")?.as_object()?;
        let claims = jwt_claims(tokens.get("id_token")?.as_str()?)?;
        let auth = files::object(Some(&claims), "https://api.openai.com/auth");
        let profile = files::object(Some(&claims), "https://api.openai.com/profile");
        let email = files::string(Some(&claims), "email").or_else(|| files::string(profile, "email"))?;
        if email.is_empty() {
            return None;
        }
        let account_id =
            files::string(Some(tokens), "account_id").or_else(|| files::string(auth, "chatgpt_account_id"));
        let access_token = files::string(Some(tokens), "access_token").map(str::to_owned);
        let expiry = access_token
            .as_deref()
            .and_then(jwt_claims)
            .and_then(|claims| claims.get("exp").and_then(number))
            .and_then(timestamp_from_seconds);
        Some(CodexAuth {
            identity: AccountIdentity::new(email, account_id.map(str::to_owned)),
            plan: files::string(auth, "chatgpt_plan_type").map(str::to_owned),
            access_token,
            access_token_expiry: expiry,
        })
    }
}

pub(crate) struct CodexAccountManager {
    store: AccountStateStore,
    runner: CommandRunner,
    paths: AccountPaths,
}

pub(crate) const MARKER_FILE: &str = ".soprano-managed-home";
pub(crate) const SYSTEM_DEFAULT_ROW_ID: &str = "system-default";

impl CodexAccountManager {
    pub fn new(store: AccountStateStore, runner: CommandRunner, paths: AccountPaths) -> Self {
        Self { store, runner, paths }
    }

    fn state(&self) -> ManagedAccountsState {
        self.store.state().codex_cli
    }

    fn update(&self, change: impl FnOnce(&mut ManagedAccountsState)) {
        self.store.update(|state| change(&mut state.codex_cli));
    }

    pub fn home(&self, account_id: &str) -> PathBuf {
        self.paths.codex_accounts_directory().join(account_id).join("home")
    }

    /// The `CODEX_HOME` new codex panes should use; nil for the System default.
    pub fn active_home(&self) -> Option<PathBuf> {
        self.state().active_account().map(|record| self.home(&record.id))
    }

    // MARK: - Listing

    pub fn list(&self) -> AccountList {
        let mut list = AccountList::new(AccountListId::CODEX_CLI);
        list.system_default = Some(match CodexAuth::read(&self.paths.codex_default_home()) {
            Some(auth) => AccountRow {
                id: SYSTEM_DEFAULT_ROW_ID.into(),
                identity: auth.identity,
                plan: auth.plan,
                ..AccountRow::default()
            },
            None => AccountRow {
                id: SYSTEM_DEFAULT_ROW_ID.into(),
                problem: Some("Not signed in".into()),
                ..AccountRow::default()
            },
        });
        let state = self.state();
        list.accounts = state
            .accounts
            .iter()
            .map(|record| {
                let auth = CodexAuth::read(&self.home(&record.id));
                AccountRow {
                    id: record.id.clone(),
                    identity: record.identity.clone(),
                    organization_name: record.organization_name.clone(),
                    plan: auth.as_ref().and_then(|auth| auth.plan.clone()).or_else(|| record.plan.clone()),
                    added_at: Some(record.created_at),
                    usage: None,
                    problem: auth.is_none().then(|| "Signed out; re-authenticate".to_owned()),
                }
            })
            .collect();
        list.selected_account_id = state.active_account_id;
        list
    }

    pub fn usage_credentials(&self) -> Vec<UsageCredential> {
        let mut homes = vec![(SYSTEM_DEFAULT_ROW_ID.to_owned(), self.paths.codex_default_home())];
        homes.extend(self.state().accounts.iter().map(|record| (record.id.clone(), self.home(&record.id))));
        let now = Utc::now();
        homes
            .into_iter()
            .filter_map(|(row_id, home)| {
                let auth = CodexAuth::read(&home)?;
                let token = auth.access_token?;
                if auth.access_token_expiry.is_some_and(|expiry| expiry <= now) {
                    return None;
                }
                Some(UsageCredential {
                    row_id,
                    account_id: auth.identity.organization_id.clone(),
                    identity: auth.identity,
                    access_token: token,
                })
            })
            .collect()
    }

    // MARK: - Actions

    pub fn add_account(
        &self,
        on_sign_in_url: LineHandler,
        cancel: &CancelToken,
    ) -> AccountResult<ManagedAccountRecord> {
        let id = uuid::Uuid::new_v4().to_string().to_uppercase();
        let home = self.home(&id);
        self.create_home(&home, &id)?;
        let result = (|| {
            let auth = self.sign_in(&home, on_sign_in_url, cancel)?;
            if self.state().accounts.iter().any(|record| record.identity.matches(&auth.identity)) {
                return Err(CodexAccountError::Duplicate(auth.identity.email).into());
            }
            let now = Utc::now();
            let record = ManagedAccountRecord {
                id: id.clone(),
                identity: auth.identity,
                organization_name: None,
                plan: auth.plan,
                created_at: now,
                last_authenticated_at: now,
            };
            self.update(|state| {
                state.accounts.push(record.clone());
                state.active_account_id = Some(id.clone());
            });
            Ok(record)
        })();
        if result.is_err() {
            let _ = self.delete_home(&home);
        }
        result
    }

    pub fn reauthenticate(
        &self,
        account_id: &str,
        on_sign_in_url: LineHandler,
        cancel: &CancelToken,
    ) -> AccountResult<()> {
        let Some(record) = self.state().accounts.into_iter().find(|record| record.id == account_id) else {
            return Err(CodexAccountError::UnknownAccount.into());
        };
        let home = self.home(account_id);
        self.create_home(&home, account_id)?;
        let auth_file = home.join("auth.json");
        let previous = fs::read(&auth_file).ok();
        let was_signed_out = !auth_file.exists();

        // Puts back the login the home had — or none, for a signed-out account.
        let restore_previous = || {
            if let Some(previous) = &previous {
                let _ = files::write(previous, &auth_file, 0o600);
            } else if was_signed_out {
                let _ = fs::remove_file(&auth_file);
            }
        };

        let auth = match self.sign_in(&home, on_sign_in_url, cancel) {
            Ok(auth) => auth,
            Err(error) => {
                restore_previous();
                return Err(error);
            }
        };
        if !auth.identity.matches(&record.identity) {
            restore_previous();
            return Err(CodexAccountError::WrongAccount {
                expected: record.identity.email,
                signed_in: auth.identity.email,
            }
            .into());
        }
        self.update(|state| {
            if let Some(record) = state.accounts.iter_mut().find(|record| record.id == account_id) {
                record.last_authenticated_at = Utc::now();
                if auth.plan.is_some() {
                    record.plan = auth.plan.clone();
                }
            }
        });
        Ok(())
    }

    pub fn select(&self, account_id: Option<&str>) -> AccountResult<()> {
        if let Some(account_id) = account_id
            && !self.state().accounts.iter().any(|record| record.id == account_id)
        {
            return Err(CodexAccountError::UnknownAccount.into());
        }
        self.update(|state| state.active_account_id = account_id.map(str::to_owned));
        Ok(())
    }

    pub fn remove(&self, account_id: &str) -> AccountResult<()> {
        self.delete_home(&self.home(account_id))?;
        self.update(|state| {
            state.accounts.retain(|record| record.id != account_id);
            if state.active_account_id.as_deref() == Some(account_id) {
                state.active_account_id = None;
            }
        });
        Ok(())
    }

    // MARK: - Homes

    fn create_home(&self, home: &Path, account_id: &str) -> AccountResult<()> {
        create_private_directory(home)?;
        let marker = home.join(MARKER_FILE);
        if !marker.exists() {
            fs::write(&marker, account_id.as_bytes())?;
        }
        CodexHomeLinker::sync(home, &self.paths.codex_default_home())?;
        Ok(())
    }

    /// Deletes a managed home's account directory. The marker check keeps a
    /// bad id from ever pointing this at a directory Soprano did not create.
    fn delete_home(&self, home: &Path) -> AccountResult<()> {
        if !home.exists() {
            return Ok(());
        }
        if !home.join(MARKER_FILE).exists() {
            return Err(CodexAccountError::NotManaged(home.display().to_string()).into());
        }
        // Links are removed as links; their ~/.codex targets are untouched.
        let account_directory = home.parent().unwrap_or(home);
        fs::remove_dir_all(account_directory)?;
        Ok(())
    }

    fn sign_in(
        &self,
        home: &Path,
        on_sign_in_url: LineHandler,
        cancel: &CancelToken,
    ) -> AccountResult<CodexAuth> {
        let environment = BTreeMap::from([("CODEX_HOME".to_owned(), home.to_string_lossy().into_owned())]);
        let on_line: LineHandler = std::sync::Arc::new(move |line: &str| {
            if let Some(url) = first_url(line) {
                on_sign_in_url(&url);
            }
        });
        let options = RunOptions {
            on_output_line: Some(on_line),
            cancel: Some(cancel.clone()),
            ..RunOptions::with_timeout(Duration::from_secs(600))
        };
        let result = self.runner.run_cli(&["codex".into(), "login".into()], &environment, options)?;
        if !result.succeeded() {
            return Err(CodexAccountError::LoginFailed(result.failure_message_running("codex")).into());
        }
        CodexAuth::read(home).ok_or_else(|| CodexAccountError::NoCredentials.into())
    }
}

/// Creates `path` (and missing parents) readable by the user only.
pub(crate) fn create_private_directory(path: &Path) -> std::io::Result<()> {
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(path)
}

/// Keeps a managed `CODEX_HOME` linked to `~/.codex`.
pub struct CodexHomeLinker;

impl CodexHomeLinker {
    /// Entries that belong to one login and are never shared: the login
    /// itself, and the model list cached for that login's plan.
    pub const ACCOUNT_ENTRIES: [&'static str; 4] =
        ["auth.json", "models_cache.json", MARKER_FILE, ".DS_Store"];

    pub fn should_share(name: &str) -> bool {
        if Self::ACCOUNT_ENTRIES.contains(&name) {
            return false;
        }
        // SQLite finds its journals next to the real database through the
        // link, so links to them would only dangle; Codex's own temporary
        // files start with "..".
        if name.ends_with("-wal") || name.ends_with("-shm") || name.ends_with("-journal") {
            return false;
        }
        !name.starts_with("..")
    }

    /// Links every shareable entry of `source` into `home`.
    ///
    /// Codex saves some files by writing a new copy and renaming it over the
    /// old one, which replaces a link with a plain file. Such a file is folded
    /// back: the newer of the two copies wins, lands in `source`, and the link
    /// is restored, so a setting changed under one account reaches all.
    pub fn sync(home: &Path, source: &Path) -> std::io::Result<()> {
        let Ok(entries) = fs::read_dir(source) else { return Ok(()) };
        for entry in entries.flatten() {
            let name = entry.file_name();
            if !Self::should_share(&name.to_string_lossy()) {
                continue;
            }
            let target = source.join(&name);
            let link = home.join(&name);
            match fs::symlink_metadata(&link) {
                Err(_) => links::create(&target, &link)?,
                Ok(metadata) if metadata.file_type().is_symlink() => {
                    if !links::points_to(&link, &target) {
                        links::remove(&link)?;
                        links::create(&target, &link)?;
                    }
                }
                Ok(metadata) if metadata.is_file() => {
                    let shared_copy = files::resolving_symlinks(&target);
                    if modification_date(&link) > modification_date(&shared_copy) {
                        files::write(&fs::read(&link)?, &target, file_mode(&metadata))
                            .map_err(|error| std::io::Error::other(error.to_string()))?;
                    }
                    fs::remove_file(&link)?;
                    links::create(&target, &link)?;
                }
                // A real directory Codex created here: its data, left alone.
                Ok(_) => {}
            }
        }
        // Links whose target has since been deleted.
        if let Ok(entries) = fs::read_dir(home) {
            for entry in entries.flatten() {
                let path = entry.path();
                let is_link =
                    fs::symlink_metadata(&path).is_ok_and(|metadata| metadata.file_type().is_symlink());
                if is_link && !path.exists() {
                    let _ = links::remove(&path);
                }
            }
        }
        Ok(())
    }
}

fn modification_date(path: &Path) -> SystemTime {
    fs::metadata(path).and_then(|metadata| metadata.modified()).unwrap_or(SystemTime::UNIX_EPOCH)
}

fn file_mode(metadata: &fs::Metadata) -> u32 {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o7777
    }
    #[cfg(not(unix))]
    {
        let _ = metadata;
        0o600
    }
}

/// Links into `~/.codex`. Unix: symlinks. Windows: symlinks need a privilege
/// (or Developer Mode), so folders become junctions, and files symlinks where
/// allowed, else hard links, else copies — a copy is folded back by `sync`
/// like any file Codex rewrote.
mod links {
    use std::fs;
    use std::io;
    use std::path::Path;

    #[cfg(unix)]
    pub fn create(target: &Path, link: &Path) -> io::Result<()> {
        std::os::unix::fs::symlink(target, link)
    }

    #[cfg(windows)]
    pub fn create(target: &Path, link: &Path) -> io::Result<()> {
        if target.is_dir() {
            return junction::create(target, link);
        }
        if std::os::windows::fs::symlink_file(target, link).is_ok() {
            return Ok(());
        }
        if fs::hard_link(target, link).is_ok() {
            return Ok(());
        }
        fs::copy(target, link).map(|_| ())
    }

    #[cfg(not(any(unix, windows)))]
    pub fn create(target: &Path, link: &Path) -> io::Result<()> {
        fs::copy(target, link).map(|_| ())
    }

    pub fn points_to(link: &Path, target: &Path) -> bool {
        let Ok(destination) = fs::read_link(link) else { return false };
        #[cfg(windows)]
        {
            let normalize = |path: &Path| {
                let text = path.to_string_lossy().to_lowercase();
                text.trim_start_matches(r"\\?\").trim_start_matches(r"\??\").to_owned()
            };
            normalize(&destination) == normalize(target)
        }
        #[cfg(not(windows))]
        {
            destination == target
        }
    }

    /// Removes the link itself, never what it points to. On Windows a junction or a
    /// folder symlink is removed as a directory: its metadata's `is_dir()` is false, so
    /// `FileTypeExt::is_symlink_dir` decides (review #18).
    pub fn remove(link: &Path) -> io::Result<()> {
        #[cfg(windows)]
        {
            use std::os::windows::fs::FileTypeExt;
            if fs::symlink_metadata(link)?.file_type().is_symlink_dir() {
                return fs::remove_dir(link);
            }
        }
        fs::remove_file(link)
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use base64::Engine;
    use soprano_platform::StateStore;

    use super::*;

    fn jwt(claims: Value) -> String {
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(claims.to_string());
        format!("eyJhbGciOiJub25lIn0.{payload}.signature")
    }

    struct Directories {
        source: PathBuf,
        home: PathBuf,
        _root: tempfile::TempDir,
    }

    fn make_directories() -> Directories {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("dot-codex");
        let home = root.path().join("managed/home");
        fs::create_dir_all(&source).unwrap();
        fs::create_dir_all(&home).unwrap();
        Directories { source, home, _root: root }
    }

    fn write(text: &str, path: &Path, modified: Option<SystemTime>) {
        fs::write(path, text).unwrap();
        if let Some(modified) = modified {
            fs::File::options().write(true).open(path).unwrap().set_modified(modified).unwrap();
        }
    }

    fn link_target(path: &Path) -> Option<PathBuf> {
        fs::read_link(path).ok()
    }

    fn ago(seconds: u64) -> SystemTime {
        SystemTime::now() - Duration::from_secs(seconds)
    }

    #[test]
    fn a_codex_login_is_identified_by_the_id_tokens_email_and_the_chatgpt_account() {
        let id_token = jwt(serde_json::json!({
            "email": "eric@example.com",
            "https://api.openai.com/auth": {"chatgpt_account_id": "ws-1", "chatgpt_plan_type": "prolite"},
        }));
        let access_token = jwt(serde_json::json!({"exp": 1_900_000_000}));
        let auth = format!(
            r#"{{"tokens": {{"id_token": "{id_token}", "access_token": "{access_token}", "account_id": "ws-1"}}}}"#
        );

        let parsed = CodexAuth::parse(auth.as_bytes()).unwrap();

        assert_eq!(parsed.identity, AccountIdentity::new("eric@example.com", Some("ws-1".into())));
        assert_eq!(parsed.plan.as_deref(), Some("prolite"));
        assert_eq!(parsed.access_token_expiry, timestamp_from_seconds(1_900_000_000.0));
    }

    #[test]
    fn an_api_key_login_without_tokens_is_not_a_chatgpt_account() {
        assert_eq!(CodexAuth::parse(br#"{"OPENAI_API_KEY": "sk-test", "tokens": null}"#), None);
    }

    #[test]
    fn a_managed_home_shares_everything_but_the_login_its_model_cache_and_sqlite_journals() {
        let dirs = make_directories();
        for name in [
            "config.toml",
            "auth.json",
            "models_cache.json",
            "state_5.sqlite",
            "state_5.sqlite-wal",
            "history.jsonl",
        ] {
            write(name, &dirs.source.join(name), None);
        }
        fs::create_dir_all(dirs.source.join("sessions")).unwrap();

        CodexHomeLinker::sync(&dirs.home, &dirs.source).unwrap();

        let entries: BTreeSet<String> = fs::read_dir(&dirs.home)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            entries,
            BTreeSet::from(["config.toml", "state_5.sqlite", "history.jsonl", "sessions"].map(String::from))
        );
        #[cfg(unix)]
        assert_eq!(link_target(&dirs.home.join("sessions")), Some(dirs.source.join("sessions")));
    }

    #[test]
    fn a_shared_file_codex_rewrote_in_the_managed_home_is_folded_back_when_newer() {
        let dirs = make_directories();
        let shared = dirs.source.join("config.toml");
        write("model = \"old\"", &shared, Some(ago(600)));
        // Codex saved its settings by renaming a new file over the link.
        let rewritten = dirs.home.join("config.toml");
        write("model = \"new\"", &rewritten, Some(SystemTime::now()));

        CodexHomeLinker::sync(&dirs.home, &dirs.source).unwrap();

        assert_eq!(fs::read_to_string(&shared).unwrap(), "model = \"new\"");
        #[cfg(unix)]
        assert_eq!(link_target(&rewritten), Some(shared));
    }

    #[test]
    fn an_older_rewritten_copy_loses_to_the_shared_file() {
        let dirs = make_directories();
        let shared = dirs.source.join("config.toml");
        write("model = \"edited by hand\"", &shared, Some(SystemTime::now()));
        let stale = dirs.home.join("config.toml");
        write("model = \"stale\"", &stale, Some(ago(600)));

        CodexHomeLinker::sync(&dirs.home, &dirs.source).unwrap();

        assert_eq!(fs::read_to_string(&shared).unwrap(), "model = \"edited by hand\"");
        #[cfg(unix)]
        assert_eq!(link_target(&stale), Some(shared));
    }

    #[test]
    fn links_to_deleted_entries_are_dropped_and_codexs_own_directories_kept() {
        let dirs = make_directories();
        let gone = dirs.source.join("prompts");
        fs::create_dir_all(&gone).unwrap();
        CodexHomeLinker::sync(&dirs.home, &dirs.source).unwrap();
        fs::remove_dir(&gone).unwrap();
        let own = dirs.home.join("log");
        fs::create_dir_all(&own).unwrap();
        fs::create_dir_all(dirs.source.join("log")).unwrap();

        CodexHomeLinker::sync(&dirs.home, &dirs.source).unwrap();

        assert_eq!(link_target(&dirs.home.join("prompts")), None);
        assert!(fs::symlink_metadata(dirs.home.join("prompts")).is_err());
        assert!(own.is_dir());
        assert_eq!(link_target(&own), None);
    }

    /// Re-authenticating a signed-out account through a stand-in login shell
    /// whose `codex login` signs in to a stranger.
    #[cfg(unix)]
    #[test]
    fn a_wrong_sign_in_for_a_signed_out_account_leaves_it_signed_out() {
        let root = tempfile::tempdir().unwrap();
        let root = root.path();
        let bin = root.join("bin");
        fs::create_dir_all(&bin).unwrap();
        fs::create_dir_all(root.join("home/.codex")).unwrap();
        let stranger = format!(
            r#"{{"tokens": {{"id_token": "{}", "account_id": "ws-z"}}}}"#,
            jwt(serde_json::json!({"email": "stranger@else.dev"}))
        );
        let scripts = [
            (
                "shell",
                format!("#!/bin/bash\nexport PATH=\"{}:$PATH\"\nexec /bin/bash -c \"$2\"\n", bin.display()),
            ),
            ("bin/codex", format!("#!/bin/bash\nprintf '%s' '{stranger}' > \"$CODEX_HOME/auth.json\"\n")),
        ];
        for (name, text) in scripts {
            let path = root.join(name);
            fs::write(&path, text).unwrap();
            crate::test_support::make_executable(&path);
        }
        let store = AccountStateStore::new(StateStore::in_memory());
        store.update(|state| {
            state.codex_cli.accounts = vec![ManagedAccountRecord {
                id: "c1".into(),
                identity: AccountIdentity::new("me@own.dev", Some("ws-1".into())),
                organization_name: None,
                plan: None,
                created_at: Utc::now(),
                last_authenticated_at: Utc::now(),
            }];
        });
        let manager = CodexAccountManager::new(
            store,
            CommandRunner::new(root.join("shell").to_string_lossy()),
            AccountPaths::new(root.join("home"), root.join("support")),
        );

        let result = manager.reauthenticate("c1", std::sync::Arc::new(|_: &str| {}), &CancelToken::default());

        assert!(matches!(result, Err(crate::AccountError::Codex(CodexAccountError::WrongAccount { .. }))));
        assert_eq!(CodexAuth::read(&manager.home("c1")), None);
        assert!(manager.list().accounts[0].problem.is_some());
    }

    #[test]
    fn removing_a_home_without_the_marker_is_refused() {
        let root = tempfile::tempdir().unwrap();
        let manager = CodexAccountManager::new(
            AccountStateStore::new(StateStore::in_memory()),
            CommandRunner::default(),
            AccountPaths::new(root.path().join("home"), root.path().join("support")),
        );
        fs::create_dir_all(manager.home("x")).unwrap();

        assert!(matches!(
            manager.remove("x"),
            Err(crate::AccountError::Codex(CodexAccountError::NotManaged(_)))
        ));
        assert!(manager.home("x").exists());
    }

    /// Review #18: a stale junction is replaced instead of failing the sync, and the
    /// folder it pointed at is left alone.
    #[cfg(windows)]
    #[test]
    fn a_junction_pointing_elsewhere_is_replaced_and_its_old_target_kept() {
        let dirs = make_directories();
        fs::create_dir_all(dirs.source.join("sessions")).unwrap();
        let elsewhere = dirs._root.path().join("elsewhere");
        fs::create_dir_all(&elsewhere).unwrap();
        let link = dirs.home.join("sessions");
        junction::create(&elsewhere, &link).unwrap();

        CodexHomeLinker::sync(&dirs.home, &dirs.source).unwrap();

        assert!(links::points_to(&link, &dirs.source.join("sessions")));
        assert!(elsewhere.is_dir());
        links::remove(&link).unwrap();
        assert!(fs::symlink_metadata(&link).is_err());
        assert!(dirs.source.join("sessions").is_dir());
    }
}
