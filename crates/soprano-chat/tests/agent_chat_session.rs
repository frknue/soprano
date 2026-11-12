use std::cell::RefCell;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::{Arc, Mutex, MutexGuard};

use serde_json::{Value, json};
use soprano_chat::*;
use soprano_types::{AgentStatus, AgentWaitingReason, DefaultAgents};

/// Stands in for an agent's ACP server: answers `initialize` and the session methods at once
/// and holds every `session/prompt` until the test answers it.
#[derive(Default)]
struct FakeState {
    sink: Option<PeerSink>,
    requests: Vec<(String, Value)>,
    notifications: Vec<(String, Value)>,
    replies: Vec<(Value, Result<Value, JsonRpcError>)>,
    load_error: Option<JsonRpcError>,
    /// Leaves `session/set_config_option` unanswered, like an agent that dies first.
    holds_settings: bool,
    /// A reopened conversation reports its settings, as omp does.
    load_reports_settings: bool,
    prompts: Vec<u64>,
    next_id: u64,
    next_request_id: u64,
    terminated: bool,
    exited: bool,
}

#[derive(Clone, Default)]
struct FakeAgent(Arc<Mutex<FakeState>>);

impl FakeAgent {
    fn state(&self) -> MutexGuard<'_, FakeState> {
        self.0.lock().expect("fake state")
    }

    fn sink(&self) -> PeerSink {
        self.state().sink.clone().expect("started")
    }

    fn methods(&self) -> Vec<String> {
        self.state().requests.iter().map(|r| r.0.clone()).collect()
    }

    fn requests(&self) -> Vec<(String, Value)> {
        self.state().requests.clone()
    }

    fn waiting_prompts(&self) -> usize {
        self.state().prompts.len()
    }

    fn is_terminated(&self) -> bool {
        self.state().terminated
    }

    fn sent_prompts(&self) -> Vec<Value> {
        self.requests()
            .into_iter()
            .filter(|r| r.0 == "session/prompt")
            .map(|r| r.1["prompt"][0]["text"].clone())
            .collect()
    }

    fn end_turn(&self, stop_reason: &str) {
        let id = self.state().prompts.remove(0);
        self.sink().send(PeerEvent::Response { id, result: Ok(json!({"stopReason": stop_reason})) });
    }

    fn send(&self, update: Value) {
        self.sink().send(PeerEvent::Notification {
            method: "session/update".into(),
            params: json!({"sessionId": "new-session", "update": update}),
        });
    }

    /// Sends the agent's request; `answer` returns what the session replied.
    fn ask(&self, method: &str, params: Value) -> Value {
        let id = {
            let mut state = self.state();
            state.next_request_id += 1;
            json!(format!("agent-{}", state.next_request_id))
        };
        self.sink().send(PeerEvent::Request { id: id.clone(), method: method.into(), params });
        id
    }

    fn answer(&self, id: &Value) -> Option<Result<Value, JsonRpcError>> {
        self.state().replies.iter().find(|r| &r.0 == id).map(|r| r.1.clone())
    }

    fn exit(&self, status: i32, stderr: &str) {
        let (sink, prompts) = {
            let mut state = self.state();
            state.exited = true;
            (state.sink.clone().expect("started"), std::mem::take(&mut state.prompts))
        };
        for id in prompts {
            sink.send(PeerEvent::Response { id, result: Err(JsonRpcError::closed()) });
        }
        sink.send(PeerEvent::Exit { status, stderr: stderr.into() });
    }
}

impl JsonRpcPeer for FakeAgent {
    fn start(&mut self, sink: PeerSink) -> std::io::Result<()> {
        self.state().sink = Some(sink);
        Ok(())
    }

    fn request(&mut self, method: &str, params: Value) -> Result<u64, JsonRpcError> {
        let mut state = self.state();
        if state.exited {
            return Err(JsonRpcError::closed());
        }
        state.next_id += 1;
        let id = state.next_id;
        state.requests.push((method.into(), params));
        let result = match method {
            "initialize" => Some(Ok(json!({
                "protocolVersion": 1, "agentCapabilities": {"loadSession": true}, "_meta": {"steering": {"supported": true}}
            }))),
            "session/new" => Some(Ok(json!({"sessionId": "new-session", "configOptions": settings()}))),
            "session/load" => Some(state.load_error.clone().map_or_else(
                || {
                    Ok(if state.load_reports_settings {
                        json!({"configOptions": settings()})
                    } else {
                        json!({})
                    })
                },
                Err,
            )),
            "session/set_config_option" if state.holds_settings => None,
            "session/prompt" => {
                state.prompts.push(id);
                None
            }
            _ => Some(Ok(json!({}))),
        };
        if let (Some(result), Some(sink)) = (result, state.sink.clone()) {
            sink.send(PeerEvent::Response { id, result });
        }
        Ok(id)
    }

