//! The chat's views driven headlessly: a fake agent stands in for omp (`FakeACPAgent` of the
//! Swift tests), keys and clicks go through GPUI's test window.

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use gpui::{AppContext as _, Entity, TestAppContext, VisualTestContext};
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
