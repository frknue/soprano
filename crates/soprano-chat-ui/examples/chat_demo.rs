//! A chat tab over a fake agent that replays a recorded ACP log (`chat_demo.acp.jsonl`) for
//! every prompt: thinking, reads, a search, an edit, a write, an approval, a command, a plan,
//! commands for the `/` menu, the answer and the context usage.
//!
//! `cargo run -p soprano-chat-ui --example chat_demo`

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use gpui::{App, AppContext as _, Bounds, WindowBounds, WindowOptions, px, size};
use serde_json::{Value, json};
use soprano_chat::{
    AcpToolStyle, AgentChatLaunch, AgentChatSession, JsonRpcError, JsonRpcPeer, LaunchSpec, PeerEvent,
    PeerSink,
};
use soprano_chat_ui::ChatView;
use soprano_ui::theme::AppearancePreference;

const RECORDING: &str = include_str!("chat_demo.acp.jsonl");
/// Pause between replayed messages, so the timeline streams.
const STEP: Duration = Duration::from_millis(350);

#[derive(Default)]
struct State {
    sink: Option<PeerSink>,
    next_id: u64,
    /// The permission request waiting for its answer, by our id for it.
    waiting: Option<(Value, usize, u64)>,
    exited: bool,
}

/// Answers the session's setup itself and replays the recording for each prompt; a recorded
/// permission request pauses the replay until the person answers it.
#[derive(Clone, Default)]
struct ReplayAgent(Arc<Mutex<State>>);

impl ReplayAgent {
    fn send(&self, event: PeerEvent) {
        if let Some(sink) = self.0.lock().ok().and_then(|s| s.sink.clone()) {
            sink.send(event);
        }
    }

    /// Plays the recording from `start` for the prompt with request id `prompt`.
    fn replay(&self, start: usize, prompt: u64) {
        let agent = self.clone();
        thread::spawn(move || {
            for (index, line) in RECORDING.lines().enumerate().skip(start) {
                thread::sleep(STEP);
                let Ok(message) = serde_json::from_str::<Value>(line) else { continue };
                if agent.0.lock().map(|s| s.exited).unwrap_or(true) {
                    return;
                }
                if let Some(method) = message.get("method").and_then(Value::as_str) {
                    let params = message.get("params").cloned().unwrap_or(Value::Null);
                    match message.get("id") {
                        Some(id) => {
                            if let Ok(mut state) = agent.0.lock() {
                                state.waiting = Some((id.clone(), index + 1, prompt));
                            }
                            agent.send(PeerEvent::Request { id: id.clone(), method: method.into(), params });
                            return;
                        }
                        None => agent.send(PeerEvent::Notification { method: method.into(), params }),
                    }
                } else if let Some(result) = message.get("result") {
                    agent.send(PeerEvent::Response { id: prompt, result: Ok(result.clone()) });
                }
            }
        });
    }
}

impl JsonRpcPeer for ReplayAgent {
    fn start(&mut self, sink: PeerSink) -> std::io::Result<()> {
        if let Ok(mut state) = self.0.lock() {
            state.sink = Some(sink);
        }
        Ok(())
    }

    fn request(&mut self, method: &str, _params: Value) -> Result<u64, JsonRpcError> {
        let id = {
            let mut state = self.0.lock().map_err(|_| JsonRpcError::closed())?;
            if state.exited {
                return Err(JsonRpcError::closed());
            }
            state.next_id += 1;
            state.next_id
        };
        let result = match method {
            "initialize" => json!({
                "protocolVersion": 1,
                "agentCapabilities": {"loadSession": true},
                "_meta": {"steering": {"supported": true}},
            }),
            "session/new" | "session/load" => json!({"sessionId": "demo", "configOptions": [
                {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "anthropic/claude-opus-5-5",
                 "options": [
                    {"value": "anthropic/claude-opus-5-5", "name": "Claude Opus 5.5"},
                    {"value": "anthropic/claude-sonnet-5", "name": "Claude Sonnet 5"},
                    {"value": "openai/gpt-6", "name": "GPT-6"},
                 ]},
                {"id": "thinking", "name": "Thinking", "category": "thought_level", "type": "select", "currentValue": "high",
                 "options": [
                    {"value": "low", "name": "low", "description": "Quick answers"},
                    {"value": "medium", "name": "medium"},
                    {"value": "high", "name": "high", "description": "Think it through"},
                 ]},
                {"id": "mode", "name": "Mode", "category": "mode", "type": "select", "currentValue": "default",
                 "options": [
                    {"value": "default", "name": "Default", "description": "Ask before commands"},
                    {"value": "plan", "name": "Plan"},
                 ]},
            ]}),
            "session/prompt" => {
                self.replay(0, id);
                return Ok(id);
            }
            _ => json!({}),
        };
        self.send(PeerEvent::Response { id, result: Ok(result) });
        Ok(id)
    }

    fn notify(&mut self, _method: &str, _params: Value) {}

    fn reply(&mut self, id: Value, _result: Result<Value, JsonRpcError>) {
        let waiting = self.0.lock().ok().and_then(|mut s| s.waiting.take_if(|w| w.0 == id));
        if let Some((_, resume, prompt)) = waiting {
            self.replay(resume, prompt);
        }
    }

    fn terminate(&mut self) {
        let sink = self.0.lock().ok().and_then(|mut state| {
            state.exited = true;
            state.sink.clone()
        });
        if let Some(sink) = sink {
            sink.send(PeerEvent::Exit { status: 0, stderr: String::new() });
        }
    }

    fn has_exited(&self) -> bool {
        self.0.lock().map(|s| s.exited).unwrap_or(true)
    }
}

fn main() {
    gpui_platform::application()
        .with_assets(soprano_ui::SopranoAssets::new(concat!(env!("CARGO_MANIFEST_DIR"), "/../../resources")))
        .run(|cx: &mut App| {
            soprano_ui::init(cx, "folio", AppearancePreference::System);
            let bounds = Bounds::centered(None, size(px(900.), px(760.)), cx);
            cx.open_window(
                WindowOptions { window_bounds: Some(WindowBounds::Windowed(bounds)), ..Default::default() },
                |window, cx| {
                    let launch = AgentChatLaunch {
                        profile_id: "omp".into(),
                        agent_name: "omp".into(),
                        spec: LaunchSpec {
                            argv: vec!["omp".into(), "acp".into()],
                            cwd: PathBuf::from("/work/shop"),
                            env: Vec::new(),
                        },
                        tool_style: AcpToolStyle::Omp,
                    };
                    let session = AgentChatSession::with_peer_factory(
                        launch,
                        Box::new(|_| Box::new(ReplayAgent::default()) as Box<dyn JsonRpcPeer>),
                    );
                    let chat = cx.new(|cx| {
                        let mut chat = ChatView::new(session, "omp", window, cx);
                        chat.start(None, window, cx);
                        chat
                    });
                    cx.new(|cx| gpui_component::Root::new(chat, window, cx))
                },
            )
            .expect("window opens");
            cx.activate(true);
        });
}
