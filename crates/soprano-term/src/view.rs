// Adapted from herdr-app (Apache-2.0)
//! The terminal as a GPUI view: draws the grid, cursor, selection and images, and turns
//! keys, mouse, scrolling, input methods, pastes and drops into what the program reads.
//! Soprano's own behaviors (`TerminalSurfaceView.swift`) live here too: the host's key
//! interception, copy mode, clipboard confirmations, focus reporting and the dashboard's
//! screen text.

use crate::clipboard::{ClipboardConfirmationCoordinator, ClipboardConfirmationKind};
use crate::copy_mode::{
    CopyModeCommand, CopyModeInput, CopyModePhase, CopyModeSelectionStyle, CopyModeSession,
};
use crate::drop_content::{self, DropPayload};
use crate::engine::{PtyMessage, Terminal, TerminalLaunch, TerminalSize};
use crate::events::{ClipboardRequest, TerminalEvent};
use crate::input_metadata::{DeliveredPresses, KeyEquivalentModifiers, KeyEquivalentRouter, KeyUpRoute};
use crate::interaction::{MouseButtonState, SurfaceFocusTracker, TerminalInteractionState};
use crate::keys::{self, KeyAction};
use crate::links;
use crate::osc::Osc52Read;
use crate::settings::{ClipboardAccess, CopyOnSelect, TerminalSettings};
use crate::theme::TerminalTheme;
use crate::vt::{self, ClipboardLocation, CursorShape, Rgb, ScreenText, Select, VtSettings};
use ghostty_sys::*;
use gpui::prelude::FluentBuilder as _;
use gpui::*;
use soprano_types::KeybindingState;
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::time::{Duration, Instant};

actions!(
    terminal,
    [
        /// Copy the selection (Ghostty's `copy_to_clipboard`).
        Copy,
        /// Paste the clipboard (Ghostty's `paste_from_clipboard`).
        Paste,
        /// Select everything, scrollback included.
        SelectAll,
        /// Clear the screen and the scrollback.
        ClearScreen,
        ScrollToTop,
        ScrollToBottom,
        ScrollPageUp,
        ScrollPageDown,
    ]
);

/// The key context terminal bindings use.
pub const KEY_CONTEXT: &str = "Terminal";

/// Ghostty's default terminal bindings for this OS, in the `Terminal` key context. On
/// Linux and Windows Command chords are Ctrl+Shift chords (the terminal convention).
pub fn default_key_bindings() -> Vec<KeyBinding> {
    let c = Some(KEY_CONTEXT);
    if cfg!(target_os = "macos") {
        vec![
            KeyBinding::new("cmd-c", Copy, c),
            KeyBinding::new("cmd-v", Paste, c),
            KeyBinding::new("cmd-a", SelectAll, c),
            KeyBinding::new("cmd-k", ClearScreen, c),
            KeyBinding::new("cmd-home", ScrollToTop, c),
            KeyBinding::new("cmd-end", ScrollToBottom, c),
            KeyBinding::new("cmd-pageup", ScrollPageUp, c),
            KeyBinding::new("cmd-pagedown", ScrollPageDown, c),
        ]
    } else {
        vec![
            KeyBinding::new("ctrl-shift-c", Copy, c),
            KeyBinding::new("ctrl-shift-v", Paste, c),
            KeyBinding::new("ctrl-shift-a", SelectAll, c),
            KeyBinding::new("shift-home", ScrollToTop, c),
            KeyBinding::new("shift-end", ScrollToBottom, c),
            KeyBinding::new("shift-pageup", ScrollPageUp, c),
            KeyBinding::new("shift-pagedown", ScrollPageDown, c),
        ]
    }
}

/// Decides, before the terminal sees a key, whether the host takes it (an app shortcut, a
/// prefix chord). Returning `true` keeps the key from the program.
pub type KeyInterceptor = Box<dyn Fn(&KeyDownEvent, &mut Window, &mut App) -> bool>;

thread_local! {
    /// The selection clipboard (copy-on-select, middle-click paste) where the OS has none.
    static SELECTION_CLIPBOARD: RefCell<String> = const { RefCell::new(String::new()) };
}

fn hsla(c: Rgb) -> Hsla {
    Rgba { r: c.0 as f32 / 255.0, g: c.1 as f32 / 255.0, b: c.2 as f32 / 255.0, a: 1.0 }.into()
}

fn color_hsla(c: soprano_types::Color) -> Hsla {
    Rgba { r: c.r as f32 / 255.0, g: c.g as f32 / 255.0, b: c.b as f32 / 255.0, a: c.a as f32 / 255.0 }.into()
}

/// One piece of a row's drawing, in cells from the row's start.
enum RowOp {
    Bg { from: usize, to: usize, color: Hsla },
    Sprite { x: usize, text: String, color: Hsla },
    Text { x: usize, line: Box<ShapedLine> },
}

/// What the canvas closures need, shared outside the entity so prepaint can resize.
struct Grid {
    terminal: Terminal,
    cell: Size<Pixels>,
    /// The window's scale factor, from the last prepaint. Programs see cells, images and
    /// pixel mouse reports in device pixels, as in Ghostty.
    scale: f32,
    /// Top-left of the cell grid in window coordinates, from the last paint.
    origin: Point<Pixels>,
    buttons_down: Vec<MouseButton>,
    /// Kitty images uploaded for drawing, by (image, generation, source rect).
    images: HashMap<(u32, u64, [u32; 4]), Arc<RenderImage>>,
    hover: Option<Point<Pixels>>,
    /// The link under the pointer to underline: (row, first column, last column).
    link_spans: vt::Spans,
    /// Text an input method is still composing, drawn at the cursor; the program sees
    /// only the finished text.
    marked: Option<String>,
    /// The cursor's cell in window coordinates, from the last paint: where the input
    /// method puts its candidate window.
    cursor_at: Option<Bounds<Pixels>>,
    /// Whether the last frame's cursor blinks.
    cursor_blinks: bool,
    /// Each row's drawing by position, kept while the row is the same (`Rc`).
    painted: Vec<(Rc<Vec<vt::Cell>>, Vec<RowOp>)>,
    /// Font and cell size used to draw.
    painted_with: (String, u32, Size<Pixels>),
}

/// Copy mode's cursor plus where its selection started, `(column, screen row)`.
struct CopyMode {
    session: CopyModeSession,
    anchor: Option<(u16, u32)>,
    /// The cursor as content, `(column, screen row)`: while selecting, the selection's end
    /// stays on its text when the viewport scrolls (output, the wheel), as Ghostty's own
    /// selection did. The session's row is viewport-relative and is resynced from this.
    cursor: (u16, u32),
    /// The grid size copy mode began on; another one ends it.
    grid: (u16, u16),
}

/// A clipboard action waiting for the user's answer.
enum PendingClipboard {
    Paste(String),
    Read(Osc52Read, String),
    Write(ClipboardLocation, String),
}

pub struct TerminalView {
    grid: Rc<RefCell<Grid>>,
    settings: TerminalSettings,
    focus: FocusHandle,
    focus_tracker: SurfaceFocusTracker,
    interceptor: Option<KeyInterceptor>,
    copy_mode: Option<CopyMode>,
    mouse_button: MouseButtonState,
    key_router: KeyEquivalentRouter<String>,
    key_clock: f64,
    suppressed_copy_mode_key_ups: HashSet<String>,
    modifiers: Modifiers,
    /// A left-button selection drag is in progress (the program doesn't take the mouse).
    selecting: bool,
    selection_pointer: Point<Pixels>,
    selection_scroll: Option<Task<()>>,
    /// Scrolled this gesture, in lines, toward the next whole one.
    scrolled: Point<f32>,
    clipboard_requests: HashMap<u64, PendingClipboard>,
    next_clipboard_request: u64,
    /// The shell's folder (OSC 7), for links to relative paths.
    cwd: Option<PathBuf>,
    link: Option<links::Target>,
    title: String,
    blink_visible: bool,
    typed_at: Option<Instant>,
    search_query: String,
    search_task: Option<Task<()>>,
    destroyed: bool,
    clipboard_coordinator: Option<Rc<ClipboardConfirmationCoordinator>>,
    /// Key presses the program got; only their releases reach it.
    delivered_presses: DeliveredPresses,
    /// The pending wake-up at a synchronized-output hold's deadline.
    render_hold: Option<(Instant, Task<()>)>,
    _reader: Task<()>,
    _blink: Task<()>,
    _subscriptions: Vec<Subscription>,
}

impl EventEmitter<TerminalEvent> for TerminalView {}

impl Focusable for TerminalView {
    fn focus_handle(&self, _cx: &App) -> FocusHandle {
        self.focus.clone()
    }
}

const BLINK_INTERVAL: Duration = Duration::from_millis(600);
/// How long reading output may hold the UI thread before painting gets a turn.
const OUTPUT_TIME_PER_TURN: Duration = Duration::from_millis(6);

