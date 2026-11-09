//! Resolves and watches git branch names for pane working directories.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, Weak};

use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};

type ChangeHandler = Arc<dyn Fn() + Send + Sync>;

/// Resolves and watches git branch names for pane working directories.
///
/// Thread-safe. `on_change` fires on the file watcher's thread whenever a watched HEAD
/// changes on disk; UI callers hop to their main thread themselves (the Swift class ran
/// its watchers on the main queue).
#[derive(Default)]
pub struct GitBranchMonitor {
    inner: Arc<Mutex<Inner>>,
}

#[derive(Default)]
struct Inner {
    on_change: Option<ChangeHandler>,
    /// cwd -> resolved HEAD file path (`None` resolutions are re-derived on each call).
    head_path_by_cwd: HashMap<String, Option<PathBuf>>,
    /// HEAD path -> cached branch name.
    branch_by_head_path: HashMap<PathBuf, String>,
    /// HEAD path -> the repository's default branch (`origin/HEAD`), `None` without one.
    default_branch_by_head_path: HashMap<PathBuf, Option<String>>,
    /// HEAD path -> active file watcher.
    watchers: HashMap<PathBuf, RecommendedWatcher>,
}

/// A repository without `origin/HEAD` counts these as its default branch.
pub const CONVENTIONAL_DEFAULT_BRANCHES: [&str; 2] = ["main", "master"];

impl GitBranchMonitor {
    pub fn new() -> Self {
        Self::default()
    }

    /// Fired whenever a watched HEAD changes on disk.
    pub fn set_on_change(&self, handler: impl Fn() + Send + Sync + 'static) {
        lock(&self.inner).on_change = Some(Arc::new(handler));
    }

    /// Current branch for a working directory; `None` when not in a git repo.
    pub fn branch(&self, cwd: &str) -> Option<String> {
        let mut inner = lock(&self.inner);
        inner.branch(cwd)
    }

    /// The branch a pane row names: the current one unless it is the
    /// repository's default, which most checkouts sit on most of the time.
    /// The default is what `origin/HEAD` points at; a repository without one
    /// counts `main` and `master`. A detached HEAD is always named.
    pub fn notable_branch(&self, cwd: &str) -> Option<String> {
        let mut inner = lock(&self.inner);
        let branch = inner.branch(cwd)?;
        let head_path = inner.head_path_by_cwd.get(cwd).cloned().flatten()?;
        let remote_default = match inner.default_branch_by_head_path.get(&head_path) {
            Some(cached) => cached.clone(),
            None => {
                let resolved = remote_default_branch(&head_path);
                inner.default_branch_by_head_path.insert(head_path, resolved.clone());
                resolved
            }
        };
        let is_default = match remote_default {
            Some(default) => default == branch,
            None => CONVENTIONAL_DEFAULT_BRANCHES.contains(&branch.as_str()),
        };
        (!is_default).then_some(branch)
    }

    /// Reconcile watchers with the current set of pane working directories.
    pub fn set_watched_paths(&self, paths: &[String]) {
        let mut inner = lock(&self.inner);
        let mut new_head_path_by_cwd = HashMap::new();
        let mut needed = HashSet::new();
        for cwd in paths.iter().collect::<HashSet<_>>() {
            let head_path = match inner.head_path_by_cwd.get(cwd.as_str()) {
                Some(Some(cached)) => Some(cached.clone()),
                _ => resolve_head_path(cwd),
            };
            if let Some(head_path) = &head_path {
                needed.insert(head_path.clone());
            }
            new_head_path_by_cwd.insert(cwd.clone(), head_path);
        }
        inner.head_path_by_cwd = new_head_path_by_cwd;

        let stale: Vec<PathBuf> =
            inner.watchers.keys().filter(|path| !needed.contains(*path)).cloned().collect();
        for head_path in stale {
            inner.watchers.remove(&head_path);
            inner.branch_by_head_path.remove(&head_path);
            inner.default_branch_by_head_path.remove(&head_path);
        }
        for head_path in needed {
            if inner.watchers.contains_key(&head_path) {
                continue;
            }
            match make_watcher(&head_path, Arc::downgrade(&self.inner)) {
                Some(watcher) => {
                    inner.watchers.insert(head_path, watcher);
                }
                None => {
                    // Watcher couldn't be established (unreadable HEAD, exhausted
                    // fds): drop the cache so each rebuild re-reads instead of
                    // serving a stale branch forever.
                    inner.branch_by_head_path.remove(&head_path);
                }
            }
        }
    }
}

impl Inner {
    fn branch(&mut self, cwd: &str) -> Option<String> {
        let head_path = match self.head_path_by_cwd.get(cwd) {
            Some(Some(cached)) => cached.clone(),
            _ => {
                let resolved = resolve_head_path(cwd);
                self.head_path_by_cwd.insert(cwd.to_owned(), resolved.clone());
                resolved?
            }
        };
        if let Some(cached) = self.branch_by_head_path.get(&head_path) {
            return Some(cached.clone());
        }
        let branch = parse_head(&head_path)?;
        self.branch_by_head_path.insert(head_path, branch.clone());
        Some(branch)
    }
}

