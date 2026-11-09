//! What a timeline shows and answers to (`ChatTimelineSource`): a chat tab's
//! [`AgentChatSession`], or the Agent Dashboard's read-only view of a terminal agent's
//! transcript ([`TranscriptSource`]).

use std::cell::RefCell;
use std::rc::Rc;

use soprano_agents::ChatThread;
use soprano_chat::{AgentChatSession, ChatPhase};

pub trait TimelineSource: 'static {
    fn thread(&self) -> ChatThread;
    /// What the timeline says while the conversation has no turns.
    fn empty_timeline_text(&self, agent_name: &str) -> String;
    /// A queued message can be steered into the running turn.
    fn can_send_queued_now(&self) -> bool {
        false
    }
    fn choose_permission_option(&self, _option_id: &str) {}
    fn send_queued_prompt_now(&self, _id: &str) {}
    fn remove_queued_prompt(&self, _id: &str) {}
}

/// The chat tab's session as the timeline reads it.
pub type SharedSession = Rc<RefCell<AgentChatSession>>;

/// [`TimelineSource`] over a chat tab's session.
pub struct SessionSource(pub SharedSession);

impl TimelineSource for SessionSource {
    fn thread(&self) -> ChatThread {
        self.0.borrow().thread()
    }

    fn empty_timeline_text(&self, agent_name: &str) -> String {
        session_empty_text(*self.0.borrow().phase() == ChatPhase::Starting, agent_name)
    }

    fn can_send_queued_now(&self) -> bool {
        let session = self.0.borrow();
        *session.phase() == ChatPhase::Working && session.supports_steering()
    }

    fn choose_permission_option(&self, option_id: &str) {
        self.0.borrow_mut().choose_permission_option(option_id);
    }

    fn send_queued_prompt_now(&self, id: &str) {
        self.0.borrow_mut().send_queued_prompt_now(id);
    }

    fn remove_queued_prompt(&self, id: &str) {
        self.0.borrow_mut().remove_queued_prompt(id);
    }
}

/// "Starting omp…" while the agent starts, else the invitation to write.
pub fn session_empty_text(starting: bool, agent_name: &str) -> String {
    if starting {
        format!("Starting {agent_name}…")
    } else {
        "Send a message to start the conversation.".into()
    }
}

/// A read-only thread (the dashboard's `DashTranscriptSource`): no approvals and no queue.
#[derive(Default)]
pub struct TranscriptSource {
    thread: RefCell<ChatThread>,
    empty_text: RefCell<String>,
}

impl TranscriptSource {
    pub fn new() -> Rc<Self> {
        Rc::new(Self::default())
    }

    /// Replaces what the timeline shows; reload the timeline afterwards.
    pub fn set(&self, thread: ChatThread, empty_text: impl Into<String>) {
        *self.thread.borrow_mut() = thread;
        *self.empty_text.borrow_mut() = empty_text.into();
    }
}

impl TimelineSource for TranscriptSource {
    fn thread(&self) -> ChatThread {
        self.thread.borrow().clone()
    }

    fn empty_timeline_text(&self, _agent_name: &str) -> String {
        self.empty_text.borrow().clone()
    }
}
