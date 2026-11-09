//! Moving items to the OS trash in a way that can be undone: every trashed item reports
//! where it went so Undo can move it back.
//!
//! - macOS: `NSFileManager.trashItem(at:resultingItemURL:)`, exactly like the Swift app;
//!   the resulting URL is the restore source.
//! - Linux/Windows: `soprano_platform::system::move_to_trash`, then the item is looked up
//!   in the freedesktop trash / Recycle Bin so it can be restored from there.

use std::collections::HashSet;
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};

use crate::root::without_verbatim_prefix;

/// Where a trashed item went.
#[derive(Clone, Debug)]
pub enum TrashedItem {
    /// A plain file-system location (macOS Trash, or a test bin); restoring moves it back.
    Path(PathBuf),
    /// An entry of the freedesktop trash or the Windows Recycle Bin.
    #[cfg(not(target_os = "macos"))]
    System(trash::TrashItem),
    /// Trashed, but the trash didn't list it afterwards, so it can't be put back.
    Unlocated(String),
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
    /// The trash's entries are listed before and after the delete, so the entry this call
    /// made is told apart from older ones with the same name (even ones trashed within
    /// the same second). An item that was trashed but can't be found again still counts
    /// as trashed: reporting failure would stop the rest of the selection and record no
    /// undo for something that is gone; its undo step reports the problem instead.
    fn trash(&self, path: &Path) -> Result<TrashedItem, String> {
        let name = path.file_name().ok_or_else(|| "no file name".to_owned())?.to_os_string();
        let parent = path.parent().map(Path::to_path_buf).unwrap_or_default();
        let before: HashSet<OsString> = trash::os_limited::list()
            .map(|items| items.into_iter().filter(|item| item.name == name).map(|item| item.id).collect())
            .unwrap_or_default();
        soprano_platform::system::move_to_trash(&[path]).map_err(|error| error.to_string())?;
        let after = trash::os_limited::list().unwrap_or_default();
        Ok(pick_new_entry(after, &before, &name, &parent, cfg!(windows))
            .map(TrashedItem::System)
            .unwrap_or_else(|| TrashedItem::Unlocated(name.to_string_lossy().into_owned())))
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

/// Of the entries named `name` that weren't in the trash `before`, the newest one from
/// `parent` — or, if the trash recorded the folder differently, the newest new one with
/// that name. Paths compare without Windows' verbatim prefix, case-insensitively when
/// `case_insensitive` (Windows).
#[cfg_attr(target_os = "macos", allow(dead_code))]
pub(crate) fn pick_new_entry<T: TrashEntry>(
    after: Vec<T>,
    before: &HashSet<OsString>,
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
    let fresh: Vec<T> =
        after.into_iter().filter(|entry| !before.contains(entry.id()) && same(entry.name(), name)).collect();
    if fresh.iter().any(&from_parent) {
        fresh.into_iter().filter(|entry| from_parent(entry)).max_by_key(TrashEntry::time_deleted)
    } else {
        fresh.into_iter().max_by_key(TrashEntry::time_deleted)
    }
}

/// Restores an OS-trash entry to its original place, never replacing an item there.
#[cfg(not(target_os = "macos"))]
pub(crate) fn restore_system(item: &trash::TrashItem) -> Result<(), String> {
    trash::os_limited::restore_all([item.clone()]).map_err(|error| error.to_string())
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
        before: &[&str],
        name: &str,
        parent: &str,
        insensitive: bool,
    ) -> Option<String> {
        let before: HashSet<OsString> = before.iter().map(OsString::from).collect();
        pick_new_entry(after, &before, OsStr::new(name), Path::new(parent), insensitive)
            .map(|entry| entry.id.to_string_lossy().into_owned())
    }

    #[test]
    fn the_entry_this_delete_made_wins_over_an_older_one_from_the_same_second() {
        let after = vec![entry("old", "a.txt", "/p", 100), entry("new", "a.txt", "/p", 100)];
        assert_eq!(pick(after, &["old"], "a.txt", "/p", false).as_deref(), Some("new"));
    }

    #[test]
    fn a_new_entry_from_the_items_folder_wins_and_any_new_one_is_the_fallback() {
        let after = vec![entry("x", "a.txt", "/other", 300), entry("y", "a.txt", "/p", 200)];
        assert_eq!(pick(after, &[], "a.txt", "/p", false).as_deref(), Some("y"));
        let recorded_elsewhere = vec![entry("z", "a.txt", "/mnt/p", 200)];
        assert_eq!(pick(recorded_elsewhere, &[], "a.txt", "/p", false).as_deref(), Some("z"));
        assert_eq!(pick(vec![entry("o", "a.txt", "/p", 1)], &["o"], "a.txt", "/p", false), None);
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
}
