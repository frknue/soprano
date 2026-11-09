//! The chat's floating composer (`ChatComposerView.swift`, `ComposerEditor.swift`): the plan,
//! the approval or question the agent waits on, the editor, the model / thinking / permissions
//! chips, the context meter and the round send / stop button; the `/` command menu floats above
//! it.
//!
//! ```text
//! ┌ surface r16 ─────────────────────────────────────────────────────────────┐
//! │ [plan: Plan 2 of 5 done · current step                              ⌄]  │
//! │ [approval: Command approval · detail        Decline  Approve  …]         │
//! │ [question: header chip · question · options]                             │
//! │ Ask anything                                                             │
//! │                     π Claude Opus 5.5 · anthropic  High  🔒 Default ◔ (↑)│
//! └──────────────────────────────────────────────────────────────────────────┘
//! ```

use std::cell::Cell;
use std::collections::HashMap;
use std::rc::Rc;
use std::time::Duration;

use gpui::{
    App, Bounds, Context, Entity, EventEmitter, FocusHandle, Focusable, IntoElement, KeyDownEvent,
    ModifiersChangedEvent, ParentElement, Pixels, Render, Styled, Subscription, Task, Window, canvas, div,
    prelude::*,
};
use gpui_component::input::{
    Enter, Escape, IndentInline, InputEvent, MoveDown, MoveUp, Textarea, TextareaState,
};
use soprano_agents::{ApprovalOptions, UserInputRequest};
use soprano_chat::{AgentChatPermission, AgentChatQuestion, ChatInteraction, ChatPhase};
use soprano_ui::ActiveSopranoTheme;
use soprano_ui::fonts::UI_FONT_FAMILY;

use crate::composer_logic::{
    AnswerDraft, ComposerHistory, ComposerPrimaryAction, ContextMeterReading, MODE_CATEGORY, MODEL_CATEGORY,
    SlashToken, THINKING_CATEGORY, chip_compaction, matching_commands, option_of, placeholder,
};
use crate::keys;
use crate::popovers::{Popover, PopoverKind};
use crate::source::SharedSession;
use crate::timeline_view::CHAT_MAX_WIDTH;
use crate::widgets::text_size;

/// The editor's line height: 14 px with relaxed leading (1.625).
pub const EDITOR_LINE_HEIGHT: f32 = 23.0;
/// The editor grows to this many lines, then scrolls (208 px).
pub const EDITOR_MAX_LINES: usize = 9;

/// What the composer tells the chat.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ComposerEvent {
    /// A message went out (or was queued): the timeline follows its end again.
    Submitted,
    /// The person asked to start the stopped agent again.
    RestartRequested,
    /// The editor took (`true`) or lost the keyboard.
    FocusChanged(bool),
}

/// The `/` menu while it shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SlashMenu {
    pub token: SlashToken,
    pub highlighted: Option<usize>,
}

pub struct ComposerView {
    pub(crate) session: SharedSession,
    pub(crate) agent_name: String,
    pub(crate) editor: Entity<TextareaState>,
    history: ComposerHistory,
    /// Answers drafted per question set.
    answers: HashMap<String, AnswerDraft>,
    /// The question set the editor is answering, if any.
    question_request_id: Option<String>,
    /// The composer's own text while the editor answers a question.
    stashed_text: Option<String>,
    /// Each question set gets its own draft id, so a new one starts over.
    question_count: usize,
    shown_question: Option<AgentChatQuestion>,
    auto_advance: Option<Task<()>>,
    pub(crate) plan_expanded: bool,
    alternate_held: bool,
    pub(crate) popover: Option<Popover>,
    /// The approval panel's "More" menu.
    pub(crate) more_menu: Option<(Entity<soprano_ui::menu::ContextMenu>, Subscription)>,
    pub(crate) slash: Option<SlashMenu>,
    /// Escape (or text the composer set) hid the menu until the caret leaves the token.
    slash_dismissed: bool,
    /// The editor's text was set by the composer, not typed.
    setting_text: bool,
    /// Where the chips and the meter sit, for the popovers they open.
    pub(crate) anchors: Rc<Anchors>,
    width: f32,
    _subscriptions: Vec<Subscription>,
}

