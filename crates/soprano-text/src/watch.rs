//! A debounced watcher on one file, for the editor's and the Markdown reader's reloads
//! (the role `ConfigFileWatcher` plays in the Swift app).
//!
//! The file's folder is watched, not the file, so atomic saves (a rename over the file)
//! and deletions are seen. Every change in the folder fires after a quiet spell; the
//! callers compare what is on disk before reading it ([`crate::editor::EditorDocument::disk_did_change`]).
//! The callback runs on the watcher's thread: forward it to the UI thread.

use std::path::Path;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread;
use std::time::Duration;

use notify::{RecommendedWatcher, RecursiveMode, Watcher};

/// Stops watching when dropped.
pub struct FileWatcher {
    _watcher: RecommendedWatcher,
}

impl FileWatcher {
    /// Calls `on_change` once things have been quiet for `debounce` after changes in the
    /// folder of `path` (150 ms for the editor, 180 ms for the Markdown reader).
    pub fn new(
        path: &Path,
        debounce: Duration,
        on_change: impl Fn() + Send + 'static,
    ) -> notify::Result<Self> {
        let folder = path.parent().filter(|parent| !parent.as_os_str().is_empty()).unwrap_or(Path::new("."));
        let (sender, receiver) = mpsc::channel::<()>();
        let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            if event.is_ok_and(|event| !event.kind.is_access()) {
                let _ = sender.send(());
            }
        })?;
        watcher.watch(folder, RecursiveMode::NonRecursive)?;
        thread::Builder::new()
            .name("soprano-file-watcher".into())
            .spawn(move || {
                // Ends when the watcher (and with it the sender) is dropped.
                while receiver.recv().is_ok() {
                    loop {
                        match receiver.recv_timeout(debounce) {
                            Ok(()) => continue,
                            Err(RecvTimeoutError::Timeout) => break,
                            Err(RecvTimeoutError::Disconnected) => return,
                        }
                    }
                    on_change();
                }
            })
            .map_err(notify::Error::io)?;
        Ok(Self { _watcher: watcher })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::channel;

    #[test]
    fn a_burst_of_writes_fires_once_after_the_quiet_spell() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("notes.md");
        std::fs::write(&path, "one").unwrap();
        let (sender, receiver) = channel();
        let _watcher = FileWatcher::new(&path, Duration::from_millis(150), move || {
            let _ = sender.send(());
        })
        .unwrap();
        // Let the backend arm, and let any report of the file's creation fire, before writing.
        thread::sleep(Duration::from_millis(500));
        while receiver.try_recv().is_ok() {}
        for text in ["two", "three", "four"] {
            std::fs::write(&path, text).unwrap();
        }
        assert!(receiver.recv_timeout(Duration::from_secs(5)).is_ok());
        assert!(receiver.recv_timeout(Duration::from_millis(400)).is_err());
    }
}
