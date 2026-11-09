//! Moving items to the OS trash in a way that can be undone: every trashed item reports
//! where it went so Undo can move it back.
//!
//! - macOS: `NSFileManager.trashItem(at:resultingItemURL:)`, exactly like the Swift app;
//!   the resulting URL is the restore source.
//! - Linux/Windows: `soprano_platform::system::move_to_trash`, then the item is looked up
//!   in the freedesktop trash / Recycle Bin so it can be restored from there. Listing the
//!   trash reads every entry, so it never runs on the calling (UI) thread: a single
//!   background worker deletes and then finds each item, in order, and Undo waits for
//!   that lookup only if it hasn't finished yet.

use std::collections::HashSet;
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::time::Duration;

use crate::root::without_verbatim_prefix;

/// Where a trashed item went.
#[derive(Clone, Debug)]
pub enum TrashedItem {
    /// A plain file-system location (macOS Trash, or a test bin); restoring moves it back.
    Path(PathBuf),
    /// An entry of the freedesktop trash or the Windows Recycle Bin, found in the
    /// background after the delete.
    #[cfg(not(target_os = "macos"))]
    System(Arc<PendingEntry<trash::TrashItem>>),
}

/// Something that can trash items reporting their new location.
pub trait TrashBin {
    fn trash(&self, path: &Path) -> Result<TrashedItem, String>;
}

/// The OS trash.
#[derive(Clone, Copy, Debug, Default)]
pub struct SystemTrash;

#[cfg(target_os = "macos")]
impl TrashBin for SystemTrash {
    fn trash(&self, path: &Path) -> Result<TrashedItem, String> {
        use objc2::rc::Retained;
        use objc2_foundation::{NSFileManager, NSString, NSURL};

        let url = NSURL::fileURLWithPath(&NSString::from_str(&path.to_string_lossy()));
        let mut resulting: Option<Retained<NSURL>> = None;
        NSFileManager::defaultManager()
            .trashItemAtURL_resultingItemURL_error(&url, Some(&mut resulting))
            .map_err(|error| error.localizedDescription().to_string())?;
        resulting
            .and_then(|url| url.path())
            .map(|path| TrashedItem::Path(PathBuf::from(path.to_string())))
            .ok_or_else(|| "the Trash did not report where the item went".to_owned())
    }
}

#[cfg(not(target_os = "macos"))]
impl TrashBin for SystemTrash {
    /// Deletes on the background worker and returns once the item is in the trash; where
    /// it went is looked up afterwards on that worker. An item that was trashed but can't
    /// be found again still counts as trashed: reporting failure would stop the rest of
    /// the selection and record no undo for something that is gone; its undo step
    /// reports the problem instead.
    fn trash(&self, path: &Path) -> Result<TrashedItem, String> {
        static WORKER: std::sync::LazyLock<TrashWorker<trash::TrashItem>> =
            std::sync::LazyLock::new(|| TrashWorker::spawn(OsTrash));
        WORKER.trash(path).map(TrashedItem::System)
    }
}

/// The freedesktop trash or the Windows Recycle Bin.
#[cfg(not(target_os = "macos"))]
struct OsTrash;

#[cfg(not(target_os = "macos"))]
impl SystemBin for OsTrash {
    type Entry = trash::TrashItem;

    fn delete(&self, path: &Path) -> Result<(), String> {
        soprano_platform::system::move_to_trash(&[path]).map_err(|error| error.to_string())
    }

    fn list(&self) -> Vec<trash::TrashItem> {
        trash::os_limited::list().unwrap_or_default()
    }
}

/// A trash that deletes items and lists its entries; abstracted so the worker's
/// ordering and matching are testable on every OS.
pub(crate) trait SystemBin: Send + 'static {
    type Entry: TrashEntry + Clone + Send + 'static;
    fn delete(&self, path: &Path) -> Result<(), String>;
    fn list(&self) -> Vec<Self::Entry>;
}

/// The trash entry of one deleted item, filled in by the worker once it has looked.
pub struct PendingEntry<E> {
    name: String,
    state: Mutex<Option<Option<E>>>,
    ready: Condvar,
}

impl<E> std::fmt::Debug for PendingEntry<E> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PendingEntry").field("name", &self.name).finish_non_exhaustive()
    }
}

#[cfg_attr(target_os = "macos", allow(dead_code))]
impl<E: Clone> PendingEntry<E> {
    fn new(name: String) -> Self {
        Self { name, state: Mutex::new(None), ready: Condvar::new() }
    }

    fn set(&self, entry: Option<E>) {
        *self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(entry);
        self.ready.notify_all();
    }

