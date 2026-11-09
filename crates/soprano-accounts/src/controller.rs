//! The one owner of account state the UI reads: it runs the three tools'
//! managers, merges their lists with usage, runs sign-ins one at a time, and
//! publishes what new agent panes need into `AccountLaunchState`.
//!
//! UI-independent: work runs on background threads and every change is
//! published to observers as a whole `AccountsSnapshot`. The host drives the
//! background refresh by calling `refresh_due(now)` (on a timer while the app
//! is in front, and when it becomes active).

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, Weak, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use chrono::Utc;
use soprano_platform::StateStore;

use crate::claude::{ClaudeCodeAccountManager, ProfileLookup};
use crate::codex::CodexAccountManager;
use soprano_launch::command_runner::{CancelToken, CommandRunner, LineHandler};

use crate::error::AccountResult;
use crate::launch::AccountLaunchState;
use crate::models::{
    AccountList, AccountListId, AccountProvider, AccountRow, AccountTool, AccountUsage, AccountsSnapshot,
    PendingLogin, Timestamp, seconds_between,
};
use crate::omp::OmpAccountManager;
use crate::secrets::{SecretStore, platform_stores};
use crate::state::{AccountPaths, AccountStateStore};
use crate::usage_api::{self, UsageCredential};

/// Background refresh cadence while Soprano is the active app; omp caches
/// usage for five minutes, so polling faster would only re-read its cache.
pub const POLL_INTERVAL_SECONDS: f64 = 300.0;
/// A non-forced refresh within this long of the last one does nothing.
pub const MINIMUM_REFRESH_INTERVAL_SECONDS: f64 = 30.0;

/// Receives every new snapshot, on the thread that changed it (a background
/// thread for refreshes and sign-ins); a UI host forwards it to its own thread.
pub type SnapshotObserver = Arc<dyn Fn(&AccountsSnapshot) + Send + Sync>;

/// Asks a provider for one account's usage.
pub(crate) type UsageFetcher =
    Arc<dyn Fn(AccountProvider, &UsageCredential) -> Option<AccountUsage> + Send + Sync>;

/// One user action (select, remove) run on the action queue.
type Action = Box<dyn FnOnce(&Arc<Inner>) + Send>;

/// A cheap handle; clones control the same accounts.
#[derive(Clone)]
pub struct AccountsController {
    inner: Arc<Inner>,
}

struct Inner {
    shared: Mutex<Shared>,
    idle: Condvar,
    observers: Mutex<BTreeMap<String, SnapshotObserver>>,
    /// Runs actions one after another in the order they were asked for, so two
    /// quick selections never apply out of order (Swift's `AsyncSerialQueue`).
    /// Started with the first action.
    actions: Mutex<Option<mpsc::Sender<Action>>>,
    store: AccountStateStore,
    paths: AccountPaths,
    launch_state: Arc<AccountLaunchState>,
    claude: ClaudeCodeAccountManager,
    codex: CodexAccountManager,
    omp: OmpAccountManager,
    usage: UsageFetcher,
}

#[derive(Default)]
struct Shared {
    snapshot: AccountsSnapshot,
    is_started: bool,
    is_refreshing: bool,
    /// A forced refresh asked for while one ran: the running one may have
    /// read the lists before the change that asked for it.
    refresh_again: bool,
    login_cancel: Option<CancelToken>,
    /// Usage fetched straight from a provider, by "<tool>|<row id>", so a
    /// refresh does not ask again for logins omp does not cover.
    direct_usage: HashMap<String, (Timestamp, Option<AccountUsage>)>,
    /// Snapshots changed since observers were last told.
    notify_pending: bool,
    /// A thread is telling observers; others leave the newest snapshot to it.
    is_notifying: bool,
    /// Background jobs still running.
    jobs: usize,
}

