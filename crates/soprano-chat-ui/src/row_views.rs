//! How each timeline row draws (`Rows/*.swift`): message bubbles, answers, folds, the work log,
//! file diffs, approvals, errors, notices, the changed-files card and queued messages.

use std::collections::HashSet;
use std::sync::Arc;

use gpui::{
    AnyElement, Context, FontFeatures, FontWeight, Hsla, IntoElement, ParentElement, ScrollEvent,
    ScrollHandle, SharedString, Styled, TextRun, Window, div, linear_color_stop, linear_gradient, prelude::*,
    px, relative,
};
use soprano_agents::{ApprovalKind, ApprovalOptions, TurnItemStatus, UserMessage};
use soprano_editor::rich::{DiffStat, HunkDiff, Markdown, MarkdownStyle};
use soprano_text::hunks::InlineDiff;
use soprano_ui::button::{ButtonSize, ButtonVariant, IconButtonSize};
use soprano_ui::fonts::{MONO_FONT_FAMILY, UI_FONT_FAMILY};
use soprano_ui::{ActiveSopranoTheme, Button, IconButton, IconName, SopranoTheme, icon};

use crate::changed_file_tree::{self, ChangedFileNode};
use crate::format;
use crate::rows::{
    AssistantRowModel, ChangedFilesModel, ExpansionSet, FileDiffRowModel, FoldRowModel, LiveWorkRowModel,
    TimelineRowContent, UserRowModel, WorkEntryRowModel, WorkGroupRowModel,
};
use crate::timeline_view::TimelineView;
use crate::widgets::{Chevron, WorkLogLine, label, text_size};
use crate::work_log::{self, WorkLogKind, timeline_icon};

/// A user bubble's text folds above this height.
const COLLAPSED_HEIGHT: f32 = 176.0;
/// A work entry's output scrolls past this height.
const ENTRY_BODY_MAX_HEIGHT: f32 = 256.0;
/// A file's diff scrolls past this height.
const DIFF_BODY_MAX_HEIGHT: f32 = 360.0;
/// An approval's command scrolls past this height.
const APPROVAL_DETAIL_MAX_HEIGHT: f32 = 160.0;
/// Lanes narrower than this drop the diff's indent under the label.
const DIFF_NARROW_WIDTH: f32 = 360.0;
/// Cards narrower than this tighten the tree.
const CARD_NARROW_WIDTH: f32 = 300.0;
/// Prose line height of the 14 px body text (1.625).
const BODY_LINE_HEIGHT: f32 = 22.75;

fn tabular() -> FontFeatures {
    FontFeatures(Arc::new(vec![("tnum".into(), 1)]))
}

/// The dark palettes' faint fill of output panels (`foreground` at 4 %, 3 % light).
fn panel_fill(t: &SopranoTheme) -> Hsla {
    t.foreground.opacity(if t.is_dark() { 0.04 } else { 0.03 })
}

impl TimelineView {
    pub(crate) fn render_row(
        &mut self,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(row) = self.rows.get(index).cloned() else { return div().into_any_element() };
        let t = cx.soprano_theme().clone();
        let zoom = t.zoom();
        let width = f32::from(self.viewport.width) / zoom;
        let lane = crate::timeline_view::lane_width(width);
        let group = Self::row_group(&row.id);
        let content: AnyElement = match &row.content {
            TimelineRowContent::User(model) => self.render_user(&row.id, model, lane, window, cx),
            TimelineRowContent::Fold(model) => self.render_fold(&row.id, model, cx),
            TimelineRowContent::Working { started_at, stopping } => {
                render_working(*started_at, *stopping, &t)
            }
            TimelineRowContent::Assistant(model) => self.render_assistant(&row.id, model, lane, cx),
            TimelineRowContent::WorkGroup(model) => self.render_group(&row.id, model, cx),
            TimelineRowContent::WorkEntry(model) => self.render_entry(&row.id, model, cx),
            TimelineRowContent::FileDiff(model) => self.render_file_diff(&row.id, model, lane, window, cx),
            TimelineRowContent::LiveWork(model) => self.render_live(&row.id, Some(model), cx),
            TimelineRowContent::Thinking => self.render_live(&row.id, None, cx),
            TimelineRowContent::Approval(request) => self.render_approval(&row.id, request, cx),
            TimelineRowContent::Error { message, date } => render_error(message, *date, &t),
            TimelineRowContent::Notice { text } => render_notice(text, &t),
            TimelineRowContent::ChangedFiles(model) => {
                div().px(t.z(4.0)).child(self.render_card(&row.id, model, lane - 8.0, cx)).into_any_element()
            }
            TimelineRowContent::Queued(message) => self.render_queued(&row.id, message, lane, window, cx),
            TimelineRowContent::Empty(text) => div()
                .h(px(self.empty_height(zoom)))
                .flex()
                .items_center()
                .justify_center()
                .child(label(text.clone(), text_size::BODY, t.muted, cx))
                .into_any_element(),
        };
        div()
            .id(SharedString::from(row.id.clone()))
            .group(group)
            .w_full()
            .flex()
            .justify_center()
            .px(t.z(crate::timeline_view::gutter(width)))
            .pb(t.z(row.bottom_spacing))
            .child(div().w(t.z(lane)).flex_none().child(content))
            .into_any_element()
    }

