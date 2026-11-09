//! Windows: toast notifications under the app's AppUserModelID (the app identity's id, which
//! the installer's Start menu shortcut carries).
//!
//! A toast's tag and group identify the tab's banner, so the next one replaces it and focusing
//! the tab withdraws it from Action Center. The user's per-app switch is the permission.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use soprano_platform::AppIdentity;
use windows::Data::Xml::Dom::XmlDocument;
use windows::Foundation::TypedEventHandler;
use windows::UI::Notifications::{NotificationSetting, ToastNotification, ToastNotificationManager};
use windows::core::{HSTRING, IInspectable};

use super::{Banner, ClickHandler, NotificationBackend, SystemAuthorization};

const GROUP: &str = "soprano";
/// Windows rejects longer tags.
const TAG_LIMIT: usize = 64;

pub(crate) fn backend(
    identity: &AppIdentity,
    on_click: ClickHandler,
) -> Option<Arc<dyn NotificationBackend>> {
    Some(Arc::new(WindowsBackend {
        app_id: HSTRING::from(identity.id.as_str()),
        on_click,
        shown: Mutex::new(HashMap::new()),
    }))
}

struct WindowsBackend {
    app_id: HSTRING,
    on_click: ClickHandler,
    /// Each tab's latest toast, kept so its activation handler stays registered.
    shown: Mutex<HashMap<String, ToastNotification>>,
}

impl WindowsBackend {
    fn setting(&self) -> windows::core::Result<NotificationSetting> {
        ToastNotificationManager::CreateToastNotifierWithId(&self.app_id)?.Setting()
    }

    fn show(&self, banner: &Banner) -> windows::core::Result<()> {
        let document = XmlDocument::new()?;
        document.LoadXml(&HSTRING::from(toast_xml(banner)))?;
        let toast = ToastNotification::CreateToastNotification(&document)?;
        toast.SetTag(&HSTRING::from(toast_tag(&banner.identifier)))?;
        toast.SetGroup(&HSTRING::from(GROUP))?;
        let on_click = self.on_click.clone();
        let click = banner.click();
        toast.Activated(&TypedEventHandler::<ToastNotification, IInspectable>::new(move |_, _| {
            on_click(click.clone());
            Ok(())
        }))?;
        ToastNotificationManager::CreateToastNotifierWithId(&self.app_id)?.Show(&toast)?;
        self.shown.lock().expect("shown lock").insert(banner.identifier.clone(), toast);
        Ok(())
    }
}

impl NotificationBackend for WindowsBackend {
    fn authorization_status(&self, done: Box<dyn FnOnce(SystemAuthorization) + Send>) {
        done(match self.setting() {
            Ok(NotificationSetting::Enabled) => SystemAuthorization::Authorized,
            Ok(_) => SystemAuthorization::Denied,
            Err(_) => SystemAuthorization::Unknown,
        });
    }

    /// Windows never prompts; the per-app switch in Settings is the answer.
    fn request_authorization(&self, done: Box<dyn FnOnce(bool) + Send>) {
        done(matches!(self.setting(), Ok(NotificationSetting::Enabled)));
    }

    fn post(&self, banner: Banner, done: Box<dyn FnOnce(Result<(), String>) + Send>) {
        done(self.show(&banner).map_err(|error| error.to_string()));
    }

    fn remove_delivered(&self, identifiers: &[String]) {
        let Ok(history) = ToastNotificationManager::History() else { return };
        let mut shown = self.shown.lock().expect("shown lock");
        for identifier in identifiers {
            shown.remove(identifier);
            let _ = history.RemoveGroupedTagWithId(
                &HSTRING::from(toast_tag(identifier)),
                &HSTRING::from(GROUP),
                &self.app_id,
            );
        }
    }
}

/// The banner's identifier, or a stable digest of it when it is too long for a tag.
fn toast_tag(identifier: &str) -> String {
    if identifier.len() <= TAG_LIMIT {
        return identifier.to_owned();
    }
    // FNV-1a: stable across runs, unlike the std hasher.
    let hash = identifier.bytes().fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    });
    format!("soprano-{hash:016x}")
}

fn escape_xml(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// Title, the optional location line, and body; silent unless the sound setting is on.
fn toast_xml(banner: &Banner) -> String {
    let lines: String = [Some(banner.title.as_str()), banner.subtitle.as_deref(), Some(banner.body.as_str())]
        .into_iter()
        .flatten()
        .map(|line| format!("<text>{}</text>", escape_xml(line)))
        .collect();
    let audio = if banner.plays_sound { "" } else { r#"<audio silent="true"/>"# };
    format!(r#"<toast><visual><binding template="ToastGeneric">{lines}</binding></visual>{audio}</toast>"#)
}
