//! omp's logins. omp keeps any number per provider in its own database and
//! balances across them; Soprano lists them with their usage, adds them with
//! `omp login`, removes them, and marks one preferred through a config overlay
//! every omp agent pane loads with `--config`.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use chrono::Utc;
use rusqlite::{Connection, OpenFlags, params};
use serde_json::Value;

use crate::codex::create_private_directory;
use crate::command::{CancelToken, CommandRunner, LineHandler, RunOptions, first_url};
use crate::error::{AccountResult, OmpAccountError};
use crate::files::{self, JsonObject};
use crate::models::{
    AccountIdentity, AccountList, AccountListId, AccountProvider, AccountRow, AccountUsage, UsageWindow,
    timestamp_from_seconds,
};
use crate::state::{AccountPaths, AccountStateStore, OmpPreference};
use crate::usage_api::number;

/// One omp login as `omp usage --json` reports it.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct OmpAccount {
    pub provider: AccountProvider,
    /// As omp stores it; omp's account policies compare it exactly.
    pub email: String,
    pub account_id: Option<String>,
    pub org_id: Option<String>,
    pub org_name: Option<String>,
    pub plan: Option<String>,
    pub usage: Option<AccountUsage>,
}

impl OmpAccount {
    /// Claude: the organization UUID. Codex: omp files the ChatGPT workspace as
    /// the org, and as the account id.
    pub fn identity(&self) -> AccountIdentity {
        AccountIdentity::new(self.email.clone(), self.org_id.clone().or_else(|| self.account_id.clone()))
    }
}

pub(crate) struct OmpAccountManager {
    store: AccountStateStore,
    runner: CommandRunner,
    paths: AccountPaths,
    agent_directory: Mutex<Option<PathBuf>>,
    /// The logins from the last successful `omp usage --json`.
    accounts: Mutex<Vec<OmpAccount>>,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl OmpAccountManager {
    pub fn new(store: AccountStateStore, runner: CommandRunner, paths: AccountPaths) -> Self {
        Self { store, runner, paths, agent_directory: Mutex::new(None), accounts: Mutex::new(Vec::new()) }
    }

    // MARK: - Listing

    /// Both providers' lists from one `omp usage --json` run (it also fetches
    /// fresh usage, which omp caches for five minutes).
    pub fn lists(&self) -> Vec<AccountList> {
        let ids = [AccountListId::OMP_CLAUDE, AccountListId::OMP_CODEX];
        let selected = |id: &AccountListId| {
            self.store.state().omp_preferred.get(id.provider.omp_provider_id()).map(row_id)
        };
        let accounts = match self.fetch_usage() {
            Ok(accounts) => accounts,
            Err(error) => {
                return ids
                    .iter()
                    .map(|id| AccountList {
                        unavailable_reason: Some(error.to_string()),
                        selected_account_id: selected(id),
                        ..AccountList::new(*id)
                    })
                    .collect();
            }
        };
        *lock(&self.accounts) = accounts.clone();
        self.prune_preferences(&accounts);
        ids.iter()
            .map(|id| AccountList {
                accounts: accounts
                    .iter()
                    .filter(|account| account.provider == id.provider)
                    .map(|account| AccountRow {
                        id: account.identity().key(),
                        identity: account.identity(),
                        organization_name: account.org_name.clone(),
                        plan: account.plan.clone(),
                        added_at: None,
                        usage: account.usage.clone(),
                        problem: None,
                    })
                    .collect(),
                selected_account_id: selected(id),
                ..AccountList::new(*id)
            })
            .collect()
    }

    fn fetch_usage(&self) -> AccountResult<Vec<OmpAccount>> {
        let result = self.runner.run_cli(
            &["omp", "usage", "--json"],
            &BTreeMap::new(),
            Duration::from_secs(90),
            RunOptions::default(),
        )?;
        if !result.succeeded() {
            return Err(OmpAccountError::Unavailable(result.failure_message_running("omp")).into());
        }
        Ok(parse_usage(result.stdout.as_bytes())?)
    }

    /// Drops a preference whose account omp no longer has: omp rejects a
    /// policy that matches no stored login, which would fail every request.
    fn prune_preferences(&self, accounts: &[OmpAccount]) {
        let stale: Vec<String> = self
            .store
            .state()
            .omp_preferred
            .iter()
            .filter(|(provider_id, preference)| {
                !accounts.iter().any(|account| {
                    account.provider.omp_provider_id() == provider_id.as_str() && matches(account, preference)
                })
            })
            .map(|(provider_id, _)| provider_id.clone())
            .collect();
        if stale.is_empty() {
            return;
        }
        self.store.update(|state| {
            for provider_id in &stale {
                state.omp_preferred.remove(provider_id);
            }
        });
        let _ = self.write_overlay();
    }

    // MARK: - Actions

    /// `omp login <provider>`. The browser's signed-in account decides which
    /// login omp stores: the same account is refreshed in place, another one
    /// is added beside it.
    pub fn sign_in(
        &self,
        provider: AccountProvider,
        on_sign_in_url: LineHandler,
        cancel: &CancelToken,
    ) -> AccountResult<()> {
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
            &["omp", "login", provider.omp_provider_id()],
            &BTreeMap::new(),
            Duration::from_secs(600),
            options,
        )?;
        if !result.succeeded() {
            return Err(OmpAccountError::LoginFailed(result.failure_message_running("omp")).into());
        }
        Ok(())
    }

