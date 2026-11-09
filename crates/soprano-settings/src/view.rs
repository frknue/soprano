//! The settings screen as one GPUI view: the card over the window (Herdr's dialog frame:
//! popover fill, 1 px border, radius 8, shadow, 35 % black backdrop), sized like the Swift
//! card (at most 1280×960, 32 px clear of every window edge), the 240 px navigation, the
//! "Settings › Page" header with its close button, and the scrolling page column.
//!
//! The view keeps no settings state of its own: every control writes one key into
//! `settings.json` through [`ConfigStore`], and the page re-renders when the store (or the
//! accounts) publish a change. Store observers run on whichever thread changed the file; they
//! only wake a task on the window's executor, which re-reads the store on the main thread.

use std::collections::HashMap;
use std::rc::Rc;

use gpui::{
    AnyElement, App, AppContext as _, ClickEvent, Context, DismissEvent, ElementId, Entity, EventEmitter,
    FocusHandle, Focusable, FontWeight, IntoElement, KeyDownEvent, MouseButton, ParentElement,
    PathPromptOptions, Pixels, Point, Render, ScrollHandle, SharedString, Styled, Subscription, Task, Window,
    div, point, prelude::*, px,
};
use gpui_component::input::{self as component_input, InputEvent, InputState};
use soprano_accounts::AccountsSource;
use soprano_accounts::models::AccountsSnapshot;
use soprano_accounts::presentation::{Confirmation, PageAction};
use soprano_config::{ConfigSnapshot, ConfigStore, KeyPlatform, Limits};
use soprano_ui::button::{IconButton, IconButtonSize};
use soprano_ui::dialog::{Dialog, DialogContent};
use soprano_ui::fonts::{self, size};
use soprano_ui::menu::ContextMenu;
use soprano_ui::{ActiveSopranoTheme, IconName, SopranoTheme, icon};

use crate::agents::AgentField;
use crate::general::{self, AddDirectoryOutcome};
use crate::notifications::{NotificationAuthorization, NotificationStatusProvider};
use crate::shortcuts::{ChordRecorder, RecordStep, RecordedKey};
use crate::tab::SettingsTab;

/// Width of the navigation column.
pub const NAV_WIDTH: f32 = 240.0;
/// The page column never grows past this.
pub const PAGE_MAX_WIDTH: f32 = 768.0;
/// The card's largest size and its distance from the window edges.
pub const CARD_MAX_WIDTH: f32 = 1280.0;
pub const CARD_MAX_HEIGHT: f32 = 960.0;
pub const CARD_MARGIN: f32 = 32.0;
const HEADER_HEIGHT: f32 = 48.0;

/// Width of the page column for a card `width` wide (`SettingsViewController.pageWidth`).
pub fn page_width(card_width: f32) -> f32 {
    (card_width - NAV_WIDTH - 48.0).clamp(320.0, PAGE_MAX_WIDTH)
}

/// What the host reacts to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SettingsEvent {
    /// Esc, the close button, or a click outside the card: take the screen away.
    Close,
    /// "Open settings.json" was used; the view already asked the OS to open the file.
    /// `error` says why that failed, for the host to show.
    OpenSettingsFile { error: Option<String> },
}

/// What is recording keys right now.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Recording {
    /// The General page's Prefix key control.
    Prefix,
    /// A Keyboard Shortcuts row.
    Binding { id: String, recorder: ChordRecorder },
}

pub struct SettingsView {
    pub(crate) store: ConfigStore,
    pub(crate) accounts: Rc<dyn AccountsSource>,
    notifications: Rc<dyn NotificationStatusProvider>,
    pub(crate) snapshot: ConfigSnapshot,
    pub(crate) accounts_snapshot: AccountsSnapshot,
    pub(crate) authorization: Option<NotificationAuthorization>,
    pub(crate) tab: SettingsTab,
    pub(crate) platform: KeyPlatform,
    focus_handle: FocusHandle,
    pub(crate) prefix_focus: FocusHandle,
    pub(crate) binding_focus: FocusHandle,
    pub(crate) recording: Option<Recording>,
    pub(crate) shortcut_query: Entity<InputState>,
    pub(crate) project_input: Entity<InputState>,
    pub(crate) timeout_input: Entity<InputState>,
    pub(crate) resize_input: Entity<InputState>,
    pub(crate) agent_inputs: HashMap<(String, AgentField), Entity<InputState>>,
    pub(crate) new_agent_inputs: [Entity<InputState>; 3],
    pub(crate) new_agent_error: Option<&'static str>,
    dialog: Option<Entity<Dialog>>,
    menu: Option<Entity<ContextMenu>>,
    pub(crate) scroll: ScrollHandle,
    subscriptions: Vec<Subscription>,
    _tasks: Vec<Task<()>>,
}

