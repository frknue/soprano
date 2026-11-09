//! Runtime state of an agent attached to a pane tab (`Models/AgentInstance.swift`). The status
//! types themselves live in `soprano-types`.

use std::time::SystemTime;

use soprano_types::{AgentConversation, AgentLaunch, AgentStatus, AgentWaitingReason};

/// Runtime state of a running agent process.
#[derive(Clone, Debug, PartialEq)]
pub struct AgentInstance {
    pub id: String,
    pub profile_id: String,
    pub status: AgentStatus,
    pub started_at: Option<SystemTime>,
    pub exit_code: Option<i32>,
    pub process_id: Option<i32>,
    pub restart_count: u32,
    pub needs_attention: bool,
    pub conversation: Option<AgentConversation>,
    /// What its CLI was started with for an automation run: the first prompt, model, and
    /// autonomy. Never persisted — a restored agent resumes its conversation and must not get
    /// its prompt a second time.
    pub launch: Option<AgentLaunch>,
    /// The automation run this agent works for; `None` for agents started by hand.
    pub automation_run_id: Option<String>,
    /// Why a `Waiting` agent waits; `None` in every other status.
    pub waiting_reason: Option<AgentWaitingReason>,
    /// The last thing the agent said in an event, in full (capped): the reply an automation
    /// run keeps when the CLI writes no transcript.
    pub last_message: Option<String>,
}

impl AgentInstance {
    /// A freshly starting agent.
    pub fn new(id: impl Into<String>, profile_id: impl Into<String>) -> Self {
        Self::with_launch(id, profile_id, None, None)
    }

    /// A freshly starting agent launched for an automation run.
    pub fn with_launch(
        id: impl Into<String>,
        profile_id: impl Into<String>,
        launch: Option<AgentLaunch>,
        automation_run_id: Option<String>,
    ) -> Self {
        Self {
            id: id.into(),
            profile_id: profile_id.into(),
            status: AgentStatus::Starting,
            started_at: Some(SystemTime::now()),
            exit_code: None,
            process_id: None,
            restart_count: 0,
            needs_attention: false,
            conversation: None,
            launch,
            automation_run_id,
            waiting_reason: None,
            last_message: None,
        }
    }
}