    /// Marks the login `row_id` preferred (nil: automatic balancing) for new
    /// omp panes; running omp panes reload the overlay and apply it to their
    /// next new session.
    pub fn select(&self, row_id: Option<&str>, provider: AccountProvider) -> AccountResult<()> {
        let Some(row_id) = row_id else {
            self.store.update(|state| {
                state.omp_preferred.remove(provider.omp_provider_id());
            });
            return self.write_overlay();
        };
        let Some(account) = self.account(row_id, provider) else {
            return Err(OmpAccountError::NotStored(row_id.to_owned()).into());
        };
        self.store.update(|state| {
            state.omp_preferred.insert(provider.omp_provider_id().to_owned(), preference(&account));
        });
        self.write_overlay()
    }

    /// Signs omp out of one account, the way omp's own `/logout` does: the
    /// login is marked deleted in omp's database, and running omp processes
    /// notice on their next request.
    pub fn remove(&self, row_id: &str, provider: AccountProvider) -> AccountResult<()> {
        let Some(account) = self.account(row_id, provider) else {
            return Err(OmpAccountError::NotStored(row_id.to_owned()).into());
        };
        let preferred = self.store.state().omp_preferred.get(provider.omp_provider_id()).cloned();
        if preferred.is_some_and(|preference| self::row_id(&preference) == row_id) {
            self.select(None, provider)?;
            // omp refuses to drop a login that a loaded policy still names;
            // give running panes a moment to reload the overlay first.
            std::thread::sleep(Duration::from_millis(1500));
        }
        let database = self.agent_directory()?.join("agent.db");
        let removed = soft_delete_login(&database, provider.omp_provider_id(), &account.identity())?;
        if !removed {
            return Err(OmpAccountError::NotStored(account.email).into());
        }
        Ok(())
    }

    fn account(&self, row_id: &str, provider: AccountProvider) -> Option<OmpAccount> {
        lock(&self.accounts)
            .iter()
            .find(|account| account.provider == provider && account.identity().key() == row_id)
            .cloned()
    }

    // MARK: - Overlay

    /// Writes the `--config` overlay from the stored preferences; untouched
    /// when nothing changed, so omp does not reload for nothing.
    pub fn write_overlay(&self) -> AccountResult<()> {
        let preferences: Vec<(String, OmpPreference)> =
            self.store.state().omp_preferred.into_iter().collect();
        let text = overlay(&preferences);
        let path = self.paths.omp_overlay_file();
        if std::fs::read_to_string(&path).is_ok_and(|current| current == text) {
            return Ok(());
        }
        if let Some(parent) = path.parent() {
            create_private_directory(parent)?;
        }
        files::write(text.as_bytes(), &path, 0o644)?;
        Ok(())
    }

    // MARK: - omp's database

    /// The folder `omp config path` names: the last absolute path it prints
    /// (shell start-up noise can come first).
    fn agent_directory(&self) -> AccountResult<PathBuf> {
        if let Some(directory) = lock(&self.agent_directory).clone() {
            return Ok(directory);
        }
        let result = self.runner.run_cli(
            &["omp", "config", "path"],
            &BTreeMap::new(),
            Duration::from_secs(60),
            RunOptions::default(),
        )?;
        let path = result
            .stdout
            .lines()
            .map(str::trim)
            .rfind(|line| Path::new(line).is_absolute())
            .map(PathBuf::from);
        let (true, Some(path)) = (result.succeeded(), path) else {
            return Err(OmpAccountError::Unavailable(result.failure_message_running("omp")).into());
        };
        *lock(&self.agent_directory) = Some(path.clone());
        Ok(path)
    }
}

