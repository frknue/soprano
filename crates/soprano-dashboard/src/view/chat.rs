//! The chat column (Soprano Agents' chat): the 52 px header naming project and thread with
//! where it runs and what can be done with it, the conversation in the centered lane, and
//! the floating composer; or, for a new thread, the headline that picks its project over
//! the composer in the middle of the column.

use gpui::{
    AnyElement, Context, ExternalPaths, FontWeight, InteractiveElement, IntoElement, ObjectFit,
    ParentElement, SharedString, StatefulInteractiveElement, Styled, Window, div, img, prelude::*,
};
use gpui_component::input::Textarea;
use soprano_chat_ui::composer::EDITOR_LINE_HEIGHT;
use soprano_chat_ui::widgets::text_size;
use soprano_ui::button::IconButton;
use soprano_ui::status::StatusPill;
use soprano_ui::tooltip::tooltip;
use soprano_ui::{Icon, IconName, Monogram, SopranoTheme, agent_icon_stem, file_type_icon, icon};

use super::sidebar::agent_glyph;
use super::{AgentDashboard, DashboardEvent, Draft, TOPBAR_HEIGHT, drag_region, measure};
use crate::attachments::{self, Attachment};
use crate::state::{self, Controls, DashboardEntry, ThreadOption};

/// An attached image's thumbnail, and the ✕ that takes an attachment out again.
const THUMBNAIL_SIZE: f32 = 56.0;
const REMOVE_SIZE: f32 = 18.0;

impl AgentDashboard {
    pub(super) fn render_chat(
        &mut self,
        theme: &SopranoTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let (gutter, lane) = self.lane(theme);
        let inset = self.composer_inset(theme);
        self.timeline.update(cx, |timeline, cx| timeline.set_bottom_inset(theme.z(inset), cx));
        let controls = self.controls();
        let composer = div().w(theme.z(lane)).child(self.render_composer(theme, cx));
        let body: AnyElement = match (&self.draft, self.selected()) {
            // A new thread: headline and composer in the middle of the column.
            (Some(draft), _) => div()
                .id("agent-dashboard-draft")
                .debug_selector(|| "agent-dashboard-draft".into())
                .flex()
                .flex_col()
                .flex_1()
                .min_h_0()
                .items_center()
                .justify_center()
                .px(theme.z(gutter))
                .pb(theme.z(TOPBAR_HEIGHT))
                .child(self.render_hero(draft, theme, cx))
                .child(composer)
                .into_any_element(),
            (None, Some(_)) => div()
                .relative()
                .flex()
                .flex_col()
                .flex_1()
                .min_h_0()
                .child(self.timeline.clone())
                .child(
                    div()
                        .absolute()
                        .left_0()
                        .right_0()
                        .bottom(theme.z(gutter))
                        .flex()
                        .justify_center()
                        .child(composer),
                )
                .into_any_element(),
            // Nothing to show and nothing to start a thread with.
            (None, None) => div()
                .flex()
                .flex_1()
                .items_center()
                .justify_center()
                .text_color(theme.muted)
                .child("No agent is set up to start a thread with.")
                .into_any_element(),
        };
        let _ = window;
        div()
            .id("agent-dashboard-detail")
            .debug_selector(|| "agent-dashboard-detail".into())
            .relative()
            .flex()
            .flex_col()
            .flex_1()
            .min_w_0()
            .h_full()
            .child(measure(&self.column_bounds))
            .child(self.render_header(controls, theme, cx))
            .child(body)
    }

