//! The git worktree an automation run works in (`Automations/AutomationWorkspace.swift`): a new
//! branch from the base, checked out under `<data dir>/worktrees/<repository>/`. A run that
//! leaves it untouched gets it removed; one with changes or commits keeps it.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use chrono::{DateTime, Utc};
use chrono_tz::Tz;
use soprano_platform::AppIdentity;

use crate::run::RunWorktree;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Checkout {
    pub worktree: RunWorktree,
    /// The run's folder inside the worktree: the same place in the repository the
    /// automation's folder names.
    pub working_directory: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WorktreeFailure {
    GitUnavailable,
    NotARepository(String),
    UnknownBase(String),
    GitFailed(String),
}

impl std::fmt::Display for WorktreeFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::GitUnavailable => f.write_str("Git isn't installed, so the run can't get a worktree."),
            Self::NotARepository(folder) => write!(
                f,
                "{} is not inside a Git repository, so the run can't get a worktree.",
                soprano_config::config_file::abbreviating_home(folder)
            ),
            Self::UnknownBase(base) => {
                write!(f, "The base branch \"{base}\" doesn't exist in the repository.")
            }
            Self::GitFailed(message) => write!(f, "Git couldn't create the worktree: {message}"),
        }
    }
}

impl std::error::Error for WorktreeFailure {}

/// `<data dir>/worktrees`.
pub fn default_directory(identity: &AppIdentity) -> PathBuf {
    soprano_platform::paths::data_dir(identity).join("worktrees")
}

/// `automation/<id>-<yyyyMMdd-HHmm>`, the time read in `zone`.
pub fn branch_name(automation_id: &str, date: DateTime<Utc>, zone: Tz) -> String {
    format!("automation/{automation_id}-{}", date.with_timezone(&zone).format("%Y%m%d-%H%M"))
}

/// Creates the worktree. Without a `base_branch`, the run starts from the remote's default
/// branch as last fetched (`origin/HEAD`), and from the checkout's `HEAD` in a repository
/// without a remote. Blocks; call it off the main thread.
pub fn create(
    folder: &str,
    automation_id: &str,
    base_branch: Option<&str>,
    date: DateTime<Utc>,
    zone: Tz,
    directory: &Path,
) -> Result<Checkout, WorktreeFailure> {
    if soprano_git::reader::executable().is_none() {
        return Err(WorktreeFailure::GitUnavailable);
    }
    let Some(root) = soprano_git::branch::repository_root(folder) else {
        return Err(WorktreeFailure::NotARepository(folder.to_owned()));
    };
    let root_text = root.to_string_lossy().into_owned();
    let base = base_branch.map(str::to_owned).unwrap_or_else(|| default_base(&root));
    let base_commit = git(&["rev-parse", "--verify", "--quiet", &format!("{base}^{{commit}}")], &root)
        .ok()
        .filter(|commit| !commit.is_empty())
        .ok_or_else(|| WorktreeFailure::UnknownBase(base.clone()))?;

    let first = branch_name(automation_id, date, zone);
    let mut branch = first.clone();
    let mut suffix = 2;
    while git(&["rev-parse", "--verify", "--quiet", &format!("refs/heads/{branch}")], &root).is_ok() {
        branch = format!("{first}-{suffix}");
        suffix += 1;
    }
    let repository = root.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let parent = directory.join(repository);
    let leaf = branch.rsplit('/').next().unwrap_or(&branch).to_owned();
    let mut path = parent.join(&leaf);
    suffix = 2;
    while path.exists() {
        path = parent.join(format!("{leaf}-{suffix}"));
        suffix += 1;
    }
    std::fs::create_dir_all(&parent).map_err(|e| WorktreeFailure::GitFailed(e.to_string()))?;
    let path_text = path.to_string_lossy().into_owned();
    git(&["worktree", "add", "--no-track", "-b", &branch, &path_text, &base_commit], &root)
        .map_err(WorktreeFailure::GitFailed)?;

    let resolved_root = resolved(&root);
    let resolved_folder = resolved(Path::new(folder));
    let relative = resolved_folder.strip_prefix(&resolved_root).ok().filter(|r| !r.as_os_str().is_empty());
    let working_directory = match relative {
        Some(relative) => path.join(relative).to_string_lossy().into_owned(),
        None => path_text.clone(),
    };
    Ok(Checkout {
        worktree: RunWorktree { path: path_text, branch, repository: root_text, base_commit, removed: false },
        working_directory,
    })
}

