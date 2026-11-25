//! Antigravity CLI (`agy`) transcripts
//! (`~/.gemini/antigravity-cli/brain/<conversation-id>/.system_generated/logs/transcript.jsonl`).

use std::collections::VecDeque;

use serde_json::Value;

use crate::json::{Object, dict, number_int, objects_at, parse_object, str_at};
use crate::timeline::{
    AgentTimelineItem, AgentToolCall, AgentToolResult, AgentTranscriptDecoding, AgentTranscriptEntry, Date,
    TimelineItemKind, ToolCallState, char_count, date_from_value, display_path, excerpt, first_line,
};

/// Reads Antigravity's linear JSONL transcript (`transcript.jsonl`).
///
/// Each line is one step in the conversation trajectory (`USER_INPUT`, `PLANNER_RESPONSE`,
/// `GENERIC`, `SYSTEM_MESSAGE`). A `PLANNER_RESPONSE` may carry `thinking`, prose (`content` /
/// `response`), and `tool_calls`; each tool call's result lands in a following `GENERIC` step in
/// the same order.
#[derive(Clone, Debug, Default)]
pub struct AgyTranscriptDecoder {
    cwd: Option<String>,
    pending_tool_calls: VecDeque<String>,
    next_step: i64,
}

impl AgyTranscriptDecoder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cwd(&self) -> Option<&str> {
        self.cwd.as_deref()
    }
}

impl AgentTranscriptDecoding for AgyTranscriptDecoder {
    fn entry_for_line(&mut self, line: &[u8]) -> Option<AgentTranscriptEntry> {
        let record = parse_object(line)?;
        if let Some(cwd) = str_at(&record, "cwd").filter(|c| !c.is_empty()) {
            self.cwd = Some(cwd.to_owned());
        }
        let step_index = number_int(record.get("step_index")).unwrap_or_else(|| {
            let n = self.next_step;
            self.next_step += 1;
            n
        });
        self.next_step = self.next_step.max(step_index + 1);
        let timestamp = date_from_value(record.get("created_at").or_else(|| record.get("timestamp")));

        match str_at(&record, "type")? {
            "USER_INPUT" => self.decode_user(&record, step_index, timestamp),
            "PLANNER_RESPONSE" => self.decode_planner(&record, step_index, timestamp),
            "GENERIC" => self.decode_generic(&record, step_index, timestamp),
            "SYSTEM_MESSAGE" => None,
            _ => None,
        }
    }
}

impl AgyTranscriptDecoder {
    fn decode_user(
        &mut self,
        record: &Object,
        step_index: i64,
        timestamp: Option<Date>,
    ) -> Option<AgentTranscriptEntry> {
        if let Some(source) = str_at(record, "source")
            && source != "USER_EXPLICIT"
        {
            return None;
        }
        let raw = str_at(record, "content")?;
        let prompt = extract_user_request(raw)?;
        self.pending_tool_calls.clear();
        Some(AgentTranscriptEntry::with_items(vec![AgentTimelineItem::new(
            format!("step-{step_index}"),
            timestamp,
            TimelineItemKind::Prompt(prompt),
        )]))
    }

    fn decode_planner(
        &mut self,
        record: &Object,
        step_index: i64,
        timestamp: Option<Date>,
    ) -> Option<AgentTranscriptEntry> {
        let mut items = Vec::new();
        if let Some(thinking) = str_at(record, "thinking").map(str::trim).filter(|t| !t.is_empty()) {
            items.push(AgentTimelineItem::new(
                format!("step-{step_index}#thinking"),
                timestamp,
                TimelineItemKind::Thinking(thinking.to_owned()),
            ));
        }
        if let Some(reply) = str_at(record, "content")
            .or_else(|| str_at(record, "response"))
            .map(str::trim)
            .filter(|t| !t.is_empty())
        {
            items.push(AgentTimelineItem::new(
                format!("step-{step_index}#reply"),
                timestamp,
                TimelineItemKind::Reply(reply.to_owned()),
            ));
        }
        for (index, call) in objects_at(record, "tool_calls").into_iter().enumerate() {
            let Some(name) = str_at(call, "name") else { continue };
            let call_id = str_at(call, "id")
                .filter(|id| !id.is_empty())
                .map(str::to_owned)
                .unwrap_or_else(|| format!("step-{step_index}#tool-{index}"));
            let args = dict(call.get("args").or_else(|| call.get("arguments")));
            let tool = tool_call(name, args, self.cwd.as_deref());
            self.pending_tool_calls.push_back(call_id.clone());
            items.push(AgentTimelineItem::new(call_id, timestamp, TimelineItemKind::Tool(tool)));
        }
        if let Some(error) = str_at(record, "error").map(str::trim).filter(|e| !e.is_empty()) {
            items.push(AgentTimelineItem::new(
                format!("step-{step_index}#error"),
                timestamp,
                TimelineItemKind::notice(error, true),
            ));
        }
        (!items.is_empty()).then(|| AgentTranscriptEntry::with_items(items))
    }

