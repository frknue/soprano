//! Claude Code asks whether to trust a folder the first time it starts in one, and waits for
//! the answer even with `--dangerously-skip-permissions`. A run nobody watches records its
//! folder as trusted the way that dialog does — the `projects.<path>.hasTrustDialogAccepted`
//! key Claude Code's own message points to — under the lock Claude Code takes for the file
//! (`ClaudeWorkspaceTrust` in `Automations/AutomationWorkspace.swift`).

use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{Map, Value};

/// `~/.claude.json`, or `.claude.json` in `CLAUDE_CONFIG_DIR`.
pub fn config_path(claude_config_dir: Option<&str>, home: &Path) -> PathBuf {
    match claude_config_dir.filter(|dir| !dir.is_empty()) {
        Some(directory) => PathBuf::from(soprano_config::expand_path(directory)).join(".claude.json"),
        None => home.join(".claude.json"),
    }
}

/// [`config_path`] for this process's environment and home.
pub fn default_config_path() -> PathBuf {
    config_path(std::env::var("CLAUDE_CONFIG_DIR").ok().as_deref(), &soprano_platform::paths::home_dir())
}

/// Marks `folder` trusted. False when there is no config to write (Claude Code never ran), it
/// can't be read, or Claude Code holds its lock for longer than `lock_timeout`.
pub fn trust(folder: &str, config: &Path, lock_timeout: Duration) -> bool {
    if !config.exists() {
        return false;
    }
    // Claude Code's lock is a directory beside the file: creating it is the atomic step that
    // claims it.
    let mut lock = config.as_os_str().to_owned();
    lock.push(".lock");
    let lock = PathBuf::from(lock);
    let deadline = Instant::now() + lock_timeout;
    while std::fs::create_dir(&lock).is_err() {
        if Instant::now() >= deadline {
            return false;
        }
        thread::sleep(Duration::from_millis(50));
    }
    let trusted = write_trust(folder, config);
    let _ = std::fs::remove_dir(&lock);
    trusted
}

fn write_trust(folder: &str, config: &Path) -> bool {
    let Some(mut document) = std::fs::read(config)
        .ok()
        .and_then(|data| serde_json::from_slice::<Value>(&data).ok())
        .and_then(|value| match value {
            Value::Object(map) => Some(map),
            _ => None,
        })
    else {
        return false;
    };
    let projects = document.entry("projects").or_insert_with(|| Value::Object(Map::new()));
    if !projects.is_object() {
        *projects = Value::Object(Map::new());
    }
    let Some(projects) = projects.as_object_mut() else { return false };
    let mut changed = false;
    // Claude Code keys projects by resolved path; the path as given covers a lookup that
    // doesn't resolve.
    let resolved_folder = resolved(Path::new(folder)).to_string_lossy().into_owned();
    let mut paths = vec![folder.to_owned()];
    if resolved_folder != folder {
        paths.push(resolved_folder);
    }
    for path in paths {
        let project = projects.entry(path).or_insert_with(|| Value::Object(Map::new()));
        if !project.is_object() {
            *project = Value::Object(Map::new());
        }
        if let Some(project) = project.as_object_mut()
            && project.get("hasTrustDialogAccepted") != Some(&Value::Bool(true))
        {
            project.insert("hasTrustDialogAccepted".into(), Value::Bool(true));
            changed = true;
        }
    }
    if !changed {
        return true;
    }
    let Ok(updated) = serde_json::to_vec_pretty(&Value::Object(document)) else { return false };
    // An atomic write replaces the file it names: write the one a symlinked config (dotfiles)
    // points to, not the link.
    let target = resolved(config);
    let permissions = std::fs::metadata(&target).ok().map(|m| m.permissions());
    let temporary = target.with_file_name(format!(
        ".{}.soprano-{}.tmp",
        target.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
        std::process::id()
    ));
    if std::fs::write(&temporary, updated).is_err() {
        return false;
    }
    if let Some(permissions) = permissions {
        let _ = std::fs::set_permissions(&temporary, permissions);
    }
    if std::fs::rename(&temporary, &target).is_err() {
        let _ = std::fs::remove_file(&temporary);
        return false;
    }
    true
}

fn resolved(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(unix)]
    fn trusting_a_folder_writes_through_a_symlinked_claude_config_instead_of_replacing_the_link() {
        let directory = tempfile::tempdir().expect("temp dir");
        let dotfile = directory.path().join("dotfiles-claude.json");
        std::fs::write(&dotfile, r#"{ "projects": {} }"#).expect("write");
        let link = directory.path().join(".claude.json");
        std::os::unix::fs::symlink(&dotfile, &link).expect("symlink");

        assert!(trust("/tmp/soprano-trusted", &link, Duration::from_secs(2)));

        assert_eq!(std::fs::read_link(&link).expect("still a link"), dotfile);
        let config: Value = serde_json::from_slice(&std::fs::read(&dotfile).expect("read")).expect("json");
        assert_eq!(config["projects"]["/tmp/soprano-trusted"]["hasTrustDialogAccepted"], Value::Bool(true));
    }

    #[test]
    fn a_missing_config_or_a_held_lock_trusts_nothing() {
        let directory = tempfile::tempdir().expect("temp dir");
        let config = directory.path().join(".claude.json");
        assert!(!trust("/tmp/x", &config, Duration::from_millis(100)));

        std::fs::write(&config, r#"{ "projects": {} }"#).expect("write");
        std::fs::create_dir(directory.path().join(".claude.json.lock")).expect("lock");
        assert!(!trust("/tmp/x", &config, Duration::from_millis(100)));
    }

    #[test]
    fn the_config_lives_in_claude_config_dir_when_it_is_set() {
        let home = Path::new("/home/me");
        assert_eq!(config_path(None, home), home.join(".claude.json"));
        assert_eq!(config_path(Some(""), home), home.join(".claude.json"));
        assert_eq!(config_path(Some("/etc/claude"), home), Path::new("/etc/claude/.claude.json"));
    }
}
