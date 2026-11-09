//! Dialogs (`Views/Shell/ShellDialogs.swift`) in Herdr's dialog card (§11.6): confirm with any
//! number of buttons (destructive ones included, and the Save / Don't Save / Cancel trio),
//! a prompt with a text field and optional validation, and an alert. Return picks the last
//! button, Esc or a click on the 35 % black backdrop cancels, a button's own chord picks it.
//! A dialog answers exactly once.

use std::rc::Rc;

use gpui::{
    App, AppContext as _, Context, DismissEvent, ElementId, Entity, EventEmitter, FocusHandle, Focusable,
    FontWeight, InteractiveElement, IntoElement, KeyDownEvent, Keystroke, Modifiers, MouseButton,
    ParentElement, Render, SharedString, Styled, Subscription, Window, div, prelude::*,
};
use gpui_component::input::{self as component_input, InputEvent, InputState};

use crate::button::{Button, ButtonVariant};
use crate::controls::{InputSize, TextInput};
use crate::fonts::{self, size};
use crate::keycaps::KeyPlatform;
use crate::motion::fade_in;
use crate::theme::ActiveSopranoTheme;

/// A button's look (`ShellDialogButton.Style`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum DialogButtonStyle {
    Primary,
    #[default]
    Outline,
    Destructive,
    DestructiveOutline,
}

impl DialogButtonStyle {
    fn variant(self) -> ButtonVariant {
        match self {
            Self::Primary => ButtonVariant::Primary,
            Self::Outline => ButtonVariant::Secondary,
            Self::Destructive => ButtonVariant::Destructive,
            Self::DestructiveOutline => ButtonVariant::DestructiveOutline,
        }
    }
}

/// A chord besides Return and Esc that picks a button. `command` is ⌘ on macOS and
/// Ctrl+Shift elsewhere (Soprano's cross-platform rule).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DialogShortcut {
    pub key: String,
    pub command: bool,
    pub ctrl: bool,
    pub shift: bool,
}

impl DialogShortcut {
    /// `⌘<key>` (Ctrl+Shift+<key> on Linux and Windows).
    pub fn command(key: &str) -> Self {
        Self { key: key.to_lowercase(), command: true, ctrl: false, shift: false }
    }

    /// Whether `keystroke` is this chord on `platform`.
    pub fn matches(&self, keystroke: &Keystroke, platform: KeyPlatform) -> bool {
        let m = keystroke.modifiers;
        let wanted = match platform {
            KeyPlatform::Mac => Modifiers {
                platform: self.command,
                control: self.ctrl,
                shift: self.shift,
                ..Modifiers::default()
            },
            KeyPlatform::Other => Modifiers {
                control: self.command || self.ctrl,
                shift: self.command || self.shift,
                alt: self.command && self.shift,
                ..Modifiers::default()
            },
        };
        let held = Modifiers {
            control: m.control,
            alt: m.alt,
            shift: m.shift,
            platform: m.platform,
            ..Modifiers::default()
        };
        held == wanted && keystroke.key.eq_ignore_ascii_case(&self.key)
    }
}

/// A dialog button (`ShellDialogButton`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DialogButton {
    pub title: SharedString,
    pub style: DialogButtonStyle,
    pub shortcut: Option<DialogShortcut>,
}

impl DialogButton {
    pub fn new(title: impl Into<SharedString>) -> Self {
        Self { title: title.into(), style: DialogButtonStyle::Outline, shortcut: None }
    }

    pub fn style(mut self, style: DialogButtonStyle) -> Self {
        self.style = style;
        self
    }

    pub fn primary(self) -> Self {
        self.style(DialogButtonStyle::Primary)
    }

    pub fn destructive(self) -> Self {
        self.style(DialogButtonStyle::Destructive)
    }

    pub fn shortcut(mut self, shortcut: DialogShortcut) -> Self {
        self.shortcut = Some(shortcut);
        self
    }

    pub fn is_destructive(&self) -> bool {
        matches!(self.style, DialogButtonStyle::Destructive | DialogButtonStyle::DestructiveOutline)
    }
}

