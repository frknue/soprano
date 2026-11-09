//! The New Automation / Edit Automation dialog (`AutomationEditorPanel`): a form card over the
//! dimmed page with the automation's name, prompt, agent, model, folder, where runs work,
//! schedule, session, grace, precheck and whether it is enabled. Save stays disabled until the
//! prompt, folder and schedule are valid; Return in a one-line field or ⌘Return saves, Esc
//! cancels. A failed write shows above the buttons and keeps the dialog open.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;

use gpui::{
    AnyElement, App, AppContext as _, Context, ElementId, Entity, EventEmitter, FocusHandle, Focusable,
    FontWeight, InteractiveElement, IntoElement, KeyDownEvent, ParentElement, PathPromptOptions, Render,
    SharedString, StatefulInteractiveElement, Styled, Subscription, Window, div, prelude::*, px,
};
use gpui_component::input::{Textarea, TextareaState};
use soprano_automations::Clock;
use soprano_config::Automation;
use soprano_ui::button::{Button, ButtonVariant};
use soprano_ui::controls::{SegmentedControl, Switch, TextInput};
use soprano_ui::dialog::DialogShortcut;
use soprano_ui::fonts::{self, size};
use soprano_ui::keycaps::KeyPlatform;
use soprano_ui::select::{Select, SelectChanged, SelectOption};
use soprano_ui::theme::ActiveSopranoTheme;
use soprano_ui::tooltip::tooltip;
use soprano_ui::{InputEvent, InputState, SopranoTheme};

use crate::form::{self, Cadence, FormValues, Note, WEEKDAYS};
use crate::format;
use crate::templates::AutomationTemplate;

/// The dialog's preferred width.
pub const WIDTH: f32 = 560.0;
const PROMPT_HEIGHT: f32 = 96.0;
/// The folder menu's value that opens the folder chooser.
const CHOOSE_FOLDER_VALUE: &str = "\u{1}choose";

/// Writes the automation; false keeps the dialog open with an error.
pub type SaveHandler = Rc<dyn Fn(&Automation, &mut Window, &mut App) -> bool>;

/// The dialog closed, saved or cancelled.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorClosed;

/// What the editor starts from.
#[derive(Clone)]
pub struct EditorSetup {
    /// The automation to edit; `None` creates one.
    pub automation: Option<Automation>,
    /// A template card's prefill for a new automation.
    pub template: Option<AutomationTemplate>,
    /// Every automation, for the folder list.
    pub automations: Vec<Automation>,
    /// Every id in settings.json, valid or not, for a new id.
    pub taken_ids: BTreeSet<String>,
    /// Roots whose child folders the folder list offers.
    pub project_directories: Vec<String>,
    /// `~/.config/soprano/settings.json`, for the write error.
    pub settings_path: String,
    pub clock: Arc<dyn Clock>,
}

pub struct AutomationEditor {
    existing: Option<Automation>,
    taken_ids: BTreeSet<String>,
    settings_path: String,
    clock: Arc<dyn Clock>,
    folder_choices: Vec<String>,
    folder: Option<String>,
    agent_ids: Vec<String>,
    grace_values: Vec<i64>,
    timeout_values: Vec<i64>,
    worktree: bool,
    reuse: bool,
    enabled: bool,
    cadence: Cadence,
    weekday: u32,
    name: Entity<InputState>,
    prompt: Entity<TextareaState>,
    model: Entity<InputState>,
    base_branch: Entity<InputState>,
    minute: Entity<InputState>,
    time: Entity<InputState>,
    cron: Entity<InputState>,
    precheck: Entity<InputState>,
    agent_select: Entity<Select>,
    folder_select: Entity<Select>,
    cadence_select: Entity<Select>,
    weekday_select: Entity<Select>,
    grace_select: Entity<Select>,
    timeout_select: Entity<Select>,
    error: Option<String>,
    on_save: Option<SaveHandler>,
    focus: FocusHandle,
    _subscriptions: Vec<Subscription>,
}

impl EventEmitter<EditorClosed> for AutomationEditor {}