impl EventEmitter<SettingsEvent> for SettingsView {}

impl Focusable for SettingsView {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl SettingsView {
    /// The screen over `store`, the accounts `accounts` lists and acts on (the app's
    /// `AccountsController`), and the notification permission `notifications` reports. It
    /// opens on General and takes the keyboard.
    pub fn new(
        store: ConfigStore,
        accounts: Rc<dyn AccountsSource>,
        notifications: Rc<dyn NotificationStatusProvider>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let observer_id = format!("soprano-settings-{}", cx.entity_id());
        let snapshot = store.snapshot();
        let keybindings = snapshot.resolved.keybindings.clone();

        let new_input =
            |placeholder: &'static str, value: String, window: &mut Window, cx: &mut Context<Self>| {
                cx.new(|cx| InputState::new(window, cx).placeholder(placeholder).default_value(value))
            };
        let shortcut_query = new_input(crate::shortcuts::SEARCH_PLACEHOLDER, String::new(), window, cx);
        let project_input = new_input("Folder path", String::new(), window, cx);
        let timeout_input = new_input("", keybindings.prefix_timeout_ms.to_string(), window, cx);
        let resize_input = new_input("", (keybindings.resize_tick_percent as i64).to_string(), window, cx);
        let new_agent_inputs = [
            new_input("id, e.g. aider", String::new(), window, cx),
            new_input("Name", String::new(), window, cx),
            new_input("Command", String::new(), window, cx),
        ];

        let mut subscriptions = vec![
            cx.subscribe_in(&shortcut_query, window, |_, _, event: &InputEvent, _, cx| {
                if matches!(event, InputEvent::Change) {
                    cx.notify();
                }
            }),
            // The folder field adds on Enter only; leaving it keeps what is typed.
            cx.subscribe_in(&project_input, window, |this, input, event: &InputEvent, window, cx| {
                if matches!(event, InputEvent::PressEnter { .. }) {
                    let text = input.read(cx).value().to_string();
                    this.add_project_directory(&text, window, cx);
                }
            }),
            // The number fields commit when editing ends, by Enter or by leaving them.
            cx.subscribe_in(&timeout_input, window, |this, _, event: &InputEvent, window, cx| {
                if matches!(event, InputEvent::PressEnter { .. } | InputEvent::Blur) {
                    this.commit_prefix_timeout(window, cx);
                }
            }),
            cx.subscribe_in(&resize_input, window, |this, _, event: &InputEvent, window, cx| {
                if matches!(event, InputEvent::PressEnter { .. } | InputEvent::Blur) {
                    this.commit_resize_step(window, cx);
                }
            }),
        ];
        for input in new_agent_inputs.clone() {
            subscriptions.push(cx.subscribe_in(&input, window, |this, _, event: &InputEvent, window, cx| {
                match event {
                    InputEvent::PressEnter { .. } => this.add_agent(window, cx),
                    InputEvent::Change if this.new_agent_error.take().is_some() => cx.notify(),
                    _ => {}
                }
            }));
        }

        let prefix_focus = cx.focus_handle();
        let binding_focus = cx.focus_handle();
        // Leaving a recorder ends its recording and keeps the current keys.
        subscriptions.push(cx.on_blur(&prefix_focus, window, |this, _, cx| {
            if this.recording == Some(Recording::Prefix) {
                this.recording = None;
                cx.notify();
            }
        }));
        subscriptions.push(cx.on_blur(&binding_focus, window, |this, _, cx| {
            if matches!(this.recording, Some(Recording::Binding { .. })) {
                this.recording = None;
                cx.notify();
            }
        }));

        // settings.json changes (another editor, the watcher, a control here) → re-read.
        let (config_tx, config_rx) = async_channel::unbounded::<()>();
        store.add_observer(observer_id.clone(), move |_| {
            let _ = config_tx.try_send(());
        });
        let config_task = cx.spawn_in(window, async move |this, cx| {
            while config_rx.recv().await.is_ok() {
                while config_rx.try_recv().is_ok() {}
                if this.update_in(cx, |this, window, cx| this.reload(window, cx)).is_err() {
                    break;
                }
            }
        });

