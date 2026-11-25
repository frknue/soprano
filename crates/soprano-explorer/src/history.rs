//! The History card: indexed Agent Session History across Claude Code, omp, Codex, and
//! OpenCode, scoped to the focused pane's Workspace / Project / All, with full-text search,
//! inline turn previews, and one-click session resume.
//!
//! Nothing is scanned while the panel is inactive; indexing runs on a background thread with
//! an mtime+size SQLite cache so refreshes stay fast even with hundreds of transcripts.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use chrono::Utc;
use gpui::{
    AnyElement, App, ClickEvent, ClipboardItem, Context, DismissEvent, Entity, FocusHandle, Focusable,
    FontWeight, Hsla, InteractiveElement, IntoElement, KeyDownEvent, MouseButton, MouseDownEvent,
    ParentElement, Pixels, Point, Render, ScrollHandle, SharedString, StatefulInteractiveElement, Styled,
    Subscription, Task, Window, div, prelude::*,
};
use gpui_component::input::{Escape, Input, InputEvent, InputState};
use soprano_agents::{
    AgentSessionIndex, AgentSessionSummary, AgentTranscriptFormat, Date, HistoryMessageRole,
    HistoryProjectGroup, HistoryQuery, HistoryQueryResult, HistoryScope, HistorySessionItem, HistorySort,
    format_relative_age, query_sessions,
};
use soprano_types::AgentCatalog;
use soprano_ui::button::{IconButton, IconButtonSize};
use soprano_ui::fonts::size;
use soprano_ui::icons::{Icon, agent_icon_stem};
use soprano_ui::{ActiveSopranoTheme, ContextMenu, IconName, MenuItem, SopranoTheme, icon};

use crate::chords;
use crate::{SidebarEvent, ui};

/// Minimum interval between automatic refreshes on reactivation.
const AUTO_REFRESH_COOLDOWN: Duration = Duration::from_secs(3);

/// Maximum sessions rendered per group before showing a "Show all" toggle so giant histories
/// stay snappy in GPUI.
const INITIAL_GROUP_LIMIT: usize = 60;

pub struct HistoryPanel {
    focus_handle: FocusHandle,
    search_input: Entity<InputState>,
    index: Arc<Mutex<AgentSessionIndex>>,
    is_active: bool,
    active_cwd: Option<String>,
    scope: HistoryScope,
    agent_filter: Option<AgentTranscriptFormat>,
    sort: HistorySort,
    search_query: String,
    sessions: Vec<AgentSessionSummary>,
    result: HistoryQueryResult,
    /// Flat list of visible session keys (respecting collapsed groups and per-group limits),
    /// for keyboard navigation.
    visible_keys: Vec<String>,
    selected_key: Option<String>,
    expanded_sessions: HashSet<String>,
    collapsed_groups: HashSet<String>,
    uncapped_groups: HashSet<String>,
    is_loading: bool,
    has_loaded: bool,
    refreshed_at: Option<Date>,
    last_auto_refresh: Option<Instant>,
    refresh_generation: u64,
    _refresh_task: Option<Task<()>>,
    scroll: ScrollHandle,
    context_menu: Option<(Entity<ContextMenu>, Subscription)>,
    _subscriptions: Vec<Subscription>,
}