impl Focusable for AutomationEditor {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl AutomationEditor {
    pub fn new(setup: EditorSetup, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let values = FormValues::load(setup.automation.as_ref(), setup.template.as_ref());
        let input = |placeholder: &str, value: &str, window: &mut Window, cx: &mut Context<Self>| {
            let (placeholder, value) = (placeholder.to_owned(), value.to_owned());
            cx.new(|cx| InputState::new(window, cx).placeholder(placeholder).default_value(value))
        };
        let name = input("Weekday repo audit", &values.name, window, cx);
        let model = input("CLI default", &values.model, window, cx);
        let base_branch = input("origin's default branch", &values.base_branch, window, cx);
        let minute = input("0", &values.minute, window, cx);
        let time = input("9:00 AM", &values.time, window, cx);
        let cron = input("0 9 * * 1-5", &values.cron, window, cx);
        let precheck = input("gh pr list --json number -q '.[0].number'", &values.precheck, window, cx);
        let prompt_text = values.prompt.clone();
        let prompt = cx.new(|cx| {
            TextareaState::new(window, cx)
                .placeholder("Review the repository health and summarize what needs attention.")
                .default_value(prompt_text)
        });

        let agent_ids = form::agent_ids(setup.automation.as_ref().map(|a| a.agent_id.as_str()));
        let agent_options: Vec<SelectOption> =
            agent_ids.iter().map(|id| SelectOption::new(id.clone(), format::agent_name(id))).collect();
        let agent_index = agent_ids.iter().position(|id| *id == values.agent_id);
        let agent_select = Select::new("automation-editor-agent", agent_options, agent_index, cx);

        let folder_select = Select::new("automation-editor-folder", Vec::new(), None, cx);
        folder_select.update(cx, |select, _| select.set_placeholder("Choose a folder"));

        let cadence_options = Cadence::ALL.iter().map(|c| SelectOption::new(c.title(), c.title())).collect();
        let cadence_index = Cadence::ALL.iter().position(|c| *c == values.cadence);
        let cadence_select = Select::new("automation-editor-cadence", cadence_options, cadence_index, cx);
        cadence_select.update(cx, |select, _| select.set_width(124.));

        let weekday_options =
            WEEKDAYS.iter().enumerate().map(|(i, day)| SelectOption::new(i.to_string(), *day)).collect();
        let weekday_select =
            Select::new("automation-editor-weekday", weekday_options, Some(values.weekday as usize), cx);
        weekday_select.update(cx, |select, _| select.set_width(132.));

        let grace = form::grace_options(values.grace_minutes);
        let grace_index = grace.iter().position(|(m, _)| *m == values.grace_minutes);
        let grace_values: Vec<i64> = grace.iter().map(|(m, _)| *m).collect();
        let grace_select = Select::new(
            "automation-editor-grace",
            grace.into_iter().map(|(m, t)| SelectOption::new(m.to_string(), t)).collect(),
            grace_index,
            cx,
        );

        let timeouts = form::timeout_options(values.precheck_timeout_seconds);
        let timeout_index = timeouts.iter().position(|(s, _)| *s == values.precheck_timeout_seconds);
        let timeout_values: Vec<i64> = timeouts.iter().map(|(s, _)| *s).collect();
        let timeout_select = Select::new(
            "automation-editor-timeout",
            timeouts.into_iter().map(|(s, t)| SelectOption::new(s.to_string(), t)).collect(),
            timeout_index,
            cx,
        );
        timeout_select.update(cx, |select, _| select.set_width(100.));

        let mut subscriptions = Vec::new();
        for field in [&name, &model, &base_branch, &minute, &time, &cron, &precheck] {
            subscriptions.push(cx.subscribe_in(field, window, |this, _, event: &InputEvent, window, cx| {
                match event {
                    InputEvent::PressEnter { .. } => this.submit(window, cx),
                    InputEvent::Change => cx.notify(),
                    _ => {}
                }
            }));
        }
        subscriptions.push(cx.subscribe(&prompt, |_, _, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                cx.notify();
            }
        }));
        subscriptions.push(cx.subscribe_in(
            &folder_select,
            window,
            |this, _, event: &SelectChanged, window, cx| {
                this.folder_changed(event.value.as_ref(), window, cx);
            },
        ));
        subscriptions.push(cx.subscribe_in(
            &cadence_select,
            window,
            |this, _, event: &SelectChanged, window, cx| {
                this.cadence_changed(Cadence::ALL[event.index.min(Cadence::ALL.len() - 1)], window, cx);
            },
        ));
        subscriptions.push(cx.subscribe(&weekday_select, |this, _, event: &SelectChanged, cx| {
            this.weekday = event.index as u32;
            cx.notify();
        }));
        for select in [&agent_select, &grace_select, &timeout_select] {
            subscriptions.push(cx.subscribe(select, |_, _, _: &SelectChanged, cx| cx.notify()));
        }

