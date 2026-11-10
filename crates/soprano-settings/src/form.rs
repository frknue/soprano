//! The settings pages' building blocks: a page is a lead paragraph and sections; a section is
//! a title (with its count, note and trailing control) over a group; a group is a card of rows
//! ruled off by hairlines; a row is a title and a muted description on the left, the control on
//! the right. Groups are `background` cards on the page's `canvas`, as panes are in the window.

use gpui::{
    AnyElement, App, ClickEvent, Div, ElementId, FontFeatures, FontWeight, Hsla, IntoElement, ParentElement,
    SharedString, Styled, Window, div, prelude::*,
};
use soprano_ui::button::{IconButton, IconButtonSize};
use soprano_ui::fonts::{self, size};
use soprano_ui::{IconName, SopranoTheme, icon};

/// Left and right inset of a group's content.
pub(crate) const INSET: f32 = 14.0;
/// Corner radius of a group.
const GROUP_RADIUS: f32 = 8.0;
/// Lead paragraphs, notes and hints wrap at a readable measure.
const TEXT_MAX_WIDTH: f32 = 640.0;

/// Monospace text as typed: Geist Mono's ligatures would close the gap before a `--flag`.
pub(crate) fn mono<E: Styled>(element: E) -> E {
    let as_typed = FontFeatures(std::sync::Arc::new(vec![("liga".into(), 0), ("calt".into(), 0)]));
    element.font_family(fonts::MONO_FONT_FAMILY).font_features(as_typed)
}

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

    /// The paragraph that opens a page.
    pub fn lead(&self, text: impl Into<SharedString>) -> Div {
        div()
            .max_w(self.z(TEXT_MAX_WIDTH))
            .text_size(self.z(size::ROW))
            .line_height(self.z(19.))
            .text_color(self.t.muted)
            .child(text.into())
    }

    /// A titled group; finish it with [`Section::rows`] or [`Section::body`].
    pub fn section(&self, title: impl Into<SharedString>) -> Section<'a> {
        Section { t: self.t, title: title.into(), count: None, note: None, reset: None }
    }

    /// The group card: rows separated by `border` hairlines.
    pub fn group(&self, rows: Vec<AnyElement>) -> Div {
        let t = self.t;
        let count = rows.len();
        div()
            .flex()
            .flex_col()
            .w_full()
            .rounded(self.z(GROUP_RADIUS))
            .border_1()
            .border_color(t.border)
            .bg(t.background)
            .overflow_hidden()
            .children(rows.into_iter().enumerate().map(move |(index, row)| {
                div().w_full().when(index + 1 < count, |d| d.border_b_1().border_color(t.border)).child(row)
            }))
    }

    /// One row: title (+ badge, reset), description, control.
    pub fn row(&self, title: impl Into<SharedString>) -> Row {
        Row {
            leading: None,
            title: title.into(),
            title_color: None,
            mono_title: false,
            badge: None,
            description: None,
            description_color: None,
            status: None,
            mono_description: false,
            reset: None,
            control: None,
            compact: false,
        }
    }

    /// A row whose content fills it from the left (an input with its buttons, "Add Account").
    pub fn bar(&self, children: Vec<AnyElement>) -> Div {
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap(self.z(8.))
            .px(self.z(INSET))
            .py(self.z(10.))
            .children(children)
    }

    /// The row a list shows while it has nothing to list.
    pub fn placeholder(&self, title: impl Into<SharedString>, hint: impl Into<SharedString>) -> AnyElement {
        div()
            .flex()
            .flex_col()
            .items_center()
            .gap(self.z(3.))
            .px(self.z(INSET))
            .py(self.z(18.))
            .child(div().text_size(self.z(size::UI)).text_color(self.t.muted).child(title.into()))
            .child(
                div()
                    .max_w(self.z(TEXT_MAX_WIDTH))
                    .text_size(self.z(size::META))
                    .line_height(self.z(17.))
                    .text_color(self.t.dim)
                    .child(hint.into()),
            )
            .into_any_element()
    }

    /// Controls side by side.
    pub fn controls(&self, children: Vec<AnyElement>) -> Div {
        div().flex().flex_row().flex_none().items_center().gap(self.z(6.)).children(children)
    }

    /// A line of small text (a status, "Off", an error under a field).
    pub fn small(&self, text: impl Into<SharedString>, color: Hsla) -> Div {
        div().text_size(self.z(size::META)).text_color(color).whitespace_nowrap().child(text.into())
    }

    /// A small outlined label after a title ("settings.json", "Preferred").
    pub fn badge(&self, text: impl Into<SharedString>, color: Hsla) -> Div {
        div()
            .flex()
            .flex_none()
            .items_center()
            .h(self.z(18.))
            .px(self.z(6.))
            .rounded(self.z(4.))
            .border_1()
            .border_color(color.opacity(0.35))
            .text_size(self.z(size::SMALL))
            .text_color(color)
            .whitespace_nowrap()
            .child(text.into())
    }

    /// A 7 px status dot.
    pub fn dot(&self, color: Hsla) -> Div {
        div().flex_none().size(self.z(7.)).rounded_full().bg(color)
    }

    /// The well a segmented control sits in.
    pub fn track(&self, control: impl IntoElement) -> Div {
        div()
            .flex_none()
            .p(self.z(2.))
            .rounded(self.z(8.))
            .border_1()
            .border_color(self.t.border)
            .bg(self.t.canvas)
            .child(control)
    }

    /// A tinted notice: a warning glyph in `color`, a title, its lines (each with a dot in its
    /// own color), and an action at the end.
    pub fn callout(
        &self,
        color: Hsla,
        title: impl Into<SharedString>,
        lines: Vec<(SharedString, Hsla)>,
        action: Option<AnyElement>,
    ) -> Div {
        let t = self.t;
        div()
            .flex()
            .flex_row()
            .items_start()
            .gap(self.z(10.))
            .w_full()
            .px(self.z(INSET))
            .py(self.z(12.))
            .rounded(self.z(GROUP_RADIUS))
            .border_1()
            .border_color(color.opacity(0.35))
            .bg(color.opacity(0.08))
            .child(div().pt(self.z(2.)).child(icon(IconName::TriangleAlert).size(15.).color(color)))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_w_0()
                    .gap(self.z(4.))
                    .child(
                        div()
                            .text_size(self.z(size::UI))
                            .line_height(self.z(19.))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(t.foreground)
                            .child(title.into()),
                    )
                    .children(lines.into_iter().map(|(line, tone)| {
                        div()
                            .flex()
                            .flex_row()
                            .items_start()
                            .gap(self.z(8.))
                            .child(div().pt(self.z(6.)).child(self.dot(tone).size(self.z(5.))))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .text_size(self.z(size::META))
                                    .line_height(self.z(17.))
                                    .text_color(t.foreground.opacity(0.85))
                                    .child(line),
                            )
                    })),
            )
            .when_some(action, |callout, action| callout.child(div().flex_none().child(action)))
    }
}