/// Everything a controller is built from; tests swap in stand-ins.
pub(crate) struct ControllerParts {
    pub store: AccountStateStore,
    pub paths: AccountPaths,
    pub runner: CommandRunner,
    /// Claude Code's Keychain (macOS); nil where it keeps only its credentials file.
    pub claude_keychain: Option<Arc<dyn SecretStore>>,
    /// Soprano's own stored logins.
    pub secrets: Arc<dyn SecretStore>,
    pub launch_state: Arc<AccountLaunchState>,
    pub profile: ProfileLookup,
    pub usage: UsageFetcher,
}

impl AccountsController {
    /// The app's controller: its accounts state in `store` (key
    /// `soprano-accounts`), the user's real homes and secret stores, and
    /// `AccountLaunchState::shared()`. Create one and keep it for the app's
    /// lifetime; call `start()` once.
    pub fn new(store: StateStore) -> Self {
        let stores = platform_stores();
        Self::with_parts(ControllerParts {
            store: AccountStateStore::new(store),
            paths: AccountPaths::live(),
            runner: CommandRunner::default(),
            claude_keychain: stores.claude_keychain,
            secrets: stores.secrets,
            launch_state: AccountLaunchState::shared(),
            profile: Arc::new(|token: &str| usage_api::claude_profile(token).ok()),
            usage: Arc::new(|provider: AccountProvider, credential: &UsageCredential| match provider {
                AccountProvider::Claude => usage_api::claude_usage(&credential.access_token).ok(),
                AccountProvider::Codex => {
                    usage_api::codex_usage(&credential.access_token, credential.account_id.as_deref()).ok()
                }
            }),
        })
    }

    pub(crate) fn with_parts(parts: ControllerParts) -> Self {
        let claude = ClaudeCodeAccountManager::new(
            parts.store.clone(),
            parts.claude_keychain,
            parts.secrets,
            parts.runner.clone(),
            parts.paths.clone(),
            parts.profile,
        );
        let codex = CodexAccountManager::new(parts.store.clone(), parts.runner.clone(), parts.paths.clone());
        let omp = OmpAccountManager::new(parts.store.clone(), parts.runner, parts.paths.clone());
        Self {
            inner: Arc::new(Inner {
                shared: Mutex::new(Shared::default()),
                idle: Condvar::new(),
                observers: Mutex::new(BTreeMap::new()),
                actions: Mutex::new(None),
                store: parts.store,
                paths: parts.paths,
                launch_state: parts.launch_state,
                claude,
                codex,
                omp,
                usage: parts.usage,
            }),
        }
    }

    /// Called once at launch: makes the omp overlay exist before any omp
    /// pane starts with it, then loads every list.
    pub fn start(&self) {
        {
            let mut shared = self.inner.lock();
            if shared.is_started {
                return;
            }
            shared.is_started = true;
        }
        let _ = self.inner.omp.write_overlay();
        self.inner.publish_launch_state();
        self.refresh(true);
    }

    pub fn snapshot(&self) -> AccountsSnapshot {
        self.inner.lock().snapshot.clone()
    }

    pub fn add_observer(&self, id: &str, handler: SnapshotObserver) {
        lock(&self.inner.observers).insert(id.to_owned(), handler);
    }

    pub fn remove_observer(&self, id: &str) {
        lock(&self.inner.observers).remove(id);
    }

    // MARK: - Refresh

    /// Re-reads every list and its usage in the background. Without `force`,
    /// a refresh within 30 s of the last one is skipped, so views can call
    /// this when they appear.
    pub fn refresh(&self, force: bool) {
        Inner::refresh(&self.inner, force);
    }

    /// The periodic refresh: refreshes (forced) when the last refresh is at
    /// least 5 minutes old, or there was none. The host calls it on a timer
    /// while the app is in front — nobody reads the status bar of a
    /// background app — and when the app becomes active. Returns whether a
    /// refresh started.
    pub fn refresh_due(&self, now: Timestamp) -> bool {
        let due = {
            let shared = self.inner.lock();
            !shared.is_refreshing
                && shared
                    .snapshot
                    .last_refresh
                    .is_none_or(|last| seconds_between(&last, &now) >= POLL_INTERVAL_SECONDS)
        };
        if due {
            self.refresh(true);
        }
        due
    }