    fn notify(&mut self, method: &str, params: Value) {
        self.state().notifications.push((method.into(), params));
    }

    fn reply(&mut self, id: Value, result: Result<Value, JsonRpcError>) {
        self.state().replies.push((id, result));
    }

    /// Like a real agent, the process outlives the signal until `exit`.
    fn terminate(&mut self) {
        self.state().terminated = true;
    }

    fn has_exited(&self) -> bool {
        self.state().exited
    }
}

/// What the stand-in agent offers a conversation.
fn settings() -> Value {
    json!([
        {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "a/one",
         "options": [{"value": "a/one", "name": "One"}, {"value": "a/two", "name": "Two"}]},
    ])
}

fn launch() -> AgentChatLaunch {
    AgentChatLaunch::new(
        &DefaultAgents::omp(),
        LaunchSpec { argv: vec!["/bin/zsh".into()], cwd: PathBuf::from("/work/repo"), env: Vec::new() },
    )
    .expect("omp chats")
}

type Events = Rc<RefCell<Vec<AgentChatEvent>>>;

fn make_session() -> (AgentChatSession, FakeAgent, Events) {
    let agent = FakeAgent::default();
    let peer = agent.clone();
    let mut session =
        AgentChatSession::with_peer_factory(launch(), Box::new(move |_| Box::new(peer.clone())));
    let events: Events = Rc::default();
    let recorded = Rc::clone(&events);
    session.set_on_event(move |event| recorded.borrow_mut().push(event.clone()));
    (session, agent, events)
}

/// Lets the session apply what the agent said.
fn settle(session: &mut AgentChatSession) {
    for _ in 0..10 {
        if !session.process_events() {
            return;
        }
    }
}

fn started() -> (AgentChatSession, FakeAgent, Events) {
    let (mut session, agent, events) = make_session();
    session.start(None);
    settle(&mut session);
    assert_eq!(session.phase(), &ChatPhase::Ready);
    (session, agent, events)
}

#[test]
fn a_new_chat_opens_a_session_and_reports_its_conversation_and_settings() {
    let (session, agent, events) = started();

    assert_eq!(agent.methods(), vec!["initialize", "session/new"]);
    assert_eq!(agent.requests()[1].1["cwd"], json!("/work/repo"));
    assert_eq!(session.session_id(), Some("new-session"));
    assert_eq!(session.config_options().iter().map(|o| o.current_name()).collect::<Vec<_>>(), vec!["One"]);
    assert!(
        events
            .borrow()
            .contains(&AgentChatEvent::Conversation { id: "new-session".into(), cwd: "/work/repo".into() })
    );
    assert_eq!(events.borrow().last(), Some(&AgentChatEvent::status(AgentStatus::Idle)));
}

#[test]
fn reopening_a_conversation_loads_it_and_falls_back_to_a_new_one_when_it_is_gone() {
    let (mut session, agent, _) = make_session();
    session.start(Some("old-session"));
    settle(&mut session);
    assert_eq!(session.phase(), &ChatPhase::Ready);
    assert_eq!(agent.methods(), vec!["initialize", "session/load"]);
    assert_eq!(session.session_id(), Some("old-session"));

    let (mut missing, gone, _) = make_session();
    gone.state().load_error = Some(JsonRpcError::new(-32_002, "Resource not found: old-session"));
    missing.start(Some("old-session"));
    settle(&mut missing);
    assert_eq!(missing.phase(), &ChatPhase::Ready);
    assert_eq!(gone.methods(), vec!["initialize", "session/load", "session/new"]);
    assert_eq!(missing.session_id(), Some("new-session"));
    assert_eq!(
        missing.thread().preamble.first().map(|i| i.kind.clone()),
        Some(TurnItemKind::Error {
            message: "Could not reopen the conversation: Resource not found: old-session".into()
        })
    );
}

