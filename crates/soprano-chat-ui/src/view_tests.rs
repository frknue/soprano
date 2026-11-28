//! The chat's views driven headlessly: a fake agent stands in for omp (`FakeACPAgent` of the
//! Swift tests), keys and clicks go through GPUI's test window.

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use gpui::{AppContext as _, Entity, Modifiers, TestAppContext, VisualTestContext, point, px};
use serde_json::{Value, json};
use soprano_agents::{AgentTimeline, AgentTimelineItem, ChatThread, TimelineItemKind};
use soprano_chat::{
    AcpToolStyle, AgentChatEvent, AgentChatLaunch, AgentChatSession, ChatPhase, JsonRpcError, JsonRpcPeer,
    LaunchSpec, PeerEvent, PeerSink,
};
use soprano_types::AgentStatus;

use crate::chat_view::{ChatView, ChatViewEvent};
use crate::composer_logic::ComposerPrimaryAction;
use crate::rows::TimelineRowContent;
use crate::source::TranscriptSource;
use crate::timeline_view::TimelineView;

#[derive(Default)]
struct FakeState {
    sink: Option<PeerSink>,
    requests: Vec<(String, Value)>,
    notifications: Vec<(String, Value)>,
    replies: Vec<(Value, Result<Value, JsonRpcError>)>,
    prompts: Vec<u64>,
    next_id: u64,
    exited: bool,
}

/// Answers `initialize` and the session methods at once and holds every `session/prompt` until
/// the test ends it.
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

    fn sent_prompts(&self) -> Vec<String> {
        self.state()
            .requests
            .iter()
            .filter(|r| r.0 == "session/prompt" || r.0 == "_session/steering")
            .map(|r| format!("{}: {}", r.0, r.1["prompt"][0]["text"].as_str().unwrap_or("")))
            .collect()
    }

    fn waiting_prompts(&self) -> usize {
        self.state().prompts.len()
    }

    fn end_turn(&self) {
        let id = self.state().prompts.remove(0);
        self.sink().send(PeerEvent::Response { id, result: Ok(json!({"stopReason": "end_turn"})) });
    }

    fn send(&self, update: Value) {
        self.sink().send(PeerEvent::Notification {
            method: "session/update".into(),
            params: json!({"sessionId": "new-session", "update": update}),
        });
    }

    fn ask(&self, method: &str, params: Value) -> Value {
        let id = json!("agent-1");
        self.sink().send(PeerEvent::Request { id: id.clone(), method: method.into(), params });
        id
    }

    fn answer(&self, id: &Value) -> Option<Result<Value, JsonRpcError>> {
        self.state().replies.iter().find(|r| &r.0 == id).map(|r| r.1.clone())
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
            "initialize" => Some(json!({
                "protocolVersion": 1, "agentCapabilities": {"loadSession": true}, "_meta": {"steering": {"supported": true}}
            })),
            "session/new" => Some(json!({"sessionId": "new-session", "configOptions": [
                {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "a/one",
                 "options": [{"value": "a/one", "name": "One"}, {"value": "a/two", "name": "Two"}]},
                {"id": "thinking", "name": "Thinking", "category": "thought_level", "type": "select", "currentValue": "low",
                 "options": [{"value": "low", "name": "Low"}, {"value": "high", "name": "High"}]},
            ]})),
            "session/prompt" => {
                state.prompts.push(id);
                None
            }
            _ => Some(json!({})),
        };
        if let (Some(result), Some(sink)) = (result, state.sink.clone()) {
            drop(state);
            sink.send(PeerEvent::Response { id, result: Ok(result) });
        }
        Ok(id)
    }

    fn notify(&mut self, method: &str, params: Value) {
        self.state().notifications.push((method.into(), params));
    }

    fn reply(&mut self, id: Value, result: Result<Value, JsonRpcError>) {
        self.state().replies.push((id, result));
    }

    fn terminate(&mut self) {
        let sink = {
            let mut state = self.state();
            state.exited = true;
            state.sink.clone()
        };
        if let Some(sink) = sink {
            sink.send(PeerEvent::Exit { status: 0, stderr: String::new() });
        }
    }

    fn has_exited(&self) -> bool {
        self.state().exited
    }
}

fn session(agent: &FakeAgent) -> AgentChatSession {
    let launch = AgentChatLaunch {
        profile_id: "omp".into(),
        agent_name: "omp".into(),
        spec: LaunchSpec {
            argv: vec!["omp".into(), "acp".into()],
            cwd: PathBuf::from("/work/repo"),
            env: Vec::new(),
        },
        tool_style: AcpToolStyle::Omp,
    };
    let agent = agent.clone();
    AgentChatSession::with_peer_factory(
        launch,
        Box::new(move |_| Box::new(agent.clone()) as Box<dyn JsonRpcPeer>),
    )
}

struct Chat {
    view: Entity<ChatView>,
    agent: FakeAgent,
    events: Rc<RefCell<Vec<ChatViewEvent>>>,
}

fn open_chat(cx: &mut TestAppContext) -> (Chat, &mut VisualTestContext) {
    cx.update(soprano_ui::init_for_tests);
    let agent = FakeAgent::default();
    let chat: Rc<RefCell<Option<Entity<ChatView>>>> = Rc::default();
    let slot = chat.clone();
    let fake = agent.clone();
    let (_, cx) = cx.add_window_view(move |window, cx| {
        let view = cx.new(|cx| ChatView::new(session(&fake), "omp", window, cx));
        *slot.borrow_mut() = Some(view.clone());
        gpui_component::Root::new(view, window, cx)
    });
    let view = chat.borrow().clone().expect("chat view");
    let events: Rc<RefCell<Vec<ChatViewEvent>>> = Rc::default();
    let recorded = events.clone();
    cx.update(|_, cx| {
        cx.subscribe(&view, move |_, event: &ChatViewEvent, _| recorded.borrow_mut().push(event.clone()))
            .detach();
    });
    (Chat { view, agent, events }, cx)
}

/// Lets the agent's messages arrive and the batched redraw run.
fn settle(cx: &mut VisualTestContext) {
    for _ in 0..3 {
        cx.run_until_parked();
        cx.executor().advance_clock(Duration::from_millis(60));
    }
    cx.run_until_parked();
}

impl Chat {
    fn start(&self, cx: &mut VisualTestContext) {
        cx.update(|window, cx| self.view.update(cx, |chat, cx| chat.start(None, window, cx)));
        settle(cx);
    }

