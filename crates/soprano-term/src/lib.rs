//! Soprano's terminal: libghostty-vt state fed by an in-process PTY ([`Terminal`]), and the
//! GPUI view that draws and drives it ([`TerminalView`]). Ports `Sources/Soprano/Terminal/*`;
//! the renderer and the libghostty-vt wrapper are adapted from herdr-app (Apache-2.0).

pub mod clipboard;
pub mod copy_mode;
pub mod drop_content;
mod engine;
mod events;
pub mod input_metadata;
pub mod interaction;
pub mod keybinds;
pub mod keys;
pub mod links;
pub mod os;
pub mod osc;
pub mod program_status;
pub mod settings;
mod sprites;
pub mod theme;
pub mod view;
pub mod vt;
mod win32_keys;

pub use clipboard::{
    ClipboardConfirmationCoordinator, ClipboardConfirmationDecision, ClipboardConfirmationKind,
    ClipboardConfirmationPresentation, ClipboardConfirmationPresenter, ClipboardConfirmationPrompt,
};
pub use engine::{PtyMessage, Terminal, TerminalLaunch, TerminalSize};
pub use events::{ClipboardRequest, TerminalEvent};
pub use interaction::TerminalInteractionState;
pub use keybinds::TerminalKeybinds;
pub use settings::{
    ClipboardAccess, CopyOnSelect, CursorStyle, GhosttyConfig, OptionAsAlt, Padding, TerminalSettings,
};
pub use theme::TerminalTheme;
pub use view::{KeyInterceptor, TerminalView, default_key_bindings};
pub use vt::{ClipboardLocation, ScreenText, StyleSpan};