#[test]
fn prompts_sent_during_a_turn_wait_and_go_out_when_it_ends() {
    let (mut session, agent, events) = started();

    assert!(session.send("First"));
    settle(&mut session);
    assert_eq!(agent.waiting_prompts(), 1);
    assert_eq!(session.phase(), &ChatPhase::Working);
    assert!(session.send("Second"));
    assert_eq!(session.queued_prompts(), vec!["Second"]);

    agent.send(json!({"sessionUpdate": "agent_message_chunk", "messageId": "m1", "content": {"type": "text", "text": "Done."}}));
    agent.end_turn("end_turn");
    settle(&mut session);
    assert_eq!(agent.waiting_prompts(), 1);
    assert!(session.queued_prompts().is_empty());

    let thread = session.thread();
    assert_eq!(
        thread.turns.iter().map(|t| t.user_message.text.as_str()).collect::<Vec<_>>(),
        vec!["First", "Second"]
    );
    assert_eq!(
        thread.turns[0].items.iter().map(|i| i.kind.clone()).collect::<Vec<_>>(),
        vec![TurnItemKind::AssistantMessage { text: "Done.".into(), is_final: true }]
    );
    assert_eq!(thread.turns[0].status, TurnStatus::Completed);
    assert!(events.borrow().contains(&AgentChatEvent::Status {
        status: AgentStatus::Waiting,
        waiting_reason: Some(AgentWaitingReason::TurnEnded),
        notify: true,
        message: Some("Done.".into()),
    }));
    assert_eq!(agent.sent_prompts(), vec![json!("First"), json!("Second")]);
}

#[test]
fn steering_sends_into_the_running_turn_and_escape_cancels_it() {
    let (mut session, agent, _) = started();
    session.send("Refactor");
    settle(&mut session);
    assert_eq!(agent.waiting_prompts(), 1);

    assert!(session.steer("Keep the tests"));
    settle(&mut session);
    assert!(agent.methods().contains(&"_session/steering".to_owned()));
    assert!(session.queued_prompts().is_empty());
    assert_eq!(
        session.thread().turns.last().map(|t| t.steers.iter().map(|s| s.text.clone()).collect::<Vec<_>>()),
        Some(vec!["Keep the tests".to_owned()])
    );

    session.cancel();
    assert_eq!(
        agent.state().notifications.iter().map(|n| n.0.clone()).collect::<Vec<_>>(),
        vec!["session/cancel"]
    );
    assert!(session.thread().active_turn().and_then(|t| t.stop_requested_at).is_some());
    agent.end_turn("cancelled");
    settle(&mut session);
    assert_eq!(session.phase(), &ChatPhase::Ready);
    assert_eq!(session.thread().turns.last().map(|t| t.status), Some(TurnStatus::Interrupted));
    assert_eq!(session.thread().turns.last().and_then(|t| t.stop_requested_at), None);
}

#[test]
fn stopping_a_turn_keeps_queued_prompts_until_the_next_turn_ends() {
    let (mut session, agent, _) = started();
    session.send("Long task");
    settle(&mut session);
    session.send("Follow-up");

    session.cancel();
    agent.end_turn("cancelled");
    settle(&mut session);
    assert_eq!(session.phase(), &ChatPhase::Ready);
    assert_eq!(agent.waiting_prompts(), 0);
    assert_eq!(session.queued_prompts(), vec!["Follow-up"]);

    session.send("Something else first");
    settle(&mut session);
    assert_eq!(agent.waiting_prompts(), 1);
    assert_eq!(session.queued_prompts(), vec!["Follow-up"]);
    agent.end_turn("end_turn");
    settle(&mut session);
    assert!(session.queued_prompts().is_empty());
    assert_eq!(agent.waiting_prompts(), 1);
    assert_eq!(
        agent.sent_prompts(),
        vec![json!("Long task"), json!("Something else first"), json!("Follow-up")]
    );
}