    // MARK: Messages

    /// A right-aligned bubble (`max-w-[80%] rounded-2xl p-3 bg-message`): long text folded at
    /// 176 px with "Show full message", the "↪ Steer" marker, and a hover footer with the
    /// timestamp and "Copy message".
    fn render_user(
        &mut self,
        row_id: &str,
        model: &UserRowModel,
        lane: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.soprano_theme().clone();
        let group = Self::row_group(row_id);
        let max_bubble = (lane * 0.8).floor();
        let content_width = max_bubble - 24.0;
        let full_height = text_height(&model.message.text, content_width, window, cx);
        let collapsible = full_height > COLLAPSED_HEIGHT + 24.0;
        let folded = collapsible && !model.expanded;
        let message_id = model.message.id.clone();
        let text = model.message.text.clone();
        let copied = self.copied.as_deref() == Some(row_id);
        let row = row_id.to_owned();
        let markdown =
            Markdown::new(SharedString::from(format!("{row_id}-text")), text.clone(), MarkdownStyle::USER)
                .shrink_to_fit(true);
        div()
            .w_full()
            .flex()
            .flex_col()
            .items_end()
            .when(model.turn_id.is_none(), |column| {
                column.child(
                    div()
                        .id(SharedString::from(format!("{row_id}-steer")))
                        .h(t.z(16.0))
                        .mb(t.z(4.0))
                        .pr(t.z(4.0))
                        .flex()
                        .items_center()
                        .gap(t.z(4.0))
                        .tooltip(soprano_ui::tooltip("Steered the active turn"))
                        .child(icon(timeline_icon::REDO).size(11.0).color(t.muted))
                        .child(label("Steer", text_size::SMALL, t.muted, cx)),
                )
            })
            .child(
                div()
                    .max_w(t.z(max_bubble))
                    .rounded(t.z(16.0))
                    .bg(t.raised)
                    .p(t.z(12.0))
                    .overflow_hidden()
                    .flex()
                    .flex_col()
                    .items_end()
                    .child(
                        div()
                            .relative()
                            .w_full()
                            .when(folded, |text| text.max_h(t.z(COLLAPSED_HEIGHT)).overflow_hidden())
                            .child(markdown)
                            .when(folded, |text| {
                                text.child(div().absolute().left_0().right_0().bottom_0().h(t.z(28.0)).bg(
                                    linear_gradient(
                                        180.0,
                                        linear_color_stop(t.raised.opacity(0.0), 0.0),
                                        linear_color_stop(t.raised, 1.0),
                                    ),
                                ))
                            }),
                    )
                    .when(collapsible, |bubble| {
                        bubble.child(
                            div().mt(t.z(6.0)).mr(t.z(-4.0)).child(
                                Button::new(
                                    SharedString::from(format!("{row_id}-toggle")),
                                    if model.expanded { "Show less" } else { "Show full message" },
                                )
                                .variant(ButtonVariant::Ghost)
                                .size(ButtonSize::Xs)
                                .on_click(cx.listener(
                                    move |this, _, _, cx| {
                                        this.toggle(ExpansionSet::Messages, &message_id, cx)
                                    },
                                )),
                            ),
                        )
                    }),
            )
            .child(
                div()
                    .mt(t.z(4.0))
                    .h(t.z(24.0))
                    .pr(t.z(4.0))
                    .flex()
                    .items_center()
                    .gap(t.z(10.0))
                    .opacity(0.0)
                    .group_hover(group, |s| s.opacity(1.0))
                    .child(time_label(model.message.created_at, &t, cx))
                    .child(self.copy_button(&row, text, copied, cx)),
            )
            .into_any_element()
    }

    fn copy_button(&self, row_id: &str, text: String, copied: bool, cx: &mut Context<Self>) -> IconButton {
        let t = cx.soprano_theme();
        let row = row_id.to_owned();
        IconButton::new(
            SharedString::from(format!("{row_id}-copy")),
            if copied { IconName::Check } else { IconName::Copy },
        )
        .size(IconButtonSize::Pane)
        .when(copied, |button| button.color(t.accent))
        .tooltip("Copy message")
        .on_click(cx.listener(move |this, _, _, cx| this.copy(&row, text.clone(), cx)))
    }

    /// An answer: no bubble, Markdown at 14/1.625 `foreground/90`, the changed-files card under
    /// the turn's answer, and a hover meta row (Copy message, timestamp).
    fn render_assistant(
        &mut self,
        row_id: &str,
        model: &AssistantRowModel,
        lane: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.soprano_theme().clone();
        let group = Self::row_group(row_id);
        let copied = self.copied.as_deref() == Some(row_id);
        div()
            .w_full()
            .py(t.z(2.0))
            .px(t.z(4.0))
            .flex()
            .flex_col()
            .map(|column| {
                if model.text.is_empty() && !model.is_streaming {
                    column.child(div().py(t.z(2.0)).child(label(
                        "(empty response)",
                        text_size::BODY,
                        t.muted,
                        cx,
                    )))
                } else {
                    column.child(
                        Markdown::new(
                            SharedString::from(format!("{row_id}-text")),
                            model.text.clone(),
                            MarkdownStyle::ASSISTANT,
                        )
                        .streaming(model.is_streaming),
                    )
                }
            })
            .when_some(model.changed_files.as_ref(), |column, files| {
                column.child(div().mt(t.z(16.0)).child(self.render_card(row_id, files, lane - 8.0, cx)))
            })
            .when(model.show_meta, |column| {
                column.child(
                    div()
                        .mt(t.z(6.0))
                        .h(t.z(24.0))
                        .flex()
                        .items_center()
                        .gap(t.z(8.0))
                        .opacity(0.0)
                        .group_hover(group, |s| s.opacity(1.0))
                        .child(self.copy_button(row_id, model.text.clone(), copied, cx))
                        .child(time_label(model.date, &t, cx)),
                )
            })
            .into_any_element()
    }

