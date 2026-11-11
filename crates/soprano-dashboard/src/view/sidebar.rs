//! The thread inbox (Soprano Agents' sidebar): the brand band, search and New Thread, then the
//! threads as cards under "Title N ⌄" headers — project and status over the title, the branch
//! and what the agent does right now under it — with stopped threads on one line each.

use gpui::{
    AnyElement, ClickEvent, Context, ElementId, Focusable as _, FontWeight, InteractiveElement, IntoElement,
    ParentElement, StatefulInteractiveElement, Styled, Window, div, prelude::*, px, relative,
};
use gpui_component::input::Input;
use soprano_agents::ActivityTone;
use soprano_chat_ui::ActivityLine;
use soprano_chat_ui::widgets::text_size;
use soprano_model::AgentDashboardEntry;
use soprano_ui::button::IconButton;
use soprano_ui::chrome::{ScrollList, SectionHeader};
use soprano_ui::status::StatusPill;
use soprano_ui::tooltip::tooltip;
use soprano_ui::{Icon, IconName, Monogram, SopranoTheme, agent_icon_stem, icon};

use super::{
    AgentDashboard, DashboardEvent, SIDEBAR_MAXIMUM_FRACTION, SIDEBAR_WIDTH, TOPBAR_HEIGHT, drag_region,
};
use crate::state::{DashboardEntry, ListRow};

/// Between the sidebar's edge and a row's surface, and between the surface and its content.
const CONTENT_INSET: f32 = 8.0;
const ROW_INSET: f32 = 10.0;

impl AgentDashboard {
    pub(super) fn render_sidebar(
        &self,
        theme: &SopranoTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let rows = self.list.rows();
        let list: AnyElement = if rows.is_empty() {
            let text = if self.list.is_searching() { "No threads found" } else { "No threads yet" };
            div()
                .flex()
                .flex_col()
                .flex_1()
                .items_center()
                .pt(theme.z(24.))
                .text_size(theme.z(text_size::SMALL))
                .text_color(theme.muted.opacity(0.6))
                .child(text)
                .into_any_element()
        } else {
            let selected = self.list.selected_id();
            let drafting = self.draft.is_some();
            let children: Vec<AnyElement> = rows
                .iter()
                .map(|row| match row {
                    ListRow::Header { section, count, folded } => {
                        let section = *section;
                        SectionHeader::new(("agent-dashboard-section", section as usize), section.title())
                            .count(*count)
                            .collapsed(*folded)
                            .medium()
                            .pl(theme.z(CONTENT_INSET + ROW_INSET))
                            .pr(theme.z(CONTENT_INSET + ROW_INSET))
                            .text_size(theme.z(text_size::SMALL))
                            .on_toggle(cx.listener(move |this, _, _, cx| this.toggle_fold(section, cx)))
                            .into_any_element()
                    }
                    ListRow::Card(entry) => {
                        let open = !drafting && selected == Some(entry.id().as_str());
                        self.render_card(entry, open, theme, cx).into_any_element()
                    }
                    ListRow::Slim(entry) => {
                        let open = !drafting && selected == Some(entry.id().as_str());
                        self.render_slim_row(entry, open, theme, cx).into_any_element()
                    }
                })
                .collect();
            ScrollList::new("agent-dashboard-list-rows", &self.list_scroll)
                .pb(theme.z(8.))
                .children(children)
                .into_any_element()
        };
        div()
            .id("agent-dashboard-list")
            .debug_selector(|| "agent-dashboard-list".into())
            .flex()
            .flex_col()
            .flex_none()
            .h_full()
            .w(theme.z(SIDEBAR_WIDTH))
            .max_w(relative(SIDEBAR_MAXIMUM_FRACTION))
            .bg(theme.chrome)
            .border_r_1()
            .border_color(theme.border)
            .child(self.render_brand(theme))
            .child(self.render_search_row(theme, window, cx))
            .child(div().flex().flex_col().flex_1().min_h_0().mt(theme.z(8.)).child(list))
    }

