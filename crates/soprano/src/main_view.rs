//! The window's root (`MainWindowController` + `MainContentViewController`): lays out the
//! sidebar, the tab rows, the split tree, the right sidebar and the status bar per SHELL-MAP.md,
//! carries out every [`Command`], routes every key through the keybinding resolver before any
//! content sees it, answers the CLI, and hosts the overlays (palette, dialogs, Settings, toasts,
//! popups).

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::time::{Duration, Instant};

use gpui::{
    AnyElement, App, AppContext, Context, Entity, FocusHandle, Focusable, InteractiveElement, IntoElement,
    KeystrokeEvent, MouseButton, MouseMoveEvent, MouseUpEvent, ParentElement, PathPromptOptions, Pixels,
    Render, SharedString, StatefulInteractiveElement, Styled, Subscription, Task, WeakEntity, Window, canvas,
    div, prelude::FluentBuilder, px,
};
use soprano_config::ConfigSnapshot;
use soprano_dashboard::{AgentDashboard, DashboardEvent, DashboardHost};
use soprano_explorer::{RightSidebar, SidebarEvent};
use soprano_ipc::transport::{Incoming, IpcServer};
use soprano_ipc::{PassthroughMode, Request, Response};
use soprano_keys::{
    BindingCommand, FocusedContent, KeyContext, KeyOutcome, KeybindingResolver, PaneHintAssignment,
    PaneNavigationClaimRegistry, Platform, ResolverChange,
};
use soprano_model::{CloseOutcome, CloseRequest, SplitDirection, TerminalTarget, WorkspaceChange};
use soprano_notify::{Authorization, BannerClick, NotificationManager, TerminalNotification};
use soprano_settings::{
    NotificationAuthorization, NotificationStatusProvider, SettingsEvent, SettingsTab, SettingsView,
};
use soprano_term::{
    ClipboardConfirmationCoordinator, ClipboardConfirmationDecision, ClipboardConfirmationPresentation,
    ClipboardConfirmationPresenter, ClipboardConfirmationPrompt, TerminalView,
};
use soprano_types::AgentCatalog;
use soprano_ui::{
    ActiveSopranoTheme, Dialog, DialogButton, DialogContent, DialogResult, Picker, PickerEvent, SopranoTheme,
    Toast, ToastLevel, ToastStack,
};

use crate::automations::{self, AutomationContext};
use crate::content::{ContentEvent, ContentHost, PaneContent, terminal_theme};
use crate::palette::{self, PaletteAction, PaletteEntry};
use crate::services::Services;
use crate::shell::{CloseTarget, Command, Page, Shell, dispatch};
use crate::views::sidebar::Sidebar;
use crate::views::split_tree::SplitTree;
use crate::views::status_bar::StatusBar;
use crate::views::tab_rows::{LayoutTabRow, WindowTabRow};
use crate::workspace::{WorkspaceHandle, WorkspaceUpdate};
use crate::{menus, sizing, window_chrome};
use soprano_automations::AutomationController;
use soprano_automations_ui::{AutomationsPage, AutomationsPageEvent};
use soprano_text::DocumentId;
use soprano_text::editor_store::{
    CloseResolution, OVERWRITE_MESSAGE, SaveChoice, SaveOutcome, overwrite_question, save_question,
};

/// What runs once the unsaved-changes question is answered with Save or Don't Save.
type Proceed = Box<dyn FnOnce(&mut MainView, &mut Window, &mut Context<MainView>)>;

/// The sidebar's resize strip straddling its trailing edge.
const SIDEBAR_HANDLE_WIDTH: f32 = 8.0;
/// How often the notification manager's upkeep runs.
const NOTIFICATION_TICK: Duration = Duration::from_secs(1);

/// What answers Settings' notification permission row.
struct NotificationStatus(Rc<RefCell<NotificationManager>>);

impl NotificationStatusProvider for NotificationStatus {
    fn authorization(&self) -> Option<NotificationAuthorization> {
        self.0.borrow().authorization().map(|status| match status {
            Authorization::Authorized => NotificationAuthorization::Authorized,
            Authorization::Denied => NotificationAuthorization::Denied,
            Authorization::NotDetermined => NotificationAuthorization::NotDetermined,
            Authorization::Unavailable => NotificationAuthorization::Unavailable,
        })
    }
}

/// Clipboard prompts go onto a channel the main view turns into dialogs.
struct ClipboardPrompts(async_channel::Sender<ClipboardPromptRequest>);

/// A prompt to show, its answer, and whether the terminal withdrew it meanwhile.
type ClipboardPromptRequest =
    (ClipboardConfirmationPrompt, Box<dyn FnOnce(ClipboardConfirmationDecision)>, Rc<RefCell<bool>>);

/// What runs when a queued dialog is answered.
type DialogCompletion = Box<dyn FnOnce(DialogResult, &mut Window, &mut App)>;

struct ClipboardPromptHandle(Rc<RefCell<bool>>);

impl ClipboardConfirmationPresentation for ClipboardPromptHandle {
    fn dismiss(&self) {
        *self.0.borrow_mut() = true;
    }
}

impl ClipboardConfirmationPresenter for ClipboardPrompts {
    fn present(
        &self,
        prompt: &ClipboardConfirmationPrompt,
        completion: Box<dyn FnOnce(ClipboardConfirmationDecision)>,
    ) -> Box<dyn ClipboardConfirmationPresentation> {
        let dismissed = Rc::new(RefCell::new(false));
        // The receiver lives as long as the main view; a closed channel means the window is
        // gone, where denying is right.
        if let Err(error) = self.0.try_send((prompt.clone(), completion, dismissed.clone())) {
            let (_, completion, _) = error.into_inner();
            completion(ClipboardConfirmationDecision::Dismissed);
        }
        Box::new(ClipboardPromptHandle(dismissed))
    }
}

/// Things the app starts once and the view keeps alive.
pub struct Startup {
    pub ipc: Option<(IpcServer, async_channel::Receiver<Incoming>)>,
    pub banner_clicks: async_channel::Receiver<BannerClick>,
    pub config_changes: async_channel::Receiver<ConfigSnapshot>,
}

pub struct MainView {
    workspace: WorkspaceHandle,
    shell: Entity<Shell>,
    services: Services,
    content: Entity<ContentHost>,
    split_tree: Entity<SplitTree>,
    sidebar: Entity<Sidebar>,
    window_tabs: Entity<WindowTabRow>,
    layout_tabs: Entity<LayoutTabRow>,
    status_bar: Entity<StatusBar>,
    right_sidebar: Entity<RightSidebar>,
    toasts: Entity<ToastStack>,
    picker: Option<Entity<Picker>>,
    palette_actions: HashMap<SharedString, PaletteAction>,
    dialog: Option<Entity<Dialog>>,
    queued_dialogs: Vec<(DialogContent, DialogCompletion)>,
    settings: Option<Entity<SettingsView>>,
    dashboard: Option<Entity<AgentDashboard>>,
    automations: AutomationContext,
    automations_page: Option<Entity<AutomationsPage>>,
    /// The focused tab's folder the right sidebar last followed.
    explorer_directory: Option<Option<String>>,
    notifications: Rc<RefCell<NotificationManager>>,
    resolver: KeybindingResolver,
    claims: PaneNavigationClaimRegistry,
    resolver_timer: Option<Task<()>>,
    clipboard: Rc<ClipboardConfirmationCoordinator>,
    clipboard_answers: async_channel::Sender<(WeakEntity<TerminalView>, u64, bool)>,
    /// The terminal font size at zoom 1 (settings and Ghostty config); zoom scales it.
    terminal_font_size: f32,
    focus: FocusHandle,
    /// The sidebar edge is being dragged: the pointer's start and the width it started at.
    sidebar_drag: Option<(Pixels, f32)>,
    _ipc_server: Option<IpcServer>,
    _subscriptions: Vec<Subscription>,
    _tasks: Vec<Task<()>>,
}

impl Focusable for MainView {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl MainView {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        workspace: WorkspaceHandle,
        shell: Entity<Shell>,
        services: Services,
        content: Entity<ContentHost>,
        notifications: Rc<RefCell<NotificationManager>>,
        startup: Startup,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let split_tree = cx.new(|cx| SplitTree::new(workspace.clone(), content.clone(), shell.clone(), cx));
        let sidebar =
            cx.new(|cx| Sidebar::new(workspace.clone(), shell.clone(), services.clone(), window, cx));
        let right_sidebar = cx.new(|cx| RightSidebar::new(services.state.clone(), window, cx));
        let window_tabs = cx
            .new(|cx| WindowTabRow::new(workspace.clone(), shell.clone(), right_sidebar.clone(), window, cx));
        let layout_tabs = cx
            .new(|cx| LayoutTabRow::new(workspace.clone(), shell.clone(), right_sidebar.clone(), window, cx));
        let status_bar =
            cx.new(|cx| StatusBar::new(workspace.clone(), shell.clone(), services.clone(), window, cx));
        let toasts = ToastStack::new(cx);

        let (prompt_sender, prompt_receiver) = async_channel::unbounded();
        let clipboard = ClipboardConfirmationCoordinator::new(ClipboardPrompts(prompt_sender));
        let (clipboard_answers, answer_receiver) =
            async_channel::unbounded::<(WeakEntity<TerminalView>, u64, bool)>();
        let terminal_font_size = content.read(cx).terminal_settings().font_size;
        let keybindings = shell.read(cx).keybindings.clone();
        let resolver = KeybindingResolver::new(keybindings, Platform::current());
        content.update(cx, |content, cx| content.set_clipboard_coordinator(clipboard.clone(), cx));

