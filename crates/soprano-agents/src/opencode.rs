//! OpenCode's stored messages (`OpenCodeMessageDecoder.swift`).

use serde_json::Value;

use crate::json::{
    Object, bool_true, dict, non_empty, number_f64, number_int, obj_at, objects_at, parse_object, str_at,
};
use crate::timeline::{
    AgentTimelineItem, AgentToolCall, AgentTranscriptEntry, Date, TimelineItemKind, ToolCallState,
    char_count, date_from_millis, diff_excerpt, display_path, excerpt, first_line, trim_spaces,
};

/// One `session_part` row: the content item's `type` column and its JSON, which leaves the type
/// out.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PartRow {
    pub kind: String,
    pub data: Vec<u8>,
}

impl PartRow {
    pub fn new(kind: impl Into<String>, data: impl Into<Vec<u8>>) -> Self {
        Self { kind: kind.into(), data: data.into() }
    }
}

/// Maps OpenCode's stored messages to timeline entries. OpenCode keeps a session in SQLite
/// instead of JSON Lines: 2.x writes one `session_message` row per message, its assistant
/// content inline or in `session_part` rows, and 1.x one `message` row whose content lives in
/// `part` rows. Both arrive here as the rows' JSON, so the mapping needs no database.
#[derive(Clone, Debug, Default)]
pub struct OpenCodeMessageDecoder {
    /// The session's directory; tool paths are shown relative to it.
    pub cwd: Option<String>,
}

const EDITING_TOOLS: [&str; 4] = ["edit", "write", "patch", "apply_patch"];

impl OpenCodeMessageDecoder {
    pub fn new(cwd: Option<String>) -> Self {
        Self { cwd }
    }

    // MARK: - OpenCode 2.x

    /// The entry for one 2.x `session_message` row. An assistant row's `parts`, in ordinal
    /// order, replace its inline `content` when there are any.
    pub fn entry(&self, id: &str, kind: &str, data: &[u8], parts: &[PartRow]) -> AgentTranscriptEntry {
        let Some(message) = parse_object(data) else { return AgentTranscriptEntry::default() };
        let timestamp = date(dict(message.get("time")).get("created"));
        let mut items = Vec::new();

        match kind {
            "user" => {
                let mut lines = vec![str_at(&message, "text").unwrap_or("").to_owned()];
                for file in objects_at(&message, "files") {
                    lines.push(placeholder(str_at(file, "mime"), str_at(file, "name")));
                }
                if let Some(text) = prompt(&lines) {
                    items = vec![AgentTimelineItem::new(id, timestamp, TimelineItemKind::Prompt(text))];
                }
            }
            "assistant" => {
                let content: Vec<Object> = if parts.is_empty() {
                    objects_at(&message, "content").into_iter().cloned().collect()
                } else {
                    parts
                        .iter()
                        .filter_map(|part| {
                            let mut item = parse_object(&part.data)?;
                            item.insert("type".into(), Value::String(part.kind.clone()));
                            Some(item)
                        })
                        .collect()
                };
                for (index, item) in content.iter().enumerate() {
                    if let Some(timeline_item) = self.content_item(item, id, index, timestamp) {
                        items.push(timeline_item);
                    }
                }
                if let Some(error) = obj_at(&message, "error") {
                    // Pressing Esc aborts the step; that is an interruption, not a failure.
                    let notice = if str_at(error, "type") == Some("aborted") {
                        TimelineItemKind::notice("Interrupted", false)
                    } else {
                        let text = non_empty(error.get("message"))
                            .or_else(|| non_empty(error.get("type")))
                            .unwrap_or("Error");
                        TimelineItemKind::notice(text, true)
                    };
                    items.push(AgentTimelineItem::new(format!("{id}#error"), timestamp, notice));
                }
            }
            "idle" => match str_at(&message, "outcome") {
                Some("interrupted") => {
                    items = vec![AgentTimelineItem::new(
                        id,
                        timestamp,
                        TimelineItemKind::notice("Interrupted", false),
                    )];
                }
                Some("failed") => {
                    let text = non_empty(dict(message.get("error")).get("message")).unwrap_or("Failed");
                    items = vec![AgentTimelineItem::new(id, timestamp, TimelineItemKind::notice(text, true))];
                }
                _ => {}
            },
            "compaction" => {
                let kind = if str_at(&message, "status") == Some("failed") {
                    let reason = non_empty(dict(message.get("error")).get("message"));
                    let text = match reason {
                        Some(reason) => format!("Context compaction failed: {reason}"),
                        None => "Context compaction failed".into(),
                    };
                    TimelineItemKind::notice(text, true)
                } else {
                    TimelineItemKind::notice("Context compacted", false)
                };
                items = vec![AgentTimelineItem::new(id, timestamp, kind)];
            }
            "shell" => {
                items = vec![AgentTimelineItem::new(
                    id,
                    timestamp,
                    TimelineItemKind::Tool(self.shell_call(&message)),
                )]
            }
            // `synthetic` and `system` are injected rather than typed; skills and agent, model
            // and location switches have nothing to show.
            _ => {}
        }
        AgentTranscriptEntry::with_items(items)
    }

