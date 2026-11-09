//! Pieces the timeline's rows share: the work-log line (`WorkLogLineView`, `ShimmerLabel`) and
//! the chat's type scale.

use std::time::Duration;

use gpui::{
    AnyElement, App, FontWeight, Hsla, IntoElement, ParentElement, RenderOnce, SharedString, Styled, Window,
    div, prelude::*, px,
};
use gpui_component::shimmer::ShimmerText;
use soprano_ui::fonts::{MONO_FONT_FAMILY, UI_FONT_FAMILY};
use soprano_ui::{ActiveSopranoTheme, IconName, icon};

use crate::work_log::timeline_icon;

/// The chat's type scale (Soprano Agents' Tailwind sizes).
pub mod text_size {
    /// `text-sm`: titles, body, assistant prose.
    pub const BODY: f32 = 14.0;
    /// Rows of menus and panels.
    pub const ROW: f32 = 13.0;
    /// `text-xs`: meta lines, buttons.
    pub const SMALL: f32 = 12.0;
    /// `text-2xs`: kbd hints.
    pub const TINY: f32 = 11.0;
    /// Command output.
    pub const CODE: f32 = 13.0;
}

/// A single line of UI text.
pub fn label(text: impl Into<SharedString>, size: f32, color: Hsla, cx: &App) -> gpui::Div {
    let t = cx.soprano_theme();
    div()
        .font_family(UI_FONT_FAMILY)
        .text_size(t.z(size))
        .text_color(color)
        .whitespace_nowrap()
        .child(text.into())
}

/// A single line of mono text.
pub fn mono(text: impl Into<SharedString>, size: f32, color: Hsla, cx: &App) -> gpui::Div {
    let t = cx.soprano_theme();
    div()
        .font_family(MONO_FONT_FAMILY)
        .text_size(t.z(size))
        .text_color(color)
        .whitespace_nowrap()
        .child(text.into())
}

/// A label that shimmers while its step runs: `color` with a window of `highlight` sweeping
/// across it every 2.2 s; under Reduce Motion it simply shows in `highlight`.
pub fn shimmer_label(
    id: impl Into<gpui::ElementId>,
    text: impl Into<SharedString>,
    color: Hsla,
    highlight: Hsla,
    shimmering: bool,
    cx: &App,
) -> AnyElement {
    let t = cx.soprano_theme();
    let text = text.into();
    if !shimmering {
        return div()
            .font_family(UI_FONT_FAMILY)
            .text_size(t.z(text_size::BODY))
            .text_color(color)
            .truncate()
            .child(text)
            .into_any_element();
    }
    if cx.reduce_motion() {
        return div()
            .font_family(UI_FONT_FAMILY)
            .text_size(t.z(text_size::BODY))
            .text_color(highlight)
            .truncate()
            .child(text)
            .into_any_element();
    }
    ShimmerText::new(text)
        .id(id)
        .duration(Duration::from_millis(2_200))
        .highlight_color(highlight)
        .spread(t.z(36.0))
        .font_family(UI_FONT_FAMILY)
        .text_size(t.z(text_size::BODY))
        .text_color(color)
        .truncate()
        .into_any_element()
}

/// Where a work-log line's chevron sits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Chevron {
    /// No chevron and no slot (approvals, the live row).
    None,
    /// In the trailing 16 px slot; `None` leaves the slot empty.
    Trailing(Option<bool>),
    /// Right after the label (group summaries).
    AfterLabel(bool),
}

/// A work-log line: a 24 px line with a 16 px icon in a 24 px column, the label (truncating),
/// an optional detail, then the trailing note, failure mark, hover timestamp and chevron.
#[derive(IntoElement)]
pub struct WorkLogLine {
    id: SharedString,
    /// The row's hover group: the timestamp shows while it is hovered.
    group: SharedString,
    icon: IconName,
    icon_color: Option<Hsla>,
    label: SharedString,
    label_color: Option<Hsla>,
    highlight: Option<Hsla>,
    /// The label's color while the row is hovered (group summaries).
    label_hover: Option<Hsla>,
    shimmering: bool,
    detail: Option<(SharedString, bool)>,
    note: Option<AnyElement>,
    failed: bool,
    time: Option<SharedString>,
    chevron: Chevron,
}

impl WorkLogLine {
    pub fn new(
        id: impl Into<SharedString>,
        group: impl Into<SharedString>,
        icon: IconName,
        label: impl Into<SharedString>,
    ) -> Self {
        Self {
            id: id.into(),
            group: group.into(),
            icon,
            icon_color: None,
            label: label.into(),
            label_color: None,
            highlight: None,
            label_hover: None,
            shimmering: false,
            detail: None,
            note: None,
            failed: false,
            time: None,
            chevron: Chevron::Trailing(None),
        }
    }

    pub fn label_color(mut self, color: Hsla) -> Self {
        self.label_color = Some(color);
        self
    }

