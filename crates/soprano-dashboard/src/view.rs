//! The Agent Dashboard view (`AgentDashboardViewController.swift`), laid out like a mail
//! client on the window's own surfaces: on `canvas`, the page header over the agents under
//! Needs you / Working / Ready / Stopped; beside them, as a pane-like `background` card, the
//! selected agent — its title and where it runs over a toolbar, its conversation (or live
//! terminal), and a reply composer.

use std::collections::HashMap;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::{Duration, SystemTime};

use futures::StreamExt as _;
use gpui::{
    AnyElement, App, AppContext as _, ClickEvent, Context, ElementId, Entity, EventEmitter, FocusHandle,
    Focusable, FontWeight, InteractiveElement, IntoElement, Keystroke, MouseButton, ParentElement, Render,
    ScrollHandle, SharedString, StatefulInteractiveElement, Styled, Subscription, Task, Window, div, point,
    prelude::*, px, relative,
};
use gpui_component::input::{Input, InputEvent, InputState};
use soprano_agents::{
    ActivityTone, AgentTimeline, AgentTimelineActivity, AgentTranscriptSource, AgentTranscriptStore,
    ChatThread,
};
use soprano_chat_ui::{ActivityLine, TimelineSource, TimelineView, TranscriptSource};
use soprano_editor::rich::RichText;
use soprano_model::AgentDashboardEntry;
use soprano_model::Workspace;
use soprano_text::context_line::{ContextLine, ContextPart};
use soprano_types::AgentStatus;
use soprano_types::TerminalTarget;
use soprano_ui::button::{Button, ButtonSize, IconButton};
use soprano_ui::chrome::{Card, ScrollList, SectionHeader, SidebarRow};
use soprano_ui::controls::SegmentedControl;
use soprano_ui::fonts::{self, size};
use soprano_ui::keycaps::Keycaps;
use soprano_ui::status::StatusPill;
use soprano_ui::theme::ActiveSopranoTheme;
use soprano_ui::tooltip::tooltip;
use soprano_ui::{Icon, IconName, SopranoTheme, agent_icon_stem, icon};

use crate::keys::{KeyAction, ScrollAmount, key_action};
use crate::state::{
    self, AgentList, Controls, DashboardEntry, TerminalText, date, elapsed_text, monitoring_subtitle,
};
use crate::text::{OutputPalette, output_highlights};

/// The agent list's width; a narrow window takes it down to 40 % of the dashboard.
const LIST_WIDTH: f32 = 380.0;
const LIST_MAXIMUM_FRACTION: f32 = 0.4;
/// The list footer with its key hints.
const FOOTER_HEIGHT: f32 = 40.0;
/// The page header.
const HEADER_HEIGHT: f32 = 48.0;
/// One agent row.
const ROW_HEIGHT: f32 = 52.0;
/// A row's icon and the gap after it: what its second line is indented by.
const ROW_ICON: f32 = 16.0;
const ROW_ICON_GAP: f32 = 9.0;
/// Between the detail card and the page's edges, as between panes in the window.
const CARD_GAP: f32 = 8.0;
/// The detail card's side margins.
const GUTTER: f32 = 20.0;
/// The detail title's icon and the gap after it: what the line under it is indented by.
const TITLE_ICON: f32 = 18.0;
const TITLE_ICON_GAP: f32 = 10.0;
/// The composer keeps to the timeline's chat lane (`Metrics.chatMaxWidth`).
const READABLE_WIDTH: f32 = 736.0;
const REPLY_FIELD_HEIGHT: f32 = 44.0;
/// One J/K line of scrolling.
const LINE_SCROLL: f32 = 48.0;
/// Between the window and the agent on the detail's location line.
const LOCATION_SEPARATOR: &str = "  /  ";

/// What the dashboard asks the app shell to do. The dashboard never mutates the workspace.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DashboardEvent {
    /// Return, a double-click or Open: focus that exact pane tab (revealing it in the
    /// sidebar) and close the dashboard.
    Open(TerminalTarget),
    /// `Workspace::stop_agent`.
    Stop(TerminalTarget),
    /// `Workspace::restart_agent`.
    Restart(TerminalTarget),
    /// Type `text` (trimmed, single line) and Return into that pane tab's terminal, or send it
    /// to the chat session for a chat tab. When it cannot be delivered, call
    /// [`AgentDashboard::reply_failed`].
    Reply { target: TerminalTarget, text: String },
    /// Esc or the close button: close the dashboard without changing the active agent.
    Close,
}

/// The exact pane tab's visible terminal text; `None` while it has no live terminal.
pub type TerminalTextProvider = Rc<dyn Fn(&TerminalTarget, &App) -> Option<String>>;
/// A folder's branch when it is not its repository's default (the branch monitor).
pub type BranchProvider = Rc<dyn Fn(&str, &App) -> Option<String>>;

/// What the shell answers that the workspace model does not know.
#[derive(Clone)]
pub struct DashboardHost {
    /// Read for the selected agent when it changes or the workspace notifies (whether a reply
    /// can go out), and once a second while the terminal is shown.
    pub terminal_text: TerminalTextProvider,
    pub notable_branch: BranchProvider,
    /// Where the agent CLIs keep their transcripts and where `~` points.
    pub home: PathBuf,
}

impl DashboardHost {
    pub fn new() -> Self {
        Self {
            terminal_text: Rc::new(|_, _| None),
            notable_branch: Rc::new(|_, _| None),
            home: state::default_home(),
        }
    }

    pub fn terminal_text(
        mut self,
        provider: impl Fn(&TerminalTarget, &App) -> Option<String> + 'static,
    ) -> Self {
        self.terminal_text = Rc::new(provider);
        self
    }

    pub fn notable_branch(mut self, provider: impl Fn(&str, &App) -> Option<String> + 'static) -> Self {
        self.notable_branch = Rc::new(provider);
        self
    }

