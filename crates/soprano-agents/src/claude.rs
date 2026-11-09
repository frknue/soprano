//! Claude Code's session transcript (`ClaudeTranscriptDecoder.swift`).

use serde_json::Value;

use crate::json::{Object, bool_true, number_int, obj_at, objects, parse_object, str_at};
use crate::timeline::{
    AgentTimelineItem, AgentToolCall, AgentToolResult, AgentTranscriptDecoding, AgentTranscriptEntry, Date,
    TimelineItemKind, ToolCallState, date_from_value, diff_excerpt, display_path, excerpt, first_line,
    trim_newlines,
};

/// Reads Claude Code's session transcript (`~/.claude/projects/<slug>/<session>.jsonl`).
///
/// Every record carrying a `uuid` is a node of the conversation tree, even when it shows
/// nothing, because a rewind starts a new branch from any of them and the timeline must follow
/// the newest leaf. Records without one (titles, modes, file-history snapshots, …) are session
/// bookkeeping.
#[derive(Clone, Debug, Default)]
pub struct ClaudeTranscriptDecoder {
    /// The session's working directory, so file tools show repo-relative paths.
    cwd: Option<String>,
}

impl ClaudeTranscriptDecoder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cwd(&self) -> Option<&str> {
        self.cwd.as_deref()
    }
}

impl AgentTranscriptDecoding for ClaudeTranscriptDecoder {
    fn entry_for_line(&mut self, line: &[u8]) -> Option<AgentTranscriptEntry> {
        let record = parse_object(line)?;
        if let Some(cwd) = str_at(&record, "cwd").filter(|c| !c.is_empty()) {
            self.cwd = Some(cwd.to_owned());
        }
        // Subagent chains interleave with the main one; letting them in would make a subagent's
        // last message the leaf and hide the conversation.
        if bool_true(&record, "isSidechain") {
            return None;
        }
        let uuid = str_at(&record, "uuid")?.to_owned();

        // Compaction restarts the chain with a null parent and keeps the link in
        // `logicalParentUuid`; following it keeps pre-compaction history.
        let parent = str_at(&record, "parentUuid").or_else(|| str_at(&record, "logicalParentUuid"));
        let mut entry = AgentTranscriptEntry::node(uuid.clone(), parent.map(str::to_owned));
        let timestamp = date_from_value(record.get("timestamp"));

        match str_at(&record, "type") {
            Some("system") => {
                if let Some(notice) = system_notice(&record) {
                    entry.items = vec![AgentTimelineItem::new(uuid, timestamp, notice)];
                }
            }
            Some("user") => decode_user(&record, &uuid, timestamp, &mut entry),
            Some("assistant") => self.decode_assistant(&record, &uuid, timestamp, &mut entry),
            _ => {}
        }
        Some(entry)
    }
}

fn system_notice(record: &Object) -> Option<TimelineItemKind> {
    let subtype = str_at(record, "subtype").unwrap_or("");
    let content = str_at(record, "content").unwrap_or("").trim();
    if subtype == "compact_boundary" {
        return Some(TimelineItemKind::notice("Conversation compacted", false));
    }
    if str_at(record, "level") == Some("error") || subtype.contains("error") {
        return Some(TimelineItemKind::notice(if content.is_empty() { subtype } else { content }, true));
    }
    if subtype == "local_command"
        && let Some(command) = slash_command(content)
    {
        return Some(TimelineItemKind::notice(command, false));
    }
    None
}