impl TerminalView {
    /// Starts `launch` in a new terminal drawn with `settings`.
    pub fn new(
        launch: TerminalLaunch,
        settings: TerminalSettings,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> anyhow::Result<Self> {
        let terminal = Self::spawn_terminal(launch, &settings, window)?;
        Ok(Self::from_terminal(terminal, settings, window, cx))
    }

    /// Starts `launch` and makes its view entity; fails before an entity exists.
    pub fn spawn(
        launch: TerminalLaunch,
        settings: TerminalSettings,
        window: &mut Window,
        cx: &mut App,
    ) -> anyhow::Result<Entity<Self>> {
        let terminal = Self::spawn_terminal(launch, &settings, window)?;
        Ok(cx.new(|cx| Self::from_terminal(terminal, settings, window, cx)))
    }

    fn spawn_terminal(
        launch: TerminalLaunch,
        settings: &TerminalSettings,
        window: &Window,
    ) -> anyhow::Result<Terminal> {
        let cell = cell_size(settings, window);
        let scale = window.scale_factor();
        Terminal::spawn(
            launch,
            settings,
            TerminalSize {
                cell_width: device(cell.width, scale),
                cell_height: device(cell.height, scale),
                ..TerminalSize::default()
            },
        )
    }

    /// The view of an already started terminal.
    pub fn from_terminal(
        terminal: Terminal,
        settings: TerminalSettings,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let cell = cell_size(&settings, window);
        let scale = window.scale_factor();
        let rx = terminal.receiver();
        let grid = Rc::new(RefCell::new(Grid {
            terminal,
            cell,
            scale,
            origin: Point::default(),
            buttons_down: Vec::new(),
            images: HashMap::new(),
            hover: None,
            link_spans: Vec::new(),
            marked: None,
            cursor_at: None,
            cursor_blinks: false,
            painted: Vec::new(),
            painted_with: (String::new(), 0, Size::default()),
        }));
        let focus = cx.focus_handle();
        let subscriptions = vec![
            cx.observe_window_activation(window, |this, window, cx| {
                this.sync_focus(window, cx);
                cx.notify();
            }),
            cx.on_focus_in(&focus, window, |this, window, cx| {
                this.sync_focus(window, cx);
                cx.notify();
            }),
            cx.on_focus_out(&focus, window, |this, _, window, cx| {
                this.sync_focus(window, cx);
                cx.notify();
            }),
        ];
        Self {
            grid,
            settings,
            focus,
            focus_tracker: SurfaceFocusTracker::default(),
            interceptor: None,
            copy_mode: None,
            mouse_button: MouseButtonState::default(),
            key_router: KeyEquivalentRouter::new(),
            key_clock: 0.0,
            suppressed_copy_mode_key_ups: HashSet::new(),
            modifiers: Modifiers::default(),
            selecting: false,
            selection_pointer: Point::default(),
            selection_scroll: None,
            scrolled: point(0.0, 0.0),
            clipboard_requests: HashMap::new(),
            next_clipboard_request: 0,
            cwd: None,
            link: None,
            title: String::new(),
            blink_visible: true,
            typed_at: None,
            search_query: String::new(),
            search_task: None,
            destroyed: false,
            clipboard_coordinator: None,
            delivered_presses: DeliveredPresses::default(),
            render_hold: None,
            _reader: Self::read_output(rx, cx),
            _blink: Self::blink(cx),
            _subscriptions: subscriptions,
        }
    }

    /// Output is read in turns of a few milliseconds so input and painting keep up.
    fn read_output(rx: async_channel::Receiver<PtyMessage>, cx: &mut Context<Self>) -> Task<()> {
        cx.spawn(async move |this, cx| {
            while let Ok(first) = rx.recv().await {
                // The deadline bounds parsing, not just collecting: a flood of output (`cat`
                // on a huge file, `yes`) leaves the rest queued, which stalls the reader.
                let turn = output_turn(first, &rx, OUTPUT_TIME_PER_TURN);
                if this.update(cx, |this, cx| this.ingest(turn, cx)).is_err() {
                    break;
                }
                if !rx.is_empty() {
                    // A ready receiver does not yield to input and painting by itself.
                    let mut yielded = false;
                    std::future::poll_fn(|cx| {
                        if std::mem::replace(&mut yielded, true) {
                            std::task::Poll::Ready(())
                        } else {
                            cx.waker().wake_by_ref();
                            std::task::Poll::Pending
                        }
                    })
                    .await;
                }
            }
        })
    }

    fn blink(cx: &mut Context<Self>) -> Task<()> {
        cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(BLINK_INTERVAL).await;
                let alive = this.update(cx, |this, cx| {
                    let blinks = this.grid.borrow().cursor_blinks && this.focus_tracker.last() == Some(true);
                    let typed_recently = this.typed_at.is_some_and(|t| t.elapsed() < BLINK_INTERVAL);
                    let visible = !blinks || typed_recently || !this.blink_visible;
                    if visible != this.blink_visible {
                        this.blink_visible = visible;
                        cx.notify();
                    }
                });
                if alive.is_err() {
                    break;
                }
            }
        })
    }

    fn ingest(&mut self, turn: impl Iterator<Item = PtyMessage>, cx: &mut Context<Self>) {
        if self.destroyed {
            // Drained, so the PTY threads never block on a terminal nobody shows.
            turn.for_each(drop);
            return;
        }
        let (events, changed, deadline) = {
            let mut g = self.grid.borrow_mut();
            for message in turn {
                g.terminal.handle(message);
            }
            let events = g.terminal.take_events();
            // Output that changed nothing on screen (an agent spinning its title) needs no
            // frame.
            let changed = g.terminal.vt_mut().shows_change();
            (events, changed, g.terminal.vt().render_hold_deadline())
        };
        for event in events {
            self.dispatch(event, cx);
        }
        self.schedule_render_hold_release(deadline, cx);
        if changed {
            cx.notify();
        }
    }

    /// A program holding the screen (synchronized output) that never lets go must not
    /// freeze it: libghostty leaves the timeout to the embedder, so the view redraws at the
    /// deadline, when `frame()` drops the hold.
    fn schedule_render_hold_release(&mut self, deadline: Option<Instant>, cx: &mut Context<Self>) {
        if self.render_hold.as_ref().map(|(at, _)| *at) == deadline {
            return;
        }
        self.render_hold = deadline.map(|deadline| {
            let task = cx.spawn(async move |this, cx| {
                cx.background_executor().timer(deadline.saturating_duration_since(Instant::now())).await;
                let _ = this.update(cx, |this, cx| {
                    this.render_hold = None;
                    cx.notify();
                });
            });
            (deadline, task)
        });
    }

    fn dispatch(&mut self, event: TerminalEvent, cx: &mut Context<Self>) {
        match event {
            TerminalEvent::ClipboardWrite { location, text } => match self.settings.clipboard_write {
                ClipboardAccess::Allow => write_clipboard(location, text, cx),
                ClipboardAccess::Deny => {}
                ClipboardAccess::Ask => self.request_confirmation(
                    ClipboardConfirmationKind::Osc52Write,
                    text.clone(),
                    PendingClipboard::Write(location, text),
                    cx,
                ),
            },
            TerminalEvent::ClipboardReadRequested(read) => {
                let text = read_clipboard(read.wants_selection_clipboard(), cx);
                match self.settings.clipboard_read {
                    ClipboardAccess::Allow => {
                        self.grid.borrow().terminal.answer_clipboard_read(&read, Some(&text))
                    }
                    ClipboardAccess::Deny => self.grid.borrow().terminal.answer_clipboard_read(&read, None),
                    ClipboardAccess::Ask => self.request_confirmation(
                        ClipboardConfirmationKind::Osc52Read,
                        text.clone(),
                        PendingClipboard::Read(read, text),
                        cx,
                    ),
                }
            }
            TerminalEvent::WorkingDirectoryChanged(path) => {
                self.cwd = Some(PathBuf::from(&path));
                cx.emit(TerminalEvent::WorkingDirectoryChanged(path));
            }
            TerminalEvent::TitleChanged(title) => {
                self.title = title.clone();
                cx.emit(TerminalEvent::TitleChanged(title));
            }
            other => cx.emit(other),
        }
    }

    fn request_confirmation(
        &mut self,
        kind: ClipboardConfirmationKind,
        content: String,
        pending: PendingClipboard,
        cx: &mut Context<Self>,
    ) {
        self.next_clipboard_request += 1;
        let id = self.next_clipboard_request;
        self.clipboard_requests.insert(id, pending);
        cx.emit(TerminalEvent::ClipboardConfirmationRequested(ClipboardRequest { id, kind, content }));
    }

    /// The user's answer to a [`TerminalEvent::ClipboardConfirmationRequested`]. A denied
    /// read answers the program with an empty clipboard.
    pub fn resolve_clipboard_request(&mut self, id: u64, allowed: bool, cx: &mut Context<Self>) {
        let Some(pending) = self.clipboard_requests.remove(&id) else { return };
        match pending {
            PendingClipboard::Paste(text) => {
                if allowed {
                    self.send_paste(&text);
                }
            }
            PendingClipboard::Read(read, text) => {
                self.grid.borrow().terminal.answer_clipboard_read(&read, allowed.then_some(text.as_str()))
            }
            PendingClipboard::Write(location, text) => {
                if allowed {
                    write_clipboard(location, text, cx);
                }
            }
        }
        cx.notify();
    }

    /// The app's clipboard prompt queue. With it, `destroy` (and so `restart`) withdraws this
    /// terminal's queued and showing prompts itself; without it, the host must call
    /// `cancel_requests(view.entity_id().as_u64())` when it sees [`TerminalEvent::Destroyed`].
    pub fn set_clipboard_coordinator(&mut self, coordinator: Option<Rc<ClipboardConfirmationCoordinator>>) {
        self.clipboard_coordinator = coordinator;
    }

    /// Lets the host take keys before the terminal sees them.
    pub fn set_key_interceptor(&mut self, interceptor: Option<KeyInterceptor>) {
        self.interceptor = interceptor;
    }

    pub fn settings(&self) -> &TerminalSettings {
        &self.settings
    }

    /// Applies new settings (a config reload): font, padding, colors, cursor, scrollback.
    pub fn set_settings(&mut self, settings: TerminalSettings, cx: &mut Context<Self>) {
        {
            let mut g = self.grid.borrow_mut();
            g.terminal.vt_mut().apply_settings(&VtSettings::from(&settings));
            g.terminal.vt_mut().set_option_as_alt(settings.option_as_alt);
        }
        self.settings = settings;
        cx.notify();
    }

    /// Switches colors (the app's theme changed).
    pub fn set_theme(&mut self, theme: TerminalTheme, cx: &mut Context<Self>) {
        let mut settings = self.settings.clone();
        settings.theme = theme;
        self.set_settings(settings, cx);
    }

    /// Changes the font size by `delta` points (Ghostty's `increase_font_size` /
    /// `decrease_font_size`). Copy mode ends: its cells moved.
    pub fn change_font_size(&mut self, delta: i32, cx: &mut Context<Self>) {
        if delta == 0 {
            return;
        }
        self.settings.font_size = (self.settings.font_size + delta as f32).max(1.0);
        self.finish_copy_mode(false, true, cx);
        cx.notify();
    }

    /// Back to the configured font size.
    pub fn reset_font_size(&mut self, configured: f32, cx: &mut Context<Self>) {
        self.settings.font_size = configured;
        self.finish_copy_mode(false, true, cx);
        cx.notify();
    }

    pub fn title(&self) -> &str {
        &self.title
    }

    pub fn working_directory(&self) -> Option<&PathBuf> {
        self.cwd.as_ref()
    }

    pub fn child_pid(&self) -> Option<u32> {
        self.grid.borrow().terminal.child_pid()
    }

    pub fn foreground_process_name(&self) -> Option<String> {
        self.grid.borrow().terminal.foreground_process_name()
    }

    pub fn foreground_cwd(&self) -> Option<PathBuf> {
        self.grid.borrow().terminal.foreground_cwd()
    }

    /// Whether the shell runs a command rather than waiting at its prompt.
    pub fn is_running_command(&self) -> bool {
        !self.destroyed && self.grid.borrow().terminal.is_running_command()
    }

    pub fn has_exited(&self) -> bool {
        self.grid.borrow().terminal.has_exited()
    }

    pub fn grid_size(&self) -> TerminalSize {
        self.grid.borrow().terminal.size()
    }

    /// Runs `f` with the terminal (headless queries, tests).
    pub fn with_terminal<R>(&self, f: impl FnOnce(&Terminal) -> R) -> R {
        f(&self.grid.borrow().terminal)
    }

    // MARK: - Writing to the program

    /// Bytes to the program as is, scrolled to the bottom as typing does.
    pub fn write(&mut self, bytes: &[u8]) {
        if self.destroyed || bytes.is_empty() {
            return;
        }
        self.typed_at = Some(Instant::now());
        let mut g = self.grid.borrow_mut();
        g.terminal.vt_mut().scroll_to_bottom();
        g.terminal.write(bytes);
    }

    /// Text typed into the program the way a paste is (bracketed when it asked), without
    /// a confirmation: drops and programmatic input (Ghostty's `ghostty_surface_text`).
    pub fn insert_text(&mut self, text: &str, cx: &mut Context<Self>) {
        if self.copy_mode.is_some() {
            self.finish_copy_mode(false, true, cx);
        }
        self.grid.borrow_mut().marked = None;
        self.send_paste(text);
        cx.notify();
    }

    fn send_paste(&mut self, text: &str) {
        let bytes = self.grid.borrow().terminal.vt().paste_bytes(text);
        self.write(&bytes);
    }

    /// Pastes `text`, asking first when it could run commands (Ghostty's paste protection).
    pub fn paste(&mut self, text: &str, cx: &mut Context<Self>) {
        if text.is_empty() {
            return;
        }
        let bracketed = self.grid.borrow().terminal.vt().bracketed_paste();
        if paste_needs_confirmation(text, &self.settings, bracketed) {
            self.request_confirmation(
                ClipboardConfirmationKind::Paste,
                text.to_owned(),
                PendingClipboard::Paste(text.to_owned()),
                cx,
            );
        } else {
            self.send_paste(text);
        }
        cx.notify();
    }

    /// Pastes the clipboard: its text, or copied files as shell-escaped paths.
    pub fn paste_from_clipboard(&mut self, cx: &mut Context<Self>) {
        let Some(item) = cx.read_from_clipboard() else { return };
        let files = item.entries().iter().find_map(|e| match e {
            ClipboardEntry::ExternalPaths(p) if !p.paths().is_empty() => Some(p.paths().to_vec()),
            _ => None,
        });
        let text = match files {
            Some(paths) => drop_content::text_from(&DropPayload::files(paths)),
            None => item.text(),
        };
        if let Some(text) = text {
            self.paste(&text, cx);
        }
    }

    /// Pastes the selection clipboard (middle click).
    pub fn paste_selection_clipboard(&mut self, cx: &mut Context<Self>) {
        let text = read_clipboard(true, cx);
        self.paste(&text, cx);
    }

    /// A drop: URLs and files as shell-escaped words, text as it is.
    pub fn drop_payload(&mut self, payload: &DropPayload, window: &mut Window, cx: &mut Context<Self>) {
        let Some(text) = drop_content::text_from(payload) else { return };
        cx.emit(TerminalEvent::FocusRequested);
        self.focus.focus(window, cx);
        self.insert_text(&text, cx);
    }

    /// Submits `text` as one line and presses Return (an agent's prompt from the
    /// dashboard). Line breaks become spaces; returns false for empty text.
    pub fn submit_text(&mut self, raw: &str, cx: &mut Context<Self>) -> bool {
        if self.destroyed {
            return false;
        }
        let text = submission_line(raw);
        let text = text.as_str();
        if text.is_empty() {
            return false;
        }
        self.insert_text(text, cx);
        let enter = {
            let mut g = self.grid.borrow_mut();
            let vt = g.terminal.vt_mut();
            let mut bytes =
                vt.encode_key(GHOSTTY_KEY_ACTION_PRESS, GHOSTTY_KEY_ENTER, 0, 0, None, Some('\r'));
            bytes.extend(vt.encode_key(
                GHOSTTY_KEY_ACTION_RELEASE,
                GHOSTTY_KEY_ENTER,
                0,
                0,
                None,
                Some('\r'),
            ));
            bytes
        };
        self.write(&enter);
        cx.emit(TerminalEvent::AgentInputSubmitted);
        true
    }

    /// Encodes `keystroke` as a key press for the program and sends it.
    pub fn send_key(&mut self, keystroke: &Keystroke, cx: &mut Context<Self>) {
        let bytes = keys::key_bytes(self.grid.borrow_mut().terminal.vt_mut(), keystroke, KeyAction::Press);
        if let Some(bytes) = bytes {
            self.write(&bytes);
        }
        cx.notify();
    }

    // MARK: - Selection and clipboard

    pub fn has_selection(&self) -> bool {
        self.grid.borrow().terminal.vt().has_selection()
    }

    pub fn selection_text(&self) -> Option<String> {
        self.grid.borrow().terminal.vt().selection_text()
    }

    /// Copies the selection to the clipboard; whether there was one. With
    /// `selection-clear-on-copy` the selection then goes.
    pub fn copy_selection(&mut self, cx: &mut Context<Self>) -> bool {
        let Some(text) = self.selection_text() else { return false };
        cx.write_to_clipboard(ClipboardItem::new_string(text));
        if self.settings.selection_clear_on_copy {
            self.grid.borrow_mut().terminal.vt_mut().clear_selection();
        }
        cx.notify();
        true
    }

    pub fn select_all(&mut self, cx: &mut Context<Self>) {
        self.grid.borrow_mut().terminal.vt_mut().select_all();
        cx.notify();
    }

    pub fn clear_selection(&mut self, cx: &mut Context<Self>) {
        self.grid.borrow_mut().terminal.vt_mut().clear_selection();
        cx.notify();
    }

    /// Clears the screen and the scrollback; a shell at its prompt redraws it (form feed).
    pub fn clear_screen(&mut self, cx: &mut Context<Self>) {
        let at_prompt = {
            let mut g = self.grid.borrow_mut();
            if g.terminal.vt().alt_screen() {
                return;
            }
            g.terminal.vt_mut().clear_screen_and_scrollback();
            !g.terminal.is_running_command()
        };
        if at_prompt {
            self.write(b"\x0c");
        }
        cx.notify();
    }

    // MARK: - Scrolling

    /// Scrolls the viewport by `lines` (negative: up into the scrollback).
    pub fn scroll(&mut self, lines: isize, cx: &mut Context<Self>) {
        self.grid.borrow_mut().terminal.vt_mut().scroll_viewport(lines);
        cx.notify();
    }

    pub fn scroll_to_top(&mut self, cx: &mut Context<Self>) {
        self.grid.borrow_mut().terminal.vt_mut().scroll_to_top();
        cx.notify();
    }

    pub fn scroll_to_bottom(&mut self, cx: &mut Context<Self>) {
        self.grid.borrow_mut().terminal.vt_mut().scroll_to_bottom();
        cx.notify();
    }

    pub fn scroll_pages(&mut self, pages: isize, cx: &mut Context<Self>) {
        let rows = self.grid.borrow().terminal.size().rows as isize;
        self.scroll(pages * rows, cx);
    }

    // MARK: - Search

    /// Searches the screen and scrollback for `query` (case-insensitively); empty clears.
    pub fn search(&mut self, query: &str, cx: &mut Context<Self>) {
        self.search_query = query.to_owned();
        {
            let mut g = self.grid.borrow_mut();
            if query.is_empty() {
                g.terminal.vt_mut().clear_search();
            } else {
                g.terminal.vt_mut().start_search(query);
            }
        }
        self.ensure_search_task(cx);
        cx.notify();
    }

    pub fn search_next(&mut self, cx: &mut Context<Self>) -> bool {
        let moved = self.grid.borrow_mut().terminal.vt_mut().search_navigate(false);
        cx.notify();
        moved
    }

    pub fn search_previous(&mut self, cx: &mut Context<Self>) -> bool {
        let moved = self.grid.borrow_mut().terminal.vt_mut().search_navigate(true);
        cx.notify();
        moved
    }

    pub fn clear_search(&mut self, cx: &mut Context<Self>) {
        self.search("", cx);
    }

    pub fn search_progress(&self) -> vt::SearchProgress {
        self.grid.borrow().terminal.vt().search_progress()
    }

    fn ensure_search_task(&mut self, cx: &mut Context<Self>) {
        if self.search_query.is_empty() {
            self.search_task = None;
            return;
        }
        if self.search_task.is_some() {
            return;
        }
        self.search_task = Some(cx.spawn(async move |this, cx| {
            loop {
                let busy = this
                    .update(cx, |this, cx| {
                        if this.search_query.is_empty() {
                            return None;
                        }
                        let mut g = this.grid.borrow_mut();
                        let changed = g.terminal.vt_mut().progress_search();
                        let busy = !g.terminal.vt().search_progress().complete;
                        drop(g);
                        if changed {
                            cx.notify();
                        }
                        Some(busy)
                    })
                    .ok()
                    .flatten();
                let Some(busy) = busy else { break };
                let delay = if busy { 33 } else { 200 };
                cx.background_executor().timer(Duration::from_millis(delay)).await;
            }
        }));
    }

    // MARK: - Screen text

    /// The visible screen as plain text (what the dashboard shows).
    pub fn visible_text(&self) -> Option<String> {
        (!self.destroyed).then(|| self.grid.borrow().terminal.vt().visible_text())
    }

    /// The visible screen plus up to `scrollback_lines` lines above it, with styles.
    pub fn screen_text(&self, scrollback_lines: usize) -> ScreenText {
        self.grid.borrow().terminal.vt().screen_text(scrollback_lines)
    }

    /// The dashboard's view of this terminal.
    pub fn interaction_state(&self) -> TerminalInteractionState {
        match self.visible_text() {
            Some(visible_text) if !self.has_exited() => {
                TerminalInteractionState { is_available: true, visible_text }
            }
            _ => TerminalInteractionState::unavailable(),
        }
    }

    // MARK: - Lifecycle

    /// Ends the terminal: copy mode, held buttons and pending confirmations go, the process
    /// is killed. Safe to call more than once.
    pub fn destroy(&mut self, cx: &mut Context<Self>) {
        self.finish_copy_mode(false, false, cx);
        self.release_tracked_left_button();
        self.key_router.reset();
        self.delivered_presses.clear();
        self.suppressed_copy_mode_key_ups.clear();
        self.focus_tracker.reset();
        self.render_hold = None;
        if self.destroyed {
            return;
        }
        self.destroyed = true;
        // Prompts queued for this terminal go too (Swift cancelled them on destroy). Deferred:
        // the coordinator answers them through the host, which updates this view.
        if let Some(coordinator) = self.clipboard_coordinator.clone() {
            let surface = cx.entity_id().as_u64();
            cx.defer(move |_| coordinator.cancel_requests(surface));
        }
        cx.emit(TerminalEvent::Destroyed);
        // Pending prompts answer as denied: a read gets an empty clipboard.
        for (_, pending) in self.clipboard_requests.drain() {
            if let PendingClipboard::Read(read, _) = pending {
                self.grid.borrow().terminal.answer_clipboard_read(&read, None);
            }
        }
        self.grid.borrow_mut().marked = None;
        self.grid.borrow_mut().terminal.kill();
        cx.notify();
    }

    /// Replaces the process with a new one from `launch` (Swift's `recreateSurface`).
    pub fn restart(&mut self, launch: TerminalLaunch, cx: &mut Context<Self>) -> anyhow::Result<()> {
        self.destroy(cx);
        let size = self.grid.borrow().terminal.size();
        let terminal = Terminal::spawn(launch, &self.settings, size)?;
        let rx = terminal.receiver();
        {
            let mut g = self.grid.borrow_mut();
            g.terminal = terminal;
            g.painted.clear();
            g.images.clear();
        }
        self.destroyed = false;
        self.title.clear();
        self.cwd = None;
        self._reader = Self::read_output(rx, cx);
        cx.notify();
        Ok(())
    }

    // MARK: - Focus

    fn sync_focus(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.destroyed {
            return;
        }
        let Some(focused) = self.focus_tracker.sync(window.is_window_active(), self.focus.is_focused(window))
        else {
            return;
        };
        let bytes = self.grid.borrow().terminal.vt().focus_bytes(focused);
        self.grid.borrow().terminal.write(&bytes);
        self.blink_visible = true;
        if focused {
            cx.set_cursor_hide_mode(if self.settings.mouse_hide_while_typing {
                CursorHideMode::OnTyping
            } else {
                CursorHideMode::Never
            });
            cx.emit(TerminalEvent::Focused);
        } else {
            self.release_tracked_left_button();
            self.mouse_button.release_left_button();
            self.key_router.reset();
            self.delivered_presses.clear();
            self.suppressed_copy_mode_key_ups.clear();
        }
    }

    // MARK: - Copy mode

    pub fn is_in_copy_mode(&self) -> bool {
        self.copy_mode.is_some()
    }

    /// Enters copy mode at the cursor, scrolled to the bottom. False when already in it.
    pub fn enter_copy_mode(&mut self, cx: &mut Context<Self>) -> bool {
        if self.copy_mode.is_some() || self.destroyed {
            return false;
        }
        let (session, grid, top) = {
            let mut g = self.grid.borrow_mut();
            let vt = g.terminal.vt_mut();
            vt.scroll_to_bottom();
            vt.clear_selection();
            let (x, y) = vt.cursor_position();
            (
                CopyModeSession::new(x as isize, y as isize, vt.cols as usize, vt.rows as usize),
                (vt.cols, vt.rows),
                vt.viewport_top(),
            )
        };
        let cursor = (session.column() as u16, top + session.row() as u32);
        self.copy_mode = Some(CopyMode { session, anchor: None, cursor, grid });
        cx.emit(TerminalEvent::CopyModeStateChanged(KeybindingState::Copy));
        cx.notify();
        true
    }

    pub fn cancel_copy_mode(&mut self, cx: &mut Context<Self>) {
        self.finish_copy_mode(false, true, cx);
    }

    fn finish_copy_mode(&mut self, copy: bool, scroll_to_bottom: bool, cx: &mut Context<Self>) {
        if self.copy_mode.is_none() {
            return;
        }
        // A drag still in progress ends with copy mode (no autoscroll, no copy-on-select).
        self.release_tracked_left_button();
        let Some(mode) = self.copy_mode.take() else { return };
        if mode.session.phase() == CopyModePhase::Selecting {
            let copied = copy
                && self.selection_text().is_some_and(|text| {
                    cx.write_to_clipboard(ClipboardItem::new_string(text));
                    true
                });
            // A yank leaves the highlight only when `selection-clear-on-copy` is off.
            if !copied || self.settings.selection_clear_on_copy {
                self.grid.borrow_mut().terminal.vt_mut().clear_selection();
            }
        }
        if scroll_to_bottom {
            self.grid.borrow_mut().terminal.vt_mut().scroll_to_bottom();
        }
        cx.emit(TerminalEvent::CopyModeStateChanged(KeybindingState::Normal));
        cx.notify();
    }

    /// Copy mode measured its cells on one grid; when the grid changes they would land on
    /// the wrong cells, so it ends instead.
    fn end_copy_mode_if_grid_changed(&mut self, cx: &mut Context<Self>) {
        let size = self.grid.borrow().terminal.size();
        if self.copy_mode.as_ref().is_some_and(|m| m.grid != (size.cols, size.rows)) {
            self.finish_copy_mode(false, true, cx);
        }
    }

    /// The copy-mode cursor in screen coordinates.
    fn copy_cursor(&self, session: &CopyModeSession) -> (u16, u32) {
        let top = self.grid.borrow().terminal.vt().viewport_top();
        (session.column() as u16, top + session.row() as u32)
    }

    fn update_copy_selection(&mut self) {
        let Some(mode) = &self.copy_mode else { return };
        let (Some(anchor), Some(style)) = (mode.anchor, mode.session.selection_style()) else { return };
        let cursor = mode.cursor;
        let mut g = self.grid.borrow_mut();
        let vt = g.terminal.vt_mut();
        match style {
            CopyModeSelectionStyle::Character => {
                vt.select_screen_range(anchor, cursor);
            }
            CopyModeSelectionStyle::Line => {
                let (top, bottom) = (anchor.1.min(cursor.1), anchor.1.max(cursor.1));
                let last = vt.cols.saturating_sub(1);
                vt.select_screen_range((0, top), (last, bottom));
            }
        }
    }

    fn scroll_lines(&mut self, lines: isize) {
        if lines != 0 {
            self.grid.borrow_mut().terminal.vt_mut().scroll_viewport(lines);
        }
    }

    fn handle_copy_mode_key(&mut self, keystroke: &Keystroke, cx: &mut Context<Self>) -> bool {
        if self.copy_mode.is_none() {
            return false;
        }
        self.suppressed_copy_mode_key_ups.insert(keystroke.key.clone());
        self.end_copy_mode_if_grid_changed(cx);
        let Some(mut mode) = self.copy_mode.take() else { return true };
        let Some(command) = mode.session.command(&CopyModeInput::from_keystroke(keystroke)) else {
            self.copy_mode = Some(mode);
            return true;
        };
        let selecting = mode.session.phase() == CopyModePhase::Selecting;
        let rows = mode.session.row_count() as isize;
        if selecting {
            // Bring the selection's end back where the session expects it, even if the
            // viewport moved since the last key.
            let top = self.grid.borrow().terminal.vt().viewport_top();
            let (scroll, row) = viewport_row_for(mode.cursor.1, top, mode.session.row_count());
            self.scroll_lines(scroll);
            mode.session.move_to_viewport_row(row);
        }
        use CopyModeCommand::*;
        match command {
            MoveLeft => {
                mode.session.move_horizontal(-1);
            }
            MoveRight => {
                mode.session.move_horizontal(1);
            }
            MoveUp => {
                let overflow = mode.session.move_vertical(-1);
                self.scroll_lines(overflow);
            }
            MoveDown => {
                let overflow = mode.session.move_vertical(1);
                self.scroll_lines(overflow);
            }
            LineStart => mode.session.move_to_line_start(),
            LineEnd => mode.session.move_to_line_end(),
            ViewportTop => mode.session.move_to_viewport_row(0),
            ViewportMiddle => mode.session.move_to_viewport_row(((rows - 1) / 2).max(0)),
            ViewportBottom => mode.session.move_to_viewport_row(rows - 1),
            HistoryTop => {
                mode.session.move_to_history_top();
                self.grid.borrow_mut().terminal.vt_mut().scroll_to_top();
            }
            HistoryBottom => {
                mode.session.move_to_history_bottom();
                self.grid.borrow_mut().terminal.vt_mut().scroll_to_bottom();
            }
            HalfPageUp | HalfPageDown => {
                let lines = (rows / 2).max(1) * if command == HalfPageUp { -1 } else { 1 };
                if selecting && mode.session.selection_style() == Some(CopyModeSelectionStyle::Character) {
                    // The cursor walks the half page, scrolling at the edges.
                    for _ in 0..lines.abs() {
                        let overflow = mode.session.move_vertical(lines.signum());
                        self.scroll_lines(overflow);
                    }
                } else {
                    self.scroll_lines(lines);
                }
            }
            PageUp => self.scroll_lines(-rows),
            PageDown => self.scroll_lines(rows),
            BeginSelection | BeginLineSelection => {
                if !selecting {
                    let style = if command == BeginSelection {
                        CopyModeSelectionStyle::Character
                    } else {
                        CopyModeSelectionStyle::Line
                    };
                    mode.anchor = Some(self.copy_cursor(&mode.session));
                    mode.cursor = self.copy_cursor(&mode.session);
                    mode.session.begin_selection(style);
                    cx.emit(TerminalEvent::CopyModeStateChanged(KeybindingState::CopySelection));
                }
            }
            CopyAndExit => {
                self.copy_mode = Some(mode);
                if selecting {
                    self.finish_copy_mode(true, true, cx);
                }
                cx.notify();
                return true;
            }
            Cancel => {
                self.copy_mode = Some(mode);
                self.finish_copy_mode(false, true, cx);
                return true;
            }
            AwaitMore => {}
        }
        mode.cursor = self.copy_cursor(&mode.session);
        self.copy_mode = Some(mode);
        self.update_copy_selection();
        cx.notify();
        true
    }

    /// A mouse press or drag in copy mode moves its cursor there; a selection made with the
    /// mouse can be extended with the keyboard or yanked.
    fn update_copy_mode_mouse(&mut self, position: Point<Pixels>, pressed: bool, cx: &mut Context<Self>) {
        self.end_copy_mode_if_grid_changed(cx);
        let (col, row, has_selection, top) = {
            let g = self.grid.borrow();
            let (x, y) = local(&g, position);
            let col = (x / f32::from(g.cell.width)).floor() as isize;
            let row = (y / f32::from(g.cell.height)).floor() as isize;
            (col, row, g.terminal.vt().has_selection(), g.terminal.vt().viewport_top())
        };
        let Some(mode) = &mut self.copy_mode else { return };
        let previous = mode.session.phase();
        mode.session.update_mouse_selection(col, row, has_selection);
        mode.cursor = (mode.session.column() as u16, top + mode.session.row() as u32);
        if pressed {
            mode.anchor = Some(mode.cursor);
        }
        let phase = mode.session.phase();
        if phase != previous {
            let state = if phase == CopyModePhase::Selecting {
                KeybindingState::CopySelection
            } else {
                KeybindingState::Copy
            };
            cx.emit(TerminalEvent::CopyModeStateChanged(state));
        }
        cx.notify();
    }

    // MARK: - Keyboard

    fn key_down(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        if self.destroyed {
            return;
        }
        let k = &event.keystroke;
        self.key_clock += 1.0;
        let equivalent =
            KeyEquivalentModifiers { command: k.modifiers.platform, control: k.modifiers.control };
        if let Some(interceptor) = &self.interceptor
            && interceptor(event, window, cx)
        {
            // The host took it: no press, and so no release, reaches the program.
            self.key_router.route_key_equivalent(self.key_clock, k.key.clone(), equivalent, false, true);
            cx.stop_propagation();
            return;
        }
        cx.stop_propagation();
        if self.grid.borrow().terminal.waits_for_key_to_close() {
            cx.emit(TerminalEvent::CloseRequested);
            return;
        }
        if self.handle_copy_mode_key(k, cx) {
            return;
        }
        let no_modifiers = !k.modifiers.modified();
        // `performable:y=copy_to_clipboard` (SopranoCopyMode.conf): with a highlight, `y`
        // copies it; without one, `y` is typed.
        if no_modifiers && k.key == "y" && self.has_selection() {
            self.copy_selection(cx);
            return;
        }
        self.key_router.prepare_for_key_down(self.key_clock, k.key.clone());
        // Typing clears a selection, as in Ghostty.
        if self.has_selection() {
            self.grid.borrow_mut().terminal.vt_mut().clear_selection();
        }
        let action = if event.is_held { KeyAction::Repeat } else { KeyAction::Press };
        let bytes = keys::key_bytes(self.grid.borrow_mut().terminal.vt_mut(), k, action);
        let Some(bytes) = bytes else {
            // Unknown to libghostty: text arrives through the input handler.
            cx.propagate();
            return;
        };
        self.blink_visible = true;
        self.write(&bytes);
        self.key_router.record_key_down_delivery(&k.key);
        self.delivered_presses.press(k.key.clone());
        if k.key == "enter" && !k.modifiers.shift {
            cx.emit(TerminalEvent::AgentInputSubmitted);
        }
        cx.notify();
    }

    fn key_up(&mut self, event: &KeyUpEvent, _window: &mut Window, cx: &mut Context<Self>) {
        let key = &event.keystroke.key;
        if self.suppressed_copy_mode_key_ups.remove(key) || self.destroyed {
            return;
        }
        // Only a press the program got has a release: keys the host intercepted or handled
        // as an action (Cmd+C, Cmd+V) never reached it.
        if !self.delivered_presses.release(key) {
            return;
        }
        if self.key_router.route_key_up(key) == KeyUpRoute::Suppress {
            return;
        }
        let bytes =
            keys::key_bytes(self.grid.borrow_mut().terminal.vt_mut(), &event.keystroke, KeyAction::Release);
        if let Some(bytes) = bytes.filter(|b| !b.is_empty()) {
            self.grid.borrow().terminal.write(&bytes);
        }
        cx.notify();
    }

    fn modifiers_changed(
        &mut self,
        event: &ModifiersChangedEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let before = std::mem::replace(&mut self.modifiers, event.modifiers);
        if self.destroyed || self.grid.borrow().marked.is_some() {
            return;
        }
        let bytes =
            keys::modifier_key_bytes(self.grid.borrow_mut().terminal.vt_mut(), before, event.modifiers);
        self.grid.borrow().terminal.write(&bytes);
        if self.grid.borrow().hover.is_some() {
            // The link modifier underlines (or stops underlining) the link under the pointer.
            cx.notify();
        }
    }

    // MARK: - Mouse

    /// Sends a mouse event to a program that tracks the mouse. Returns whether it did
    /// (Shift keeps the mouse for selecting).
    fn mouse(
        &mut self,
        action: GhosttyMouseAction,
        button: Option<MouseButton>,
        pos: Point<Pixels>,
        mods: Modifiers,
    ) -> bool {
        let mut g = self.grid.borrow_mut();
        if !track_mouse_button(&mut g.buttons_down, action, button) {
            return false;
        }
        if !g.terminal.vt().mouse_tracking() || mods.shift {
            return false;
        }
        let b = button.map(|b| match b {
            MouseButton::Left => GHOSTTY_MOUSE_BUTTON_LEFT,
            MouseButton::Right => GHOSTTY_MOUSE_BUTTON_RIGHT,
            MouseButton::Middle => GHOSTTY_MOUSE_BUTTON_MIDDLE,
            MouseButton::Navigate(NavigationDirection::Back) => GHOSTTY_MOUSE_BUTTON_FOUR,
            MouseButton::Navigate(NavigationDirection::Forward) => GHOSTTY_MOUSE_BUTTON_FIVE,
        });
        let ((x, y), size) = mouse_at(&g, pos);
        let any = !g.buttons_down.is_empty();
        let bytes = g.terminal.vt_mut().encode_mouse(action, b, keys::mouse_mods(mods), x, y, size, any);
        g.terminal.write(&bytes);
        true
    }

    /// Releases a left press whose release went elsewhere (focus loss).
    fn release_tracked_left_button(&mut self) {
        if self.mouse_button.release_left_button() {
            let pos = self.selection_pointer;
            self.mouse(GHOSTTY_MOUSE_ACTION_RELEASE, Some(MouseButton::Left), pos, Modifiers::default());
        }
        if self.selecting {
            self.selecting = false;
            self.selection_scroll = None;
        }
    }

    /// The link at a window position, and where it shows.
    fn link_at(&self, pos: Point<Pixels>) -> Option<(links::Target, vt::Spans)> {
        let g = self.grid.borrow();
        let (x, y) = local(&g, pos);
        let (col, row) = (x / f32::from(g.cell.width), y / f32::from(g.cell.height));
        let hit = g.terminal.vt().link_at(col as u16, row as u16, |text, at| {
            let range = links::find(text, at)?;
            links::resolve(&text[range.clone()], self.cwd.as_deref()).map(|_| range)
        })?;
        let target = if hit.hyperlink {
            links::resolve(&hit.target, self.cwd.as_deref()).unwrap_or(links::Target::Url(hit.target.clone()))
        } else {
            links::resolve(&hit.target, self.cwd.as_deref())?
        };
        Some((target, hit.spans))
    }

    fn start_selection(&mut self, pos: Point<Pixels>, cx: &mut Context<Self>) {
        self.selecting = true;
        self.selection_pointer = pos;
        self.select(Select::Press, pos, cx);
        self.selection_scroll = Some(cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(Duration::from_millis(50)).await;
                let keep = this
                    .update(cx, |this, cx| {
                        if !this.selecting {
                            return false;
                        }
                        let lines = {
                            let g = this.grid.borrow();
                            let y = f32::from(this.selection_pointer.y - g.origin.y);
                            selection_scroll_lines(y, f32::from(g.cell.height), g.terminal.size().rows)
                        };
                        if lines != 0 {
                            this.scroll_lines(lines);
                            this.select(Select::Drag, this.selection_pointer, cx);
                        }
                        true
                    })
                    .unwrap_or(false);
                if !keep {
                    break;
                }
            }
        }));
    }

    fn finish_selection(&mut self, pos: Point<Pixels>, cx: &mut Context<Self>) {
        self.selecting = false;
        self.selection_scroll = None;
        self.grid.borrow_mut().buttons_down.retain(|b| *b != MouseButton::Left);
        self.select(Select::Release, pos, cx);
        if self.copy_mode.is_none() {
            self.copy_on_select(cx);
        }
    }

    fn copy_on_select(&mut self, cx: &mut Context<Self>) {
        let Some(text) = self.selection_text() else { return };
        match self.settings.copy_on_select {
            CopyOnSelect::False => {}
            CopyOnSelect::True => write_clipboard(ClipboardLocation::Selection, text, cx),
            CopyOnSelect::Clipboard => {
                write_clipboard(ClipboardLocation::Selection, text.clone(), cx);
                write_clipboard(ClipboardLocation::Standard, text, cx);
            }
        }
    }

    /// Selecting with the mouse (when the program doesn't take it).
    fn select(&mut self, step: Select, pos: Point<Pixels>, cx: &mut Context<Self>) {
        {
            let mut g = self.grid.borrow_mut();
            let (x, y) = local(&g, pos);
            let (cw, ch) = (f32::from(g.cell.width), f32::from(g.cell.height));
            let (col, row) = ((x / cw) as u16, (y / ch) as u16);
            let height = ch * g.terminal.size().rows as f32;
            g.terminal.vt_mut().select(step, col, row, x, y, cw, height);
        }
        if self.copy_mode.is_some() {
            self.update_copy_mode_mouse(pos, matches!(step, Select::Press), cx);
        }
        cx.notify();
    }

    fn mouse_down_left(&mut self, ev: &MouseDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        if self.destroyed {
            return;
        }
        cx.emit(TerminalEvent::FocusRequested);
        self.focus.focus(window, cx);
        if link_mods(&ev.modifiers)
            && let Some((target, _)) = self.link_at(ev.position)
        {
            links::open(&target);
            return;
        }
        self.mouse_button.press_left_button();
        self.selection_pointer = ev.position;
        if self.mouse(GHOSTTY_MOUSE_ACTION_PRESS, Some(MouseButton::Left), ev.position, ev.modifiers) {
            // The program took the click: the old selection ends, so a copy can't repeat it.
            self.clear_selection(cx);
            if self.copy_mode.is_some() {
                self.update_copy_mode_mouse(ev.position, true, cx);
            }
        } else {
            self.start_selection(ev.position, cx);
        }
    }

    fn scroll_event(&mut self, ev: &ScrollEvent, _window: &mut Window, cx: &mut Context<Self>) {
        cx.stop_propagation();
        if self.destroyed {
            return;
        }
        let mut g = self.grid.borrow_mut();
        let size = g.terminal.size();
        let steps =
            scroll_delta_steps(&mut self.scrolled, ev.delta, ev.touch_phase, g.cell, size.cols, size.rows);
        let n = steps.y.unsigned_abs() as usize;
        if steps.x == 0 && n == 0 {
            return;
        }
        let up = steps.y > 0;
        if g.terminal.vt().mouse_tracking() && !ev.modifiers.shift {
            let ((x, y), sz) = mouse_at(&g, ev.position);
            let out = scroll_mouse_bytes(g.terminal.vt_mut(), steps, ev.modifiers, x, y, sz);
            g.terminal.write(&out);
        } else if n == 0 {
            return;
        } else if g.terminal.vt().alt_screen() && g.terminal.vt().alternate_scroll() {
            let key = if up { GHOSTTY_KEY_ARROW_UP } else { GHOSTTY_KEY_ARROW_DOWN };
            let mut out = Vec::new();
            for _ in 0..n {
                out.extend(g.terminal.vt_mut().encode_key(GHOSTTY_KEY_ACTION_PRESS, key, 0, 0, None, None));
            }
            g.terminal.write(&out);
        } else {
            g.terminal.vt_mut().scroll_viewport(if up { -(n as isize) } else { n as isize });
        }
        drop(g);
        cx.notify();
    }

    fn fit(&mut self, bounds: Bounds<Pixels>, cell: Size<Pixels>, scale: f32, cx: &mut Context<Self>) {
        let (cols, rows) = grid_size(&self.settings, bounds.size, cell);
        let size = TerminalSize {
            cols,
            rows,
            cell_width: device(cell.width, scale),
            cell_height: device(cell.height, scale),
        };
        let changed = {
            let mut g = self.grid.borrow_mut();
            g.cell = cell;
            g.scale = scale;
            let changed = g.terminal.size() != size;
            g.terminal.resize(size);
            changed
        };
        if changed {
            self.end_copy_mode_if_grid_changed(cx);
        }
    }
}

