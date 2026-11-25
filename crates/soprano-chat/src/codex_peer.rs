//! Translates between Soprano's ACP [`AgentChatSession`](crate::AgentChatSession) and OpenAI
//! Codex's native `codex app-server --stdio` JSON-RPC 2.0 protocol.
//!
//! `AgentChatSession` sends standard ACP methods (`initialize`, `session/new`, `session/load`,
//! `session/prompt`, `session/cancel`, `session/set_config_option`, `_session/steering`) and
//! consumes ACP `session/update` notifications and permission/elicitation requests. This peer
//! wraps an inner [`JsonRpcPeer`] speaking Codex's app-server protocol (`initialize` +
//! `initialized`, `model/list`, `thread/start`, `thread/resume`, `turn/start`, `turn/steer`,
//! `turn/interrupt`, and `item/*` / `turn/*` notifications) so Codex works as a first-class
//! native Chat UI agent with zero external ACP wrappers.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;

use serde_json::{Map, Value, json};
use soprano_agents::JsonValueExt;

use crate::rpc::{JsonRpcConnection, JsonRpcError, JsonRpcPeer, PeerEvent, PeerSink};

/// Models returned by Codex's `model/list`, used to build ACP `configOptions` for the composer's
/// model and thinking-level chips.
#[derive(Clone, Debug, PartialEq, Eq)]
struct CodexModel {
    id: String,
    display_name: String,
    description: Option<String>,
    efforts: Vec<(String, Option<String>)>,
    default_effort: Option<String>,
}

#[derive(Clone, Debug)]
enum PendingCodexRequest {
    Initialize { acp_id: u64 },
    ModelList,
    ThreadStart { acp_id: u64 },
    ThreadResume { acp_id: u64 },
    TurnStart { acp_id: u64 },
    TurnSteer { acp_id: u64 },
}

#[derive(Clone, Debug)]
enum PendingServerRequest {
    CommandApproval { codex_id: Value },
    FileChangeApproval { codex_id: Value },
    UserInput { codex_id: Value, question_ids: Vec<String> },
}

#[derive(Default)]
struct BridgeState {
    next_acp_id: u64,
    next_server_req_id: u64,
    thread_id: Option<String>,
    active_turn_id: Option<String>,
    pending_prompt_acp_id: Option<u64>,
    current_model: Option<String>,
    current_effort: Option<String>,
    models: Vec<CodexModel>,
    pending_requests: HashMap<u64, PendingCodexRequest>,
    pending_server_requests: HashMap<String, PendingServerRequest>,
    /// Agent message item ids that already emitted `item/agentMessage/delta` chunks, so
    /// `item/completed` does not duplicate their text.
    streamed_messages: HashSet<String>,
    /// Reasoning item ids that already emitted delta chunks.
    streamed_reasoning: HashSet<String>,
    /// Accumulated command output per item id while `item/commandExecution/outputDelta` streams.
    command_outputs: HashMap<String, String>,
    /// Item ids that emitted a `tool_call` on `item/started`.
    started_tools: HashSet<String>,
}

impl BridgeState {
    fn alloc_acp_id(&mut self) -> u64 {
        self.next_acp_id += 1;
        self.next_acp_id
    }

    fn alloc_server_req_id(&mut self) -> String {
        self.next_server_req_id += 1;
        format!("codex-req-{}", self.next_server_req_id)
    }

    fn config_options(&self) -> Value {
        let mut options = Vec::new();
        if !self.models.is_empty() {
            let current = self
                .current_model
                .clone()
                .or_else(|| self.models.first().map(|m| m.id.clone()))
                .unwrap_or_default();
            let values: Vec<Value> = self
                .models
                .iter()
                .map(|m| {
                    let mut entry = json!({"value": m.id, "name": m.display_name});
                    if let Some(desc) = &m.description {
                        entry["description"] = Value::String(desc.clone());
                    }
                    entry
                })
                .collect();
            options.push(json!({
                "id": "model",
                "name": "Model",
                "category": "model",
                "type": "select",
                "currentValue": current,
                "options": values,
            }));

            let active_model = self.models.iter().find(|m| m.id == current).or_else(|| self.models.first());
            if let Some(model) = active_model
                && !model.efforts.is_empty()
            {
                let current_effort = self
                    .current_effort
                    .clone()
                    .filter(|e| model.efforts.iter().any(|(id, _)| id == e))
                    .or_else(|| model.default_effort.clone())
                    .or_else(|| model.efforts.first().map(|(id, _)| id.clone()))
                    .unwrap_or_default();
                let effort_values: Vec<Value> = model
                    .efforts
                    .iter()
                    .map(|(effort, desc)| {
                        let mut entry = json!({"value": effort, "name": effort_label(effort)});
                        if let Some(desc) = desc {
                            entry["description"] = Value::String(desc.clone());
                        }
                        entry
                    })
                    .collect();
                options.push(json!({
                    "id": "thought_level",
                    "name": "Reasoning",
                    "category": "thought_level",
                    "type": "select",
                    "currentValue": current_effort,
                    "options": effort_values,
                }));
            }
        }
        Value::Array(options)
    }
}

/// A [`JsonRpcPeer`] that speaks ACP to [`AgentChatSession`](crate::AgentChatSession) while
/// driving `codex app-server --stdio` underneath.
pub struct CodexAppServerPeer {
    inner: Arc<Mutex<Box<dyn JsonRpcPeer>>>,
    state: Arc<Mutex<BridgeState>>,
    sink: Arc<Mutex<Option<PeerSink>>>,
    exited: Arc<AtomicBool>,
    started: bool,
    bridge_thread: Option<JoinHandle<()>>,
}

impl CodexAppServerPeer {
    pub fn new(argv: Vec<String>, cwd: Option<PathBuf>, env: Option<Vec<(String, String)>>) -> Self {
        Self::with_inner(Box::new(JsonRpcConnection::new(argv, cwd, env)))
    }

    pub fn with_inner(inner: Box<dyn JsonRpcPeer>) -> Self {
        Self {
            inner: Arc::new(Mutex::new(inner)),
            state: Arc::new(Mutex::new(BridgeState::default())),
            sink: Arc::new(Mutex::new(None)),
            exited: Arc::new(AtomicBool::new(false)),
            started: false,
            bridge_thread: None,
        }
    }
}

impl JsonRpcPeer for CodexAppServerPeer {
    fn start(&mut self, sink: PeerSink) -> std::io::Result<()> {
        *lock(&self.sink) = Some(sink.clone());
        let (tx, rx) = mpsc::channel::<(u64, PeerEvent)>();
        let inner_sink = PeerSink::new(1, tx);
        lock(&self.inner).start(inner_sink)?;
        self.started = true;

        let inner = Arc::clone(&self.inner);
        let state = Arc::clone(&self.state);
        let exited = Arc::clone(&self.exited);
        let handle = std::thread::Builder::new()
            .name("soprano-codex-bridge".into())
            .spawn(move || {
                while let Ok((_, event)) = rx.recv() {
                    handle_inner_event(event, &inner, &state, &sink, &exited);
                }
            })
            .ok();
        self.bridge_thread = handle;
        Ok(())
    }