/// Bounds of the footer controls in the last frame.
#[derive(Default)]
pub(crate) struct Anchors {
    pub surface: Cell<Bounds<Pixels>>,
    pub model: Cell<Bounds<Pixels>>,
    pub traits: Cell<Bounds<Pixels>>,
    pub permissions: Cell<Bounds<Pixels>>,
    pub meter: Cell<Bounds<Pixels>>,
}

impl EventEmitter<ComposerEvent> for ComposerView {}

impl Focusable for ComposerView {
    fn focus_handle(&self, cx: &App) -> FocusHandle {
        self.editor.focus_handle(cx)
    }
}

impl ComposerView {
    pub fn new(
        session: SharedSession,
        agent_name: impl Into<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let agent_name = agent_name.into();
        let editor = cx.new(|cx| {
            TextareaState::new(window, cx).auto_grow(2, EDITOR_MAX_LINES).placeholder("Ask anything")
        });
        let subscription =
            cx.subscribe_in(&editor, window, |this, _, event: &InputEvent, window, cx| match event {
                InputEvent::Change => this.text_changed(window, cx),
                InputEvent::Focus => cx.emit(ComposerEvent::FocusChanged(true)),
                InputEvent::Blur => {
                    this.slash = None;
                    cx.emit(ComposerEvent::FocusChanged(false));
                    cx.notify();
                }
                InputEvent::PressEnter { .. } => {}
            });
        let mut view = Self {
            session,
            agent_name,
            editor,
            history: ComposerHistory::default(),
            answers: HashMap::new(),
            question_request_id: None,
            stashed_text: None,
            question_count: 0,
            shown_question: None,
            auto_advance: None,
            plan_expanded: false,
            alternate_held: false,
            popover: None,
            more_menu: None,
            slash: None,
            slash_dismissed: false,
            setting_text: false,
            anchors: Rc::new(Anchors::default()),
            width: CHAT_MAX_WIDTH,
            _subscriptions: vec![subscription],
        };
        view.refresh(window, cx);
        view
    }

    /// Ends what floats above the composer (the tab is closing).
    pub fn close(&mut self, cx: &mut Context<Self>) {
        self.popover = None;
        self.slash = None;
        self.auto_advance = None;
        cx.notify();
    }

    pub fn focus_editor(&self, window: &mut Window, cx: &mut App) {
        self.editor.update(cx, |editor, cx| editor.focus(window, cx));
    }

    pub fn text(&self, cx: &App) -> String {
        self.editor.read(cx).value().to_string()
    }

    /// Replaces the editor's text, the caret at its end. Text the composer sets never opens the
    /// `/` menu.
    pub fn set_text(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.setting_text = true;
        self.editor.update(cx, |editor, cx| {
            editor.set_value(text.to_owned(), window, cx);
            editor.set_selected_range(text.len()..text.len(), cx);
        });
        self.text_changed(window, cx);
        self.setting_text = false;
    }

    // MARK: Reading

    fn permission(&self) -> Option<AgentChatPermission> {
        match self.session.borrow().interaction() {
            Some(ChatInteraction::Permission(permission)) => Some(permission.clone()),
            _ => None,
        }
    }

    fn question(&self) -> Option<AgentChatQuestion> {
        match self.session.borrow().interaction() {
            Some(ChatInteraction::Question(question)) => Some(question.clone()),
            _ => None,
        }
    }

    /// The question set as the composer asks it.
    pub(crate) fn pending_input(&self) -> Option<UserInputRequest> {
        self.question().map(|q| q.user_input_request(&format!("question-{}", self.question_count)))
    }

    /// The draft of the question set the editor answers.
    pub(crate) fn draft(&self) -> Option<(UserInputRequest, AnswerDraft)> {
        let request = self.pending_input()?;
        if self.question_request_id.as_deref() != Some(request.id.as_str()) {
            return None;
        }
        let draft = self.answers.get(&request.id)?.clone();
        Some((request, draft))
    }

    fn has_content(&self, cx: &App) -> bool {
        !self.text(cx).trim().is_empty()
    }

    fn is_stopped(&self) -> bool {
        matches!(self.session.borrow().phase(), ChatPhase::Stopped(_))
    }

    fn is_working(&self) -> bool {
        *self.session.borrow().phase() == ChatPhase::Working
    }

    /// Stop was pressed and the agent has not ended the turn yet.
    pub(crate) fn is_stopping(&self) -> bool {
        self.session.borrow().thread().active_turn().is_some_and(|t| t.stop_requested_at.is_some())
    }