type ResetHandler = Box<dyn Fn(&ClickEvent, &mut Window, &mut App)>;

/// The "Reset to default" button after a title.
fn reset_button((id, handler): (ElementId, ResetHandler)) -> IconButton {
    IconButton::new(id, IconName::UNDO)
        .size(IconButtonSize::Tab)
        .tooltip("Reset to default")
        .on_click(move |event, window, cx| handler(event, window, cx))
}

/// A section under construction.
pub(crate) struct Section<'a> {
    t: &'a SopranoTheme,
    title: SharedString,
    count: Option<usize>,
    note: Option<SharedString>,
    reset: Option<(ElementId, ResetHandler)>,
}

impl Section<'_> {
    /// "Title N": how many rows the group lists.
    pub fn count(mut self, count: usize) -> Self {
        self.count = Some(count);
        self
    }

    /// A muted line under the title.
    pub fn note(mut self, text: impl Into<SharedString>) -> Self {
        let text = text.into();
        self.note = (!text.is_empty()).then_some(text);
        self
    }

    /// The "Reset to default" button after the title, while the section's value `differs`
    /// from the default.
    pub fn reset_when(
        mut self,
        differs: bool,
        id: impl Into<ElementId>,
        handler: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.reset = differs.then(|| (id.into(), Box::new(handler) as ResetHandler));
        self
    }

    /// The section over a group of `rows`.
    pub fn rows(self, rows: Vec<AnyElement>) -> AnyElement {
        let group = Form::new(self.t).group(rows);
        self.body(group)
    }

    /// The section over any content.
    pub fn body(self, body: impl IntoElement) -> AnyElement {
        let t = self.t;
        let title = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(t.z(8.))
            .text_size(t.z(size::UI))
            .line_height(t.z(18.))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_baseline()
                    .gap(t.z(6.))
                    .child(div().font_weight(FontWeight::SEMIBOLD).text_color(t.foreground).child(self.title))
                    .when_some(self.count, |row, count| {
                        row.child(div().text_size(t.z(size::META)).text_color(t.dim).child(count.to_string()))
                    }),
            )
            .children(self.reset.map(reset_button));
        let heading = div().flex().flex_col().gap(t.z(2.)).px(t.z(2.)).child(title).when_some(
            self.note,
            |col, note| {
                col.child(
                    div()
                        .max_w(t.z(TEXT_MAX_WIDTH))
                        .text_size(t.z(size::META))
                        .line_height(t.z(17.))
                        .text_color(t.muted)
                        .child(note),
                )
            },
        );
        div().flex().flex_col().w_full().gap(t.z(10.)).child(heading).child(body).into_any_element()
    }
}

