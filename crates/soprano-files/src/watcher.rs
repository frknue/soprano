//! Recursive watcher for directory trees, built on `notify` (FSEvents on macOS, inotify on
//! Linux, ReadDirectoryChangesW on Windows). Bursts within `latency` are coalesced into
//! one batch: the changed paths plus whether events were dropped and the trees need a
//! full rescan. Batches arrive on the watcher's own thread.
//!
//! Like the Swift stream's `WatchRoot` flag, a root that is itself renamed or deleted is
//! reported (as a rescan batch naming the root). A root the native backend can't watch —
//! typically Linux's inotify watch limit in a large repository — is polled instead, so
//! live updates keep working there, just slower.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::ThreadId;
use std::time::{Duration, Instant};

use notify::event::Flag;
use notify::{Event, EventKind, PollWatcher, RecursiveMode, Watcher};

/// Default coalescing window, as in the Swift FSEvents stream.
pub const DEFAULT_LATENCY: Duration = Duration::from_millis(150);
/// How often a root that falls back to polling is re-scanned.
pub const POLL_INTERVAL: Duration = Duration::from_secs(2);

type EventResult = notify::Result<Event>;

pub struct FileSystemWatcher {
    paths: Vec<PathBuf>,
    watchers: Vec<Box<dyn Watcher + Send>>,
    stopped: Arc<AtomicBool>,
    /// Held while a batch is delivered, so `stop` can wait out one in flight.
    delivering: Arc<Mutex<()>>,
    worker: ThreadId,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Backend {
    Native,
    /// Tests: what a root gets when the native backend refuses it.
    #[cfg_attr(not(test), allow(dead_code))]
    Polling,
}

impl FileSystemWatcher {
    /// Starts watching `paths` recursively; `None` when no path can be watched at all.
    pub fn new(
        paths: Vec<PathBuf>,
        latency: Duration,
        handler: impl FnMut(Vec<PathBuf>, bool) + Send + 'static,
    ) -> Option<Self> {
        Self::start(paths, latency, handler, Backend::Native)
    }

    fn start(
        paths: Vec<PathBuf>,
        latency: Duration,
        mut handler: impl FnMut(Vec<PathBuf>, bool) + Send + 'static,
        backend: Backend,
    ) -> Option<Self> {
        let (sender, receiver) = mpsc::channel::<EventResult>();
        let mut watchers: Vec<Box<dyn Watcher + Send>> = Vec::new();
        let mut native =
            if backend == Backend::Native { notify::recommended_watcher(sender.clone()).ok() } else { None };
        let mut watching = false;
        for path in &paths {
            if let Some(native) = native.as_mut()
                && native.watch(path, RecursiveMode::Recursive).is_ok()
            {
                watching = true;
                continue;
            }
            // Polling a missing path would "succeed" and watch nothing.
            if path.exists()
                && let Some(poller) = poll_watcher(path, sender.clone())
            {
                watchers.push(Box::new(poller));
                watching = true;
            }
        }
        if !watching {
            return None;
        }
        if let Some(native) = native {
            watchers.push(Box::new(native));
        }
        watchers.extend(paths.iter().filter_map(|root| root_watcher(root, sender.clone())));
        drop(sender);

        let stopped = Arc::new(AtomicBool::new(false));
        let delivering = Arc::new(Mutex::new(()));
        let (thread_stopped, thread_delivering) = (stopped.clone(), delivering.clone());
        let worker = std::thread::Builder::new()
            .name("soprano-file-watcher".to_owned())
            .spawn(move || {
                // Ends when every watcher (each holds a sender) is dropped.
                while let Ok(first) = receiver.recv() {
                    let mut batch = Batch::default();
                    batch.collect(first);
                    let deadline = Instant::now() + latency;
                    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
                        match receiver.recv_timeout(remaining) {
                            Ok(result) => batch.collect(result),
                            Err(mpsc::RecvTimeoutError::Timeout) => break,
                            Err(mpsc::RecvTimeoutError::Disconnected) => return,
                        }
                    }
                    if batch.paths.is_empty() && !batch.needs_rescan {
                        continue;
                    }
                    let _delivering =
                        thread_delivering.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                    if thread_stopped.load(Ordering::SeqCst) {
                        return;
                    }
                    handler(batch.paths, batch.needs_rescan);
                }
            })
            .ok()?;
        Some(Self { paths, watchers, stopped, delivering, worker: worker.thread().id() })
    }

