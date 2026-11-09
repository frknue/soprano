//! Folding an ACP session's `session/update`s into the chat's turns (`ACPTurnBuilder.swift`).

use std::collections::{BTreeMap, HashMap};

use serde_json::Value;
use soprano_agents::{
    ApprovalDecision, ApprovalRequest, ChatThread, Date, FileChange, FileChangeKind, JsonValueExt, ToolCall,
    ToolCategory, Turn, TurnCommand, TurnItem, TurnItemKind, TurnItemStatus, TurnStatus, UserInputRequest,
    UserMessage, omp_edit_changes,
};

/// How a chat tab reads an agent's tool calls. omp's ACP mode sends its own tool names,
/// arguments and results, which say what each call is; any other agent is read from the
/// protocol's generic kind, title and content.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AcpToolStyle {
    Omp,
    Generic,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ChunkKind {
    Prompt,
    Reply,
    Thinking,
}

/// What a tool call said about itself so far: the call carries the name and arguments, updates
/// carry the output.
#[derive(Clone, Debug, Default, PartialEq)]
struct Tool {
    name: Option<String>,
    kind: Option<String>,
    title: Option<String>,
    args: Value,
    raw_output: Option<Value>,
    content: Vec<Value>,
}

#[derive(Clone, Debug, PartialEq)]
struct OpenChunk {
    kind: ChunkKind,
    key: Option<String>,
    item_id: String,
}

/// Folds an Agent Client Protocol session's `session/update` notifications into the chat's
/// turns ([`ChatThread`]): each prompt starts a turn; streamed reply and thinking chunks join
/// per message into its items, tool calls update their item in place, approvals and questions
/// are recorded where they happened. Agents echo a prompt only while `session/load` replays
/// history: a replayed user message starts a turn, and replayed turns carry no times.
#[derive(Clone, Debug)]
pub struct AcpTurnBuilder {
    pub cwd: Option<String>,
    pub tool_style: AcpToolStyle,
    is_replaying: bool,
    thread: ChatThread,
    tools: HashMap<String, Tool>,
    /// The streamed item the next chunk of the same kind and message continues.
    open_chunk: Option<OpenChunk>,
    next_local_id: u64,
}

impl PartialEq for AcpTurnBuilder {
    fn eq(&self, other: &Self) -> bool {
        self.thread == other.thread && self.is_replaying == other.is_replaying
    }
}

impl AcpTurnBuilder {
    pub fn new(cwd: Option<String>, tool_style: AcpToolStyle) -> Self {
        Self {
            cwd,
            tool_style,
            is_replaying: false,
            thread: ChatThread::default(),
            tools: HashMap::new(),
            open_chunk: None,
            next_local_id: 1,
        }
    }

    pub fn thread(&self) -> &ChatThread {
        &self.thread
    }

    pub fn is_replaying(&self) -> bool {
        self.is_replaying
    }

    /// Set while `session/load` replays history. Clearing it ends the last replayed turn.
    pub fn set_replaying(&mut self, replaying: bool) {
        let was = self.is_replaying;
        self.is_replaying = replaying;
        if was && !replaying {
            self.end_replayed_turn();
        }
    }

    // MARK: - Turns

    /// A prompt this chat sent: starts a turn.
    pub fn add_prompt(&mut self, text: &str, date: Date) {
        self.close_chunk(Some(date));
        let id = self.local_id("turn");
        let message_id = self.local_id("message");
        let mut turn = Turn::new(id, UserMessage::new(message_id, text, Some(date)));
        turn.started_at = Some(date);
        self.thread.turns.push(turn);
    }

    /// A message steered into the running turn; a new turn when none runs.
    pub fn add_steer(&mut self, text: &str, date: Date) {
        let Some(index) = self.active_turn_index() else { return self.add_prompt(text, date) };
        self.close_chunk(Some(date));
        let id = self.local_id("steer");
        self.thread.turns[index].steers.push(UserMessage::new(id, text, Some(date)));
    }

    /// Stop was pressed: the turn says "Stopping…" until it ends.
    pub fn mark_stop_requested(&mut self, date: Date) {
        if let Some(index) = self.active_turn_index() {
            self.thread.turns[index].stop_requested_at = Some(date);
        }
    }

