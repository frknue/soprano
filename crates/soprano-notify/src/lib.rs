//! soprano-notify: the app side of agent notifications (`AgentNotificationManager.swift`).
//!
//! [`NotificationManager`] receives `agent-event` reports ([`soprano_ipc::AgentEvent`]) and
//! terminal OSC notifications ([`TerminalNotification`]) on the UI thread and updates the
//! [`soprano_model::Workspace`]: it attaches the reporting agent to its tab, sets its status,
//! waiting reason, conversation, process and last message, marks unfocused tabs as needing
//! attention, and posts one native banner per tab for panes that are not focused. Focus
//! changes clear those marks and withdraw the banners. The OS service sits behind
//! [`NotificationBackend`]: `UNUserNotificationCenter` on macOS (bundled builds only),
//! the D-Bus notification server on Linux, and toasts on Windows.

mod authorization;
mod backend;
mod manager;

pub use authorization::{AUTHORIZATION_KEY, Authorization};
pub use backend::{
    Banner, BannerClick, ClickHandler, NotificationBackend, SystemAuthorization, system_backend,
};
pub use manager::{NotificationManager, TerminalNotification};

#[cfg(test)]
mod tests;