    /// The entry, waiting up to `timeout` for the lookup. `Err` explains why there is none.
    pub(crate) fn wait(&self, timeout: Duration) -> Result<E, String> {
        let state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let (state, _) = self
            .ready
            .wait_timeout_while(state, timeout, |state| state.is_none())
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        match &*state {
            Some(Some(entry)) => Ok(entry.clone()),
            Some(None) => Err(format!(
                "'{}' is in the trash, but the trash didn't list it, so it can't be put back",
                self.name
            )),
            None => Err(format!("'{}' is in the trash, but finding it there is taking too long", self.name)),
        }
    }
}

struct Request<E> {
    path: PathBuf,
    reply: mpsc::Sender<Result<(), String>>,
    pending: Arc<PendingEntry<E>>,
}

/// One background thread that handles trash requests in order: delete, report the
/// delete's result, then list the trash and find the entry it made. Serializing keeps the
/// lookup exact: entries this worker already found are claimed (by id and deletion time,
/// since ids can be reused), so an older or earlier-trashed item with the same name and
/// folder, even from the same second, is never taken for the newest one.
pub(crate) struct TrashWorker<E> {
    sender: Option<mpsc::Sender<Request<E>>>,
}

#[cfg_attr(target_os = "macos", allow(dead_code))]
impl<E: TrashEntry + Clone + Send + 'static> TrashWorker<E> {
    pub(crate) fn spawn<B: SystemBin<Entry = E>>(bin: B) -> Self {
        let (sender, receiver) = mpsc::channel::<Request<E>>();
        let spawned = std::thread::Builder::new().name("soprano-trash".to_owned()).spawn(move || {
            let mut claimed: HashSet<(OsString, i64)> = HashSet::new();
            for request in receiver {
                let deleted = bin.delete(&request.path);
                let succeeded = deleted.is_ok();
                let _ = request.reply.send(deleted);
                if !succeeded {
                    request.pending.set(None);
                    continue;
                }
                let name = request.path.file_name().map(OsStr::to_os_string).unwrap_or_default();
                let parent = request.path.parent().map(Path::to_path_buf).unwrap_or_default();
                let entries = bin.list();
                // Entries that left the trash free their claim (their ids may come back).
                claimed
                    .retain(|(id, time)| entries.iter().any(|e| e.id() == id && e.time_deleted() == *time));
                let found = pick_new_entry(entries, &claimed, &name, &parent, cfg!(windows));
                if let Some(entry) = &found {
                    claimed.insert((entry.id().to_os_string(), entry.time_deleted()));
                }
                request.pending.set(found);
            }
        });
        Self { sender: spawned.ok().map(|_| sender) }
    }

    /// Deletes `path` on the worker, returning once it is in the trash.
    pub(crate) fn trash(&self, path: &Path) -> Result<Arc<PendingEntry<E>>, String> {
        let sender = self.sender.as_ref().ok_or_else(|| "the trash worker could not start".to_owned())?;
        let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
        let pending = Arc::new(PendingEntry::new(name));
        let (reply, result) = mpsc::channel();
        sender
            .send(Request { path: path.to_path_buf(), reply, pending: pending.clone() })
            .map_err(|_| "the trash worker stopped".to_owned())?;
        result.recv().map_err(|_| "the trash worker stopped".to_owned())??;
        Ok(pending)
    }
}

/// A trash listing entry, abstracted so the matching rules are testable everywhere.
pub(crate) trait TrashEntry {
    fn id(&self) -> &OsStr;
    fn name(&self) -> &OsStr;
    fn original_parent(&self) -> &Path;
    fn time_deleted(&self) -> i64;
}

#[cfg(not(target_os = "macos"))]
impl TrashEntry for trash::TrashItem {
    fn id(&self) -> &OsStr {
        &self.id
    }
    fn name(&self) -> &OsStr {
        &self.name
    }
    fn original_parent(&self) -> &Path {
        &self.original_parent
    }
    fn time_deleted(&self) -> i64 {
        self.time_deleted
    }
}