    /// Ends the running turn: what was still streaming is complete, tool calls still running
    /// were cut short, and a turn that did not end normally says why (`failure`, or the stop
    /// reason).
    pub fn finish_turn(&mut self, stop_reason: Option<&str>, failure: Option<&str>, date: Date) {
        self.close_chunk(Some(date));
        let Some(index) = self.active_turn_index() else { return };
        let turn = &mut self.thread.turns[index];
        for item in &mut turn.items {
            if item.status.is_active() {
                item.status = TurnItemStatus::Interrupted;
                item.completed_at = Some(date);
            }
        }
        let reason = match stop_reason {
            Some("max_tokens") => Some("The reply reached the model's output limit."),
            Some("max_turn_requests") => Some("The turn reached its request limit."),
            Some("refusal") => Some("The model refused to continue."),
            _ => None,
        };
        if let Some(message) = failure.or(reason) {
            turn.status = TurnStatus::Failed;
            turn.failure_message = Some(message.to_owned());
        } else {
            turn.status = if stop_reason == Some("cancelled") {
                TurnStatus::Interrupted
            } else {
                TurnStatus::Completed
            };
        }
        turn.completed_at = Some(date);
        turn.stop_requested_at = None;
        mark_answer(turn);
    }

    /// A notice or error: in the running turn, else the last one, else before the first.
    pub fn add_notice(&mut self, text: &str, is_error: bool, date: Option<Date>) {
        self.close_chunk(date);
        let kind = if is_error {
            TurnItemKind::Error { message: text.to_owned() }
        } else {
            TurnItemKind::Notice { text: text.to_owned() }
        };
        let item = TurnItem {
            id: self.local_id("notice"),
            kind,
            status: TurnItemStatus::Completed,
            started_at: date,
            completed_at: date,
        };
        match self.thread.turns.last_mut() {
            Some(turn) => turn.items.push(item),
            None => self.thread.preamble.push(item),
        }
    }

    // MARK: - Approvals and questions

    pub fn add_approval(&mut self, request: ApprovalRequest, date: Date) {
        self.close_chunk(Some(date));
        let item = TurnItem {
            id: request.id.clone(),
            kind: TurnItemKind::Approval(request),
            status: TurnItemStatus::Pending,
            started_at: Some(date),
            completed_at: None,
        };
        self.append_to_active_turn(item, Some(date));
    }

    pub fn resolve_approval(&mut self, id: &str, decision: ApprovalDecision, date: Date) {
        self.update_item(id, |item| {
            let TurnItemKind::Approval(request) = &mut item.kind else { return };
            request.decision = Some(decision);
            item.status = if matches!(decision, ApprovalDecision::Decline | ApprovalDecision::Cancel) {
                TurnItemStatus::Declined
            } else {
                TurnItemStatus::Completed
            };
            item.completed_at = Some(date);
        });
    }

    pub fn add_user_input(&mut self, request: UserInputRequest, date: Date) {
        self.close_chunk(Some(date));
        let item = TurnItem {
            id: request.id.clone(),
            kind: TurnItemKind::UserInput(request),
            status: TurnItemStatus::Pending,
            started_at: Some(date),
            completed_at: None,
        };
        self.append_to_active_turn(item, Some(date));
    }

    /// Records the answers, or a dismissal when `answers` is `None`.
    pub fn resolve_user_input(
        &mut self,
        id: &str,
        answers: Option<BTreeMap<String, Vec<String>>>,
        date: Date,
    ) {
        self.update_item(id, |item| {
            let TurnItemKind::UserInput(request) = &mut item.kind else { return };
            request.dismissed = answers.is_none();
            item.status =
                if answers.is_none() { TurnItemStatus::Declined } else { TurnItemStatus::Completed };
            request.answers = answers;
            item.completed_at = Some(date);
        });
    }

    // MARK: - Updates

    /// Applies one `update` object. False when it changes nothing visible.
    pub fn apply(&mut self, update: &Value, date: Date) -> bool {
        let timestamp = if self.is_replaying { None } else { Some(date) };
        match update.get("sessionUpdate").and_then(Value::as_str) {
            Some("user_message_chunk") => self.append_chunk(ChunkKind::Prompt, update, timestamp),
            Some("agent_message_chunk") => self.append_chunk(ChunkKind::Reply, update, timestamp),
            Some("agent_thought_chunk") => self.append_chunk(ChunkKind::Thinking, update, timestamp),
            Some("tool_call") => self.start_tool(update, timestamp),
            Some("tool_call_update") => self.update_tool(update, timestamp),
            _ => false,
        }
    }

