//! The chat's conversation as turns (`ChatTurns.swift`), ported from Soprano Agents' turn model
//! (`SopranoAgentsCore/Models/{Threads,TurnItems}.swift`): each message the person sends starts
//! a turn, and everything the agent does until it ends — prose, reasoning, commands, edits,
//! other tools, approvals, questions — lands in that turn's items in arrival order.
//! `ACPTurnBuilder` folds an agent's ACP `session/update`s into it; the chat tab renders it.
//!
//! Times are optional: a conversation reopened with `session/load` replays its history without
//! them.

use std::collections::{BTreeMap, HashMap};
use std::time::Duration;

use crate::timeline::Date;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TurnItemStatus {
    Pending,
    Running,
    Completed,
    Failed,
    /// The person declined it (approval).
    Declined,
    /// The turn ended while the item ran.
    Interrupted,
}

impl TurnItemStatus {
    pub fn is_active(self) -> bool {
        matches!(self, Self::Pending | Self::Running)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Running => "running",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Declined => "declined",
            Self::Interrupted => "interrupted",
        }
    }
}

/// One entry of a turn's activity log.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct TurnItem {
    pub id: String,
    pub kind: TurnItemKind,
    pub status: TurnItemStatus,
    pub started_at: Option<Date>,
    pub completed_at: Option<Date>,
}

impl TurnItem {
    /// An item that is running, with no times.
    pub fn new(id: impl Into<String>, kind: TurnItemKind) -> Self {
        Self { id: id.into(), kind, status: TurnItemStatus::Running, started_at: None, completed_at: None }
    }

