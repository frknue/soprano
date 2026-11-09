//! Moving items to the OS trash in a way that can be undone: every trashed item reports
//! where it went so Undo can move it back.
//!
//! - macOS: `NSFileManager.trashItem(at:resultingItemURL:)`, exactly like the Swift app;
//!   the resulting URL is the restore source.
//! - Linux/Windows: `soprano_platform::system::move_to_trash`, then the item is looked up
//!   in the freedesktop trash / Recycle Bin so it can be restored from there.

use std::path::{Path, PathBuf};

/// Where a trashed item went.
#[derive(Clone, Debug)]
pub enum TrashedItem {
    /// A plain file-system location (macOS Trash, or a test bin); restoring moves it back.
    Path(PathBuf),
    /// An entry of the freedesktop trash or the Windows Recycle Bin.
    #[cfg(not(target_os = "macos"))]
    System(trash::TrashItem),
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
    fn trash(&self, path: &Path) -> Result<TrashedItem, String> {
        let name = path.file_name().ok_or_else(|| "no file name".to_owned())?.to_os_string();
        let parent = path.parent().map(Path::to_path_buf).unwrap_or_default();
        let resolved_parent = std::fs::canonicalize(&parent).unwrap_or_else(|_| parent.clone());
        soprano_platform::system::move_to_trash(&[path]).map_err(|error| error.to_string())?;
        trash::os_limited::list()
            .map_err(|error| error.to_string())?
            .into_iter()
            .filter(|item| {
                item.name == name
                    && (item.original_parent == parent || item.original_parent == resolved_parent)
            })
            .max_by_key(|item| item.time_deleted)
            .map(TrashedItem::System)
            .ok_or_else(|| "the trash did not list the item".to_owned())
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
