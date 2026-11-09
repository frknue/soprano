//! soprano-dashboard: the Agent Dashboard (`AgentDashboardViewController.swift`) in GPUI with
//! Herdr's look.
//!
//! [`AgentDashboard`] lists every agent across the session's windows under Needs you /
//! Working / Ready / Stopped and shows the selected one's conversation (Claude Code, Codex,
//! OpenCode, omp transcripts in the chat timeline) or live terminal, with a reply line. It
//! reads the workspace entity and never mutates it: actions go out as [`DashboardEvent`]s.

pub mod keys;
pub mod state;
pub mod text;
mod view;

pub use keys::{KeyAction, ScrollAmount};
pub use state::{AgentList, DashboardEntry, TerminalText};
pub use view::{AgentDashboard, BranchProvider, DashboardEvent, DashboardHost, TerminalTextProvider};