#[test]
fn a_permission_request_waits_for_the_persons_choice_and_returns_it() {
    let (mut session, agent, events) = started();
    session.send("List files");
    settle(&mut session);

    let id = agent.ask(
        "session/request_permission",
        json!({
            "sessionId": "new-session",
            "toolCall": {"toolCallId": "t1", "title": "rm -rf build", "kind": "execute", "rawInput": {"command": "rm -rf build"}},
            "options": [
                {"optionId": "allow_once", "name": "Allow once", "kind": "allow_once"},
                {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"},
            ],
        }),
    );
    settle(&mut session);
    let Some(ChatInteraction::Permission(permission)) = session.interaction() else {
        panic!("no permission card")
    };
    assert_eq!(permission.title, "rm -rf build");
    assert_eq!(permission.detail, None);
    assert_eq!(
        permission.options.iter().map(|o| o.name.as_str()).collect::<Vec<_>>(),
        vec!["Allow once", "Reject"]
    );
    assert_eq!(agent.answer(&id), None);
    assert_eq!(
        events.borrow().last(),
        Some(&AgentChatEvent::Status {
            status: AgentStatus::Waiting,
            waiting_reason: Some(AgentWaitingReason::Approval),
            notify: true,
            message: Some("rm -rf build".into()),
        })
    );
    let thread = session.thread();
    let pending = thread.active_turn().and_then(|t| t.pending_approval()).expect("pending approval");
    assert_eq!(pending.kind, ApprovalKind::Command);
    assert_eq!(pending.detail, "rm -rf build");

    session.choose_permission_option("reject_once");
    assert_eq!(
        agent.answer(&id),
        Some(Ok(json!({"outcome": {"outcome": "selected", "optionId": "reject_once"}})))
    );
    assert_eq!(session.interaction(), None);
    assert_eq!(events.borrow().last(), Some(&AgentChatEvent::status(AgentStatus::Running)));
    // The turn keeps what was asked and the answer.
    let thread = session.thread();
    let turn = thread.active_turn().expect("running turn");
    let item = turn.items.last().expect("approval item");
    let TurnItemKind::Approval(request) = &item.kind else { panic!("no approval item") };
    assert_eq!(request.decision, Some(ApprovalDecision::Decline));
    assert_eq!(item.status, TurnItemStatus::Declined);
    assert_eq!(turn.pending_approval(), None);
}

#[test]
fn approve_and_decline_pick_allow_once_and_reject_once_and_more_holds_the_rest() {
    let options: &[ApprovalOption] = &[
        ApprovalOption::new("always", "Always allow", "allow_always"),
        ApprovalOption::new("once", "Allow once", "allow_once"),
        ApprovalOption::new("no", "Reject", "reject_once"),
        ApprovalOption::new("never", "Always reject", "reject_always"),
    ];
    assert_eq!(options.approve_option().map(|o| o.id.as_str()), Some("once"));
    assert_eq!(options.decline_option().map(|o| o.id.as_str()), Some("no"));
    assert_eq!(
        options.more_options().iter().map(|o| o.name.as_str()).collect::<Vec<_>>(),
        vec!["Always allow", "Always reject"]
    );
    assert_eq!(ApprovalDecision::of_option_kind("allow_always"), ApprovalDecision::AcceptForSession);
    assert_eq!(ApprovalDecision::of_option_kind("reject_always"), ApprovalDecision::Decline);
}

#[test]
fn a_question_form_becomes_fields_in_order_with_their_own_answer_keys() {
    let schema: Value = serde_json::from_str(
        r#"{"type":"object","properties":{
          "q10":{"type":"string","title":"Last?","oneOf":[{"const":"Yes","title":"Yes"}]},
          "q0":{"type":"string","title":"Which database?","description":"Storage","oneOf":[{"const":"SQLite","title":"SQLite","description":"Local file"},{"const":"Postgres","title":"Postgres"}],"default":"SQLite"},
          "q0__other":{"type":"string","title":"Other (type your own)"},
          "q2":{"type":"array","title":"Which targets?","items":{"anyOf":[{"const":"macOS","title":"macOS"},{"const":"Linux","title":"Linux"}]}}
        }}"#,
    )
    .expect("schema");
    let question = AgentChatQuestion::new("Answer 3 questions", &schema).expect("question");
    assert_eq!(question.fields.iter().map(|f| f.key.as_str()).collect::<Vec<_>>(), vec!["q0", "q2", "q10"]);
    let first = &question.fields[0];
    assert_eq!(first.title, "Which database?");
    assert_eq!(first.detail.as_deref(), Some("Storage"));
    assert_eq!(
        first.choices.iter().map(|c| c.label.as_str()).collect::<Vec<_>>(),
        vec!["SQLite", "Postgres"]
    );
    assert_eq!(first.choices[0].detail.as_deref(), Some("Local file"));
    assert_eq!(first.other_key.as_deref(), Some("q0__other"));
    assert_eq!(first.recommended.as_deref(), Some("SQLite"));
    assert!(question.fields[1].allows_multiple);
    assert_eq!(question.fields[1].other_key, None);
}