    pub fn home(mut self, home: impl Into<PathBuf>) -> Self {
        self.home = home.into();
        self
    }
}

impl Default for DashboardHost {
    fn default() -> Self {
        Self::new()
    }
}

/// The Agent Dashboard page. Create it with [`AgentDashboard::new`], render it over the
/// workspace, focus it ([`Focusable`]) when it opens and drop it when it closes (that stops
/// following transcripts).
pub struct AgentDashboard {
    workspace: Entity<Workspace>,
    host: DashboardHost,
    list: AgentList,
    window_count: usize,
    /// The list's keyboard focus (the dashboard root).
    focus: FocusHandle,
    /// The live terminal text, focused by a click into it.
    terminal_focus: FocusHandle,
    reply: Entity<InputState>,
    /// The last reply could not be delivered: the status and terminal availability it failed
    /// under; either changing clears it.
    reply_failed: Option<(Option<AgentStatus>, bool)>,
    /// The agent the detail shows; its draft is cleared when another is selected.
    detail_id: Option<String>,
    /// The selected agent's terminal text (`None`: unavailable).
    terminal: Option<String>,
    /// Set with T; applies to every agent until switched back.
    prefers_terminal: bool,
    transcripts: AgentTranscriptStore,
    sources: HashMap<String, AgentTranscriptSource>,
    timelines: HashMap<String, AgentTimeline>,
    transcript_source: Rc<TranscriptSource>,
    timeline: Entity<TimelineView>,
    list_scroll: ScrollHandle,
    terminal_scroll: ScrollHandle,
    /// Scroll the terminal to its end after the next layout (new text or a new agent).
    terminal_scroll_to_end: bool,
    now: SystemTime,
    _subscriptions: Vec<Subscription>,
    _tasks: Vec<Task<()>>,
}

impl EventEmitter<DashboardEvent> for AgentDashboard {}

impl Focusable for AgentDashboard {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl AgentDashboard {
    pub fn new(
        workspace: Entity<Workspace>,
        host: DashboardHost,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let reply = cx.new(|cx| InputState::new(window, cx));
        let transcript_source = TranscriptSource::new();
        let timeline = cx.new(|cx| {
            let source: Rc<dyn TimelineSource> = transcript_source.clone();
            let mut timeline = TimelineView::new(source, "", window, cx);
            timeline.set_bottom_inset(cx.soprano_theme().z(8.), cx);
            // The minimal work log until O.
            timeline.set_detailed(false, cx);
            timeline
        });
        let transcripts = AgentTranscriptStore::with_home(host.home.clone());
        let (changes, mut changed) = futures::channel::mpsc::unbounded::<String>();
        transcripts.set_on_change(move |id| {
            let _ = changes.unbounded_send(id.to_owned());
        });

        let entity = cx.entity().downgrade();
        let subscriptions = vec![
            cx.observe_in(&workspace, window, |this, _, window, cx| this.refresh(window, cx)),
            cx.subscribe_in(&reply, window, |this, _, event: &InputEvent, window, cx| match event {
                InputEvent::PressEnter { .. } => this.send_reply(window, cx),
                InputEvent::Change | InputEvent::Focus | InputEvent::Blur => cx.notify(),
            }),
            cx.intercept_keystrokes(move |event, window, cx| {
                let Some(this) = entity.upgrade() else { return };
                if this.update(cx, |this, cx| this.handle_keystroke(&event.keystroke, window, cx)) {
                    cx.stop_propagation();
                }
            }),
        ];
        let tasks = vec![
            cx.spawn_in(window, async move |this, cx| {
                while let Some(id) = changed.next().await {
                    if this
                        .update_in(cx, |this, window, cx| this.transcript_changed(&id, window, cx))
                        .is_err()
                    {
                        return;
                    }
                }
            }),
            cx.spawn_in(window, async move |this, cx| {
                loop {
                    cx.background_executor().timer(Duration::from_secs(1)).await;
                    if this.update(cx, |this, cx| this.tick(cx)).is_err() {
                        return;
                    }
                }
            }),
        ];

        let mut dashboard = Self {
            workspace,
            host,
            list: AgentList::default(),
            window_count: 0,
            focus: cx.focus_handle(),
            terminal_focus: cx.focus_handle(),
            reply,
            reply_failed: None,
            detail_id: None,
            terminal: None,
            prefers_terminal: false,
            transcripts,
            sources: HashMap::new(),
            timelines: HashMap::new(),
            transcript_source,
            timeline,
            list_scroll: ScrollHandle::new(),
            terminal_scroll: ScrollHandle::new(),
            terminal_scroll_to_end: true,
            now: SystemTime::now(),
            _subscriptions: subscriptions,
            _tasks: tasks,
        };
        dashboard.refresh(window, cx);
        dashboard
    }

    // MARK: - Model

    /// Brings the dashboard up to date with the workspace (every model notification).
    pub fn refresh(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let workspace = self.workspace.read(cx);
        let entries: Vec<DashboardEntry> = workspace
            .agent_dashboard_entries()
            .into_iter()
            .map(|mut entry| {
                let waiting_reason =
                    workspace.agent(&entry.pane_id, &entry.tab_id).and_then(|agent| agent.waiting_reason);
                entry.branch = entry
                    .cwd
                    .as_deref()
                    .filter(|_| entry.machine.is_none())
                    .and_then(|cwd| (self.host.notable_branch)(cwd, cx));
                DashboardEntry { entry, waiting_reason }
            })
            .collect();
        self.window_count = workspace.window_count();
        let selection_moved = self.list.update(entries);
        self.track_transcripts();
        self.sync_detail(window, cx);
        if selection_moved {
            self.scroll_selection_into_view();
        }
        cx.notify();
    }

