//! The chat's timeline (`ChatTimelineView.swift`, `TimelineListView.swift`): the source's turns
//! in the centered chat lane, what is expanded, the "Working for" clock, following the newest
//! row and the "Scroll to end" pill. The Agent Dashboard shows terminal agents' transcripts
//! with it too.

use std::collections::HashMap;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use gpui::FollowMode;
use gpui::{
    App, ClickEvent, ClipboardItem, Context, DismissEvent, Entity, EventEmitter, FocusHandle, Focusable,
    FontWeight, IntoElement, KeyDownEvent, ListAlignment, ListOffset, ListState, ParentElement, Pixels,
    Render, ScrollHandle, SharedString, Styled, Subscription, Task, Window, div, list, prelude::*, px,
};
use soprano_text::hunks::InlineDiff;
use soprano_ui::fonts::UI_FONT_FAMILY;
use soprano_ui::menu::{ContextMenu, MenuItem};
use soprano_ui::{ActiveSopranoTheme, IconName, icon};

use crate::rows::{ExpansionSet, TimelineExpansion, TimelineRow, TimelineRowContent, timeline_rows};
use crate::source::TimelineSource;
use crate::widgets::text_size;

/// `--chat-content-max-width` (46rem): timeline lane and composer.
pub const CHAT_MAX_WIDTH: f32 = 736.0;
/// The page gutter: 20, or 12 in a column too narrow to spare it (a chat tab in a split pane).
pub const GUTTER: f32 = 20.0;
pub const NARROW_GUTTER: f32 = 12.0;
/// Columns narrower than this take the narrow gutter.
pub const NARROW_WIDTH: f32 = 480.0;
/// `h-3 sm:h-4` top spacer.
pub const TOP_PADDING: f32 = 16.0;

/// The page gutter for a column `width` wide.
pub fn gutter(width: f32) -> f32 {
    if width < NARROW_WIDTH { NARROW_GUTTER } else { GUTTER }
}

/// The chat lane's width in a column `width` wide: the lane cap inside the page gutters.
pub fn lane_width(width: f32) -> f32 {
    (width - gutter(width) * 2.0).clamp(0.0, CHAT_MAX_WIDTH)
}

/// What the timeline tells its host.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TimelineEvent {
    /// The timeline started (`true`) or stopped following its newest row.
    FollowingChanged(bool),
}

/// The parsed diff of a file row and the text it came from (`InlineDiff.of`'s cache).
struct CachedDiff {
    diff: String,
    full_content: bool,
    value: Arc<InlineDiff>,
}

pub struct TimelineView {
    source: Rc<dyn TimelineSource>,
    agent_name: String,
    pub(crate) expansion: TimelineExpansion,
    pub(crate) rows: Vec<TimelineRow>,
    pub(crate) list: ListState,
    focus_handle: FocusHandle,
    bottom_inset: f32,
    was_following: bool,
    clock: Option<Task<()>>,
    /// The row whose Copy button shows its check for a moment.
    pub(crate) copied: Option<String>,
    copy_reset: Option<Task<()>>,
    pub(crate) menu: Option<(Entity<ContextMenu>, Subscription)>,
    diffs: HashMap<String, CachedDiff>,
    /// Scroll positions of open diff bodies, by row id (a running write keeps its end in view).
    pub(crate) diff_scrolls: HashMap<String, ScrollHandle>,
    /// The list's size at the last frame, in window pixels (read before the list lays out:
    /// its rows cannot ask the list while it measures them).
    pub(crate) viewport: gpui::Size<Pixels>,
}

impl EventEmitter<TimelineEvent> for TimelineView {}

impl Focusable for TimelineView {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl TimelineView {
    pub fn new(
        source: Rc<dyn TimelineSource>,
        agent_name: impl Into<String>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let list = ListState::new(0, ListAlignment::Top, px(320.0));
        list.set_follow_mode(FollowMode::Tail);
        let entity = cx.weak_entity();
        // The list calls this while it holds its own state: take what it reports, never ask it.
        list.set_scroll_handler(move |event, _, cx| {
            let following = event.is_following_tail;
            if let Some(view) = entity.upgrade() {
                view.update(cx, |view, cx| view.set_following(following, cx));
            }
        });
        let mut view = Self {
            source,
            agent_name: agent_name.into(),
            expansion: TimelineExpansion::default(),
            rows: Vec::new(),
            list,
            focus_handle: cx.focus_handle(),
            bottom_inset: 0.0,
            was_following: true,
            clock: None,
            copied: None,
            copy_reset: None,
            menu: None,
            diffs: HashMap::new(),
            diff_scrolls: HashMap::new(),
            viewport: gpui::Size::default(),
        };
        view.reload(true, cx);
        view
    }