    pub fn paths(&self) -> &[PathBuf] {
        &self.paths
    }

    /// Stops watching. Once it returns no batch is delivered any more: a batch in flight
    /// on another thread is waited out. (Called from inside the handler, it stops the
    /// batches after the current one.) Dropping the watcher does the same.
    pub fn stop(&mut self) {
        self.stopped.store(true, Ordering::SeqCst);
        if std::thread::current().id() != self.worker {
            drop(self.delivering.lock().unwrap_or_else(std::sync::PoisonError::into_inner));
        }
        // No lock is held here: native backends join their own threads on drop.
        self.watchers.clear();
    }
}

impl Drop for FileSystemWatcher {
    fn drop(&mut self) {
        self.stop();
    }
}

/// One coalesced batch, de-duplicated in arrival order.
#[derive(Default)]
struct Batch {
    paths: Vec<PathBuf>,
    seen: HashSet<PathBuf>,
    needs_rescan: bool,
}

impl Batch {
    fn collect(&mut self, result: EventResult) {
        match result {
            Ok(event) => {
                if event.need_rescan() {
                    self.needs_rescan = true;
                }
                if matches!(event.kind, EventKind::Access(_)) {
                    return;
                }
                for path in event.paths {
                    if self.seen.insert(path.clone()) {
                        self.paths.push(path);
                    }
                }
            }
            // Dropped or failed events: the trees must be re-read.
            Err(_) => self.needs_rescan = true,
        }
    }
}

fn poll_watcher(path: &Path, sender: mpsc::Sender<EventResult>) -> Option<PollWatcher> {
    let config = notify::Config::default().with_poll_interval(POLL_INTERVAL);
    let mut poller = PollWatcher::new(sender, config).ok()?;
    poller.watch(path, RecursiveMode::Recursive).ok()?;
    Some(poller)
}

/// Watches a root's parent for the root itself being renamed or deleted, which a
/// recursive watch on the root doesn't reliably report on every backend.
fn root_watcher(root: &Path, sender: mpsc::Sender<EventResult>) -> Option<Box<dyn Watcher + Send>> {
    let parent = root.parent()?.to_path_buf();
    let mut spellings = vec![root.to_path_buf()];
    if let Some(resolved) = crate::root::real_path(root)
        && resolved != root
    {
        spellings.push(resolved);
    }
    let reported = root.to_path_buf();
    let mut watcher = notify::recommended_watcher(move |result: EventResult| {
        let Ok(event) = result else { return };
        if matches!(event.kind, EventKind::Access(_))
            || !event.paths.iter().any(|path| spellings.contains(path))
        {
            return;
        }
        let _ =
            sender.send(Ok(Event::new(EventKind::Other).add_path(reported.clone()).set_flag(Flag::Rescan)));
    })
    .ok()?;
    watcher.watch(&parent, RecursiveMode::NonRecursive).ok()?;
    Some(Box::new(watcher))
}

#[cfg(test)]
mod tests {
    use super::*;

    type Seen = Arc<Mutex<Vec<(Vec<PathBuf>, bool)>>>;

    fn recorder() -> (Seen, impl FnMut(Vec<PathBuf>, bool) + Send + 'static) {
        let seen: Seen = Arc::new(Mutex::new(Vec::new()));
        let sink = seen.clone();
        (seen, move |paths, rescan| sink.lock().expect("lock").push((paths, rescan)))
    }