    fn content_item(
        &self,
        item: &Object,
        message_id: &str,
        index: usize,
        timestamp: Option<Date>,
    ) -> Option<AgentTimelineItem> {
        let item_id = format!("{message_id}#{index}");
        match str_at(item, "type") {
            Some("text") => {
                let text = non_empty(item.get("text"))?;
                Some(AgentTimelineItem::new(item_id, timestamp, TimelineItemKind::Reply(text.to_owned())))
            }
            // Empty when the provider returned only encrypted reasoning.
            Some("reasoning") => Some(AgentTimelineItem::new(
                item_id,
                timestamp,
                TimelineItemKind::Thinking(str_at(item, "text").unwrap_or("").to_owned()),
            )),
            Some("tool") => {
                let call_id = str_at(item, "id")?;
                let state = dict(item.get("state"));
                let time = dict(item.get("time"));
                let metadata = dict(state.get("metadata"));
                let call_state = match str_at(state, "status") {
                    Some("completed") if exited_non_zero(metadata) => ToolCallState::Failed,
                    Some("completed") => ToolCallState::Succeeded,
                    Some("error") => ToolCallState::Failed,
                    _ => ToolCallState::Running,
                };
                let content = objects_at(state, "content")
                    .into_iter()
                    .filter(|p| str_at(p, "type") == Some("text"))
                    .filter_map(|p| str_at(p, "text"))
                    .collect::<Vec<_>>()
                    .join("\n");
                let error = str_at(dict(state.get("error")), "message").unwrap_or("");
                let output = [content.as_str(), error]
                    .into_iter()
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join("\n");
                Some(AgentTimelineItem::new(
                    call_id,
                    date(time.get("created")).or(timestamp),
                    TimelineItemKind::Tool(self.tool_call(
                        str_at(item, "name").unwrap_or("tool"),
                        // A streaming call's input is still a partial JSON string.
                        dict(state.get("input")),
                        metadata,
                        call_state,
                        &output,
                        date(time.get("completed")),
                    )),
                ))
            }
            _ => None,
        }
    }

    /// A command the person ran from OpenCode's prompt with `!`.
    fn shell_call(&self, message: &Object) -> AgentToolCall {
        let command = str_at(message, "command").unwrap_or("");
        let summary = first_line(command);
        let exit = number_int(message.get("exit"));
        let state = match str_at(message, "status") {
            Some("exited") if exit.unwrap_or(0) == 0 => ToolCallState::Succeeded,
            Some("exited" | "timeout" | "killed") => ToolCallState::Failed,
            _ => ToolCallState::Running,
        };
        let output = match message.get("output") {
            Some(Value::String(text)) => Some(text.as_str()),
            other => {
                let object = dict(other);
                str_at(object, "text").or_else(|| str_at(object, "content"))
            }
        };
        AgentToolCall {
            detail: (!command.is_empty() && command != summary).then(|| command.to_owned()),
            state,
            output: excerpt(output),
            finished_at: date(dict(message.get("time")).get("completed")),
            ..AgentToolCall::new("Shell", summary)
        }
    }