        // A snapshot can change from inside a button's own action; the task lets that event
        // finish before the page re-renders.
        let (accounts_tx, accounts_rx) = async_channel::unbounded::<()>();
        accounts.add_observer(
            &observer_id,
            std::sync::Arc::new(move |_: &AccountsSnapshot| {
                let _ = accounts_tx.try_send(());
            }),
        );
        let accounts_task = cx.spawn_in(window, async move |this, cx| {
            while accounts_rx.recv().await.is_ok() {
                while accounts_rx.try_recv().is_ok() {}
                let updated = this.update(cx, |this, cx| {
                    this.accounts_snapshot = this.accounts.snapshot();
                    cx.notify();
                });
                if updated.is_err() {
                    break;
                }
            }
        });

        let release_store = store.clone();
        let release_accounts = accounts.clone();
        let release_id = observer_id.clone();
        subscriptions.push(cx.on_release(move |_, _| {
            release_store.remove_observer(&release_id);
            release_accounts.remove_observer(&release_id);
        }));

        let focus_handle = cx.focus_handle();
        focus_handle.focus(window, cx);
        let accounts_snapshot = accounts.snapshot();
        let authorization = notifications.authorization();
        Self {
            store,
            accounts,
            notifications,
            snapshot,
            accounts_snapshot,
            authorization,
            tab: SettingsTab::General,
            platform: KeyPlatform::current(),
            focus_handle,
            prefix_focus,
            binding_focus,
            recording: None,
            shortcut_query,
            project_input,
            timeout_input,
            resize_input,
            agent_inputs: HashMap::new(),
            new_agent_inputs,
            new_agent_error: None,
            dialog: None,
            menu: None,
            scroll: ScrollHandle::new(),
            subscriptions,
            _tasks: vec![config_task, accounts_task],
        }
    }

    // MARK: - Public API

    /// The page on screen.
    pub fn current_tab(&self) -> SettingsTab {
        self.tab
    }

    /// Opens `tab` (the Accounts page from the status bar's usage readout, the General page
    /// from `⌘,`). Opening Accounts refreshes them, throttled by the controller.
    pub fn switch_tab(&mut self, tab: SettingsTab, window: &mut Window, cx: &mut Context<Self>) {
        let changed = tab != self.tab;
        self.tab = tab;
        self.recording = None;
        if changed {
            self.scroll.set_offset(point(px(0.), px(0.)));
            self.focus_handle.focus(window, cx);
        }
        if tab == SettingsTab::Accounts {
            soprano_accounts::presentation::AccountsPage::on_open(&*self.accounts);
            self.accounts_snapshot = self.accounts.snapshot();
        }
        cx.notify();
    }

    /// The Keyboard Shortcuts filter text.
    pub fn shortcut_query(&self, cx: &App) -> String {
        self.shortcut_query.read(cx).value().to_string()
    }

    /// Sets the Keyboard Shortcuts filter.
    pub fn set_shortcut_query(&mut self, query: &str, window: &mut Window, cx: &mut Context<Self>) {
        let query = query.to_owned();
        self.shortcut_query.update(cx, |state, cx| state.set_value(query, window, cx));
        cx.notify();
    }

    /// Whether a recorder is taking every key (the Prefix key control or a shortcut row): the
    /// host's keybinding resolver must step aside (`KeyContext::keys_captured`), since ⌃A,
    /// ⌘1 and friends are exactly what a recording wants.
    pub fn captures_keys(&self) -> bool {
        self.recording.is_some()
    }

    /// Re-reads the notification permission; the app calls it when the OS reports a change
    /// (the user may come straight back from System Settings).
    pub fn notification_authorization_changed(&mut self, cx: &mut Context<Self>) {
        let authorization = self.notifications.authorization();
        if authorization != self.authorization {
            self.authorization = authorization;
            cx.notify();
        }
    }

    /// The store's current state on screen, keeping what is being typed into focused fields.
    pub fn reload(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.snapshot = self.store.snapshot();
        let keybindings = self.snapshot.resolved.keybindings.clone();
        self.sync_input(&self.timeout_input.clone(), keybindings.prefix_timeout_ms.to_string(), window, cx);
        self.sync_input(
            &self.resize_input.clone(),
            (keybindings.resize_tick_percent as i64).to_string(),
            window,
            cx,
        );
        self.sync_agent_inputs(window, cx);
        cx.notify();
    }

