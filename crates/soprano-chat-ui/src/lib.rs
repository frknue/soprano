//! soprano-chat-ui: Soprano's chat in GPUI — the timeline of turns (also the Agent Dashboard's
//! transcript view) and the chat tab with its floating composer. See docs/rust-rewrite/PLAN.md.
//!
//! - [`TimelineView`]: the turns of any [`TimelineSource`] (a chat session, or a terminal
//!   agent's transcript through [`TranscriptSource`]).
//! - [`ChatView`]: a chat tab — timeline plus [`ComposerView`] over an `AgentChatSession`.
//! - [`ActivityLine`]: what an agent is doing right now, in one line.
//!
//! Windows showing these need gpui-component's `Root` (text selection, inputs) and
//! `soprano_ui::init`.

pub mod activity;
pub mod changed_file_tree;
pub mod chat_view;
pub mod composer;
pub mod composer_logic;
mod composer_parts;
pub mod format;
pub mod keys;
mod popovers;
mod row_views;
pub mod rows;
pub mod source;
pub mod timeline_view;
#[cfg(test)]
mod view_tests;
pub mod widgets;
pub mod work_log;

pub use activity::{ActivityLine, activity_parts};
pub use chat_view::{ChatView, ChatViewEvent};
pub use composer::{ComposerEvent, ComposerView};
pub use popovers::PopoverKind;
pub use rows::{TimelineExpansion, TimelineRow, TimelineRowContent, fold_label, timeline_rows};
pub use source::{SessionSource, SharedSession, TimelineSource, TranscriptSource};
pub use timeline_view::{TimelineEvent, TimelineView};
