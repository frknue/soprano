//! Buttons: Herdr's icon buttons (26×26 r6 in chrome, p3 r4 in pane headers) with Soprano's
//! `GhostIconButton` states, and text buttons (`TextButton`/`ShellTextButton` variants in
//! Herdr's dialog-button look: h32 px14 r8, hover opacity 0.88).

use std::rc::Rc;

use gpui::{
    AnyElement, App, ClickEvent, ElementId, FontWeight, Hsla, InteractiveElement, IntoElement, MouseButton,
    ParentElement, RenderOnce, SharedString, StatefulInteractiveElement, Styled, Window, div, prelude::*,
};

use crate::fonts::size;
use crate::icons::{Icon, IconName, icon};
use crate::theme::ActiveSopranoTheme;
use crate::tooltip::tooltip;

pub type ClickHandler = Rc<dyn Fn(&ClickEvent, &mut Window, &mut App)>;

/// Where an icon button sits.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum IconButtonSize {
    /// 26×26, radius 6, 15 px glyph: brand row, section headers, tab row.
    #[default]
    Chrome,
    /// Padding 3, radius 4, 14 px glyph: pane header hover buttons.
    Pane,
    /// Padding 2, radius 4, 12 px glyph: a tab's close button.
    Tab,
}

/// A square glyph button: transparent at rest in `muted` (or its own tint), `hover` fill and
/// `foreground` under the pointer, `selected` fill while toggled on. Mouse-down never reaches
/// the window, so a button in a drag region does not move the window.
#[derive(IntoElement)]
pub struct IconButton {
    id: ElementId,
    glyph: Icon,
    size: IconButtonSize,
    icon_size: Option<f32>,
    color: Option<Hsla>,
    selected: bool,
    disabled: bool,
    tooltip: Option<SharedString>,
    on_click: Option<ClickHandler>,
}

impl IconButton {
    pub fn new(id: impl Into<ElementId>, name: IconName) -> Self {
        Self::with_icon(id, Icon::new(name))
    }

    /// A button showing any icon (e.g. `Icon::program("claude")`).
    pub fn with_icon(id: impl Into<ElementId>, glyph: Icon) -> Self {
        Self {
            id: id.into(),
            glyph,
            size: IconButtonSize::Chrome,
            icon_size: None,
            color: None,
            selected: false,
            disabled: false,
            tooltip: None,
            on_click: None,
        }
    }

    pub fn size(mut self, size: IconButtonSize) -> Self {
        self.size = size;
        self
    }

    /// Glyph side in designed px (defaults: chrome 15, pane 14, tab 12).
    pub fn icon_size(mut self, side: f32) -> Self {
        self.icon_size = Some(side);
        self
    }

    /// Resting tint (default `muted`).
    pub fn color(mut self, color: Hsla) -> Self {
        self.color = Some(color);
        self
    }

    /// Toggled on: `selected` fill and `foreground` glyph.
    pub fn selected(mut self, selected: bool) -> Self {
        self.selected = selected;
        self
    }

    pub fn disabled(mut self, disabled: bool) -> Self {
        self.disabled = disabled;
        self
    }

    pub fn tooltip(mut self, text: impl Into<SharedString>) -> Self {
        self.tooltip = Some(text.into());
        self
    }

    pub fn on_click(mut self, handler: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static) -> Self {
        self.on_click = Some(Rc::new(handler));
        self
    }
}

impl RenderOnce for IconButton {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let (default_icon, radius) = match self.size {
            IconButtonSize::Chrome => (15.0, 6.0),
            IconButtonSize::Pane => (14.0, 4.0),
            IconButtonSize::Tab => (12.0, 4.0),
        };
        let resting = self.color.unwrap_or(theme.muted);
        let tint = if self.disabled {
            resting.opacity(0.5)
        } else if self.selected {
            theme.foreground
        } else {
            resting
        };
        let (hover_fill, hover_fg) = (theme.hover, theme.foreground);
        let enabled = !self.disabled;
        let glyph = self.glyph.size(self.icon_size.unwrap_or(default_icon)).color(tint);
        div()
            .id(self.id)
            .flex()
            .flex_none()
            .items_center()
            .justify_center()
            .rounded(theme.z(radius))
            .map(|button| match self.size {
                IconButtonSize::Chrome => button.size(theme.z(26.)),
                IconButtonSize::Pane => button.p(theme.z(3.)),
                IconButtonSize::Tab => button.p(theme.z(2.)),
            })
            .when(self.selected, |button| button.bg(theme.selected))
            .when(enabled, |button| {
                button.cursor_pointer().hover(move |style| style.bg(hover_fill).text_color(hover_fg))
            })
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .child(glyph)
            .when_some(self.tooltip, |button, text| button.tooltip(tooltip(text)))
            .when_some(self.on_click.filter(|_| enabled), |button, handler| {
                button.on_click(move |event, window, cx| handler(event, window, cx))
            })
    }
}

/// Text button variants (`TextButton.Variant`, `ShellTextButton.Variant`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ButtonVariant {
    /// `solid` fill, `solid_foreground` text: the default action.
    Primary,
    /// `raised` fill with an `input` border: Cancel and other secondary actions.
    #[default]
    Secondary,
    /// No fill until hovered.
    Ghost,
    /// `failed` fill, white text.
    Destructive,
    /// A faint `failed` ring and `failed` text (Don't Save).
    DestructiveOutline,
    /// Bare text in `muted`, `foreground` on hover: inline links and footers.
    Text,
}