    /// A message waiting for the running turn: dashed bubble at the end with "Send now" (steers
    /// it in, when the agent can be steered) and "Remove".
    fn render_queued(
        &mut self,
        row_id: &str,
        message: &UserMessage,
        lane: f32,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.soprano_theme().clone();
        let max_bubble = (lane * 0.8).floor();
        let send_id = message.id.clone();
        let remove_id = message.id.clone();
        div()
            .w_full()
            .flex()
            .flex_col()
            .items_end()
            .child(
                div()
                    .max_w(t.z(max_bubble))
                    .rounded(t.z(16.0))
                    .border_1()
                    .border_dashed()
                    .border_color(t.input)
                    .p(t.z(12.0))
                    .child(
                        Markdown::new(
                            SharedString::from(format!("{row_id}-text")),
                            message.text.clone(),
                            MarkdownStyle::USER,
                        )
                        .shrink_to_fit(true),
                    ),
            )
            .child(
                div()
                    .mt(t.z(4.0))
                    .h(t.z(24.0))
                    .flex()
                    .items_center()
                    .gap(t.z(4.0))
                    .child(div().mr(t.z(4.0)).child(label("Queued", text_size::SMALL, t.muted, cx)))
                    .when(self.can_send_queued_now(), |footer| {
                        footer.child(
                            Button::new(SharedString::from(format!("{row_id}-send")), "Send now")
                                .icon(IconName::ArrowUp)
                                .variant(ButtonVariant::Ghost)
                                .size(ButtonSize::Xs)
                                .on_click(
                                    cx.listener(move |this, _, _, cx| this.send_queued_now(&send_id, cx)),
                                ),
                        )
                    })
                    .child(
                        Button::new(SharedString::from(format!("{row_id}-remove")), "Remove")
                            .icon(timeline_icon::CLOSE)
                            .variant(ButtonVariant::Ghost)
                            .size(ButtonSize::Xs)
                            .on_click(cx.listener(move |this, _, _, cx| this.remove_queued(&remove_id, cx))),
                    ),
            )
            .into_any_element()
    }

    // MARK: Folds