    // MARK: - Messages

    fn append_chunk(&mut self, kind: ChunkKind, update: &Value, date: Option<Date>) -> bool {
        let text = text_of(update.get("content"));
        if text.is_empty() {
            return false;
        }
        let key = update.get("messageId").and_then(Value::as_str).map(str::to_owned);

        if kind == ChunkKind::Prompt {
            return self.append_user_chunk(&text, key, date);
        }
        if let Some(open) = self.open_chunk.clone()
            && open.kind == kind
            && open.key == key
            && self.append_text(&text, &open.item_id)
        {
            return true;
        }
        self.close_chunk(date);
        let id = self.local_id(if kind == ChunkKind::Reply { "reply" } else { "thinking" });
        let item_kind = if kind == ChunkKind::Reply {
            TurnItemKind::AssistantMessage { text, is_final: false }
        } else {
            TurnItemKind::Reasoning { text }
        };
        let item = TurnItem {
            id: id.clone(),
            kind: item_kind,
            status: TurnItemStatus::Running,
            started_at: date,
            completed_at: None,
        };
        self.append_to_active_turn(item, date);
        self.open_chunk = Some(OpenChunk { kind, key, item_id: id });
        true
    }

    /// A user message the agent sent: replayed history, or a message the agent itself added
    /// while working.
    fn append_user_chunk(&mut self, text: &str, key: Option<String>, date: Option<Date>) -> bool {
        if let Some(open) = &self.open_chunk
            && open.kind == ChunkKind::Prompt
            && open.key == key
            && let Some(last) = self.thread.turns.last_mut()
        {
            if last.user_message.id == open.item_id {
                last.user_message.text.push_str(text);
                return true;
            }
            if let Some(steer) = last.steers.iter_mut().rev().find(|s| s.id == open.item_id) {
                steer.text.push_str(text);
                return true;
            }
        }
        self.close_chunk(date);
        let id = self.local_id("message");
        match self.active_turn_index().filter(|_| !self.is_replaying) {
            Some(index) => self.thread.turns[index].steers.push(UserMessage::new(id.clone(), text, date)),
            None => {
                self.end_replayed_turn();
                let turn_id = self.local_id("turn");
                let mut turn = Turn::new(turn_id, UserMessage::new(id.clone(), text, date));
                turn.started_at = date;
                self.thread.turns.push(turn);
            }
        }
        self.open_chunk = Some(OpenChunk { kind: ChunkKind::Prompt, key, item_id: id });
        true
    }

    fn append_text(&mut self, text: &str, id: &str) -> bool {
        let mut appended = false;
        self.update_item(id, |item| match &mut item.kind {
            TurnItemKind::AssistantMessage { text: existing, .. }
            | TurnItemKind::Reasoning { text: existing } => {
                existing.push_str(text);
                appended = true;
            }
            _ => {}
        });
        appended
    }

    /// The streamed message or thought is complete once anything else arrives.
    fn close_chunk(&mut self, date: Option<Date>) {
        let Some(open) = self.open_chunk.take() else { return };
        if open.kind == ChunkKind::Prompt {
            return;
        }
        self.update_item(&open.item_id, |item| {
            if item.status.is_active() {
                item.status = TurnItemStatus::Completed;
                item.completed_at = date;
            }
        });
    }

    // MARK: - Tool calls

    fn start_tool(&mut self, update: &Value, date: Option<Date>) -> bool {
        let Some(id) = update.get("toolCallId").and_then(Value::as_str).map(str::to_owned) else {
            return false;
        };
        self.close_chunk(date);
        let mut tool = self.tools.get(&id).cloned().unwrap_or_default();
        if let Some(name) = update.get("name").and_then(Value::as_str) {
            tool.name = Some(name.to_owned());
        }
        if let Some(kind) = update.get("kind").and_then(Value::as_str) {
            tool.kind = Some(kind.to_owned());
        }
        if let Some(title) = update.get("title").and_then(Value::non_empty_string) {
            tool.title = Some(title.to_owned());
        }
        merge_tool_payload(&mut tool, update);
        self.tools.insert(id.clone(), tool.clone());
        let status =
            status_of(update.get("status").and_then(Value::as_str)).unwrap_or(TurnItemStatus::Running);
        let Some(kind) = self.item_kind(&tool, status) else { return false };
        if self.item(&id).is_some() {
            self.update_item(&id, |item| {
                item.kind = kind;
                item.status = status;
            });
        } else {
            let item = TurnItem {
                id,
                kind,
                status,
                started_at: date,
                completed_at: if status.is_active() { None } else { date },
            };
            self.append_to_active_turn(item, date);
        }
        true
    }