    // MARK: - Writing

    pub(crate) fn sync_input(
        &self,
        input: &Entity<InputState>,
        value: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let state = input.read(cx);
        if state.focus_handle(cx).is_focused(window) || state.value().as_ref() == value {
            return;
        }
        input.update(cx, |state, cx| state.set_value(value, window, cx));
    }

    /// Writes one key and puts the result on screen.
    pub(crate) fn write(
        &mut self,
        value: impl Into<serde_json::Value>,
        path: &[&str],
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.store.write(value, path);
        self.reload(window, cx);
    }

    /// Removes one key so the built-in default applies again.
    pub(crate) fn reset(&mut self, path: &[&str], window: &mut Window, cx: &mut Context<Self>) {
        self.store.remove(path);
        self.reload(window, cx);
        self.apply_theme_fallback(cx);
    }

    /// The app's store observer applies theme and appearance; a standalone screen (demos,
    /// tests) has none, so apply them here unless already in force.
    pub(crate) fn apply_theme_fallback(&self, cx: &mut App) {
        if !cx.has_global::<SopranoTheme>() {
            return;
        }
        let settings = &self.snapshot.resolved.settings;
        let appearance = match settings.appearance {
            soprano_config::AppearancePreference::System => soprano_ui::theme::AppearancePreference::System,
            soprano_config::AppearancePreference::Light => soprano_ui::theme::AppearancePreference::Light,
            soprano_config::AppearancePreference::Dark => soprano_ui::theme::AppearancePreference::Dark,
        };
        let manager = cx.soprano_theme().manager();
        if manager.theme_id() != settings.theme_id || manager.appearance() != appearance {
            SopranoTheme::update_settings(&settings.theme_id.clone(), appearance, cx);
        }
    }

    pub(crate) fn open_settings_file(&mut self, cx: &mut Context<Self>) {
        let error = self.store.open_in_editor().err();
        cx.emit(SettingsEvent::OpenSettingsFile { error });
    }

    pub(crate) fn add_project_directory(&mut self, raw: &str, window: &mut Window, cx: &mut Context<Self>) {
        let outcome = general::add_project_directory(&self.store, raw);
        match outcome {
            AddDirectoryOutcome::NotADirectory => window.play_system_bell(),
            outcome if outcome.clears_input() => {
                self.project_input.update(cx, |state, cx| state.set_value("", window, cx));
            }
            _ => {}
        }
        self.reload(window, cx);
    }

    pub(crate) fn browse_project_directory(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let paths = cx.prompt_for_paths(PathPromptOptions {
            files: false,
            directories: true,
            multiple: false,
            prompt: Some("Add".into()),
        });
        cx.spawn_in(window, async move |this, cx| {
            let Ok(Ok(Some(paths))) = paths.await else { return };
            let Some(path) = paths.into_iter().next() else { return };
            let _ = this.update_in(cx, |this, window, cx| {
                this.add_project_directory(&path.display().to_string(), window, cx);
            });
        })
        .detach();
    }

    pub(crate) fn remove_project_directory(
        &mut self,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        general::remove_project_directory(&self.store, index);
        self.reload(window, cx);
    }