/// Of the entries named `name` not `claimed` (by id and deletion time), the newest one from
/// `parent` — or, if the trash recorded the folder differently, the newest new one with
/// that name. Paths compare without Windows' verbatim prefix, case-insensitively when
/// `case_insensitive` (Windows).
#[cfg_attr(target_os = "macos", allow(dead_code))]
pub(crate) fn pick_new_entry<T: TrashEntry>(
    after: Vec<T>,
    claimed: &HashSet<(OsString, i64)>,
    name: &OsStr,
    parent: &Path,
    case_insensitive: bool,
) -> Option<T> {
    let same = |a: &OsStr, b: &OsStr| {
        if case_insensitive {
            a.to_string_lossy().to_lowercase() == b.to_string_lossy().to_lowercase()
        } else {
            a == b
        }
    };
    let wanted_parent = without_verbatim_prefix(parent).into_owned();
    let resolved_parent =
        std::fs::canonicalize(parent).map(|p| without_verbatim_prefix(&p).into_owned()).ok();
    let from_parent = |entry: &T| {
        let recorded = without_verbatim_prefix(entry.original_parent()).into_owned();
        same(recorded.as_os_str(), wanted_parent.as_os_str())
            || resolved_parent
                .as_ref()
                .is_some_and(|resolved| same(recorded.as_os_str(), resolved.as_os_str()))
    };
    let fresh: Vec<T> = after
        .into_iter()
        .filter(|entry| {
            same(entry.name(), name) && !claimed.contains(&(entry.id().to_os_string(), entry.time_deleted()))
        })
        .collect();
    if fresh.iter().any(&from_parent) {
        fresh.into_iter().filter(|entry| from_parent(entry)).max_by_key(TrashEntry::time_deleted)
    } else {
        fresh.into_iter().max_by_key(TrashEntry::time_deleted)
    }
}

/// How long Undo waits for a lookup still running on the worker.
#[cfg_attr(target_os = "macos", allow(dead_code))]
const LOOKUP_TIMEOUT: Duration = Duration::from_secs(30);

/// Restores an OS-trash entry to its original place, never replacing an item there.
#[cfg(not(target_os = "macos"))]
pub(crate) fn restore_system(pending: &PendingEntry<trash::TrashItem>) -> Result<(), String> {
    let item = pending.wait(LOOKUP_TIMEOUT)?;
    trash::os_limited::restore_all([item]).map_err(|error| error.to_string())
}

/// A trash that is a plain folder: items move into it under unique names. For tests and
/// embedders that keep their own bin.
#[derive(Clone, Debug)]
pub struct DirectoryTrash {
    pub directory: PathBuf,
}