        let folder_choices = form::folder_choices(&setup.automations, &setup.project_directories);
        let mut editor = Self {
            existing: setup.automation,
            taken_ids: setup.taken_ids,
            settings_path: setup.settings_path,
            clock: setup.clock,
            folder_choices,
            folder: values.folder.clone(),
            agent_ids,
            grace_values,
            timeout_values,
            worktree: values.worktree,
            reuse: values.reuse,
            enabled: values.enabled,
            cadence: values.cadence,
            weekday: values.weekday,
            name,
            prompt,
            model,
            base_branch,
            minute,
            time,
            cron,
            precheck,
            agent_select,
            folder_select,
            cadence_select,
            weekday_select,
            grace_select,
            timeout_select,
            error: None,
            on_save: None,
            focus: cx.focus_handle(),
            _subscriptions: subscriptions,
        };
        editor.populate_folders(cx);
        editor.name.update(cx, |state, cx| state.focus(window, cx));
        editor
    }

    pub fn set_on_save(&mut self, handler: impl Fn(&Automation, &mut Window, &mut App) -> bool + 'static) {
        self.on_save = Some(Rc::new(handler));
    }

    /// What the fields hold now.
    pub fn values(&self, cx: &App) -> FormValues {
        let selected_value = |select: &Entity<Select>| {
            select.read(cx).selected().map(|option| option.value.to_string()).unwrap_or_default()
        };
        let agent_id = selected_value(&self.agent_select);
        FormValues {
            name: self.name.read(cx).value().to_string(),
            prompt: self.prompt.read(cx).value().to_string(),
            agent_id: if self.agent_ids.contains(&agent_id) { agent_id } else { String::new() },
            model: self.model.read(cx).value().to_string(),
            folder: self.folder.clone(),
            worktree: self.worktree,
            base_branch: self.base_branch.read(cx).value().to_string(),
            reuse: self.reuse,
            cadence: self.cadence,
            minute: self.minute.read(cx).value().to_string(),
            weekday: self.weekday,
            time: self.time.read(cx).value().to_string(),
            cron: self.cron.read(cx).value().to_string(),
            grace_minutes: selected_value(&self.grace_select)
                .parse()
                .ok()
                .filter(|m| self.grace_values.contains(m))
                .unwrap_or(Automation::DEFAULT_GRACE_MINUTES),
            precheck: self.precheck.read(cx).value().to_string(),
            precheck_timeout_seconds: selected_value(&self.timeout_select)
                .parse()
                .ok()
                .filter(|s| self.timeout_values.contains(s))
                .unwrap_or(Automation::DEFAULT_PRECHECK_TIMEOUT_SECONDS),
            enabled: self.enabled,
        }
    }

    /// Whether Save would write now.
    pub fn can_save(&self, cx: &App) -> bool {
        self.values(cx).validation(self.clock.now(), self.clock.time_zone()).can_save
    }

    /// The error shown above the buttons, if any.
    pub fn shown_error(&self) -> Option<&str> {
        self.error.as_deref()
    }

    pub fn is_new(&self) -> bool {
        self.existing.is_none()
    }

    #[cfg(test)]
    pub(crate) fn set_test_values(
        &mut self,
        name: &str,
        prompt: &str,
        folder: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.name.update(cx, |state, cx| state.set_value(name.to_owned(), window, cx));
        self.prompt.update(cx, |state, cx| state.set_value(prompt.to_owned(), window, cx));
        self.folder = Some(folder.to_owned());
        self.populate_folders(cx);
    }

    // MARK: - Folders

    fn populate_folders(&mut self, cx: &mut Context<Self>) {
        if let Some(folder) = &self.folder
            && !self.folder_choices.contains(folder)
        {
            self.folder_choices.insert(0, folder.clone());
        }
        let mut options: Vec<SelectOption> = self
            .folder_choices
            .iter()
            .map(|folder| SelectOption::new(folder.clone(), format::path(folder)))
            .collect();
        options.push(SelectOption::new(CHOOSE_FOLDER_VALUE, "Choose Folder…"));
        let selected =
            self.folder.as_ref().and_then(|folder| self.folder_choices.iter().position(|f| f == folder));
        self.folder_select.update(cx, |select, cx| select.set_options(options, selected, cx));
    }

    fn folder_changed(&mut self, value: &str, window: &mut Window, cx: &mut Context<Self>) {
        if value == CHOOSE_FOLDER_VALUE {
            self.populate_folders(cx);
            self.choose_folder(window, cx);
            return;
        }
        self.folder = Some(value.to_owned()).filter(|v| !v.is_empty());
        self.populate_folders(cx);
        cx.notify();
    }

    fn choose_folder(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let paths = cx.prompt_for_paths(PathPromptOptions {
            files: false,
            directories: true,
            multiple: false,
            prompt: Some("Choose".into()),
        });
        cx.spawn_in(window, async move |this, cx| {
            let Ok(Ok(Some(paths))) = paths.await else { return };
            let Some(path) = paths.into_iter().next() else { return };
            this.update(cx, |this, cx| this.folder_chosen(path, cx)).ok();
        })
        .detach();
    }

    fn folder_chosen(&mut self, path: PathBuf, cx: &mut Context<Self>) {
        self.folder = Some(path.to_string_lossy().into_owned());
        self.populate_folders(cx);
        cx.notify();
    }

    // MARK: - Schedule

    fn cadence_changed(&mut self, cadence: Cadence, window: &mut Window, cx: &mut Context<Self>) {
        // Custom starts from the preset it replaces, so a small change is easy.
        if cadence == Cadence::Custom && self.cron.read(cx).value().is_empty() {
            let preset = self.values(cx).schedule().ok().filter(|_| self.cadence != Cadence::Custom);
            if let Some(schedule) = preset {
                self.cron.update(cx, |state, cx| state.set_value(schedule.expression, window, cx));
            }
        }
        self.cadence = cadence;
        cx.notify();
    }

    // MARK: - Actions

    fn cancel(&mut self, cx: &mut Context<Self>) {
        cx.emit(EditorClosed);
    }

    /// Saves when the fields describe an automation; keeps the dialog open with an error
    /// when it could not be written.
    pub fn submit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let values = self.values(cx);
        if !values.validation(self.clock.now(), self.clock.time_zone()).can_save {
            return;
        }
        let Some(automation) = values.automation(self.existing.as_ref(), &self.taken_ids) else { return };
        let saved = self.on_save.clone().is_some_and(|save| save(&automation, window, cx));
        if saved {
            self.error = None;
            cx.emit(EditorClosed);
        } else {
            self.error = Some(format!(
                "Soprano couldn't save the automation. Check that {} is writable, then try again.",
                self.settings_path
            ));
        }
        cx.notify();
    }

    /// Esc cancels and ⌘Return saves from any control, the prompt included.
    fn on_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let keystroke = &event.keystroke;
        let modifiers = &keystroke.modifiers;
        let plain = !modifiers.control && !modifiers.alt && !modifiers.shift && !modifiers.platform;
        if keystroke.key == "escape" && plain {
            cx.stop_propagation();
            self.cancel(cx);
        } else if DialogShortcut::command("enter").matches(keystroke, KeyPlatform::current()) {
            cx.stop_propagation();
            self.submit(window, cx);
        }
    }

    // MARK: - Rendering

    fn labeled(
        theme: &SopranoTheme,
        title: &'static str,
        control: impl IntoElement,
        note: Option<&Note>,
    ) -> AnyElement {
        div()
            .flex()
            .flex_col()
            .w_full()
            .gap(theme.z(6.))
            .child(
                div()
                    .text_size(theme.z(size::ROW))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(theme.foreground)
                    .child(title),
            )
            .child(control)
            .when_some(note, |column, note| column.child(Self::note(theme, note)))
            .into_any_element()
    }

    fn note(theme: &SopranoTheme, note: &Note) -> impl IntoElement {
        div()
            .text_size(theme.z(size::META))
            .text_color(if note.is_error { theme.failed } else { theme.muted })
            .child(note.text.clone())
    }

    fn pair(theme: &SopranoTheme, leading: AnyElement, trailing: AnyElement) -> AnyElement {
        div()
            .flex()
            .flex_row()
            .items_start()
            .gap(theme.z(12.))
            .child(div().flex_1().min_w_0().child(leading))
            .child(div().flex_1().min_w_0().child(trailing))
            .into_any_element()
    }

    fn body(&self, values: &FormValues, theme: &SopranoTheme, cx: &mut Context<Self>) -> AnyElement {
        let validation = values.validation(self.clock.now(), self.clock.time_zone());
        let z = |v: f32| theme.z(v);
        let worktree = self.worktree;

        let prompt = div()
            .h(z(PROMPT_HEIGHT))
            .w_full()
            .rounded(z(8.))
            .border_1()
            .border_color(theme.input)
            .bg(theme.background)
            .px(z(10.))
            .py(z(6.))
            .text_size(z(size::ROW))
            .child(Textarea::new(&self.prompt).appearance(false).h(px(PROMPT_HEIGHT - 12.)));

        let runs_in = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(z(8.))
            .child(
                SegmentedControl::new("automation-editor-runs-in", ["Folder", "New worktree"])
                    .selected(usize::from(worktree))
                    .on_select({
                        let this = cx.entity().downgrade();
                        move |index, _, cx| {
                            this.update(cx, |this, cx| {
                                this.worktree = index == 1;
                                cx.notify();
                            })
                            .ok();
                        }
                    }),
            )
            .when(worktree, |line| {
                line.child(
                    div()
                        .id("automation-editor-base-branch")
                        .flex_1()
                        .min_w_0()
                        .tooltip(tooltip("The branch each run's worktree starts from"))
                        .child(TextInput::new(&self.base_branch)),
                )
            });

        let cadence = self.cadence;
        let schedule = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(z(8.))
            .child(self.cadence_select.clone())
            .when(cadence == Cadence::Hourly, |line| {
                line.child(div().text_size(z(size::ROW)).text_color(theme.muted).child("at minute")).child(
                    div()
                        .id("automation-editor-minute")
                        .w(z(56.))
                        .tooltip(tooltip("0–59"))
                        .child(TextInput::new(&self.minute).invalid(validation.minute_invalid)),
                )
            })
            .when(cadence == Cadence::Weekly, |line| line.child(self.weekday_select.clone()))
            .when(matches!(cadence, Cadence::Daily | Cadence::Weekdays | Cadence::Weekly), |line| {
                line.child(
                    div().w(z(108.)).child(TextInput::new(&self.time).invalid(validation.time_invalid)),
                )
            })
            .when(cadence == Cadence::Custom, |line| {
                line.child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .child(TextInput::new(&self.cron).invalid(validation.cron_invalid)),
                )
            });

        let session_tip = if worktree {
            "Worktree runs always start a fresh agent"
        } else {
            "Reuse hands the prompt to the previous run's agent while it is open and idle"
        };
        let session = div().id("automation-editor-session").tooltip(tooltip(session_tip)).child(
            SegmentedControl::new("automation-editor-session-control", ["Fresh", "Reuse"])
                .selected(usize::from(!worktree && self.reuse))
                .disabled_segments(if worktree { vec![1] } else { Vec::new() })
                .on_select({
                    let this = cx.entity().downgrade();
                    move |index, _, cx| {
                        this.update(cx, |this, cx| {
                            this.reuse = index == 1;
                            cx.notify();
                        })
                        .ok();
                    }
                }),
        );
        let grace = div()
            .id("automation-editor-grace-field")
            .tooltip(tooltip(if cfg!(target_os = "macos") {
                "How late a run due while the Mac slept or Soprano was closed may still start"
            } else {
                "How late a run due while the computer slept or Soprano was closed may still start"
            }))
            .child(self.grace_select.clone());

        let precheck = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(z(8.))
            .child(
                div()
                    .id("automation-editor-precheck")
                    .flex_1()
                    .min_w_0()
                    .tooltip(tooltip(
                        "A shell command run in the folder before each scheduled run; the run starts only when it exits 0",
                    ))
                    .child(TextInput::new(&self.precheck)),
            )
            .child(
                div()
                    .id("automation-editor-timeout")
                    .tooltip(tooltip("How long the precheck may take"))
                    .child(self.timeout_select.clone()),
            );

        let enabled = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(z(8.))
            .child(Switch::new("automation-editor-enabled", self.enabled).on_change({
                let this = cx.entity().downgrade();
                move |on, _, cx| {
                    this.update(cx, |this, cx| {
                        this.enabled = on;
                        cx.notify();
                    })
                    .ok();
                }
            }))
            .child(div().text_size(z(size::ROW)).child("Enabled"));

        let title = if self.existing.is_none() { "New Automation" } else { "Edit Automation" };
        div()
            .flex()
            .flex_col()
            .gap(z(14.))
            .pt(z(24.))
            .px(z(24.))
            .pb(z(20.))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(z(8.))
                    .mb(z(6.))
                    .child(div().text_size(z(16.)).font_weight(FontWeight::SEMIBOLD).child(title))
                    .child(
                        div().text_size(z(size::ROW)).text_color(theme.muted).child(
                            "Sends the prompt to an agent on a schedule while Soprano is open, until you pause it.",
                        ),
                    ),
            )
            .child(Self::labeled(theme, "Name", TextInput::new(&self.name), None))
            .child(Self::labeled(theme, "Prompt", prompt, validation.prompt_note.as_ref()))
            .child(Self::pair(
                theme,
                Self::labeled(theme, "Agent", self.agent_select.clone(), None),
                Self::labeled(theme, "Model", TextInput::new(&self.model), None),
            ))
            .child(Self::labeled(theme, "Folder", self.folder_select.clone(), validation.folder_note.as_ref()))
            .child(Self::labeled(theme, "Runs in", runs_in, None))
            .child(Self::labeled(theme, "Schedule", schedule, Some(&validation.schedule_note)))
            .child(Self::pair(
                theme,
                Self::labeled(theme, "Session", session, None),
                Self::labeled(theme, "Grace", grace, None),
            ))
            .child(Self::labeled(theme, "Precheck", precheck, None))
            .child(div().mt(z(2.)).child(enabled))
            .when_some(self.error.clone(), |body, error| {
                body.child(div().text_size(z(size::META)).text_color(theme.failed).child(error))
            })
            .into_any_element()
    }
}

