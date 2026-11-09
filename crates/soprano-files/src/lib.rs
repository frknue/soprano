//! soprano-files: the file explorer's model — project root resolution, lazy listing,
//! visibility toggles, the find-files filter, keyboard/drag rules, file operations with
//! undo/redo, and a recursive file-system watcher. No gpui.

pub mod listing;
pub mod operations;
pub mod root;
pub mod trash;
pub mod tree;
pub mod watcher;

pub use listing::FileExplorerEntry;
pub use operations::{FileExplorerOperations, OperationError};
pub use root::{ExplorerPreferences, ExplorerRoot, explorer_root};
pub use tree::{FileExplorerNode, FileExplorerTree, VisibilityRules, VisibleRow};
pub use watcher::FileSystemWatcher;