    fn phase(&self, cx: &mut VisualTestContext) -> ChatPhase {
        cx.update(|_, cx| self.view.read(cx).session().borrow().phase().clone())
    }

    fn focus_composer(&self, cx: &mut VisualTestContext) {
        cx.update(|window, cx| self.view.update(cx, |chat, cx| chat.focus_composer(window, cx)));
        cx.run_until_parked();
    }

    fn type_text(&self, text: &str, cx: &mut VisualTestContext) {
        self.focus_composer(cx);
        cx.simulate_input(text);
        cx.run_until_parked();
    }

    fn composer_text(&self, cx: &mut VisualTestContext) -> String {
        cx.update(|_, cx| {
            let composer = self.view.read(cx).composer().clone();
            composer.read(cx).text(cx)
        })
    }

    fn rows(&self, cx: &mut VisualTestContext) -> Vec<TimelineRowContent> {
        cx.update(|_, cx| {
            let timeline = self.view.read(cx).timeline().clone();
            timeline.read(cx).rows().iter().map(|r| r.content.clone()).collect()
        })
    }

    fn queued(&self, cx: &mut VisualTestContext) -> Vec<String> {
        cx.update(|_, cx| self.view.read(cx).session().borrow().queued_prompts())
    }
}

#[gpui::test]
fn the_chat_reports_status_and_conversation_to_its_tab(cx: &mut TestAppContext) {
    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    assert_eq!(chat.phase(cx), ChatPhase::Ready);
    let events = chat.events.borrow().clone();
    assert!(events.contains(&ChatViewEvent::Agent(AgentChatEvent::status(AgentStatus::Starting))));
    assert!(events.contains(&ChatViewEvent::Agent(AgentChatEvent::Conversation {
        id: "new-session".into(),
        cwd: "/work/repo".into()
    })));
    assert!(events.contains(&ChatViewEvent::Agent(AgentChatEvent::status(AgentStatus::Idle))));
    assert!(
        matches!(chat.rows(cx).as_slice(), [TimelineRowContent::Empty(text)] if text == "Send a message to start the conversation.")
    );

    chat.agent.send(json!({"sessionUpdate": "session_info_update", "title": "Greet the user"}));
    settle(cx);
    assert!(
        chat.events.borrow().contains(&ChatViewEvent::Agent(AgentChatEvent::Title("Greet the user".into())))
    );

    // Stopping leaves the chat, stopped: Return asks the tab to restart the agent.
    cx.update(|window, cx| chat.view.update(cx, |chat, cx| chat.stop(window, cx)));
    settle(cx);
    assert!(
        chat.events.borrow().contains(&ChatViewEvent::Agent(AgentChatEvent::status(AgentStatus::Stopped)))
    );
    chat.focus_composer(cx);
    cx.simulate_keystrokes("enter");
    cx.run_until_parked();
    assert!(chat.events.borrow().contains(&ChatViewEvent::RestartRequested));
}

#[gpui::test]
fn return_sends_and_messages_during_a_turn_wait_in_the_queue(cx: &mut TestAppContext) {
    let (chat, cx) = open_chat(cx);
    chat.start(cx);

    chat.type_text("First", cx);
    cx.simulate_keystrokes("enter");
    settle(cx);
    assert_eq!(chat.agent.sent_prompts(), ["session/prompt: First"]);
    assert_eq!(chat.agent.waiting_prompts(), 1);
    assert_eq!(chat.composer_text(cx), "");
    assert_eq!(chat.phase(cx), ChatPhase::Working);

    chat.type_text("Second", cx);
    cx.simulate_keystrokes("enter");
    settle(cx);
    assert_eq!(chat.queued(cx), ["Second"]);
    assert!(chat.rows(cx).iter().any(|r| matches!(r, TimelineRowContent::Queued(m) if m.text == "Second")));

    chat.agent.send(json!({"sessionUpdate": "agent_message_chunk", "messageId": "m1", "content": {"type": "text", "text": "Done."}}));
    chat.agent.end_turn();
    settle(cx);
    assert_eq!(chat.agent.sent_prompts(), ["session/prompt: First", "session/prompt: Second"]);
    assert!(chat.queued(cx).is_empty());
    assert!(chat.rows(cx).iter().any(|r| matches!(r, TimelineRowContent::Assistant(a) if a.text == "Done.")));
}

#[gpui::test]
fn shift_return_adds_a_line_instead_of_sending(cx: &mut TestAppContext) {
    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    chat.type_text("One", cx);
    cx.simulate_keystrokes("shift-enter");
    cx.simulate_input("Two");
    cx.run_until_parked();
    assert_eq!(chat.composer_text(cx), "One\nTwo");
    assert!(chat.agent.sent_prompts().is_empty());
}

#[gpui::test]
fn command_return_steers_and_escape_stops_the_running_turn(cx: &mut TestAppContext) {
    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    chat.type_text("Refactor", cx);
    cx.simulate_keystrokes("enter");
    settle(cx);

    chat.type_text("Keep the tests", cx);
    let action = cx.update(|_, cx| {
        let composer = chat.view.read(cx).composer().clone();
        composer.read(cx).primary_action(cx)
    });
    assert_eq!(action, ComposerPrimaryAction::Queue);
    cx.simulate_keystrokes(if cfg!(target_os = "macos") { "cmd-enter" } else { "ctrl-shift-enter" });
    settle(cx);
    assert!(chat.agent.methods().contains(&"_session/steering".to_owned()));
    assert!(chat.queued(cx).is_empty());

    cx.simulate_keystrokes("escape");
    settle(cx);
    assert_eq!(
        chat.agent.state().notifications.iter().map(|n| n.0.clone()).collect::<Vec<_>>(),
        ["session/cancel"]
    );
    assert!(chat.rows(cx).contains(&TimelineRowContent::Working {
        started_at: chat.view.read_with(cx, |chat, _| chat.session().borrow().thread().turns[0].started_at),
        stopping: true
    }));
}

#[gpui::test]
fn up_recalls_earlier_messages_in_an_empty_composer(cx: &mut TestAppContext) {
    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    chat.type_text("Explain the fix", cx);
    cx.simulate_keystrokes("enter");
    settle(cx);
    chat.agent.end_turn();
    settle(cx);

    chat.focus_composer(cx);
    cx.simulate_keystrokes("up");
    cx.run_until_parked();
    assert_eq!(chat.composer_text(cx), "Explain the fix");
    cx.simulate_keystrokes("down");
    cx.run_until_parked();
    assert_eq!(chat.composer_text(cx), "");
}

