//! Projects the Soprano tokens onto gpui-component's theme (HERDR-UI.md §2.1 gpui-kit mapping,
//! `src/mods.rs` `apply_theme`) so its Input, Editor, List, Popover and Scrollbar look like
//! Herdr, and installs Herdr's scrollbar (§13): thumb 6 px (8 hovered or dragged), inset 4,
//! square, min length 48, foreground at 35 % (55 % hovered), clear track, no motion.

use std::rc::Rc;

use gpui::{App, Hsla, Rgba};
use gpui_component::{Theme, ThemeConfig};
use serde_json::{Map, Value, json};

use super::SopranoTheme;
use crate::fonts;

/// `#rrggbbaa` for a GPUI color, the format gpui-component's theme files use.
fn hex(color: Hsla) -> Value {
    let rgba: Rgba = color.into();
    let ch = |v: f32| (v.clamp(0.0, 1.0) * 255.0).round() as u8;
    Value::String(format!("#{:02x}{:02x}{:02x}{:02x}", ch(rgba.r), ch(rgba.g), ch(rgba.b), ch(rgba.a)))
}

/// The gpui-component theme file for the current Soprano theme.
pub(crate) fn config(theme: &SopranoTheme) -> Value {
    let t = theme.tokens();
    let clear = Hsla::transparent_black();
    let thumb = t.foreground.opacity(0.35);
    let thumb_hover = t.foreground.opacity(0.55);
    let mut colors = Map::new();
    let mut set = |key: &str, color: Hsla| {
        colors.insert(key.to_owned(), hex(color));
    };
    // The gpui-kit mapping (primary = accent, secondary = muted = raised, accent = hover,
    // destructive = failed, ring = ring).
    set("background", t.background);
    set("foreground", t.foreground);
    set("border", t.border);
    set("input.border", t.input);
    set("ring", t.ring);
    set("selection.background", t.selection);
    set("caret", t.accent);
    set("link", t.accent);
    set("link.hover", t.accent);
    set("link.active", t.accent);
    set("primary.background", t.accent);
    set("primary.foreground", t.accent_foreground);
    set("secondary.background", t.raised);
    set("secondary.foreground", t.foreground);
    set("secondary.hover.background", t.selected);
    set("secondary.active.background", t.selected);
    set("muted.background", t.raised);
    set("muted.foreground", t.muted);
    set("accent.background", t.hover);
    set("accent.foreground", t.foreground);
    set("danger.background", t.failed);
    set("danger.foreground", t.background);
    set("success.background", t.done);
    set("success.foreground", t.background);
    set("warning.background", t.approval);
    set("warning.foreground", t.background);
    set("info.background", t.working);
    set("info.foreground", t.background);
    set("popover.background", t.popover);
    set("popover.foreground", t.foreground);
    set("list.background", clear);
    set("list.even.background", clear);
    set("list.head.background", clear);
    set("list.hover.background", t.hover);
    set("list.active.background", t.selected);
    set("list.active.border", clear);
    set("scrollbar.background", clear);
    set("scrollbar.thumb.background", thumb);
    set("scrollbar.thumb.hover.background", thumb_hover);
    set("sidebar.background", t.chrome);
    set("sidebar.foreground", t.foreground);
    set("sidebar.border", t.border);
    set("sidebar.accent.background", t.hover);
    set("sidebar.accent.foreground", t.foreground);
    set("sidebar.primary.background", t.selected);
    set("sidebar.primary.foreground", t.foreground);
    set("title_bar.background", t.chrome);
    set("title_bar.border", t.border);
    set("status_bar.background", t.chrome);
    set("status_bar.border", t.border);
    set("tab_bar.background", t.chrome);
    set("tab_bar.segmented.background", t.chrome);
    set("tab.background", t.chrome);
    set("tab.foreground", t.muted);
    set("tab.active.background", t.raised);
    set("tab.active.foreground", t.foreground);
    set("switch.background", t.input);
    set("switch.thumb.background", t.foreground);
    set("slider.background", t.accent);
    set("slider.thumb.background", t.foreground);
    set("progress.bar.background", t.accent);
    set("skeleton.background", t.raised);
    set("drag.border", t.accent);
    set("drop_target.background", t.accent.opacity(0.15));
    set("overlay", t.backdrop);
    set("window.border", t.border);
    set("table.background", t.background);
    set("table.head.background", t.chrome);
    set("table.head.foreground", t.muted);
    set("table.hover.background", t.hover);
    set("table.active.background", t.selected);
    set("table.active.border", clear);
    set("table.row.border", t.border);
    set("group_box.background", t.raised);
    set("group_box.foreground", t.foreground);
    set("group_box.title.foreground", t.dim);
    for (key, index) in [("red", 1), ("green", 2), ("yellow", 3), ("blue", 4), ("magenta", 5), ("cyan", 6)] {
        set(&format!("base.{key}"), t.ansi[index]);
        set(&format!("base.{key}.light"), t.ansi[index + 8]);
    }
    json!({
        "name": format!("Soprano {}", theme.theme().name),
        "mode": if t.is_dark() { "dark" } else { "light" },
        "font.family": fonts::UI_FONT_FAMILY,
        "font.size": fonts::size::UI * theme.zoom(),
        "mono_font.family": fonts::TERMINAL_FONT_FAMILY,
        "mono_font.size": fonts::size::FILE_PREVIEW * theme.zoom(),
        "radius": 6,
        "radius.lg": 8,
        "shadow": true,
        "colors": Value::Object(colors),
    })
}

