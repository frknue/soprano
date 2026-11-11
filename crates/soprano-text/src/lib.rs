//! soprano-text: the UI-independent text logic behind Soprano's editor, diff and Markdown
//! views (see docs/rust-rewrite/PLAN.md). No gpui; every range is a UTF-8 byte range into the
//! text it describes, ready for GPUI text runs.

pub mod context_line;
pub mod diff;
pub mod editor;
pub mod editor_store;
pub mod find;
pub mod hunks;
pub mod markdown;
pub mod syntax;
pub mod watch;

pub use editor::EditorDocument;
pub use editor_store::{DocumentId, EditorDocumentStore};
pub use syntax::{CodeLanguage, SyntaxToken, SyntaxTokenKind};