    /// `[SA] project / Title  ◌ Working 2m … ▢ ~/git/shop ⑂ branch [≡][↻][■][↗]`; the band
    /// moves the window.
    fn render_header(
        &self,
        controls: Controls,
        theme: &SopranoTheme,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let header = drag_region(div().id("agent-dashboard-header"))
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(theme.z(12.))
            .h(theme.z(TOPBAR_HEIGHT))
            .pl(theme.z(20.))
            .pr(theme.z(12.))
            .font_weight(FontWeight::MEDIUM);
        let entry = match (&self.draft, self.selected()) {
            (None, Some(entry)) => entry,
            _ => return header.child(div().flex_1().min_w_0().truncate().child("New thread")),
        };
        let breadcrumb = div()
            .id("agent-dashboard-title")
            .flex()
            .flex_row()
            // The title keeps its room; the location chip gives way first.
            .flex_shrink(1.)
            .min_w_0()
            .items_center()
            .gap(theme.z(12.))
            .tooltip(tooltip(entry.title()))
            .when(!entry.project.is_empty(), |crumbs| {
                crumbs
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .flex_none()
                            .items_center()
                            .gap(theme.z(6.))
                            .max_w(theme.z(180.))
                            .text_color(theme.muted)
                            .child(Monogram::new(entry.project.clone()).size(14.))
                            .child(div().min_w_0().truncate().child(entry.project.clone())),
                    )
                    .child(div().flex_none().text_color(theme.muted).child("/"))
            })
            .child(div().min_w_0().truncate().child(entry.title()))
            .child(
                div()
                    .flex_none()
                    .font_weight(FontWeight::NORMAL)
                    .child(StatusPill::new(entry.pill()).relative_to(Some(entry.since)).now(self.now)),
            );
        let detailed = self.timeline.read(cx).is_detailed();
        let button = |selector: &'static str, button: IconButton| {
            div().debug_selector(move || selector.into()).child(button)
        };
        let buttons = div()
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(theme.z(4.))
            .child(button(
                "agent-dashboard-details",
                IconButton::new("agent-dashboard-details", IconName::ListChecks)
                    .icon_size(14.)
                    .selected(detailed && controls.details)
                    .disabled(!controls.details)
                    .tooltip("Show thinking, full commands and output (O)")
                    .on_click(cx.listener(|this, _, _, cx| this.toggle_details(cx))),
            ))
            .child(button(
                "agent-dashboard-restart",
                IconButton::new("agent-dashboard-restart", IconName::RotateCcw)
                    .icon_size(14.)
                    .disabled(!controls.restart)
                    .tooltip("Restart the agent")
                    .on_click(
                        cx.listener(|this, _, _, cx| this.emit_for_selection(DashboardEvent::Restart, cx)),
                    ),
            ))
            .child(button(
                "agent-dashboard-stop",
                IconButton::new("agent-dashboard-stop", IconName::STOP)
                    .icon_size(13.)
                    .disabled(!controls.stop)
                    .tooltip("Stop the agent")
                    .on_click(
                        cx.listener(|this, _, _, cx| this.emit_for_selection(DashboardEvent::Stop, cx)),
                    ),
            ))
            .child(button(
                "agent-dashboard-open",
                IconButton::new("agent-dashboard-open", IconName::ExternalLink)
                    .icon_size(14.)
                    .disabled(!controls.open)
                    .tooltip("Open in its window (Return)")
                    .on_click(
                        cx.listener(|this, _, _, cx| this.emit_for_selection(DashboardEvent::Open, cx)),
                    ),
            ));
        header
            .child(breadcrumb)
            .child(div().flex_1())
            .children(self.render_location(entry, theme, cx))
            .child(buttons)
    }

    /// Where the thread runs: its folder and, off the default branch, its branch. A click
    /// opens it in its window.
    fn render_location(
        &self,
        entry: &DashboardEntry,
        theme: &SopranoTheme,
        cx: &mut Context<Self>,
    ) -> Option<impl IntoElement + use<>> {
        let path = entry.abbreviated_path(&self.host.home)?;
        let (hover, foreground) = (theme.hover, theme.foreground);
        let folder = if entry.entry.machine.is_some() { IconName::Server } else { IconName::Folder };
        Some(
            div()
                .id("agent-dashboard-location")
                .debug_selector(|| "agent-dashboard-location".into())
                .flex()
                .flex_row()
                .flex_shrink(1000.)
                .overflow_hidden()
                .min_w_0()
                .max_w(theme.z(320.))
                .items_center()
                .gap(theme.z(4.))
                .h(theme.z(28.))
                .px(theme.z(8.))
                .rounded(theme.z(6.))
                .text_size(theme.z(text_size::SMALL))
                .text_color(theme.muted)
                .cursor_pointer()
                .hover(move |chip| chip.bg(hover).text_color(foreground))
                .tooltip(tooltip(entry.location_tooltip(&self.host.home)))
                .on_mouse_down(gpui::MouseButton::Left, |_, _, cx| cx.stop_propagation())
                .on_click(cx.listener(|this, _, _, cx| this.emit_for_selection(DashboardEvent::Open, cx)))
                .child(icon(folder).size(12.).color(theme.muted))
                .child(div().min_w_0().truncate().child(path))
                .children(entry.entry.branch.clone().map(|branch| {
                    div()
                        .flex()
                        .flex_row()
                        .flex_none()
                        .items_center()
                        .gap(theme.z(4.))
                        .ml(theme.z(6.))
                        .max_w(theme.z(160.))
                        .child(icon(IconName::GitBranch).size(11.).color(theme.muted))
                        .child(div().min_w_0().truncate().child(branch))
                })),
        )
    }

    /// "What should we build in storefront?" — the project's name opens the picker — over
    /// where the thread's tab will go.
    fn render_hero(&self, draft: &Draft, theme: &SopranoTheme, cx: &mut Context<Self>) -> impl IntoElement {
        let foreground = theme.foreground;
        let project = div()
            .id("agent-dashboard-draft-project")
            .debug_selector(|| "agent-dashboard-draft-project".into())
            .flex()
            .flex_row()
            .flex_shrink(1.)
            .min_w_0()
            .items_center()
            .gap(theme.z(6.))
            .ml(theme.z(7.))
            .font_weight(FontWeight::MEDIUM)
            .cursor_pointer()
            .border_b_1()
            .border_color(gpui::transparent_black())
            .hover(move |name| name.border_color(foreground.opacity(0.6)))
            .tooltip(tooltip("Choose a project"))
            .on_click(cx.listener(|this, _, window, cx| this.open_project_picker(window, cx)))
            .child(div().min_w_0().truncate().child(draft.project.name.clone()))
            .child(icon(IconName::ChevronDown).size(14.).color(theme.muted));
        div()
            .flex()
            .flex_col()
            .flex_none()
            .items_center()
            .gap(theme.z(8.))
            .max_w_full()
            .mb(theme.z(24.))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .max_w_full()
                    .text_size(theme.z(24.))
                    .child(div().flex_none().child("What should we build in"))
                    .child(project)
                    .child(div().flex_none().child("?")),
            )
            .child(
                div()
                    .id("agent-dashboard-draft-destination")
                    .text_color(theme.muted)
                    .font_weight(FontWeight::MEDIUM)
                    .child(state::draft_destination(draft.window_title.as_deref())),
            )
    }

    /// The floating composer: what the message brings along, the editor over the agent, a
    /// hint and the round send button. Files dropped onto it are attached.
    fn render_composer(&self, theme: &SopranoTheme, cx: &mut Context<Self>) -> impl IntoElement {
        let enabled = self.composer_enabled();
        let can_send =
            enabled && attachments::message_text(&self.editor.read(cx).value(), &self.attachments).is_some();
        let (hint, failed) = self.composer_hint();
        let dashboard = cx.entity().downgrade();
        let accent = theme.accent;
        div()
            .id("agent-dashboard-composer")
            .debug_selector(|| "agent-dashboard-composer".into())
            .relative()
            .w_full()
            .rounded(theme.z(16.))
            .border_1()
            .border_color(theme.foreground.opacity(if theme.is_dark() { 0.05 } else { 0.08 }))
            .bg(theme.popover.opacity(0.92))
            .when(!theme.is_dark(), |surface| surface.shadow_sm())
            .flex()
            .flex_col()
            .overflow_hidden()
            // The card floats over the conversation: a click into it must not also land on
            // the turn underneath, which would take the keyboard back from the editor.
            .block_mouse_except_scroll()
            .when(enabled, |card| {
                card.drag_over::<ExternalPaths>(move |card, _, _, _| card.border_color(accent)).on_drop(
                    cx.listener(|this, dropped: &ExternalPaths, window, cx| {
                        this.attach_files(dropped.paths().iter().cloned(), cx);
                        this.focus_composer(window, cx);
                    }),
                )
            })
            .child(measure(&self.composer_bounds))
            .children(self.render_attachments(theme, cx))
            .child(
                div()
                    .px(theme.z(16.))
                    .pt(theme.z(16.))
                    .pb(theme.z(8.))
                    .text_size(theme.z(text_size::BODY))
                    .text_color(theme.foreground)
                    .line_height(theme.z(EDITOR_LINE_HEIGHT))
                    .capture_action(cx.listener(Self::on_enter))
                    .child(
                        Textarea::new(&self.editor)
                            .appearance(false)
                            .bordered(false)
                            // A composer that cannot send steps back; the hint says why.
                            .disabled(!enabled)
                            .on_paste(move |clipboard, _, cx| {
                                dashboard.update(cx, |this, cx| this.paste(clipboard, cx)).unwrap_or(false)
                            }),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(theme.z(8.))
                    .h(theme.z(32.))
                    .mx(theme.z(8.))
                    .mb(theme.z(8.))
                    .child(self.render_agent_chip(theme, cx))
                    .children(self.render_option_chip(ThreadOption::Model, theme, cx))
                    .children(self.render_option_chip(ThreadOption::Thinking, theme, cx))
                    .child(
                        div()
                            .id("agent-dashboard-composer-hint")
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_right()
                            .text_size(theme.z(text_size::SMALL))
                            .text_color(if failed { theme.failed } else { theme.muted })
                            .child(hint),
                    )
                    .child(send_button(can_send, theme, cx)),
            )
    }

    /// What the message brings along, over the editor: images as thumbnails, other files by
    /// name, each with a ✕ that takes it out again.
    fn render_attachments(
        &self,
        theme: &SopranoTheme,
        cx: &mut Context<Self>,
    ) -> Option<impl IntoElement + use<>> {
        if self.attachments.is_empty() {
            return None;
        }
        let items = self.attachments.iter().enumerate().map(|(index, attachment)| {
            let remove = remove_button(index, attachment, theme, cx);
            let item = div()
                .id(("agent-dashboard-attachment", index))
                .relative()
                .flex_none()
                .rounded(theme.z(8.))
                .overflow_hidden()
                .tooltip(tooltip(attachment.name()));
            if attachment.is_image() {
                item.size(theme.z(THUMBNAIL_SIZE))
                    .border_1()
                    .border_color(theme.border)
                    .child(img(attachment.path.clone()).size_full().object_fit(ObjectFit::Cover))
                    .child(div().absolute().top(theme.z(3.)).right(theme.z(3.)).child(remove))
            } else {
                let name = attachment.name();
                item.flex()
                    .flex_row()
                    .items_center()
                    .gap(theme.z(6.))
                    .h(theme.z(28.))
                    .max_w(theme.z(240.))
                    .pl(theme.z(8.))
                    .pr(theme.z(5.))
                    .bg(theme.hover)
                    .text_size(theme.z(text_size::SMALL))
                    .child(icon(file_type_icon(&name)).size(14.).color(theme.muted))
                    .child(div().min_w_0().truncate().child(name))
                    .child(remove)
            }
        });
        Some(
            div()
                .id("agent-dashboard-attachments")
                .debug_selector(|| "agent-dashboard-attachments".into())
                .flex()
                .flex_row()
                .flex_wrap()
                .items_center()
                .gap(theme.z(8.))
                .px(theme.z(16.))
                .pt(theme.z(14.))
                .children(items),
        )
    }

    /// Who the composer writes to: the thread's agent, or for a new thread the agent it
    /// starts with, which a click changes.
    fn render_agent_chip(&self, theme: &SopranoTheme, cx: &mut Context<Self>) -> impl IntoElement {
        let chip = div()
            .id("agent-dashboard-agent")
            .debug_selector(|| "agent-dashboard-agent".into())
            .relative()
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(theme.z(6.))
            .h(theme.z(28.))
            .pl(theme.z(7.))
            .pr(theme.z(8.))
            .rounded(theme.z(8.))
            .font_weight(FontWeight::MEDIUM)
            .text_color(theme.foreground.opacity(0.8));
        let (hover, foreground) = (theme.hover, theme.foreground);
        match (&self.draft, self.selected()) {
            (Some(draft), _) => {
                let glyph = match agent_icon_stem(&draft.agent.profile_id) {
                    Some(stem) => Icon::program(stem),
                    None => icon(IconName::Bot),
                };
                chip.child(measure(&self.agent_chip_bounds))
                    .when(self.menu.is_some(), |chip| chip.bg(hover).text_color(foreground))
                    .when(!draft.launching, |chip| {
                        chip.cursor_pointer()
                            .hover(move |chip| chip.bg(hover).text_color(foreground))
                            .tooltip(tooltip("The agent the thread starts with"))
                            .on_click(cx.listener(|this, _, window, cx| this.open_agent_menu(window, cx)))
                    })
                    .child(glyph.size(16.).color(theme.muted))
                    .child(SharedString::from(draft.agent.name()))
                    .child(icon(IconName::ChevronDown).size(12.).color(theme.muted))
            }
            (None, Some(entry)) => chip
                .child(agent_glyph(&entry.entry).size(16.).color(theme.muted))
                .child(SharedString::from(entry.entry.profile_name.clone())),
            (None, None) => chip,
        }
    }

    /// The thread's model or thinking level, when its agent offers a choice: a click opens
    /// the choices.
    fn render_option_chip(
        &self,
        kind: ThreadOption,
        theme: &SopranoTheme,
        cx: &mut Context<Self>,
    ) -> Option<impl IntoElement + use<>> {
        let option = kind.of(self.composer_options())?;
        let (id, hint, slot) = match kind {
            ThreadOption::Model => ("agent-dashboard-model", "The model the thread runs on", 0),
            ThreadOption::Thinking => ("agent-dashboard-thinking", "How hard the model thinks", 1),
        };
        let (hover, foreground) = (theme.hover, theme.foreground);
        Some(
            div()
                .id(id)
                .debug_selector(move || id.into())
                .relative()
                .flex()
                .flex_row()
                .items_center()
                .gap(theme.z(4.))
                .h(theme.z(28.))
                .px(theme.z(8.))
                .rounded(theme.z(8.))
                .text_color(theme.foreground.opacity(0.8))
                // The model's name gives way first in a narrow composer.
                .when(kind == ThreadOption::Model, |chip| chip.min_w(theme.z(48.)))
                .when(kind == ThreadOption::Thinking, |chip| chip.flex_none())
                .child(measure(&self.option_chip_bounds[slot]))
                .when(self.options_enabled(), |chip| {
                    chip.cursor_pointer()
                        .hover(move |chip| chip.bg(hover).text_color(foreground))
                        .tooltip(tooltip(hint))
                        .on_click(cx.listener(move |this, _, window, cx| match kind {
                            ThreadOption::Model => this.open_model_picker(window, cx),
                            ThreadOption::Thinking => this.open_thinking_menu(window, cx),
                        }))
                })
                .when(!self.options_enabled(), |chip| chip.opacity(0.55))
                .child(div().min_w_0().truncate().child(SharedString::from(kind.label(option))))
                .child(icon(IconName::ChevronDown).size(12.).color(theme.muted)),
        )
    }
}