/// Applies the current [`SopranoTheme`] to gpui-component and its Base layer. Needs
/// `gpui_component::init` to have run (done by [`crate::init`]).
pub(crate) fn apply(cx: &mut App) {
    if !cx.has_global::<Theme>() {
        return;
    }
    let config = match serde_json::from_value::<ThemeConfig>(config(SopranoTheme::global(cx))) {
        Ok(config) => Rc::new(config),
        Err(error) => {
            tracing::error!("Soprano theme did not map onto gpui-component: {error}");
            return;
        }
    };
    Theme::update(cx, |theme| {
        theme.apply_config(&config);
        theme.scrollbar_mode = gpui_component::scroll::ScrollbarMode::Scrolling;
    });
    install_scrollbar(cx);
}

/// Herdr's scrollbar: Base's defaults (6/8 px thumb, inset 4, radius 0, min 48, 2 s idle,
/// no enter/exit motion) with the foreground at 35 % / 55 % on a clear track.
fn install_scrollbar(cx: &mut App) {
    let t = SopranoTheme::global(cx).tokens();
    let (thumb, thumb_hover) = (t.foreground.opacity(0.35), t.foreground.opacity(0.55));
    let clear = Hsla::transparent_black();
    let mode = Theme::global(cx).scrollbar_mode;
    let styles = gpui_base::ScrollbarStyles::default()
        .track(|style| style.bg(clear))
        .track_hover(|style| style.bg(clear))
        .track_active(|style| style.bg(clear).border_color(clear))
        .thumb(|style| {
            style
                .bg(thumb)
                .width(gpui::px(6.))
                .inset(gpui::px(4.))
                .radius(gpui::px(0.))
                .min_length(gpui::px(48.))
        })
        .thumb_hover(|style| style.bg(thumb_hover).width(gpui::px(8.)).radius(gpui::px(0.)))
        .thumb_active(|style| style.bg(thumb_hover).width(gpui::px(8.)).radius(gpui::px(0.)));
    gpui_base::Theme::global_mut(cx).scrollbar = gpui_base::ScrollbarTheme::new()
        .with_mode(mode)
        .with_motion(gpui_base::ScrollbarMotion::default())
        .with_styles(styles);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::theme::{Appearance, AppearancePreference, ThemeManager};

    #[test]
    fn the_component_theme_file_parses_and_maps_herdr_roles() {
        let theme =
            SopranoTheme::new(ThemeManager::new("folio", AppearancePreference::Dark, Appearance::Dark));
        let value = config(&theme);
        assert_eq!(value["mode"], "dark");
        assert_eq!(value["colors"]["primary.background"], hex(theme.accent));
        assert_eq!(value["colors"]["accent.background"], hex(theme.hover));
        assert_eq!(value["colors"]["secondary.background"], hex(theme.raised));
        assert_eq!(value["colors"]["danger.background"], hex(theme.failed));
        let config: ThemeConfig = serde_json::from_value(value).expect("a valid gpui-component theme");
        assert!(config.mode.is_dark());
        assert_eq!(config.font_family.as_deref(), Some(fonts::UI_FONT_FAMILY));
    }
}
