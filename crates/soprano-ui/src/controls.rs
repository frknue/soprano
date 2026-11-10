//! Form controls: the toggle switch, the segmented control (`ShellSegmentedControl`) and the
//! text input (gpui-component's `Input` in Herdr's field look).

use std::rc::Rc;

use gpui::{
    App, ElementId, Entity, Focusable, FontWeight, InteractiveElement, IntoElement, MouseButton,
    ParentElement, RenderOnce, SharedString, StatefulInteractiveElement, Styled, Window, div, prelude::*,
};
use gpui_component::input::{Input, InputState};

use crate::fonts::size;

/// Called with a switch's new value.
pub type ToggleHandler = Rc<dyn Fn(bool, &mut Window, &mut App)>;
/// Called with a chosen segment.
pub type IndexHandler = Rc<dyn Fn(usize, &mut Window, &mut App)>;
use crate::theme::ActiveSopranoTheme;

/// An on/off switch, 28×16. On tracks are ink (`solid`) with a `solid_foreground` knob; off
/// tracks are `input` with a `muted` knob. No motion: the knob jumps.
#[derive(IntoElement)]
pub struct Switch {
    id: ElementId,
    on: bool,
    disabled: bool,
    on_change: Option<ToggleHandler>,
}

impl Switch {
    pub fn new(id: impl Into<ElementId>, on: bool) -> Self {
        Self { id: id.into(), on, disabled: false, on_change: None }
    }

    pub fn disabled(mut self, disabled: bool) -> Self {
        self.disabled = disabled;
        self
    }

    /// Called with the new value when clicked.
    pub fn on_change(mut self, handler: impl Fn(bool, &mut Window, &mut App) + 'static) -> Self {
        self.on_change = Some(Rc::new(handler));
        self
    }
}

impl RenderOnce for Switch {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let (track, knob) =
            if self.on { (theme.solid, theme.solid_foreground) } else { (theme.input, theme.muted) };
        let on = self.on;
        let enabled = !self.disabled;
        div()
            .id(self.id)
            .flex()
            .flex_none()
            .items_center()
            .w(theme.z(28.))
            .h(theme.z(16.))
            .p(theme.z(2.))
            .rounded(theme.z(8.))
            .bg(track)
            .when(on, |s| s.justify_end())
            .when(!enabled, |s| s.opacity(0.5))
            .when(enabled, |s| s.cursor_pointer())
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .child(div().size(theme.z(12.)).rounded(theme.z(6.)).bg(knob))
            .when_some(self.on_change.filter(|_| enabled), |s, handler| {
                s.on_click(move |_, window, cx| handler(!on, window, cx))
            })
    }
}

/// A row of tab-style segments: h24, radius 6, 12 px; the selected one `selected` with
/// `foreground` medium text, others `muted` with a `hover` fill. Disabled segments are muted
/// at 45 % and ignore clicks; a click on the selected segment does nothing.
#[derive(IntoElement)]
pub struct SegmentedControl {
    id: ElementId,
    titles: Vec<SharedString>,
    selected: usize,
    disabled: Vec<usize>,
    well: bool,
    on_select: Option<IndexHandler>,
}

impl SegmentedControl {
    pub fn new(id: impl Into<ElementId>, titles: impl IntoIterator<Item = impl Into<SharedString>>) -> Self {
        Self {
            id: id.into(),
            titles: titles.into_iter().map(Into::into).collect(),
            selected: 0,
            disabled: Vec::new(),
            well: false,
            on_select: None,
        }
    }

    pub fn selected(mut self, index: usize) -> Self {
        self.selected = index;
        self
    }

    pub fn disabled_segments(mut self, indices: impl IntoIterator<Item = usize>) -> Self {
        self.disabled = indices.into_iter().collect();
        self
    }

    /// Sets the segments in a well (`canvas`, 1 px border, radius 8, 2 px inset): for a
    /// control that stands on its own in a form or toolbar rather than in a row of tabs.
    pub fn well(mut self) -> Self {
        self.well = true;
        self
    }

    pub fn on_select(mut self, handler: impl Fn(usize, &mut Window, &mut App) + 'static) -> Self {
        self.on_select = Some(Rc::new(handler));
        self
    }
}

