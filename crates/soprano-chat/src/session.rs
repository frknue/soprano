//! One conversation with an agent over the Agent Client Protocol (`AgentChatSession.swift`).

use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::Utc;
use serde_json::{Map, Value, json};
use soprano_agents::{
    ApprovalDecision, ApprovalKind, ApprovalOption, ApprovalRequest, ChatThread, Date, JsonValueExt,
    TurnItemKind, UserInputOption, UserInputQuestion, UserInputRequest, UserMessage,
};
use soprano_types::{AgentCatalog, AgentProfile, AgentStatus, AgentWaitingReason};

use crate::rpc::{JsonRpcConnection, JsonRpcError, JsonRpcPeer, PeerEvent, PeerSink};
use crate::turn_builder::{AcpToolStyle, AcpTurnBuilder};

/// The process to run: the command line (`argv[0]` is the executable), its working directory
/// and its whole environment. `soprano-launch` builds it (the agent's ACP server run through the
/// user's login shell, like an agent pane, with `SOPRANO_*` variables of a parent pane dropped
/// and `SOPRANO_AGENT_PROFILE` / `SOPRANO_AGENT_NAME` set).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LaunchSpec {
    pub argv: Vec<String>,
    pub cwd: PathBuf,
    pub env: Vec<(String, String)>,
}

/// How a chat tab starts its agent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentChatLaunch {
    pub profile_id: String,
    pub agent_name: String,
    pub spec: LaunchSpec,
    pub tool_style: AcpToolStyle,
}

impl AgentChatLaunch {
    /// A launch of `spec` for `profile`, reading omp's tool calls its own way.
    pub fn new(profile: &AgentProfile, spec: LaunchSpec) -> Option<Self> {
        if !Self::supports(&profile.id) {
            return None;
        }
        Some(Self {
            profile_id: profile.id.clone(),
            agent_name: profile.name.clone(),
            spec,
            tool_style: if profile.id == "omp" { AcpToolStyle::Omp } else { AcpToolStyle::Generic },
        })
    }

    /// Agents a chat tab can run, by profile id: those whose CLI serves the Agent Client
    /// Protocol on stdio.
    pub fn supports(profile_id: &str) -> bool {
        profile_id == "omp"
    }

    /// The catalog's agents that open as a chat, in catalog order.
    pub fn chat_profiles() -> Vec<AgentProfile> {
        AgentCatalog::shared().all().into_iter().filter(|p| Self::supports(&p.id)).collect()
    }

    /// The working directory as the agent sees it.
    pub fn working_directory(&self) -> String {
        self.spec.cwd.to_string_lossy().into_owned()
    }

    pub fn make_connection(&self) -> JsonRpcConnection {
        JsonRpcConnection::new(
            self.spec.argv.clone(),
            Some(self.spec.cwd.clone()),
            Some(self.spec.env.clone()),
        )
    }
}

/// A tool call the agent wants to run once the person allows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentChatPermission {
    pub title: String,
    /// The full command or input when it says more than the title.
    pub detail: Option<String>,
    /// What the tool does, for the approval's heading.
    pub kind: ApprovalKind,
    pub options: Vec<ApprovalOption>,
}

impl AgentChatPermission {
    /// What is being approved: the command, else the title.
    pub fn subject(&self) -> String {
        match &self.detail {
            Some(detail) => detail.clone(),
            None => self.title.strip_prefix("$ ").unwrap_or(&self.title).to_owned(),
        }
    }