    /// "Worked for 3m 12s ›" at the top of a finished turn (`border-b border-border/60`).
    fn render_fold(&mut self, row_id: &str, model: &FoldRowModel, cx: &mut Context<Self>) -> AnyElement {
        let t = cx.soprano_theme().clone();
        let group = Self::row_group(row_id);
        let header = SharedString::from(format!("{row_id}-header"));
        let turn_id = model.turn_id.clone();
        div()
            .w_full()
            .flex()
            .flex_col()
            .child(
                div()
                    .pt(t.z(4.0))
                    .pb(t.z(8.0))
                    .h(t.z(4.0 + 23.0 + 8.0))
                    .flex()
                    .items_center()
                    .child(
                        div()
                            .id(header.clone())
                            .group(header.clone())
                            .pl(t.z(4.0))
                            .pr(t.z(4.0))
                            .flex()
                            .items_center()
                            .gap(t.z(4.0))
                            .cursor_pointer()
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.toggle(ExpansionSet::Turns, &turn_id, cx)
                            }))
                            .child(
                                div()
                                    .font_family(UI_FONT_FAMILY)
                                    .font_features(tabular())
                                    .text_size(t.z(text_size::BODY))
                                    .text_color(t.muted)
                                    .group_hover(header.clone(), |s| s.text_color(t.foreground))
                                    .whitespace_nowrap()
                                    .child(model.label.clone()),
                            )
                            .child(
                                div()
                                    .text_color(t.muted)
                                    .group_hover(header, |s| s.text_color(t.foreground))
                                    .child(
                                        icon(if model.expanded {
                                            IconName::ChevronDown
                                        } else {
                                            IconName::ChevronRight
                                        })
                                        .size(11.0),
                                    ),
                            ),
                    )
                    .child(div().flex_1())
                    .child(
                        div()
                            .pr(t.z(2.0))
                            .opacity(0.0)
                            .group_hover(group, |s| s.opacity(1.0))
                            .child(time_label(model.date, &t, cx)),
                    ),
            )
            .child(div().h(px(1.0)).w_full().bg(t.border.opacity(0.6)))
            .into_any_element()
    }

    // MARK: Work log

    fn render_group(
        &mut self,
        row_id: &str,
        model: &WorkGroupRowModel,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.soprano_theme().clone();
        let group = Self::row_group(row_id);
        let group_id = model.group_id.clone();
        div()
            .id(SharedString::from(format!("{row_id}-header")))
            .py(t.z(2.0))
            .cursor_pointer()
            .text_color(t.muted)
            .on_click(cx.listener(move |this, _, _, cx| this.toggle(ExpansionSet::Groups, &group_id, cx)))
            .child(
                WorkLogLine::new(row_id.to_owned(), group.clone(), model.icon, model.summary.clone())
                    .label_color(t.muted)
                    .label_hover(t.foreground)
                    .icon_color(if model.failed { t.failed.opacity(0.85) } else { t.muted })
                    .chevron(Chevron::AfterLabel(model.expanded))
                    .time(format::timestamp(model.date)),
            )
            .hover(|s| s.text_color(t.foreground))
            .into_any_element()
    }

    /// One work-log entry that opens to its output (mono 13, at most 256 px, scrolls) or, for
    /// thoughts and answered questions, its Markdown.
    fn render_entry(
        &mut self,
        row_id: &str,
        model: &WorkEntryRowModel,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.soprano_theme().clone();
        let entry = &model.entry;
        let group = Self::row_group(row_id);
        let pad = if model.grouped { 0.0 } else { 2.0 };
        let can_expand = entry.can_expand();
        let expanded = model.expanded && can_expand;
        let label_color = if entry.is_tool_like() { t.muted } else { t.foreground.opacity(0.8) };
        let detail =
            if entry.kind == WorkLogKind::Reasoning && model.expanded { None } else { entry.detail.clone() };
        let note =
            entry.note.clone().map(|note| label(note, text_size::SMALL, t.muted, cx).into_any_element());
        let entry_id = entry.id.clone();
        let line = WorkLogLine::new(row_id.to_owned(), group, entry.icon, entry.label.clone())
            .label_color(label_color)
            .icon_color(if entry.is_failed() { t.failed.opacity(0.85) } else { t.muted })
            .shimmer(entry.is_active(), if entry.is_active() { t.foreground } else { label_color })
            .detail(detail, entry.detail_is_code)
            .note(note)
            .time(format::timestamp(entry.started_at))
            .chevron(Chevron::Trailing(can_expand.then_some(model.expanded)));
        div()
            .py(t.z(pad))
            .flex()
            .flex_col()
            .child(
                div()
                    .id(SharedString::from(format!("{row_id}-header")))
                    .when(can_expand, |header| {
                        header.cursor_pointer().on_click(cx.listener(move |this, _, _, cx| {
                            this.toggle(ExpansionSet::Entries, &entry_id, cx)
                        }))
                    })
                    .child(line),
            )
            .when(expanded && entry.body_is_markdown, |column| {
                column.child(
                    div().mt(t.z(2.0)).mb(t.z(8.0)).pl(t.z(30.0)).pr(t.z(4.0)).child(
                        Markdown::new(
                            SharedString::from(format!("{row_id}-body")),
                            entry.body.clone().unwrap_or_default(),
                            MarkdownStyle::THOUGHT,
                        )
                        .streaming(entry.is_active()),
                    ),
                )
            })
            .when(expanded && !entry.body_is_markdown, |column| {
                let scroll = self.scroll_handle(row_id, "output");
                column.child(
                    div()
                        .mt(t.z(2.0))
                        .mb(t.z(8.0))
                        .ml(t.z(30.0))
                        .rounded(t.z(6.0))
                        .bg(panel_fill(&t))
                        .p(t.z(8.0))
                        .on_scroll(contain_scroll(scroll.clone()))
                        .child(
                            div()
                                .id(SharedString::from(format!("{row_id}-output")))
                                .max_h(t.z(ENTRY_BODY_MAX_HEIGHT))
                                .overflow_y_scroll()
                                .track_scroll(&scroll)
                                .font_family(MONO_FONT_FAMILY)
                                .text_size(t.z(text_size::CODE))
                                .line_height(t.z((text_size::CODE * 1.625).round()))
                                .text_color(t.muted)
                                .child(entry.body.clone().unwrap_or_default()),
                        ),
                )
            })
            .into_any_element()
    }

    /// One file an edit or write touched: "Edited Sources/App.swift  +12 −3" (shimmering while
    /// the call runs) that opens to its diff, at most 360 px tall (it scrolls); while the call
    /// runs the diff keeps its newest line in view unless the person scrolled up.
    fn render_file_diff(
        &mut self,
        row_id: &str,
        model: &FileDiffRowModel,
        lane: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.soprano_theme().clone();
        let group = Self::row_group(row_id);
        let pad = if model.grouped { 0.0 } else { 2.0 };
        let diff = if model.can_expand() {
            self.inline_diff(&model.id, &model.change, model.expanded)
        } else {
            None
        };
        let failed = model.status == TurnItemStatus::Failed;
        let note: Option<AnyElement> = diff.as_ref().and_then(|diff| {
            if model.change.is_full_content == Some(true) {
                // A write carries the whole new file, not a change: +N would claim every line is new.
                let lines = diff.additions;
                Some(
                    div()
                        .font_family(MONO_FONT_FAMILY)
                        .text_size(t.z(text_size::SMALL))
                        .text_color(t.muted)
                        .child(format!("{lines} {}", if lines == 1 { "line" } else { "lines" }))
                        .into_any_element(),
                )
            } else if diff.additions + diff.deletions > 0 {
                Some(
                    DiffStat::new(diff.additions, diff.deletions, text_size::SMALL)
                        .mute_zero(true)
                        .into_any_element(),
                )
            } else {
                None
            }
        });
        let diff_id = model.id.clone();
        let line = WorkLogLine::new(row_id.to_owned(), group, timeline_icon::WORK_EDIT, model.label())
            .label_color(t.muted)
            .shimmer(model.is_active(), t.foreground)
            .note(note)
            .failed(failed)
            .time(format::timestamp(model.date))
            .chevron(Chevron::Trailing(model.can_expand().then_some(model.expanded)));
        let open = model.expanded && diff.is_some();
        let indent = if lane < DIFF_NARROW_WIDTH { 0.0 } else { 30.0 };
        let body = diff.filter(|_| open).map(|diff| {
            let scroll = self.scroll_handle(row_id, "diff");
            let wraps = wraps(&diff, lane - indent, window);
            if model.is_active() {
                let max = scroll.max_offset().y;
                let at_end = max <= px(0.0) || -scroll.offset().y >= max - px(1.0);
                if at_end {
                    scroll.scroll_to_bottom();
                }
            }
            div()
                .mt(t.z(2.0))
                .mb(t.z(8.0))
                .ml(t.z(indent))
                .rounded(t.z(6.0))
                .border_1()
                .border_color(t.border.opacity(0.6))
                .bg(panel_fill(&t))
                .py(t.z(4.0))
                .overflow_hidden()
                .on_scroll(contain_scroll(scroll.clone()))
                .child(
                    div()
                        .id(SharedString::from(format!("{row_id}-diff")))
                        .max_h(t.z(DIFF_BODY_MAX_HEIGHT))
                        .overflow_y_scroll()
                        .when(!wraps, |body| body.overflow_x_scroll())
                        .track_scroll(&scroll)
                        .child(
                            HunkDiff::new(SharedString::from(format!("{row_id}-hunks")), diff).wrap(wraps),
                        ),
                )
        });
        div()
            .py(t.z(pad))
            .flex()
            .flex_col()
            .child(
                div()
                    .id(SharedString::from(format!("{row_id}-header")))
                    .when(model.can_expand(), |header| {
                        header.cursor_pointer().on_click(
                            cx.listener(move |this, _, _, cx| this.toggle(ExpansionSet::Diffs, &diff_id, cx)),
                        )
                    })
                    .child(line),
            )
            .children(body)
            .into_any_element()
    }

    /// The running turn's current step, shimmering, with the latest thought above it (up to 4
    /// lines); clicking shows the group's steps. Also the "Thinking" row.
    fn render_live(
        &mut self,
        row_id: &str,
        model: Option<&LiveWorkRowModel>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.soprano_theme().clone();
        let group = Self::row_group(row_id);
        let (icon_name, text, active) = match model {
            Some(model) => (model.entry.icon, work_log::live_label(&model.entry), model.active),
            None => (timeline_icon::WORK_REASONING, "Thinking".to_owned(), true),
        };
        let thought = model
            .filter(|m| !m.expanded && m.entry.kind != WorkLogKind::Reasoning)
            .and_then(|m| m.thought.clone())
            .filter(|thought| !thought.is_empty());
        let group_id = model.map(|m| m.group_id.clone());
        div()
            .id(SharedString::from(format!("{row_id}-header")))
            .py(t.z(2.0))
            .flex()
            .flex_col()
            .when_some(group_id, |row, group_id| {
                row.cursor_pointer().on_click(
                    cx.listener(move |this, _, _, cx| this.toggle(ExpansionSet::Groups, &group_id, cx)),
                )
            })
            .when_some(thought, |row, thought| {
                row.child(
                    div()
                        .flex()
                        .items_start()
                        .min_h(t.z(24.0))
                        .child(
                            div()
                                .flex_none()
                                .pt(t.z(4.0))
                                .pl(t.z(6.0))
                                .pr(t.z(10.0))
                                .child(icon(timeline_icon::WORK_REASONING).size(13.0).color(t.muted)),
                        )
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .pt(t.z(2.0))
                                .pb(t.z(2.0))
                                .font_family(UI_FONT_FAMILY)
                                .text_size(t.z(text_size::BODY))
                                .line_height(t.z(20.0))
                                .text_color(t.muted)
                                .line_clamp(4)
                                .child(thought),
                        ),
                )
            })
            .child(
                WorkLogLine::new(row_id.to_owned(), group, icon_name, text)
                    .icon_color(t.foreground)
                    .label_color(t.muted)
                    .shimmer(active, t.foreground)
                    .chevron(Chevron::None),
            )
            .into_any_element()
    }

    // MARK: Cards

    /// A pending approval: kind icon and title, the command or path in mono, the reason, then
    /// "Waiting for approval · Decline Approve More".
    fn render_approval(
        &mut self,
        row_id: &str,
        request: &soprano_agents::ApprovalRequest,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.soprano_theme().clone();
        let group = Self::row_group(row_id);
        let detail =
            if request.detail.is_empty() { request.kind.title().to_owned() } else { request.detail.clone() };
        let decline = request.options.decline_option().map(|o| o.id.clone());
        let approve = request.options.approve_option().map(|o| o.id.clone());
        let more: Vec<(String, String)> =
            request.options.more_options().into_iter().map(|o| (o.id.clone(), o.name.clone())).collect();
        let inline_button = |id: &str, title: &'static str, muted: bool| {
            Button::new(SharedString::from(format!("{row_id}-{id}")), title)
                .variant(if muted { ButtonVariant::Text } else { ButtonVariant::Ghost })
                .size(ButtonSize::Xs)
        };
        div()
            .py(t.z(2.0))
            .flex()
            .flex_col()
            .child(
                WorkLogLine::new(row_id.to_owned(), group, approval_icon(request.kind), request.kind.title())
                    .label_color(t.muted)
                    .chevron(Chevron::None),
            )
            .child({
                let scroll = self.scroll_handle(row_id, "detail");
                div().ml(t.z(32.0)).mr(t.z(4.0)).mb(t.z(4.0)).on_scroll(contain_scroll(scroll.clone())).child(
                    div()
                        .id(SharedString::from(format!("{row_id}-detail")))
                        .max_h(t.z(APPROVAL_DETAIL_MAX_HEIGHT))
                        .overflow_y_scroll()
                        .track_scroll(&scroll)
                        .font_family(MONO_FONT_FAMILY)
                        .text_size(t.z(text_size::SMALL))
                        .line_height(t.z(20.0))
                        .text_color(t.foreground)
                        .child(detail),
                )
            })
            .when_some(request.reason.clone().filter(|r| !r.is_empty()), |column, reason| {
                column.child(
                    div()
                        .ml(t.z(30.0))
                        .mr(t.z(4.0))
                        .mb(t.z(4.0))
                        .font_family(UI_FONT_FAMILY)
                        .text_size(t.z(text_size::SMALL))
                        .text_color(t.muted)
                        .child(reason),
                )
            })
            .child(
                div()
                    .ml(t.z(34.0))
                    .mb(t.z(4.0))
                    .h(t.z(20.0))
                    .flex()
                    .items_center()
                    .gap(t.z(8.0))
                    .child(icon(timeline_icon::SHIELD).size(10.0).color(t.approval))
                    .child(label("Waiting for approval", text_size::SMALL, t.approval, cx))
                    .child(label("·", text_size::SMALL, t.muted, cx))
                    .when_some(decline, |bar, id| {
                        bar.child(
                            inline_button("decline", "Decline", true)
                                .on_click(cx.listener(move |this, _, _, cx| this.respond(&id, cx))),
                        )
                    })
                    .when_some(approve, |bar, id| {
                        bar.child(
                            inline_button("approve", "Approve", false)
                                .on_click(cx.listener(move |this, _, _, cx| this.respond(&id, cx))),
                        )
                    })
                    .when(!more.is_empty(), |bar| {
                        bar.child(
                            inline_button("more", "More", true).tooltip("More approval options").on_click(
                                cx.listener(move |this, event, window, cx| {
                                    this.show_more_menu(event, more.clone(), window, cx)
                                }),
                            ),
                        )
                    }),
            )
            .into_any_element()
    }

    /// The changed-files card: `rounded-lg`, header "N changed files +A −D" with "Expand/Collapse
    /// all folders", then the folder tree with per-file stats. Clicking a file shows its diff.
    pub(crate) fn render_card(
        &mut self,
        row_id: &str,
        model: &ChangedFilesModel,
        width: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.soprano_theme().clone();
        let nodes = changed_file_tree::build(&model.files);
        let tree_rows = changed_file_tree::rows(&nodes, &model.closed_folders);
        let count = model.files.len();
        let has_directories = model.files.iter().any(|f| f.path.contains('/'));
        let all_open = model.closed_folders.is_empty();
        let narrow = width < CARD_NARROW_WIDTH;
        let turn_id = model.turn_id.clone();
        let all_paths: HashSet<String> = changed_file_tree::directory_paths(&nodes).into_iter().collect();
        let fill = if t.is_dark() { t.input.opacity(0.2) } else { t.raised };
        div()
            .w_full()
            .rounded(t.z(8.0))
            .bg(fill)
            .flex()
            .flex_col()
            .child(
                div()
                    .h(t.z(40.0))
                    .px(t.z(12.0))
                    .flex()
                    .items_center()
                    .gap(t.z(12.0))
                    .overflow_hidden()
                    .child(
                        div()
                            .min_w_0()
                            .truncate()
                            .font_family(UI_FONT_FAMILY)
                            .text_size(t.z(text_size::SMALL))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(t.foreground)
                            .child(format!("{count} changed file{}", if count == 1 { "" } else { "s" })),
                    )
                    .when(!narrow, |header| {
                        header.child(
                            DiffStat::new(model.additions(), model.deletions(), text_size::SMALL)
                                .minus_sign(true),
                        )
                    })
                    .child(div().flex_1())
                    .when(has_directories, |header| {
                        let tip = if all_open { "Collapse all folders" } else { "Expand all folders" };
                        let turn = turn_id.clone();
                        header.child(
                            IconButton::new(
                                SharedString::from(format!("{row_id}-folders")),
                                timeline_icon::UNFOLD_ALL,
                            )
                            .size(IconButtonSize::Pane)
                            .tooltip(tip)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                let closed = if all_open { all_paths.clone() } else { HashSet::new() };
                                this.set_closed_folders(&turn, closed, cx)
                            })),
                        )
                    }),
            )
            .child(div().px(t.z(if narrow { 4.0 } else { 8.0 })).pb(t.z(8.0)).flex().flex_col().children(
                tree_rows.into_iter().enumerate().map(|(index, tree_row)| {
                    let closed = model.closed_folders.contains(tree_row.node.path());
                    self.render_tree_row(
                        row_id,
                        index,
                        &model.turn_id,
                        &tree_row,
                        closed,
                        has_directories,
                        narrow,
                        &model.closed_folders,
                        cx,
                    )
                }),
            ))
            .into_any_element()
    }

    #[allow(clippy::too_many_arguments)]
    fn render_tree_row(
        &mut self,
        row_id: &str,
        index: usize,
        turn_id: &str,
        tree_row: &changed_file_tree::ChangedFileTreeRow,
        closed: bool,
        shows_spacer: bool,
        narrow: bool,
        closed_folders: &HashSet<String>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = cx.soprano_theme().clone();
        let node = &tree_row.node;
        let is_directory = node.is_directory();
        let (additions, deletions) = node.stats();
        let hover = SharedString::from(format!("{row_id}-tree-{index}"));
        let turn = turn_id.to_owned();
        let path = node.path().to_owned();
        let closed_folders = closed_folders.clone();
        let node_kind_is_dir = is_directory;
        let icon_gap = if narrow { 4.0 } else { 8.0 };
        div()
            .id(hover.clone())
            .group(hover.clone())
            .h(t.z(28.0))
            .rounded(t.z(6.0))
            .pl(t
                .z((if narrow { 4.0 } else { 8.0 })
                    + tree_row.depth as f32 * if narrow { 8.0 } else { 14.0 }))
            .pr(t.z(8.0))
            .flex()
            .items_center()
            .gap(t.z(icon_gap))
            .cursor_pointer()
            .hover(|s| s.bg(t.hover))
            .tooltip(soprano_ui::tooltip(node.path().to_owned()))
            .on_click(cx.listener(move |this, _, _, cx| {
                if node_kind_is_dir {
                    let mut closed = closed_folders.clone();
                    if !closed.remove(&path) {
                        closed.insert(path.clone());
                    }
                    this.set_closed_folders(&turn, closed, cx);
                } else {
                    this.reveal_diff(&turn, &path, cx);
                }
            }))
            .when(is_directory || shows_spacer || tree_row.depth > 0, |row| {
                row.child(div().w(t.z(14.0)).flex_none().flex().justify_center().when(is_directory, |slot| {
                    slot.child(
                        icon(if closed { IconName::ChevronRight } else { IconName::ChevronDown })
                            .size(10.0)
                            .color(t.muted.opacity(0.7)),
                    )
                }))
            })
            .child(
                div().w(t.z(14.0)).flex_none().flex().justify_center().child(
                    icon(match node {
                        ChangedFileNode::Directory { .. } if closed => timeline_icon::FOLDER,
                        ChangedFileNode::Directory { .. } => timeline_icon::FOLDER_OPEN,
                        ChangedFileNode::File { .. } => timeline_icon::FILE,
                    })
                    .size(12.0)
                    .color(t.muted.opacity(0.75)),
                ),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .font_family(MONO_FONT_FAMILY)
                    .text_size(t.z(if is_directory { text_size::TINY } else { text_size::SMALL }))
                    .text_color(if is_directory { t.muted.opacity(0.9) } else { t.foreground.opacity(0.85) })
                    .group_hover(hover, |s| s.text_color(t.foreground))
                    .text_ellipsis_middle()
                    .whitespace_nowrap()
                    .overflow_hidden()
                    .child(node.name().to_owned()),
            )
            .when(additions + deletions > 0 && !narrow, |row| {
                row.child(div().flex_none().child(DiffStat::new(additions, deletions, 10.0).minus_sign(true)))
            })
            .into_any_element()
    }
}

