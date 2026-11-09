//! A debounced watcher on one file, for the editor's and the Markdown reader's reloads.
//!
//! The Swift editor and reader used `ConfigFileWatcher`, so this is that watcher
//! (`soprano_config::ConfigFileWatcher`) with their debounce: it watches the file's folder
//! (atomic saves rename over the file) and, for a symlink, the folder of the file it points
//! at; it re-arms when the folder is replaced or the link re-pointed, and retries every
//! [`REARM_INTERVAL`] while the folder is missing. Callers compare what is on disk before
//! reading it ([`crate::editor::EditorDocument::disk_did_change`]). The callback runs on the
//! watcher's thread: forward it to the UI thread.

use std::path::Path;
use std::time::Duration;

use soprano_config::ConfigFileWatcher;

/// How often a watch whose folder is missing tries again.
pub const REARM_INTERVAL: Duration = soprano_config::watcher::DEFAULT_REARM_INTERVAL;

/// Stops watching when dropped.
pub struct FileWatcher {
    _watcher: ConfigFileWatcher,
}

impl FileWatcher {
    /// Calls `on_change` once things have been quiet for `debounce` after a change to `path`
    /// (150 ms for the editor, 180 ms for the Markdown reader).
    pub fn new(path: &Path, debounce: Duration, on_change: impl Fn() + Send + 'static) -> Self {
        Self { _watcher: ConfigFileWatcher::start(path, debounce, REARM_INTERVAL, on_change) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::{Receiver, channel};
    use std::thread;

    fn watch(path: &Path) -> (FileWatcher, Receiver<()>) {
        let (sender, receiver) = channel();
        let watcher = FileWatcher::new(path, Duration::from_millis(150), move || {
            let _ = sender.send(());
        });
        // Let the backend arm, and let any report of earlier writes fire, before writing.
        thread::sleep(Duration::from_millis(500));
        while receiver.try_recv().is_ok() {}
        (watcher, receiver)
    }

    #[test]
    fn a_burst_of_writes_fires_once_after_the_quiet_spell() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("notes.md");
        std::fs::write(&path, "one").unwrap();
        let (_watcher, receiver) = watch(&path);
        for text in ["two", "three", "four"] {
            std::fs::write(&path, text).unwrap();
        }
        assert!(receiver.recv_timeout(Duration::from_secs(5)).is_ok());
        assert!(receiver.recv_timeout(Duration::from_millis(400)).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn a_file_opened_through_a_symlink_into_another_folder_is_seen_changing() {
        let root = tempfile::tempdir().unwrap();
        let elsewhere = root.path().join("elsewhere");
        std::fs::create_dir(&elsewhere).unwrap();
        let target = elsewhere.join("notes.md");
        std::fs::write(&target, "one").unwrap();
        let link = root.path().join("link.md");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        let (_watcher, receiver) = watch(&link);

        std::fs::write(&target, "two").unwrap();
        assert!(receiver.recv_timeout(Duration::from_secs(5)).is_ok());
    }

    #[test]
    fn a_watch_on_a_missing_folder_arms_once_the_folder_appears() {
        let root = tempfile::tempdir().unwrap();
        let folder = root.path().join("later");
        let path = folder.join("notes.md");
        let (_watcher, receiver) = watch(&path);

        std::fs::create_dir(&folder).unwrap();
        std::fs::write(&path, "one").unwrap();
        // The retry after REARM_INTERVAL picks up what was written while blind.
        assert!(receiver.recv_timeout(REARM_INTERVAL + Duration::from_secs(5)).is_ok());
    }
}