    /// Follows the transcripts of the listed agents whose CLI writes one.
    fn track_transcripts(&mut self) {
        let sources: HashMap<String, AgentTranscriptSource> = self
            .list
            .entries()
            .filter_map(|entry| {
                AgentTranscriptSource::new(&entry.entry.profile_id, entry.entry.conversation.as_ref())
                    .map(|source| (entry.id(), source))
            })
            .collect();
        if sources == self.sources {
            return;
        }
        self.timelines
            .retain(|id, _| sources.get(id).is_some_and(|source| self.sources.get(id) == Some(source)));
        for id in sources.keys() {
            if !self.timelines.contains_key(id)
                && let Some(timeline) = self.transcripts.timeline(id)
            {
                self.timelines.insert(id.clone(), timeline);
            }
        }
        self.transcripts.track(sources.clone());
        self.sources = sources;
    }

    fn transcript_changed(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        match self.transcripts.timeline(id) {
            Some(timeline) => self.timelines.insert(id.to_owned(), timeline),
            None => self.timelines.remove(id),
        };
        if self.list.selected_id() == Some(id) {
            self.render_timeline(false, window, cx);
        }
        cx.notify();
    }

    /// Once a second: elapsed times, transcripts, and the shown terminal.
    fn tick(&mut self, cx: &mut Context<Self>) {
        self.now = SystemTime::now();
        self.transcripts.refresh();
        if !self.shows_timeline() {
            self.read_terminal(cx);
        }
        cx.notify();
    }

    fn selected(&self) -> Option<&DashboardEntry> {
        self.list.selected()
    }

    fn has_transcript(&self) -> bool {
        self.list.selected_id().is_some_and(|id| self.sources.contains_key(id))
    }

    fn selected_timeline(&self) -> Option<&AgentTimeline> {
        self.list.selected_id().and_then(|id| self.timelines.get(id))
    }

    fn shows_timeline(&self) -> bool {
        state::shows_timeline(self.selected(), self.has_transcript(), self.prefers_terminal)
    }

    fn controls(&self) -> Controls {
        Controls::new(self.selected(), self.has_transcript(), self.prefers_terminal, self.terminal.is_some())
    }

    /// Reads the selected agent's terminal; reading terminal text is not free, so only while
    /// it is shown or to decide whether a reply can go out.
    fn read_terminal(&mut self, cx: &mut Context<Self>) {
        let terminal = self.selected().and_then(|entry| (self.host.terminal_text)(&entry.target(), cx));
        if terminal != self.terminal {
            self.terminal = terminal;
            self.terminal_scroll_to_end = true;
        }
        // Like Swift's `updateControls`, a new status or terminal availability puts the
        // status hint back in place of "Could not send".
        if self.reply_failed.is_some_and(|state| state != self.reply_state()) {
            self.reply_failed = None;
        }
    }

    /// What the reply hint depends on: the selected agent's status and whether its terminal
    /// is available.
    fn reply_state(&self) -> (Option<AgentStatus>, bool) {
        (self.selected().map(DashboardEntry::status), self.terminal.is_some())
    }

    /// Follows the selection into the detail view.
    fn sync_detail(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let selected = self.list.selected_id().map(str::to_owned);
        let selection_changed = selected != self.detail_id;
        self.read_terminal(cx);
        if selection_changed {
            self.detail_id = selected;
            self.reply_failed = None;
            self.terminal_scroll_to_end = true;
            self.reply.update(cx, |reply, cx| reply.set_value("", window, cx));
        }
        let placeholder = self.selected().map(DashboardEntry::reply_placeholder).unwrap_or_default();
        let enabled = self.controls().reply;
        let agent_name = self.selected().map(|entry| entry.entry.profile_name.clone()).unwrap_or_default();
        self.reply.update(cx, |reply, cx| {
            reply.set_placeholder(placeholder, window, cx);
            reply.set_disabled(!enabled, cx);
        });
        self.timeline.update(cx, |timeline, cx| timeline.set_agent_name(agent_name, cx));
        self.render_timeline(selection_changed, window, cx);
    }

    /// Hands the transcript to the timeline as turns; the last one runs while the agent works.
    fn render_timeline(&mut self, scroll_to_end: bool, _: &mut Window, cx: &mut Context<Self>) {
        if !self.shows_timeline() {
            return;
        }
        let running = state::is_agent_working(self.selected().map(DashboardEntry::status));
        let thread = self
            .selected_timeline()
            .map(|timeline| ChatThread::from_transcript(timeline, running))
            .unwrap_or_default();
        self.transcript_source.set(thread, state::TIMELINE_EMPTY);
        self.timeline.update(cx, |timeline, cx| timeline.reload(scroll_to_end, cx));
    }

    // MARK: - Actions

    fn select(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        window.focus(&self.focus, cx);
        if self.list.select(id) {
            self.sync_detail(window, cx);
        }
        cx.notify();
    }

    fn move_selection(&mut self, delta: i32, window: &mut Window, cx: &mut Context<Self>) {
        // J/K drive the list even from the timeline or terminal; take the keyboard back so
        // the moved row shows the focused selection.
        window.focus(&self.focus, cx);
        if self.list.move_selection(delta) {
            self.sync_detail(window, cx);
            self.scroll_selection_into_view();
        }
        cx.notify();
    }

    /// The list's children are section headers and rows; scrolls to the selected row's child.
    fn scroll_selection_into_view(&self) {
        let Some(selected) = self.list.selected_index() else { return };
        let mut child = 0;
        let mut row = 0;
        for (_, entries) in self.list.sections() {
            child += 1;
            if selected < row + entries.len() {
                self.list_scroll.scroll_to_item(child + selected - row);
                return;
            }
            row += entries.len();
            child += entries.len();
        }
    }

