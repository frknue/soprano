//! An agent CLI's own transcript as the chat's turns (`TranscriptThread.swift`).

use crate::chat_turns::{
    ChatThread, FileChange, FileChangeKind, ToolCall, ToolCategory, Turn, TurnCommand, TurnItem,
    TurnItemKind, TurnItemStatus, TurnStatus, UserMessage,
};
use crate::timeline::{AgentTimeline, AgentTimelineItem, AgentToolCall, TimelineItemKind, ToolCallState};

const COMMAND_TOOLS: [&str; 7] = ["bash", "run", "shell", "exec", "exec_command", "local_shell", "execute"];
const EDIT_TOOLS: [&str; 9] =
    ["edit", "multiedit", "write", "notebookedit", "add", "delete", "apply_patch", "patch", "ast_edit"];

impl ChatThread {
    /// An agent CLI's own transcript (read by the Claude Code, Codex, omp and OpenCode decoders)
    /// as the chat's turns, so the Agent Dashboard shows a terminal agent's conversation in the
    /// chat timeline: each prompt starts a turn, and the replies, thinking, tool calls and
    /// notices after it land in that turn in order. While the agent works the last turn runs; a
    /// finished turn's last reply is its answer, the replies before it commentary the "Worked
    /// for" fold hides. Items before the first prompt (the transcript's head fell off
    /// [`AgentTimeline::ITEM_LIMIT`]) open a turn without a message.
    pub fn from_transcript(transcript: &AgentTimeline, is_running: bool) -> Self {
        let mut preamble: Vec<TurnItem> = Vec::new();
        let mut turns: Vec<Turn> = Vec::new();
        for item in &transcript.items {
            if let TimelineItemKind::Prompt(text) = &item.kind {
                let mut turn = Turn::new(
                    item.id.clone(),
                    UserMessage::new(item.id.clone(), text.clone(), item.timestamp),
                );
                turn.status = TurnStatus::Completed;
                turn.started_at = item.timestamp;
                turns.push(turn);
                continue;
            }
            let Some(turn_item) = turn_item(item) else { continue };
            if turns.is_empty() {
                match turn_item.kind {
                    TurnItemKind::Notice { .. } | TurnItemKind::Error { .. } => {
                        preamble.push(turn_item);
                        continue;
                    }
                    _ => {
                        let mut turn =
                            Turn::new("transcript-head", UserMessage::new("transcript-head", "", None));
                        turn.status = TurnStatus::Completed;
                        turn.started_at = item.timestamp;
                        turns.push(turn);
                    }
                }
            }
            if let Some(last) = turns.last_mut() {
                last.items.push(turn_item);
            }
        }

        let count = turns.len();
        for (index, turn) in turns.iter_mut().enumerate() {
            let running = is_running && index == count - 1;
            turn.status = if running { TurnStatus::Running } else { TurnStatus::Completed };
            turn.completed_at = if running {
                None
            } else {
                turn.items.iter().filter_map(|i| i.completed_at.or(i.started_at)).max()
            };
            // A turn's answer is its last reply once it has finished.
            if !running
                && let Some(answer) = turn
                    .items
                    .iter_mut()
                    .rev()
                    .find(|i| matches!(i.kind, TurnItemKind::AssistantMessage { .. }))
                && let TurnItemKind::AssistantMessage { is_final, .. } = &mut answer.kind
            {
                *is_final = true;
            }
        }
        Self { preamble, turns, queue: Vec::new() }
    }