fn decode_user(record: &Object, uuid: &str, timestamp: Option<Date>, entry: &mut AgentTranscriptEntry) {
    // Meta records are context Claude Code injects (skill bodies, caveats), not something the
    // person typed.
    if bool_true(record, "isMeta") {
        return;
    }
    let Some(message) = obj_at(record, "message") else { return };

    if let Some(text) = str_at(message, "content") {
        if let Some(kind) = user_text_kind(text) {
            entry.items = vec![AgentTimelineItem::new(uuid, timestamp, kind)];
        }
        return;
    }
    let Some(parts) = objects(message.get("content")) else { return };

    let mut texts: Vec<String> = Vec::new();
    let mut tool_results: Vec<(String, AgentToolResult)> = Vec::new();
    for part in parts {
        match str_at(part, "type") {
            Some("text") => {
                if let Some(text) = str_at(part, "text") {
                    texts.push(text.to_owned());
                }
            }
            Some("image") => texts.push("[image]".into()),
            Some("tool_result") => {
                let Some(call_id) = str_at(part, "tool_use_id") else { continue };
                let mut result = AgentToolResult::new(if bool_true(part, "is_error") {
                    ToolCallState::Failed
                } else {
                    ToolCallState::Succeeded
                });
                result.output = excerpt(tool_result_text(part.get("content")).as_deref());
                result.finished_at = timestamp;
                tool_results.push((call_id.to_owned(), result));
            }
            _ => {}
        }
    }

    // `toolUseResult` describes the single tool this record answers, so it can only refine the
    // result when there is exactly one.
    if tool_results.len() == 1
        && let Some(structured) = obj_at(record, "toolUseResult")
    {
        refine(&mut tool_results[0].1, structured);
    }
    for (call_id, result) in tool_results {
        entry.results.insert(call_id, result);
    }

    let joined = texts.iter().map(|t| t.trim()).filter(|t| !t.is_empty()).collect::<Vec<_>>().join("\n\n");
    if let Some(kind) = prompt_kind(&joined) {
        entry.items = vec![AgentTimelineItem::new(uuid, timestamp, kind)];
    }
}

/// What a plain-string user message shows. Claude Code stores slash commands, bash mode, and
/// their output as tagged strings.
fn user_text_kind(text: &str) -> Option<TimelineItemKind> {
    if let Some(command) = slash_command(text) {
        return Some(TimelineItemKind::Prompt(command));
    }
    let trimmed = text.trim();
    for output_tag in [
        "<local-command-stdout>",
        "<local-command-stderr>",
        "<local-command-caveat>",
        "<bash-stdout>",
        "<bash-stderr>",
    ] {
        if trimmed.starts_with(output_tag) {
            return None;
        }
    }
    if let Some(command) = tag_content("bash-input", trimmed) {
        return Some(TimelineItemKind::Prompt(format!("! {}", command.trim())));
    }
    prompt_kind(trimmed)
}

fn prompt_kind(text: &str) -> Option<TimelineItemKind> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.starts_with("[Request interrupted by user") {
        return Some(TimelineItemKind::notice("Interrupted", false));
    }
    Some(TimelineItemKind::Prompt(trimmed.to_owned()))
}

/// "/name args" from a `<command-name>` tagged string.
fn slash_command(text: &str) -> Option<String> {
    let name = tag_content("command-name", text)?.trim();
    if name.is_empty() {
        return None;
    }
    let command = if name.starts_with('/') { name.to_owned() } else { format!("/{name}") };
    let arguments = tag_content("command-args", text).unwrap_or("").trim();
    Some(if arguments.is_empty() { command } else { format!("{command} {arguments}") })
}

fn tag_content<'a>(tag: &str, text: &'a str) -> Option<&'a str> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let start = text.find(&open)? + open.len();
    let end = text[start..].find(&close)? + start;
    Some(&text[start..end])
}

/// The text of a `tool_result` content, which is a string or an array of parts; images and tool
/// references have nothing to show as output.
fn tool_result_text(content: Option<&Value>) -> Option<String> {
    if let Some(text) = content.and_then(Value::as_str) {
        return Some(text.to_owned());
    }
    let parts = objects(content)?;
    let texts: Vec<&str> = parts
        .iter()
        .filter(|p| str_at(p, "type") == Some("text"))
        .filter_map(|p| str_at(p, "text"))
        .collect();
    if texts.is_empty() { None } else { Some(texts.join("\n")) }
}