impl Render for AutomationEditor {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.soprano_theme().clone();
        let z = |v: f32| theme.z(v);
        let values = self.values(cx);
        let can_save = values.validation(self.clock.now(), self.clock.time_zone()).can_save;
        let body = self.body(&values, &theme, cx);
        let viewport = window.viewport_size();
        let save_title: SharedString =
            if self.existing.is_none() { "Create".into() } else { "Save Changes".into() };
        div()
            .id("automation-editor")
            .key_context("AutomationEditor")
            .track_focus(&self.focus)
            .on_key_down(cx.listener(Self::on_key))
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .bg(theme.backdrop)
            .font_family(fonts::UI_FONT_FAMILY)
            .text_color(theme.foreground)
            .child(
                div()
                    .id("automation-editor-card")
                    .flex()
                    .flex_col()
                    .w(z(WIDTH).min(viewport.width - px(32.)))
                    .max_h(viewport.height - px(32.))
                    .bg(theme.popover)
                    .border_1()
                    .border_color(theme.border)
                    .rounded(z(8.))
                    .shadow_lg()
                    .on_mouse_down(gpui::MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .child(
                        div().id("automation-editor-body").flex_1().min_h_0().overflow_y_scroll().child(body),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .justify_end()
                            .gap(z(8.))
                            .px(z(24.))
                            .py(z(16.))
                            .border_t_1()
                            .border_color(theme.border)
                            .child(
                                Button::new("automation-editor-cancel", "Cancel")
                                    .variant(ButtonVariant::Secondary)
                                    .on_click(cx.listener(|this, _, _, cx| this.cancel(cx))),
                            )
                            .child(
                                Button::new(ElementId::Name("automation-editor-save".into()), save_title)
                                    .primary()
                                    .disabled(!can_save)
                                    .on_click(cx.listener(|this, _, window, cx| this.submit(window, cx))),
                            ),
                    ),
            )
    }
}
