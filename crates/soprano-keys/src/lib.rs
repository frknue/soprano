//! soprano-keys: the keybinding resolver (Swift `Controllers/KeybindingManager.swift`) without a
//! UI. The host translates its keystrokes into [`KeyEvent`]s, feeds them to a
//! [`KeybindingResolver`] with a [`KeyContext`], and acts on the [`KeyOutcome`]: deliver the key,
//! run a binding ([`BindingCommand::from_binding_id`]), focus a pane, or show prefix/hint state.
//!
//! See docs/rust-rewrite/PLAN.md.

pub mod claims;
pub mod command;
pub mod event;
pub mod hints;
pub mod resolver;

pub use claims::{PaneNavigationClaimRegistry, PassthroughClaims};
pub use command::{
    BindingCommand, FocusedContent, dispatches_through_main_menu, launched_agent_id, split_direction,
};
pub use event::{ESCAPE, KeyEvent, Modifiers, Platform, SHIFTED_SYMBOLS, binding_key, is_shifted_symbol};
pub use hints::{PaneHintAssignment, PaneHintStep, pane_hint_step};
pub use resolver::{
    KeyContext, KeyOutcome, KeybindingResolver, PANE_NAVIGATION_BINDING_IDS, ResolverChange,
    should_forward_prefix_key,
};
