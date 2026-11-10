//! The pages: a lead paragraph where a page needs one, then titled sections of grouped rows
//! (`form`).

use gpui::{
    AnyElement, ClickEvent, Context, ElementId, FontWeight, Hsla, IntoElement, MouseButton, ParentElement,
    SharedString, Styled, Window, div, prelude::*,
};
use gpui_component::input::InputState;
use soprano_accounts::presentation::{
    AccountsPage, Button as AccountButton, ButtonVariant as AccountButtonVariant, EntryRow, SectionBody,
    SectionFooter,
};
use soprano_config::{
    AppSettings, AppearancePreference, ConfigIssue, DefaultKeybindings, Limits, Severity, prefix_legend_for,
};
use soprano_launch::MachineCheck;
use soprano_types::{AgentProfile, DefaultAgents};
use soprano_ui::button::{Button, ButtonSize, ButtonVariant, IconButton, IconButtonSize};
use soprano_ui::controls::{SegmentedControl, Switch, TextInput};
use soprano_ui::fonts::size;
use soprano_ui::keycaps::Keycaps;
use soprano_ui::theme::{AppTheme, Appearance, FOLIO_ID, FOLIO_INK, FOLIO_PAPER, ThemeOption, theme_for};
use soprano_ui::tooltip::tooltip;
use soprano_ui::{Icon, IconName, SopranoTheme, agent_icon_stem, icon};

use crate::about;
use crate::agents::{self, AgentField};
use crate::form::{Form, INSET, mono};
use crate::general::{self, Toggle};
use crate::notifications::{NotificationStatusRow, StatusTone};
use crate::shortcuts::{self, ShortcutEntry};
use crate::view::{MachineStatus, Recording, SettingsView};

fn id(prefix: &str, key: impl std::fmt::Display) -> ElementId {
    SharedString::from(format!("{prefix}-{key}")).into()
}

/// The dot before a status line.
fn tone_color(t: &SopranoTheme, tone: StatusTone) -> Hsla {
    match tone {
        StatusTone::Normal => t.dim,
        StatusTone::Success => t.done,
        StatusTone::Error => t.failed,
    }
}

