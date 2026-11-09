//! How a pane's process starts: argv, working directory and environment for plain shells,
//! agent CLIs (with their launch-scoped Soprano hooks) and chat ACP servers, plus the
//! login-shell command runner the accounts and automations layers use.
//!
//! Ports `TerminalConfig` (`Terminal/TerminalSurfaceView.swift`), `AgentChatLaunch`
//! (`Chat/AgentChatSession.swift`), `CommandRunner` (`Accounts/CommandRunner.swift`),
//! `SopranoResources`, and the child environment and shell integration Ghostty used to add
//! (`ghostty/src/termio/{Exec,shell_integration}.zig`).

pub mod chat;
pub mod command_runner;
pub mod integrations;
pub mod quote;
pub mod resources;
pub mod shell_integration;
pub mod spec;

pub use chat::ChatLaunch;
pub use command_runner::{CancelToken, CommandError, CommandResult, CommandRunner, RunOptions};
pub use quote::{ShellFlavor, shell_quoted};
pub use resources::Resources;
pub use spec::{
    AccountAdjustments, AgentRequest, LaunchContext, LaunchSpec, fallback_shell, launch_arguments,
};
