//! soprano-ipc: the CLI subcommands Soprano's binary answers inside its own terminals
//! (`agent-event`, `navigate-pane`, `navigation-passthrough`, `markdown`/`md`/`<file.md>`,
//! `browser`), the launch decision for everything else, and the local-socket transport that
//! replaces the Swift app's `DistributedNotificationCenter` routing.
//!
//! The app's `main` calls [`run_cli`] first; on [`CliOutcome::StartApp`] it starts the UI and
//! [`IpcServer::start`]s on [`endpoint_for_pid`] of its own pid, exporting the endpoint to panes as
//! `SOPRANO_SOCKET` next to `SOPRANO_APP_PID`.

pub mod agent_event;
pub mod alert;
pub mod browser;
pub mod caller_cwd;
pub mod cli;
pub mod launch;
pub mod markdown;
pub mod navigation;
pub mod protocol;
pub mod transport;

pub use alert::AgentAlert;
pub use cli::{CliHost, CliOutcome, SystemHost, endpoint_from_environment, run_cli, run_cli_with};
pub use launch::LaunchDispatch;
pub use navigation::{PaneNavigationClaimRegistry, TerminalTarget};
pub use protocol::{AgentEvent, AgentEventState, NavigationDirection, PassthroughMode, Request, Response};
pub use transport::{
    Endpoint, Incoming, IpcServer, REPLY_TIMEOUT, Replier, endpoint_for_pid, send, send_with_timeout,
};

/// Environment variable naming the app's IPC endpoint in every pane.
pub const SOCKET_ENV: &str = "SOPRANO_SOCKET";
/// Environment variable carrying the owning app's process id in every pane.
pub const APP_PID_ENV: &str = "SOPRANO_APP_PID";