#[test]
fn an_answered_question_goes_back_as_the_forms_content() {
    let (mut session, agent, _) = started();
    let id = agent.ask(
        "elicitation/create",
        json!({
            "mode": "form", "sessionId": "new-session", "message": "Pick one",
            "requestedSchema": {"type": "object", "properties": {
                "q0": {"type": "string", "title": "Pick one", "oneOf": [{"const": "A", "title": "A"}]},
            }},
        }),
    );
    settle(&mut session);
    let mut content = serde_json::Map::new();
    content.insert("q0".into(), json!("A"));
    session.answer_question(content);
    assert_eq!(agent.answer(&id), Some(Ok(json!({"action": "accept", "content": {"q0": "A"}}))));
    let thread = session.thread();
    let Some(TurnItemKind::UserInput(request)) =
        thread.turns.last().and_then(|t| t.items.last()).map(|i| &i.kind)
    else {
        panic!("no question item")
    };
    assert_eq!(request.answers, Some(BTreeMap::from([("q0".to_owned(), vec!["A".to_owned()])])));
}

#[test]
fn answers_by_question_become_the_forms_content_with_typed_answers_under_the_other_key() {
    let schema: Value = serde_json::from_str(
        r#"{"type":"object","properties":{
          "q0":{"type":"string","title":"Which database?","description":"Storage","oneOf":[{"const":"SQLite","title":"SQLite"}]},
          "q0__other":{"type":"string","title":"Other (type your own)"},
          "q1":{"type":"array","title":"Which targets?","items":{"anyOf":[{"const":"macOS","title":"macOS"},{"const":"Linux","title":"Linux"}]}},
          "q2":{"type":"string","title":"Anything else?"}
        }}"#,
    )
    .expect("schema");
    let question = AgentChatQuestion::new("Answer 3 questions", &schema).expect("question");
    let request = question.user_input_request("r");
    assert_eq!(
        request.questions.iter().map(|q| q.header.as_str()).collect::<Vec<_>>(),
        vec!["Storage", "", ""]
    );
    assert_eq!(request.questions.iter().map(|q| q.allows_other).collect::<Vec<_>>(), vec![true, false, true]);

    let answers = |pairs: &[(&str, &[&str])]| -> BTreeMap<String, Vec<String>> {
        pairs.iter().map(|(k, v)| ((*k).to_owned(), v.iter().map(|s| (*s).to_owned()).collect())).collect()
    };
    let picked =
        question.content(&answers(&[("q0", &["SQLite"]), ("q1", &["macOS", "Linux"]), ("q2", &["No"])]));
    assert_eq!(Value::Object(picked), json!({"q0": "SQLite", "q1": ["macOS", "Linux"], "q2": "No"}));
    let typed = question.content(&answers(&[("q0", &["DuckDB"]), ("q1", &[]), ("q2", &["No"])]));
    assert_eq!(Value::Object(typed.clone()), json!({"q0__other": "DuckDB", "q1": [], "q2": "No"}));
    assert_eq!(question.answers(&typed), answers(&[("q0", &["DuckDB"]), ("q1", &[]), ("q2", &["No"])]));
}

#[test]
fn an_agent_that_exits_mid_turn_ends_the_turn_and_reports_why() {
    let (mut session, agent, events) = started();
    session.send("Go");
    settle(&mut session);
    agent.send(json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "name": "bash", "title": "$ make", "status": "pending", "rawInput": {"command": "make"}}));

    agent.exit(1, "boot\nerror: Config overlay not found");
    settle(&mut session);
    assert!(!session.is_running());

    let thread = session.thread();
    assert_eq!(
        thread.turns.last().and_then(|t| t.items.first()).map(|i| i.status),
        Some(TurnItemStatus::Interrupted)
    );
    let reason = "The agent exited with status 1:\nboot\nerror: Config overlay not found";
    assert_eq!(session.phase(), &ChatPhase::Stopped(Some(reason.into())));
    assert_eq!(
        thread.turns.last().and_then(|t| t.items.last()).map(|i| i.kind.clone()),
        Some(TurnItemKind::Error { message: reason.into() })
    );
    assert_eq!(
        events.borrow().last(),
        Some(&AgentChatEvent::Status {
            status: AgentStatus::Error,
            waiting_reason: None,
            notify: true,
            message: Some(reason.into())
        })
    );
    assert!(!session.send("Again"));
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum RestartPath {
    Restart,
    StopThenRestart,
    RestartTwice,
}