    /// What a CLI's tool call reads as in the work log, by the tool names the decoders give.
    pub fn kind_of(call: &AgentToolCall) -> TurnItemKind {
        let name = call.name.to_lowercase();
        let summary = &call.summary;
        if COMMAND_TOOLS.contains(&name.as_str()) {
            let exit_code = match call.state {
                ToolCallState::Succeeded => Some(0),
                ToolCallState::Failed => Some(1),
                ToolCallState::Running | ToolCallState::Interrupted => None,
            };
            return TurnItemKind::Command(TurnCommand::new(
                call.detail.clone().unwrap_or_else(|| summary.clone()),
                call.output.clone().unwrap_or_default(),
                exit_code,
            ));
        }
        if EDIT_TOOLS.contains(&name.as_str()) || call.diff.is_some() {
            return TurnItemKind::FileChange(file_changes(call, &name));
        }
        let tool = |category: ToolCategory, title: String| {
            TurnItemKind::ToolCall(ToolCall {
                name: call.name.clone(),
                category,
                title,
                input: call.detail.clone(),
                output: call.output.clone(),
            })
        };
        match name.as_str() {
            "read" | "view" => tool(
                ToolCategory::Read,
                if summary.is_empty() { "Read file".into() } else { format!("Read {summary}") },
            ),
            "grep" | "glob" | "search" | "list" | "find" | "ls" | "ast_grep" | "codesearch" => tool(
                ToolCategory::Search,
                if summary.is_empty() { "Searched files".into() } else { format!("Searched {summary}") },
            ),
            "websearch" | "web_search" => TurnItemKind::WebSearch { query: summary.clone() },
            "task" | "agent" | "subagent" => tool(
                ToolCategory::Subagent,
                if summary.is_empty() { "Subagent".into() } else { format!("Subagent: {summary}") },
            ),
            _ => tool(
                ToolCategory::Other,
                if summary.is_empty() { call.name.clone() } else { format!("{} {summary}", call.name) },
            ),
        }
    }
}

fn turn_item(item: &AgentTimelineItem) -> Option<TurnItem> {
    let completed = |kind: TurnItemKind| TurnItem {
        id: item.id.clone(),
        kind,
        status: TurnItemStatus::Completed,
        started_at: item.timestamp,
        completed_at: item.timestamp,
    };
    match &item.kind {
        TimelineItemKind::Prompt(_) => None,
        TimelineItemKind::Reply(text) => {
            Some(completed(TurnItemKind::AssistantMessage { text: text.clone(), is_final: false }))
        }
        TimelineItemKind::Thinking(text) => {
            (!text.trim().is_empty()).then(|| completed(TurnItemKind::Reasoning { text: text.clone() }))
        }
        TimelineItemKind::Notice { text, is_error } => Some(completed(if *is_error {
            TurnItemKind::Error { message: text.clone() }
        } else {
            TurnItemKind::Notice { text: text.clone() }
        })),
        TimelineItemKind::Tool(call) => {
            let status = match call.state {
                ToolCallState::Running => TurnItemStatus::Running,
                ToolCallState::Succeeded => TurnItemStatus::Completed,
                ToolCallState::Failed => TurnItemStatus::Failed,
                ToolCallState::Interrupted => TurnItemStatus::Interrupted,
            };
            Some(TurnItem {
                id: item.id.clone(),
                kind: ChatThread::kind_of(call),
                status,
                started_at: item.timestamp,
                completed_at: call.finished_at,
            })
        }
    }
}

fn is_file_header(line: &str) -> bool {
    line.starts_with("diff ") && !line.starts_with("diff --")
}

/// The files one edit touched. Codex joins a multi-file change's diffs, each led by
/// `diff <path>`; every other call names its one file in its summary.
fn file_changes(call: &AgentToolCall, name: &str) -> Vec<FileChange> {
    let kind = match name {
        "add" => FileChangeKind::Add,
        "delete" => FileChangeKind::Delete,
        _ => FileChangeKind::Update,
    };
    let is_write = name == "write";
    let Some(diff) = call.diff.as_deref().filter(|d| is_file_header(d)) else {
        return vec![FileChange {
            path: call.summary.clone(),
            kind,
            move_path: None,
            diff: call.diff.clone(),
            is_full_content: is_write.then_some(true),
        }];
    };
    let mut changes = Vec::new();
    let mut lines: Vec<&str> = Vec::new();
    let flush = |lines: &[&str], changes: &mut Vec<FileChange>| {
        let Some(header) = lines.first() else { return };
        changes.push(FileChange::with_diff(&header["diff ".len()..], kind, Some(lines[1..].join("\n"))));
    };
    for line in diff.split('\n') {
        if is_file_header(line) {
            flush(&lines, &mut changes);
            lines = vec![line];
        } else {
            lines.push(line);
        }
    }
    flush(&lines, &mut changes);
    changes
}