impl HistoryPanel {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        Self::with_index(AgentSessionIndex::for_current_user(), window, cx)
    }

    pub fn with_index(index: AgentSessionIndex, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search_input = cx.new(|cx| InputState::new(window, cx).placeholder("Search sessions…"));
        let subscriptions =
            vec![
                cx.subscribe_in(&search_input, window, |this, input, event: &InputEvent, window, cx| {
                    match event {
                        InputEvent::Change => {
                            let query = input.read(cx).value().to_string();
                            this.set_search_query(query, cx);
                        }
                        InputEvent::PressEnter { .. } => {
                            this.resume_selected_or_first(false, false, cx);
                        }
                        _ => {
                            let _ = window;
                        }
                    }
                }),
                cx.observe_window_activation(window, |this, window, cx| {
                    if window.is_window_active() && this.is_active {
                        this.maybe_auto_refresh(cx);
                    }
                }),
            ];
        Self {
            focus_handle: cx.focus_handle(),
            search_input,
            index: Arc::new(Mutex::new(index)),
            is_active: false,
            active_cwd: None,
            scope: HistoryScope::Project,
            agent_filter: None,
            sort: HistorySort::LastUpdated,
            search_query: String::new(),
            sessions: Vec::new(),
            result: HistoryQueryResult::default(),
            visible_keys: Vec::new(),
            selected_key: None,
            expanded_sessions: HashSet::new(),
            collapsed_groups: HashSet::new(),
            uncapped_groups: HashSet::new(),
            is_loading: false,
            has_loaded: false,
            refreshed_at: None,
            last_auto_refresh: None,
            refresh_generation: 0,
            _refresh_task: None,
            scroll: ScrollHandle::new(),
            context_menu: None,
            _subscriptions: subscriptions,
        }
    }

    pub fn is_active(&self) -> bool {
        self.is_active
    }

    pub fn scope(&self) -> HistoryScope {
        self.scope
    }

    pub fn matched_count(&self) -> usize {
        self.result.matched_count
    }

    pub fn contains_focus(&self, window: &Window, cx: &App) -> bool {
        self.focus_handle.contains_focused(window, cx)
            || self.search_input.read(cx).focus_handle(cx).is_focused(window)
    }

    /// Moves keyboard focus into the search input (e.g. on ⇧⌘H).
    pub fn focus_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.search_input.update(cx, |input, cx| input.focus(window, cx));
        cx.notify();
    }

    /// Moves keyboard focus into the session list.
    pub fn focus_list(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        window.focus(&self.focus_handle, cx);
        if self.selected_key.is_none() {
            self.selected_key = self.visible_keys.first().cloned();
        }
        cx.notify();
    }

    /// Follows the focused pane's working directory.
    pub fn set_working_directory(&mut self, cwd: Option<&str>, cx: &mut Context<Self>) {
        let next = cwd.filter(|s| !s.is_empty()).map(str::to_owned);
        if self.active_cwd == next {
            return;
        }
        self.active_cwd = next;
        self.recompute(cx);
    }

    /// Starts indexing when the sidebar shows History; stops background work when hidden.
    pub fn set_active(&mut self, active: bool, cx: &mut Context<Self>) {
        if active == self.is_active {
            return;
        }
        self.is_active = active;
        if active {
            if !self.has_loaded {
                self.refresh(cx);
            } else {
                self.maybe_auto_refresh(cx);
            }
        } else {
            self.context_menu = None;
        }
        cx.notify();
    }

    pub fn set_scope(&mut self, scope: HistoryScope, cx: &mut Context<Self>) {
        if self.scope == scope {
            return;
        }
        self.scope = scope;
        self.recompute(cx);
    }

    pub fn set_agent_filter(&mut self, agent: Option<AgentTranscriptFormat>, cx: &mut Context<Self>) {
        if self.agent_filter == agent {
            return;
        }
        self.agent_filter = agent;
        self.recompute(cx);
    }

    pub fn set_sort(&mut self, sort: HistorySort, cx: &mut Context<Self>) {
        if self.sort == sort {
            return;
        }
        self.sort = sort;
        self.recompute(cx);
    }

    pub fn set_search_query(&mut self, query: String, cx: &mut Context<Self>) {
        if self.search_query == query {
            return;
        }
        self.search_query = query;
        self.recompute(cx);
    }

    fn maybe_auto_refresh(&mut self, cx: &mut Context<Self>) {
        if self.is_loading {
            return;
        }
        let now = Instant::now();
        if self.last_auto_refresh.is_some_and(|last| now.duration_since(last) < AUTO_REFRESH_COOLDOWN) {
            return;
        }
        self.refresh(cx);
    }

    /// Triggers an asynchronous background refresh of the transcript index.
    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        self.refresh_generation += 1;
        let generation = self.refresh_generation;
        self.is_loading = true;
        self.last_auto_refresh = Some(Instant::now());
        let index = Arc::clone(&self.index);
        let bg = cx.background_executor().spawn(async move {
            let mut guard = index.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            guard.refresh()
        });
        self._refresh_task = Some(cx.spawn(async move |this, cx| {
            let outcome = bg.await;
            let _ = this.update(cx, |this, cx| {
                if this.refresh_generation != generation {
                    return;
                }
                this.sessions = outcome.sessions;
                this.refreshed_at = Some(outcome.refreshed_at);
                this.is_loading = false;
                this.has_loaded = true;
                this.recompute(cx);
            });
        }));
        cx.notify();
    }

    fn recompute(&mut self, cx: &mut Context<Self>) {
        let query = HistoryQuery {
            scope: self.scope,
            active_cwd: self.active_cwd.clone(),
            search: self.search_query.clone(),
            agent: self.agent_filter,
            sort: self.sort,
        };
        self.result = query_sessions(&self.sessions, &query);
        self.rebuild_visible_keys();
        if let Some(selected) = &self.selected_key
            && !self.visible_keys.contains(selected)
        {
            self.selected_key = self.visible_keys.first().cloned();
        }
        cx.notify();
    }

    fn rebuild_visible_keys(&mut self) {
        self.visible_keys.clear();
        for group in &self.result.groups {
            if self.collapsed_groups.contains(&group.key) {
                continue;
            }
            let limit = self.group_limit(&group.key);
            for item in group.sessions.iter().take(limit) {
                self.visible_keys.push(item.session.key());
            }
        }
    }

    fn group_limit(&self, group_key: &str) -> usize {
        if self.uncapped_groups.contains(group_key) || !self.search_query.trim().is_empty() {
            usize::MAX
        } else {
            INITIAL_GROUP_LIMIT
        }
    }

    fn find_session_by_key(&self, key: &str) -> Option<&HistorySessionItem> {
        self.result.groups.iter().flat_map(|g| g.sessions.iter()).find(|item| item.session.key() == key)
    }

    fn toggle_group(&mut self, group_key: &str, cx: &mut Context<Self>) {
        if !self.collapsed_groups.remove(group_key) {
            self.collapsed_groups.insert(group_key.to_owned());
        }
        self.rebuild_visible_keys();
        cx.notify();
    }

    fn toggle_expand_session(&mut self, session_key: &str, cx: &mut Context<Self>) {
        if !self.expanded_sessions.remove(session_key) {
            self.expanded_sessions.insert(session_key.to_owned());
        }
        cx.notify();
    }

    fn resume_session(
        &self,
        session: &AgentSessionSummary,
        chat: bool,
        new_tab: bool,
        cx: &mut Context<Self>,
    ) {
        cx.emit(SidebarEvent::ResumeSession {
            profile_id: session.profile_id.to_owned(),
            conversation: session.conversation(),
            chat,
            new_tab,
        });
    }

    fn resume_selected_or_first(&self, chat: bool, new_tab: bool, cx: &mut Context<Self>) {
        let key = self.selected_key.as_deref().or_else(|| self.visible_keys.first().map(String::as_str));
        if let Some(key) = key
            && let Some(item) = self.find_session_by_key(key)
        {
            self.resume_session(&item.session, chat, new_tab, cx);
        }
    }

    fn move_selection(&mut self, delta: isize, cx: &mut Context<Self>) {
        if self.visible_keys.is_empty() {
            return;
        }
        let next =
            match self.selected_key.as_deref().and_then(|k| self.visible_keys.iter().position(|v| v == k)) {
                Some(current) => {
                    let len = self.visible_keys.len() as isize;
                    (current as isize + delta).clamp(0, len - 1) as usize
                }
                None => {
                    if delta >= 0 {
                        0
                    } else {
                        self.visible_keys.len() - 1
                    }
                }
            };
        self.selected_key = self.visible_keys.get(next).cloned();
        cx.notify();
    }

    fn handle_list_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let key = event.keystroke.key.as_str();
        let mods = &event.keystroke.modifiers;
        if chords::is_plain(mods) {
            match key {
                "down" | "j" => {
                    cx.stop_propagation();
                    self.move_selection(1, cx);
                }
                "up" | "k" => {
                    cx.stop_propagation();
                    if self.selected_key.as_deref() == self.visible_keys.first().map(String::as_str) {
                        self.focus_search(window, cx);
                    } else {
                        self.move_selection(-1, cx);
                    }
                }
                "enter" => {
                    cx.stop_propagation();
                    self.resume_selected_or_first(false, false, cx);
                }
                "space" => {
                    cx.stop_propagation();
                    if let Some(key) = self.selected_key.clone() {
                        self.toggle_expand_session(&key, cx);
                    }
                }
                "/" => {
                    cx.stop_propagation();
                    self.focus_search(window, cx);
                }
                "escape" => {
                    cx.stop_propagation();
                    cx.emit(SidebarEvent::FocusPane);
                }
                _ => {}
            }
        } else if key == "f" && (mods.platform || mods.control) && !mods.alt && !mods.shift {
            cx.stop_propagation();
            self.focus_search(window, cx);
        }
    }

    // MARK: - Context menus

    fn show_menu(
        &mut self,
        position: Point<Pixels>,
        items: Vec<MenuItem>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let menu = ContextMenu::new(position, items, window, cx);
        let sub = cx.subscribe(&menu, |this, _, _: &DismissEvent, cx| {
            this.context_menu = None;
            cx.notify();
        });
        self.context_menu = Some((menu, sub));
        cx.notify();
    }

    fn open_filter_menu(&mut self, position: Point<Pixels>, window: &mut Window, cx: &mut Context<Self>) {
        let this = cx.entity().downgrade();
        let current = self.agent_filter;
        let mut items = vec![
            MenuItem::new("All Agents").checked(current.is_none()).on_select({
                let this = this.clone();
                move |_, cx| {
                    let _ = this.update(cx, |panel, cx| panel.set_agent_filter(None, cx));
                }
            }),
            MenuItem::separator(),
        ];
        for format in AgentTranscriptFormat::ALL {
            let label = AgentSessionSummary::full_agent_label(format);
            let this = this.clone();
            items.push(MenuItem::new(label).checked(current == Some(format)).on_select(move |_, cx| {
                let _ = this.update(cx, |panel, cx| panel.set_agent_filter(Some(format), cx));
            }));
        }
        self.show_menu(position, items, window, cx);
    }

    fn open_sort_menu(&mut self, position: Point<Pixels>, window: &mut Window, cx: &mut Context<Self>) {
        let this = cx.entity().downgrade();
        let current = self.sort;
        let items = HistorySort::ALL
            .into_iter()
            .map(|sort| {
                let this = this.clone();
                MenuItem::new(sort.label()).checked(current == sort).on_select(move |_, cx| {
                    let _ = this.update(cx, |panel, cx| panel.set_sort(sort, cx));
                })
            })
            .collect();
        self.show_menu(position, items, window, cx);
    }

    fn open_session_menu(
        &mut self,
        session: AgentSessionSummary,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let this = cx.entity().downgrade();
        let mut items = vec![
            MenuItem::new("Resume in Split Pane").icon(IconName::SplitRight).on_select({
                let this = this.clone();
                let session = session.clone();
                move |_, cx| {
                    let _ = this.update(cx, |panel, cx| panel.resume_session(&session, false, false, cx));
                }
            }),
            MenuItem::new("Resume in New Tab").icon(IconName::Plus).on_select({
                let this = this.clone();
                let session = session.clone();
                move |_, cx| {
                    let _ = this.update(cx, |panel, cx| panel.resume_session(&session, false, true, cx));
                }
            }),
            MenuItem::new("Resume in Chat").icon(IconName::MessageSquare).on_select({
                let this = this.clone();
                let session = session.clone();
                move |_, cx| {
                    let _ = this.update(cx, |panel, cx| panel.resume_session(&session, true, false, cx));
                }
            }),
        ];
        items.push(MenuItem::separator());
        items.push(MenuItem::new("Copy Resume Command").icon(IconName::Terminal).on_select({
            let this = this.clone();
            let command = session.resume_command();
            move |_, cx| {
                cx.write_to_clipboard(ClipboardItem::new_string(command.clone()));
                let _ = this.update(cx, |_, cx| {
                    cx.emit(SidebarEvent::ShowInfo("Copied resume command".into()));
                });
            }
        }));
        items.push(MenuItem::new("Copy Session ID").icon(IconName::Copy).on_select({
            let this = this.clone();
            let id = session.id.clone();
            move |_, cx| {
                cx.write_to_clipboard(ClipboardItem::new_string(id.clone()));
                let _ = this.update(cx, |_, cx| {
                    cx.emit(SidebarEvent::ShowInfo("Copied session ID".into()));
                });
            }
        }));
        if let Some(cwd) = session.cwd.clone() {
            let this = this.clone();
            items.push(MenuItem::new("Copy Directory Path").icon(IconName::Folder).on_select(
                move |_, cx| {
                    cx.write_to_clipboard(ClipboardItem::new_string(cwd.clone()));
                    let _ = this.update(cx, |_, cx| {
                        cx.emit(SidebarEvent::ShowInfo("Copied directory path".into()));
                    });
                },
            ));
        }
        if let Some(path) = session.transcript_path.clone() {
            let this = this.clone();
            let reveal_label =
                if cfg!(target_os = "macos") { "Reveal Transcript in Finder" } else { "Reveal Transcript" };
            items.push(MenuItem::new(reveal_label).icon(IconName::ExternalLink).on_select(move |_, cx| {
                if let Err(error) = crate::reveal::reveal(std::slice::from_ref(&path)) {
                    let _ = this.update(cx, |_, cx| {
                        cx.emit(SidebarEvent::ShowError(format!("Could not reveal transcript: {error}")));
                    });
                }
            }));
        }
        self.show_menu(position, items, window, cx);
    }

    // MARK: - Rendering helpers

    fn render_scope_bar(&self, t: &SopranoTheme, cx: &mut Context<Self>) -> impl IntoElement {
        let hover = t.hover;
        let active_scope = self.scope;
        div().flex_none().px(t.z(10.)).pt(t.z(8.)).child(
            div()
                .flex()
                .flex_row()
                .items_center()
                .w_full()
                .p(t.z(2.))
                .gap(t.z(2.))
                .rounded(t.z(8.))
                .border_1()
                .border_color(t.border)
                .bg(t.canvas)
                .children(HistoryScope::ALL.into_iter().map(|scope| {
                    let active = scope == active_scope;
                    div()
                        .id(SharedString::from(format!("history-scope-{}", scope.label())))
                        .flex()
                        .flex_1()
                        .items_center()
                        .justify_center()
                        .h(t.z(24.))
                        .rounded(t.z(6.))
                        .text_size(t.z(size::META))
                        .font_weight(if active { FontWeight::MEDIUM } else { FontWeight::NORMAL })
                        .text_color(if active { t.foreground } else { t.muted })
                        .when(active, |s| s.bg(t.selected).border_1().border_color(t.input))
                        .when(!active, |s| s.cursor_pointer().hover(move |st| st.bg(hover)))
                        .on_click(cx.listener(move |this, _, _, cx| this.set_scope(scope, cx)))
                        .child(scope.label())
                })),
        )
    }

    fn render_search_bar(
        &self,
        t: &SopranoTheme,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let search_empty = self.search_input.read(cx).value().is_empty();
        let focused = self.search_input.read(cx).focus_handle(cx).is_focused(window);
        div()
            .flex_none()
            .px(t.z(10.))
            .pt(t.z(8.))
            .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                if event.keystroke.key == "down" && chords::is_plain(&event.keystroke.modifiers) {
                    cx.stop_propagation();
                    this.focus_list(window, cx);
                }
            }))
            .on_action(cx.listener(|this, _: &Escape, window, cx| {
                cx.stop_propagation();
                if this.search_input.read(cx).value().is_empty() {
                    cx.emit(SidebarEvent::FocusPane);
                } else {
                    this.search_input.update(cx, |input, cx| input.set_value("", window, cx));
                    this.set_search_query(String::new(), cx);
                }
            }))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(t.z(6.))
                    .h(t.z(28.))
                    .px(t.z(8.))
                    .rounded(t.z(8.))
                    .border_1()
                    .border_color(if focused { t.accent } else { t.border })
                    .bg(t.canvas)
                    .child(icon(IconName::Search).size(13.).color(t.dim))
                    .child(div().flex_1().min_w_0().child(Input::new(&self.search_input).appearance(false)))
                    .when(!search_empty, |field| {
                        field.child(
                            IconButton::new("history-clear-search", IconName::X)
                                .size(IconButtonSize::Tab)
                                .tooltip("Clear session search")
                                .on_click(cx.listener(|this, _, window, cx| {
                                    this.search_input.update(cx, |input, cx| {
                                        input.set_value("", window, cx);
                                        input.focus(window, cx);
                                    });
                                    this.set_search_query(String::new(), cx);
                                })),
                        )
                    }),
            )
    }

    fn render_status_strip(&self, t: &SopranoTheme, now: Date) -> impl IntoElement {
        let (glyph, glyph_color, status_text, time_text) = if self.is_loading {
            (IconName::LoaderCircle, t.muted, "Indexing history…", String::new())
        } else if let Some(refreshed) = self.refreshed_at {
            (IconName::Check, t.ansi[2], "History refreshed", format_relative_age(refreshed, now))
        } else {
            (IconName::Clock, t.dim, "Indexed history", String::new())
        };
        div()
            .flex()
            .flex_none()
            .items_center()
            .justify_between()
            .px(t.z(12.))
            .py(t.z(6.))
            .mt(t.z(6.))
            .border_t_1()
            .border_b_1()
            .border_color(t.border)
            .text_size(t.z(size::SMALL))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(t.z(6.))
                    .text_color(t.muted)
                    .child(icon(glyph).size(12.).color(glyph_color))
                    .child(status_text),
            )
            .when(!time_text.is_empty(), |row| row.child(div().text_color(t.dim).child(time_text)))
    }

    fn render_summary_row(&self, t: &SopranoTheme, cx: &mut Context<Self>) -> impl IntoElement {
        let matched = self.result.matched_count;
        let scoped = self.result.scoped_count;
        let noun = if matched == 1 { "session" } else { "sessions" };
        let count_label = if !self.search_query.trim().is_empty() && matched != scoped {
            format!("{matched} of {scoped} {noun}")
        } else {
            format!("{matched} {noun}")
        };
        let fg = t.foreground;
        div()
            .flex()
            .flex_none()
            .items_center()
            .justify_between()
            .px(t.z(12.))
            .py(t.z(7.))
            .border_b_1()
            .border_color(t.border)
            .child(
                div()
                    .text_size(t.z(size::META))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(t.foreground)
                    .child(count_label),
            )
            .child(
                div()
                    .id("history-sort-trigger")
                    .flex()
                    .items_center()
                    .gap(t.z(4.))
                    .px(t.z(4.))
                    .py(t.z(2.))
                    .rounded(t.z(5.))
                    .cursor_pointer()
                    .text_size(t.z(size::META))
                    .text_color(t.muted)
                    .hover(move |s| s.text_color(fg))
                    .on_click(cx.listener(|this, event: &ClickEvent, window, cx| {
                        this.open_sort_menu(event.position(), window, cx);
                    }))
                    .child(self.sort.label())
                    .child(icon(IconName::ChevronDown).size(11.).color(t.dim)),
            )
    }

    fn render_group(
        &self,
        group: &HistoryProjectGroup,
        t: &SopranoTheme,
        now: Date,
        focused: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let collapsed = self.collapsed_groups.contains(&group.key);
        let group_key = group.key.clone();
        let hover = t.hover;
        let limit = self.group_limit(&group.key);
        let hidden = group.sessions.len().saturating_sub(limit);

        let header = div()
            .id(SharedString::from(format!("history-group-{}", group.key)))
            .flex()
            .items_center()
            .justify_between()
            .w_full()
            .px(t.z(12.))
            .py(t.z(6.))
            .border_b_1()
            .border_color(t.border)
            .cursor_pointer()
            .hover(move |s| s.bg(hover))
            .on_click(cx.listener(move |this, _, _, cx| this.toggle_group(&group_key, cx)))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(t.z(6.))
                    .min_w_0()
                    .flex_1()
                    .child(
                        icon(if collapsed { IconName::ChevronRight } else { IconName::ChevronDown })
                            .size(12.)
                            .color(t.dim),
                    )
                    .child(
                        div()
                            .truncate()
                            .text_size(t.z(size::META))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(t.foreground)
                            .child(group.name.clone()),
                    ),
            )
            .child(
                div()
                    .flex_none()
                    .px(t.z(6.))
                    .py(t.z(1.))
                    .rounded(t.z(999.))
                    .bg(t.raised)
                    .text_size(t.z(size::SMALL))
                    .text_color(t.muted)
                    .child(group.sessions.len().to_string()),
            );

        let mut container = div().flex().flex_col().w_full().child(header);
        if !collapsed {
            for item in group.sessions.iter().take(limit) {
                container = container.child(self.render_session_card(item, t, now, focused, cx));
            }
            if hidden > 0 {
                let expand_key = group.key.clone();
                let hover = t.hover;
                container = container.child(
                    div()
                        .id(SharedString::from(format!("history-show-more-{}", group.key)))
                        .flex()
                        .items_center()
                        .justify_center()
                        .py(t.z(8.))
                        .border_b_1()
                        .border_color(t.border)
                        .cursor_pointer()
                        .text_size(t.z(size::SMALL))
                        .text_color(t.muted)
                        .hover(move |s| s.bg(hover))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.uncapped_groups.insert(expand_key.clone());
                            this.rebuild_visible_keys();
                            cx.notify();
                        }))
                        .child(format!("Show {hidden} more sessions")),
                );
            }
        }
        container.into_any_element()
    }

    fn render_session_card(
        &self,
        item: &HistorySessionItem,
        t: &SopranoTheme,
        now: Date,
        focused: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let session = &item.session;
        let key = session.key();
        let selected = self.selected_key.as_deref() == Some(key.as_str());
        let expanded = self.expanded_sessions.contains(&key);
        let fill = if selected { Some(if focused { t.selected } else { t.hover }) } else { None };
        let hover = t.hover;

        // Agent icon & tint from AgentCatalog.
        let agent_color: Hsla = AgentCatalog::shared()
            .profile(session.profile_id)
            .map(|p| soprano_ui::color::hsla(p.color()))
            .unwrap_or(t.muted);
        let agent_glyph: AnyElement = match agent_icon_stem(session.profile_id) {
            Some(stem) => Icon::program(stem).size(12.).color(agent_color).into_any_element(),
            None => icon(IconName::Bot).size(12.).color(agent_color).into_any_element(),
        };

        // Title row + expand chevron + more actions menu button.
        let expand_key = key.clone();
        let menu_session = session.clone();
        let title_row = div()
            .flex()
            .items_center()
            .gap(t.z(4.))
            .w_full()
            .min_w_0()
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(t.z(size::ROW))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(t.foreground)
                    .child(session.title.clone()),
            )
            .child(
                IconButton::new(
                    SharedString::from(format!("history-expand-{key}")),
                    if expanded { IconName::ChevronUp } else { IconName::ChevronDown },
                )
                .size(IconButtonSize::Tab)
                .icon_size(12.)
                .tooltip(if expanded { "Collapse preview" } else { "Expand preview" })
                .on_click(cx.listener(move |this, _, _, cx| {
                    cx.stop_propagation();
                    this.toggle_expand_session(&expand_key, cx);
                })),
            )
            .child(
                IconButton::new(SharedString::from(format!("history-more-{key}")), IconName::Ellipsis)
                    .size(IconButtonSize::Tab)
                    .icon_size(12.)
                    .tooltip("Session Actions")
                    .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
                        cx.stop_propagation();
                        this.open_session_menu(menu_session.clone(), event.position(), window, cx);
                    })),
            );

        // Preview line (search match snippet when query hit conversation prose, else last message).
        let preview_element: Option<AnyElement> = if let Some(snippet) = &item.match_snippet {
            Some(
                div()
                    .mt(t.z(3.))
                    .pl(t.z(6.))
                    .border_l_2()
                    .border_color(t.accent)
                    .text_size(t.z(size::META))
                    .text_color(t.muted)
                    .line_clamp(2)
                    .child(snippet.clone())
                    .into_any_element(),
            )
        } else if let Some(preview) = &session.last_message_text {
            let role_prefix = session.last_message_role.map_or("", HistoryMessageRole::prefix);
            Some(
                div()
                    .mt(t.z(3.))
                    .text_size(t.z(size::META))
                    .text_color(t.muted)
                    .line_clamp(2)
                    .child(format!("{role_prefix}{preview}"))
                    .into_any_element(),
            )
        } else {
            None
        };

        // Metadata line: [icon] OMP · 130 msgs · 2 subagents · 4m ago · claude-opus-4-6
        let mut meta_parts: Vec<String> = Vec::new();
        let msg_noun = if session.message_count == 1 { "msg" } else { "msgs" };
        meta_parts.push(format!("{} {msg_noun}", session.message_count));
        if session.subagent_count > 0 {
            let sub_noun = if session.subagent_count == 1 { "subagent" } else { "subagents" };
            meta_parts.push(format!("{} {sub_noun}", session.subagent_count));
        }
        meta_parts.push(format_relative_age(session.updated_at, now));
        if let Some(model) = &session.model {
            meta_parts.push(model.clone());
        }
        let meta_row = div()
            .flex()
            .items_center()
            .gap(t.z(5.))
            .mt(t.z(5.))
            .min_w_0()
            .text_size(t.z(size::SMALL))
            .text_color(t.dim)
            .child(agent_glyph)
            .child(div().flex_none().text_color(t.muted).child(session.short_agent_label()))
            .child(div().flex_1().min_w_0().truncate().child(format!("· {}", meta_parts.join(" · "))));

        // Chips row: [Current worktree] [⎇ main]
        let has_worktree_chip = item.is_current_worktree || item.worktree_label.is_some();
        let chips_row = (has_worktree_chip || item.branch.is_some()).then(|| {
            let mut row = div().flex().flex_row().flex_wrap().items_center().gap(t.z(5.)).mt(t.z(6.));
            if item.is_current_worktree {
                row = row.child(chip(t, "Current worktree", None));
            } else if let Some(label) = &item.worktree_label {
                row = row.child(chip(t, label, Some(IconName::Folder)));
            }
            if let Some(branch) = &item.branch {
                row = row.child(chip(t, branch, Some(IconName::GitBranch)));
            }
            row
        });

        // Inline expanded section: recent messages + quick resume buttons.
        let expanded_section = expanded.then(|| self.render_expanded_details(session, t, cx));

        let click_key = key.clone();
        let dbl_session = session.clone();
        let ctx_session = session.clone();
        let ctx_key = key.clone();

        div()
            .id(SharedString::from(format!("history-card-{key}")))
            .flex()
            .flex_col()
            .w_full()
            .min_w_0()
            .px(t.z(12.))
            .py(t.z(9.))
            .border_b_1()
            .border_color(t.border)
            .cursor_pointer()
            .when_some(fill, |card, fill| card.bg(fill))
            .when(fill.is_none(), |card| card.hover(move |s| s.bg(hover)))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(move |this, _: &MouseDownEvent, window, cx| {
                    window.focus(&this.focus_handle, cx);
                }),
            )
            .on_mouse_down(
                MouseButton::Right,
                cx.listener(move |this, event: &MouseDownEvent, window, cx| {
                    cx.stop_propagation();
                    window.focus(&this.focus_handle, cx);
                    this.selected_key = Some(ctx_key.clone());
                    this.open_session_menu(ctx_session.clone(), event.position, window, cx);
                }),
            )
            .on_click(cx.listener(move |this, event: &ClickEvent, _, cx| {
                this.selected_key = Some(click_key.clone());
                if event.click_count() >= 2 {
                    this.resume_session(&dbl_session, false, false, cx);
                } else {
                    cx.notify();
                }
            }))
            .child(title_row)
            .children(preview_element)
            .child(meta_row)
            .children(chips_row)
            .children(expanded_section)
            .into_any_element()
    }

    fn render_expanded_details(
        &self,
        session: &AgentSessionSummary,
        t: &SopranoTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let key = session.key();
        let s_pane = session.clone();
        let s_tab = session.clone();
        let s_chat = session.clone();
        let copy_cmd = session.resume_command();

        let mut turns = div()
            .flex()
            .flex_col()
            .gap(t.z(5.))
            .p(t.z(8.))
            .mt(t.z(8.))
            .rounded(t.z(7.))
            .bg(t.canvas)
            .border_1()
            .border_color(t.border);

        if session.recent_messages.is_empty() {
            turns = turns.child(
                div().text_size(t.z(size::SMALL)).text_color(t.dim).child("No message preview available."),
            );
        } else {
            for msg in &session.recent_messages {
                let role_label = match msg.role {
                    HistoryMessageRole::User => "You",
                    HistoryMessageRole::Assistant => session.short_agent_label(),
                };
                let role_color = match msg.role {
                    HistoryMessageRole::User => t.accent,
                    HistoryMessageRole::Assistant => t.muted,
                };
                turns = turns.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(t.z(1.))
                        .child(
                            div()
                                .text_size(t.z(size::SMALL))
                                .font_weight(FontWeight::MEDIUM)
                                .text_color(role_color)
                                .child(role_label),
                        )
                        .child(
                            div()
                                .text_size(t.z(size::SMALL))
                                .text_color(t.foreground.opacity(0.88))
                                .line_clamp(3)
                                .child(msg.text.clone()),
                        ),
                );
            }
        }

        let mut actions = div().flex().flex_row().flex_wrap().items_center().gap(t.z(6.)).mt(t.z(7.));
        actions = actions.child(action_pill(
            SharedString::from(format!("history-resume-pane-{key}")),
            t,
            IconName::Play,
            "Resume",
            true,
            cx.listener(move |this, _, _, cx| {
                cx.stop_propagation();
                this.resume_session(&s_pane, false, false, cx);
            }),
        ));
        actions = actions.child(action_pill(
            SharedString::from(format!("history-resume-tab-{key}")),
            t,
            IconName::Plus,
            "New Tab",
            false,
            cx.listener(move |this, _, _, cx| {
                cx.stop_propagation();
                this.resume_session(&s_tab, false, true, cx);
            }),
        ));
        actions = actions.child(action_pill(
            SharedString::from(format!("history-resume-chat-{key}")),
            t,
            IconName::MessageSquare,
            "Chat",
            false,
            cx.listener(move |this, _, _, cx| {
                cx.stop_propagation();
                this.resume_session(&s_chat, true, false, cx);
            }),
        ));
        actions = actions.child(action_pill(
            SharedString::from(format!("history-copy-cmd-{key}")),
            t,
            IconName::Copy,
            "Copy cmd",
            false,
            cx.listener(move |_, _, _, cx| {
                cx.stop_propagation();
                cx.write_to_clipboard(ClipboardItem::new_string(copy_cmd.clone()));
                cx.emit(SidebarEvent::ShowInfo("Copied resume command".into()));
            }),
        ));

        div().flex().flex_col().w_full().child(turns).child(actions).into_any_element()
    }
}

