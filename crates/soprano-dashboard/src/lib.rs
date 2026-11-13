//! soprano-dashboard: the Agent Dashboard in GPUI, laid out like Soprano Agents.
//!
//! [`AgentDashboard`] lists every agent across the workspace's windows as threads under
//! Needs you / Working / Ready / Stopped and shows the open one as a chat: its conversation
//! (Claude Code, Codex, OpenCode, omp transcripts in the chat timeline) over a floating
//! composer. A new thread is drafted in the same place, for a project and an agent. It reads
//! the workspace entity and never mutates it: actions go out as [`DashboardEvent`]s.

pub mod attachments;
pub mod keys;
pub mod state;
mod view;

pub use attachments::Attachment;
pub use keys::{KeyAction, KeyFocus, ScrollAmount};
pub use state::{AgentChoice, AgentList, DashboardEntry, ListRow, ProjectChoice, ThreadOption};
pub use view::{
    AgentDashboard, BranchProvider, DashboardEvent, DashboardHost, DraftOptionsProvider, ProjectsProvider,
    RepliesProvider, ThreadOptionsProvider,
};
