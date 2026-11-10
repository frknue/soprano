//! The pages, as titled sections of grouped rows (`SettingsForm`).

use gpui::{
    AnyElement, ClickEvent, Context, ElementId, FontWeight, Hsla, IntoElement, ParentElement, SharedString,
    Styled, Window, div, prelude::*,
};
use gpui_component::input::InputState;
use soprano_accounts::presentation::{
    AccountsPage, Button as AccountButton, ButtonVariant as AccountButtonVariant, EntryRow, SectionBody,
    SectionFooter,
};
use soprano_config::{
    AppSettings, AppearancePreference, DefaultKeybindings, Limits, Severity, prefix_legend_for,
};
use soprano_launch::MachineCheck;
use soprano_types::AgentProfile;
use soprano_ui::button::{Button, ButtonSize, ButtonVariant};
use soprano_ui::controls::{InputSize, SegmentedControl, Switch, TextInput};
use soprano_ui::fonts::{self, size};
use soprano_ui::keycaps::Keycaps;
use soprano_ui::{IconName, SopranoTheme, icon};

use crate::about;
use crate::agents::{self, AgentField};
use crate::form::Form;
use crate::general::{self, Toggle};
use crate::notifications::{NotificationStatusRow, StatusTone};
use crate::shortcuts;
use crate::view::{MachineStatus, Recording, SettingsView};

fn id(prefix: &str, key: impl std::fmt::Display) -> ElementId {
    SharedString::from(format!("{prefix}-{key}")).into()
}

fn tone_color(t: &SopranoTheme, tone: StatusTone) -> Hsla {
    match tone {
        StatusTone::Normal => t.foreground,
        StatusTone::Success => t.working,
        StatusTone::Error => t.failed,
    }
}