fn lock(inner: &Mutex<Inner>) -> MutexGuard<'_, Inner> {
    inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// Watches HEAD's directory rather than the file: git updates HEAD via atomic rename,
/// which would orphan a watch on the file itself.
fn make_watcher(head_path: &Path, inner: Weak<Mutex<Inner>>) -> Option<RecommendedWatcher> {
    if !head_path.exists() {
        return None;
    }
    let directory = head_path.parent()?.to_path_buf();
    let file_name = head_path.file_name()?.to_os_string();
    let key = head_path.to_path_buf();
    let mut watcher = notify::recommended_watcher(move |result: notify::Result<notify::Event>| {
        let Ok(event) = result else { return };
        if matches!(event.kind, EventKind::Access(_)) {
            return;
        }
        if !event.paths.iter().any(|path| path.file_name() == Some(file_name.as_os_str())) {
            return;
        }
        let Some(inner) = inner.upgrade() else { return };
        let handler = {
            let mut inner = lock(&inner);
            inner.branch_by_head_path.remove(&key);
            // A checkout or `git remote set-head` comes with a HEAD change often
            // enough; re-reading origin/HEAD then is cheap.
            inner.default_branch_by_head_path.remove(&key);
            inner.on_change.clone()
        };
        if let Some(handler) = handler {
            handler();
        }
    })
    .ok()?;
    watcher.watch(&directory, RecursiveMode::NonRecursive).ok()?;
    Some(watcher)
}

/// `main` from `<common git dir>/refs/remotes/origin/HEAD`, which a clone
/// writes as `ref: refs/remotes/origin/main`. A linked worktree's git dir
/// names the common one in its `commondir` file.
pub fn remote_default_branch(head_path: &Path) -> Option<String> {
    let git_directory = head_path.parent()?;
    let mut common_directory = git_directory.to_path_buf();
    if let Ok(pointer) = std::fs::read_to_string(git_directory.join("commondir")) {
        let pointer = pointer.trim();
        common_directory = if Path::new(pointer).is_absolute() {
            PathBuf::from(pointer)
        } else {
            soprano_platform::paths::normalize(&git_directory.join(pointer))
        };
    }
    let contents = std::fs::read_to_string(common_directory.join("refs/remotes/origin/HEAD")).ok()?;
    let name = contents.trim().strip_prefix("ref: refs/remotes/origin/")?;
    (!name.is_empty()).then(|| name.to_owned())
}

/// Walk up from `path` to the repo's HEAD file. Handles `.git`
/// directories and `.git` files containing a `gitdir:` pointer
/// (worktrees and submodules).
pub fn resolve_head_path(path: &str) -> Option<PathBuf> {
    let entry = find_git_entry(path)?;
    if entry.is_directory {
        return Some(entry.git_path.join("HEAD"));
    }
    let contents = std::fs::read_to_string(&entry.git_path).ok()?;
    let target = contents.trim().strip_prefix("gitdir:")?.trim();
    let git_directory = if Path::new(target).is_absolute() {
        PathBuf::from(target)
    } else {
        soprano_platform::paths::normalize(&entry.working_tree.join(target))
    };
    Some(git_directory.join("HEAD"))
}

/// The working tree containing `path`: the nearest directory, `path`
/// itself included, that holds a `.git` directory or `gitdir:` file. A
/// linked worktree or submodule is its own root.
pub fn repository_root(path: &str) -> Option<PathBuf> {
    find_git_entry(path).map(|entry| entry.working_tree)
}

struct GitEntry {
    working_tree: PathBuf,
    git_path: PathBuf,
    is_directory: bool,
}

fn find_git_entry(path: &str) -> Option<GitEntry> {
    let mut directory = standardize(path);
    loop {
        let git_path = directory.join(".git");
        if let Ok(metadata) = std::fs::metadata(&git_path) {
            return Some(GitEntry { working_tree: directory, git_path, is_directory: metadata.is_dir() });
        }
        if !directory.pop() {
            return None;
        }
    }
}

/// Tilde-expanded, absolute (against the current directory), with `.` and `..` removed;
/// symlinks are kept, like Foundation's `standardizedFileURL`.
pub fn standardize(path: &str) -> PathBuf {
    let expanded = soprano_platform::paths::expand_tilde(path);
    let absolute = if expanded.is_absolute() {
        expanded
    } else {
        std::env::current_dir().map(|cwd| cwd.join(&expanded)).unwrap_or(expanded)
    };
    soprano_platform::paths::normalize(&absolute)
}

