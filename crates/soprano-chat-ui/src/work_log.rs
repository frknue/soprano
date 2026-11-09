//! The work log's presentation (`WorkLog.swift`): one entry per tool item of a turn, group
//! summaries ("Read 2 files and ran 1 command"), live labels and thought lines. Pure data; the
//! timeline renders it.

use std::collections::{BTreeSet, HashMap};
use std::sync::LazyLock;

use fancy_regex::Regex;
use soprano_agents::{
    ApprovalDecision, ApprovalKind, Date, FileChange, FileChangeKind, ToolCategory, TurnItem, TurnItemKind,
    TurnItemStatus, UserInputRequest,
};
use soprano_ui::IconName;

/// The timeline's glyphs (`TimelineIcon`), as Lucide icons.
pub mod timeline_icon {
    use soprano_ui::IconName;

    pub const WORK_READ: IconName = IconName::Eye;
    pub const WORK_EDIT: IconName = IconName::SquarePen;
    pub const WORK_COMMAND: IconName = IconName::Terminal;
    pub const WORK_WEB: IconName = IconName::Globe;
    pub const WORK_SEARCH: IconName = IconName::Search;
    pub const WORK_TOOL: IconName = IconName::Wrench;
    pub const WORK_MIXED: IconName = IconName::Hammer;
    pub const WORK_REASONING: IconName = IconName::Brain;
    pub const WORK_AGENT: IconName = IconName::Cpu;
    pub const WORK_MESSAGE: IconName = IconName::MessageSquare;
    pub const CIRCLE_X: IconName = IconName::X;
    pub const FOLDER: IconName = IconName::Folder;
    pub const FOLDER_OPEN: IconName = IconName::FolderOpen;
    pub const FILE: IconName = IconName::File;
    pub const REDO: IconName = IconName::Redo2;
    pub const CLOSE: IconName = IconName::X;
    pub const MINIMIZE: IconName = IconName::Minimize2;
    pub const SHIELD: IconName = IconName::Shield;
    pub const UNFOLD_ALL: IconName = IconName::ChevronsUpDown;
    pub const PLAN: IconName = IconName::ListChecks;
}

use timeline_icon::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum WorkLogKind {
    Reasoning,
    Command,
    FileChange,
    Read,
    CodeSearch,
    WebSearch,
    Tool,
    Subagent,
    Approval,
    UserInput,
}

/// The summary bucket ("Read 3 files", "Ran 2 commands", …).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum WorkLogAction {
    Read,
    Edit,
    Command,
    Search,
    CodeSearch,
    Other,
}

/// One row of the work log, derived from a [`TurnItem`].
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct WorkLogEntry {
    pub id: String,
    pub kind: WorkLogKind,
    pub status: TurnItemStatus,
    pub started_at: Option<Date>,
    /// One-line label: "Ran command", "Changed Sources/App.swift", "Read …", "Thought".
    pub label: String,
    /// Text after the label: the command (mono), the search query, the thought line.
    pub detail: Option<String>,
    pub detail_is_code: bool,
    /// Trailing note: an approval's decision, a dismissed question.
    pub note: Option<String>,
    /// Shown when the row expands (output, diff, tool input/output, the full thought).
    pub body: Option<String>,
    /// The body is Markdown (reasoning, question answers) rather than monospaced output.
    pub body_is_markdown: bool,
    pub changed_files: Vec<String>,
    pub icon: IconName,
    /// The files of a file change, each shown as its own diff row.
    pub file_changes: Vec<FileChange>,
}

impl WorkLogEntry {
    pub fn is_tool_like(&self) -> bool {
        self.kind != WorkLogKind::Reasoning
    }

    pub fn is_failed(&self) -> bool {
        self.status == TurnItemStatus::Failed
    }

    pub fn is_active(&self) -> bool {
        self.status.is_active()
    }

    pub fn can_expand(&self) -> bool {
        self.body.as_deref().is_some_and(|b| !b.trim().is_empty())
    }

    pub fn action(&self) -> WorkLogAction {
        match self.kind {
            WorkLogKind::Read => WorkLogAction::Read,
            WorkLogKind::FileChange => WorkLogAction::Edit,
            WorkLogKind::Command => WorkLogAction::Command,
            WorkLogKind::WebSearch => WorkLogAction::Search,
            WorkLogKind::CodeSearch => WorkLogAction::CodeSearch,
            _ => WorkLogAction::Other,
        }
    }