impl SettingsView {
    fn open_file_button(&self, key: &str, cx: &mut Context<Self>) -> Button {
        Button::new(id("open-settings-file", key), "Open settings.json")
            .size(ButtonSize::Sm)
            .on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.open_settings_file(cx)))
    }

    // MARK: - General

    pub(crate) fn general_page(
        &mut self,
        t: &SopranoTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let form = Form::new(t);
        let settings = self.snapshot.resolved.settings.clone();
        let defaults = AppSettings::default();
        let mut sections = Vec::new();

        // Without this, a typo in the file would fail silently.
        let issues = self.snapshot.issues();
        if !issues.is_empty() {
            let rows = issues
                .iter()
                .enumerate()
                .map(|(index, issue)| {
                    let (title, color) = match issue.severity {
                        Severity::Error => ("Error", t.failed),
                        Severity::Warning => ("Warning", t.approval),
                    };
                    let description = match issue.line {
                        Some(line) => format!("Line {line}: {}", issue.message),
                        None => issue.message.clone(),
                    };
                    form.row(title)
                        .description(description)
                        .description_color(color)
                        .control(self.open_file_button(&format!("issue-{index}"), cx))
                        .render(t)
                })
                .collect();
            sections.push(form.section(Some("settings.json"), None, rows).into_any_element());
        }

        let theme_name = soprano_ui::theme::theme_options()
            .into_iter()
            .find(|option| option.id == settings.theme_id)
            .map_or_else(|| settings.theme_id.clone(), |option| option.name.to_owned());
        let theme_select = div()
            .id("settings-theme")
            .flex()
            .flex_row()
            .items_center()
            .justify_between()
            .gap(t.z(6.))
            .w(t.z(224.))
            .h(t.z(28.))
            .px(t.z(10.))
            .rounded(t.z(8.))
            .border_1()
            .border_color(t.input)
            .bg(t.raised)
            .cursor_pointer()
            .hover(|s| s.bg(t.hover))
            .text_size(t.z(size::UI))
            .child(div().truncate().child(theme_name))
            .child(icon(IconName::ChevronDown).size(12.).color(t.muted))
            .child({
                let bounds = self.theme_select_bounds.clone();
                gpui::canvas(move |b, _, _| bounds.set(b), |_, _, _, _| {}).absolute().size_full()
            })
            .on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.open_theme_menu(window, cx)));
        let appearance_index =
            AppearancePreference::ALL.iter().position(|p| *p == settings.appearance).unwrap_or_default();
        let appearance = SegmentedControl::new(
            "settings-appearance",
            AppearancePreference::ALL.map(general::appearance_title),
        )
        .selected(appearance_index)
        .on_select({
            let view = cx.entity().downgrade();
            move |index, window, cx| {
                let preference = AppearancePreference::ALL[index];
                let _ = view.update(cx, |this, cx| {
                    this.write(preference.raw_value(), general::APPEARANCE_KEY, window, cx);
                    this.apply_theme_fallback(cx);
                });
            }
        });

        let appearance_rows = vec![
            form.row("Theme")
                .description(general::THEME_DESCRIPTION)
                .reset_when(
                    settings.theme_id != defaults.theme_id,
                    "reset-theme",
                    cx.listener(|this, _: &ClickEvent, window, cx| {
                        this.reset(general::THEME_KEY, window, cx)
                    }),
                )
                .control(theme_select)
                .render(t),
            form.row("Appearance")
                .description(general::appearance_description())
                .reset_when(
                    settings.appearance != defaults.appearance,
                    "reset-appearance",
                    cx.listener(|this, _: &ClickEvent, window, cx| {
                        this.reset(general::APPEARANCE_KEY, window, cx)
                    }),
                )
                .control(appearance)
                .render(t),
            self.toggle_row(&form, Toggle::HideWindowBar, &settings, &defaults, cx),
            self.toggle_row(&form, Toggle::HideWindowTabs, &settings, &defaults, cx),
            self.toggle_row(&form, Toggle::StatusBarUptime, &settings, &defaults, cx),
        ];
        sections.push(form.section(Some("Appearance"), None, appearance_rows).into_any_element());
        sections.push(
            form.section(
                Some("Session"),
                None,
                vec![self.toggle_row(&form, Toggle::RestoreLastSession, &settings, &defaults, cx)],
            )
            .into_any_element(),
        );

        // Permission lives in the OS settings, and macOS only ever prompts once. The row says
        // where it stands and offers the way there.
        let status = NotificationStatusRow::new(self.authorization);
        let status_row = form
            .row(status.title)
            .title_color(tone_color(t, status.tone))
            .description(status.message.clone())
            .when_some_control(status.button.map(|label| {
                Button::new("settings-notification-settings", label).size(ButtonSize::Sm).on_click(
                    |_, _, _| {
                        let _ = crate::os_notifications::open_notification_settings();
                    },
                )
            }))
            .render(t);
        sections.push(
            form.section(
                Some("Notifications"),
                Some("Banners for panes that are not focused, named window ▸ pane."),
                vec![self.toggle_row(&form, Toggle::NotificationSound, &settings, &defaults, cx), status_row],
            )
            .into_any_element(),
        );

        sections.push(self.project_directories_section(&form, t, cx));
        sections.push(self.keybinding_behavior_section(&form, t, window, cx));
        sections
    }

    fn toggle_row(
        &self,
        form: &Form,
        toggle: Toggle,
        settings: &AppSettings,
        defaults: &AppSettings,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let is_on = toggle.value(settings);
        form.row(toggle.title())
            .description(toggle.description(self.platform))
            .reset_when(
                is_on != toggle.value(defaults),
                id("reset", toggle.label()),
                cx.listener(move |this, _: &ClickEvent, window, cx| this.reset(toggle.key(), window, cx)),
            )
            .control(Switch::new(id("switch", toggle.label()), is_on).on_change({
                let view = cx.entity().downgrade();
                move |value, window, cx| {
                    let _ = view.update(cx, |this, cx| this.write(value, toggle.key(), window, cx));
                }
            }))
            .render(form.t)
    }

    fn project_directories_section(
        &self,
        form: &Form,
        t: &SopranoTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let directories = general::configured_project_directories(&self.store);
        let mut rows = Vec::new();
        if directories.is_empty() {
            rows.push(
                form.row(general::NO_PROJECT_DIRECTORIES)
                    .description(general::NO_PROJECT_DIRECTORIES_HINT)
                    .render(t),
            );
        }
        for (index, directory) in directories.iter().enumerate() {
            let reachable = general::is_reachable_directory(directory);
            rows.push(
                form.row(directory.clone())
                    .mono_title()
                    .description(if reachable { "" } else { "Not found" })
                    .description_color(t.approval)
                    .control(
                        Button::new(id("remove-directory", index), "Remove").size(ButtonSize::Xs).on_click(
                            cx.listener(move |this, _: &ClickEvent, window, cx| {
                                this.remove_project_directory(index, window, cx)
                            }),
                        ),
                    )
                    .render(t),
            );
        }
        rows.push(
            form.actions_row(vec![
                div().flex_1().min_w_0().child(TextInput::new(&self.project_input)).into_any_element(),
                Button::new("browse-directory", "Browse…")
                    .size(ButtonSize::Sm)
                    .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                        this.browse_project_directory(window, cx)
                    }))
                    .into_any_element(),
                Button::new("add-directory", "Add")
                    .primary()
                    .size(ButtonSize::Sm)
                    .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                        let text = this.project_input.read(cx).value().to_string();
                        this.add_project_directory(&text, window, cx);
                    }))
                    .into_any_element(),
            ])
            .into_any_element(),
        );
        form.section(Some("Project directories"), Some(general::PROJECT_DIRECTORIES_NOTE), rows)
            .into_any_element()
    }

    // MARK: - Machines

    pub(crate) fn machines_page(&mut self, t: &SopranoTheme, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let form = Form::new(t);
        let machines = &self.snapshot.resolved.machines;
        let mut rows = Vec::new();
        if machines.is_empty() {
            rows.push(form.row(general::NO_MACHINES).description(general::NO_MACHINES_HINT).render(t));
        }
        for machine in machines {
            let mut description = format!("ssh {}", machine.destination());
            for arg in &machine.ssh_args {
                description.push(' ');
                description.push_str(arg);
            }
            if let Some(directory) = &machine.directory {
                description.push_str(&format!(" · {directory}"));
            }
            let (status, status_color) = match self.machine_status.get(&machine.name) {
                None => (None, t.muted),
                Some(MachineStatus::Checking) => (Some("Checking…".to_owned()), t.muted),
                Some(MachineStatus::Checked(check)) => {
                    let healthy = matches!(check, MachineCheck::Ready { tmux: Some(_), .. });
                    (Some(check.summary()), if healthy { t.working } else { t.approval })
                }
            };
            let check_name = machine.name.clone();
            let remove_name = machine.name.clone();
            let checking = matches!(self.machine_status.get(&machine.name), Some(MachineStatus::Checking));
            let mut row = form.row(machine.name.clone()).mono_title().description(description);
            if let Some(status) = status {
                row = row.status(status, status_color);
            }
            rows.push(
                row.control(form.controls(vec![
                    Button::new(id("check-machine", &machine.name), "Check")
                        .size(ButtonSize::Xs)
                        .disabled(checking)
                        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            this.check_machine(&check_name, cx)
                        }))
                        .into_any_element(),
                    Button::new(id("remove-machine", &machine.name), "Remove")
                        .size(ButtonSize::Xs)
                        .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                            this.remove_machine(&remove_name, window, cx)
                        }))
                        .into_any_element(),
                ]))
                .render(t),
            );
        }
        rows.push(
            form.actions_row(vec![
                div().flex_1().min_w_0().child(TextInput::new(&self.machine_input)).into_any_element(),
                Button::new("add-machine", "Add")
                    .primary()
                    .size(ButtonSize::Sm)
                    .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                        let text = this.machine_input.read(cx).value().to_string();
                        this.add_machine(&text, window, cx);
                    }))
                    .into_any_element(),
            ])
            .into_any_element(),
        );
        if let Some(notice) = &self.machine_notice {
            rows.push(
                div()
                    .px(t.z(16.))
                    .pb(t.z(12.))
                    .child(form.small(notice.text.clone(), if notice.is_error { t.failed } else { t.muted }))
                    .into_any_element(),
            );
        }
        vec![form.section(None, Some(general::MACHINES_NOTE), rows).into_any_element()]
    }

    fn keybinding_behavior_section(
        &self,
        form: &Form,
        t: &SopranoTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let keybindings = &self.snapshot.resolved.keybindings;
        let defaults = DefaultKeybindings::config_for(self.platform);
        let recording = self.recording == Some(Recording::Prefix);
        let legend = if recording {
            general::recording_legend(self.platform).to_owned()
        } else {
            prefix_legend_for(&keybindings.prefix_key, self.platform)
        };
        let focused = self.prefix_focus.is_focused(window);
        let prefix = div()
            .id("settings-prefix-key")
            .track_focus(&self.prefix_focus)
            .flex()
            .items_center()
            .justify_center()
            .min_w(t.z(56.))
            .h(t.z(30.))
            .px(t.z(8.))
            .rounded(t.z(8.))
            .border_1()
            .border_color(if recording || focused { t.accent } else { t.input })
            .bg(t.background)
            .cursor_pointer()
            .text_size(t.z(size::UI))
            .text_color(if recording { t.muted } else { t.foreground })
            .child(legend)
            .tooltip(soprano_ui::tooltip::tooltip(match self.platform {
                soprano_config::KeyPlatform::Mac => "Click, then press the key to use with Control",
                soprano_config::KeyPlatform::Other => "Click, then press the key to use with Ctrl",
            }))
            .on_mouse_down(gpui::MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.begin_prefix_recording(window, cx)))
            .on_key_down(cx.listener(Self::on_prefix_key));

        let timeout_limits = Limits::PREFIX_TIMEOUT_MS;
        let resize_limits = Limits::RESIZE_TICK_PERCENT;
        let number = |input: &gpui::Entity<InputState>, width: f32| {
            div().w(t.z(width)).child(TextInput::new(input).size(InputSize::Small))
        };
        let rows = vec![
            form.row("Prefix key")
                .description(general::prefix_key_description(&keybindings.prefix_key, self.platform))
                .reset_when(
                    keybindings.prefix_key != defaults.prefix_key,
                    "reset-prefix-key",
                    cx.listener(|this, _: &ClickEvent, window, cx| {
                        this.reset(general::PREFIX_KEY_KEY, window, cx)
                    }),
                )
                .control(prefix)
                .render(t),
            form.row("Prefix timeout")
                .description(format!(
                    "Milliseconds the prefix waits for its key ({}–{}).",
                    timeout_limits.start(),
                    timeout_limits.end()
                ))
                .reset_when(
                    keybindings.prefix_timeout_ms != defaults.prefix_timeout_ms,
                    "reset-prefix-timeout",
                    cx.listener(|this, _: &ClickEvent, window, cx| {
                        this.reset(general::PREFIX_TIMEOUT_KEY, window, cx)
                    }),
                )
                .control(number(&self.timeout_input, 80.))
                .render(t),
            form.row("Resize step")
                .description(format!(
                    "Percent of the window a pane grows or shrinks per resize key ({}–{}).",
                    resize_limits.start(),
                    resize_limits.end()
                ))
                .reset_when(
                    keybindings.resize_tick_percent != defaults.resize_tick_percent,
                    "reset-resize-step",
                    cx.listener(|this, _: &ClickEvent, window, cx| {
                        this.reset(general::RESIZE_STEP_KEY, window, cx)
                    }),
                )
                .control(number(&self.resize_input, 64.))
                .render(t),
        ];
        form.section(Some("Keybindings"), None, rows).into_any_element()
    }

    // MARK: - Keyboard Shortcuts

    pub(crate) fn shortcuts_page(
        &mut self,
        t: &SopranoTheme,
        _: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let form = Form::new(t);
        let query = self.shortcut_query(cx);
        let mut sections = vec![
            TextInput::new(&self.shortcut_query)
                .size(InputSize::Regular)
                .prefix(icon(IconName::Search).size(14.).color(t.muted))
                .into_any_element(),
        ];
        if query.is_empty() {
            sections.push(
                form.section(
                    None,
                    None,
                    vec![
                        form.row("Keyboard shortcuts")
                            .description(shortcuts::instructions(&self.snapshot.resolved.keybindings))
                            .control(self.open_file_button("shortcuts", cx))
                            .render(t),
                    ],
                )
                .into_any_element(),
            );
        }
        let issues = self.snapshot.issues();
        let general_issues = shortcuts::keybinding_issues(&issues);
        if !general_issues.is_empty() && query.is_empty() {
            let rows = general_issues
                .iter()
                .map(|issue| {
                    form.row("Warning")
                        .description(issue.message.clone())
                        .description_color(t.approval)
                        .render(t)
                })
                .collect();
            sections.push(form.section(Some("Problems"), None, rows).into_any_element());
        }

        let groups = shortcuts::shortcut_groups_for(&self.snapshot.resolved, &issues, &query, self.platform);
        if groups.is_empty() {
            sections.push(
                form.section(
                    None,
                    None,
                    vec![
                        form.row(shortcuts::NO_MATCHES_TITLE)
                            .description(shortcuts::NO_MATCHES_HINT)
                            .render(t),
                    ],
                )
                .into_any_element(),
            );
        }
        let prefix_key = self.snapshot.resolved.keybindings.prefix_key.clone();
        for group in groups {
            let rows = group
                .entries
                .into_iter()
                .map(|entry| {
                    let binding_id = entry.binding.id.clone();
                    let recording = match &self.recording {
                        Some(Recording::Binding { id, recorder }) if *id == binding_id => {
                            Some(recorder.is_awaiting_prefix_key())
                        }
                        _ => None,
                    };
                    let control: AnyElement = match recording {
                        Some(awaiting) => div()
                            .id(id("recording", &binding_id))
                            .track_focus(&self.binding_focus)
                            .flex()
                            .items_center()
                            .h(t.z(26.))
                            .px(t.z(8.))
                            .rounded(t.z(6.))
                            .border_1()
                            .border_color(t.accent)
                            .bg(t.background)
                            .text_size(t.z(size::META))
                            .text_color(t.muted)
                            .whitespace_nowrap()
                            .child(shortcuts::recording_hint(awaiting, &prefix_key, self.platform))
                            .on_key_down(cx.listener(Self::on_binding_key))
                            .into_any_element(),
                        None => {
                            let record_id = binding_id.clone();
                            div()
                                .id(id("keys", &binding_id))
                                .cursor_pointer()
                                .rounded(t.z(6.))
                                .p(t.z(2.))
                                .hover(|s| s.bg(t.hover))
                                .tooltip(soprano_ui::tooltip::tooltip("Click and press new keys to rebind"))
                                .child(if entry.is_disabled {
                                    form.small("Off", t.muted.opacity(0.7)).into_any_element()
                                } else {
                                    Keycaps::alternatives(entry.caps.clone()).into_any_element()
                                })
                                .on_mouse_down(gpui::MouseButton::Left, |_, _, cx| cx.stop_propagation())
                                .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                                    this.begin_binding_recording(&record_id, window, cx)
                                }))
                                .into_any_element()
                        }
                    };
                    let mut description = entry.description();
                    for issue in &entry.issues {
                        description.push('\n');
                        description.push_str(&issue.message);
                    }
                    let reset_id = binding_id.clone();
                    form.row(entry.binding.label.clone())
                        .description(description)
                        .when_some_description_color((!entry.issues.is_empty()).then_some(t.approval))
                        .when_title_color(entry.is_disabled.then_some(t.muted))
                        .reset_when(
                            entry.is_resettable(),
                            id("reset-binding", &binding_id),
                            cx.listener(move |this, _: &ClickEvent, window, cx| {
                                this.reset(&shortcuts::binding_key_path(&reset_id), window, cx)
                            }),
                        )
                        .when_tooltip(entry.is_customized.then_some(shortcuts::CUSTOMIZED_TOOLTIP))
                        .control(control)
                        .render(t)
                })
                .collect();
            sections.push(form.section(Some(group.title), None, rows).into_any_element());
        }
        sections
    }

    // MARK: - Agent Profiles

    pub(crate) fn agents_page(
        &mut self,
        t: &SopranoTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        self.ensure_agent_inputs(window, cx);
        let form = Form::new(t);
        let intro = form.section(
            None,
            None,
            vec![
                form.row(agents::INTRO_TITLE)
                    .description(agents::INTRO)
                    .control(self.open_file_button("agents", cx))
                    .render(t),
            ],
        );
        let configured = self.snapshot.resolved.configured_agent_ids.clone();
        let profiles: Vec<AnyElement> = self
            .snapshot
            .resolved
            .agents
            .clone()
            .into_iter()
            .map(|profile| self.agent_profile_row(&profile, configured.contains(&profile.id), t, cx))
            .collect();

        let [new_id, new_name, new_command] = self.new_agent_inputs.clone();
        let add_row = div()
            .flex()
            .flex_col()
            .gap(t.z(8.))
            .px(t.z(16.))
            .py(t.z(12.))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .gap(t.z(8.))
                    .child(div().flex_1().child(TextInput::new(&new_id).small()))
                    .child(div().flex_1().child(TextInput::new(&new_name).small()))
                    .child(div().flex_1().child(TextInput::new(&new_command).small()))
                    .child(
                        Button::new("add-agent", "Add Agent")
                            .primary()
                            .icon(IconName::Plus)
                            .size(ButtonSize::Sm)
                            .on_click(
                                cx.listener(|this, _: &ClickEvent, window, cx| this.add_agent(window, cx)),
                            ),
                    ),
            )
            .when_some(self.new_agent_error, |col, error| col.child(form.small(error, t.failed)));
        vec![
            intro.into_any_element(),
            form.section(Some("Profiles"), None, profiles).into_any_element(),
            form.section(
                Some("Add an agent"),
                Some("A new id defines a new agent; it needs a command to run."),
                vec![add_row.into_any_element()],
            )
            .into_any_element(),
        ]
    }

    fn agent_profile_row(
        &self,
        profile: &AgentProfile,
        is_configured: bool,
        t: &SopranoTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let color: Hsla = soprano_ui::color::hsla(profile.color());
        let reset_id = profile.id.clone();
        let header = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(t.z(8.))
            .child(div().size(t.z(8.)).rounded_full().bg(color))
            .child(div().text_size(t.z(size::UI)).font_weight(FontWeight::MEDIUM).child(profile.name.clone()))
            .when(is_configured, |row| {
                row.child(
                    div()
                        .px(t.z(6.))
                        .h(t.z(18.))
                        .flex()
                        .items_center()
                        .rounded(t.z(4.))
                        .bg(t.raised)
                        .border_1()
                        .border_color(t.border)
                        .text_size(t.z(size::SMALL))
                        .text_color(t.muted)
                        .child(agents::CONFIGURED_BADGE),
                )
                .child(
                    soprano_ui::button::IconButton::new(id("reset-agent", &profile.id), IconName::UNDO)
                        .size(soprano_ui::button::IconButtonSize::Tab)
                        .tooltip(if agents::is_built_in(&profile.id) {
                            "Reset to default"
                        } else {
                            "Remove agent"
                        })
                        .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                            agents::remove_agent_entry(&this.store, &reset_id);
                            this.reload(window, cx);
                        })),
                )
            });
        let fields = AgentField::ALL.iter().map(|field| {
            let input = self.agent_inputs.get(&(profile.id.clone(), *field)).cloned();
            div()
                .flex()
                .flex_col()
                .gap(t.z(4.))
                .w(gpui::relative(0.48))
                .child(div().text_size(t.z(size::SMALL)).text_color(t.muted).child(field.label()))
                .children(input.map(|input| TextInput::new(&input).small()))
        });
        div()
            .flex()
            .flex_col()
            .gap(t.z(4.))
            .px(t.z(16.))
            .py(t.z(12.))
            .child(header)
            .child(div().text_size(t.z(size::META)).text_color(t.muted).child(profile.description.clone()))
            .child(
                div()
                    .mt(t.z(2.))
                    .text_size(t.z(size::META))
                    .font_family(fonts::MONO_FONT_FAMILY)
                    .truncate()
                    .child(agents::command_line(profile)),
            )
            .child(
                div()
                    .text_size(t.z(size::SMALL))
                    .font_family(fonts::MONO_FONT_FAMILY)
                    .text_color(t.muted)
                    .child(agents::patterns_line(profile)),
            )
            .child(div().mt(t.z(8.)).flex().flex_row().flex_wrap().gap(t.z(8.)).children(fields))
            .into_any_element()
    }

    /// One input per profile field, created on first sight and kept in step with the file.
    fn ensure_agent_inputs(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let profiles = self.snapshot.resolved.agents.clone();
        for profile in profiles {
            for field in AgentField::ALL {
                let key = (profile.id.clone(), field);
                if self.agent_inputs.contains_key(&key) {
                    continue;
                }
                let entry = agents::configured_entry(&self.snapshot.config, &profile.id);
                let value = field.displayed(&profile, entry.as_ref());
                let input = cx.new(|cx| {
                    InputState::new(window, cx).placeholder(field.placeholder()).default_value(value)
                });
                let agent_id = profile.id.clone();
                self.track_agent_input(&input, agent_id, field, window, cx);
                self.agent_inputs.insert(key, input);
            }
        }
    }

    fn track_agent_input(
        &mut self,
        input: &gpui::Entity<InputState>,
        agent_id: String,
        field: AgentField,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let subscription = cx.subscribe_in(
            input,
            window,
            move |this, input, event: &gpui_component::input::InputEvent, window, cx| {
                if matches!(
                    event,
                    gpui_component::input::InputEvent::PressEnter { .. }
                        | gpui_component::input::InputEvent::Blur
                ) {
                    let text = input.read(cx).value().to_string();
                    let profile = this.snapshot.resolved.agents.iter().find(|p| p.id == agent_id).cloned();
                    let entry = agents::configured_entry(&this.snapshot.config, &agent_id);
                    if profile.is_some_and(|profile| field.displayed(&profile, entry.as_ref()) == text) {
                        return;
                    }
                    agents::set_agent_field(&this.store, &agent_id, field, &text);
                    this.reload(window, cx);
                }
            },
        );
        self.push_subscription(subscription);
    }

    /// Keeps unfocused agent fields showing what the file says.
    pub(crate) fn sync_agent_inputs(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let profiles = self.snapshot.resolved.agents.clone();
        for profile in &profiles {
            let entry = agents::configured_entry(&self.snapshot.config, &profile.id);
            for field in AgentField::ALL {
                if let Some(input) = self.agent_inputs.get(&(profile.id.clone(), field)).cloned() {
                    self.sync_input(&input, field.displayed(profile, entry.as_ref()), window, cx);
                }
            }
        }
        self.agent_inputs.retain(|(id, _), _| profiles.iter().any(|p| &p.id == id));
    }

    pub(crate) fn add_agent(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let [id_input, name_input, command_input] = self.new_agent_inputs.clone();
        let read =
            |input: &gpui::Entity<InputState>, cx: &mut Context<Self>| input.read(cx).value().to_string();
        let (agent_id, name, command) =
            (read(&id_input, cx), read(&name_input, cx), read(&command_input, cx));
        match agents::add_agent(&self.store, &agent_id, &name, &command, &self.snapshot.resolved.agents) {
            Ok(()) => {
                self.new_agent_error = None;
                for input in [id_input, name_input, command_input] {
                    input.update(cx, |state, cx| state.set_value("", window, cx));
                }
            }
            Err(error) => self.new_agent_error = Some(error.message()),
        }
        self.reload(window, cx);
    }

    // MARK: - Accounts

    pub(crate) fn accounts_page(&mut self, t: &SopranoTheme, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let form = Form::new(t);
        let now = soprano_accounts::chrono::Utc::now();
        let page = AccountsPage::build(&self.accounts_snapshot, &now);
        let mut sections = vec![
            form.section(
                None,
                None,
                vec![
                    form.row("Accounts")
                        .description(page.intro)
                        .control(form.controls(vec![
                            form.small(page.updated.clone(), t.muted).into_any_element(),
                            self.account_button(&page.refresh, "refresh", cx).into_any_element(),
                        ]))
                        .render(t),
                ],
            )
            .into_any_element(),
        ];
        for (section_index, section) in page.sections.iter().enumerate() {
            let mut rows = Vec::new();
            if let Some(error) = &section.error {
                rows.push(
                    form.row(error.title)
                        .description(error.message.clone())
                        .description_color(t.failed)
                        .control(self.account_button(&error.dismiss, &format!("dismiss-{section_index}"), cx))
                        .render(t),
                );
            }
            match &section.body {
                SectionBody::Unavailable(reason) => {
                    rows.push(form.row("Unavailable").description(reason.clone()).render(t))
                }
                SectionBody::Placeholder(text) => rows.push(form.row(*text).render(t)),
                SectionBody::Rows(entries) => {
                    for (row_index, entry) in entries.iter().enumerate() {
                        rows.push(self.account_entry_row(
                            entry,
                            &format!("{section_index}-{row_index}"),
                            t,
                            cx,
                        ));
                    }
                }
            }
            rows.push(match &section.footer {
                SectionFooter::Pending { text, description, buttons } => form
                    .row(text.clone())
                    .description(*description)
                    .control(
                        form.controls(
                            buttons
                                .iter()
                                .enumerate()
                                .map(|(i, b)| {
                                    self.account_button(b, &format!("pending-{section_index}-{i}"), cx)
                                        .into_any_element()
                                })
                                .collect(),
                        ),
                    )
                    .render(t),
                SectionFooter::Add(button) => form
                    .actions_row(vec![
                        self.account_button(button, &format!("add-{section_index}"), cx).into_any_element(),
                    ])
                    .into_any_element(),
            });
            sections.push(
                form.section(Some(section.title.as_str()), Some(section.note), rows).into_any_element(),
            );
        }
        sections
    }

    fn account_button(&self, button: &AccountButton, key: &str, cx: &mut Context<Self>) -> Button {
        let variant = match button.variant {
            AccountButtonVariant::Default => ButtonVariant::Secondary,
            AccountButtonVariant::Primary => ButtonVariant::Primary,
            AccountButtonVariant::Ghost => ButtonVariant::Ghost,
            AccountButtonVariant::DestructiveOutline => ButtonVariant::DestructiveOutline,
        };
        let action = button.action.clone();
        Button::new(id(&format!("account-{}", button.title), key), button.title)
            .variant(variant)
            .size(ButtonSize::Xs)
            .disabled(!button.is_enabled)
            .when_icon(button.symbol.map(|_| IconName::Plus))
            .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                this.perform_account_action(action.clone(), window, cx)
            }))
    }

    /// A login: mark, title with its badge, the detail line, the problem, the buttons. The
    /// chosen login sits on a faint fill with a filled mark.
    fn account_entry_row(
        &self,
        entry: &EntryRow,
        key: &str,
        t: &SopranoTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let has_problem = entry.problem.as_deref().is_some_and(|p| !p.is_empty());
        let buttons: Vec<AnyElement> = entry
            .buttons
            .iter()
            .enumerate()
            .map(|(i, b)| self.account_button(b, &format!("{key}-{i}"), cx).into_any_element())
            .collect();
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap(t.z(24.))
            .min_h(t.z(60.))
            .px(t.z(16.))
            .py(t.z(12.))
            .when(entry.is_selected, |row| {
                row.bg(t.foreground.opacity(if t.is_dark() { 0.06 } else { 0.035 }))
            })
            .child(
                div()
                    .flex()
                    .flex_row()
                    .flex_1()
                    .min_w_0()
                    .gap(t.z(10.))
                    .child(div().pt(t.z(5.)).child(account_mark(entry.is_selected, has_problem, t)))
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .min_w_0()
                            .gap(t.z(3.))
                            .child(
                                div()
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap(t.z(8.))
                                    .child(
                                        div()
                                            .truncate()
                                            .text_size(t.z(size::UI))
                                            .font_weight(FontWeight::MEDIUM)
                                            .child(entry.title.clone()),
                                    )
                                    .when_some(entry.badge, |row, badge| row.child(badge_chip(badge, t))),
                            )
                            .child(
                                div()
                                    .text_size(t.z(size::META))
                                    .text_color(t.muted)
                                    .child(entry.detail.clone()),
                            )
                            .when_some(entry.problem.clone().filter(|_| has_problem), |col, problem| {
                                col.child(
                                    div().text_size(t.z(size::META)).text_color(t.failed).child(problem),
                                )
                            }),
                    ),
            )
            .when(!buttons.is_empty(), |row| {
                row.child(div().flex().flex_row().flex_none().gap(t.z(6.)).children(buttons))
            })
            .into_any_element()
    }

    // MARK: - About

    pub(crate) fn about_page(&mut self, t: &SopranoTheme, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let form = Form::new(t);
        let about = form.section(
            Some("About"),
            None,
            vec![
                form.row("Version")
                    .description(about::VERSION_DESCRIPTION)
                    .control(form.value(soprano_platform::identity::app_version(), false))
                    .render(t),
                form.row("Runtime")
                    .description(about::RUNTIME_DESCRIPTION)
                    .control(form.value(about::RUNTIME, false))
                    .render(t),
                form.row("Settings file")
                    .description(self.store.display_path())
                    .mono_description()
                    .control(form.controls(vec![
                        self.open_file_button("about", cx).into_any_element(),
                        Button::new("reveal-settings-file", about::reveal_label())
                            .ghost()
                            .size(ButtonSize::Sm)
                            .on_click(cx.listener(|this, _: &ClickEvent, _, _| {
                                let _ = this.store.reveal_in_file_manager();
                            }))
                            .into_any_element(),
                        Button::new("reload-settings-file", "Reload")
                            .ghost()
                            .size(ButtonSize::Sm)
                            .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                                this.store.reload_from_disk();
                                this.reload(window, cx);
                            }))
                            .into_any_element(),
                    ]))
                    .render(t),
            ],
        );
        let links = form.section(
            Some("Links"),
            None,
            about::LINKS
                .iter()
                .map(|link| {
                    let url = link.url;
                    form.row(link.title)
                        .description(link.description)
                        .control(
                            Button::new(id("link", link.title), "Open")
                                .icon(IconName::ExternalLink)
                                .size(ButtonSize::Xs)
                                .on_click(move |_, _, _| {
                                    let _ = soprano_platform::system::open_default(url);
                                }),
                        )
                        .render(t)
                })
                .collect(),
        );
        let notices = form.section(
            Some("Licenses"),
            Some("Soprano is built on these projects; their licenses ship with the app."),
            about::LICENSE_NOTICES
                .iter()
                .map(|notice| {
                    let path = notice.path();
                    form.row(notice.component)
                        .description(notice.license)
                        .when_some_control(path.map(|path| {
                            Button::new(id("license", notice.component), "View")
                                .size(ButtonSize::Xs)
                                .on_click(move |_, _, _| {
                                    let _ =
                                        soprano_platform::system::open_default(&path.display().to_string());
                                })
                        }))
                        .render(t)
                })
                .collect(),
        );
        let keybindings = &self.snapshot.resolved.keybindings;
        let quick_reference = form.section(
            Some("Quick reference"),
            None,
            about::quick_reference_bindings(keybindings)
                .into_iter()
                .map(|binding| {
                    form.row(binding.label.clone())
                        .control(Keycaps::alternatives(soprano_config::settings_keycap_alternatives_for(
                            binding,
                            &keybindings.prefix_key,
                            self.platform,
                        )))
                        .render(t)
                })
                .collect(),
        );
        vec![
            about.into_any_element(),
            links.into_any_element(),
            notices.into_any_element(),
            quick_reference.into_any_element(),
        ]
    }
}

