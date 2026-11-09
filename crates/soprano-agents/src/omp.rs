//! omp's session files (`OmpSessionDecoder.swift`).

use serde_json::Value;

use crate::json::{
    Object, bool_true, dict, non_empty, number_int, obj_at, objects, objects_at, parse_object, str_at,
};
use crate::timeline::{
    AgentTimelineItem, AgentToolCall, AgentToolResult, AgentTranscriptDecoding, AgentTranscriptEntry, Date,
    TimelineItemKind, ToolCallState, date_from_value, diff_excerpt, display_path, excerpt, first_line,
};

/// Reads omp's session files (`~/.omp/agent/sessions/<cwd>/<id>.jsonl`). Every record after the
/// header hangs off its parent, so rewinding starts a new branch; records that show nothing
/// still stay as nodes so the branch walk can pass through them.
#[derive(Clone, Debug, Default)]
pub struct OmpSessionDecoder {
    /// From the session header; tool paths are shown relative to it.
    cwd: Option<String>,
}

impl OmpSessionDecoder {
    pub fn new(cwd: Option<String>) -> Self {
        Self { cwd }
    }

    pub fn cwd(&self) -> Option<&str> {
        self.cwd.as_deref()
    }
}

impl AgentTranscriptDecoding for OmpSessionDecoder {
    fn entry_for_line(&mut self, line: &[u8]) -> Option<AgentTranscriptEntry> {
        let record = parse_object(line)?;
        let kind = str_at(&record, "type")?;
        if kind == "session" {
            self.cwd = str_at(&record, "cwd").map(str::to_owned);
            return None;
        }
        // Records outside the tree, such as `title`, carry no id.
        let id = str_at(&record, "id")?.to_owned();
        let mut entry =
            AgentTranscriptEntry::node(id.clone(), str_at(&record, "parentId").map(str::to_owned));
        let timestamp = date_from_value(record.get("timestamp"));
        match kind {
            "message" => {
                if let Some(message) = obj_at(&record, "message") {
                    self.decode(message, &id, timestamp, &mut entry);
                }
            }
            "compaction" => {
                entry.items = vec![AgentTimelineItem::new(
                    id,
                    timestamp,
                    TimelineItemKind::notice("Context compacted", false),
                )];
            }
            _ => {}
        }
        Some(entry)
    }
}

impl OmpSessionDecoder {
    fn decode(&self, message: &Object, id: &str, timestamp: Option<Date>, entry: &mut AgentTranscriptEntry) {
        match str_at(message, "role") {
            Some("user") => {
                // omp marks messages it injects itself; only what the person typed is a prompt.
                if let Some(attribution) = str_at(message, "attribution")
                    && attribution != "user"
                {
                    return;
                }
                let text = prompt_text(message.get("content"));
                if text.trim().is_empty() {
                    return;
                }
                entry.items = vec![AgentTimelineItem::new(id, timestamp, TimelineItemKind::Prompt(text))];
            }
            Some("assistant") => entry.items = self.assistant_items(message, id, timestamp),
            Some("toolResult") => {
                let Some(call_id) = str_at(message, "toolCallId") else { return };
                entry.results.insert(call_id.to_owned(), self.result(message, timestamp));
            }
            // `developer` carries system reminders, which must never show.
            _ => {}
        }
    }

    fn assistant_items(&self, message: &Object, id: &str, timestamp: Option<Date>) -> Vec<AgentTimelineItem> {
        let mut items = Vec::new();
        for (index, part) in objects_at(message, "content").into_iter().enumerate() {
            let item_id = format!("{id}#{index}");
            match str_at(part, "type") {
                Some("thinking") => {
                    let thinking = str_at(part, "thinking").unwrap_or("").to_owned();
                    items.push(AgentTimelineItem::new(
                        item_id,
                        timestamp,
                        TimelineItemKind::Thinking(thinking),
                    ));
                }
                Some("text") => {
                    let Some(text) = str_at(part, "text").filter(|t| !t.trim().is_empty()) else { continue };
                    items.push(AgentTimelineItem::new(
                        item_id,
                        timestamp,
                        TimelineItemKind::Reply(text.to_owned()),
                    ));
                }
                Some("toolCall") => {
                    let Some(call_id) = str_at(part, "id") else { continue };
                    items.push(AgentTimelineItem::new(
                        call_id,
                        timestamp,
                        TimelineItemKind::Tool(self.tool_call(part)),
                    ));
                }
                _ => {}
            }
        }

        match str_at(message, "stopReason") {
            Some("error") => {
                if let Some(error) = str_at(message, "errorMessage").filter(|e| !e.is_empty()) {
                    items.push(AgentTimelineItem::new(
                        format!("{id}#error"),
                        timestamp,
                        TimelineItemKind::notice(error, true),
                    ));
                }
            }
            Some("aborted") => items.push(AgentTimelineItem::new(
                format!("{id}#aborted"),
                timestamp,
                TimelineItemKind::notice("Interrupted", false),
            )),
            _ => {}
        }
        items
    }