    /// Reasoning without text never shows.
    pub fn is_visible(&self) -> bool {
        self.kind != WorkLogKind::Reasoning || self.can_expand()
    }
}

/// The work-log entry for an item; `None` for items the timeline shows as their own rows
/// (assistant messages, errors, notices).
pub fn entry(item: &TurnItem) -> Option<WorkLogEntry> {
    let make = |kind: WorkLogKind, label: String, icon: IconName| WorkLogEntry {
        id: item.id.clone(),
        kind,
        status: item.status,
        started_at: item.started_at,
        label,
        detail: None,
        detail_is_code: false,
        note: None,
        body: None,
        body_is_markdown: false,
        changed_files: Vec::new(),
        icon,
        file_changes: Vec::new(),
    };
    let detail = |text: String| (!text.is_empty()).then_some(text);
    let active = item.status.is_active();
    Some(match &item.kind {
        TurnItemKind::Reasoning { text } => WorkLogEntry {
            detail: detail(thought_line(text)),
            body: Some(text.clone()),
            body_is_markdown: true,
            ..make(WorkLogKind::Reasoning, if active { "Thinking" } else { "Thought" }.into(), WORK_REASONING)
        },
        TurnItemKind::Command(command) => {
            let mut body = format!("$ {}", command.command);
            let output = command.output.trim_matches(['\n', '\r']);
            if !output.is_empty() {
                body.push('\n');
                body.push_str(output);
            }
            if let Some(exit) = command.exit_code
                && exit != 0
            {
                body.push_str(&format!("\n\nExit code {exit}"));
            }
            WorkLogEntry {
                detail: detail(single_line(&command.command)),
                detail_is_code: true,
                body: Some(body),
                ..make(
                    WorkLogKind::Command,
                    if active { "Running command" } else { "Ran command" }.into(),
                    WORK_COMMAND,
                )
            }
        }
        TurnItemKind::FileChange(changes) => {
            let paths: Vec<String> =
                changes.iter().map(|c| c.move_path.clone().unwrap_or_else(|| c.path.clone())).collect();
            let writes = !changes.is_empty() && changes.iter().all(|c| c.is_full_content == Some(true));
            let verb = if active { if writes { "Writing" } else { "Editing" } } else { "Changed" };
            let label = match changes.len() {
                0 => format!("{verb} files"),
                1 => format!("{verb} {}", paths[0]),
                count => format!("{verb} {count} files"),
            };
            let diffs: Vec<&str> =
                changes.iter().filter_map(|c| c.diff.as_deref()).filter(|d| !d.is_empty()).collect();
            let body = if diffs.is_empty() {
                changes
                    .iter()
                    .map(|c| format!("{} {}", file_change_verb(c.kind), change_description(c)))
                    .collect::<Vec<_>>()
                    .join("\n")
            } else {
                diffs.join("\n")
            };
            WorkLogEntry {
                body: Some(body),
                changed_files: paths,
                file_changes: changes.clone(),
                ..make(WorkLogKind::FileChange, label, WORK_EDIT)
            }
        }
        TurnItemKind::ToolCall(tool) => {
            let body = [tool.input.as_deref(), tool.output.as_deref()]
                .into_iter()
                .flatten()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join("\n\n");
            let title = tool.title.trim();
            let titled = |fallback: String| if title.is_empty() { fallback } else { title.to_owned() };
            let (kind, label, icon) = match tool.category {
                ToolCategory::Read => (WorkLogKind::Read, titled("Read file".into()), WORK_READ),
                ToolCategory::Search => {
                    (WorkLogKind::CodeSearch, titled("Searched files".into()), WORK_SEARCH)
                }
                ToolCategory::Subagent => (
                    WorkLogKind::Subagent,
                    titled(if tool.name.is_empty() { "Subagent".into() } else { tool.name.clone() }),
                    WORK_AGENT,
                ),
                ToolCategory::Other => {
                    let name = tool.name.trim_matches(' ');
                    (
                        WorkLogKind::Tool,
                        titled(if name.is_empty() { "Tool call".into() } else { name.to_owned() }),
                        WORK_TOOL,
                    )
                }
            };
            WorkLogEntry { body: Some(body), ..make(kind, label, icon) }
        }
        TurnItemKind::WebSearch { query } => WorkLogEntry {
            detail: detail(single_line(query)),
            body: Some(query.clone()),
            ..make(WorkLogKind::WebSearch, "Searched the web".into(), WORK_WEB)
        },
        TurnItemKind::Approval(request) => {
            let reason = request.reason.as_ref().map(|r| format!("{r}\n\n")).unwrap_or_default();
            WorkLogEntry {
                detail: detail(single_line(if request.detail.is_empty() {
                    request.kind.title()
                } else {
                    &request.detail
                })),
                detail_is_code: matches!(
                    request.kind,
                    ApprovalKind::Command | ApprovalKind::FileChange | ApprovalKind::FileRead
                ),
                note: request.decision.map(|d| decision_note(d).to_owned()),
                body: Some(reason + &request.detail),
                ..make(WorkLogKind::Approval, "Approval requested".into(), WORK_MESSAGE)
            }
        }
        TurnItemKind::UserInput(request) => {
            let answered = request.answers.is_some();
            WorkLogEntry {
                detail: request.questions.first().map(|q| single_line(&q.question)).and_then(detail),
                note: if request.dismissed {
                    Some("Dismissed".into())
                } else if answered {
                    answer_preview(request)
                } else {
                    None
                },
                body: Some(if answered {
                    question_answer_markdown(request)
                } else {
                    request.questions.iter().map(|q| q.question.as_str()).collect::<Vec<_>>().join("\n\n")
                }),
                body_is_markdown: true,
                ..make(
                    WorkLogKind::UserInput,
                    if answered { "Answered questions" } else { "Input requested" }.into(),
                    WORK_MESSAGE,
                )
            }
        }
        TurnItemKind::AssistantMessage { .. } | TurnItemKind::Error { .. } | TurnItemKind::Notice { .. } => {
            return None;
        }
    })
}

