//! Opens the active terminal tab's Git repository in Soprano Git, the family's
//! Git client (a separate macOS app). Soprano Git takes folders the way Finder and
//! `open -a` hand them over, so this resolves the repository root here and passes that
//! on; a repository Soprano Git already shows just gets its tab selected there.
//!
//! Soprano Git exists only on macOS: elsewhere [`is_available`] is false so the UI hides
//! the command, and [`installed_application`] finds nothing.

use std::path::{Path, PathBuf};

use crate::branch::repository_root;

pub const BUNDLE_IDENTIFIER: &str = "com.soprano.git";

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Plan {
    Open { repository: PathBuf, application: PathBuf },
    NoWorkingDirectory,
    NotInstalled,
    NotARepository(String),
}

/// Whether this OS can run Soprano Git at all.
pub fn is_available() -> bool {
    cfg!(target_os = "macos")
}

/// What opening `working_directory` would do. `application` locates the
/// installed Soprano Git; tests pass their own.
pub fn plan(working_directory: Option<&str>, application: impl FnOnce() -> Option<PathBuf>) -> Plan {
    let Some(working_directory) = working_directory.filter(|dir| !dir.is_empty()) else {
        return Plan::NoWorkingDirectory;
    };
    let Some(application) = application() else { return Plan::NotInstalled };
    let directory = soprano_platform::paths::expand_tilde(working_directory).to_string_lossy().into_owned();
    match repository_root(&directory) {
        Some(repository) => Plan::Open { repository, application },
        None => Plan::NotARepository(directory),
    }
}

/// The installed Soprano Git app, found by bundle identifier through Launch Services'
/// Spotlight index, falling back to the usual Applications folders.
#[cfg(target_os = "macos")]
pub fn installed_application() -> Option<PathBuf> {
    let query = format!("kMDItemCFBundleIdentifier == '{BUNDLE_IDENTIFIER}'");
    if let Ok(output) = std::process::Command::new("/usr/bin/mdfind").arg(query).output()
        && output.status.success()
        && let Some(found) = pick_application(&String::from_utf8_lossy(&output.stdout))
    {
        return Some(found);
    }
    let home = soprano_platform::paths::home_dir();
    [PathBuf::from("/Applications/Soprano Git.app"), home.join("Applications/Soprano Git.app")]
        .into_iter()
        .find(|path| path.is_dir())
}

/// The best of `mdfind`'s matches, one per line: never a copy in a Trash, and an
/// installed copy (in an Applications folder) before a build lying elsewhere — the way
/// Launch Services prefers installed apps.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn pick_application(candidates: &str) -> Option<PathBuf> {
    let usable: Vec<&str> = candidates
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.contains("/.Trash/") && !line.contains("/.Trashes/"))
        .collect();
    usable
        .iter()
        .find(|line| line.starts_with("/Applications/") || line.contains("/Applications/"))
        .or_else(|| usable.first())
        .map(PathBuf::from)
}

#[cfg(not(target_os = "macos"))]
pub fn installed_application() -> Option<PathBuf> {
    None
}

/// Why nothing opens, for every plan that doesn't open anything.
pub fn explanation(plan: &Plan) -> Option<String> {
    match plan {
        Plan::Open { .. } => None,
        Plan::NoWorkingDirectory => Some(
            "The active tab has no folder. Focus a terminal inside a Git repository and try again."
                .to_owned(),
        ),
        Plan::NotInstalled => Some("Soprano Git isn't installed.".to_owned()),
        Plan::NotARepository(directory) => Some(format!(
            "{} is not inside a Git repository.",
            soprano_platform::paths::abbreviate_home(Path::new(directory))
        )),
    }
}

/// Opens the repository, or reports why it can't through `report`. A plan that opens
/// nothing is reported at once on the caller's thread; the launch itself runs on a
/// background thread (like `NSWorkspace.open`'s completion handler), which reports a
/// failure from there, so UI callers hop back to their main thread in `report`.
pub fn open(working_directory: Option<&str>, report: impl FnOnce(String) + Send + 'static) {
    let plan = plan(working_directory, installed_application);
    let Plan::Open { repository, application } = plan else {
        if let Some(message) = explanation(&plan) {
            report(message);
        }
        return;
    };
    let spawned = std::thread::Builder::new().name("soprano-git-launcher".to_owned()).spawn(move || {
        if let Err(error) = launch(&repository, &application) {
            report(format!("Soprano Git could not open {}: {error}", repository.display()));
        }
    });
    if let Err(error) = spawned {
        // The closure holding `report` went with the thread that never started.
        tracing::warn!("could not start the Soprano Git launcher: {error}");
    }
}