    pub fn agent_name(&self) -> &str {
        &self.agent_name
    }

    pub fn set_agent_name(&mut self, name: impl Into<String>, cx: &mut Context<Self>) {
        self.agent_name = name.into();
        self.reload(false, cx);
    }

    /// The rows on screen, in order.
    pub fn rows(&self) -> &[TimelineRow] {
        &self.rows
    }

    pub fn expansion(&self) -> &TimelineExpansion {
        &self.expansion
    }

    /// Space at the bottom the floating composer covers; the timeline pads its end by it.
    pub fn set_bottom_inset(&mut self, inset: Pixels, cx: &mut Context<Self>) {
        let inset = f32::from(inset);
        if (inset - self.bottom_inset).abs() > 0.5 {
            self.bottom_inset = inset;
            cx.notify();
        }
    }

    /// Re-reads the source. `scroll_to_end` follows the newest row again.
    pub fn reload(&mut self, scroll_to_end: bool, cx: &mut Context<Self>) {
        let thread = self.source.thread();
        let empty = self.source.empty_timeline_text(&self.agent_name);
        let rows = timeline_rows(&thread, &empty, &self.expansion);
        self.set_rows(rows);
        if scroll_to_end {
            self.list.set_follow_mode(FollowMode::Tail);
        }
        self.update_clock(thread.is_running(), cx);
        self.scrolled(cx);
        cx.notify();
    }

    /// Replaces the rows, re-measuring only the ones that changed.
    fn set_rows(&mut self, rows: Vec<TimelineRow>) {
        let old = &self.rows;
        let prefix = old.iter().zip(&rows).take_while(|(a, b)| a == b).count();
        let max_suffix = old.len().min(rows.len()) - prefix;
        let suffix =
            old.iter().rev().zip(rows.iter().rev()).take(max_suffix).take_while(|(a, b)| a == b).count();
        let old_range = prefix..old.len() - suffix;
        let new_count = rows.len() - suffix - prefix;
        if !old_range.is_empty() || new_count > 0 {
            self.list.splice(old_range, new_count);
        }
        let live: std::collections::HashSet<&str> = rows.iter().map(|r| r.id.as_str()).collect();
        self.diff_scrolls.retain(|key, _| key.split('|').next().is_some_and(|id| live.contains(id)));
        self.rows = rows;
    }

    /// Whether the timeline sticks to its newest row as rows arrive.
    pub fn is_following(&self) -> bool {
        self.list.is_following_tail()
    }

    /// The detailed work log (folds, groups and diffs open by default) or the minimal one.
    /// What the person toggled is read against the default, so switching drops it.
    pub fn is_detailed(&self) -> bool {
        self.expansion.detailed
    }

    pub fn set_detailed(&mut self, detailed: bool, cx: &mut Context<Self>) {
        if detailed == self.expansion.detailed {
            return;
        }
        self.expansion.detailed = detailed;
        self.expansion.turns.clear();
        self.expansion.groups.clear();
        self.expansion.diffs.clear();
        self.reload(false, cx);
    }

    /// Scrolls by `delta` as the person would: leaving the end stops following.
    pub fn scroll_by(&mut self, delta: Pixels, cx: &mut Context<Self>) {
        self.list.scroll_by(delta);
        self.scrolled(cx);
        cx.notify();
    }

    fn viewport_height(&self) -> f32 {
        f32::from(self.viewport.height)
    }

    /// The visible height a page scroll moves by.
    pub fn page_height(&self) -> Pixels {
        px((self.viewport_height() - self.bottom_inset - 40.0).max(48.0))
    }

    /// Scrolls the next (`direction` > 0) or previous message the person sent to the top. Past
    /// the last message it follows the newest row; before the first it goes to the top.
    pub fn jump_to_message(&mut self, direction: i32, cx: &mut Context<Self>) {
        let top = self.list.logical_scroll_top();
        let messages = self.rows.iter().enumerate().filter(|(_, r)| r.is_turn_message()).map(|(i, _)| i);
        let target = if direction > 0 {
            messages.clone().find(|&i| i > top.item_ix)
        } else {
            messages.rev().find(|&i| i < top.item_ix || (i == top.item_ix && top.offset_in_item > px(8.0)))
        };
        match target {
            Some(index) => self.list.scroll_to(ListOffset { item_ix: index, offset_in_item: px(0.0) }),
            None if direction > 0 => {
                self.jump_to_latest(cx);
                return;
            }
            None => self.list.scroll_to(ListOffset { item_ix: 0, offset_in_item: px(0.0) }),
        }
        if target.is_some() || direction <= 0 {
            self.list.pause_following_tail();
        }
        self.scrolled(cx);
        cx.notify();
    }

