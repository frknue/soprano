//! JSON wire protocol shared between Soprano's mobile server and the embedded PWA.

use std::collections::BTreeMap;
use std::hash::{DefaultHasher, Hash, Hasher};

use serde::{Deserialize, Serialize};
use soprano_agents::{
    ApprovalDecision, ChatThread, Date, FileChangeKind, ToolCategory, Turn, TurnItem, TurnItemKind,
    TurnStatus, UserInputRequest, UserMessage,
};

/// Turns a thread request returns unless it asks for another number (`?turns=N`, 0 for all).
pub const DEFAULT_TURN_LIMIT: usize = 30;

/// A phone gets the end of long output and the start of long input; whole logs stay on the
/// desktop.
const TEXT_LIMIT: usize = 16 * 1024;
const DIFF_LIMIT: usize = 48 * 1024;

/// Active Soprano theme colors as CSS colors so the PWA matches the desktop. Each field is the
/// `Tokens` field of the same name.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MobileTheme {
    pub dark: bool,
    pub background: String,
    pub canvas: String,
    pub popover: String,
    pub raised: String,
    pub hover: String,
    pub border: String,
    pub foreground: String,
    pub muted: String,
    pub dim: String,
    pub accent: String,
    pub solid: String,
    pub solid_foreground: String,
    pub working: String,
    pub approval: String,
    pub input: String,
    pub failed: String,
    pub done: String,
    pub diff_add: String,
    pub diff_delete: String,
    pub diff_add_word: String,
    pub diff_delete_word: String,
    pub diff_add_foreground: String,
    pub diff_delete_foreground: String,
}

impl MobileTheme {
    /// `/theme.css`: the colors as CSS variables (`solid_foreground` → `--solid-foreground`) and
    /// `color-scheme`, so the first paint is themed before any script runs. Empty before the app
    /// published a theme: the stylesheet's own defaults apply.
    pub fn css(&self) -> String {
        if self.background.is_empty() {
            return String::new();
        }
        let mut css = format!(":root {{\n  color-scheme: {};\n", if self.dark { "dark" } else { "light" });
        if let Ok(serde_json::Value::Object(fields)) = serde_json::to_value(self) {
            for (name, value) in &fields {
                if let serde_json::Value::String(color) = value
                    && !color.is_empty()
                {
                    css.push_str(&format!("  --{}: {color};\n", name.replace('_', "-")));
                }
            }
        }
        css.push_str("}\n");
        css
    }
}

/// Top-level inbox snapshot pushed over REST (`GET /api/snapshot`) and WebSocket.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MobileSnapshot {
    pub host_name: String,
    pub theme: MobileTheme,
    pub threads: Vec<MobileThreadSummary>,
    pub projects: Vec<MobileProject>,
    pub agents: Vec<MobileAgentProfile>,
}

/// One agent thread row in the mobile inbox.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MobileThreadSummary {
    /// `pane_id:tab_id`.
    pub id: String,
    pub title: String,
    pub project: String,
    pub profile_id: String,
    pub profile_name: String,
    /// `"running" | "starting" | "waiting" | "error" | "idle" | "stopped"`
    pub status: String,
    /// `"needs_you" | "working" | "ready" | "stopped"`
    pub section: String,
    /// `"approval" | "question" | "turn"` while `status` is `"waiting"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub waiting_reason: Option<String>,
    pub needs_attention: bool,
    pub is_chat: bool,
    pub accepts_replies: bool,
    /// The tab is the agent's own, so it can be stopped and restarted from here.
    pub can_stop: bool,
    pub can_restart: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
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
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MobileThreadDetail {
    pub summary: MobileThreadSummary,
    /// The agent's transcript is still being read: `turns` arrive with the next update.
    pub loading: bool,
    /// Notices from before the first turn.
    pub preamble: Vec<MobileTurnItem>,
    /// Turns before `turns` that the request's limit left out.
    pub earlier_turns: usize,
    pub turns: Vec<MobileTurn>,
    pub options: Vec<MobileConfigOption>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_approval: Option<MobileApproval>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_input: Option<MobileUserInput>,
    pub queued_prompts: Vec<String>,
}

