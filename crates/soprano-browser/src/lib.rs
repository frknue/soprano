//! Soprano's browser pane: a wry web view (WKWebView, WebView2, WebKitGTK) under Herdr's
//! toolbar, and the app side of `soprano browser` automation.
//!
//! The app routes a request with [`is_open_command`] (spawn a pane) or [`resolve_target`] →
//! [`BrowserRegistry::view`] → [`BrowserView::perform_automation`], answering with
//! [`no_target_message`] / [`unavailable_message`] / [`PANE_LIMIT_MESSAGE`] when it cannot.

pub mod address;
mod page_gate;
mod registry;
mod screenshot;
pub mod scripts;
mod target;
pub mod value;
mod view;

pub use address::resolve as resolve_address;
pub use page_gate::{PAGE_NOT_STARTED_MESSAGE, PAGE_START_TIMEOUT};
pub use registry::{BrowserRegistry, Registry};
pub use screenshot::UNSUPPORTED_MESSAGE as SCREENSHOT_UNSUPPORTED_MESSAGE;
pub use target::{
    PANE_LIMIT_MESSAGE, PaneTabs, is_open_command, no_target_message, resolve_target, unavailable_message,
};
pub use view::{
    BrowserEvent, BrowserView, FocusAddressBar, GoBack, GoForward, KEY_CONTEXT, Reload, bind_keys,
};
