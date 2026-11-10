//! Value types shared by every Soprano crate. Kept small and stable: crates that are ported in
//! parallel compile against these without depending on each other.

pub mod agent;
pub mod color;
pub mod keybinding;
pub mod layout;
pub mod machine;
pub mod program_status;

pub use agent::{
    AgentCatalog, AgentConversation, AgentLaunch, AgentProfile, AgentStatus, AgentWaitingReason,
    DefaultAgents, OutputPatterns,
};
pub use color::Color;
pub use keybinding::{KeyBinding, KeyBindingCategory, KeyBindingConfig, KeyBindingMode, KeybindingState};
pub use layout::{NavigationDirection, SplitDirection, TerminalTarget};
pub use machine::Machine;
