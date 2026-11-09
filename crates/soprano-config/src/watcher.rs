//! Watches `settings.json` for edits made outside the app (`ConfigFileWatcher` in
//! `Config/ConfigFile.swift`), on top of the `notify` crate.
//!
//! It watches the containing **directory**, not the file: editors save atomically by writing a
//! temp file and renaming it over the target, which destroys the original inode and silences a
//! file-only watch after the first save. When `settings.json` is a symlink, the directory of
//! the file it points at is watched as well, and the watch follows the link when `ln -sf`
//! re-points it. When the config directory itself is deleted or replaced (a dotfiles
//! re-clone), the watch is rebuilt against the new directory; while it is missing, the watcher
//! retries every `rearm_interval` — only in that transient state, so this never becomes a
//! steady-state poll.

use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use notify::{RecommendedWatcher, RecursiveMode, Watcher};

use crate::config_file::resolving_symlink;

pub const DEFAULT_DEBOUNCE: Duration = Duration::from_millis(120);
pub const DEFAULT_REARM_INTERVAL: Duration = Duration::from_secs(2);

enum Message {
    Event,
    Stop,
}

/// A running watch; dropping it (or calling [`ConfigFileWatcher::stop`]) ends it.
pub struct ConfigFileWatcher {
    sender: Sender<Message>,
    thread: Option<JoinHandle<()>>,
}

impl ConfigFileWatcher {
    /// Starts watching `path`, calling `on_change` (on the watcher's own thread) once per burst
    /// of file-system events, `debounce` after the last one.
    ///
    /// Both watches are armed before this returns, so a save made right after `start` is seen.
    pub fn start(
        path: &Path,
        debounce: Duration,
        rearm_interval: Duration,
        on_change: impl Fn() + Send + 'static,
    ) -> Self {
        let (sender, receiver) = mpsc::channel();
        let event_sender = sender.clone();
        let notify_watcher = notify::recommended_watcher(move |result: notify::Result<notify::Event>| {
            if result.is_ok() {
                let _ = event_sender.send(Message::Event);
            }
        })
        .ok();

        let mut state = WatchState {
            path: path.to_path_buf(),
            watcher: notify_watcher,
            watched: Vec::new(),
            identity: None,
        };
        state.rearm();

        let thread = std::thread::Builder::new()
            .name("soprano-config-watcher".into())
            .spawn(move || {
                let mut pending: Option<Instant> = None;
                loop {
                    let blind = state.is_blind();
                    let now = Instant::now();
                    let timeout = match (pending, blind) {
                        (Some(deadline), true) => deadline.saturating_duration_since(now).min(rearm_interval),
                        (Some(deadline), false) => deadline.saturating_duration_since(now),
                        (None, true) => rearm_interval,
                        (None, false) => Duration::from_secs(3600),
                    };
                    match receiver.recv_timeout(timeout) {
                        Ok(Message::Stop) | Err(RecvTimeoutError::Disconnected) => return,
                        Ok(Message::Event) => {
                            // The directory may have been replaced, or the symlink re-pointed:
                            // rebuild the watch before reporting so the next save is seen too.
                            if state.current_identity() != state.identity {
                                state.rearm();
                            }
                            pending = Some(Instant::now() + debounce);
                        }
                        Err(RecvTimeoutError::Timeout) => {
                            if blind {
                                state.rearm();
                                if !state.is_blind() {
                                    // Pick up any edit made while we could not see.
                                    pending = Some(Instant::now() + debounce);
                                }
                            }
                        }
                    }
                    if pending.is_some_and(|deadline| Instant::now() >= deadline) {
                        pending = None;
                        on_change();
                    }
                }
            })
            .ok();

        Self { sender, thread }
    }

    /// Starts watching with the default debounce (120 ms) and re-arm interval (2 s).
    pub fn start_default(path: &Path, on_change: impl Fn() + Send + 'static) -> Self {
        Self::start(path, DEFAULT_DEBOUNCE, DEFAULT_REARM_INTERVAL, on_change)
    }

    pub fn stop(mut self) {
        self.shutdown();
    }

    fn shutdown(&mut self) {
        let _ = self.sender.send(Message::Stop);
        if let Some(thread) = self.thread.take()
            && thread.thread().id() != std::thread::current().id()
        {
            let _ = thread.join();
        }
    }
}

impl Drop for ConfigFileWatcher {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// What the watch was armed against: the config directory's identity and where the settings
/// path leads. A change in either means the watch must be rebuilt.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Identity {
    directory: DirectoryId,
    target: PathBuf,
}

struct WatchState {
    path: PathBuf,
    watcher: Option<RecommendedWatcher>,
    watched: Vec<PathBuf>,
    /// `None` while blind: the config directory is missing (or no watch could be armed).
    identity: Option<Identity>,
}

impl WatchState {
    fn is_blind(&self) -> bool {
        self.identity.is_none()
    }

    fn directory(&self) -> PathBuf {
        self.path.parent().map(Path::to_path_buf).unwrap_or_default()
    }

    fn current_identity(&self) -> Option<Identity> {
        let directory = directory_id(&self.directory())?;
        Some(Identity { directory, target: resolving_symlink(&self.path) })
    }

    fn rearm(&mut self) {
        let identity = self.current_identity();
        let directory = self.directory();
        let Some(watcher) = self.watcher.as_mut() else {
            self.identity = None;
            return;
        };
        for path in self.watched.drain(..) {
            let _ = watcher.unwatch(&path);
        }
        let Some(identity) = identity else {
            self.identity = None;
            return;
        };

        if watcher.watch(&directory, RecursiveMode::NonRecursive).is_err() {
            self.identity = None;
            return;
        }
        self.watched.push(directory.clone());
        // A symlinked settings.json: edits land in the target's directory.
        if let Some(target_directory) = identity.target.parent()
            && target_directory != directory
            && watcher.watch(target_directory, RecursiveMode::NonRecursive).is_ok()
        {
            self.watched.push(target_directory.to_path_buf());
        }
        self.identity = Some(identity);
    }
}

