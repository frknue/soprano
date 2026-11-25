//! A chat tab (`AgentChatPaneView.swift`): the conversation with an agent — the timeline of
//! turns in the centered lane and the floating composer over its end — instead of the agent's
//! terminal. Holds the tab's [`AgentChatSession`], so the agent runs as long as the view does.
//!
//! ```text
//! ┌ timeline (lane ≤ 736, centered) ───────────────────────────┐
//! │                         user bubble right (≤ 80%, r16)     │
//! │ Worked for 3m 12s ⌄                                        │
//! │ assistant markdown 14/1.625                                │
//! │ N changed files card                                       │
//! │      ┌ composer r16 (≤ 736, 20 above the bottom) ┐         │
//! └──────┴───────────────────────────────────────────┴─────────┘
//! ```

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Duration;

use futures::StreamExt;
use futures::channel::mpsc;
use gpui::{
    App, Bounds, ClickEvent, Context, Entity, EventEmitter, FocusHandle, Focusable, IntoElement,
    KeyDownEvent, MouseButton, ParentElement, Pixels, Render, Styled, Subscription, Task, Window, canvas,
    div, prelude::*,
};
use gpui_component::input::{self as component_input, Input, InputEvent, InputState};
use soprano_chat::{AgentChatEvent, AgentChatSession, ChatPhase};
use soprano_ui::button::{IconButton, IconButtonSize};
use soprano_ui::fonts::UI_FONT_FAMILY;
use soprano_ui::{ActiveSopranoTheme, IconName, SopranoTheme, icon};

use crate::composer::{ComposerEvent, ComposerView};
use crate::keys;
use crate::source::{SessionSource, SharedSession};
use crate::timeline_view::{CHAT_MAX_WIDTH, TimelineView, gutter};
use crate::widgets::text_size;

/// Delay that batches streamed chunks into one redraw.
const RENDER_DELAY: Duration = Duration::from_millis(50);

/// What the chat tells the tab that hosts it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChatViewEvent {
    /// The session's status, conversation and title, for the tab's agent (the host turns them
    /// into the workspace's agent status, conversation record and tab title).
    Agent(AgentChatEvent),
    /// The person works in the chat: activate its pane tab (and clear its attention).
    FocusRequested,
    /// Restart the agent through the tab, so its status starts over too.
    RestartRequested,
}

pub struct ChatView {
    session: SharedSession,
    timeline: Entity<TimelineView>,
    composer: Entity<ComposerView>,
    find_input: Entity<InputState>,
    find_open: bool,
    focus_handle: FocusHandle,
    /// What the session reported, emitted once the session is no longer borrowed.
    reported: Rc<RefCell<Vec<AgentChatEvent>>>,
    render_scheduled: Option<Task<()>>,
    bounds: Rc<Cell<Bounds<Pixels>>>,
    _pump: Task<()>,
    _subscriptions: Vec<Subscription>,
}

impl EventEmitter<ChatViewEvent> for ChatView {}

impl Focusable for ChatView {
    fn focus_handle(&self, cx: &App) -> FocusHandle {
        self.composer.focus_handle(cx)
    }
}