fn restart_waits_for_the_old_agent(path: RestartPath) {
    let first = FakeAgent::default();
    let second = FakeAgent::default();
    let peers = Rc::new(RefCell::new(vec![first.clone(), second.clone()]));
    let factory_peers = Rc::clone(&peers);
    let mut session = AgentChatSession::with_peer_factory(
        launch(),
        Box::new(move |_| Box::new(factory_peers.borrow_mut().remove(0))),
    );
    let events: Events = Rc::default();
    let recorded = Rc::clone(&events);
    session.set_on_event(move |event| recorded.borrow_mut().push(event.clone()));
    session.start(None);
    settle(&mut session);
    assert_eq!(session.phase(), &ChatPhase::Ready);
    let reported = events.borrow().len();

    match path {
        RestartPath::Restart => session.restart(None),
        RestartPath::StopThenRestart => {
            session.stop();
            session.restart(None);
        }
        RestartPath::RestartTwice => {
            session.restart(None);
            settle(&mut session);
            session.restart(None);
        }
    }
    assert!(first.is_terminated());
    // The old process still holds the conversation: nothing opens it yet.
    settle(&mut session);
    assert!(second.requests().is_empty());
    assert_eq!(session.phase(), &ChatPhase::Starting);

    first.exit(0, "");
    settle(&mut session);
    assert_eq!(session.phase(), &ChatPhase::Ready);
    assert_eq!(second.methods(), vec!["initialize", "session/load"]);
    assert_eq!(second.requests().last().map(|r| r.1["sessionId"].clone()), Some(json!("new-session")));
    // Only a stop the person asked for reports one.
    let stopped = events.borrow()[reported..].contains(&AgentChatEvent::status(AgentStatus::Stopped));
    assert_eq!(stopped, path == RestartPath::StopThenRestart);
}

#[test]
fn restarting_waits_for_the_old_agent_to_exit_then_reopens_the_conversation() {
    restart_waits_for_the_old_agent(RestartPath::Restart);
}

#[test]
fn stopping_then_restarting_waits_for_the_old_agent_to_exit_then_reopens_the_conversation() {
    restart_waits_for_the_old_agent(RestartPath::StopThenRestart);
}

#[test]
fn restarting_twice_waits_for_the_old_agent_to_exit_then_reopens_the_conversation() {
    restart_waits_for_the_old_agent(RestartPath::RestartTwice);
}

#[test]
fn only_agents_that_serve_acp_open_as_a_chat() {
    let spec = LaunchSpec {
        argv: vec!["omp".into(), "acp".into()],
        cwd: PathBuf::from("/work/repo"),
        env: Vec::new(),
    };
    let launch = AgentChatLaunch::new(&DefaultAgents::omp(), spec.clone()).expect("omp chats");
    assert_eq!(launch.tool_style, AcpToolStyle::Omp);
    assert_eq!(launch.working_directory(), "/work/repo");
    assert_eq!(AgentChatLaunch::new(&DefaultAgents::codex(), spec), None);
    assert_eq!(
        AgentChatLaunch::chat_profiles().iter().map(|p| p.id.as_str()).collect::<Vec<_>>(),
        vec!["omp"]
    );
}

#[test]
fn the_agents_commands_feed_the_slash_menu_and_compact_sends_its_command() {
    let (mut session, agent, _) = started();
    assert!(!session.can_compact());
    agent.send(json!({"sessionUpdate": "available_commands_update", "availableCommands": [
        {"name": "compact", "description": "Compact the conversation", "input": {"hint": "[focus]"}},
        {"name": "review", "description": ""},
    ]}));
    settle(&mut session);
    assert_eq!(
        session.commands(),
        &[
            AgentChatCommand {
                name: "compact".into(),
                description: Some("Compact the conversation".into()),
                hint: Some("[focus]".into())
            },
            AgentChatCommand { name: "review".into(), description: None, hint: None },
        ]
    );
    assert_eq!(session.commands()[0].insert_text(), "/compact ");
    assert!(session.can_compact());

    session.compact();
    settle(&mut session);
    assert_eq!(agent.waiting_prompts(), 1);
    assert_eq!(agent.sent_prompts().last(), Some(&json!("/compact")));
    assert!(!session.can_compact());
}

#[test]
fn a_queued_prompt_can_be_removed_or_steered_in_by_its_id() {
    let (mut session, agent, _) = started();
    session.send("Work");
    settle(&mut session);
    session.send("Later");
    session.send("Now");
    let queue = session.thread().queue;
    assert_eq!(queue.iter().map(|m| m.text.as_str()).collect::<Vec<_>>(), vec!["Later", "Now"]);
    assert_ne!(queue[0].id, queue[1].id);

    session.remove_queued_prompt(&queue[0].id);
    session.send_queued_prompt_now(&queue[1].id);
    assert!(session.queued_prompts().is_empty());
    settle(&mut session);
    assert!(agent.methods().contains(&"_session/steering".to_owned()));
    assert_eq!(
        session.thread().active_turn().map(|t| t.steers.iter().map(|s| s.text.clone()).collect::<Vec<_>>()),
        Some(vec!["Now".to_owned()])
    );
}

