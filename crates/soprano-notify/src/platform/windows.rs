//! Windows: toast notifications under the app's AppUserModelID (the app identity's id).
//!
//! Windows shows toasts of an unpackaged app only for an AppUserModelID that a Start menu
//! shortcut carries. The release is a plain zip without an installer, so the backend registers
//! itself at startup: it sets the id on the process and keeps
//! `%APPDATA%\Microsoft\Windows\Start Menu\Programs\<app name>.lnk` pointing at the running
//! executable with that id.
//!
//! A toast's tag and group identify the tab's banner, so the next one replaces it and focusing
//! the tab withdraws it from Action Center. The user's per-app switch is the permission.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread;

use soprano_platform::AppIdentity;
use windows::Data::Xml::Dom::XmlDocument;
use windows::Foundation::TypedEventHandler;
use windows::UI::Notifications::{NotificationSetting, ToastNotification, ToastNotificationManager};
use windows::Win32::Storage::EnhancedStorage::PKEY_AppUserModel_ID;
use windows::Win32::System::Com::StructuredStorage::{PROPVARIANT, PropVariantClear};
use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoUninitialize,
    IPersistFile, STGM_READ,
};
use windows::Win32::System::Variant::VT_LPWSTR;
use windows::Win32::UI::Shell::PropertiesSystem::IPropertyStore;
use windows::Win32::UI::Shell::{IShellLinkW, SetCurrentProcessExplicitAppUserModelID, ShellLink};
use windows::core::{HSTRING, IInspectable, Interface, PWSTR};

use super::start_menu;
use super::{Banner, ClickHandler, NotificationBackend, SystemAuthorization};

const GROUP: &str = "soprano";
/// Windows rejects longer tags.
const TAG_LIMIT: usize = 64;

pub(crate) fn backend(
    identity: &AppIdentity,
    on_click: ClickHandler,
) -> Option<Arc<dyn NotificationBackend>> {
    register_app_id(identity);
    Some(Arc::new(WindowsBackend {
        app_id: HSTRING::from(identity.id.as_str()),
        on_click,
        shown: Mutex::new(HashMap::new()),
    }))
}

/// Once per launch, before the first toast: the process id and the Start menu shortcut.
/// Failures are logged; toasts then simply do not appear, as on a system that blocks them.
fn register_app_id(identity: &AppIdentity) {
    // SAFETY: a plain Win32 call with a valid, NUL-terminated string.
    if let Err(error) =
        unsafe { SetCurrentProcessExplicitAppUserModelID(&HSTRING::from(identity.id.as_str())) }
    {
        tracing::warn!("Soprano: could not set the AppUserModelID {}: {error}", identity.id);
    }
    let Some(appdata) = std::env::var_os("APPDATA") else {
        tracing::warn!("Soprano: APPDATA is not set; no Start menu shortcut for notifications");
        return;
    };
    let exe = match std::env::current_exe() {
        Ok(exe) => exe,
        Err(error) => {
            tracing::warn!("Soprano: could not locate the executable for the Start menu shortcut: {error}");
            return;
        }
    };
    let link = start_menu::shortcut_path(Path::new(&appdata), &identity.name);
    let app_id = identity.id.clone();
    // A thread of its own, so COM is initialized in a known apartment, independent of the UI
    // thread's.
    let result = thread::spawn(move || {
        let result = ensure_shortcut(&link, &exe, &app_id);
        result.map_err(|error| format!("{}: {error}", link.display()))
    })
    .join();
    match result {
        Ok(Ok(())) => {}
        Ok(Err(error)) => tracing::warn!("Soprano: could not write the Start menu shortcut {error}"),
        Err(_) => tracing::warn!("Soprano: writing the Start menu shortcut panicked"),
    }
}

/// Leaves a shortcut that already points at `exe` with `app_id` alone; writes it otherwise.
fn ensure_shortcut(link: &Path, exe: &Path, app_id: &str) -> windows::core::Result<()> {
    // SAFETY: balanced with `CoUninitialize` below on this thread.
    unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }.ok()?;
    let result = if link.exists() && shortcut_matches(link, exe, app_id).unwrap_or(false) {
        Ok(())
    } else {
        write_shortcut(link, exe, app_id)
    };
    // SAFETY: matches the successful `CoInitializeEx` above.
    unsafe { CoUninitialize() };
    result
}

fn shortcut_matches(link: &Path, exe: &Path, app_id: &str) -> windows::core::Result<bool> {
    // SAFETY: COM calls on interfaces this function owns; buffers outlive the calls, and the
    // property value is cleared after reading.
    unsafe {
        let shell_link: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER)?;
        shell_link.cast::<IPersistFile>()?.Load(&HSTRING::from(link), STGM_READ)?;
        let mut buffer = [0u16; 2048];
        shell_link.GetPath(&mut buffer, std::ptr::null_mut(), 0)?;
        let length = buffer.iter().position(|&unit| unit == 0).unwrap_or(buffer.len());
        let target = String::from_utf16_lossy(&buffer[..length]);

        let mut value = shell_link.cast::<IPropertyStore>()?.GetValue(&PKEY_AppUserModel_ID)?;
        let fields = &value.Anonymous.Anonymous;
        let stored_id = if fields.vt == VT_LPWSTR && !fields.Anonymous.pwszVal.is_null() {
            fields.Anonymous.pwszVal.to_string().ok()
        } else {
            None
        };
        PropVariantClear(&mut value)?;
        Ok(start_menu::same_target(&target, &exe.to_string_lossy()) && stored_id.as_deref() == Some(app_id))
    }
}

fn write_shortcut(link: &Path, exe: &Path, app_id: &str) -> windows::core::Result<()> {
    if let Some(directory) = link.parent() {
        std::fs::create_dir_all(directory).map_err(windows::core::Error::from)?;
    }
    let mut id: Vec<u16> = app_id.encode_utf16().chain(std::iter::once(0)).collect();
    // SAFETY: COM calls on interfaces this function owns. The property value borrows `id`,
    // which outlives `SetValue` (the store copies it), and is never cleared.
    unsafe {
        let shell_link: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER)?;
        shell_link.SetPath(&HSTRING::from(exe))?;
        if let Some(directory) = exe.parent() {
            shell_link.SetWorkingDirectory(&HSTRING::from(directory))?;
        }
        let mut value = PROPVARIANT::default();
        // Plain `Copy` fields of a zeroed value: no destructor runs.
        (*value.Anonymous.Anonymous).vt = VT_LPWSTR;
        (*value.Anonymous.Anonymous).Anonymous.pwszVal = PWSTR(id.as_mut_ptr());
        let store = shell_link.cast::<IPropertyStore>()?;
        store.SetValue(&PKEY_AppUserModel_ID, &value)?;
        store.Commit()?;
        shell_link.cast::<IPersistFile>()?.Save(&HSTRING::from(link), true)
    }
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
