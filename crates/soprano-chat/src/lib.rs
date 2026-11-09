//! soprano-chat: chat tabs' Agent Client Protocol client — stdio JSON-RPC 2.0 with the agent's
//! process, the ACP session (`omp acp`), and folding its updates into the chat's turns. No UI;
//! see docs/rust-rewrite/PLAN.md.
//!
//! The turn model ([`ChatThread`], [`Turn`], [`TurnItem`], …), `JsonValue` and the omp edit
//! preview live in `soprano-agents` (the dashboard renders terminal agents' transcripts with
//! the same model) and are re-exported here.

pub mod rpc;
pub mod session;
pub mod turn_builder;

pub use rpc::{JsonRpcConnection, JsonRpcError, JsonRpcPeer, LineSplitter, PeerEvent, PeerSink, StderrTail};
pub use session::{
    AgentChatCommand, AgentChatConfigOption, AgentChatEvent, AgentChatLaunch, AgentChatPermission,
    AgentChatPlanEntry, AgentChatQuestion, AgentChatSession, ChatInteraction, ChatPhase, ConfigOptionValue,
    LaunchSpec, PlanEntryStatus, QuestionChoice, QuestionField,
};
pub use soprano_agents::chat_turns::*;
pub use soprano_agents::{JsonValue, JsonValueExt, omp_edit_changes};
pub use turn_builder::{
    ACP_DIFF_CONTEXT, AcpToolStyle, AcpTurnBuilder, acp_unified_diff, argument_path, content_text,
    input_text, relative_path, text_of, unified_diff,
};