#[test]
fn model_mode_plan_and_context_updates_change_what_the_chat_shows() {
    let (mut session, agent, _) = started();
    session.set_config_option("model", "a/two");
    settle(&mut session);
    assert_eq!(
        agent.requests().last().map(|r| r.1.clone()),
        Some(json!({"sessionId": "new-session", "configId": "model", "value": "a/two"}))
    );

    agent.send(json!({"sessionUpdate": "plan", "entries": [
        {"content": "Read the code", "status": "completed"},
        {"content": "Fix it", "status": "in_progress"},
        {"content": "", "status": "pending"},
        {"content": "Test it"},
    ]}));
    agent.send(json!({"sessionUpdate": "usage_update", "used": 1200, "size": 200000}));
    agent.send(json!({"sessionUpdate": "config_option_update", "configOptions": [
        {"id": "mode", "name": "Mode", "category": "mode", "type": "select", "currentValue": "default",
         "options": [{"value": "default", "name": "Default"}, {"value": "plan", "name": "Plan"}]},
    ]}));
    agent.send(json!({"sessionUpdate": "current_mode_update", "currentModeId": "plan"}));
    settle(&mut session);

    assert_eq!(
        session.plan().iter().map(|e| (e.content.as_str(), e.status)).collect::<Vec<_>>(),
        vec![
            ("Read the code", PlanEntryStatus::Completed),
            ("Fix it", PlanEntryStatus::InProgress),
            ("Test it", PlanEntryStatus::Pending),
        ]
    );
    assert_eq!(session.context_usage(), Some((1200, 200_000)));
    assert_eq!(session.config_options().iter().map(|o| o.current_name()).collect::<Vec<_>>(), vec!["Plan"]);
}

#[test]
fn a_conversation_started_with_a_model_gets_it_before_its_first_prompt() {
    let (mut session, agent, _) = make_session();
    // The agent offers neither a thinking level nor a model a/nine: both are skipped.
    session.set_opening_options(vec![
        ("thinking".into(), "high".into()),
        ("model".into(), "a/two".into()),
        ("model".into(), "a/nine".into()),
    ]);
    session.start(None);
    assert!(session.send("Fix the totals"));
    settle(&mut session);

    assert_eq!(
        agent.methods(),
        vec!["initialize", "session/new", "session/set_config_option", "session/prompt"]
    );
    assert_eq!(
        agent.requests()[2].1,
        json!({"sessionId": "new-session", "configId": "model", "value": "a/two"})
    );
    assert!(!session.has_opening_options());
    assert_eq!(session.phase(), &ChatPhase::Working);
}

#[test]
fn opening_settings_the_conversation_already_has_send_nothing() {
    let (mut session, agent, _) = started();
    session.set_opening_options(vec![("model".into(), "a/one".into())]);
    assert!(session.send("Hello"));
    settle(&mut session);
    assert_eq!(agent.methods(), vec!["initialize", "session/new", "session/prompt"]);
}

#[test]
fn probing_reads_what_a_new_conversation_offers_and_ends_the_agent() {
    let (session, agent, _) = make_session();
    let options = session
        .probe_config_options(vec![("model".into(), "a/two".into())], std::time::Duration::from_secs(5));

    assert_eq!(options.iter().map(|option| option.id.as_str()).collect::<Vec<_>>(), vec!["model"]);
    assert_eq!(agent.methods(), vec!["initialize", "session/new", "session/set_config_option"]);
    assert!(agent.is_terminated());
}

