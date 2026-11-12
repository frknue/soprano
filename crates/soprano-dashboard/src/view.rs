//! The Agent Dashboard view, in Soprano Agents' layout: the thread inbox on the left (search,
//! New Thread, cards under Needs you / Working / Ready / Stopped), and beside it the open
//! thread as a chat — a 52 px header naming project and thread, the conversation in the
//! centered lane, and the floating composer. A new thread is drafted in the same column.

mod chat;
mod sidebar;

use std::cell::Cell;
use std::collections::HashMap;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::{Duration, SystemTime};

use futures::StreamExt as _;
use gpui::{
    App, AppContext as _, Bounds, Context, DismissEvent, Entity, EventEmitter, FocusHandle, Focusable,
    InteractiveElement, IntoElement, Keystroke, MouseButton, ParentElement, Pixels, Render, ScrollHandle,
    Styled, Subscription, Task, Window, canvas, div, point, px,
};
use gpui_component::input::{Enter, InputEvent, InputState, TextareaState};
use soprano_agents::{
    AgentTimeline, AgentTimelineActivity, AgentTranscriptSource, AgentTranscriptStore, ChatThread,
};
use soprano_chat::AgentChatConfigOption;
use soprano_chat_ui::composer_logic::option_title;
use soprano_chat_ui::timeline_view::{gutter, lane_width};
use soprano_chat_ui::{TimelineSource, TimelineView, TranscriptSource};
use soprano_model::Workspace;
use soprano_platform::StateStore;
use soprano_types::{AgentStatus, TerminalTarget};
use soprano_ui::fonts;
use soprano_ui::status::StatusClock;
use soprano_ui::theme::ActiveSopranoTheme;
use soprano_ui::{ContextMenu, IconName, MenuItem, Picker, PickerEvent, PickerItem, SopranoTheme};

use crate::keys::{KeyAction, KeyFocus, ScrollAmount, key_action};
use crate::state::{self, AgentChoice, AgentList, Controls, DashboardEntry, ProjectChoice, ThreadOption};

/// The inbox's width (Soprano Agents' sidebar); a narrow window takes it down to 40 %.
const SIDEBAR_WIDTH: f32 = 256.0;
const SIDEBAR_MAXIMUM_FRACTION: f32 = 0.4;
/// The band over the inbox and the chat: brand and header, and what the window is moved by.
const TOPBAR_HEIGHT: f32 = 52.0;
/// One J/K line of scrolling.
const LINE_SCROLL: f32 = 48.0;
/// What the composer covers before it has been measured.
const COMPOSER_HEIGHT: f32 = 118.0;
/// The picker row that asks for any folder.
const CHOOSE_FOLDER_ID: &str = "choose-folder";
/// What a model's picker row id starts with, before its value.
const MODEL_ID_PREFIX: &str = "model:";
/// How long the agent gets to answer a changed setting before it is read back.
const OPTION_READ_DELAY: Duration = Duration::from_millis(200);

/// What the dashboard asks the app shell to do. The dashboard never mutates the workspace.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DashboardEvent {
    /// Return, a double-click or Open: show that exact pane tab in its window.
    Open(TerminalTarget),
    /// `Workspace::stop_agent`.
    Stop(TerminalTarget),
    /// `Workspace::restart_agent`.
    Restart(TerminalTarget),
    /// Send `text` to that pane tab's agent: typed into its terminal (line breaks become
    /// spaces there), or to the chat session of a chat tab. When it cannot be delivered, call
    /// [`AgentDashboard::reply_failed`].
    Reply { target: TerminalTarget, text: String },
    /// Start an agent in `cwd` with `prompt` as its first message, as a tab of the window
    /// that works on that project (`Workspace::open_thread`); an agent that runs as a chat
    /// starts with `options` (option id, value) set. Answer with
    /// [`AgentDashboard::thread_opened`] or [`AgentDashboard::thread_failed`].
    NewThread { profile_id: String, cwd: String, prompt: String, options: Vec<(String, String)> },
    /// Set the option `id` of that pane tab's chat session to `value` (its model, its
    /// thinking level).
    SetOption { target: TerminalTarget, id: String, value: String },
    /// Ask for any folder for the thread being drafted; answer with
    /// [`AgentDashboard::set_draft_project`].
    ChooseProject,
    /// Esc on the list or ⌘W: close the dashboard.
    Close,
}

/// Whether the exact pane tab's agent can take a message right now.
pub type RepliesProvider = Rc<dyn Fn(&TerminalTarget, &App) -> bool>;
/// A folder's branch when it is not its repository's default (the branch monitor).
pub type BranchProvider = Rc<dyn Fn(&str, &App) -> Option<String>>;
/// The folders a new thread is offered, in the order to list them.
pub type ProjectsProvider = Rc<dyn Fn(&App) -> Vec<ProjectChoice>>;
/// The settings the exact pane tab's chat session offers right now (model, thinking level);
/// none for an agent in its terminal.
pub type ThreadOptionsProvider = Rc<dyn Fn(&TerminalTarget, &App) -> Vec<AgentChatConfigOption>>;
/// The settings a new thread of that agent would offer once the (option id, value) pairs are
/// applied in order, read from a throwaway conversation; none for an agent in its terminal.
pub type DraftOptionsProvider =
    Rc<dyn Fn(&str, Vec<(String, String)>, &mut App) -> Task<Vec<AgentChatConfigOption>>>;