/// The scroll position of a row's inner box (`part`: its diff, output or detail).
impl TimelineView {
    fn scroll_handle(&mut self, row_id: &str, part: &str) -> ScrollHandle {
        self.diff_scrolls.entry(format!("{row_id}|{part}")).or_default().clone()
    }
}

/// Keeps a wheel the box can still use away from the timeline; at the box's edge the timeline
/// scrolls (Swift `PassThroughScrollView`). Registered on the box's parent, so it runs after
/// the box scrolled.
fn contain_scroll(handle: ScrollHandle) -> impl Fn(&ScrollEvent, &mut Window, &mut gpui::App) + 'static {
    move |event, _, cx| {
        let delta = event.delta.pixel_delta(px(20.0));
        let offset = handle.offset();
        let max = handle.max_offset();
        let movable = if delta.y.abs() >= delta.x.abs() {
            (delta.y > px(0.0) && offset.y < px(0.0)) || (delta.y < px(0.0) && -offset.y < max.y)
        } else {
            (delta.x > px(0.0) && offset.x < px(0.0)) || (delta.x < px(0.0) && -offset.x < max.x)
        };
        if movable {
            cx.stop_propagation();
        }
    }
}

fn approval_icon(kind: ApprovalKind) -> IconName {
    match kind {
        ApprovalKind::Command => timeline_icon::WORK_COMMAND,
        ApprovalKind::FileChange => timeline_icon::WORK_EDIT,
        ApprovalKind::FileRead => timeline_icon::WORK_READ,
        ApprovalKind::Other => timeline_icon::SHIELD,
    }
}

