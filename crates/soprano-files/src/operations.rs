//! The file-system edits the explorer performs. Each one records its inverse on an undo
//! stack, so Undo / Redo walk them back and forth: a deletion goes to the trash and
//! undoing it moves the item back out. Single-threaded, like the Swift main-actor class.

use std::collections::HashSet;
use std::fmt;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use crate::listing::duplicate_name;
use crate::trash::{SystemTrash, TrashBin, TrashedItem};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OperationError {
    AlreadyExists(String),
    InvalidName(String),
    MoveIntoItself(String),
    CopyIntoItself(String),
    TrashFailed(String),
    Failed(String),
}

impl fmt::Display for OperationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::AlreadyExists(name) => {
                write!(f, "A file or folder named '{name}' already exists in this location")
            }
            Self::InvalidName(name) => write!(f, "'{name}' is not a valid file or folder name"),
            Self::MoveIntoItself(name) => write!(f, "Cannot move '{name}' into itself"),
            Self::CopyIntoItself(name) => write!(f, "Cannot copy '{name}' into itself"),
            Self::TrashFailed(name) => write!(f, "Failed to move to Trash '{name}'."),
            Self::Failed(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for OperationError {}

type Result<T, E = OperationError> = std::result::Result<T, E>;

#[derive(Clone, Debug)]
enum Step {
    Move { from: PathBuf, to: PathBuf },
    Trash(PathBuf),
    Restore { trashed: TrashedItem, to: PathBuf },
}

impl Step {
    fn touched_directories(&self) -> Vec<PathBuf> {
        match self {
            Self::Move { from, to } => vec![parent(from), parent(to)],
            Self::Trash(url) | Self::Restore { to: url, .. } => vec![parent(url)],
        }
    }
}

#[derive(Clone, Debug)]
struct Group {
    steps: Vec<Step>,
    action_name: String,
}

pub type DirectoriesChanged = Box<dyn FnMut(&HashSet<PathBuf>)>;
pub type UndoFailure = Box<dyn FnMut(&OperationError)>;
pub type ItemMoved = Box<dyn FnMut(&Path, &Path)>;

pub struct FileExplorerOperations {
    trash_bin: Box<dyn TrashBin>,
    undo_stack: Vec<Group>,
    redo_stack: Vec<Group>,
    /// Directories whose listing an operation changed, so the tree can reload
    /// them without waiting for the file-system watcher.
    pub on_directories_changed: Option<DirectoriesChanged>,
    /// Undo or redo that could not be applied, typically because the item
    /// was moved or deleted outside the explorer in the meantime.
    pub on_undo_failure: Option<UndoFailure>,
    /// An item moved, by rename, move, undo, or redo, so open editors can
    /// follow their files.
    pub on_item_moved: Option<ItemMoved>,
}

impl Default for FileExplorerOperations {
    fn default() -> Self {
        Self::new()
    }
}

impl FileExplorerOperations {
    pub fn new() -> Self {
        Self::with_trash(Box::new(SystemTrash))
    }

    pub fn with_trash(trash_bin: Box<dyn TrashBin>) -> Self {
        Self {
            trash_bin,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            on_directories_changed: None,
            on_undo_failure: None,
            on_item_moved: None,
        }
    }

    // MARK: Operations

    pub fn create_file(&mut self, name: &str, directory: &Path) -> Result<PathBuf> {
        let url = self.destination(name, directory)?;
        match std::fs::OpenOptions::new().write(true).create_new(true).open(&url) {
            Ok(_) => {}
            Err(error) if error.kind() == ErrorKind::AlreadyExists => {
                return Err(OperationError::AlreadyExists(name.to_owned()));
            }
            Err(error) => return Err(OperationError::Failed(error.to_string())),
        }
        self.record(vec![Step::Trash(url.clone())], "New File", [directory.to_path_buf()].into());
        Ok(url)
    }

    pub fn create_folder(&mut self, name: &str, directory: &Path) -> Result<PathBuf> {
        let url = self.destination(name, directory)?;
        match std::fs::create_dir(&url) {
            Ok(()) => {}
            Err(error) if error.kind() == ErrorKind::AlreadyExists => {
                return Err(OperationError::AlreadyExists(name.to_owned()));
            }
            Err(error) => return Err(OperationError::Failed(error.to_string())),
        }
        self.record(vec![Step::Trash(url.clone())], "New Folder", [directory.to_path_buf()].into());
        Ok(url)
    }

    /// Renames in place; never replaces an existing item.
    pub fn rename(&mut self, url: &Path, name: &str) -> Result<PathBuf> {
        if Some(name) == file_name(url).as_deref() {
            return Ok(url.to_path_buf());
        }
        let directory = parent(url);
        let is_case_only_change =
            file_name(url).is_some_and(|current| current.to_lowercase() == name.to_lowercase());
        // A case-only change may "collide" with the item itself on a
        // case-insensitive volume; perform_move tells that apart from a real
        // second item.
        let target = if is_case_only_change && is_valid_name(name) {
            directory.join(name)
        } else {
            self.destination(name, &directory)?
        };
        self.perform_move(url, &target)?;
        self.record(
            vec![Step::Move { from: target.clone(), to: url.to_path_buf() }],
            "Rename",
            [directory].into(),
        );
        Ok(target)
    }

    /// Moves items into `folder` and returns each moved item with its new
    /// location. Items already there are skipped, as are items inside other
    /// moved folders (they travel with them); a folder cannot be moved into
    /// itself or one of its descendants.
    pub fn move_items(&mut self, urls: &[PathBuf], folder: &Path) -> Result<Vec<(PathBuf, PathBuf)>> {
        let folder_path = standardized(folder);
        let mut inverse = Vec::new();
        let mut changed: HashSet<PathBuf> = [folder.to_path_buf()].into();
        let mut moved = Vec::new();
        let result = (|| {
            for url in outermost(urls) {
                if folder_path.starts_with(standardized(&url)) {
                    return Err(OperationError::MoveIntoItself(file_name(&url).unwrap_or_default()));
                }
                let parent_folder = parent(&url);
                if standardized(&parent_folder) == folder_path {
                    continue;
                }
                let target = self.destination(&file_name(&url).unwrap_or_default(), folder)?;
                self.perform_move(&url, &target)?;
                inverse.push(Step::Move { from: target.clone(), to: url.clone() });
                changed.insert(parent_folder);
                moved.push((url, target));
            }
            Ok(())
        })();
        if !inverse.is_empty() {
            inverse.reverse();
            self.record(inverse, "Move", changed);
        }
        result.map(|()| moved)
    }

    /// Copies items dropped from outside the explorer, or ⌥-dragged inside
    /// it, into `folder`, naming any that collide the way Duplicate does; a
    /// folder cannot be copied into itself or one of its descendants.
    pub fn copy_items(&mut self, urls: &[PathBuf], folder: &Path) -> Result<Vec<PathBuf>> {
        let folder_path = standardized(folder);
        let sources = outermost(urls);
        for url in &sources {
            if folder_path.starts_with(standardized(url)) {
                return Err(OperationError::CopyIntoItself(file_name(url).unwrap_or_default()));
            }
        }
        let mut inverse = Vec::new();
        let mut copied = Vec::new();
        let result = (|| {
            for url in &sources {
                let mut name = file_name(url).unwrap_or_default();
                if exists(&folder.join(&name)) {
                    name = duplicate_name(&name, |candidate| exists(&folder.join(candidate)));
                }
                let target = folder.join(&name);
                copy_item(url, &target).map_err(|error| OperationError::Failed(error.to_string()))?;
                inverse.push(Step::Trash(target.clone()));
                copied.push(target);
            }
            Ok(())
        })();
        if !inverse.is_empty() {
            inverse.reverse();
            self.record(inverse, "Copy", [folder.to_path_buf()].into());
        }
        result.map(|()| copied)
    }

    /// Copies a file next to itself as "name copy.ext", "name copy 2.ext", ….
    pub fn duplicate(&mut self, url: &Path) -> Result<PathBuf> {
        let directory = parent(url);
        let name = duplicate_name(&file_name(url).unwrap_or_default(), |candidate| {
            exists(&directory.join(candidate))
        });
        let target = directory.join(name);
        copy_item(url, &target).map_err(|error| OperationError::Failed(error.to_string()))?;
        self.record(vec![Step::Trash(target.clone())], "Duplicate", [directory].into());
        Ok(target)
    }

    /// Moves items to the trash without asking, like Finder's ⌘⌫. Items that
    /// are already gone count as deleted.
    pub fn trash(&mut self, urls: &[PathBuf]) -> Result<()> {
        let mut inverse = Vec::new();
        let mut changed = HashSet::new();
        let mut result = Ok(());
        for url in outermost(urls) {
            changed.insert(parent(&url));
            if !exists(&url) {
                continue;
            }
            match self.trash_bin.trash(&url) {
                Ok(trashed) => inverse.push(Step::Restore { trashed, to: url }),
                Err(_) => {
                    result = Err(OperationError::TrashFailed(file_name(&url).unwrap_or_default()));
                    break;
                }
            }
        }
        if !inverse.is_empty() {
            inverse.reverse();
            self.record(inverse, "Move to Trash", changed);
        }
        result
    }

    // MARK: Undo

    pub fn can_undo(&self) -> bool {
        !self.undo_stack.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo_stack.is_empty()
    }

    /// "Undo <name>" for the Edit menu.
    pub fn undo_action_name(&self) -> Option<&str> {
        self.undo_stack.last().map(|group| group.action_name.as_str())
    }

    pub fn redo_action_name(&self) -> Option<&str> {
        self.redo_stack.last().map(|group| group.action_name.as_str())
    }

    /// Walks the last operation back; false when there was nothing to undo. Failures go
    /// to `on_undo_failure`.
    pub fn undo(&mut self) -> bool {
        let Some(group) = self.undo_stack.pop() else { return false };
        if let Some(inverse) = self.apply(group) {
            self.redo_stack.push(inverse);
        }
        true
    }

    /// Re-applies the last undone operation; false when there was nothing to redo.
    pub fn redo(&mut self) -> bool {
        let Some(group) = self.redo_stack.pop() else { return false };
        if let Some(inverse) = self.apply(group) {
            self.undo_stack.push(inverse);
        }
        true
    }

    /// Registers `inverse` as the undo of the operation that just ran.
    fn record(&mut self, inverse: Vec<Step>, action_name: &str, changed: HashSet<PathBuf>) {
        self.undo_stack.push(Group { steps: inverse, action_name: action_name.to_owned() });
        self.redo_stack.clear();
        if let Some(callback) = self.on_directories_changed.as_mut() {
            callback(&changed);
        }
    }

    /// Runs undo/redo steps and returns their inverse for the opposite stack.
    fn apply(&mut self, group: Group) -> Option<Group> {
        let mut inverse = Vec::new();
        let mut changed = HashSet::new();
        let mut failure = None;
        for step in group.steps {
            changed.extend(step.touched_directories());
            let result = match step {
                Step::Move { from, to } => {
                    self.perform_move(&from, &to).map(|()| Step::Move { from: to, to: from })
                }
                Step::Trash(url) => {
                    if !exists(&url) {
                        continue;
                    }
                    match self.trash_bin.trash(&url) {
                        Ok(trashed) => Ok(Step::Restore { trashed, to: url }),
                        Err(_) => Err(OperationError::TrashFailed(file_name(&url).unwrap_or_default())),
                    }
                }
                Step::Restore { trashed, to } => self.restore(&trashed, &to).map(|()| Step::Trash(to)),
            };
            match result {
                Ok(step) => inverse.push(step),
                Err(error) => {
                    failure = Some(error);
                    break;
                }
            }
        }
        if let Some(error) = failure
            && let Some(callback) = self.on_undo_failure.as_mut()
        {
            callback(&error);
        }
        if let Some(callback) = self.on_directories_changed.as_mut() {
            callback(&changed);
        }
        if inverse.is_empty() {
            return None;
        }
        inverse.reverse();
        Some(Group { steps: inverse, action_name: group.action_name })
    }

    // MARK: File System

    fn destination(&self, name: &str, directory: &Path) -> Result<PathBuf> {
        if !is_valid_name(name) {
            return Err(OperationError::InvalidName(name.to_owned()));
        }
        let url = directory.join(name);
        if exists(&url) {
            return Err(OperationError::AlreadyExists(name.to_owned()));
        }
        Ok(url)
    }

    fn restore(&mut self, trashed: &TrashedItem, to: &Path) -> Result<()> {
        match trashed {
            TrashedItem::Path(path) => self.perform_move(path, to),
            #[cfg(not(target_os = "macos"))]
            TrashedItem::System(item) => {
                if exists(to) {
                    return Err(OperationError::AlreadyExists(file_name(to).unwrap_or_default()));
                }
                crate::trash::restore_system(item).map_err(OperationError::Failed)
            }
        }
    }

    /// Moves `source` to `target`, never replacing a different item at
    /// `target`: the one guard for operations, undo, and redo alike.
    fn perform_move(&mut self, source: &Path, target: &Path) -> Result<()> {
        let target_name = || file_name(target).unwrap_or_default();
        let is_case_only = source.to_string_lossy().to_lowercase() == target.to_string_lossy().to_lowercase()
            && source != target;
        if is_case_only && is_same_item(source, target) {
            // Case-only change on a case-insensitive volume: the target is the source
            // itself, which an exclusive rename would refuse, so a plain rename does it.
            std::fs::rename(source, target).map_err(|error| OperationError::Failed(error.to_string()))?;
        } else {
            // On a case-sensitive volume the other spelling can be a second item; the
            // exclusive rename refuses that atomically, even if it appeared just now.
            match rename_exclusive(source, target) {
                Ok(()) => {}
                Err(error) if error.kind() == ErrorKind::AlreadyExists => {
                    return Err(OperationError::AlreadyExists(target_name()));
                }
                Err(error) if is_cross_device(&error) && !is_case_only => {
                    // Like FileManager.moveItem across volumes: copy, then remove.
                    copy_item(source, target).map_err(|error| match error.kind() {
                        ErrorKind::AlreadyExists => OperationError::AlreadyExists(target_name()),
                        _ => OperationError::Failed(error.to_string()),
                    })?;
                    remove_item(source).map_err(|error| OperationError::Failed(error.to_string()))?;
                }
                Err(error) => return Err(OperationError::Failed(error.to_string())),
            }
        }
        if let Some(callback) = self.on_item_moved.as_mut() {
            callback(source, target);
        }
        Ok(())
    }
}

pub fn is_valid_name(name: &str) -> bool {
    !name.is_empty() && name != "." && name != ".." && !name.contains('/') && !name.contains('\0')
}

/// `urls` without any item that sits inside another listed folder.
pub fn outermost(urls: &[PathBuf]) -> Vec<PathBuf> {
    let paths: HashSet<PathBuf> = urls.iter().map(|url| standardized(url)).collect();
    urls.iter()
        .filter(|url| !standardized(url).ancestors().skip(1).any(|ancestor| paths.contains(ancestor)))
        .cloned()
        .collect()
}

fn standardized(path: &Path) -> PathBuf {
    soprano_platform::paths::normalize(path)
}

fn parent(path: &Path) -> PathBuf {
    path.parent().map(Path::to_path_buf).unwrap_or_default()
}

fn file_name(path: &Path) -> Option<String> {
    path.file_name().map(|name| name.to_string_lossy().into_owned())
}

/// Whether anything, including a dangling symlink, occupies `path`.
fn exists(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok()
}

#[cfg(unix)]
fn is_same_item(lhs: &Path, rhs: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    match (std::fs::symlink_metadata(lhs), std::fs::symlink_metadata(rhs)) {
        (Ok(a), Ok(b)) => a.dev() == b.dev() && a.ino() == b.ino(),
        _ => false,
    }
}

#[cfg(not(unix))]
fn is_same_item(lhs: &Path, rhs: &Path) -> bool {
    match (std::fs::canonicalize(lhs), std::fs::canonicalize(rhs)) {
        (Ok(a), Ok(b)) => a.to_string_lossy().to_lowercase() == b.to_string_lossy().to_lowercase(),
        _ => false,
    }
}

fn is_cross_device(error: &std::io::Error) -> bool {
    error.kind() == ErrorKind::CrossesDevices
}

#[cfg(unix)]
fn c_path(path: &Path) -> std::io::Result<std::ffi::CString> {
    use std::os::unix::ffi::OsStrExt;
    std::ffi::CString::new(path.as_os_str().as_bytes())
        .map_err(|_| std::io::Error::from(ErrorKind::InvalidInput))
}

/// rename(2) that fails with `AlreadyExists` instead of replacing the target.
#[cfg(target_os = "macos")]
fn rename_exclusive(source: &Path, target: &Path) -> std::io::Result<()> {
    let (source, target) = (c_path(source)?, c_path(target)?);
    // SAFETY: both arguments are valid NUL-terminated paths.
    let result = unsafe { libc::renamex_np(source.as_ptr(), target.as_ptr(), libc::RENAME_EXCL) };
    if result == 0 { Ok(()) } else { Err(std::io::Error::last_os_error()) }
}

#[cfg(target_os = "linux")]
fn rename_exclusive(source: &Path, target: &Path) -> std::io::Result<()> {
    let (c_source, c_target) = (c_path(source)?, c_path(target)?);
    // SAFETY: both arguments are valid NUL-terminated paths.
    let result = unsafe {
        libc::renameat2(
            libc::AT_FDCWD,
            c_source.as_ptr(),
            libc::AT_FDCWD,
            c_target.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    if result == 0 {
        return Ok(());
    }
    let error = std::io::Error::last_os_error();
    match error.raw_os_error() {
        // Kernels or file systems without RENAME_NOREPLACE.
        Some(libc::EINVAL | libc::ENOSYS) => check_then_rename(source, target),
        _ => Err(error),
    }
}

/// Elsewhere there is no atomic exclusive rename: check, then rename (std's rename
/// replaces on Windows).
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn rename_exclusive(source: &Path, target: &Path) -> std::io::Result<()> {
    check_then_rename(source, target)
}

#[cfg_attr(target_os = "macos", allow(dead_code))]
fn check_then_rename(source: &Path, target: &Path) -> std::io::Result<()> {
    if exists(target) && !is_same_item(source, target) {
        return Err(ErrorKind::AlreadyExists.into());
    }
    std::fs::rename(source, target)
}

/// Copies a file, folder (recursively) or symlink (as a link); fails if `target` exists.
fn copy_item(source: &Path, target: &Path) -> std::io::Result<()> {
    if exists(target) {
        return Err(ErrorKind::AlreadyExists.into());
    }
    let metadata = std::fs::symlink_metadata(source)?;
    if metadata.file_type().is_symlink() {
        let link = std::fs::read_link(source)?;
        #[cfg(unix)]
        return std::os::unix::fs::symlink(link, target);
        #[cfg(windows)]
        return if std::fs::metadata(source).is_ok_and(|m| m.is_dir()) {
            std::os::windows::fs::symlink_dir(link, target)
        } else {
            std::os::windows::fs::symlink_file(link, target)
        };
    }
    if metadata.is_dir() {
        std::fs::create_dir(target)?;
        for entry in std::fs::read_dir(source)? {
            let entry = entry?;
            copy_item(&entry.path(), &target.join(entry.file_name()))?;
        }
        return Ok(());
    }
    std::fs::copy(source, target).map(|_| ())
}

fn remove_item(path: &Path) -> std::io::Result<()> {
    if std::fs::symlink_metadata(path)?.is_dir() {
        std::fs::remove_dir_all(path)
    } else {
        std::fs::remove_file(path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::trash::DirectoryTrash;
    use std::cell::RefCell;
    use std::rc::Rc;

    fn read(path: &Path) -> String {
        std::fs::read_to_string(path).expect("read")
    }

    #[test]
    fn creating_never_replaces_an_existing_item() {
        let root = tempfile::tempdir().expect("tempdir");
        let root = root.path();
        let mut operations = FileExplorerOperations::new();
        std::fs::write(root.join("taken.txt"), "keep").expect("write");

        assert_eq!(
            operations.create_file("taken.txt", root),
            Err(OperationError::AlreadyExists("taken.txt".into()))
        );
        assert_eq!(
            operations.create_folder("taken.txt", root),
            Err(OperationError::AlreadyExists("taken.txt".into()))
        );
        assert_eq!(operations.create_file("a/b", root), Err(OperationError::InvalidName("a/b".into())));
        assert_eq!(read(&root.join("taken.txt")), "keep");
    }

    #[test]
    fn renaming_refuses_to_overwrite_but_allows_a_case_only_change() {
        let root = tempfile::tempdir().expect("tempdir");
        let root = root.path();
        let mut operations = FileExplorerOperations::new();
        let first = root.join("first.txt");
        std::fs::write(&first, "first").expect("write");
        std::fs::write(root.join("second.txt"), "second").expect("write");

        assert_eq!(
            operations.rename(&first, "second.txt"),
            Err(OperationError::AlreadyExists("second.txt".into()))
        );

        let renamed = operations.rename(&first, "First.txt").expect("rename");
        let names: Vec<String> = std::fs::read_dir(root)
            .expect("list")
            .map(|e| e.expect("entry").file_name().to_string_lossy().into_owned())
            .collect();
        assert!(names.contains(&"First.txt".to_owned()));
        assert_eq!(read(&renamed), "first");
    }

    #[test]
    fn moving_a_folder_together_with_its_own_file_moves_it_once() {
        let root = tempfile::tempdir().expect("tempdir");
        let root = root.path();
        let mut operations = FileExplorerOperations::new();
        let folder = root.join("folder");
        let inner = folder.join("inner.txt");
        let target = root.join("target");
        std::fs::create_dir_all(&folder).expect("mkdir");
        std::fs::create_dir_all(&target).expect("mkdir");
        std::fs::write(&inner, "x").expect("write");

        let moved = operations.move_items(&[folder, inner], &target).expect("move");

        assert_eq!(moved.into_iter().map(|(_, t)| t).collect::<Vec<_>>(), [target.join("folder")]);
        assert!(target.join("folder/inner.txt").exists());
    }

    /// Runs `body` in a directory where `foo` and `Foo` can be two different files: the
    /// temp dir when its volume is case-sensitive, else (macOS) a scratch case-sensitive
    /// APFS volume, like the Swift test. Returns false when neither is available.
    fn with_case_sensitive_directory(body: impl FnOnce(&Path)) -> bool {
        let scratch = tempfile::tempdir().expect("tempdir");
        std::fs::write(scratch.path().join("probe"), "").expect("probe");
        if !scratch.path().join("PROBE").exists() {
            body(scratch.path());
            return true;
        }
        #[cfg(target_os = "macos")]
        {
            let hdiutil = |arguments: &[&str]| {
                std::process::Command::new("/usr/bin/hdiutil")
                    .args(arguments)
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status()
                    .is_ok_and(|s| s.success())
            };
            let image = scratch.path().join("volume");
            let mount = scratch.path().join("mnt");
            let image_text = image.to_string_lossy().into_owned();
            let mount_text = mount.to_string_lossy().into_owned();
            let created = hdiutil(&[
                "create",
                "-size",
                "8m",
                "-fs",
                "Case-sensitive APFS",
                "-volname",
                "SopranoCase",
                "-type",
                "SPARSE",
                "-quiet",
                &image_text,
            ]);
            if !created
                || !hdiutil(&[
                    "attach",
                    "-nobrowse",
                    "-noverify",
                    "-quiet",
                    "-mountpoint",
                    &mount_text,
                    &format!("{image_text}.sparseimage"),
                ])
            {
                return false;
            }
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| body(&mount)));
            hdiutil(&["detach", "-force", "-quiet", &mount_text]);
            if let Err(panic) = result {
                std::panic::resume_unwind(panic);
            }
            true
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = body;
            false
        }
    }

    #[test]
    fn undoing_a_case_only_rename_never_replaces_a_file_created_in_the_meantime() {
        let ran = with_case_sensitive_directory(|root| {
            let mut operations = FileExplorerOperations::new();
            let failures = Rc::new(RefCell::new(Vec::new()));
            let sink = failures.clone();
            operations.on_undo_failure = Some(Box::new(move |error| sink.borrow_mut().push(error.clone())));
            let original = root.join("foo");
            std::fs::write(&original, "original").expect("write");

            let renamed = operations.rename(&original, "Foo").expect("rename");
            // Another program claims the old spelling before the user hits Undo.
            std::fs::write(&original, "newcomer").expect("write");
            operations.undo();

            assert_eq!(*failures.borrow(), [OperationError::AlreadyExists("foo".into())]);
            assert_eq!(read(&original), "newcomer");
            assert_eq!(read(&renamed), "original");

            // The forward direction refuses the same collision.
            assert_eq!(operations.rename(&renamed, "foo"), Err(OperationError::AlreadyExists("foo".into())));
            assert_eq!(read(&original), "newcomer");
        });
        if !ran {
            eprintln!("skipped: no case-sensitive volume available");
        }
    }

    #[test]
    fn a_folder_cannot_move_into_itself() {
        let root = tempfile::tempdir().expect("tempdir");
        let mut operations = FileExplorerOperations::new();
        let folder = root.path().join("folder");
        let child = folder.join("child");
        std::fs::create_dir_all(&child).expect("mkdir");

        assert_eq!(
            operations.move_items(&[folder], &child),
            Err(OperationError::MoveIntoItself("folder".into()))
        );
        assert!(child.exists());
    }

    #[test]
    fn a_folder_cannot_be_copied_into_itself() {
        let root = tempfile::tempdir().expect("tempdir");
        let mut operations = FileExplorerOperations::new();
        let folder = root.path().join("folder");
        let child = folder.join("child");
        std::fs::create_dir_all(&child).expect("mkdir");

        assert_eq!(
            operations.copy_items(&[folder], &child),
            Err(OperationError::CopyIntoItself("folder".into()))
        );
        assert_eq!(std::fs::read_dir(&child).expect("list").count(), 0);
    }

    #[test]
    fn undo_walks_moves_back_and_redo_reapplies_them() {
        let root = tempfile::tempdir().expect("tempdir");
        let mut operations = FileExplorerOperations::new();
        let file = root.path().join("note.txt");
        let folder = root.path().join("archive");
        std::fs::write(&file, "hello").expect("write");
        std::fs::create_dir_all(&folder).expect("mkdir");

        let moved = operations.move_items(std::slice::from_ref(&file), &folder).expect("move");
        assert_eq!(moved.into_iter().map(|(_, t)| t).collect::<Vec<_>>(), [folder.join("note.txt")]);
        assert_eq!(operations.undo_action_name(), Some("Move"));

        operations.undo();
        assert!(file.exists());
        assert!(!folder.join("note.txt").exists());

        operations.redo();
        assert!(!file.exists());
        assert_eq!(read(&folder.join("note.txt")), "hello");
    }

    #[test]
    fn deleting_moves_to_the_trash_and_undo_restores_the_file() {
        let root = tempfile::tempdir().expect("tempdir");
        let mut operations = FileExplorerOperations::new();
        let file = root.path().join(format!("draft-{}.txt", std::process::id()));
        std::fs::write(&file, "draft").expect("write");

        operations.trash(std::slice::from_ref(&file)).expect("trash");
        assert!(!file.exists());

        operations.undo();
        assert_eq!(read(&file), "draft");

        // Redo trashes it again; clean the trash up afterwards.
        operations.redo();
        assert!(!file.exists());
        operations.undo();
        std::fs::remove_file(&file).expect("cleanup");
    }

    #[test]
    fn undoing_a_creation_trashes_the_item_and_redo_brings_it_back() {
        let root = tempfile::tempdir().expect("tempdir");
        let bin = tempfile::tempdir().expect("bin");
        let mut operations = FileExplorerOperations::with_trash(Box::new(DirectoryTrash {
            directory: bin.path().to_path_buf(),
        }));
        let changed = Rc::new(RefCell::new(Vec::new()));
        let sink = changed.clone();
        operations.on_directories_changed = Some(Box::new(move |dirs| sink.borrow_mut().push(dirs.clone())));

        let created = operations.create_file("new.txt", root.path()).expect("create");
        assert!(created.exists());
        assert_eq!(operations.undo_action_name(), Some("New File"));
        assert!(operations.undo());
        assert!(!created.exists());
        assert_eq!(operations.redo_action_name(), Some("New File"));
        assert!(operations.redo());
        assert!(created.exists());
        assert!(!operations.can_redo());
        assert_eq!(changed.borrow().len(), 3);
        assert!(changed.borrow().iter().all(|dirs| dirs.contains(root.path())));
    }

    #[test]
    fn duplicating_copies_next_to_the_original_under_a_free_name() {
        let root = tempfile::tempdir().expect("tempdir");
        let mut operations = FileExplorerOperations::new();
        let file = root.path().join("notes.txt");
        std::fs::write(&file, "n").expect("write");

        assert_eq!(operations.duplicate(&file), Ok(root.path().join("notes copy.txt")));
        assert_eq!(operations.duplicate(&file), Ok(root.path().join("notes copy 2.txt")));
        assert_eq!(read(&root.path().join("notes copy 2.txt")), "n");
    }

    #[test]
    fn drops_from_outside_are_copied_under_a_free_name() {
        let root = tempfile::tempdir().expect("tempdir");
        let mut operations = FileExplorerOperations::new();
        let outside = root.path().join("outside");
        let inside = root.path().join("inside");
        std::fs::create_dir_all(&outside).expect("mkdir");
        std::fs::create_dir_all(&inside).expect("mkdir");
        let source = outside.join("logo.png");
        std::fs::write(&source, "png").expect("write");
        std::fs::write(inside.join("logo.png"), "old").expect("write");

        let copied = operations.copy_items(std::slice::from_ref(&source), &inside).expect("copy");

        assert_eq!(copied, [inside.join("logo copy.png")]);
        assert!(source.exists());
        assert_eq!(read(&inside.join("logo.png")), "old");
    }

    #[test]
    fn moves_report_each_item_so_editors_can_follow() {
        let root = tempfile::tempdir().expect("tempdir");
        let mut operations = FileExplorerOperations::new();
        let moves = Rc::new(RefCell::new(Vec::new()));
        let sink = moves.clone();
        operations.on_item_moved =
            Some(Box::new(move |from, to| sink.borrow_mut().push((from.to_path_buf(), to.to_path_buf()))));
        let file = root.path().join("a.txt");
        std::fs::write(&file, "").expect("write");

        let renamed = operations.rename(&file, "b.txt").expect("rename");
        operations.undo();

        assert_eq!(*moves.borrow(), [(file.clone(), renamed.clone()), (renamed, file)]);
    }
}
