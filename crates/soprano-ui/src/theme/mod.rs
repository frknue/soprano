//! Themes: Soprano's palettes, Herdr's token derivation, the live [`SopranoTheme`] global with
//! zoom and Reduce Motion, and the projection onto gpui-component's theme.

mod component;
mod manager;
mod palettes;
mod tokens;

use std::ops::Deref;

use gpui::{App, Global, Pixels, Subscription, Window, px};

pub use manager::ThemeManager;
pub use palettes::{
    ALL_THEMES, ATOM_ONE_DARK, AppTheme, Appearance, AppearancePreference, CATPPUCCIN_MOCHA, DRACULA,
    FOLIO_ID, FOLIO_INK, FOLIO_PAPER, GRAPH_LANE_COUNT, GRUVBOX_DARK, MINIMUM_LANE_DISTANCE, NORD,
    SOLARIZED_DARK, SyntaxColors, TOKYO_NIGHT, TerminalColors, ThemeColors, ThemeOption, is_known_theme_id,
    theme_for, theme_options,
};
pub use tokens::{HerdrColors, Lamp, SemanticColors, StatusTone, SyntaxTokens, Tokens};

/// GPUI's rem at zoom 1: Herdr sets `rem = ui_font_size × zoom` = 13 px.
pub const REM: f32 = 13.0;
pub const MIN_ZOOM: f32 = 0.5;
pub const MAX_ZOOM: f32 = 3.0;
pub const ZOOM_STEP: f32 = 0.1;

/// The live theme: the resolved palette's tokens, the zoom factor and Reduce Motion.
/// Installed as a GPUI global by [`crate::init`]; read it with
/// [`ActiveSopranoTheme::soprano_theme`] (`cx.soprano_theme().hover`, `cx.soprano_theme().z(30.)`).
/// Observe it with `cx.observe_global::<SopranoTheme>(…)`: every change goes through
/// `update_global`, so observers fire.
#[derive(Clone, Debug)]
pub struct SopranoTheme {
    manager: ThemeManager,
    tokens: Tokens,
    zoom: f32,
    reduce_motion: bool,
}

impl Global for SopranoTheme {}

impl Deref for SopranoTheme {
    type Target = Tokens;

    fn deref(&self) -> &Tokens {
        &self.tokens
    }
}

/// `cx.soprano_theme()` on `App` and every `Context<T>`.
pub trait ActiveSopranoTheme {
    fn soprano_theme(&self) -> &SopranoTheme;
}

impl ActiveSopranoTheme for App {
    fn soprano_theme(&self) -> &SopranoTheme {
        SopranoTheme::global(self)
    }
}

impl SopranoTheme {
    pub fn new(manager: ThemeManager) -> Self {
        let tokens = Tokens::new(manager.current());
        Self { manager, tokens, zoom: 1.0, reduce_motion: false }
    }

    /// The installed theme. Panics only when [`crate::init`] was never called.
    pub fn global(cx: &App) -> &Self {
        cx.global::<Self>()
    }

    /// Installs (or replaces) the global for `theme_id` and `appearance`, resolving `folio`
    /// against the OS appearance, and themes gpui-component to match.
    pub fn install(theme_id: &str, appearance: AppearancePreference, cx: &mut App) {
        let system = Appearance::from_window(cx.window_appearance());
        let (zoom, reduce_motion) =
            cx.try_global::<Self>().map(|theme| (theme.zoom, theme.reduce_motion)).unwrap_or((1.0, false));
        let mut manager = ThemeManager::new(theme_id, appearance, system);
        Self::drive_app_appearance(&mut manager, cx);
        let mut theme = Self::new(manager);
        theme.zoom = zoom;
        theme.reduce_motion = reduce_motion;
        cx.set_global(theme);
        Self::did_change(cx);
    }

    /// `applyApplicationAppearance`: the app's windows, menus, alerts and panels follow the
    /// OS while `folio` follows the system, else take the resolved theme's appearance. While
    /// following, the system appearance is re-read (an override no longer masks it).
    fn drive_app_appearance(manager: &mut ThemeManager, cx: &App) {
        cx.set_window_appearance(manager.app_appearance().map(|appearance| match appearance {
            Appearance::Light => gpui::WindowAppearance::Light,
            Appearance::Dark => gpui::WindowAppearance::Dark,
        }));
        if manager.follows_system() {
            manager.set_system_appearance(Appearance::from_window(cx.window_appearance()));
        }
    }