    // MARK: - Sign-in

    pub fn add_account(&self, list: AccountListId) {
        Inner::start_sign_in(&self.inner, list, None);
    }

    pub fn reauthenticate(&self, account_id: &str, list: AccountListId) {
        Inner::start_sign_in(&self.inner, list, Some(account_id.to_owned()));
    }

    pub fn cancel_login(&self) {
        if let Some(token) = &self.inner.lock().login_cancel {
            token.cancel();
        }
    }

    // MARK: - Selection and removal

    pub fn select(&self, account_id: Option<&str>, list: AccountListId) {
        // Show the choice at once; the refresh after it confirms or corrects it.
        self.inner.mutate(|snapshot| {
            if let Some(entry) = snapshot.lists.get_mut(&list) {
                entry.selected_account_id = account_id.map(str::to_owned);
            }
        });
        let account_id = account_id.map(str::to_owned);
        Inner::perform(&self.inner, list, move |inner| match list.tool {
            AccountTool::ClaudeCode => inner.claude.select(account_id.as_deref()),
            AccountTool::CodexCli => inner.codex.select(account_id.as_deref()),
            AccountTool::Omp => inner.omp.select(account_id.as_deref(), list.provider),
        });
    }

    pub fn remove(&self, account_id: &str, list: AccountListId) {
        let account_id = account_id.to_owned();
        Inner::perform(&self.inner, list, move |inner| match list.tool {
            AccountTool::ClaudeCode => inner.claude.remove(&account_id),
            AccountTool::CodexCli => inner.codex.remove(&account_id),
            AccountTool::Omp => inner.omp.remove(&account_id, list.provider),
        });
    }

    pub fn dismiss_error(&self, list: AccountListId) {
        self.inner.mutate(|snapshot| {
            snapshot.errors.remove(&list);
        });
    }

    /// Waits up to `timeout` for every background refresh and action to end;
    /// true when they did. For tests and an orderly shutdown.
    pub fn wait_until_idle(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        let mut shared = self.inner.lock();
        while shared.jobs > 0 {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return false;
            }
            shared =
                self.inner.idle.wait_timeout(shared, remaining).map_or_else(|e| e.into_inner().0, |r| r.0);
        }
        true
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl Inner {
    fn lock(&self) -> MutexGuard<'_, Shared> {
        lock(&self.shared)
    }

    /// Changes the snapshot and, when it changed, tells every observer.
    fn mutate(&self, change: impl FnOnce(&mut AccountsSnapshot)) {
        self.mutate_shared(|shared| change(&mut shared.snapshot));
    }

    fn mutate_shared<T>(&self, change: impl FnOnce(&mut Shared) -> T) -> T {
        let (result, changed) = {
            let mut shared = self.lock();
            let before = shared.snapshot.clone();
            let result = change(&mut shared);
            (result, shared.snapshot != before)
        };
        if changed {
            self.notify();
        }
        result
    }

    /// Tells observers about the newest snapshot without holding any lock while
    /// they run, so an observer may call back into the controller (review #9).
    /// One thread delivers at a time; a change made meanwhile — by an observer
    /// or another thread — is delivered by that same loop afterwards, so
    /// observers see snapshots in order and the last one they see is current.
    fn notify(&self) {
        {
            let mut shared = self.lock();
            shared.notify_pending = true;
            if shared.is_notifying {
                return;
            }
            shared.is_notifying = true;
        }
        loop {
            let snapshot = {
                let mut shared = self.lock();
                if !shared.notify_pending {
                    shared.is_notifying = false;
                    return;
                }
                shared.notify_pending = false;
                shared.snapshot.clone()
            };
            let observers: Vec<SnapshotObserver> = lock(&self.observers).values().cloned().collect();
            for observer in observers {
                observer(&snapshot);
            }
        }
    }

    fn spawn(self: &Arc<Self>, job: impl FnOnce(&Arc<Inner>) + Send + 'static) {
        self.lock().jobs += 1;
        let inner = Arc::clone(self);
        thread::spawn(move || {
            job(&inner);
            inner.job_finished();
        });
    }

