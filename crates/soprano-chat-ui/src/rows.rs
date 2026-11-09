//! The chat's turns as the rows the timeline shows (`TimelineRows.swift`, ported from Soprano
//! Agents): user messages, "Working for" / "Worked for …" folds, answers, work groups and
//! entries, a diff row per changed file, approvals, errors, notices, changed-files cards and
//! queued messages.

use std::collections::{HashMap, HashSet};

use soprano_agents::{
    ApprovalRequest, ChangedFileStat, ChatThread, Date, FileChange, FileChangeKind, Turn, TurnItem,
    TurnItemKind, TurnItemStatus, TurnStatus, UserMessage, turn_duration_text,
};
use soprano_ui::IconName;

use crate::work_log::{self, WorkLogEntry, WorkLogKind};

/// What the person opened or closed in the timeline. Ids are turn, group and item ids.
///
/// `turns`, `groups` and `diffs` hold what the person toggled away from the work log's default:
/// closed in the minimal work log, open in the detailed one (`detailed`). Read them through
/// [`is_turn_open`](Self::is_turn_open) and friends.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TimelineExpansion {
    /// Finished turns whose "Worked for …" fold was toggled.
    pub turns: HashSet<String>,
    /// Work groups (and live work rows) that were toggled.
    pub groups: HashSet<String>,
    /// Work entries showing their output.
    pub entries: HashSet<String>,
    /// Long user messages shown in full.
    pub messages: HashSet<String>,
    /// Changed-files cards: turn id → closed folder paths.
    pub closed_folders: HashMap<String, HashSet<String>>,
    /// File diffs ([`FileDiffRowModel::id`]) that were toggled.
    pub diffs: HashSet<String>,
    /// The detailed work log: folds, work groups and file diffs open by default.
    pub detailed: bool,
}

impl Default for TimelineExpansion {
    fn default() -> Self {
        Self {
            turns: HashSet::new(),
            groups: HashSet::new(),
            entries: HashSet::new(),
            messages: HashSet::new(),
            closed_folders: HashMap::new(),
            diffs: HashSet::new(),
            detailed: true,
        }
    }
}

/// The sets read against the work log's default.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExpansionSet {
    Turns,
    Groups,
    Entries,
    Messages,
    Diffs,
}

impl TimelineExpansion {
    pub fn minimal() -> Self {
        Self { detailed: false, ..Self::default() }
    }

    pub fn is_turn_open(&self, turn_id: &str) -> bool {
        self.turns.contains(turn_id) != self.detailed
    }

    pub fn is_group_open(&self, group_id: &str) -> bool {
        self.groups.contains(group_id) != self.detailed
    }

    pub fn is_diff_open(&self, diff_id: &str) -> bool {
        self.diffs.contains(diff_id) != self.detailed
    }

    pub fn set_mut(&mut self, set: ExpansionSet) -> &mut HashSet<String> {
        match set {
            ExpansionSet::Turns => &mut self.turns,
            ExpansionSet::Groups => &mut self.groups,
            ExpansionSet::Entries => &mut self.entries,
            ExpansionSet::Messages => &mut self.messages,
            ExpansionSet::Diffs => &mut self.diffs,
        }
    }

    /// Flips `id` in `set`.
    pub fn toggle(&mut self, set: ExpansionSet, id: &str) {
        let ids = self.set_mut(set);
        if !ids.remove(id) {
            ids.insert(id.to_owned());
        }
    }

