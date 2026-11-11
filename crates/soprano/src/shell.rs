//! The window's shell state every chrome view reads (sidebar visibility and width, keybinding
//! mode, held Control, the page covering the workspace, the settings in force) and the one
//! funnel for everything the chrome asks the app to do: [`Command`].
//!
//! Views never run app-level work themselves. They read the [`WorkspaceHandle`] (and may run
//! plain model mutations through it), and for anything else they `dispatch` a [`Command`]; the
//! main view carries it out with the window at hand (dialogs, focus, pages, closes that need
//! confirmation).
//!
//! [`WorkspaceHandle`]: crate::workspace::WorkspaceHandle

use std::time::SystemTime;

use gpui::{AnyView, App, Context, DismissEvent, Entity, EventEmitter, ManagedView, Subscription, Window};
use soprano_config::AppSettings;
use soprano_explorer::SidebarWidthStore;
use soprano_platform::StateStore;
use soprano_types::{KeyBindingConfig, KeybindingState, Machine};

/// Persisted visibility of the left sidebar (`MainContentViewController.sidebarVisibleKey`).
pub const SIDEBAR_VISIBLE_KEY: &str = "soprano-sidebar-visible";

/// A full-workspace page right of the sidebar (`showDashboard` / `showAutomations`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Page {
    Dashboard,
    Automations,
    Statistics,
}

/// Something to close; the main view asks about unsaved editors first when the model says so.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CloseTarget {
    Session(String),
    Window(String),
    Pane(String),
    LayoutTab(String),
    ActiveLayoutTab,
    PaneTab {
        pane_id: String,
        tab_id: String,
    },
    /// A terminal's process is gone (and, with wait-after-command, a key was pressed).
    TerminalClosed {
        pane_id: String,
        tab_id: String,
    },
}

/// Everything the chrome asks the app to do beyond a plain model mutation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Command {
    /// Run a keybinding's command exactly as if its chord had been pressed.
    RunBinding(String),
    OpenCommandPalette,
    FindWindow,
    FindSession,
    OpenProjectSearch,
    NewSession,
    /// Choose a machine (`machines` in settings.json) and open a terminal on it.
    MachineTerminal,
    /// Ask for an ssh destination and add it to `machines`, then check it.
    AddMachine,
    /// Open a terminal on this machine beside the active pane.
    NewTerminalOn(String),
    RenameSession,
    /// Close the active session, after confirming.
    CloseSession,
    /// Rename a window (`None`: the active one).
    RenameWindow(Option<String>),
    SaveWorkspaceAs,
    /// Load a saved workspace by id.
    LoadWorkspace(String),
    Close(CloseTarget),
    ToggleSidebar,
    ToggleRightSidebar,
    ToggleExplorer,
    ToggleSourceControl,
    OpenSettings,
    OpenAccountsSettings,
    OpenSettingsFile,
    OpenDashboard,
    ToggleAutomations,
    /// Show the Automations page (on its list).
    OpenAutomations,
    /// A sidebar row was chosen: the Automations or Statistics page gives way to the workspace.
    LeavePage,
    /// Show the statistics board, or return from it to the workspace.
    ToggleStatistics,
    /// Show the Automations page on a run's report.
    OpenAutomationRun(String),
    /// Choose a Markdown file: into a new reader pane (`None`) or as a tab of a pane.
    OpenMarkdown {
        pane_id: Option<String>,
    },
    OpenInSopranoGit,
    StartCopyMode,
    /// A one-button notice over the window.
    ShowNotice {
        title: String,
        message: String,
    },
}

/// The chrome's shared state, an entity the views observe.
pub struct Shell {
    pub state: StateStore,
    pub settings: AppSettings,
    /// The `machines` of `settings.json`.
    pub machines: Vec<Machine>,
    pub keybindings: KeyBindingConfig,
    pub sidebar_visible: bool,
    /// The width the sidebar has (and reopens at).
    pub sidebar_width: f32,
    /// The resize handle is hovered or dragged: the sidebar edge shows it.
    pub sidebar_resize_highlighted: bool,
    pub keybinding_mode: KeybindingState,
    /// Control (Alt+Shift off macOS) is held: pane hints and window numbers show.
    pub control_held: bool,
    /// The pane hint letters typed so far.
    pub typed_pane_hint: String,
    pub page: Option<Page>,
    /// When the app started (the status bar's uptime).
    pub launched_at: SystemTime,
    /// The open context menu or popup (a soprano-ui `ContextMenu`, the usage card, …), drawn
    /// by the main view above everything else.
    pub popup: Option<AnyView>,
    popup_subscription: Option<Subscription>,
}