#[gpui::test]
fn sending_while_an_approval_waits_declines_it_and_redirects_the_agent(cx: &mut TestAppContext) {
    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    chat.type_text("Clean up", cx);
    cx.simulate_keystrokes("enter");
    settle(cx);
    let id = chat.agent.ask(
        "session/request_permission",
        json!({
            "sessionId": "new-session",
            "toolCall": {"toolCallId": "t1", "title": "rm -rf build", "kind": "execute", "rawInput": {"command": "rm -rf build"}},
            "options": [
                {"optionId": "allow_once", "name": "Allow once", "kind": "allow_once"},
                {"optionId": "allow_always", "name": "Always allow", "kind": "allow_always"},
                {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"},
            ],
        }),
    );
    settle(cx);
    assert!(chat.rows(cx).iter().any(|r| matches!(r, TimelineRowContent::Approval(_))));
    let action = cx.update(|_, cx| {
        let composer = chat.view.read(cx).composer().clone();
        composer.read(cx).primary_action(cx)
    });
    assert_eq!(action, ComposerPrimaryAction::Stop);

    chat.type_text("Keep the build folder", cx);
    cx.simulate_keystrokes("enter");
    settle(cx);
    assert_eq!(
        chat.agent.answer(&id),
        Some(Ok(json!({"outcome": {"outcome": "selected", "optionId": "reject_once"}})))
    );
    assert!(chat.agent.sent_prompts().contains(&"_session/steering: Keep the build folder".to_owned()));
}

#[gpui::test]
fn a_question_takes_its_options_by_digit_and_submits_the_answer(cx: &mut TestAppContext) {
    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    chat.type_text("Pick a fix", cx);
    cx.simulate_keystrokes("enter");
    settle(cx);
    let id = chat.agent.ask(
        "elicitation/create",
        json!({
            "sessionId": "new-session",
            "message": "How should I fix it?",
            "mode": "form",
            "requestedSchema": {"type": "object", "properties": {
                "q0": {"type": "string", "title": "Which approach?", "description": "Fix approach",
                       "oneOf": [{"const": "Patch"}, {"const": "Rewrite"}]},
            }},
        }),
    );
    settle(cx);
    chat.focus_composer(cx);
    cx.simulate_keystrokes("2");
    settle(cx);
    assert_eq!(chat.composer_text(cx), "");
    cx.simulate_keystrokes("enter");
    settle(cx);
    assert_eq!(chat.agent.answer(&id), Some(Ok(json!({"action": "accept", "content": {"q0": "Rewrite"}}))));
}

#[gpui::test]
fn a_question_starts_on_its_default_option_and_return_submits_it(cx: &mut TestAppContext) {
    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    chat.type_text("Pick a fix", cx);
    cx.simulate_keystrokes("enter");
    settle(cx);
    let id = chat.agent.ask(
        "elicitation/create",
        json!({
            "sessionId": "new-session",
            "message": "The patch is smaller.",
            "mode": "form",
            "requestedSchema": {"type": "object", "properties": {
                "approach": {"type": "string", "title": "Which approach?", "default": "rewrite",
                             "oneOf": [{"const": "patch", "title": "Patch"}, {"const": "rewrite", "title": "Rewrite"}]},
            }},
        }),
    );
    settle(cx);
    chat.focus_composer(cx);
    cx.simulate_keystrokes("enter");
    settle(cx);
    assert_eq!(
        chat.agent.answer(&id),
        Some(Ok(json!({"action": "accept", "content": {"approach": "rewrite"}})))
    );
}

#[gpui::test]
fn a_default_names_an_option_by_its_value_even_when_another_option_has_that_label(cx: &mut TestAppContext) {
    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    chat.type_text("Pick one", cx);
    cx.simulate_keystrokes("enter");
    settle(cx);
    let id = chat.agent.ask(
        "elicitation/create",
        json!({
            "sessionId": "new-session",
            "message": "",
            "mode": "form",
            "requestedSchema": {"type": "object", "properties": {
                "pick": {"type": "string", "title": "Which?", "default": "b",
                         "oneOf": [{"const": "a", "title": "b"}, {"const": "b", "title": "Second"}]},
            }},
        }),
    );
    settle(cx);
    chat.focus_composer(cx);
    cx.simulate_keystrokes("enter");
    settle(cx);
    assert_eq!(chat.agent.answer(&id), Some(Ok(json!({"action": "accept", "content": {"pick": "b"}}))));
}

#[gpui::test]
fn slash_lists_the_agents_commands_and_tab_inserts_the_highlighted_one(cx: &mut TestAppContext) {
    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    chat.agent.send(json!({"sessionUpdate": "available_commands_update", "availableCommands": [
        {"name": "compact", "description": "Compact the conversation", "input": {"hint": "[focus]"}},
        {"name": "review", "description": "Look at a diff"},
    ]}));
    settle(cx);
    chat.type_text("/co", cx);
    let shown = cx.update(|_, cx| {
        let composer = chat.view.read(cx).composer().clone();
        composer.read(cx).shown_commands().into_iter().map(|c| c.name).collect::<Vec<_>>()
    });
    assert_eq!(shown, ["compact"]);
    cx.simulate_keystrokes("tab");
    cx.run_until_parked();
    assert_eq!(chat.composer_text(cx), "/compact ");

    // Escape hides the menu until the caret leaves the token.
    chat.type_text("\n/re", cx);
    cx.simulate_keystrokes("escape");
    cx.run_until_parked();
    let open = cx.update(|_, cx| {
        let composer = chat.view.read(cx).composer().clone();
        composer.read(cx).slash.is_some()
    });
    assert!(!open);
}

#[gpui::test]
fn queued_messages_can_be_removed_or_steered_in_from_the_timeline(cx: &mut TestAppContext) {
    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    chat.type_text("Work", cx);
    cx.simulate_keystrokes("enter");
    settle(cx);
    for text in ["Later", "Now"] {
        chat.type_text(text, cx);
        cx.simulate_keystrokes("enter");
        settle(cx);
    }
    let ids: Vec<String> = cx.update(|_, cx| {
        chat.view.read(cx).session().borrow().thread().queue.iter().map(|m| m.id.clone()).collect()
    });
    let timeline = cx.update(|_, cx| chat.view.read(cx).timeline().clone());
    cx.update(|_, cx| {
        timeline.update(cx, |timeline, cx| {
            assert!(timeline.can_send_queued_now());
            timeline.remove_queued(&ids[0], cx);
            timeline.send_queued_now(&ids[1], cx);
        })
    });
    settle(cx);
    assert!(chat.queued(cx).is_empty());
    assert!(chat.agent.sent_prompts().contains(&"_session/steering: Now".to_owned()));
}

fn transcript(turns: usize) -> ChatThread {
    let start = chrono::Utc::now() - chrono::Duration::hours(1);
    let mut items = Vec::new();
    for turn in 0..turns {
        let at = |s: i64| Some(start + chrono::Duration::seconds(turn as i64 * 120 + s));
        items.push(AgentTimelineItem::new(
            format!("p{turn}"),
            at(0),
            TimelineItemKind::Prompt(format!("Prompt {turn}")),
        ));
        let mut call = soprano_agents::AgentToolCall::new("Bash", "swift test");
        call.state = soprano_agents::ToolCallState::Succeeded;
        call.output = Some("passed".into());
        call.finished_at = at(20);
        items.push(AgentTimelineItem::new(format!("c{turn}"), at(5), TimelineItemKind::Tool(call)));
        let reply = (1..=8)
            .map(|n| format!("Paragraph {n} of the answer, long enough to take a line."))
            .collect::<Vec<_>>()
            .join("\n\n");
        items.push(AgentTimelineItem::new(format!("r{turn}"), at(40), TimelineItemKind::Reply(reply)));
    }
    ChatThread::from_transcript(&AgentTimeline::new(items), false)
}

#[gpui::test]
fn a_transcript_reads_as_the_timeline_with_prompt_jumps_and_following(cx: &mut TestAppContext) {
    cx.update(soprano_ui::init_for_tests);
    let source = TranscriptSource::new();
    source.set(transcript(3), "No conversation yet.");
    let shared = source.clone();
    let (timeline, cx) =
        cx.add_window_view(move |window, cx| TimelineView::new(shared, "Claude Code", window, cx));
    cx.run_until_parked();
    let users = timeline.read_with(cx, |t, _| t.rows().iter().filter(|r| r.is_turn_message()).count());
    assert_eq!(users, 3);
    assert!(timeline.read_with(cx, |t, _| t.is_following()));

    timeline.update(cx, |t, cx| t.set_detailed(false, cx));
    let folds: Vec<String> = timeline.read_with(cx, |t, _| {
        t.rows()
            .iter()
            .filter_map(|r| match &r.content {
                TimelineRowContent::Fold(fold) => Some(fold.label.clone()),
                _ => None,
            })
            .collect()
    });
    // Agents' minimal work log: each finished turn folded behind "Worked for …".
    assert_eq!(folds, ["Worked for 40s", "Worked for 40s", "Worked for 40s"]);
    assert!(timeline.read_with(cx, |t, _| {
        t.rows().iter().any(|r| matches!(r.content, TimelineRowContent::Assistant(_)))
    }));

    // The detailed work log opens the folds: the commands show.
    timeline.update(cx, |t, cx| t.set_detailed(true, cx));
    let commands = timeline.read_with(cx, |t, _| {
        t.rows()
            .iter()
            .filter(
                |r| matches!(&r.content, TimelineRowContent::WorkEntry(e) if e.entry.label == "Ran command"),
            )
            .count()
    });
    assert_eq!(commands, 3);

    timeline.update(cx, |t, cx| t.jump_to_message(-1, cx));
    cx.run_until_parked();
    assert!(!timeline.read_with(cx, |t, _| t.is_following()));
    timeline.update(cx, |t, cx| t.jump_to_latest(cx));
    cx.run_until_parked();
    assert!(timeline.read_with(cx, |t, _| t.is_following()));

    source.set(ChatThread::default(), "No conversation yet.");
    timeline.update(cx, |t, cx| t.reload(true, cx));
    assert!(matches!(
        timeline.read_with(cx, |t, _| t.rows()[0].content.clone()),
        TimelineRowContent::Empty(text) if text == "No conversation yet."
    ));
}

#[gpui::test]
fn wheel_scrolling_the_timeline_stops_following_without_crashing(cx: &mut TestAppContext) {
    cx.update(soprano_ui::init_for_tests);
    let source = TranscriptSource::new();
    source.set(transcript(6), "No conversation yet.");
    let shared = source.clone();
    let (timeline, cx) =
        cx.add_window_view(move |window, cx| TimelineView::new(shared, "Claude Code", window, cx));
    cx.run_until_parked();
    assert!(timeline.read_with(cx, |t, _| t.is_following()));
    let wheel = |y: f32| gpui::ScrollEvent {
        position: gpui::point(gpui::px(200.0), gpui::px(200.0)),
        delta: gpui::ScrollDelta::Pixels(gpui::point(gpui::px(0.0), gpui::px(y))),
        ..Default::default()
    };
    // Up: away from the end (the list's scroll callback must not read the list again).
    let events: Rc<RefCell<Vec<crate::TimelineEvent>>> = Rc::default();
    let recorded = events.clone();
    cx.update(|_, cx| {
        cx.subscribe(&timeline, move |_, event: &crate::TimelineEvent, _| {
            recorded.borrow_mut().push(event.clone())
        })
        .detach();
    });
    for _ in 0..5 {
        cx.simulate_event(wheel(2_000.0));
        cx.run_until_parked();
    }
    assert!(events.borrow().contains(&crate::TimelineEvent::FollowingChanged(false)));
    assert!(!timeline.read_with(cx, |t, _| t.is_following()));
    // Down far past the end: following again.
    cx.simulate_event(wheel(-100_000.0));
    cx.run_until_parked();
    assert!(timeline.read_with(cx, |t, _| t.is_following()));
}

#[gpui::test]
fn stop_with_a_typed_answer_on_screen_stops_the_turn_instead_of_answering(cx: &mut TestAppContext) {
    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    chat.type_text("Pick a fix", cx);
    cx.simulate_keystrokes("enter");
    settle(cx);
    let id = chat.agent.ask(
        "elicitation/create",
        json!({
            "sessionId": "new-session",
            "message": "How should I fix it?",
            "requestedSchema": {"type": "object", "properties": {
                "q0": {"type": "string", "title": "Which approach?", "oneOf": [{"const": "Patch"}]},
                "q0__other": {"type": "string"},
            }},
        }),
    );
    settle(cx);
    chat.type_text("My own fix", cx);
    let composer = cx.update(|_, cx| chat.view.read(cx).composer().clone());
    cx.update(|window, cx| {
        composer.update(cx, |composer, cx| {
            composer.primary_clicked(ComposerPrimaryAction::Stop, false, window, cx)
        })
    });
    settle(cx);
    assert_eq!(
        chat.agent.state().notifications.iter().map(|n| n.0.clone()).collect::<Vec<_>>(),
        ["session/cancel"]
    );
    assert_ne!(
        chat.agent.answer(&id),
        Some(Ok(json!({"action": "accept", "content": {"q0__other": "My own fix"}})))
    );
}

#[gpui::test]
fn a_chip_closes_its_own_popover_and_the_editor_gets_the_keyboard_back(cx: &mut TestAppContext) {
    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    let composer = cx.update(|_, cx| chat.view.read(cx).composer().clone());
    cx.update(|window, cx| {
        composer.update(cx, |c, cx| c.toggle_popover(crate::PopoverKind::Model, window, cx))
    });
    cx.run_until_parked();
    assert!(composer.read_with(cx, |c, _| c.popover.is_some()));
    cx.update(|window, cx| {
        composer.update(cx, |c, cx| c.toggle_popover(crate::PopoverKind::Model, window, cx))
    });
    cx.run_until_parked();
    assert!(composer.read_with(cx, |c, _| c.popover.is_none()));
    let focused =
        cx.update(|window, cx| gpui::Focusable::focus_handle(composer.read(cx), cx).is_focused(window));
    assert!(focused);
}

#[gpui::test]
fn a_narrow_pane_still_picks_the_thinking_level_from_its_glyph(cx: &mut TestAppContext) {
    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    cx.simulate_resize(gpui::size(px(400.), px(700.)));
    settle(cx);
    // The composer takes the width the chat was painted at on its next render.
    cx.update(|_, cx| chat.view.update(cx, |_, cx| cx.notify()));
    settle(cx);
    let composer = cx.update(|_, cx| chat.view.read(cx).composer().clone());
    assert!(composer.read_with(cx, |c, _| c.chip_compaction()) >= 1, "the composer is laid out narrow");

    let chip = composer.read_with(cx, |c, _| c.anchors.traits.get());
    assert!(chip.size.width > px(0.), "the thinking chip is on screen");
    cx.simulate_click(chip.center(), Modifiers::none());
    cx.run_until_parked();
    assert_eq!(
        composer.read_with(cx, |c, _| c.popover.as_ref().map(|p| p.kind)),
        Some(crate::PopoverKind::Traits)
    );

    cx.simulate_keystrokes("down enter");
    settle(cx);
    let picked = chat.agent.state().requests.iter().any(|(method, params)| {
        method == "session/set_config_option" && params["configId"] == "thinking" && params["value"] == "high"
    });
    assert!(picked, "the pick reaches the agent");
}

#[gpui::test]
fn the_keyboard_in_a_popover_or_the_conversation_is_still_in_the_chat(cx: &mut TestAppContext) {
    // The app puts the keyboard back on a pane's content whenever the workspace changes, which
    // a working agent causes several times a second: a chat whose model picker or conversation
    // has the keyboard must count as having it, or what is typed there lands in the composer.
    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    cx.simulate_resize(gpui::size(px(1000.), px(700.)));
    settle(cx);
    let in_chat =
        |cx: &mut VisualTestContext| cx.update(|window, cx| chat.view.read(cx).contains_focused(window, cx));
    let in_editor = |cx: &mut VisualTestContext| {
        cx.update(|window, cx| {
            use gpui::Focusable as _;
            chat.view.read(cx).focus_handle(cx).contains_focused(window, cx)
        })
    };
    chat.focus_composer(cx);
    assert!(in_chat(cx) && in_editor(cx));

    let composer = cx.update(|_, cx| chat.view.read(cx).composer().clone());
    cx.update(|window, cx| {
        composer.update(cx, |c, cx| c.toggle_popover(crate::PopoverKind::Model, window, cx))
    });
    cx.run_until_parked();
    assert!(!in_editor(cx));
    assert!(in_chat(cx));
    cx.simulate_keystrokes("escape");
    cx.run_until_parked();

    cx.simulate_click(point(px(500.), px(200.)), Modifiers::none());
    cx.run_until_parked();
    assert!(!in_editor(cx));
    assert!(in_chat(cx));
}

#[gpui::test]
fn opening_a_step_during_a_running_turn_keeps_following(cx: &mut TestAppContext) {
    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    chat.type_text("Build it", cx);
    cx.simulate_keystrokes("enter");
    settle(cx);
    chat.agent.send(json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "name": "bash", "title": "$ make", "status": "completed",
        "rawInput": {"command": "make"}, "rawOutput": {"content": [{"type": "text", "text": "ok"}], "details": {"exitCode": 0}}}));
    settle(cx);
    let timeline = cx.update(|_, cx| chat.view.read(cx).timeline().clone());
    assert!(timeline.read_with(cx, |t, _| t.is_following()));
    let entry = timeline.read_with(cx, |t, _| {
        t.rows().iter().find_map(|r| match &r.content {
            TimelineRowContent::WorkEntry(model) => Some(model.entry.id.clone()),
            _ => None,
        })
    });
    let entry = entry.expect("the command's entry");
    timeline.update(cx, |t, cx| t.toggle(crate::rows::ExpansionSet::Entries, &entry, cx));
    cx.run_until_parked();
    assert!(timeline.read_with(cx, |t, _| t.is_following()));
}

