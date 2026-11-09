//! soprano-git: git status, Source Control changes and diffs, branch monitoring, and the
//! Soprano Git launcher. Shells out to the `git` CLI; no gpui.

pub mod branch;
pub mod changes;
pub mod launcher;
pub mod natural;
pub mod reader;
pub mod status;

pub use branch::GitBranchMonitor;
pub use changes::{
    GitChange, GitChangeArea, GitChangeList, GitDiffHighlights, GitDiffLayout, GitDiffLine, GitDiffLineKind,
    GitDiffRow, GitDiffRowKind, GitDiffToken, GitFileDiff, GitLineCounts,
};
pub use status::{GitFileStatus, GitStatusSnapshot};