impl EventEmitter<Command> for Shell {}

impl Shell {
    pub fn new(state: StateStore, settings: AppSettings, keybindings: KeyBindingConfig) -> Self {
        let sidebar_visible = state.get::<bool>(SIDEBAR_VISIBLE_KEY).unwrap_or(true);
        let sidebar_width = SidebarWidthStore::LEFT.load(&state);
        Self {
            state,
            settings,
            machines: Vec::new(),
            keybindings,
            sidebar_visible,
            sidebar_width,
            sidebar_resize_highlighted: false,
            keybinding_mode: KeybindingState::Normal,
            control_held: false,
            typed_pane_hint: String::new(),
            page: None,
            launched_at: SystemTime::now(),
            popup: None,
            popup_subscription: None,
        }
    }

    /// Shows `popup` (anything that dismisses itself, such as soprano-ui's `ContextMenu`) above
    /// the window and gives it the keyboard; it goes away on its `DismissEvent`.
    pub fn show_popup<M: ManagedView>(
        &mut self,
        popup: Entity<M>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let handle = popup.read(cx).focus_handle(cx);
        // The keyboard goes back where it was when the popup closes (the usage card does not
        // restore it itself, unlike `ContextMenu`), as closing Swift's child window did.
        let previous = window.focused(cx);
        self.popup_subscription =
            Some(cx.subscribe_in(&popup, window, move |shell, _, _: &DismissEvent, window, cx| {
                if let Some(previous) = &previous {
                    window.focus(previous, cx);
                }
                shell.popup = None;
                shell.popup_subscription = None;
                cx.notify();
            }));
        self.popup = Some(popup.into());
        window.focus(&handle, cx);
        cx.notify();
    }

    /// The keycaps of the first of `binding_ids` that is bound (Swift `commandShortcut(for:)`).
    pub fn shortcut(&self, binding_ids: &[&str]) -> Vec<String> {
        binding_ids
            .iter()
            .filter_map(|id| self.keybindings.bindings.iter().find(|binding| binding.id == *id))
            .map(|binding| soprano_ui::keycaps::keycaps(binding, &self.keybindings.prefix_key))
            .find(|caps| !caps.is_empty())
            .unwrap_or_default()
    }

    pub fn set_sidebar_visible(&mut self, visible: bool) {
        self.sidebar_visible = visible;
        self.state.set(SIDEBAR_VISIBLE_KEY, &visible);
    }

    /// Applies a dragged width, clamped to the allowed range and to what the window can spare
    /// for panes. False when nothing changed (or the sidebar is hidden).
    pub fn drag_sidebar_width(&mut self, proposed: f32, available_width: Option<f32>) -> bool {
        if !self.sidebar_visible {
            return false;
        }
        let width = SidebarWidthStore::LEFT.clamp(proposed, available_width);
        if width == self.sidebar_width {
            return false;
        }
        self.sidebar_width = width;
        true
    }

    pub fn save_sidebar_width(&self) {
        SidebarWidthStore::LEFT.save(self.sidebar_width, &self.state);
    }

    pub fn reset_sidebar_width(&mut self) {
        self.sidebar_width = SidebarWidthStore::LEFT.default_width;
        self.save_sidebar_width();
    }
}

/// Asks the main view to carry out `command`.
pub fn dispatch(shell: &Entity<Shell>, command: Command, cx: &mut App) {
    shell.update(cx, |_, cx| cx.emit(command));
}

#[cfg(test)]
mod tests {
    use super::*;
    use soprano_config::DefaultKeybindings;

    fn shell() -> Shell {
        Shell::new(StateStore::in_memory(), AppSettings::default_settings(), DefaultKeybindings::config())
    }

    struct Card(gpui::FocusHandle);

    impl EventEmitter<DismissEvent> for Card {}

    impl gpui::Focusable for Card {
        fn focus_handle(&self, _: &App) -> gpui::FocusHandle {
            self.0.clone()
        }
    }