/// "ref: refs/heads/main" -> "main"; detached HEAD -> 7-char sha prefix.
pub fn parse_head(head_path: &Path) -> Option<String> {
    let contents = std::fs::read_to_string(head_path).ok()?;
    let line = contents.trim();
    if let Some(name) = line.strip_prefix("ref: refs/heads/") {
        return (!name.is_empty()).then(|| name.to_owned());
    }
    if line.starts_with("ref: ") {
        return line.rsplit('/').next().map(str::to_owned);
    }
    if line.chars().count() < 7 {
        return None;
    }
    Some(line.chars().take(7).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    /// A `.git` directory with just the files the monitor reads.
    fn make_repository(head: &str, origin_head: Option<&str>) -> tempfile::TempDir {
        let root = tempfile::tempdir().expect("tempdir");
        let git = root.path().join(".git");
        std::fs::create_dir_all(git.join("refs/remotes/origin")).expect("mkdir");
        std::fs::write(git.join("HEAD"), format!("ref: refs/heads/{head}\n")).expect("HEAD");
        if let Some(origin_head) = origin_head {
            std::fs::write(
                git.join("refs/remotes/origin/HEAD"),
                format!("ref: refs/remotes/origin/{origin_head}\n"),
            )
            .expect("origin HEAD");
        }
        root
    }

    fn path(dir: &tempfile::TempDir) -> String {
        dir.path().to_string_lossy().into_owned()
    }

    #[test]
    fn the_branch_origin_names_as_its_default_is_not_notable() {
        let develop = make_repository("develop", Some("develop"));
        let main = make_repository("main", Some("develop"));
        let monitor = GitBranchMonitor::new();

        assert_eq!(monitor.notable_branch(&path(&develop)), None);
        assert_eq!(monitor.notable_branch(&path(&main)).as_deref(), Some("main"));
    }

    #[test]
    fn without_an_origin_main_and_master_count_as_the_default() {
        let main = make_repository("main", None);
        let master = make_repository("master", None);
        let feature = make_repository("feat/automations", None);
        let monitor = GitBranchMonitor::new();

        assert_eq!(monitor.notable_branch(&path(&main)), None);
        assert_eq!(monitor.notable_branch(&path(&master)), None);
        let sources = feature.path().join("Sources").to_string_lossy().into_owned();
        assert_eq!(monitor.notable_branch(&sources).as_deref(), Some("feat/automations"));
    }

    #[test]
    fn a_linked_worktree_reads_the_default_from_its_common_git_directory() {
        let repository = make_repository("main", Some("main"));
        let worktree_git = repository.path().join(".git/worktrees/feature");
        std::fs::create_dir_all(&worktree_git).expect("mkdir");
        std::fs::write(worktree_git.join("HEAD"), "ref: refs/heads/main\n").expect("HEAD");
        std::fs::write(worktree_git.join("commondir"), "../..\n").expect("commondir");
        let checkout = repository.path().join("checkout");
        std::fs::create_dir_all(&checkout).expect("mkdir");
        std::fs::write(checkout.join(".git"), format!("gitdir: {}\n", worktree_git.display()))
            .expect("gitdir");

        assert_eq!(GitBranchMonitor::new().notable_branch(&checkout.to_string_lossy()), None);
        assert_eq!(remote_default_branch(&worktree_git.join("HEAD")).as_deref(), Some("main"));
    }

    #[test]
    fn a_detached_head_is_always_named() {
        let repository = make_repository("main", Some("main"));
        std::fs::write(repository.path().join(".git/HEAD"), "4cb9594f00d1e3b0c0ffee0000000000000000aa\n")
            .expect("HEAD");

        assert_eq!(GitBranchMonitor::new().notable_branch(&path(&repository)).as_deref(), Some("4cb9594"));
    }

    #[test]
    fn a_folder_outside_any_repository_has_no_branch() {
        assert_eq!(GitBranchMonitor::new().notable_branch("/"), None);
    }

    #[test]
    fn a_head_change_on_disk_refreshes_the_branch_and_fires_on_change() {
        let repository = make_repository("main", None);
        let monitor = GitBranchMonitor::new();
        let fired = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = fired.clone();
        monitor.set_on_change(move || flag.store(true, std::sync::atomic::Ordering::SeqCst));
        monitor.set_watched_paths(&[path(&repository)]);
        assert_eq!(monitor.branch(&path(&repository)).as_deref(), Some("main"));
        std::thread::sleep(Duration::from_millis(300));

        // git writes HEAD through a lock file and an atomic rename.
        let git = repository.path().join(".git");
        std::fs::write(git.join("HEAD.lock"), "ref: refs/heads/feature\n").expect("lock");
        std::fs::rename(git.join("HEAD.lock"), git.join("HEAD")).expect("rename");

        let deadline = Instant::now() + Duration::from_secs(10);
        while !fired.load(std::sync::atomic::Ordering::SeqCst) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(fired.load(std::sync::atomic::Ordering::SeqCst));
        assert_eq!(monitor.branch(&path(&repository)).as_deref(), Some("feature"));
    }
}