    fn request(&mut self, method: &str, params: Value) -> Result<u64, JsonRpcError> {
        if !self.started || self.exited.load(Ordering::SeqCst) {
            return Err(JsonRpcError::closed());
        }
        let acp_id = lock(&self.state).alloc_acp_id();
        match method {
            "initialize" => {
                let codex_params = json!({
                    "clientInfo": {
                        "name": "soprano",
                        "title": "Soprano",
                        "version": soprano_platform::identity::app_version(),
                    },
                    "capabilities": {
                        "experimentalApi": true,
                    },
                });
                send_codex_request(
                    &self.inner,
                    &self.state,
                    "initialize",
                    codex_params,
                    PendingCodexRequest::Initialize { acp_id },
                )?;
            }
            "session/new" => {
                let cwd = params.get("cwd").and_then(Value::as_str).map(str::to_owned);
                let model = lock(&self.state).current_model.clone();
                let mut codex_params = Map::new();
                if let Some(cwd) = cwd {
                    codex_params.insert("cwd".into(), Value::String(cwd));
                }
                if let Some(model) = model {
                    codex_params.insert("model".into(), Value::String(model));
                }
                codex_params.insert("approvalPolicy".into(), Value::String("never".into()));
                codex_params.insert("sandbox".into(), Value::String("danger-full-access".into()));
                send_codex_request(
                    &self.inner,
                    &self.state,
                    "thread/start",
                    Value::Object(codex_params),
                    PendingCodexRequest::ThreadStart { acp_id },
                )?;
            }
            "session/load" => {
                let thread_id =
                    params.get("sessionId").and_then(Value::as_str).unwrap_or_default().to_owned();
                let cwd = params.get("cwd").and_then(Value::as_str).map(str::to_owned);
                let mut codex_params = Map::new();
                codex_params.insert("threadId".into(), Value::String(thread_id));
                if let Some(cwd) = cwd {
                    codex_params.insert("cwd".into(), Value::String(cwd));
                }
                codex_params.insert("approvalPolicy".into(), Value::String("never".into()));
                codex_params.insert("sandbox".into(), Value::String("danger-full-access".into()));
                send_codex_request(
                    &self.inner,
                    &self.state,
                    "thread/resume",
                    Value::Object(codex_params),
                    PendingCodexRequest::ThreadResume { acp_id },
                )?;
            }
            "session/prompt" => {
                let text = extract_prompt_text(&params);
                let (thread_id, model, effort) = {
                    let s = lock(&self.state);
                    (s.thread_id.clone(), s.current_model.clone(), s.current_effort.clone())
                };
                let Some(thread_id) = thread_id else {
                    return Err(JsonRpcError::new(JsonRpcError::INTERNAL_ERROR, "No Codex thread open."));
                };
                let mut codex_params = Map::new();
                codex_params.insert("threadId".into(), Value::String(thread_id));
                codex_params
                    .insert("input".into(), json!([{"type": "text", "text": text, "text_elements": []}]));
                if let Some(model) = model {
                    codex_params.insert("model".into(), Value::String(model));
                }
                if let Some(effort) = effort {
                    codex_params.insert("effort".into(), Value::String(effort));
                }
                let mut inner_guard = lock(&self.inner);
                let mut state_guard = lock(&self.state);
                let codex_id = inner_guard.request("turn/start", Value::Object(codex_params))?;
                state_guard.pending_prompt_acp_id = Some(acp_id);
                state_guard.pending_requests.insert(codex_id, PendingCodexRequest::TurnStart { acp_id });
            }
            "_session/steering" => {
                let text = extract_prompt_text(&params);
                let (thread_id, turn_id) = {
                    let s = lock(&self.state);
                    (s.thread_id.clone(), s.active_turn_id.clone())
                };
                let (Some(thread_id), Some(turn_id)) = (thread_id, turn_id) else {
                    if let Some(sink) = lock(&self.sink).clone() {
                        sink.send(PeerEvent::Response {
                            id: acp_id,
                            result: Ok(json!({"outcome": "promptRequired"})),
                        });
                    }
                    return Ok(acp_id);
                };
                let codex_params = json!({
                    "threadId": thread_id,
                    "expectedTurnId": turn_id,
                    "input": [{"type": "text", "text": text, "text_elements": []}],
                });
                send_codex_request(
                    &self.inner,
                    &self.state,
                    "turn/steer",
                    codex_params,
                    PendingCodexRequest::TurnSteer { acp_id },
                )?;
            }
            "session/set_config_option" => {
                let config_id = params.get("configId").and_then(Value::as_str).unwrap_or("");
                let value = params.get("value").and_then(Value::as_str).unwrap_or("");
                let options = {
                    let mut s = lock(&self.state);
                    match config_id {
                        "model" if !value.is_empty() => {
                            s.current_model = Some(value.to_owned());
                            if let Some(model) = s.models.iter().find(|m| m.id == value)
                                && s.current_effort
                                    .as_ref()
                                    .is_none_or(|e| !model.efforts.iter().any(|(id, _)| id == e))
                            {
                                s.current_effort = model.default_effort.clone();
                            }
                        }
                        "thought_level" if !value.is_empty() => {
                            s.current_effort = Some(value.to_owned());
                        }
                        _ => {}
                    }
                    s.config_options()
                };
                if let Some(sink) = lock(&self.sink).clone() {
                    sink.send(PeerEvent::Response {
                        id: acp_id,
                        result: Ok(json!({"configOptions": options})),
                    });
                }
            }
            _ => {
                if let Some(sink) = lock(&self.sink).clone() {
                    sink.send(PeerEvent::Response {
                        id: acp_id,
                        result: Err(JsonRpcError::new(
                            JsonRpcError::METHOD_NOT_FOUND,
                            format!("Unsupported method: {method}"),
                        )),
                    });
                }
            }
        }
        Ok(acp_id)
    }

    fn notify(&mut self, method: &str, _params: Value) {
        if method == "session/cancel" {
            let (thread_id, turn_id) = {
                let s = lock(&self.state);
                (s.thread_id.clone(), s.active_turn_id.clone())
            };
            if let (Some(thread_id), Some(turn_id)) = (thread_id, turn_id) {
                let _ = lock(&self.inner)
                    .request("turn/interrupt", json!({"threadId": thread_id, "turnId": turn_id}));
            }
        }
    }