#[cfg(target_os = "macos")]
fn launch(repository: &Path, application: &Path) -> std::io::Result<()> {
    // `open -a` activates the app, like `OpenConfiguration.activates = true`.
    let status =
        std::process::Command::new("/usr/bin/open").arg("-a").arg(application).arg(repository).status()?;
    if status.success() { Ok(()) } else { Err(std::io::Error::other(format!("open exited with {status}"))) }
}

#[cfg(not(target_os = "macos"))]
fn launch(_repository: &Path, _application: &Path) -> std::io::Result<()> {
    Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "Soprano Git is only available on macOS"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::branch::standardize;

    fn application() -> Option<PathBuf> {
        Some(PathBuf::from("/Applications/Soprano Git.app"))
    }

    fn opened_repository(plan: &Plan) -> Option<PathBuf> {
        match plan {
            Plan::Open { repository, .. } => Some(repository.clone()),
            _ => None,
        }
    }

    #[test]
    fn a_terminal_deep_inside_a_repository_opens_the_repository_root() {
        let root = tempfile::tempdir().expect("tempdir");
        std::fs::create_dir_all(root.path().join(".git")).expect("mkdir");
        let nested = root.path().join("Sources/App");
        std::fs::create_dir_all(&nested).expect("mkdir");

        let plan = plan(Some(&nested.to_string_lossy()), application);

        assert_eq!(opened_repository(&plan), Some(standardize(&root.path().to_string_lossy())));
        assert_eq!(explanation(&plan), None);
    }

    #[test]
    fn a_linked_worktree_opens_itself_rather_than_its_main_repository() {
        let root = tempfile::tempdir().expect("tempdir");
        let main = root.path().join("main");
        std::fs::create_dir_all(main.join(".git/worktrees/feature")).expect("mkdir");
        let worktree = root.path().join("feature");
        std::fs::create_dir_all(&worktree).expect("mkdir");
        std::fs::write(worktree.join(".git"), format!("gitdir: {}/.git/worktrees/feature\n", main.display()))
            .expect("gitdir");

        let plan = plan(Some(&worktree.to_string_lossy()), application);

        assert_eq!(opened_repository(&plan), Some(standardize(&worktree.to_string_lossy())));
    }

    #[test]
    fn a_folder_outside_any_repository_is_explained_instead_of_opened() {
        let root = tempfile::tempdir().expect("tempdir");
        let directory = root.path().to_string_lossy().into_owned();

        let plan = plan(Some(&directory), application);

        assert_eq!(plan, Plan::NotARepository(directory));
        assert!(explanation(&plan).is_some_and(|text| text.ends_with("is not inside a Git repository.")));
    }

    #[test]
    fn nothing_opens_when_soprano_git_is_not_installed() {
        let root = tempfile::tempdir().expect("tempdir");
        std::fs::create_dir_all(root.path().join(".git")).expect("mkdir");

        let plan = plan(Some(&root.path().to_string_lossy()), || None);

        assert_eq!(plan, Plan::NotInstalled);
        assert_eq!(explanation(&plan).as_deref(), Some("Soprano Git isn't installed."));
    }

    #[test]
    fn a_tab_without_a_folder_is_explained() {
        assert_eq!(plan(None, application), Plan::NoWorkingDirectory);
        assert_eq!(plan(Some(""), application), Plan::NoWorkingDirectory);
    }

    #[test]
    fn the_installed_copy_wins_and_trashed_copies_are_never_opened() {
        let found = "/Users/me/.Trash/Soprano Git.app\n/Users/me/dev/build/Soprano Git.app\n/Applications/Soprano Git.app\n";
        assert_eq!(pick_application(found), Some(PathBuf::from("/Applications/Soprano Git.app")));
        assert_eq!(
            pick_application("/Users/me/.Trash/Soprano Git.app\n/Users/me/dev/Soprano Git.app\n"),
            Some(PathBuf::from("/Users/me/dev/Soprano Git.app"))
        );
        assert_eq!(pick_application("/Volumes/X/.Trashes/501/Soprano Git.app\n"), None);
        assert_eq!(pick_application(""), None);
    }
}