/// Checks a prompt's text: `Err(message)` keeps the dialog open and shows the message.
pub type Validator = Rc<dyn Fn(&str) -> Result<(), SharedString>>;

/// A prompt's one-line text input.
#[derive(Clone)]
pub struct DialogField {
    pub placeholder: SharedString,
    pub initial_value: SharedString,
    /// A hint under the field (11.5 px `dim`).
    pub hint: Option<SharedString>,
    pub validate: Option<Validator>,
}

/// What a dialog shows (`ShellDialogContent`).
#[derive(Clone)]
pub struct DialogContent {
    pub title: SharedString,
    pub message: SharedString,
    /// In display order (left to right); the last one is the default (Return).
    pub buttons: Vec<DialogButton>,
    pub field: Option<DialogField>,
}

impl DialogContent {
    pub fn new(
        title: impl Into<SharedString>,
        message: impl Into<SharedString>,
        buttons: Vec<DialogButton>,
    ) -> Self {
        Self { title: title.into(), message: message.into(), buttons, field: None }
    }

    /// Two-button confirm ("Delete X?"): Cancel and `confirm_title` (destructive or primary).
    pub fn confirm(
        title: impl Into<SharedString>,
        message: impl Into<SharedString>,
        confirm_title: impl Into<SharedString>,
        destructive: bool,
    ) -> Self {
        let confirm = DialogButton::new(confirm_title).style(if destructive {
            DialogButtonStyle::Destructive
        } else {
            DialogButtonStyle::Primary
        });
        Self::new(title, message, vec![DialogButton::new("Cancel"), confirm])
    }

    /// One OK button.
    pub fn alert(title: impl Into<SharedString>, message: impl Into<SharedString>) -> Self {
        Self::new(title, message, vec![DialogButton::new("OK").primary()])
    }

    /// The unsaved-changes question: Don't Save (⌘D), Cancel, Save.
    pub fn save_changes(title: impl Into<SharedString>, message: impl Into<SharedString>) -> Self {
        Self::new(
            title,
            message,
            vec![
                DialogButton::new("Don't Save")
                    .style(DialogButtonStyle::DestructiveOutline)
                    .shortcut(DialogShortcut::command("d")),
                DialogButton::new("Cancel"),
                DialogButton::new("Save").primary(),
            ],
        )
    }

    /// Single-line input with Cancel and `confirm_title`; the field starts with
    /// `initial_value` selected.
    pub fn prompt(
        title: impl Into<SharedString>,
        message: impl Into<SharedString>,
        placeholder: impl Into<SharedString>,
        initial_value: impl Into<SharedString>,
        confirm_title: impl Into<SharedString>,
    ) -> Self {
        Self {
            title: title.into(),
            message: message.into(),
            buttons: vec![DialogButton::new("Cancel"), DialogButton::new(confirm_title).primary()],
            field: Some(DialogField {
                placeholder: placeholder.into(),
                initial_value: initial_value.into(),
                hint: None,
                validate: None,
            }),
        }
    }

    /// Adds a check to a prompt's text.
    pub fn validate(mut self, validate: impl Fn(&str) -> Result<(), SharedString> + 'static) -> Self {
        if let Some(field) = &mut self.field {
            field.validate = Some(Rc::new(validate));
        }
        self
    }

    /// Adds a hint under a prompt's field.
    pub fn hint(mut self, hint: impl Into<SharedString>) -> Self {
        if let Some(field) = &mut self.field {
            field.hint = Some(hint.into());
        }
        self
    }

    /// What a key press does: `Some(None)` cancels (Esc), `Some(Some(i))` picks button `i`
    /// (Return picks the last; a button's own chord picks it), `None` passes the key on.
    pub fn key_choice(&self, keystroke: &Keystroke, platform: KeyPlatform) -> Option<Option<usize>> {
        let m = keystroke.modifiers;
        let bare = !(m.control || m.alt || m.shift || m.platform);
        match keystroke.key.as_str() {
            "escape" if bare => return Some(None),
            "enter" if bare && !self.buttons.is_empty() => return Some(Some(self.buttons.len() - 1)),
            _ => {}
        }
        if bare {
            return None;
        }
        self.buttons
            .iter()
            .position(|b| b.shortcut.as_ref().is_some_and(|s| s.matches(keystroke, platform)))
            .map(Some)
    }
}