    fn reply(&mut self, id: Value, result: Result<Value, JsonRpcError>) {
        let Some(key) = id.as_str() else { return };
        let Some(pending) = lock(&self.state).pending_server_requests.remove(key) else { return };
        match pending {
            PendingServerRequest::CommandApproval { codex_id } => {
                let decision = match &result {
                    Ok(value) => codex_approval_decision(value),
                    Err(_) => "cancel",
                };
                lock(&self.inner).reply(codex_id, Ok(json!({"decision": decision})));
            }
            PendingServerRequest::FileChangeApproval { codex_id } => {
                let decision = match &result {
                    Ok(value) => codex_approval_decision(value),
                    Err(_) => "cancel",
                };
                lock(&self.inner).reply(codex_id, Ok(json!({"decision": decision})));
            }
            PendingServerRequest::UserInput { codex_id, question_ids } => {
                let mut answers = Map::new();
                if let Ok(value) = result
                    && value.get("action").and_then(Value::as_str) == Some("accept")
                    && let Some(content) = value.get("content").and_then(Value::as_object)
                {
                    for qid in &question_ids {
                        let other_key = format!("{qid}__other");
                        let list: Vec<Value> =
                            if let Some(other) = content.get(&other_key).and_then(Value::non_empty_string) {
                                vec![Value::String(other.to_owned())]
                            } else if let Some(val) = content.get(qid).and_then(Value::as_str) {
                                vec![Value::String(val.to_owned())]
                            } else if let Some(arr) = content.get(qid).and_then(Value::as_array) {
                                arr.iter()
                                    .filter_map(Value::as_str)
                                    .map(|s| Value::String(s.to_owned()))
                                    .collect()
                            } else {
                                Vec::new()
                            };
                        answers.insert(qid.clone(), json!({"answers": list}));
                    }
                }
                lock(&self.inner).reply(codex_id, Ok(json!({"answers": Value::Object(answers)})));
            }
        }
    }

    fn terminate(&mut self) {
        lock(&self.inner).terminate();
    }

    fn has_exited(&self) -> bool {
        !self.started || self.exited.load(Ordering::SeqCst) || lock(&self.inner).has_exited()
    }
}

impl Drop for CodexAppServerPeer {
    fn drop(&mut self) {
        self.bridge_thread = None;
    }
}

/// Sends a Codex JSON-RPC request and records its pending ACP handler atomically under the
/// consistent `inner` -> `state` lock order so a fast/synchronous response can never beat the
/// pending map insertion.
fn send_codex_request(
    inner: &Arc<Mutex<Box<dyn JsonRpcPeer>>>,
    state: &Arc<Mutex<BridgeState>>,
    method: &str,
    params: Value,
    pending: PendingCodexRequest,
) -> Result<(), JsonRpcError> {
    let mut inner_guard = lock(inner);
    let mut state_guard = lock(state);
    let codex_id = inner_guard.request(method, params)?;
    state_guard.pending_requests.insert(codex_id, pending);
    Ok(())
}

fn handle_inner_event(
    event: PeerEvent,
    inner: &Arc<Mutex<Box<dyn JsonRpcPeer>>>,
    state: &Arc<Mutex<BridgeState>>,
    sink: &PeerSink,
    exited: &Arc<AtomicBool>,
) {
    match event {
        PeerEvent::Response { id, result } => {
            let pending = lock(state).pending_requests.remove(&id);
            let Some(pending) = pending else { return };
            match pending {
                PendingCodexRequest::Initialize { acp_id } => match result {
                    Ok(_) => {
                        lock(inner).notify("initialized", json!({}));
                        let _ = send_codex_request(
                            inner,
                            state,
                            "model/list",
                            json!({}),
                            PendingCodexRequest::ModelList,
                        );
                        sink.send(PeerEvent::Response {
                            id: acp_id,
                            result: Ok(json!({
                                "protocolVersion": 1,
                                "agentCapabilities": { "loadSession": true },
                                "_meta": { "steering": { "supported": true } },
                            })),
                        });
                    }
                    Err(error) => sink.send(PeerEvent::Response { id: acp_id, result: Err(error) }),
                },
                PendingCodexRequest::ModelList => {
                    if let Ok(value) = result {
                        let models = parse_codex_models(&value);
                        let update = {
                            let mut s = lock(state);
                            s.models = models;
                            s.thread_id.clone().map(|sid| (sid, s.config_options()))
                        };
                        if let Some((session_id, options)) = update
                            && options.as_array().is_some_and(|a| !a.is_empty())
                        {
                            emit_session_update(
                                sink,
                                &session_id,
                                json!({
                                    "sessionUpdate": "config_option_update",
                                    "configOptions": options,
                                }),
                            );
                        }
                    }
                }
                PendingCodexRequest::ThreadStart { acp_id } => match result {
                    Ok(value) => {
                        let (session_id, options) = record_thread_open(state, &value);
                        match session_id {
                            Some(id) => sink.send(PeerEvent::Response {
                                id: acp_id,
                                result: Ok(json!({"sessionId": id, "configOptions": options})),
                            }),
                            None => sink.send(PeerEvent::Response {
                                id: acp_id,
                                result: Err(JsonRpcError::new(
                                    JsonRpcError::INTERNAL_ERROR,
                                    "Codex returned no thread id.",
                                )),
                            }),
                        }
                    }
                    Err(error) => sink.send(PeerEvent::Response { id: acp_id, result: Err(error) }),
                },
                PendingCodexRequest::ThreadResume { acp_id } => match result {
                    Ok(value) => {
                        let (session_id, options) = record_thread_open(state, &value);
                        match session_id {
                            Some(id) => {
                                if let Some(turns) =
                                    value.get("thread").and_then(|t| t.get("turns")).and_then(Value::as_array)
                                {
                                    replay_codex_turns(sink, &id, turns);
                                }
                                sink.send(PeerEvent::Response {
                                    id: acp_id,
                                    result: Ok(json!({"sessionId": id, "configOptions": options})),
                                });
                            }
                            None => sink.send(PeerEvent::Response {
                                id: acp_id,
                                result: Err(JsonRpcError::new(
                                    JsonRpcError::INTERNAL_ERROR,
                                    "Codex returned no thread id on resume.",
                                )),
                            }),
                        }
                    }
                    Err(error) => sink.send(PeerEvent::Response { id: acp_id, result: Err(error) }),
                },
                PendingCodexRequest::TurnStart { acp_id } => match result {
                    Ok(value) => {
                        if let Some(turn_id) =
                            value.get("turn").and_then(|t| t.get("id")).and_then(Value::as_str)
                        {
                            lock(state).active_turn_id = Some(turn_id.to_owned());
                        }
                    }
                    Err(error) => {
                        let mut s = lock(state);
                        if s.pending_prompt_acp_id == Some(acp_id) {
                            s.pending_prompt_acp_id = None;
                        }
                        drop(s);
                        sink.send(PeerEvent::Response { id: acp_id, result: Err(error) });
                    }
                },
                PendingCodexRequest::TurnSteer { acp_id } => {
                    let outcome = match result {
                        Ok(_) => json!({"outcome": "steered"}),
                        Err(_) => json!({"outcome": "promptRequired"}),
                    };
                    sink.send(PeerEvent::Response { id: acp_id, result: Ok(outcome) });
                }
            }
        }
        PeerEvent::Notification { method, params } => {
            handle_codex_notification(&method, &params, state, sink);
        }
        PeerEvent::Request { id, method, params } => {
            handle_codex_request(id, &method, &params, inner, state, sink);
        }
        PeerEvent::Exit { status, stderr } => {
            exited.store(true, Ordering::SeqCst);
            let pending_acp_ids: Vec<u64> = {
                let mut s = lock(state);
                let mut ids: Vec<u64> = s
                    .pending_requests
                    .drain()
                    .filter_map(|(_, req)| match req {
                        PendingCodexRequest::Initialize { acp_id }
                        | PendingCodexRequest::ThreadStart { acp_id }
                        | PendingCodexRequest::ThreadResume { acp_id }
                        | PendingCodexRequest::TurnStart { acp_id }
                        | PendingCodexRequest::TurnSteer { acp_id } => Some(acp_id),
                        PendingCodexRequest::ModelList => None,
                    })
                    .collect();
                if let Some(prompt_id) = s.pending_prompt_acp_id.take()
                    && !ids.contains(&prompt_id)
                {
                    ids.push(prompt_id);
                }
                ids
            };
            for acp_id in pending_acp_ids {
                sink.send(PeerEvent::Response { id: acp_id, result: Err(JsonRpcError::closed()) });
            }
            sink.send(PeerEvent::Exit { status, stderr });
        }
    }
}

