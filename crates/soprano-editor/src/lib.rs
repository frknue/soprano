//! soprano-editor: Soprano's file surfaces in GPUI over soprano-text's models.
//!
//! - [`rich`]: rendered Markdown, selectable styled text with links, code blocks and diff
//!   rows, shared by the chat, the Automations run detail and the views below.
//! - [`EditorView`] (with [`EditorDocuments`], the documents shared by every tab), the
//!   [`DiffView`] and the [`MarkdownReaderView`].
//! - [`colors`]: the theme colors and syntax color maps those draw with.

pub mod colors;
pub mod diff_view;
pub mod documents;
pub mod editor;
pub mod http;
pub mod keys;
pub mod reader;
pub mod rich;
pub mod surface;

pub use colors::SurfaceColors;
pub use diff_view::{DiffEvent, DiffView};
pub use documents::{DocumentsEvent, EditorDocuments, TextEdit};
pub use editor::{EditorEvent, EditorView};
pub use http::install_http_client;
pub use reader::{MarkdownReaderView, ReaderEvent};