impl ChatView {
    /// The chat over `session`. It installs the session's change, event and waker callbacks
    /// (its events come out as [`ChatViewEvent::Agent`]); start the agent with
    /// [`start`](Self::start) unless the tab was stopped.
    pub fn new(
        session: AgentChatSession,
        agent_name: impl Into<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let agent_name = agent_name.into();
        let session: SharedSession = Rc::new(RefCell::new(session));
        let reported = Rc::new(RefCell::new(Vec::new()));
        let (wake, mut woken) = mpsc::unbounded::<()>();
        {
            let mut session = session.borrow_mut();
            let on_change = wake.clone();
            session.set_on_change(move || {
                on_change.unbounded_send(()).ok();
            });
            let on_event = wake.clone();
            let events = reported.clone();
            session.set_on_event(move |event| {
                events.borrow_mut().push(event.clone());
                on_event.unbounded_send(()).ok();
            });
            let waker = wake.clone();
            session.set_waker(move || {
                waker.unbounded_send(()).ok();
            });
        }
        let source = Rc::new(SessionSource(session.clone()));
        let timeline = cx.new(|cx| TimelineView::new(source, agent_name.clone(), window, cx));
        let composer = cx.new(|cx| ComposerView::new(session.clone(), agent_name, window, cx));
        let find_input = cx.new(|cx| InputState::new(window, cx).placeholder("Find in chat…"));
        let pump = cx.spawn_in(window, async move |this, cx| {
            while woken.next().await.is_some() {
                while woken.try_recv().is_ok() {}
                if this.update_in(cx, |this, window, cx| this.pump(window, cx)).is_err() {
                    break;
                }
            }
        });
        let subscriptions = vec![
            cx.subscribe_in(&composer, window, |this, _, event: &ComposerEvent, _window, cx| match event {
                ComposerEvent::Submitted => {
                    this.timeline.update(cx, |timeline, cx| timeline.jump_to_latest(cx))
                }
                ComposerEvent::RestartRequested => {
                    cx.emit(ChatViewEvent::FocusRequested);
                    cx.emit(ChatViewEvent::RestartRequested);
                }
                ComposerEvent::FocusChanged(true) => cx.emit(ChatViewEvent::FocusRequested),
                ComposerEvent::FocusChanged(false) => {}
            }),
            cx.subscribe_in(
                &find_input,
                window,
                |this, input, event: &InputEvent, _window, cx| match event {
                    InputEvent::Change => {
                        let query = input.read(cx).value().to_string();
                        this.timeline.update(cx, |timeline, cx| timeline.set_find_query(&query, cx));
                        cx.notify();
                    }
                    InputEvent::PressEnter { secondary, shift } => {
                        this.timeline
                            .update(cx, |timeline, cx| timeline.find_step(!*shift && !*secondary, cx));
                        cx.notify();
                    }
                    _ => {}
                },
            ),
            cx.observe_global::<SopranoTheme>(|_, cx| cx.notify()),
        ];
        Self {
            session,
            timeline,
            composer,
            find_input,
            find_open: false,
            focus_handle: cx.focus_handle(),
            reported,
            render_scheduled: None,
            bounds: Rc::new(Cell::new(Bounds::default())),
            _pump: pump,
            _subscriptions: subscriptions,
        }
    }

    /// The tab's session (the host reads its conversation and phase).
    pub fn session(&self) -> SharedSession {
        self.session.clone()
    }

    pub fn timeline(&self) -> &Entity<TimelineView> {
        &self.timeline
    }

    pub fn composer(&self) -> &Entity<ComposerView> {
        &self.composer
    }

    /// Starts the agent on `resuming` (the tab's conversation), else a new conversation.
    pub fn start(&mut self, resuming: Option<&str>, window: &mut Window, cx: &mut Context<Self>) {
        self.session.borrow_mut().start(resuming);
        self.render_now(window, cx);
    }

    /// Ends the agent's process; the chat stays, stopped.
    pub fn stop(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.session.borrow_mut().stop();
        self.render_now(window, cx);
    }

    /// Starts the agent again on its conversation, or on `fallback` when it never opened one.
    pub fn restart(&mut self, fallback: Option<&str>, window: &mut Window, cx: &mut Context<Self>) {
        self.session.borrow_mut().restart(fallback);
        self.render_now(window, cx);
    }

    /// Sends a prompt from outside the chat (the dashboard's reply): queued while a turn runs.
    pub fn submit_prompt(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) -> bool {
        let sent = self.session.borrow_mut().send(text);
        if sent {
            self.timeline.update(cx, |timeline, cx| timeline.jump_to_latest(cx));
        }
        self.render_now(window, cx);
        sent
    }

    /// Starts the conversation of a new thread: `options` (option id, value) are set once it
    /// is open, then `text` goes out as its first message.
    pub fn submit_opening(
        &mut self,
        options: Vec<(String, String)>,
        text: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        self.session.borrow_mut().set_opening_options(options);
        self.submit_prompt(text, window, cx)
    }

    /// Changes one of the agent's session settings from outside the chat (the dashboard's
    /// model and thinking chips).
    pub fn set_option(&mut self, id: &str, value: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.session.borrow_mut().set_config_option(id, value);
        self.render_now(window, cx);
    }

    /// Ends the agent when the tab goes away.
    pub fn close(&mut self, cx: &mut Context<Self>) {
        self.timeline.update(cx, |timeline, _| timeline.close());
        self.composer.update(cx, |composer, cx| composer.close(cx));
        {
            let mut session = self.session.borrow_mut();
            session.set_on_change(|| {});
            session.set_on_event(|_| {});
            session.stop();
        }
        self.reported.borrow_mut().clear();
        self.render_scheduled = None;
    }