    fn wait_for(seen: &Seen, timeout: Duration, condition: impl Fn(&[(Vec<PathBuf>, bool)]) -> bool) -> bool {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if condition(&seen.lock().expect("lock")) {
                return true;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        condition(&seen.lock().expect("lock"))
    }

    fn canonical_tempdir() -> (tempfile::TempDir, PathBuf) {
        let temp = tempfile::tempdir().expect("tempdir");
        let root = std::fs::canonicalize(temp.path()).expect("canonicalize");
        (temp, root)
    }

    #[test]
    fn files_created_inside_the_tree_arrive_in_a_batch() {
        let (_temp, base) = canonical_tempdir();
        let root = base.join("root");
        std::fs::create_dir_all(root.join("Sources")).expect("mkdir");
        let (seen, handler) = recorder();
        let _watcher = FileSystemWatcher::new(vec![root.clone()], DEFAULT_LATENCY, handler).expect("watcher");
        std::thread::sleep(Duration::from_millis(300));

        let created = root.join("Sources/generated.swift");
        std::fs::write(&created, "").expect("write");

        assert!(wait_for(&seen, Duration::from_secs(10), |batches| batches
            .iter()
            .any(|(p, _)| p.contains(&created))));
    }

    #[test]
    fn nothing_can_be_watched_without_an_existing_path() {
        let path = PathBuf::from("/nonexistent/soprano");
        assert!(FileSystemWatcher::new(vec![path], DEFAULT_LATENCY, |_, _| {}).is_none());
    }

    #[test]
    fn a_root_the_native_backend_refuses_is_polled_instead() {
        let (_temp, base) = canonical_tempdir();
        let root = base.join("root");
        std::fs::create_dir_all(&root).expect("mkdir");
        let (seen, handler) = recorder();
        let _watcher =
            FileSystemWatcher::start(vec![root.clone()], DEFAULT_LATENCY, handler, Backend::Polling)
                .expect("watcher");
        std::thread::sleep(Duration::from_millis(300));

        let created = root.join("new.txt");
        std::fs::write(&created, "").expect("write");

        let timeout = POLL_INTERVAL * 5;
        assert!(wait_for(&seen, timeout, |batches| batches.iter().any(|(p, _)| p.contains(&created))));
    }

    #[test]
    fn renaming_the_root_itself_asks_for_a_rescan() {
        let (_temp, base) = canonical_tempdir();
        let root = base.join("root");
        std::fs::create_dir_all(&root).expect("mkdir");
        let (seen, handler) = recorder();
        let _watcher = FileSystemWatcher::new(vec![root.clone()], DEFAULT_LATENCY, handler).expect("watcher");
        std::thread::sleep(Duration::from_millis(300));

        std::fs::rename(&root, base.join("renamed")).expect("rename");

        assert!(wait_for(&seen, Duration::from_secs(10), |batches| {
            batches.iter().any(|(paths, rescan)| *rescan && paths.contains(&root))
        }));
    }

    #[test]
    fn no_batch_arrives_after_stop_returns() {
        let (_temp, base) = canonical_tempdir();
        let root = base.join("root");
        std::fs::create_dir_all(&root).expect("mkdir");
        let (seen, handler) = recorder();
        let mut watcher =
            FileSystemWatcher::new(vec![root.clone()], DEFAULT_LATENCY, handler).expect("watcher");
        std::thread::sleep(Duration::from_millis(300));
        // Events already queued when stop runs must not be delivered after it.
        std::fs::write(root.join("a.txt"), "").expect("write");

        watcher.stop();
        let delivered = seen.lock().expect("lock").len();
        std::fs::write(root.join("b.txt"), "").expect("write");
        std::thread::sleep(Duration::from_millis(800));

        assert_eq!(seen.lock().expect("lock").len(), delivered);
    }

    #[test]
    fn batches_list_each_path_once_in_arrival_order() {
        let mut batch = Batch::default();
        for path in ["/a", "/b", "/a", "/c", "/b"] {
            batch.collect(Ok(Event::new(EventKind::Any).add_path(PathBuf::from(path))));
        }
        batch.collect(Err(notify::Error::generic("dropped")));

        assert_eq!(batch.paths, ["/a", "/b", "/c"].map(PathBuf::from));
        assert!(batch.needs_rescan);
    }
}