    fn emit_for_selection(
        &self,
        event: impl FnOnce(TerminalTarget) -> DashboardEvent,
        cx: &mut Context<Self>,
    ) {
        if let Some(entry) = self.selected() {
            cx.emit(event(entry.target()));
        }
    }

    fn set_prefers_terminal(&mut self, prefers: bool, window: &mut Window, cx: &mut Context<Self>) {
        let is_chat = self.selected().is_some_and(|entry| entry.entry.is_chat);
        if !self.has_transcript() || is_chat || prefers == self.prefers_terminal {
            return;
        }
        self.prefers_terminal = prefers;
        if prefers {
            self.terminal_scroll_to_end = true;
            self.read_terminal(cx);
        } else {
            self.render_timeline(true, window, cx);
        }
        cx.notify();
    }

    fn toggle_details(&mut self, cx: &mut Context<Self>) {
        if !self.shows_timeline() {
            return;
        }
        self.timeline.update(cx, |timeline, cx| {
            let detailed = !timeline.is_detailed();
            timeline.set_detailed(detailed, cx);
        });
        cx.notify();
    }

    fn scroll_text(&mut self, amount: ScrollAmount, cx: &mut Context<Self>) {
        if self.shows_timeline() {
            self.timeline.update(cx, |timeline, cx| {
                let delta = match amount {
                    ScrollAmount::Lines(count) => px(count as f32 * LINE_SCROLL),
                    ScrollAmount::Pages(count) => timeline.page_height() * count as f32,
                };
                timeline.scroll_by(delta, cx);
            });
            return;
        }
        let viewport = self.terminal_scroll.bounds().size.height;
        let delta = match amount {
            ScrollAmount::Lines(count) => px(count as f32 * LINE_SCROLL),
            ScrollAmount::Pages(count) => (viewport - px(40.)).max(px(LINE_SCROLL)) * count as f32,
        };
        let maximum = self.terminal_scroll.max_offset().y;
        let current = -self.terminal_scroll.offset().y;
        let next = (current + delta).clamp(px(0.), maximum.max(px(0.)));
        self.terminal_scroll.set_offset(point(px(0.), -next));
        cx.notify();
    }

    fn follow_latest(&mut self, cx: &mut Context<Self>) {
        if self.shows_timeline() {
            self.timeline.update(cx, |timeline, cx| timeline.jump_to_latest(cx));
        } else {
            self.terminal_scroll.scroll_to_bottom();
            cx.notify();
        }
    }

    fn focus_reply(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.controls().reply {
            self.reply.update(cx, |reply, cx| reply.focus(window, cx));
            cx.notify();
        }
    }

    fn send_reply(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(target) = self.selected().map(DashboardEntry::target) else { return };
        if !self.controls().reply {
            return;
        }
        let Some(text) = state::reply_text(&self.reply.read(cx).value()) else { return };
        self.reply_failed = None;
        self.reply.update(cx, |reply, cx| reply.set_value("", window, cx));
        cx.emit(DashboardEvent::Reply { target, text });
        cx.notify();
    }

    /// The shell could not deliver a [`DashboardEvent::Reply`]: the draft comes back (unless
    /// something new was typed) and the hint says so in the error color.
    pub fn reply_failed(
        &mut self,
        target: &TerminalTarget,
        text: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.selected().map(DashboardEntry::target).as_ref() != Some(target) {
            return;
        }
        self.reply_failed = Some(self.reply_state());
        if self.reply.read(cx).value().is_empty() {
            self.reply.update(cx, |reply, cx| reply.set_value(text.to_owned(), window, cx));
        }
        cx.notify();
    }

    /// Runs the dashboard shortcut for `keystroke` while the keyboard is anywhere inside the
    /// dashboard (list, conversation, terminal text or reply field). Returns whether it was one.
    fn handle_keystroke(
        &mut self,
        keystroke: &Keystroke,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.focus.contains_focused(window, cx) {
            return false;
        }
        let reply_focused = self.reply.read(cx).focus_handle(cx).contains_focused(window, cx);
        let Some(action) = key_action(keystroke, reply_focused) else { return false };
        self.perform(action, window, cx);
        true
    }

    /// Runs one keyboard action.
    pub fn perform(&mut self, action: KeyAction, window: &mut Window, cx: &mut Context<Self>) {
        match action {
            KeyAction::Dismiss => cx.emit(DashboardEvent::Close),
            KeyAction::Move(delta) => self.move_selection(delta, window, cx),
            KeyAction::Activate => self.emit_for_selection(DashboardEvent::Open, cx),
            KeyAction::FocusReply => self.focus_reply(window, cx),
            KeyAction::LeaveReply => {
                window.focus(&self.focus, cx);
                cx.notify();
            }
            KeyAction::Scroll(amount) => self.scroll_text(amount, cx),
            KeyAction::JumpTurn(direction) => {
                if self.shows_timeline() {
                    self.timeline.update(cx, |timeline, cx| timeline.jump_to_message(direction, cx));
                }
            }
            KeyAction::ToggleDetails => self.toggle_details(cx),
            KeyAction::FollowLatest => self.follow_latest(cx),
            KeyAction::ToggleTerminal => self.set_prefers_terminal(!self.prefers_terminal, window, cx),
        }
    }

    // MARK: - Reading (for the shell and tests)

    /// The agents in list order.
    pub fn list(&self) -> &AgentList {
        &self.list
    }

    /// `Monitoring N agents across M windows`.
    pub fn subtitle(&self) -> String {
        monitoring_subtitle(self.list.len(), self.window_count)
    }

    pub fn is_showing_terminal(&self) -> bool {
        !self.shows_timeline()
    }

    pub fn timeline_view(&self) -> &Entity<TimelineView> {
        &self.timeline
    }

    /// What the selected agent's terminal shows.
    pub fn terminal_text(&self) -> TerminalText {
        TerminalText::new(self.terminal.as_deref())
    }