// MARK: - Helpers

/// A length in device pixels.
fn device(v: Pixels, scale: f32) -> u32 {
    (f32::from(v) * scale).round().max(1.0) as u32
}

fn write_clipboard(location: ClipboardLocation, text: String, cx: &mut App) {
    match location {
        ClipboardLocation::Standard => cx.write_to_clipboard(ClipboardItem::new_string(text)),
        ClipboardLocation::Selection => {
            #[cfg(any(target_os = "linux", target_os = "freebsd"))]
            cx.write_to_primary(ClipboardItem::new_string(text.clone()));
            SELECTION_CLIPBOARD.with(|s| *s.borrow_mut() = text);
        }
    }
}

fn read_clipboard(selection: bool, cx: &mut App) -> String {
    if selection {
        #[cfg(any(target_os = "linux", target_os = "freebsd"))]
        if let Some(text) = cx.read_from_primary().and_then(|i| i.text()) {
            return text;
        }
        return SELECTION_CLIPBOARD.with(|s| s.borrow().clone());
    }
    cx.read_from_clipboard().and_then(|i| i.text()).unwrap_or_default()
}

/// Where a content row shows: the lines to scroll to bring it into a viewport of `rows`
/// starting at screen row `top`, and its viewport row afterwards.
fn viewport_row_for(screen_row: u32, top: u32, rows: usize) -> (isize, isize) {
    let rows = rows.max(1) as isize;
    let row = screen_row as isize - top as isize;
    if row < 0 {
        (row, 0)
    } else if row >= rows {
        (row - rows + 1, rows - 1)
    } else {
        (0, row)
    }
}