    // MARK: - OpenCode 1.x

    /// The entry for one 1.x `message` row and its `part` rows in id order.
    pub fn legacy_entry(&self, id: &str, data: &[u8], parts: &[Vec<u8>]) -> AgentTranscriptEntry {
        let Some(message) = parse_object(data) else { return AgentTranscriptEntry::default() };
        let timestamp = date(dict(message.get("time")).get("created"));
        let parts: Vec<Object> = parts.iter().filter_map(|p| parse_object(p)).collect();
        let mut items = Vec::new();

        match str_at(&message, "role") {
            Some("user") => {
                let mut lines: Vec<String> = Vec::new();
                let mut compacted = false;
                for part in &parts {
                    match str_at(part, "type") {
                        Some("text") if !bool_true(part, "synthetic") => {
                            lines.push(str_at(part, "text").unwrap_or("").to_owned());
                        }
                        Some("file") => {
                            lines.push(placeholder(str_at(part, "mime"), str_at(part, "filename")))
                        }
                        Some("compaction") => compacted = true,
                        _ => {}
                    }
                }
                if let Some(text) = prompt(&lines) {
                    items.push(AgentTimelineItem::new(id, timestamp, TimelineItemKind::Prompt(text)));
                }
                if compacted {
                    items.push(AgentTimelineItem::new(
                        format!("{id}#compaction"),
                        timestamp,
                        TimelineItemKind::notice("Context compacted", false),
                    ));
                }
            }
            Some("assistant") => {
                // A compaction's summary is written as an assistant message.
                let is_summary = bool_true(&message, "summary");
                for (index, part) in parts.iter().enumerate() {
                    let item_id = format!("{id}#{index}");
                    match str_at(part, "type") {
                        Some("text") => {
                            if is_summary || bool_true(part, "synthetic") {
                                continue;
                            }
                            let Some(text) = non_empty(part.get("text")) else { continue };
                            items.push(AgentTimelineItem::new(
                                item_id,
                                timestamp,
                                TimelineItemKind::Reply(text.to_owned()),
                            ));
                        }
                        Some("reasoning") => items.push(AgentTimelineItem::new(
                            item_id,
                            timestamp,
                            TimelineItemKind::Thinking(str_at(part, "text").unwrap_or("").to_owned()),
                        )),
                        Some("tool") => items.push(self.legacy_tool_item(part, &item_id, timestamp)),
                        _ => {}
                    }
                }
                if let Some(error) = obj_at(&message, "error") {
                    if str_at(error, "name") == Some("MessageAbortedError") {
                        items.push(AgentTimelineItem::new(
                            format!("{id}#error"),
                            timestamp,
                            TimelineItemKind::notice("Interrupted", false),
                        ));
                    } else {
                        let text = non_empty(dict(error.get("data")).get("message"))
                            .or_else(|| non_empty(error.get("name")))
                            .unwrap_or("Error");
                        items.push(AgentTimelineItem::new(
                            format!("{id}#error"),
                            timestamp,
                            TimelineItemKind::notice(text, true),
                        ));
                    }
                }
            }
            _ => {}
        }
        AgentTranscriptEntry::with_items(items)
    }

    fn legacy_tool_item(
        &self,
        part: &Object,
        fallback_id: &str,
        timestamp: Option<Date>,
    ) -> AgentTimelineItem {
        let state = dict(part.get("state"));
        let time = dict(state.get("time"));
        let metadata = dict(state.get("metadata"));
        let call_state = match str_at(state, "status") {
            Some("completed") if exited_non_zero(metadata) => ToolCallState::Failed,
            Some("completed") => ToolCallState::Succeeded,
            Some("error") => ToolCallState::Failed,
            _ => ToolCallState::Running,
        };
        let output = [str_at(state, "output").unwrap_or(""), str_at(state, "error").unwrap_or("")]
            .into_iter()
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join("\n");
        let id = non_empty(part.get("callID")).or_else(|| non_empty(part.get("id"))).unwrap_or(fallback_id);
        AgentTimelineItem::new(
            id,
            date(time.get("start")).or(timestamp),
            TimelineItemKind::Tool(self.tool_call(
                str_at(part, "tool").unwrap_or("tool"),
                dict(state.get("input")),
                metadata,
                call_state,
                &output,
                date(time.get("end")),
            )),
        )
    }