/// "Working for 12s" while a turn runs; the timeline's clock re-renders it every second.
fn render_working(started_at: Option<soprano_agents::Date>, stopping: bool, t: &SopranoTheme) -> AnyElement {
    div()
        .flex()
        .flex_col()
        .child(
            div()
                .pt(t.z(4.0))
                .pb(t.z(8.0))
                .h(t.z(4.0 + 24.0 + 8.0))
                .pl(t.z(4.0))
                .flex()
                .items_center()
                .font_family(UI_FONT_FAMILY)
                .font_features(tabular())
                .text_size(t.z(text_size::BODY))
                .text_color(t.muted)
                .child(format::working_label(started_at, stopping, chrono::Utc::now())),
        )
        .child(div().h(px(1.0)).w_full().bg(t.border.opacity(0.6)))
        .into_any_element()
}

/// A failure in the error color with its time.
fn render_error(message: &str, date: Option<soprano_agents::Date>, t: &SopranoTheme) -> AnyElement {
    div()
        .py(t.z(2.0))
        .min_h(t.z(28.0))
        .flex()
        .items_start()
        .child(
            div()
                .flex_none()
                .pt(t.z(4.0))
                .pl(t.z(6.0))
                .pr(t.z(10.0))
                .child(icon(IconName::CircleAlert).size(13.0).color(t.failed)),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .pt(t.z(2.0))
                .font_family(UI_FONT_FAMILY)
                .text_size(t.z(text_size::BODY))
                .font_weight(FontWeight::MEDIUM)
                .text_color(t.failed)
                .child(message.to_owned()),
        )
        .child(
            div()
                .flex_none()
                .pt(t.z(4.0))
                .pl(t.z(8.0))
                .pr(t.z(2.0))
                .font_family(UI_FONT_FAMILY)
                .text_size(t.z(text_size::SMALL))
                .text_color(t.muted)
                .child(format::timestamp(date)),
        )
        .into_any_element()
}