/// Whether pasting `text` waits for the user (Ghostty's paste protection). A bracketed
/// paste is trusted when `clipboard-paste-bracketed-safe` is on, unless the text carries
/// the end marker that would let it out of the brackets.
fn paste_needs_confirmation(text: &str, settings: &TerminalSettings, bracketed: bool) -> bool {
    if !settings.clipboard_paste_protection {
        return false;
    }
    if text.contains("\x1b[201~") {
        return true;
    }
    !(settings.clipboard_paste_bracketed_safe && bracketed) && !vt::paste_is_safe(text)
}

/// Text submitted as one line: every line break (any of Unicode's) joins its neighbors with
/// one space, empty lines vanish, and the ends are trimmed.
fn submission_line(raw: &str) -> String {
    let newline =
        |c: char| matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}');
    raw.split(newline).filter(|line| !line.is_empty()).collect::<Vec<_>>().join(" ").trim().to_owned()
}

/// The messages of one output turn: the first, then whatever is queued until `budget` runs
/// out. Lazy, so the budget limits parsing; a turn can overshoot by one message.
fn output_turn(
    first: PtyMessage,
    rx: &async_channel::Receiver<PtyMessage>,
    budget: Duration,
) -> impl Iterator<Item = PtyMessage> + '_ {
    let deadline = Instant::now() + budget;
    let mut first = Some(first);
    std::iter::from_fn(move || {
        if let Some(first) = first.take() {
            return Some(first);
        }
        if Instant::now() >= deadline {
            return None;
        }
        rx.try_recv().ok()
    })
}