    fn update_tool(&mut self, update: &Value, date: Option<Date>) -> bool {
        let Some(id) = update.get("toolCallId").and_then(Value::as_str).map(str::to_owned) else {
            return false;
        };
        let Some(mut tool) = self.tools.get(&id).cloned() else { return false };
        let Some(current_status) = self.item(&id).map(|i| i.status) else { return false };
        self.close_chunk(date);
        if let Some(title) = update.get("title").and_then(Value::non_empty_string) {
            tool.title = Some(title.to_owned());
        }
        merge_tool_payload(&mut tool, update);
        self.tools.insert(id.clone(), tool.clone());
        let status = status_of(update.get("status").and_then(Value::as_str)).unwrap_or(current_status);
        let Some(kind) = self.item_kind(&tool, status) else { return false };
        self.update_item(&id, |item| {
            item.kind = kind;
            item.status = status;
            if !status.is_active() {
                item.completed_at = date;
            }
        });
        true
    }

    /// The turn item a tool call reads as. `None` for calls the chat shows otherwise (omp's
    /// `ask`: its question).
    fn item_kind(&self, tool: &Tool, status: TurnItemStatus) -> Option<TurnItemKind> {
        if self.tool_style == AcpToolStyle::Omp
            && let Some(name) = &tool.name
        {
            return self.omp_item_kind(name, tool, status);
        }
        Some(self.generic_item_kind(tool))
    }

    /// omp's tools as Soprano Agents reads them (`OmpEventMapper.toolItem`).
    fn omp_item_kind(&self, name: &str, tool: &Tool, status: TurnItemStatus) -> Option<TurnItemKind> {
        let args = &tool.args;
        let output = content_text(tool.raw_output.as_ref().and_then(|o| o.get("content")));
        let path = args.get("path").and_then(Value::non_empty_string);
        let tool_call = |category: ToolCategory, title: String| {
            TurnItemKind::ToolCall(ToolCall {
                name: name.to_owned(),
                category,
                title,
                input: input_text(args),
                output: output.clone(),
            })
        };
        Some(match name {
            "bash" => {
                let details = tool.raw_output.as_ref().and_then(|o| o.get("details"));
                let exit_code = details
                    .and_then(|d| d.get("exitCode"))
                    .and_then(JsonValueExt::int)
                    .or((status == TurnItemStatus::Completed).then_some(0));
                TurnItemKind::Command(TurnCommand::new(
                    args.get("command")
                        .and_then(Value::as_str)
                        .map(str::to_owned)
                        .or_else(|| tool.title.clone())
                        .unwrap_or_default(),
                    output.clone().unwrap_or_default(),
                    exit_code,
                ))
            }
            "write" | "edit" | "apply_patch" | "ast_edit" => {
                TurnItemKind::FileChange(self.omp_file_changes(name, tool, status))
            }
            "read" => tool_call(ToolCategory::Read, format!("Read {}", self.relative(path.unwrap_or("")))),
            "grep" | "glob" | "find" | "ast_grep" => {
                let pattern = ["pattern", "query", "pat"]
                    .iter()
                    .find_map(|k| args.get(*k).and_then(Value::non_empty_string));
                let title = match pattern {
                    Some(pattern) => match path {
                        Some(path) => format!("Searched {pattern} in {}", self.relative(path)),
                        None => format!("Searched {pattern}"),
                    },
                    None => format!("Searched {}", self.relative(path.unwrap_or("."))),
                };
                tool_call(ToolCategory::Search, title)
            }
            "web_search" => TurnItemKind::WebSearch {
                query: args
                    .get("query")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .or_else(|| tool.title.clone())
                    .unwrap_or_default(),
            },
            "task" => {
                let names: Vec<&str> = args
                    .get("tasks")
                    .and_then(Value::as_array)
                    .map(|tasks| {
                        tasks.iter().filter_map(|t| t.get("name").and_then(Value::non_empty_string)).collect()
                    })
                    .unwrap_or_default();
                let label = tool.title.clone().or_else(|| (!names.is_empty()).then(|| names.join(", ")));
                tool_call(
                    ToolCategory::Subagent,
                    label.map_or_else(|| "Subagent".to_owned(), |l| format!("Subagent: {l}")),
                )
            }
            "todo" => tool_call(ToolCategory::Other, "Updated tasks".into()),
            "ask" => return None,
            _ => tool_call(ToolCategory::Other, tool.title.clone().unwrap_or_else(|| name.to_owned())),
        })
    }