    /// Queues `action` behind every earlier one.
    fn enqueue(self: &Arc<Self>, action: Action) {
        self.lock().jobs += 1;
        let mut sender = lock(&self.actions);
        let queue = sender.get_or_insert_with(|| {
            let (send, receive) = mpsc::channel::<Action>();
            let weak = Arc::downgrade(self);
            thread::spawn(move || run_actions(&weak, &receive));
            send
        });
        if let Err(mpsc::SendError(action)) = queue.send(action) {
            // The worker is gone (it never is while `self` lives); run on a thread instead.
            let inner = Arc::clone(self);
            thread::spawn(move || {
                action(&inner);
                inner.job_finished();
            });
        }
    }

    fn job_finished(&self) {
        let mut shared = self.lock();
        shared.jobs -= 1;
        self.idle.notify_all();
    }

    fn refresh(self: &Arc<Self>, force: bool) {
        let start = self.mutate_shared(|shared| {
            if shared.is_refreshing {
                if force {
                    shared.refresh_again = true;
                }
                return false;
            }
            if !force
                && let Some(last) = shared.snapshot.last_refresh
                && seconds_between(&last, &Utc::now()) < MINIMUM_REFRESH_INTERVAL_SECONDS
            {
                return false;
            }
            shared.is_refreshing = true;
            shared.snapshot.is_refreshing = true;
            true
        });
        if start {
            self.spawn(|inner| inner.perform_refresh());
        }
    }

    fn perform_refresh(self: &Arc<Self>) {
        let (omp_lists, claude_list) = thread::scope(|scope| {
            let omp = scope.spawn(|| self.omp.lists());
            let claude = self.claude.list();
            (omp.join().unwrap_or_default(), claude)
        });
        let mut lists: HashMap<AccountListId, AccountList> = HashMap::new();
        lists.insert(AccountListId::CODEX_CLI, self.codex.list());
        lists.insert(AccountListId::CLAUDE_CODE, claude_list);
        for list in omp_lists {
            lists.insert(list.id, list);
        }
        self.attach_usage(&mut lists);

        // One change, so observers rebuild once per refresh.
        let again = self.mutate_shared(|shared| {
            shared.snapshot.lists = lists;
            shared.snapshot.last_refresh = Some(Utc::now());
            shared.snapshot.is_refreshing = false;
            shared.is_refreshing = false;
            std::mem::take(&mut shared.refresh_again)
        });
        self.publish_launch_state();
        if again {
            self.refresh(true);
        }
    }

    /// Fills CLI rows with usage: omp's report for the same account when omp
    /// has one (usage is per account, whichever tool asks), else the
    /// provider's own answer for a still-valid token, reused for five minutes.
    fn attach_usage(&self, lists: &mut HashMap<AccountListId, AccountList>) {
        for id in [AccountListId::CLAUDE_CODE, AccountListId::CODEX_CLI] {
            let Some(mut list) = lists.get(&id).cloned() else { continue };
            let reported: Vec<AccountRow> = lists
                .get(&AccountListId::new(AccountTool::Omp, id.provider))
                .map(|list| list.accounts.clone())
                .unwrap_or_default();
            let credentials = if id == AccountListId::CLAUDE_CODE {
                self.claude.usage_credentials()
            } else {
                self.codex.usage_credentials()
            };

            let usage = |row: &AccountRow| -> Option<AccountUsage> {
                if row.identity.email.is_empty() {
                    return None;
                }
                if let Some(usage) = reported
                    .iter()
                    .find(|reported| reported.identity.matches(&row.identity))
                    .and_then(|r| r.usage.clone())
                {
                    return Some(usage);
                }
                let key = format!("{}|{}", id.tool.raw_value(), row.id);
                let now = Utc::now();
                if let Some((fetched_at, cached)) = self.lock().direct_usage.get(&key)
                    && seconds_between(fetched_at, &now) < POLL_INTERVAL_SECONDS
                {
                    return cached.clone();
                }
                let credential = credentials.iter().find(|credential| credential.row_id == row.id)?;
                let fetched = (self.usage)(id.provider, credential);
                self.lock().direct_usage.insert(key, (now, fetched.clone()));
                fetched
            };

            if let Some(system_default) = list.system_default.as_mut() {
                system_default.usage = usage(system_default);
            }
            for row in &mut list.accounts {
                row.usage = usage(row);
            }
            lists.insert(id, list);
        }
    }