// Held-button events belong to the pane that received the press.
fn track_mouse_button(
    buttons: &mut Vec<MouseButton>,
    action: GhosttyMouseAction,
    button: Option<MouseButton>,
) -> bool {
    if let Some(button) = button {
        if action == GHOSTTY_MOUSE_ACTION_PRESS {
            if !buttons.contains(&button) {
                buttons.push(button);
            }
        } else if !buttons.contains(&button) {
            return false;
        } else if action == GHOSTTY_MOUSE_ACTION_RELEASE {
            buttons.retain(|b| *b != button);
        }
    }
    true
}

/// Command-click on macOS, Ctrl-click elsewhere, opens links (Ghostty's link modifier).
fn link_mods(m: &Modifiers) -> bool {
    let key = if cfg!(target_os = "macos") { m.platform && !m.control } else { m.control && !m.platform };
    key && !m.alt && !m.shift
}

fn local(g: &Grid, p: Point<Pixels>) -> (f32, f32) {
    (f32::from(p.x - g.origin.x).max(0.0), f32::from(p.y - g.origin.y).max(0.0))
}

/// A pointer position and the grid for mouse reports, in device pixels.
fn mouse_at(g: &Grid, p: Point<Pixels>) -> ((f32, f32), (u32, u32, f32, f32)) {
    let ((x, y), s) = (local(g, p), g.scale);
    let size = g.terminal.size();
    (
        (x * s, y * s),
        (size.cols as u32, size.rows as u32, f32::from(g.cell.width) * s, f32::from(g.cell.height) * s),
    )
}