/// omp's `auth.accountPolicies`: a positive priority puts the account ahead
/// of its siblings while it has allowance left; when it runs out, omp fails
/// over to the others as usual.
pub(crate) fn overlay(preferences: &[(String, OmpPreference)]) -> String {
    let mut lines = vec![
        "# Written by Soprano (Settings → Accounts); edits here are overwritten.".to_owned(),
        "# Soprano starts omp agent panes with --config pointing at this file.".to_owned(),
    ];
    if preferences.is_empty() {
        lines.push("{}".to_owned());
        return lines.join("\n") + "\n";
    }
    lines.push("auth:".to_owned());
    lines.push("  accountPolicies:".to_owned());
    for (provider_id, preference) in preferences {
        lines.push(format!("    - provider: {}", yaml_quoted(provider_id)));
        lines.push("      account:".to_owned());
        lines.push(format!("        email: {}", yaml_quoted(&preference.email)));
        if let Some(org_id) = &preference.org_id {
            lines.push(format!("        orgId: {}", yaml_quoted(org_id)));
        }
        lines.push("      priority: 100".to_owned());
    }
    lines.join("\n") + "\n"
}

fn yaml_quoted(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

/// Marks the matching OAuth login deleted, exactly as omp's `removeById`
/// does (`disabled_cause = 'deleted by user'`). The row's identity key is
/// `email:<lowercased email>|org:<org id>`. Returns false when no active
/// login matches.
pub(crate) fn soft_delete_login(
    database_path: &Path,
    provider_id: &str,
    identity: &AccountIdentity,
) -> Result<bool, OmpAccountError> {
    let unsupported = |error: rusqlite::Error| OmpAccountError::UnsupportedStore(error.to_string());
    let database = Connection::open_with_flags(
        database_path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|_| OmpAccountError::Unavailable(format!("could not open {}", database_path.display())))?;
    let _ = database.busy_timeout(Duration::from_secs(5));

    let required =
        BTreeSet::from(["id", "provider", "credential_type", "identity_key", "disabled_cause", "updated_at"]);
    let columns: BTreeSet<String> = {
        let mut statement = database.prepare("PRAGMA table_info(auth_credentials)").map_err(unsupported)?;
        let names = statement.query_map([], |row| row.get::<_, String>(1)).map_err(unsupported)?;
        names.filter_map(Result::ok).collect()
    };
    let missing: Vec<&str> = required.iter().copied().filter(|name| !columns.contains(*name)).collect();
    if !missing.is_empty() {
        return Err(OmpAccountError::UnsupportedStore(format!(
            "auth_credentials lacks {}",
            missing.join(", ")
        )));
    }

    let matches: Vec<i64> = {
        let mut statement = database
            .prepare(
                "SELECT id, identity_key FROM auth_credentials \
                 WHERE provider = ? AND credential_type = 'oauth' AND disabled_cause IS NULL",
            )
            .map_err(unsupported)?;
        let rows = statement
            .query_map(params![provider_id], |row| {
                Ok((row.get::<_, i64>(0)?, row.get::<_, Option<String>>(1)?))
            })
            .map_err(unsupported)?;
        rows.filter_map(Result::ok)
            .filter(|(_, key)| key.as_deref().is_some_and(|key| identity_key_matches(key, identity)))
            .map(|(id, _)| id)
            .collect()
    };
    let id = match matches.as_slice() {
        [id] => *id,
        [] => return Ok(false),
        _ => {
            return Err(OmpAccountError::UnsupportedStore(format!(
                "{} logins match {}",
                matches.len(),
                identity.email
            )));
        }
    };

    let changed = database
        .execute(
            "UPDATE auth_credentials \
             SET disabled_cause = 'deleted by user', updated_at = CAST(strftime('%s','now') AS INTEGER) \
             WHERE id = ? AND disabled_cause IS NULL",
            params![id],
        )
        .map_err(|error| OmpAccountError::Unavailable(error.to_string()))?;
    Ok(changed == 1)
}

/// omp identity keys are `|`-joined `kind:value` parts, e.g.
/// `email:a@b.c|org:1234`; emails are stored lowercased.
pub(crate) fn identity_key_matches(key: &str, identity: &AccountIdentity) -> bool {
    let parts: HashMap<&str, &str> = key.split('|').filter_map(|part| part.split_once(':')).collect();
    if parts.get("email").copied() != Some(identity.email.to_lowercase().as_str()) {
        return false;
    }
    let Some(organization_id) = identity.organization_id.as_deref() else { return true };
    parts.get("org").copied() == Some(organization_id)
        || parts.get("account").copied() == Some(organization_id)
}

// MARK: - Parsing

/// Every OAuth account in `omp usage --json`: those with a usage report and
/// those omp could not fetch usage for (`accountsWithoutUsage`).
pub(crate) fn parse_usage(data: &[u8]) -> Result<Vec<OmpAccount>, OmpAccountError> {
    // Shell start-up noise can precede the JSON document.
    let text = String::from_utf8_lossy(data);
    let object = text
        .find('{')
        .and_then(|start| match serde_json::from_str::<Value>(&text[start..]) {
            Ok(Value::Object(object)) => Some(object),
            _ => None,
        })
        .ok_or_else(|| OmpAccountError::Unavailable("`omp usage --json` printed no usage report.".into()))?;

    let mut accounts: Vec<OmpAccount> = Vec::new();
    let mut add = |account: OmpAccount| {
        let key = account.identity().key();
        if !accounts
            .iter()
            .any(|existing| existing.provider == account.provider && existing.identity().key() == key)
        {
            accounts.push(account);
        }
    };
    let string = |object: Option<&JsonObject>, key: &str| files::string(object, key).map(str::to_owned);
    for report in object.get("reports").and_then(Value::as_array).into_iter().flatten() {
        let report = report.as_object();
        let Some(provider) =
            files::string(report, "provider").and_then(AccountProvider::from_omp_provider_id)
        else {
            continue;
        };
        let metadata = files::object(report, "metadata");
        let Some(email) = files::string(metadata, "email").filter(|email| !email.is_empty()) else {
            continue;
        };
        if metadata.is_none() {
            continue;
        }
        let fetched_at = report
            .and_then(|report| report.get("fetchedAt"))
            .and_then(number)
            .and_then(|ms| timestamp_from_seconds(ms / 1000.0))
            .unwrap_or_else(Utc::now);
        let windows: Vec<UsageWindow> = report
            .and_then(|report| report.get("limits"))
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|limit| window(limit.as_object()?))
            .collect();
        add(OmpAccount {
            provider,
            email: email.to_owned(),
            account_id: string(metadata, "accountId"),
            org_id: string(metadata, "orgId"),
            org_name: string(metadata, "orgName"),
            plan: string(metadata, "planType"),
            usage: (!windows.is_empty()).then_some(AccountUsage { windows, fetched_at }),
        });
    }
    for entry in object.get("accountsWithoutUsage").and_then(Value::as_array).into_iter().flatten() {
        let entry = entry.as_object();
        let Some(provider) = files::string(entry, "provider").and_then(AccountProvider::from_omp_provider_id)
        else {
            continue;
        };
        let Some(email) = files::string(entry, "email").filter(|email| !email.is_empty()) else { continue };
        add(OmpAccount {
            provider,
            email: email.to_owned(),
            account_id: string(entry, "accountId"),
            org_id: string(entry, "orgId"),
            org_name: string(entry, "orgName"),
            plan: None,
            usage: None,
        });
    }
    Ok(accounts)
}