    // MARK: - Tool calls

    fn tool_call(
        &self,
        name: &str,
        input: &Object,
        metadata: &Object,
        state: ToolCallState,
        output: &str,
        finished_at: Option<Date>,
    ) -> AgentToolCall {
        let mut call = self.describe(name, input);
        call.state = state;
        call.output = excerpt(Some(output));
        call.finished_at = finished_at;
        if EDITING_TOOLS.contains(&name)
            && let Some((diff, paths)) = self.file_change(metadata)
        {
            call.diff = Some(diff);
            call.output = None;
            if let Some(paths) = paths {
                call.summary = paths;
            }
        }
        call
    }

    fn describe(&self, name: &str, input: &Object) -> AgentToolCall {
        // 2.x tools take `path`; sessions migrated from 1.x keep `filePath`.
        let path = non_empty(input.get("path"))
            .or_else(|| non_empty(input.get("filePath")))
            .map(|p| self.display(p));
        let searched = |label: &str| {
            let pattern = str_at(input, "pattern").unwrap_or("");
            AgentToolCall::new(
                label,
                path.as_ref().map(|p| format!("{pattern} in {p}")).unwrap_or_else(|| pattern.to_owned()),
            )
        };

        match name {
            "shell" | "bash" => {
                let command = str_at(input, "command").unwrap_or("");
                let summary = first_line(command);
                let detail = (!command.is_empty() && command != summary).then(|| command.to_owned());
                AgentToolCall { detail, ..AgentToolCall::new("Bash", summary) }
            }
            "read" => AgentToolCall::new("Read", path.clone().unwrap_or_default()),
            "edit" => AgentToolCall::new("Edit", path.clone().unwrap_or_default()),
            "write" => AgentToolCall::new("Write", path.clone().unwrap_or_default()),
            "patch" | "apply_patch" => {
                let patch_path =
                    str_at(input, "patchText").and_then(first_patch_path).map(|p| self.display(&p));
                AgentToolCall::new("Edit", patch_path.unwrap_or_default())
            }
            "glob" => searched("Glob"),
            "grep" => searched("Grep"),
            "webfetch" => AgentToolCall::new("WebFetch", non_empty(input.get("url")).unwrap_or("")),
            "websearch" => AgentToolCall::new(
                "WebSearch",
                non_empty(input.get("query")).map(first_line).unwrap_or_default(),
            ),
            "subagent" | "task" => AgentToolCall::new(
                "Task",
                non_empty(input.get("description")).map(first_line).unwrap_or_default(),
            ),
            "todowrite" => {
                let count = input.get("todos").and_then(Value::as_array).map_or(0, Vec::len);
                AgentToolCall::new(
                    "Todo",
                    if count == 1 { "1 todo".to_owned() } else { format!("{count} todos") },
                )
            }
            "question" => {
                let question =
                    objects_at(input, "questions").into_iter().find_map(|q| non_empty(q.get("question")));
                AgentToolCall::new("Ask", question.map(first_line).unwrap_or_default())
            }
            // 1.x names the skill, 2.x passes its id.
            "skill" => AgentToolCall::new(
                "Skill",
                non_empty(input.get("name")).or_else(|| non_empty(input.get("id"))).unwrap_or(""),
            ),
            // MCP tools arrive as `<server>_<tool>`.
            _ => AgentToolCall::new(name, summary_of_arguments(input)),
        }
    }

    // MARK: - Diffs