fn grid_size(settings: &TerminalSettings, bounds: Size<Pixels>, cell: Size<Pixels>) -> (u16, u16) {
    let p = settings.padding;
    let cols = ((f32::from(bounds.width) - p.left - p.right) / f32::from(cell.width)).floor().max(2.0) as u16;
    let rows =
        ((f32::from(bounds.height) - p.top - p.bottom) / f32::from(cell.height)).floor().max(1.0) as u16;
    (cols, rows)
}

fn selection_scroll_lines(y: f32, cell_height: f32, rows: u16) -> isize {
    let height = cell_height * rows as f32;
    let outside = if y < 0.0 {
        y
    } else if y >= height {
        y - height + 1.0
    } else {
        return 0;
    };
    (outside / cell_height).abs().ceil().clamp(1.0, 5.0) as isize * if outside < 0.0 { -1 } else { 1 }
}

/// Whole lines (and columns) for one scroll event. Trackpad pixels count double, as in
/// Ghostty's macOS app (`TerminalInputMetadata.scrollDeltas`), and add up to a line before
/// one scrolls; each gesture starts from nothing.
fn scroll_delta_steps(
    scrolled: &mut Point<f32>,
    delta: ScrollDelta,
    phase: TouchPhase,
    cell: Size<Pixels>,
    cols: u16,
    rows: u16,
) -> Point<i32> {
    let lines = match delta {
        // As in Ghostty, a sideways notch moves one column; a vertical one, three lines.
        ScrollDelta::Lines(p) if cfg!(target_os = "macos") => {
            return point(macos_wheel_steps(p.x) / 3, macos_wheel_steps(p.y));
        }
        ScrollDelta::Lines(p) => p,
        ScrollDelta::Pixels(p) => {
            let (x, y) = crate::input_metadata::scroll_deltas(
                f64::from(f32::from(p.x)),
                f64::from(f32::from(p.y)),
                true,
            );
            point(x as f32 / f32::from(cell.width), y as f32 / f32::from(cell.height))
        }
    };
    point(
        scroll_steps(&mut scrolled.x, phase, lines.x, cols as f32),
        scroll_steps(&mut scrolled.y, phase, lines.y, rows as f32),
    )
}

fn scroll_mouse_bytes(
    vt: &mut vt::Vt,
    steps: Point<i32>,
    mods: Modifiers,
    x: f32,
    y: f32,
    size: (u32, u32, f32, f32),
) -> Vec<u8> {
    let mut out = Vec::new();
    for (steps, positive, negative) in [
        (steps.y, GHOSTTY_MOUSE_BUTTON_FOUR, GHOSTTY_MOUSE_BUTTON_FIVE),
        (steps.x, GHOSTTY_MOUSE_BUTTON_SIX, GHOSTTY_MOUSE_BUTTON_SEVEN),
    ] {
        let button = if steps > 0 { positive } else { negative };
        for _ in 0..steps.unsigned_abs() {
            out.extend(vt.encode_mouse(
                GHOSTTY_MOUSE_ACTION_PRESS,
                Some(button),
                keys::mouse_mods(mods),
                x,
                y,
                size,
                false,
            ));
        }
    }
    out
}

/// Whole lines to scroll for one scroll event: small moves add up to a line before one
/// scrolls, and each gesture starts from nothing. Kept under a screen, so turning back is
/// quick.
fn scroll_steps(scrolled: &mut f32, phase: TouchPhase, lines: f32, rows: f32) -> i32 {
    match phase {
        TouchPhase::Started => {
            *scrolled = 0.0;
            0
        }
        TouchPhase::Moved => {
            let before = scrolled.trunc() as i32;
            *scrolled += lines;
            let after = scrolled.trunc() as i32;
            *scrolled %= rows.max(1.0);
            after - before
        }
        _ => 0,
    }
}

/// Lines for a macOS mouse wheel event, as Ghostty scrolls them: at least one tick, times
/// Ghostty's wheel multiplier of 3, the fraction dropped.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn macos_wheel_steps(ticks: f32) -> i32 {
    if ticks == 0.0 {
        return 0;
    }
    (ticks.signum() * ticks.abs().max(1.0) * 3.0).trunc() as i32
}

/// The bundled icon font every terminal falls back to, as Ghostty's embedded Nerd Font
/// symbols do: prompts draw their Powerline/devicon glyphs under any configured font.
const SYMBOLS_FALLBACK: &str = "Symbols Nerd Font";

fn cell_font(settings: &TerminalSettings, bold: bool, italic: bool) -> Font {
    let mut f = font(settings.font_family.clone());
    // Ligatures off: every character keeps its own cell.
    f.features = FontFeatures(Arc::new(vec![("calt".into(), 0), ("liga".into(), 0), ("dlig".into(), 0)]));
    f.fallbacks = Some(FontFallbacks::from_fonts(vec![SYMBOLS_FALLBACK.to_owned()]));
    f.weight = if bold { FontWeight::BOLD } else { FontWeight::NORMAL };
    f.style = if italic { FontStyle::Italic } else { FontStyle::Normal };
    f
}

/// The cell for the configured font: the advance of `M`, and the font's ascent plus
/// descent rounded up to a device pixel.
pub fn cell_size(settings: &TerminalSettings, window: &Window) -> Size<Pixels> {
    let ts = window.text_system();
    let id = ts.resolve_font(&cell_font(settings, false, false));
    let fs = px(settings.font_size);
    let w = ts.advance(id, fs, 'M').map(|s| s.width).unwrap_or(fs * 0.6);
    let h = ts.ascent(id, fs) + ts.descent(id, fs).abs();
    let scale = window.scale_factor();
    // The width stays the font's own advance: GPUI only moves a glyph onto the grid once
    // it drifts over 1px, so a rounded width made text wobble. Boxes snap their edges.
    size(w, px((f32::from(h) * scale).ceil() / scale))
}

// Force-width shaping moves glyph origins, but does not resize fallback glyphs.
fn fallback_size(
    c: &vt::Cell,
    font: &Font,
    font_size: Pixels,
    width: Pixels,
    ts: &WindowTextSystem,
) -> Option<Pixels> {
    if c.wide || c.text.is_ascii() {
        return None;
    }
    let first = c.text.chars().next()?;
    let primary = ts.resolve_font(font);
    if ts.advance(primary, font_size, first).is_ok() {
        return None;
    }
    let run = TextRun { len: c.text.len(), font: font.clone(), ..Default::default() };
    let line = ts.shape_line(c.text.clone().into(), font_size, &[run], None);
    (line.width() > width).then(|| font_size * f32::from(width) / f32::from(line.width()))
}

/// A row's drawing: its backgrounds, merged into runs of one color, then its text in runs
/// of one style (wide characters and sprites on their own).
fn row_ops(
    settings: &TerminalSettings,
    row: &[vt::Cell],
    cell: Size<Pixels>,
    window: &mut Window,
) -> Vec<RowOp> {
    let font_size = px(settings.font_size);
    let mut ops = Vec::new();
    let mut x = 0;
    while x < row.len() {
        let Some(bg) = row[x].bg else {
            x += 1;
            continue;
        };
        let start = x;
        while x < row.len() && row[x].bg == Some(bg) {
            x += 1;
        }
        ops.push(RowOp::Bg { from: start, to: x, color: hsla(bg) });
    }
    let mut x = 0;
    while x < row.len() {
        let start = x;
        let c = &row[start];
        x += 1;
        if c.text.is_empty() && !c.underline && !c.strike {
            continue;
        }
        let mut color = hsla(c.fg);
        if c.faint {
            color.a = TerminalTheme::FAINT_OPACITY;
        }
        if crate::sprites::is_sprite(&c.text) {
            ops.push(RowOp::Sprite { x: start, text: c.text.clone(), color });
            continue;
        }
        let text_font = cell_font(settings, c.bold, c.italic);
        let fitted = fallback_size(c, &text_font, font_size, cell.width, window.text_system());
        let mut text = if c.text.is_empty() { " ".to_owned() } else { c.text.clone() };
        if !c.wide && fitted.is_none() {
            while x < row.len() {
                let d = &row[x];
                let same = !d.wide
                    && d.fg == c.fg
                    && d.bold == c.bold
                    && d.italic == c.italic
                    && d.faint == c.faint
                    && d.underline == c.underline
                    && d.strike == c.strike;
                if !same
                    || (d.text.is_empty() && !d.underline && !d.strike)
                    || crate::sprites::is_sprite(&d.text)
                    || fallback_size(d, &text_font, font_size, cell.width, window.text_system()).is_some()
                {
                    break;
                }
                text.push_str(if d.text.is_empty() { " " } else { &d.text });
                x += 1;
            }
        }
        if text.trim_matches(' ').is_empty() && !c.underline && !c.strike {
            continue;
        }
        let run = TextRun {
            len: text.len(),
            font: text_font,
            color,
            background_color: None,
            underline: c.underline.then_some(UnderlineStyle {
                thickness: px(1.0),
                color: Some(color),
                wavy: false,
            }),
            strikethrough: c.strike.then_some(StrikethroughStyle { thickness: px(1.0), color: Some(color) }),
        };
        let force = (!c.wide).then_some(cell.width);
        let line = window.text_system().shape_line(text.into(), fitted.unwrap_or(font_size), &[run], force);
        ops.push(RowOp::Text { x: start, line: Box::new(line) });
    }
    ops
}

/// What paint needs from the view besides the grid.
struct PaintState {
    settings: TerminalSettings,
    focused: bool,
    blink_visible: bool,
    copy_cursor: Option<(usize, usize)>,
}