/// The answer (`ShellDialogResult`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DialogResult {
    /// The chosen button, None when cancelled (Esc, a click outside).
    pub index: Option<usize>,
    /// The text input's value, empty without one.
    pub text: String,
}

impl DialogResult {
    /// A prompt's answer: the trimmed text on confirm (any button but the first), None on
    /// cancel or when blank.
    pub fn prompt_value(&self) -> Option<String> {
        let index = self.index?;
        if index == 0 {
            return None;
        }
        let value = self.text.trim();
        (!value.is_empty()).then(|| value.to_owned())
    }
}

/// Chords the app keeps while a dialog shows (`ShellDialogOverlayWindow.passesToMenu`): cut,
/// copy, paste, select all, undo, redo, quit, hide. The app's keystroke interceptor should
/// swallow every other chord while a dialog is up.
pub fn dialog_passes_chord_to_app(keystroke: &Keystroke) -> bool {
    let m = keystroke.modifiers;
    let key = keystroke.key.to_lowercase();
    let command = m.platform || (!cfg!(target_os = "macos") && m.control);
    match (command, m.shift, m.alt, m.control && m.platform) {
        (true, false, false, false) => ["x", "c", "v", "a", "z", "q", "h"].contains(&key.as_str()),
        (true, true, false, false) => key == "z",
        (true, false, true, false) => key == "h",
        _ => false,
    }
}

type Completion = Box<dyn FnOnce(DialogResult, &mut Window, &mut App)>;

/// A dialog over the window: the backdrop plus a centered 380 px card. Render the entity in
/// the window's root (it covers the window); it emits the [`DialogResult`] and then
/// [`DismissEvent`], and calls [`Dialog::on_finish`]'s callback.
pub struct Dialog {
    content: DialogContent,
    input: Option<Entity<InputState>>,
    error: Option<SharedString>,
    focus_handle: FocusHandle,
    completion: Option<Completion>,
    finished: bool,
    _subscription: Option<Subscription>,
}

impl EventEmitter<DialogResult> for Dialog {}
impl EventEmitter<DismissEvent> for Dialog {}

impl Focusable for Dialog {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl Dialog {
    /// Presents `content`: focuses the prompt's field with its text selected, else the card.
    pub fn new(content: DialogContent, window: &mut Window, cx: &mut App) -> Entity<Self> {
        cx.new(|cx| {
            let focus_handle = cx.focus_handle();
            let input = content.field.as_ref().map(|field| {
                let placeholder = field.placeholder.clone();
                let initial = field.initial_value.clone();
                cx.new(|cx| InputState::new(window, cx).placeholder(placeholder).default_value(initial))
            });
            let subscription = input.as_ref().map(|input| {
                cx.subscribe_in(input, window, |this: &mut Self, _, event: &InputEvent, window, cx| {
                    match event {
                        InputEvent::PressEnter { .. } => this.confirm_default(window, cx),
                        InputEvent::Change if this.error.take().is_some() => cx.notify(),
                        _ => {}
                    }
                })
            });
            match &input {
                Some(input) => input.update(cx, |state, cx| {
                    state.focus(window, cx);
                    state.select_all(window, cx);
                }),
                None => focus_handle.focus(window, cx),
            }
            Self {
                content,
                input,
                error: None,
                focus_handle,
                completion: None,
                finished: false,
                _subscription: subscription,
            }
        })
    }

    /// Called once with the answer.
    pub fn on_finish(&mut self, completion: impl FnOnce(DialogResult, &mut Window, &mut App) + 'static) {
        self.completion = Some(Box::new(completion));
    }

    pub fn content(&self) -> &DialogContent {
        &self.content
    }

    pub fn is_finished(&self) -> bool {
        self.finished
    }

    fn text(&self, cx: &App) -> String {
        self.input.as_ref().map(|input| input.read(cx).value().to_string()).unwrap_or_default()
    }

