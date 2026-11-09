//! Per-OS locations. `settings.json` itself is resolved by the config crate
//! (`SOPRANO_CONFIG`, `XDG_CONFIG_HOME`, `~/.config/soprano`) on every OS.

use std::path::{Path, PathBuf};

use crate::AppIdentity;

/// The user's home directory. Panics only on a system with no home at all, where nothing
/// Soprano persists could work anyway.
pub fn home_dir() -> PathBuf {
    dirs::home_dir().expect("no home directory")
}

/// Per-app data folder, the equivalent of macOS's `Application Support/<bundle id>`:
///
/// - macOS: `~/Library/Application Support/<app id>` (the same folder the Swift app used, so
///   automations, worktrees and Codex account homes carry over)
/// - Linux: `$XDG_DATA_HOME/<app id>` (default `~/.local/share/<app id>`)
/// - Windows: `%APPDATA%\<app id>`
///
/// `SOPRANO_DATA_DIR` overrides it outright (tests, isolated profiles).
pub fn data_dir(identity: &AppIdentity) -> PathBuf {
    if let Some(dir) = env_dir("SOPRANO_DATA_DIR") {
        return dir;
    }
    dirs::data_dir().unwrap_or_else(|| home_dir().join(".local/share")).join(&identity.id)
}

/// Where packaged resources live (agent hook templates, plugins, shell integration, fonts,
/// icons, terminfo). `SOPRANO_RESOURCES_DIR` overrides; otherwise, relative to the executable:
///
/// - macOS bundle: `Soprano.app/Contents/Resources`
/// - Linux/Windows install: `<exe dir>/resources`, then `<exe dir>/../share/soprano`
/// - a source checkout (`cargo run`): `<repo>/resources`
pub fn resources_dir() -> Option<PathBuf> {
    if let Some(dir) = env_dir("SOPRANO_RESOURCES_DIR") {
        return Some(dir);
    }
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    resources_dir_for_executable(&exe, |p| p.is_dir())
}

/// The resource-folder search behind [`resources_dir`], with the existence check injectable.
pub fn resources_dir_for_executable(exe: &Path, is_dir: impl Fn(&Path) -> bool) -> Option<PathBuf> {
    let exe_dir = exe.parent()?;
    let mut candidates = vec![
        exe_dir.join("../Resources"),
        exe_dir.join("resources"),
        exe_dir.join("../share/soprano"),
    ];
    // target/{debug,release}/soprano → <repo>/resources
    if let Some(repo) = exe_dir.parent().and_then(Path::parent) {
        candidates.push(repo.join("resources"));
    }
    candidates.into_iter().find(|c| is_dir(c)).map(|c| normalize(&c))
}

/// `path` with `$HOME` folded back to `~`, as a user would type it.
pub fn abbreviate_home(path: &Path) -> String {
    abbreviate_home_in(path, &home_dir())
}

pub fn abbreviate_home_in(path: &Path, home: &Path) -> String {
    match path.strip_prefix(home) {
        Ok(rest) if rest.as_os_str().is_empty() => "~".into(),
        Ok(rest) => format!("~{}{}", std::path::MAIN_SEPARATOR, rest.display()),
        Err(_) => path.display().to_string(),
    }
}

/// Expands a leading `~` or `~/` to the home directory.
pub fn expand_tilde(path: &str) -> PathBuf {
    expand_tilde_in(path, &home_dir())
}

pub fn expand_tilde_in(path: &str, home: &Path) -> PathBuf {
    if path == "~" {
        return home.to_path_buf();
    }
    if let Some(rest) = path.strip_prefix("~/").or_else(|| path.strip_prefix("~\\")) {
        return home.join(rest);
    }
    PathBuf::from(path)
}

/// Lexically removes `.` and `..` components without touching the file system.
pub fn normalize(path: &Path) -> PathBuf {
    use std::path::Component;
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    out.push("..");
                }
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

fn env_dir(key: &str) -> Option<PathBuf> {
    std::env::var_os(key).filter(|v| !v.is_empty()).map(|v| expand_tilde(&v.to_string_lossy()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn home_is_folded_to_a_tilde_only_at_the_start_of_the_path() {
        let home = Path::new("/Users/me");
        assert_eq!(abbreviate_home_in(Path::new("/Users/me"), home), "~");
        assert_eq!(abbreviate_home_in(Path::new("/Users/me/git/x"), home), "~/git/x");
        assert_eq!(abbreviate_home_in(Path::new("/tmp/Users/me"), home), "/tmp/Users/me");
        assert_eq!(abbreviate_home_in(Path::new("/Users/meow"), home), "/Users/meow");
    }

    #[test]
    fn tilde_expansion_leaves_other_paths_alone() {
        let home = Path::new("/home/me");
        assert_eq!(expand_tilde_in("~", home), PathBuf::from("/home/me"));
        assert_eq!(expand_tilde_in("~/git", home), PathBuf::from("/home/me/git"));
        assert_eq!(expand_tilde_in("~other/git", home), PathBuf::from("~other/git"));
        assert_eq!(expand_tilde_in("/abs", home), PathBuf::from("/abs"));
    }

    #[test]
    fn a_macos_bundle_finds_its_contents_resources_folder_before_a_checkout() {
        let exe = Path::new("/Applications/Soprano.app/Contents/MacOS/soprano");
        let found = resources_dir_for_executable(exe, |p| {
            normalize(p) == Path::new("/Applications/Soprano.app/Contents/Resources")
        });
        assert_eq!(found, Some(PathBuf::from("/Applications/Soprano.app/Contents/Resources")));
    }

    #[test]
    fn a_cargo_build_finds_the_repository_resources_folder() {
        let exe = Path::new("/src/soprano/target/debug/soprano");
        let found = resources_dir_for_executable(exe, |p| normalize(p) == Path::new("/src/soprano/resources"));
        assert_eq!(found, Some(PathBuf::from("/src/soprano/resources")));
    }
}