    /// Why the agent asks: its title, when the command says what runs.
    pub fn reason(&self) -> Option<String> {
        self.detail.as_ref().map(|_| self.title.clone())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QuestionChoice {
    pub label: String,
    pub detail: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QuestionField {
    pub key: String,
    pub title: String,
    pub detail: Option<String>,
    pub choices: Vec<QuestionChoice>,
    pub allows_multiple: bool,
    /// The key a typed answer goes under, when the field takes one.
    pub other_key: Option<String>,
    pub recommended: Option<String>,
}

/// Questions the agent asks, as an ACP form elicitation: one or more fields, each a choice
/// among labels and, where offered, an answer of one's own.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentChatQuestion {
    pub message: String,
    pub fields: Vec<QuestionField>,
}

impl AgentChatQuestion {
    /// Parses `requestedSchema` from `elicitation/create`. `None` for a form with nothing a
    /// person could answer.
    pub fn new(message: &str, schema: &Value) -> Option<Self> {
        let properties = schema.get("properties")?.as_object()?;
        let mut keys: Vec<&String> = properties.keys().filter(|k| !k.ends_with("__other")).collect();
        keys.sort_by(|a, b| numeric_order(a, b));
        let mut fields = Vec::new();
        for key in keys {
            let property = &properties[key.as_str()];
            let is_array = property.get("type").and_then(Value::as_str) == Some("array");
            let options = if is_array {
                property.get("items").and_then(|i| i.get("anyOf")).and_then(Value::as_array)
            } else {
                property.get("oneOf").and_then(Value::as_array)
            };
            let choices: Vec<QuestionChoice> = options
                .map(|options| {
                    options
                        .iter()
                        .filter_map(|option| {
                            let label = option
                                .get("const")
                                .and_then(Value::as_str)
                                .or_else(|| option.get("title").and_then(Value::as_str))?;
                            Some(QuestionChoice {
                                label: label.to_owned(),
                                detail: option
                                    .get("description")
                                    .and_then(Value::non_empty_string)
                                    .map(str::to_owned),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            let other = format!("{key}__other");
            let other_key = properties.contains_key(&other).then_some(other);
            if choices.is_empty()
                && other_key.is_none()
                && property.get("type").and_then(Value::as_str) != Some("string")
            {
                continue;
            }
            let other_key = other_key.or_else(|| choices.is_empty().then(|| key.clone()));
            fields.push(QuestionField {
                key: key.clone(),
                title: property.get("title").and_then(Value::non_empty_string).unwrap_or(message).to_owned(),
                detail: property.get("description").and_then(Value::non_empty_string).map(str::to_owned),
                choices,
                allows_multiple: is_array,
                other_key,
                recommended: property.get("default").and_then(Value::as_str).map(str::to_owned),
            });
        }
        if fields.is_empty() {
            return None;
        }
        Some(Self { message: message.to_owned(), fields })
    }

    /// The questions as the composer asks them: the field's description as the header chip,
    /// its title as the question.
    pub fn user_input_request(&self, id: &str) -> UserInputRequest {
        UserInputRequest {
            id: id.to_owned(),
            questions: self
                .fields
                .iter()
                .map(|field| UserInputQuestion {
                    id: field.key.clone(),
                    header: field.detail.clone().unwrap_or_default(),
                    question: field.title.clone(),
                    options: field
                        .choices
                        .iter()
                        .map(|c| UserInputOption { label: c.label.clone(), description: c.detail.clone() })
                        .collect(),
                    allows_multiple: field.allows_multiple,
                    allows_other: field.other_key.is_some(),
                })
                .collect(),
            answers: None,
            dismissed: false,
        }
    }

    /// The form's content for answers by question id ([`user_input_request`]): chosen labels,
    /// or a typed answer under the field's `other_key`.
    ///
    /// [`user_input_request`]: Self::user_input_request
    pub fn content(&self, answers: &BTreeMap<String, Vec<String>>) -> Map<String, Value> {
        let mut content = Map::new();
        for field in &self.fields {
            let values = answers.get(&field.key).cloned().unwrap_or_default();
            let is_label = |value: &str| field.choices.iter().any(|c| c.label == value);
            if let Some(other_key) = &field.other_key
                && values.len() == 1
                && !is_label(&values[0])
            {
                if *other_key != field.key && field.allows_multiple {
                    content.insert(field.key.clone(), Value::Array(Vec::new()));
                }
                content.insert(other_key.clone(), Value::String(values[0].clone()));
            } else if field.allows_multiple {
                content
                    .insert(field.key.clone(), Value::Array(values.into_iter().map(Value::String).collect()));
            } else if let Some(value) = values.into_iter().next() {
                content.insert(field.key.clone(), Value::String(value));
            }
        }
        content
    }

    /// What the content answers, by question id, as the timeline shows it.
    pub fn answers(&self, content: &Map<String, Value>) -> BTreeMap<String, Vec<String>> {
        let mut answers = BTreeMap::new();
        for field in &self.fields {
            if let Some(typed) =
                field.other_key.as_ref().and_then(|k| content.get(k)).and_then(Value::non_empty_string)
            {
                answers.insert(field.key.clone(), vec![typed.to_owned()]);
            } else if let Some(value) = content.get(&field.key).and_then(Value::as_str) {
                answers.insert(field.key.clone(), vec![value.to_owned()]);
            } else if let Some(values) = content.get(&field.key).and_then(Value::as_array) {
                answers.insert(
                    field.key.clone(),
                    values.iter().filter_map(Value::as_str).map(str::to_owned).collect(),
                );
            }
        }
        answers
    }
}

/// `q0`, `q1`, …, `q10` in numeric order rather than by string (Foundation's `.numeric`).
fn numeric_order(a: &str, b: &str) -> std::cmp::Ordering {
    let mut a = a.chars().peekable();
    let mut b = b.chars().peekable();
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (None, None) => return std::cmp::Ordering::Equal,
            (None, Some(_)) => return std::cmp::Ordering::Less,
            (Some(_), None) => return std::cmp::Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let mut left = String::new();
                while let Some(c) = a.peek().copied().filter(char::is_ascii_digit) {
                    left.push(c);
                    a.next();
                }
                let mut right = String::new();
                while let Some(c) = b.peek().copied().filter(char::is_ascii_digit) {
                    right.push(c);
                    b.next();
                }
                let left = left.trim_start_matches('0');
                let right = right.trim_start_matches('0');
                let order = left.len().cmp(&right.len()).then_with(|| left.cmp(right));
                if order != std::cmp::Ordering::Equal {
                    return order;
                }
            }
            (Some(x), Some(y)) => {
                if x != y {
                    return x.cmp(&y);
                }
                a.next();
                b.next();
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConfigOptionValue {
    pub value: String,
    pub name: String,
    /// What the value means ("Auto-detect per prompt"; a model's `provider/id`).
    pub detail: Option<String>,
}

/// One of the session settings the agent offers, such as the model, the thinking level or the
/// mode.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentChatConfigOption {
    pub id: String,
    pub name: String,
    pub category: Option<String>,
    pub current_value: String,
    pub values: Vec<ConfigOptionValue>,
}

impl AgentChatConfigOption {
    pub fn current_name(&self) -> &str {
        self.values.iter().find(|v| v.value == self.current_value).map_or(&self.current_value, |v| &v.name)
    }

    pub fn parse(list: Option<&Value>) -> Vec<Self> {
        let Some(list) = list.and_then(Value::as_array) else { return Vec::new() };
        list.iter()
            .filter_map(|option| {
                if option.get("type").and_then(Value::as_str) != Some("select") {
                    return None;
                }
                let id = option.get("id").and_then(Value::as_str)?;
                let current = option.get("currentValue").and_then(Value::as_str)?;
                let values = option
                    .get("options")
                    .and_then(Value::as_array)
                    .map(|values| {
                        values
                            .iter()
                            .filter_map(|value| {
                                let raw = value.get("value").and_then(Value::as_str)?;
                                Some(ConfigOptionValue {
                                    value: raw.to_owned(),
                                    name: value
                                        .get("name")
                                        .and_then(Value::non_empty_string)
                                        .unwrap_or(raw)
                                        .to_owned(),
                                    detail: value
                                        .get("description")
                                        .and_then(Value::non_empty_string)
                                        .map(str::to_owned),
                                })
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                Some(Self {
                    id: id.to_owned(),
                    name: option.get("name").and_then(Value::as_str).unwrap_or(id).to_owned(),
                    category: option.get("category").and_then(Value::as_str).map(str::to_owned),
                    current_value: current.to_owned(),
                    values,
                })
            })
            .collect()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlanEntryStatus {
    Pending,
    InProgress,
    Completed,
}

/// One step of the plan the agent keeps for the current task.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentChatPlanEntry {
    pub content: String,
    pub status: PlanEntryStatus,
}

/// A `/` command the agent offers (`available_commands_update`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentChatCommand {
    pub name: String,
    pub description: Option<String>,
    /// What the command takes after its name.
    pub hint: Option<String>,
}

impl AgentChatCommand {
    /// What choosing it types: the command and a space for its input.
    pub fn insert_text(&self) -> String {
        format!("/{} ", self.name)
    }

    pub fn parse(list: Option<&Value>) -> Vec<Self> {
        let Some(list) = list.and_then(Value::as_array) else { return Vec::new() };
        list.iter()
            .filter_map(|command| {
                let name = command.get("name").and_then(Value::non_empty_string)?;
                Some(Self {
                    name: name.strip_prefix('/').unwrap_or(name).to_owned(),
                    description: command
                        .get("description")
                        .and_then(Value::non_empty_string)
                        .map(str::to_owned),
                    hint: command
                        .get("input")
                        .and_then(|i| i.get("hint"))
                        .and_then(Value::non_empty_string)
                        .map(str::to_owned),
                })
            })
            .collect()
    }
}

/// What the session tells the tab that hosts it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AgentChatEvent {
    /// The status the sidebar, headers and dashboard show. `notify` asks for attention unless
    /// the person is looking at the chat.
    Status {
        status: AgentStatus,
        waiting_reason: Option<AgentWaitingReason>,
        notify: bool,
        message: Option<String>,
    },
    /// The agent's id for this conversation, for resuming it after a restart.
    Conversation {
        id: String,
        cwd: String,
    },
    Title(String),
}

impl AgentChatEvent {
    pub fn status(status: AgentStatus) -> Self {
        Self::Status { status, waiting_reason: None, notify: false, message: None }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChatPhase {
    Starting,
    Ready,
    Working,
    /// The agent's process ended; the text explains an unexpected end.
    Stopped(Option<String>),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChatInteraction {
    Permission(AgentChatPermission),
    Question(AgentChatQuestion),
}

/// What a request this session sent is for.
#[derive(Clone, Debug)]
enum Pending {
    Initialize { resuming: Option<String> },
    Load { conversation_id: String },
    New,
    Prompt,
    Steering,
    SetConfig { id: String },
}

type MakePeer = Box<dyn FnMut(&AgentChatLaunch) -> Box<dyn JsonRpcPeer>>;
type EventCallback = Box<dyn FnMut(&AgentChatEvent)>;
type Waker = crate::rpc::WakerSlot;

/// One conversation with an agent over the Agent Client Protocol: starts its server, opens or
/// reloads the session, sends prompts, and keeps what the chat tab shows — the turns, what the
/// agent is waiting on, the plan, the commands and the settings it offers.
///
/// The session lives on its owner's thread (the UI's). Its agent's messages queue up on a
/// channel; the waker set with [`set_waker`](Self::set_waker) runs (on a background thread)
/// whenever one arrives, and the owner then calls [`process_events`](Self::process_events),
/// which applies them and calls `on_change` / `on_event`. The Swift session did the same on the
/// main actor with `async` requests.
pub struct AgentChatSession {
    pub launch: AgentChatLaunch,
    phase: ChatPhase,
    builder: AcpTurnBuilder,
    interaction: Option<ChatInteraction>,
    config_options: Vec<AgentChatConfigOption>,
    plan: Vec<AgentChatPlanEntry>,
    /// Messages waiting for the running turn, oldest first.
    queue: Vec<UserMessage>,
    /// The `/` commands the agent offers.
    commands: Vec<AgentChatCommand>,
    /// Context tokens in use and the window's size, after the last turn.
    context_usage: Option<(i64, i64)>,
    session_id: Option<String>,
    supports_steering: bool,
    turn_started_at: Option<Date>,

    on_change: Option<Box<dyn FnMut()>>,
    on_event: Option<EventCallback>,

    make_peer: MakePeer,
    peer: Option<(u64, Box<dyn JsonRpcPeer>)>,
    /// Processes this session ended that have not exited yet.
    retiring: HashMap<u64, Box<dyn JsonRpcPeer>>,
    /// A start waiting for retiring processes to exit: the conversation to open.
    pending_start: Option<Option<String>>,
    pending: HashMap<(u64, u64), Pending>,
    /// The agent's request on screen: which peer asked, and its request id.
    interaction_reply: Option<(u64, Value)>,
    /// The turn item of the approval or question on screen.
    interaction_item_id: Option<String>,
    next_local_id: u64,
    next_peer_id: u64,

    events: Receiver<(u64, PeerEvent)>,
    sender: Sender<(u64, PeerEvent)>,
    waker: Waker,
}

impl AgentChatSession {
    /// A session that runs `launch` as a real process.
    pub fn new(launch: AgentChatLaunch) -> Self {
        Self::with_peer_factory(
            launch,
            Box::new(|launch: &AgentChatLaunch| Box::new(launch.make_connection()) as Box<dyn JsonRpcPeer>),
        )
    }

    /// A session whose agent `make_peer` provides (tests stand in a fake agent).
    pub fn with_peer_factory(launch: AgentChatLaunch, make_peer: MakePeer) -> Self {
        let builder = AcpTurnBuilder::new(Some(launch.working_directory()), launch.tool_style);
        let (sender, events) = mpsc::channel();
        Self {
            launch,
            // Stopped until `start`, which a tab stopped before a relaunch skips.
            phase: ChatPhase::Stopped(None),
            builder,
            interaction: None,
            config_options: Vec::new(),
            plan: Vec::new(),
            queue: Vec::new(),
            commands: Vec::new(),
            context_usage: None,
            session_id: None,
            supports_steering: false,
            turn_started_at: None,
            on_change: None,
            on_event: None,
            make_peer,
            peer: None,
            retiring: HashMap::new(),
            pending_start: None,
            pending: HashMap::new(),
            interaction_reply: None,
            interaction_item_id: None,
            next_local_id: 1,
            next_peer_id: 1,
            events,
            sender,
            waker: Arc::new(Mutex::new(None)),
        }
    }

    /// Called whenever the view should re-read the session.
    pub fn set_on_change(&mut self, callback: impl FnMut() + 'static) {
        self.on_change = Some(Box::new(callback));
    }

    pub fn set_on_event(&mut self, callback: impl FnMut(&AgentChatEvent) + 'static) {
        self.on_event = Some(Box::new(callback));
    }

    /// Runs on a background thread whenever the agent said something; the owner then calls
    /// [`process_events`](Self::process_events) on its own thread.
    pub fn set_waker(&mut self, waker: impl Fn() + Send + Sync + 'static) {
        if let Ok(mut slot) = self.waker.lock() {
            *slot = Some(Arc::new(waker));
        }
    }

    // MARK: - State

    pub fn phase(&self) -> &ChatPhase {
        &self.phase
    }

    pub fn builder(&self) -> &AcpTurnBuilder {
        &self.builder
    }

    pub fn interaction(&self) -> Option<&ChatInteraction> {
        self.interaction.as_ref()
    }

    pub fn config_options(&self) -> &[AgentChatConfigOption] {
        &self.config_options
    }

    pub fn plan(&self) -> &[AgentChatPlanEntry] {
        &self.plan
    }

    pub fn commands(&self) -> &[AgentChatCommand] {
        &self.commands
    }

    /// Context tokens in use and the window's size, after the last turn.
    pub fn context_usage(&self) -> Option<(i64, i64)> {
        self.context_usage
    }

    pub fn session_id(&self) -> Option<&str> {
        self.session_id.as_deref()
    }

    pub fn supports_steering(&self) -> bool {
        self.supports_steering
    }

    pub fn turn_started_at(&self) -> Option<Date> {
        self.turn_started_at
    }

    /// The conversation as the chat shows it, queued messages included.
    pub fn thread(&self) -> ChatThread {
        let mut thread = self.builder.thread().clone();
        thread.queue.clone_from(&self.queue);
        thread
    }

    pub fn queued_prompts(&self) -> Vec<String> {
        self.queue.iter().map(|m| m.text.clone()).collect()
    }

    /// The agent offers `/compact` and nothing runs: the context can be compacted.
    pub fn can_compact(&self) -> bool {
        self.phase == ChatPhase::Ready
            && self.interaction.is_none()
            && self.commands.iter().any(|c| c.name == "compact")
    }

    pub fn is_running(&self) -> bool {
        !matches!(self.phase, ChatPhase::Stopped(_))
    }

    // MARK: - Events

    /// Applies everything the agent said since the last call. Returns whether anything arrived.
    pub fn process_events(&mut self) -> bool {
        let mut any = false;
        while let Ok((peer_id, event)) = self.events.try_recv() {
            any = true;
            self.handle(peer_id, event);
        }
        any
    }

    /// Waits up to `timeout` for the agent to say something, then applies it and whatever else
    /// arrived. Returns whether anything arrived.
    pub fn wait_and_process_events(&mut self, timeout: Duration) -> bool {
        match self.events.recv_timeout(timeout) {
            Ok((peer_id, event)) => {
                self.handle(peer_id, event);
                self.process_events();
                true
            }
            Err(_) => false,
        }
    }

    fn handle(&mut self, peer_id: u64, event: PeerEvent) {
        let current = self.peer.as_ref().is_some_and(|(id, _)| *id == peer_id);
        match event {
            PeerEvent::Exit { status, stderr } => {
                if self.retiring.remove(&peer_id).is_some() {
                    self.launch_if_retired();
                } else if current {
                    self.did_exit(status, &stderr);
                }
            }
            PeerEvent::Response { id, result } => {
                let Some(pending) = self.pending.remove(&(peer_id, id)) else { return };
                if current {
                    self.handle_response(pending, result);
                }
            }
            PeerEvent::Notification { method, params } => {
                if current {
                    self.handle_notification(&method, &params);
                }
            }
            PeerEvent::Request { id, method, params } => {
                if current {
                    self.handle_request(peer_id, id, &method, &params);
                } else if let Some(peer) = self.retiring.get_mut(&peer_id) {
                    peer.reply(id, Err(JsonRpcError::new(JsonRpcError::INTERNAL_ERROR, "Session closed")));
                }
            }
        }
    }

    // MARK: - Lifecycle

    /// Starts the agent and opens `conversation_id` when given, else a new conversation. Waits
    /// first for every process this session ended to exit: one may still hold the
    /// conversation, and a load it blocks would open a new one instead.
    pub fn start(&mut self, resuming: Option<&str>) {
        self.phase = ChatPhase::Starting;
        self.report(AgentChatEvent::status(AgentStatus::Starting));
        self.changed();
        // A start while an agent still runs replaces it: that process is asked to end and
        // retired, so its requests get "Session closed" and the new one waits for it to exit.
        if let Some((peer_id, mut peer)) = self.peer.take() {
            peer.terminate();
            self.pending.retain(|(id, _), _| *id != peer_id);
            if !peer.has_exited() {
                self.retiring.insert(peer_id, peer);
            }
        }
        self.retiring.retain(|_, peer| !peer.has_exited());
        // A stop or another start while waiting wins.
        self.pending_start = Some(resuming.map(str::to_owned));
        self.launch_if_retired();
    }

    fn launch_if_retired(&mut self) {
        if !self.retiring.is_empty() {
            return;
        }
        if let Some(resuming) = self.pending_start.take() {
            self.launch_peer(resuming);
        }
    }

    fn launch_peer(&mut self, resuming: Option<String>) {
        let peer_id = self.next_peer_id;
        self.next_peer_id += 1;
        let mut peer = (self.make_peer)(&self.launch);
        // The sink reads the session's waker slot on every delivery, so a waker set later is used.
        let started = peer.start(PeerSink::with_waker(peer_id, self.sender.clone(), Arc::clone(&self.waker)));
        self.peer = Some((peer_id, peer));
        if let Err(error) = started {
            self.did_exit(-1, &error.to_string());
            return;
        }
        let params = json!({
            "protocolVersion": 1,
            "clientCapabilities": {
                "fs": {"readTextFile": false, "writeTextFile": false},
                "terminal": false,
                // Lets the agent ask questions (omp's `ask` tool) and have a plan approved
                // instead of auto-approving it.
                "elicitation": {"form": {}},
            },
            "clientInfo": {"name": "soprano", "title": "Soprano", "version": soprano_platform::identity::app_version()},
        });
        self.send_request("initialize", params, Pending::Initialize { resuming });
    }

    /// Ends the agent's process. The conversation stays on disk.
    pub fn stop(&mut self) {
        self.shutdown();
        self.report(AgentChatEvent::status(AgentStatus::Stopped));
        self.changed();
    }

    /// Starts the agent again on the same conversation, or on `fallback` when this session
    /// never opened one. Reports no stop in between: the tab is already starting.
    pub fn restart(&mut self, fallback: Option<&str>) {
        let conversation_id = self.session_id.clone().or_else(|| fallback.map(str::to_owned));
        self.shutdown();
        self.builder = AcpTurnBuilder::new(Some(self.launch.working_directory()), self.launch.tool_style);
        self.plan.clear();
        self.commands.clear();
        self.context_usage = None;
        self.start(conversation_id.as_deref());
    }

    /// Ends the process and whatever it was doing; later messages from it are ignored. An
    /// unanswered request dies with the process, which the next `start` waits for.
    fn shutdown(&mut self) {
        self.pending_start = None;
        if let Some((peer_id, mut peer)) = self.peer.take() {
            peer.terminate();
            // Keeps the peer until its process is gone, across any number of stops and restarts.
            if !peer.has_exited() {
                self.retiring.insert(peer_id, peer);
            }
        }
        self.interaction = None;
        self.interaction_reply = None;
        self.interaction_item_id = None;
        if self.turn_started_at.take().is_some() {
            self.builder.finish_turn(Some("cancelled"), None, now());
        }
        self.phase = ChatPhase::Stopped(None);
    }

    fn handle_response(&mut self, pending: Pending, result: Result<Value, JsonRpcError>) {
        match pending {
            Pending::Initialize { resuming } => match result {
                Ok(initialized) => {
                    self.supports_steering = initialized
                        .get("_meta")
                        .and_then(|m| m.get("steering"))
                        .and_then(|s| s.get("supported"))
                        .and_then(Value::as_bool)
                        == Some(true);
                    let can_load = initialized
                        .get("agentCapabilities")
                        .and_then(|c| c.get("loadSession"))
                        .and_then(Value::as_bool)
                        == Some(true);
                    match resuming.filter(|_| can_load) {
                        Some(conversation_id) => {
                            self.builder.set_replaying(true);
                            let params = json!({"sessionId": conversation_id, "cwd": self.launch.working_directory(), "mcpServers": []});
                            self.send_request("session/load", params, Pending::Load { conversation_id });
                        }
                        None => self.request_new_session(),
                    }
                }
                Err(error) => self.open_failed(&error),
            },
            Pending::Load { conversation_id } => match result {
                Ok(opened) => {
                    self.session_id = Some(conversation_id);
                    self.builder.set_replaying(false);
                    self.finish_open(&opened);
                }
                Err(error) if error.is_closed() => self.builder.set_replaying(false),
                Err(error) => {
                    self.builder.add_notice(
                        &format!("Could not reopen the conversation: {}", error.message),
                        true,
                        None,
                    );
                    self.builder.set_replaying(false);
                    self.request_new_session();
                }
            },
            Pending::New => match result {
                Ok(created) => match created.get("sessionId").and_then(Value::as_str) {
                    Some(id) => {
                        self.session_id = Some(id.to_owned());
                        self.finish_open(&created);
                    }
                    None => self.open_failed(&JsonRpcError::new(
                        JsonRpcError::INTERNAL_ERROR,
                        "The agent returned no session.",
                    )),
                },
                Err(error) => self.open_failed(&error),
            },
            Pending::Prompt => self.finish_turn(result),
            Pending::Steering => {
                if let Err(error) = result
                    && !error.is_closed()
                {
                    self.builder.add_notice(
                        &format!("Could not steer the agent: {}", error.message),
                        true,
                        None,
                    );
                    self.changed();
                }
            }
            Pending::SetConfig { id } => match result {
                Ok(result) => {
                    let options = AgentChatConfigOption::parse(result.get("configOptions"));
                    if !options.is_empty() {
                        self.config_options = options;
                    }
                    self.changed();
                }
                Err(error) if error.is_closed() => {}
                Err(error) => {
                    self.builder.add_notice(&format!("Could not change {id}: {}", error.message), true, None);
                    self.changed();
                }
            },
        }
    }

    fn request_new_session(&mut self) {
        let params = json!({"cwd": self.launch.working_directory(), "mcpServers": []});
        self.send_request("session/new", params, Pending::New);
    }

    fn finish_open(&mut self, opened: &Value) {
        self.config_options = AgentChatConfigOption::parse(opened.get("configOptions"));
        if let Some(id) = self.session_id.clone() {
            self.report(AgentChatEvent::Conversation { id, cwd: self.launch.working_directory() });
        }
        self.phase = ChatPhase::Ready;
        self.report(AgentChatEvent::status(AgentStatus::Idle));
        self.changed();
        self.send_next_queued_prompt();
    }

    fn open_failed(&mut self, error: &JsonRpcError) {
        if error.is_closed() {
            return;
        }
        self.builder.set_replaying(false);
        self.builder.add_notice(
            &format!("The agent could not start a conversation: {}", error.message),
            true,
            None,
        );
        if let Some((_, peer)) = self.peer.as_mut() {
            peer.terminate();
        }
    }

    fn did_exit(&mut self, status: i32, stderr: &str) {
        // The process is gone: nothing to wait for.
        if let Some((peer_id, _)) = &self.peer {
            let peer_id = *peer_id;
            self.pending.retain(|(id, _), _| *id != peer_id);
        }
        self.peer = None;
        self.shutdown();
        let reason = if status == 0 {
            "The agent exited.".to_owned()
        } else {
            let lines: Vec<&str> = stderr.split('\n').filter(|l| !l.is_empty()).collect();
            let last_lines = lines[lines.len().saturating_sub(6)..].join("\n");
            if last_lines.is_empty() {
                format!("The agent exited with status {status}.")
            } else {
                format!("The agent exited with status {status}:\n{last_lines}")
            }
        };
        self.builder.add_notice(&reason, status != 0, Some(now()));
        self.phase = ChatPhase::Stopped(if status == 0 { None } else { Some(reason.clone()) });
        self.report(AgentChatEvent::Status {
            status: if status == 0 { AgentStatus::Stopped } else { AgentStatus::Error },
            waiting_reason: None,
            notify: status != 0,
            message: Some(reason),
        });
        self.changed();
    }

    // MARK: - Prompts

    /// Sends `text`, or queues it while a turn runs; it goes out when the turn ends. False when
    /// the agent is not running.
    pub fn send(&mut self, text: &str) -> bool {
        let text = text.trim();
        if text.is_empty() || !self.is_running() {
            return false;
        }
        if self.phase != ChatPhase::Ready || self.interaction.is_some() {
            let id = self.local_id("queued");
            self.queue.push(UserMessage::new(id, text, Some(now())));
            self.changed();
            return true;
        }
        self.prompt(text);
        true
    }

    /// Sends `text` into the running turn, which the agent reads before its next step. Falls
    /// back to [`send`](Self::send) when nothing runs or the agent cannot be steered.
    pub fn steer(&mut self, text: &str) -> bool {
        let text = text.trim();
        if text.is_empty() || !self.is_running() {
            return false;
        }
        let Some(session_id) = self
            .session_id
            .clone()
            .filter(|_| self.phase == ChatPhase::Working && self.supports_steering && self.peer.is_some())
        else {
            return self.send(text);
        };
        self.builder.add_steer(text, now());
        self.changed();
        let params = json!({"sessionId": session_id, "prompt": [{"type": "text", "text": text}]});
        self.send_request("_session/steering", params, Pending::Steering);
        true
    }

    /// Drops a queued prompt before it is sent.
    pub fn remove_queued_prompt_at(&mut self, index: usize) {
        if index < self.queue.len() {
            self.queue.remove(index);
            self.changed();
        }
    }

    pub fn remove_queued_prompt(&mut self, id: &str) {
        if let Some(index) = self.queue.iter().position(|m| m.id == id) {
            self.remove_queued_prompt_at(index);
        }
    }

    /// Steers a queued prompt into the running turn instead of waiting.
    pub fn send_queued_prompt_now(&mut self, id: &str) {
        if self.phase != ChatPhase::Working || !self.supports_steering {
            return;
        }
        let Some(index) = self.queue.iter().position(|m| m.id == id) else { return };
        let message = self.queue.remove(index);
        self.steer(&message.text);
    }

    /// Stops the running turn. Queued prompts stay queued and go out after the next turn the
    /// person starts, not right after the stop.
    pub fn cancel(&mut self) {
        if self.phase != ChatPhase::Working || self.peer.is_none() {
            return;
        }
        let Some(session_id) = self.session_id.clone() else { return };
        self.fail_interaction();
        self.builder.mark_stop_requested(now());
        self.changed();
        if let Some((_, peer)) = self.peer.as_mut() {
            peer.notify("session/cancel", json!({"sessionId": session_id}));
        }
    }

    /// Asks the agent to summarize the conversation so far (its `/compact`).
    pub fn compact(&mut self) {
        if self.can_compact() {
            self.prompt("/compact");
        }
    }

    fn prompt(&mut self, text: &str) {
        if self.peer.is_none() {
            return;
        }
        let Some(session_id) = self.session_id.clone() else { return };
        let started = now();
        self.builder.add_prompt(text, started);
        self.phase = ChatPhase::Working;
        self.turn_started_at = Some(started);
        self.report(AgentChatEvent::status(AgentStatus::Running));
        self.changed();
        let params = json!({"sessionId": session_id, "prompt": [{"type": "text", "text": text}]});
        self.send_request("session/prompt", params, Pending::Prompt);
    }

    fn finish_turn(&mut self, outcome: Result<Value, JsonRpcError>) {
        // An exit already ended the turn and said why.
        if outcome.as_ref().is_err_and(JsonRpcError::is_closed) {
            return;
        }
        self.fail_interaction();
        self.turn_started_at = None;
        self.phase = ChatPhase::Ready;
        // A stop holds the queue: sending it now would undo the stop.
        let mut sends_queue = true;
        match outcome {
            Ok(result) => {
                let stop_reason = result.get("stopReason").and_then(Value::as_str);
                self.builder.finish_turn(stop_reason, None, now());
                if stop_reason == Some("cancelled") {
                    sends_queue = false;
                    self.report(AgentChatEvent::status(AgentStatus::Idle));
                } else {
                    let message = self.last_reply();
                    self.report(AgentChatEvent::Status {
                        status: AgentStatus::Waiting,
                        waiting_reason: Some(AgentWaitingReason::TurnEnded),
                        notify: true,
                        message,
                    });
                }
            }
            Err(error) => {
                self.builder.finish_turn(None, Some(&error.message), now());
                self.report(AgentChatEvent::Status {
                    status: AgentStatus::Error,
                    waiting_reason: None,
                    notify: true,
                    message: Some(error.message),
                });
            }
        }
        self.changed();
        if sends_queue {
            self.send_next_queued_prompt();
        }
    }

    fn send_next_queued_prompt(&mut self) {
        if self.phase != ChatPhase::Ready || self.interaction.is_some() || self.queue.is_empty() {
            return;
        }
        let message = self.queue.remove(0);
        self.prompt(&message.text);
    }

    /// The last turn's answer, for the notification.
    fn last_reply(&self) -> Option<String> {
        self.builder.thread().turns.last()?.items.iter().rev().find_map(|item| match &item.kind {
            TurnItemKind::AssistantMessage { text, .. } => Some(text.chars().take(4_096).collect()),
            _ => None,
        })
    }

    fn local_id(&mut self, prefix: &str) -> String {
        let id = format!("{prefix}-{}", self.next_local_id);
        self.next_local_id += 1;
        id
    }

    fn send_request(&mut self, method: &str, params: Value, purpose: Pending) {
        let Some((peer_id, peer)) = self.peer.as_mut() else { return };
        let peer_id = *peer_id;
        match peer.request(method, params) {
            Ok(id) => {
                self.pending.insert((peer_id, id), purpose);
            }
            Err(error) => self.handle_response(purpose, Err(error)),
        }
    }

    // MARK: - Settings

    /// Changes one of the agent's session settings, such as the model, thinking level or mode.
    pub fn set_config_option(&mut self, id: &str, value: &str) {
        if self.peer.is_none() {
            return;
        }
        let Some(session_id) = self.session_id.clone() else { return };
        let Some(option) = self.config_options.iter().find(|o| o.id == id) else { return };
        if option.current_value == value {
            return;
        }
        let params = json!({"sessionId": session_id, "configId": id, "value": value});
        self.send_request("session/set_config_option", params, Pending::SetConfig { id: id.to_owned() });
    }

    // MARK: - Interactions

    /// Answers a permission request with one of its options.
    pub fn choose_permission_option(&mut self, option_id: &str) {
        let Some(ChatInteraction::Permission(permission)) = &self.interaction else { return };
        let Some(option) = permission.options.iter().find(|o| o.id == option_id) else { return };
        let decision = ApprovalDecision::of_option_kind(&option.kind);
        if let Some(id) = self.interaction_item_id.clone() {
            self.builder.resolve_approval(&id, decision, now());
        }
        self.resolve_interaction(Ok(json!({"outcome": {"outcome": "selected", "optionId": option_id}})));
    }

    /// Answers a question form: per field key, the chosen labels or the typed answer under its
    /// `other_key`.
    pub fn answer_question(&mut self, content: Map<String, Value>) {
        let Some(ChatInteraction::Question(question)) = &self.interaction else { return };
        let answers = question.answers(&content);
        if let Some(id) = self.interaction_item_id.clone() {
            self.builder.resolve_user_input(&id, Some(answers), now());
        }
        self.resolve_interaction(Ok(json!({"action": "accept", "content": Value::Object(content)})));
    }

    pub fn decline_question(&mut self) {
        if !matches!(self.interaction, Some(ChatInteraction::Question(_))) {
            return;
        }
        if let Some(id) = self.interaction_item_id.clone() {
            self.builder.resolve_user_input(&id, None, now());
        }
        self.resolve_interaction(Ok(json!({"action": "decline"})));
    }

    fn resolve_interaction(&mut self, result: Result<Value, JsonRpcError>) {
        let reply = self.interaction_reply.take();
        self.interaction = None;
        self.interaction_item_id = None;
        if let Some((peer_id, id)) = reply {
            self.reply_to(peer_id, id, result);
        }
        if self.phase == ChatPhase::Working {
            self.report(AgentChatEvent::status(AgentStatus::Running));
        }
        self.changed();
    }

    /// Withdraws a pending request when its turn ends or the agent leaves.
    fn fail_interaction(&mut self) {
        let Some(interaction) = &self.interaction else { return };
        let is_permission = matches!(interaction, ChatInteraction::Permission(_));
        self.withdraw_interaction_item();
        if is_permission {
            self.resolve_interaction(Ok(json!({"outcome": {"outcome": "cancelled"}})));
        } else {
            self.resolve_interaction(Ok(json!({"action": "cancel"})));
        }
    }

    /// The request on screen went unanswered: its turn item says so.
    fn withdraw_interaction_item(&mut self) {
        let (Some(id), Some(interaction)) = (self.interaction_item_id.clone(), &self.interaction) else {
            return;
        };
        match interaction {
            ChatInteraction::Permission(_) => {
                self.builder.resolve_approval(&id, ApprovalDecision::Cancel, now())
            }
            ChatInteraction::Question(_) => self.builder.resolve_user_input(&id, None, now()),
        }
    }

    fn reply_to(&mut self, peer_id: u64, id: Value, result: Result<Value, JsonRpcError>) {
        match self.peer.as_mut() {
            Some((current, peer)) if *current == peer_id => peer.reply(id, result),
            _ => {
                if let Some(peer) = self.retiring.get_mut(&peer_id) {
                    peer.reply(id, result);
                }
            }
        }
    }

    // MARK: - Messages from the agent

    fn handle_notification(&mut self, method: &str, params: &Value) {
        match method {
            "session/update" => {
                let matches_session = self.session_id.is_none()
                    || params.get("sessionId").and_then(Value::as_str) == self.session_id.as_deref();
                if let Some(update) = params.get("update").filter(|_| matches_session) {
                    self.apply(update);
                }
            }
            "_omp/compaction/start" => {
                self.builder.add_notice("Compacting context…", false, Some(now()));
                self.changed();
            }
            "_omp/compaction/end" => {
                if let Some(message) = params.get("errorMessage").and_then(Value::non_empty_string) {
                    self.builder.add_notice(
                        &format!("Context compaction failed: {message}"),
                        true,
                        Some(now()),
                    );
                } else if params.get("aborted").and_then(Value::as_bool) != Some(true)
                    && params.get("skipped").and_then(Value::as_bool) != Some(true)
                {
                    self.builder.add_notice("Context compacted", false, Some(now()));
                }
                self.changed();
            }
            "$/cancel_request" => {
                // The agent withdrew the question it asked, e.g. after steering.
                self.withdraw_interaction_item();
                self.interaction_reply = None;
                self.interaction = None;
                self.interaction_item_id = None;
                self.changed();
            }
            _ => {}
        }
    }

    fn apply(&mut self, update: &Value) {
        match update.get("sessionUpdate").and_then(Value::as_str) {
            Some("plan") => {
                self.plan = update
                    .get("entries")
                    .and_then(Value::as_array)
                    .map(|entries| {
                        entries
                            .iter()
                            .filter_map(|entry| {
                                let content = entry.get("content").and_then(Value::non_empty_string)?;
                                let status = match entry.get("status").and_then(Value::as_str) {
                                    Some("completed") => PlanEntryStatus::Completed,
                                    Some("in_progress") => PlanEntryStatus::InProgress,
                                    _ => PlanEntryStatus::Pending,
                                };
                                Some(AgentChatPlanEntry { content: content.to_owned(), status })
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                self.changed();
            }
            Some("config_option_update") => {
                let options = AgentChatConfigOption::parse(update.get("configOptions"));
                if !options.is_empty() {
                    self.config_options = options;
                    self.changed();
                }
            }
            Some("current_mode_update") => {
                if let Some(mode) = update.get("currentModeId").and_then(Value::as_str)
                    && let Some(option) =
                        self.config_options.iter_mut().find(|o| o.category.as_deref() == Some("mode"))
                {
                    option.current_value = mode.to_owned();
                    self.changed();
                }
            }
            Some("session_info_update") => {
                if let Some(title) = update.get("title").and_then(Value::non_empty_string) {
                    self.report(AgentChatEvent::Title(title.to_owned()));
                }
            }
            Some("usage_update") => {
                if let (Some(used), Some(size)) = (
                    update.get("used").and_then(JsonValueExt::int),
                    update.get("size").and_then(JsonValueExt::int),
                ) && size > 0
                {
                    self.context_usage = Some((used, size));
                    self.changed();
                }
            }
            Some("available_commands_update") => {
                self.commands = AgentChatCommand::parse(update.get("availableCommands"));
                self.changed();
            }
            _ => {
                if self.builder.apply(update, now()) {
                    self.changed();
                }
            }
        }
    }

    fn handle_request(&mut self, peer_id: u64, id: Value, method: &str, params: &Value) {
        match method {
            "session/request_permission" => {
                let tool_call = params.get("toolCall").cloned().unwrap_or(Value::Null);
                let options: Vec<ApprovalOption> = params
                    .get("options")
                    .and_then(Value::as_array)
                    .map(|options| {
                        options
                            .iter()
                            .filter_map(|option| {
                                let option_id = option.get("optionId").and_then(Value::as_str)?;
                                Some(ApprovalOption::new(
                                    option_id,
                                    option.get("name").and_then(Value::as_str).unwrap_or(option_id),
                                    option.get("kind").and_then(Value::as_str).unwrap_or(""),
                                ))
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                if options.is_empty() {
                    self.reply_to(peer_id, id, Ok(json!({"outcome": {"outcome": "cancelled"}})));
                    return;
                }
                let title = tool_call
                    .get("title")
                    .and_then(Value::non_empty_string)
                    .unwrap_or("Run a tool")
                    .to_owned();
                let command = tool_call
                    .get("rawInput")
                    .and_then(|i| i.get("command"))
                    .and_then(Value::non_empty_string);
                let permission = AgentChatPermission {
                    detail: command.filter(|c| *c != title && format!("$ {c}") != title).map(str::to_owned),
                    kind: ApprovalKind::of_acp_kind(tool_call.get("kind").and_then(Value::as_str)),
                    options,
                    title: title.clone(),
                };
                let request = ApprovalRequest {
                    id: String::new(),
                    kind: permission.kind,
                    detail: permission.subject(),
                    reason: permission.reason(),
                    options: permission.options.clone(),
                    decision: None,
                };
                self.present(
                    ChatInteraction::Permission(permission),
                    peer_id,
                    id,
                    AgentWaitingReason::Approval,
                    Some(title),
                );
                let item_id = self.local_id("approval");
                self.interaction_item_id = Some(item_id.clone());
                self.builder.add_approval(ApprovalRequest { id: item_id, ..request }, now());
                self.changed();
            }
            "elicitation/create" => {
                let question = (params.get("mode").and_then(Value::as_str).unwrap_or("form") == "form")
                    .then(|| {
                        AgentChatQuestion::new(
                            params.get("message").and_then(Value::as_str).unwrap_or(""),
                            params.get("requestedSchema").unwrap_or(&Value::Null),
                        )
                    })
                    .flatten();
                let Some(question) = question else {
                    self.reply_to(peer_id, id, Ok(json!({"action": "decline"})));
                    return;
                };
                let message = question.fields.first().map(|f| f.title.clone());
                let item_id = self.local_id("question");
                let request = question.user_input_request(&item_id);
                self.present(
                    ChatInteraction::Question(question),
                    peer_id,
                    id,
                    AgentWaitingReason::Question,
                    message,
                );
                self.interaction_item_id = Some(item_id);
                self.builder.add_user_input(request, now());
                self.changed();
            }
            _ => self.reply_to(
                peer_id,
                id,
                Err(JsonRpcError::new(JsonRpcError::METHOD_NOT_FOUND, format!("Method not found: {method}"))),
            ),
        }
    }

    fn present(
        &mut self,
        interaction: ChatInteraction,
        peer_id: u64,
        id: Value,
        reason: AgentWaitingReason,
        message: Option<String>,
    ) {
        // A newer request replaces one the agent left unanswered.
        self.fail_interaction();
        self.interaction = Some(interaction);
        self.interaction_reply = Some((peer_id, id));
        self.report(AgentChatEvent::Status {
            status: AgentStatus::Waiting,
            waiting_reason: Some(reason),
            notify: true,
            message,
        });
        self.changed();
    }

    // MARK: - Output

    fn report(&mut self, event: AgentChatEvent) {
        if let Some(callback) = self.on_event.as_mut() {
            callback(&event);
        }
    }

    fn changed(&mut self) {
        if let Some(callback) = self.on_change.as_mut() {
            callback();
        }
    }
}

fn now() -> Date {
    Utc::now()
}