/// "Read 3 files and ran 2 commands", "Thought", "Thought (×3)".
pub fn summary(entries: &[WorkLogEntry]) -> String {
    let tools: Vec<&WorkLogEntry> = entries.iter().filter(|e| e.is_tool_like()).collect();
    if !entries.is_empty() && tools.is_empty() {
        return if entries.len() == 1 { "Thought".into() } else { format!("Thought (×{})", entries.len()) };
    }
    let mut order: Vec<WorkLogAction> = Vec::new();
    let mut grouped: HashMap<WorkLogAction, Vec<&WorkLogEntry>> = HashMap::new();
    for entry in &tools {
        let action = entry.action();
        if !grouped.contains_key(&action) {
            order.push(action);
        }
        grouped.entry(action).or_default().push(entry);
    }
    let mut summaries: Vec<(usize, WorkLogAction, usize, String)> = order
        .iter()
        .enumerate()
        .map(|(index, action)| {
            let group = &grouped[action];
            (index, *action, group.len(), action_label(*action, action_count(*action, group)))
        })
        .collect();
    summaries.sort_by_key(|s| (priority(s.1), s.0));
    summaries.truncate(2);
    summaries.sort_by_key(|s| s.0);
    let mut labels: Vec<String> = summaries.iter().map(|s| s.3.clone()).collect();
    let remaining = tools.len() - summaries.iter().map(|s| s.2).sum::<usize>();
    if remaining > 0 {
        labels.push(format!(
            "Performed {remaining} other {}",
            if remaining == 1 { "action" } else { "actions" }
        ));
    }
    let sentence: Vec<String> = labels
        .into_iter()
        .enumerate()
        .map(|(index, label)| if index == 0 { label } else { lowercase_first(&label) })
        .collect();
    if sentence.len() < 3 {
        return sentence.join(" and ");
    }
    let (last, rest) = sentence.split_last().expect("three or more labels");
    format!("{}, and {last}", rest.join(", "))
}