    /// "Soprano Agents" beside the window's controls; the band moves the window.
    fn render_brand(&self, theme: &SopranoTheme) -> impl IntoElement {
        let leading =
            if self.host.leading_inset > 0.0 { self.host.leading_inset } else { CONTENT_INSET + ROW_INSET };
        drag_region(div().id("agent-dashboard-brand"))
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .h(theme.z(TOPBAR_HEIGHT))
            .pl(theme.z(leading))
            .pr(theme.z(12.))
            .font_weight(FontWeight::MEDIUM)
            .whitespace_nowrap()
            .overflow_hidden()
            .child("Soprano")
            .child(div().text_color(theme.muted).child("\u{a0}Agents"))
    }

    /// The search field and the New Thread button.
    fn render_search_row(
        &self,
        theme: &SopranoTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let focused = self.search.focus_handle(cx).contains_focused(window, cx);
        let active = focused || self.list.is_searching();
        let hover = theme.hover;
        div()
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(theme.z(4.))
            .h(theme.z(32.))
            .mx(theme.z(CONTENT_INSET))
            .child(
                div()
                    .id("agent-dashboard-search")
                    .debug_selector(|| "agent-dashboard-search".into())
                    .flex()
                    .flex_row()
                    .flex_1()
                    .min_w_0()
                    .items_center()
                    .h_full()
                    .pl(theme.z(8.))
                    .rounded(theme.z(6.))
                    .border_1()
                    .border_color(if focused { theme.accent.opacity(0.7) } else { gpui::transparent_black() })
                    .when(active, |field| field.bg(hover))
                    .hover(move |field| field.bg(hover))
                    .text_color(if active { theme.foreground } else { theme.muted })
                    .child(icon(IconName::Search).size(13.).color(theme.muted))
                    .child(div().flex_1().min_w_0().child(Input::new(&self.search).appearance(false))),
            )
            .child(
                div().debug_selector(|| "agent-dashboard-new-thread".into()).child(
                    IconButton::new("agent-dashboard-new-thread", IconName::NEW_THREAD)
                        .icon_size(14.)
                        .selected(self.draft.is_some())
                        .tooltip("New thread (N)")
                        .on_click(cx.listener(|this, _, window, cx| this.new_thread(window, cx))),
                ),
            )
    }

