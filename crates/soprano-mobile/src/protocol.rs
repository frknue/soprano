//! JSON wire protocol shared between Soprano's mobile server and the embedded PWA.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use soprano_agents::{ApprovalRequest, ChatThread, TurnItem, TurnItemKind, UserInputRequest};

/// Active Soprano theme colors serialized as CSS hex strings so the PWA matches the desktop.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MobileTheme {
    pub canvas: String,
    pub surface: String,
    pub raised: String,
    pub hover: String,
    pub border: String,
    pub foreground: String,
    pub muted: String,
    pub dim: String,
    pub accent: String,
    pub working: String,
    pub approval: String,
    pub input: String,
    pub failed: String,
    pub done: String,
}

/// Top-level inbox snapshot pushed over REST (`GET /api/snapshot`) and WebSocket.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MobileSnapshot {
    pub version: u64,
    pub host_name: String,
    pub theme: MobileTheme,
    pub threads: Vec<MobileThreadSummary>,
    pub projects: Vec<MobileProject>,
    pub agents: Vec<MobileAgentProfile>,
}

/// One agent thread card in the mobile inbox.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MobileThreadSummary {
    pub id: String,
    pub pane_id: String,
    pub tab_id: String,
    pub title: String,
    pub project: String,
    pub profile_id: String,
    pub profile_name: String,
    /// `"running" | "starting" | "waiting" | "error" | "idle" | "stopped"`
    pub status: String,
    /// `"needs_you" | "working" | "ready" | "stopped"`
    pub section: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waiting_reason: Option<String>,
    pub needs_attention: bool,
    pub is_chat: bool,
    pub accepts_replies: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_name: Option<String>,
    pub window_title: String,
    /// Unix epoch milliseconds when the agent entered its current status.
    pub since_ms: i64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MobileProject {
    pub name: String,
    pub path: String,
    pub display_path: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MobileAgentProfile {
    pub id: String,
    pub name: String,
}

/// Full conversation state for one open thread (`GET /api/threads/{id}`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MobileThreadDetail {
    pub summary: MobileThreadSummary,
    pub turns: Vec<MobileTurn>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase: Option<String>,
    #[serde(default)]
    pub options: Vec<MobileConfigOption>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_approval: Option<MobileApproval>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_input: Option<MobileUserInput>,
    #[serde(default)]
    pub queued_prompts: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MobileTurn {
    pub id: String,
    pub user_text: String,
    pub items: Vec<MobileTurnItem>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum MobileTurnItem {
    AssistantMessage { id: String, status: String, text: String, is_final: bool },
    Reasoning { id: String, status: String, text: String },
    Command { id: String, status: String, command: String, output: String, exit_code: Option<i64> },
    FileChange { id: String, status: String, files: Vec<MobileFileChange> },
    ToolCall { id: String, status: String, name: String, title: String, detail: Option<String> },
    WebSearch { id: String, status: String, query: String },
    Error { id: String, status: String, message: String },
    Notice { id: String, status: String, text: String },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MobileFileChange {
    pub path: String,
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diff: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MobileConfigOption {
    pub id: String,
    pub name: String,
    pub current_value: String,
    pub values: Vec<MobileConfigOptionValue>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MobileConfigOptionValue {
    pub value: String,
    pub name: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MobileApproval {
    pub id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    pub options: Vec<MobileApprovalOption>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MobileApprovalOption {
    pub id: String,
    pub label: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MobileUserInput {
    pub id: String,
    pub questions: Vec<MobileUserQuestion>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MobileUserQuestion {
    pub id: String,
    pub prompt: String,
    pub options: Vec<MobileUserQuestionOption>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MobileUserQuestionOption {
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// Server-to-client WebSocket push messages.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerEvent {
    Snapshot { snapshot: Box<MobileSnapshot> },
    ThreadUpdated { thread_id: String },
}

/// Request from the HTTP/WS server to Soprano's GPUI main thread.
#[derive(Debug)]
pub enum MobileAction {
    GetThread { thread_id: String },
    Reply { thread_id: String, text: String },
    Approve { thread_id: String, option_id: String },
    AnswerUserInput { thread_id: String, answers: BTreeMap<String, Vec<String>> },
    DeclineUserInput { thread_id: String },
    Stop { thread_id: String },
    Restart { thread_id: String },
    Cancel { thread_id: String },
    SetOption { thread_id: String, id: String, value: String },
    NewThread { profile_id: String, cwd: String, prompt: String, options: Vec<(String, String)> },
}

/// Reply returned from Soprano's GPUI main thread to the awaiting HTTP handler.
#[derive(Debug)]
pub enum MobileActionResponse {
    Ok,
    Thread(Box<MobileThreadDetail>),
    Created { thread_id: String },
    NotFound(String),
    Error(String),
}

/// Envelope delivered over `async_channel` from `soprano-mobile` into `MainView`.
#[derive(Debug)]
pub struct MobileCommand {
    pub action: MobileAction,
    pub reply: async_channel::Sender<MobileActionResponse>,
}

/// Converts a `soprano_agents::ChatThread` into wire-ready [`MobileTurn`]s.
pub fn turns_from_chat_thread(thread: &ChatThread) -> Vec<MobileTurn> {
    thread
        .turns
        .iter()
        .map(|turn| MobileTurn {
            id: turn.id.clone(),
            user_text: turn.user_message.text.clone(),
            items: turn.items.iter().filter_map(mobile_item_from_turn_item).collect(),
        })
        .collect()
}

fn mobile_item_from_turn_item(item: &TurnItem) -> Option<MobileTurnItem> {
    let status = item.status.as_str().to_owned();
    let id = item.id.clone();
    match &item.kind {
        TurnItemKind::AssistantMessage { text, is_final } => {
            Some(MobileTurnItem::AssistantMessage { id, status, text: text.clone(), is_final: *is_final })
        }
        TurnItemKind::Reasoning { text } => {
            Some(MobileTurnItem::Reasoning { id, status, text: text.clone() })
        }
        TurnItemKind::Command(cmd) => Some(MobileTurnItem::Command {
            id,
            status,
            command: cmd.command.clone(),
            output: cmd.output.clone(),
            exit_code: cmd.exit_code,
        }),
        TurnItemKind::FileChange(changes) => Some(MobileTurnItem::FileChange {
            id,
            status,
            files: changes
                .iter()
                .map(|c| MobileFileChange {
                    path: c.path.clone(),
                    kind: match c.kind {
                        soprano_agents::FileChangeKind::Add => "add",
                        soprano_agents::FileChangeKind::Delete => "delete",
                        soprano_agents::FileChangeKind::Update => "update",
                        soprano_agents::FileChangeKind::Move => "move",
                    }
                    .to_owned(),
                    diff: c.diff.clone(),
                })
                .collect(),
        }),
        TurnItemKind::ToolCall(call) => {
            let detail = [call.input.as_deref(), call.output.as_deref()]
                .into_iter()
                .flatten()
                .filter(|s| !s.trim().is_empty())
                .collect::<Vec<_>>()
                .join("\n\n");
            Some(MobileTurnItem::ToolCall {
                id,
                status,
                name: call.name.clone(),
                title: call.title.clone(),
                detail: (!detail.is_empty()).then_some(detail),
            })
        }
        TurnItemKind::WebSearch { query } => {
            Some(MobileTurnItem::WebSearch { id, status, query: query.clone() })
        }
        TurnItemKind::Error { message } => {
            Some(MobileTurnItem::Error { id, status, message: message.clone() })
        }
        TurnItemKind::Notice { text } => Some(MobileTurnItem::Notice { id, status, text: text.clone() }),
        // Approvals and user-input cards are rendered as interactive action cards from
        // `pending_approval` / `pending_input` when active.
        TurnItemKind::Approval(_) | TurnItemKind::UserInput(_) => None,
    }
}

pub fn approval_from_request(req: &ApprovalRequest) -> MobileApproval {
    let title = req.kind.title().to_owned();
    let detail = [Some(req.detail.as_str()), req.reason.as_deref()]
        .into_iter()
        .flatten()
        .filter(|s| !s.trim().is_empty())
        .collect::<Vec<_>>()
        .join("\n\n");
    MobileApproval {
        id: req.id.clone(),
        title,
        detail: (!detail.is_empty()).then_some(detail),
        options: req
            .options
            .iter()
            .map(|o| MobileApprovalOption { id: o.id.clone(), label: o.name.clone() })
            .collect(),
    }
}

pub fn user_input_from_request(req: &UserInputRequest) -> MobileUserInput {
    MobileUserInput {
        id: req.id.clone(),
        questions: req
            .questions
            .iter()
            .map(|q| MobileUserQuestion {
                id: q.id.clone(),
                prompt: q.question.clone(),
                options: q
                    .options
                    .iter()
                    .map(|o| MobileUserQuestionOption {
                        label: o.label.clone(),
                        description: o.description.clone(),
                    })
                    .collect(),
            })
            .collect(),
    }
}