fn record_thread_open(state: &Arc<Mutex<BridgeState>>, value: &Value) -> (Option<String>, Value) {
    let mut s = lock(state);
    let session_id = value.get("thread").and_then(|t| t.get("id")).and_then(Value::as_str).map(str::to_owned);
    if let Some(id) = &session_id {
        s.thread_id = Some(id.clone());
    }
    if let Some(model) = value.get("model").and_then(Value::non_empty_string) {
        s.current_model = Some(model.to_owned());
    }
    if let Some(effort) = value.get("reasoningEffort").and_then(Value::non_empty_string) {
        s.current_effort = Some(effort.to_owned());
    }
    let options = s.config_options();
    (session_id, options)
}

fn handle_codex_notification(method: &str, params: &Value, state: &Arc<Mutex<BridgeState>>, sink: &PeerSink) {
    let session_id = {
        let s = lock(state);
        params.get("threadId").and_then(Value::as_str).map(str::to_owned).or_else(|| s.thread_id.clone())
    };
    let Some(session_id) = session_id else { return };

    match method {
        "turn/started" => {
            if let Some(turn_id) = params.get("turn").and_then(|t| t.get("id")).and_then(Value::as_str) {
                lock(state).active_turn_id = Some(turn_id.to_owned());
            }
        }
        "turn/completed" => {
            let prompt_acp_id = {
                let mut s = lock(state);
                s.active_turn_id = None;
                s.streamed_messages.clear();
                s.streamed_reasoning.clear();
                s.command_outputs.clear();
                s.started_tools.clear();
                s.pending_prompt_acp_id.take()
            };
            let Some(acp_id) = prompt_acp_id else { return };
            let turn = params.get("turn").unwrap_or(&Value::Null);
            let status = turn.get("status").and_then(Value::as_str).unwrap_or("completed");
            let response = match status {
                "interrupted" => Ok(json!({"stopReason": "cancelled"})),
                "failed" => {
                    let message = turn
                        .get("error")
                        .and_then(|e| e.get("message"))
                        .and_then(Value::non_empty_string)
                        .unwrap_or("Codex turn failed");
                    Err(JsonRpcError::new(JsonRpcError::INTERNAL_ERROR, message))
                }
                _ => Ok(json!({"stopReason": "end_turn"})),
            };
            sink.send(PeerEvent::Response { id: acp_id, result: response });
        }
        "item/agentMessage/delta" => {
            let item_id = params.get("itemId").and_then(Value::as_str).unwrap_or("msg");
            let delta = params.get("delta").and_then(Value::as_str).unwrap_or("");
            if delta.is_empty() {
                return;
            }
            lock(state).streamed_messages.insert(item_id.to_owned());
            emit_session_update(
                sink,
                &session_id,
                json!({
                    "sessionUpdate": "agent_message_chunk",
                    "messageId": item_id,
                    "content": {"type": "text", "text": delta},
                }),
            );
        }
        "item/reasoning/summaryTextDelta" | "item/reasoning/textDelta" => {
            let item_id = params.get("itemId").and_then(Value::as_str).unwrap_or("reasoning");
            let delta = params.get("delta").and_then(Value::as_str).unwrap_or("");
            if delta.is_empty() {
                return;
            }
            lock(state).streamed_reasoning.insert(item_id.to_owned());
            emit_session_update(
                sink,
                &session_id,
                json!({
                    "sessionUpdate": "agent_thought_chunk",
                    "messageId": item_id,
                    "content": {"type": "text", "text": delta},
                }),
            );
        }
        "item/commandExecution/outputDelta" => {
            let Some(item_id) = params.get("itemId").and_then(Value::as_str) else { return };
            let delta = params.get("delta").and_then(Value::as_str).unwrap_or("");
            if delta.is_empty() {
                return;
            }
            let output = {
                let mut s = lock(state);
                let buf = s.command_outputs.entry(item_id.to_owned()).or_default();
                buf.push_str(delta);
                buf.clone()
            };
            emit_session_update(
                sink,
                &session_id,
                json!({
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": item_id,
                    "status": "in_progress",
                    "content": [{"type": "content", "content": {"type": "text", "text": output}}],
                }),
            );
        }
        "item/started" => {
            let Some(item) = params.get("item") else { return };
            if let Some(update) = codex_item_to_acp_start(item) {
                if let Some(id) = item.get("id").and_then(Value::as_str) {
                    lock(state).started_tools.insert(id.to_owned());
                }
                emit_session_update(sink, &session_id, update);
            }
        }
        "item/completed" => {
            let Some(item) = params.get("item") else { return };
            let item_type = item.get("type").and_then(Value::as_str).unwrap_or("");
            let item_id = item.get("id").and_then(Value::as_str).unwrap_or("");
            match item_type {
                "agentMessage" => {
                    let already_streamed = lock(state).streamed_messages.contains(item_id);
                    if !already_streamed
                        && let Some(text) = item.get("text").and_then(Value::non_empty_string)
                    {
                        emit_session_update(
                            sink,
                            &session_id,
                            json!({
                                "sessionUpdate": "agent_message_chunk",
                                "messageId": item_id,
                                "content": {"type": "text", "text": text},
                            }),
                        );
                    }
                }
                "reasoning" => {
                    let already_streamed = lock(state).streamed_reasoning.contains(item_id);
                    if !already_streamed {
                        let text = codex_reasoning_text(item);
                        if !text.is_empty() {
                            emit_session_update(
                                sink,
                                &session_id,
                                json!({
                                    "sessionUpdate": "agent_thought_chunk",
                                    "messageId": item_id,
                                    "content": {"type": "text", "text": text},
                                }),
                            );
                        }
                    }
                }
                "contextCompaction" => {
                    sink.send(PeerEvent::Notification {
                        method: "_omp/compaction/end".into(),
                        params: json!({}),
                    });
                }
                _ => {
                    let was_started = lock(state).started_tools.contains(item_id);
                    if !was_started && let Some(start) = codex_item_to_acp_start(item) {
                        emit_session_update(sink, &session_id, start);
                    }
                    if let Some(update) = codex_item_to_acp_complete(item) {
                        emit_session_update(sink, &session_id, update);
                    }
                }
            }
        }
        "thread/tokenUsage/updated" => {
            let Some(usage) = params.get("tokenUsage") else { return };
            let used =
                usage.get("last").and_then(|l| l.get("totalTokens")).and_then(JsonValueExt::int).or_else(
                    || usage.get("total").and_then(|t| t.get("totalTokens")).and_then(JsonValueExt::int),
                );
            let size = usage.get("modelContextWindow").and_then(JsonValueExt::int);
            if let (Some(used), Some(size)) = (used, size)
                && size > 0
            {
                emit_session_update(
                    sink,
                    &session_id,
                    json!({
                        "sessionUpdate": "usage_update",
                        "used": used,
                        "size": size,
                    }),
                );
            }
        }
        "thread/name/updated" => {
            if let Some(title) = params.get("threadName").and_then(Value::non_empty_string) {
                emit_session_update(
                    sink,
                    &session_id,
                    json!({
                        "sessionUpdate": "session_info_update",
                        "title": title,
                    }),
                );
            }
        }
        "thread/compacted" => {
            sink.send(PeerEvent::Notification { method: "_omp/compaction/end".into(), params: json!({}) });
        }
        _ => {}
    }
}

