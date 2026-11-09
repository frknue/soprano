//! Codex CLI rollouts (`CodexRolloutDecoder.swift`).

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::sync::LazyLock;

use regex::Regex;
use serde_json::Value;

use crate::json::{
    Object, bool_true, dict, number_int, obj_at, objects, objects_at, parse_object, str_at, strings,
};
use crate::timeline::{
    AgentTimelineItem, AgentToolCall, AgentTranscriptDecoding, AgentTranscriptEntry, Date, TimelineItemKind,
    ToolCallState, char_count, date_from_value, diff_excerpt, display_path, excerpt, first_line,
};

/// Reads a Codex CLI rollout (`~/.codex/sessions/…/rollout-*.jsonl`).
///
/// Codex writes the finished work twice: as model-facing `response_item` records and as
/// `item_completed` events. The events carry status, exit codes and diffs, so they are the
/// source of truth; `response_item` calls only stand in while the work is still running, and
/// the `response_item` messages are skipped because they also hold injected developer and
/// AGENTS.md text nobody typed.
#[derive(Clone, Debug, Default)]
pub struct CodexRolloutDecoder {
    /// The session's working directory, for showing paths relative to it.
    cwd: Option<String>,
}

impl CodexRolloutDecoder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cwd(&self) -> Option<&str> {
        self.cwd.as_deref()
    }
}

impl AgentTranscriptDecoding for CodexRolloutDecoder {
    fn entry_for_line(&mut self, line: &[u8]) -> Option<AgentTranscriptEntry> {
        let record = parse_object(line)?;
        let kind = str_at(&record, "type")?;
        let payload = obj_at(&record, "payload")?;
        let timestamp = date_from_value(record.get("timestamp"));
        match kind {
            "session_meta" | "turn_context" => {
                if let Some(cwd) = str_at(payload, "cwd").filter(|c| !c.is_empty()) {
                    self.cwd = Some(cwd.to_owned());
                }
                None
            }
            "event_msg" => self.event(payload, timestamp),
            "response_item" => response_item(payload, timestamp),
            _ => None,
        }
    }
}

impl CodexRolloutDecoder {
    fn event(&self, payload: &Object, timestamp: Option<Date>) -> Option<AgentTranscriptEntry> {
        match str_at(payload, "type") {
            Some("item_completed") => {
                let item = obj_at(payload, "item")?;
                let id = str_at(item, "id")?;
                let mut kind = self.completed_kind(item)?;
                if let TimelineItemKind::Tool(call) = &mut kind {
                    call.finished_at = timestamp;
                }
                Some(AgentTranscriptEntry::with_items(vec![AgentTimelineItem::new(id, timestamp, kind)]))
            }
            Some("turn_aborted") => {
                let turn = str_at(payload, "turn_id").map(str::to_owned).unwrap_or_else(random_id);
                Some(AgentTranscriptEntry::with_items(vec![AgentTimelineItem::new(
                    format!("aborted-{turn}"),
                    timestamp,
                    TimelineItemKind::notice("Interrupted", false),
                )]))
            }
            Some("error") => {
                let message = str_at(payload, "message").filter(|m| !m.is_empty()).unwrap_or("Error");
                let mut hasher = DefaultHasher::new();
                message.hash(&mut hasher);
                let seconds = timestamp.map_or(0.0, |t| t.timestamp_micros() as f64 / 1_000_000.0);
                Some(AgentTranscriptEntry::with_items(vec![AgentTimelineItem::new(
                    format!("error-{seconds}-{}", hasher.finish()),
                    timestamp,
                    TimelineItemKind::notice(message, true),
                )]))
            }
            _ => None,
        }
    }

    fn completed_kind(&self, item: &Object) -> Option<TimelineItemKind> {
        match str_at(item, "type")? {
            "UserMessage" => {
                let parts: Vec<&str> = objects_at(item, "content")
                    .into_iter()
                    .filter_map(|part| match str_at(part, "type") {
                        Some("text") => str_at(part, "text"),
                        Some("image" | "local_image") => Some("[image]"),
                        _ => None,
                    })
                    .collect();
                let text = parts.join("\n");
                (!text.is_empty()).then_some(TimelineItemKind::Prompt(text))
            }
            "AgentMessage" => {
                let text: String =
                    objects_at(item, "content").into_iter().filter_map(|p| str_at(p, "text")).collect();
                (!text.is_empty()).then_some(TimelineItemKind::Reply(text))
            }
            "Reasoning" => {
                let text = strings(item.get("summary_text")).unwrap_or_default().join("\n\n");
                (!text.is_empty()).then_some(TimelineItemKind::Thinking(text))
            }
            "CommandExecution" => Some(TimelineItemKind::Tool(self.command_call(item))),
            "FileChange" => self.file_change_call(item).map(TimelineItemKind::Tool),
            "McpToolCall" => Some(TimelineItemKind::Tool(mcp_call(item))),
            "Extension" => {
                let kind = str_at(item, "kind").unwrap_or("Extension");
                if kind == "web.search" {
                    return Some(TimelineItemKind::Tool(web_search_call(item)));
                }
                Some(TimelineItemKind::Tool(AgentToolCall {
                    state: ToolCallState::Succeeded,
                    ..AgentToolCall::new(kind, "")
                }))
            }
            "WebSearch" => Some(TimelineItemKind::Tool(web_search_call(item))),
            "ContextCompaction" => Some(TimelineItemKind::notice("Context compacted", false)),
            _ => None,
        }
    }