    /// A tool call from its `toolCall` part: `name`, `arguments`, `intent`. omp's ACP mode sends
    /// the same name and arguments, so chat tabs use it too.
    pub fn tool_call(&self, part: &Object) -> AgentToolCall {
        let name = str_at(part, "name").unwrap_or("tool");
        let arguments = dict(part.get("arguments"));
        // The agent's own one-line description of the call.
        let intent =
            non_empty(part.get("intent")).or_else(|| non_empty(arguments.get("i"))).map(str::to_owned);
        let path = non_empty(arguments.get("path")).map(|p| display_path(p, self.cwd.as_deref()));
        let or_intent = |value: Option<String>| value.or_else(|| intent.clone()).unwrap_or_default();

        match name {
            "bash" => {
                let command = str_at(arguments, "command").unwrap_or("");
                let summary = intent.clone().unwrap_or_else(|| first_line(command));
                let detail = (!command.is_empty() && command != summary).then(|| command.to_owned());
                AgentToolCall { detail, ..AgentToolCall::new("Bash", summary) }
            }
            "read" => AgentToolCall::new("Read", or_intent(path)),
            "edit" => AgentToolCall::new("Edit", or_intent(None)),
            "write" => AgentToolCall::new("Write", or_intent(path)),
            "grep" => {
                let pattern = str_at(arguments, "pattern").unwrap_or("");
                AgentToolCall::new(
                    "Grep",
                    path.map(|p| format!("{pattern} in {p}")).unwrap_or_else(|| pattern.to_owned()),
                )
            }
            "glob" => AgentToolCall::new("Glob", or_intent(path)),
            "eval" => {
                AgentToolCall::new("Eval", or_intent(non_empty(arguments.get("title")).map(str::to_owned)))
            }
            "web_search" => AgentToolCall::new(
                "WebSearch",
                or_intent(non_empty(arguments.get("query")).map(str::to_owned)),
            ),
            "task" => AgentToolCall::new("Task", or_intent(None)),
            "todo" => AgentToolCall::new("Todo", or_intent(None)),
            "ask" => {
                let question = objects_at(arguments, "questions")
                    .into_iter()
                    .find_map(|q| non_empty(q.get("question")))
                    .map(first_line);
                AgentToolCall::new("Ask", or_intent(question))
            }
            _ => {
                let mut chars = name.chars();
                let label = match chars.next() {
                    Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                    None => String::new(),
                };
                AgentToolCall::new(label, or_intent(None))
            }
        }
    }

    /// A tool's result from its `toolResult` message: `content`, `details`, `isError`,
    /// `toolName`. omp's ACP mode sends the same `content` and `details` as a finished call's
    /// `rawOutput`.
    pub fn result(&self, message: &Object, finished_at: Option<Date>) -> AgentToolResult {
        let details = dict(message.get("details"));
        let exit_code = number_int(details.get("exitCode")).unwrap_or(0);
        let failed = bool_true(message, "isError") || exit_code != 0;
        let text = objects(message.get("content"))
            .unwrap_or_default()
            .into_iter()
            .filter(|p| str_at(p, "type") == Some("text"))
            .filter_map(|p| str_at(p, "text"))
            .collect::<Vec<_>>()
            .join("\n");
        let mut result =
            AgentToolResult::new(if failed { ToolCallState::Failed } else { ToolCallState::Succeeded });
        result.output = excerpt(Some(&text));
        result.finished_at = finished_at;

        let tool_name = str_at(message, "toolName");
        if matches!(tool_name, Some("edit" | "write"))
            && let Some(diff) = str_at(details, "diff").and_then(unified_diff)
        {
            result.diff = diff_excerpt(Some(&diff));
            result.output = None;
            result.summary = self.changed_paths(details);
        }
        result
    }

    /// The edited file, or every file of a multi-file edit, whose results list their paths per
    /// file instead.
    fn changed_paths(&self, details: &Object) -> Option<String> {
        let paths: Vec<&str> = match non_empty(details.get("path")) {
            Some(path) => vec![path],
            None => objects_at(details, "perFileResults")
                .into_iter()
                .filter_map(|r| non_empty(r.get("path")))
                .collect(),
        };
        if paths.is_empty() {
            return None;
        }
        Some(paths.iter().map(|p| display_path(p, self.cwd.as_deref())).collect::<Vec<_>>().join(", "))
    }
}

fn prompt_text(content: Option<&Value>) -> String {
    if let Some(text) = content.and_then(Value::as_str) {
        return text.to_owned();
    }
    let Some(parts) = objects(content) else { return String::new() };
    parts
        .into_iter()
        .filter_map(|part| match str_at(part, "type") {
            Some("text") => str_at(part, "text"),
            Some("image") => Some("[image]"),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// omp numbers every diff line (` 12|kept`, `-13|old`, `+13|new`) and separates hunks with an
/// empty line; the timeline wants plain unified lines with `@@` between hunks.
fn unified_diff(diff: &str) -> Option<String> {
    let mut lines: Vec<String> = Vec::new();
    for line in diff.split('\n') {
        let numbered = line.chars().next().filter(|op| matches!(op, ' ' | '+' | '-')).and_then(|op| {
            let bar = line.find('|')?;
            line[1..bar].chars().all(|c| c.is_numeric()).then(|| format!("{op}{}", &line[bar + 1..]))
        });
        match numbered {
            Some(numbered) => lines.push(numbered),
            None => {
                if line.is_empty()
                    && let Some(last) = lines.last()
                    && last != "@@"
                {
                    lines.push("@@".into());
                }
            }
        }
    }
    while lines.last().is_some_and(|l| l == "@@") {
        lines.pop();
    }
    if lines.is_empty() { None } else { Some(lines.join("\n")) }
}