    /// The hunks an edit, write or patch result recorded, and the files they changed. 2.x lists
    /// each file with its own patch; 1.x keeps one diff text that may cover several files, or
    /// one `filediff`.
    fn file_change(&self, metadata: &Object) -> Option<(String, Option<String>)> {
        let mut patches: Vec<(Option<String>, &str)> = Vec::new();
        let files = objects_at(metadata, "files");
        if !files.is_empty() {
            patches = files
                .into_iter()
                .filter_map(|file| {
                    let patch = str_at(file, "patch")?;
                    let path = non_empty(file.get("file")).or_else(|| non_empty(file.get("filePath")));
                    Some((path.map(str::to_owned), patch))
                })
                .collect();
        } else if let Some(diff) = str_at(metadata, "diff") {
            patches = vec![(None, diff)];
        } else if let Some(filediff) = obj_at(metadata, "filediff")
            && let Some(patch) = str_at(filediff, "patch")
        {
            patches = vec![(non_empty(filediff.get("file")).map(str::to_owned), patch)];
        }

        let mut sections: Vec<(Option<String>, Vec<String>)> = Vec::new();
        for (path, patch) in patches {
            let mut parsed = hunks(patch);
            if parsed.len() == 1
                && let Some(path) = path
            {
                sections.push((Some(path), parsed.remove(0).1));
            } else {
                sections.extend(parsed);
            }
        }
        if sections.is_empty() {
            return None;
        }

        let several = sections.len() > 1;
        let diff = sections
            .iter()
            .map(|(path, lines)| {
                let body = lines.join("\n");
                match path {
                    Some(path) if several => format!("diff {}\n{body}", self.display(path)),
                    _ => body,
                }
            })
            .collect::<Vec<_>>()
            .join("\n");
        let excerpt = diff_excerpt(Some(&diff))?;
        let paths: Vec<String> =
            sections.iter().filter_map(|(p, _)| p.as_deref()).map(|p| self.display(p)).collect();
        Some((excerpt, if paths.is_empty() { None } else { Some(paths.join(", ")) }))
    }

    fn display(&self, path: &str) -> String {
        display_path(path, self.cwd.as_deref())
    }
}

fn summary_of_arguments(arguments: &Object) -> String {
    for key in ["title", "description", "query", "path", "filePath", "url", "command"] {
        if let Some(value) = non_empty(arguments.get(key)) {
            return first_line(value);
        }
    }
    let mut keys: Vec<&String> = arguments.keys().collect();
    keys.sort();
    keys.into_iter()
        .filter_map(|k| str_at(arguments, k))
        .find(|v| !v.is_empty() && char_count(v) <= 160 && !v.contains('\n'))
        .map(first_line)
        .unwrap_or_default()
}

/// The first file an `apply_patch` envelope names, before its result lists every changed file.
fn first_patch_path(patch_text: &str) -> Option<String> {
    for line in patch_text.split(crate::timeline::is_newline).filter(|l| !l.is_empty()) {
        for marker in ["*** Add File: ", "*** Update File: ", "*** Delete File: "] {
            if let Some(rest) = line.strip_prefix(marker) {
                let path = trim_spaces(rest);
                return (!path.trim().is_empty()).then(|| path.to_owned());
            }
        }
    }
    None
}

type Section = (Option<String>, Vec<String>);

