//! Translates between Soprano's ACP [`AgentChatSession`](crate::AgentChatSession) and Anthropic
//! Claude Code's native bidirectional NDJSON protocol (`claude -p --input-format stream-json
//! --output-format stream-json --verbose --include-partial-messages`).
//!
//! Spawns the `claude` process lazily on `session/new` or `session/load` so the process receives
//! `--session-id <uuid>` (new) or `--resume <id>` (resume) via `SOPRANO_CLAUDE_SESSION_ID` /
//! `SOPRANO_CLAUDE_RESUME_ID`. On `session/load`, any existing transcript on disk is replayed via
//! `soprano-agents` so switching from Terminal CLI to Chat UI preserves the conversation history.

use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader, ErrorKind, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use soprano_agents::{
    AgentTranscriptFormat, AgentTranscriptSource, JsonValueExt, TimelineItemKind, ToolCallState,
};

use crate::rpc::{
    JsonRpcConnection, JsonRpcError, JsonRpcPeer, LineSplitter, PeerEvent, PeerSink, StderrTail,
    child_exit_code, configure_child, kill_child, terminate_child,
};

/// Default model choices surfaced in Claude Code's composer chip.
const CLAUDE_MODELS: &[(&str, &str)] = &[
    ("default", "Default"),
    ("sonnet", "Claude Sonnet"),
    ("opus", "Claude Opus"),
    ("haiku", "Claude Haiku"),
];

/// Stateful translator from Claude Code `stream-json` stdout objects into ACP [`PeerEvent`]s.
/// Separated from process I/O so unit tests can exercise every message type deterministically.
pub struct ClaudeStreamTranslator {
    pub session_id: String,
    pub pending_prompt_acp_id: Option<u64>,
    pub current_model: String,
    pub available_models: Vec<(String, String)>,
    /// Content block indices currently being streamed via `stream_event`.
    streamed_text_this_message: bool,
    streamed_thinking_this_message: bool,
    active_message_id: u64,
    /// Tool call ids already started so `assistant` updates rather than duplicates them.
    started_tools: HashSet<String>,
    /// Diff blocks attached to file-edit tool calls so `tool_result` updates preserve them.
    tool_diffs: HashMap<String, Vec<Value>>,
    /// Pending `control_request` ids awaiting an ACP reply (`acp_req_id` -> `claude_request_id`).
    pub pending_control_requests: HashMap<String, String>,
    next_control_id: u64,
}

impl ClaudeStreamTranslator {
    pub fn new(session_id: impl Into<String>) -> Self {
        Self {
            session_id: session_id.into(),
            pending_prompt_acp_id: None,
            current_model: "default".into(),
            available_models: CLAUDE_MODELS.iter().map(|(id, name)| ((*id).into(), (*name).into())).collect(),
            streamed_text_this_message: false,
            streamed_thinking_this_message: false,
            active_message_id: 0,
            started_tools: HashSet::new(),
            tool_diffs: HashMap::new(),
            pending_control_requests: HashMap::new(),
            next_control_id: 0,
        }
    }

    pub fn config_options(&self) -> Value {
        let mut options: Vec<Value> =
            self.available_models.iter().map(|(value, name)| json!({"value": value, "name": name})).collect();
        if !self.available_models.iter().any(|(v, _)| v == &self.current_model) {
            options.insert(0, json!({"value": self.current_model, "name": self.current_model}));
        }
        json!([{
            "id": "model",
            "name": "Model",
            "category": "model",
            "type": "select",
            "currentValue": self.current_model,
            "options": options,
        }])
    }