    impl gpui::Render for Card {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl gpui::IntoElement {
            gpui::Empty
        }
    }

    #[gpui::test]
    fn closing_a_popup_gives_the_keyboard_back(cx: &mut gpui::TestAppContext) {
        let cx = cx.add_empty_window();
        let (shell, terminal) = cx.update(|window, cx| {
            let terminal = cx.focus_handle();
            window.focus(&terminal, cx);
            (gpui::AppContext::new(cx, |_| shell()), terminal)
        });
        let card = cx.update(|window, cx| {
            let card = gpui::AppContext::new(cx, |cx| Card(cx.focus_handle()));
            shell.update(cx, |shell, cx| shell.show_popup(card.clone(), window, cx));
            card
        });
        cx.update(|window, cx| assert!(card.read(cx).0.is_focused(window)));
        cx.update(|_, cx| card.update(cx, |_, cx| cx.emit(DismissEvent)));
        cx.run_until_parked();
        cx.update(|window, cx| {
            assert!(terminal.is_focused(window));
            assert!(shell.read(cx).popup.is_none());
        });
    }

    #[test]
    fn the_sidebar_starts_visible_at_its_default_width() {
        let shell = shell();
        assert!(shell.sidebar_visible);
        assert_eq!(shell.sidebar_width, SidebarWidthStore::LEFT.default_width);
    }

    #[test]
    fn a_dragged_width_survives_into_the_next_launch() {
        let state = StateStore::in_memory();
        let mut shell =
            Shell::new(state.clone(), AppSettings::default_settings(), DefaultKeybindings::config());
        assert!(shell.drag_sidebar_width(280.0, Some(1400.0)));
        shell.save_sidebar_width();
        let relaunched = Shell::new(state, AppSettings::default_settings(), DefaultKeybindings::config());
        assert_eq!(relaunched.sidebar_width, 280.0);
    }

    #[test]
    fn dragging_beyond_the_allowed_range_stops_at_the_bound() {
        let mut shell = shell();
        shell.drag_sidebar_width(-500.0, Some(1400.0));
        assert_eq!(shell.sidebar_width, SidebarWidthStore::LEFT.minimum_width);
        shell.drag_sidebar_width(5000.0, Some(1400.0));
        assert_eq!(shell.sidebar_width, SidebarWidthStore::LEFT.maximum_width);
    }

    #[test]
    fn double_clicking_the_handle_restores_the_default_width() {
        let mut shell = shell();
        shell.drag_sidebar_width(400.0, Some(1400.0));
        shell.reset_sidebar_width();
        assert_eq!(shell.sidebar_width, SidebarWidthStore::LEFT.default_width);
        assert_eq!(SidebarWidthStore::LEFT.load(&shell.state), SidebarWidthStore::LEFT.default_width);
    }

    #[test]
    fn dragging_a_hidden_sidebar_does_not_change_its_width() {
        let mut shell = shell();
        shell.set_sidebar_visible(false);
        assert!(!shell.drag_sidebar_width(340.0, Some(1400.0)));
        assert_eq!(shell.sidebar_width, SidebarWidthStore::LEFT.default_width);
    }

    #[test]
    fn the_sidebar_visibility_survives_a_relaunch() {
        let state = StateStore::in_memory();
        let mut shell =
            Shell::new(state.clone(), AppSettings::default_settings(), DefaultKeybindings::config());
        shell.set_sidebar_visible(false);
        assert!(
            !Shell::new(state, AppSettings::default_settings(), DefaultKeybindings::config()).sidebar_visible
        );
    }

    #[test]
    fn both_sidebars_together_still_leave_panes_the_reserved_width() {
        let mut shell = shell();
        let right = SidebarWidthStore::RIGHT.default_width;
        shell.drag_sidebar_width(5000.0, Some(1000.0 - right));
        assert_eq!(shell.sidebar_width, 1000.0 - right - SidebarWidthStore::RESERVED_CONTENT_WIDTH);
    }

    #[test]
    fn command_shortcuts_use_the_first_bound_binding() {
        let shell = shell();
        assert!(!shell.shortcut(&["command-palette"]).is_empty());
        assert!(shell.shortcut(&["no-such-binding"]).is_empty());
        assert_eq!(
            shell.shortcut(&["no-such-binding", "command-palette"]),
            shell.shortcut(&["command-palette"])
        );
    }
}