    /// The files an omp edit or write touched: what its result reports, else (still running, or
    /// a write, which reports no diff) the code its arguments carry. A failed call changed
    /// nothing.
    fn omp_file_changes(&self, name: &str, tool: &Tool, status: TurnItemStatus) -> Vec<FileChange> {
        let changes =
            tool.raw_output.as_ref().map(|r| self.reported_changes(name, tool, r)).unwrap_or_default();
        if matches!(status, TurnItemStatus::Failed | TurnItemStatus::Declined)
            || changes.iter().any(|c| c.diff.is_some())
        {
            return changes;
        }
        let relative = |path: &str| self.relative(path);
        let preview = omp_edit_changes(name, &tool.args, &relative);
        let Some(first) = preview.first() else { return changes };
        if preview.len() == 1 && changes.len() == 1 && !changes[0].path.is_empty() {
            let mut change = changes[0].clone();
            change.diff.clone_from(&first.diff);
            change.is_full_content = first.is_full_content;
            return vec![change];
        }
        preview
    }

    fn reported_changes(&self, name: &str, tool: &Tool, result: &Value) -> Vec<FileChange> {
        let details = result.get("details");
        if let Some(per_file) = details.and_then(|d| d.get("perFileResults")).and_then(Value::as_array)
            && !per_file.is_empty()
        {
            return per_file
                .iter()
                .filter_map(|file| {
                    let path = file.get("path").and_then(Value::non_empty_string)?;
                    Some(FileChange {
                        path: self.relative(path),
                        kind: change_kind(file.get("op").and_then(Value::as_str)),
                        move_path: file
                            .get("move")
                            .and_then(Value::non_empty_string)
                            .map(|m| self.relative(m)),
                        diff: file.get("diff").and_then(Value::non_empty_string).and_then(unified_diff),
                        is_full_content: None,
                    })
                })
                .collect();
        }
        let path = details
            .and_then(|d| {
                d.get("path")
                    .and_then(Value::non_empty_string)
                    .or_else(|| d.get("resolvedPath").and_then(Value::non_empty_string))
            })
            .map(str::to_owned)
            .or_else(|| argument_path(&tool.args));
        let Some(path) = path else { return Vec::new() };
        let mut kind = change_kind(details.and_then(|d| d.get("op")).and_then(Value::as_str));
        if name == "write" && details.and_then(|d| d.get("op")).is_none() {
            let text = content_text(result.get("content")).unwrap_or_default().to_lowercase();
            kind = if text.contains("created") || text.contains("new file") {
                FileChangeKind::Add
            } else {
                FileChangeKind::Update
            };
        }
        let move_path =
            details.and_then(|d| d.get("move")).and_then(Value::non_empty_string).map(|m| self.relative(m));
        vec![FileChange {
            path: self.relative(&path),
            kind: if move_path.is_none() { kind } else { FileChangeKind::Move },
            move_path,
            diff: details
                .and_then(|d| d.get("diff"))
                .and_then(Value::non_empty_string)
                .and_then(unified_diff),
            is_full_content: None,
        }]
    }

