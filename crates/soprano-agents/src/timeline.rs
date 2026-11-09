//! The visible conversation of one agent, the same for every CLI (`AgentTimeline.swift`).

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::Path;

use chrono::{DateTime, TimeZone, Utc};
use serde_json::Value;

/// A point in time as the transcripts store it.
pub type Date = DateTime<Utc>;

/// The agent CLIs whose own transcript the dashboard can read. Claude Code, Codex and omp keep
/// their conversations as JSON Lines, each in a different shape; OpenCode keeps them in a
/// SQLite database.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AgentTranscriptFormat {
    ClaudeCode,
    Codex,
    Omp,
    OpenCode,
}

impl AgentTranscriptFormat {
    pub const ALL: [Self; 4] = [Self::ClaudeCode, Self::Codex, Self::Omp, Self::OpenCode];

    pub fn from_profile_id(profile_id: &str) -> Option<Self> {
        match profile_id {
            "claude-code" => Some(Self::ClaudeCode),
            "codex" => Some(Self::Codex),
            "omp" => Some(Self::Omp),
            "opencode" => Some(Self::OpenCode),
            _ => None,
        }
    }
}

/// What one timeline item is.
#[derive(Clone, Debug, PartialEq)]
pub enum TimelineItemKind {
    /// What the person sent.
    Prompt(String),
    /// The agent's prose, as Markdown.
    Reply(String),
    /// Visible reasoning; empty when the CLI stored only an encrypted form.
    Thinking(String),
    Tool(AgentToolCall),
    /// Compaction, interruption, API errors, and similar markers.
    Notice {
        text: String,
        is_error: bool,
    },
}

impl TimelineItemKind {
    pub fn notice(text: impl Into<String>, is_error: bool) -> Self {
        Self::Notice { text: text.into(), is_error }
    }
}

/// One thing that happened in an agent's conversation.
#[derive(Clone, Debug, PartialEq)]
pub struct AgentTimelineItem {
    pub id: String,
    pub timestamp: Option<Date>,
    pub kind: TimelineItemKind,
}

impl AgentTimelineItem {
    pub fn new(id: impl Into<String>, timestamp: Option<Date>, kind: TimelineItemKind) -> Self {
        Self { id: id.into(), timestamp, kind }
    }

    pub fn tool_call(&self) -> Option<&AgentToolCall> {
        match &self.kind {
            TimelineItemKind::Tool(call) => Some(call),
            _ => None,
        }
    }