#[gpui::test]
fn the_slash_menu_highlights_commands_that_arrive_after_typing_slash(cx: &mut TestAppContext) {
    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    chat.type_text("/", cx);
    let composer = cx.update(|_, cx| chat.view.read(cx).composer().clone());
    assert_eq!(composer.read_with(cx, |c, _| c.slash.as_ref().and_then(|m| m.highlighted)), None);
    chat.agent.send(json!({"sessionUpdate": "available_commands_update", "availableCommands": [
        {"name": "compact", "description": "Compact the conversation"},
    ]}));
    settle(cx);
    assert_eq!(composer.read_with(cx, |c, _| c.slash.as_ref().and_then(|m| m.highlighted)), Some(0));
    cx.simulate_keystrokes("enter");
    cx.run_until_parked();
    assert_eq!(chat.composer_text(cx), "/compact ");
    assert!(chat.agent.sent_prompts().is_empty());
}

#[gpui::test]
fn the_pointer_over_the_work_log_shows_its_times_and_the_chat_stays_up(cx: &mut TestAppContext) {
    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    cx.update(|window, cx| chat.view.update(cx, |view, cx| view.submit_prompt("Read the notes", window, cx)));
    settle(cx);
    for (id, path) in [("call-1", "skill://valkental"), ("call-2", "skill://brief")] {
        chat.agent.send(json!({
            "sessionUpdate": "tool_call", "toolCallId": id, "title": format!("Reading {path}"),
            "kind": "read", "status": "pending", "rawInput": {"path": path},
        }));
        chat.agent.send(json!({
            "sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": "Notes"}}],
        }));
    }
    settle(cx);
    let work_rows = |chat: &Chat, cx: &mut VisualTestContext| {
        chat.rows(cx)
            .iter()
            .filter(|row| matches!(row, TimelineRowContent::WorkGroup(_) | TimelineRowContent::WorkEntry(_)))
            .count()
    };
    let shown = work_rows(&chat, cx);
    assert!(shown > 0, "{:?}", chat.rows(cx));

    // Down the conversation, a few points apart: every row is under the pointer once, which
    // shows what it keeps for hovering (a work log line's time).
    let size = cx.update(|window, _| window.viewport_size());
    let mut y = px(0.);
    while y < size.height {
        cx.simulate_mouse_move(point(size.width / 2., y), None, Modifiers::none());
        cx.update(|window, cx| window.draw(cx).clear(cx));
        y += px(6.);
    }
    assert_eq!(work_rows(&chat, cx), shown);
}

