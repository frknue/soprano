//! Reusable rich elements: rendered Markdown (chat answers, the reader, automation run
//! details), selectable styled text with links, code blocks, and diff rows.

pub mod code;
pub mod diff;
pub mod inline;
pub mod markdown;
pub mod text;

pub use code::CodeBlock;
pub use diff::{
    DiffFoldRow, DiffLineRow, DiffRowLayout, DiffSplitRow, DiffStat, HunkDiff, hunk_side, number_width,
    styled_highlights,
};
pub use markdown::{Markdown, MarkdownBlocks, MarkdownStyle, ReaderDocument, anchor_block, opens_externally};
pub use text::{LinkHandler, RichText};
