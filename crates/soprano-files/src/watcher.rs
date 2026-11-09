//! Recursive watcher for directory trees, built on `notify` (FSEvents on macOS, inotify on
//! Linux, ReadDirectoryChangesW on Windows). Bursts within `latency` are coalesced into
//! one batch: the changed paths plus whether events were dropped and the trees need a
//! full rescan. Batches arrive on the watcher's own thread.

use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};

/// Default coalescing window, as in the Swift FSEvents stream.
pub const DEFAULT_LATENCY: Duration = Duration::from_millis(150);

pub struct FileSystemWatcher {
    paths: Vec<PathBuf>,
    watcher: Option<RecommendedWatcher>,
}

impl FileSystemWatcher {
    /// Starts watching `paths` recursively; `None` when no path can be watched.
    pub fn new(
        paths: Vec<PathBuf>,
        latency: Duration,
        mut handler: impl FnMut(Vec<PathBuf>, bool) + Send + 'static,
    ) -> Option<Self> {
        let (sender, receiver) = mpsc::channel::<notify::Result<notify::Event>>();
        let mut watcher = notify::recommended_watcher(sender).ok()?;
        let mut watching = false;
        for path in &paths {
            watching |= watcher.watch(path, RecursiveMode::Recursive).is_ok();
        }
        if !watching {
            return None;
        }
        std::thread::Builder::new()
            .name("soprano-file-watcher".to_owned())
            .spawn(move || {
                // Ends when the watcher (the channel's sender) is dropped.
                while let Ok(first) = receiver.recv() {
                    let mut batch = Vec::new();
                    let mut needs_rescan = false;
                    let mut collect = |result: notify::Result<notify::Event>| match result {
                        Ok(event) => {
                            if event.need_rescan() {
                                needs_rescan = true;
                            }
                            if !matches!(event.kind, EventKind::Access(_)) {
                                for path in event.paths {
                                    if !batch.contains(&path) {
                                        batch.push(path);
                                    }
                                }
                            }
                        }
                        // Dropped or failed events: the trees must be re-read.
                        Err(_) => needs_rescan = true,
                    };
                    collect(first);
                    let deadline = Instant::now() + latency;
                    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
                        match receiver.recv_timeout(remaining) {
                            Ok(result) => collect(result),
                            Err(mpsc::RecvTimeoutError::Timeout) => break,
                            Err(mpsc::RecvTimeoutError::Disconnected) => return,
                        }
                    }
                    if !batch.is_empty() || needs_rescan {
                        handler(batch, needs_rescan);
                    }
                }
            })
            .ok()?;
        Some(Self { paths, watcher: Some(watcher) })
    }

    pub fn paths(&self) -> &[PathBuf] {
        &self.paths
    }

    /// Stops watching; no batches arrive afterwards (dropping does the same).
    pub fn stop(&mut self) {
        self.watcher = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[test]
    fn files_created_inside_the_tree_arrive_in_a_batch() {
        let temp = tempfile::tempdir().expect("tempdir");
        let root = std::fs::canonicalize(temp.path()).expect("canonicalize");
        std::fs::create_dir_all(root.join("Sources")).expect("mkdir");
        let seen = Arc::new(Mutex::new(Vec::<PathBuf>::new()));
        let sink = seen.clone();
        let _watcher = FileSystemWatcher::new(vec![root.clone()], DEFAULT_LATENCY, move |paths, _| {
            sink.lock().expect("lock").extend(paths);
        })
        .expect("watcher");
        std::thread::sleep(Duration::from_millis(300));

        let created = root.join("Sources/generated.swift");
        std::fs::write(&created, "").expect("write");

        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline && !seen.lock().expect("lock").contains(&created) {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(seen.lock().expect("lock").contains(&created));
    }

    #[test]
    fn nothing_can_be_watched_without_an_existing_path() {
        assert!(
            FileSystemWatcher::new(vec![PathBuf::from("/nonexistent/soprano")], DEFAULT_LATENCY, |_, _| {})
                .is_none()
        );
    }
}