impl RenderOnce for SegmentedControl {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let hover = theme.hover;
        let segments = self.titles.into_iter().enumerate().map(|(index, title)| {
            let active = index == self.selected;
            let enabled = !self.disabled.contains(&index);
            let color = if !enabled {
                theme.muted.opacity(0.45)
            } else if active {
                theme.foreground
            } else {
                theme.muted
            };
            let handler = self.on_select.clone().filter(|_| enabled && !active);
            div()
                .id(ElementId::NamedInteger(format!("{:?}", self.id).into(), index as u64))
                .flex()
                .items_center()
                .justify_center()
                .h(theme.z(24.))
                .px(theme.z(10.))
                .rounded(theme.z(6.))
                .text_color(color)
                .font_weight(if active { FontWeight::MEDIUM } else { FontWeight::NORMAL })
                .when(active, |s| s.bg(theme.selected))
                .when(enabled && !active, |s| s.cursor_pointer().hover(move |st| st.bg(hover)))
                .child(title)
                .when_some(handler, |s, handler| s.on_click(move |_, window, cx| handler(index, window, cx)))
        });
        div()
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(theme.z(2.))
            .text_size(theme.z(size::META))
            .when(self.well, |control| {
                control
                    .p(theme.z(2.))
                    .rounded(theme.z(8.))
                    .border_1()
                    .border_color(theme.border)
                    .bg(theme.canvas)
            })
            .children(segments)
    }
}

/// Text field heights.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum InputSize {
    /// h28, radius 7.
    Small,
    /// h32, radius 8 (commit message, settings fields).
    #[default]
    Regular,
    /// h36, radius 9 (dialog prompt, picker search).
    Large,
}

/// A single-line text field over gpui-component's [`InputState`]: px 10, `background` fill,
/// 1 px border that is `accent` while focused (always `accent` with [`TextInput::accent`]),
/// 12.8 px text. Subscribe to the state's `InputEvent`s for changes and Enter.
#[derive(IntoElement)]
pub struct TextInput {
    state: Entity<InputState>,
    size: InputSize,
    always_accent: bool,
    invalid: bool,
    prefix: Option<gpui::AnyElement>,
    suffix: Option<gpui::AnyElement>,
}

/// `text_input(&state)`.
pub fn text_input(state: &Entity<InputState>) -> TextInput {
    TextInput::new(state)
}

impl TextInput {
    pub fn new(state: &Entity<InputState>) -> Self {
        Self {
            state: state.clone(),
            size: InputSize::Regular,
            always_accent: false,
            invalid: false,
            prefix: None,
            suffix: None,
        }
    }

    pub fn size(mut self, size: InputSize) -> Self {
        self.size = size;
        self
    }

    pub fn small(self) -> Self {
        self.size(InputSize::Small)
    }

    pub fn large(self) -> Self {
        self.size(InputSize::Large)
    }

    /// The palette and picker search fields keep an accent border.
    pub fn accent(mut self) -> Self {
        self.always_accent = true;
        self
    }

    /// A validation error: `failed` border.
    pub fn invalid(mut self, invalid: bool) -> Self {
        self.invalid = invalid;
        self
    }

    /// A leading element (a search icon).
    pub fn prefix(mut self, element: impl IntoElement) -> Self {
        self.prefix = Some(element.into_any_element());
        self
    }

    /// A trailing element (an "Esc" hint, keycaps).
    pub fn suffix(mut self, element: impl IntoElement) -> Self {
        self.suffix = Some(element.into_any_element());
        self
    }
}

impl RenderOnce for TextInput {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let focused = self.state.read(cx).focus_handle(cx).is_focused(window);
        let theme = cx.soprano_theme();
        let (height, radius) = match self.size {
            InputSize::Small => (28.0, 7.0),
            InputSize::Regular => (32.0, 8.0),
            InputSize::Large => (36.0, 9.0),
        };
        let border = if self.invalid {
            theme.failed
        } else if focused || self.always_accent {
            theme.accent
        } else {
            theme.input
        };
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap(theme.z(8.))
            .h(theme.z(height))
            .px(theme.z(10.))
            .rounded(theme.z(radius))
            .border_1()
            .border_color(border)
            .bg(theme.background)
            .text_size(theme.z(size::ROW))
            .text_color(theme.foreground)
            .children(self.prefix)
            .child(div().flex_1().min_w_0().child(Input::new(&self.state).appearance(false)))
            .children(self.suffix)
    }
}