/// "Context compacted" divider: hairlines on both sides of a muted label.
fn render_notice(text: &str, t: &SopranoTheme) -> AnyElement {
    let rule = || div().flex_1().h(px(1.0)).bg(t.border.opacity(0.7));
    div()
        .h(t.z(24.0))
        .flex()
        .items_center()
        .gap(t.z(12.0))
        .child(rule())
        .child(
            div()
                .flex()
                .items_center()
                .gap(t.z(6.0))
                .max_w(relative(0.8))
                .child(icon(timeline_icon::MINIMIZE).size(10.0).color(t.muted))
                .child(
                    div()
                        .font_family(UI_FONT_FAMILY)
                        .text_size(t.z(text_size::SMALL))
                        .text_color(t.muted)
                        .truncate()
                        .child(text.to_owned()),
                ),
        )
        .child(rule())
        .into_any_element()
}

/// The muted timestamp of a row, with the full date as its tooltip.
fn time_label(date: Option<soprano_agents::Date>, t: &SopranoTheme, _cx: &mut gpui::App) -> AnyElement {
    let text = format::timestamp(date);
    let tip = format::tooltip(date);
    div()
        .id(SharedString::from(format!("time-{}", date.map(|d| d.timestamp_millis()).unwrap_or_default())))
        .font_family(UI_FONT_FAMILY)
        .text_size(t.z(text_size::SMALL))
        .text_color(t.muted)
        .whitespace_nowrap()
        .when_some(tip, |time, tip| time.tooltip(soprano_ui::tooltip(tip)))
        .child(text)
        .into_any_element()
}

