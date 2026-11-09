//! Tooltips: the overlay frame (popover, 1 px border, radius 6, shadow) around 12 px text, with
//! an optional keycap row. Use with GPUI's `.tooltip(soprano_ui::tooltip("Close"))` on any
//! element with an id.

use gpui::{
    AnyView, App, AppContext as _, Context, IntoElement, ParentElement, Render, SharedString, Styled, Window,
    div, prelude::*,
};

use crate::fonts::{self, size};
use crate::keycaps::Keycaps;
use crate::theme::ActiveSopranoTheme;

/// The tooltip view.
pub struct Tooltip {
    text: SharedString,
    keycaps: Vec<String>,
}

impl Tooltip {
    pub fn new(text: impl Into<SharedString>) -> Self {
        Self { text: text.into(), keycaps: Vec::new() }
    }

    /// K1 caps shown after the text.
    pub fn keycaps(mut self, caps: Vec<String>) -> Self {
        self.keycaps = caps;
        self
    }

    pub fn build(self, cx: &mut App) -> AnyView {
        cx.new(|_| self).into()
    }
}

impl Render for Tooltip {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.soprano_theme();
        div().pt(theme.z(6.)).child(
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(theme.z(8.))
                .max_w(theme.z(360.))
                .px(theme.z(8.))
                .py(theme.z(4.))
                .rounded(theme.z(6.))
                .bg(theme.popover)
                .border_1()
                .border_color(theme.border)
                .shadow_md()
                .font_family(fonts::UI_FONT_FAMILY)
                .text_size(theme.z(size::META))
                .text_color(theme.foreground)
                .child(self.text.clone())
                .when(!self.keycaps.is_empty(), |row| row.child(Keycaps::new(self.keycaps.clone()).small())),
        )
    }
}

/// A tooltip builder for GPUI's `.tooltip(…)`.
pub fn tooltip(text: impl Into<SharedString>) -> impl Fn(&mut Window, &mut App) -> AnyView + 'static {
    let text = text.into();
    move |_, cx| Tooltip::new(text.clone()).build(cx)
}

/// A tooltip with keycaps (`Split right  ⌘D`).
pub fn tooltip_with_keycaps(
    text: impl Into<SharedString>,
    caps: Vec<String>,
) -> impl Fn(&mut Window, &mut App) -> AnyView + 'static {
    let text = text.into();
    move |_, cx| Tooltip::new(text.clone()).keycaps(caps.clone()).build(cx)
}