    /// Translates one parsed NDJSON object from Claude Code's stdout into zero or more ACP
    /// [`PeerEvent`]s.
    pub fn handle_message(&mut self, msg: &Value) -> Vec<PeerEvent> {
        let mut out = Vec::new();
        let Some(kind) = msg.get("type").and_then(Value::as_str) else { return out };
        match kind {
            "system" => {
                if let Some(sid) = msg.get("session_id").and_then(Value::non_empty_string) {
                    self.session_id = sid.to_owned();
                }
                if msg.get("subtype").and_then(Value::as_str) == Some("init") {
                    if let Some(model) = msg.get("model").and_then(Value::non_empty_string) {
                        self.current_model = model.to_owned();
                        out.push(self.session_update(json!({
                            "sessionUpdate": "config_option_update",
                            "configOptions": self.config_options(),
                        })));
                    }
                    if let Some(commands) = msg.get("slash_commands").and_then(Value::as_array) {
                        let available: Vec<Value> = commands
                            .iter()
                            .filter_map(Value::non_empty_string)
                            .map(|name| {
                                json!({
                                    "name": name.strip_prefix('/').unwrap_or(name),
                                })
                            })
                            .collect();
                        if !available.is_empty() {
                            out.push(self.session_update(json!({
                                "sessionUpdate": "available_commands_update",
                                "availableCommands": available,
                            })));
                        }
                    }
                } else if msg.get("subtype").and_then(Value::as_str) == Some("compact_boundary") {
                    out.push(PeerEvent::Notification {
                        method: "_omp/compaction/end".into(),
                        params: json!({}),
                    });
                }
            }
            "stream_event" => {
                let Some(event) = msg.get("event") else { return out };
                match event.get("type").and_then(Value::as_str) {
                    Some("message_start") => {
                        self.active_message_id += 1;
                        self.streamed_text_this_message = false;
                        self.streamed_thinking_this_message = false;
                    }
                    Some("content_block_start") => {
                        if let Some(block) = event.get("content_block")
                            && block.get("type").and_then(Value::as_str) == Some("tool_use")
                            && let Some(update) =
                                claude_tool_use_to_acp(block, &mut self.started_tools, &mut self.tool_diffs)
                        {
                            out.push(self.session_update(update));
                        }
                    }
                    Some("content_block_delta") => {
                        let Some(delta) = event.get("delta") else { return out };
                        let message_id = format!("claude-msg-{}", self.active_message_id);
                        match delta.get("type").and_then(Value::as_str) {
                            Some("text_delta") => {
                                if let Some(text) = delta.get("text").and_then(Value::as_str)
                                    && !text.is_empty()
                                {
                                    self.streamed_text_this_message = true;
                                    out.push(self.session_update(json!({
                                        "sessionUpdate": "agent_message_chunk",
                                        "messageId": message_id,
                                        "content": {"type": "text", "text": text},
                                    })));
                                }
                            }
                            Some("thinking_delta") => {
                                if let Some(text) = delta.get("thinking").and_then(Value::as_str)
                                    && !text.is_empty()
                                {
                                    self.streamed_thinking_this_message = true;
                                    out.push(self.session_update(json!({
                                        "sessionUpdate": "agent_thought_chunk",
                                        "messageId": message_id,
                                        "content": {"type": "text", "text": text},
                                    })));
                                }
                            }
                            _ => {}
                        }
                    }
                    _ => {}
                }
            }
            "assistant" => {
                if let Some(parts) =
                    msg.get("message").and_then(|m| m.get("content")).and_then(Value::as_array)
                {
                    let message_id = format!("claude-msg-{}", self.active_message_id);
                    for part in parts {
                        match part.get("type").and_then(Value::as_str) {
                            Some("text") if !self.streamed_text_this_message => {
                                if let Some(text) = part.get("text").and_then(Value::as_str)
                                    && !text.is_empty()
                                {
                                    out.push(self.session_update(json!({
                                        "sessionUpdate": "agent_message_chunk",
                                        "messageId": message_id,
                                        "content": {"type": "text", "text": text},
                                    })));
                                }
                            }
                            Some("thinking") if !self.streamed_thinking_this_message => {
                                if let Some(text) = part.get("thinking").and_then(Value::as_str)
                                    && !text.is_empty()
                                {
                                    out.push(self.session_update(json!({
                                        "sessionUpdate": "agent_thought_chunk",
                                        "messageId": message_id,
                                        "content": {"type": "text", "text": text},
                                    })));
                                }
                            }
                            Some("tool_use") => {
                                if let Some(update) = claude_tool_use_to_acp(
                                    part,
                                    &mut self.started_tools,
                                    &mut self.tool_diffs,
                                ) {
                                    out.push(self.session_update(update));
                                }
                            }
                            _ => {}
                        }
                    }
                }
                self.streamed_text_this_message = false;
                self.streamed_thinking_this_message = false;
            }
            "user" => {
                if let Some(parts) =
                    msg.get("message").and_then(|m| m.get("content")).and_then(Value::as_array)
                {
                    for part in parts {
                        if part.get("type").and_then(Value::as_str) != Some("tool_result") {
                            continue;
                        }
                        let Some(tool_id) = part.get("tool_use_id").and_then(Value::as_str) else {
                            continue;
                        };
                        let is_error = part.get("is_error").and_then(Value::as_bool) == Some(true);
                        let text = claude_tool_result_text(part.get("content"));
                        let mut content = self.tool_diffs.remove(tool_id).unwrap_or_default();
                        if let Some(t) = text {
                            content.push(json!({"type": "content", "content": {"type": "text", "text": t}}));
                        }
                        out.push(self.session_update(json!({
                            "sessionUpdate": "tool_call_update",
                            "toolCallId": tool_id,
                            "status": if is_error { "failed" } else { "completed" },
                            "content": content,
                        })));
                    }
                }
            }
            "result" => {
                if let Some((used, size)) = extract_claude_usage(msg) {
                    out.push(self.session_update(json!({
                        "sessionUpdate": "usage_update",
                        "used": used,
                        "size": size,
                    })));
                }
                self.started_tools.clear();
                self.tool_diffs.clear();
                self.streamed_text_this_message = false;
                self.streamed_thinking_this_message = false;
                if let Some(acp_id) = self.pending_prompt_acp_id.take() {
                    let is_error = msg.get("is_error").and_then(Value::as_bool) == Some(true);
                    let subtype = msg.get("subtype").and_then(Value::as_str).unwrap_or("");
                    let result = if is_error {
                        let message = msg
                            .get("result")
                            .and_then(Value::non_empty_string)
                            .or_else(|| {
                                msg.get("errors")
                                    .and_then(Value::as_array)
                                    .and_then(|a| a.first())
                                    .and_then(Value::non_empty_string)
                            })
                            .unwrap_or("Claude Code turn failed");
                        Err(JsonRpcError::new(JsonRpcError::INTERNAL_ERROR, message))
                    } else if subtype == "interrupted" {
                        Ok(json!({"stopReason": "cancelled"}))
                    } else {
                        Ok(json!({"stopReason": "end_turn"}))
                    };
                    out.push(PeerEvent::Response { id: acp_id, result });
                }
            }
            "control_request" => {
                let Some(request_id) = msg.get("request_id").and_then(Value::as_str) else { return out };
                let Some(req) = msg.get("request") else { return out };
                if req.get("subtype").and_then(Value::as_str) == Some("can_use_tool") {
                    let tool_name = req.get("tool_name").and_then(Value::as_str).unwrap_or("Tool");
                    let input = req.get("input").cloned().unwrap_or(Value::Null);
                    let (acp_kind, title) = claude_tool_summary(tool_name, &input);
                    self.next_control_id += 1;
                    let acp_req_id = format!("claude-ctrl-{}", self.next_control_id);
                    self.pending_control_requests.insert(acp_req_id.clone(), request_id.to_owned());
                    out.push(PeerEvent::Request {
                        id: Value::String(acp_req_id),
                        method: "session/request_permission".into(),
                        params: json!({
                            "toolCall": {
                                "title": title,
                                "kind": acp_kind,
                                "rawInput": input,
                            },
                            "options": [
                                {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                                {"optionId": "deny", "name": "Deny", "kind": "reject_once"},
                            ],
                        }),
                    });
                }
            }
            _ => {}
        }
        out
    }

    fn session_update(&self, update: Value) -> PeerEvent {
        PeerEvent::Notification {
            method: "session/update".into(),
            params: json!({"sessionId": self.session_id, "update": update}),
        }
    }
}

struct ChildState {
    stdin: Mutex<Option<ChildStdin>>,
    exited: AtomicBool,
    terminate_requested: Mutex<Option<Instant>>,
}

impl ChildState {
    fn write_json(&self, value: &Value) -> bool {
        if self.exited.load(Ordering::SeqCst) {
            return false;
        }
        let Ok(mut line) = serde_json::to_vec(value) else { return false };
        line.push(b'\n');
        if let Some(stdin) = lock(&self.stdin).as_mut() {
            return stdin.write_all(&line).and_then(|()| stdin.flush()).is_ok();
        }
        false
    }
}

/// A [`JsonRpcPeer`] that speaks ACP to [`AgentChatSession`](crate::AgentChatSession) while
/// driving `claude -p --input-format stream-json --output-format stream-json ...` underneath.
pub struct ClaudeStreamJsonPeer {
    argv: Vec<String>,
    cwd: Option<PathBuf>,
    env: Option<Vec<(String, String)>>,
    sink: Option<PeerSink>,
    translator: Arc<Mutex<ClaudeStreamTranslator>>,
    child: Arc<ChildState>,
    started: bool,
    spawned: bool,
    next_acp_id: u64,
    next_control_out_id: u64,
    threads: Vec<JoinHandle<()>>,
}

impl ClaudeStreamJsonPeer {
    pub fn new(argv: Vec<String>, cwd: Option<PathBuf>, env: Option<Vec<(String, String)>>) -> Self {
        Self {
            argv,
            cwd,
            env,
            sink: None,
            translator: Arc::new(Mutex::new(ClaudeStreamTranslator::new(""))),
            child: Arc::new(ChildState {
                stdin: Mutex::new(None),
                exited: AtomicBool::new(false),
                terminate_requested: Mutex::new(None),
            }),
            started: false,
            spawned: false,
            next_acp_id: 0,
            next_control_out_id: 0,
            threads: Vec::new(),
        }
    }