impl TrashBin for DirectoryTrash {
    fn trash(&self, path: &Path) -> Result<TrashedItem, String> {
        let name = path.file_name().ok_or_else(|| "no file name".to_owned())?.to_string_lossy().into_owned();
        let mut target = self.directory.join(&name);
        let mut number = 2;
        while std::fs::symlink_metadata(&target).is_ok() {
            target = self.directory.join(format!("{name} {number}"));
            number += 1;
        }
        std::fs::rename(path, &target).map_err(|error| error.to_string())?;
        Ok(TrashedItem::Path(target))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Clone, Debug)]
    struct Entry {
        id: OsString,
        name: OsString,
        parent: PathBuf,
        deleted: i64,
    }

    impl TrashEntry for Entry {
        fn id(&self) -> &OsStr {
            &self.id
        }
        fn name(&self) -> &OsStr {
            &self.name
        }
        fn original_parent(&self) -> &Path {
            &self.parent
        }
        fn time_deleted(&self) -> i64 {
            self.deleted
        }
    }

    fn entry(id: &str, name: &str, parent: &str, deleted: i64) -> Entry {
        Entry { id: id.into(), name: name.into(), parent: parent.into(), deleted }
    }

    fn pick(
        after: Vec<Entry>,
        claimed: &[(&str, i64)],
        name: &str,
        parent: &str,
        insensitive: bool,
    ) -> Option<String> {
        let claimed: HashSet<(OsString, i64)> =
            claimed.iter().map(|(id, time)| (OsString::from(id), *time)).collect();
        pick_new_entry(after, &claimed, OsStr::new(name), Path::new(parent), insensitive)
            .map(|entry| entry.id.to_string_lossy().into_owned())
    }

    #[test]
    fn the_entry_this_delete_made_wins_over_an_older_one_from_the_same_second() {
        let after = vec![entry("old", "a.txt", "/p", 100), entry("new", "a.txt", "/p", 100)];
        assert_eq!(pick(after, &[("old", 100)], "a.txt", "/p", false).as_deref(), Some("new"));
    }

    #[test]
    fn a_new_entry_from_the_items_folder_wins_and_any_new_one_is_the_fallback() {
        let after = vec![entry("x", "a.txt", "/other", 300), entry("y", "a.txt", "/p", 200)];
        assert_eq!(pick(after, &[], "a.txt", "/p", false).as_deref(), Some("y"));
        let recorded_elsewhere = vec![entry("z", "a.txt", "/mnt/p", 200)];
        assert_eq!(pick(recorded_elsewhere, &[], "a.txt", "/p", false).as_deref(), Some("z"));
        assert_eq!(pick(vec![entry("o", "a.txt", "/p", 1)], &[("o", 1)], "a.txt", "/p", false), None);
        assert_eq!(pick(vec![entry("b", "b.txt", "/p", 1)], &[], "a.txt", "/p", false), None);
    }

    #[test]
    fn windows_matching_ignores_case() {
        let after = vec![entry("w", "Draft.TXT", "/Proj", 1)];
        assert_eq!(pick(after, &[], "draft.txt", "/proj", true).as_deref(), Some("w"));
        let after = vec![entry("w", "Draft.TXT", "/Proj", 1)];
        assert_eq!(pick(after, &[], "draft.txt", "/proj", false), None);
    }

    #[cfg(windows)]
    #[test]
    fn windows_matching_ignores_the_verbatim_prefix() {
        let after = vec![entry("v", "a.txt", r"\\?\C:\proj", 1)];
        assert_eq!(pick(after, &[], "a.txt", r"C:\proj", true).as_deref(), Some("v"));
    }

    /// A fake trash: deleting adds an entry (ids reused like freedesktop's info files
    /// once free), listing can be held up to show it happens off the caller's thread.
    #[derive(Clone, Default)]
    struct FakeBin {
        entries: Arc<Mutex<Vec<Entry>>>,
        clock: Arc<Mutex<i64>>,
        list_gate: Arc<Mutex<()>>,
    }

    impl SystemBin for FakeBin {
        type Entry = Entry;

        fn delete(&self, path: &Path) -> Result<(), String> {
            let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            if name == "locked.txt" {
                return Err("permission denied".to_owned());
            }
            let mut entries = self.entries.lock().expect("lock");
            let mut id = name.clone();
            let mut number = 2;
            while entries.iter().any(|e| e.id == OsString::from(&id)) {
                id = format!("{name}.{number}");
                number += 1;
            }
            let parent = path.parent().map(Path::to_path_buf).unwrap_or_default();
            let deleted = *self.clock.lock().expect("lock");
            entries.push(Entry { id: id.into(), name: name.into(), parent, deleted });
            Ok(())
        }

        fn list(&self) -> Vec<Entry> {
            let _gate = self.list_gate.lock().expect("lock");
            self.entries.lock().expect("lock").clone()
        }
    }

    fn found(pending: &PendingEntry<Entry>) -> String {
        pending.wait(Duration::from_secs(10)).expect("found").id.to_string_lossy().into_owned()
    }

    #[test]
    fn items_trashed_from_one_folder_in_one_second_each_find_their_own_entry() {
        let bin = FakeBin::default();
        *bin.clock.lock().expect("lock") = 100;
        bin.entries.lock().expect("lock").push(entry("older", "a.txt", "/p", 50));
        let worker = TrashWorker::spawn(bin.clone());

        let first = worker.trash(Path::new("/p/a.txt")).expect("trashed");
        let second = worker.trash(Path::new("/p/a.txt")).expect("trashed");

        assert_eq!(found(&first), "a.txt");
        assert_eq!(found(&second), "a.txt.2");
    }

    #[test]
    fn trashing_returns_before_the_trash_is_listed() {
        let bin = FakeBin::default();
        let worker = TrashWorker::spawn(bin.clone());
        let gate = bin.list_gate.lock().expect("lock");

        let pending = worker.trash(Path::new("/p/a.txt")).expect("trashed while listing is held");

        assert!(pending.wait(Duration::from_millis(20)).is_err());
        drop(gate);
        assert_eq!(found(&pending), "a.txt");
    }

    #[test]
    fn a_failed_delete_is_reported_to_the_caller() {
        let worker = TrashWorker::spawn(FakeBin::default());
        assert_eq!(worker.trash(Path::new("/p/locked.txt")).map(|_| ()), Err("permission denied".to_owned()));
    }

    #[test]
    fn an_entry_id_reused_after_a_restore_is_found_again() {
        let bin = FakeBin::default();
        let worker = TrashWorker::spawn(bin.clone());
        *bin.clock.lock().expect("lock") = 100;
        assert_eq!(found(&worker.trash(Path::new("/p/a.txt")).expect("trashed")), "a.txt");
        bin.entries.lock().expect("lock").clear(); // restored
        *bin.clock.lock().expect("lock") = 200;

        assert_eq!(found(&worker.trash(Path::new("/p/a.txt")).expect("trashed")), "a.txt");
    }

    #[test]
    fn an_item_the_trash_does_not_list_explains_why_it_cannot_come_back() {
        let pending = PendingEntry::<Entry>::new("a.txt".to_owned());
        pending.set(None);
        let error = pending.wait(Duration::from_millis(10)).expect_err("missing");
        assert!(error.contains("'a.txt' is in the trash"), "{error}");
    }
}