        let (wake_sender, wake_receiver) = async_channel::unbounded::<()>();
        let controller = automations::create_controller(
            &soprano_platform::AppIdentity::current(),
            services.config.clone(),
            &workspace,
            &content,
            &notifications,
            move || {
                let _ = wake_sender.try_send(());
            },
            cx,
        );
        let automations = AutomationContext {
            controller,
            workspace: workspace.clone(),
            content: content.clone(),
            notifications: notifications.clone(),
        };

        let this_for_keys = cx.entity().downgrade();
        let mut subscriptions = vec![
            cx.subscribe_in(&shell, window, |this, _, command: &Command, window, cx| {
                this.run(command.clone(), window, cx)
            }),
            cx.subscribe_in(&workspace.bus, window, |this, _, update: &WorkspaceUpdate, window, cx| {
                this.workspace_changed(update, window, cx)
            }),
            cx.subscribe_in(&content, window, |this, _, event: &ContentEvent, window, cx| {
                this.content_event(event, window, cx)
            }),
            cx.subscribe_in(&right_sidebar, window, |this, _, event: &SidebarEvent, window, cx| {
                this.sidebar_event(event, window, cx)
            }),
            cx.observe(&shell, |_, _, cx| cx.notify()),
            cx.observe(&right_sidebar, |_, _, cx| cx.notify()),
            cx.observe_window_activation(window, |this, window, cx| {
                this.window_activation_changed(window, cx)
            }),
            cx.observe_window_bounds(window, |this, window, cx| {
                this.save_window_frame(window, cx);
                this.update_right_sidebar_width(window, cx);
            }),
            cx.observe_global_in::<SopranoTheme>(window, |this, _, cx| this.theme_changed(cx)),
            cx.intercept_keystrokes(move |event, window, cx| {
                if let Some(this) = this_for_keys.upgrade() {
                    this.update(cx, |this, cx| this.intercept_key(event, window, cx));
                }
            }),
            SopranoTheme::observe_system_appearance(window),
        ];
        subscriptions.push(cx.on_release(|this, _| this.notifications.borrow_mut().app_did_resign_active()));