    /// Any other agent's tool call, from the protocol's kind, title and content.
    fn generic_item_kind(&self, tool: &Tool) -> TurnItemKind {
        let title = tool.title.clone().unwrap_or_default();
        let output = tool
            .content
            .iter()
            .filter(|block| block.get("type").and_then(Value::as_str) == Some("content"))
            .map(|block| text_of(block.get("content")))
            .filter(|t| !t.is_empty())
            .collect::<Vec<_>>()
            .join("\n");
        let optional_output = (!output.is_empty()).then(|| output.clone());
        match tool.kind.as_deref() {
            Some("execute") => TurnItemKind::Command(TurnCommand::new(
                tool.args.get("command").and_then(Value::as_str).map(str::to_owned).unwrap_or(title),
                output,
                None,
            )),
            Some("edit" | "delete" | "move") => {
                let mut changes = Vec::new();
                for block in
                    tool.content.iter().filter(|b| b.get("type").and_then(Value::as_str) == Some("diff"))
                {
                    let Some(path) = block.get("path").and_then(Value::non_empty_string) else { continue };
                    let old = block.get("oldText").and_then(Value::as_str);
                    let new = block.get("newText").and_then(Value::as_str).unwrap_or("");
                    let kind = match old {
                        None => FileChangeKind::Add,
                        Some(_) if new.is_empty() => FileChangeKind::Delete,
                        Some(_) => FileChangeKind::Update,
                    };
                    changes.push(FileChange::with_diff(
                        self.relative(path),
                        kind,
                        acp_unified_diff(old.unwrap_or(""), new),
                    ));
                }
                TurnItemKind::FileChange(changes)
            }
            Some("read") => TurnItemKind::ToolCall(ToolCall {
                name: "read".into(),
                category: ToolCategory::Read,
                title: if title.is_empty() { "Read file".into() } else { title },
                input: None,
                output: optional_output,
            }),
            Some("search") => TurnItemKind::ToolCall(ToolCall {
                name: "search".into(),
                category: ToolCategory::Search,
                title,
                input: None,
                output: optional_output,
            }),
            other => TurnItemKind::ToolCall(ToolCall {
                name: other.unwrap_or("tool").to_owned(),
                category: ToolCategory::Other,
                title,
                input: None,
                output: optional_output,
            }),
        }
    }

    // MARK: - Helpers

    /// The turn new items go to: the running one; else the last; else a new turn with no
    /// message of its own (the agent started working by itself).
    fn append_to_active_turn(&mut self, item: TurnItem, date: Option<Date>) {
        if self.thread.turns.is_empty() {
            let id = self.local_id("turn");
            let message_id = self.local_id("message");
            let mut turn = Turn::new(id, UserMessage::new(message_id, "", date));
            turn.started_at = date;
            self.thread.turns.push(turn);
        }
        if let Some(turn) = self.thread.turns.last_mut() {
            turn.items.push(item);
        }
    }

    fn active_turn_index(&self) -> Option<usize> {
        let last = self.thread.turns.len().checked_sub(1)?;
        self.thread.turns[last].is_running().then_some(last)
    }

    fn item(&self, id: &str) -> Option<&TurnItem> {
        self.thread.turns.iter().rev().find_map(|turn| turn.items.iter().rev().find(|i| i.id == id))
    }

    fn update_item(&mut self, id: &str, change: impl FnOnce(&mut TurnItem)) {
        for turn in self.thread.turns.iter_mut().rev() {
            if let Some(item) = turn.items.iter_mut().rev().find(|i| i.id == id) {
                change(item);
                return;
            }
        }
    }

    /// A replayed turn has ended once the next one starts or the replay ends.
    fn end_replayed_turn(&mut self) {
        let Some(last) = self.thread.turns.last() else { return };
        if !last.is_running() || last.started_at.is_some() {
            return;
        }
        self.close_chunk(None);
        let Some(turn) = self.thread.turns.last_mut() else { return };
        for item in &mut turn.items {
            if item.status.is_active() {
                item.status = TurnItemStatus::Completed;
            }
        }
        turn.status = TurnStatus::Completed;
        mark_answer(turn);
    }

    fn local_id(&mut self, prefix: &str) -> String {
        let id = format!("local-{prefix}-{}", self.next_local_id);
        self.next_local_id += 1;
        id
    }

    fn relative(&self, path: &str) -> String {
        relative_path(path, self.cwd.as_deref())
    }
}

fn merge_tool_payload(tool: &mut Tool, update: &Value) {
    if let Some(args) = update.get("rawInput") {
        tool.args = args.clone();
    }
    if let Some(output) = update.get("rawOutput") {
        tool.raw_output = Some(output.clone());
    }
    if let Some(content) = update.get("content").and_then(Value::as_array) {
        tool.content.clone_from(content);
    }
}