fn default_base(root: &Path) -> String {
    git(&["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], root)
        .ok()
        .filter(|head| !head.is_empty())
        .unwrap_or_else(|| "HEAD".into())
}

/// Whether the run left the worktree as it found it: no changes, no untracked files, no
/// commits past its base.
pub fn is_untouched(worktree: &RunWorktree) -> bool {
    let path = Path::new(&worktree.path);
    match git(&["status", "--porcelain", "--untracked-files=all"], path) {
        Ok(status) if status.is_empty() => {}
        _ => return false,
    }
    git(&["rev-parse", "HEAD"], path).is_ok_and(|head| head == worktree.base_commit)
}

/// Removes the worktree and its branch.
pub fn remove(worktree: &RunWorktree) {
    let repository = Path::new(&worktree.repository);
    let _ = git(&["worktree", "remove", "--force", &worktree.path], repository);
    let _ = git(&["branch", "-D", &worktree.branch], repository);
}

/// Runs git in `directory`; trimmed stdout, or the trimmed stderr when it fails.
pub fn git(arguments: &[&str], directory: &Path) -> Result<String, String> {
    let Some(executable) = soprano_git::reader::executable() else {
        return Err("git is not installed".into());
    };
    let output = Command::new(executable)
        .args(arguments)
        .current_dir(directory)
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .output()
        .map_err(|e| e.to_string())?;
    if !output.status.success() {
        let message = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        return Err(if message.is_empty() {
            format!("git exited with {}", output.status.code().unwrap_or(-1))
        } else {
            message
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn resolved(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Repository {
        _base: tempfile::TempDir,
        root: PathBuf,
        worktrees: PathBuf,
    }

    /// A repository with one commit, plus a folder for worktrees, both thrown away after the
    /// test.
    fn make_repository() -> Repository {
        let base = tempfile::tempdir().expect("temp dir");
        let canonical = std::fs::canonicalize(base.path()).expect("canonical");
        let root = canonical.join("shop");
        std::fs::create_dir_all(root.join("theme")).expect("folders");
        for arguments in [
            &["init", "--quiet", "--initial-branch=main"][..],
            &["config", "user.email", "test@example.com"],
            &["config", "user.name", "Test"],
        ] {
            git(arguments, &root).expect("git");
        }
        std::fs::write(root.join("README.md"), "readme\n").expect("write");
        std::fs::write(root.join("theme/index.liquid"), "theme\n").expect("write");
        git(&["add", "."], &root).expect("add");
        git(&["commit", "--quiet", "-m", "init"], &root).expect("commit");
        Repository { worktrees: canonical.join("worktrees"), root, _base: base }
    }

    fn date() -> DateTime<Utc> {
        DateTime::from_timestamp(1_793_260_800, 0).expect("date")
    }

    fn checkout(
        repository: &Repository,
        folder: &Path,
        base: Option<&str>,
    ) -> Result<Checkout, WorktreeFailure> {
        create(&folder.to_string_lossy(), "audit", base, date(), Tz::UTC, &repository.worktrees)
    }

    fn has_git() -> bool {
        soprano_git::reader::executable().is_some()
    }

    #[test]
    fn a_runs_worktree_starts_at_the_same_place_in_the_repository_on_its_own_branch() {
        if !has_git() {
            return;
        }
        let repository = make_repository();
        let checkout = checkout(&repository, &repository.root.join("theme"), None).expect("checkout");

        assert!(checkout.worktree.branch.starts_with("automation/audit-"));
        assert_eq!(
            checkout.working_directory,
            Path::new(&checkout.worktree.path).join("theme").to_string_lossy()
        );
        assert!(Path::new(&checkout.working_directory).join("index.liquid").exists());
        assert!(checkout.worktree.path.starts_with(&*repository.worktrees.join("shop").to_string_lossy()));
        assert_eq!(
            git(&["rev-parse", "HEAD"], Path::new(&checkout.worktree.path)).as_deref(),
            Ok(checkout.worktree.base_commit.as_str())
        );
    }

    #[test]
    fn two_runs_in_the_same_minute_get_different_branches() {
        if !has_git() {
            return;
        }
        let repository = make_repository();
        let first = checkout(&repository, &repository.root, None).expect("first");
        let second = checkout(&repository, &repository.root, None).expect("second");

        assert_ne!(first.worktree.branch, second.worktree.branch);
        assert_ne!(first.worktree.path, second.worktree.path);
    }

    #[test]
    fn a_worktree_the_run_left_alone_counts_as_untouched_and_is_removed_with_its_branch() {
        if !has_git() {
            return;
        }
        let repository = make_repository();
        let checkout = checkout(&repository, &repository.root, None).expect("checkout");

        assert!(is_untouched(&checkout.worktree));
        remove(&checkout.worktree);

        assert!(!Path::new(&checkout.worktree.path).exists());
        let branch = format!("refs/heads/{}", checkout.worktree.branch);
        assert!(git(&["rev-parse", "--verify", "--quiet", &branch], &repository.root).is_err());
    }

    #[test]
    fn a_worktree_with_a_change_or_a_commit_is_not_untouched() {
        if !has_git() {
            return;
        }
        let repository = make_repository();
        let changed = checkout(&repository, &repository.root, None).expect("changed");
        std::fs::write(Path::new(&changed.worktree.path).join("notes.md"), "new\n").expect("write");
        let committed = checkout(&repository, &repository.root, None).expect("committed");
        git(&["commit", "--quiet", "--allow-empty", "-m", "work"], Path::new(&committed.worktree.path))
            .expect("commit");

        assert!(!is_untouched(&changed.worktree));
        assert!(!is_untouched(&committed.worktree));
    }

    #[test]
    fn a_base_branch_that_does_not_exist_fails_with_its_name() {
        if !has_git() {
            return;
        }
        let repository = make_repository();
        assert_eq!(
            checkout(&repository, &repository.root, Some("release")),
            Err(WorktreeFailure::UnknownBase("release".into()))
        );
        assert_eq!(
            WorktreeFailure::UnknownBase("release".into()).to_string(),
            "The base branch \"release\" doesn't exist in the repository."
        );
    }

    #[test]
    fn branch_names_carry_the_automation_and_the_local_minute() {
        let date = DateTime::from_timestamp(1_793_260_800, 0).expect("date");
        assert_eq!(branch_name("audit", date, chrono_tz::Europe::Berlin), "automation/audit-20261029-0900");
    }
}