#[gpui::test]
fn a_click_into_the_composer_over_the_conversation_gives_it_the_keyboard(cx: &mut TestAppContext) {
    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    cx.simulate_resize(gpui::size(px(1000.), px(700.)));
    settle(cx);
    chat.type_text("hi", cx);
    // Somewhere else first: the conversation takes the keyboard for its own keys.
    cx.simulate_click(point(px(500.), px(200.)), Modifiers::none());
    cx.run_until_parked();
    chat.events.borrow_mut().clear();

    // The timeline ends cleanly above the composer rather than scrolling under it.
    let (timeline_bottom, surface) = cx.update(|_, cx| {
        let timeline = chat.view.read(cx).timeline().read(cx);
        let surface = chat.view.read(cx).composer().read(cx).anchors.surface.get();
        (timeline.list.viewport_bounds().bottom(), surface)
    });
    assert!(
        timeline_bottom <= surface.origin.y,
        "timeline ({timeline_bottom:?}) must stop above composer ({:?})",
        surface.origin.y
    );
    cx.simulate_click(point(surface.origin.x + px(60.), surface.origin.y + px(28.)), Modifiers::none());
    cx.run_until_parked();
    let focused = cx.update(|window, cx| {
        use gpui::Focusable as _;
        let editor = chat.view.read(cx).composer().read(cx).editor.clone();
        editor.focus_handle(cx).contains_focused(window, cx)
    });
    assert!(focused);
    // The click still makes its pane the active one.
    assert!(matches!(chat.events.borrow().as_slice(), [ChatViewEvent::FocusRequested]));

    // Keys that are not letters reach the editor too.
    cx.write_to_clipboard(gpui::ClipboardItem::new_string(" there".into()));
    cx.simulate_keystrokes("cmd-v");
    assert_eq!(chat.composer_text(cx), "hi there");
    cx.simulate_keystrokes("backspace enter");
    settle(cx);
    assert_eq!(chat.agent.sent_prompts(), ["session/prompt: hi ther"]);
}