fn chip(t: &SopranoTheme, label: &str, glyph: Option<IconName>) -> impl IntoElement {
    div()
        .flex()
        .items_center()
        .gap(t.z(4.))
        .px(t.z(6.))
        .py(t.z(2.))
        .rounded(t.z(5.))
        .bg(t.raised)
        .border_1()
        .border_color(t.border)
        .text_size(t.z(10.5))
        .text_color(t.muted)
        .children(glyph.map(|name| icon(name).size(10.).color(t.dim)))
        .child(label.to_owned())
}

fn action_pill(
    id: SharedString,
    t: &SopranoTheme,
    glyph: IconName,
    label: &'static str,
    primary: bool,
    on_click: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
) -> impl IntoElement {
    let bg = if primary { t.solid } else { t.raised };
    let fg = if primary { t.solid_foreground } else { t.foreground };
    let hover = if primary { t.solid.opacity(0.88) } else { t.selected };
    div()
        .id(id)
        .flex()
        .items_center()
        .gap(t.z(4.))
        .h(t.z(24.))
        .px(t.z(8.))
        .rounded(t.z(6.))
        .bg(bg)
        .when(!primary, |b| b.border_1().border_color(t.border))
        .text_size(t.z(size::SMALL))
        .font_weight(FontWeight::MEDIUM)
        .text_color(fg)
        .cursor_pointer()
        .hover(move |s| s.bg(hover))
        .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
        .on_click(on_click)
        .child(icon(glyph).size(11.).color(fg))
        .child(label)
}