    fn command_call(&self, item: &Object) -> AgentToolCall {
        let command = strings(item.get("command"))
            .and_then(|c| c.last().copied())
            .or_else(|| str_at(item, "command"))
            .unwrap_or("")
            .to_owned();
        let parsed = objects(item.get("parsed_cmd")).and_then(|p| p.first().copied());
        let parsed_str = |key: &str| parsed.and_then(|p| str_at(p, key));
        let (name, mut summary) = match parsed_str("type") {
            Some("read") => (
                "Read",
                parsed_str("path")
                    .map(|p| display_path(p, self.cwd.as_deref()))
                    .unwrap_or_else(|| first_line(&command)),
            ),
            Some("search") => ("Search", first_line(parsed_str("cmd").unwrap_or(&command))),
            Some("list_files" | "list") => ("List", first_line(parsed_str("cmd").unwrap_or(&command))),
            _ => ("Run", first_line(&command)),
        };
        if summary.is_empty() {
            summary = first_line(&command);
        }
        let detail = (command.contains('\n') || command != summary).then(|| command.clone());

        let exit_code = number_int(item.get("exit_code"));
        let state = match str_at(item, "status") {
            Some("failed") => ToolCallState::Failed,
            Some("declined" | "interrupted" | "cancelled") => ToolCallState::Interrupted,
            Some("in_progress") => ToolCallState::Running,
            _ if exit_code.unwrap_or(0) == 0 => ToolCallState::Succeeded,
            _ => ToolCallState::Failed,
        };
        AgentToolCall {
            detail,
            state,
            output: excerpt(str_at(item, "aggregated_output")),
            ..AgentToolCall::new(name, summary)
        }
    }

    fn file_change_call(&self, item: &Object) -> Option<AgentToolCall> {
        let changes = obj_at(item, "changes")?;
        // `[String: [String: Any]]`: every value must be an object.
        if changes.is_empty() || changes.values().any(|v| !v.is_object()) {
            return None;
        }
        let mut paths: Vec<&String> = changes.keys().collect();
        paths.sort();
        let first = dict(changes.get(paths[0].as_str()));
        let name = if paths.len() > 1 {
            "Edit"
        } else {
            match str_at(first, "type") {
                Some("add") => "Add",
                Some("delete") => "Delete",
                _ => "Edit",
            }
        };
        let cwd = self.cwd.as_deref();
        let mut summary = display_path(paths[0], cwd);
        if paths.len() > 1 {
            summary += &format!(" +{} more", paths.len() - 1);
        }

        let diffs: Vec<String> = paths
            .iter()
            .filter_map(|path| {
                let diff = file_diff(dict(changes.get(path.as_str())))?;
                if paths.len() > 1 {
                    Some(format!("diff {}\n{diff}", display_path(path, cwd)))
                } else {
                    Some(diff)
                }
            })
            .collect();
        let state = match str_at(item, "status") {
            Some("failed") => ToolCallState::Failed,
            Some("declined") => ToolCallState::Interrupted,
            _ => ToolCallState::Succeeded,
        };
        let joined = (!diffs.is_empty()).then(|| diffs.join("\n"));
        Some(AgentToolCall {
            state,
            diff: diff_excerpt(joined.as_deref()),
            ..AgentToolCall::new(name, summary)
        })
    }
}

/// Added files store their whole text in `content` instead of a diff, and deleted ones may too;
/// both read best as all-plus or all-minus lines.
fn file_diff(change: &Object) -> Option<String> {
    if let Some(diff) = str_at(change, "unified_diff").filter(|d| !d.is_empty()) {
        return Some(diff.to_owned());
    }
    let content = str_at(change, "content").filter(|c| !c.is_empty())?;
    let marker = if str_at(change, "type") == Some("delete") { "-" } else { "+" };
    let mut lines: Vec<&str> = content.split('\n').collect();
    if lines.last() == Some(&"") {
        lines.pop();
    }
    Some(lines.iter().map(|l| format!("{marker}{l}")).collect::<Vec<_>>().join("\n"))
}