/// The turn's answer: its last message, when no tool ran after it.
fn mark_answer(turn: &mut Turn) {
    for item in turn.items.iter_mut().rev() {
        match &mut item.kind {
            TurnItemKind::AssistantMessage { is_final, .. } => {
                *is_final = true;
                return;
            }
            TurnItemKind::Command(_)
            | TurnItemKind::FileChange(_)
            | TurnItemKind::ToolCall(_)
            | TurnItemKind::WebSearch { .. } => {
                return;
            }
            _ => {}
        }
    }
}

fn status_of(status: Option<&str>) -> Option<TurnItemStatus> {
    match status? {
        "pending" => Some(TurnItemStatus::Pending),
        "in_progress" => Some(TurnItemStatus::Running),
        "completed" => Some(TurnItemStatus::Completed),
        "failed" => Some(TurnItemStatus::Failed),
        _ => None,
    }
}

fn change_kind(op: Option<&str>) -> FileChangeKind {
    match op {
        Some("create") => FileChangeKind::Add,
        Some("delete") => FileChangeKind::Delete,
        _ => FileChangeKind::Update,
    }
}

/// The text of one content block; an image only as a marker.
pub fn text_of(content: Option<&Value>) -> String {
    let Some(content) = content else { return String::new() };
    let string = |key: &str| content.get(key).and_then(Value::as_str);
    match string("type") {
        Some("text") => string("text").unwrap_or("").to_owned(),
        Some("image") => "[image]".into(),
        Some("resource_link") => {
            string("title").or_else(|| string("name")).or_else(|| string("uri")).unwrap_or("").to_owned()
        }
        Some("resource") => content
            .get("resource")
            .and_then(|r| r.get("text"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned(),
        _ => String::new(),
    }
}

/// `path` relative to `cwd` when inside it (`/tmp` and `/private/tmp` alike).
pub fn relative_path(path: &str, cwd: Option<&str>) -> String {
    let Some(cwd) = cwd.filter(|c| !c.is_empty()) else { return path.to_owned() };
    let bases = match cwd.strip_prefix("/private") {
        Some(rest) if cwd.starts_with("/private/") => vec![cwd.to_owned(), rest.to_owned()],
        _ => vec![cwd.to_owned(), format!("/private{cwd}")],
    };
    for base in bases {
        if path == base {
            return ".".into();
        }
        let prefix = if base.ends_with('/') { base } else { format!("{base}/") };
        if let Some(rest) = path.strip_prefix(&prefix) {
            return rest.to_owned();
        }
    }
    path.to_owned()
}

pub fn content_text(content: Option<&Value>) -> Option<String> {
    match content? {
        Value::String(text) => Some(text.clone()),
        Value::Array(blocks) => {
            let texts: Vec<&str> = blocks
                .iter()
                .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
                .filter_map(|b| b.get("text").and_then(Value::as_str))
                .collect();
            (!texts.is_empty()).then(|| texts.join("\n"))
        }
        _ => None,
    }
}

/// Pretty-printed tool arguments with sorted keys; `None` for none.
pub fn input_text(args: &Value) -> Option<String> {
    match args {
        Value::Null => None,
        Value::Object(object) if object.is_empty() => None,
        other => serde_json::to_string_pretty(&sorted(other)).ok(),
    }
}

fn sorted(value: &Value) -> Value {
    match value {
        Value::Object(object) => {
            let mut keys: Vec<&String> = object.keys().collect();
            keys.sort();
            Value::Object(keys.into_iter().map(|k| (k.clone(), sorted(&object[k]))).collect())
        }
        Value::Array(values) => Value::Array(values.iter().map(sorted).collect()),
        other => other.clone(),
    }
}

/// The file a write or edit call names: `path`, else the `[path#TAG]` header of a hashline
/// edit's `input`.
pub fn argument_path(args: &Value) -> Option<String> {
    if let Some(path) = args.get("path").and_then(Value::non_empty_string) {
        return Some(path.to_owned());
    }
    let input = args.get("input").and_then(Value::as_str)?;
    let rest = input.strip_prefix('[')?;
    let close = rest.find(']')?;
    let header = &rest[..close];
    let path = header.split('#').next().unwrap_or(header);
    (!path.is_empty()).then(|| path.to_owned())
}

/// omp's display diff (`-12|old`, `+12|new`, ` 12|context`, `...` between hunks) as unified
/// hunks; text already unified is kept.
pub fn unified_diff(diff: &str) -> Option<String> {
    if diff.starts_with("@@") || diff.starts_with("---") || diff.starts_with("diff ") {
        return Some(diff.to_owned());
    }
    struct Hunk {
        lines: Vec<String>,
        old_start: Option<i64>,
        new_start: Option<i64>,
        old_count: i64,
        new_count: i64,
    }
    impl Hunk {
        fn new() -> Self {
            Self { lines: Vec::new(), old_start: None, new_start: None, old_count: 0, new_count: 0 }
        }
        fn flush(&mut self, hunks: &mut Vec<String>) {
            if self.lines.is_empty() {
                return;
            }
            let old = self.old_start.or(self.new_start).unwrap_or(1);
            let new = self.new_start.or(self.old_start).unwrap_or(1);
            let header = format!(
                "@@ -{},{} +{},{} @@",
                if self.old_count == 0 { old - 1 } else { old },
                self.old_count,
                if self.new_count == 0 { new - 1 } else { new },
                self.new_count
            );
            let mut text = vec![header];
            text.append(&mut self.lines);
            hunks.push(text.join("\n"));
            *self = Self::new();
        }
    }
    let mut hunks = Vec::new();
    let mut hunk = Hunk::new();
    for line in diff.split('\n') {
        let Some(marker) = line.chars().next().filter(|m| matches!(m, '+' | '-' | ' ')) else {
            hunk.flush(&mut hunks);
            continue;
        };
        let Some(bar) = line.find('|') else {
            hunk.flush(&mut hunks);
            continue;
        };
        let number = line[1..bar].trim().parse::<i64>().ok();
        let text = &line[bar + 1..];
        match marker {
            '-' => {
                hunk.old_start = hunk.old_start.or(number);
                hunk.old_count += 1;
            }
            '+' => {
                hunk.new_start = hunk.new_start.or(number);
                hunk.new_count += 1;
            }
            _ => {
                hunk.old_start = hunk.old_start.or(number);
                hunk.new_start = hunk.new_start.or(number);
                hunk.old_count += 1;
                hunk.new_count += 1;
            }
        }
        hunk.lines.push(format!("{marker}{text}"));
    }
    hunk.flush(&mut hunks);
    (!hunks.is_empty()).then(|| hunks.join("\n"))
}

/// Lines of context [`acp_unified_diff`] keeps around the change.
pub const ACP_DIFF_CONTEXT: usize = 3;

/// A unified diff between two versions of a file's text, for agents that report an edit as old
/// and new text: one hunk around everything that changed, unchanged leading and trailing lines
/// trimmed down to [`ACP_DIFF_CONTEXT`]. `None` when nothing changed.
pub fn acp_unified_diff(old: &str, new: &str) -> Option<String> {
    if old == new {
        return None;
    }
    let old_lines = diff_lines(old);
    let new_lines = diff_lines(new);
    let mut prefix = 0;
    while prefix < old_lines.len() && prefix < new_lines.len() && old_lines[prefix] == new_lines[prefix] {
        prefix += 1;
    }
    let mut suffix = 0;
    while suffix < old_lines.len() - prefix
        && suffix < new_lines.len() - prefix
        && old_lines[old_lines.len() - 1 - suffix] == new_lines[new_lines.len() - 1 - suffix]
    {
        suffix += 1;
    }
    let leading = prefix.min(ACP_DIFF_CONTEXT);
    let trailing = suffix.min(ACP_DIFF_CONTEXT);
    let old_start = prefix - leading;
    let old_end = old_lines.len() - suffix + trailing;
    let new_end = new_lines.len() - suffix + trailing;

    let mut result = vec![format!(
        "@@ -{},{} +{},{} @@",
        old_start + 1,
        old_end - old_start,
        old_start + 1,
        new_end - old_start
    )];
    result.extend(old_lines[old_start..prefix].iter().map(|l| format!(" {l}")));
    result.extend(old_lines[prefix..old_lines.len() - suffix].iter().map(|l| format!("-{l}")));
    result.extend(new_lines[prefix..new_lines.len() - suffix].iter().map(|l| format!("+{l}")));
    result.extend(old_lines[old_lines.len() - suffix..old_end].iter().map(|l| format!(" {l}")));
    Some(result.join("\n"))
}

fn diff_lines(text: &str) -> Vec<&str> {
    if text.is_empty() {
        return Vec::new();
    }
    let mut lines: Vec<&str> = text.split('\n').collect();
    if lines.last() == Some(&"") {
        lines.pop();
    }
    lines
}