/// Icon of a group header: the shared action's icon, brain for reasoning-only, hammer when mixed.
pub fn summary_icon(entries: &[WorkLogEntry]) -> IconName {
    let tools: Vec<&WorkLogEntry> = entries.iter().filter(|e| e.is_tool_like()).collect();
    if !entries.is_empty() && tools.is_empty() {
        return WORK_REASONING;
    }
    let actions: BTreeSet<u8> = tools.iter().map(|e| e.action() as u8).collect();
    if actions.len() != 1 {
        return WORK_MIXED;
    }
    match tools[0].action() {
        WorkLogAction::Read => WORK_READ,
        WorkLogAction::Edit => WORK_EDIT,
        WorkLogAction::Command => WORK_COMMAND,
        WorkLogAction::Search => WORK_WEB,
        WorkLogAction::CodeSearch => WORK_SEARCH,
        WorkLogAction::Other => {
            let kinds: BTreeSet<u8> = tools.iter().map(|e| e.kind as u8).collect();
            if kinds.len() == 1 { tools[0].icon } else { WORK_MIXED }
        }
    }
}

/// Label of the live activity row ("Running swift", "Thinking", "Changed App.swift").
pub fn live_label(entry: &WorkLogEntry) -> String {
    match entry.kind {
        WorkLogKind::Reasoning => entry
            .detail
            .clone()
            .unwrap_or_else(|| if entry.is_active() { "Thinking" } else { "Thought" }.into()),
        WorkLogKind::Command => {
            let verb = match entry.status {
                TurnItemStatus::Pending | TurnItemStatus::Running => "Running",
                TurnItemStatus::Failed => "Failed",
                TurnItemStatus::Declined => "Declined",
                TurnItemStatus::Interrupted => "Stopped",
                TurnItemStatus::Completed => "Ran",
            };
            let program =
                program_name(entry.detail.as_deref().unwrap_or("")).unwrap_or_else(|| "command".into());
            format!("{verb} {program}")
        }
        _ => match &entry.detail {
            Some(detail) => format!("{} {detail}", entry.label),
            None => entry.label.clone(),
        },
    }
}

static LINK: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"!?\[([^\]]*)\]\([^)]*\)").expect("link pattern"));
static LIST_MARK: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?m)^[ \t]*(?:#{1,6}|[-*+]|\d+\.)[ \t]+").expect("list pattern"));
static CODE_BOLD_STRIKE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"`+|\*\*|~~").expect("marks pattern"));
static EMPHASIS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(^|[^\w*])[*_]([^*_\n]+)[*_](?![\w*])").expect("emphasis pattern"));
static WHITESPACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").expect("whitespace pattern"));
static SENTENCE_END: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"[.?!]["'”’)]?(?=\s)"#).expect("sentence pattern"));
static NEWLINE_RUN: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s*\n\s*").expect("newline pattern"));

/// First sentence (or bold heading) of a reasoning summary, Markdown stripped, one line.
pub fn thought_line(markdown: &str) -> String {
    let trimmed_start = markdown.trim_start_matches([' ', '\t', '\n']);
    let mut heading: Option<&str> = None;
    if let Some(rest) = trimmed_start.strip_prefix("**")
        && let Some(close) = rest.find("**")
    {
        let candidate = &rest[..close];
        let after = rest[close + 2..].split('\n').next().unwrap_or("");
        if !candidate.is_empty() && !candidate.contains('\n') && after.trim_matches([' ', '\t']).is_empty() {
            heading = Some(candidate);
        }
    }
    let mut text = heading.unwrap_or(markdown).to_owned();
    text = LINK.replace_all(&text, "$1").into_owned();
    text = LIST_MARK.replace_all(&text, "").into_owned();
    text = CODE_BOLD_STRIKE.replace_all(&text, "").into_owned();
    text = EMPHASIS.replace_all(&text, "$1$2").into_owned();
    text = WHITESPACE.replace_all(&text, " ").into_owned();
    let text = text.trim_matches([' ', '\t']).to_owned();
    if heading.is_some() {
        return text;
    }
    if let Ok(Some(end)) = SENTENCE_END.find(&text) {
        return text[..end.end()].to_owned();
    }
    text
}