/// What the shell answers that the workspace model does not know.
#[derive(Clone)]
pub struct DashboardHost {
    /// Read for the selected thread when it changes, the workspace notifies, and once a second.
    pub accepts_replies: RepliesProvider,
    pub notable_branch: BranchProvider,
    pub projects: ProjectsProvider,
    /// Read for the selected thread like `accepts_replies`.
    pub thread_options: ThreadOptionsProvider,
    /// Asked when a draft opens, changes its agent, or changes its model.
    pub draft_options: DraftOptionsProvider,
    /// Where the agent CLIs keep their transcripts and where `~` points.
    pub home: PathBuf,
    /// App state: the agent the last thread was started with.
    pub state: StateStore,
    /// What the window's own controls take at the inbox's top-left (the macOS traffic
    /// lights); the brand starts after it.
    pub leading_inset: f32,
}

impl DashboardHost {
    pub fn new() -> Self {
        Self {
            accepts_replies: Rc::new(|_, _| false),
            notable_branch: Rc::new(|_, _| None),
            projects: Rc::new(|_| Vec::new()),
            thread_options: Rc::new(|_, _| Vec::new()),
            draft_options: Rc::new(|_, _, _| Task::ready(Vec::new())),
            home: state::default_home(),
            state: StateStore::in_memory(),
            leading_inset: 0.0,
        }
    }

    pub fn accepts_replies(mut self, provider: impl Fn(&TerminalTarget, &App) -> bool + 'static) -> Self {
        self.accepts_replies = Rc::new(provider);
        self
    }

    pub fn notable_branch(mut self, provider: impl Fn(&str, &App) -> Option<String> + 'static) -> Self {
        self.notable_branch = Rc::new(provider);
        self
    }

    pub fn projects(mut self, provider: impl Fn(&App) -> Vec<ProjectChoice> + 'static) -> Self {
        self.projects = Rc::new(provider);
        self
    }

    pub fn thread_options(
        mut self,
        provider: impl Fn(&TerminalTarget, &App) -> Vec<AgentChatConfigOption> + 'static,
    ) -> Self {
        self.thread_options = Rc::new(provider);
        self
    }

    pub fn draft_options(
        mut self,
        provider: impl Fn(&str, Vec<(String, String)>, &mut App) -> Task<Vec<AgentChatConfigOption>> + 'static,
    ) -> Self {
        self.draft_options = Rc::new(provider);
        self
    }

    pub fn home(mut self, home: impl Into<PathBuf>) -> Self {
        self.home = home.into();
        self
    }

    pub fn state(mut self, state: StateStore) -> Self {
        self.state = state;
        self
    }

    pub fn leading_inset(mut self, inset: f32) -> Self {
        self.leading_inset = inset;
        self
    }
}

impl Default for DashboardHost {
    fn default() -> Self {
        Self::new()
    }
}

/// The thread being drafted.
struct Draft {
    project: ProjectChoice,
    agent: AgentChoice,
    /// The window its tab joins; `None`: it opens a window of its own.
    window_title: Option<String>,
    /// The workspace layout `window_title` was read from.
    layout_generation: u64,
    /// Sent to the shell, which has not answered yet.
    launching: bool,
    /// Why the last launch did not happen.
    error: Option<String>,
    /// What the agent offers a new conversation (its model, its thinking level), with what
    /// the thread will start with as the current values; empty until the host answered, and
    /// for an agent in its terminal.
    options: Vec<AgentChatConfigOption>,
    /// The host reading `options`.
    _probe: Option<Task<()>>,
}

/// The Agent Dashboard. Create it with [`AgentDashboard::new`], render it as a window's
/// content, focus it ([`Focusable`]) when it opens and drop it when it closes (that stops
/// following transcripts).
pub struct AgentDashboard {
    workspace: Entity<Workspace>,
    host: DashboardHost,
    list: AgentList,
    /// The inbox's keyboard focus (the dashboard root).
    focus: FocusHandle,
    search: Entity<InputState>,
    editor: Entity<TextareaState>,
    draft: Option<Draft>,
    /// The last message could not be delivered: the status and availability it failed under;
    /// either changing clears it.
    send_failed: Option<(Option<AgentStatus>, bool)>,
    /// The thread the chat shows; its unsent text is cleared when another is selected.
    detail_id: Option<String>,
    /// Whether the selected thread's agent takes a message.
    accepts_replies: bool,
    /// The settings the selected thread's chat session offers.
    options: Vec<AgentChatConfigOption>,
    /// Reads `options` back once the agent answered a change.
    _option_read: Option<Task<()>>,
    transcripts: AgentTranscriptStore,
    sources: HashMap<String, AgentTranscriptSource>,
    timelines: HashMap<String, AgentTimeline>,
    transcript_source: Rc<TranscriptSource>,
    timeline: Entity<TimelineView>,
    /// Project folder names by working directory: finding a project walks the disk.
    project_names: HashMap<String, String>,
    list_scroll: ScrollHandle,
    picker: Option<Entity<Picker>>,
    menu: Option<Entity<ContextMenu>>,
    /// The chat column, the composer card, the draft's agent chip and the option chips (in
    /// [`ThreadOption::ALL`]'s order) as last drawn.
    column_bounds: Rc<Cell<Bounds<Pixels>>>,
    composer_bounds: Rc<Cell<Bounds<Pixels>>>,
    agent_chip_bounds: Rc<Cell<Bounds<Pixels>>>,
    option_chip_bounds: [Rc<Cell<Bounds<Pixels>>>; 2],
    now: SystemTime,
    _overlay: Option<Subscription>,
    _subscriptions: Vec<Subscription>,
    _tasks: Vec<Task<()>>,
}

impl EventEmitter<DashboardEvent> for AgentDashboard {}