#[gpui::test]
fn chat_zoom_scales_both_composer_text_and_timeline_messages(cx: &mut TestAppContext) {
    use soprano_ui::SopranoTheme;
    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    cx.simulate_resize(gpui::size(px(1000.), px(700.)));
    cx.update(|window, cx| {
        chat.view.update(cx, |view, cx| view.submit_prompt("Hello world from user", window, cx))
    });
    settle(cx);
    chat.agent.send(json!({
        "sessionUpdate": "agent_message_chunk",
        "content": {"type": "text", "text": "Hello back from assistant with **bold** text."}
    }));
    chat.agent.end_turn();
    settle(cx);
    chat.type_text("Please check if the issue is real", cx);
    cx.update(|window, cx| window.draw(cx).clear(cx));

    let measure = |cx: &mut VisualTestContext| {
        cx.update(|window, cx| {
            use gpui::EntityInputHandler as _;
            let composer = chat.view.read(cx).composer().clone();
            let editor = composer.read(cx).editor.clone();
            let surface = composer.read(cx).anchors.surface.get();
            let lh = editor.read(cx).line_height();
            let input_bounds = editor.read(cx).input_bounds();
            let bounds =
                editor.update(cx, |state, cx| state.bounds_for_range(0..6, input_bounds, window, cx));
            let timeline = chat.view.read(cx).timeline().clone();
            let list_bounds = timeline.read(cx).list.bounds_for_item(0);
            let assistant_bounds = timeline.read(cx).list.bounds_for_item(1);
            (surface, lh, bounds, list_bounds, assistant_bounds)
        })
    };

    let (_surf1, lh1, glyph1, row0_1, row1_1) = measure(cx);

    cx.update(|_, cx| SopranoTheme::set_chat_zoom(2.0, cx));
    cx.run_until_parked();
    cx.update(|window, cx| window.draw(cx).clear(cx));
    cx.update(|window, cx| window.draw(cx).clear(cx));

    let (_surf2, lh2, glyph2, row0_2, row1_2) = measure(cx);

    assert!(lh2.unwrap() > lh1.unwrap() * 1.5, "line height did not scale: {lh1:?} -> {lh2:?}");
    let w1 = glyph1.unwrap().size.width;
    let w2 = glyph2.unwrap().size.width;
    assert!(w2 > w1 * 1.5, "typed glyph width did not scale: {w1:?} -> {w2:?}");
    let h1 = row0_1.unwrap().size.height;
    let h2 = row0_2.unwrap().size.height;
    assert!(h2 > h1 * 1.5, "user message row height did not scale: {h1:?} -> {h2:?}");
    let a1 = row1_1.unwrap().size.height;
    let a2 = row1_2.unwrap().size.height;
    assert!(a2 > a1 * 1.5, "assistant message row height did not scale: {a1:?} -> {a2:?}");
}

fn paste_clipboard(cx: &mut VisualTestContext, clipboard: gpui::ClipboardItem) {
    cx.write_to_clipboard(clipboard);
    cx.simulate_keystrokes(if cfg!(target_os = "macos") { "cmd-v" } else { "ctrl-v" });
    cx.run_until_parked();
}