impl MobileThreadDetail {
    /// Identifies this exact content: a phone that already shows it is told "unchanged"
    /// instead of getting the conversation again.
    pub fn revision(&self) -> u64 {
        let mut hasher = DefaultHasher::new();
        self.hash(&mut hasher);
        hasher.finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MobileTurn {
    pub id: String,
    /// Empty for a turn whose message fell off the transcript's head.
    pub user_text: String,
    /// `"running" | "completed" | "interrupted" | "failed"`
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure_message: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at_ms: Option<i64>,
    /// Stop was pressed; the turn says "Stopping…" until it ends.
    pub stopping: bool,
    /// The activity log in arrival order, steered messages among it.
    pub items: Vec<MobileTurnItem>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum MobileTurnItem {
    AssistantMessage {
        id: String,
        status: String,
        text: String,
        is_final: bool,
    },
    Reasoning {
        id: String,
        status: String,
        text: String,
    },
    Command {
        id: String,
        status: String,
        command: String,
        output: String,
        exit_code: Option<i64>,
    },
    FileChange {
        id: String,
        status: String,
        files: Vec<MobileFileChange>,
    },
    ToolCall {
        id: String,
        status: String,
        name: String,
        /// `"read" | "search" | "subagent" | "other"`
        category: String,
        title: String,
        input: Option<String>,
        output: Option<String>,
    },
    WebSearch {
        id: String,
        status: String,
        query: String,
    },
    /// An approval the person answered; a pending one is the thread's `pending_approval`.
    Approval {
        id: String,
        status: String,
        title: String,
        detail: String,
        /// `"accept" | "accept_for_session" | "decline" | "cancel"`
        decision: String,
    },
    /// Questions the person answered or dismissed; pending ones are the thread's
    /// `pending_input`.
    UserInput {
        id: String,
        status: String,
        dismissed: bool,
        answers: Vec<MobileAnswer>,
    },
    /// A message sent into the running turn.
    Steer {
        id: String,
        text: String,
    },
    Error {
        id: String,
        status: String,
        message: String,
    },
    Notice {
        id: String,
        status: String,
        text: String,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MobileFileChange {
    pub path: String,
    /// `"add" | "delete" | "update" | "move"`
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub move_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diff: Option<String>,
    /// `diff` is the file's whole new content (a write), not a change against the old file.
    pub is_full_content: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MobileAnswer {
    pub question: String,
    pub answer: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MobileConfigOption {
    pub id: String,
    pub name: String,
    pub current_value: String,
    pub values: Vec<MobileConfigOptionValue>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MobileConfigOptionValue {
    pub value: String,
    pub name: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MobileApproval {
    pub title: String,
    /// What is being approved: the command line or the tool's title.
    pub detail: String,
    /// `detail` is a command line.
    pub is_command: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    pub options: Vec<MobileApprovalOption>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MobileApprovalOption {
    pub id: String,
    pub label: String,
    /// `allow_once`, `allow_always`, `reject_once` or `reject_always`.
    pub kind: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MobileUserInput {
    pub questions: Vec<MobileUserQuestion>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MobileUserQuestion {
    pub id: String,
    /// Short chip text ("Fix approach"); may be empty.
    pub header: String,
    pub prompt: String,
    pub options: Vec<MobileUserQuestionOption>,
    pub allows_multiple: bool,
    /// A typed answer is allowed besides the options.
    pub allows_other: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MobileUserQuestionOption {
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// Server-to-client WebSocket push messages.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerEvent {
    Snapshot {
        snapshot: Box<MobileSnapshot>,
    },
    ThreadUpdated {
        thread_id: String,
    },
    /// Sent on a quiet connection so the phone can tell it from a dead one.
    Ping,
}

/// Client-to-server WebSocket messages.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientEvent {
    /// The thread this phone shows (`None`: the inbox). Soprano announces changes of watched
    /// threads with [`ServerEvent::ThreadUpdated`].
    Watch { thread_id: Option<String> },
}

/// Request from the HTTP/WS server to Soprano's GPUI main thread.
#[derive(Debug)]
pub enum MobileAction {
    /// `turn_limit`: the newest turns to return, 0 for all.
    GetThread {
        thread_id: String,
        turn_limit: usize,
    },
    Reply {
        thread_id: String,
        text: String,
    },
    Approve {
        thread_id: String,
        option_id: String,
    },
    AnswerUserInput {
        thread_id: String,
        answers: BTreeMap<String, Vec<String>>,
    },
    DeclineUserInput {
        thread_id: String,
    },
    Stop {
        thread_id: String,
    },
    Restart {
        thread_id: String,
    },
    Cancel {
        thread_id: String,
    },
    SetOption {
        thread_id: String,
        id: String,
        value: String,
    },
    NewThread {
        profile_id: String,
        cwd: String,
        prompt: String,
        options: Vec<(String, String)>,
    },
}

/// Reply returned from Soprano's GPUI main thread to the awaiting HTTP handler.
#[derive(Debug)]
pub enum MobileActionResponse {
    Ok,
    /// `revision` is `detail.revision()`.
    Thread {
        detail: Box<MobileThreadDetail>,
        revision: u64,
    },
    Created {
        thread_id: String,
    },
    NotFound(String),
    Error(String),
}

/// Envelope delivered over `async_channel` from `soprano-mobile` into `MainView`.
#[derive(Debug)]
pub struct MobileCommand {
    pub action: MobileAction,
    pub reply: async_channel::Sender<MobileActionResponse>,
}

/// The newest `turn_limit` turns of `thread` (all of them for 0) in wire form, after the number
/// of turns left out before them.
pub fn turns_from_chat_thread(thread: &ChatThread, turn_limit: usize) -> (usize, Vec<MobileTurn>) {
    let earlier = if turn_limit == 0 { 0 } else { thread.turns.len().saturating_sub(turn_limit) };
    (earlier, thread.turns[earlier..].iter().map(mobile_turn).collect())
}

/// Activity items in wire form (a thread's preamble).
pub fn items_from_turn_items(items: &[TurnItem]) -> Vec<MobileTurnItem> {
    items.iter().filter_map(mobile_item).collect()
}

fn millis(date: Option<Date>) -> Option<i64> {
    date.map(|date| date.timestamp_millis())
}

fn mobile_turn(turn: &Turn) -> MobileTurn {
    let steer =
        |message: &UserMessage| MobileTurnItem::Steer { id: message.id.clone(), text: message.text.clone() };
    // A steer sits before the first item that started after it was sent.
    let mut items = Vec::with_capacity(turn.items.len() + turn.steers.len());
    let mut steers = turn.steers.iter().peekable();
    for item in &turn.items {
        while let Some(message) = steers.next_if(|message| {
            matches!((message.created_at, item.started_at), (Some(sent), Some(started)) if sent <= started)
        }) {
            items.push(steer(message));
        }
        items.extend(mobile_item(item));
    }
    items.extend(steers.map(steer));
    MobileTurn {
        id: turn.id.clone(),
        user_text: turn.user_message.text.clone(),
        status: match turn.status {
            TurnStatus::Running => "running",
            TurnStatus::Completed => "completed",
            TurnStatus::Interrupted => "interrupted",
            TurnStatus::Failed => "failed",
        }
        .to_owned(),
        failure_message: turn.failure_message.clone(),
        started_at_ms: millis(turn.started_at),
        completed_at_ms: millis(turn.completed_at),
        stopping: turn.stop_requested_at.is_some(),
        items,
    }
}

/// The start of `text`, cut at `limit` bytes.
fn clip_end(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.to_owned();
    }
    let mut end = limit;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}\n… cut here; the rest is on the desktop", &text[..end])
}

/// The end of `text`, cut to `limit` bytes.
fn clip_start(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.to_owned();
    }
    let mut start = text.len() - limit;
    while !text.is_char_boundary(start) {
        start += 1;
    }
    format!("… earlier output is on the desktop\n{}", &text[start..])
}

fn mobile_item(item: &TurnItem) -> Option<MobileTurnItem> {
    let status = item.status.as_str().to_owned();
    let id = item.id.clone();
    Some(match &item.kind {
        TurnItemKind::AssistantMessage { text, is_final } => {
            MobileTurnItem::AssistantMessage { id, status, text: text.clone(), is_final: *is_final }
        }
        TurnItemKind::Reasoning { text } => {
            MobileTurnItem::Reasoning { id, status, text: clip_end(text, TEXT_LIMIT) }
        }
        TurnItemKind::Command(command) => MobileTurnItem::Command {
            id,
            status,
            command: command.command.clone(),
            output: clip_start(&command.output, TEXT_LIMIT),
            exit_code: command.exit_code,
        },
        TurnItemKind::FileChange(changes) => MobileTurnItem::FileChange {
            id,
            status,
            files: changes
                .iter()
                .map(|change| MobileFileChange {
                    path: change.path.clone(),
                    kind: match change.kind {
                        FileChangeKind::Add => "add",
                        FileChangeKind::Delete => "delete",
                        FileChangeKind::Update => "update",
                        FileChangeKind::Move => "move",
                    }
                    .to_owned(),
                    move_path: change.move_path.clone(),
                    diff: change.diff.as_deref().map(|diff| clip_end(diff, DIFF_LIMIT)),
                    is_full_content: change.is_full_content == Some(true),
                })
                .collect(),
        },
        TurnItemKind::ToolCall(call) => {
            let clip = |text: &Option<String>| {
                text.as_deref().filter(|text| !text.trim().is_empty()).map(|text| clip_end(text, TEXT_LIMIT))
            };
            MobileTurnItem::ToolCall {
                id,
                status,
                name: call.name.clone(),
                category: match call.category {
                    ToolCategory::Read => "read",
                    ToolCategory::Search => "search",
                    ToolCategory::Subagent => "subagent",
                    ToolCategory::Other => "other",
                }
                .to_owned(),
                title: call.title.clone(),
                input: clip(&call.input),
                output: clip(&call.output),
            }
        }
        TurnItemKind::WebSearch { query } => MobileTurnItem::WebSearch { id, status, query: query.clone() },
        TurnItemKind::Approval(request) => MobileTurnItem::Approval {
            id,
            status,
            title: request.kind.title().to_owned(),
            detail: request.detail.clone(),
            decision: match request.decision? {
                ApprovalDecision::Accept => "accept",
                ApprovalDecision::AcceptForSession => "accept_for_session",
                ApprovalDecision::Decline => "decline",
                ApprovalDecision::Cancel => "cancel",
            }
            .to_owned(),
        },
        TurnItemKind::UserInput(request) => {
            if request.answers.is_none() && !request.dismissed {
                return None;
            }
            let answers = request.answers.as_ref().map_or_else(Vec::new, |answers| {
                request
                    .questions
                    .iter()
                    .map(|question| MobileAnswer {
                        question: question.question.clone(),
                        answer: answers.get(&question.id).map(|values| values.join(", ")).unwrap_or_default(),
                    })
                    .collect()
            });
            MobileTurnItem::UserInput { id, status, dismissed: request.dismissed, answers }
        }
        TurnItemKind::Error { message } => MobileTurnItem::Error { id, status, message: message.clone() },
        TurnItemKind::Notice { text } => MobileTurnItem::Notice { id, status, text: text.clone() },
    })
}

pub fn user_input_from_request(req: &UserInputRequest) -> MobileUserInput {
    MobileUserInput {
        questions: req
            .questions
            .iter()
            .map(|q| MobileUserQuestion {
                id: q.id.clone(),
                header: q.header.clone(),
                prompt: q.question.clone(),
                options: q
                    .options
                    .iter()
                    .map(|o| MobileUserQuestionOption {
                        label: o.label.clone(),
                        description: o.description.clone(),
                    })
                    .collect(),
                allows_multiple: q.allows_multiple,
                allows_other: q.allows_other,
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use soprano_agents::{TurnCommand, TurnItemStatus, date_from_millis};

    use super::*;

    fn turn(id: &str) -> Turn {
        let mut turn = Turn::new(id, UserMessage::new(id, format!("prompt {id}"), None));
        turn.status = TurnStatus::Completed;
        turn
    }

    #[test]
    fn a_turn_limit_keeps_the_newest_turns_and_counts_the_rest() {
        let thread = ChatThread { turns: vec![turn("a"), turn("b"), turn("c")], ..ChatThread::default() };

        let (earlier, turns) = turns_from_chat_thread(&thread, 2);
        assert_eq!(earlier, 1);
        assert_eq!(turns.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(), ["b", "c"]);

        let (earlier, turns) = turns_from_chat_thread(&thread, 0);
        assert_eq!((earlier, turns.len()), (0, 3));
    }

    #[test]
    fn a_steer_sits_before_the_first_item_started_after_it() {
        let item = |id: &str, at: f64| TurnItem {
            started_at: date_from_millis(at),
            ..TurnItem::with_status(
                id,
                TurnItemKind::Notice { text: id.to_owned() },
                TurnItemStatus::Completed,
            )
        };
        let mut running = turn("t");
        running.items = vec![item("first", 1_000.0), item("second", 3_000.0)];
        running.steers = vec![
            UserMessage::new("steer", "look at the tests", date_from_millis(2_000.0)),
            UserMessage::new("late", "and the docs", date_from_millis(9_000.0)),
        ];
        let thread = ChatThread { turns: vec![running], ..ChatThread::default() };

        let (_, turns) = turns_from_chat_thread(&thread, 0);
        let order: Vec<&str> = turns[0]
            .items
            .iter()
            .map(|item| match item {
                MobileTurnItem::Notice { id, .. } | MobileTurnItem::Steer { id, .. } => id.as_str(),
                other => panic!("unexpected item {other:?}"),
            })
            .collect();
        assert_eq!(order, ["first", "steer", "second", "late"]);
    }

    #[test]
    fn long_command_output_keeps_its_end() {
        let output = format!("{}\nlast line", "é".repeat(TEXT_LIMIT));
        let mut running = turn("t");
        running.items =
            vec![TurnItem::new("cmd", TurnItemKind::Command(TurnCommand::new("make", output, None)))];
        let thread = ChatThread { turns: vec![running], ..ChatThread::default() };

        let (_, turns) = turns_from_chat_thread(&thread, 0);
        let MobileTurnItem::Command { output, .. } = &turns[0].items[0] else { panic!("a command") };
        assert!(output.len() < TEXT_LIMIT + 64);
        assert!(output.starts_with("… earlier output"));
        assert!(output.ends_with("last line"));
    }

    #[test]
    fn the_revision_follows_the_content() {
        let detail = |text: &str| MobileThreadDetail {
            summary: MobileThreadSummary {
                id: "pane:tab".into(),
                title: "Fix the build".into(),
                project: "soprano".into(),
                profile_id: "omp".into(),
                profile_name: "omp".into(),
                status: "running".into(),
                section: "working".into(),
                waiting_reason: None,
                needs_attention: false,
                is_chat: true,
                accepts_replies: true,
                can_stop: true,
                can_restart: true,
                branch: None,
                since_ms: 0,
            },
            loading: false,
            preamble: Vec::new(),
            earlier_turns: 0,
            turns: Vec::new(),
            options: Vec::new(),
            pending_approval: None,
            pending_input: None,
            queued_prompts: vec![text.to_owned()],
        };
        assert_eq!(detail("a").revision(), detail("a").revision());
        assert_ne!(detail("a").revision(), detail("b").revision());
    }

    #[test]
    fn the_theme_css_names_tokens_in_kebab_case_and_is_empty_before_a_theme_is_known() {
        assert_eq!(MobileTheme::default().css(), "");
        let theme = MobileTheme {
            dark: true,
            background: "#101010".into(),
            solid_foreground: "#0b0b0b".into(),
            ..MobileTheme::default()
        };
        let css = theme.css();
        assert!(css.contains("color-scheme: dark;"));
        assert!(css.contains("--background: #101010;"));
        assert!(css.contains("--solid-foreground: #0b0b0b;"));
        assert!(!css.contains("--canvas"));
    }
}
