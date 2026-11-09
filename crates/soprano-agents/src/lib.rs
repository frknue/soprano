//! soprano-agents: reading agent CLIs' own transcripts (Claude Code, Codex, omp, OpenCode) into
//! one timeline, following them for the Agent Dashboard, the chat's turn model, and the
//! dashboard's snapshot and grouping. No UI; see docs/rust-rewrite/PLAN.md.

pub mod activity;
pub mod chat_turns;
pub mod claude;
pub mod codex;
pub mod dashboard;
pub mod json;
pub mod omp;
pub mod omp_edit_preview;
pub mod opencode;
pub mod opencode_reader;
pub mod store;
pub mod timeline;
pub mod transcript_thread;

pub use activity::{ActivityTone, AgentTimelineActivity, activity_duration};
pub use chat_turns::{
    ApprovalDecision, ApprovalKind, ApprovalOption, ApprovalOptions, ApprovalRequest, ChangedFileStat,
    ChatThread, FileChange, FileChangeKind, ToolCall, ToolCategory, Turn, TurnCommand, TurnItem,
    TurnItemKind, TurnItemStatus, TurnStatus, UserInputOption, UserInputQuestion, UserInputRequest,
    UserMessage, diff_line_count, turn_duration_text,
};
pub use claude::ClaudeTranscriptDecoder;
pub use codex::CodexRolloutDecoder;
pub use dashboard::{
    AgentDashboardEntry, AgentDashboardSection, AgentDashboardSnapshot, DashboardEntryStatus, elapsed_text,
};
pub use json::{JsonValue, JsonValueExt};
pub use omp::OmpSessionDecoder;
pub use omp_edit_preview::omp_edit_changes;
pub use opencode::{OpenCodeMessageDecoder, PartRow};
pub use opencode_reader::OpenCodeTranscriptReader;
pub use store::{
    AgentTranscriptLocator, AgentTranscriptReader, AgentTranscriptSource, AgentTranscriptStore,
    TranscriptFollower,
};
pub use timeline::{
    AgentTimeline, AgentTimelineItem, AgentToolCall, AgentToolResult, AgentTranscriptDecoding,
    AgentTranscriptEntry, AgentTranscriptFormat, Date, TimelineItemKind, ToolCallState, date_from_millis,
    date_from_value, diff_excerpt, display_path, excerpt, first_line, first_line_limited, parse_date,
};