    /// Follows the newest row again (the "Scroll to end" pill, End, `G`).
    pub fn jump_to_latest(&mut self, cx: &mut Context<Self>) {
        self.list.set_follow_mode(FollowMode::Tail);
        self.list.scroll_to_end();
        self.scrolled(cx);
        cx.notify();
    }

    fn scrolled(&mut self, cx: &mut Context<Self>) {
        let following = self.is_following();
        self.set_following(following, cx);
    }

    /// Records whether the timeline follows its end and tells the host when that changed.
    /// Never reads the list (the list's scroll callback lands here).
    fn set_following(&mut self, following: bool, cx: &mut Context<Self>) {
        if following != self.was_following {
            self.was_following = following;
            cx.emit(TimelineEvent::FollowingChanged(following));
            cx.notify();
        }
    }

    /// Keeps row `index`'s header in view: nothing when it already shows (8 px inside the lane
    /// above the composer), else the row goes to the top and the timeline stops following.
    fn reveal_row(&mut self, index: usize, cx: &mut Context<Self>) {
        let viewport = self.list.viewport_bounds();
        let header = px(24.0);
        let visible_top = viewport.top() + px(8.0);
        let visible_bottom = viewport.bottom() - px(self.bottom_inset) - px(8.0);
        let shown = self
            .list
            .bounds_for_item(index)
            .is_some_and(|bounds| bounds.top() >= visible_top && bounds.top() + header <= visible_bottom);
        if shown {
            return;
        }
        self.list.scroll_to(ListOffset { item_ix: index, offset_in_item: px(0.0) });
        self.list.pause_following_tail();
        self.scrolled(cx);
    }