    /// Opens or closes `id` in a set read against the default (`Turns`, `Groups`, `Diffs`).
    pub fn set(&mut self, set: ExpansionSet, id: &str, open: bool) {
        let detailed = self.detailed;
        let ids = self.set_mut(set);
        if open != detailed {
            ids.insert(id.to_owned());
        } else {
            ids.remove(id);
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UserRowModel {
    pub message: UserMessage,
    /// The turn this message started; `None` for steers.
    pub turn_id: Option<String>,
    pub expanded: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FoldRowModel {
    pub turn_id: String,
    pub label: String,
    pub date: Option<Date>,
    pub expanded: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChangedFilesModel {
    pub turn_id: String,
    pub files: Vec<ChangedFileStat>,
    pub closed_folders: HashSet<String>,
}

impl ChangedFilesModel {
    pub fn additions(&self) -> usize {
        self.files.iter().map(|f| f.additions).sum()
    }

    pub fn deletions(&self) -> usize {
        self.files.iter().map(|f| f.deletions).sum()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AssistantRowModel {
    pub item_id: String,
    pub text: String,
    pub is_streaming: bool,
    /// A complete answer, or the finished turn's last message: copy button and timestamp below it.
    pub show_meta: bool,
    pub date: Option<Date>,
    pub changed_files: Option<ChangedFilesModel>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkGroupRowModel {
    pub group_id: String,
    pub summary: String,
    pub icon: IconName,
    pub failed: bool,
    pub expanded: bool,
    pub date: Option<Date>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkEntryRowModel {
    pub entry: WorkLogEntry,
    /// Part of an expanded group (no own vertical padding).
    pub grouped: bool,
    pub expanded: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LiveWorkRowModel {
    pub group_id: String,
    pub entry: WorkLogEntry,
    /// Latest reasoning line, shown above the live row (up to 4 lines).
    pub thought: Option<String>,
    pub expanded: bool,
    /// A tool is still running (or the last one succeeded): the label shimmers.
    pub active: bool,
}

/// One file an edit or write touched: a header line ("Edited Sources/App.swift  +12 −3") that
/// opens its diff. A running call shows the code as the model writes it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileDiffRowModel {
    /// The item id and the file's index in it: the row's expansion key.
    pub id: String,
    pub change: FileChange,
    pub status: TurnItemStatus,
    pub date: Option<Date>,
    pub expanded: bool,
    /// Part of an expanded group (no own vertical padding).
    pub grouped: bool,
}

impl FileDiffRowModel {
    pub fn is_active(&self) -> bool {
        self.status.is_active()
    }

    pub fn can_expand(&self) -> bool {
        self.change.diff.as_deref().is_some_and(|d| !d.is_empty())
    }

    /// The path the diff shows: the destination of a move.
    pub fn shown_path(&self) -> &str {
        self.change.move_path.as_deref().unwrap_or(&self.change.path)
    }

    /// "Editing App.swift", "Wrote App.swift", "Edit failed: App.swift".
    pub fn label(&self) -> String {
        let path = match &self.change.move_path {
            Some(destination) => format!("{} → {destination}", self.change.path),
            None => self.change.path.clone(),
        };
        let wrote = self.change.is_full_content == Some(true);
        let verb = match (self.status, self.change.kind) {
            (TurnItemStatus::Pending | TurnItemStatus::Running, FileChangeKind::Add) => "Writing",
            (TurnItemStatus::Pending | TurnItemStatus::Running, _) => {
                if wrote {
                    "Writing"
                } else {
                    "Editing"
                }
            }
            (TurnItemStatus::Failed, _) => {
                if wrote {
                    "Write failed:"
                } else {
                    "Edit failed:"
                }
            }
            (TurnItemStatus::Declined, _) => "Declined",
            (TurnItemStatus::Interrupted, _) => {
                if wrote {
                    "Stopped writing"
                } else {
                    "Stopped editing"
                }
            }
            (TurnItemStatus::Completed, FileChangeKind::Add) => "Created",
            (TurnItemStatus::Completed, FileChangeKind::Delete) => "Deleted",
            (TurnItemStatus::Completed, FileChangeKind::Move) => "Moved",
            (TurnItemStatus::Completed, FileChangeKind::Update) => {
                if wrote {
                    "Wrote"
                } else {
                    "Edited"
                }
            }
        };
        format!("{verb} {path}")
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TimelineRowContent {
    User(UserRowModel),
    Fold(FoldRowModel),
    Working {
        started_at: Option<Date>,
        stopping: bool,
    },
    Assistant(AssistantRowModel),
    WorkGroup(WorkGroupRowModel),
    WorkEntry(WorkEntryRowModel),
    FileDiff(FileDiffRowModel),
    LiveWork(LiveWorkRowModel),
    Thinking,
    Approval(ApprovalRequest),
    Error {
        message: String,
        date: Option<Date>,
    },
    Notice {
        text: String,
    },
    ChangedFiles(ChangedFilesModel),
    Queued(UserMessage),
    /// The empty chat: what it says while the agent starts or waits for the first message.
    Empty(String),
}

impl TimelineRowContent {
    /// Rows of the work log: adjacent ones sit flush.
    pub fn is_work_log(&self) -> bool {
        matches!(
            self,
            Self::WorkGroup(_)
                | Self::WorkEntry(_)
                | Self::FileDiff(_)
                | Self::LiveWork(_)
                | Self::Thinking
                | Self::Approval(_)
        )
    }
}

/// One row of the timeline: a stable id (reuse, scroll anchoring) and its content.
#[derive(Clone, Debug, PartialEq)]
pub struct TimelineRow {
    pub id: String,
    pub content: TimelineRowContent,
    /// Space under the row, per row kind.
    pub bottom_spacing: f32,
}

impl TimelineRow {
    fn new(id: String, content: TimelineRowContent) -> Self {
        Self { id, content, bottom_spacing: 0.0 }
    }

    /// A message that started a turn (the dashboard's `[` / `]` jump between them).
    pub fn is_turn_message(&self) -> bool {
        matches!(&self.content, TimelineRowContent::User(model) if model.turn_id.is_some())
    }
}

/// Fold label: "Worked for 3m 12s", "You stopped after 12s"; "Worked" for a replayed turn.
pub fn fold_label(turn: &Turn) -> String {
    let interrupted = turn.status == TurnStatus::Interrupted;
    let Some(seconds) = turn.started_at.and_then(|start| turn.duration_seconds(start)) else {
        return if interrupted { "You stopped".into() } else { "Worked".into() };
    };
    let duration = turn_duration_text(seconds);
    if interrupted { format!("You stopped after {duration}") } else { format!("Worked for {duration}") }
}

/// Thread → timeline rows:
///
/// - Each turn: the user message, then "Working for" while it runs ("Stopping…" once Stop was
///   pressed, without "Thinking"), or a "Worked for …" fold when it finished (it hides
///   commentary and work, never an answer or a card).
/// - Consecutive tool items form a work group: one summary row ("Read 2 files and ran 1
///   command"), or a single entry row when the group holds one tool call. A file change shows
///   as one diff row per file.
/// - The detailed work log opens folds, groups and diffs by default; a running turn's trailing
///   group then shows like any open group, its running step shimmering. Collapsing that group
///   gives the minimal live row.
/// - "Thinking" ends a running turn that shows no live tool, waits on nobody and has not just
///   answered.
/// - The turn's answer carries the changed-files card, computed from its edits.
/// - Steers sit at the time they were sent; queued messages close the thread.
pub fn timeline_rows(
    thread: &ChatThread,
    empty_text: &str,
    expansion: &TimelineExpansion,
) -> Vec<TimelineRow> {
    let mut rows = Vec::new();
    for item in &thread.preamble {
        match &item.kind {
            TurnItemKind::Error { message } => rows.push(TimelineRow::new(
                format!("error:{}", item.id),
                TimelineRowContent::Error { message: message.clone(), date: item.started_at },
            )),
            TurnItemKind::Notice { text } => rows.push(TimelineRow::new(
                format!("notice:{}", item.id),
                TimelineRowContent::Notice { text: text.clone() },
            )),
            _ => {}
        }
    }
    if thread.turns.is_empty() && thread.queue.is_empty() && rows.is_empty() {
        return vec![TimelineRow::new("empty".into(), TimelineRowContent::Empty(empty_text.to_owned()))];
    }
    for turn in &thread.turns {
        TurnRows::new(turn, expansion, &mut rows).append();
    }
    for queued in &thread.queue {
        rows.push(TimelineRow::new(
            format!("queued:{}", queued.id),
            TimelineRowContent::Queued(queued.clone()),
        ));
    }
    apply_spacing(&mut rows);
    rows
}

enum Piece<'a> {
    Item(&'a TurnItem),
    Steer(&'a UserMessage),
}

/// Building one turn's rows; the Swift nested `flushGroup` closure's state.
struct TurnRows<'a> {
    turn: &'a Turn,
    expansion: &'a TimelineExpansion,
    rows: &'a mut Vec<TimelineRow>,
    is_running: bool,
    group: Vec<WorkLogEntry>,
    has_live_activity: bool,
}

impl<'a> TurnRows<'a> {
    fn new(turn: &'a Turn, expansion: &'a TimelineExpansion, rows: &'a mut Vec<TimelineRow>) -> Self {
        Self {
            turn,
            expansion,
            rows,
            is_running: turn.is_running(),
            group: Vec::new(),
            has_live_activity: false,
        }
    }

    fn push(&mut self, id: String, content: TimelineRowContent) {
        self.rows.push(TimelineRow::new(id, content));
    }

    fn append(mut self) {
        let turn = self.turn;
        let expansion = self.expansion;
        let is_running = self.is_running;
        if !turn.user_message.text.is_empty() {
            self.push(
                format!("user:{}", turn.user_message.id),
                TimelineRowContent::User(UserRowModel {
                    message: turn.user_message.clone(),
                    turn_id: Some(turn.id.clone()),
                    expanded: expansion.messages.contains(&turn.user_message.id),
                }),
            );
        }

        let terminal_id = turn
            .items
            .iter()
            .rev()
            .find(|i| matches!(i.kind, TurnItemKind::AssistantMessage { .. }))
            .map(|i| i.id.clone());
        let terminal_index = terminal_id
            .as_ref()
            .and_then(|id| turn.items.iter().position(|i| &i.id == id))
            .unwrap_or(turn.items.len());

        // Which items the closed fold hides.
        let mut hidden: HashSet<&str> = HashSet::new();
        if !is_running && turn.status != TurnStatus::Failed {
            for (index, item) in turn.items.iter().enumerate() {
                if hides_in_fold(item, index, terminal_index, terminal_id.as_deref()) {
                    hidden.insert(&item.id);
                }
            }
        }
        let fold_open = expansion.is_turn_open(&turn.id);
        if is_running {
            self.push(
                format!("working:{}", turn.id),
                TimelineRowContent::Working {
                    started_at: turn.started_at,
                    stopping: turn.stop_requested_at.is_some(),
                },
            );
        } else if !hidden.is_empty() {
            self.push(
                format!("fold:{}", turn.id),
                TimelineRowContent::Fold(FoldRowModel {
                    turn_id: turn.id.clone(),
                    label: fold_label(turn),
                    date: turn.started_at,
                    expanded: fold_open,
                }),
            );
        }

        let files = if is_running { Vec::new() } else { turn.changed_files() };
        let changed_files = (!files.is_empty()).then(|| ChangedFilesModel {
            turn_id: turn.id.clone(),
            files,
            closed_folders: expansion.closed_folders.get(&turn.id).cloned().unwrap_or_default(),
        });
        let mut placed_changed_files = false;

        let shown: Vec<&TurnItem> =
            turn.items.iter().filter(|i| fold_open || !hidden.contains(i.id.as_str())).collect();
        let mut waits_on_user = false;
        let mut answered = false;

        for piece in interleave(&shown, &turn.steers) {
            match piece {
                Piece::Steer(message) => {
                    self.flush_group(false);
                    answered = false;
                    self.push(
                        format!("user:{}", message.id),
                        TimelineRowContent::User(UserRowModel {
                            message: message.clone(),
                            turn_id: None,
                            expanded: expansion.messages.contains(&message.id),
                        }),
                    );
                }
                Piece::Item(item) => {
                    answered = false;
                    match &item.kind {
                        TurnItemKind::AssistantMessage { text, is_final } => {
                            self.flush_group(false);
                            answered = *is_final;
                            let is_terminal = Some(&item.id) == terminal_id.as_ref() && !is_running;
                            let mut card = None;
                            if is_terminal && changed_files.is_some() {
                                card = changed_files.clone();
                                placed_changed_files = true;
                            }
                            self.push(
                                format!("assistant:{}", item.id),
                                TimelineRowContent::Assistant(AssistantRowModel {
                                    item_id: item.id.clone(),
                                    text: text.clone(),
                                    is_streaming: item.status.is_active() && is_running,
                                    show_meta: is_terminal || (*is_final && !item.status.is_active()),
                                    date: item.completed_at.or(item.started_at),
                                    changed_files: card,
                                }),
                            );
                        }
                        TurnItemKind::Error { message } => {
                            self.flush_group(false);
                            self.push(
                                format!("error:{}", item.id),
                                TimelineRowContent::Error { message: message.clone(), date: item.started_at },
                            );
                        }
                        TurnItemKind::Notice { text } => {
                            self.flush_group(false);
                            self.push(
                                format!("notice:{}", item.id),
                                TimelineRowContent::Notice { text: text.clone() },
                            );
                        }
                        TurnItemKind::Approval(request) if request.decision.is_none() => {
                            self.flush_group(false);
                            if is_running {
                                waits_on_user = true;
                            }
                            self.push(
                                format!("approval:{}", item.id),
                                TimelineRowContent::Approval(request.clone()),
                            );
                        }
                        TurnItemKind::UserInput(request) => {
                            self.flush_group(false);
                            if is_running && request.answers.is_none() && !request.dismissed {
                                waits_on_user = true;
                            }
                            if let Some(entry) = work_log::entry(item) {
                                let expanded = expansion.entries.contains(&item.id);
                                self.push(
                                    format!("entry:{}", item.id),
                                    TimelineRowContent::WorkEntry(WorkEntryRowModel {
                                        entry,
                                        grouped: false,
                                        expanded,
                                    }),
                                );
                            }
                        }
                        _ => {
                            if let Some(entry) = work_log::entry(item)
                                && entry.is_visible()
                            {
                                self.group.push(entry);
                            }
                        }
                    }
                }
            }
        }
        self.flush_group(true);

        if turn.status == TurnStatus::Failed
            && let Some(failure) = &turn.failure_message
        {
            self.push(
                format!("failure:{}", turn.id),
                TimelineRowContent::Error {
                    message: failure.clone(),
                    date: turn.completed_at.or(turn.started_at),
                },
            );
        }
        if let Some(changed_files) = changed_files
            && !placed_changed_files
        {
            self.push(format!("files:{}", turn.id), TimelineRowContent::ChangedFiles(changed_files));
        }
        if is_running
            && !self.has_live_activity
            && !waits_on_user
            && !answered
            && turn.stop_requested_at.is_none()
        {
            self.push(format!("thinking:{}", turn.id), TimelineRowContent::Thinking);
        }
    }

    fn flush_group(&mut self, trailing: bool) {
        if self.group.is_empty() {
            return;
        }
        let group = std::mem::take(&mut self.group);
        let expansion = self.expansion;
        let group_id = format!("group:{}", group[0].id);
        let expanded = expansion.is_group_open(&group_id);
        if trailing
            && self.is_running
            && let Some(last) = group.last()
            && !last.is_failed()
        {
            let running = group.iter().rev().find(|e| e.is_active());
            let current = running.unwrap_or(last);
            let detailed = expanded && expansion.detailed;
            // The minimal live row shimmers with the last step too; the detailed steps shimmer
            // only while one runs, else "Thinking" shows the turn is alive.
            let active = running.is_some() || (!detailed && last.status == TurnItemStatus::Completed);
            self.has_live_activity = self.has_live_activity || active;
            if !detailed {
                let thought = group
                    .iter()
                    .rev()
                    .find(|e| {
                        e.kind == WorkLogKind::Reasoning && e.detail.as_deref().is_some_and(|d| !d.is_empty())
                    })
                    .and_then(|e| e.detail.clone());
                let id = format!("live:{}", self.turn.id);
                self.push(
                    id,
                    TimelineRowContent::LiveWork(LiveWorkRowModel {
                        group_id,
                        entry: current.clone(),
                        thought,
                        expanded,
                        active,
                    }),
                );
                if expanded {
                    self.append_entries(&group, true);
                }
                return;
            }
        }
        if group.len() == 1 && group[0].is_tool_like() {
            let entry = &group[0];
            if !entry.file_changes.is_empty() {
                self.append_diffs(entry, false);
                return;
            }
            let expanded = expansion.entries.contains(&entry.id);
            self.push(
                format!("entry:{}", entry.id),
                TimelineRowContent::WorkEntry(WorkEntryRowModel {
                    entry: entry.clone(),
                    grouped: false,
                    expanded,
                }),
            );
            return;
        }
        let failed = group.iter().rev().find(|e| e.is_tool_like()).is_some_and(WorkLogEntry::is_failed);
        self.push(
            group_id.clone(),
            TimelineRowContent::WorkGroup(WorkGroupRowModel {
                group_id,
                summary: work_log::summary(&group),
                icon: work_log::summary_icon(&group),
                failed,
                expanded,
                date: group[0].started_at,
            }),
        );
        if expanded {
            self.append_entries(&group, true);
        }
    }

    /// The steps of a work group: a diff row per changed file, an entry row for everything else.
    fn append_entries(&mut self, entries: &[WorkLogEntry], grouped: bool) {
        for entry in entries {
            if !entry.file_changes.is_empty() {
                self.append_diffs(entry, grouped);
                continue;
            }
            let expanded = self.expansion.entries.contains(&entry.id);
            self.push(
                format!("entry:{}", entry.id),
                TimelineRowContent::WorkEntry(WorkEntryRowModel { entry: entry.clone(), grouped, expanded }),
            );
        }
    }

    fn append_diffs(&mut self, entry: &WorkLogEntry, grouped: bool) {
        for (index, change) in entry.file_changes.iter().enumerate() {
            let id = format!("{}:{index}", entry.id);
            let expanded = self.expansion.is_diff_open(&id);
            self.push(
                format!("diff:{id}"),
                TimelineRowContent::FileDiff(FileDiffRowModel {
                    id,
                    change: change.clone(),
                    status: entry.status,
                    date: entry.started_at,
                    expanded,
                    grouped,
                }),
            );
        }
    }
}

/// The closed fold hides commentary and finished work; it keeps every final answer, the last
/// message, errors, notices, questions, pending approvals and failed work after the last message.
fn hides_in_fold(item: &TurnItem, index: usize, terminal_index: usize, terminal_id: Option<&str>) -> bool {
    match &item.kind {
        TurnItemKind::AssistantMessage { is_final, .. } => !is_final && Some(item.id.as_str()) != terminal_id,
        TurnItemKind::Error { .. } | TurnItemKind::Notice { .. } | TurnItemKind::UserInput(_) => false,
        TurnItemKind::Approval(request) => request.decision.is_some(),
        TurnItemKind::Reasoning { .. }
        | TurnItemKind::Command(_)
        | TurnItemKind::FileChange(_)
        | TurnItemKind::ToolCall(_)
        | TurnItemKind::WebSearch { .. } => {
            if index > terminal_index && item.status == TurnItemStatus::Failed {
                return false;
            }
            work_log::entry(item).is_some_and(|e| e.is_visible())
        }
    }
}

/// Items in order with each steer placed before the first item that started after it.
fn interleave<'a>(items: &[&'a TurnItem], steers: &'a [UserMessage]) -> Vec<Piece<'a>> {
    let mut remaining: Vec<&UserMessage> = steers.iter().collect();
    remaining.sort_by_key(|s| s.created_at);
    let mut remaining = remaining.into_iter().peekable();
    let mut pieces = Vec::new();
    for item in items {
        while let Some(steer) = remaining.next_if(|s| s.created_at <= item.started_at) {
            pieces.push(Piece::Steer(steer));
        }
        pieces.push(Piece::Item(item));
    }
    pieces.extend(remaining.map(Piece::Steer));
    pieces
}

/// Row padding: user messages and cards 16, assistant prose 8 (16 under its meta row), folds 6,
/// work-log rows 8 unless the next row continues the log (then flush; an expanded group's
/// entries end with 4).
fn apply_spacing(rows: &mut [TimelineRow]) {
    for index in 0..rows.len() {
        let continues = rows.get(index + 1).is_some_and(|next| next.content.is_work_log());
        let spacing =
            match &rows[index].content {
                TimelineRowContent::User(_) | TimelineRowContent::ChangedFiles(_) => 16.0,
                TimelineRowContent::Fold(_) | TimelineRowContent::Working { .. } => 6.0,
                TimelineRowContent::Assistant(model) => {
                    if model.show_meta {
                        16.0
                    } else {
                        8.0
                    }
                }
                TimelineRowContent::WorkGroup(WorkGroupRowModel { expanded, .. })
                | TimelineRowContent::LiveWork(LiveWorkRowModel { expanded, .. }) => {
                    if continues || *expanded { 0.0 } else { 8.0 }
                }
                TimelineRowContent::WorkEntry(WorkEntryRowModel { grouped, .. })
                | TimelineRowContent::FileDiff(FileDiffRowModel { grouped, .. }) => {
                    if continues {
                        0.0
                    } else if *grouped {
                        4.0
                    } else {
                        8.0
                    }
                }
                TimelineRowContent::Thinking | TimelineRowContent::Approval(_) => {
                    if continues {
                        0.0
                    } else {
                        8.0
                    }
                }
                TimelineRowContent::Error { .. }
                | TimelineRowContent::Notice { .. }
                | TimelineRowContent::Queued(_) => 8.0,
                TimelineRowContent::Empty(_) => 0.0,
            };
        rows[index].bottom_spacing = spacing;
    }
}

#[cfg(test)]
mod tests {
    use chrono::{TimeZone, Utc};
    use serde_json::{Value, json};
    use soprano_agents::{
        AgentTimeline, AgentTimelineItem, AgentToolCall, ApprovalKind, ApprovalOption, TimelineItemKind,
        ToolCallState, TurnCommand,
    };
    use soprano_chat::{AcpToolStyle, AcpTurnBuilder};

    use super::*;

    fn now() -> Date {
        Utc.timestamp_opt(1_000, 0).single().expect("date")
    }

    fn at(seconds: i64) -> Date {
        now() + chrono::Duration::seconds(seconds)
    }

    fn update(json: &str) -> Value {
        serde_json::from_str(json).expect("update json")
    }

    fn ids(rows: &[TimelineRow]) -> Vec<&str> {
        rows.iter().map(|r| r.id.as_str()).collect()
    }

    #[test]
    fn an_empty_thread_shows_the_empty_text() {
        let rows = timeline_rows(&ChatThread::default(), "Starting omp…", &TimelineExpansion::default());
        assert_eq!(
            rows,
            [TimelineRow::new("empty".into(), TimelineRowContent::Empty("Starting omp…".into()))]
        );
    }

    #[test]
    fn ending_a_turn_labels_its_fold_by_how_it_ended() {
        let mut builder = AcpTurnBuilder::new(None, AcpToolStyle::Omp);
        builder.add_prompt("Sleep", now());
        builder.apply(
            &update(
                r#"{"sessionUpdate":"tool_call","toolCallId":"t1","name":"bash","title":"$ sleep 60","status":"pending","rawInput":{"command":"sleep 60"}}"#,
            ),
            now(),
        );
        builder.mark_stop_requested(now());
        builder.finish_turn(Some("cancelled"), None, at(12));
        assert_eq!(fold_label(&builder.thread().turns[0]), "You stopped after 12s");

        builder.add_prompt("Answer", now());
        builder.apply(
            &update(r#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Done."}}"#),
            now(),
        );
        builder.finish_turn(Some("end_turn"), None, at(72));
        assert_eq!(fold_label(&builder.thread().turns[1]), "Worked for 1m 12s");
    }

    #[test]
    fn a_replayed_turn_without_times_folds_as_worked() {
        let mut builder = AcpTurnBuilder::new(None, AcpToolStyle::Omp);
        builder.set_replaying(true);
        for json in [
            r#"{"sessionUpdate":"user_message_chunk","messageId":"u2","content":{"type":"text","text":"Run it"}}"#,
            r#"{"sessionUpdate":"tool_call","toolCallId":"t1","name":"bash","title":"$ make","status":"completed","rawInput":{"command":"make"},"rawOutput":{"content":[{"type":"text","text":"ok"}],"details":{"exitCode":0}}}"#,
            r#"{"sessionUpdate":"agent_message_chunk","messageId":"a2","content":{"type":"text","text":"Built."}}"#,
        ] {
            builder.apply(&update(json), now());
        }
        builder.set_replaying(false);
        assert_eq!(fold_label(&builder.thread().turns[0]), "Worked");
    }

    #[test]
    fn the_timeline_shows_a_finished_turns_work_behind_its_fold_and_the_answer_with_its_files() {
        let mut builder = AcpTurnBuilder::new(Some("/r".into()), AcpToolStyle::Omp);
        builder.add_prompt("Fix", now());
        builder.apply(
            &update(
                r#"{"sessionUpdate":"tool_call","toolCallId":"t1","name":"edit","status":"completed","rawInput":{"path":"/r/a.swift"},"rawOutput":{"details":{"diff":"+1|x","path":"/r/a.swift"}}}"#,
            ),
            now(),
        );
        builder.apply(
            &update(r#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Fixed."}}"#),
            now(),
        );
        builder.finish_turn(Some("end_turn"), None, at(52));
        let thread = builder.thread();
        let rows = timeline_rows(thread, "", &TimelineExpansion::minimal());
        assert_eq!(rows[0].id, format!("user:{}", thread.turns[0].user_message.id));
        let TimelineRowContent::Fold(fold) = &rows[1].content else { panic!("no fold") };
        assert_eq!(fold.label, "Worked for 52s");
        let TimelineRowContent::Assistant(answer) = &rows[2].content else { panic!("no answer") };
        assert_eq!(
            answer.changed_files.as_ref().map(|c| c.files.clone()),
            Some(vec![ChangedFileStat { path: "a.swift".into(), additions: 1, deletions: 0 }])
        );
        assert_eq!(rows.len(), 3);
        // Open (the detailed default), the edit shows as its file's diff row.
        let open = timeline_rows(thread, "", &TimelineExpansion::default());
        assert!(open.iter().any(|r| matches!(r.content, TimelineRowContent::FileDiff(_))));
    }

    fn transcript_item(id: &str, seconds: i64, kind: TimelineItemKind) -> AgentTimelineItem {
        AgentTimelineItem::new(id, Some(at(seconds)), kind)
    }

    #[test]
    fn each_prompt_starts_a_turn_and_a_finished_turn_folds_behind_worked_for() {
        let mut call = AgentToolCall::new("Bash", "swift build");
        call.state = ToolCallState::Succeeded;
        call.output = Some("ok".into());
        call.finished_at = Some(at(40));
        let timeline = AgentTimeline::new(vec![
            transcript_item("p1", 0, TimelineItemKind::Prompt("Fix the build".into())),
            transcript_item("r1", 5, TimelineItemKind::Reply("Looking at it.".into())),
            transcript_item("c1", 10, TimelineItemKind::Tool(call)),
            transcript_item("r2", 72, TimelineItemKind::Reply("Fixed.".into())),
            transcript_item("p2", 100, TimelineItemKind::Prompt("Now the tests".into())),
            transcript_item("t2", 103, TimelineItemKind::Thinking("Running the suite.".into())),
        ]);
        let thread = ChatThread::from_transcript(&timeline, true);
        let rows = timeline_rows(&thread, "", &TimelineExpansion::minimal());
        let fold = rows.iter().find(|r| r.id == "fold:p1").expect("fold");
        let TimelineRowContent::Fold(model) = &fold.content else { panic!("not a fold") };
        assert_eq!(model.label, "Worked for 1m 12s");
        assert!(rows.iter().any(|r| r.id == "working:p2"));
    }

    #[test]
    fn work_before_the_first_kept_prompt_opens_a_turn_without_a_message() {
        let timeline = AgentTimeline::new(vec![
            transcript_item(
                "n1",
                0,
                TimelineItemKind::Notice { text: "Context compacted".into(), is_error: false },
            ),
            transcript_item("r0", 1, TimelineItemKind::Reply("…and that finishes the refactor.".into())),
            transcript_item("p1", 5, TimelineItemKind::Prompt("Ship it".into())),
        ]);
        let thread = ChatThread::from_transcript(&timeline, false);
        let rows = timeline_rows(&thread, "", &TimelineExpansion::default());
        assert!(!rows.iter().any(|r| r.id == "user:transcript-head"));
        assert!(rows.iter().any(|r| r.id == "assistant:r0"));
        assert_eq!(rows[0].id, "notice:n1");
    }

    fn running_turn(items: Vec<TurnItem>) -> ChatThread {
        let mut turn = Turn::new("turn", UserMessage::new("m", "Go", Some(now())));
        turn.started_at = Some(now());
        turn.items = items;
        ChatThread { preamble: Vec::new(), turns: vec![turn], queue: Vec::new() }
    }

    fn command(id: &str, status: TurnItemStatus) -> TurnItem {
        let mut item = TurnItem::with_status(
            id,
            TurnItemKind::Command(TurnCommand::new("cargo test", "", None)),
            status,
        );
        item.started_at = Some(now());
        item
    }

    #[test]
    fn a_running_turn_says_working_and_thinking_until_a_tool_runs() {
        let thread = running_turn(Vec::new());
        assert_eq!(
            ids(&timeline_rows(&thread, "", &TimelineExpansion::default())),
            ["user:m", "working:turn", "thinking:turn"]
        );

        // The minimal log shows the running tool as the live row instead of "Thinking".
        let thread = running_turn(vec![command("c1", TurnItemStatus::Running)]);
        let rows = timeline_rows(&thread, "", &TimelineExpansion::minimal());
        assert_eq!(ids(&rows), ["user:m", "working:turn", "live:turn"]);
        let TimelineRowContent::LiveWork(live) = &rows[2].content else { panic!("no live row") };
        assert!(live.active);
        assert_eq!(work_log::live_label(&live.entry), "Running cargo");

        // The detailed log lists the running step like any open group.
        let rows = timeline_rows(&thread, "", &TimelineExpansion::default());
        assert_eq!(ids(&rows), ["user:m", "working:turn", "entry:c1"]);
    }

    #[test]
    fn a_stop_request_says_stopping_without_thinking() {
        let mut thread = running_turn(Vec::new());
        thread.turns[0].stop_requested_at = Some(now());
        let rows = timeline_rows(&thread, "", &TimelineExpansion::default());
        assert_eq!(ids(&rows), ["user:m", "working:turn"]);
        assert_eq!(rows[1].content, TimelineRowContent::Working { started_at: Some(now()), stopping: true });
    }

    #[test]
    fn a_pending_approval_waits_on_the_person_instead_of_thinking() {
        let request = ApprovalRequest {
            id: "a1".into(),
            kind: ApprovalKind::Command,
            detail: "rm -rf build".into(),
            reason: None,
            options: vec![ApprovalOption::new("o1", "Allow", "allow_once")],
            decision: None,
        };
        let thread = running_turn(vec![TurnItem::new("a1", TurnItemKind::Approval(request.clone()))]);
        let rows = timeline_rows(&thread, "", &TimelineExpansion::default());
        assert_eq!(ids(&rows), ["user:m", "working:turn", "approval:a1"]);
        assert_eq!(rows[2].content, TimelineRowContent::Approval(request));
    }

    #[test]
    fn steers_sit_where_they_were_sent_and_queued_messages_close_the_thread() {
        let mut first = command("c1", TurnItemStatus::Completed);
        first.started_at = Some(at(1));
        let mut second = command("c2", TurnItemStatus::Completed);
        second.started_at = Some(at(5));
        let mut thread = running_turn(vec![first, second]);
        thread.turns[0].steers = vec![UserMessage::new("s1", "Keep the tests", Some(at(3)))];
        thread.queue = vec![UserMessage::new("q1", "Later", Some(at(6)))];
        let rows = timeline_rows(&thread, "", &TimelineExpansion::default());
        // The detailed log's finished last step leaves the turn "Thinking".
        assert_eq!(
            ids(&rows),
            ["user:m", "working:turn", "entry:c1", "user:s1", "entry:c2", "thinking:turn", "queued:q1"]
        );
        assert!(!rows[3].is_turn_message());
        assert!(rows[0].is_turn_message());
    }

    #[test]
    fn spacing_keeps_the_work_log_flush_and_spaces_messages_and_cards() {
        let thread = running_turn(vec![
            command("c1", TurnItemStatus::Completed),
            command("c2", TurnItemStatus::Running),
        ]);
        let rows = timeline_rows(&thread, "", &TimelineExpansion::default());
        let spacing: Vec<(&str, f32)> = rows.iter().map(|r| (r.id.as_str(), r.bottom_spacing)).collect();
        assert_eq!(
            spacing,
            [
                ("user:m", 16.0),
                ("working:turn", 6.0),
                ("group:c1", 0.0),
                ("entry:c1", 0.0),
                ("entry:c2", 4.0)
            ]
        );
    }

    #[test]
    fn a_diff_rows_label_names_how_the_file_changed() {
        let model = |status, kind, full: Option<bool>| FileDiffRowModel {
            id: "e:0".into(),
            change: FileChange { is_full_content: full, ..FileChange::new("App.swift", kind) },
            status,
            date: None,
            expanded: false,
            grouped: false,
        };
        assert_eq!(model(TurnItemStatus::Running, FileChangeKind::Update, None).label(), "Editing App.swift");
        assert_eq!(
            model(TurnItemStatus::Completed, FileChangeKind::Update, Some(true)).label(),
            "Wrote App.swift"
        );
        assert_eq!(
            model(TurnItemStatus::Failed, FileChangeKind::Update, None).label(),
            "Edit failed: App.swift"
        );
        assert_eq!(model(TurnItemStatus::Completed, FileChangeKind::Add, None).label(), "Created App.swift");
        let mut moved = model(TurnItemStatus::Completed, FileChangeKind::Move, None);
        moved.change.move_path = Some("B.swift".into());
        assert_eq!(moved.label(), "Moved App.swift → B.swift");
        assert_eq!(moved.shown_path(), "B.swift");
    }

    #[test]
    fn expansion_is_read_against_the_detailed_default() {
        let mut expansion = TimelineExpansion::default();
        assert!(expansion.is_group_open("g"));
        expansion.toggle(ExpansionSet::Groups, "g");
        assert!(!expansion.is_group_open("g"));
        expansion.set(ExpansionSet::Groups, "g", true);
        assert!(expansion.is_group_open("g"));
        let mut minimal = TimelineExpansion::minimal();
        minimal.set(ExpansionSet::Diffs, "d", true);
        assert!(minimal.is_diff_open("d"));
        let _ = json!(null);
    }
}