impl SettingsView {
    fn open_file_button(&self, key: &str, cx: &mut Context<Self>) -> Button {
        Button::new(id("open-settings-file", key), "Open settings.json")
            .size(ButtonSize::Sm)
            .on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.open_settings_file(cx)))
    }

    /// A page's opening paragraph with `end` beside it.
    fn lead(&self, form: &Form, text: impl Into<SharedString>, end: impl IntoElement) -> AnyElement {
        div()
            .flex()
            .flex_row()
            .items_start()
            .gap(form.t.z(24.))
            .child(div().flex_1().min_w_0().child(form.lead(text)))
            .child(div().flex_none().child(end))
            .into_any_element()
    }

    /// What `settings.json` got wrong: without this, a typo in the file would fail silently.
    fn issues_callout(&self, form: &Form, issues: &[ConfigIssue], cx: &mut Context<Self>) -> AnyElement {
        let t = form.t;
        let tone = |severity: Severity| match severity {
            Severity::Error => t.failed,
            Severity::Warning => t.approval,
        };
        let worst =
            if issues.iter().any(|issue| issue.severity == Severity::Error) { t.failed } else { t.approval };
        let title = match issues.len() {
            1 => "settings.json has a problem".to_owned(),
            count => format!("settings.json has {count} problems"),
        };
        let lines = issues
            .iter()
            .map(|issue| {
                let text = match issue.line {
                    Some(line) => format!("Line {line}: {}", issue.message),
                    None => issue.message.clone(),
                };
                (SharedString::from(text), tone(issue.severity))
            })
            .collect();
        form.callout(worst, title, lines, Some(self.open_file_button("issues", cx).into_any_element()))
            .into_any_element()
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

        let issues = self.snapshot.issues();
        if !issues.is_empty() {
            sections.push(self.issues_callout(&form, &issues, cx));
        }
        sections.push(self.appearance_section(&form, &settings, &defaults, cx));
        sections.push(
            form.section("Window").rows(
                [Toggle::HideWindowBar, Toggle::HideWindowTabs, Toggle::StatusBarUptime]
                    .map(|toggle| self.toggle_row(&form, toggle, &settings, &defaults, cx))
                    .into(),
            ),
        );
        sections.push(form.section("Session").rows(vec![self.toggle_row(
            &form,
            Toggle::RestoreLastSession,
            &settings,
            &defaults,
            cx,
        )]));

        // Permission lives in the OS settings, and macOS only ever prompts once. The row says
        // where it stands and offers the way there.
        let status = NotificationStatusRow::new(self.authorization);
        let status_row = form
            .row(status.title)
            .leading(form.dot(tone_color(t, status.tone)))
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
            form.section("Notifications")
                .note("Banners for panes that are not focused, named window ▸ pane.")
                .rows(vec![
                    self.toggle_row(&form, Toggle::NotificationSound, &settings, &defaults, cx),
                    status_row,
                ]),
        );

        sections.push(self.project_directories_section(&form, cx));
        sections.push(self.keybinding_behavior_section(&form, window, cx));
        sections
    }

    /// The theme tiles and, for Folio, which of its two palettes to use. The section's reset
    /// button puts the default theme back.
    fn appearance_section(
        &self,
        form: &Form,
        settings: &AppSettings,
        defaults: &AppSettings,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = form.t;
        let tiles: Vec<AnyElement> = soprano_ui::theme::theme_options()
            .into_iter()
            .map(|option| self.theme_tile(option, option.id == settings.theme_id, t, cx))
            .collect();
        // The tiles' selection rings stand 2 px outside their previews.
        let theme = div()
            .grid()
            .grid_cols(5)
            .gap_x(t.z(6.))
            .gap_y(t.z(10.))
            .px(t.z(INSET - 2.))
            .pt(t.z(12.))
            .pb(t.z(10.))
            .children(tiles);

        let appearance_index =
            AppearancePreference::ALL.iter().position(|p| *p == settings.appearance).unwrap_or_default();
        let appearance = SegmentedControl::new(
            "settings-appearance",
            AppearancePreference::ALL.map(general::appearance_title),
        )
        .selected(appearance_index)
        .well()
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
        let appearance_row = form
            .row("Appearance")
            .description(general::appearance_description())
            .reset_when(
                settings.appearance != defaults.appearance,
                "reset-appearance",
                cx.listener(|this, _: &ClickEvent, window, cx| {
                    this.reset(general::APPEARANCE_KEY, window, cx)
                }),
            )
            .control(appearance)
            .render(t);
        form.section("Theme")
            .note(general::THEME_DESCRIPTION)
            .reset_when(
                settings.theme_id != defaults.theme_id,
                "reset-theme",
                cx.listener(|this, _: &ClickEvent, window, cx| this.reset(general::THEME_KEY, window, cx)),
            )
            .rows(vec![theme.into_any_element(), appearance_row])
    }

    /// One theme: a preview in its own colors over its name. Folio shows both of its palettes,
    /// since it follows the appearance.
    fn theme_tile(
        &self,
        option: ThemeOption,
        selected: bool,
        t: &SopranoTheme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme_id = option.id;
        let group = SharedString::from(format!("settings-theme-{theme_id}"));
        let palettes: Vec<&'static AppTheme> = if theme_id == FOLIO_ID {
            vec![&FOLIO_PAPER, &FOLIO_INK]
        } else {
            vec![theme_for(theme_id, Appearance::Dark)]
        };
        let preview = div()
            .flex()
            .flex_row()
            .h(t.z(54.))
            .rounded(t.z(6.))
            .border_1()
            .border_color(t.border)
            .overflow_hidden()
            .children(palettes.into_iter().map(|palette| theme_swatch(palette, t)));
        let (hover_ring, hover_text) = (t.input, t.foreground);
        div()
            .id(group.clone())
            .debug_selector(|| group.to_string())
            .group(group.clone())
            .flex()
            .flex_col()
            .gap(t.z(4.))
            .min_w_0()
            .cursor_pointer()
            .child(
                div()
                    .p(t.z(2.))
                    .rounded(t.z(9.))
                    .border_1()
                    .border_color(if selected { t.accent } else { gpui::transparent_black() })
                    .when(!selected, |ring| {
                        ring.group_hover(group.clone(), move |s| s.border_color(hover_ring))
                    })
                    .child(preview),
            )
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(t.z(4.))
                    .px(t.z(3.))
                    .text_size(t.z(size::META))
                    .line_height(t.z(17.))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_color(if selected { t.foreground } else { t.muted })
                            .when(selected, |name| name.font_weight(FontWeight::MEDIUM))
                            .when(!selected, |name| {
                                name.group_hover(group.clone(), move |s| s.text_color(hover_text))
                            })
                            .child(option.name),
                    )
                    .when(selected, |row| row.child(icon(IconName::Check).size(12.).color(t.accent))),
            )
            .on_click(
                cx.listener(move |this, _: &ClickEvent, window, cx| this.select_theme(theme_id, window, cx)),
            )
            .into_any_element()
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

    fn project_directories_section(&self, form: &Form, cx: &mut Context<Self>) -> AnyElement {
        let t = form.t;
        let directories = general::configured_project_directories(&self.store);
        let mut rows = Vec::new();
        if directories.is_empty() {
            rows.push(
                form.placeholder(general::NO_PROJECT_DIRECTORIES, general::NO_PROJECT_DIRECTORIES_HINT),
            );
        }
        for (index, directory) in directories.iter().enumerate() {
            let mut row = form
                .row(directory.clone())
                .mono_title()
                .leading(icon(IconName::Folder).size(15.).color(t.muted));
            if !general::is_reachable_directory(directory) {
                row = row.badge(form.badge("Not found", t.approval));
            }
            rows.push(
                row.control(
                    IconButton::new(id("remove-directory", index), IconName::X)
                        .tooltip("Remove from the list")
                        .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                            this.remove_project_directory(index, window, cx)
                        })),
                )
                .render(t),
            );
        }
        rows.push(
            form.bar(vec![
                div()
                    .flex_1()
                    .min_w_0()
                    .child(TextInput::new(&self.project_input).small())
                    .into_any_element(),
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
        form.section("Project directories").note(general::PROJECT_DIRECTORIES_NOTE).rows(rows)
    }

    fn keybinding_behavior_section(
        &self,
        form: &Form,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = form.t;
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
            .h(t.z(28.))
            .px(t.z(10.))
            .rounded(t.z(7.))
            .border_1()
            .border_color(if recording || focused { t.accent } else { t.input })
            .bg(t.raised)
            .cursor_pointer()
            .text_size(t.z(size::ROW))
            .font_weight(FontWeight::MEDIUM)
            .text_color(if recording { t.muted } else { t.foreground })
            .child(legend)
            .tooltip(tooltip(match self.platform {
                soprano_config::KeyPlatform::Mac => "Click, then press the key to use with Control",
                soprano_config::KeyPlatform::Other => "Click, then press the key to use with Ctrl",
            }))
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .on_click(cx.listener(|this, _: &ClickEvent, window, cx| this.begin_prefix_recording(window, cx)))
            .on_key_down(cx.listener(Self::on_prefix_key));

        let timeout_limits = Limits::PREFIX_TIMEOUT_MS;
        let resize_limits = Limits::RESIZE_TICK_PERCENT;
        let number = |input: &gpui::Entity<InputState>, unit: &'static str| {
            div().w(t.z(104.)).child(
                TextInput::new(input)
                    .small()
                    .suffix(div().text_size(t.z(size::META)).text_color(t.dim).child(unit)),
            )
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
                .control(number(&self.timeout_input, "ms"))
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
                .control(number(&self.resize_input, "%"))
                .render(t),
        ];
        form.section("Keybindings").rows(rows)
    }

    // MARK: - Machines

    pub(crate) fn machines_page(&mut self, t: &SopranoTheme, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let form = Form::new(t);
        let machines = &self.snapshot.resolved.machines;
        let mut rows = Vec::new();
        if machines.is_empty() {
            rows.push(form.placeholder(general::NO_MACHINES, general::NO_MACHINES_HINT));
        }
        for machine in machines {
            let mut command = format!("ssh {}", machine.destination());
            for arg in &machine.ssh_args {
                command.push(' ');
                command.push_str(arg);
            }
            if let Some(directory) = &machine.directory {
                command.push_str(&format!(" · {directory}"));
            }
            let status = self.machine_status.get(&machine.name);
            let checking = matches!(status, Some(MachineStatus::Checking));
            let mut row = form
                .row(machine.name.clone())
                .mono_title()
                .leading(icon(IconName::Server).size(15.).color(t.muted))
                .description(command)
                .mono_description();
            row = match status {
                None => row,
                Some(MachineStatus::Checking) => row.status("Checking…", t.dim),
                Some(MachineStatus::Checked(check)) => {
                    let healthy = matches!(check, MachineCheck::Ready { tmux: Some(_), .. });
                    row.status(check.summary(), if healthy { t.done } else { t.approval })
                }
            };
            let check_name = machine.name.clone();
            let remove_name = machine.name.clone();
            rows.push(
                row.control(form.controls(vec![
                    IconButton::new(id("check-machine", &machine.name), IconName::RefreshCw)
                        .icon_size(14.)
                        .tooltip("Check the connection")
                        .disabled(checking)
                        .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| {
                            this.check_machine(&check_name, cx)
                        }))
                        .into_any_element(),
                    IconButton::new(id("remove-machine", &machine.name), IconName::X)
                        .tooltip("Remove from the list")
                        .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                            this.remove_machine(&remove_name, window, cx)
                        }))
                        .into_any_element(),
                ]))
                .render(t),
            );
        }
        let add = form.bar(vec![
            div().flex_1().min_w_0().child(TextInput::new(&self.machine_input).small()).into_any_element(),
            Button::new("add-machine", "Add")
                .primary()
                .size(ButtonSize::Sm)
                .on_click(cx.listener(|this, _: &ClickEvent, window, cx| {
                    let text = this.machine_input.read(cx).value().to_string();
                    this.add_machine(&text, window, cx);
                }))
                .into_any_element(),
        ]);
        rows.push(
            div()
                .flex()
                .flex_col()
                .child(add)
                .when_some(self.machine_notice.as_ref(), |col, notice| {
                    col.child(
                        div().px(t.z(INSET)).pb(t.z(10.)).child(
                            form.small(notice.text.clone(), if notice.is_error { t.failed } else { t.muted })
                                .whitespace_normal(),
                        ),
                    )
                })
                .into_any_element(),
        );
        vec![form.lead(general::MACHINES_NOTE).into_any_element(), form.group(rows).into_any_element()]
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
        let search =
            TextInput::new(&self.shortcut_query).prefix(icon(IconName::Search).size(14.).color(t.muted));
        let mut sections = vec![
            div()
                .flex()
                .flex_col()
                .gap(t.z(14.))
                .child(search)
                .when(query.is_empty(), |top| {
                    top.child(self.lead(
                        &form,
                        shortcuts::instructions(&self.snapshot.resolved.keybindings),
                        self.open_file_button("shortcuts", cx),
                    ))
                })
                .into_any_element(),
        ];
        let issues = self.snapshot.issues();
        let general_issues = shortcuts::keybinding_issues(&issues);
        if !general_issues.is_empty() && query.is_empty() {
            let lines = general_issues
                .iter()
                .map(|issue| (SharedString::from(issue.message.clone()), t.approval))
                .collect();
            sections.push(form.callout(t.approval, "Keybinding problems", lines, None).into_any_element());
        }

        let groups = shortcuts::shortcut_groups_for(&self.snapshot.resolved, &issues, &query, self.platform);
        if groups.is_empty() {
            sections.push(
                form.group(vec![form.placeholder(shortcuts::NO_MATCHES_TITLE, shortcuts::NO_MATCHES_HINT)])
                    .into_any_element(),
            );
        }
        let prefix_key = self.snapshot.resolved.keybindings.prefix_key.clone();
        for group in groups {
            let count = group.entries.len();
            let rows =
                group.entries.iter().map(|entry| self.shortcut_row(entry, &prefix_key, &form, cx)).collect();
            sections.push(form.section(group.title).count(count).rows(rows));
        }
        sections
    }

    /// One shortcut on one line: its name (the id is its tooltip), what it does, and its keys,
    /// which record a new chord when clicked.
    fn shortcut_row(
        &self,
        entry: &ShortcutEntry,
        prefix_key: &str,
        form: &Form,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = form.t;
        let binding_id = entry.binding.id.clone();
        let recording = match &self.recording {
            Some(Recording::Binding { id, recorder }) if *id == binding_id => {
                Some(recorder.is_awaiting_prefix_key())
            }
            _ => None,
        };
        let keys: AnyElement = match recording {
            Some(awaiting) => div()
                .id(id("recording", &binding_id))
                .track_focus(&self.binding_focus)
                .flex()
                .flex_none()
                .items_center()
                .h(t.z(24.))
                .px(t.z(8.))
                .rounded(t.z(6.))
                .border_1()
                .border_color(t.accent)
                .bg(t.canvas)
                .text_size(t.z(size::META))
                .text_color(t.muted)
                .whitespace_nowrap()
                .child(shortcuts::recording_hint(awaiting, prefix_key, self.platform))
                .on_key_down(cx.listener(Self::on_binding_key))
                .into_any_element(),
            None => {
                let record_id = binding_id.clone();
                div()
                    .id(id("keys", &binding_id))
                    .flex()
                    .flex_none()
                    .items_center()
                    .h(t.z(24.))
                    .px(t.z(3.))
                    .rounded(t.z(6.))
                    .cursor_pointer()
                    .hover(|s| s.bg(t.hover))
                    .tooltip(tooltip("Click and press new keys to rebind"))
                    .child(if entry.is_disabled {
                        form.small("Off", t.dim).px(t.z(3.)).into_any_element()
                    } else {
                        Keycaps::alternatives(entry.caps.clone()).color(t.muted).into_any_element()
                    })
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                        this.begin_binding_recording(&record_id, window, cx)
                    }))
                    .into_any_element()
            }
        };
        let label_tooltip = if entry.is_customized {
            format!("{binding_id} · {}", shortcuts::CUSTOMIZED_TOOLTIP)
        } else {
            binding_id.clone()
        };
        let label = div()
            .id(id("shortcut", &binding_id))
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(t.z(6.))
            .w(t.z(190.))
            .tooltip(tooltip(label_tooltip))
            .child(
                div()
                    .min_w_0()
                    .truncate()
                    .text_size(t.z(size::UI))
                    .text_color(if entry.is_disabled { t.muted } else { t.foreground })
                    .child(entry.binding.label.clone()),
            )
            .when(entry.is_customized, |label| label.child(form.dot(t.accent).size(t.z(5.))));
        let reset = entry.is_resettable().then(|| {
            let reset_id = binding_id.clone();
            IconButton::new(id("reset-binding", &binding_id), IconName::UNDO)
                .size(IconButtonSize::Tab)
                .tooltip("Reset to default")
                .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                    this.reset(&shortcuts::binding_key_path(&reset_id), window, cx)
                }))
        });
        div()
            .flex()
            .flex_col()
            .justify_center()
            .gap(t.z(3.))
            .min_h(t.z(38.))
            .px(t.z(INSET))
            .py(t.z(6.))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(t.z(12.))
                    .child(label)
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(t.z(size::META))
                            .text_color(t.muted)
                            .child(entry.binding.description.clone()),
                    )
                    .children(reset)
                    .child(keys),
            )
            .children(entry.issues.iter().map(|issue| {
                div()
                    .text_size(t.z(size::META))
                    .line_height(t.z(17.))
                    .text_color(t.approval)
                    .child(issue.message.clone())
            }))
            .into_any_element()
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
        let configured = self.snapshot.resolved.configured_agent_ids.clone();
        let agents = self.snapshot.resolved.agents.clone();
        let profiles: Vec<AnyElement> = agents
            .iter()
            .map(|profile| self.agent_profile_row(profile, configured.contains(&profile.id), &form, cx))
            .collect();

        let [new_id, new_name, new_command] = self.new_agent_inputs.clone();
        let add_row = div()
            .flex()
            .flex_col()
            .gap(t.z(8.))
            .px(t.z(INSET))
            .py(t.z(10.))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(t.z(8.))
                    .child(div().flex_none().w(t.z(150.)).child(TextInput::new(&new_id).small()))
                    .child(div().flex_none().w(t.z(150.)).child(TextInput::new(&new_name).small()))
                    .child(div().flex_1().min_w_0().child(TextInput::new(&new_command).small()))
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
            self.lead(&form, agents::INTRO, self.open_file_button("agents", cx)),
            form.section("Profiles").count(agents.len()).rows(profiles),
            form.section("Add an agent")
                .note("A new id defines a new agent; it needs a command to run.")
                .rows(vec![add_row.into_any_element()]),
        ]
    }

    /// A profile as one line (icon, name, what it is, its command); a click opens its fields
    /// under it.
    fn agent_profile_row(
        &self,
        profile: &AgentProfile,
        is_configured: bool,
        form: &Form,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = form.t;
        let expanded = self.expanded_agent.as_deref() == Some(profile.id.as_str());
        let color: Hsla = soprano_ui::color::hsla(profile.color());
        let glyph = match agent_icon_stem(&profile.id) {
            Some(stem) => Icon::program(stem),
            None if profile.id == DefaultAgents::TERMINAL => Icon::new(IconName::SHELL),
            None => Icon::new(IconName::Bot),
        };
        let toggle_id = profile.id.clone();
        let header = div()
            .id(id("agent", &profile.id))
            .flex()
            .flex_row()
            .items_center()
            .gap(t.z(10.))
            .min_h(t.z(52.))
            .px(t.z(INSET))
            .py(t.z(8.))
            .cursor_pointer()
            .hover(|s| s.bg(t.hover))
            .child(
                icon(if expanded { IconName::ChevronDown } else { IconName::ChevronRight })
                    .size(12.)
                    .color(t.dim),
            )
            .child(glyph.size(16.).color(color))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_w_0()
                    .gap(t.z(1.))
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(t.z(8.))
                            .child(
                                div()
                                    .min_w_0()
                                    .truncate()
                                    .text_size(t.z(size::UI))
                                    .line_height(t.z(19.))
                                    .child(profile.name.clone()),
                            )
                            .when(is_configured, |row| {
                                row.child(form.badge(agents::CONFIGURED_BADGE, t.muted))
                            }),
                    )
                    .when(!profile.description.is_empty(), |col| {
                        col.child(
                            div()
                                .truncate()
                                .text_size(t.z(size::META))
                                .line_height(t.z(17.))
                                .text_color(t.muted)
                                .child(profile.description.clone()),
                        )
                    }),
            )
            .child(
                div()
                    .flex_none()
                    .max_w(t.z(260.))
                    .truncate()
                    .text_size(t.z(size::META))
                    .map(mono)
                    .text_color(t.muted)
                    .child(agents::command_line(profile)),
            )
            .on_click(cx.listener(move |this, _: &ClickEvent, _, cx| this.toggle_agent(&toggle_id, cx)));
        if !expanded {
            return header.into_any_element();
        }

        let fields = AgentField::ALL.iter().map(|field| {
            let input = self.agent_inputs.get(&(profile.id.clone(), *field)).cloned();
            div()
                .flex()
                .flex_col()
                .gap(t.z(5.))
                .min_w_0()
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(t.z(6.))
                        .text_size(t.z(size::SECTION))
                        .text_color(t.muted)
                        .child(field.label())
                        .when(*field == AgentField::Color, |label| label.child(form.dot(color))),
                )
                .children(input.map(|input| TextInput::new(&input).small()))
        });
        let built_in = agents::is_built_in(&profile.id);
        let reset_id = profile.id.clone();
        // Indented to the name, past the chevron and the icon.
        let body = div()
            .flex()
            .flex_col()
            .gap(t.z(12.))
            .pl(t.z(INSET + 48.))
            .pr(t.z(INSET))
            .pt(t.z(2.))
            .pb(t.z(14.))
            .child(div().grid().grid_cols(2).gap_x(t.z(12.)).gap_y(t.z(10.)).children(fields))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(t.z(12.))
                    .min_h(t.z(24.))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(t.z(size::SMALL))
                            .map(mono)
                            .text_color(t.dim)
                            .child(agents::patterns_line(profile)),
                    )
                    .when(is_configured, |row| {
                        let (label, glyph, variant) = if built_in {
                            ("Reset to default", IconName::UNDO, ButtonVariant::Secondary)
                        } else {
                            ("Remove agent", IconName::Trash, ButtonVariant::DestructiveOutline)
                        };
                        row.child(
                            Button::new(id("reset-agent", &profile.id), label)
                                .variant(variant)
                                .icon(glyph)
                                .size(ButtonSize::Xs)
                                .on_click(cx.listener(move |this, _: &ClickEvent, window, cx| {
                                    agents::remove_agent_entry(&this.store, &reset_id);
                                    this.reload(window, cx);
                                })),
                        )
                    }),
            );
        div().flex().flex_col().child(header).child(body).into_any_element()
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
        let refresh = form.controls(vec![
            form.small(page.updated.clone(), t.dim).into_any_element(),
            self.account_button(&page.refresh, "refresh", cx).size(ButtonSize::Sm).into_any_element(),
        ]);
        let mut sections = vec![self.lead(&form, page.intro, refresh)];
        for (section_index, section) in page.sections.iter().enumerate() {
            let mut rows = Vec::new();
            if let Some(error) = &section.error {
                rows.push(
                    form.row(error.title)
                        .leading(icon(IconName::CircleAlert).size(15.).color(t.failed))
                        .description(error.message.clone())
                        .description_color(t.failed)
                        .control(self.account_button(&error.dismiss, &format!("dismiss-{section_index}"), cx))
                        .render(t),
                );
            }
            match &section.body {
                SectionBody::Unavailable(reason) => {
                    rows.push(form.placeholder("Unavailable", reason.clone()))
                }
                SectionBody::Placeholder(text) => rows.push(form.row(*text).title_color(t.muted).render(t)),
                SectionBody::Rows(entries) => {
                    for (row_index, entry) in entries.iter().enumerate() {
                        rows.push(self.account_entry_row(
                            entry,
                            &format!("{section_index}-{row_index}"),
                            &form,
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
                    .bar(vec![
                        self.account_button(button, &format!("add-{section_index}"), cx).into_any_element(),
                    ])
                    .into_any_element(),
            });
            sections.push(form.section(section.title.clone()).note(section.note).rows(rows));
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
        form: &Form,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let t = form.t;
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
            .gap(t.z(16.))
            .min_h(t.z(52.))
            .px(t.z(INSET))
            .py(t.z(9.))
            .when(entry.is_selected, |row| {
                row.bg(t.foreground.opacity(if t.is_dark() { 0.05 } else { 0.03 }))
            })
            .child(
                div()
                    .flex()
                    .flex_row()
                    .flex_1()
                    .min_w_0()
                    .gap(t.z(10.))
                    .child(div().pt(t.z(6.)).child(account_mark(entry.is_selected, has_problem, t)))
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .min_w_0()
                            .gap(t.z(1.))
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
                                            .line_height(t.z(19.))
                                            .when(entry.is_selected, |title| {
                                                title.font_weight(FontWeight::MEDIUM)
                                            })
                                            .child(entry.title.clone()),
                                    )
                                    .when_some(entry.badge, |row, badge| {
                                        row.child(form.badge(badge, t.muted))
                                    }),
                            )
                            .child(
                                div()
                                    .text_size(t.z(size::META))
                                    .line_height(t.z(17.))
                                    .text_color(t.muted)
                                    .child(entry.detail.clone()),
                            )
                            .when_some(entry.problem.clone().filter(|_| has_problem), |col, problem| {
                                col.child(
                                    div()
                                        .text_size(t.z(size::META))
                                        .line_height(t.z(17.))
                                        .text_color(t.failed)
                                        .child(problem),
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
        let links = about::LINKS.iter().map(|link| {
            let url = link.url;
            Button::new(id("link", link.title), link.title)
                .icon(IconName::ExternalLink)
                .size(ButtonSize::Sm)
                .tooltip(link.description)
                .on_click(move |_, _, _| {
                    let _ = soprano_platform::system::open_default(url);
                })
        });
        let hero = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(t.z(18.))
            .child(gpui::img(about::APP_ICON).flex_none().size(t.z(72.)))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_w_0()
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_baseline()
                            .gap(t.z(8.))
                            .child(
                                div()
                                    .text_size(t.z(20.))
                                    .line_height(t.z(26.))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child(soprano_platform::identity::AppIdentity::current().name),
                            )
                            .child(
                                div()
                                    .text_size(t.z(size::ROW))
                                    .map(mono)
                                    .text_color(t.muted)
                                    .child(soprano_platform::identity::app_version()),
                            ),
                    )
                    .child(
                        div()
                            .text_size(t.z(size::ROW))
                            .line_height(t.z(19.))
                            .text_color(t.muted)
                            .child(about::TAGLINE),
                    )
                    .child(
                        div()
                            .text_size(t.z(size::META))
                            .line_height(t.z(17.))
                            .text_color(t.dim)
                            .child(about::RUNTIME),
                    )
                    .child(div().flex().flex_row().flex_wrap().gap(t.z(6.)).pt(t.z(12.)).children(links)),
            );

        let settings_file = form.section("Settings file").rows(vec![
            form.row(self.store.display_path())
                .mono_title()
                .leading(icon(IconName::FileText).size(15.).color(t.muted))
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
        ]);

        let keybindings = &self.snapshot.resolved.keybindings;
        let reference = about::quick_reference_bindings(keybindings)
            .into_iter()
            .map(|binding| {
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(t.z(12.))
                    .h(t.z(30.))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(t.z(size::UI))
                            .child(binding.label.clone()),
                    )
                    .child(
                        Keycaps::alternatives(soprano_config::settings_keycap_alternatives_for(
                            binding,
                            &keybindings.prefix_key,
                            self.platform,
                        ))
                        .color(t.muted),
                    )
            })
            .collect::<Vec<_>>();
        let quick_reference = form.section("Quick reference").body(form.group(vec![
                div()
                    .grid()
                    .grid_cols(2)
                    .gap_x(t.z(32.))
                    .px(t.z(INSET))
                    .py(t.z(8.))
                    .children(reference)
                    .into_any_element(),
            ]));

        let notices = form
            .section("Licenses")
            .note("Soprano is built on these projects; their licenses ship with the app.")
            .rows(
                about::LICENSE_NOTICES
                    .iter()
                    .map(|notice| {
                        let view = notice.path().map(|path| {
                            Button::new(id("license", notice.component), "View")
                                .variant(ButtonVariant::Text)
                                .on_click(move |_, _, _| {
                                    let _ =
                                        soprano_platform::system::open_default(&path.display().to_string());
                                })
                                .into_any_element()
                        });
                        // The View column keeps its width so the license names line up.
                        form.row(notice.component)
                            .compact()
                            .control(form.controls(vec![
                                form.small(notice.license, t.muted).into_any_element(),
                                div().flex().justify_end().w(t.z(32.)).children(view).into_any_element(),
                            ]))
                            .render(t)
                    })
                    .collect(),
            );
        vec![hero.into_any_element(), settings_file, quick_reference, notices]
    }
}

/// A theme's terminal in miniature: its background with lines in its text and ANSI colors.
fn theme_swatch(palette: &AppTheme, t: &SopranoTheme) -> gpui::Div {
    let color = soprano_ui::color::hsla;
    let foreground = color(palette.terminal.foreground);
    let ansi = palette.terminal.ansi;
    let bar = |width: f32, fill: Hsla| div().flex_none().w(t.z(width)).h(t.z(4.)).rounded(t.z(2.)).bg(fill);
    let line = || div().flex().flex_row().gap(t.z(4.));
    div()
        .flex()
        .flex_col()
        .flex_1()
        .min_w_0()
        .h_full()
        .justify_center()
        .gap(t.z(6.))
        .px(t.z(9.))
        .overflow_hidden()
        .bg(color(palette.terminal.background))
        .child(line().child(bar(7., color(ansi[2]))).child(bar(26., foreground.opacity(0.9))))
        .child(
            line()
                .child(bar(16., color(ansi[4])))
                .child(bar(11., color(ansi[3])))
                .child(bar(9., color(ansi[5]))),
        )
        .child(line().child(bar(32., foreground.opacity(0.4))))
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

/// Small builder conveniences for optional parts.
trait WhenSome: Sized {
    fn when_some_control(self, control: Option<impl IntoElement>) -> Self;
}

impl WhenSome for crate::form::Row {
    fn when_some_control(self, control: Option<impl IntoElement>) -> Self {
        match control {
            Some(control) => self.control(control),
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