/// Replaces the model-facing result text with what the tool actually did: the edit's patch, the
/// created file, or the command's own output.
fn refine(result: &mut AgentToolResult, structured: &Object) {
    if let Some(hunks) = objects(structured.get("structuredPatch")).filter(|h| !h.is_empty()) {
        let mut lines: Vec<String> = Vec::new();
        for hunk in hunks {
            let int = |key: &str| number_int(hunk.get(key)).unwrap_or(0);
            lines.push(format!(
                "@@ -{},{} +{},{} @@",
                int("oldStart"),
                int("oldLines"),
                int("newStart"),
                int("newLines")
            ));
            if let Some(body) = crate::json::strings(hunk.get("lines")) {
                lines.extend(body.into_iter().map(str::to_owned));
            }
        }
        result.diff = diff_excerpt(Some(&lines.join("\n")));
        result.output = None;
        return;
    }
    if str_at(structured, "type") == Some("create")
        && let Some(content) = str_at(structured, "content")
    {
        let mut lines: Vec<&str> = content.split('\n').collect();
        if content.ends_with('\n') {
            lines.pop();
        }
        let body = lines.iter().map(|l| format!("+{l}")).collect::<Vec<_>>().join("\n");
        result.diff = diff_excerpt(Some(&body));
        result.output = None;
        return;
    }
    let stdout = str_at(structured, "stdout");
    let stderr = str_at(structured, "stderr");
    if stdout.is_some() || stderr.is_some() {
        let streams: Vec<&str> =
            [stdout, stderr].into_iter().flatten().map(trim_newlines).filter(|s| !s.is_empty()).collect();
        result.output = excerpt(Some(&streams.join("\n")));
        if bool_true(structured, "interrupted") {
            result.state = ToolCallState::Interrupted;
        }
    }
}

impl ClaudeTranscriptDecoder {
    fn decode_assistant(
        &self,
        record: &Object,
        uuid: &str,
        timestamp: Option<Date>,
        entry: &mut AgentTranscriptEntry,
    ) {
        let parts = obj_at(record, "message").and_then(|m| objects(m.get("content"))).unwrap_or_default();

        if bool_true(record, "isApiErrorMessage") {
            let text = parts
                .iter()
                .filter(|p| str_at(p, "type") == Some("text"))
                .filter_map(|p| str_at(p, "text"))
                .collect::<Vec<_>>()
                .join("\n");
            let text = text.trim();
            let message = if text.is_empty() {
                str_at(record, "error").unwrap_or("API error").to_owned()
            } else {
                text.to_owned()
            };
            entry.items =
                vec![AgentTimelineItem::new(uuid, timestamp, TimelineItemKind::notice(message, true))];
            return;
        }

        let count = parts.len();
        for (index, part) in parts.into_iter().enumerate() {
            let item_id = if count > 1 { format!("{uuid}#{index}") } else { uuid.to_owned() };
            match str_at(part, "type") {
                Some("thinking") => {
                    let text = str_at(part, "thinking").unwrap_or("").trim().to_owned();
                    entry.items.push(AgentTimelineItem::new(
                        item_id,
                        timestamp,
                        TimelineItemKind::Thinking(text),
                    ));
                }
                Some("redacted_thinking") => {
                    entry.items.push(AgentTimelineItem::new(
                        item_id,
                        timestamp,
                        TimelineItemKind::Thinking(String::new()),
                    ));
                }
                Some("text") => {
                    let text = str_at(part, "text").unwrap_or("").trim();
                    if text.is_empty() {
                        continue;
                    }
                    entry.items.push(AgentTimelineItem::new(
                        item_id,
                        timestamp,
                        TimelineItemKind::Reply(text.to_owned()),
                    ));
                }
                Some("tool_use") => {
                    let (Some(call_id), Some(name)) = (str_at(part, "id"), str_at(part, "name")) else {
                        continue;
                    };
                    let call = tool_call(name, input_of(part), self.cwd.as_deref());
                    entry.items.push(AgentTimelineItem::new(
                        call_id,
                        timestamp,
                        TimelineItemKind::Tool(call),
                    ));
                }
                Some("server_tool_use") => {
                    let (Some(call_id), Some(name)) = (str_at(part, "id"), str_at(part, "name")) else {
                        continue;
                    };
                    if name == "advisor" {
                        continue;
                    }
                    let name = if name == "web_search" { "WebSearch" } else { name };
                    let call = tool_call(name, input_of(part), self.cwd.as_deref());
                    entry.items.push(AgentTimelineItem::new(
                        call_id,
                        timestamp,
                        TimelineItemKind::Tool(call),
                    ));
                }
                Some("web_search_tool_result") => {
                    let Some(call_id) = str_at(part, "tool_use_id") else { continue };
                    let mut result = AgentToolResult::new(ToolCallState::Succeeded);
                    result.finished_at = timestamp;
                    entry.results.insert(call_id.to_owned(), result);
                }
                _ => {}
            }
        }
    }
}

