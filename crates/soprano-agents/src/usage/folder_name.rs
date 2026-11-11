//! omp's session folder names: where it files a working directory's sessions, which is how its
//! usage history names a project (`UsageSummary.swift`'s `UsageFolderName`).

use std::path::{Component, Path, PathBuf};

/// The stats folder for `path`. omp files a working directory's sessions under its canonical
/// path (`realpath`, so `/tmp/x` is `/private/tmp/x`): under the temporary directory
/// `-tmp-<relative>`, under home `-<relative>` (home itself `-`), elsewhere `--<absolute>--`,
/// with `/`, `\` and `:` as `-`. Its stats then store that name with a leading `--` and every
/// later `--` as `/` (`--opt-work--` → `/opt-work/`).
pub fn encode(path: &Path, home: &Path, temporary_directory: &Path) -> String {
    stats_folder(&session_directory(path, home, temporary_directory))
}

/// A readable title for a folder no project claims: without its leading and trailing dashes and
/// slashes (`-git-app` → `git-app`, `/private-tmp/` → `private-tmp`), `~` for home. The dashes
/// of the path are ambiguous, so they stay.
pub fn fallback_title(folder: &str) -> String {
    let trimmed = folder.trim_matches(['-', '/']);
    if trimmed.is_empty() { "~".to_owned() } else { trimmed.to_owned() }
}

/// The directory omp keeps the sessions of `path` in.
fn session_directory(path: &Path, home: &Path, temporary_directory: &Path) -> String {
    let path = canonical(path);
    if let Some(relative) = relative(&path, &canonical(temporary_directory)) {
        return if relative.is_empty() { "-tmp".to_owned() } else { format!("-tmp-{}", dashed(relative)) };
    }
    if let Some(relative) = relative(&path, &canonical(home)) {
        return format!("-{}", dashed(relative));
    }
    format!("--{}--", dashed(path.trim_start_matches('/')))
}

/// omp-stats' `extractFolderFromPath`: `^--` → `/`, then every `--` → `/`.
fn stats_folder(directory: &str) -> String {
    match directory.strip_prefix("--") {
        Some(rest) => format!("/{}", rest.replace("--", "/")),
        None => directory.replace("--", "/"),
    }
}

/// Node's `realpathSync` (symlinks resolved, `/tmp` → `/private/tmp`), else the lexically
/// normalized path for one that doesn't exist; without trailing slashes.
fn canonical(path: &Path) -> String {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().map_or_else(|_| path.to_path_buf(), |directory| directory.join(path))
    };
    let normalized = lexically_normalized(&absolute);
    let resolved = std::fs::canonicalize(&normalized).unwrap_or(normalized);
    let mut resolved = resolved.to_string_lossy().into_owned();
    while resolved.len() > 1 && resolved.ends_with('/') {
        resolved.pop();
    }
    resolved
}

/// `path` without `.`, `..` and repeated separators, resolved by name only: no file system
/// access, so a `..` after a symlink leaves the link's parent as written.
pub(super) fn lexically_normalized(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                // The parent of the root is the root; a relative path keeps a leading `..`.
                if matches!(normalized.components().next_back(), Some(Component::Normal(_))) {
                    normalized.pop();
                } else if !normalized.has_root() {
                    normalized.push(component);
                }
            }
            Component::Prefix(_) | Component::RootDir | Component::Normal(_) => normalized.push(component),
        }
    }
    normalized
}

/// `path` relative to `root` ("" for the root itself); `None` outside it.
fn relative<'a>(path: &'a str, root: &str) -> Option<&'a str> {
    let rest = path.strip_prefix(root)?;
    if rest.is_empty() || root.ends_with('/') {
        return Some(rest);
    }
    rest.strip_prefix('/')
}

fn dashed(text: &str) -> String {
    text.replace(['/', '\\', ':'], "-")
}
