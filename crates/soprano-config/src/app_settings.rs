//! Application-wide preferences (`Models/AppSettings.swift`) and the theme ids `settings.json`
//! accepts (`Config/Theme.swift`; the palettes themselves live in the UI crate).

use serde::{Deserialize, Serialize};
use soprano_platform::StateStore;

/// The `theme` value that follows the appearance: Folio Paper when light, Folio Ink when dark.
pub const FOLIO_THEME_ID: &str = "folio";

/// Every id `settings.json` accepts, in picker order: Folio (following the appearance), then
/// each concrete palette.
pub const KNOWN_THEME_IDS: &[&str] = &[
    "folio",
    "folio-paper",
    "folio-ink",
    "gruvbox-dark",
    "catppuccin-mocha",
    "dracula",
    "solarized-dark",
    "nord",
    "tokyo-night",
    "atom-one-dark",
];

pub fn is_known_theme_id(id: &str) -> bool {
    KNOWN_THEME_IDS.contains(&id)
}

/// The `appearance` key: follow the OS, or pin light or dark.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AppearancePreference {
    #[default]
    System,
    Light,
    Dark,
}

impl AppearancePreference {
    pub const ALL: [Self; 3] = [Self::System, Self::Light, Self::Dark];

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::Light => "light",
            Self::Dark => "dark",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|p| p.raw_value() == raw)
    }
}

/// Application-wide preferences.
///
/// `settings.json` is the source of truth (see `ConfigStore`); the `StateStore` copy is only
/// read once, to seed that file for users who configured the app before it existed.
///
/// Every field falls back to its default when missing, so a stored payload written before a
/// key existed still loads instead of throwing every other setting away with it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppSettings {
    pub restore_last_session: bool,
    pub theme_id: String,
    /// `system` follows the OS; `light` and `dark` pin the app appearance. The `folio` theme
    /// resolves to Paper or Ink from the result.
    pub appearance: AppearancePreference,
    pub hide_window_bar: bool,
    /// Hides the numbered window tabs; the tab row moves up into their place. On by default:
    /// the sidebar, `⌃1`…`⌃9`, and `⌘F` already switch windows.
    pub hide_window_tabs: bool,
    /// Shows how long Soprano has been running (`Up 2:14:07`) in the status bar. Off by
    /// default: an always-ticking clock is noise.
    pub status_bar_uptime: bool,
    pub project_directories: Vec<String>,
    /// Off by default. A pane that wants you is already announced by the banner, the unread
    /// ring, and the pane header; adding a chime to every finished turn is the kind of thing
    /// people disable once and never turn back on.
    pub notification_sound: bool,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            restore_last_session: true,
            theme_id: FOLIO_THEME_ID.into(),
            appearance: AppearancePreference::System,
            hide_window_bar: false,
            hide_window_tabs: true,
            status_bar_uptime: false,
            project_directories: Vec::new(),
            notification_sound: false,
        }
    }
}

impl AppSettings {
    /// The legacy persistence key (`UserDefaults` → `StateStore`).
    pub const STATE_KEY: &'static str = "soprano-app-settings";

    pub fn default_settings() -> Self {
        Self::default()
    }

    /// Reads the pre-`settings.json` preferences, used once to seed that file so an upgrade
    /// does not reset someone's configuration.
    ///
    /// There is deliberately no `save` counterpart: settings are written to `settings.json`
    /// through `ConfigStore`, and a second store that could drift out of sync would be a bug
    /// waiting to happen.
    pub fn load(store: &StateStore) -> Self {
        store.get::<Self>(Self::STATE_KEY).unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn notification_sound_is_off_until_it_is_asked_for() {
        assert!(!AppSettings::default_settings().notification_sound);
    }

    #[test]
    fn the_window_bar_remains_visible_by_default() {
        assert!(!AppSettings::default_settings().hide_window_bar);
    }

    /// The stored payload predates this key. Decoding has to tolerate that, or the caller
    /// throws away every other setting alongside it.
    #[test]
    fn settings_stored_before_the_key_existed_still_decode() {
        let legacy = r#"{"restoreLastSession":false,"themeId":"nord","projectDirectories":["/tmp"]}"#;
        let decoded: AppSettings = serde_json::from_str(legacy).expect("decodes");
        assert!(!decoded.restore_last_session);
        assert_eq!(decoded.theme_id, "nord");
        assert_eq!(decoded.project_directories, ["/tmp"]);
        assert!(!decoded.notification_sound);
    }

    #[test]
    fn a_legacy_stored_payload_keeps_the_window_bar_visible() {
        let legacy = r#"{"restoreLastSession":false,"themeId":"nord","projectDirectories":[]}"#;
        let decoded: AppSettings = serde_json::from_str(legacy).expect("decodes");
        assert!(!decoded.hide_window_bar);
        assert!(!decoded.restore_last_session);
        assert_eq!(decoded.theme_id, "nord");
    }

    #[test]
    fn a_round_trip_through_json_keeps_the_sound_choice() {
        let settings = AppSettings { notification_sound: true, ..AppSettings::default() };
        let json = serde_json::to_string(&settings).expect("encodes");
        assert_eq!(serde_json::from_str::<AppSettings>(&json).expect("decodes"), settings);
    }

    #[test]
    fn legacy_settings_are_read_from_the_state_store() {
        let store = StateStore::in_memory();
        assert_eq!(AppSettings::load(&store), AppSettings::default());
        store
            .set_raw(AppSettings::STATE_KEY, serde_json::json!({"themeId": "dracula", "appearance": "dark"}));
        let loaded = AppSettings::load(&store);
        assert_eq!(loaded.theme_id, "dracula");
        assert_eq!(loaded.appearance, AppearancePreference::Dark);
        assert!(loaded.hide_window_tabs);
    }

    #[test]
    fn folio_and_every_palette_are_known_theme_ids() {
        assert_eq!(KNOWN_THEME_IDS.len(), 10);
        assert!(is_known_theme_id("folio-ink"));
        assert!(!is_known_theme_id("mission-control"));
    }
}