    fn alloc_id(&mut self) -> u64 {
        self.next_acp_id += 1;
        self.next_acp_id
    }

    fn spawn_claude(&mut self, resume_id: Option<&str>, new_session_id: Option<&str>) -> std::io::Result<()> {
        let Some((program, arguments)) = self.argv.split_first() else {
            return Err(std::io::Error::new(ErrorKind::InvalidInput, "empty command line"));
        };
        let mut command = Command::new(program);
        command.args(arguments).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        configure_child(&mut command);
        if let Some(cwd) = &self.cwd {
            command.current_dir(cwd);
        }
        let mut env_pairs = self.env.clone().unwrap_or_default();
        env_pairs.retain(|(k, _)| {
            !matches!(
                k.as_str(),
                "SOPRANO_CLAUDE_RESUME_ID" | "SOPRANO_CLAUDE_SESSION_ID" | "SOPRANO_CLAUDE_MODEL"
            )
        });
        if let Some(id) = resume_id {
            env_pairs.push(("SOPRANO_CLAUDE_RESUME_ID".into(), id.to_owned()));
        } else if let Some(id) = new_session_id {
            env_pairs.push(("SOPRANO_CLAUDE_SESSION_ID".into(), id.to_owned()));
        }
        let current_model = lock(&self.translator).current_model.clone();
        if current_model != "default" && !current_model.is_empty() {
            env_pairs.push(("SOPRANO_CLAUDE_MODEL".into(), current_model));
        }
        if self.env.is_some() {
            command.env_clear();
        }
        command.envs(env_pairs.iter().map(|(k, v)| (k, v)));

        let mut child = command.spawn()?;
        self.spawned = true;
        *lock(&self.child.stdin) = child.stdin.take();
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        let tail = Arc::new(StderrTail::new(JsonRpcConnection::STDERR_LIMIT));
        let sink = self.sink.clone().expect("started");

        let (finished, finished_readers) = mpsc::channel::<()>();
        let mut readers = 0;
        if let Some(stdout) = stdout {
            let child_state = Arc::clone(&self.child);
            let translator = Arc::clone(&self.translator);
            let sink = sink.clone();
            let finished = finished.clone();
            readers += 1;
            std::thread::spawn(move || {
                read_claude_stdout(stdout, &child_state, &translator, &sink);
                let _ = finished.send(());
            });
        }
        if let Some(mut stderr) = stderr {
            let tail = Arc::clone(&tail);
            let finished = finished.clone();
            readers += 1;
            std::thread::spawn(move || {
                let mut buffer = [0u8; 4096];
                loop {
                    match stderr.read(&mut buffer) {
                        Ok(0) => break,
                        Ok(count) => tail.append(&buffer[..count]),
                        Err(error) if error.kind() == ErrorKind::Interrupted => {}
                        Err(_) => break,
                    }
                }
                let _ = finished.send(());
            });
        }
        drop(finished);

        let child_state = Arc::clone(&self.child);
        let translator = Arc::clone(&self.translator);
        let waiter = std::thread::spawn(move || {
            let status =
                wait_claude_child(&mut child, &child_state, JsonRpcConnection::DEFAULT_EXIT_GRACE_PERIOD);
            let deadline = Instant::now() + JsonRpcConnection::OUTPUT_DRAIN_TIMEOUT;
            for _ in 0..readers {
                let left = deadline.saturating_duration_since(Instant::now());
                if finished_readers.recv_timeout(left).is_err() {
                    break;
                }
            }
            child_state.exited.store(true, Ordering::SeqCst);
            *lock(&child_state.stdin) = None;
            if let Some(prompt_id) = lock(&translator).pending_prompt_acp_id.take() {
                sink.send(PeerEvent::Response { id: prompt_id, result: Err(JsonRpcError::closed()) });
            }
            sink.send(PeerEvent::Exit { status, stderr: tail.text() });
        });
        self.threads.push(waiter);
        Ok(())
    }
}

impl JsonRpcPeer for ClaudeStreamJsonPeer {
    fn start(&mut self, sink: PeerSink) -> std::io::Result<()> {
        self.sink = Some(sink);
        self.started = true;
        Ok(())
    }