    /// Reads a number field, clamps it into `range` and shows the result; returns the value to
    /// write (text that is not a number reverts to `current` and writes nothing). Like Swift,
    /// the clamped value is always written, so committing fixes an out-of-range value the
    /// file still holds.
    fn commit_number(
        &mut self,
        input: Entity<InputState>,
        range: std::ops::RangeInclusive<i64>,
        current: i64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<i64> {
        let text = input.read(cx).value().to_string();
        let shown = general::committed_integer(&text, &range);
        let value = shown.unwrap_or(current);
        input.update(cx, |state, cx| state.set_value(value.to_string(), window, cx));
        shown
    }

    pub(crate) fn commit_prefix_timeout(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let current = self.snapshot.resolved.keybindings.prefix_timeout_ms;
        let input = self.timeout_input.clone();
        if let Some(value) = self.commit_number(input, Limits::PREFIX_TIMEOUT_MS, current, window, cx) {
            self.write(value, general::PREFIX_TIMEOUT_KEY, window, cx);
        }
    }

    /// `resizeTickPercent` is a float key, so it goes through `write_number`, which refuses
    /// non-finite values with an issue.
    pub(crate) fn commit_resize_step(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let current = self.snapshot.resolved.keybindings.resize_tick_percent as i64;
        let input = self.resize_input.clone();
        if let Some(value) = self.commit_number(input, Limits::RESIZE_TICK_PERCENT, current, window, cx) {
            self.store.write_number(value as f64, general::RESIZE_STEP_KEY);
            self.reload(window, cx);
        }
    }

    // MARK: - Recording

    pub(crate) fn begin_prefix_recording(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.recording = Some(Recording::Prefix);
        self.prefix_focus.focus(window, cx);
        cx.notify();
    }

    pub(crate) fn begin_binding_recording(&mut self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        let prefix_key = self.snapshot.resolved.keybindings.prefix_key.clone();
        self.recording = Some(Recording::Binding {
            id: id.to_owned(),
            recorder: ChordRecorder::new(&prefix_key, self.platform),
        });
        self.binding_focus.focus(window, cx);
        cx.notify();
    }

    fn end_recording(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.recording = None;
        self.focus_handle.focus(window, cx);
        cx.notify();
    }

    pub(crate) fn on_prefix_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let keystroke = &event.keystroke;
        let plain = !keystroke.modifiers.modified();
        if self.recording != Some(Recording::Prefix) {
            // Focused but idle: Space starts a recording.
            if plain && keystroke.key == "space" {
                cx.stop_propagation();
                self.begin_prefix_recording(window, cx);
            }
            return;
        }
        cx.stop_propagation();
        // Esc keeps the current prefix.
        if plain && keystroke.key == "escape" {
            self.end_recording(window, cx);
            return;
        }
        if keystroke.modifiers.platform || keystroke.modifiers.function {
            window.play_system_bell();
            return;
        }
        match general::recorded_prefix_key(&keystroke.key, keystroke.modifiers.shift) {
            Some(key) => {
                self.end_recording(window, cx);
                self.write(key, general::PREFIX_KEY_KEY, window, cx);
            }
            None => window.play_system_bell(),
        }
    }