/// The 8 px mark before a login: a filled dot for the chosen one, a ring for the others, an
/// error diamond for a login with a problem.
pub(crate) fn account_mark(is_selected: bool, has_problem: bool, t: &SopranoTheme) -> AnyElement {
    let side = t.z(8.);
    if has_problem {
        return icon(IconName::Square)
            .size(7.)
            .color(t.failed)
            .rotate(gpui::radians(std::f32::consts::FRAC_PI_4))
            .into_any_element();
    }
    if is_selected {
        div().size(side).rounded_full().bg(t.foreground).into_any_element()
    } else {
        div().size(side).rounded_full().border_1().border_color(t.muted).into_any_element()
    }
}

fn badge_chip(text: &'static str, t: &SopranoTheme) -> impl IntoElement {
    div()
        .flex_none()
        .px(t.z(6.))
        .h(t.z(18.))
        .flex()
        .items_center()
        .rounded(t.z(4.))
        .bg(t.raised)
        .border_1()
        .border_color(t.border)
        .text_size(t.z(size::SMALL))
        .text_color(t.muted)
        .child(text)
}

/// Small builder conveniences for optional parts.
trait WhenSome: Sized {
    fn when_some_control(self, control: Option<impl IntoElement>) -> Self;
    fn when_some_description_color(self, color: Option<Hsla>) -> Self;
    fn when_title_color(self, color: Option<Hsla>) -> Self;
    fn when_tooltip(self, text: Option<&'static str>) -> Self;
}

impl WhenSome for crate::form::Row {
    fn when_some_control(self, control: Option<impl IntoElement>) -> Self {
        match control {
            Some(control) => self.control(control),
            None => self,
        }
    }

    fn when_some_description_color(self, color: Option<Hsla>) -> Self {
        match color {
            Some(color) => self.description_color(color),
            None => self,
        }
    }

    fn when_title_color(self, color: Option<Hsla>) -> Self {
        match color {
            Some(color) => self.title_color(color),
            None => self,
        }
    }

    fn when_tooltip(self, text: Option<&'static str>) -> Self {
        match text {
            Some(text) => self.tooltip(text),
            None => self,
        }
    }
}

trait WhenIcon: Sized {
    fn when_icon(self, icon: Option<IconName>) -> Self;
}

impl WhenIcon for Button {
    fn when_icon(self, icon: Option<IconName>) -> Self {
        match icon {
            Some(icon) => self.icon(icon),
            None => self,
        }
    }
}