    /// What the round button does now.
    pub(crate) fn primary_action(&self, cx: &App) -> ComposerPrimaryAction {
        let session = self.session.borrow();
        ComposerPrimaryAction::resolve(
            matches!(session.phase(), ChatPhase::Stopped(_)),
            *session.phase() == ChatPhase::Working,
            self.has_content(cx),
            matches!(session.interaction(), Some(ChatInteraction::Permission(_))),
            session.supports_steering(),
            self.alternate_held,
        )
    }

    pub(crate) fn context_reading(&self) -> Option<ContextMeterReading> {
        ContextMeterReading::new(self.session.borrow().context_usage())
    }

    pub(crate) fn chip_compaction(&self) -> u8 {
        chip_compaction(self.width)
    }

    // MARK: Refresh

    /// Re-reads the session.
    pub fn refresh(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.history.position().is_none() {
            self.history = ComposerHistory::new(ComposerHistory::entries_of(&self.session.borrow().thread()));
        }
        self.update_question(window, cx);
        let question = self.draft().and_then(|(request, draft)| draft.current_question(&request).cloned());
        let text =
            placeholder(question.as_ref(), self.is_stopped(), self.permission().is_some(), &self.agent_name);
        self.editor.update(cx, |editor, cx| editor.set_placeholder(text, window, cx));
        if self.permission().is_some() || self.question_request_id.is_some() {
            self.slash = None;
        }
        cx.notify();
    }

    /// Enters, follows or leaves question mode as the agent's questions come and go.
    fn update_question(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(question) = self.question() else {
            self.shown_question = None;
            if self.question_request_id.take().is_some() {
                let stashed = self.stashed_text.take().unwrap_or_default();
                self.set_text(&stashed, window, cx);
            }
            return;
        };
        if self.shown_question.as_ref() != Some(&question) {
            self.shown_question = Some(question);
            self.question_count += 1;
        }
        let Some(request) = self.pending_input() else { return };
        if self.question_request_id.as_deref() != Some(request.id.as_str()) {
            if self.question_request_id.is_none() {
                self.stashed_text = Some(self.text(cx));
            }
            self.question_request_id = Some(request.id.clone());
            let draft = self.answers.entry(request.id.clone()).or_default().clone();
            let custom = draft
                .current_question(&request)
                .and_then(|q| draft.custom.get(&q.id).cloned())
                .unwrap_or_default();
            self.set_text(&custom, window, cx);
        }
    }

    // MARK: Editing

    fn text_changed(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let text = self.text(cx);
        if let Some(current) = self.history.current()
            && text != current
        {
            self.history.reset();
        }
        if let Some((request, mut draft)) = self.draft()
            && let Some(question) = draft.current_question(&request)
        {
            draft.custom.insert(question.id.clone(), text);
            self.answers.insert(request.id.clone(), draft);
        }
        if self.setting_text {
            self.slash_dismissed = true;
        }
        self.sync_slash_menu(window, cx);
        cx.notify();
    }

    /// Opens, filters or closes the `/` menu for the token at the caret.
    pub(crate) fn sync_slash_menu(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let (text, selection) = {
            let editor = self.editor.read(cx);
            (editor.value().to_string(), editor.selected_range())
        };
        let token =
            (self.question_request_id.is_none() && self.permission().is_none() && selection.is_empty())
                .then(|| SlashToken::at(&text, selection.start))
                .flatten();
        let Some(token) = token else {
            self.slash_dismissed = false;
            self.slash = None;
            return;
        };
        let focused = self.editor.focus_handle(cx).is_focused(window);
        if self.slash_dismissed || !focused {
            self.slash = None;
            return;
        }
        if self.slash.as_ref().is_some_and(|menu| menu.token == token) {
            return;
        }
        self.popover = None;
        let has_matches = !matching_commands(self.session.borrow().commands(), &token.query).is_empty();
        self.slash = Some(SlashMenu { token, highlighted: has_matches.then_some(0) });
    }

    /// Replaces the typed token with the command's text, keeping what follows it.
    pub(crate) fn insert_command(&mut self, insert_text: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(menu) = self.slash.take() else { return };
        let text = self.text(cx);
        let (range, insert) = menu.token.replacement(insert_text, &text);
        let mut edited = String::with_capacity(text.len() + insert.len());
        edited.push_str(&text[..range.start]);
        edited.push_str(&insert);
        edited.push_str(&text[range.end.min(text.len())..]);
        let caret = range.start + insert.len();
        self.editor.update(cx, |editor, cx| {
            editor.set_value(edited, window, cx);
            editor.set_selected_range(caret..caret, cx);
        });
        self.slash_dismissed = true;
        self.focus_editor(window, cx);
        cx.notify();
    }