    fn decode_generic(
        &mut self,
        record: &Object,
        step_index: i64,
        timestamp: Option<Date>,
    ) -> Option<AgentTranscriptEntry> {
        let explicit_id = str_at(record, "tool_call_id").filter(|id| !id.is_empty()).map(str::to_owned);
        let call_id = match explicit_id {
            Some(id) => {
                if let Some(pos) = self.pending_tool_calls.iter().position(|pending| pending == &id) {
                    self.pending_tool_calls.remove(pos);
                }
                Some(id)
            }
            None => self.pending_tool_calls.pop_front(),
        };

        let status = str_at(record, "status");
        let error = str_at(record, "error").map(str::trim).filter(|e| !e.is_empty());
        let content = str_at(record, "content");

        if let Some(call_id) = call_id {
            let state = if status == Some("ERROR") || error.is_some() {
                ToolCallState::Failed
            } else if matches!(status, Some("CANCELED" | "CANCELLED")) {
                ToolCallState::Interrupted
            } else {
                ToolCallState::Succeeded
            };
            let mut result = AgentToolResult::new(state);
            result.output = excerpt(error.or(content));
            result.finished_at = timestamp;
            let mut entry = AgentTranscriptEntry::default();
            entry.results.insert(call_id, result);
            return Some(entry);
        }

        if let Some(error) = error {
            return Some(AgentTranscriptEntry::with_items(vec![AgentTimelineItem::new(
                format!("step-{step_index}#error"),
                timestamp,
                TimelineItemKind::notice(error, true),
            )]));
        }
        None
    }
}

/// Extracts the human-written prompt from an Antigravity `USER_INPUT` content block, which wraps
/// the user's message in `<USER_REQUEST>…</USER_REQUEST>` beside `<ADDITIONAL_METADATA>` and
/// `<USER_SETTINGS_CHANGE>` tags.
pub(crate) fn extract_user_request(raw: &str) -> Option<String> {
    if let Some(inner) = tag_content("USER_REQUEST", raw) {
        let trimmed = inner.trim();
        return (!trimmed.is_empty()).then(|| trimmed.to_owned());
    }
    let mut cleaned = raw.to_owned();
    for tag in ["ADDITIONAL_METADATA", "USER_SETTINGS_CHANGE", "SYSTEM_MESSAGE"] {
        cleaned = strip_tag_block(&cleaned, tag);
    }
    let trimmed = cleaned.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

fn tag_content<'a>(tag: &str, text: &'a str) -> Option<&'a str> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let start = text.find(&open)? + open.len();
    let end = text[start..].find(&close)? + start;
    Some(&text[start..end])
}

fn strip_tag_block(text: &str, tag: &str) -> String {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let mut result = text.to_owned();
    while let Some(start) = result.find(&open) {
        match result[start + open.len()..].find(&close) {
            Some(rel_end) => {
                let end = start + open.len() + rel_end + close.len();
                result.replace_range(start..end, "");
            }
            None => break,
        }
    }
    result
}

/// Antigravity encodes tool argument values in `transcript.jsonl` as JSON strings (e.g.
/// `"CommandLine": "\"git status\""`). Unquote when the value itself is a JSON string literal.
fn arg_string(args: &Object, key: &str) -> Option<String> {
    let value = args.get(key)?;
    let raw = match value {
        Value::String(s) => s.as_str(),
        _ => return None,
    };
    let decoded = if raw.starts_with('"') && raw.ends_with('"') && raw.len() >= 2 {
        serde_json::from_str::<String>(raw).unwrap_or_else(|_| raw.to_owned())
    } else {
        raw.to_owned()
    };
    let trimmed = decoded.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

fn tool_call(name: &str, args: &Object, cwd: Option<&str>) -> AgentToolCall {
    let path = |keys: &[&str]| {
        keys.iter().find_map(|key| arg_string(args, key)).map(|p| display_path(&p, cwd)).unwrap_or_default()
    };
    match name {
        "run_command" => {
            let command = arg_string(args, "CommandLine").unwrap_or_default();
            let summary = arg_string(args, "toolSummary")
                .map(|s| first_line(&s))
                .unwrap_or_else(|| first_line(&command));
            let detail = (command.contains('\n') || command != summary)
                .then(|| command.clone())
                .filter(|d| !d.is_empty());
            AgentToolCall { detail, ..AgentToolCall::new("Run", summary) }
        }
        "read_file" | "view_file" | "view_file_outline" | "view_code_item" => {
            AgentToolCall::new("Read", path(&["Path", "AbsolutePath", "File"]))
        }
        "edit_file" | "replace_file_content" | "multi_replace_file_content" => {
            AgentToolCall::new("Edit", path(&["Path", "TargetFile"]))
        }
        "write_file" | "write_to_file" => AgentToolCall::new("Write", path(&["Path", "TargetFile"])),
        "grep_search" => {
            let query = arg_string(args, "Query").unwrap_or_default();
            let scope = arg_string(args, "SearchPath")
                .map(|p| format!(" in {}", display_path(&p, cwd)))
                .unwrap_or_default();
            AgentToolCall::new("Grep", first_line(&(query + &scope)))
        }
        "find_by_name" => AgentToolCall::new(
            "Find",
            first_line(&arg_string(args, "Pattern").unwrap_or_else(|| path(&["SearchDirectory"]))),
        ),
        "list_dir" => AgentToolCall::new("List", path(&["DirectoryPath"])),
        "search_web" => {
            AgentToolCall::new("WebSearch", first_line(&arg_string(args, "query").unwrap_or_default()))
        }
        "invoke_subagent" => {
            let role = arg_string(args, "Role").or_else(|| arg_string(args, "TypeName")).unwrap_or_default();
            AgentToolCall::new("Subagent", first_line(&role))
        }
        _ => AgentToolCall::new(name, first_short_arg(args)),
    }
}

fn first_short_arg(args: &Object) -> String {
    let mut keys: Vec<&String> = args.keys().collect();
    keys.sort();
    for key in keys {
        let Some(value) = arg_string(args, key) else { continue };
        if char_count(&value) <= 200 && !value.contains('\n') {
            return first_line(&value);
        }
    }
    String::new()
}