fn paint_grid(
    bounds: Bounds<Pixels>,
    grid: &Rc<RefCell<Grid>>,
    state: &PaintState,
    window: &mut Window,
    cx: &mut App,
) {
    let settings = &state.settings;
    let theme = &settings.theme;
    let scale = window.scale_factor();
    let snap = |v: Pixels| px((f32::from(v) * scale).round() / scale);
    let snap_box = |b: Bounds<Pixels>| {
        let (x0, x1) = (snap(b.origin.x), snap(b.origin.x + b.size.width));
        let (y0, y1) = (snap(b.origin.y), snap(b.origin.y + b.size.height));
        Bounds::new(point(x0, y0), size(x1 - x0, y1 - y0))
    };
    let mut g = grid.borrow_mut();
    let cell = g.cell;
    let rows = g.terminal.size().rows;
    // Rows rarely fill the height exactly: split what's left above and below.
    let spare = (f32::from(bounds.size.height)
        - settings.padding.top
        - settings.padding.bottom
        - f32::from(cell.height) * rows as f32)
        .max(0.0);
    let origin =
        bounds.origin + point(px(settings.padding.left), px(settings.padding.top + (spare / 2.0).floor()));
    let origin = point(snap(origin.x), snap(origin.y));
    g.origin = origin;
    let frame = g.terminal.vt_mut().frame();
    g.cursor_blinks = frame.cursor.is_some_and(|c| c.blinking);
    let placements = g.terminal.vt().placements();
    let mut images: Vec<(bool, Bounds<Pixels>, Arc<RenderImage>)> = Vec::new();
    let mut keep = HashSet::new();
    for p in &placements {
        let key = (p.image, p.generation, p.source);
        keep.insert(key);
        if !g.images.contains_key(&key)
            && let Some((w, h, bgra)) = g.terminal.vt().image_bgra(p.image, p.source)
            && let Some(buf) = image::RgbaImage::from_raw(w, h, bgra)
        {
            g.images.insert(key, Arc::new(RenderImage::new(smallvec::smallvec![image::Frame::new(buf)])));
        }
        if let Some(img) = g.images.get(&key) {
            let [x, y, mut width, mut height] =
                p.pixel_geometry(f32::from(cell.width), f32::from(cell.height));
            if p.cell_pixels.is_none() {
                // Direct placements are in device pixels.
                width /= scale;
                height /= scale;
            }
            let pos = origin + point(px(x), px(y));
            // Placeholder runs contain no text and must cover explicit cell backgrounds.
            let below = p.z < 0 && p.cell_pixels.is_none();
            images.push((below, Bounds::new(pos, size(px(width), px(height))), img.clone()));
        }
    }
    g.images.retain(|k, _| keep.contains(k));
    let link_spans = g.link_spans.clone();
    let marked = g.marked.clone();
    let with = (settings.font_family.clone(), settings.font_size.to_bits(), cell);
    let mut painted = std::mem::take(&mut g.painted);
    if g.painted_with != with || frame.all {
        painted.clear();
    }
    drop(g);

    window.paint_quad(fill(bounds, hsla(frame.bg)));
    let at = |x: usize, y: usize| origin + point(cell.width * x as f32, cell.height * y as f32);
    let paint_images = |below: bool, window: &mut Window| {
        for (image_below, b, img) in &images {
            if *image_below == below {
                let _ = window.paint_image(*b, *b, Corners::default(), img.clone(), 0, false);
            }
        }
    };
    paint_images(true, window);

    // Each row's drawing is built once and painted again while the row is the same.
    painted.truncate(frame.rows.len());
    for (y, row) in frame.rows.iter().enumerate() {
        if frame.all || painted.get(y).is_none_or(|(r, _)| !Rc::ptr_eq(r, row)) {
            let ops = row_ops(settings, row, cell, window);
            if y < painted.len() {
                painted[y] = (row.clone(), ops);
            } else {
                painted.push((row.clone(), ops));
            }
        }
    }
    // Backgrounds first, then search highlights, then text.
    for (y, (_, ops)) in painted.iter().enumerate() {
        for op in ops {
            if let RowOp::Bg { from, to, color } = op {
                let b = Bounds::new(at(*from, y), size(cell.width * (to - from) as f32, cell.height));
                window.paint_quad(fill(snap_box(b), *color));
            }
        }
    }
    for selected in [false, true] {
        for span in frame.search_spans.iter().filter(|span| span.selected == selected) {
            let y = span.row as usize;
            let Some(row) = frame.rows.get(y) else { continue };
            let (start, end) = (span.start as usize, (span.end as usize + 1).min(row.len()));
            if start >= end {
                continue;
            }
            let highlight = color_hsla(theme.cursor).opacity(if selected { 0.55 } else { 0.28 });
            let b = Bounds::new(at(start, y), size(cell.width * (end - start) as f32, cell.height));
            window.paint_quad(fill(snap_box(b), highlight));
        }
    }
    for (y, (_, ops)) in painted.iter().enumerate() {
        for op in ops {
            match op {
                RowOp::Bg { .. } => {}
                RowOp::Sprite { x, text, color } => {
                    crate::sprites::paint(text, Bounds::new(at(*x, y), cell), *color, window)
                }
                RowOp::Text { x, line } => {
                    let _ = line.paint(at(*x, y), cell.height, TextAlign::Left, None, window, cx);
                }
            }
        }
    }
    {
        let mut g = grid.borrow_mut();
        (g.painted, g.painted_with) = (painted, with);
    }

    for &(y, x0, x1) in &link_spans {
        let Some(row) = frame.rows.get(y as usize) else { continue };
        let color = row.get(x0 as usize).map_or(hsla(frame.fg), |c| hsla(c.fg));
        let (x0, x1) = (x0 as usize, (x1 as usize + 1).min(row.len()));
        let line = Bounds::new(
            at(x0, y as usize) + point(px(0.0), cell.height - px(2.0)),
            size(cell.width * (x1 - x0) as f32, px(1.0)),
        );
        window.paint_quad(fill(snap_box(line), color));
    }

    paint_images(false, window);

    if let Some(cur) = frame.cursor.filter(|_| state.copy_cursor.is_none()) {
        let (x, y) = (cur.x as usize, cur.y as usize);
        let wide = frame.rows.get(y).and_then(|r| r.get(x)).is_some_and(|c| c.wide);
        let w = cell.width * if wide { 2.0 } else { 1.0 };
        let p = at(x, y);
        let blink_hidden = state.focused && cur.blinking && !state.blink_visible;
        if !state.focused {
            // Unfocused: a hollow block in fg @ 55 %, never the accent.
            window.paint_quad(outline(
                snap_box(Bounds::new(p, size(w, cell.height))),
                color_hsla(theme.unfocused_cursor()),
                BorderStyle::Solid,
            ));
        } else if !blink_hidden {
            let color = hsla(cur.color);
            match cur.shape {
                CursorShape::Block => {
                    window.paint_quad(fill(snap_box(Bounds::new(p, size(w, cell.height))), color));
                    if let Some(c) = frame.rows.get(y).and_then(|r| r.get(x)).filter(|c| !c.text.is_empty()) {
                        let run = TextRun {
                            len: c.text.len(),
                            font: cell_font(settings, c.bold, c.italic),
                            color: color_hsla(theme.cursor_text),
                            background_color: None,
                            underline: None,
                            strikethrough: None,
                        };
                        let line = window.text_system().shape_line(
                            c.text.clone().into(),
                            px(settings.font_size),
                            &[run],
                            None,
                        );
                        let _ = line.paint(p, cell.height, TextAlign::Left, None, window, cx);
                    }
                }
                CursorShape::Bar => {
                    window.paint_quad(fill(snap_box(Bounds::new(p, size(px(2.0), cell.height))), color))
                }
                CursorShape::Underline => window.paint_quad(fill(
                    snap_box(Bounds::new(p + point(px(0.0), cell.height - px(2.0)), size(w, px(2.0)))),
                    color,
                )),
                CursorShape::Hollow => window.paint_quad(outline(
                    snap_box(Bounds::new(p, size(w, cell.height))),
                    color,
                    BorderStyle::Solid,
                )),
            }
        }
    }
    // Copy mode's cursor: the caret edge over a selection fill.
    if let Some((x, y)) = state.copy_cursor {
        let b = snap_box(Bounds::new(at(x, y), cell));
        window.paint_quad(fill(b, color_hsla(theme.selection_background)));
        window.paint_quad(outline(b, color_hsla(theme.cursor), BorderStyle::Solid));
    }
    // What an input method is composing, at the cursor, underlined on the background.
    if let (Some((cx_, cy_)), Some(text)) = (frame.cursor_cell, marked.filter(|t| !t.is_empty())) {
        let p = at(cx_ as usize, cy_ as usize);
        let fg = hsla(frame.fg);
        let run = TextRun {
            len: text.len(),
            font: cell_font(settings, false, false),
            color: fg,
            background_color: None,
            underline: Some(UnderlineStyle { thickness: px(1.0), color: Some(fg), wavy: false }),
            strikethrough: None,
        };
        let line = window.text_system().shape_line(text.into(), px(settings.font_size), &[run], None);
        window.paint_quad(fill(snap_box(Bounds::new(p, size(line.width, cell.height))), hsla(frame.bg)));
        let _ = line.paint(p, cell.height, TextAlign::Left, None, window, cx);
    }
    grid.borrow_mut().cursor_at =
        frame.cursor_cell.map(|(x, y)| Bounds::new(at(x as usize, y as usize), cell));
}