    /// The concrete palette in force.
    pub fn theme(&self) -> &'static AppTheme {
        self.manager.current()
    }

    pub fn manager(&self) -> &ThemeManager {
        &self.manager
    }

    pub fn tokens(&self) -> &Tokens {
        &self.tokens
    }

    pub fn zoom(&self) -> f32 {
        self.zoom
    }

    /// A designed length at the current zoom (Herdr's `z()`).
    pub fn z(&self, designed: f32) -> Pixels {
        px(designed * self.zoom)
    }

    /// The rem size windows should use: 13 px × zoom.
    pub fn rem_size(&self) -> Pixels {
        self.z(REM)
    }

    pub fn reduce_motion(&self) -> bool {
        self.reduce_motion
    }

    /// Sets the window's rem to [`Self::rem_size`] so GPUI's rem-based helpers match Herdr.
    /// Call it at the top of the root view's `render`.
    pub fn apply_to_window(&self, window: &mut Window) {
        window.set_rem_size(self.rem_size());
    }

    pub fn set_theme(id: &str, cx: &mut App) {
        Self::change(cx, |manager| {
            manager.set_theme(id);
        });
    }

    pub fn set_appearance(appearance: AppearancePreference, cx: &mut App) {
        Self::change(cx, |manager| {
            manager.set_appearance(appearance);
        });
    }

    /// Applies the `theme` and `appearance` settings together.
    pub fn update_settings(theme_id: &str, appearance: AppearancePreference, cx: &mut App) {
        Self::change(cx, |manager| {
            manager.update(theme_id, appearance);
        });
    }

    /// The OS switched between light and dark.
    pub fn set_system_appearance(system: Appearance, cx: &mut App) {
        Self::change(cx, |manager| {
            manager.set_system_appearance(system);
        });
    }

    /// Keeps `folio` following the OS: re-resolves whenever `window`'s appearance changes.
    pub fn observe_system_appearance(window: &Window) -> Subscription {
        window.observe_window_appearance(|window, cx| {
            Self::set_system_appearance(Appearance::from_window(window.appearance()), cx);
        })
    }

    /// Sets the zoom, rounded to 0.1 steps and clamped to 0.5…3.0.
    pub fn set_zoom(zoom: f32, cx: &mut App) {
        let zoom = clamp_zoom(zoom);
        if (cx.soprano_theme().zoom - zoom).abs() < f32::EPSILON {
            return;
        }
        cx.global_mut::<Self>().zoom = zoom;
        Self::did_change(cx);
    }

    /// ⌘= : one step larger.
    pub fn zoom_in(cx: &mut App) {
        Self::set_zoom(cx.soprano_theme().zoom + ZOOM_STEP, cx);
    }

    /// ⌘- : one step smaller.
    pub fn zoom_out(cx: &mut App) {
        Self::set_zoom(cx.soprano_theme().zoom - ZOOM_STEP, cx);
    }

    /// ⌘0 : back to 1.
    pub fn reset_zoom(cx: &mut App) {
        Self::set_zoom(1.0, cx);
    }

    /// Reduce Motion: no fades and no spinning (also sets GPUI's own flag, which stops
    /// every `with_animation`).
    pub fn set_reduce_motion(reduce_motion: bool, cx: &mut App) {
        cx.set_reduce_motion(reduce_motion);
        if cx.soprano_theme().reduce_motion != reduce_motion {
            cx.global_mut::<Self>().reduce_motion = reduce_motion;
            cx.refresh_windows();
        }
    }

    fn change(cx: &mut App, apply: impl FnOnce(&mut ThemeManager)) {
        let before = cx.soprano_theme().manager.clone();
        let mut manager = before.clone();
        apply(&mut manager);
        // Every update re-applies the app appearance, even when the palette stays.
        Self::drive_app_appearance(&mut manager, cx);
        let changed = manager.current().id != before.current().id;
        if !changed
            && manager.theme_id() == before.theme_id()
            && manager.appearance() == before.appearance()
            && manager.system_appearance() == before.system_appearance()
        {
            return;
        }
        let theme = cx.global_mut::<Self>();
        theme.manager = manager;
        if changed {
            theme.tokens = Tokens::new(theme.manager.current());
            Self::did_change(cx);
        }
    }

    fn did_change(cx: &mut App) {
        component::apply(cx);
        cx.refresh_windows();
    }
}

fn clamp_zoom(zoom: f32) -> f32 {
    ((zoom / ZOOM_STEP).round() * ZOOM_STEP).clamp(MIN_ZOOM, MAX_ZOOM)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zoom_moves_in_tenths_between_half_and_triple_size() {
        assert!((clamp_zoom(1.04) - 1.0).abs() < 1e-6);
        assert!((clamp_zoom(1.06) - 1.1).abs() < 1e-6);
        assert!((clamp_zoom(0.2) - MIN_ZOOM).abs() < 1e-6);
        assert!((clamp_zoom(9.0) - MAX_ZOOM).abs() < 1e-6);
    }

    #[test]
    fn z_scales_designed_lengths_by_the_zoom() {
        let mut theme =
            SopranoTheme::new(ThemeManager::new("nord", AppearancePreference::Dark, Appearance::Dark));
        assert_eq!(theme.z(30.0), px(30.0));
        theme.zoom = 1.5;
        assert_eq!(theme.z(30.0), px(45.0));
        assert_eq!(theme.rem_size(), px(19.5));
        assert_eq!(theme.theme().id, "nord");
        assert_eq!(theme.hover, theme.tokens().hover);
    }
}