#[gpui::test]
fn files_dropped_onto_the_chat_composer_or_timeline_are_attached_and_sent(cx: &mut TestAppContext) {
    use gpui::{ExternalPaths, FileDropEvent, Focusable as _};
    use soprano_platform::shell::path_word;

    use crate::attachments::Attachment;

    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    cx.simulate_resize(gpui::size(px(1000.), px(700.)));
    settle(cx);
    // Focus outside the composer first.
    cx.simulate_click(point(px(500.), px(200.)), Modifiers::none());
    cx.run_until_parked();
    chat.events.borrow_mut().clear();

    // Drop a screenshot onto the composer card.
    let composer_pos = cx.debug_bounds("chat-composer-card").expect("composer card bounds").center();
    let shot = PathBuf::from("/tmp/shots/Screen Shot 1.png");
    cx.simulate_event(FileDropEvent::Entered {
        position: composer_pos,
        paths: ExternalPaths(vec![shot.clone()].into()),
    });
    cx.simulate_event(FileDropEvent::Submit { position: composer_pos });
    cx.run_until_parked();

    let attached = cx.update(|_, cx| chat.view.read(cx).composer().read(cx).attachments().to_vec());
    assert_eq!(attached, [Attachment::file(&shot)]);
    assert!(cx.debug_bounds("chat-composer-attachments").is_some());
    let focused = cx.update(|window, cx| {
        let editor = chat.view.read(cx).composer().read(cx).editor.clone();
        editor.focus_handle(cx).contains_focused(window, cx)
    });
    assert!(focused);
    assert!(chat.events.borrow().contains(&ChatViewEvent::FocusRequested));

    // Dropping another file on the timeline above the composer also attaches it (deduplicating
    // duplicates).
    let timeline_pos = point(px(500.), px(120.));
    let notes = PathBuf::from("/tmp/shots/notes.md");
    cx.simulate_event(FileDropEvent::Entered {
        position: timeline_pos,
        paths: ExternalPaths(vec![shot.clone(), notes.clone()].into()),
    });
    cx.simulate_event(FileDropEvent::Submit { position: timeline_pos });
    cx.run_until_parked();

    let attached = cx.update(|_, cx| chat.view.read(cx).composer().read(cx).attachments().to_vec());
    assert_eq!(attached, [Attachment::file(&shot), Attachment::file(&notes)]);

    // Pressing Return with only attachments (no text) sends their paths and clears the shelf.
    cx.simulate_keystrokes("enter");
    settle(cx);
    assert_eq!(
        chat.agent.sent_prompts(),
        [format!("session/prompt: {} {}", path_word(&shot), path_word(&notes))]
    );
    let attached = cx.update(|_, cx| chat.view.read(cx).composer().read(cx).attachments().to_vec());
    assert!(attached.is_empty());
}

#[gpui::test]
fn pasted_images_and_files_in_the_chat_composer_become_attachments(cx: &mut TestAppContext) {
    use gpui::{ClipboardEntry, ClipboardItem, ExternalPaths, Image, ImageFormat};
    use soprano_platform::shell::path_word;

    let (chat, cx) = open_chat(cx);
    let folder = tempfile::tempdir().expect("attachments folder");
    cx.update(|_, cx| chat.view.update(cx, |view, cx| view.set_attachments_dir(folder.path(), cx)));
    chat.start(cx);
    cx.simulate_resize(gpui::size(px(1000.), px(700.)));
    settle(cx);
    cx.update(|window, cx| chat.view.update(cx, |view, cx| view.focus_composer(window, cx)));
    cx.run_until_parked();

    // Paste two screenshots: both are stored as files under the attachments folder.
    let shot = ClipboardItem::new_image(&Image::from_bytes(ImageFormat::Png, b"a screenshot".to_vec()));
    paste_clipboard(cx, shot.clone());
    paste_clipboard(cx, shot);
    let pasted = cx.update(|_, cx| chat.view.read(cx).composer().read(cx).attachments().to_vec());
    assert_eq!(pasted.len(), 2);
    assert!(pasted.iter().all(|a| a.pasted && a.path.starts_with(folder.path())));
    assert_eq!(std::fs::read(&pasted[1].path).expect("pasted image"), b"a screenshot");

    // Removing the first deletes its temporary file; the second remains.
    cx.update(|_, cx| {
        let composer = chat.view.read(cx).composer().clone();
        composer.update(cx, |composer, cx| composer.remove_attachment(0, cx));
    });
    assert!(!pasted[0].path.exists());
    assert!(pasted[1].path.exists());

    // Copied files paste as attachments too; plain text still pastes into the editor.
    let copied_file = folder.path().join("report.txt");
    paste_clipboard(
        cx,
        ClipboardItem {
            entries: vec![ClipboardEntry::ExternalPaths(ExternalPaths(vec![copied_file.clone()].into()))],
        },
    );
    paste_clipboard(cx, ClipboardItem::new_string("Please check this".into()));
    assert_eq!(chat.composer_text(cx), "Please check this");

    cx.simulate_keystrokes("enter");
    settle(cx);
    assert_eq!(
        chat.agent.sent_prompts(),
        [format!(
            "session/prompt: Please check this\n{} {}",
            path_word(&pasted[1].path),
            path_word(&copied_file)
        )]
    );
    // Sent pasted image stays on disk for the agent to read.
    assert!(pasted[1].path.exists());

    // Unsent pasted image is cleaned up when the chat closes.
    let unsent_shot = ClipboardItem::new_image(&Image::from_bytes(ImageFormat::Png, b"unsent".to_vec()));
    paste_clipboard(cx, unsent_shot);
    let unsent = cx.update(|_, cx| chat.view.read(cx).composer().read(cx).attachments().to_vec());
    assert_eq!(unsent.len(), 1);
    assert!(unsent[0].path.exists());
    cx.update(|_, cx| chat.view.update(cx, |view, cx| view.close(cx)));
    assert!(!unsent[0].path.exists());
}