fn input_of(part: &Object) -> &Object {
    crate::json::dict(part.get("input"))
}

/// Name, one-line summary, and fuller detail for a tool call, picked per Claude Code tool so the
/// row says what the call touches.
pub fn tool_call(name: &str, input: &Object, cwd: Option<&str>) -> AgentToolCall {
    let string = |key: &str| -> Option<String> {
        let trimmed = str_at(input, key)?.trim();
        if trimmed.is_empty() { None } else { Some(trimmed.to_owned()) }
    };
    let path = |key: &str| string(key).map(|p| display_path(&p, cwd)).unwrap_or_default();

    match name {
        "Bash" => {
            let command = string("command").unwrap_or_default();
            let summary =
                string("description").map(|d| first_line(&d)).unwrap_or_else(|| first_line(&command));
            let detail = (command.contains('\n') || command != summary)
                .then(|| command.clone())
                .filter(|d| !d.is_empty());
            return AgentToolCall { detail, ..AgentToolCall::new(name, summary) };
        }
        "Read" | "Edit" | "MultiEdit" | "Write" => return AgentToolCall::new(name, path("file_path")),
        "NotebookEdit" => return AgentToolCall::new(name, path("notebook_path")),
        "Grep" => {
            let pattern = string("pattern").unwrap_or_default();
            let scope = string("path").map(|p| format!(" in {}", display_path(&p, cwd))).unwrap_or_default();
            return AgentToolCall::new(name, first_line(&(pattern + &scope)));
        }
        "Glob" => return AgentToolCall::new(name, first_line(&string("pattern").unwrap_or_default())),
        "WebFetch" => return AgentToolCall::new(name, string("url").unwrap_or_default()),
        "WebSearch" | "ToolSearch" => {
            return AgentToolCall::new(name, first_line(&string("query").unwrap_or_default()));
        }
        "Task" | "Agent" => {
            let description = string("description").unwrap_or_default();
            let summary = match string("subagent_type") {
                Some(kind) => format!("{description} ({kind})"),
                None => description,
            };
            return AgentToolCall::new(name, first_line(&summary));
        }
        "TodoWrite" => {
            let count = input.get("todos").and_then(Value::as_array).map_or(0, Vec::len);
            return AgentToolCall::new(name, format!("Update todos ({count})"));
        }
        "Skill" => {
            return AgentToolCall::new(
                name,
                string("skill").or_else(|| string("command")).unwrap_or_default(),
            );
        }
        _ => {}
    }

    if let Some(qualified) = name.strip_prefix("mcp__") {
        let label = match qualified.find("__") {
            Some(separator) => format!("{} · {}", &qualified[..separator], &qualified[separator + 2..]),
            None => qualified.to_owned(),
        };
        let preferred = ["query", "prompt", "url", "path", "file_path", "title", "description", "task_id"]
            .iter()
            .find_map(|key| string(key));
        let summary = preferred.map(|p| first_line(&p)).unwrap_or_else(|| first_short_string(input));
        return AgentToolCall::new(label, summary);
    }
    AgentToolCall::new(name, first_short_string(input))
}

/// The first short string argument, so unknown tools still say something.
fn first_short_string(input: &Object) -> String {
    let mut keys: Vec<&String> = input.keys().collect();
    keys.sort();
    for key in keys {
        let Some(value) = str_at(input, key) else { continue };
        let trimmed = value.trim();
        if !trimmed.is_empty() && crate::timeline::char_count(trimmed) <= 200 && !trimmed.contains('\n') {
            return first_line(trimmed);
        }
    }
    String::new()
}