    /// Escape, or Return/Tab with nothing to pick: hide the menu until the caret leaves the token.
    pub(crate) fn dismiss_slash_menu(&mut self, cx: &mut Context<Self>) {
        self.slash_dismissed = true;
        self.slash = None;
        cx.notify();
    }

    fn recall_history(&mut self, up: bool, window: &mut Window, cx: &mut Context<Self>) -> bool {
        if self.question_request_id.is_some() {
            return false;
        }
        let text = self.text(cx);
        if up {
            if !(text.is_empty() || Some(text.as_str()) == self.history.current()) {
                return false;
            }
            return match self.history.older() {
                Some(entry) => {
                    self.set_text(&entry, window, cx);
                    true
                }
                None => self.history.position().is_some(),
            };
        }
        if self.history.position().is_none() || Some(text.as_str()) != self.history.current() {
            return false;
        }
        match self.history.newer() {
            Some(entry) => {
                self.set_text(&entry, window, cx);
                true
            }
            None => false,
        }
    }

    // MARK: Sending

    pub(crate) fn primary_clicked(&mut self, alternate: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.primary_action(cx) == ComposerPrimaryAction::Stop {
            self.session.borrow_mut().cancel();
            cx.notify();
            return;
        }
        self.submit(alternate, window, cx);
    }

    /// Return / the send button. `alternate` (⌘) steers instead of queueing while a turn runs.
    pub fn submit(&mut self, alternate: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.is_stopped() {
            cx.emit(ComposerEvent::RestartRequested);
            return;
        }
        if self.question_request_id.is_some() {
            self.advance_question(window, cx);
            return;
        }
        let text = self.text(cx).trim().to_owned();
        if text.is_empty() {
            return;
        }
        let sent = {
            let permission = self.permission();
            let mut session = self.session.borrow_mut();
            if let Some(decline) = permission.as_ref().and_then(|p| p.options.decline_option().cloned()) {
                // Decline, then deliver the message: it redirects the turn the agent continues.
                session.choose_permission_option(&decline.id);
                session.steer(&text)
            } else if alternate && *session.phase() == ChatPhase::Working {
                session.steer(&text)
            } else {
                session.send(&text)
            }
        };
        if !sent {
            return;
        }
        self.set_text("", window, cx);
        self.history.reset();
        cx.emit(ComposerEvent::Submitted);
        cx.notify();
    }

    /// Escape: closes the `/` menu or a popover, else stops the running turn.
    pub(crate) fn escape(&mut self, cx: &mut Context<Self>) -> bool {
        if self.slash.is_some() {
            self.dismiss_slash_menu(cx);
            return true;
        }
        if self.popover.is_some() {
            self.close_popover(cx);
            return true;
        }
        if !self.is_working() {
            return false;
        }
        self.session.borrow_mut().cancel();
        cx.notify();
        true
    }

    // MARK: Questions

    pub(crate) fn toggle_option(&mut self, option_index: usize, window: &mut Window, cx: &mut Context<Self>) {
        let Some((request, mut draft)) = self.draft() else { return };
        let Some(moves_on) = draft.toggle_option(option_index, &request) else { return };
        self.answers.insert(request.id.clone(), draft);
        self.set_text("", window, cx);
        self.refresh(window, cx);
        if !moves_on {
            return;
        }
        let request_id = request.id.clone();
        self.auto_advance = Some(cx.spawn_in(window, async move |this, cx| {
            cx.background_executor().timer(Duration::from_millis(200)).await;
            this.update_in(cx, |this, window, cx| {
                // A later question set keeps its own question.
                if this.pending_input().map(|r| r.id) == Some(request_id) {
                    this.advance_question(window, cx);
                }
            })
            .ok();
        }));
    }

    fn move_question(&mut self, delta: isize, window: &mut Window, cx: &mut Context<Self>) {
        let Some((request, mut draft)) = self.draft() else { return };
        let Some(next) = draft.index.checked_add_signed(delta).filter(|n| *n < request.questions.len())
        else {
            return;
        };
        if let Some(question) = draft.current_question(&request) {
            draft.custom.insert(question.id.clone(), self.text(cx));
        }
        draft.index = next;
        let custom = draft.custom.get(&request.questions[next].id).cloned().unwrap_or_default();
        self.answers.insert(request.id.clone(), draft);
        self.set_text(&custom, window, cx);
        self.refresh(window, cx);
    }