#[test]
fn a_restart_before_an_opening_setting_is_answered_applies_it_again_then_sends_the_prompt() {
    let first = FakeAgent::default();
    first.state().holds_settings = true;
    let second = FakeAgent::default();
    second.state().load_reports_settings = true;
    let peers = Rc::new(RefCell::new(vec![first.clone(), second.clone()]));
    let mut session = AgentChatSession::with_peer_factory(
        launch(),
        Box::new(move |_| Box::new(peers.borrow_mut().remove(0))),
    );
    session.set_opening_options(vec![("model".into(), "a/two".into())]);
    session.start(None);
    assert!(session.send("Fix the totals"));
    settle(&mut session);
    // The setting is with the agent, and the prompt waits for its answer.
    assert_eq!(first.methods().last().map(String::as_str), Some("session/set_config_option"));
    assert!(session.has_opening_options());

    // The agent goes away without answering: the conversation it reopens gets the setting
    // again, and the prompt after it.
    session.restart(None);
    first.exit(0, "");
    settle(&mut session);
    assert_eq!(
        second.methods(),
        vec!["initialize", "session/load", "session/set_config_option", "session/prompt"]
    );
    assert_eq!(second.requests()[2].1["value"], json!("a/two"));
    assert!(!session.has_opening_options());
}

#[test]
fn an_agent_that_exits_before_answering_an_opening_setting_does_not_hold_later_prompts() {
    let first = FakeAgent::default();
    first.state().holds_settings = true;
    let second = FakeAgent::default();
    let peers = Rc::new(RefCell::new(vec![first.clone(), second.clone()]));
    let mut session = AgentChatSession::with_peer_factory(
        launch(),
        Box::new(move |_| Box::new(peers.borrow_mut().remove(0))),
    );
    session.set_opening_options(vec![("model".into(), "a/two".into())]);
    session.start(None);
    settle(&mut session);
    first.exit(1, "boom");
    settle(&mut session);
    assert!(!session.is_running());

    // Started again, on a conversation that reports no settings: the prompt goes out.
    session.restart(None);
    settle(&mut session);
    assert!(session.send("Hello"));
    settle(&mut session);
    assert_eq!(second.sent_prompts(), vec![json!("Hello")]);
}

// AgentChatTabTests: the part that is the session's — what the chat reports to its tab.
#[test]
fn the_chat_reports_status_conversation_and_title_to_its_tab() {
    let (mut session, agent, events) = started();
    assert!(
        events
            .borrow()
            .contains(&AgentChatEvent::Conversation { id: "new-session".into(), cwd: "/work/repo".into() })
    );
    assert_eq!(events.borrow().last(), Some(&AgentChatEvent::status(AgentStatus::Idle)));

    assert!(session.send("Hello"));
    settle(&mut session);
    assert_eq!(agent.waiting_prompts(), 1);
    assert_eq!(events.borrow().last(), Some(&AgentChatEvent::status(AgentStatus::Running)));

    agent.send(json!({"sessionUpdate": "session_info_update", "title": "Greet the user"}));
    settle(&mut session);
    assert_eq!(events.borrow().last(), Some(&AgentChatEvent::Title("Greet the user".into())));

    // Stopping a chat leaves it stopped.
    session.stop();
    assert!(!session.is_running());
    assert_eq!(events.borrow().last(), Some(&AgentChatEvent::status(AgentStatus::Stopped)));
    assert_eq!(session.thread().turns.last().map(|t| t.status), Some(TurnStatus::Interrupted));
}

#[test]
fn a_waker_set_after_the_agent_started_is_still_woken() {
    let (mut session, agent, _) = started();
    let woken = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counter = Arc::clone(&woken);
    session.set_waker(move || {
        counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    });
    agent.send(json!({"sessionUpdate": "session_info_update", "title": "Hi"}));
    assert_eq!(woken.load(std::sync::atomic::Ordering::SeqCst), 1);
}

#[test]
fn starting_while_an_agent_runs_retires_it_and_waits_for_it_to_exit() {
    let first = FakeAgent::default();
    let second = FakeAgent::default();
    let peers = Rc::new(RefCell::new(vec![first.clone(), second.clone()]));
    let factory_peers = Rc::clone(&peers);
    let mut session = AgentChatSession::with_peer_factory(
        launch(),
        Box::new(move |_| Box::new(factory_peers.borrow_mut().remove(0))),
    );
    session.start(None);
    settle(&mut session);
    assert_eq!(session.phase(), &ChatPhase::Ready);

    session.start(None);
    assert!(first.is_terminated());
    let id = first
        .ask("session/request_permission", json!({"options": [{"optionId": "a", "kind": "allow_once"}]}));
    settle(&mut session);
    assert_eq!(
        first.answer(&id),
        Some(Err(JsonRpcError::new(JsonRpcError::INTERNAL_ERROR, "Session closed")))
    );
    assert!(second.requests().is_empty());

    first.exit(0, "");
    settle(&mut session);
    assert_eq!(session.phase(), &ChatPhase::Ready);
    assert_eq!(second.methods(), vec!["initialize", "session/new"]);
}