impl Focusable for AgentDashboard {
    /// What takes the keyboard when the dashboard opens: the inbox, or the composer when it
    /// opens on a new thread, so the first key typed is the message's first letter.
    fn focus_handle(&self, cx: &App) -> FocusHandle {
        if self.draft.is_some() { self.editor.focus_handle(cx) } else { self.focus.clone() }
    }
}

impl AgentDashboard {
    pub fn new(
        workspace: Entity<Workspace>,
        host: DashboardHost,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search"));
        let editor = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(2, soprano_chat_ui::composer::EDITOR_MAX_LINES)
                .placeholder(state::PLACEHOLDER)
        });
        let transcript_source = TranscriptSource::new();
        let timeline = cx.new(|cx| {
            let source: Rc<dyn TimelineSource> = transcript_source.clone();
            let mut timeline = TimelineView::new(source, "", window, cx);
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
            cx.subscribe_in(&search, window, |this, search, event: &InputEvent, _, cx| {
                if matches!(event, InputEvent::Change) {
                    let query = search.read(cx).value().to_string();
                    this.list.set_query(&query);
                    this.list_scroll.scroll_to_item(0);
                }
                cx.notify();
            }),
            cx.subscribe_in(&editor, window, |this, _, event: &InputEvent, _, cx| {
                // Typing again puts the status hint back in place of "Could not send".
                if matches!(event, InputEvent::Change) {
                    this.send_failed = None;
                    if let Some(draft) = &mut this.draft {
                        draft.error = None;
                    }
                }
                cx.notify();
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
                    if this.update_in(cx, |this, window, cx| this.tick(window, cx)).is_err() {
                        return;
                    }
                }
            }),
        ];

        let mut dashboard = Self {
            workspace,
            host,
            list: AgentList::default(),
            focus: cx.focus_handle(),
            search,
            editor,
            draft: None,
            send_failed: None,
            detail_id: None,
            accepts_replies: false,
            options: Vec::new(),
            _option_read: None,
            transcripts,
            sources: HashMap::new(),
            timelines: HashMap::new(),
            transcript_source,
            timeline,
            project_names: HashMap::new(),
            list_scroll: ScrollHandle::new(),
            picker: None,
            menu: None,
            column_bounds: Rc::new(Cell::new(Bounds::default())),
            composer_bounds: Rc::new(Cell::new(Bounds::default())),
            agent_chip_bounds: Rc::new(Cell::new(Bounds::default())),
            option_chip_bounds: Default::default(),
            now: SystemTime::now(),
            _overlay: None,
            _subscriptions: subscriptions,
            _tasks: tasks,
        };
        dashboard.refresh(window, cx);
        // With no thread to show, the dashboard opens on a new one.
        dashboard.draft_when_empty(window, cx);
        dashboard.sync_composer(window, cx);
        dashboard
    }

    // MARK: - Model

    /// Brings the dashboard up to date with the workspace (every model notification).
    pub fn refresh(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let now = SystemTime::now();
        // `StatusClock` is a global; take it out so the entries can read the workspace alongside.
        let mut clock = std::mem::take(cx.default_global::<StatusClock>());
        let workspace = self.workspace.read(cx);
        let layout_generation = workspace.layout_generation();
        let entries: Vec<DashboardEntry> = workspace
            .agent_dashboard_entries()
            .into_iter()
            .map(|mut entry| {
                let agent = workspace.agent(&entry.pane_id, &entry.tab_id);
                let waiting_reason = agent.and_then(|agent| agent.waiting_reason);
                let since =
                    agent.map_or(now, |agent| clock.since(&agent.id, agent.status, agent.started_at, now));
                entry.branch = entry
                    .cwd
                    .as_deref()
                    .filter(|_| entry.machine.is_none())
                    .and_then(|cwd| (self.host.notable_branch)(cwd, cx));
                let project = project_name(&mut self.project_names, &entry);
                DashboardEntry { entry, waiting_reason, project, since }
            })
            .collect();
        let draft_window =
            self.draft.as_ref().filter(|draft| draft.layout_generation != layout_generation).map(|draft| {
                workspace.window_for_thread(&draft.project.path).map(|window| window.title.clone())
            });
        *cx.default_global::<StatusClock>() = clock;
        // A working agent retitles its tab several times a second (its spinner): most
        // notifications change nothing the dashboard shows.
        if draft_window.is_none() && self.list.holds(&entries) {
            let accepted = self.accepts_replies;
            self.read_availability(cx);
            if accepted != self.accepts_replies {
                self.sync_composer(window, cx);
                cx.notify();
            }
            return;
        }
        if let (Some(draft), Some(window_title)) = (&mut self.draft, draft_window) {
            draft.window_title = window_title;
            draft.layout_generation = layout_generation;
        }
        self.now = now;
        let selection_moved = self.list.update(entries);
        self.track_transcripts();
        self.draft_when_empty(window, cx);
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

    /// Once a second: live durations, transcripts, and whether the thread takes a message.
    fn tick(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.now = SystemTime::now();
        self.transcripts.refresh();
        let accepted = self.accepts_replies;
        self.read_availability(cx);
        if accepted != self.accepts_replies {
            self.sync_composer(window, cx);
        }
        cx.notify();
    }

    fn selected(&self) -> Option<&DashboardEntry> {
        self.list.selected()
    }

    /// Whether the selected thread's conversation can be read: its CLI writes a transcript the
    /// dashboard follows.
    fn has_conversation(&self) -> bool {
        self.list.selected_id().is_some_and(|id| self.sources.contains_key(id))
    }

    fn selected_timeline(&self) -> Option<&AgentTimeline> {
        self.list.selected_id().and_then(|id| self.timelines.get(id))
    }

    /// What a thread's agent does right now, or last said: the line under its title.
    fn current_activity(&self, entry: &DashboardEntry) -> Option<AgentTimelineActivity> {
        let now = soprano_agents::Date::from(self.now);
        AgentTimelineActivity::current(self.timelines.get(&entry.id()), entry.status(), now)
    }

    fn controls(&self) -> Controls {
        Controls::new(self.selected(), self.has_conversation(), self.accepts_replies)
    }

    fn read_availability(&mut self, cx: &mut Context<Self>) {
        let target = self.selected().map(DashboardEntry::target);
        self.accepts_replies = target.as_ref().is_some_and(|target| (self.host.accepts_replies)(target, cx));
        self.options =
            target.as_ref().map(|target| (self.host.thread_options)(target, cx)).unwrap_or_default();
        // A new status or availability puts the status hint back in place of "Could not send".
        if self.send_failed.is_some_and(|state| state != self.reply_state()) {
            self.send_failed = None;
        }
    }

    /// What the composer hint depends on: the selected thread's status and whether its agent
    /// takes a message.
    fn reply_state(&self) -> (Option<AgentStatus>, bool) {
        (self.selected().map(DashboardEntry::status), self.accepts_replies)
    }

    /// Follows the selection into the chat column.
    fn sync_detail(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let selected = self.list.selected_id().map(str::to_owned);
        let selection_changed = selected != self.detail_id;
        self.read_availability(cx);
        if selection_changed {
            self.detail_id = selected;
            self.send_failed = None;
            if self.draft.is_none() {
                self.editor.update(cx, |editor, cx| editor.set_value("", window, cx));
            }
        }
        let agent_name = self.selected().map(|entry| entry.entry.profile_name.clone()).unwrap_or_default();
        if self.timeline.read(cx).agent_name() != agent_name {
            self.timeline.update(cx, |timeline, cx| timeline.set_agent_name(agent_name, cx));
        }
        self.sync_composer(window, cx);
        self.render_timeline(selection_changed, window, cx);
    }

    /// The editor takes text while a draft is being written or the thread takes a message.
    fn sync_composer(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let enabled = match &self.draft {
            Some(draft) => !draft.launching,
            None => self.controls().reply,
        };
        let _ = window;
        self.editor.update(cx, |editor, cx| editor.set_disabled(!enabled, cx));
    }

    /// Hands the transcript to the timeline as turns; the last one runs while the agent works.
    fn render_timeline(&mut self, scroll_to_end: bool, _: &mut Window, cx: &mut Context<Self>) {
        let Some(entry) = self.selected() else { return };
        let running = state::is_agent_working(Some(entry.status()));
        let empty = state::timeline_empty_text(entry, self.has_conversation());
        let thread = self
            .selected_timeline()
            .map(|timeline| ChatThread::from_transcript(timeline, running))
            .unwrap_or_default();
        self.transcript_source.set(thread, empty);
        self.timeline.update(cx, |timeline, cx| timeline.reload(scroll_to_end, cx));
    }

    // MARK: - Threads

    fn select(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        window.focus(&self.focus, cx);
        self.leave_draft(window, cx);
        if self.list.select(id) {
            self.sync_detail(window, cx);
        }
        cx.notify();
    }

    fn move_selection(&mut self, delta: i32, window: &mut Window, cx: &mut Context<Self>) {
        // J/K drive the list even from the conversation; the search field keeps the keyboard
        // while it is typed in.
        if !self.search.focus_handle(cx).contains_focused(window, cx) {
            window.focus(&self.focus, cx);
        }
        // Out of a draft, the first key shows the thread that was open.
        let was_drafting = self.draft.is_some();
        self.leave_draft(window, cx);
        if !was_drafting && self.list.move_selection(delta) {
            self.sync_detail(window, cx);
        }
        self.scroll_selection_into_view();
        cx.notify();
    }

    fn scroll_selection_into_view(&self) {
        if let Some(row) = self.list.selected_row() {
            self.list_scroll.scroll_to_item(row);
        }
    }

    fn emit_for_selection(
        &self,
        event: impl FnOnce(TerminalTarget) -> DashboardEvent,
        cx: &mut Context<Self>,
    ) {
        if self.draft.is_none()
            && let Some(entry) = self.selected()
        {
            cx.emit(event(entry.target()));
        }
    }

    /// Folds a section's threads away, or shows them again.
    pub fn toggle_fold(&mut self, section: soprano_agents::AgentDashboardSection, cx: &mut Context<Self>) {
        self.list.toggle_fold(section);
        cx.notify();
    }

    /// Narrows the inbox to the threads matching `query`, as typing in the search field does.
    pub fn set_search(&mut self, query: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.search.update(cx, |search, cx| search.set_value(query.to_owned(), window, cx));
        self.list.set_query(query);
        self.list_scroll.scroll_to_item(0);
        cx.notify();
    }

    /// Replaces what the composer holds.
    pub fn set_composer_text(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.editor.update(cx, |editor, cx| editor.set_value(text.to_owned(), window, cx));
        cx.notify();
    }

    fn toggle_details(&mut self, cx: &mut Context<Self>) {
        if !self.controls().details || self.draft.is_some() {
            return;
        }
        self.timeline.update(cx, |timeline, cx| {
            let detailed = !timeline.is_detailed();
            timeline.set_detailed(detailed, cx);
        });
        cx.notify();
    }

    fn scroll_text(&mut self, amount: ScrollAmount, cx: &mut Context<Self>) {
        self.timeline.update(cx, |timeline, cx| {
            let delta = match amount {
                ScrollAmount::Lines(count) => px(count as f32 * LINE_SCROLL),
                ScrollAmount::Pages(count) => timeline.page_height() * count as f32,
            };
            timeline.scroll_by(delta, cx);
        });
    }

    fn focus_composer(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let enabled = match &self.draft {
            Some(draft) => !draft.launching,
            None => self.controls().reply,
        };
        if enabled {
            self.editor.update(cx, |editor, cx| editor.focus(window, cx));
            cx.notify();
        }
    }

    fn focus_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.search.update(cx, |search, cx| search.focus(window, cx));
        cx.notify();
    }

    fn clear_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.search.update(cx, |search, cx| search.set_value("", window, cx));
        self.list.set_query("");
        window.focus(&self.focus, cx);
        self.scroll_selection_into_view();
        cx.notify();
    }

    // MARK: - Composer

    /// Return in the composer: ⇧Return adds a line, Return sends.
    fn on_enter(&mut self, action: &Enter, window: &mut Window, cx: &mut Context<Self>) {
        if action.shift {
            return;
        }
        cx.stop_propagation();
        self.send(window, cx);
    }

    /// Sends what the composer holds: the first message of the drafted thread, or a message to
    /// the open one.
    fn send(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(text) = state::reply_text(&self.editor.read(cx).value()) else { return };
        if let Some(draft) = &mut self.draft {
            if draft.launching {
                return;
            }
            draft.launching = true;
            draft.error = None;
            draft.agent.remember(&self.host.state);
            let options = ThreadOption::opening(&draft.options);
            ThreadOption::remember(&self.host.state, &draft.agent.profile_id, &options);
            let event = DashboardEvent::NewThread {
                profile_id: draft.agent.profile_id.clone(),
                cwd: draft.project.path.clone(),
                prompt: text,
                options,
            };
            self.sync_composer(window, cx);
            cx.emit(event);
            cx.notify();
            return;
        }
        let Some(target) = self.selected().map(DashboardEntry::target) else { return };
        if !self.controls().reply {
            return;
        }
        self.send_failed = None;
        self.editor.update(cx, |editor, cx| editor.set_value("", window, cx));
        self.timeline.update(cx, |timeline, cx| timeline.jump_to_latest(cx));
        cx.emit(DashboardEvent::Reply { target, text });
        cx.notify();
    }

    /// The shell could not deliver a [`DashboardEvent::Reply`]: the text comes back (unless
    /// something new was typed) and the hint says so in the error color.
    pub fn reply_failed(
        &mut self,
        target: &TerminalTarget,
        text: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.draft.is_some() || self.selected().map(DashboardEntry::target).as_ref() != Some(target) {
            return;
        }
        if self.editor.read(cx).value().is_empty() {
            self.editor.update(cx, |editor, cx| editor.set_value(text.to_owned(), window, cx));
        }
        // After the text: putting it back counts as typing, which clears the hint.
        self.send_failed = Some(self.reply_state());
        cx.notify();
    }

    // MARK: - New thread

    /// Opens the draft of a new thread (N, ⌘N, the pencil button) and gives its composer the
    /// keyboard.
    pub fn new_thread(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.draft.is_none() {
            self.start_draft(cx);
            self.editor.update(cx, |editor, cx| editor.set_value("", window, cx));
        }
        self.sync_composer(window, cx);
        self.focus_composer(window, cx);
        cx.notify();
    }

    /// A draft in the open thread's project, else where the workspace's active tab works,
    /// else the home folder; with the agent the last thread started with.
    fn start_draft(&mut self, cx: &mut Context<Self>) {
        let Some(agent) = AgentChoice::initial(&self.host.state) else { return };
        let workspace = self.workspace.read(cx);
        let folder = self
            .selected()
            .filter(|entry| entry.entry.machine.is_none())
            .and_then(|entry| entry.entry.cwd.clone())
            .or_else(|| {
                workspace
                    .active_working_directory()
                    .filter(|_| workspace.machine_of_pane(workspace.active_pane_id()).is_none())
            });
        let path = match folder {
            Some(folder) => Workspace::project_root(&folder),
            None => self.host.home.clone(),
        };
        self.draft = Some(Draft {
            project: ProjectChoice::at(path.to_string_lossy().into_owned()),
            agent,
            window_title: None,
            layout_generation: 0,
            launching: false,
            error: None,
            options: Vec::new(),
            _probe: None,
        });
        self.read_draft_window(cx);
        self.read_draft_options(None, cx);
    }

    /// Which window the drafted thread's tab would join.
    fn read_draft_window(&mut self, cx: &mut Context<Self>) {
        let Some(draft) = &mut self.draft else { return };
        let workspace = self.workspace.read(cx);
        draft.window_title =
            workspace.window_for_thread(&draft.project.path).map(|window| window.title.clone());
        draft.layout_generation = workspace.layout_generation();
    }

    /// Gives a draft up for the open thread; a draft the shell is starting stays, and so does
    /// the only thing there is to show.
    fn leave_draft(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.list.is_empty() || self.draft.as_ref().is_none_or(|draft| draft.launching) {
            return;
        }
        self.draft = None;
        self.editor.update(cx, |editor, cx| editor.set_value("", window, cx));
        self.sync_composer(window, cx);
        self.render_timeline(true, window, cx);
        cx.notify();
    }

    /// The folder the drafted thread works in (the project picker, or the shell's answer to
    /// [`DashboardEvent::ChooseProject`]).
    pub fn set_draft_project(&mut self, path: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(draft) = &mut self.draft else { return };
        if draft.launching {
            return;
        }
        draft.project = ProjectChoice::at(path);
        draft.error = None;
        self.read_draft_window(cx);
        self.focus_composer(window, cx);
        cx.notify();
    }

    fn set_draft_agent(&mut self, agent: AgentChoice, cx: &mut Context<Self>) {
        if let Some(draft) = &mut self.draft
            && !draft.launching
            && draft.agent != agent
        {
            draft.agent = agent;
            draft.options.clear();
            self.read_draft_options(None, cx);
            cx.notify();
        }
    }

    /// Asks the host what the draft's agent offers a new conversation that starts with
    /// `opening`, else with what the agent's last thread started with.
    fn read_draft_options(&mut self, opening: Option<Vec<(String, String)>>, cx: &mut Context<Self>) {
        let Some(draft) = &mut self.draft else { return };
        let profile_id = draft.agent.profile_id.clone();
        let opening = opening.unwrap_or_else(|| ThreadOption::remembered(&self.host.state, &profile_id));
        let reading = (self.host.draft_options)(&profile_id, opening, cx);
        draft._probe = Some(cx.spawn(async move |this, cx| {
            let mut options = reading.await;
            let _ = this.update(cx, |this, cx| {
                // An agent that did not answer leaves what was offered before.
                if let Some(draft) = this.draft.as_mut().filter(|draft| draft.agent.profile_id == profile_id)
                    && !options.is_empty()
                {
                    // The answer takes a moment: what was picked meanwhile stands where the
                    // agent still offers it.
                    for (id, value) in ThreadOption::opening(&draft.options) {
                        ThreadOption::choose(&mut options, &id, &value);
                    }
                    draft.options = options;
                    cx.notify();
                }
            });
        }));
    }

    /// The settings the composer offers: the drafted thread's, else the open thread's.
    pub fn composer_options(&self) -> &[AgentChatConfigOption] {
        match &self.draft {
            Some(draft) => &draft.options,
            None => &self.options,
        }
    }

    /// Whether a setting can be changed now: not while the draft is being started, and only
    /// while the open thread's agent runs.
    fn options_enabled(&self) -> bool {
        match &self.draft {
            Some(draft) => !draft.launching,
            None => self.accepts_replies,
        }
    }

    /// Sets the option `id` of the drafted or open thread to `value`.
    pub fn pick_option(&mut self, id: &str, value: &str, cx: &mut Context<Self>) {
        if !self.options_enabled() {
            return;
        }
        if let Some(draft) = &mut self.draft {
            let was_model = ThreadOption::Model.of(&draft.options).is_some_and(|option| option.id == id);
            if ThreadOption::choose(&mut draft.options, id, value) && was_model {
                // Another model thinks in other levels: ask what it offers.
                let opening = ThreadOption::opening(&draft.options);
                self.read_draft_options(Some(opening), cx);
            }
            cx.notify();
            return;
        }
        let Some(target) = self.selected().map(DashboardEntry::target) else { return };
        if !ThreadOption::choose(&mut self.options, id, value) {
            return;
        }
        cx.emit(DashboardEvent::SetOption { target, id: id.to_owned(), value: value.to_owned() });
        self._option_read = Some(cx.spawn(async move |this, cx| {
            cx.background_executor().timer(OPTION_READ_DELAY).await;
            let _ = this.update(cx, |this, cx| {
                this.read_availability(cx);
                cx.notify();
            });
        }));
        cx.notify();
    }

    /// With no thread to show, the chat column holds a new one, ready to type: an empty
    /// column would also leave the keyboard nowhere.
    fn draft_when_empty(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.list.is_empty() || self.draft.is_some() {
            return;
        }
        self.start_draft(cx);
        if self.draft.is_some() {
            self.editor.update(cx, |editor, cx| {
                editor.set_value("", window, cx);
                editor.set_disabled(false, cx);
                editor.focus(window, cx);
            });
        }
    }

    /// The shell opened the drafted thread as `target`: the draft gives way to it, and the
    /// keyboard goes back to the inbox (its agent is still starting and takes no message yet).
    pub fn thread_opened(&mut self, target: &TerminalTarget, window: &mut Window, cx: &mut Context<Self>) {
        self.draft = None;
        self.editor.update(cx, |editor, cx| editor.set_value("", window, cx));
        self.refresh(window, cx);
        self.list.select(&format!("{}:{}", target.pane_id, target.tab_id));
        self.draft_when_empty(window, cx);
        if self.draft.is_none() {
            window.focus(&self.focus, cx);
        }
        self.sync_detail(window, cx);
        self.scroll_selection_into_view();
        cx.notify();
    }

    /// The shell could not open the drafted thread: the draft stays as written and says why.
    pub fn thread_failed(&mut self, message: &str, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(draft) = &mut self.draft {
            draft.launching = false;
            draft.error = Some(message.to_owned());
        }
        self.sync_composer(window, cx);
        cx.notify();
    }

    /// The project picker over the dashboard (a click on the draft's project): the host's
    /// folders, then any folder.
    pub fn open_project_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.draft.as_ref().is_none_or(|draft| draft.launching) {
            return;
        }
        let mut items: Vec<PickerItem> = (self.host.projects)(cx)
            .into_iter()
            .map(|project| {
                PickerItem::new(format!("project:{}", project.path), project.name)
                    .icon(IconName::Folder)
                    .description(soprano_platform::paths::abbreviate_home_in(
                        std::path::Path::new(&project.path),
                        &self.host.home,
                    ))
            })
            .collect();
        items.push(
            PickerItem::new(CHOOSE_FOLDER_ID, "Choose Folder…")
                .icon(IconName::FolderPlus)
                .description("Start the thread in any folder"),
        );
        let picker = Picker::new(items, window, cx);
        picker.update(cx, |picker, cx| picker.set_placeholder("Search projects…", window, cx));
        self._overlay = Some(cx.subscribe_in(&picker, window, |this, _, event: &PickerEvent, window, cx| {
            this.picker = None;
            this._overlay = None;
            if let PickerEvent::Confirmed { id, .. } = event {
                match id.strip_prefix("project:") {
                    Some(path) => this.set_draft_project(path, window, cx),
                    None => cx.emit(DashboardEvent::ChooseProject),
                }
            }
            cx.notify();
        }));
        self.picker = Some(picker);
        cx.notify();
    }

    /// The agents a thread can start with, as a menu above the draft's agent chip (a click on
    /// it).
    pub fn open_agent_menu(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(draft) = self.draft.as_ref().filter(|draft| !draft.launching) else { return };
        let choices = AgentChoice::all();
        let theme = cx.soprano_theme();
        let chip = self.agent_chip_bounds.get();
        // Rows of 31 in a padding of 5, with a gap of 6 to the chip.
        let height = theme.z(choices.len() as f32 * 31.0 + 16.0);
        let position = point(chip.origin.x, (chip.origin.y - height).max(px(8.)));
        let entity = cx.entity().downgrade();
        let items = choices
            .into_iter()
            .map(|choice| {
                let entity = entity.clone();
                let picked = choice.clone();
                MenuItem::new(choice.name()).icon(IconName::SHELL).checked(choice == draft.agent).on_select(
                    move |_, cx| {
                        let picked = picked.clone();
                        let _ = entity.update(cx, |this, cx| this.set_draft_agent(picked, cx));
                    },
                )
            })
            .collect();
        let menu = ContextMenu::new(position, items, window, cx);
        self._overlay = Some(cx.subscribe_in(&menu, window, |this, _, _: &DismissEvent, _, cx| {
            this.menu = None;
            this._overlay = None;
            cx.notify();
        }));
        self.menu = Some(menu);
        cx.notify();
    }

    /// The models the thread's agent offers, as a picker over the dashboard (a click on the
    /// model chip, ⇧⌘M).
    pub fn open_model_picker(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.options_enabled() || self.picker.is_some() {
            return;
        }
        let Some(option) = ThreadOption::Model.of(self.composer_options()).cloned() else { return };
        let items = option
            .values
            .iter()
            .map(|value| {
                let item = PickerItem::new(format!("{MODEL_ID_PREFIX}{}", value.value), value.name.clone())
                    .description(value.detail.clone().unwrap_or_else(|| value.value.clone()));
                let item = match soprano_chat_ui::composer_logic::model_provider(value) {
                    Some(provider) => item.group(provider.to_owned()),
                    None => item,
                };
                if value.value == option.current_value { item.icon(IconName::Check) } else { item }
            })
            .collect();
        let picker = Picker::new(items, window, cx);
        picker.update(cx, |picker, cx| picker.set_placeholder("Search models…", window, cx));
        self._overlay =
            Some(cx.subscribe_in(&picker, window, move |this, _, event: &PickerEvent, window, cx| {
                this.picker = None;
                this._overlay = None;
                if let PickerEvent::Confirmed { id, .. } = event
                    && let Some(value) = id.strip_prefix(MODEL_ID_PREFIX)
                {
                    this.pick_option(&option.id, value, cx);
                    this.focus_composer(window, cx);
                }
                cx.notify();
            }));
        self.picker = Some(picker);
        cx.notify();
    }

    /// How hard the thread's model thinks, as a menu above its chip (a click on it, ⇧⌘E).
    pub fn open_thinking_menu(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.options_enabled() || self.menu.is_some() {
            return;
        }
        let Some(option) = ThreadOption::Thinking.of(self.composer_options()).cloned() else { return };
        let theme = cx.soprano_theme();
        let chip = self.option_chip_bounds[1].get();
        // Rows of 31 in a padding of 5, with a gap of 6 to the chip.
        let height = theme.z(option.values.len() as f32 * 31.0 + 16.0);
        let position = point(chip.origin.x, (chip.origin.y - height).max(px(8.)));
        let entity = cx.entity().downgrade();
        let items = option
            .values
            .iter()
            .map(|value| {
                let entity = entity.clone();
                let (id, picked) = (option.id.clone(), value.value.clone());
                MenuItem::new(option_title(&value.name))
                    .checked(value.value == option.current_value)
                    .on_select(move |_, cx| {
                        let _ = entity.update(cx, |this, cx| this.pick_option(&id, &picked, cx));
                    })
            })
            .collect();
        let menu = ContextMenu::new(position, items, window, cx);
        self._overlay = Some(cx.subscribe_in(&menu, window, |this, _, _: &DismissEvent, _, cx| {
            this.menu = None;
            this._overlay = None;
            cx.notify();
        }));
        self.menu = Some(menu);
        cx.notify();
    }

    // MARK: - Keyboard

    /// Runs the dashboard shortcut for `keystroke` while the keyboard is anywhere inside the
    /// dashboard. Returns whether it was one.
    fn handle_keystroke(
        &mut self,
        keystroke: &Keystroke,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        // A menu or the picker over the dashboard takes every key.
        if self.picker.is_some() || self.menu.is_some() || !self.focus.contains_focused(window, cx) {
            return false;
        }
        let focus = if self.editor.focus_handle(cx).contains_focused(window, cx) {
            KeyFocus::Composer
        } else if self.search.focus_handle(cx).contains_focused(window, cx) {
            KeyFocus::Search
        } else {
            KeyFocus::List
        };
        let Some(action) = key_action(keystroke, focus) else { return false };
        self.perform(action, window, cx);
        true
    }

    /// Runs one keyboard action.
    pub fn perform(&mut self, action: KeyAction, window: &mut Window, cx: &mut Context<Self>) {
        match action {
            KeyAction::Dismiss => {
                // Esc first gives up a draft; with nothing else to show it closes the window.
                let drafting = self.draft.as_ref().is_some_and(|draft| !draft.launching);
                if drafting && !self.list.is_empty() {
                    self.leave_draft(window, cx);
                } else {
                    cx.emit(DashboardEvent::Close);
                }
            }
            KeyAction::Move(delta) => self.move_selection(delta, window, cx),
            KeyAction::Activate => self.emit_for_selection(DashboardEvent::Open, cx),
            KeyAction::FocusComposer => self.focus_composer(window, cx),
            KeyAction::FocusList => {
                window.focus(&self.focus, cx);
                cx.notify();
            }
            KeyAction::FocusSearch => self.focus_search(window, cx),
            KeyAction::ClearSearch => self.clear_search(window, cx),
            KeyAction::NewThread => self.new_thread(window, cx),
            KeyAction::PickModel => self.open_model_picker(window, cx),
            KeyAction::PickThinking => self.open_thinking_menu(window, cx),
            KeyAction::Scroll(amount) => self.scroll_text(amount, cx),
            KeyAction::JumpTurn(direction) => {
                self.timeline.update(cx, |timeline, cx| timeline.jump_to_message(direction, cx));
            }
            KeyAction::ToggleDetails => self.toggle_details(cx),
            KeyAction::FollowLatest => self.timeline.update(cx, |timeline, cx| timeline.jump_to_latest(cx)),
        }
    }

    // MARK: - Reading (for the shell and tests)

    /// The inbox.
    pub fn list(&self) -> &AgentList {
        &self.list
    }

    pub fn timeline_view(&self) -> &Entity<TimelineView> {
        &self.timeline
    }

    /// The composer's text.
    pub fn composer_text(&self, cx: &App) -> String {
        self.editor.read(cx).value().to_string()
    }

    /// Whether a new thread is being drafted.
    pub fn is_drafting(&self) -> bool {
        self.draft.is_some()
    }

    /// The folder and agent the drafted thread starts with.
    pub fn draft_choice(&self) -> Option<(&ProjectChoice, &AgentChoice)> {
        self.draft.as_ref().map(|draft| (&draft.project, &draft.agent))
    }

    /// The line beside the send button: why nothing can be sent, or what went wrong; empty
    /// otherwise. The flag marks an error.
    pub fn composer_hint(&self) -> (String, bool) {
        if let Some(draft) = &self.draft {
            return match (&draft.error, draft.launching) {
                (Some(error), _) => (error.clone(), true),
                (None, true) => (format!("Starting {}…", draft.agent.name()), false),
                (None, false) => (String::new(), false),
            };
        }
        if self.send_failed.is_some() {
            return (state::SEND_FAILED.to_owned(), true);
        }
        (state::composer_hint(self.selected(), self.accepts_replies).to_owned(), false)
    }
}