    pub(crate) fn previous_question(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.auto_advance = None;
        self.move_question(-1, window, cx);
    }

    /// "Next question", or "Submit answers" on the last one.
    pub(crate) fn advance_question(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.auto_advance = None;
        let (Some(question), Some((request, draft))) = (self.question(), self.draft()) else { return };
        if !draft.is_last(&request) {
            if !draft.answer(draft.index, &request).is_empty() {
                self.move_question(1, window, cx);
            }
            return;
        }
        if !draft.is_complete(&request) {
            return;
        }
        let content = question.content(&draft.result(&request));
        self.session.borrow_mut().answer_question(content);
        self.refresh(window, cx);
    }

    pub(crate) fn decline_question(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.session.borrow_mut().decline_question();
        self.refresh(window, cx);
    }

    pub(crate) fn choose_permission(&mut self, option_id: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.session.borrow_mut().choose_permission_option(option_id);
        self.refresh(window, cx);
    }

    // MARK: Settings

    pub(crate) fn toggle_popover(&mut self, kind: PopoverKind, window: &mut Window, cx: &mut Context<Self>) {
        if self.popover.as_ref().is_some_and(|p| p.kind == kind) {
            self.close_popover(cx);
            return;
        }
        // Settings change only while the agent runs; the context card always opens.
        if kind != PopoverKind::Context && !self.session.borrow().is_running() {
            return;
        }
        let category = match kind {
            PopoverKind::Model => Some(MODEL_CATEGORY),
            PopoverKind::Traits => Some(THINKING_CATEGORY),
            PopoverKind::Permissions => Some(MODE_CATEGORY),
            PopoverKind::Context => None,
        };
        if let Some(category) = category
            && option_of(self.session.borrow().config_options(), category).is_none()
        {
            return;
        }
        self.slash = None;
        self.popover = Some(Popover::new(kind, self, window, cx));
        cx.notify();
    }

    pub(crate) fn close_popover(&mut self, cx: &mut Context<Self>) {
        if self.popover.take().is_some() {
            cx.notify();
        }
    }

    /// Sets one of the agent's settings and closes its menu.
    pub(crate) fn set_option(&mut self, id: &str, value: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.session.borrow_mut().set_config_option(id, value);
        self.popover = None;
        self.focus_editor(window, cx);
        cx.notify();
    }

    pub(crate) fn compact(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.session.borrow_mut().compact();
        self.popover = None;
        self.focus_editor(window, cx);
        cx.emit(ComposerEvent::Submitted);
        cx.notify();
    }

    // MARK: Keys

    fn on_enter(&mut self, action: &Enter, window: &mut Window, cx: &mut Context<Self>) {
        if action.shift {
            // ⇧Return adds a newline.
            return;
        }
        cx.stop_propagation();
        if !action.secondary && self.slash.is_some() {
            if !self.choose_highlighted_command(window, cx) {
                self.dismiss_slash_menu(cx);
            }
            return;
        }
        self.submit(action.secondary, window, cx);
    }

    fn on_tab(&mut self, _: &IndentInline, window: &mut Window, cx: &mut Context<Self>) {
        if self.slash.is_none() {
            return;
        }
        cx.stop_propagation();
        if !self.choose_highlighted_command(window, cx) {
            self.dismiss_slash_menu(cx);
        }
    }

    fn on_move(&mut self, up: bool, window: &mut Window, cx: &mut Context<Self>) {
        if self.slash.is_some() {
            self.move_slash_highlight(if up { -1 } else { 1 }, cx);
            cx.stop_propagation();
            return;
        }
        if self.recall_history(up, window, cx) {
            cx.stop_propagation();
        }
    }

    fn on_escape(&mut self, _: &Escape, _window: &mut Window, cx: &mut Context<Self>) {
        if self.escape(cx) {
            cx.stop_propagation();
        }
    }

