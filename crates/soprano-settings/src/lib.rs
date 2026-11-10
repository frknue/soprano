//! soprano-settings: the Settings card (General, Machines, Keyboard Shortcuts, Agent Profiles,
//! Accounts, About) shown over the window, and the status bar's account usage popover.
//!
//! - [`SettingsView`]: the card; construct it with a [`soprano_config::ConfigStore`], the
//!   accounts source and a [`NotificationStatusProvider`]; it emits [`SettingsEvent`]s.
//! - [`AccountUsagePopover`]: every account's usage windows; emits [`UsagePopoverEvent`]s.
//! - The page logic (`general`, `shortcuts`, `agents`, `about`, `notifications`) is plain
//!   Rust over the store, testable without a window.

pub mod about;
pub mod agents;
mod form;
pub mod general;
pub mod notifications;
pub mod os_notifications;
mod pages;
pub mod shortcuts;
pub mod tab;
mod usage_popover;
mod view;

pub use notifications::{
    NotificationAuthorization, NotificationStatusProvider, NotificationStatusRow, StatusTone,
};
pub use os_notifications::{NotificationPlatform, open_notification_settings};
pub use tab::SettingsTab;
pub use usage_popover::{AccountUsagePopover, UsagePopoverEvent, usage_bar_color, usage_percent_color};
pub use view::{
    CARD_MARGIN, CARD_MAX_HEIGHT, CARD_MAX_WIDTH, NAV_WIDTH, PAGE_MAX_WIDTH, SettingsEvent, SettingsView,
};
#[cfg(test)]
mod view_tests;
