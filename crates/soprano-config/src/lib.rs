//! soprano-config: everything `settings.json` owns (see docs/rust-rewrite/PLAN.md).
//!
//! - [`jsonc`]: comment/trailing-comma tolerant reading and comment-preserving key writes.
//! - [`config_file`]: where the file lives, atomic writes through symlinks, the first-run
//!   template.
//! - [`SopranoConfig`] → [`ResolvedConfig`]: the file over the built-in defaults, with
//!   [`ConfigIssue`]s instead of failures.
//! - [`ConfigStore`]: the live projection of the file (load, watch, write, observers).
//! - [`KeyChord`], keycaps and [`DefaultKeybindings`]: shortcut text ↔ bindings.
//! - [`AppSettings`], [`Automation`] entries, [`CronSchedule`], [`AppVersion`].

pub mod app_settings;
pub mod app_version;
pub mod automation;
pub mod config;
pub mod config_file;
pub mod cron;
pub mod default_keybindings;
pub mod jsonc;
pub mod key_chord;
pub mod store;
pub mod watcher;

pub use app_settings::{
    AppSettings, AppearancePreference, FOLIO_THEME_ID, KNOWN_THEME_IDS, is_known_theme_id,
};
pub use app_version::AppVersion;
pub use automation::{Automation, AutomationEntry, AutomationSession, AutomationWorkspace};
pub use config::{
    AgentConfig, BindingOverride, ConfigIssue, KeybindingsConfig, Limits, NotificationsConfig,
    ResolvedConfig, Severity, SopranoConfig, StatusBarConfig, expand_path, install_agents,
};
pub use cron::{AutomationCadence, CronParseError, CronSchedule};
pub use default_keybindings::DefaultKeybindings;
pub use key_chord::{
    KeyChord, KeyPlatform, PlatformModifiers, keycaps, keycaps_for, prefix_legend, prefix_legend_for,
    settings_keycap_alternatives, settings_keycap_alternatives_for,
};
pub use store::{ConfigSnapshot, ConfigStore};
pub use watcher::ConfigFileWatcher;