    /// ⌘Return off the Mac (Ctrl+Shift+Enter) and digits picking a question's options.
    fn on_key_down(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let keystroke = &event.keystroke;
        if keystroke.key == "enter" && keys::is_command(&keystroke.modifiers) {
            cx.stop_propagation();
            self.submit(true, window, cx);
            return;
        }
        if self.question_request_id.is_none()
            || !self.text(cx).is_empty()
            || !keys::is_plain(&keystroke.modifiers)
        {
            return;
        }
        if let Ok(digit) = keystroke.key.parse::<usize>()
            && (1..=9).contains(&digit)
        {
            cx.stop_propagation();
            self.toggle_option(digit - 1, window, cx);
        }
    }

    fn modifiers_changed(&mut self, event: &ModifiersChangedEvent, _: &mut Window, cx: &mut Context<Self>) {
        let held = keys::holds_command(&event.modifiers);
        if held != self.alternate_held {
            self.alternate_held = held;
            cx.notify();
        }
    }

    pub(crate) fn shown_commands(&self) -> Vec<soprano_chat::AgentChatCommand> {
        match &self.slash {
            Some(menu) => matching_commands(self.session.borrow().commands(), &menu.token.query),
            None => Vec::new(),
        }
    }

    pub(crate) fn move_slash_highlight(&mut self, delta: isize, cx: &mut Context<Self>) {
        let count = self.shown_commands().len();
        if let Some(menu) = self.slash.as_mut()
            && count > 0
        {
            let current =
                menu.highlighted.map_or(if delta > 0 { -1 } else { count as isize }, |h| h as isize);
            menu.highlighted = Some((current + delta).clamp(0, count as isize - 1) as usize);
            cx.notify();
        }
    }

    /// Picks the highlighted command; false when nothing is highlighted.
    pub(crate) fn choose_highlighted_command(&mut self, window: &mut Window, cx: &mut Context<Self>) -> bool {
        let commands = self.shown_commands();
        let Some(command) = self.slash.as_ref().and_then(|m| m.highlighted).and_then(|h| commands.get(h))
        else {
            return false;
        };
        let insert = command.insert_text();
        self.insert_command(&insert, window, cx);
        true
    }
}

impl Render for ComposerView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.sync_slash_menu(window, cx);
        let t = cx.soprano_theme().clone();
        let has_panel = self.permission().is_some() || self.question_request_id.is_some();
        let anchors = self.anchors.clone();
        let editor = Textarea::new(&self.editor).appearance(false).bordered(false);
        div()
            .id("chat-composer")
            .key_context("ChatComposer")
            .relative()
            .w_full()
            .on_modifiers_changed(cx.listener(Self::modifiers_changed))
            .child(
                canvas(move |bounds, _, _| anchors.surface.set(bounds), |_, _, _, _| {})
                    .absolute()
                    .size_full(),
            )
            .child(
                div()
                    .w_full()
                    .rounded(t.z(16.0))
                    .border_1()
                    .border_color(t.foreground.opacity(if t.is_dark() { 0.05 } else { 0.08 }))
                    .bg(t.popover.opacity(0.92))
                    .when(!t.is_dark(), |surface| surface.shadow_sm())
                    .flex()
                    .flex_col()
                    .overflow_hidden()
                    .children(self.render_plan(cx))
                    .children(self.render_approval(cx))
                    .children(self.render_question(cx))
                    .child(
                        div()
                            .px(t.z(16.0))
                            .pt(t.z(if has_panel { 10.0 } else { 16.0 }))
                            .pb(t.z(8.0))
                            .font_family(UI_FONT_FAMILY)
                            .text_size(t.z(text_size::BODY))
                            .line_height(t.z(EDITOR_LINE_HEIGHT))
                            .text_color(t.foreground)
                            .capture_action(cx.listener(Self::on_enter))
                            .capture_action(cx.listener(Self::on_tab))
                            .capture_action(
                                cx.listener(|this, _: &MoveUp, window, cx| this.on_move(true, window, cx)),
                            )
                            .capture_action(
                                cx.listener(|this, _: &MoveDown, window, cx| this.on_move(false, window, cx)),
                            )
                            .capture_action(cx.listener(Self::on_escape))
                            .capture_key_down(cx.listener(Self::on_key_down))
                            .child(editor),
                    )
                    .child(self.render_footer(window, cx)),
            )
            .children(self.render_slash_menu(cx))
            .children(self.render_popover(window, cx))
    }
}

impl ComposerView {
    /// Lays the composer out for `width` (the chips give way in a narrow composer).
    pub(crate) fn set_width(&mut self, width: f32) {
        self.width = width;
    }
}