    /// The surface every thread row shares: radius 6, the open thread filled, the others
    /// under the pointer; a click opens the thread here, a double-click in its window.
    fn row_surface(
        &self,
        entry: &DashboardEntry,
        open: bool,
        theme: &SopranoTheme,
        cx: &mut Context<Self>,
    ) -> gpui::Stateful<gpui::Div> {
        let id = entry.id();
        let hover = theme.hover;
        // Light themes ring the open thread; the ring is always there so nothing shifts.
        let ring =
            if open && !theme.is_dark() { theme.border.opacity(0.7) } else { gpui::transparent_black() };
        div()
            .id(ElementId::Name(format!("agent-dashboard-row-{id}").into()))
            .mx(theme.z(CONTENT_INSET))
            .px(theme.z(ROW_INSET))
            .rounded(theme.z(6.))
            .border_1()
            .border_color(ring)
            .cursor_pointer()
            .map(|row| match (open, entry.entry.needs_attention) {
                (true, _) => row.bg(theme.selected),
                (false, true) => row.bg(theme.attention_row_wash).hover(move |row| row.bg(hover)),
                (false, false) => row.hover(move |row| row.bg(hover)),
            })
            .tooltip(tooltip(entry.row_tooltip(&self.host.home)))
            .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
                if event.click_count() >= 2 {
                    if let Some(entry) = this.list.entry(&id) {
                        cx.emit(DashboardEvent::Open(entry.target()));
                    }
                } else {
                    this.select(&id, window, cx);
                }
            }))
    }

    /// A thread as a card: its project and status, what it works on, and under that the
    /// machine or branch, what the agent does right now, and the agent's mark.
    fn render_card(
        &self,
        entry: &DashboardEntry,
        open: bool,
        theme: &SopranoTheme,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let receded = entry.is_receded(open);
        let activity = self.current_activity(entry);
        let has_meta = entry.has_meta() || activity.is_some();
        let mark = || agent_glyph(&entry.entry).size(14.).color(theme.muted.opacity(0.6));
        let project = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(theme.z(6.))
            .h(theme.z(20.))
            .min_w_0()
            .when(!entry.project.is_empty(), |line| line.child(Monogram::new(entry.project.clone())))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(theme.z(text_size::SMALL))
                    .text_color(theme.muted)
                    .child(if entry.project.is_empty() {
                        "No project".to_owned()
                    } else {
                        entry.project.clone()
                    }),
            )
            .child(StatusPill::new(entry.pill()).relative_to(Some(entry.since)).now(self.now));
        let title = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(theme.z(6.))
            .h(theme.z(20.))
            .mt(theme.z(4.))
            .min_w_0()
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .font_weight(if receded { FontWeight::NORMAL } else { FontWeight::MEDIUM })
                    .text_color(if receded { theme.foreground.opacity(0.75) } else { theme.foreground })
                    .child(entry.title()),
            )
            .when(!has_meta, |line| line.child(mark()));
        let meta = has_meta.then(|| {
            let part = |glyph: IconName, text: &str| {
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(theme.z(4.))
                    .min_w_0()
                    .child(icon(glyph).size(11.).color(theme.muted))
                    .child(div().min_w_0().truncate().child(text.to_owned()))
            };
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(theme.z(8.))
                .h(theme.z(16.))
                .mt(theme.z(2.))
                .min_w_0()
                .text_size(theme.z(text_size::SMALL))
                .text_color(theme.muted)
                // What the agent does says more than where: the machine and branch show while
                // there is nothing to say (the header and the tooltip always name them).
                .map(|line| match activity {
                    Some(activity) => {
                        let failed = activity.tone == ActivityTone::Failed;
                        line.child(
                            div().flex_1().min_w_0().child(
                                ActivityLine::new(activity)
                                    .compact(true)
                                    .fonts(text_size::SMALL, FontWeight::NORMAL)
                                    .color(if failed { theme.failed } else { theme.muted }),
                            ),
                        )
                    }
                    None => line
                        .children(
                            entry
                                .entry
                                .machine
                                .as_deref()
                                .map(|machine| part(IconName::Server, machine).flex_none()),
                        )
                        .children(
                            entry.entry.branch.as_deref().map(|branch| part(IconName::GitBranch, branch)),
                        )
                        .child(div().flex_1()),
                })
                .child(mark())
        });
        let selector = format!("agent-dashboard-row-{}", entry.id());
        div().debug_selector(move || selector).pt(theme.z(2.)).pb(theme.z(3.)).child(
            self.row_surface(entry, open, theme, cx)
                .flex()
                .flex_col()
                // With the ring: 8 above, and 8 below the third line or 6 below the title.
                .pt(theme.z(7.))
                .pb(theme.z(if has_meta { 7. } else { 5. }))
                .child(project)
                .child(title)
                .children(meta),
        )
    }

    /// A stopped thread on one line: monogram, title, and how long ago it stopped.
    fn render_slim_row(
        &self,
        entry: &DashboardEntry,
        open: bool,
        theme: &SopranoTheme,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let selector = format!("agent-dashboard-row-{}", entry.id());
        div().debug_selector(move || selector).pb(px(1.)).child(
            self.row_surface(entry, open, theme, cx)
                .flex()
                .flex_row()
                .items_center()
                .gap(theme.z(10.))
                .h(theme.z(36.))
                .when(!entry.project.is_empty(), |row| {
                    row.child(
                        div()
                            .opacity(if open { 1.0 } else { 0.4 })
                            .child(Monogram::new(entry.project.clone())),
                    )
                })
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .truncate()
                        .text_color(if open { theme.foreground } else { theme.muted })
                        .child(entry.title()),
                )
                .child(StatusPill::new(None).relative_to(Some(entry.since)).now(self.now)),
        )
    }
}

/// The agent's program icon where one ships, else a chat or agent glyph.
pub(super) fn agent_glyph(entry: &AgentDashboardEntry) -> Icon {
    match agent_icon_stem(&entry.profile_id) {
        Some(stem) => Icon::program(stem),
        None if entry.is_chat => icon(IconName::MessageSquare),
        None => icon(IconName::Bot),
    }
}