    /// One sign-in at a time: the CLIs listen on fixed local ports for the
    /// browser's redirect (Codex on 1455 for both `codex` and omp).
    fn start_sign_in(self: &Arc<Self>, list: AccountListId, account_id: Option<String>) {
        let cancel = CancelToken::default();
        let started = self.mutate_shared(|shared| {
            if shared.snapshot.pending_login.is_some() {
                return false;
            }
            shared.snapshot.errors.remove(&list);
            shared.snapshot.pending_login =
                Some(PendingLogin { list, account_id: account_id.clone(), sign_in_url: None });
            shared.login_cancel = Some(cancel.clone());
            true
        });
        if !started {
            return;
        }
        self.spawn(move |inner| {
            let weak = Arc::downgrade(inner);
            let on_sign_in_url: LineHandler = Arc::new(move |url: &str| {
                if let Some(inner) = weak.upgrade() {
                    inner.sign_in_url_arrived(url, list);
                }
            });
            let result: AccountResult<()> = match (list.tool, account_id.as_deref()) {
                (AccountTool::ClaudeCode, Some(id)) => {
                    inner.claude.reauthenticate(id, on_sign_in_url, &cancel)
                }
                (AccountTool::ClaudeCode, None) => {
                    inner.claude.add_account(on_sign_in_url, &cancel).map(|_| ())
                }
                (AccountTool::CodexCli, Some(id)) => inner.codex.reauthenticate(id, on_sign_in_url, &cancel),
                (AccountTool::CodexCli, None) => inner.codex.add_account(on_sign_in_url, &cancel).map(|_| ()),
                (AccountTool::Omp, _) => inner.omp.sign_in(list.provider, on_sign_in_url, &cancel),
            };
            inner.mutate_shared(|shared| {
                match result {
                    // The user cancelled; nothing to report.
                    Err(error) if error.is_cancelled() => {}
                    Err(error) => {
                        shared.snapshot.errors.insert(list, error.to_string());
                    }
                    Ok(()) => {}
                }
                shared.snapshot.pending_login = None;
                shared.login_cancel = None;
            });
            inner.publish_launch_state();
            inner.refresh(true);
        });
    }

    fn sign_in_url_arrived(&self, url: &str, list: AccountListId) {
        // The first https URL a CLI prints is the authorization page.
        self.mutate(|snapshot| {
            if let Some(pending) = snapshot.pending_login.as_mut()
                && pending.list == list
                && pending.sign_in_url.is_none()
            {
                pending.sign_in_url = Some(url.to_owned());
            }
        });
    }

    fn perform(
        self: &Arc<Self>,
        list: AccountListId,
        action: impl FnOnce(&Inner) -> AccountResult<()> + Send + 'static,
    ) {
        self.mutate(|snapshot| {
            snapshot.errors.remove(&list);
        });
        self.enqueue(Box::new(move |inner: &Arc<Inner>| {
            if let Err(error) = action(inner) {
                inner.mutate(|snapshot| {
                    snapshot.errors.insert(list, error.to_string());
                });
            }
            inner.publish_launch_state();
            inner.refresh(true);
        }));
    }

    fn publish_launch_state(&self) {
        self.launch_state.update(
            self.codex.active_home(),
            self.paths.codex_default_home(),
            // Only with a preference: an omp too old for --config must keep
            // starting for anyone who never picks one.
            (!self.store.state().omp_preferred.is_empty()).then(|| self.paths.omp_overlay_file()),
        );
    }
}