    /// Whether the keyboard is anywhere in the chat: the composer, one of its popovers, or
    /// the conversation. [`Focusable::focus_handle`] is only where it goes when the chat gets
    /// it.
    pub fn contains_focused(&self, window: &Window, cx: &App) -> bool {
        self.focus_handle.contains_focused(window, cx)
    }

    /// Gives the composer the keyboard.
    pub fn focus_composer(&self, window: &mut Window, cx: &mut App) {
        let editor = self.composer.read(cx).editor.clone();
        editor.update(cx, |editor, cx| editor.focus(window, cx));
    }

    /// Opens the Find-in-Chat bar and focuses its search input.
    pub fn open_find(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.find_open = true;
        let query = self.find_input.read(cx).value().to_string();
        if !query.is_empty() {
            self.timeline.update(cx, |timeline, cx| timeline.set_find_query(&query, cx));
        }
        self.find_input.update(cx, |input, cx| input.focus(window, cx));
        cx.notify();
    }

    /// Closes the Find-in-Chat bar, clears match highlights, and returns focus to the composer.
    pub fn close_find(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.find_open {
            return;
        }
        self.find_open = false;
        self.timeline.update(cx, |timeline, cx| timeline.clear_find(cx));
        self.focus_composer(window, cx);
        cx.notify();
    }

    pub fn is_find_open(&self) -> bool {
        self.find_open
    }

    pub fn find_next(&mut self, cx: &mut Context<Self>) {
        self.timeline.update(cx, |timeline, cx| timeline.find_step(true, cx));
        cx.notify();
    }

    pub fn find_prev(&mut self, cx: &mut Context<Self>) {
        self.timeline.update(cx, |timeline, cx| timeline.find_step(false, cx));
        cx.notify();
    }

    /// Applies what the agent said and batches the redraw.
    fn pump(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.session.borrow_mut().process_events();
        self.flush_events(cx);
        if self.render_scheduled.is_some() {
            return;
        }
        self.render_scheduled = Some(cx.spawn_in(window, async move |this, cx| {
            cx.background_executor().timer(RENDER_DELAY).await;
            this.update_in(cx, |this, window, cx| {
                this.render_scheduled = None;
                this.render_now(window, cx);
            })
            .ok();
        }));
    }

    fn flush_events(&mut self, cx: &mut Context<Self>) {
        let events = std::mem::take(&mut *self.reported.borrow_mut());
        for event in events {
            cx.emit(ChatViewEvent::Agent(event));
        }
    }

    fn render_now(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.flush_events(cx);
        self.timeline.update(cx, |timeline, cx| timeline.reload(false, cx));
        self.composer.update(cx, |composer, cx| composer.refresh(window, cx));
        cx.notify();
    }

    /// Handles find shortcuts (⌘F / ⌘G / ⇧⌘G), Escape to close find or cancel a running turn,
    /// and forwards plain keys typed in the timeline to the composer.
    fn key_down(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let keystroke = &event.keystroke;
        let cmd = if cfg!(target_os = "macos") {
            keystroke.modifiers.platform && !keystroke.modifiers.control && !keystroke.modifiers.alt
        } else {
            keystroke.modifiers.control && keystroke.modifiers.shift && !keystroke.modifiers.alt
        };
        if cmd && !keystroke.modifiers.shift && keystroke.key == "f" {
            self.open_find(window, cx);
            cx.stop_propagation();
            return;
        }
        if self.find_open && cmd && keystroke.key == "g" {
            if keystroke.modifiers.shift {
                self.find_prev(cx);
            } else {
                self.find_next(cx);
            }
            cx.stop_propagation();
            return;
        }
        if self.find_open && keystroke.key == "escape" && !keystroke.modifiers.modified() {
            self.close_find(window, cx);
            cx.stop_propagation();
            return;
        }
        if !self.timeline.focus_handle(cx).contains_focused(window, cx) {
            return;
        }
        if keystroke.key == "escape" && *self.session.borrow().phase() == ChatPhase::Working {
            self.session.borrow_mut().cancel();
            self.render_now(window, cx);
            cx.stop_propagation();
            return;
        }
        let Some(typed) =
            keystroke.key_char.clone().filter(|c| !c.is_empty() && !c.chars().any(char::is_control))
        else {
            return;
        };
        if !keys::is_plain(&keystroke.modifiers) {
            return;
        }
        cx.stop_propagation();
        let editor = self.composer.read(cx).editor.clone();
        editor.update(cx, |editor, cx| {
            editor.focus(window, cx);
            editor.insert(typed, window, cx);
        });
    }