/// Splits a unified diff into its files and keeps only hunk lines: the `Index:`, `====`, `---`
/// and `+++` headers and `\ No newline` markers go. Hunk line counts decide where a hunk ends,
/// so a removed line that starts with `--` is never taken for a header.
fn hunks(patch: &str) -> Vec<Section> {
    struct State {
        sections: Vec<Section>,
        lines: Vec<String>,
        index_path: Option<String>,
        old_path: Option<String>,
        new_path: Option<String>,
        // Inside a hunk whose header carries no line counts.
        uncounted: bool,
    }
    impl State {
        fn flush(&mut self) {
            if !self.lines.is_empty() {
                let path = self
                    .new_path
                    .clone()
                    .or_else(|| self.old_path.clone())
                    .or_else(|| self.index_path.clone());
                self.sections.push((path, std::mem::take(&mut self.lines)));
            }
            self.index_path = None;
            self.old_path = None;
            self.new_path = None;
            self.uncounted = false;
        }
    }
    let mut state = State {
        sections: Vec::new(),
        lines: Vec::new(),
        index_path: None,
        old_path: None,
        new_path: None,
        uncounted: false,
    };
    let mut old_left: i64 = 0;
    let mut new_left: i64 = 0;

    for raw_line in patch.split('\n') {
        let line = raw_line.strip_suffix('\r').unwrap_or(raw_line);
        if line.starts_with('\\') {
            continue;
        }
        if old_left > 0 || new_left > 0 {
            match line.chars().next() {
                Some('+') => new_left -= 1,
                Some('-') => old_left -= 1,
                _ => {
                    old_left -= 1;
                    new_left -= 1;
                }
            }
            state.lines.push(if line.is_empty() { " ".into() } else { line.to_owned() });
            continue;
        }
        if line.starts_with("@@") {
            state.lines.push(line.to_owned());
            if let Some((old, new)) = hunk_counts(line) {
                old_left = old;
                new_left = new;
                state.uncounted = false;
            } else {
                state.uncounted = true;
            }
        } else if line.starts_with("Index: ") || line.starts_with("diff --git ") {
            state.flush();
            if line.starts_with("Index: ") {
                state.index_path = header_path(line);
            }
        } else if line.starts_with("--- ") {
            if !state.lines.is_empty() {
                state.flush();
            }
            state.old_path = header_path(line);
        } else if line.starts_with("+++ ") {
            state.new_path = header_path(line);
        } else if state.uncounted && matches!(line.chars().next(), Some('+' | '-' | ' ')) {
            state.lines.push(line.to_owned());
        }
    }
    state.flush();
    state.sections
}

/// The old and new line counts of an `@@ -a,b +c,d @@` header; an omitted count means one line.
fn hunk_counts(header: &str) -> Option<(i64, i64)> {
    let mut old = None;
    let mut new = None;
    for token in header.split(' ').filter(|t| !t.is_empty()).skip(1) {
        if token == "@@" {
            break;
        }
        let sign = token.chars().next()?;
        if sign != '-' && sign != '+' {
            return None;
        }
        let range: Vec<&str> = token[1..].split(',').collect();
        if range.len() > 2 || range[0].parse::<i64>().is_err() {
            return None;
        }
        let count = if range.len() == 2 { range[1].parse::<i64>().ok() } else { Some(1) };
        if sign == '-' {
            old = count;
        } else {
            new = count;
        }
    }
    Some((old?, new?))
}

/// The file a diff header names, without the timestamp after a tab; `/dev/null` names none.
fn header_path(line: &str) -> Option<String> {
    let rest = line.split_once(' ').map_or("", |(_, rest)| rest);
    let path = trim_spaces(rest.split('\t').next().unwrap_or(""));
    if path.is_empty() || path == "/dev/null" { None } else { Some(path.to_owned()) }
}

/// Whether a shell tool reported a non-zero exit code.
fn exited_non_zero(metadata: &Object) -> bool {
    number_int(metadata.get("exit")).is_some_and(|exit| exit != 0)
}

fn placeholder(mime: Option<&str>, name: Option<&str>) -> String {
    if mime.is_some_and(|m| m.starts_with("image/")) {
        return "[image]".into();
    }
    match name.filter(|n| !n.trim().is_empty()) {
        Some(name) => format!("[file {name}]"),
        None => "[file]".into(),
    }
}

/// The prompt shown for a message's typed text and attachments, or `None` when nothing but
/// whitespace was sent.
fn prompt(lines: &[String]) -> Option<String> {
    let text = lines.iter().filter(|l| !l.is_empty()).cloned().collect::<Vec<_>>().join("\n");
    (!text.trim().is_empty()).then_some(text)
}

/// OpenCode stores times as epoch milliseconds.
fn date(value: Option<&Value>) -> Option<Date> {
    number_f64(value).and_then(date_from_millis)
}