    fn update_clock(&mut self, running: bool, cx: &mut Context<Self>) {
        if !running {
            self.clock = None;
            return;
        }
        if self.clock.is_some() {
            return;
        }
        self.clock = Some(cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(Duration::from_secs(1)).await;
                if this.update(cx, |_, cx| cx.notify()).is_err() {
                    break;
                }
            }
        }));
    }

    /// Stops the clock (the tab is closing).
    pub fn close(&mut self) {
        self.clock = None;
        self.copy_reset = None;
        self.menu = None;
    }

    // MARK: Expansion

    pub(crate) fn toggle(&mut self, set: ExpansionSet, id: &str, cx: &mut Context<Self>) {
        self.expansion.toggle(set, id);
        self.reload(false, cx);
        // A following timeline keeps its end in view; keep an opened row's header in view instead.
        if let Some(index) = self.opened_row(set, id) {
            self.reveal_row(index, cx);
        }
    }

    /// The row that toggling `id` opened, if it opened one.
    fn opened_row(&self, set: ExpansionSet, id: &str) -> Option<usize> {
        self.rows.iter().position(|row| match (&row.content, set) {
            (TimelineRowContent::Fold(m), ExpansionSet::Turns) => m.turn_id == id && m.expanded,
            (TimelineRowContent::WorkGroup(m), ExpansionSet::Groups) => m.group_id == id && m.expanded,
            (TimelineRowContent::LiveWork(m), ExpansionSet::Groups) => m.group_id == id && m.expanded,
            (TimelineRowContent::WorkEntry(m), ExpansionSet::Entries) => m.entry.id == id && m.expanded,
            (TimelineRowContent::FileDiff(m), ExpansionSet::Diffs) => m.id == id && m.expanded,
            (TimelineRowContent::User(m), ExpansionSet::Messages) => m.message.id == id && m.expanded,
            _ => false,
        })
    }

    pub(crate) fn set_closed_folders(
        &mut self,
        turn_id: &str,
        paths: std::collections::HashSet<String>,
        cx: &mut Context<Self>,
    ) {
        self.expansion.closed_folders.insert(turn_id.to_owned(), paths);
        self.reload(false, cx);
    }

    /// Opens the turn's fold and the work group holding the file's diff, opens the diff and
    /// scrolls to it.
    pub fn reveal_diff(&mut self, turn_id: &str, path: &str, cx: &mut Context<Self>) {
        self.expansion.set(ExpansionSet::Turns, turn_id, true);
        let thread = self.source.thread();
        let empty = self.source.empty_timeline_text(&self.agent_name);
        let message_row =
            thread.turns.iter().find(|t| t.id == turn_id).map(|t| format!("user:{}", t.user_message.id));
        let fold_row = format!("fold:{turn_id}");
        for _ in 0..2 {
            let rows = timeline_rows(&thread, &empty, &self.expansion);
            let Some(start) =
                rows.iter().position(|r| Some(&r.id) == message_row.as_ref() || r.id == fold_row)
            else {
                break;
            };
            // The turn's rows run until the next turn's message.
            let end = rows[start + 1..]
                .iter()
                .position(TimelineRow::is_turn_message)
                .map_or(rows.len(), |i| start + 1 + i);
            if let Some(row) = rows[start..end].iter().find(|row| {
                matches!(&row.content, TimelineRowContent::FileDiff(model) if model.shown_path() == path)
            }) {
                if let TimelineRowContent::FileDiff(model) = &row.content {
                    self.expansion.set(ExpansionSet::Diffs, &model.id.clone(), true);
                }
                let id = row.id.clone();
                self.reload(false, cx);
                if let Some(index) = self.rows.iter().position(|r| r.id == id) {
                    self.reveal_row(index, cx);
                }
                return;
            }
            // The diff sits in a closed group: open the turn's groups and look again.
            for row in &rows[start..end] {
                if let TimelineRowContent::WorkGroup(model) = &row.content
                    && !model.expanded
                {
                    self.expansion.set(ExpansionSet::Groups, &model.group_id.clone(), true);
                }
            }
        }
        self.reload(false, cx);
    }

    // MARK: Source actions

    pub(crate) fn respond(&mut self, option_id: &str, cx: &mut Context<Self>) {
        self.source.choose_permission_option(option_id);
        self.reload(false, cx);
    }

    pub(crate) fn can_send_queued_now(&self) -> bool {
        self.source.can_send_queued_now()
    }

    pub(crate) fn send_queued_now(&mut self, id: &str, cx: &mut Context<Self>) {
        self.source.send_queued_prompt_now(id);
        self.reload(false, cx);
    }

    pub(crate) fn remove_queued(&mut self, id: &str, cx: &mut Context<Self>) {
        self.source.remove_queued_prompt(id);
        self.reload(false, cx);
    }

    /// Copies `text` and shows the row's Copy button as a check for a moment.
    pub(crate) fn copy(&mut self, row_id: &str, text: String, cx: &mut Context<Self>) {
        cx.write_to_clipboard(ClipboardItem::new_string(text));
        self.copied = Some(row_id.to_owned());
        self.copy_reset = Some(cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_millis(1_200)).await;
            this.update(cx, |this, cx| {
                this.copied = None;
                cx.notify();
            })
            .ok();
        }));
        cx.notify();
    }

    /// The "More" menu of an approval's other answers.
    pub(crate) fn show_more_menu(
        &mut self,
        event: &ClickEvent,
        options: Vec<(String, String)>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let entity = cx.weak_entity();
        let items = options
            .into_iter()
            .map(|(id, name)| {
                let entity = entity.clone();
                MenuItem::new(name).on_select(move |_, cx| {
                    if let Some(view) = entity.upgrade() {
                        view.update(cx, |view, cx| view.respond(&id, cx));
                    }
                })
            })
            .collect();
        let menu = ContextMenu::new(event.position(), items, window, cx);
        let subscription = cx.subscribe(&menu, |this, _, _: &DismissEvent, cx| {
            this.menu = None;
            cx.notify();
        });
        self.menu = Some((menu, subscription));
        cx.notify();
    }

    /// The parsed diff of file row `id`, parsed once per text and colored once open.
    pub(crate) fn inline_diff(
        &mut self,
        id: &str,
        change: &soprano_agents::FileChange,
        highlighted: bool,
    ) -> Option<Arc<InlineDiff>> {
        let diff = change.diff.as_deref().filter(|d| !d.is_empty())?;
        let full_content = change.is_full_content == Some(true);
        if let Some(cached) = self.diffs.get(id)
            && cached.full_content == full_content
            && cached.diff == diff
            && (!highlighted || cached.value.is_highlighted())
        {
            return Some(cached.value.clone());
        }
        let mut value = match self.diffs.remove(id) {
            Some(cached) if cached.full_content == full_content && cached.diff == diff => {
                Arc::try_unwrap(cached.value).unwrap_or_else(|shared| (*shared).clone())
            }
            _ => InlineDiff::new(diff, change.move_path.as_deref().unwrap_or(&change.path), full_content),
        };
        if highlighted {
            value.highlight();
        }
        if self.diffs.len() >= 512 {
            self.diffs.clear();
        }
        let value = Arc::new(value);
        self.diffs
            .insert(id.to_owned(), CachedDiff { diff: diff.to_owned(), full_content, value: value.clone() });
        Some(value)
    }

    // MARK: Keys

    fn key_down(&mut self, event: &KeyDownEvent, _window: &mut Window, cx: &mut Context<Self>) {
        let modifiers = event.keystroke.modifiers;
        if modifiers.control || modifiers.alt || modifiers.platform {
            return;
        }
        let page = px((self.viewport_height() - self.bottom_inset - 60.0).max(40.0));
        match event.keystroke.key.as_str() {
            "down" if !modifiers.shift => self.scroll_by(px(48.0), cx),
            "up" if !modifiers.shift => self.scroll_by(px(-48.0), cx),
            "pagedown" => self.scroll_by(page, cx),
            "space" => self.scroll_by(if modifiers.shift { -page } else { page }, cx),
            "pageup" => self.scroll_by(-page, cx),
            "home" => {
                self.list.scroll_to(ListOffset { item_ix: 0, offset_in_item: px(0.0) });
                self.scrolled(cx);
                cx.notify();
            }
            "end" => self.jump_to_latest(cx),
            _ => return,
        }
        cx.stop_propagation();
    }

    fn render_pill(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.soprano_theme().clone();
        let fill = if t.is_dark() { t.popover } else { t.background };
        div()
            .id("timeline-scroll-to-end")
            .absolute()
            .left_0()
            .right_0()
            .bottom(px(self.bottom_inset) - t.z(6.0))
            .flex()
            .justify_center()
            .child(
                div()
                    .id("timeline-scroll-to-end-pill")
                    .h(t.z(26.0))
                    .pl(t.z(10.0))
                    .pr(t.z(12.0))
                    .flex()
                    .items_center()
                    .gap(t.z(4.0))
                    .rounded(t.z(13.0))
                    .border_1()
                    .border_color(t.border)
                    .bg(fill.opacity(0.92))
                    .hover(|s| s.bg(t.raised))
                    .shadow_md()
                    .cursor_pointer()
                    .tooltip(soprano_ui::tooltip("Jump to latest"))
                    .on_click(cx.listener(|this, _, _, cx| this.jump_to_latest(cx)))
                    .child(icon(IconName::ChevronDown).size(11.0).color(t.foreground))
                    .child(
                        div()
                            .font_family(UI_FONT_FAMILY)
                            .text_size(t.z(text_size::SMALL))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(t.foreground)
                            .child("Scroll to end"),
                    ),
            )
    }
}