/// A percentage limit as a window: "5h", "7d", or "7d fable" for a
/// model-scoped one. Dollar-denominated limits (extra usage) are skipped.
fn window(limit: &JsonObject) -> Option<UsageWindow> {
    let amount = files::object(Some(limit), "amount");
    if files::string(amount, "unit").is_some_and(|unit| unit != "percent") {
        return None;
    }
    let used_fraction = amount
        .and_then(|amount| amount.get("usedFraction"))
        .and_then(number)
        .or_else(|| amount.and_then(|amount| amount.get("used")).and_then(number).map(|used| used / 100.0))?;
    let window = files::object(Some(limit), "window");
    let scope = files::object(Some(limit), "scope");
    let mut label = files::string(window, "id")
        .or_else(|| files::string(window, "label"))
        .or_else(|| files::string(Some(limit), "label"))
        .unwrap_or("limit")
        .to_owned();
    if let Some(tier) = files::string(scope, "tier").filter(|tier| !tier.is_empty()) {
        label = format!("{label} {tier}");
    }
    Some(UsageWindow {
        label,
        used_fraction,
        resets_at: window
            .and_then(|window| window.get("resetsAt"))
            .and_then(number)
            .and_then(|ms| timestamp_from_seconds(ms / 1000.0)),
    })
}

