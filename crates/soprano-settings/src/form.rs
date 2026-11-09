//! The settings pages' building blocks (`SettingsForm`): a section is a title over a grouped
//! card of rows ruled off by hairlines; a row is the title (+ reset) and a muted description on
//! the left, the control on the right. Measurements follow the Swift form; colors and type
//! are Herdr's tokens.

use gpui::{
    AnyElement, App, ClickEvent, Div, ElementId, FontWeight, Hsla, IntoElement, ParentElement, SharedString,
    Styled, Window, div, prelude::*,
};
use soprano_ui::button::{IconButton, IconButtonSize};
use soprano_ui::fonts::{self, size};
use soprano_ui::{IconName, SopranoTheme};

/// Section and row content shared by every page.
pub(crate) struct Form<'a> {
    pub t: &'a SopranoTheme,
}

impl<'a> Form<'a> {
    pub fn new(t: &'a SopranoTheme) -> Self {
        Self { t }
    }

    fn z(&self, v: f32) -> gpui::Pixels {
        self.t.z(v)
    }

    /// A titled group of rows; `note` is a muted line between the title and the group.
    pub fn section(&self, title: Option<&str>, note: Option<&str>, rows: Vec<AnyElement>) -> Div {
        let t = self.t;
        div()
            .flex()
            .flex_col()
            .w_full()
            .when_some(title.map(SharedString::from), |s, title| {
                s.child(
                    div()
                        .h(self.z(28.))
                        .px(self.z(16.))
                        .flex()
                        .items_center()
                        .text_size(self.z(size::DIALOG_TITLE))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(t.foreground)
                        .child(title),
                )
            })
            .when_some(note.map(SharedString::from), |s, note| {
                s.child(
                    div()
                        .px(self.z(16.))
                        .pt(self.z(2.))
                        .text_size(self.z(size::META))
                        .text_color(t.muted)
                        .child(note),
                )
            })
            .child(self.group(rows).mt(self.z(if title.is_some() || note.is_some() { 10. } else { 0. })))
    }

    /// The grouped card: rows separated by `border` hairlines.
    pub fn group(&self, rows: Vec<AnyElement>) -> Div {
        let t = self.t;
        let count = rows.len();
        div()
            .flex()
            .flex_col()
            .w_full()
            .rounded(self.z(10.))
            .border_1()
            .border_color(t.border)
            .bg(t.background)
            .overflow_hidden()
            .children(rows.into_iter().enumerate().map(move |(index, row)| {
                div().w_full().when(index + 1 < count, |d| d.border_b_1().border_color(t.border)).child(row)
            }))
    }

    /// One row: title (+ reset), description, control.
    pub fn row(&self, title: impl Into<SharedString>) -> Row {
        Row {
            title: title.into(),
            title_color: None,
            mono_title: false,
            description: None,
            description_color: None,
            mono_description: false,
            reset: None,
            control: None,
            tooltip: None,
        }
    }

    /// A row whose content fills it from the left (an input with its buttons, "Add Account").
    pub fn actions_row(&self, children: Vec<AnyElement>) -> Div {
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap(self.z(8.))
            .min_h(self.z(52.))
            .px(self.z(16.))
            .py(self.z(10.))
            .children(children)
    }

    /// A read-only value on the right of a row.
    pub fn value(&self, text: impl Into<SharedString>, mono: bool) -> Div {
        div()
            .text_size(self.z(if mono { size::ROW } else { size::UI }))
            .when(mono, |d| d.font_family(fonts::MONO_FONT_FAMILY))
            .text_color(self.t.muted)
            .truncate()
            .child(text.into())
    }

    /// Controls side by side.
    pub fn controls(&self, children: Vec<AnyElement>) -> Div {
        div().flex().flex_row().flex_none().items_center().gap(self.z(6.)).children(children)
    }

    /// A muted line of small text (status, "Off").
    pub fn small(&self, text: impl Into<SharedString>, color: Hsla) -> Div {
        div().text_size(self.z(size::META)).text_color(color).whitespace_nowrap().child(text.into())
    }
}

type ResetHandler = Box<dyn Fn(&ClickEvent, &mut Window, &mut App)>;

/// A settings row under construction (`SettingsForm.row`).
pub(crate) struct Row {
    title: SharedString,
    title_color: Option<Hsla>,
    mono_title: bool,
    description: Option<SharedString>,
    description_color: Option<Hsla>,
    mono_description: bool,
    reset: Option<(ElementId, ResetHandler)>,
    control: Option<AnyElement>,
    tooltip: Option<SharedString>,
}

impl Row {
    pub fn description(mut self, text: impl Into<SharedString>) -> Self {
        let text = text.into();
        self.description = (!text.is_empty()).then_some(text);
        self
    }

    pub fn description_color(mut self, color: Hsla) -> Self {
        self.description_color = Some(color);
        self
    }

    pub fn mono_description(mut self) -> Self {
        self.mono_description = true;
        self
    }

    pub fn title_color(mut self, color: Hsla) -> Self {
        self.title_color = Some(color);
        self
    }

    pub fn mono_title(mut self) -> Self {
        self.mono_title = true;
        self
    }

    pub fn tooltip(mut self, text: impl Into<SharedString>) -> Self {
        self.tooltip = Some(text.into());
        self
    }

    /// The "Reset to default" button after the title; only pass it when the value differs
    /// from the default.
    pub fn reset(
        mut self,
        id: impl Into<ElementId>,
        handler: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.reset = Some((id.into(), Box::new(handler)));
        self
    }

    pub fn reset_when(
        self,
        differs: bool,
        id: impl Into<ElementId>,
        handler: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    ) -> Self {
        if differs { self.reset(id, handler) } else { self }
    }

    pub fn control(mut self, control: impl IntoElement) -> Self {
        self.control = Some(control.into_any_element());
        self
    }

    pub fn render(self, t: &SopranoTheme) -> AnyElement {
        let title = div()
            .min_w_0()
            .truncate()
            .text_size(t.z(size::UI))
            .font_weight(FontWeight::MEDIUM)
            .text_color(self.title_color.unwrap_or(t.foreground))
            .when(self.mono_title, |d| d.font_family(fonts::MONO_FONT_FAMILY))
            .child(self.title);
        let title_row = div().flex().flex_row().items_center().gap(t.z(6.)).min_w_0().child(title).when_some(
            self.reset,
            |row, (id, handler)| {
                row.child(
                    IconButton::new(id, IconName::UNDO)
                        .size(IconButtonSize::Tab)
                        .tooltip("Reset to default")
                        .on_click(move |event, window, cx| handler(event, window, cx)),
                )
            },
        );
        let left = div().flex().flex_col().flex_1().min_w_0().gap(t.z(4.)).child(title_row).when_some(
            self.description,
            |col, description| {
                col.child(
                    div()
                        .max_w(t.z(672.))
                        .text_size(t.z(size::META))
                        .text_color(self.description_color.unwrap_or(t.muted))
                        .when(self.mono_description, |d| d.font_family(fonts::MONO_FONT_FAMILY))
                        .child(description),
                )
            },
        );
        let row = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(t.z(32.))
            .min_h(t.z(52.))
            .px(t.z(16.))
            .py(t.z(12.))
            .child(left)
            .when_some(self.control, |row, control| row.child(div().flex_none().child(control)));
        match self.tooltip {
            Some(text) => row
                .id(SharedString::from(format!("row-tooltip-{text}")))
                .tooltip(soprano_ui::tooltip::tooltip(text))
                .into_any_element(),
            None => row.into_any_element(),
        }
    }
}