impl Render for HistoryPanel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.soprano_theme().clone();
        let now = Utc::now();
        let focused = self.focus_handle.is_focused(window);

        let filter_badge = self.agent_filter.map(|format| {
            let hover = t.hover;
            div()
                .id("history-active-agent-filter")
                .flex()
                .items_center()
                .gap(t.z(4.))
                .px(t.z(6.))
                .py(t.z(2.))
                .rounded(t.z(5.))
                .bg(t.selected)
                .text_size(t.z(size::SMALL))
                .text_color(t.foreground)
                .cursor_pointer()
                .hover(move |s| s.bg(hover))
                .on_click(cx.listener(|this, _, _, cx| this.set_agent_filter(None, cx)))
                .child(AgentSessionSummary::full_agent_label(format))
                .child(icon(IconName::X).size(10.).color(t.muted))
        });

        let header = ui::header(&t, "History")
            .child(div().flex_1())
            .children(filter_badge)
            .child(
                IconButton::new("history-filter-agent", IconName::FILTER)
                    .icon_size(14.)
                    .color(if self.agent_filter.is_some() { t.accent } else { t.muted })
                    .tooltip("Filter by Agent")
                    .on_click(cx.listener(|this, event: &ClickEvent, window, cx| {
                        this.open_filter_menu(event.position(), window, cx);
                    })),
            )
            .child(ui::icon_button(
                "history-refresh",
                if self.is_loading { IconName::LoaderCircle } else { IconName::RefreshCw },
                if self.is_loading { "Refreshing History…" } else { "Refresh History" },
                !self.is_loading,
                cx.listener(|this, _, _, cx| this.refresh(cx)),
            ));

        let body: AnyElement = if self.is_loading && !self.has_loaded {
            ui::empty_state(
                &t,
                "Indexing agent sessions…\nReading Claude Code, omp, Codex, OpenCode, and Antigravity history.",
            )
            .into_any_element()
        } else if self.result.groups.is_empty() {
            let msg = if !self.search_query.trim().is_empty() {
                format!(
                    "No matching sessions\nNothing matched \"{}\"{}.",
                    self.search_query.trim(),
                    if self.scope != HistoryScope::All { " in this scope — try All" } else { "" }
                )
            } else if self.scope != HistoryScope::All && self.active_cwd.is_none() {
                "No active folder\nFocus a terminal or switch scope to All.".to_owned()
            } else if self.scope != HistoryScope::All {
                format!(
                    "No sessions in this {}\nSwitch to All to search across every project.",
                    self.scope.label().to_lowercase()
                )
            } else {
                "No agent sessions found\nSessions from Claude Code, omp, Codex, OpenCode, and Antigravity appear here."
                    .to_owned()
            };
            ui::empty_state(&t, &msg).into_any_element()
        } else {
            let groups: Vec<AnyElement> = self
                .result
                .groups
                .iter()
                .map(|group| self.render_group(group, &t, now, focused, cx))
                .collect();
            div()
                .id("history-scroll")
                .flex_1()
                .min_h_0()
                .w_full()
                .overflow_y_scroll()
                .track_scroll(&self.scroll)
                .child(div().flex().flex_col().w_full().children(groups))
                .into_any_element()
        };

        let list_area = div()
            .id("history-list-focus")
            .track_focus(&self.focus_handle)
            .flex()
            .flex_col()
            .flex_1()
            .min_h_0()
            .w_full()
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                this.handle_list_key(event, window, cx);
            }))
            .child(body);

        let menu = self.context_menu.as_ref().map(|(menu, _)| menu.clone());

        ui::card(&t)
            .relative()
            .child(header)
            .child(self.render_scope_bar(&t, cx))
            .child(self.render_search_bar(&t, window, cx))
            .child(self.render_status_strip(&t, now))
            .child(self.render_summary_row(&t, cx))
            .child(list_area)
            .children(menu)
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::fs;

    use gpui::TestAppContext;

    use super::*;

    #[gpui::test]
    fn history_panel_scopes_searches_and_emits_resume_events(cx: &mut TestAppContext) {
        cx.update(soprano_ui::init_for_tests);
        let home = tempfile::tempdir().expect("home");
        let repo = home.path().join("ab_tool");
        fs::create_dir_all(repo.join(".git")).expect("mkdir .git");
        fs::write(repo.join(".git/HEAD"), "ref: refs/heads/main\n").expect("HEAD");

        let other = home.path().join("other_repo");
        fs::create_dir_all(other.join(".git")).expect("mkdir .git");
        fs::write(other.join(".git/HEAD"), "ref: refs/heads/main\n").expect("HEAD");

        let claude_dir = home.path().join(".claude/projects/-ab_tool");
        fs::create_dir_all(&claude_dir).expect("mkdir claude");
        fs::write(
            claude_dir.join("sess-1.jsonl"),
            format!(
                r#"{{"type":"user","uuid":"u1","sessionId":"sess-1","cwd":"{cwd}","timestamp":"2026-11-24T09:00:00.000Z","message":{{"role":"user","content":"Draft shipping protection copy"}}}}
{{"type":"assistant","uuid":"a1","parentUuid":"u1","timestamp":"2026-11-24T09:02:00.000Z","message":{{"role":"assistant","model":"claude-opus-4-6","content":[{{"type":"text","text":"Draft is ready."}}]}}}}
"#,
                cwd = repo.to_string_lossy()
            ),
        )
        .expect("write claude");
        fs::write(
            claude_dir.join("sess-2.jsonl"),
            format!(
                r#"{{"type":"user","uuid":"u1","sessionId":"sess-2","cwd":"{cwd}","timestamp":"2026-11-24T08:00:00.000Z","message":{{"role":"user","content":"Fix billing webhook"}}}}
"#,
                cwd = other.to_string_lossy()
            ),
        )
        .expect("write other");

        let events: Arc<Mutex<Vec<SidebarEvent>>> = Arc::new(Mutex::new(Vec::new()));
        let events_sink = Arc::clone(&events);
        let index = AgentSessionIndex::new(home.path().to_path_buf(), HashMap::new(), None);
        let (panel, cx) = cx.add_window_view(|window, cx| {
            let panel = HistoryPanel::with_index(index, window, cx);
            let sink = Arc::clone(&events_sink);
            cx.subscribe(&cx.entity(), move |_, _, event: &SidebarEvent, _| {
                sink.lock().unwrap().push(event.clone());
            })
            .detach();
            panel
        });

        panel.update(cx, |panel, cx| {
            panel.set_working_directory(Some(&repo.to_string_lossy()), cx);
            panel.set_active(true, cx);
        });
        cx.run_until_parked();

        // Project scope shows only the session in ab_tool.
        panel.read_with(cx, |panel, _| {
            assert_eq!(panel.scope(), HistoryScope::Project);
            assert_eq!(panel.matched_count(), 1);
        });

        // Switching to All shows both sessions.
        panel.update(cx, |panel, cx| panel.set_scope(HistoryScope::All, cx));
        panel.read_with(cx, |panel, _| assert_eq!(panel.matched_count(), 2));

        // Searching filters to the matching session and resuming emits SidebarEvent::ResumeSession.
        panel.update(cx, |panel, cx| {
            panel.set_search_query("shipping".into(), cx);
            panel.resume_selected_or_first(false, false, cx);
        });
        panel.read_with(cx, |panel, _| assert_eq!(panel.matched_count(), 1));

        let emitted = events.lock().unwrap();
        assert!(matches!(
            emitted.as_slice(),
            [SidebarEvent::ResumeSession { profile_id, conversation, chat: false, new_tab: false }]
                if profile_id == "claude-code" && conversation.id == "sess-1"
        ));
    }
}
