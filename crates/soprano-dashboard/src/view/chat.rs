//! The chat column (Soprano Agents' chat): the 52 px header naming project and thread with
//! where it runs and what can be done with it, the conversation in the centered lane, and
//! the floating composer; or, for a new thread, the headline that picks its project over
//! the composer in the middle of the column.

use gpui::{
    AnyElement, Context, FontWeight, InteractiveElement, IntoElement, ParentElement, SharedString,
    StatefulInteractiveElement, Styled, Window, div, prelude::*,
};
use gpui_component::input::Textarea;
use soprano_chat_ui::composer::EDITOR_LINE_HEIGHT;
use soprano_chat_ui::widgets::text_size;
use soprano_ui::button::IconButton;
use soprano_ui::status::StatusPill;
use soprano_ui::tooltip::tooltip;
use soprano_ui::{Icon, IconName, Monogram, SopranoTheme, agent_icon_stem, icon};

use super::sidebar::agent_glyph;
use super::{AgentDashboard, DashboardEvent, Draft, TOPBAR_HEIGHT, drag_region, measure};
use crate::state::{self, Controls, DashboardEntry};

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
        let composer = div().w(theme.z(lane)).child(self.render_composer(controls, theme, cx));
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
            (None, None) => div().flex_1().into_any_element(),
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

    /// The floating composer: the editor over the agent, a hint and the round send button.
    fn render_composer(
        &self,
        controls: Controls,
        theme: &SopranoTheme,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let has_text = state::reply_text(&self.editor.read(cx).value()).is_some();
        let (enabled, can_send) = match &self.draft {
            Some(draft) => (!draft.launching, !draft.launching && has_text),
            None => (controls.reply, controls.reply && has_text),
        };
        let (hint, failed) = self.composer_hint();
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
            .child(measure(&self.composer_bounds))
            .child(
                div()
                    .px(theme.z(16.))
                    .pt(theme.z(16.))
                    .pb(theme.z(8.))
                    .text_size(theme.z(text_size::BODY))
                    .text_color(theme.foreground)
                    .line_height(theme.z(EDITOR_LINE_HEIGHT))
                    // A composer that cannot send steps back; the hint says why.
                    .when(!enabled, |body| body.opacity(0.55))
                    .capture_action(cx.listener(Self::on_enter))
                    .child(Textarea::new(&self.editor).appearance(false).bordered(false)),
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
                    .child(SharedString::from(draft.agent.label()))
                    .child(icon(IconName::ChevronDown).size(12.).color(theme.muted))
            }
            (None, Some(entry)) => chip.child(agent_glyph(&entry.entry).size(16.).color(theme.muted)).child(
                SharedString::from(if entry.entry.is_chat {
                    format!("{} · Chat", entry.entry.profile_name)
                } else {
                    entry.entry.profile_name.clone()
                }),
            ),
            (None, None) => chip,
        }
    }
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