    fn confirm_default(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let last = self.content.buttons.len().checked_sub(1);
        self.finish(last, window, cx);
    }

    /// Closes with the chosen button (None = cancelled). Confirming a prompt whose
    /// validator rejects the text shows the message and keeps the dialog open. A finished
    /// dialog ignores later calls.
    pub fn finish(&mut self, index: Option<usize>, window: &mut Window, cx: &mut Context<Self>) {
        if self.finished {
            return;
        }
        let text = self.text(cx);
        if let (Some(index), Some(validate)) =
            (index, self.content.field.as_ref().and_then(|f| f.validate.clone()))
            && index > 0
            && let Err(message) = validate(text.trim())
        {
            self.error = Some(message);
            cx.notify();
            return;
        }
        self.finished = true;
        let result = DialogResult { index, text };
        cx.emit(result.clone());
        cx.emit(DismissEvent);
        if let Some(completion) = self.completion.take() {
            window.defer(cx, move |window, cx| completion(result, window, cx));
        }
        cx.notify();
    }

    fn on_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(choice) = self.content.key_choice(&event.keystroke, KeyPlatform::current()) {
            cx.stop_propagation();
            self.finish(choice, window, cx);
        }
    }
}

impl Render for Dialog {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.finished {
            return div().into_any_element();
        }
        let theme = cx.soprano_theme();
        let z = |v: f32| theme.z(v);
        let (title, message) = (self.content.title.clone(), self.content.message.clone());
        let field = self.content.field.clone();
        let error = self.error.clone();
        let buttons = self.content.buttons.iter().enumerate().map(|(index, spec)| {
            Button::new(ElementId::NamedInteger("dialog-button".into(), index as u64), spec.title.clone())
                .variant(spec.style.variant())
                .on_click(cx.listener(move |this, _, window, cx| this.finish(Some(index), window, cx)))
        });
        let card = div()
            .id("soprano-dialog-card")
            .flex()
            .flex_col()
            .gap(z(12.))
            .w(z(380.))
            .max_w(gpui::relative(0.9))
            .p(z(18.))
            .rounded(z(8.))
            .bg(theme.popover)
            .border_1()
            .border_color(theme.border)
            .shadow_lg()
            .font_family(fonts::UI_FONT_FAMILY)
            .text_size(z(size::UI))
            .text_color(theme.foreground)
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .gap(z(8.))
                    .child(
                        div().text_size(z(size::DIALOG_TITLE)).font_weight(FontWeight::SEMIBOLD).child(title),
                    )
                    .child(div().text_size(z(size::SMALL)).text_color(theme.dim).child("Esc")),
            )
            .when(!message.is_empty(), |card| card.child(div().text_color(theme.muted).child(message)))
            .when_some(self.input.clone().zip(field), |card, (input, field)| {
                card.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(z(6.))
                        .child(TextInput::new(&input).size(InputSize::Large).invalid(error.is_some()))
                        .when_some(error.clone().or(field.hint), |col, note| {
                            col.child(
                                div()
                                    .text_size(z(size::SECTION))
                                    .text_color(if error.is_some() { theme.failed } else { theme.dim })
                                    .child(note),
                            )
                        }),
                )
            })
            .child(div().flex().flex_row().justify_end().gap(z(8.)).pt(z(4.)).children(buttons));
        let backdrop = div()
            .id("soprano-dialog")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(theme.backdrop)
            .track_focus(&self.focus_handle)
            .key_context("SopranoDialog")
            .on_key_down(cx.listener(Self::on_key))
            .on_action(
                cx.listener(|this, _: &component_input::Escape, window, cx| this.finish(None, window, cx)),
            )
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, _, window, cx| this.finish(None, window, cx)),
            )
            .child(card);
        fade_in(backdrop, "soprano-dialog-fade", cx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(text: &'static str) -> Keystroke {
        Keystroke::parse(text).expect("keystroke")
    }

    #[test]
    fn return_confirms_with_the_last_button_and_escape_cancels_even_with_text() {
        let prompt = DialogContent::prompt(
            "Rename Session",
            "Name this group of windows.",
            "Session name",
            "Main",
            "Rename",
        );
        assert_eq!(prompt.key_choice(&key("enter"), KeyPlatform::Mac), Some(Some(1)));
        assert_eq!(prompt.key_choice(&key("escape"), KeyPlatform::Mac), Some(None));
        assert_eq!(prompt.key_choice(&key("a"), KeyPlatform::Mac), None);
    }

    #[test]
    fn return_in_a_prompt_confirms_with_the_trimmed_text() {
        let result = DialogResult { index: Some(1), text: "  Release work  ".into() };
        assert_eq!(result.prompt_value().as_deref(), Some("Release work"));
    }

    #[test]
    fn a_blank_prompt_answer_counts_as_no_answer() {
        assert_eq!(DialogResult { index: Some(1), text: "   ".into() }.prompt_value(), None);
        assert_eq!(DialogResult { index: Some(0), text: "Kept".into() }.prompt_value(), None);
        assert_eq!(DialogResult { index: None, text: "Kept".into() }.prompt_value(), None);
    }

    #[test]
    fn a_buttons_own_shortcut_picks_it() {
        let save = DialogContent::save_changes("Save?", "");
        assert_eq!(save.key_choice(&key("d"), KeyPlatform::Mac), None);
        assert_eq!(save.key_choice(&key("cmd-d"), KeyPlatform::Mac), Some(Some(0)));
        assert_eq!(save.key_choice(&key("ctrl-shift-d"), KeyPlatform::Other), Some(Some(0)));
        assert_eq!(save.key_choice(&key("ctrl-d"), KeyPlatform::Other), None);
        assert_eq!(save.key_choice(&key("enter"), KeyPlatform::Mac), Some(Some(2)));
        assert_eq!(
            save.buttons.iter().map(|b| b.title.as_ref()).collect::<Vec<_>>(),
            ["Don't Save", "Cancel", "Save"]
        );
        assert!(save.buttons[0].is_destructive());
    }

    #[test]
    fn confirm_and_alert_shapes() {
        let confirm = DialogContent::confirm("Close Session?", "", "Close Session", true);
        assert_eq!(confirm.buttons.len(), 2);
        assert_eq!(confirm.buttons[1].style, DialogButtonStyle::Destructive);
        assert_eq!(
            DialogContent::confirm("Rename?", "", "Rename", false).buttons[1].style,
            DialogButtonStyle::Primary
        );
        let alert = DialogContent::alert("Done", "It worked.");
        assert_eq!(alert.key_choice(&key("enter"), KeyPlatform::Mac), Some(Some(0)));
    }

    #[test]
    fn editing_and_quit_chords_pass_to_the_app_while_others_stop_at_the_dialog() {
        if cfg!(target_os = "macos") {
            assert!(dialog_passes_chord_to_app(&key("cmd-c")));
            assert!(dialog_passes_chord_to_app(&key("cmd-shift-z")));
            assert!(dialog_passes_chord_to_app(&key("cmd-alt-h")));
            assert!(!dialog_passes_chord_to_app(&key("cmd-p")));
            assert!(!dialog_passes_chord_to_app(&key("cmd-shift-d")));
        }
        assert!(!dialog_passes_chord_to_app(&key("p")));
    }

    mod window {
        use super::super::*;
        use gpui::TestAppContext;

        struct Host {
            dialog: Entity<Dialog>,
        }

        impl Render for Host {
            fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
                div().size_full().child(self.dialog.clone())
            }
        }

        fn setup(
            cx: &mut TestAppContext,
            content: DialogContent,
        ) -> (Entity<Dialog>, &mut gpui::VisualTestContext) {
            cx.update(crate::init_for_tests);
            let (host, cx) =
                cx.add_window_view(|window, cx| Host { dialog: Dialog::new(content, window, cx) });
            let dialog = host.read_with(cx, |host, _| host.dialog.clone());
            (dialog, cx)
        }

        #[gpui::test]
        fn a_dialog_answers_once_though_the_backdrop_is_clicked_after_a_button(cx: &mut TestAppContext) {
            let (dialog, cx) = setup(cx, DialogContent::confirm("Delete?", "", "Delete", true));
            let answers = Rc::new(std::cell::RefCell::new(Vec::new()));
            let sink = answers.clone();
            cx.update(|window, cx| {
                dialog.update(cx, |dialog, cx| {
                    dialog.on_finish(move |result, _, _| sink.borrow_mut().push(result.index));
                    dialog.finish(Some(1), window, cx);
                    dialog.finish(None, window, cx);
                })
            });
            cx.run_until_parked();
            assert_eq!(*answers.borrow(), [Some(1)]);
        }

        #[gpui::test]
        fn a_prompt_starts_with_its_initial_value_and_validation_keeps_it_open(cx: &mut TestAppContext) {
            let content = DialogContent::prompt("Rename", "", "Name", "Main", "Rename")
                .validate(|text| if text.contains('/') { Err("No slashes".into()) } else { Ok(()) });
            let (dialog, cx) = setup(cx, content);
            let value = cx.update(|_, cx| dialog.read(cx).text(cx));
            assert_eq!(value, "Main");
            let input = cx.update(|_, cx| dialog.read(cx).input.clone().expect("input"));
            cx.update(|window, cx| {
                input.update(cx, |state, cx| state.set_value("a/b", window, cx));
                dialog.update(cx, |dialog, cx| dialog.finish(Some(1), window, cx));
            });
            assert!(cx.update(|_, cx| !dialog.read(cx).is_finished()));
            assert_eq!(cx.update(|_, cx| dialog.read(cx).error.clone()), Some("No slashes".into()));
            cx.update(|window, cx| {
                input.update(cx, |state, cx| state.set_value("  Release  ", window, cx));
                dialog.update(cx, |dialog, cx| dialog.finish(Some(1), window, cx));
            });
            assert!(cx.update(|_, cx| dialog.read(cx).is_finished()));
        }

        fn record(
            dialog: &Entity<Dialog>,
            cx: &mut gpui::VisualTestContext,
        ) -> Rc<std::cell::RefCell<Vec<DialogResult>>> {
            let results = Rc::new(std::cell::RefCell::new(Vec::new()));
            let sink = results.clone();
            cx.update(|_, cx| {
                cx.subscribe(dialog, move |_, result: &DialogResult, _| {
                    sink.borrow_mut().push(result.clone())
                })
                .detach()
            });
            results
        }

        #[gpui::test]
        fn return_in_the_field_confirms_like_the_default_button(cx: &mut TestAppContext) {
            let (dialog, cx) =
                setup(cx, DialogContent::prompt("Rename Session", "", "Session name", "Main", "Rename"));
            let results = record(&dialog, cx);
            cx.simulate_keystrokes("enter");
            let result = results.borrow().first().cloned().expect("answered");
            assert_eq!(result.index, Some(1));
            assert_eq!(result.prompt_value().as_deref(), Some("Main"));
        }

        #[gpui::test]
        fn escape_in_a_prompt_cancels_even_with_text(cx: &mut TestAppContext) {
            let (dialog, cx) =
                setup(cx, DialogContent::prompt("Rename Session", "", "Session name", "Main", "Rename"));
            let results = record(&dialog, cx);
            cx.simulate_keystrokes("escape");
            let result = results.borrow().first().cloned().expect("answered");
            assert_eq!(result.index, None);
            assert_eq!(result.prompt_value(), None);
        }

        #[gpui::test]
        fn escape_and_return_reach_the_dialog_from_its_card(cx: &mut TestAppContext) {
            let (dialog, cx) = setup(cx, DialogContent::save_changes("Save?", ""));
            let results = Rc::new(std::cell::RefCell::new(Vec::new()));
            let sink = results.clone();
            cx.update(|_, cx| {
                cx.subscribe(&dialog, move |_, result: &DialogResult, _| sink.borrow_mut().push(result.index))
                    .detach()
            });
            cx.simulate_keystrokes("enter");
            assert_eq!(*results.borrow(), [Some(2)]);
        }
    }
}