/// The folder name of the project `entry` works in: its checkout's on this computer, the
/// folder's own on a machine; empty without a folder.
fn project_name(names: &mut HashMap<String, String>, entry: &soprano_model::AgentDashboardEntry) -> String {
    let Some(cwd) = entry.cwd.as_deref() else { return String::new() };
    if entry.machine.is_some() {
        return ProjectChoice::at(cwd).name;
    }
    names
        .entry(cwd.to_owned())
        .or_insert_with(|| {
            ProjectChoice::at(Workspace::project_root(cwd).to_string_lossy().into_owned()).name
        })
        .clone()
}

// MARK: - Rendering

impl Render for AgentDashboard {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.soprano_theme().clone();
        div()
            .id("agent-dashboard")
            .key_context("AgentDashboard")
            .track_focus(&self.focus)
            .relative()
            .flex()
            .flex_row()
            .size_full()
            .bg(theme.background)
            .text_color(theme.foreground)
            .font_family(fonts::UI_FONT_FAMILY)
            .text_size(theme.z(soprano_chat_ui::widgets::text_size::BODY))
            .child(self.render_sidebar(&theme, window, cx))
            .child(self.render_chat(&theme, window, cx))
            .children(self.picker.clone())
            .children(self.menu.clone())
    }
}

impl AgentDashboard {
    /// The chat column's page gutter and lane width, from its last drawn width.
    fn lane(&self, theme: &SopranoTheme) -> (f32, f32) {
        let width = f32::from(self.column_bounds.get().size.width) / theme.zoom();
        // Before the first layout the column has no width; the lane cap stands in.
        if width <= 0.0 {
            return (soprano_chat_ui::timeline_view::GUTTER, soprano_chat_ui::timeline_view::CHAT_MAX_WIDTH);
        }
        (gutter(width), lane_width(width))
    }

    /// What the composer covers at the timeline's end.
    fn composer_inset(&self, theme: &SopranoTheme) -> f32 {
        let height = f32::from(self.composer_bounds.get().size.height) / theme.zoom();
        let (gutter, _) = self.lane(theme);
        (if height > 0.0 { height } else { COMPOSER_HEIGHT }) + gutter * 2.0
    }
}

/// A band the window is moved by: mouse-down drags it, a double-click zooms it.
fn drag_region<E: InteractiveElement>(element: E) -> E {
    element.on_mouse_down(MouseButton::Left, |event, window, _| {
        if event.click_count >= 2 {
            window.zoom_window();
        } else {
            window.start_window_move();
        }
    })
}

/// Records where `bounds` is drawn, as an invisible layer over its parent.
fn measure(bounds: &Rc<Cell<Bounds<Pixels>>>) -> impl IntoElement {
    let bounds = bounds.clone();
    canvas(move |drawn, _, _| bounds.set(drawn), |_, _, _, _| {}).absolute().size_full()
}

#[cfg(test)]
#[path = "view_tests.rs"]
mod tests;