    /// The reply field's state (its draft).
    pub fn reply_input(&self) -> &Entity<InputState> {
        &self.reply
    }

    /// The line under the reply field.
    pub fn reply_hint(&self) -> &'static str {
        if self.reply_failed.is_some() {
            return state::SEND_FAILED;
        }
        state::reply_hint(self.selected(), self.terminal.is_some())
    }

    /// What the selected agent is doing, or its status in words.
    pub fn activity_text(&self) -> String {
        match self.current_activity(self.selected()) {
            Some(activity) => activity.text(),
            None => state::fallback_activity(self.selected().map(DashboardEntry::status)).to_owned(),
        }
    }

    fn current_activity(&self, entry: Option<&DashboardEntry>) -> Option<AgentTimelineActivity> {
        let entry = entry?;
        AgentTimelineActivity::current(self.timelines.get(&entry.id()), entry.status(), date(self.now))
    }
}

// MARK: - Rendering

impl Render for AgentDashboard {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if std::mem::take(&mut self.terminal_scroll_to_end) {
            self.terminal_scroll.scroll_to_bottom();
        }
        let theme = cx.soprano_theme().clone();
        // The selection falls to the first agent, so only an empty dashboard has none.
        let body = match self.selected() {
            Some(entry) => div()
                .flex()
                .flex_row()
                .flex_1()
                .min_h_0()
                .child(self.render_list(&theme, window, cx))
                .child(self.render_detail(entry, &theme, window, cx)),
            None => {
                div().flex().flex_col().flex_1().min_h_0().px(theme.z(CARD_GAP)).pb(theme.z(CARD_GAP)).child(
                    Card::new().flex_1().min_h_0().child(empty_state(
                        IconName::Bot,
                        "No agents to monitor",
                        Some("Launch an agent from the sidebar or command palette."),
                        &theme,
                    )),
                )
            }
        };
        div()
            .id("agent-dashboard")
            .key_context("AgentDashboard")
            .track_focus(&self.focus)
            .flex()
            .flex_col()
            .size_full()
            .bg(theme.canvas)
            .text_color(theme.foreground)
            .font_family(fonts::UI_FONT_FAMILY)
            .text_size(theme.z(size::UI))
            .child(self.render_header(&theme, cx))
            .child(body)
    }
}

impl AgentDashboard {
    /// The page's title and what it monitors, with Esc / close at the corner.
    fn render_header(&self, theme: &SopranoTheme, cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(theme.z(10.))
            .h(theme.z(HEADER_HEIGHT))
            .pl(theme.z(16.))
            .pr(theme.z(12.))
            .child(
                div()
                    .flex_none()
                    .text_size(theme.z(size::DIALOG_TITLE))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child("Agent Dashboard"),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(theme.z(size::ROW))
                    .text_color(theme.muted)
                    .child(self.subtitle()),
            )
            .child(Keycaps::new(["esc"]).small())
            .child(
                IconButton::new("agent-dashboard-done", IconName::X)
                    .tooltip("Return to the workspace (Esc)")
                    .on_click(cx.listener(|_, _, _, cx| cx.emit(DashboardEvent::Close))),
            )
    }

    fn render_list(
        &self,
        theme: &SopranoTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let list_focused = self.focus.is_focused(window);
        let mut children: Vec<AnyElement> = Vec::new();
        for (index, (section, entries)) in self.list.sections().iter().enumerate() {
            children.push(
                SectionHeader::new(("agent-dashboard-section", index), section.title())
                    .count(entries.len())
                    .medium()
                    .pl(theme.z(8.))
                    .into_any_element(),
            );
            for entry in entries {
                let selected = self.list.selected_id() == Some(entry.id().as_str());
                children.push(self.render_row(entry, selected, list_focused, theme, cx).into_any_element());
            }
        }
        let rows = ScrollList::new("agent-dashboard-list-rows", &self.list_scroll)
            .px(theme.z(8.))
            .pb(theme.z(8.))
            .gap(theme.z(2.))
            .children(children);
        div()
            .id("agent-dashboard-list")
            .debug_selector(|| "agent-dashboard-list".into())
            .flex()
            .flex_col()
            .flex_none()
            .h_full()
            .w(theme.z(LIST_WIDTH))
            .max_w(relative(LIST_MAXIMUM_FRACTION))
            .child(div().flex().flex_col().flex_1().min_h_0().child(rows))
            .child(self.render_key_hints(theme))
    }