    /// The label's color while the row (its hover group) is hovered.
    pub fn label_hover(mut self, color: Hsla) -> Self {
        self.label_hover = Some(color);
        self
    }

    pub fn icon_color(mut self, color: Hsla) -> Self {
        self.icon_color = Some(color);
        self
    }

    /// Shimmers toward `highlight` while `shimmering`.
    pub fn shimmer(mut self, shimmering: bool, highlight: Hsla) -> Self {
        self.shimmering = shimmering;
        self.highlight = Some(highlight);
        self
    }

    /// Text after the label: mono when `is_code`.
    pub fn detail(mut self, detail: Option<String>, is_code: bool) -> Self {
        self.detail = detail.filter(|d| !d.is_empty()).map(|d| (d.into(), is_code));
        self
    }

    pub fn note(mut self, note: Option<AnyElement>) -> Self {
        self.note = note;
        self
    }

    pub fn failed(mut self, failed: bool) -> Self {
        self.failed = failed;
        self
    }

    /// Shown while the row is hovered; empty for a replayed item.
    pub fn time(mut self, time: String) -> Self {
        self.time = (!time.is_empty()).then(|| time.into());
        self
    }

    pub fn chevron(mut self, chevron: Chevron) -> Self {
        self.chevron = chevron;
        self
    }
}

fn chevron_icon(open: bool, size: f32, color: Hsla) -> impl IntoElement {
    icon(if open { IconName::ChevronDown } else { IconName::ChevronRight }).size(size).color(color)
}

impl RenderOnce for WorkLogLine {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let t = cx.soprano_theme().clone();
        let muted = t.muted;
        let label_color = self.label_color.unwrap_or(muted);
        let icon_color = self.icon_color.unwrap_or(if self.failed { t.failed.opacity(0.85) } else { muted });
        let label = match self.label_hover.filter(|_| !self.shimmering) {
            Some(hover) => div()
                .font_family(UI_FONT_FAMILY)
                .text_size(t.z(text_size::BODY))
                .text_color(label_color)
                .group_hover(self.group.clone(), move |s| s.text_color(hover))
                .truncate()
                .child(self.label.clone())
                .into_any_element(),
            None => shimmer_label(
                SharedString::from(format!("{}-label", self.id)),
                self.label.clone(),
                label_color,
                self.highlight.unwrap_or(label_color),
                self.shimmering,
                cx,
            ),
        };
        let chevron_color = muted.opacity(0.7);
        div()
            .h(t.z(24.0))
            .w_full()
            .flex()
            .flex_row()
            .items_center()
            .overflow_hidden()
            .child(
                div()
                    .flex_none()
                    .pl(t.z(6.0))
                    .pr(t.z(10.0))
                    .child(icon(self.icon).size(13.0).color(icon_color)),
            )
            .child(div().min_w_0().child(label))
            .when_some(
                match self.chevron {
                    Chevron::AfterLabel(open) => Some(open),
                    _ => None,
                },
                |line, open| {
                    line.child(div().flex_none().ml(t.z(4.0)).child(chevron_icon(open, 10.0, chevron_color)))
                },
            )
            .child(div().flex_1().min_w_0().pl(t.z(6.0)).when_some(self.detail, |cell, (detail, is_code)| {
                let family = if is_code { MONO_FONT_FAMILY } else { UI_FONT_FAMILY };
                let size = if is_code { text_size::SMALL } else { text_size::BODY };
                cell.font_family(family)
                    .text_size(t.z(size))
                    .text_color(muted.opacity(0.85))
                    .truncate()
                    .child(detail)
            }))
            .when_some(self.note, |line, note| {
                line.child(div().flex_none().max_w(gpui::relative(0.4)).truncate().ml(t.z(6.0)).child(note))
            })
            .when(self.failed, |line| {
                line.child(
                    div()
                        .flex_none()
                        .ml(t.z(6.0))
                        .child(icon(timeline_icon::CIRCLE_X).size(10.0).color(t.failed.opacity(0.85))),
                )
            })
            .when_some(self.time, |line, time| {
                line.child(
                    div()
                        .flex_none()
                        .ml(t.z(6.0))
                        .hidden()
                        .group_hover(self.group.clone(), |s| s.flex())
                        .font_family(UI_FONT_FAMILY)
                        .text_size(t.z(text_size::SMALL))
                        .text_color(muted)
                        .whitespace_nowrap()
                        .child(time),
                )
            })
            .when_some(
                match self.chevron {
                    Chevron::Trailing(state) => Some(state),
                    _ => None,
                },
                |line, state| {
                    line.child(
                        div()
                            .flex_none()
                            .w(t.z(16.0))
                            .ml(t.z(6.0))
                            .mr(t.z(2.0))
                            .flex()
                            .justify_center()
                            .when_some(state, |slot, open| {
                                slot.child(chevron_icon(open, 10.0, chevron_color))
                            }),
                    )
                },
            )
            .font_weight(FontWeight::NORMAL)
            .line_height(px(t.z(24.0).into()))
    }
}