    fn request(&mut self, method: &str, params: Value) -> Result<u64, JsonRpcError> {
        if !self.started || self.child.exited.load(Ordering::SeqCst) {
            return Err(JsonRpcError::closed());
        }
        let acp_id = self.alloc_id();
        let Some(sink) = self.sink.clone() else {
            return Err(JsonRpcError::closed());
        };
        match method {
            "initialize" => {
                sink.send(PeerEvent::Response {
                    id: acp_id,
                    result: Ok(json!({
                        "protocolVersion": 1,
                        "agentCapabilities": { "loadSession": true },
                    })),
                });
            }
            "session/new" => {
                let session_id = generate_uuid_v4();
                let options = {
                    let mut tr = lock(&self.translator);
                    tr.session_id = session_id.clone();
                    tr.config_options()
                };
                if let Err(error) = self.spawn_claude(None, Some(&session_id)) {
                    sink.send(PeerEvent::Response {
                        id: acp_id,
                        result: Err(JsonRpcError::new(JsonRpcError::INTERNAL_ERROR, error.to_string())),
                    });
                    return Ok(acp_id);
                }
                sink.send(PeerEvent::Response {
                    id: acp_id,
                    result: Ok(json!({"sessionId": session_id, "configOptions": options})),
                });
            }
            "session/load" => {
                let session_id =
                    params.get("sessionId").and_then(Value::as_str).unwrap_or_default().to_owned();
                let options = {
                    let mut tr = lock(&self.translator);
                    tr.session_id = session_id.clone();
                    tr.config_options()
                };
                if let Some(home) = soprano_platform::paths::home_dir().to_str().map(Path::new) {
                    replay_claude_transcript(&sink, &session_id, home);
                }
                if let Err(error) = self.spawn_claude(Some(&session_id), None) {
                    sink.send(PeerEvent::Response {
                        id: acp_id,
                        result: Err(JsonRpcError::new(JsonRpcError::INTERNAL_ERROR, error.to_string())),
                    });
                    return Ok(acp_id);
                }
                sink.send(PeerEvent::Response {
                    id: acp_id,
                    result: Ok(json!({"sessionId": session_id, "configOptions": options})),
                });
            }
            "session/prompt" => {
                let text = extract_prompt_text(&params);
                lock(&self.translator).pending_prompt_acp_id = Some(acp_id);
                let payload = json!({
                    "type": "user",
                    "message": {
                        "role": "user",
                        "content": text,
                    }
                });
                if !self.child.write_json(&payload) {
                    lock(&self.translator).pending_prompt_acp_id = None;
                    return Err(JsonRpcError::closed());
                }
            }
            "session/set_config_option" => {
                let config_id = params.get("configId").and_then(Value::as_str).unwrap_or("");
                let value = params.get("value").and_then(Value::as_str).unwrap_or("");
                let options = {
                    let mut tr = lock(&self.translator);
                    if config_id == "model" && !value.is_empty() {
                        tr.current_model = value.to_owned();
                    }
                    tr.config_options()
                };
                if config_id == "model" && !value.is_empty() && self.spawned {
                    self.next_control_out_id += 1;
                    let req_id = format!("soprano-model-{}", self.next_control_out_id);
                    let model_value =
                        if value == "default" { Value::Null } else { Value::String(value.to_owned()) };
                    self.child.write_json(&json!({
                        "type": "control_request",
                        "request_id": req_id,
                        "request": {
                            "subtype": "set_model",
                            "model": model_value,
                        }
                    }));
                }
                sink.send(PeerEvent::Response { id: acp_id, result: Ok(json!({"configOptions": options})) });
            }
            _ => {
                sink.send(PeerEvent::Response {
                    id: acp_id,
                    result: Err(JsonRpcError::new(
                        JsonRpcError::METHOD_NOT_FOUND,
                        format!("Unsupported method: {method}"),
                    )),
                });
            }
        }
        Ok(acp_id)
    }

