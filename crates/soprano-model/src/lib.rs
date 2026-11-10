//! soprano-model: the workspace model — sessions → logical windows → layout tabs → split panes
//! → pane tabs — with agents, focus, maximize, save/restore and named workspaces. See
//! docs/rust-rewrite/PLAN.md.
//!
//! [`Workspace`] is the Swift `AgentManager`; [`SessionManager`] the named-workspace list.

pub mod agent_instance;
pub mod file_url;
pub mod pane;
mod process;
pub mod session;
pub mod session_manager;
pub mod split_node;
pub mod terminal_title;
pub mod window;
pub mod workspace;

pub use agent_instance::AgentInstance;
pub use pane::{PaneContentKind, PaneState, PaneTab, PaneType, Remote, chat_supports};
pub use session::{ReferenceDate, SavedLayoutTab, SavedPane, SavedTab, SavedWindow, WorkspaceSession};
pub use session_manager::SessionManager;
pub use split_node::{PaneFrame, SplitBranch, SplitBranchSide, SplitNode};
pub use window::{LayoutTab, TerminalSessionState, WorkspaceWindowState};
pub use workspace::{
    ActiveLocation, ActivitySummary, AgentDashboardEntry, AgentReadinessGeneration, CloseConfirmation,
    CloseOutcome, CloseRequest, PaneShortcut, TerminalLifecycleAction, Workspace, WorkspaceChange,
    WorkspaceEvent,
};
