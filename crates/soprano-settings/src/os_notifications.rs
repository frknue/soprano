//! Where each OS keeps its notification permission, and what it is called there.

/// The OS whose notification settings the permission line describes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NotificationPlatform {
    MacOs,
    Windows,
    Linux,
}

impl NotificationPlatform {
    pub fn current() -> Self {
        if cfg!(target_os = "macos") {
            Self::MacOs
        } else if cfg!(windows) {
            Self::Windows
        } else {
            Self::Linux
        }
    }

    /// Who decides, as the sentence's subject.
    pub(crate) fn subject(self) -> &'static str {
        match self {
            Self::MacOs => "macOS",
            Self::Windows => "Windows",
            Self::Linux => "Your desktop",
        }
    }

    /// The button that opens the OS page, where there is one.
    pub(crate) fn settings_button(self) -> Option<&'static str> {
        match self {
            Self::MacOs => Some("Open System Settings"),
            Self::Windows => Some("Open Notification Settings"),
            Self::Linux => None,
        }
    }

    /// Appended to allowed/blocked lines where no button can take the user there.
    pub(crate) fn settings_hint(self) -> &'static str {
        match self {
            Self::MacOs | Self::Windows => "",
            Self::Linux => " Change this in your desktop's notification settings.",
        }
    }

    pub(crate) fn unavailable_message(self) -> &'static str {
        match self {
            Self::MacOs => "Notifications need the packaged app; unbundled builds cannot post them.",
            Self::Windows | Self::Linux => "No notification service is running, so banners cannot be shown.",
        }
    }

    /// The URL of the OS notification settings.
    pub fn settings_url(self) -> Option<&'static str> {
        match self {
            Self::MacOs => Some("x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
            Self::Windows => Some("ms-settings:notifications"),
            Self::Linux => None,
        }
    }
}

/// Opens the running OS's notification settings (System Settings ▸ Notifications on macOS,
/// Settings ▸ Notifications on Windows). Linux has no single page; nothing happens there.
pub fn open_notification_settings() -> Result<(), String> {
    match NotificationPlatform::current().settings_url() {
        Some(url) => soprano_platform::system::open_default(url).map_err(|error| error.to_string()),
        None => Ok(()),
    }
}