    fn notify(&mut self, method: &str, _params: Value) {
        if method == "session/cancel" && self.spawned {
            self.next_control_out_id += 1;
            let req_id = format!("soprano-cancel-{}", self.next_control_out_id);
            self.child.write_json(&json!({
                "type": "control_request",
                "request_id": req_id,
                "request": { "subtype": "interrupt" },
            }));
        }
    }

    fn reply(&mut self, id: Value, result: Result<Value, JsonRpcError>) {
        let Some(acp_req_id) = id.as_str() else { return };
        let Some(request_id) = lock(&self.translator).pending_control_requests.remove(acp_req_id) else {
            return;
        };
        let allowed = result.ok().is_some_and(|v| {
            v.get("outcome")
                .and_then(|o| o.get("optionId"))
                .and_then(Value::as_str)
                .is_some_and(|id| id == "allow")
        });
        let behavior = if allowed { "allow" } else { "deny" };
        self.child.write_json(&json!({
            "type": "control_response",
            "response": {
                "subtype": "success",
                "request_id": request_id,
                "response": {
                    "behavior": behavior,
                },
            }
        }));
    }

    fn terminate(&mut self) {
        if !self.spawned || self.child.exited.load(Ordering::SeqCst) {
            self.child.exited.store(true, Ordering::SeqCst);
            return;
        }
        *lock(&self.child.stdin) = None;
        let mut requested = lock(&self.child.terminate_requested);
        if requested.is_none() {
            *requested = Some(Instant::now());
        }
    }