    pub(crate) fn on_binding_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(Recording::Binding { id, recorder }) = self.recording.as_mut() else { return };
        cx.stop_propagation();
        let keystroke = &event.keystroke;
        if keystroke.key.is_empty() || is_modifier_key(&keystroke.key) {
            return;
        }
        let key = RecordedKey {
            key: keystroke.key.clone(),
            key_char: keystroke.key_char.clone(),
            ctrl: keystroke.modifiers.control,
            alt: keystroke.modifiers.alt,
            shift: keystroke.modifiers.shift,
            platform: keystroke.modifiers.platform,
        };
        let id = id.clone();
        match recorder.key(&key) {
            RecordStep::AwaitingPrefixKey => cx.notify(),
            RecordStep::Refused => window.play_system_bell(),
            RecordStep::Cancel => self.end_recording(window, cx),
            RecordStep::TurnOff => {
                self.end_recording(window, cx);
                self.write(serde_json::Value::Null, &crate::shortcuts::binding_key_path(&id), window, cx);
            }
            RecordStep::Bound(chord) => {
                self.end_recording(window, cx);
                self.write(chord, &crate::shortcuts::binding_key_path(&id), window, cx);
            }
        }
    }

    // MARK: - Accounts

    pub(crate) fn perform_account_action(
        &mut self,
        action: PageAction,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(confirmation) = action.perform(&*self.accounts) {
            self.confirm(confirmation, window, cx);
        }
        self.accounts_snapshot = self.accounts.snapshot();
        cx.notify();
    }

    fn confirm(&mut self, confirmation: Confirmation, window: &mut Window, cx: &mut Context<Self>) {
        let content = DialogContent::confirm(
            confirmation.title.clone(),
            confirmation.message,
            confirmation.confirm_title,
            confirmation.is_destructive,
        );
        let dialog = Dialog::new(content, window, cx);
        let accounts = self.accounts.clone();
        let action = confirmation.action;
        dialog.update(cx, |dialog, _| {
            dialog.on_finish(move |result, _, _| {
                if result.index == Some(1) {
                    action.perform(&*accounts);
                }
            });
        });
        self.subscriptions.push(cx.subscribe_in(&dialog, window, |this, _, _: &DismissEvent, window, cx| {
            this.dialog = None;
            this.focus_handle.focus(window, cx);
            cx.notify();
        }));
        self.dialog = Some(dialog);
        cx.notify();
    }

    pub(crate) fn push_subscription(&mut self, subscription: Subscription) {
        self.subscriptions.push(subscription);
    }

    /// Whether the theme menu is open.
    #[cfg(test)]
    pub(crate) fn is_showing_menu(&self) -> bool {
        self.menu.is_some()
    }

    /// The account-removal confirmation on screen, if any.
    pub fn is_confirming(&self) -> bool {
        self.dialog.is_some()
    }

    // MARK: - Theme menu

    pub(crate) fn open_theme_menu(
        &mut self,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let selected = self.snapshot.resolved.settings.theme_id.clone();
        let view = cx.entity().downgrade();
        let items: Vec<soprano_ui::menu::MenuItem> = soprano_ui::theme::theme_options()
            .into_iter()
            .enumerate()
            .flat_map(|(index, option)| {
                let view = view.clone();
                let id = option.id;
                let item = soprano_ui::menu::MenuItem::new(option.name).checked(id == selected).on_select(
                    move |window, cx| {
                        let _ = view.update(cx, |this, cx| {
                            this.write(id, general::THEME_KEY, window, cx);
                            this.apply_theme_fallback(cx);
                        });
                    },
                );
                // Folio follows the appearance; the separator sets it apart from the
                // palettes that pin their own.
                if index == 0 { vec![item, soprano_ui::menu::MenuItem::separator()] } else { vec![item] }
            })
            .collect();
        let menu = ContextMenu::new(position, items, window, cx);
        menu.update(cx, |menu, _| menu.set_width(224.));
        self.subscriptions.push(cx.subscribe_in(&menu, window, |this, _, _: &DismissEvent, _, cx| {
            this.menu = None;
            cx.notify();
        }));
        self.menu = Some(menu);
        cx.notify();
    }

    // MARK: - Esc

    /// Esc in the focused shortcut filter while it holds a query clears the query first; otherwise it
    /// closes the screen. Recorders and dialogs take their own Esc before it gets here.
    pub(crate) fn escape(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let query_focused = self.shortcut_query.read(cx).focus_handle(cx).is_focused(window);
        if self.tab == SettingsTab::KeyboardShortcuts && query_focused && !self.shortcut_query(cx).is_empty()
        {
            self.set_shortcut_query("", window, cx);
            return;
        }
        cx.emit(SettingsEvent::Close);
    }

    pub(crate) fn close(&mut self, cx: &mut Context<Self>) {
        cx.emit(SettingsEvent::Close);
    }

    // MARK: - Rendering

    fn render_nav(&self, t: &SopranoTheme, cx: &mut Context<Self>) -> AnyElement {
        let item = |id: ElementId, title: &'static str, glyph: IconName, active: bool| {
            div()
                .id(id)
                .flex()
                .flex_row()
                .items_center()
                .gap(t.z(8.))
                .h(t.z(32.))
                .px(t.z(8.))
                .rounded(t.z(8.))
                .cursor_pointer()
                .text_size(t.z(size::UI))
                .text_color(t.foreground)
                .when(active, |d| d.bg(t.selected).font_weight(FontWeight::MEDIUM))
                .when(!active, |d| d.hover(|s| s.bg(t.hover)))
                .child(icon(glyph).size(14.).color(if active { t.foreground } else { t.muted }))
                .child(title)
        };
        let tabs = SettingsTab::ALL.into_iter().map(|tab| {
            item(
                SharedString::from(format!("settings-nav-{}", tab.title())).into(),
                tab.title(),
                tab.icon(),
                tab == self.tab,
            )
            .on_click(cx.listener(move |this, _, window, cx| this.switch_tab(tab, window, cx)))
        });
        div()
            .flex()
            .flex_col()
            .flex_none()
            .w(t.z(NAV_WIDTH))
            .h_full()
            .bg(t.chrome)
            .border_r_1()
            .border_color(t.border)
            .child(
                div()
                    .h(t.z(HEADER_HEIGHT))
                    .flex()
                    .items_center()
                    .px(t.z(20.))
                    .text_size(t.z(size::UI))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(t.foreground)
                    .child("Settings"),
            )
            .child(div().flex().flex_col().gap(t.z(2.)).px(t.z(12.)).children(tabs))
            .child(div().flex_1())
            .child(
                div().px(t.z(12.)).pb(t.z(12.)).child(
                    item("settings-nav-open-file".into(), "Open settings.json", IconName::FileText, false)
                        .on_click(cx.listener(|this, _, _, cx| this.open_settings_file(cx))),
                ),
            )
            .into_any_element()
    }

    fn render_header(&self, t: &SopranoTheme, cx: &mut Context<Self>) -> AnyElement {
        div()
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(t.z(6.))
            .h(t.z(HEADER_HEIGHT))
            .pl(t.z(24.))
            .pr(t.z(12.))
            .border_b_1()
            .border_color(t.border)
            .text_size(t.z(size::UI))
            .child(div().text_color(t.muted).child("Settings"))
            .child(icon(IconName::ChevronRight).size(11.).color(t.muted))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(t.foreground)
                    .child(self.tab.title()),
            )
            .child(
                IconButton::new("settings-close", IconName::X)
                    .size(IconButtonSize::Chrome)
                    .tooltip("Close settings")
                    .on_click(cx.listener(|this, _: &ClickEvent, _, cx| this.close(cx))),
            )
            .into_any_element()
    }

    fn render_page(
        &mut self,
        t: &SopranoTheme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        match self.tab {
            SettingsTab::General => self.general_page(t, window, cx),
            SettingsTab::KeyboardShortcuts => self.shortcuts_page(t, window, cx),
            SettingsTab::AgentProfiles => self.agents_page(t, window, cx),
            SettingsTab::Accounts => self.accounts_page(t, cx),
            SettingsTab::About => self.about_page(t, cx),
        }
    }
}

