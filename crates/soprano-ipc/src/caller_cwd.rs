//! The directory a CLI invocation's relative paths resolve against: the real process working
//! directory, spelled as `$PWD` when `$PWD` names that same directory (it keeps the symlinked path
//! the shell shows). `$PWD` is only inherited, so a subprocess spawned with another cwd still
//! carries its parent's value and must not win.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub fn resolve(environment: &HashMap<String, String>, current_directory: &Path) -> PathBuf {
    match environment.get("PWD") {
        Some(pwd) if Path::new(pwd).is_absolute() && same_file(Path::new(pwd), current_directory) => {
            PathBuf::from(pwd)
        }
        _ => current_directory.to_path_buf(),
    }
}

#[cfg(unix)]
fn same_file(a: &Path, b: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    match (std::fs::metadata(a), std::fs::metadata(b)) {
        (Ok(a), Ok(b)) => a.dev() == b.dev() && a.ino() == b.ino(),
        _ => false,
    }
}

/// Windows has no stable inode through std; the canonical (symlink-resolved) paths stand in for
/// the file identity.
#[cfg(not(unix))]
fn same_file(a: &Path, b: &Path) -> bool {
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn an_inherited_pwd_naming_another_directory_loses_to_the_real_working_directory() {
        let root = tempfile::tempdir().expect("temp dir");
        let parent = root.path().join("parent");
        let child = root.path().join("child");
        let alias = root.path().join("alias");
        std::fs::create_dir_all(&parent).expect("mkdir");
        std::fs::create_dir_all(&child).expect("mkdir");
        std::os::unix::fs::symlink(&child, &alias).expect("symlink");
        let pwd = |path: &Path| HashMap::from([("PWD".to_string(), path.to_string_lossy().into_owned())]);

        assert_eq!(resolve(&pwd(&parent), &child), child);
        assert_eq!(resolve(&pwd(&alias), &child), alias);
        assert_eq!(resolve(&HashMap::new(), &child), child);
    }
}