        let mut tasks = Vec::new();
        let (ipc_server, ipc_receiver) = match startup.ipc {
            Some((server, receiver)) => (Some(server), Some(receiver)),
            None => (None, None),
        };
        if let Some(receiver) = ipc_receiver {
            tasks.push(cx.spawn_in(window, async move |this, cx| {
                while let Ok(incoming) = receiver.recv().await {
                    if this
                        .update_in(cx, |this, window, cx| this.handle_request(incoming, window, cx))
                        .is_err()
                    {
                        break;
                    }
                }
            }));
        }
        tasks.push(cx.spawn_in(window, async move |this, cx| {
            while let Ok((prompt, completion, dismissed)) = prompt_receiver.recv().await {
                if this
                    .update_in(cx, |this, window, cx| {
                        this.present_clipboard_prompt(prompt, completion, dismissed, window, cx)
                    })
                    .is_err()
                {
                    break;
                }
            }
        }));
        tasks.push(cx.spawn(async move |_, cx| {
            while let Ok((terminal, id, allowed)) = answer_receiver.recv().await {
                cx.update(|cx| {
                    terminal
                        .update(cx, |terminal, cx| terminal.resolve_clipboard_request(id, allowed, cx))
                        .ok();
                });
            }
        }));
        let clicks = startup.banner_clicks;
        tasks.push(cx.spawn_in(window, async move |this, cx| {
            while let Ok(click) = clicks.recv().await {
                if this.update_in(cx, |this, window, cx| this.banner_clicked(click, window, cx)).is_err() {
                    break;
                }
            }
        }));
        let config_changes = startup.config_changes;
        tasks.push(cx.spawn_in(window, async move |this, cx| {
            while let Ok(snapshot) = config_changes.recv().await {
                if this.update_in(cx, |this, window, cx| this.config_changed(snapshot, window, cx)).is_err() {
                    break;
                }
            }
        }));
        tasks.push(cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(NOTIFICATION_TICK).await;
                let alive = this.update(cx, |this, cx| {
                    let notifications = this.notifications.clone();
                    this.workspace.update(cx, |ws| notifications.borrow_mut().tick(Instant::now(), ws));
                });
                if alive.is_err() {
                    break;
                }
            }
        }));
        // Automations: due runs every half minute and right after the machine wakes
        // (`didWakeNotification`), background results whenever the worker wakes us, and runs
        // waiting for a display.
        tasks.push(cx.spawn_in(window, async move |this, cx| {
            let mut detector = crate::power::WakeDetector::new();
            loop {
                cx.background_executor().timer(crate::power::WAKE_SAMPLE_INTERVAL).await;
                if !detector.observe(std::time::SystemTime::now()) {
                    continue;
                }
                if this.update_in(cx, |this, window, cx| this.tick_automations(window, cx)).is_err() {
                    break;
                }
            }
        }));
        tasks.push(cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor().timer(AutomationController::CHECK_INTERVAL).await;
                if this.update_in(cx, |this, window, cx| this.tick_automations(window, cx)).is_err() {
                    break;
                }
            }
        }));
        tasks.push(cx.spawn_in(window, async move |this, cx| {
            while wake_receiver.recv().await.is_ok() {
                let drained = this.update_in(cx, |this, window, cx| {
                    automations::drive(&this.automations, window, cx, |controller, host| {
                        controller.drain(host)
                    });
                });
                if drained.is_err() {
                    break;
                }
            }
        }));
        tasks.push(cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor().timer(AutomationController::DISPLAY_RETRY_INTERVAL).await;
                let retried = this.update_in(cx, |this, window, cx| {
                    if this.automations.controller.read(cx).is_waiting_for_display() {
                        automations::drive(&this.automations, window, cx, |controller, host| {
                            controller.retry_waiting_terminals(host)
                        });
                    }
                });
                if retried.is_err() {
                    break;
                }
            }
        }));
        cx.defer_in(window, |this, window, cx| this.tick_automations(window, cx));

        let mut view = Self {
            workspace,
            shell,
            services,
            content,
            split_tree,
            sidebar,
            window_tabs,
            layout_tabs,
            status_bar,
            right_sidebar,
            toasts,
            picker: None,
            palette_actions: HashMap::new(),
            dialog: None,
            queued_dialogs: Vec::new(),
            settings: None,
            dashboard: None,
            automations,
            automations_page: None,
            explorer_directory: None,
            notifications,
            resolver,
            claims: PaneNavigationClaimRegistry::new(),
            resolver_timer: None,
            clipboard,
            clipboard_answers,
            terminal_font_size,
            focus: cx.focus_handle(),
            sidebar_drag: None,
            _ipc_server: ipc_server,
            _subscriptions: subscriptions,
            _tasks: tasks,
        };
        view.sync_right_sidebar(window, cx);
        view.theme_changed(cx);
        window_chrome::apply_window_bar(window, view.shell.read(cx).settings.hide_window_bar);
        view.sync_keyboard_focus(window, cx);
        view
    }

    // MARK: - Commands

    pub fn run(&mut self, command: Command, window: &mut Window, cx: &mut Context<Self>) {
        match command {
            Command::RunBinding(id) => self.run_binding(&id, window, cx),
            Command::OpenCommandPalette => self.open_command_palette(window, cx),
            Command::FindWindow => {
                let items = palette::window_items(&self.workspace, &self.shell, cx);
                self.show_picker(items, Some("Search windows and panes..."), Vec::new(), window, cx);
            }
            Command::FindSession => {
                let items = palette::session_items(&self.workspace, cx);
                self.show_picker(items, Some("Search sessions..."), Vec::new(), window, cx);
            }
            Command::OpenProjectSearch => self.open_project_search(window, cx),
            Command::NewSession => {
                self.prompt_for_session_name("New Session", String::new(), None, window, cx)
            }
            Command::RenameSession => {
                let Some(session) = self.workspace.read(cx).active_session().cloned() else { return };
                self.prompt_for_session_name(
                    "Rename Session",
                    session.name.clone(),
                    Some(session.id),
                    window,
                    cx,
                );
            }
            Command::CloseSession => self.confirm_close_session(window, cx),
            Command::RenameWindow(id) => self.prompt_to_rename_window(id, window, cx),
            Command::SaveWorkspaceAs => self.save_workspace_as(window, cx),
            Command::LoadWorkspace(id) => {
                // The saved list lives in the state store; read it there so the workspace can be
                // borrowed for the restore.
                let sessions = soprano_model::SessionManager::new(self.services.state.clone());
                let outcome = self.workspace.update(cx, |ws| sessions.load_session(&id, ws));
                self.resolve_close(outcome, window, cx);
            }
            Command::Close(target) => self.close(target, window, cx),
            Command::ToggleSidebar => {
                self.shell.update(cx, |shell, cx| {
                    let visible = !shell.sidebar_visible;
                    shell.set_sidebar_visible(visible);
                    cx.notify();
                });
                self.sync_right_sidebar(window, cx);
            }
            Command::ToggleRightSidebar => {
                self.right_sidebar.update(cx, |sidebar, cx| sidebar.toggle_open(window, cx));
                self.after_right_sidebar_toggle(window, cx);
            }
            Command::ToggleExplorer => {
                self.right_sidebar.update(cx, |sidebar, cx| sidebar.toggle_explorer(window, cx));
                self.after_right_sidebar_toggle(window, cx);
            }
            Command::ToggleSourceControl => {
                self.right_sidebar.update(cx, |sidebar, cx| sidebar.toggle_source_control(window, cx));
                self.after_right_sidebar_toggle(window, cx);
            }
            Command::OpenSettings => self.show_settings(None, window, cx),
            Command::OpenAccountsSettings => self.show_settings(Some(SettingsTab::Accounts), window, cx),
            Command::OpenSettingsFile => {
                if let Err(message) = self.services.config.open_in_editor() {
                    self.toast(ToastLevel::Error, message, cx);
                }
            }
            Command::OpenDashboard => self.show_page(Page::Dashboard, window, cx),
            Command::ToggleAutomations => {
                if self.shell.read(cx).page == Some(Page::Automations) {
                    self.close_page(true, window, cx);
                } else {
                    self.show_page(Page::Automations, window, cx);
                }
            }
            Command::OpenAutomations => self.show_page(Page::Automations, window, cx),
            Command::CloseAutomations => {
                if self.shell.read(cx).page == Some(Page::Automations) {
                    self.close_page(true, window, cx);
                }
            }
            Command::OpenAutomationRun(run_id) => self.open_automation_run(&run_id, window, cx),
            Command::OpenMarkdown { pane_id } => self.choose_markdown_file(pane_id, window, cx),
            Command::OpenInSopranoGit => {
                let cwd = self.workspace.read(cx).active_working_directory();
                let shell = self.shell.downgrade();
                let (sender, receiver) = async_channel::bounded::<String>(1);
                soprano_git::launcher::open(cwd.as_deref(), move |message| {
                    let _ = sender.try_send(message);
                });
                cx.spawn(async move |_, cx| {
                    if let Ok(message) = receiver.recv().await {
                        cx.update(|cx| {
                            if let Some(shell) = shell.upgrade() {
                                dispatch(
                                    &shell,
                                    Command::ShowNotice { title: "Open in Soprano Git".into(), message },
                                    cx,
                                );
                            }
                        });
                    }
                })
                .detach();
            }
            Command::ZoomIn => SopranoTheme::zoom_in(cx),
            Command::ZoomOut => SopranoTheme::zoom_out(cx),
            Command::ZoomReset => SopranoTheme::reset_zoom(cx),
            Command::StartCopyMode => {
                if let Some(terminal) = self.content.read(cx).active_terminal(cx) {
                    terminal.update(cx, |terminal, cx| {
                        terminal.enter_copy_mode(cx);
                    });
                }
            }
            Command::ShowNotice { title, message } => {
                self.present_dialog(DialogContent::alert(title, message), |_, _, _| {}, window, cx)
            }
        }
    }

    /// `KeybindingManager.executeBinding`.
    fn run_binding(&mut self, binding_id: &str, window: &mut Window, cx: &mut Context<Self>) {
        let Some(command) = BindingCommand::from_binding_id(binding_id, AgentCatalog::shared()) else {
            return;
        };
        let tick = self.shell.read(cx).keybindings.resize_tick_percent;
        let ws = self.workspace.clone();
        match command {
            BindingCommand::SelectWindow(number) => {
                ws.update(cx, |ws| ws.activate_window_number(number.max(0) as usize))
            }
            BindingCommand::LaunchAgent(id) => {
                ws.update(cx, |ws| ws.spawn_agent(&id, None, false));
            }
            BindingCommand::Split(direction) => {
                let direction = match direction {
                    soprano_keys::SplitDirection::Horizontal => SplitDirection::Horizontal,
                    soprano_keys::SplitDirection::Vertical => SplitDirection::Vertical,
                };
                ws.update(cx, |ws| {
                    let pane = ws.active_pane_id().to_owned();
                    ws.split_pane(direction, &pane)
                });
            }
            BindingCommand::NewChat => {
                if let Some(profile) = soprano_launch::ChatLaunch::chat_profiles().first() {
                    ws.update(cx, |ws| ws.spawn_agent(&profile.id, None, true));
                }
            }
            BindingCommand::Navigate(direction) => {
                ws.update(cx, |ws| ws.navigate_to_pane(model_direction(direction)))
            }
            BindingCommand::PreviousWindow => ws.update(cx, |ws| ws.activate_previous_window()),
            BindingCommand::NextWindow => ws.update(cx, |ws| ws.activate_next_window()),
            BindingCommand::LastWindow => ws.update(cx, |ws| ws.activate_last_window()),
            BindingCommand::Resize(direction) => {
                ws.update(cx, |ws| ws.resize_pane(model_direction(direction), tick))
            }
            BindingCommand::ClosePane => {
                let pane = ws.read(cx).active_pane_id().to_owned();
                self.close(CloseTarget::Pane(pane), window, cx);
            }
            BindingCommand::CloseActivePaneTab => self.close_active_pane_tab(window, cx),
            BindingCommand::ToggleMaximize => ws.update(cx, |ws| ws.toggle_maximize()),
            BindingCommand::StartCopyMode => self.run(Command::StartCopyMode, window, cx),
            BindingCommand::NewWindow => {
                ws.update(cx, |ws| ws.create_window(None, None));
            }
            BindingCommand::NewSession => self.run(Command::NewSession, window, cx),
            BindingCommand::FindSession => self.run(Command::FindSession, window, cx),
            BindingCommand::NewTab => {
                ws.update(cx, |ws| ws.create_layout_tab(None, None));
            }
            BindingCommand::CloseTab => self.close(CloseTarget::ActiveLayoutTab, window, cx),
            BindingCommand::NextTab => ws.update(cx, |ws| ws.activate_next_layout_tab()),
            BindingCommand::PreviousTab => ws.update(cx, |ws| ws.activate_previous_layout_tab()),
            BindingCommand::NewPaneTab => {
                ws.update(cx, |ws| {
                    let pane = ws.active_pane_id().to_owned();
                    ws.add_tab_to_pane(&pane, soprano_model::PaneType::Terminal, None, None)
                });
            }
            BindingCommand::NextPaneTab => ws.update(cx, |ws| {
                let pane = ws.active_pane_id().to_owned();
                ws.next_tab(&pane)
            }),
            BindingCommand::PreviousPaneTab => ws.update(cx, |ws| {
                let pane = ws.active_pane_id().to_owned();
                ws.prev_tab(&pane)
            }),
            BindingCommand::CommandPalette => self.run(Command::OpenCommandPalette, window, cx),
            BindingCommand::FindWindow => self.run(Command::FindWindow, window, cx),
            BindingCommand::OpenProject => self.run(Command::OpenProjectSearch, window, cx),
            BindingCommand::OpenInSopranoGit => self.run(Command::OpenInSopranoGit, window, cx),
            BindingCommand::RenameWindow => self.run(Command::RenameWindow(None), window, cx),
            BindingCommand::CloseWindow => {
                let id = ws.read(cx).active_window_id().to_owned();
                self.close(CloseTarget::Window(id), window, cx);
            }
            BindingCommand::NewTerminal => {
                ws.update(cx, |ws| ws.spawn_terminal(None));
            }
            BindingCommand::NewBrowser => {
                ws.update(cx, |ws| ws.spawn_browser(None));
            }
            BindingCommand::SaveSession => self.run(Command::SaveWorkspaceAs, window, cx),
            BindingCommand::ToggleSidebar => self.run(Command::ToggleSidebar, window, cx),
            BindingCommand::ToggleRightSidebar => self.run(Command::ToggleRightSidebar, window, cx),
            BindingCommand::ToggleExplorer => self.run(Command::ToggleExplorer, window, cx),
            BindingCommand::ToggleSourceControl => self.run(Command::ToggleSourceControl, window, cx),
            BindingCommand::OpenSettings => self.run(Command::OpenSettings, window, cx),
            BindingCommand::OpenAgentDashboard => self.run(Command::OpenDashboard, window, cx),
            BindingCommand::Zoom(delta) => {
                self.run(if delta > 0 { Command::ZoomIn } else { Command::ZoomOut }, window, cx)
            }
            BindingCommand::ZoomReset => self.run(Command::ZoomReset, window, cx),
        }
    }

    /// Closes the active pane's active tab; its last tab takes the pane with it.
    fn close_active_pane_tab(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let ws = self.workspace.read(cx);
        let pane_id = ws.active_pane_id().to_owned();
        match ws.pane(&pane_id).and_then(|pane| pane.active_tab()).map(|tab| tab.id.clone()) {
            Some(tab_id) => self.close(CloseTarget::PaneTab { pane_id, tab_id }, window, cx),
            None => self.close(CloseTarget::Pane(pane_id), window, cx),
        }
    }

    // MARK: - Closing

    fn close(&mut self, target: CloseTarget, window: &mut Window, cx: &mut Context<Self>) {
        let outcome = self.workspace.update(cx, |ws| match &target {
            CloseTarget::Session(id) => ws.close_session(id),
            CloseTarget::Window(id) => ws.close_window(id),
            CloseTarget::Pane(id) => ws.close_pane(id),
            CloseTarget::LayoutTab(id) => ws.close_layout_tab(id),
            CloseTarget::ActiveLayoutTab => ws.close_active_layout_tab(),
            CloseTarget::PaneTab { pane_id, tab_id } => ws.remove_tab_from_pane(pane_id, tab_id),
            CloseTarget::TerminalClosed { pane_id, tab_id } => {
                ws.handle_terminal_close(&TerminalTarget::new(pane_id, tab_id))
            }
        });
        self.resolve_close(outcome, window, cx);
    }

    /// A close the model held back because something showing in the closing tabs is unsaved:
    /// ask, then close (or not).
    fn resolve_close(&mut self, outcome: CloseOutcome, window: &mut Window, cx: &mut Context<Self>) {
        let CloseOutcome::NeedsConfirmation { targets, request } = outcome else { return };
        self.confirm_closing(targets, request, window, cx);
    }

    /// Closes `request` once the unsaved documents only its tabs show are saved or dropped
    /// (Save / Don't Save / Cancel); Cancel keeps everything open.
    fn confirm_closing(
        &mut self,
        targets: Vec<TerminalTarget>,
        request: CloseRequest,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let documents = self.documents(cx).read(cx).store().unsaved_when_closing(&targets);
        self.ask_to_save(
            documents,
            Box::new(move |this, _, cx| {
                let outcome = this.workspace.update(cx, |ws| ws.force_close(request));
                if let CloseOutcome::NeedsConfirmation { .. } = outcome {
                    tracing::warn!("a confirmed close asked for confirmation again");
                }
            }),
            window,
            cx,
        );
    }

    /// Quit (⌘Q, the menu, closing the main window): asks about every unsaved document first.
    pub fn request_quit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let documents = self.documents(cx).read(cx).store().unsaved_when_closing_all();
        self.ask_to_save(documents, Box::new(|_, _, cx| cx.quit()), window, cx);
    }

    /// Whether quitting has to ask about unsaved documents first.
    pub fn has_unsaved_documents(&self, cx: &App) -> bool {
        !self.documents(cx).read(cx).store().unsaved_when_closing_all().is_empty()
    }

    /// The save question for `documents` (`soprano_text::save_question`); `proceed` runs once
    /// they are saved or discarded. Without documents it runs at once.
    fn ask_to_save(
        &mut self,
        documents: Vec<DocumentId>,
        proceed: Proceed,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if documents.is_empty() {
            proceed(self, window, cx);
            return;
        }
        let names = self.documents(cx).read(cx).store().names(&documents);
        let (title, message, save_title) = save_question(&names);
        let this = cx.entity().downgrade();
        self.present_dialog(
            DialogContent::save_changes(title, message, save_title),
            move |result, window, cx| {
                let choice = match result.index {
                    Some(0) => SaveChoice::Discard,
                    Some(2) => SaveChoice::Save,
                    _ => SaveChoice::Cancel,
                };
                this.update(cx, |this, cx| this.resolve_saves(documents, choice, proceed, window, cx)).ok();
            },
            window,
            cx,
        );
    }

    /// Applies the answer; a save that needs an overwrite confirmation asks for it and goes
    /// on with the rest, a failed save reports the error and keeps everything open.
    fn resolve_saves(
        &mut self,
        documents: Vec<DocumentId>,
        choice: SaveChoice,
        proceed: Proceed,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let store = self.documents(cx);
        match store.update(cx, |store, cx| store.resolve_unsaved(&documents, choice, cx)) {
            CloseResolution::Proceed => proceed(self, window, cx),
            CloseResolution::Cancel => {}
            CloseResolution::SaveBlocked { document, outcome: SaveOutcome::NeedsOverwriteConfirmation } => {
                let name = store.read(cx).store().names(&[document]).pop().unwrap_or_default();
                let this = cx.entity().downgrade();
                self.present_dialog(
                    DialogContent::confirm(
                        overwrite_question(&name),
                        OVERWRITE_MESSAGE,
                        "Save Anyway",
                        false,
                    ),
                    move |result, window, cx| {
                        if result.index != Some(1) {
                            return;
                        }
                        this.update(cx, |this, cx| {
                            let store = this.documents(cx);
                            match store.update(cx, |store, cx| store.save_anyway(document, cx)) {
                                SaveOutcome::Saved => {
                                    let rest: Vec<DocumentId> = documents
                                        .into_iter()
                                        .filter(|id| {
                                            store.read(cx).document(*id).is_some_and(|d| d.is_dirty())
                                        })
                                        .collect();
                                    this.resolve_saves(rest, SaveChoice::Save, proceed, window, cx);
                                }
                                SaveOutcome::Failed(error) => this.report_save_failure(&error, window, cx),
                                SaveOutcome::NeedsOverwriteConfirmation => {}
                            }
                        })
                        .ok();
                    },
                    window,
                    cx,
                );
            }
            CloseResolution::SaveBlocked { outcome: SaveOutcome::Failed(error), .. } => {
                self.report_save_failure(&error, window, cx)
            }
            CloseResolution::SaveBlocked { outcome: SaveOutcome::Saved, .. } => proceed(self, window, cx),
        }
    }

    /// A save error in an alert, its description as the title (as the editor reports it).
    fn report_save_failure(&mut self, error: &std::io::Error, window: &mut Window, cx: &mut Context<Self>) {
        self.present_dialog(DialogContent::alert(error.to_string(), ""), |_, _, _| {}, window, cx);
    }

    // MARK: - Prompts

    fn present_dialog(
        &mut self,
        content: DialogContent,
        completion: impl FnOnce(DialogResult, &mut Window, &mut App) + 'static,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.dialog.is_some() {
            self.queued_dialogs.push((content, Box::new(completion)));
            return;
        }
        let dialog = Dialog::new(content, window, cx);
        let this = cx.entity().downgrade();
        dialog.update(cx, |dialog, _| {
            dialog.on_finish(move |result, window, cx| {
                completion(result, window, cx);
                if let Some(this) = this.upgrade() {
                    this.update(cx, |this, cx| this.dialog_finished(window, cx));
                }
            })
        });
        self.dialog = Some(dialog);
        cx.notify();
    }

    fn dialog_finished(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.dialog = None;
        if !self.queued_dialogs.is_empty() {
            let (content, completion) = self.queued_dialogs.remove(0);
            self.present_dialog(content, completion, window, cx);
        } else {
            self.sync_keyboard_focus(window, cx);
        }
        cx.notify();
    }

    fn prompt_for_session_name(
        &mut self,
        title: &str,
        initial: String,
        session_id: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let confirm = if initial.is_empty() { "Create" } else { "Rename" };
        let content = DialogContent::prompt(
            title.to_owned(),
            "Name this group of windows.",
            "Session name",
            initial,
            confirm,
        );
        let workspace = self.workspace.clone();
        self.present_dialog(
            content,
            move |result, _, cx| {
                let Some(name) = result.prompt_value() else { return };
                workspace.update(cx, |ws| match &session_id {
                    Some(id) => ws.rename_session(id, &name),
                    None => {
                        ws.create_session(&name, None);
                    }
                });
            },
            window,
            cx,
        );
    }

    fn confirm_close_session(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(session) = self.workspace.read(cx).active_session().cloned() else { return };
        let content = DialogContent::confirm(
            format!("Close \"{}\"?", session.name),
            "All windows and running terminals in this session will close.",
            "Close Session",
            true,
        );
        let shell = self.shell.clone();
        self.present_dialog(
            content,
            move |result, _, cx| {
                if result.index == Some(1) {
                    dispatch(&shell, Command::Close(CloseTarget::Session(session.id.clone())), cx);
                }
            },
            window,
            cx,
        );
    }

    fn prompt_to_rename_window(
        &mut self,
        window_id: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let ws = self.workspace.read(cx);
        let id = window_id.unwrap_or_else(|| ws.active_window_id().to_owned());
        let Some(terminal_window) = ws.window(&id) else { return };
        let content = DialogContent::prompt(
            "Rename Window",
            "Choose a stable name for this window.",
            "",
            terminal_window.title.clone(),
            "Rename",
        );
        let workspace = self.workspace.clone();
        self.present_dialog(
            content,
            move |result, _, cx| {
                if let Some(name) = result.prompt_value() {
                    workspace.update(cx, |ws| ws.rename_window(&id, &name));
                }
            },
            window,
            cx,
        );
    }

    fn save_workspace_as(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let content = DialogContent::prompt(
            "Save Workspace",
            "Save a snapshot of all sessions and their window layouts:",
            "Workspace name",
            "",
            "Save",
        );
        let workspace = self.workspace.clone();
        let sessions = self.services.sessions.clone();
        self.present_dialog(
            content,
            move |result, _, cx| {
                let Some(name) = result.prompt_value() else { return };
                let snapshot_source = workspace.model.clone();
                sessions.update(cx, |sessions, cx| {
                    sessions.save_session(&name, snapshot_source.read(cx));
                    cx.notify();
                });
            },
            window,
            cx,
        );
    }

    // MARK: - Pickers

    fn show_picker(
        &mut self,
        entries: Vec<PaletteEntry>,
        placeholder: Option<&str>,
        search_keycaps: Vec<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.palette_actions =
            entries.iter().map(|entry| (entry.item.id.clone(), entry.action.clone())).collect();
        let items = entries.into_iter().map(|entry| entry.item).collect();
        let picker = Picker::new(items, window, cx);
        picker.update(cx, |picker, cx| {
            if let Some(placeholder) = placeholder {
                picker.set_placeholder(placeholder.to_owned(), window, cx);
            }
            picker.set_search_keycaps(search_keycaps);
        });
        let subscription =
            cx.subscribe_in(&picker, window, |this, picker, event: &PickerEvent, window, cx| {
                if this.picker.as_ref() != Some(picker) {
                    return;
                }
                this.picker = None;
                let action = match event {
                    PickerEvent::Confirmed { id, query } => {
                        this.palette_actions.get(id).cloned().map(|a| (a, query.clone()))
                    }
                    PickerEvent::Dismissed => None,
                };
                this.palette_actions.clear();
                cx.notify();
                match action {
                    // The palette closes first; the action runs on the next turn so a picker or
                    // dialog it opens takes the keyboard.
                    Some((action, query)) => cx.defer_in(window, move |this, window, cx| {
                        action(&query, window, cx);
                        if this.picker.is_none() && this.dialog.is_none() {
                            this.sync_keyboard_focus(window, cx);
                        }
                    }),
                    None => this.sync_keyboard_focus(window, cx),
                }
            });
        self._subscriptions.push(subscription);
        self.picker = Some(picker);
        cx.notify();
    }

    fn open_command_palette(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let installed = soprano_git::launcher::installed_application().is_some();
        let display_path = self.services.config.display_path();
        let entries = palette::command_items(&self.workspace, &self.shell, installed, &display_path, cx);
        let caps = self.shell.read(cx).shortcut(&["command-palette"]);
        self.show_picker(entries, None, caps, window, cx);
    }

    fn open_project_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let roots = self.shell.read(cx).settings.project_directories.clone();
        let workspace = self.workspace.clone();
        let choose: PaletteAction = Rc::new(move |_, _, cx| {
            let workspace = workspace.clone();
            let paths = cx.prompt_for_paths(PathPromptOptions {
                files: false,
                directories: true,
                multiple: false,
                prompt: Some("Open".into()),
            });
            cx.spawn(async move |cx| {
                if let Ok(Ok(Some(paths))) = paths.await
                    && let Some(path) = paths.first()
                {
                    let path = path.to_string_lossy().into_owned();
                    cx.update(|cx| workspace.update(cx, |ws| ws.spawn_terminal(Some(&path))));
                }
            })
            .detach();
        });
        let entries = palette::project_items(&self.workspace, &roots, choose);
        self.show_picker(entries, Some("Search projects..."), Vec::new(), window, cx);
    }

    /// `MarkdownFilePicker`: a Markdown file into a new reader pane, or as a tab of `pane_id`.
    fn choose_markdown_file(&mut self, pane_id: Option<String>, window: &mut Window, cx: &mut Context<Self>) {
        let paths = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some("Open".into()),
        });
        let workspace = self.workspace.clone();
        let shell = self.shell.downgrade();
        let _ = window;
        cx.spawn(async move |_, cx| {
            let Ok(Ok(Some(paths))) = paths.await else { return };
            let Some(path) = paths.first().map(|p| soprano_model::file_url::standardized_path(p)) else {
                return;
            };
            cx.update(|cx| {
                if !is_markdown(&path) {
                    if let Some(shell) = shell.upgrade() {
                        dispatch(
                            &shell,
                            Command::ShowNotice {
                                title: "Open Markdown…".into(),
                                message: "Choose a Markdown file to open in a live reader.".into(),
                            },
                            cx,
                        );
                    }
                    return;
                }
                workspace.update(cx, |ws| match &pane_id {
                    Some(pane) => {
                        ws.open_markdown(&path, pane);
                    }
                    None => {
                        ws.spawn_markdown(&path, None);
                    }
                })
            });
        })
        .detach();
    }

    // MARK: - Pages and Settings

    fn show_settings(&mut self, tab: Option<SettingsTab>, window: &mut Window, cx: &mut Context<Self>) {
        if self.shell.read(cx).page.is_some() {
            self.close_page(false, window, cx);
        }
        self.notifications.borrow().refresh_authorization();
        let view = match &self.settings {
            Some(view) => {
                view.update(cx, |view, cx| view.reload(window, cx));
                view.clone()
            }
            None => {
                let store = self.services.config.clone();
                let accounts: Rc<dyn soprano_accounts::AccountsSource> =
                    Rc::new(self.services.accounts.clone());
                let status: Rc<dyn NotificationStatusProvider> =
                    Rc::new(NotificationStatus(self.notifications.clone()));
                let view = cx.new(|cx| SettingsView::new(store, accounts, status, window, cx));
                let subscription = cx.subscribe_in(
                    &view,
                    window,
                    |this, _, event: &SettingsEvent, window, cx| match event {
                        SettingsEvent::Close => this.close_settings(window, cx),
                        SettingsEvent::OpenSettingsFile { error } => {
                            if let Some(error) = error {
                                this.toast(ToastLevel::Error, error.clone(), cx);
                            }
                        }
                    },
                );
                self._subscriptions.push(subscription);
                self.settings = Some(view.clone());
                view
            }
        };
        if let Some(tab) = tab {
            view.update(cx, |view, cx| view.switch_tab(tab, window, cx));
        }
        let handle = view.focus_handle(cx);
        window.focus(&handle, cx);
        cx.notify();
    }

    fn close_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.settings.take().is_some() {
            cx.notify();
            self.sync_keyboard_focus(window, cx);
        }
    }

    fn show_page(&mut self, page: Page, window: &mut Window, cx: &mut Context<Self>) {
        if self.settings.is_some() {
            self.close_settings(window, cx);
        }
        if page != Page::Dashboard {
            self.dashboard = None;
        }
        if page != Page::Automations {
            self.automations_page = None;
        }
        if page == Page::Automations && self.automations_page.is_none() {
            let controller = self.automations.controller.clone();
            let model = self.workspace.model.clone();
            let automations = cx.new(|cx| AutomationsPage::new(controller, model, window, cx));
            let subscription = cx.subscribe_in(
                &automations,
                window,
                |this, page, event: &AutomationsPageEvent, window, cx| {
                    this.automations_event(page.clone(), event, window, cx)
                },
            );
            self._subscriptions.push(subscription);
            let handle = automations.focus_handle(cx);
            window.focus(&handle, cx);
            self.automations_page = Some(automations);
        }
        if page == Page::Dashboard && self.dashboard.is_none() {
            let content = self.content.clone();
            let branches = self.services.branches.clone();
            let host = DashboardHost::new()
                .terminal_text(move |target, cx| content.read(cx).dashboard_text(target, cx))
                .notable_branch(move |cwd, _| branches.notable_branch(cwd));
            let model = self.workspace.model.clone();
            let dashboard = cx.new(|cx| AgentDashboard::new(model, host, window, cx));
            let subscription =
                cx.subscribe_in(&dashboard, window, |this, dashboard, event: &DashboardEvent, window, cx| {
                    this.dashboard_event(dashboard.clone(), event, window, cx)
                });
            self._subscriptions.push(subscription);
            let handle = dashboard.focus_handle(cx);
            self.dashboard = Some(dashboard);
            window.focus(&handle, cx);
        }
        self.shell.update(cx, |shell, cx| {
            shell.page = Some(page);
            cx.notify();
        });
    }

    fn close_page(&mut self, restore_focus: bool, window: &mut Window, cx: &mut Context<Self>) {
        self.dashboard = None;
        self.automations_page = None;
        self.shell.update(cx, |shell, cx| {
            shell.page = None;
            cx.notify();
        });
        if restore_focus {
            self.sync_keyboard_focus(window, cx);
        }
    }

    /// `AgentDashboardViewController`'s callbacks.
    fn dashboard_event(
        &mut self,
        dashboard: Entity<AgentDashboard>,
        event: &DashboardEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match event {
            DashboardEvent::Open(target) => {
                self.close_page(false, window, cx);
                self.workspace.update(cx, |ws| ws.focus_tab(&target.pane_id, &target.tab_id, true));
                self.sync_keyboard_focus(window, cx);
            }
            DashboardEvent::Stop(target) => self.workspace.update(cx, |ws| ws.stop_agent(target)),
            DashboardEvent::Restart(target) => self.workspace.update(cx, |ws| ws.restart_agent(target)),
            DashboardEvent::Reply { target, text } => {
                let sent =
                    self.content.update(cx, |content, cx| content.reply_to_agent(text, target, window, cx));
                if !sent {
                    dashboard.update(cx, |dashboard, cx| dashboard.reply_failed(target, text, window, cx));
                }
            }
            DashboardEvent::Close => self.close_page(true, window, cx),
        }
    }

    /// The Automations page's requests (`AutomationsViewController`'s callbacks).
    fn automations_event(
        &mut self,
        page: Entity<AutomationsPage>,
        event: &AutomationsPageEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match event {
            AutomationsPageEvent::Dismiss => self.close_page(true, window, cx),
            AutomationsPageEvent::RunNow { automation_id } => {
                automations::drive(&self.automations, window, cx, |controller, host| {
                    controller.run_now(host, automation_id)
                });
            }
            AutomationsPageEvent::OpenRun { run_id } => {
                let opened = automations::drive(&self.automations, window, cx, |controller, host| {
                    controller.open_run(host, run_id)
                });
                if opened {
                    self.close_page(true, window, cx);
                }
            }
            AutomationsPageEvent::Delete { automation_id } => {
                let deleted = automations::drive(&self.automations, window, cx, |controller, host| {
                    controller.delete(host, automation_id)
                });
                if !deleted {
                    page.update(cx, |page, cx| page.show_write_failure(window, cx));
                }
            }
        }
    }

    /// A banner of an automation run: the Automations page on that run.
    fn open_automation_run(&mut self, run_id: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.show_page(Page::Automations, window, cx);
        if let Some(page) = self.automations_page.clone() {
            page.update(cx, |page, cx| page.show_run(run_id, window, cx));
        }
    }

    // MARK: - Right sidebar

    fn sidebar_event(&mut self, event: &SidebarEvent, window: &mut Window, cx: &mut Context<Self>) {
        match event {
            SidebarEvent::OpenFile { path, preview, focus } => {
                // A file with unsaved changes never opens as a preview the next file replaces.
                let preview = *preview && !self.documents(cx).read(cx).store().has_unsaved_changes(path);
                let path = path.clone();
                let opened = self.workspace.update(cx, |ws| ws.open_editor(&path, preview, None));
                self.file_opened(opened.is_some(), *focus, window, cx);
            }
            SidebarEvent::OpenDiff { path, staged, preview, focus } => {
                let (path, staged, preview) = (path.clone(), *staged, *preview);
                let opened = self.workspace.update(cx, |ws| ws.open_diff(&path, staged, preview, None));
                self.file_opened(opened.is_some(), *focus, window, cx);
            }
            SidebarEvent::OpenMarkdownPreview { path } => {
                let path = path.clone();
                self.workspace.update(cx, |ws| crate::content::preview_markdown_in_file_pane(ws, &path));
            }
            SidebarEvent::OpenInTerminal { directory } => {
                let directory = directory.to_string_lossy().into_owned();
                self.workspace.update(cx, |ws| ws.spawn_terminal(Some(&directory)));
            }
            SidebarEvent::FocusPane => self.return_keyboard_focus_to_panes(window, cx),
            SidebarEvent::ItemMoved { from, to } => {
                let (from, to) = (from.clone(), to.clone());
                self.documents(cx).update(cx, |documents, cx| documents.relocate(&from, &to, cx));
                self.workspace.update(cx, |ws| ws.relocate_file_tabs(&from, &to));
            }
            SidebarEvent::ShowError(message) => self.toast(ToastLevel::Error, message.clone(), cx),
        }
    }

    fn documents(&self, cx: &App) -> Entity<soprano_editor::EditorDocuments<TerminalTarget>> {
        self.content.read(cx).documents().clone()
    }

    /// After the explorer opened a file or diff: the keyboard follows it into the panes when
    /// asked (`onReturnFocus`); no room for the tab says so.
    fn file_opened(&mut self, opened: bool, focus: bool, window: &mut Window, cx: &mut Context<Self>) {
        if !opened {
            self.toast(ToastLevel::Error, soprano_explorer::NO_ROOM_MESSAGE, cx);
        } else if focus {
            self.return_keyboard_focus_to_panes(window, cx);
        }
    }

    /// The explorer follows the focused tab's folder (`effectiveWorkingDirectory`, none for
    /// file and browser tabs, which keep the roots); finding roots walks the disk, so only a
    /// changed folder is passed on.
    fn sync_right_sidebar(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.update_right_sidebar_width(window, cx);
        let cwd = {
            let ws = self.workspace.read(cx);
            ws.pane(ws.active_pane_id())
                .and_then(|pane| pane.active_tab())
                .and_then(|tab| tab.effective_working_directory())
        };
        if self.explorer_directory.as_ref() == Some(&cwd) {
            return;
        }
        self.explorer_directory = Some(cwd.clone());
        self.right_sidebar.update(cx, |sidebar, cx| sidebar.set_working_directory(cwd.as_deref(), cx));
    }

    /// The explorer's width leaves the panes their share of the window.
    fn update_right_sidebar_width(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let shell = self.shell.read(cx);
        let left = if shell.sidebar_visible { shell.sidebar_width } else { 0.0 };
        let zoom = cx.soprano_theme().zoom();
        let available = f32::from(window.viewport_size().width) / zoom - left;
        self.right_sidebar.update(cx, |sidebar, _| sidebar.set_available_width(Some(available)));
    }

    fn after_right_sidebar_toggle(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let sidebar = self.right_sidebar.read(cx);
        if !sidebar.is_open() || !sidebar.contains_focus(window, cx) {
            self.sync_keyboard_focus(window, cx);
        }
    }

    // MARK: - Workspace and content

    fn workspace_changed(&mut self, update: &WorkspaceUpdate, window: &mut Window, cx: &mut Context<Self>) {
        // Passthrough claims of closed tabs go; a restored workspace drops them all.
        let (valid, generation) = {
            let ws = self.workspace.read(cx);
            let valid: HashSet<soprano_keys::TerminalTarget> = ws
                .panes()
                .values()
                .flat_map(|pane| {
                    pane.tabs.iter().map(|tab| soprano_keys::TerminalTarget::new(&pane.id, &tab.id))
                })
                .collect();
            (valid, ws.workspace_restore_generation())
        };
        self.claims.synchronize(&valid, generation as i64);
        let changes = update.changes.clone();
        let notifications = self.notifications.clone();
        if changes.iter().any(|c| matches!(c, WorkspaceChange::Model | WorkspaceChange::Layout)) {
            self.workspace.update(cx, |ws| notifications.borrow_mut().workspace_did_change(ws, &changes));
        }
        if self.services.sessions.update(cx, |sessions, _| sessions.take_changed()) {
            cx.notify();
        }
        automations::drive(&self.automations, window, cx, |controller, host| {
            controller.workspace_changed(host)
        });
        self.sync_right_sidebar(window, cx);
        if self.picker.is_none() && self.dialog.is_none() && self.settings.is_none() {
            self.sync_keyboard_focus(window, cx);
        }
        cx.notify();
    }

    fn content_event(&mut self, event: &ContentEvent, window: &mut Window, cx: &mut Context<Self>) {
        match event {
            ContentEvent::CopyModeChanged(state) => {
                self.resolver.copy_mode_changed(*state);
                self.apply_resolver_changes(window, cx);
            }
            ContentEvent::ClipboardConfirmation { terminal, request } => {
                let answers = self.clipboard_answers.clone();
                let weak = terminal.downgrade();
                let id = request.id;
                // The coordinator answers without a context; the answer reaches the terminal
                // through the view's answer task.
                let resolve = move |allowed: bool| {
                    let _ = answers.try_send((weak, id, allowed));
                };
                self.clipboard.enqueue(
                    terminal.entity_id().as_u64(),
                    request.kind,
                    request.content.clone(),
                    resolve,
                );
            }
            ContentEvent::DesktopNotification { target, title, body } => {
                let notification =
                    TerminalNotification { target: target.clone(), title: title.clone(), body: body.clone() };
                let notifications = self.notifications.clone();
                self.workspace.update(cx, |ws| {
                    notifications.borrow_mut().handle_terminal_notification(ws, notification)
                });
            }
            ContentEvent::TerminalDestroyed(id) => self.clipboard.cancel_requests(*id),
            ContentEvent::ShowError(message) => self.toast(ToastLevel::Error, message.clone(), cx),
            ContentEvent::AgentEvent(event) => {
                let notifications = self.notifications.clone();
                let event = event.clone();
                self.workspace.update(cx, |ws| notifications.borrow_mut().handle_agent_event(ws, event));
            }
            ContentEvent::SurfaceFocused(target) => {
                let notifications = self.notifications.clone();
                let target = target.clone();
                self.workspace.update(cx, |ws| notifications.borrow_mut().surface_did_focus(ws, target));
            }
        }
    }

    fn present_clipboard_prompt(
        &mut self,
        prompt: ClipboardConfirmationPrompt,
        completion: Box<dyn FnOnce(ClipboardConfirmationDecision)>,
        dismissed: Rc<RefCell<bool>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if *dismissed.borrow() {
            completion(ClipboardConfirmationDecision::Dismissed);
            return;
        }
        let message = format!("{}\n\n{}", prompt.message(), prompt.content);
        let content = DialogContent::new(
            prompt.title(),
            message,
            vec![
                DialogButton::new(prompt.deny_button_title()),
                DialogButton::new(prompt.allow_button_title()).primary(),
            ],
        );
        self.present_dialog(
            content,
            move |result, _, _| {
                completion(match result.index {
                    Some(1) => ClipboardConfirmationDecision::Allow,
                    Some(_) => ClipboardConfirmationDecision::Deny,
                    None => ClipboardConfirmationDecision::Dismissed,
                })
            },
            window,
            cx,
        );
    }

    fn banner_clicked(&mut self, click: BannerClick, window: &mut Window, cx: &mut Context<Self>) {
        cx.activate(true);
        match click {
            BannerClick::Tab(target) => {
                self.workspace.update(cx, |ws| ws.focus_tab(&target.pane_id, &target.tab_id, false));
                self.close_page(false, window, cx);
                self.sync_keyboard_focus(window, cx);
            }
            BannerClick::AutomationRun(run_id) => self.run(Command::OpenAutomationRun(run_id), window, cx),
        }
    }

    // MARK: - Settings, theme, window

    fn config_changed(&mut self, snapshot: ConfigSnapshot, window: &mut Window, cx: &mut Context<Self>) {
        let settings = snapshot.resolved.settings.clone();
        let keybindings = snapshot.resolved.keybindings.clone();
        SopranoTheme::update_settings(&settings.theme_id, theme_appearance(settings.appearance), cx);
        window_chrome::apply_window_bar(window, settings.hide_window_bar);
        self.resolver.apply_config(keybindings.clone());
        menus::install(&keybindings, cx);
        self.workspace.update(cx, |ws| ws.reload_agent_profiles());
        self.shell.update(cx, |shell, cx| {
            shell.settings = settings;
            shell.keybindings = keybindings;
            cx.notify();
        });
        if let Some(view) = &self.settings {
            view.update(cx, |view, cx| view.reload(window, cx));
        }
        self.apply_resolver_changes(window, cx);
        // settings.json may have added, changed or removed automations.
        self.tick_automations(window, cx);
    }

    /// `AutomationController.tick` now.
    fn tick_automations(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let now = chrono::Utc::now();
        automations::drive(&self.automations, window, cx, |controller, host| controller.tick(host, now));
    }

    fn theme_changed(&mut self, cx: &mut Context<Self>) {
        let theme = cx.soprano_theme();
        let zoom = theme.zoom();
        let palette = terminal_theme(theme.theme());
        let font_size = self.terminal_font_size * zoom;
        self.content.update(cx, |content, cx| {
            let mut settings = content.terminal_settings().clone();
            settings.theme = palette;
            settings.font_size = font_size;
            content.set_terminal_settings(settings, cx);
        });
        cx.notify();
    }

    fn window_activation_changed(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let notifications = self.notifications.clone();
        if window.is_window_active() {
            self.workspace.update(cx, |ws| notifications.borrow_mut().app_did_become_active(ws));
        } else {
            notifications.borrow_mut().app_did_resign_active();
            self.resolver.app_resigned_active();
            self.apply_resolver_changes(window, cx);
        }
    }

    pub fn save_window_frame(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if window.is_fullscreen() {
            return;
        }
        let frame = window_chrome::current_frame(window);
        sizing::save_frame(&self.services.state, frame);
        let _ = cx;
    }

    /// Writes the window frame and, with `restoreLastSession`, the workspace (quit and close).
    pub fn save_last_workspace_if_needed(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.save_window_frame(window, cx);
        if !self.shell.read(cx).settings.restore_last_session {
            return;
        }
        let snapshot = self.workspace.read(cx).snapshot_workspace();
        soprano_model::WorkspaceSession::save_last(&snapshot, &self.services.state);
    }

    // MARK: - Keyboard

    /// What has the keyboard, for chords a content view keeps (`keybindingFocusedContent`).
    fn focused_content(&self, window: &Window, cx: &App) -> FocusedContent {
        let content = self.content.read(cx);
        for (_, item) in content.contents() {
            let Some(handle) = item.focus_handle(cx) else { continue };
            if handle.contains_focused(window, cx) {
                return match item {
                    PaneContent::Terminal(_) => FocusedContent::Terminal,
                    PaneContent::Browser(_) => FocusedContent::Browser,
                    _ => FocusedContent::Other,
                };
            }
        }
        FocusedContent::Other
    }

    fn keys_captured(&self, cx: &App) -> bool {
        self.picker.is_some()
            || self.dialog.is_some()
            || self
                .settings
                .as_ref()
                .is_some_and(|view| view.read(cx).captures_keys() || view.read(cx).is_confirming())
    }

    fn intercept_key(&mut self, event: &KeystrokeEvent, window: &mut Window, cx: &mut Context<Self>) {
        if self.dialog.is_some() && !soprano_ui::dialog::dialog_passes_chord_to_app(&event.keystroke) {
            // The dialog takes every key except the app's own editing chords.
            return;
        }
        let key = crate::keyboard::key_event(&event.keystroke);
        let active_target = {
            let ws = self.workspace.read(cx);
            let pane = ws.active_pane_id();
            ws.pane(pane)
                .and_then(|p| p.active_tab())
                .map(|tab| soprano_keys::TerminalTarget::new(pane, &tab.id))
        };
        let hints: Vec<PaneHintAssignment> = self
            .workspace
            .read(cx)
            .pane_shortcut_assignments()
            .into_iter()
            .map(|shortcut| PaneHintAssignment::new(shortcut.key, shortcut.pane_id))
            .collect();
        let context = KeyContext {
            focused_content: self.focused_content(window, cx),
            keys_captured: self.keys_captured(cx),
            active_target,
            claims: &self.claims,
            pane_hints: &hints,
            now: Instant::now(),
        };
        let outcome = self.resolver.handle(&key, &context);
        match outcome {
            KeyOutcome::PassThrough | KeyOutcome::LiteralPrefix => {}
            KeyOutcome::Consumed | KeyOutcome::EnterPrefix | KeyOutcome::PaneHintPending(_) => {
                cx.stop_propagation()
            }
            KeyOutcome::Action(id) | KeyOutcome::MenuAction(id) => {
                cx.stop_propagation();
                self.run_binding(&id, window, cx);
            }
            KeyOutcome::FocusPaneHint(pane_id) => {
                cx.stop_propagation();
                self.workspace.update(cx, |ws| ws.focus_pane(&pane_id));
                self.close_page(false, window, cx);
                self.sync_keyboard_focus(window, cx);
            }
        }
        self.apply_resolver_changes(window, cx);
    }

    pub fn modifiers_changed(
        &mut self,
        modifiers: &gpui::Modifiers,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.resolver.modifiers_changed(crate::keyboard::modifiers(modifiers));
        self.apply_resolver_changes(window, cx);
    }

    /// Shows what the resolver changed and re-arms its timer.
    fn apply_resolver_changes(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let changes = self.resolver.drain_changes();
        if !changes.is_empty() {
            let mode = self.resolver.display_state();
            self.shell.update(cx, |shell, cx| {
                for change in changes {
                    match change {
                        ResolverChange::State(_) => shell.keybinding_mode = mode,
                        ResolverChange::ControlKeyHeld(held) => shell.control_held = held,
                        ResolverChange::TypedPaneHint(typed) => shell.typed_pane_hint = typed,
                    }
                }
                cx.notify();
            });
        }
        self.resolver_timer = self.resolver.next_deadline().map(|deadline| {
            let delay = crate::keyboard::delay_until(deadline, Instant::now());
            cx.spawn_in(window, async move |this, cx| {
                cx.background_executor().timer(delay).await;
                this.update_in(cx, |this, window, cx| {
                    if this.resolver.tick(Instant::now()) {
                        this.apply_resolver_changes(window, cx);
                    }
                })
                .ok();
            })
        });
    }

    // MARK: - Focus

    /// Keeps the keyboard on the active pane's content (`syncKeyboardFocus`): unless a page,
    /// overlay or another live view (the right sidebar, Settings) has it.
    pub fn sync_keyboard_focus(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.shell.read(cx).page.is_some()
            || self.picker.is_some()
            || self.dialog.is_some()
            || self.settings.is_some()
        {
            return;
        }
        let content = self.content.read(cx);
        let focused_elsewhere = window.focused(cx).is_some()
            && !content.owns_focus(window, cx)
            && !self.focus.is_focused(window)
            && !self.shell.read(cx).popup.is_some();
        if focused_elsewhere && self.right_sidebar.read(cx).contains_focus(window, cx) {
            return;
        }
        let pane_id = self.workspace.read(cx).active_pane_id().to_owned();
        let Some(handle) = content.active_content(&pane_id, cx).and_then(|c| c.focus_handle(cx)) else {
            if window.focused(cx).is_none() {
                window.focus(&self.focus, cx);
            }
            return;
        };
        if !handle.contains_focused(window, cx) {
            match content.active_content(&pane_id, cx) {
                Some(PaneContent::Browser(browser)) => {
                    let browser = browser.clone();
                    browser.update(cx, |browser, cx| browser.focus_preferred_control(window, cx));
                }
                _ => window.focus(&handle, cx),
            }
        }
    }

    fn return_keyboard_focus_to_panes(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        window.focus(&self.focus, cx);
        self.sync_keyboard_focus(window, cx);
    }

    // MARK: - IPC

    fn handle_request(&mut self, incoming: Incoming, window: &mut Window, cx: &mut Context<Self>) {
        let Incoming { request, reply } = incoming;
        let respond = move |response: Response| {
            if let Some(reply) = reply
                && let Err(error) = reply.send(&response)
            {
                tracing::warn!("cannot answer the CLI: {error}");
            }
        };
        match request {
            Request::AgentEvent(event) => {
                let notifications = self.notifications.clone();
                self.workspace.update(cx, |ws| notifications.borrow_mut().handle_agent_event(ws, event));
                respond_none(respond);
            }
            Request::NavigatePane { pane_id, tab_id, direction } => {
                self.workspace.update(cx, |ws| crate::ipc::navigate_pane(ws, &pane_id, &tab_id, direction));
                respond_none(respond);
            }
            Request::NavigationPassthrough { pane_id, tab_id, mode, source } => {
                let target = soprano_keys::TerminalTarget::new(pane_id, tab_id);
                match mode {
                    PassthroughMode::Enable => self.claims.enable(&source, &target),
                    PassthroughMode::Disable => self.claims.disable(&source, &target),
                }
                respond_none(respond);
            }
            Request::OpenMarkdown { path, opens_new_pane, caller_pane_id, caller_tab_id } => {
                let response = self.workspace.update(cx, |ws| {
                    crate::ipc::open_markdown(
                        ws,
                        &path,
                        opens_new_pane,
                        caller_pane_id.as_deref(),
                        caller_tab_id.as_deref(),
                    )
                });
                respond(response);
            }
            Request::Browser { command, arguments, target_pane_id, .. } => {
                if soprano_browser::is_open_command(&command) {
                    let response = self.workspace.update(cx, |ws| crate::ipc::open_browser(ws, &arguments));
                    respond(response);
                    return;
                }
                let target =
                    match crate::ipc::browser_target(self.workspace.read(cx), target_pane_id.as_deref()) {
                        Ok(target) => target,
                        Err(message) => return respond(Response::failure(message)),
                    };
                self.workspace.update(cx, |ws| ws.focus_tab(&target.pane_id, &target.tab_id, false));
                // The tab's view exists once the layout has synced (next turn).
                cx.defer_in(window, move |_, window, cx| {
                    let Some(view) = soprano_browser::BrowserRegistry::view(&target, cx) else {
                        return respond(Response::failure(soprano_browser::unavailable_message(&target)));
                    };
                    let task =
                        view.update(cx, |view, cx| view.perform_automation(&command, &arguments, window, cx));
                    cx.spawn(async move |_, _| {
                        respond(match task.await {
                            Ok(output) => Response::success(output),
                            Err(error) => Response::failure(error),
                        })
                    })
                    .detach();
                });
            }
        }
    }

    // MARK: - Toasts

    fn toast(&mut self, level: ToastLevel, title: impl Into<SharedString>, cx: &mut Context<Self>) {
        let toast = Toast::new(level, title);
        self.toasts.update(cx, |toasts, cx| {
            toasts.push(toast, cx);
        });
    }

    // MARK: - Rendering

    fn render_sidebar(&mut self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let theme = cx.soprano_theme();
        let shell = self.shell.read(cx);
        let width = theme.z(shell.sidebar_width);
        let highlighted = shell.sidebar_resize_highlighted || self.sidebar_drag.is_some();
        let border = theme.border;
        let handle_color = if highlighted { theme.input } else { gpui::transparent_black() };
        let handle_width = theme.z(SIDEBAR_HANDLE_WIDTH);
        let dragging = self.sidebar_drag.is_some();
        let entity = cx.entity().downgrade();
        let _ = window;
        div()
            .relative()
            .flex_none()
            .h_full()
            .w(width)
            .flex()
            .child(div().flex_1().min_w_0().h_full().bg(theme.chrome).child(self.sidebar.clone()))
            .child(div().w(px(1.)).h_full().flex_none().bg(border))
            .child(
                div()
                    .id("sidebar-resize-handle")
                    .absolute()
                    .top_0()
                    .bottom_0()
                    .right(-handle_width / 2.)
                    .w(handle_width)
                    .cursor_col_resize()
                    .child(
                        div()
                            .absolute()
                            .top_0()
                            .bottom_0()
                            .left(handle_width / 2.)
                            .w(px(1.))
                            .bg(handle_color),
                    )
                    .tooltip(soprano_ui::tooltip("Drag to resize the sidebar, double-click to reset"))
                    .on_hover(cx.listener(|this, hovered: &bool, _, cx| {
                        if this.sidebar_drag.is_none() {
                            let hovered = *hovered;
                            this.shell.update(cx, |shell, cx| {
                                shell.sidebar_resize_highlighted = hovered;
                                cx.notify();
                            });
                        }
                    }))
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(|this, event: &gpui::MouseDownEvent, _, cx| {
                            cx.stop_propagation();
                            if event.click_count >= 2 {
                                this.shell.update(cx, |shell, cx| {
                                    shell.reset_sidebar_width();
                                    cx.notify();
                                });
                                return;
                            }
                            let width = this.shell.read(cx).sidebar_width;
                            this.sidebar_drag = Some((event.position.x, width));
                            cx.notify();
                        }),
                    ),
            )
            .when(dragging, |sidebar| {
                sidebar.child(
                    canvas(
                        |_, _, _| {},
                        move |_, _, window, _| {
                            let moved = entity.clone();
                            window.on_mouse_event(move |event: &MouseMoveEvent, phase, window, cx| {
                                if phase.bubble() {
                                    moved
                                        .update(cx, |this, cx| {
                                            this.drag_sidebar_to(event.position.x, window, cx)
                                        })
                                        .ok();
                                }
                            });
                            let released = entity.clone();
                            window.on_mouse_event(move |_: &MouseUpEvent, phase, _, cx| {
                                if phase.bubble() {
                                    released.update(cx, |this, cx| this.end_sidebar_drag(cx)).ok();
                                }
                            });
                        },
                    )
                    .absolute()
                    .size_0(),
                )
            })
            .into_any_element()
    }

    fn drag_sidebar_to(&mut self, x: Pixels, window: &mut Window, cx: &mut Context<Self>) {
        let Some((start_x, start_width)) = self.sidebar_drag else { return };
        let zoom = cx.soprano_theme().zoom();
        let proposed = start_width + f32::from(x - start_x) / zoom;
        let right = {
            let sidebar = self.right_sidebar.read(cx);
            if sidebar.is_open() { sidebar.width() } else { 0.0 }
        };
        let available = f32::from(window.viewport_size().width) / zoom - right;
        let changed = self.shell.update(cx, |shell, cx| {
            let changed = shell.drag_sidebar_width(proposed, Some(available));
            if changed {
                cx.notify();
            }
            changed
        });
        if changed {
            self.sync_right_sidebar(window, cx);
        }
    }

    fn end_sidebar_drag(&mut self, cx: &mut Context<Self>) {
        if self.sidebar_drag.take().is_some() {
            self.shell.update(cx, |shell, cx| {
                shell.save_sidebar_width();
                shell.sidebar_resize_highlighted = false;
                cx.notify();
            });
        }
    }

    fn render_work(&mut self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let theme = cx.soprano_theme();
        let shell = self.shell.read(cx);
        let gap = theme.z(8.0);
        let page = shell.page;
        let show_window_tabs = !shell.settings.hide_window_tabs;
        let _ = window;
        let body: AnyElement = match page {
            Some(page) => self.render_page(page, cx),
            None => div()
                .flex()
                .flex_col()
                .flex_1()
                .min_h_0()
                .when(show_window_tabs, |work| work.child(self.window_tabs.clone()))
                .child(self.layout_tabs.clone())
                .child(
                    div()
                        .flex()
                        .flex_1()
                        .min_h_0()
                        .p(gap)
                        .gap(gap)
                        .child(div().flex_1().min_w_0().h_full().child(self.split_tree.clone()))
                        .when(self.right_sidebar.read(cx).is_open(), |body| {
                            body.child(self.right_sidebar.clone())
                        }),
                )
                .into_any_element(),
        };
        div()
            .flex()
            .flex_col()
            .flex_1()
            .min_w_0()
            .h_full()
            .child(body)
            .child(self.status_bar.clone())
            .into_any_element()
    }

    fn render_page(&mut self, page: Page, cx: &mut Context<Self>) -> AnyElement {
        let view: Option<gpui::AnyView> = match page {
            Page::Dashboard => self.dashboard.clone().map(Into::into),
            Page::Automations => self.automations_page.clone().map(Into::into),
        };
        let theme = cx.soprano_theme();
        div().flex_1().min_h_0().bg(theme.canvas).children(view).into_any_element()
    }
}