    fn render_key_hints(&self, theme: &SopranoTheme) -> impl IntoElement {
        let hint = |caps: &[&'static str], label: &'static str| {
            div()
                .flex()
                .flex_row()
                .flex_none()
                .items_center()
                .gap(theme.z(5.))
                .child(Keycaps::new(caps.iter().copied()).small())
                .child(div().text_size(theme.z(size::SMALL)).text_color(theme.dim).child(label))
        };
        div()
            .id("agent-dashboard-key-hints")
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(theme.z(14.))
            .h(theme.z(FOOTER_HEIGHT))
            .px(theme.z(16.))
            .overflow_hidden()
            .child(hint(&["J", "K"], "Select"))
            .child(hint(&["↵"], "Open"))
            .child(hint(&["Tab"], "Reply"))
            .child(hint(&["T"], "Terminal"))
    }

    /// An agent on two lines: its program icon, what it works on and its status pill; under
    /// the title, who and where it is with what it does now, and how long it has run.
    fn render_row(
        &self,
        entry: &DashboardEntry,
        selected: bool,
        list_focused: bool,
        theme: &SopranoTheme,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let id = entry.id();
        let home = &self.host.home;
        // An agent with nothing going on steps back, as in the sidebar.
        let quiet = !selected && matches!(entry.status(), AgentStatus::Idle | AgentStatus::Stopped);
        let ink = if quiet { theme.muted } else { theme.foreground };

        let activity = self.current_activity(Some(entry)).map(|activity| {
            let color = if activity.tone == ActivityTone::Failed { theme.failed } else { theme.muted };
            ActivityLine::new(activity)
                .compact(true)
                .fonts(size::SMALL, FontWeight::NORMAL)
                .color(color)
                .into_any_element()
        });
        let context = context_element(
            ElementId::Name(format!("agent-dashboard-activity-{id}").into()),
            &entry.context(home),
            activity,
            size::SMALL,
            theme.muted,
            theme,
        );

        let row_id = id.clone();
        let selector = format!("agent-dashboard-row-{id}");
        let row = SidebarRow::new(ElementId::Name(format!("agent-dashboard-row-{id}").into()))
            .height(ROW_HEIGHT)
            .selected(selected && list_focused)
            .when(selected && !list_focused, |row| row.bg(theme.hover))
            .when(!selected && entry.entry.needs_attention, |row| row.bg(theme.attention_row_wash))
            .tooltip(entry.row_tooltip(home))
            .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
                if event.click_count() >= 2 {
                    if let Some(entry) = this.list.entry(&row_id) {
                        cx.emit(DashboardEvent::Open(entry.target()));
                    }
                } else {
                    this.select(&row_id, window, cx);
                }
            }))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_w_0()
                    .gap(theme.z(1.))
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(theme.z(ROW_ICON_GAP))
                            .min_w_0()
                            .child(agent_glyph(&entry.entry).size(ROW_ICON).color(ink))
                            .child(div().flex_1().min_w_0().truncate().text_color(ink).child(entry.title()))
                            .child(StatusPill::new(Some(entry.pill())).now(self.now)),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(theme.z(8.))
                            .min_w_0()
                            .pl(theme.z(ROW_ICON + ROW_ICON_GAP))
                            .child(div().flex_1().min_w_0().child(context))
                            .children(self.elapsed(entry).map(|elapsed| {
                                div()
                                    .flex_none()
                                    .text_size(theme.z(size::SMALL))
                                    .text_color(theme.dim)
                                    .child(elapsed)
                            })),
                    ),
            );
        div().debug_selector(move || selector).child(row)
    }

    /// How long the agent has run; a stopped agent's pill already says all there is.
    fn elapsed(&self, entry: &DashboardEntry) -> Option<String> {
        (entry.status() != AgentStatus::Stopped)
            .then(|| elapsed_text(entry.status(), entry.entry.started_at, self.now))
    }

    /// The selected agent as a card like its pane: who it is, the toolbar, what it wrote, and
    /// the reply field.
    fn render_detail(
        &self,
        entry: &DashboardEntry,
        theme: &SopranoTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let controls = self.controls();
        let shows_timeline = self.shows_timeline();
        let content = if shows_timeline {
            div().flex().flex_col().flex_1().min_h_0().child(self.timeline.clone()).into_any_element()
        } else {
            self.render_terminal(theme).into_any_element()
        };
        let card = Card::new()
            .flex_1()
            .min_h_0()
            .child(self.render_title(entry, theme))
            .child(self.render_location(entry, theme))
            .child(self.render_toolbar(controls, shows_timeline, theme, cx))
            .child(div().flex_none().mt(theme.z(12.)).h(px(1.)).bg(theme.border))
            .child(content)
            .child(self.render_composer(entry, controls, theme, window, cx));
        div()
            .id("agent-dashboard-detail")
            .debug_selector(|| "agent-dashboard-detail".into())
            .flex()
            .flex_col()
            .flex_1()
            .min_w_0()
            .h_full()
            .pr(theme.z(CARD_GAP))
            .pb(theme.z(CARD_GAP))
            .child(card)
    }

    fn render_title(&self, entry: &DashboardEntry, theme: &SopranoTheme) -> impl IntoElement {
        div()
            .id("agent-dashboard-detail-title")
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(theme.z(TITLE_ICON_GAP))
            .pt(theme.z(16.))
            .px(theme.z(GUTTER))
            .tooltip(tooltip(entry.title()))
            .child(agent_glyph(&entry.entry).size(TITLE_ICON).color(theme.foreground))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(theme.z(size::DIALOG_TITLE))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(entry.title()),
            )
    }

    /// Under the title: the status pill, how long the agent has run, and
    /// `window  /  omp · folder · ⎇ branch`.
    fn render_location(&self, entry: &DashboardEntry, theme: &SopranoTheme) -> impl IntoElement {
        let home = &self.host.home;
        let mut context = entry.context(home);
        context.context.insert(0, format!("{}{LOCATION_SEPARATOR}", entry.entry.window_title));
        let quiet = |text: SharedString| {
            div().flex_none().text_size(theme.z(size::META)).text_color(theme.dim).child(text)
        };
        div()
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(theme.z(8.))
            .mt(theme.z(2.))
            .pl(theme.z(GUTTER + TITLE_ICON + TITLE_ICON_GAP))
            .pr(theme.z(GUTTER))
            .min_w_0()
            .child(StatusPill::new(Some(entry.pill())).now(self.now))
            .children(self.elapsed(entry).map(|elapsed| quiet(elapsed.into())))
            .child(quiet("·".into()))
            .child(
                div()
                    .id("agent-dashboard-detail-location")
                    .flex_1()
                    .min_w_0()
                    .tooltip(tooltip(entry.location_tooltip(home)))
                    .child(context_element(
                        "agent-dashboard-detail-context",
                        &context,
                        None,
                        size::META,
                        theme.muted,
                        theme,
                    )),
            )
    }

    fn render_toolbar(
        &self,
        controls: Controls,
        shows_timeline: bool,
        theme: &SopranoTheme,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let detailed = self.timeline.read(cx).is_detailed();
        let disabled_segments: Vec<usize> =
            [(!controls.timeline_segment).then_some(0), (!controls.terminal_segment).then_some(1)]
                .into_iter()
                .flatten()
                .collect();
        // A card too narrow for both groups on one line gives each its own.
        div()
            .id("agent-dashboard-toolbar")
            .flex()
            .flex_row()
            .flex_wrap()
            .flex_none()
            .items_center()
            .gap(theme.z(8.))
            .mt(theme.z(14.))
            .px(theme.z(GUTTER))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .flex_none()
                    .items_center()
                    .gap(theme.z(6.))
                    .child(
                        div()
                            .id("agent-dashboard-mode")
                            .tooltip(tooltip("Show the conversation or the live terminal (T)"))
                            .child(
                                SegmentedControl::new(
                                    "agent-dashboard-mode-segments",
                                    ["Timeline", "Terminal"],
                                )
                                .selected(if shows_timeline { 0 } else { 1 })
                                .disabled_segments(disabled_segments)
                                .well()
                                .on_select({
                                    let this = cx.entity().downgrade();
                                    move |index, window, cx| {
                                        let _ = this.update(cx, |this, cx| {
                                            this.set_prefers_terminal(index == 1, window, cx)
                                        });
                                    }
                                }),
                            ),
                    )
                    .child(
                        Button::new(
                            "agent-dashboard-details",
                            if detailed { "Hide details" } else { "Show details" },
                        )
                        .ghost()
                        .size(ButtonSize::Sm)
                        .keycap("O")
                        .disabled(!controls.details)
                        .tooltip("Show thinking, full commands, and output (O)")
                        .on_click(cx.listener(|this, _, _, cx| this.toggle_details(cx))),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_row()
                    .flex_none()
                    .items_center()
                    .gap(theme.z(6.))
                    .ml_auto()
                    .child(
                        div().debug_selector(|| "agent-dashboard-open".into()).child(
                            Button::new("agent-dashboard-open", "Open")
                                .size(ButtonSize::Sm)
                                .keycap("↵")
                                .disabled(!controls.open)
                                .tooltip("Open the agent in its window (Return)")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.emit_for_selection(DashboardEvent::Open, cx)
                                })),
                        ),
                    )
                    .child(
                        div().debug_selector(|| "agent-dashboard-stop".into()).child(
                            Button::new("agent-dashboard-stop", "Stop")
                                .size(ButtonSize::Sm)
                                .disabled(!controls.stop)
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.emit_for_selection(DashboardEvent::Stop, cx)
                                })),
                        ),
                    )
                    .child(
                        div().debug_selector(|| "agent-dashboard-restart".into()).child(
                            Button::new("agent-dashboard-restart", "Restart")
                                .size(ButtonSize::Sm)
                                .disabled(!controls.restart)
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.emit_for_selection(DashboardEvent::Restart, cx)
                                })),
                        ),
                    ),
            )
    }

    /// The live terminal across the card (its lines are as wide as the agent's pane),
    /// highlighted in the theme's colors and selectable for copying; a note in its place while
    /// there is nothing to show.
    fn render_terminal(&self, theme: &SopranoTheme) -> impl IntoElement {
        let focus = self.terminal_focus.clone();
        let terminal = div()
            .id("agent-dashboard-terminal")
            .debug_selector(|| "agent-dashboard-terminal".into())
            .track_focus(&self.terminal_focus)
            .flex_1()
            .min_h_0()
            .on_mouse_down(MouseButton::Left, move |_, window, cx| window.focus(&focus, cx));
        match self.terminal_text() {
            TerminalText::Output(text) => {
                let highlights = output_highlights(&text, &OutputPalette::new(theme));
                terminal
                    .overflow_y_scroll()
                    .track_scroll(&self.terminal_scroll)
                    .px(theme.z(GUTTER))
                    .py(theme.z(14.))
                    .font_family(fonts::TERMINAL_FONT_FAMILY)
                    .font_weight(fonts::TERMINAL_WEIGHT)
                    .text_size(theme.z(size::META))
                    .text_color(theme.terminal_foreground)
                    .child(
                        RichText::new("agent-dashboard-terminal-text", text)
                            .highlights(highlights)
                            .selection_color(theme.selection),
                    )
            }
            TerminalText::Message(message) => {
                terminal.flex().flex_col().child(empty_state(IconName::SHELL, message, None, theme))
            }
        }
    }

    /// What the agent does over the reply field, kept to the chat lane.
    fn render_composer(
        &self,
        entry: &DashboardEntry,
        controls: Controls,
        theme: &SopranoTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let reply_focused = self.reply.read(cx).focus_handle(cx).contains_focused(window, cx);
        let can_send = controls.reply && state::reply_text(&self.reply.read(cx).value()).is_some();
        let hint_color = if self.reply_failed.is_some() { theme.failed } else { theme.dim };
        div().flex().flex_row().flex_none().justify_center().px(theme.z(GUTTER)).pt(theme.z(12.)).child(
            div()
                .flex()
                .flex_col()
                .w_full()
                .max_w(theme.z(READABLE_WIDTH))
                .child(self.render_activity(entry, theme))
                .child(
                    div()
                        .id("agent-dashboard-reply-card")
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(theme.z(10.))
                        .mt(theme.z(8.))
                        .h(theme.z(REPLY_FIELD_HEIGHT))
                        .pl(theme.z(6.))
                        .pr(theme.z(8.))
                        .rounded(theme.z(10.))
                        .border_1()
                        .border_color(if reply_focused { theme.accent } else { theme.input })
                        .bg(theme.raised)
                        .text_size(theme.z(size::UI))
                        // A field that cannot take a reply steps back; the hint says why.
                        .when(!controls.reply, |card| card.opacity(0.55))
                        .child(div().flex_1().min_w_0().child(Input::new(&self.reply).appearance(false)))
                        .child(send_button(can_send, theme, cx)),
                )
                .child(
                    div()
                        .id("agent-dashboard-reply-hint")
                        .mt(theme.z(6.))
                        .mb(theme.z(10.))
                        .pl(theme.z(2.))
                        .h(theme.z(15.))
                        .truncate()
                        .text_size(theme.z(size::SMALL))
                        .text_color(hint_color)
                        .child(self.reply_hint()),
                ),
        )
    }

    fn render_activity(&self, entry: &DashboardEntry, theme: &SopranoTheme) -> impl IntoElement {
        let pill = entry.pill();
        let text = match self.current_activity(Some(entry)) {
            Some(activity) => {
                let failed = activity.tone == ActivityTone::Failed;
                ActivityLine::new(activity)
                    .fonts(size::ROW, FontWeight::MEDIUM)
                    .color(if failed { theme.failed } else { theme.muted })
                    .code_color(if failed { theme.failed } else { theme.foreground })
                    .into_any_element()
            }
            None => div()
                .truncate()
                .text_size(theme.z(size::ROW))
                .text_color(theme.muted)
                .child(state::fallback_activity(Some(entry.status())))
                .into_any_element(),
        };
        div()
            .id("agent-dashboard-activity-line")
            .flex()
            .flex_row()
            .items_center()
            .gap(theme.z(8.))
            .pl(theme.z(2.))
            .h(theme.z(18.))
            .min_w_0()
            .child(div().flex_none().child(icon(pill.icon).size(12.).color(theme.tone(pill.tone))))
            .child(div().flex_1().min_w_0().child(text))
    }
}

