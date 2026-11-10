//! Soprano's design system in GPUI: Herdr's look (HERDR-UI.md) over Soprano's themes and
//! semantics.
//!
//! Start-up: serve assets with `Application::new().with_assets(SopranoAssets::from_resources_dir())`,
//! call [`init`] once, wrap each window's root view in `gpui_component::Root`, keep
//! `SopranoTheme::observe_system_appearance(window)` alive per window, and call
//! `cx.soprano_theme().apply_to_window(window)` at the top of the root view's `render`.

pub mod assets;
pub mod button;
pub mod chrome;
pub mod color;
pub mod controls;
pub mod dialog;
pub mod fonts;
pub mod icons;
pub mod identity;
pub mod keycaps;
pub mod menu;
pub mod motion;
pub mod picker;
pub mod select;
#[cfg(feature = "snapshot")]
pub mod snapshot;
pub mod status;
pub mod theme;
pub mod toast;
pub mod tooltip;

pub use assets::SopranoAssets;
pub use button::{Button, ButtonSize, ButtonVariant, IconButton, IconButtonSize};
pub use chrome::{
    Card, CardHeader, PanelToggle, ScrollList, SectionHeader, SidebarRow, StatusBar, StatusBarItem, TabPill,
};
pub use controls::{InputSize, SegmentedControl, Switch, TextInput, text_input};
pub use dialog::{Dialog, DialogButton, DialogContent, DialogResult};
pub use gpui_component::input::{InputEvent, InputState};
pub use icons::{Icon, IconName, agent_icon_stem, file_type_icon, folder_icon, icon, program_icon_path};
pub use identity::{Avatar, Monogram, monogram, project_color, project_color_index};
pub use keycaps::{Keycaps, keycaps};
pub use menu::{ContextMenu, MenuItem};
pub use picker::{Picker, PickerEvent, PickerItem};
pub use select::{Select, SelectChanged, SelectOption};
pub use status::{StatusClock, StatusGlyph, StatusPill, StatusPillSpec, TabBadge, TabBadgeView};
pub use theme::{ActiveSopranoTheme, Appearance, AppearancePreference, SopranoTheme, StatusTone};
pub use toast::{Toast, ToastLevel, ToastStack};
pub use tooltip::{Tooltip, tooltip, tooltip_with_keycaps};

use gpui::App;

/// Sets up the design system once at start-up: gpui-component, the [`SopranoTheme`] global
/// for `theme_id`/`appearance` (`folio` resolves by the OS appearance) with gpui-component
/// themed to match, and the bundled fonts from `<resources>/fonts` (a failure is logged; text
/// then falls back to system fonts).
pub fn init(cx: &mut App, theme_id: &str, appearance: AppearancePreference) {
    gpui_component::init(cx);
    picker::bind_keys(cx);
    SopranoTheme::install(theme_id, appearance, cx);
    if let Err(error) = fonts::register_fonts(cx) {
        tracing::warn!("Soprano fonts not registered: {error:#}");
    }
}

/// [`init`] for tests: no font loading, the `folio` theme under a dark appearance.
pub fn init_for_tests(cx: &mut App) {
    gpui_component::init(cx);
    picker::bind_keys(cx);
    SopranoTheme::install(theme::FOLIO_ID, AppearancePreference::Dark, cx);
}