#[gpui::test]
fn at_mentions_list_project_files_and_tab_inserts_the_highlighted_path(cx: &mut TestAppContext) {
    let (chat, cx) = open_chat(cx);
    chat.start(cx);
    cx.simulate_resize(gpui::size(px(1000.), px(700.)));
    settle(cx);

    cx.update(|_, cx| {
        let composer = chat.view.read(cx).composer().clone();
        composer.update(cx, |composer, cx| {
            composer.set_project_files(
                vec![
                    "README.md".into(),
                    "crates/soprano-chat-ui/src/composer.rs".into(),
                    "crates/soprano-chat-ui/src/mentions.rs".into(),
                ],
                cx,
            );
        });
    });

    // Orca-style attach button and context bar are rendered.
    assert!(cx.debug_bounds("composer-attach").is_some());
    assert!(cx.debug_bounds("chat-composer-context").is_some());

    chat.type_text("Look at @comp", cx);
    cx.run_until_parked();
    assert!(cx.debug_bounds("composer-mention-menu").is_some());

    cx.simulate_keystrokes("tab");
    cx.run_until_parked();
    assert_eq!(chat.composer_text(cx), "Look at @crates/soprano-chat-ui/src/composer.rs ");
    assert!(cx.debug_bounds("composer-mention-menu").is_none());

    // Escape dismisses an open `@` menu without clearing the typed text.
    chat.type_text("@ment", cx);
    cx.run_until_parked();
    assert!(cx.debug_bounds("composer-mention-menu").is_some());
    cx.simulate_keystrokes("escape");
    cx.run_until_parked();
    assert!(cx.debug_bounds("composer-mention-menu").is_none());
    assert_eq!(chat.composer_text(cx), "Look at @crates/soprano-chat-ui/src/composer.rs @ment");
}

#[gpui::test]
fn branch_switcher_filters_blocks_dirty_trees_and_checks_out_on_enter(cx: &mut TestAppContext) {
    use soprano_git::{BranchInfo, BranchList};

    cx.update(soprano_ui::init_for_tests);
    let Some(git_bin) = soprano_git::reader::executable() else { return };
    let temp = tempfile::tempdir().expect("tempdir");
    let root = temp.path();
    let run_git = |args: &[&str]| {
        let status =
            std::process::Command::new(git_bin).arg("-C").arg(root).args(args).status().expect("git");
        assert!(status.success(), "git {args:?} failed");
    };
    run_git(&["init", "-q", "-b", "main"]);
    std::fs::write(root.join("README.md"), "hello\n").expect("write");
    run_git(&["add", "."]);
    run_git(&[
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@t",
        "-c",
        "commit.gpgsign=false",
        "-c",
        "core.hooksPath=/dev/null",
        "commit",
        "-qm",
        "init",
    ]);
    run_git(&["branch", "feat/switch-me"]);

    // 1. Dirty working tree: pressing Enter on another branch must NOT switch.
    let dirty_list = BranchList {
        current_branch: Some("main".into()),
        changed_files: 3,
        branches: vec![
            BranchInfo {
                name: "main".into(),
                is_current: true,
                committer_timestamp: Some(200),
                worktree_path: None,
            },
            BranchInfo {
                name: "feat/switch-me".into(),
                is_current: false,
                committer_timestamp: Some(100),
                worktree_path: None,
            },
        ],
    };
    let events: Rc<RefCell<Vec<crate::BranchSwitcherEvent>>> = Rc::default();
    let root_path = root.to_path_buf();
    let (dirty_switcher, cx_dirty) = cx.add_window_view(move |window, cx| {
        crate::BranchSwitcher::with_branches(root_path, gpui::Bounds::default(), true, dirty_list, window, cx)
    });
    let recorded = events.clone();
    cx_dirty.update(|_, cx| {
        cx.subscribe(&dirty_switcher, move |_, event: &crate::BranchSwitcherEvent, _| {
            recorded.borrow_mut().push(event.clone());
        })
        .detach();
    });
    cx_dirty.run_until_parked();
    cx_dirty.simulate_keystrokes("down enter");
    cx_dirty.run_until_parked();
    assert!(events.borrow().is_empty(), "dirty tree must block branch switch");
    assert_eq!(soprano_git::branch::current_branch(&root.to_string_lossy()).as_deref(), Some("main"));

    // 2. Clean working tree: filter by query and press Enter to switch branch.
    let clean_list = soprano_git::reader::branches(root).expect("branches");
    assert_eq!(clean_list.changed_files, 0);
    let events2: Rc<RefCell<Vec<crate::BranchSwitcherEvent>>> = Rc::default();
    let root_path2 = root.to_path_buf();
    let (switcher, cx_clean) = cx.add_window_view(move |window, cx| {
        crate::BranchSwitcher::with_branches(
            root_path2,
            gpui::Bounds::default(),
            true,
            clean_list,
            window,
            cx,
        )
    });
    let recorded2 = events2.clone();
    cx_clean.update(|_, cx| {
        cx.subscribe(&switcher, move |_, event: &crate::BranchSwitcherEvent, _| {
            recorded2.borrow_mut().push(event.clone());
        })
        .detach();
    });
    cx_clean.run_until_parked();
    switcher.update_in(cx_clean, |s, window, cx| {
        s.search_input().update(cx, |input, cx| input.set_value("switch", window, cx));
    });
    cx_clean.run_until_parked();
    let shown: Vec<String> =
        switcher.read_with(cx_clean, |s, cx| s.shown_branches(cx).into_iter().map(|b| b.name).collect());
    assert_eq!(shown, ["feat/switch-me"]);

    cx_clean.simulate_keystrokes("enter");
    cx_clean.run_until_parked();
    assert_eq!(events2.borrow().as_slice(), &[crate::BranchSwitcherEvent::Switched("feat/switch-me".into())]);
    assert_eq!(
        soprano_git::branch::current_branch(&root.to_string_lossy()).as_deref(),
        Some("feat/switch-me")
    );
}

#[gpui::test]
fn sent_attachments_render_as_timeline_thumbnails_and_chips_instead_of_raw_paths(cx: &mut TestAppContext) {
    let (chat, cx) = open_chat(cx);
    let folder = tempfile::tempdir().expect("attachments folder");
    let shot = folder.path().join("preview.png");
    let notes = folder.path().join("notes.md");
    std::fs::write(&shot, b"fake png bytes").expect("shot");
    std::fs::write(&notes, "# Notes\n").expect("notes");

    chat.start(cx);
    cx.simulate_resize(gpui::size(px(1000.), px(700.)));
    settle(cx);

    cx.update(|window, cx| {
        chat.view.update(cx, |view, cx| {
            view.attach_files([shot.clone(), notes.clone()], window, cx);
            view.focus_composer(window, cx);
        });
    });
    cx.run_until_parked();
    cx.simulate_keystrokes("enter");
    settle(cx);

    assert!(
        cx.debug_bounds("user-message-attachments").is_some(),
        "sent attachments should render in the timeline attachment strip"
    );
}