    fn has_exited(&self) -> bool {
        !self.spawned || self.child.exited.load(Ordering::SeqCst)
    }
}

impl Drop for ClaudeStreamJsonPeer {
    fn drop(&mut self) {
        self.threads.clear();
    }
}

fn read_claude_stdout(
    stdout: impl Read,
    child: &ChildState,
    translator: &Arc<Mutex<ClaudeStreamTranslator>>,
    sink: &PeerSink,
) {
    let mut reader = BufReader::new(stdout);
    let mut splitter = LineSplitter::default();
    loop {
        let chunk = match reader.fill_buf() {
            Err(error) if error.kind() == ErrorKind::Interrupted => continue,
            Ok([]) | Err(_) => return,
            Ok(chunk) => chunk.to_vec(),
        };
        reader.consume(chunk.len());
        for line in splitter.append(&chunk) {
            if child.exited.load(Ordering::SeqCst) {
                return;
            }
            let Some(message) = soprano_agents::json::parse_value(&line) else { continue };
            let events = lock(translator).handle_message(&message);
            for event in events {
                sink.send(event);
            }
        }
    }
}

fn wait_claude_child(child: &mut Child, state: &ChildState, grace: Duration) -> i32 {
    let mut signalled = false;
    let mut killed = false;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return child_exit_code(status),
            Ok(None) => {}
            Err(_) => return -1,
        }
        let requested = *lock(&state.terminate_requested);
        if let Some(at) = requested {
            if !signalled {
                signalled = true;
                terminate_child(child);
            } else if !killed && at.elapsed() >= grace {
                killed = true;
                kill_child(child);
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Replays an existing Claude Code transcript from disk into ACP `session/update` notifications so
/// resuming a conversation in Chat UI displays its full history immediately.
fn replay_claude_transcript(sink: &PeerSink, session_id: &str, home: &Path) {
    let source = AgentTranscriptSource {
        format: AgentTranscriptFormat::ClaudeCode,
        conversation_id: session_id.to_owned(),
        path: None,
    };
    let mut reader = source.make_reader(home);
    let Some(timeline) = reader.read_appended() else { return };
    for item in &timeline.items {
        match &item.kind {
            TimelineItemKind::Prompt(text) => {
                emit_update(
                    sink,
                    session_id,
                    json!({
                        "sessionUpdate": "user_message_chunk",
                        "messageId": item.id,
                        "content": {"type": "text", "text": text},
                    }),
                );
            }
            TimelineItemKind::Reply(text) => {
                emit_update(
                    sink,
                    session_id,
                    json!({
                        "sessionUpdate": "agent_message_chunk",
                        "messageId": item.id,
                        "content": {"type": "text", "text": text},
                    }),
                );
            }
            TimelineItemKind::Thinking(text) => {
                emit_update(
                    sink,
                    session_id,
                    json!({
                        "sessionUpdate": "agent_thought_chunk",
                        "messageId": item.id,
                        "content": {"type": "text", "text": text},
                    }),
                );
            }
            TimelineItemKind::Tool(call) => {
                let kind = match call.name.as_str() {
                    "Run" | "Bash" => "execute",
                    "Read" => "read",
                    "Search" | "Grep" | "Glob" => "search",
                    "Edit" | "Write" => "edit",
                    _ => "other",
                };
                let status = match call.state {
                    ToolCallState::Failed => "failed",
                    ToolCallState::Interrupted => "cancelled",
                    ToolCallState::Running => "in_progress",
                    ToolCallState::Succeeded => "completed",
                };
                let title = if call.summary.is_empty() {
                    call.name.clone()
                } else {
                    format!("{} {}", call.name, call.summary)
                };
                let mut content = Vec::new();
                if let Some(output) = &call.output
                    && !output.is_empty()
                {
                    content.push(json!({"type": "content", "content": {"type": "text", "text": output}}));
                }
                emit_update(
                    sink,
                    session_id,
                    json!({
                        "sessionUpdate": "tool_call",
                        "toolCallId": item.id,
                        "kind": kind,
                        "title": title,
                        "status": status,
                        "rawInput": call.detail.as_ref().map(|d| json!({"command": d})).unwrap_or(Value::Null),
                        "content": content,
                    }),
                );
            }
            TimelineItemKind::Notice { .. } => {}
        }
    }
}

fn claude_tool_use_to_acp(
    block: &Value,
    started_tools: &mut HashSet<String>,
    tool_diffs: &mut HashMap<String, Vec<Value>>,
) -> Option<Value> {
    let id = block.get("id").and_then(Value::as_str)?;
    let name = block.get("name").and_then(Value::as_str).unwrap_or("tool");
    let input = block.get("input").cloned().unwrap_or(Value::Null);
    let (acp_kind, title) = claude_tool_summary(name, &input);
    let mut content = Vec::new();
    if matches!(name, "Edit" | "Write")
        && let Some(path) = input.get("file_path").and_then(Value::non_empty_string)
    {
        if name == "Edit" {
            let old = input.get("old_string").and_then(Value::as_str).unwrap_or("");
            let new = input.get("new_string").and_then(Value::as_str).unwrap_or("");
            if !old.is_empty() || !new.is_empty() {
                content.push(json!({"type": "diff", "path": path, "oldText": old, "newText": new}));
            }
        } else if let Some(new) = input.get("content").and_then(Value::as_str) {
            content.push(json!({"type": "diff", "path": path, "newText": new}));
        }
    }
    if !content.is_empty() {
        tool_diffs.insert(id.to_owned(), content.clone());
    }
    let already_started = !started_tools.insert(id.to_owned());
    let mut update = json!({
        "sessionUpdate": if already_started { "tool_call_update" } else { "tool_call" },
        "toolCallId": id,
        "kind": acp_kind,
        "title": title,
        "status": "in_progress",
        "rawInput": input,
    });
    if !content.is_empty() {
        update["content"] = Value::Array(content);
    }
    Some(update)
}

fn claude_tool_summary(name: &str, input: &Value) -> (&'static str, String) {
    match name {
        "Bash" => {
            let cmd = input.get("command").and_then(Value::non_empty_string).unwrap_or("bash");
            ("execute", cmd.to_owned())
        }
        "Read" => {
            let path = input.get("file_path").and_then(Value::non_empty_string).unwrap_or("file");
            ("read", format!("Read {path}"))
        }
        "Edit" | "MultiEdit" | "NotebookEdit" => {
            let path = input
                .get("file_path")
                .or_else(|| input.get("notebook_path"))
                .and_then(Value::non_empty_string)
                .unwrap_or("file");
            ("edit", format!("Edit {path}"))
        }
        "Write" => {
            let path = input.get("file_path").and_then(Value::non_empty_string).unwrap_or("file");
            ("edit", format!("Write {path}"))
        }
        "Grep" => {
            let pattern = input.get("pattern").and_then(Value::non_empty_string).unwrap_or("");
            let path = input.get("path").and_then(Value::non_empty_string);
            let title = match (pattern.is_empty(), path) {
                (false, Some(p)) => format!("Searched {pattern} in {p}"),
                (false, None) => format!("Searched {pattern}"),
                (true, Some(p)) => format!("Searched {p}"),
                (true, None) => "Searched".into(),
            };
            ("search", title)
        }
        "Glob" => {
            let pattern = input.get("pattern").and_then(Value::non_empty_string).unwrap_or("*");
            ("search", format!("Found {pattern}"))
        }
        "WebSearch" => {
            let query = input.get("query").and_then(Value::non_empty_string).unwrap_or("Web search");
            ("web_search", query.to_owned())
        }
        other => ("other", other.to_owned()),
    }
}

fn claude_tool_result_text(content: Option<&Value>) -> Option<String> {
    let content = content?;
    if let Some(text) = content.as_str() {
        return (!text.is_empty()).then(|| text.to_owned());
    }
    let parts = content.as_array()?;
    let joined: Vec<&str> = parts
        .iter()
        .filter_map(|p| {
            if p.get("type").and_then(Value::as_str) == Some("text") {
                p.get("text").and_then(Value::as_str)
            } else {
                None
            }
        })
        .filter(|s| !s.is_empty())
        .collect();
    (!joined.is_empty()).then(|| joined.join("\n"))
}

fn extract_claude_usage(msg: &Value) -> Option<(i64, i64)> {
    let usage = msg.get("usage")?;
    let input = usage.get("input_tokens").and_then(JsonValueExt::int).unwrap_or(0);
    let cache_read = usage.get("cache_read_input_tokens").and_then(JsonValueExt::int).unwrap_or(0);
    let cache_create = usage.get("cache_creation_input_tokens").and_then(JsonValueExt::int).unwrap_or(0);
    let output = usage.get("output_tokens").and_then(JsonValueExt::int).unwrap_or(0);
    let used = input + cache_read + cache_create + output;
    if used <= 0 {
        return None;
    }
    let size = msg
        .get("modelUsage")
        .and_then(Value::as_object)
        .and_then(|models| models.values().find_map(|m| m.get("contextWindow").and_then(JsonValueExt::int)))
        .unwrap_or(200_000);
    Some((used, size))
}

fn extract_prompt_text(params: &Value) -> String {
    params
        .get("prompt")
        .and_then(Value::as_array)
        .map(|blocks| {
            blocks
                .iter()
                .filter_map(|block| block.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

fn emit_update(sink: &PeerSink, session_id: &str, update: Value) {
    sink.send(PeerEvent::Notification {
        method: "session/update".into(),
        params: json!({"sessionId": session_id, "update": update}),
    });
}

/// Generates an RFC 4122 v4 UUID without extra crate dependencies.
fn generate_uuid_v4() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(1);
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let seq = COUNTER.fetch_add(1, Ordering::Relaxed) as u128;
    let pid = std::process::id() as u128;
    // Mix time, pid, and sequence using SplitMix64-style finalizers.
    let mut hi =
        (nanos as u64) ^ (pid as u64).rotate_left(17) ^ (seq as u64).wrapping_mul(0x9e37_79b9_7f4a_7c15);
    hi = (hi ^ (hi >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    hi = (hi ^ (hi >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    hi ^= hi >> 31;
    let mut lo =
        ((nanos >> 64) as u64) ^ (seq as u64).rotate_left(31) ^ hi.wrapping_mul(0x9e37_79b9_7f4a_7c15);
    lo = (lo ^ (lo >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    lo = (lo ^ (lo >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    lo ^= lo >> 31;

    let mut bytes = [0u8; 16];
    bytes[..8].copy_from_slice(&hi.to_be_bytes());
    bytes[8..].copy_from_slice(&lo.to_be_bytes());
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 1
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15]
    )
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::turn_builder::{AcpToolStyle, AcpTurnBuilder};
    use chrono::Utc;
    use soprano_agents::TurnItemKind;

    #[test]
    fn claude_translator_folds_streaming_text_thinking_tools_and_result_into_acp() {
        let mut tr = ClaudeStreamTranslator::new("sess-1");
        tr.pending_prompt_acp_id = Some(42);
        let mut builder = AcpTurnBuilder::new(Some("/work".into()), AcpToolStyle::Generic);
        builder.add_prompt("Fix bug", Utc::now());

        let messages = [
            json!({"type": "system", "subtype": "init", "session_id": "sess-1", "model": "claude-sonnet-4-6", "slash_commands": ["/compact", "/clear"]}),
            json!({"type": "stream_event", "event": {"type": "message_start"}}),
            json!({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "thinking_delta", "thinking": "Inspecting"}}}),
            json!({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "Done!"}}}),
            json!({"type": "assistant", "message": {"content": [
                {"type": "thinking", "thinking": "Inspecting"},
                {"type": "text", "text": "Done!"},
                {"type": "tool_use", "id": "tu-1", "name": "Edit", "input": {"file_path": "/work/a.rs", "old_string": "old", "new_string": "new"}}
            ]}}),
            json!({"type": "user", "message": {"content": [
                {"type": "tool_result", "tool_use_id": "tu-1", "content": "Updated a.rs", "is_error": false}
            ]}}),
            json!({"type": "result", "subtype": "success", "is_error": false, "usage": {"input_tokens": 500, "output_tokens": 100}}),
        ];

        let mut prompt_reply = None;
        let mut saw_commands = false;
        let mut saw_usage = false;
        for msg in &messages {
            for event in tr.handle_message(msg) {
                match event {
                    PeerEvent::Notification { method, params } if method == "session/update" => {
                        let update = params.get("update").expect("update");
                        match update.get("sessionUpdate").and_then(Value::as_str) {
                            Some("available_commands_update") => saw_commands = true,
                            Some("usage_update") => saw_usage = true,
                            _ => {
                                builder.apply(update, Utc::now());
                            }
                        }
                    }
                    PeerEvent::Response { id: 42, result } => prompt_reply = Some(result),
                    _ => {}
                }
            }
        }

        assert!(saw_commands);
        assert!(saw_usage);
        assert_eq!(prompt_reply, Some(Ok(json!({"stopReason": "end_turn"}))));
        let items = &builder.thread().turns[0].items;
        // Text & thinking were streamed, so `assistant` must not duplicate them.
        assert!(
            items.iter().any(|i| matches!(&i.kind, TurnItemKind::Reasoning { text } if text == "Inspecting"))
        );
        assert!(
            items
                .iter()
                .any(|i| matches!(&i.kind, TurnItemKind::AssistantMessage { text, .. } if text == "Done!"))
        );
        assert!(items.iter().any(|i| matches!(&i.kind, TurnItemKind::FileChange(changes) if changes.len() == 1 && changes[0].path == "a.rs")));
    }

    #[test]
    fn uuid_v4_has_standard_format_and_is_unique() {
        let a = generate_uuid_v4();
        let b = generate_uuid_v4();
        assert_eq!(a.len(), 36);
        assert_ne!(a, b);
        assert_eq!(&a[14..15], "4");
    }
}