pub fn decision_note(decision: ApprovalDecision) -> &'static str {
    match decision {
        ApprovalDecision::Accept => "Approved",
        ApprovalDecision::AcceptForSession => "Always allowed",
        ApprovalDecision::Decline => "Declined",
        ApprovalDecision::Cancel => "Cancelled",
    }
}

/// The program a command line runs ("swift" for `swift build`, "rg" for `cd x && rg …`).
pub fn program_name(command: &str) -> Option<String> {
    let segment = command.rsplit("&&").next().unwrap_or(command);
    for word in segment.split(' ').filter(|w| !w.is_empty()) {
        if word.contains('=') && !word.starts_with('-') {
            continue;
        }
        if ["sudo", "env", "time", "exec"].contains(&word) {
            continue;
        }
        let name = word.rsplit('/').find(|s| !s.is_empty()).unwrap_or(word);
        return Some(name.trim_matches(['"', '\'', '(', ')', ';']).to_owned());
    }
    None
}

fn priority(action: WorkLogAction) -> u8 {
    match action {
        WorkLogAction::Command | WorkLogAction::Edit => 0,
        WorkLogAction::Other => 2,
        WorkLogAction::Read | WorkLogAction::Search | WorkLogAction::CodeSearch => 1,
    }
}

fn action_count(action: WorkLogAction, entries: &[&WorkLogEntry]) -> usize {
    if action != WorkLogAction::Edit {
        return entries.len();
    }
    let mut files: BTreeSet<&str> = BTreeSet::new();
    let mut without_files = 0;
    for entry in entries {
        if entry.changed_files.is_empty() {
            without_files += 1;
        } else {
            files.extend(entry.changed_files.iter().map(String::as_str));
        }
    }
    files.len() + without_files
}

fn action_label(action: WorkLogAction, count: usize) -> String {
    let plural = |one: &str, many: &str| if count == 1 { one.to_owned() } else { many.to_owned() };
    match action {
        WorkLogAction::Read => format!("Read {count} {}", plural("file", "files")),
        WorkLogAction::Edit => format!("Changed {count} {}", plural("file", "files")),
        WorkLogAction::Command => format!("Ran {count} {}", plural("command", "commands")),
        WorkLogAction::Search => format!("Searched the web {count} {}", plural("time", "times")),
        WorkLogAction::CodeSearch => format!("Searched code {count} {}", plural("time", "times")),
        WorkLogAction::Other => format!("Used {count} {}", plural("tool", "tools")),
    }
}

fn lowercase_first(label: &str) -> String {
    let mut chars = label.chars();
    match chars.next() {
        Some(first) => first.to_lowercase().chain(chars).collect(),
        None => String::new(),
    }
}

fn single_line(text: &str) -> String {
    NEWLINE_RUN.replace_all(text, " ").trim_matches([' ', '\t']).to_owned()
}

fn file_change_verb(kind: FileChangeKind) -> &'static str {
    match kind {
        FileChangeKind::Add => "Added",
        FileChangeKind::Delete => "Deleted",
        FileChangeKind::Update => "Updated",
        FileChangeKind::Move => "Moved",
    }
}

fn change_description(change: &FileChange) -> String {
    match &change.move_path {
        Some(destination) => format!("{} → {destination}", change.path),
        None => change.path.clone(),
    }
}

fn answer_preview(request: &UserInputRequest) -> Option<String> {
    let answers = request.answers.as_ref()?;
    let values: Vec<String> = request
        .questions
        .iter()
        .filter_map(|q| answers.get(&q.id).map(|a| a.join(", ")))
        .filter(|v| !v.is_empty())
        .collect();
    (!values.is_empty()).then(|| values.join(" · "))
}