    pub fn with_status(id: impl Into<String>, kind: TurnItemKind, status: TurnItemStatus) -> Self {
        Self { status, ..Self::new(id, kind) }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum TurnItemKind {
    /// Assistant prose (Markdown). `is_final`: the turn's answer; false: commentary between tools.
    AssistantMessage {
        text: String,
        is_final: bool,
    },
    /// Reasoning ("Thinking").
    Reasoning {
        text: String,
    },
    /// Shell command. `output` grows while it runs.
    Command(TurnCommand),
    /// File edits (one call may touch several files).
    FileChange(Vec<FileChange>),
    /// Any other tool: read, search, subagents, the rest.
    ToolCall(ToolCall),
    WebSearch {
        query: String,
    },
    Approval(ApprovalRequest),
    UserInput(UserInputRequest),
    Error {
        message: String,
    },
    /// Informational divider ("Context compacted").
    Notice {
        text: String,
    },
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct TurnCommand {
    pub command: String,
    pub output: String,
    pub exit_code: Option<i64>,
}

impl TurnCommand {
    pub fn new(command: impl Into<String>, output: impl Into<String>, exit_code: Option<i64>) -> Self {
        Self { command: command.into(), output: output.into(), exit_code }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FileChangeKind {
    Add,
    Delete,
    Update,
    Move,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct FileChange {
    pub path: String,
    pub kind: FileChangeKind,
    /// Destination of a move.
    pub move_path: Option<String>,
    /// Unified diff of this file when the agent reports one.
    pub diff: Option<String>,
    /// `diff` is the file's whole new content (a write), not a change against the old file.
    pub is_full_content: Option<bool>,
}

impl FileChange {
    pub fn new(path: impl Into<String>, kind: FileChangeKind) -> Self {
        Self { path: path.into(), kind, move_path: None, diff: None, is_full_content: None }
    }

    pub fn with_diff(path: impl Into<String>, kind: FileChangeKind, diff: Option<String>) -> Self {
        Self { diff, ..Self::new(path, kind) }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ToolCategory {
    /// Read a file.
    Read,
    /// grep / glob / find.
    Search,
    Subagent,
    Other,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ToolCall {
    /// The agent's tool name ("read", "grep", "lsp").
    pub name: String,
    pub category: ToolCategory,
    /// One-line label for the work log ("Read Sources/App.swift").
    pub title: String,
    /// Pretty-printed input, shown when the row opens.
    pub input: Option<String>,
    pub output: Option<String>,
}

impl ToolCall {
    pub fn new(name: impl Into<String>, category: ToolCategory, title: impl Into<String>) -> Self {
        Self { name: name.into(), category, title: title.into(), input: None, output: None }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ApprovalKind {
    Command,
    FileChange,
    FileRead,
    Other,
}

impl ApprovalKind {
    pub fn title(self) -> &'static str {
        match self {
            Self::Command => "Command approval",
            Self::FileChange => "File change approval",
            Self::FileRead => "File read approval",
            Self::Other => "Approval",
        }
    }

    /// The kind of a tool the agent asks to run, by its ACP `kind`.
    pub fn of_acp_kind(acp_kind: Option<&str>) -> Self {
        match acp_kind {
            Some("execute") => Self::Command,
            Some("edit" | "delete" | "move") => Self::FileChange,
            Some("read" | "search") => Self::FileRead,
            _ => Self::Other,
        }
    }
}

/// How the person answered an approval.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ApprovalDecision {
    Accept,
    AcceptForSession,
    Decline,
    Cancel,
}

impl ApprovalDecision {
    /// The decision an ACP permission option kind stands for.
    pub fn of_option_kind(option_kind: &str) -> Self {
        match option_kind {
            "allow_always" => Self::AcceptForSession,
            "allow_once" => Self::Accept,
            other if other.starts_with("allow") => Self::Accept,
            _ => Self::Decline,
        }
    }
}

/// The agent wants permission. Lives in the activity log as `Approval`; `decision` is set once
/// answered.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ApprovalRequest {
    pub id: String,
    pub kind: ApprovalKind,
    /// What is being approved: the command line or the tool's title.
    pub detail: String,
    /// Why the agent asks, when it says.
    pub reason: Option<String>,
    /// The answers the agent offers.
    pub options: Vec<ApprovalOption>,
    pub decision: Option<ApprovalDecision>,
}

/// One answer an ACP permission request offers.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ApprovalOption {
    pub id: String,
    pub name: String,
    /// `allow_once`, `allow_always`, `reject_once` or `reject_always`.
    pub kind: String,
}

impl ApprovalOption {
    pub fn new(id: impl Into<String>, name: impl Into<String>, kind: impl Into<String>) -> Self {
        Self { id: id.into(), name: name.into(), kind: kind.into() }
    }

    pub fn allows(&self) -> bool {
        self.kind.starts_with("allow")
    }
}

/// Picking answers among an approval's options.
pub trait ApprovalOptions {
    /// What Approve picks: allow once, else any allow.
    fn approve_option(&self) -> Option<&ApprovalOption>;
    /// What Decline picks: reject once, else any reject.
    fn decline_option(&self) -> Option<&ApprovalOption>;
    /// Every other answer ("Always allow"), for the More menu.
    fn more_options(&self) -> Vec<&ApprovalOption>;
}

impl ApprovalOptions for [ApprovalOption] {
    fn approve_option(&self) -> Option<&ApprovalOption> {
        self.iter().find(|o| o.kind == "allow_once").or_else(|| self.iter().find(|o| o.allows()))
    }

    fn decline_option(&self) -> Option<&ApprovalOption> {
        self.iter().find(|o| o.kind == "reject_once").or_else(|| self.iter().find(|o| !o.allows()))
    }

    fn more_options(&self) -> Vec<&ApprovalOption> {
        let approve = self.approve_option();
        let decline = self.decline_option();
        self.iter().filter(|o| Some(*o) != approve && Some(*o) != decline).collect()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct UserInputOption {
    pub label: String,
    pub description: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct UserInputQuestion {
    pub id: String,
    /// Short chip text ("Fix approach").
    pub header: String,
    pub question: String,
    pub options: Vec<UserInputOption>,
    pub allows_multiple: bool,
    /// A typed answer is allowed besides the options.
    pub allows_other: bool,
}

/// The agent asks structured questions.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct UserInputRequest {
    pub id: String,
    pub questions: Vec<UserInputQuestion>,
    /// Question id → chosen labels or typed text; `None` until answered.
    pub answers: Option<BTreeMap<String, Vec<String>>>,
    pub dismissed: bool,
}

/// What the person sent to start, or steer, a turn.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct UserMessage {
    pub id: String,
    pub text: String,
    pub created_at: Option<Date>,
}

impl UserMessage {
    pub fn new(id: impl Into<String>, text: impl Into<String>, created_at: Option<Date>) -> Self {
        Self { id: id.into(), text: text.into(), created_at }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TurnStatus {
    Running,
    Completed,
    Interrupted,
    Failed,
}

/// One run of the agent, started by a message.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Turn {
    pub id: String,
    pub user_message: UserMessage,
    pub status: TurnStatus,
    pub failure_message: Option<String>,
    pub started_at: Option<Date>,
    pub completed_at: Option<Date>,
    /// Activity log in arrival order.
    pub items: Vec<TurnItem>,
    /// Messages steered into the turn while it ran.
    pub steers: Vec<UserMessage>,
    /// When the person pressed Stop; the turn says "Stopping…" until it ends.
    pub stop_requested_at: Option<Date>,
}

impl Turn {
    /// A running turn with no items.
    pub fn new(id: impl Into<String>, user_message: UserMessage) -> Self {
        Self {
            id: id.into(),
            user_message,
            status: TurnStatus::Running,
            failure_message: None,
            started_at: None,
            completed_at: None,
            items: Vec::new(),
            steers: Vec::new(),
            stop_requested_at: None,
        }
    }

    pub fn is_running(&self) -> bool {
        self.status == TurnStatus::Running
    }

    /// Wall time of the turn ("Worked for 3m 12s"); `None` for a replayed turn.
    pub fn duration(&self, now: Date) -> Option<Duration> {
        let started = self.started_at?;
        let end = self.completed_at.unwrap_or(now);
        Some((end - started).to_std().unwrap_or(Duration::ZERO))
    }

    /// Like [`duration`](Self::duration), in seconds, negative when the clock went backwards.
    pub fn duration_seconds(&self, now: Date) -> Option<f64> {
        let started = self.started_at?;
        let end = self.completed_at.unwrap_or(now);
        Some((end - started).num_microseconds().unwrap_or(0) as f64 / 1_000_000.0)
    }

    pub fn pending_approval(&self) -> Option<&ApprovalRequest> {
        self.items.iter().rev().find_map(|item| match &item.kind {
            TurnItemKind::Approval(request) if request.decision.is_none() => Some(request),
            _ => None,
        })
    }

    /// Files the turn's finished edits changed, with the lines their diffs add and remove.
    pub fn changed_files(&self) -> Vec<ChangedFileStat> {
        let mut order: Vec<String> = Vec::new();
        let mut stats: HashMap<String, ChangedFileStat> = HashMap::new();
        for item in self.items.iter().filter(|i| i.status == TurnItemStatus::Completed) {
            let TurnItemKind::FileChange(changes) = &item.kind else { continue };
            for change in changes {
                let path = change.move_path.as_deref().unwrap_or(&change.path);
                if path.is_empty() {
                    continue;
                }
                let (additions, deletions) = diff_line_count(change.diff.as_deref().unwrap_or(""));
                let stat = stats.entry(path.to_owned()).or_insert_with(|| {
                    order.push(path.to_owned());
                    ChangedFileStat { path: path.to_owned(), additions: 0, deletions: 0 }
                });
                stat.additions += additions;
                stat.deletions += if change.is_full_content == Some(true) { 0 } else { deletions };
            }
        }
        order.into_iter().filter_map(|p| stats.remove(&p)).collect()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ChangedFileStat {
    pub path: String,
    pub additions: usize,
    pub deletions: usize,
}

impl ChangedFileStat {
    pub fn id(&self) -> &str {
        &self.path
    }
}

/// Lines a unified diff adds and removes (hunk headers and file headers aside).
pub fn diff_line_count(diff: &str) -> (usize, usize) {
    let mut additions = 0;
    let mut deletions = 0;
    for line in diff.split('\n') {
        if line.starts_with("+++") || line.starts_with("---") {
            continue;
        }
        if line.starts_with('+') {
            additions += 1;
        } else if line.starts_with('-') {
            deletions += 1;
        }
    }
    (additions, deletions)
}

/// The chat's conversation: notices from before the first turn, the turns, and the messages
/// waiting for the running turn.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct ChatThread {
    /// Notices with no turn to belong to ("Could not reopen the conversation").
    pub preamble: Vec<TurnItem>,
    pub turns: Vec<Turn>,
    pub queue: Vec<UserMessage>,
}

impl ChatThread {
    /// The turn the agent works on.
    pub fn active_turn(&self) -> Option<&Turn> {
        self.turns.last().filter(|t| t.is_running())
    }

    pub fn active_turn_mut(&mut self) -> Option<&mut Turn> {
        self.turns.last_mut().filter(|t| t.is_running())
    }

    pub fn is_running(&self) -> bool {
        self.active_turn().is_some()
    }
}

/// Turn duration ("Worked for 1m 12s"): `Nms` under 1 s, `N.Ns` under 10 s, `Ns` under a
/// minute, else `1h 2m 3s` with zero parts left out.
pub fn turn_duration_text(interval: f64) -> String {
    if interval < 1.0 {
        return format!("{}ms", ((interval * 1000.0) as i64).max(0));
    }
    if interval < 10.0 {
        return format!("{interval:.1}s");
    }
    let seconds = interval as i64;
    if seconds < 60 {
        return format!("{seconds}s");
    }
    let hours = seconds / 3600;
    let minutes = (seconds % 3600) / 60;
    let rest = seconds % 60;
    let mut parts = Vec::new();
    if hours > 0 {
        parts.push(format!("{hours}h"));
    }
    if minutes > 0 {
        parts.push(format!("{minutes}m"));
    }
    if rest > 0 {
        parts.push(format!("{rest}s"));
    }
    parts.join(" ")
}