    pub fn is_prompt(&self) -> bool {
        matches!(self.kind, TimelineItemKind::Prompt(_))
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum ToolCallState {
    #[default]
    Running,
    Succeeded,
    Failed,
    /// A newer prompt arrived before any result: the turn was cut short.
    Interrupted,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct AgentToolCall {
    /// Short tool label: "Bash", "Edit", "Read", "cua_repl.js".
    pub name: String,
    /// One line saying what the call does: the command, the file, the query.
    pub summary: String,
    /// The full input when it says more than `summary`, such as a multi-line command.
    pub detail: Option<String>,
    pub state: ToolCallState,
    /// What the tool printed, already shortened with [`excerpt`].
    pub output: Option<String>,
    /// Unified-diff lines (`+`, `-`, space, `@@`) for file edits.
    pub diff: Option<String>,
    pub finished_at: Option<Date>,
}

impl AgentToolCall {
    pub fn new(name: impl Into<String>, summary: impl Into<String>) -> Self {
        Self { name: name.into(), summary: summary.into(), ..Self::default() }
    }

    pub fn apply(&mut self, result: &AgentToolResult) {
        self.state = result.state;
        if result.output.is_some() {
            self.output.clone_from(&result.output);
        }
        if result.diff.is_some() {
            self.diff.clone_from(&result.diff);
        }
        if let Some(summary) = &result.summary {
            self.summary.clone_from(summary);
        }
        if result.finished_at.is_some() {
            self.finished_at = result.finished_at;
        }
    }
}

/// The finishing half of a tool call, written by a later transcript record.
#[derive(Clone, Debug, PartialEq)]
pub struct AgentToolResult {
    pub state: ToolCallState,
    pub output: Option<String>,
    pub diff: Option<String>,
    /// Replaces the call's summary when the result names the subject better.
    pub summary: Option<String>,
    pub finished_at: Option<Date>,
}

impl AgentToolResult {
    pub fn new(state: ToolCallState) -> Self {
        Self { state, output: None, diff: None, summary: None, finished_at: None }
    }
}

/// One transcript line reduced to what the timeline needs.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct AgentTranscriptEntry {
    /// Position in the conversation tree for CLIs that branch when a person rewinds (Claude
    /// Code, omp). `None` for linear transcripts and for records outside the tree.
    pub id: Option<String>,
    pub parent_id: Option<String>,
    pub items: Vec<AgentTimelineItem>,
    /// Results keyed by the id of the tool call item they finish.
    pub results: BTreeMap<String, AgentToolResult>,
    /// Provisional items this record supersedes. An id that another record rewrote with the
    /// finished item is kept.
    pub dropped_item_ids: Vec<String>,
}

impl AgentTranscriptEntry {
    pub fn node(id: impl Into<String>, parent_id: Option<String>) -> Self {
        Self { id: Some(id.into()), parent_id, ..Self::default() }
    }

    pub fn with_items(items: Vec<AgentTimelineItem>) -> Self {
        Self { items, ..Self::default() }
    }
}

/// Reads one CLI's transcript a line at a time. Decoders keep whatever later lines need, such
/// as the session's working directory.
pub trait AgentTranscriptDecoding: Send {
    /// The entry one JSON line contributes, or `None` for lines the timeline neither shows nor
    /// needs for branch tracking. Malformed lines are `None`.
    fn entry_for_line(&mut self, line: &[u8]) -> Option<AgentTranscriptEntry>;
}

/// The visible conversation of one agent, newest last.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct AgentTimeline {
    pub items: Vec<AgentTimelineItem>,
}

impl AgentTimeline {
    /// Items kept per agent; older ones fall off the front.
    pub const ITEM_LIMIT: usize = 400;
    /// Characters kept from one tool's output.
    pub const OUTPUT_CHARACTER_LIMIT: usize = 4_000;
    /// Lines kept from one tool's output before the middle is elided.
    pub const OUTPUT_LINE_LIMIT: usize = 40;
    /// Diff lines kept per tool call.
    pub const DIFF_LINE_LIMIT: usize = 400;

    pub fn new(items: Vec<AgentTimelineItem>) -> Self {
        Self { items }
    }

    /// Folds transcript entries into the conversation a person sees: only the branch ending at
    /// the newest tree record, results merged into their calls, provisional items dropped, and
    /// calls left without a result when a new prompt arrived marked interrupted.
    pub fn from_entries(entries: &[AgentTranscriptEntry]) -> Self {
        Self::from_entries_with_limit(entries, Self::ITEM_LIMIT)
    }

    pub fn from_entries_with_limit(entries: &[AgentTranscriptEntry], limit: usize) -> Self {
        let visible = current_branch(entries);
        let mut items: Vec<AgentTimelineItem> = Vec::new();
        let mut index_by_id: HashMap<String, usize> = HashMap::new();
        let mut dropped: HashSet<String> = HashSet::new();
        // Ids a second record rewrote: the finished item now stands there, and Codex reuses the
        // provisional call's id for it.
        let mut replaced: HashSet<String> = HashSet::new();

        for entry in visible {
            for item in &entry.items {
                if item.is_prompt() {
                    for existing in &mut items {
                        if let TimelineItemKind::Tool(call) = &mut existing.kind
                            && call.state == ToolCallState::Running
                        {
                            call.state = ToolCallState::Interrupted;
                        }
                    }
                }
                if let Some(&index) = index_by_id.get(&item.id) {
                    items[index] = item.clone();
                    replaced.insert(item.id.clone());
                } else {
                    index_by_id.insert(item.id.clone(), items.len());
                    items.push(item.clone());
                }
            }
            for (call_id, result) in &entry.results {
                if let Some(&index) = index_by_id.get(call_id)
                    && let TimelineItemKind::Tool(call) = &mut items[index].kind
                {
                    call.apply(result);
                }
            }
            dropped.extend(entry.dropped_item_ids.iter().cloned());
        }

        dropped.retain(|id| !replaced.contains(id));
        if !dropped.is_empty() {
            items.retain(|item| !dropped.contains(&item.id));
        }
        if items.len() > limit {
            items.drain(..items.len() - limit);
        }
        Self { items }
    }