/// The action queue's worker: runs each action as long as the controller lives.
fn run_actions(inner: &Weak<Inner>, actions: &mpsc::Receiver<Action>) {
    while let Ok(action) = actions.recv() {
        let Some(inner) = inner.upgrade() else { return };
        action(&inner);
        inner.job_finished();
    }
}

#[cfg(all(test, unix))]
mod tests {
    use std::fs;
    use std::path::Path;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;
    use crate::models::{AccountIdentity, UsageWindow};
    use crate::secrets::MemorySecretStore;
    use crate::state::ManagedAccountRecord;

    struct Fixture {
        controller: AccountsController,
        store: AccountStateStore,
        launch: Arc<AccountLaunchState>,
        paths: AccountPaths,
        fetches: Arc<AtomicUsize>,
        _root: tempfile::TempDir,
    }

    /// A login shell whose CLIs come from `bin`: `scripts` maps a CLI name to
    /// its bash body. Missing CLIs fail like an unknown command.
    #[cfg(unix)]
    fn make_fixture(scripts: &[(&str, &str)]) -> Fixture {
        let root = tempfile::tempdir().unwrap();
        let bin = root.path().join("bin");
        fs::create_dir_all(&bin).unwrap();
        fs::create_dir_all(root.path().join("home/.claude")).unwrap();
        let shell = root.path().join("shell");
        fs::write(
            &shell,
            format!(
                "#!/bin/bash\nexport PATH=\"{}:/usr/bin:/bin\"\nexec /bin/bash -c \"$2\"\n",
                bin.display()
            ),
        )
        .unwrap();
        crate::test_support::make_executable(&shell);
        for (name, body) in scripts {
            let path = bin.join(name);
            fs::write(&path, format!("#!/bin/bash\n{body}\n")).unwrap();
            crate::test_support::make_executable(&path);
        }
        let store = AccountStateStore::new(StateStore::in_memory());
        let paths = AccountPaths::new(root.path().join("home"), root.path().join("support"));
        let launch = Arc::new(AccountLaunchState::new());
        let fetches = Arc::new(AtomicUsize::new(0));
        let counter = Arc::clone(&fetches);
        let controller = AccountsController::with_parts(ControllerParts {
            store: store.clone(),
            paths: paths.clone(),
            runner: CommandRunner::new(shell.to_string_lossy()),
            claude_keychain: None,
            secrets: Arc::new(MemorySecretStore::default()),
            launch_state: Arc::clone(&launch),
            profile: Arc::new(|_: &str| None),
            usage: Arc::new(move |_, _| {
                counter.fetch_add(1, Ordering::SeqCst);
                Some(AccountUsage {
                    windows: vec![UsageWindow { label: "5h".into(), used_fraction: 0.25, resets_at: None }],
                    fetched_at: Utc::now(),
                })
            }),
        });
        Fixture { controller, store, launch, paths, fetches, _root: root }
    }

    fn wait(fixture: &Fixture) {
        assert!(fixture.controller.wait_until_idle(Duration::from_secs(30)));
    }

    #[cfg(unix)]
    #[test]
    fn a_refresh_loads_every_list_and_says_why_one_is_unavailable() {
        let fixture = make_fixture(&[]);
        let seen = Arc::new(AtomicUsize::new(0));
        let counter = Arc::clone(&seen);
        fixture.controller.add_observer(
            "test",
            Arc::new(move |_| {
                counter.fetch_add(1, Ordering::SeqCst);
            }),
        );

        fixture.controller.start();
        wait(&fixture);

        let snapshot = fixture.controller.snapshot();
        assert!(!snapshot.is_refreshing);
        assert!(snapshot.last_refresh.is_some());
        let omp = &snapshot.lists[&AccountListId::OMP_CLAUDE];
        assert_eq!(
            omp.unavailable_reason.as_deref(),
            Some("omp: omp is not installed or not on the login shell's PATH.")
        );
        let codex = &snapshot.lists[&AccountListId::CODEX_CLI];
        assert_eq!(
            codex.system_default.as_ref().and_then(|row| row.problem.as_deref()),
            Some("Not signed in")
        );
        assert!(snapshot.lists[&AccountListId::CLAUDE_CODE].unavailable_reason.is_none());
        assert!(seen.load(Ordering::SeqCst) >= 2);
        // The overlay exists before any omp pane starts with it.
        assert!(fixture.paths.omp_overlay_file().exists());
    }