impl Render for TimelineView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.soprano_theme().clone();
        self.viewport = self.list.viewport_bounds().size;
        let shows_pill = !self.is_following() && !self.rows.is_empty();
        let bottom = self.bottom_inset;
        div()
            .id("agent-chat-timeline")
            .key_context("ChatTimeline")
            .track_focus(&self.focus_handle)
            .on_key_down(cx.listener(Self::key_down))
            .on_mouse_down(
                gpui::MouseButton::Left,
                cx.listener(|this, _, window, cx| {
                    this.focus_handle.focus(window, cx);
                }),
            )
            .relative()
            .size_full()
            .bg(t.background)
            .child(
                list(
                    self.list.clone(),
                    cx.processor(|this, index, window, cx| this.render_row(index, window, cx)),
                )
                .size_full()
                .pt(t.z(TOP_PADDING))
                .pb(px(bottom)),
            )
            .when(shows_pill, |view| view.child(self.render_pill(cx)))
            .when_some(self.menu.as_ref().map(|(menu, _)| menu.clone()), |view, menu| view.child(menu))
    }
}

impl TimelineView {
    /// Height of the empty state in window pixels: the visible lane above the composer.
    pub(crate) fn empty_height(&self, zoom: f32) -> f32 {
        (self.viewport_height() - self.bottom_inset - TOP_PADDING * zoom).max(20.0 * zoom)
    }

    pub(crate) fn row_group(id: &str) -> SharedString {
        SharedString::from(format!("row-{id}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_lane_keeps_the_gutters_and_caps_at_the_chat_width() {
        assert_eq!(gutter(479.0), NARROW_GUTTER);
        assert_eq!(gutter(480.0), GUTTER);
        assert_eq!(lane_width(1200.0), CHAT_MAX_WIDTH);
        assert_eq!(lane_width(600.0), 560.0);
        assert_eq!(lane_width(400.0), 376.0);
        assert_eq!(lane_width(10.0), 0.0);
    }
}