/// The agent's program icon where one ships, else a chat or agent glyph.
fn agent_glyph(entry: &AgentDashboardEntry) -> Icon {
    match agent_icon_stem(&entry.profile_id) {
        Some(stem) => Icon::program(stem),
        None if entry.is_chat => Icon::new(IconName::MessageSquare),
        None => Icon::new(IconName::Bot),
    }
}

/// What a list or the card shows while it has nothing: a glyph over a line or two, centered.
fn empty_state(
    glyph: IconName,
    title: &'static str,
    hint: Option<&'static str>,
    theme: &SopranoTheme,
) -> gpui::Div {
    div()
        .flex()
        .flex_col()
        .flex_1()
        .min_h_0()
        .items_center()
        .justify_center()
        .gap(theme.z(6.))
        .px(theme.z(24.))
        .text_center()
        .child(div().pb(theme.z(4.)).child(icon(glyph).size(22.).color(theme.dim)))
        .child(div().text_size(theme.z(size::UI)).text_color(theme.muted).child(title))
        .children(hint.map(|hint| div().text_size(theme.z(size::META)).text_color(theme.dim).child(hint)))
}

/// A context line (`omp · folder · ⎇ branch`) at `text_size`, optionally followed by ` — ` and
/// an activity, on one line truncated at the tail. The branch is led by the branch glyph.
fn context_element(
    id: impl Into<ElementId>,
    context: &ContextLine,
    activity: Option<AnyElement>,
    text_size: f32,
    color: gpui::Hsla,
    theme: &SopranoTheme,
) -> AnyElement {
    let mut head = String::new();
    let mut branch: Option<String> = None;
    let mut tail = String::new();
    for part in context.parts() {
        let target = if branch.is_some() { &mut tail } else { &mut head };
        match part {
            ContextPart::Text(text) => {
                if !target.is_empty() && !target.ends_with(LOCATION_SEPARATOR) {
                    target.push_str(ContextLine::SEPARATOR);
                }
                target.push_str(&text);
            }
            ContextPart::Branch(name) => {
                if !head.is_empty() && !head.ends_with(LOCATION_SEPARATOR) {
                    head.push_str(ContextLine::SEPARATOR);
                }
                branch = Some(name);
            }
        }
    }
    if branch.is_none() {
        // Without a glyph the whole line is one text.
        tail = std::mem::take(&mut head);
    }
    let has_context = !tail.is_empty() || branch.is_some() || !head.is_empty();
    if activity.is_some() && has_context {
        tail.push_str(" — ");
    }
    let head_text = (!head.is_empty()).then(|| div().flex_none().child(SharedString::from(head)));
    let glyph = branch.map(|name| {
        div()
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(theme.z(3.))
            .child(icon(IconName::GitBranch).size(text_size).color(color))
            .child(SharedString::from(name))
    });
    let tail_text = (!tail.is_empty()).then(|| div().min_w_0().truncate().child(SharedString::from(tail)));
    div()
        .id(id)
        .flex()
        .flex_row()
        .items_center()
        .min_w_0()
        .overflow_hidden()
        .whitespace_nowrap()
        .text_size(theme.z(text_size))
        .text_color(color)
        .children(head_text)
        .children(glyph)
        .children(tail_text)
        .children(activity.map(|activity| div().flex_1().min_w_0().child(activity)))
        .into_any_element()
}

/// The composer's round send button: the ink disc while there is something to send, faint
/// otherwise.
fn send_button(can_send: bool, theme: &SopranoTheme, cx: &mut Context<AgentDashboard>) -> impl IntoElement {
    div()
        .id("agent-dashboard-send")
        .flex()
        .flex_none()
        .items_center()
        .justify_center()
        .size(theme.z(28.))
        .rounded_full()
        .bg(if can_send { theme.solid } else { theme.solid.opacity(0.25) })
        .tooltip(tooltip("Send"))
        .when(can_send, |button| {
            button.cursor_pointer().on_click(cx.listener(|this, _, window, cx| this.send_reply(window, cx)))
        })
        .child(icon(IconName::ArrowUp).size(14.).color(theme.solid_foreground))
}

#[cfg(test)]
#[path = "view_tests.rs"]
mod tests;