/// The ✕ on an attachment: a small disc that stays readable over a thumbnail.
fn remove_button(
    index: usize,
    attachment: &Attachment,
    theme: &SopranoTheme,
    cx: &mut Context<AgentDashboard>,
) -> impl IntoElement + use<> {
    let (rest, hover) = (theme.background.opacity(0.8), theme.background);
    div()
        .id(("agent-dashboard-attachment-remove", index))
        .flex()
        .flex_none()
        .items_center()
        .justify_center()
        .size(theme.z(REMOVE_SIZE))
        .rounded(theme.z(REMOVE_SIZE / 2.))
        .bg(rest)
        .cursor_pointer()
        .hover(move |button| button.bg(hover))
        .tooltip(tooltip(format!("Remove {}", attachment.name())))
        .on_click(cx.listener(move |this, _, _, cx| this.remove_attachment(index, cx)))
        .child(icon(IconName::X).size(10.).color(theme.foreground))
}

/// The composer's round send button: the accent disc while there is something to send, faint
/// otherwise.
fn send_button(can_send: bool, theme: &SopranoTheme, cx: &mut Context<AgentDashboard>) -> impl IntoElement {
    let (fill, glyph) = if can_send {
        (theme.accent, theme.accent_foreground)
    } else {
        (theme.foreground.opacity(0.12), theme.muted)
    };
    let hover = theme.accent.blend(theme.background.opacity(0.1));
    div()
        .id("agent-dashboard-send")
        .debug_selector(|| "agent-dashboard-send".into())
        .flex()
        .flex_none()
        .items_center()
        .justify_center()
        .size(theme.z(32.))
        .rounded(theme.z(16.))
        .bg(fill)
        .tooltip(tooltip("Send (Return)"))
        .when(can_send, |button| {
            button
                .cursor_pointer()
                .hover(move |button| button.bg(hover))
                .on_click(cx.listener(|this, _, window, cx| this.send(window, cx)))
        })
        .child(icon(IconName::ArrowUp).size(14.).color(glyph))
}