fn handle_codex_request(
    codex_id: Value,
    method: &str,
    params: &Value,
    inner: &Arc<Mutex<Box<dyn JsonRpcPeer>>>,
    state: &Arc<Mutex<BridgeState>>,
    sink: &PeerSink,
) {
    match method {
        "item/commandExecution/requestApproval" => {
            let command = params.get("command").and_then(Value::non_empty_string).unwrap_or("Run command");
            let title = params
                .get("reason")
                .and_then(Value::non_empty_string)
                .map(str::to_owned)
                .unwrap_or_else(|| format!("$ {command}"));
            let req_id = {
                let mut s = lock(state);
                let id = s.alloc_server_req_id();
                s.pending_server_requests
                    .insert(id.clone(), PendingServerRequest::CommandApproval { codex_id });
                id
            };
            sink.send(PeerEvent::Request {
                id: Value::String(req_id),
                method: "session/request_permission".into(),
                params: json!({
                    "toolCall": {
                        "title": title,
                        "kind": "execute",
                        "rawInput": {"command": command},
                    },
                    "options": approval_options(),
                }),
            });
        }
        "item/fileChange/requestApproval" => {
            let title = params
                .get("reason")
                .and_then(Value::non_empty_string)
                .or_else(|| params.get("grantRoot").and_then(Value::non_empty_string))
                .unwrap_or("Apply file changes");
            let req_id = {
                let mut s = lock(state);
                let id = s.alloc_server_req_id();
                s.pending_server_requests
                    .insert(id.clone(), PendingServerRequest::FileChangeApproval { codex_id });
                id
            };
            sink.send(PeerEvent::Request {
                id: Value::String(req_id),
                method: "session/request_permission".into(),
                params: json!({
                    "toolCall": {
                        "title": title,
                        "kind": "edit",
                    },
                    "options": approval_options(),
                }),
            });
        }
        "item/tool/requestUserInput" => {
            let questions = params.get("questions").and_then(Value::as_array).cloned().unwrap_or_default();
            if questions.is_empty() {
                lock(inner).reply(codex_id, Ok(json!({"answers": {}})));
                return;
            }
            let mut properties = Map::new();
            let mut question_ids = Vec::new();
            for q in &questions {
                let Some(qid) = q.get("id").and_then(Value::as_str) else { continue };
                question_ids.push(qid.to_owned());
                let title = q.get("question").and_then(Value::as_str).unwrap_or("");
                let header = q.get("header").and_then(Value::as_str).unwrap_or("");
                let is_other = q.get("isOther").and_then(Value::as_bool).unwrap_or(false);
                let options: Vec<Value> = q
                    .get("options")
                    .and_then(Value::as_array)
                    .map(|opts| {
                        opts.iter()
                            .filter_map(|o| {
                                let label = o.get("label").and_then(Value::as_str)?;
                                let desc = o.get("description").and_then(Value::as_str).unwrap_or("");
                                Some(json!({"const": label, "description": desc}))
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                let mut prop = Map::new();
                prop.insert("type".into(), Value::String("string".into()));
                prop.insert("title".into(), Value::String(title.to_owned()));
                if !header.is_empty() {
                    prop.insert("description".into(), Value::String(header.to_owned()));
                }
                if !options.is_empty() {
                    prop.insert("oneOf".into(), Value::Array(options));
                }
                properties.insert(qid.to_owned(), Value::Object(prop));
                if is_other {
                    properties.insert(format!("{qid}__other"), json!({"type": "string"}));
                }
            }
            let req_id = {
                let mut s = lock(state);
                let id = s.alloc_server_req_id();
                s.pending_server_requests
                    .insert(id.clone(), PendingServerRequest::UserInput { codex_id, question_ids });
                id
            };
            sink.send(PeerEvent::Request {
                id: Value::String(req_id),
                method: "elicitation/create".into(),
                params: json!({
                    "mode": "form",
                    "message": "Input requested",
                    "requestedSchema": {
                        "type": "object",
                        "properties": Value::Object(properties),
                    },
                }),
            });
        }
        _ => {
            lock(inner).reply(
                codex_id,
                Err(JsonRpcError::new(JsonRpcError::METHOD_NOT_FOUND, format!("Method not found: {method}"))),
            );
        }
    }
}

/// Replays a resumed Codex thread's turns as ACP `session/update` notifications so the timeline
/// shows full prior history immediately.
fn replay_codex_turns(sink: &PeerSink, session_id: &str, turns: &[Value]) {
    for turn in turns {
        let Some(items) = turn.get("items").and_then(Value::as_array) else { continue };
        for item in items {
            let item_type = item.get("type").and_then(Value::as_str).unwrap_or("");
            let item_id = item.get("id").and_then(Value::as_str).unwrap_or("replayed");
            match item_type {
                "userMessage" => {
                    let text = codex_user_message_text(item);
                    if !text.is_empty() {
                        emit_session_update(
                            sink,
                            session_id,
                            json!({
                                "sessionUpdate": "user_message_chunk",
                                "messageId": item_id,
                                "content": {"type": "text", "text": text},
                            }),
                        );
                    }
                }
                "agentMessage" => {
                    if let Some(text) = item.get("text").and_then(Value::non_empty_string) {
                        emit_session_update(
                            sink,
                            session_id,
                            json!({
                                "sessionUpdate": "agent_message_chunk",
                                "messageId": item_id,
                                "content": {"type": "text", "text": text},
                            }),
                        );
                    }
                }
                "reasoning" => {
                    let text = codex_reasoning_text(item);
                    if !text.is_empty() {
                        emit_session_update(
                            sink,
                            session_id,
                            json!({
                                "sessionUpdate": "agent_thought_chunk",
                                "messageId": item_id,
                                "content": {"type": "text", "text": text},
                            }),
                        );
                    }
                }
                _ => {
                    if let Some(start) = codex_item_to_acp_start(item) {
                        emit_session_update(sink, session_id, start);
                    }
                    if let Some(complete) = codex_item_to_acp_complete(item) {
                        emit_session_update(sink, session_id, complete);
                    }
                }
            }
        }
    }
}

fn codex_item_to_acp_start(item: &Value) -> Option<Value> {
    let id = item.get("id").and_then(Value::as_str)?;
    let kind = item.get("type").and_then(Value::as_str)?;
    match kind {
        "commandExecution" => {
            let command = item.get("command").and_then(Value::as_str).unwrap_or("");
            Some(json!({
                "sessionUpdate": "tool_call",
                "toolCallId": id,
                "kind": "execute",
                "title": command,
                "status": "in_progress",
                "rawInput": {"command": command},
            }))
        }
        "fileChange" => {
            let changes = codex_file_change_blocks(item);
            let title =
                changes.first().and_then(|c| c.get("path")).and_then(Value::as_str).unwrap_or("Edit files");
            Some(json!({
                "sessionUpdate": "tool_call",
                "toolCallId": id,
                "kind": "edit",
                "title": title,
                "status": "in_progress",
                "content": changes,
            }))
        }
        "mcpToolCall" => {
            let server = item.get("server").and_then(Value::as_str).unwrap_or("");
            let tool = item.get("tool").and_then(Value::as_str).unwrap_or("mcp");
            let title = if server.is_empty() { tool.to_owned() } else { format!("{server}: {tool}") };
            Some(json!({
                "sessionUpdate": "tool_call",
                "toolCallId": id,
                "kind": "other",
                "title": title,
                "status": "in_progress",
                "rawInput": item.get("arguments").cloned().unwrap_or(Value::Null),
            }))
        }
        "dynamicToolCall" => {
            let tool = item.get("tool").and_then(Value::as_str).unwrap_or("tool");
            Some(json!({
                "sessionUpdate": "tool_call",
                "toolCallId": id,
                "kind": "other",
                "title": tool,
                "status": "in_progress",
                "rawInput": item.get("arguments").cloned().unwrap_or(Value::Null),
            }))
        }
        "webSearch" => {
            let query = item.get("query").and_then(Value::as_str).unwrap_or("Web search");
            Some(json!({
                "sessionUpdate": "tool_call",
                "toolCallId": id,
                "kind": "web_search",
                "title": query,
                "status": "in_progress",
                "rawInput": {"query": query},
            }))
        }
        "imageView" => {
            let path = item.get("path").and_then(Value::as_str).unwrap_or("image");
            Some(json!({
                "sessionUpdate": "tool_call",
                "toolCallId": id,
                "kind": "read",
                "title": format!("Viewed {path}"),
                "status": "in_progress",
            }))
        }
        "collabAgentToolCall" => {
            let tool = item.get("tool").and_then(Value::as_str).unwrap_or("subagent");
            Some(json!({
                "sessionUpdate": "tool_call",
                "toolCallId": id,
                "kind": "other",
                "title": format!("Agent: {tool}"),
                "status": "in_progress",
            }))
        }
        _ => None,
    }
}

fn codex_item_to_acp_complete(item: &Value) -> Option<Value> {
    let id = item.get("id").and_then(Value::as_str)?;
    let kind = item.get("type").and_then(Value::as_str)?;
    match kind {
        "commandExecution" => {
            let exit_code = item.get("exitCode").and_then(JsonValueExt::int);
            let status = match item.get("status").and_then(Value::as_str) {
                Some("failed") => "failed",
                Some("declined") => "cancelled",
                _ if exit_code.is_some_and(|c| c != 0) => "failed",
                _ => "completed",
            };
            let output = item.get("aggregatedOutput").and_then(Value::as_str).unwrap_or("");
            let content = if output.is_empty() {
                Vec::new()
            } else {
                vec![json!({"type": "content", "content": {"type": "text", "text": output}})]
            };
            let mut raw_output = Map::new();
            if let Some(code) = exit_code {
                raw_output.insert("exitCode".into(), Value::Number(code.into()));
            }
            Some(json!({
                "sessionUpdate": "tool_call_update",
                "toolCallId": id,
                "status": status,
                "content": content,
                "rawOutput": Value::Object(raw_output),
            }))
        }
        "fileChange" => {
            let status = match item.get("status").and_then(Value::as_str) {
                Some("failed") => "failed",
                Some("declined") => "cancelled",
                _ => "completed",
            };
            let changes = codex_file_change_blocks(item);
            Some(json!({
                "sessionUpdate": "tool_call_update",
                "toolCallId": id,
                "status": status,
                "content": changes,
            }))
        }
        "mcpToolCall" => {
            let status = match item.get("status").and_then(Value::as_str) {
                Some("failed") => "failed",
                _ => "completed",
            };
            let output = item
                .get("error")
                .and_then(|e| e.get("message"))
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| {
                    item.get("result")
                        .and_then(|r| r.get("content"))
                        .and_then(Value::as_array)
                        .map(|parts| {
                            parts
                                .iter()
                                .filter_map(|p| p.get("text").and_then(Value::as_str))
                                .collect::<Vec<_>>()
                                .join("\n")
                        })
                        .filter(|s| !s.is_empty())
                });
            let content = output
                .map(|text| vec![json!({"type": "content", "content": {"type": "text", "text": text}})])
                .unwrap_or_default();
            Some(json!({
                "sessionUpdate": "tool_call_update",
                "toolCallId": id,
                "status": status,
                "content": content,
            }))
        }
        "dynamicToolCall" | "webSearch" | "imageView" | "collabAgentToolCall" => {
            let status = match item.get("status").and_then(Value::as_str) {
                Some("failed") => "failed",
                _ => "completed",
            };
            Some(json!({
                "sessionUpdate": "tool_call_update",
                "toolCallId": id,
                "status": status,
            }))
        }
        _ => None,
    }
}

fn codex_file_change_blocks(item: &Value) -> Vec<Value> {
    let Some(changes) = item.get("changes").and_then(Value::as_array) else { return Vec::new() };
    changes
        .iter()
        .filter_map(|change| {
            let path = change.get("path").and_then(Value::non_empty_string)?;
            let kind_obj = change.get("kind");
            let kind = kind_obj.and_then(|k| k.get("type")).and_then(Value::as_str).unwrap_or("update");
            let move_path = kind_obj.and_then(|k| k.get("move_path")).and_then(Value::non_empty_string);
            let diff = change.get("diff").and_then(Value::as_str).unwrap_or("");
            let mut block = json!({
                "type": "unified_diff",
                "path": path,
                "kind": kind,
                "diff": diff,
            });
            if let Some(dest) = move_path {
                block["movePath"] = Value::String(dest.to_owned());
            }
            Some(block)
        })
        .collect()
}

fn codex_user_message_text(item: &Value) -> String {
    item.get("content")
        .and_then(Value::as_array)
        .map(|parts| {
            parts
                .iter()
                .filter_map(|part| match part.get("type").and_then(Value::as_str) {
                    Some("text") => part.get("text").and_then(Value::as_str),
                    Some("image" | "localImage") => Some("[image]"),
                    _ => None,
                })
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

fn codex_reasoning_text(item: &Value) -> String {
    let summary: Vec<&str> = item
        .get("summary")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter_map(Value::as_str).filter(|s| !s.is_empty()).collect())
        .unwrap_or_default();
    if !summary.is_empty() {
        return summary.join("\n\n");
    }
    item.get("content")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter().filter_map(Value::as_str).filter(|s| !s.is_empty()).collect::<Vec<_>>().join("\n\n")
        })
        .unwrap_or_default()
}

fn parse_codex_models(value: &Value) -> Vec<CodexModel> {
    let Some(data) = value.get("data").and_then(Value::as_array) else { return Vec::new() };
    data.iter()
        .filter(|m| m.get("hidden").and_then(Value::as_bool) != Some(true))
        .filter_map(|m| {
            let id = m.get("model").or_else(|| m.get("id")).and_then(Value::non_empty_string)?;
            let display_name = m.get("displayName").and_then(Value::non_empty_string).unwrap_or(id);
            let description = m.get("description").and_then(Value::non_empty_string).map(str::to_owned);
            let efforts: Vec<(String, Option<String>)> = m
                .get("supportedReasoningEfforts")
                .and_then(Value::as_array)
                .map(|opts| {
                    opts.iter()
                        .filter_map(|o| {
                            let effort = o.get("reasoningEffort").and_then(Value::non_empty_string)?;
                            let desc =
                                o.get("description").and_then(Value::non_empty_string).map(str::to_owned);
                            Some((effort.to_owned(), desc))
                        })
                        .collect()
                })
                .unwrap_or_default();
            let default_effort =
                m.get("defaultReasoningEffort").and_then(Value::non_empty_string).map(str::to_owned);
            Some(CodexModel {
                id: id.to_owned(),
                display_name: display_name.to_owned(),
                description,
                efforts,
                default_effort,
            })
        })
        .collect()
}

fn effort_label(raw: &str) -> String {
    match raw {
        "none" => "None".into(),
        "minimal" => "Minimal".into(),
        "low" => "Low".into(),
        "medium" => "Medium".into(),
        "high" => "High".into(),
        "xhigh" => "Extra high".into(),
        other => other.to_owned(),
    }
}

fn approval_options() -> Value {
    json!([
        {"optionId": "accept", "name": "Allow once", "kind": "allow_once"},
        {"optionId": "acceptForSession", "name": "Allow for session", "kind": "allow_always"},
        {"optionId": "decline", "name": "Deny", "kind": "reject_once"},
    ])
}

fn codex_approval_decision(acp_reply: &Value) -> &'static str {
    let outcome = acp_reply.get("outcome");
    match outcome.and_then(|o| o.get("outcome")).and_then(Value::as_str) {
        Some("selected") => match outcome.and_then(|o| o.get("optionId")).and_then(Value::as_str) {
            Some("accept") => "accept",
            Some("acceptForSession") => "acceptForSession",
            Some("decline") => "decline",
            _ => "cancel",
        },
        _ => "cancel",
    }
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

fn emit_session_update(sink: &PeerSink, session_id: &str, update: Value) {
    sink.send(PeerEvent::Notification {
        method: "session/update".into(),
        params: json!({"sessionId": session_id, "update": update}),
    });
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    use crate::session::{AgentChatLaunch, AgentChatSession, ChatPhase, LaunchSpec};
    use soprano_agents::TurnItemKind;
    use soprano_types::DefaultAgents;

    struct FakeCodexServer {
        sink: Option<PeerSink>,
        next_id: u64,
        received: Arc<Mutex<Vec<(String, Value)>>>,
        resumed_turns: Vec<Value>,
    }

    impl FakeCodexServer {
        fn new(received: Arc<Mutex<Vec<(String, Value)>>>, resumed_turns: Vec<Value>) -> Self {
            Self { sink: None, next_id: 0, received, resumed_turns }
        }
    }

    impl JsonRpcPeer for FakeCodexServer {
        fn start(&mut self, sink: PeerSink) -> std::io::Result<()> {
            self.sink = Some(sink);
            Ok(())
        }

        fn request(&mut self, method: &str, params: Value) -> Result<u64, JsonRpcError> {
            self.next_id += 1;
            let id = self.next_id;
            lock(&self.received).push((method.to_owned(), params.clone()));
            let sink = self.sink.clone().expect("started");
            match method {
                "initialize" => {
                    sink.send(PeerEvent::Response {
                        id,
                        result: Ok(json!({"userAgent": "codex", "codexHome": "/tmp", "platformFamily": "unix", "platformOs": "macos"})),
                    });
                }
                "model/list" => {
                    sink.send(PeerEvent::Response {
                        id,
                        result: Ok(json!({
                            "data": [{
                                "id": "o3",
                                "model": "o3",
                                "displayName": "o3",
                                "description": "Reasoning model",
                                "hidden": false,
                                "supportedReasoningEfforts": [
                                    {"reasoningEffort": "medium", "description": "Balanced"},
                                    {"reasoningEffort": "high", "description": "Deep"}
                                ],
                                "defaultReasoningEffort": "medium",
                                "isDefault": true
                            }],
                            "nextCursor": null
                        })),
                    });
                }
                "thread/start" => {
                    sink.send(PeerEvent::Response {
                        id,
                        result: Ok(json!({
                            "thread": {"id": "thr-1", "turns": []},
                            "model": "o3",
                            "reasoningEffort": "medium"
                        })),
                    });
                }
                "thread/resume" => {
                    let tid = params.get("threadId").and_then(Value::as_str).unwrap_or("thr-1");
                    sink.send(PeerEvent::Response {
                        id,
                        result: Ok(json!({
                            "thread": {"id": tid, "turns": self.resumed_turns},
                            "model": "o3",
                            "reasoningEffort": "high"
                        })),
                    });
                }
                "turn/start" => {
                    let tid = params.get("threadId").and_then(Value::as_str).unwrap_or("thr-1");
                    sink.send(PeerEvent::Response { id, result: Ok(json!({"turn": {"id": "turn-1"}})) });
                    sink.send(PeerEvent::Notification {
                        method: "turn/started".into(),
                        params: json!({"threadId": tid, "turn": {"id": "turn-1"}}),
                    });
                    sink.send(PeerEvent::Notification {
                        method: "item/reasoning/summaryTextDelta".into(),
                        params: json!({"threadId": tid, "turnId": "turn-1", "itemId": "r1", "delta": "Checking files"}),
                    });
                    sink.send(PeerEvent::Notification {
                        method: "item/started".into(),
                        params: json!({
                            "threadId": tid,
                            "turnId": "turn-1",
                            "item": {"type": "commandExecution", "id": "cmd-1", "command": "cargo test", "status": "inProgress"}
                        }),
                    });
                    sink.send(PeerEvent::Notification {
                        method: "item/completed".into(),
                        params: json!({
                            "threadId": tid,
                            "turnId": "turn-1",
                            "item": {"type": "commandExecution", "id": "cmd-1", "command": "cargo test", "status": "completed", "aggregatedOutput": "ok", "exitCode": 0}
                        }),
                    });
                    sink.send(PeerEvent::Notification {
                        method: "item/agentMessage/delta".into(),
                        params: json!({"threadId": tid, "turnId": "turn-1", "itemId": "m1", "delta": "All "}),
                    });
                    sink.send(PeerEvent::Notification {
                        method: "item/agentMessage/delta".into(),
                        params: json!({"threadId": tid, "turnId": "turn-1", "itemId": "m1", "delta": "green."}),
                    });
                    sink.send(PeerEvent::Notification {
                        method: "item/completed".into(),
                        params: json!({
                            "threadId": tid,
                            "turnId": "turn-1",
                            "item": {"type": "agentMessage", "id": "m1", "text": "All green."}
                        }),
                    });
                    sink.send(PeerEvent::Notification {
                        method: "turn/completed".into(),
                        params: json!({"threadId": tid, "turn": {"id": "turn-1", "status": "completed", "error": null}}),
                    });
                }
                _ => {}
            }
            Ok(id)
        }

        fn notify(&mut self, method: &str, params: Value) {
            lock(&self.received).push((method.to_owned(), params));
        }

        fn reply(&mut self, _id: Value, _result: Result<Value, JsonRpcError>) {}
        fn terminate(&mut self) {}
        fn has_exited(&self) -> bool {
            true
        }
    }

    fn drain(session: &mut AgentChatSession) {
        for _ in 0..20 {
            if !session.wait_and_process_events(Duration::from_millis(20)) {
                break;
            }
        }
    }

    #[test]
    fn codex_peer_translates_handshake_prompt_streaming_and_tools_to_acp() {
        let received = Arc::new(Mutex::new(Vec::new()));
        let recorded = Arc::clone(&received);
        let launch = AgentChatLaunch::new(
            &DefaultAgents::codex(),
            LaunchSpec { argv: vec!["codex".into()], cwd: PathBuf::from("/work"), env: Vec::new() },
        )
        .expect("codex supports chat");
        let mut session = AgentChatSession::with_peer_factory(
            launch,
            Box::new(move |_| {
                Box::new(CodexAppServerPeer::with_inner(Box::new(FakeCodexServer::new(
                    Arc::clone(&recorded),
                    Vec::new(),
                ))))
            }),
        );

        session.start(None);
        drain(&mut session);
        assert_eq!(*session.phase(), ChatPhase::Ready);
        assert_eq!(session.session_id(), Some("thr-1"));
        assert!(session.supports_steering());
        assert_eq!(session.config_options().len(), 2);

        assert!(session.send("Run tests"));
        drain(&mut session);
        assert_eq!(*session.phase(), ChatPhase::Ready);
        let thread = session.thread();
        assert_eq!(thread.turns.len(), 1);
        let items = &thread.turns[0].items;
        assert!(
            items
                .iter()
                .any(|i| matches!(&i.kind, TurnItemKind::Reasoning { text } if text == "Checking files"))
        );
        assert!(items.iter().any(|i| matches!(&i.kind, TurnItemKind::Command(cmd) if cmd.command == "cargo test" && cmd.exit_code == Some(0))));
        assert!(
            items.iter().any(
                |i| matches!(&i.kind, TurnItemKind::AssistantMessage { text, .. } if text == "All green.")
            )
        );
        assert!(lock(&received).iter().any(|(m, _)| m == "initialized"));
    }

    #[test]
    fn codex_peer_replays_history_when_resuming_an_existing_thread() {
        let received = Arc::new(Mutex::new(Vec::new()));
        let recorded = Arc::clone(&received);
        let history = vec![json!({
            "id": "turn-0",
            "status": "completed",
            "items": [
                {"type": "userMessage", "id": "u0", "content": [{"type": "text", "text": "Hello"}]},
                {"type": "agentMessage", "id": "a0", "text": "Hi there!"}
            ]
        })];
        let launch = AgentChatLaunch::new(
            &DefaultAgents::codex(),
            LaunchSpec { argv: vec!["codex".into()], cwd: PathBuf::from("/work"), env: Vec::new() },
        )
        .expect("codex supports chat");
        let mut session = AgentChatSession::with_peer_factory(
            launch,
            Box::new(move |_| {
                Box::new(CodexAppServerPeer::with_inner(Box::new(FakeCodexServer::new(
                    Arc::clone(&recorded),
                    history.clone(),
                ))))
            }),
        );

        session.start(Some("thr-existing"));
        drain(&mut session);
        assert_eq!(session.session_id(), Some("thr-existing"));
        let thread = session.thread();
        assert_eq!(thread.turns.len(), 1);
        assert_eq!(thread.turns[0].user_message.text, "Hello");
        assert!(thread.turns[0].items.iter().any(|i| {
            matches!(&i.kind, TurnItemKind::AssistantMessage { text, .. } if text == "Hi there!")
        }));
    }
}