fn question_answer_markdown(request: &UserInputRequest) -> String {
    request
        .questions
        .iter()
        .map(|question| {
            let answer = request
                .answers
                .as_ref()
                .and_then(|a| a.get(&question.id))
                .map(|a| a.join(", "))
                .unwrap_or_else(|| "—".into());
            format!("**{}**\n\n{answer}", question.question)
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use soprano_agents::{ToolCall, TurnCommand};

    fn item(id: &str, kind: TurnItemKind, status: TurnItemStatus) -> TurnItem {
        TurnItem::with_status(id, kind, status)
    }

    fn tool(id: &str, category: ToolCategory, title: &str) -> WorkLogEntry {
        entry(&item(
            id,
            TurnItemKind::ToolCall(ToolCall::new("t", category, title)),
            TurnItemStatus::Completed,
        ))
        .expect("tool entry")
    }

    fn command(id: &str, line: &str) -> WorkLogEntry {
        entry(&item(
            id,
            TurnItemKind::Command(TurnCommand::new(line, "", Some(0))),
            TurnItemStatus::Completed,
        ))
        .expect("command entry")
    }

    #[test]
    fn a_group_summary_names_the_two_most_important_actions_and_counts_the_rest() {
        let entries = vec![
            tool("r1", ToolCategory::Read, "Read a"),
            tool("r2", ToolCategory::Read, "Read b"),
            command("c1", "swift build"),
            tool("o1", ToolCategory::Other, "Todo"),
        ];
        assert_eq!(summary(&entries), "Read 2 files, ran 1 command, and performed 1 other action");
        assert_eq!(summary(&entries[..3]), "Read 2 files and ran 1 command");
        assert_eq!(summary_icon(&entries[..2]), WORK_READ);
        assert_eq!(summary_icon(&entries[..3]), WORK_MIXED);
    }

    #[test]
    fn reasoning_alone_reads_as_thought_with_its_count() {
        let thought = entry(&item(
            "t1",
            TurnItemKind::Reasoning { text: "Checking.".into() },
            TurnItemStatus::Completed,
        ))
        .expect("thought");
        assert_eq!(summary(std::slice::from_ref(&thought)), "Thought");
        assert_eq!(summary(&[thought.clone(), thought.clone(), thought]), "Thought (×3)");
    }

    #[test]
    fn empty_reasoning_never_shows() {
        let empty =
            entry(&item("t", TurnItemKind::Reasoning { text: " \n".into() }, TurnItemStatus::Running))
                .expect("entry");
        assert!(!empty.is_visible());
        assert_eq!(empty.label, "Thinking");
    }

    #[test]
    fn a_thought_line_is_the_bold_heading_or_the_first_sentence_without_markdown() {
        assert_eq!(thought_line("**Planning the fix**\n\nThen more."), "Planning the fix");
        assert_eq!(
            thought_line("I'll check `main.rs` and the [docs](http://x). Then build."),
            "I'll check main.rs and the docs."
        );
        assert_eq!(thought_line("- *Quick* look at it"), "Quick look at it");
    }

    #[test]
    fn a_commands_program_skips_assignments_and_wrappers() {
        assert_eq!(program_name("swift build").as_deref(), Some("swift"));
        assert_eq!(program_name("cd x && FOO=1 sudo /usr/bin/rg todo").as_deref(), Some("rg"));
        assert_eq!(program_name("").as_deref(), None);
        let running = entry(&item(
            "c",
            TurnItemKind::Command(TurnCommand::new("cargo test", "", None)),
            TurnItemStatus::Running,
        ))
        .expect("entry");
        assert_eq!(live_label(&running), "Running cargo");
    }

    #[test]
    fn a_failed_command_body_carries_its_output_and_exit_code() {
        let failed = entry(&item(
            "c",
            TurnItemKind::Command(TurnCommand::new("make", "\nboom\n", Some(2))),
            TurnItemStatus::Failed,
        ))
        .expect("entry");
        assert_eq!(failed.body.as_deref(), Some("$ make\nboom\n\nExit code 2"));
        assert_eq!(failed.label, "Ran command");
        assert_eq!(failed.detail.as_deref(), Some("make"));
    }

    #[test]
    fn edits_count_each_file_once() {
        let edit = |id: &str, path: &str| {
            entry(&item(
                id,
                TurnItemKind::FileChange(vec![FileChange::new(path, FileChangeKind::Update)]),
                TurnItemStatus::Completed,
            ))
            .expect("entry")
        };
        let entries = vec![edit("e1", "a.rs"), edit("e2", "a.rs"), edit("e3", "b.rs")];
        assert_eq!(summary(&entries), "Changed 2 files");
        assert_eq!(entries[0].label, "Changed a.rs");
        assert_eq!(entries[0].body.as_deref(), Some("Updated a.rs"));
    }
}
