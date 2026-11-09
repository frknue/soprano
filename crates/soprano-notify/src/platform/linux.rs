//! Linux and the BSDs: the freedesktop notification server over D-Bus (`notify-rust`).
//!
//! There is no permission prompt: a running notification server means banners are allowed,
//! none means they are unavailable. A tab's next banner reuses the server id of its last one,
//! which replaces it; clicking a banner (its default action) reports the click.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::thread;

use notify_rust::{ActionResponse, Hint, Notification, NotificationHandle};
use soprano_platform::AppIdentity;

use super::{Banner, ClickHandler, NotificationBackend, SystemAuthorization};

pub(crate) fn backend(
    identity: &AppIdentity,
    on_click: ClickHandler,
) -> Option<Arc<dyn NotificationBackend>> {
    Some(Arc::new(LinuxBackend {
        app_name: identity.name.clone(),
        desktop_entry: identity.id.clone(),
        on_click,
        shown: Arc::new(Mutex::new(HashMap::new())),
        next_generation: AtomicU64::new(0),
    }))
}

/// A banner still on screen or in the server's list.
struct Shown {
    handle: NotificationHandle,
    /// Tells this banner's click listener from those of the banners it replaced (they share
    /// the server id).
    generation: u64,
}

struct LinuxBackend {
    app_name: String,
    desktop_entry: String,
    on_click: ClickHandler,
    shown: Arc<Mutex<HashMap<String, Shown>>>,
    next_generation: AtomicU64,
}

fn server_is_running() -> bool {
    notify_rust::get_server_information().is_ok()
}

/// Servers that render markup in the body need `&`, `<` and `>` escaped; others show text as is.
static RENDERS_MARKUP: LazyLock<bool> = LazyLock::new(|| {
    notify_rust::get_capabilities().is_ok_and(|capabilities| capabilities.iter().any(|c| c == "body-markup"))
});

fn escape_markup(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// The location line (a plain terminal's `session ▸ window ▸ pane`) heads the body: the
/// freedesktop spec has no subtitle.
fn body_text(banner: &Banner) -> String {
    [banner.subtitle.as_deref(), Some(banner.body.as_str())]
        .into_iter()
        .flatten()
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

impl NotificationBackend for LinuxBackend {
    fn authorization_status(&self, done: Box<dyn FnOnce(SystemAuthorization) + Send>) {
        thread::spawn(move || {
            done(if server_is_running() {
                SystemAuthorization::Authorized
            } else {
                SystemAuthorization::Unknown
            })
        });
    }

    fn request_authorization(&self, done: Box<dyn FnOnce(bool) + Send>) {
        thread::spawn(move || done(server_is_running()));
    }

    fn post(&self, banner: Banner, done: Box<dyn FnOnce(Result<(), String>) + Send>) {
        let app_name = self.app_name.clone();
        let desktop_entry = self.desktop_entry.clone();
        let on_click = self.on_click.clone();
        let shown = self.shown.clone();
        let generation = self.next_generation.fetch_add(1, Ordering::Relaxed);
        thread::spawn(move || {
            let body = body_text(&banner);
            let body = if *RENDERS_MARKUP { escape_markup(&body) } else { body };
            let mut notification = Notification::new();
            notification
                .appname(&app_name)
                .summary(&banner.title)
                .body(&body)
                .action("default", "Open")
                .hint(Hint::DesktopEntry(desktop_entry));
            if banner.plays_sound {
                notification.hint(Hint::SoundName("message-new-instant".into()));
            } else {
                notification.hint(Hint::SuppressSound(true));
            }
            let replaced =
                shown.lock().expect("shown lock").get(&banner.identifier).map(|shown| shown.handle.id());
            if let Some(id) = replaced {
                notification.id(id);
            }
            let handle = match notification.show() {
                Ok(handle) => handle,
                Err(error) => return done(Err(error.to_string())),
            };
            let id = handle.id();
            shown.lock().expect("shown lock").insert(banner.identifier.clone(), Shown { handle, generation });
            done(Ok(()));

            let is_current = |shown: &HashMap<String, Shown>| {
                shown.get(&banner.identifier).is_some_and(|entry| entry.generation == generation)
            };
            let _ = notify_rust::handle_action(id, |response| {
                if let ActionResponse::Custom(_) = response
                    && is_current(&shown.lock().expect("shown lock"))
                {
                    on_click(banner.click());
                }
            });
            let mut shown = shown.lock().expect("shown lock");
            if is_current(&shown) {
                shown.remove(&banner.identifier);
            }
        });
    }

    fn remove_delivered(&self, identifiers: &[String]) {
        let mut shown = self.shown.lock().expect("shown lock");
        for identifier in identifiers {
            if let Some(entry) = shown.remove(identifier) {
                thread::spawn(move || entry.handle.close());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use soprano_model::TerminalTarget;

    use super::*;

    #[test]
    fn the_location_heads_the_body_and_empty_lines_are_dropped() {
        let target = TerminalTarget::new("pane-1", "tab-2");
        let mut banner = Banner {
            identifier: Banner::identifier(&target),
            title: "Build".into(),
            subtitle: Some("Session 1 ▸ Terminal 1 ▸ Terminal 1".into()),
            body: String::new(),
            plays_sound: false,
            thread_identifier: "pane-1".into(),
            target,
            automation_run_id: None,
        };
        assert_eq!(body_text(&banner), "Session 1 ▸ Terminal 1 ▸ Terminal 1");
        banner.body = "Done".into();
        assert_eq!(body_text(&banner), "Session 1 ▸ Terminal 1 ▸ Terminal 1\nDone");
        assert_eq!(escape_markup("a <b> & c"), "a &lt;b&gt; &amp; c");
    }
}