impl Render for MainView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        cx.soprano_theme().apply_to_window(window);
        let theme = cx.soprano_theme().clone();
        let sidebar_visible = self.shell.read(cx).sidebar_visible;
        let sidebar = sidebar_visible.then(|| self.render_sidebar(window, cx));
        let work = self.render_work(window, cx);
        let popup = self.shell.read(cx).popup.clone();
        div()
            .id("soprano-main")
            .key_context("SopranoMain")
            .track_focus(&self.focus)
            .size_full()
            .relative()
            .flex()
            .bg(theme.canvas)
            .text_color(theme.foreground)
            .font_family(soprano_ui::fonts::UI_FONT_FAMILY)
            .text_size(theme.z(soprano_ui::fonts::size::UI))
            .on_modifiers_changed(cx.listener(|this, event: &gpui::ModifiersChangedEvent, window, cx| {
                this.modifiers_changed(&event.modifiers, window, cx)
            }))
            .on_action(cx.listener(|this, action: &menus::FindWindow, window, cx| {
                this.menu_action(action, window, cx)
            }))
            .on_action(cx.listener(|this, action: &menus::CommandPalette, window, cx| {
                this.menu_action(action, window, cx)
            }))
            .on_action(cx.listener(|this, action: &menus::OpenProject, window, cx| {
                this.menu_action(action, window, cx)
            }))
            .on_action(cx.listener(|this, action: &menus::OpenInSopranoGit, window, cx| {
                this.menu_action(action, window, cx)
            }))
            .on_action(cx.listener(|this, action: &menus::OpenMarkdown, window, cx| {
                this.menu_action(action, window, cx)
            }))
            .on_action(cx.listener(|this, action: &menus::AgentDashboard, window, cx| {
                this.menu_action(action, window, cx)
            }))
            .on_action(cx.listener(|this, action: &menus::Automations, window, cx| {
                this.menu_action(action, window, cx)
            }))
            .on_action(cx.listener(|this, action: &menus::OpenSettingsFile, window, cx| {
                this.menu_action(action, window, cx)
            }))
            .on_action(cx.listener(|this, _: &gpui_component::input::Copy, _, cx| {
                if let Some(terminal) = this.content.read(cx).active_terminal(cx) {
                    terminal.update(cx, |terminal, cx| {
                        terminal.copy_selection(cx);
                    });
                }
            }))
            .on_action(cx.listener(|this, _: &gpui_component::input::Paste, _, cx| {
                if let Some(terminal) = this.content.read(cx).active_terminal(cx) {
                    terminal.update(cx, |terminal, cx| terminal.paste_from_clipboard(cx));
                }
            }))
            .on_action(cx.listener(|this, _: &gpui_component::input::SelectAll, _, cx| {
                if let Some(terminal) = this.content.read(cx).active_terminal(cx) {
                    terminal.update(cx, |terminal, cx| terminal.select_all(cx));
                }
            }))
            .children(sidebar)
            .child(work)
            .when_some(self.settings.clone(), |root, settings| root.child(settings))
            .when_some(self.picker.clone(), |root, picker| root.child(picker))
            .when_some(popup, |root, popup| root.child(popup))
            .when_some(self.dialog.clone(), |root, dialog| root.child(dialog))
            .child(self.toasts.clone())
    }
}

impl MainView {
    fn menu_action(&mut self, action: &dyn gpui::Action, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(command) = menus::command_for(action) {
            self.run(command, window, cx);
        }
    }
}

fn respond_none(respond: impl FnOnce(Response)) {
    // One-way requests have no replier; dropping the closure drops nothing to send.
    drop(respond);
}

fn model_direction(direction: soprano_keys::NavigationDirection) -> soprano_model::NavigationDirection {
    match direction {
        soprano_keys::NavigationDirection::Left => soprano_model::NavigationDirection::Left,
        soprano_keys::NavigationDirection::Right => soprano_model::NavigationDirection::Right,
        soprano_keys::NavigationDirection::Up => soprano_model::NavigationDirection::Up,
        soprano_keys::NavigationDirection::Down => soprano_model::NavigationDirection::Down,
    }
}

pub fn theme_appearance(
    preference: soprano_config::AppearancePreference,
) -> soprano_ui::AppearancePreference {
    soprano_ui::AppearancePreference::parse(preference.raw_value())
        .unwrap_or(soprano_ui::AppearancePreference::System)
}

pub fn is_markdown(path: &std::path::Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| matches!(ext.to_lowercase().as_str(), "md" | "markdown"))
}
