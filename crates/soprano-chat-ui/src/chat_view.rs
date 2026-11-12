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
    App, Bounds, Context, Entity, EventEmitter, FocusHandle, Focusable, IntoElement, KeyDownEvent,
    MouseButton, ParentElement, Pixels, Render, Styled, Subscription, Task, Window, canvas, div, prelude::*,
};
use soprano_chat::{AgentChatEvent, AgentChatSession, ChatPhase};
use soprano_ui::{ActiveSopranoTheme, SopranoTheme};

use crate::composer::{ComposerEvent, ComposerView};
use crate::keys;
use crate::source::{SessionSource, SharedSession};
use crate::timeline_view::{CHAT_MAX_WIDTH, TimelineView, gutter};

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
            cx.observe_global::<SopranoTheme>(|_, cx| cx.notify()),
        ];
        Self {
            session,
            timeline,
            composer,
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

    /// Gives the composer the keyboard.
    pub fn focus_composer(&self, window: &mut Window, cx: &mut App) {
        let editor = self.composer.read(cx).editor.clone();
        editor.update(cx, |editor, cx| editor.focus(window, cx));
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

    /// Escape stops the running turn; plain keys typed while reading go to the composer.
    fn key_down(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        if !self.timeline.focus_handle(cx).contains_focused(window, cx) {
            return;
        }
        let keystroke = &event.keystroke;
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
            .child(
                div()
                    .absolute()
                    .left_0()
                    .right_0()
                    .bottom(t.z(gutter))
                    .flex()
                    .justify_center()
                    .child(div().w(t.z(composer_width)).child(self.composer.clone())),
            )
    }
}