    fn render_find_bar(&self, t: &SopranoTheme, cx: &mut Context<Self>) -> impl IntoElement {
        let (current, total) = self.timeline.read(cx).find_summary();
        let has_query = !self.find_input.read(cx).value().trim().is_empty();
        let count_text = if !has_query {
            String::new()
        } else if total == 0 {
            "No matches".to_owned()
        } else {
            format!("{current} / {total}")
        };
        let fill = if t.is_dark() { t.popover } else { t.background };
        div()
            .id("agent-chat-find-bar")
            .absolute()
            .top(t.z(10.0))
            .right(t.z(12.0))
            .w(t.z(310.0))
            .h(t.z(34.0))
            .px(t.z(8.0))
            .flex()
            .flex_row()
            .items_center()
            .gap(t.z(6.0))
            .rounded(t.z(8.0))
            .border_1()
            .border_color(t.border)
            .bg(fill)
            .shadow_md()
            .block_mouse_except_scroll()
            .capture_action(cx.listener(|this, _: &component_input::Escape, window, cx| {
                cx.stop_propagation();
                this.close_find(window, cx);
            }))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|_, _, _, cx| cx.emit(ChatViewEvent::FocusRequested)),
            )
            .child(icon(IconName::Search).size(13.0).color(t.muted))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .child(Input::new(&self.find_input).appearance(false).cleanable(false)),
            )
            .when(!count_text.is_empty(), |bar| {
                bar.child(
                    div()
                        .flex_none()
                        .font_family(UI_FONT_FAMILY)
                        .text_size(t.z(text_size::SMALL))
                        .text_color(if total == 0 { t.failed } else { t.muted })
                        .whitespace_nowrap()
                        .child(count_text),
                )
            })
            .child(
                IconButton::new("chat-find-prev", IconName::ChevronUp)
                    .size(IconButtonSize::Pane)
                    .tooltip("Previous match (⇧Enter)")
                    .disabled(total == 0)
                    .on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.find_prev(cx))),
            )
            .child(
                IconButton::new("chat-find-next", IconName::ChevronDown)
                    .size(IconButtonSize::Pane)
                    .tooltip("Next match (Enter)")
                    .disabled(total == 0)
                    .on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.find_next(cx))),
            )
            .child(
                IconButton::new("chat-find-close", IconName::X)
                    .size(IconButtonSize::Pane)
                    .tooltip("Close (Esc)")
                    .on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.close_find(window, cx))),
            )
    }
}

impl Render for ChatView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.soprano_theme().clone();
        let zoom = t.zoom();
        let width = f32::from(self.bounds.get().size.width) / zoom;
        let gutter = gutter(width);
        let composer_width = (width - gutter * 2.0).clamp(0.0, CHAT_MAX_WIDTH);
        let composer_height = f32::from(self.composer.read(cx).anchors.surface.get().size.height) / zoom;
        let inset = if composer_height > 0.0 { composer_height } else { 140.0 } + gutter * 2.0;
        self.composer.update(cx, |composer, _| composer.set_width(composer_width));
        self.timeline.update(cx, |timeline, cx| timeline.set_bottom_inset(t.z(inset), cx));
        let bounds = self.bounds.clone();
        div()
            .id("agent-chat")
            .key_context("AgentChat")
            .track_focus(&self.focus_handle)
            .on_key_down(cx.listener(Self::key_down))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|_, _, _, cx| cx.emit(ChatViewEvent::FocusRequested)),
            )
            .relative()
            .size_full()
            .overflow_hidden()
            .bg(t.background)
            .child(canvas(move |b, _, _| bounds.set(b), |_, _, _, _| {}).absolute().size_full())
            .child(self.timeline.clone())
            .when(self.find_open, |view| view.child(self.render_find_bar(&t, cx)))
            .child(
                div().absolute().left_0().right_0().bottom(t.z(gutter)).flex().justify_center().child(
                    div()
                        .id("agent-chat-composer")
                        .w(t.z(composer_width))
                        // The composer floats over the conversation: a click into it
                        // must not also land on the turn underneath, which would take
                        // the keyboard back from the editor. Its pane still becomes the
                        // active one.
                        .block_mouse_except_scroll()
                        .on_mouse_down(
                            MouseButton::Left,
                            cx.listener(|_, _, _, cx| cx.emit(ChatViewEvent::FocusRequested)),
                        )
                        .child(self.composer.clone()),
                ),
            )
    }
}