/// OS text input (dead keys, Pinyin, Japanese, Korean) types here. The program gets the
/// finished text; what is still being composed shows at the cursor.
impl EntityInputHandler for TerminalView {
    fn text_for_range(
        &mut self,
        range: std::ops::Range<usize>,
        adjusted: &mut Option<std::ops::Range<usize>>,
        _w: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<String> {
        let marked = self.grid.borrow().marked.clone().unwrap_or_default();
        let units: Vec<u16> = marked.encode_utf16().collect();
        let range = range.start.min(units.len())..range.end.min(units.len());
        *adjusted = Some(range.clone());
        Some(String::from_utf16_lossy(&units[range]))
    }

    fn selected_text_range(
        &mut self,
        _ignore_disabled: bool,
        _w: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<UTF16Selection> {
        let len = self.grid.borrow().marked.as_ref().map_or(0, |m| m.encode_utf16().count());
        Some(UTF16Selection { range: len..len, reversed: false })
    }

    fn marked_text_range(&self, _w: &mut Window, _cx: &mut Context<Self>) -> Option<std::ops::Range<usize>> {
        self.grid.borrow().marked.as_ref().filter(|m| !m.is_empty()).map(|m| 0..m.encode_utf16().count())
    }

    fn unmark_text(&mut self, _w: &mut Window, cx: &mut Context<Self>) {
        self.grid.borrow_mut().marked = None;
        cx.notify();
    }

    fn replace_text_in_range(
        &mut self,
        _range: Option<std::ops::Range<usize>>,
        text: &str,
        _w: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.grid.borrow_mut().marked = None;
        if self.copy_mode.is_some() {
            return;
        }
        self.write(text.as_bytes());
        cx.notify();
    }

    fn replace_and_mark_text_in_range(
        &mut self,
        _range: Option<std::ops::Range<usize>>,
        text: &str,
        _selected: Option<std::ops::Range<usize>>,
        _w: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.grid.borrow_mut().marked = (!text.is_empty()).then(|| text.to_owned());
        cx.notify();
    }

    fn bounds_for_range(
        &mut self,
        range: std::ops::Range<usize>,
        _element: Bounds<Pixels>,
        _w: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<Bounds<Pixels>> {
        let g = self.grid.borrow();
        let at = g.cursor_at?;
        Some(Bounds::new(at.origin + point(g.cell.width * range.start as f32, px(0.0)), at.size))
    }

    fn character_index_for_point(
        &mut self,
        _point: Point<Pixels>,
        _w: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<usize> {
        None
    }
}

impl Render for TerminalView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.sync_focus(window, cx);
        let focused = self.focus_tracker.last() == Some(true);
        let cell = cell_size(&self.settings, window);
        let hover = self.grid.borrow().hover;
        let found = hover.filter(|_| link_mods(&window.modifiers())).and_then(|pos| self.link_at(pos));
        let (link, spans) = found.unzip();
        self.link = link;
        self.grid.borrow_mut().link_spans = spans.unwrap_or_default();
        let copy_cursor = self
            .copy_mode
            .as_ref()
            .filter(|m| m.session.phase() == CopyModePhase::Navigating)
            .map(|m| (m.session.column(), m.session.row()));
        let state = PaintState {
            settings: self.settings.clone(),
            focused,
            blink_visible: self.blink_visible,
            copy_cursor,
        };
        let grid_paint = self.grid.clone();
        let view = cx.entity().downgrade();
        let fit_view = view.clone();
        let (input_focus, input_view) = (self.focus.clone(), cx.entity());
        let terminal_focused = self.focus.is_focused(window);
        let bg = color_hsla(self.settings.theme.background);

        div()
            .id(("terminal", cx.entity_id()))
            .track_focus(&self.focus)
            .key_context(KEY_CONTEXT)
            .size_full()
            .bg(bg)
            .cursor(if self.link.is_some() { CursorStyle::PointingHand } else { CursorStyle::IBeam })
            .on_action(cx.listener(|this, _: &Copy, _, cx| {
                this.copy_selection(cx);
            }))
            .on_action(cx.listener(|this, _: &Paste, _, cx| this.paste_from_clipboard(cx)))
            .on_action(cx.listener(|this, _: &SelectAll, _, cx| this.select_all(cx)))
            .on_action(cx.listener(|this, _: &ClearScreen, _, cx| this.clear_screen(cx)))
            .on_action(cx.listener(|this, _: &ScrollToTop, _, cx| this.scroll_to_top(cx)))
            .on_action(cx.listener(|this, _: &ScrollToBottom, _, cx| this.scroll_to_bottom(cx)))
            .on_action(cx.listener(|this, _: &ScrollPageUp, _, cx| this.scroll_pages(-1, cx)))
            .on_action(cx.listener(|this, _: &ScrollPageDown, _, cx| this.scroll_pages(1, cx)))
            .on_key_down(cx.listener(Self::key_down))
            .on_key_up(cx.listener(Self::key_up))
            .on_modifiers_changed(cx.listener(Self::modifiers_changed))
            .on_drop(cx.listener(|this, paths: &ExternalPaths, window, cx| {
                this.drop_payload(&DropPayload::files(paths.paths().to_vec()), window, cx)
            }))
            .on_scroll(cx.listener(Self::scroll_event))
            .on_hover(cx.listener(|this, hovered: &bool, _, cx| {
                if !hovered {
                    this.grid.borrow_mut().hover = None;
                    if this.link.is_some() {
                        cx.notify();
                    }
                }
            }))
            .on_mouse_down(MouseButton::Left, cx.listener(Self::mouse_down_left))
            .on_mouse_down(
                MouseButton::Right,
                cx.listener(|this, ev: &MouseDownEvent, _, _| {
                    this.mouse(GHOSTTY_MOUSE_ACTION_PRESS, Some(ev.button), ev.position, ev.modifiers);
                }),
            )
            .on_mouse_down(
                MouseButton::Middle,
                cx.listener(|this, ev: &MouseDownEvent, _, cx| {
                    if !this.mouse(GHOSTTY_MOUSE_ACTION_PRESS, Some(ev.button), ev.position, ev.modifiers) {
                        this.paste_selection_clipboard(cx);
                    }
                }),
            )
            .on_mouse_move(cx.listener(|this, ev: &MouseMoveEvent, _, cx| {
                this.grid.borrow_mut().hover = Some(ev.position);
                if link_mods(&ev.modifiers) || this.link.is_some() {
                    cx.notify();
                }
                if !this.selecting && ev.pressed_button.is_none() {
                    this.mouse(GHOSTTY_MOUSE_ACTION_MOTION, None, ev.position, ev.modifiers);
                }
            }))
            .child(
                canvas(
                    move |bounds, window, cx| {
                        let scale = window.scale_factor();
                        let _ = fit_view.update(cx, |this, cx| this.fit(bounds, cell, scale, cx));
                    },
                    move |bounds, _, window, cx| {
                        paint_grid(bounds, &grid_paint, &state, window, cx);
                        let move_view = view.clone();
                        window.on_mouse_event(move |ev: &MouseMoveEvent, phase, _, cx| {
                            if phase != DispatchPhase::Capture {
                                return;
                            }
                            let _ = move_view.update(cx, |this, cx| {
                                // A press whose release went elsewhere ends here.
                                let buttons = u32::from(ev.pressed_button == Some(MouseButton::Left));
                                if this.mouse_button.reconcile(buttons) {
                                    this.mouse(
                                        GHOSTTY_MOUSE_ACTION_RELEASE,
                                        Some(MouseButton::Left),
                                        ev.position,
                                        ev.modifiers,
                                    );
                                    if this.selecting {
                                        this.finish_selection(ev.position, cx);
                                    }
                                    return;
                                }
                                if !this.selecting
                                    && ev.pressed_button.is_some()
                                    && !this.grid.borrow().buttons_down.is_empty()
                                {
                                    this.mouse(
                                        GHOSTTY_MOUSE_ACTION_MOTION,
                                        ev.pressed_button,
                                        ev.position,
                                        ev.modifiers,
                                    );
                                }
                                if this.selecting {
                                    this.selection_pointer = ev.position;
                                    if ev.pressed_button == Some(MouseButton::Left) {
                                        this.select(Select::Drag, ev.position, cx);
                                    }
                                }
                            });
                        });
                        let up_view = view.clone();
                        window.on_mouse_event(move |ev: &MouseUpEvent, phase, _, cx| {
                            if phase != DispatchPhase::Capture {
                                return;
                            }
                            let _ = up_view.update(cx, |this, cx| {
                                if ev.button == MouseButton::Left {
                                    this.mouse_button.release_left_button();
                                }
                                if (!this.selecting || ev.button != MouseButton::Left)
                                    && this.grid.borrow().buttons_down.contains(&ev.button)
                                {
                                    this.mouse(
                                        GHOSTTY_MOUSE_ACTION_RELEASE,
                                        Some(ev.button),
                                        ev.position,
                                        ev.modifiers,
                                    );
                                    if this.copy_mode.is_some() && ev.button == MouseButton::Left {
                                        this.update_copy_mode_mouse(ev.position, false, cx);
                                    }
                                }
                                if this.selecting && ev.button == MouseButton::Left {
                                    this.finish_selection(ev.position, cx);
                                }
                            });
                        });
                        if terminal_focused {
                            window.handle_input(
                                &input_focus,
                                ElementInputHandler::new(bounds, input_view),
                                cx,
                            );
                        }
                    },
                )
                .size_full(),
            )
            .when(self.destroyed, |d| d.opacity(0.6))
    }
}

#[cfg(test)]
mod tests {
    use super::{
        grid_size, link_mods, macos_wheel_steps, output_turn, paste_needs_confirmation, scroll_delta_steps,
        scroll_steps, selection_scroll_lines, submission_line, track_mouse_button, viewport_row_for,
    };
    use crate::settings::TerminalSettings;
    use ghostty_sys::*;
    use gpui::{Modifiers, MouseButton, ScrollDelta, TouchPhase, point, px, size};

    #[test]
    fn touchpad_moves_add_up_to_whole_lines() {
        let mut s = 0.0;
        assert_eq!(scroll_steps(&mut s, TouchPhase::Started, 0.0, 40.0), 0);
        let total: i32 = (0..12).map(|_| scroll_steps(&mut s, TouchPhase::Moved, 0.25, 40.0)).sum();
        assert_eq!(total, 3, "twelve quarter lines: not twelve lines");
        assert_eq!(scroll_steps(&mut s, TouchPhase::Started, 0.0, 40.0), 0);
        assert_eq!(scroll_steps(&mut s, TouchPhase::Moved, -0.5, 40.0), 0);
        assert_eq!(scroll_steps(&mut s, TouchPhase::Moved, -0.6, 40.0), -1);
    }

    #[test]
    fn trackpad_pixels_count_double_toward_whole_lines() {
        let mut scrolled = point(0.0, 0.0);
        let cell = size(px(10.0), px(20.0));
        let steps = scroll_delta_steps(
            &mut scrolled,
            ScrollDelta::Pixels(point(px(0.0), px(20.0))),
            TouchPhase::Moved,
            cell,
            80,
            24,
        );
        assert_eq!(steps, point(0, 2));
    }

    #[test]
    fn macos_wheel_events_scroll_as_in_ghostty() {
        assert_eq!(macos_wheel_steps(0.1), 3);
        assert_eq!(macos_wheel_steps(-0.1), -3);
        assert_eq!(macos_wheel_steps(1.5), 4);
        assert_eq!(macos_wheel_steps(0.0), 0);
    }

    #[test]
    fn mouse_buttons_only_follow_the_pane_that_took_each_press() {
        let mut buttons = Vec::new();
        assert!(!track_mouse_button(&mut buttons, GHOSTTY_MOUSE_ACTION_MOTION, Some(MouseButton::Left)));
        assert!(!track_mouse_button(&mut buttons, GHOSTTY_MOUSE_ACTION_RELEASE, Some(MouseButton::Left)));
        assert!(track_mouse_button(&mut buttons, GHOSTTY_MOUSE_ACTION_PRESS, Some(MouseButton::Left)));
        assert!(track_mouse_button(&mut buttons, GHOSTTY_MOUSE_ACTION_MOTION, Some(MouseButton::Left)));
        assert!(track_mouse_button(&mut buttons, GHOSTTY_MOUSE_ACTION_RELEASE, Some(MouseButton::Left)));
        assert!(buttons.is_empty());
        assert!(track_mouse_button(&mut buttons, GHOSTTY_MOUSE_ACTION_MOTION, None));
    }

    #[test]
    fn selection_autoscroll_only_runs_outside_the_grid_and_caps_speed() {
        assert_eq!(selection_scroll_lines(10.0, 20.0, 10), 0);
        assert_eq!(selection_scroll_lines(-1.0, 20.0, 10), -1);
        assert_eq!(selection_scroll_lines(-500.0, 20.0, 10), -5);
        assert_eq!(selection_scroll_lines(200.0, 20.0, 10), 1);
    }

    #[test]
    fn the_link_modifier_is_command_on_macos_and_control_elsewhere() {
        let cmd = Modifiers { platform: true, ..Modifiers::default() };
        let ctrl = Modifiers { control: true, ..Modifiers::default() };
        assert_eq!(link_mods(&cmd), cfg!(target_os = "macos"));
        assert_eq!(link_mods(&ctrl), !cfg!(target_os = "macos"));
        assert!(!link_mods(&Modifiers { shift: true, ..cmd }));
    }

    #[test]
    fn the_grid_fills_the_bounds_inside_the_padding() {
        let settings = TerminalSettings::default();
        let cols_rows = grid_size(&settings, size(px(828.0), px(504.0)), size(px(8.0), px(16.0)));
        assert_eq!(cols_rows, (100, 30));
    }

    #[test]
    fn submitted_text_becomes_one_line_without_doubled_spaces() {
        assert_eq!(submission_line("a\r\nb"), "a b");
        assert_eq!(submission_line("  fix\n\n the tests \u{2028}now\n"), "fix  the tests  now");
        assert_eq!(submission_line("\n\r\n"), "");
    }

    #[test]
    fn an_embedded_bracketed_paste_end_always_asks_first() {
        let settings = TerminalSettings::default();
        assert!(paste_needs_confirmation("ls\x1b[201~rm -rf ~", &settings, true));
        assert!(!paste_needs_confirmation("ls\nmake", &settings, true), "bracketed pastes are safe");
        assert!(paste_needs_confirmation("ls\nmake", &settings, false));
        assert!(!paste_needs_confirmation("ls -la", &settings, false));
        let off = TerminalSettings { clipboard_paste_protection: false, ..TerminalSettings::default() };
        assert!(!paste_needs_confirmation("ls\x1b[201~", &off, true));
    }

    #[test]
    fn the_copy_cursor_follows_its_content_when_the_viewport_moves() {
        // Content row 50 with the viewport at 40..64: row 10, no scrolling.
        assert_eq!(viewport_row_for(50, 40, 24), (0, 10));
        // Output scrolled the viewport down past it: scroll back up to show it on top.
        assert_eq!(viewport_row_for(50, 60, 24), (-10, 0));
        // Scrolled up past it: scroll down so it is the last row.
        assert_eq!(viewport_row_for(80, 40, 24), (17, 23));
    }

    #[test]
    fn an_output_turn_stops_parsing_at_its_deadline() {
        let (tx, rx) = async_channel::bounded(8);
        for _ in 0..4 {
            tx.send_blocking(crate::PtyMessage::Data(vec![b'x'])).unwrap();
        }
        let first = crate::PtyMessage::Data(vec![b'a']);
        assert_eq!(output_turn(first, &rx, std::time::Duration::from_secs(5)).count(), 5);
        tx.send_blocking(crate::PtyMessage::Data(vec![b'x'])).unwrap();
        let first = crate::PtyMessage::Data(vec![b'a']);
        assert_eq!(output_turn(first, &rx, std::time::Duration::ZERO).count(), 1, "the rest waits");
        assert_eq!(rx.len(), 1);
    }
}