    #[cfg(unix)]
    #[test]
    fn the_periodic_refresh_runs_only_once_five_minutes_have_passed() {
        let fixture = make_fixture(&[]);
        assert!(fixture.controller.refresh_due(Utc::now()));
        wait(&fixture);
        let last = fixture.controller.snapshot().last_refresh.unwrap();

        assert!(!fixture.controller.refresh_due(last + chrono::Duration::seconds(299)));
        assert!(fixture.controller.refresh_due(last + chrono::Duration::seconds(300)));
        wait(&fixture);

        // A view appearing within 30 s of a refresh does not start another.
        let last = fixture.controller.snapshot().last_refresh.unwrap();
        fixture.controller.refresh(false);
        assert_eq!(fixture.controller.snapshot().last_refresh, Some(last));
        assert!(!fixture.controller.snapshot().is_refreshing);
    }

    #[cfg(unix)]
    #[test]
    fn choosing_a_codex_account_points_new_codex_panes_at_its_home() {
        let fixture = make_fixture(&[]);
        let now = Utc::now();
        fixture.store.update(|state| {
            state.codex_cli.accounts = vec![ManagedAccountRecord {
                id: "c1".into(),
                identity: AccountIdentity::new("me@own.dev", None),
                organization_name: None,
                plan: None,
                created_at: now,
                last_authenticated_at: now,
            }];
        });

        fixture.controller.select(Some("c1"), AccountListId::CODEX_CLI);
        wait(&fixture);

        let home = fixture.paths.codex_accounts_directory().join("c1/home");
        assert_eq!(
            fixture.launch.adjustments("codex").environment.get("CODEX_HOME").map(Path::new),
            Some(home.as_path())
        );
        assert_eq!(
            fixture.controller.snapshot().lists[&AccountListId::CODEX_CLI].selected_account_id.as_deref(),
            Some("c1")
        );

        fixture.controller.select(Some("gone"), AccountListId::CODEX_CLI);
        wait(&fixture);
        assert_eq!(
            fixture.controller.snapshot().errors.get(&AccountListId::CODEX_CLI).map(String::as_str),
            Some("That account is no longer in the list.")
        );
        fixture.controller.dismiss_error(AccountListId::CODEX_CLI);
        assert!(fixture.controller.snapshot().errors.is_empty());
    }

    fn codex_record(id: &str) -> ManagedAccountRecord {
        let now = Utc::now();
        ManagedAccountRecord {
            id: id.into(),
            identity: AccountIdentity::new(format!("{id}@own.dev"), None),
            organization_name: None,
            plan: None,
            created_at: now,
            last_authenticated_at: now,
        }
    }

    /// Review #10: actions run first-in, first-out, so the last choice wins.
    #[test]
    fn quick_selections_apply_in_the_order_they_were_made() {
        let fixture = make_fixture(&[]);
        fixture.store.update(|state| state.codex_cli.accounts = vec![codex_record("c1"), codex_record("c2")]);

        for round in 0..20 {
            fixture.controller.select(Some("c1"), AccountListId::CODEX_CLI);
            fixture.controller.select(None, AccountListId::CODEX_CLI);
            let last = if round % 2 == 0 { "c2" } else { "c1" };
            fixture.controller.select(Some(last), AccountListId::CODEX_CLI);
        }
        fixture.controller.select(Some("c2"), AccountListId::CODEX_CLI);
        wait(&fixture);

        assert_eq!(fixture.store.state().codex_cli.active_account_id.as_deref(), Some("c2"));
        assert_eq!(
            fixture.controller.snapshot().lists[&AccountListId::CODEX_CLI].selected_account_id.as_deref(),
            Some("c2")
        );
    }

