//! The General page's notification permission line: what the OS currently allows, said in
//! the OS's own terms, with the way to its notification settings where there is one.
//!
//! The permission itself is the app's to read (`UNUserNotificationCenter` on macOS, the
//! notification server elsewhere); the settings screen takes it through
//! [`NotificationStatusProvider`] and re-reads it when the app calls
//! [`crate::SettingsView::notification_authorization_changed`].

use crate::os_notifications::NotificationPlatform;

/// Whether the OS lets Soprano post banners (`AgentNotificationManager.Authorization`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum NotificationAuthorization {
    Authorized,
    Denied,
    /// The OS has not asked the user yet (macOS prompts once, on the first banner).
    NotDetermined,
    /// This build cannot post notifications at all (an unbundled macOS build).
    Unavailable,
}

/// What the settings screen reads the permission from. `None` while the app is still asking
/// the OS.
pub trait NotificationStatusProvider: 'static {
    fn authorization(&self) -> Option<NotificationAuthorization>;
}

/// A fixed answer, for hosts that know the permission up front (and for tests and demos).
impl NotificationStatusProvider for Option<NotificationAuthorization> {
    fn authorization(&self) -> Option<NotificationAuthorization> {
        *self
    }
}

/// How the permission line reads: colored by `tone`, with the OS settings button when
/// `offers_system_settings`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NotificationStatusRow {
    pub title: &'static str,
    pub message: String,
    pub tone: StatusTone,
    /// The label of the button that opens the OS notification settings; `None` hides it
    /// (nothing there would change the outcome, or the OS has no such page).
    pub button: Option<&'static str>,
}

/// The color role of a status line's title.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StatusTone {
    Normal,
    Success,
    Error,
}

impl NotificationStatusRow {
    /// The line for `authorization` on the running OS.
    pub fn new(authorization: Option<NotificationAuthorization>) -> Self {
        Self::for_platform(authorization, NotificationPlatform::current())
    }

    /// Ported from `refreshNotificationAuthorizationRow`; the OS is named as it is on
    /// `platform` (Linux has no single settings page to send anyone to, so it says where to
    /// look instead of offering a button).
    pub fn for_platform(
        authorization: Option<NotificationAuthorization>,
        platform: NotificationPlatform,
    ) -> Self {
        let os = platform.subject();
        let settings_button = platform.settings_button();
        match authorization {
            Some(NotificationAuthorization::Authorized) => Self {
                title: "Notifications allowed",
                message: format!(
                    "{os} is allowed to show Soprano notifications.{}",
                    platform.settings_hint()
                ),
                tone: StatusTone::Success,
                button: settings_button,
            },
            Some(NotificationAuthorization::Denied) => Self {
                title: "Notifications blocked",
                message: format!(
                    "{os} is blocking Soprano notifications. Panes still show status and an unread ring, but no banner appears.{}",
                    platform.settings_hint()
                ),
                tone: StatusTone::Error,
                button: settings_button,
            },
            Some(NotificationAuthorization::NotDetermined) => Self {
                title: "Not asked yet",
                message: format!(
                    "{os} has not been asked yet. The prompt appears the first time an unfocused pane wants you."
                ),
                tone: StatusTone::Normal,
                button: None,
            },
            Some(NotificationAuthorization::Unavailable) => Self {
                title: "Notifications unavailable",
                message: platform.unavailable_message().to_owned(),
                tone: StatusTone::Normal,
                button: None,
            },
            None => Self {
                title: "Checking permission",
                message: "Checking notification permission…".to_owned(),
                tone: StatusTone::Normal,
                button: None,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use NotificationAuthorization::*;

    #[test]
    fn the_mac_line_keeps_the_swift_wording_and_offers_system_settings_only_where_it_helps() {
        let mac = NotificationPlatform::MacOs;
        let allowed = NotificationStatusRow::for_platform(Some(Authorized), mac);
        assert_eq!(allowed.title, "Notifications allowed");
        assert_eq!(allowed.message, "macOS is allowed to show Soprano notifications.");
        assert_eq!(allowed.tone, StatusTone::Success);
        assert_eq!(allowed.button, Some("Open System Settings"));

        let blocked = NotificationStatusRow::for_platform(Some(Denied), mac);
        assert_eq!(blocked.title, "Notifications blocked");
        assert_eq!(
            blocked.message,
            "macOS is blocking Soprano notifications. Panes still show status and an unread ring, but no banner appears."
        );
        assert_eq!(blocked.tone, StatusTone::Error);
        assert!(blocked.button.is_some());

        let unasked = NotificationStatusRow::for_platform(Some(NotDetermined), mac);
        assert_eq!(unasked.title, "Not asked yet");
        assert!(unasked.message.starts_with("macOS has not been asked yet."));
        assert_eq!(unasked.button, None);

        let unavailable = NotificationStatusRow::for_platform(Some(Unavailable), mac);
        assert_eq!(
            unavailable.message,
            "Notifications need the packaged app; unbundled builds cannot post them."
        );
        assert_eq!(unavailable.button, None);

        let checking = NotificationStatusRow::for_platform(None, mac);
        assert_eq!(checking.title, "Checking permission");
        assert_eq!(checking.message, "Checking notification permission…");
        assert_eq!(checking.button, None);
    }

    #[test]
    fn windows_sends_people_to_its_notification_settings_page() {
        let row = NotificationStatusRow::for_platform(Some(Denied), NotificationPlatform::Windows);
        assert!(row.message.starts_with("Windows is blocking Soprano notifications."));
        assert_eq!(row.button, Some("Open Notification Settings"));
    }

    #[test]
    fn linux_has_no_settings_page_to_open_so_the_line_says_where_to_look() {
        let row = NotificationStatusRow::for_platform(Some(Authorized), NotificationPlatform::Linux);
        assert_eq!(row.button, None);
        assert!(row.message.starts_with("Your desktop is allowed to show Soprano notifications."));
        assert!(row.message.contains("desktop's notification settings"));
    }
}