/// A settings row under construction.
pub(crate) struct Row {
    leading: Option<AnyElement>,
    title: SharedString,
    title_color: Option<Hsla>,
    mono_title: bool,
    badge: Option<AnyElement>,
    description: Option<SharedString>,
    description_color: Option<Hsla>,
    status: Option<(SharedString, Hsla)>,
    mono_description: bool,
    reset: Option<(ElementId, ResetHandler)>,
    control: Option<AnyElement>,
    compact: bool,
}

impl Row {
    /// A glyph or mark before the text.
    pub fn leading(mut self, element: impl IntoElement) -> Self {
        self.leading = Some(element.into_any_element());
        self
    }

    pub fn description(mut self, text: impl Into<SharedString>) -> Self {
        let text = text.into();
        self.description = (!text.is_empty()).then_some(text);
        self
    }

    pub fn description_color(mut self, color: Hsla) -> Self {
        self.description_color = Some(color);
        self
    }

    /// A line with a dot in `color` under the description (a machine's connection check).
    pub fn status(mut self, text: impl Into<SharedString>, color: Hsla) -> Self {
        self.status = Some((text.into(), color));
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

    /// A badge after the title.
    pub fn badge(mut self, badge: impl IntoElement) -> Self {
        self.badge = Some(badge.into_any_element());
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

    /// A one-line row in a long list (licenses): less air above and below.
    pub fn compact(mut self) -> Self {
        self.compact = true;
        self
    }

    pub fn control(mut self, control: impl IntoElement) -> Self {
        self.control = Some(control.into_any_element());
        self
    }

    pub fn render(self, t: &SopranoTheme) -> AnyElement {
        let multiline = self.description.is_some() || self.status.is_some();
        let title = div()
            .min_w_0()
            .truncate()
            .text_size(t.z(if self.mono_title { size::ROW } else { size::UI }))
            .line_height(t.z(19.))
            .text_color(self.title_color.unwrap_or(t.foreground))
            .when(self.mono_title, mono)
            .child(self.title);
        let title_row = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(t.z(8.))
            .min_w_0()
            .child(title)
            .children(self.badge)
            .children(self.reset.map(reset_button));
        let text = div()
            .flex()
            .flex_col()
            .flex_1()
            .min_w_0()
            .gap(t.z(2.))
            .child(title_row)
            .when_some(self.description, |col, description| {
                col.child(
                    div()
                        .text_size(t.z(size::META))
                        .line_height(t.z(17.))
                        .text_color(self.description_color.unwrap_or(t.muted))
                        .when(self.mono_description, mono)
                        .child(description),
                )
            })
            .when_some(self.status, |col, (status, color)| {
                col.child(
                    div()
                        .flex()
                        .flex_row()
                        .items_start()
                        .gap(t.z(6.))
                        .pt(t.z(2.))
                        .child(div().pt(t.z(5.)).child(div().size(t.z(7.)).rounded_full().bg(color)))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .text_size(t.z(size::META))
                                .line_height(t.z(17.))
                                .text_color(t.muted)
                                .child(status),
                        ),
                )
            });
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap(t.z(12.))
            .min_h(t.z(if self.compact { 36. } else { 44. }))
            .px(t.z(INSET))
            .py(t.z(if self.compact { 6. } else { 10. }))
            // Beside several lines of text, the mark sits on the title's line.
            .children(self.leading.map(|leading| {
                div()
                    .flex()
                    .flex_none()
                    .items_center()
                    .h(t.z(19.))
                    .when(multiline, |mark| mark.self_start())
                    .child(leading)
            }))
            .child(text)
            .when_some(self.control, |row, control| row.child(div().flex_none().pl(t.z(12.)).child(control)))
            .into_any_element()
    }
}