/// The policy selector omp matches exactly: its own email and org fields.
pub(crate) fn preference(account: &OmpAccount) -> OmpPreference {
    OmpPreference {
        email: account.email.clone(),
        org_id: account.org_id.clone(),
        account_id: account.account_id.clone(),
    }
}

pub(crate) fn row_id(preference: &OmpPreference) -> String {
    AccountIdentity::new(
        preference.email.clone(),
        preference.org_id.clone().or_else(|| preference.account_id.clone()),
    )
    .key()
}

fn matches(account: &OmpAccount, preference: &OmpPreference) -> bool {
    account.email == preference.email && account.org_id == preference.org_id
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The shape `omp usage --json` prints, preceded by the stderr-free noise
    /// a prompt theme can put on stdout during shell start-up.
    const OMP_USAGE: &str = r#"[gitstatus] warming up
{
  "generatedAt": 1791498135730,
  "reports": [
    {
      "provider": "anthropic",
      "fetchedAt": 1791498129907,
      "limits": [
        { "id": "anthropic:5h", "label": "Claude 5 Hour",
          "scope": { "provider": "anthropic", "windowId": "5h", "shared": true },
          "window": { "id": "5h", "label": "5 Hour", "durationMs": 18000000, "resetsAt": 1791511800000 },
          "amount": { "used": 9, "limit": 100, "usedFraction": 0.09, "unit": "percent" } },
        { "id": "anthropic:7d:fable", "label": "Claude 7 Day (Fable)",
          "scope": { "provider": "anthropic", "windowId": "7d", "tier": "fable" },
          "window": { "id": "7d", "label": "7 Day", "resetsAt": 1791993600000 },
          "amount": { "used": 0, "limit": 100, "usedFraction": 0, "unit": "percent" } },
        { "id": "anthropic:extra", "label": "Claude Extra Usage",
          "scope": { "provider": "anthropic" },
          "window": { "id": "month", "label": "Month" },
          "amount": { "used": 12.5, "limit": 50, "unit": "usd" } }
      ],
      "metadata": { "email": "Ada@Example.com", "accountId": "acct-1", "orgId": "org-1", "orgName": "Ada's Organization" }
    },
    {
      "provider": "openai-codex",
      "fetchedAt": 1791498085858,
      "limits": [
        { "id": "openai-codex:primary", "label": "7 days",
          "scope": { "provider": "openai-codex", "windowId": "7d", "shared": true },
          "window": { "id": "7d", "label": "7 days", "resetsAt": 1791959189000 },
          "amount": { "used": 15, "limit": 100, "usedFraction": 0.15, "unit": "percent" } }
      ],
      "metadata": { "planType": "prolite", "email": "eric@example.com", "accountId": "ws-9", "orgId": "ws-9" }
    },
    {
      "provider": "zai",
      "limits": [],
      "metadata": { "email": "someone@example.com" }
    }
  ],
  "accountsWithoutUsage": [
    { "provider": "anthropic", "email": "second@example.com", "orgId": "org-2", "orgName": "Second" }
  ],
  "disabledCredentials": []
}
"#;

    #[test]
    fn omp_usage_yields_every_claude_and_codex_account_with_percent_windows_only() {
        let accounts = parse_usage(OMP_USAGE.as_bytes()).unwrap();

        assert_eq!(
            accounts.iter().map(|a| a.email.as_str()).collect::<Vec<_>>(),
            ["Ada@Example.com", "eric@example.com", "second@example.com"]
        );

        let ada = &accounts[0];
        assert_eq!(ada.provider, AccountProvider::Claude);
        assert_eq!(ada.identity(), AccountIdentity::new("Ada@Example.com", Some("org-1".into())));
        let usage = ada.usage.as_ref().unwrap();
        assert_eq!(usage.windows.iter().map(|w| w.label.as_str()).collect::<Vec<_>>(), ["5h", "7d fable"]);
        assert_eq!(usage.windows[0].used_fraction, 0.09);
        assert_eq!(usage.windows[0].resets_at, timestamp_from_seconds(1_791_511_800.0));

        let eric = &accounts[1];
        assert_eq!(eric.provider, AccountProvider::Codex);
        assert_eq!(eric.plan.as_deref(), Some("prolite"));
        assert_eq!(eric.identity().organization_id.as_deref(), Some("ws-9"));

        // omp could not fetch this one's usage, but it is still a login to list.
        assert_eq!(accounts[2].usage, None);
        assert_eq!(accounts[2].org_name.as_deref(), Some("Second"));
    }

    #[test]
    fn omp_usage_without_a_json_document_is_reported_as_unavailable() {
        assert!(matches!(
            parse_usage(b"zsh: command not found: omp\n"),
            Err(OmpAccountError::Unavailable(_))
        ));
    }

    /// omp's `auth_credentials` table and its change-revision trigger, as
    /// omp 18 creates them.
    const SCHEMA: &str = "
        CREATE TABLE auth_credentials (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            provider TEXT NOT NULL,
            credential_type TEXT NOT NULL,
            data TEXT NOT NULL,
            disabled_cause TEXT DEFAULT NULL,
            identity_key TEXT DEFAULT NULL,
            created_at INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE auth_change_revision (id INTEGER PRIMARY KEY CHECK (id = 1), revision INTEGER NOT NULL);
        INSERT INTO auth_change_revision VALUES (1, 0);
        CREATE TRIGGER bump AFTER UPDATE ON auth_credentials
        BEGIN UPDATE auth_change_revision SET revision = revision + 1 WHERE id = 1; END;
        INSERT INTO auth_credentials (provider, credential_type, data, identity_key) VALUES
            ('anthropic', 'oauth', '{}', 'email:ada@example.com|org:org-personal'),
            ('anthropic', 'oauth', '{}', 'email:ada@example.com|org:org-team'),
            ('openai-codex', 'oauth', '{}', 'email:ada@example.com|org:org-personal'),
            ('anthropic', 'api_key', '{}', NULL);
    ";

    fn make_database(dir: &tempfile::TempDir, sql: &str) -> PathBuf {
        let path = dir.path().join("agent.db");
        Connection::open(&path).unwrap().execute_batch(sql).unwrap();
        path
    }

    fn causes(path: &Path) -> Vec<Option<String>> {
        let database = Connection::open(path).unwrap();
        let mut statement =
            database.prepare("SELECT disabled_cause FROM auth_credentials ORDER BY id").unwrap();
        statement.query_map([], |row| row.get(0)).unwrap().map(Result::unwrap).collect()
    }

    #[test]
    fn removing_an_omp_login_marks_only_that_organizations_row_deleted_the_way_omp_does() {
        let dir = tempfile::tempdir().unwrap();
        let path = make_database(&dir, SCHEMA);

        let removed = soft_delete_login(
            &path,
            "anthropic",
            &AccountIdentity::new("Ada@Example.com", Some("org-team".into())),
        )
        .unwrap();

        assert!(removed);
        assert_eq!(causes(&path), [None, Some("deleted by user".to_owned()), None, None]);
    }

    #[test]
    fn removing_a_login_omp_no_longer_has_reports_nothing_removed() {
        let dir = tempfile::tempdir().unwrap();
        let path = make_database(&dir, SCHEMA);
        let identity = AccountIdentity::new("ada@example.com", Some("org-personal".into()));

        assert!(soft_delete_login(&path, "anthropic", &identity).unwrap());
        // Already deleted: a second removal must not touch the tombstone again.
        assert!(!soft_delete_login(&path, "anthropic", &identity).unwrap());
        // The same person's Codex login is a different provider's row.
        assert_eq!(causes(&path)[2], None);
    }

    #[test]
    fn an_omp_database_without_identity_keys_is_refused_rather_than_guessed_at() {
        let dir = tempfile::tempdir().unwrap();
        let path = make_database(
            &dir,
            "CREATE TABLE auth_credentials (id INTEGER PRIMARY KEY, provider TEXT, credential_type TEXT, data TEXT);
             INSERT INTO auth_credentials (provider, credential_type, data) VALUES ('anthropic', 'oauth', '{}');",
        );

        let result = soft_delete_login(&path, "anthropic", &AccountIdentity::new("ada@example.com", None));

        assert_eq!(
            result,
            Err(OmpAccountError::UnsupportedStore(
                "auth_credentials lacks disabled_cause, identity_key, updated_at".into()
            ))
        );
    }

    #[test]
    fn identity_keys_match_on_lowercased_email_and_the_organization_or_account() {
        let identity = AccountIdentity::new("Ada@Example.com", Some("ws-1".into()));
        assert!(identity_key_matches("email:ada@example.com|org:ws-1", &identity));
        assert!(identity_key_matches("account:ws-1|email:ada@example.com", &identity));
        assert!(!identity_key_matches("email:ada@example.com|org:ws-2", &identity));
        assert!(!identity_key_matches("email:bob@example.com|org:ws-1", &identity));
    }

    #[test]
    fn the_overlay_without_preferences_is_an_empty_mapping_omp_accepts() {
        let text = overlay(&[]);
        assert!(text.ends_with("\n{}\n"));
        assert!(!text.contains("accountPolicies"));
    }

    #[test]
    fn the_overlay_gives_each_preferred_account_a_priority_policy_with_quoted_selectors() {
        let text = overlay(&[
            (
                "anthropic".into(),
                OmpPreference {
                    email: "ada@example.com".into(),
                    org_id: Some("org-1".into()),
                    account_id: None,
                },
            ),
            (
                "openai-codex".into(),
                OmpPreference { email: r#"odd"name@example.com"#.into(), org_id: None, account_id: None },
            ),
        ]);

        assert!(text.contains(
            "auth:
  accountPolicies:
    - provider: \"anthropic\"
      account:
        email: \"ada@example.com\"
        orgId: \"org-1\"
      priority: 100
    - provider: \"openai-codex\"
      account:
        email: \"odd\\\"name@example.com\"
      priority: 100"
        ));
    }

    /// A stand-in login shell whose `omp` prints `OMP_USAGE`.
    #[cfg(unix)]
    fn fake_omp(root: &Path) -> CommandRunner {
        let bin = root.join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::write(root.join("usage.json"), OMP_USAGE).unwrap();
        let scripts = [
            (
                "shell",
                format!("#!/bin/bash\nexport PATH=\"{}:$PATH\"\nexec /bin/bash -c \"$2\"\n", bin.display()),
            ),
            ("bin/omp", format!("#!/bin/bash\ncat '{}'\n", root.join("usage.json").display())),
        ];
        for (name, text) in scripts {
            let path = root.join(name);
            std::fs::write(&path, text).unwrap();
            crate::command::tests::make_executable(&path);
        }
        CommandRunner::with_shell(root.join("shell").to_string_lossy())
    }

    #[cfg(unix)]
    #[test]
    fn preferring_an_omp_login_writes_its_policy_and_a_vanished_one_is_dropped() {
        use soprano_platform::StateStore;
        let root = tempfile::tempdir().unwrap();
        let store = AccountStateStore::new(StateStore::in_memory());
        let paths = AccountPaths::new(root.path().join("home"), root.path().join("support"));
        let manager = OmpAccountManager::new(store.clone(), fake_omp(root.path()), paths.clone());

        let lists = manager.lists();
        let claude = &lists[0];
        assert_eq!(claude.id, AccountListId::OMP_CLAUDE);
        assert_eq!(claude.accounts.len(), 2);
        let ada = claude.accounts[0].id.clone();
        manager.select(Some(&ada), AccountProvider::Claude).unwrap();

        let overlay = std::fs::read_to_string(paths.omp_overlay_file()).unwrap();
        assert!(overlay.contains("email: \"Ada@Example.com\""));
        assert!(overlay.contains("orgId: \"org-1\""));
        assert_eq!(manager.lists()[0].selected_account_id, Some(ada));

        // A preference naming a login omp no longer reports is pruned.
        store.update(|state| {
            state.omp_preferred.insert(
                "openai-codex".into(),
                OmpPreference { email: "gone@example.com".into(), org_id: None, account_id: None },
            );
        });
        manager.lists();
        assert!(!store.state().omp_preferred.contains_key("openai-codex"));
        assert!(!std::fs::read_to_string(paths.omp_overlay_file()).unwrap().contains("gone@example.com"));
    }
}