    /// Review #9: an observer that calls back into the controller from inside its
    /// callback does not deadlock, and still sees the snapshot that call produced.
    #[test]
    fn an_observer_may_call_back_into_the_controller() {
        let fixture = make_fixture(&[]);
        let controller = fixture.controller.clone();
        let dismissed = Arc::new(AtomicUsize::new(0));
        let seen_clean = Arc::new(AtomicUsize::new(0));
        let (dismissed_count, clean_count) = (Arc::clone(&dismissed), Arc::clone(&seen_clean));
        fixture.controller.add_observer(
            "reentrant",
            Arc::new(move |snapshot: &AccountsSnapshot| {
                let _ = controller.snapshot();
                if snapshot.errors.contains_key(&AccountListId::CODEX_CLI) {
                    dismissed_count.fetch_add(1, Ordering::SeqCst);
                    controller.dismiss_error(AccountListId::CODEX_CLI);
                } else {
                    clean_count.fetch_add(1, Ordering::SeqCst);
                }
            }),
        );

        let (done, finished) = std::sync::mpsc::channel();
        let selecting = fixture.controller.clone();
        thread::spawn(move || {
            selecting.select(Some("gone"), AccountListId::CODEX_CLI);
            let _ = done.send(());
        });
        finished.recv_timeout(Duration::from_secs(10)).expect("select returned");
        wait(&fixture);

        assert_eq!(dismissed.load(Ordering::SeqCst), 1);
        assert!(seen_clean.load(Ordering::SeqCst) >= 1);
        assert!(fixture.controller.snapshot().errors.is_empty());
        fixture.controller.remove_observer("reentrant");
    }

    #[cfg(unix)]
    #[test]
    fn only_one_sign_in_runs_at_a_time_and_cancelling_it_reports_nothing() {
        let fixture = make_fixture(&[(
            "omp",
            "[ \"$1\" = login ] || exit 1\necho \"Open https://auth.example/login?x=1\"\nexec sleep 30",
        )]);

        fixture.controller.add_account(AccountListId::OMP_CLAUDE);
        fixture.controller.add_account(AccountListId::CODEX_CLI);
        let deadline = Instant::now() + Duration::from_secs(15);
        while fixture
            .controller
            .snapshot()
            .pending_login
            .as_ref()
            .and_then(|p| p.sign_in_url.clone())
            .is_none()
            && Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(20));
        }
        let pending = fixture.controller.snapshot().pending_login.unwrap();
        assert_eq!(pending.list, AccountListId::OMP_CLAUDE);
        assert_eq!(pending.sign_in_url.as_deref(), Some("https://auth.example/login?x=1"));

        fixture.controller.cancel_login();
        wait(&fixture);

        let snapshot = fixture.controller.snapshot();
        assert_eq!(snapshot.pending_login, None);
        assert!(snapshot.errors.is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn cli_logins_omp_does_not_report_get_the_providers_usage_once_per_five_minutes() {
        let fixture = make_fixture(&[]);
        let auth = format!(
            r#"{{"tokens": {{"id_token": "e30.{}.s", "access_token": "token"}}}}"#,
            base64::Engine::encode(
                &base64::engine::general_purpose::URL_SAFE_NO_PAD,
                br#"{"email":"me@own.dev"}"#
            )
        );
        fs::create_dir_all(fixture.paths.codex_default_home()).unwrap();
        fs::write(fixture.paths.codex_default_home().join("auth.json"), auth).unwrap();

        fixture.controller.refresh(true);
        wait(&fixture);
        fixture.controller.refresh(true);
        wait(&fixture);

        let snapshot = fixture.controller.snapshot();
        let system_default = snapshot.lists[&AccountListId::CODEX_CLI].system_default.clone().unwrap();
        assert_eq!(system_default.identity.email, "me@own.dev");
        assert_eq!(system_default.usage.map(|usage| usage.windows[0].used_fraction), Some(0.25));
        assert_eq!(fixture.fetches.load(Ordering::SeqCst), 1);
        assert_eq!(
            snapshot.headline(AccountProvider::Codex).map(|(row, _)| row.id.as_str()),
            Some("system-default")
        );
    }
}
