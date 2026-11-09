//! The OS notification service behind one small interface, so the manager's rules (permission
//! flow, one banner per tab, removal on focus) are the same everywhere and testable without a
//! notification center. Each OS has its own module under `platform/`.

use std::sync::Arc;

use soprano_model::TerminalTarget;
use soprano_platform::AppIdentity;

#[cfg(target_os = "macos")]
#[path = "platform/macos.rs"]
mod system;

#[cfg(all(unix, not(target_os = "macos")))]
#[path = "platform/linux.rs"]
mod system;

#[cfg(windows)]
#[path = "platform/windows.rs"]
mod system;

#[cfg(any(windows, test))]
#[path = "platform/start_menu.rs"]
mod start_menu;

#[cfg(not(any(unix, windows)))]
mod system {
    use std::sync::Arc;

    pub(crate) fn backend(
        _identity: &soprano_platform::AppIdentity,
        _on_click: super::ClickHandler,
    ) -> Option<Arc<dyn super::NotificationBackend>> {
        None
    }
}

/// What a click on a banner opens.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum BannerClick {
    /// The pane tab that asked for attention: activate the app and focus it.
    Tab(TerminalTarget),
    /// An automation run's banner: activate the app and open the run in Automations (its
    /// terminal may already be closed).
    AutomationRun(String),
}

impl BannerClick {
    /// Decodes a banner's user info (`paneId`, `tabId`, `automationRunId`), the keys the Swift
    /// app wrote, so banners it delivered still open their tab.
    pub fn from_user_info(pane_id: Option<&str>, tab_id: Option<&str>, run_id: Option<&str>) -> Option<Self> {
        if let Some(run_id) = run_id {
            return Some(Self::AutomationRun(run_id.to_owned()));
        }
        Some(Self::Tab(TerminalTarget::new(pane_id?, tab_id?)))
    }
}

/// Called with every banner click, on whichever thread the OS reports it.
pub type ClickHandler = Arc<dyn Fn(BannerClick) + Send + Sync>;

/// One banner as the manager wants it shown.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Banner {
    /// `soprano-<paneId>-<tabId>`: the next banner for the same tab replaces this one.
    pub identifier: String,
    pub title: String,
    pub subtitle: Option<String>,
    pub body: String,
    pub plays_sound: bool,
    /// Groups a pane's banners in the notification list (macOS thread identifier).
    pub thread_identifier: String,
    /// The tab (or automation run) the banner stands for.
    pub target: TerminalTarget,
    pub automation_run_id: Option<String>,
}

impl Banner {
    pub fn identifier(target: &TerminalTarget) -> String {
        format!("soprano-{}-{}", target.pane_id, target.tab_id)
    }

    pub fn click(&self) -> BannerClick {
        match &self.automation_run_id {
            Some(run_id) => BannerClick::AutomationRun(run_id.clone()),
            None => BannerClick::Tab(self.target.clone()),
        }
    }
}

/// The OS's permission answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SystemAuthorization {
    /// Authorized, provisional or ephemeral.
    Authorized,
    Denied,
    NotDetermined,
    /// No answer the app understands, or no notification service to ask.
    Unknown,
}

/// A notification service. Completion handlers may run on any thread.
pub trait NotificationBackend: Send + Sync {
    fn authorization_status(&self, done: Box<dyn FnOnce(SystemAuthorization) + Send>);
    /// Asks for alert and sound permission; `done(granted)`.
    fn request_authorization(&self, done: Box<dyn FnOnce(bool) + Send>);
    /// Shows `banner`, replacing a delivered one with the same identifier.
    fn post(&self, banner: Banner, done: Box<dyn FnOnce(Result<(), String>) + Send>);
    fn remove_delivered(&self, identifiers: &[String]);
}

/// The running OS's notification service; `None` when this process cannot post at all
/// (on macOS: not a bundled `.app` with an identifier, where touching
/// `UNUserNotificationCenter` raises an exception).
pub fn system_backend(
    identity: &AppIdentity,
    on_click: ClickHandler,
) -> Option<Arc<dyn NotificationBackend>> {
    system::backend(identity, on_click)
}