/// Text button heights (`TextButton.Size`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ButtonSize {
    /// h24, px 8, 12 px text.
    Xs,
    /// h28, px 10, 12 px text.
    Sm,
    /// h32, px 14, 12 px text: dialog buttons.
    #[default]
    Regular,
}

/// A text button with an optional leading icon and trailing keycap chip.
#[derive(IntoElement)]
pub struct Button {
    id: ElementId,
    label: SharedString,
    variant: ButtonVariant,
    size: ButtonSize,
    icon: Option<IconName>,
    keycap: Option<SharedString>,
    disabled: bool,
    full_width: bool,
    tooltip: Option<SharedString>,
    on_click: Option<ClickHandler>,
}

impl Button {
    pub fn new(id: impl Into<ElementId>, label: impl Into<SharedString>) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            variant: ButtonVariant::Secondary,
            size: ButtonSize::Regular,
            icon: None,
            keycap: None,
            disabled: false,
            full_width: false,
            tooltip: None,
            on_click: None,
        }
    }

    pub fn variant(mut self, variant: ButtonVariant) -> Self {
        self.variant = variant;
        self
    }

    pub fn primary(self) -> Self {
        self.variant(ButtonVariant::Primary)
    }

    pub fn ghost(self) -> Self {
        self.variant(ButtonVariant::Ghost)
    }

    pub fn size(mut self, size: ButtonSize) -> Self {
        self.size = size;
        self
    }

    pub fn icon(mut self, icon: IconName) -> Self {
        self.icon = Some(icon);
        self
    }

    /// A keyboard hint chip after the label (`⌘↵`).
    pub fn keycap(mut self, keycap: impl Into<SharedString>) -> Self {
        self.keycap = Some(keycap.into());
        self
    }

    pub fn disabled(mut self, disabled: bool) -> Self {
        self.disabled = disabled;
        self
    }

    pub fn full_width(mut self) -> Self {
        self.full_width = true;
        self
    }

    pub fn tooltip(mut self, text: impl Into<SharedString>) -> Self {
        self.tooltip = Some(text.into());
        self
    }

    pub fn on_click(mut self, handler: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static) -> Self {
        self.on_click = Some(Rc::new(handler));
        self
    }
}

impl RenderOnce for Button {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let (height, padding, radius) = match self.size {
            ButtonSize::Xs => (24.0, 8.0, 6.0),
            ButtonSize::Sm => (28.0, 10.0, 8.0),
            ButtonSize::Regular => (32.0, 14.0, 8.0),
        };
        let white = gpui::white();
        let (fill, text, border): (Option<Hsla>, Hsla, Option<Hsla>) = match self.variant {
            ButtonVariant::Primary => (Some(theme.solid), theme.solid_foreground, None),
            ButtonVariant::Secondary => (Some(theme.raised), theme.foreground, Some(theme.input)),
            ButtonVariant::Ghost => (None, theme.foreground, None),
            ButtonVariant::Destructive => (Some(theme.failed), white, None),
            ButtonVariant::DestructiveOutline => (None, theme.failed, Some(theme.failed.opacity(0.4))),
            ButtonVariant::Text => (None, theme.muted, None),
        };
        let enabled = !self.disabled;
        let hover = theme.hover;
        let foreground = theme.foreground;
        let failed_wash = theme.failed.opacity(0.08);
        let chip_fill = if self.variant == ButtonVariant::Primary {
            theme.solid_foreground.opacity(0.18)
        } else {
            theme.foreground.opacity(0.07)
        };
        let chip_text = if self.variant == ButtonVariant::Primary { text } else { theme.muted };
        let variant = self.variant;
        let content: Vec<AnyElement> = [
            self.icon.map(|name| {
                icon(name)
                    .size(if self.size == ButtonSize::Xs { 12. } else { 14. })
                    .color(text)
                    .into_any_element()
            }),
            Some(div().truncate().child(self.label).into_any_element()),
            self.keycap.map(|keycap| {
                div()
                    .flex()
                    .items_center()
                    .justify_center()
                    .h(theme.z(18.))
                    .min_w(theme.z(18.))
                    .px(theme.z(4.))
                    .rounded(theme.z(4.))
                    .bg(chip_fill)
                    .text_color(chip_text)
                    .text_size(theme.z(size::SMALL))
                    .child(keycap)
                    .into_any_element()
            }),
        ]
        .into_iter()
        .flatten()
        .collect();
        div()
            .id(self.id)
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .justify_center()
            .gap(theme.z(6.))
            .when(variant != ButtonVariant::Text, |b| b.h(theme.z(height)).px(theme.z(padding)))
            .rounded(theme.z(radius))
            .when(self.full_width, |b| b.w_full())
            .when_some(fill, |b, fill| b.bg(fill))
            .when_some(border, |b, border| b.border_1().border_color(border))
            .text_color(text)
            .text_size(theme.z(size::META))
            .font_weight(FontWeight::MEDIUM)
            .whitespace_nowrap()
            .when(!enabled, |b| b.opacity(0.5))
            .when(enabled, |b| {
                b.cursor_pointer().hover(move |style| match variant {
                    ButtonVariant::Primary | ButtonVariant::Secondary | ButtonVariant::Destructive => {
                        style.opacity(0.88)
                    }
                    ButtonVariant::Ghost => style.bg(hover),
                    ButtonVariant::DestructiveOutline => style.bg(failed_wash),
                    ButtonVariant::Text => style.text_color(foreground),
                })
            })
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .children(content)
            .when_some(self.tooltip, |b, text| b.tooltip(tooltip(text)))
            .when_some(self.on_click.filter(|_| enabled), |b, handler| {
                b.on_click(move |event, window, cx| handler(event, window, cx))
            })
    }
}