fn is_modifier_key(key: &str) -> bool {
    matches!(key, "shift" | "control" | "alt" | "platform" | "function" | "capslock")
}

impl Render for SettingsView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let t = cx.soprano_theme().clone();
        let page = self.render_page(&t, window, cx);
        let nav = self.render_nav(&t, cx);
        let header = self.render_header(&t, cx);
        let card = div()
            .id("settings-card")
            .flex()
            .flex_row()
            .size_full()
            .max_w(t.z(CARD_MAX_WIDTH))
            .max_h(t.z(CARD_MAX_HEIGHT))
            .rounded(t.z(8.))
            .border_1()
            .border_color(t.border)
            .bg(t.popover)
            .shadow_lg()
            .overflow_hidden()
            .font_family(fonts::UI_FONT_FAMILY)
            .text_color(t.foreground)
            // Clicks on the card never reach the backdrop.
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .child(nav)
            .child(
                div().flex().flex_col().flex_1().min_w_0().h_full().child(header).child(
                    div()
                        .id("settings-scroll")
                        .flex_1()
                        .min_h_0()
                        .overflow_y_scroll()
                        .track_scroll(&self.scroll)
                        .child(
                            div().flex().justify_center().px(t.z(24.)).py(t.z(32.)).child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap(t.z(32.))
                                    .w_full()
                                    .max_w(t.z(PAGE_MAX_WIDTH))
                                    .min_w(t.z(320.))
                                    .children(page),
                            ),
                        ),
                ),
            );
        div()
            .id("settings-overlay")
            .absolute()
            .inset_0()
            .flex()
            .items_center()
            .justify_center()
            .p(t.z(CARD_MARGIN))
            .bg(t.backdrop)
            .track_focus(&self.focus_handle)
            .key_context("SopranoSettings")
            // A text field's own Escape action would swallow Esc; take it first.
            .capture_action(cx.listener(|this, _: &component_input::Escape, window, cx| {
                cx.stop_propagation();
                this.escape(window, cx);
            }))
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                if event.keystroke.key == "escape" && !event.keystroke.modifiers.modified() {
                    cx.stop_propagation();
                    this.escape(window, cx);
                }
            }))
            // A click that cancels the dialog or closes the theme menu stops there; only a
            // click on the bare backdrop closes Settings.
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, _, _, cx| {
                    if this.dialog.is_none() && this.menu.is_none() {
                        this.close(cx);
                    }
                }),
            )
            // The workspace underneath must not take scroll.
            .on_scroll(|_, _, cx| cx.stop_propagation())
            .child(card)
            .children(self.dialog.clone())
            .children(self.menu.clone())
    }
}
