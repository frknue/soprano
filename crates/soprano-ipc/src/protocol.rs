//! The messages a CLI invocation sends to the app that owns its terminal, one JSON object per
//! line. They replace the Swift app's `DistributedNotificationCenter` notifications
//! (`com.soprano.<kind>.<app-pid>` requests, `com.soprano.<kind>-response.<request-id>` replies);
//! a reply now travels back over the same connection, so no request id is needed.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use soprano_types::{AgentConversation, AgentStatus, AgentWaitingReason, NavigationDirection};

/// The lifecycle state an agent hook reports with `soprano agent-event <state>`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum AgentEventState {
    Ready,
    Running,
    NeedsInput,
    Error,
    Stopped,
}

impl AgentEventState {
    /// Parses the CLI spelling (`ready`, `running`, `needs-input`, `error`, `stopped`).
    pub fn from_raw(raw: &str) -> Option<Self> {
        match raw {
            "ready" => Some(Self::Ready),
            "running" => Some(Self::Running),
            "needs-input" => Some(Self::NeedsInput),
            "error" => Some(Self::Error),
            "stopped" => Some(Self::Stopped),
            _ => None,
        }
    }

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Ready => "ready",
            Self::Running => "running",
            Self::NeedsInput => "needs-input",
            Self::Error => "error",
            Self::Stopped => "stopped",
        }
    }

    pub fn agent_status(self) -> AgentStatus {
        match self {
            Self::Ready => AgentStatus::Idle,
            Self::Running => AgentStatus::Running,
            Self::NeedsInput => AgentStatus::Waiting,
            Self::Error => AgentStatus::Error,
            Self::Stopped => AgentStatus::Stopped,
        }
    }

    /// The banner body an event carries when the hook passes no `--body`.
    pub fn default_body(self) -> &'static str {
        match self {
            Self::Ready => "Ready for a prompt",
            Self::Running => "Working",
            Self::NeedsInput => "Input required",
            Self::Error => "The agent stopped with an error",
            Self::Stopped => "Stopped",
        }
    }
}

/// One `soprano agent-event` report (Swift `AgentEventPayload`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentEvent {
    pub pane_id: String,
    pub tab_id: String,
    pub state: AgentEventState,
    /// `--notify`: the event may raise a banner.
    pub notify: bool,
    pub title: String,
    pub body: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile_id: Option<String>,
    /// `--pid`, else the hook's owning process (the nearest non-shell ancestor).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub process_id: Option<i32>,
    /// What the agent itself said, untrimmed of prose, capped at `FULL_MESSAGE_LIMIT` chars.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    /// Only on `needs-input` events, when a flag or the payload says why.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<AgentWaitingReason>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation: Option<AgentConversation>,
}

/// `soprano navigation-passthrough enable|disable <source>`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PassthroughMode {
    Enable,
    Disable,
}

/// A request from a CLI invocation to the app that owns its terminal.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Request {
    /// Replaces `com.soprano.agent-event.<pid>`. One-way.
    AgentEvent(AgentEvent),
    /// Replaces `com.soprano.navigate-pane.<pid>` with `direction`. One-way.
    #[serde(rename_all = "camelCase")]
    NavigatePane { pane_id: String, tab_id: String, direction: NavigationDirection },
    /// Replaces `com.soprano.navigate-pane.<pid>` with `passthrough`/`source`. One-way.
    #[serde(rename_all = "camelCase")]
    NavigationPassthrough { pane_id: String, tab_id: String, mode: PassthroughMode, source: String },
    /// Replaces `com.soprano.markdown-request.<pid>`; answered with a [`Response`].
    #[serde(rename_all = "camelCase")]
    OpenMarkdown {
        /// Absolute, lexically standardized path of a file the CLI found readable.
        path: PathBuf,
        opens_new_pane: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        caller_pane_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        caller_tab_id: Option<String>,
    },
    /// Replaces `com.soprano.browser-request.<pid>`; answered with a [`Response`].
    #[serde(rename_all = "camelCase")]
    Browser {
        command: String,
        arguments: Vec<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target_pane_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        caller_pane_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        caller_tab_id: Option<String>,
    },
    /// Dev builds (`visual-snapshot`): render the main window into a PNG at `path` (absolute);
    /// answered with the written path.
    #[cfg(feature = "visual-snapshot")]
    DebugSnapshot { path: PathBuf },
    /// Dev builds (`visual-snapshot`): input dispatched through the main window; answered once
    /// the window has redrawn.
    #[cfg(feature = "visual-snapshot")]
    DebugInput { input: crate::debug::DebugInput },
}

impl Request {
    /// Whether the CLI waits for a [`Response`] on the connection.
    pub fn expects_reply(&self) -> bool {
        #[cfg(feature = "visual-snapshot")]
        if matches!(self, Self::DebugSnapshot { .. } | Self::DebugInput { .. }) {
            return true;
        }
        matches!(self, Self::OpenMarkdown { .. } | Self::Browser { .. })
    }
}

/// The app's answer to a request that expects one (Swift `["ok": "1", "output": …]` /
/// `["ok": "0", "error": …]`). The CLI prints `output` to stdout and exits 0, or `error` to
/// stderr and exits 1.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "camelCase")]
pub enum Response {
    Ok { output: String },
    Error { error: String },
}

impl Response {
    pub fn success(output: impl Into<String>) -> Self {
        Self::Ok { output: output.into() }
    }

    pub fn failure(error: impl Into<String>) -> Self {
        Self::Error { error: error.into() }
    }
}