fn mcp_call(item: &Object) -> AgentToolCall {
    let server = str_at(item, "server").unwrap_or("");
    let tool = str_at(item, "tool").unwrap_or("");
    let name = if server.is_empty() { tool.to_owned() } else { format!("{server}.{tool}") };
    let summary =
        summary_of_arguments(dict(item.get("arguments")), &["title", "description", "query", "path"], true);
    let result = obj_at(item, "result");
    let mut output = result
        .map(|r| objects_at(r, "content"))
        .unwrap_or_default()
        .into_iter()
        .filter(|p| str_at(p, "type") == Some("text"))
        .filter_map(|p| str_at(p, "text"))
        .collect::<Vec<_>>()
        .join("\n");
    if output.is_empty() {
        let error =
            str_at(item, "error").or_else(|| obj_at(item, "error").and_then(|e| str_at(e, "message")));
        if let Some(error) = error {
            output = error.to_owned();
        }
    }
    let failed = str_at(item, "status") == Some("failed")
        || result.is_some_and(|r| bool_true(r, "isError"))
        || item.get("error").is_some_and(Value::is_string);
    AgentToolCall {
        state: if failed { ToolCallState::Failed } else { ToolCallState::Succeeded },
        output: excerpt(Some(&output)),
        ..AgentToolCall::new(name, summary)
    }
}

fn web_search_call(item: &Object) -> AgentToolCall {
    let query = str_at(item, "query")
        .or_else(|| obj_at(item, "action").and_then(|a| str_at(a, "query")))
        .unwrap_or("");
    AgentToolCall { state: ToolCallState::Succeeded, ..AgentToolCall::new("WebSearch", first_line(query)) }
}

fn response_item(payload: &Object, timestamp: Option<Date>) -> Option<AgentTranscriptEntry> {
    match str_at(payload, "type") {
        Some("function_call" | "custom_tool_call" | "local_shell_call") => {
            let call_id = str_at(payload, "call_id").or_else(|| str_at(payload, "id"))?;
            let call = provisional_call(payload);
            Some(AgentTranscriptEntry::with_items(vec![AgentTimelineItem::new(
                call_id,
                timestamp,
                TimelineItemKind::Tool(call),
            )]))
        }
        Some("function_call_output" | "custom_tool_call_output" | "local_shell_call_output") => {
            let call_id = str_at(payload, "call_id")?;
            Some(AgentTranscriptEntry {
                dropped_item_ids: vec![call_id.to_owned()],
                ..AgentTranscriptEntry::default()
            })
        }
        _ => None,
    }
}

fn provisional_call(payload: &Object) -> AgentToolCall {
    let name = str_at(payload, "name").unwrap_or("");
    match str_at(payload, "type") {
        Some("custom_tool_call") => {
            let input = str_at(payload, "input").unwrap_or("");
            if name == "exec" {
                let command = first_cmd_literal(input).unwrap_or_else(|| input.to_owned());
                let summary = first_line(&command);
                let detail = (input != summary).then(|| input.to_owned());
                return AgentToolCall { detail, ..AgentToolCall::new("Run", summary) };
            }
            AgentToolCall::new(name, first_line(input))
        }
        Some("local_shell_call") => {
            let command = obj_at(payload, "action")
                .and_then(|a| strings(a.get("command")))
                .and_then(|c| c.last().copied())
                .unwrap_or("");
            AgentToolCall::new("Run", first_line(command))
        }
        _ => {
            let mut label = name.to_owned();
            if let Some(namespace) = str_at(payload, "namespace").filter(|n| !n.is_empty()) {
                let namespace = namespace.strip_prefix("mcp__").unwrap_or(namespace);
                label = format!("{namespace}.{name}");
            }
            let arguments =
                str_at(payload, "arguments").and_then(|a| parse_object(a.as_bytes())).unwrap_or_default();
            let summary =
                summary_of_arguments(&arguments, &["title", "command", "cmd", "query", "path"], false);
            AgentToolCall::new(label, summary)
        }
    }
}

fn summary_of_arguments(arguments: &Object, keys: &[&str], fallback_to_short_string: bool) -> String {
    for key in keys {
        if let Some(value) = str_at(arguments, key).filter(|v| !v.is_empty()) {
            return first_line(value);
        }
        if let Some(last) = strings(arguments.get(*key)).and_then(|v| v.last().copied()) {
            return first_line(last);
        }
    }
    if !fallback_to_short_string {
        return String::new();
    }
    let mut keys: Vec<&String> = arguments.keys().collect();
    keys.sort();
    keys.into_iter()
        .filter_map(|k| str_at(arguments, k))
        .find(|v| !v.is_empty() && char_count(v) <= 160 && !v.contains('\n'))
        .map(first_line)
        .unwrap_or_default()
}

static CMD_LITERAL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"cmd\s*:\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')"#).expect("valid regex"));

/// Code-mode `exec` sends JavaScript; the shell command it runs is the first `cmd: "…"`
/// literal, which says far more than the script's first line.
pub fn first_cmd_literal(source: &str) -> Option<String> {
    let literal = CMD_LITERAL.captures(source)?.get(1)?.as_str();
    let body = &literal[1..literal.len() - 1];
    let mut result = String::new();
    let mut chars = body.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            result.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => result.push('\n'),
            Some('t') => result.push('\t'),
            Some('r') => result.push('\r'),
            Some(other) => result.push(other),
            None => result.push('\\'),
        }
    }
    Some(result)
}

/// A fresh id, like Swift's `UUID().uuidString`, so two aborted turns without an id never share
/// one (and one "Interrupted" notice never replaces the other).
fn random_id() -> String {
    uuid::Uuid::new_v4().to_string().to_uppercase()
}