/// A directory's identity: device and inode on Unix, so a deleted-and-recreated directory
/// reads as new; elsewhere its creation time.
#[derive(Clone, Debug, PartialEq, Eq)]
struct DirectoryId(u64, u64);

#[cfg(unix)]
fn directory_id(path: &Path) -> Option<DirectoryId> {
    use std::os::unix::fs::MetadataExt;
    let metadata = std::fs::metadata(path).ok().filter(|m| m.is_dir())?;
    Some(DirectoryId(metadata.dev(), metadata.ino()))
}

#[cfg(not(unix))]
fn directory_id(path: &Path) -> Option<DirectoryId> {
    let metadata = std::fs::metadata(path).ok().filter(|m| m.is_dir())?;
    let created = metadata
        .created()
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |duration| duration.as_nanos() as u64);
    Some(DirectoryId(created, 0))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config_file;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn wait_until(deadline: Duration, condition: impl Fn() -> bool) -> bool {
        let end = Instant::now() + deadline;
        while Instant::now() < end {
            if condition() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        condition()
    }

    /// Someone re-cloning their dotfiles deletes and recreates the whole config directory.
    /// Every handle we hold then points at a dead directory, so the watch has to be rebuilt
    /// against the new one rather than going quietly deaf for the rest of the session.
    #[test]
    fn the_watch_is_rebuilt_after_the_config_directory_is_replaced() {
        let root = tempfile::tempdir().expect("tempdir");
        let directory = root.path().join("soprano-watch");
        let path = directory.join("settings.json");
        config_file::write("{}", &path).expect("writes");

        let changes = Arc::new(AtomicUsize::new(0));
        let counter = changes.clone();
        let watcher = ConfigFileWatcher::start(
            &path,
            Duration::from_millis(20),
            Duration::from_millis(50),
            move || {
                counter.fetch_add(1, Ordering::SeqCst);
            },
        );

        std::fs::remove_dir_all(&directory).expect("removes");
        std::thread::sleep(Duration::from_millis(200));

        let before = changes.load(Ordering::SeqCst);
        config_file::write(r#"{ "theme": "catppuccin-mocha" }"#, &path).expect("writes");
        assert!(wait_until(Duration::from_secs(15), || changes.load(Ordering::SeqCst) > before));
        watcher.stop();
    }

    /// `ln -sf` re-points a dotfiles symlink without touching either target file; only the
    /// config directory notices. Edits to the new target must still be picked up.
    #[cfg(unix)]
    #[test]
    fn edits_reach_the_watch_after_the_settings_symlink_is_repointed() {
        let root = tempfile::tempdir().expect("tempdir");
        let config = root.path().join("config");
        let dotfiles = root.path().join("dotfiles");
        std::fs::create_dir_all(&config).expect("dir");
        std::fs::create_dir_all(&dotfiles).expect("dir");
        let old = dotfiles.join("old.json");
        let new = dotfiles.join("new.json");
        std::fs::write(&old, "{}").expect("writes");
        std::fs::write(&new, "{}").expect("writes");
        let path = config.join("settings.json");
        std::os::unix::fs::symlink(&old, &path).expect("symlink");

        let changes = Arc::new(AtomicUsize::new(0));
        let counter = changes.clone();
        let watcher =
            ConfigFileWatcher::start(&path, Duration::from_millis(20), DEFAULT_REARM_INTERVAL, move || {
                counter.fetch_add(1, Ordering::SeqCst);
            });

        std::fs::remove_file(&path).expect("removes link");
        std::os::unix::fs::symlink(&new, &path).expect("symlink");
        std::thread::sleep(Duration::from_millis(300));

        let before = changes.load(Ordering::SeqCst);
        std::fs::write(&new, r#"{ "theme": "catppuccin-mocha" }"#).expect("writes");
        assert!(wait_until(Duration::from_secs(5), || changes.load(Ordering::SeqCst) > before));
        watcher.stop();
    }

    /// A symlink into a directory elsewhere is watched at its target.
    #[cfg(unix)]
    #[test]
    fn edits_to_a_symlinked_settings_file_in_another_directory_are_seen() {
        let root = tempfile::tempdir().expect("tempdir");
        let config = root.path().join("config");
        let dotfiles = root.path().join("dotfiles");
        std::fs::create_dir_all(&config).expect("dir");
        std::fs::create_dir_all(&dotfiles).expect("dir");
        let target = dotfiles.join("soprano.json");
        std::fs::write(&target, "{}").expect("writes");
        let path = config.join("settings.json");
        std::os::unix::fs::symlink(&target, &path).expect("symlink");

        let changes = Arc::new(AtomicUsize::new(0));
        let counter = changes.clone();
        let watcher =
            ConfigFileWatcher::start(&path, Duration::from_millis(20), DEFAULT_REARM_INTERVAL, move || {
                counter.fetch_add(1, Ordering::SeqCst);
            });
        std::thread::sleep(Duration::from_millis(200));
        let before = changes.load(Ordering::SeqCst);
        std::fs::write(&target, r#"{ "theme": "nord" }"#).expect("writes");
        assert!(wait_until(Duration::from_secs(5), || changes.load(Ordering::SeqCst) > before));
        watcher.stop();
    }
}