/// The height plain text takes at the user bubble's 14 px prose, wrapped to `width`.
fn text_height(text: &str, width: f32, window: &mut Window, cx: &gpui::App) -> f32 {
    let t = cx.soprano_theme();
    let font_size = t.z(text_size::BODY);
    let run = TextRun {
        len: text.len(),
        font: gpui::font(UI_FONT_FAMILY),
        color: t.foreground,
        background_color: None,
        underline: None,
        strikethrough: None,
    };
    let line_height = t.z(BODY_LINE_HEIGHT);
    match window.text_system().shape_text(
        SharedString::from(text.to_owned()),
        font_size,
        &[run],
        Some(t.z(width)),
        None,
    ) {
        Ok(lines) => {
            lines.iter().map(|line| f32::from(line.size(line_height).height)).sum::<f32>() / t.zoom()
        }
        Err(_) => text.lines().count() as f32 * BODY_LINE_HEIGHT,
    }
}

/// Whether a diff `width` wide wraps its lines: at least 40 columns of code fit beside the
/// number gutter; narrower, lines stay whole and the diff scrolls sideways.
fn wraps(diff: &InlineDiff, width: f32, window: &mut Window) -> bool {
    use soprano_editor::rich::diff::{DIFF_FONT_SIZE, digit_width, number_width};
    let text_width = width
        - number_width(diff.max_number, window)
        - soprano_text::diff::CODE_INSET
        - soprano_text::diff::CODE_TRAILING;
    text_width >= InlineDiff::MINIMUM_WRAP_COLUMNS as f32 * digit_width(DIFF_FONT_SIZE, window)
}