    /// The newest tool call still waiting for its result.
    pub fn running_tool(&self) -> Option<&AgentTimelineItem> {
        self.items
            .iter()
            .rev()
            .find(|item| item.tool_call().is_some_and(|c| c.state == ToolCallState::Running))
    }
}

/// Entries on the branch that ends at the newest tree record, in file order, plus side branches
/// without a prompt: Claude Code hangs the second of two parallel tool calls and its result off
/// the first call, so they leave the path to the leaf without being abandoned. A side branch
/// that holds a prompt is what a rewind left behind and stays hidden. Records outside the tree
/// always stay.
fn current_branch(entries: &[AgentTranscriptEntry]) -> Vec<&AgentTranscriptEntry> {
    let leaf = entries.iter().rev().find_map(|e| e.id.as_deref());
    let Some(leaf) = leaf.filter(|_| entries.iter().any(|e| e.parent_id.is_some())) else {
        return entries.iter().collect();
    };

    let mut parent_by_id: HashMap<&str, Option<&str>> = HashMap::new();
    let mut children_by_id: HashMap<&str, Vec<&str>> = HashMap::new();
    let mut has_prompt: HashSet<&str> = HashSet::new();
    for entry in entries {
        let Some(id) = entry.id.as_deref() else { continue };
        parent_by_id.insert(id, entry.parent_id.as_deref());
        if let Some(parent) = entry.parent_id.as_deref() {
            children_by_id.entry(parent).or_default().push(id);
        }
        if entry.items.iter().any(AgentTimelineItem::is_prompt) {
            has_prompt.insert(id);
        }
    }

    let mut branch: HashSet<&str> = HashSet::new();
    let mut cursor = Some(leaf);
    while let Some(id) = cursor {
        if !branch.insert(id) {
            break;
        }
        cursor = parent_by_id.get(id).copied().flatten();
    }

    let mut visible = branch.clone();
    for id in &branch {
        for &child in children_by_id.get(id).map(Vec::as_slice).unwrap_or_default() {
            if branch.contains(child) {
                continue;
            }
            let mut subtree: HashSet<&str> = HashSet::new();
            let mut pending = vec![child];
            let mut abandoned = false;
            while !abandoned {
                let Some(node) = pending.pop() else { break };
                if visible.contains(node) || !subtree.insert(node) {
                    continue;
                }
                abandoned = has_prompt.contains(node);
                pending.extend(children_by_id.get(node).map(Vec::as_slice).unwrap_or_default());
            }
            if !abandoned {
                visible.extend(subtree);
            }
        }
    }
    entries.iter().filter(|e| e.id.as_deref().is_none_or(|id| visible.contains(id))).collect()
}

// MARK: - Text helpers shared by the decoders

/// Characters Foundation's `.newlines` set holds.
pub(crate) fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// Trims Foundation's `.whitespaces` (no line breaks).
pub(crate) fn trim_spaces(text: &str) -> &str {
    text.trim_matches(|c: char| c.is_whitespace() && !is_newline(c))
}

/// Trims Foundation's `.newlines`.
pub(crate) fn trim_newlines(text: &str) -> &str {
    text.trim_matches(is_newline)
}

pub(crate) fn char_count(text: &str) -> usize {
    text.chars().count()
}

pub(crate) fn prefix_chars(text: &str, count: usize) -> &str {
    match text.char_indices().nth(count) {
        Some((index, _)) => &text[..index],
        None => text,
    }
}

/// `path` relative to `cwd` when it lies inside it, else with `~` for home.
pub fn display_path(path: &str, cwd: Option<&str>) -> String {
    if let Some(cwd) = cwd.filter(|c| !c.is_empty()) {
        let base = if cwd.ends_with('/') { cwd.to_owned() } else { format!("{cwd}/") };
        if let Some(rest) = path.strip_prefix(&base)
            && !rest.is_empty()
        {
            return rest.to_owned();
        }
    }
    soprano_platform::paths::abbreviate_home(Path::new(path))
}

/// The first non-empty line of `text`, trimmed and cut to 160 characters.
pub fn first_line(text: &str) -> String {
    first_line_limited(text, 160)
}

/// The first non-empty line of `text`, trimmed and cut to `limit` characters.
pub fn first_line_limited(text: &str, limit: usize) -> String {
    let line = text.split(is_newline).map(trim_spaces).find(|l| !l.is_empty()).unwrap_or("");
    if char_count(line) > limit {
        format!("{}…", prefix_chars(line, limit.saturating_sub(1)))
    } else {
        line.to_owned()
    }
}

/// Tool output short enough to show: long output keeps its head and its tail (where errors
/// land), and anything still too long is cut. `None` when nothing but whitespace was printed.
pub fn excerpt(text: Option<&str>) -> Option<String> {
    let trimmed = text?.trim();
    if trimmed.is_empty() {
        return None;
    }
    let lines: Vec<&str> = trimmed.split('\n').collect();
    let mut result = if lines.len() > AgentTimeline::OUTPUT_LINE_LIMIT {
        let head = AgentTimeline::OUTPUT_LINE_LIMIT / 4;
        let tail = AgentTimeline::OUTPUT_LINE_LIMIT - head;
        let elided = lines.len() - head - tail;
        let marker = format!("⋯ {elided} more lines ⋯");
        let mut kept: Vec<&str> = lines[..head].to_vec();
        kept.push(&marker);
        kept.extend_from_slice(&lines[lines.len() - tail..]);
        kept.join("\n")
    } else {
        lines.join("\n")
    };
    if char_count(&result) > AgentTimeline::OUTPUT_CHARACTER_LIMIT {
        result = format!("{}\n⋯", prefix_chars(&result, AgentTimeline::OUTPUT_CHARACTER_LIMIT));
    }
    Some(result)
}

/// A diff cut to [`AgentTimeline::DIFF_LINE_LIMIT`] lines.
pub fn diff_excerpt(diff: Option<&str>) -> Option<String> {
    let trimmed = trim_newlines(diff?);
    if trimmed.is_empty() {
        return None;
    }
    let lines: Vec<&str> = trimmed.split('\n').collect();
    if lines.len() <= AgentTimeline::DIFF_LINE_LIMIT {
        return Some(trimmed.to_owned());
    }
    let marker = format!("⋯ {} more lines ⋯", lines.len() - AgentTimeline::DIFF_LINE_LIMIT);
    let mut kept: Vec<&str> = lines[..AgentTimeline::DIFF_LINE_LIMIT].to_vec();
    kept.push(&marker);
    Some(kept.join("\n"))
}

/// ISO 8601 timestamps as the CLIs write them, with or without fractions; a number is epoch
/// milliseconds.
pub fn date_from_value(value: Option<&Value>) -> Option<Date> {
    match value? {
        Value::Number(n) => date_from_millis(n.as_f64()?),
        Value::String(s) => parse_date(s),
        _ => None,
    }
}

pub fn parse_date(text: &str) -> Option<Date> {
    DateTime::parse_from_rfc3339(text).ok().map(|d| d.with_timezone(&Utc))
}

pub fn date_from_millis(milliseconds: f64) -> Option<Date> {
    if !milliseconds.is_finite() {
        return None;
    }
    let micros = (milliseconds * 1_000.0).round() as i64;
    Utc.timestamp_micros(micros).single()
}
