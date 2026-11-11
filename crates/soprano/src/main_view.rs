//! The window's root (`MainWindowController` + `MainContentViewController`): lays out the
//! sidebar, the tab rows, the split tree, the right sidebar and the status bar per SHELL-MAP.md,
//! carries out every [`Command`], routes every key through the keybinding resolver before any
//! content sees it, answers the CLI, hosts the overlays (palette, dialogs, Settings, toasts,
//! popups), and owns the Agents window beside it.

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
use soprano_model::{CloseOutcome, CloseRequest, WorkspaceChange};
use soprano_notify::{Authorization, BannerClick, NotificationManager, TerminalNotification};
use soprano_settings::{
    NotificationAuthorization, NotificationStatusProvider, SettingsEvent, SettingsTab, SettingsView,
};
use soprano_term::{
    ClipboardConfirmationCoordinator, ClipboardConfirmationDecision, ClipboardConfirmationPresentation,
    ClipboardConfirmationPresenter, ClipboardConfirmationPrompt, TerminalView,
};
use soprano_types::AgentCatalog;
use soprano_types::TerminalTarget;
use soprano_ui::{
    ActiveSopranoTheme, Dialog, DialogButton, DialogContent, DialogResult, Picker, PickerEvent, SopranoTheme,
    Toast, ToastLevel, ToastStack,
};

use crate::agents_window::{self, AgentsWindowHandle};
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
use soprano_statistics::{StatisticsBoard, StatisticsEvent};
use soprano_text::DocumentId;
use soprano_text::editor_store::{
    CloseResolution, OVERWRITE_MESSAGE, SaveChoice, SaveOutcome, overwrite_question, save_question,
};

/// What runs once the unsaved-changes question is answered with Save or Don't Save.
type Proceed = Box<dyn FnOnce(&mut MainView, &mut Window, &mut Context<MainView>)>;

/// The sidebar's resize strip straddling its trailing edge.
const SIDEBAR_HANDLE_WIDTH: f32 = 8.0;
/// How long the window must stay put before its frame is saved.
const FRAME_SAVE_DELAY: Duration = Duration::from_millis(500);
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
    /// The Agents window while it is open, with the subscription to its dashboard.
    agents: Option<(AgentsWindowHandle, Subscription)>,
    /// This window: keys typed in the Agents window are not the workspace's.
    window_id: gpui::WindowId,
    automations: AutomationContext,
    automations_page: Option<Entity<AutomationsPage>>,
    statistics: Option<Entity<StatisticsBoard>>,
    /// The focused tab's folder the right sidebar last followed.
    explorer_directory: Option<Option<String>>,
    notifications: Rc<RefCell<NotificationManager>>,
    resolver: KeybindingResolver,
    claims: PaneNavigationClaimRegistry,
    resolver_timer: Option<Task<()>>,
    clipboard: Rc<ClipboardConfirmationCoordinator>,
    clipboard_answers: async_channel::Sender<(WeakEntity<TerminalView>, u64, bool)>,
    focus: FocusHandle,
    /// The sidebar edge is being dragged: the pointer's start and the width it started at.
    sidebar_drag: Option<(Pixels, f32)>,
    /// The pending frame save while the window moves or resizes.
    frame_save: Option<Task<()>>,
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
        let keybindings = shell.read(cx).keybindings.clone();
        let resolver = KeybindingResolver::new(keybindings, Platform::current());
        content.update(cx, |content, cx| content.set_clipboard_coordinator(clipboard.clone(), cx));

        let (quit_sender, quit_requests) = async_channel::unbounded::<()>();
        crate::terminate::install(content.read(cx).unsaved(), quit_sender);
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
                this.schedule_frame_save(window, cx);
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
        // A system quit (Dock, logout) held back for unsaved files asks here.
        tasks.push(cx.spawn_in(window, async move |this, cx| {
            while quit_requests.recv().await.is_ok() {
                if this.update_in(cx, |this, window, cx| this.request_quit(window, cx)).is_err() {
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
            agents: None,
            window_id: window.window_handle().window_id(),
            automations,
            automations_page: None,
            statistics: None,
            explorer_directory: None,
            notifications,
            resolver,
            claims: PaneNavigationClaimRegistry::new(),
            resolver_timer: None,
            clipboard,
            clipboard_answers,
            focus: cx.focus_handle(),
            sidebar_drag: None,
            frame_save: None,
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
            Command::MachineTerminal => {
                let machines = self.shell.read(cx).machines.clone();
                match machines.as_slice() {
                    [] => self.prompt_to_add_machine(window, cx),
                    [machine] => self.run(Command::NewTerminalOn(machine.name.clone()), window, cx),
                    _ => {
                        let mut items = palette::machine_items(&self.shell, &machines);
                        items.push(palette::add_machine_item(&self.shell));
                        self.show_picker(items, Some("Open a terminal on…"), Vec::new(), window, cx);
                    }
                }
            }
            Command::AddMachine => self.prompt_to_add_machine(window, cx),
            Command::NewTerminalOn(machine) => {
                self.workspace.update(cx, |ws| ws.spawn_terminal_on(&machine));
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
            Command::ToggleDashboard => self.toggle_agents_window(window, cx),
            Command::ToggleAutomations => {
                if self.shell.read(cx).page == Some(Page::Automations) {
                    self.close_page(true, window, cx);
                } else {
                    self.show_page(Page::Automations, window, cx);
                }
            }
            Command::OpenAutomations => self.show_page(Page::Automations, window, cx),
            Command::LeavePage => {
                if matches!(self.shell.read(cx).page, Some(Page::Automations | Page::Statistics)) {
                    self.close_page(true, window, cx);
                }
            }
            Command::ToggleStatistics => {
                if self.shell.read(cx).page == Some(Page::Statistics) {
                    self.close_page(true, window, cx);
                } else {
                    self.show_page(Page::Statistics, window, cx);
                }
            }
            Command::OpenAutomationRun(run_id) => self.open_automation_run(&run_id, window, cx),
            Command::OpenMarkdown { pane_id } => self.choose_markdown_file(pane_id, window, cx),
            Command::OpenInSopranoGit => {
                let (machine, cwd) = {
                    let ws = self.workspace.read(cx);
                    (
                        ws.machine_of_pane(ws.active_pane_id()).map(str::to_owned),
                        ws.active_working_directory(),
                    )
                };
                if let Some(machine) = machine {
                    let message = format!("Soprano Git opens folders on this computer, not on {machine}.");
                    self.toast(ToastLevel::Error, message, cx);
                    return;
                }
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
            BindingCommand::Navigate(direction) => ws.update(cx, |ws| ws.navigate_to_pane(direction)),
            BindingCommand::PreviousWindow => ws.update(cx, |ws| ws.activate_previous_window()),
            BindingCommand::NextWindow => ws.update(cx, |ws| ws.activate_next_window()),
            BindingCommand::LastWindow => ws.update(cx, |ws| ws.activate_last_window()),
            BindingCommand::Resize(direction) => ws.update(cx, |ws| ws.resize_pane(direction, tick)),
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
            BindingCommand::MachineTerminal => self.run(Command::MachineTerminal, window, cx),
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
            BindingCommand::OpenAgentDashboard => self.run(Command::ToggleDashboard, window, cx),
            BindingCommand::ToggleStatistics => self.run(Command::ToggleStatistics, window, cx),
            // `keybindingZoom`: the active terminal's font, not the whole UI.
            BindingCommand::Zoom(delta) => {
                self.content.update(cx, |content, cx| content.change_active_terminal_font_size(delta, cx))
            }
            BindingCommand::ZoomReset => {
                self.content.update(cx, |content, cx| content.reset_active_terminal_font_size(cx))
            }
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

    /// "Add Machine…": asks for an ssh destination, lists it in `machines` and checks the
    /// login in the background; the result arrives as a toast.
    fn prompt_to_add_machine(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let content = DialogContent::prompt(
            "Add Machine".to_owned(),
            "Soprano lists it under machines in settings.json and checks that ssh can log in.",
            "user@host, or a Host from ~/.ssh/config",
            String::new(),
            "Add",
        );
        let this = cx.entity().downgrade();
        self.present_dialog(
            content,
            move |result, _, cx| {
                let Some(raw) = result.prompt_value() else { return };
                let _ = this.update(cx, |this, cx| this.add_machine(&raw, cx));
            },
            window,
            cx,
        );
    }

    fn add_machine(&mut self, raw: &str, cx: &mut Context<Self>) {
        let Some(machine) = soprano_config::machine_for_destination(raw) else { return };
        let failure = match soprano_config::add_machine(&self.services.config, &machine) {
            soprano_config::MachineEdit::Done => None,
            soprano_config::MachineEdit::Exists => Some(format!("{} is listed already.", machine.name)),
            soprano_config::MachineEdit::InvalidName => Some(format!(
                "\"{}\" cannot name a machine: it needs no spaces and no leading dash.",
                machine.name
            )),
            soprano_config::MachineEdit::NotFound | soprano_config::MachineEdit::WriteFailed => {
                Some("settings.json could not be written, so the machine was not added.".to_owned())
            }
        };
        if let Some(message) = failure {
            self.toast(ToastLevel::Error, message, cx);
            return;
        }
        self.toast(ToastLevel::Info, format!("{} added · checking…", machine.name), cx);
        let check = cx.background_spawn({
            let machine = machine.clone();
            async move { soprano_launch::check_machine(&machine) }
        });
        cx.spawn(async move |this, cx| {
            let result = check.await;
            let _ = this.update(cx, |this, cx| match result {
                soprano_launch::MachineCheck::Ready { tmux: Some(_), .. } => this.toast(
                    ToastLevel::Success,
                    format!("{} added · {}", machine.name, result.summary()),
                    cx,
                ),
                soprano_launch::MachineCheck::Ready { tmux: None, .. } => this.toast(
                    ToastLevel::Warning,
                    format!("{} added · {}", machine.name, result.summary()),
                    cx,
                ),
                soprano_launch::MachineCheck::Unreachable { .. } => this.toast(
                    ToastLevel::Error,
                    format!("{} added, but ssh cannot log in: {}", machine.name, result.summary()),
                    cx,
                ),
            });
        })
        .detach();
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
        if page != Page::Automations {
            self.automations_page = None;
        }
        if page != Page::Statistics {
            self.statistics = None;
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
        if page == Page::Statistics && self.statistics.is_none() {
            let host = crate::statistics::host(self.workspace.model.clone());
            let board = cx.new(|cx| StatisticsBoard::new(host, window, cx));
            let subscription =
                cx.subscribe_in(&board, window, |this, _, event: &StatisticsEvent, window, cx| match event {
                    StatisticsEvent::Close => this.close_page(true, window, cx),
                });
            self._subscriptions.push(subscription);
            let handle = board.focus_handle(cx);
            self.statistics = Some(board);
            window.focus(&handle, cx);
        }
        self.shell.update(cx, |shell, cx| {
            shell.page = Some(page);
            cx.notify();
        });
    }

    fn close_page(&mut self, restore_focus: bool, window: &mut Window, cx: &mut Context<Self>) {
        self.automations_page = None;
        self.statistics = None;
        self.shell.update(cx, |shell, cx| {
            shell.page = None;
            cx.notify();
        });
        if restore_focus {
            self.sync_keyboard_focus(window, cx);
        }
    }

    // MARK: - Agents window

    /// `⇧⌘D`: opens the Agents window, brings it forward while it is behind, and closes it
    /// while it is in front.
    fn toggle_agents_window(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some((agents, _)) = self.agents.as_ref().filter(|(agents, _)| agents.is_open()) else {
            return self.open_agents_window(window, cx);
        };
        let handle = agents.window;
        let state = self.services.state.clone();
        let closed = handle.update(cx, |_, window, _| {
            let in_front = window.is_window_active();
            if in_front {
                agents_window::close(window, &state);
            } else {
                window.activate_window();
            }
            in_front
        });
        match closed {
            Ok(true) => self.agents = None,
            Ok(false) => {}
            // The window is in the middle of an update of its own: the request came from a key
            // or the menu in it, so it is the one in front. It closes once that update is over.
            Err(_) => {
                self.agents = None;
                cx.defer(move |cx| {
                    handle.update(cx, |_, window, _| agents_window::close(window, &state)).ok();
                });
            }
        }
    }

    fn open_agents_window(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let content = self.content.clone();
        let branches = self.services.branches.clone();
        let workspace = self.workspace.clone();
        let shell = self.shell.clone();
        let host = DashboardHost::new()
            .accepts_replies(move |target, cx| content.read(cx).accepts_prompt(target, cx))
            .notable_branch(move |cwd, _| branches.notable_branch(cwd))
            .projects(move |cx| {
                agents_window::project_choices(
                    workspace.read(cx),
                    &shell.read(cx).settings.project_directories,
                )
            })
            .state(self.services.state.clone())
            .leading_inset(window_chrome::agents_leading_inset());
        let display = match window.display(cx) {
            Some(display) => window_chrome::frame_of(display.visible_bounds()),
            None => window_chrome::main_visible_frame(cx),
        };
        match agents_window::open(self.workspace.model.clone(), host, &self.services.state, display, cx) {
            Ok(agents) => {
                let Some(dashboard) = agents.dashboard.upgrade() else { return };
                let subscription =
                    cx.subscribe_in(&dashboard, window, |this, _, event: &DashboardEvent, window, cx| {
                        this.dashboard_event(event, window, cx)
                    });
                self.agents = Some((agents, subscription));
            }
            Err(error) => {
                self.toast(ToastLevel::Error, format!("The Agents window could not open: {error}"), cx)
            }
        }
    }

    fn close_agents_window(&mut self, cx: &mut Context<Self>) {
        let Some((agents, _)) = self.agents.take() else { return };
        let state = self.services.state.clone();
        agents.window.update(cx, |_, window, _| agents_window::close(window, &state)).ok();
    }

    /// Runs `f` on the dashboard in its own window.
    fn with_dashboard(
        &self,
        cx: &mut App,
        f: impl FnOnce(&mut AgentDashboard, &mut Window, &mut Context<AgentDashboard>),
    ) {
        let Some((agents, _)) = &self.agents else { return };
        let Some(dashboard) = agents.dashboard.upgrade() else { return };
        agents
            .window
            .update(cx, |_, window, cx| dashboard.update(cx, |dashboard, cx| f(dashboard, window, cx)))
            .ok();
    }

    /// What the dashboard asks for. `window` is the main window: the dashboard's events arrive
    /// here once its own window is done with the key or click that caused them.
    fn dashboard_event(&mut self, event: &DashboardEvent, window: &mut Window, cx: &mut Context<Self>) {
        match event {
            DashboardEvent::Open(target) => {
                // The agent shows in the main window, which comes forward; the Agents window
                // stays where it is.
                self.close_page(false, window, cx);
                self.workspace.update(cx, |ws| ws.focus_tab(&target.pane_id, &target.tab_id, true));
                window.activate_window();
                self.sync_keyboard_focus(window, cx);
            }
            DashboardEvent::Stop(target) => self.workspace.update(cx, |ws| ws.stop_agent(target)),
            DashboardEvent::Restart(target) => self.workspace.update(cx, |ws| ws.restart_agent(target)),
            DashboardEvent::Reply { target, text } => {
                let sent =
                    self.content.update(cx, |content, cx| content.reply_to_agent(text, target, window, cx));
                if !sent {
                    self.with_dashboard(cx, |dashboard, window, cx| {
                        dashboard.reply_failed(target, text, window, cx)
                    });
                }
            }
            DashboardEvent::NewThread { profile_id, chat, cwd, prompt } => {
                let opened =
                    self.workspace.update(cx, |ws| ws.open_thread(profile_id, *chat, cwd, Some(prompt)));
                let Some(target) = opened else {
                    return self.with_dashboard(cx, |dashboard, window, cx| {
                        dashboard.thread_failed(
                            "This agent can no longer be started with a message.",
                            window,
                            cx,
                        )
                    });
                };
                // Its tab waits behind the visible one, so nothing has started its agent yet.
                let started =
                    self.content.update(cx, |content, cx| content.start_thread(&target, prompt, window, cx));
                if !started {
                    self.toast(ToastLevel::Error, "The agent could not start. Open it in its window.", cx);
                }
                self.with_dashboard(cx, |dashboard, window, cx| dashboard.thread_opened(&target, window, cx));
            }
            DashboardEvent::ChooseProject => {
                let paths = cx.prompt_for_paths(PathPromptOptions {
                    files: false,
                    directories: true,
                    multiple: false,
                    prompt: Some("Choose".into()),
                });
                cx.spawn(async move |this, cx| {
                    let Ok(Ok(Some(paths))) = paths.await else { return };
                    let Some(path) = paths.first().map(|path| path.to_string_lossy().into_owned()) else {
                        return;
                    };
                    this.update(cx, |this, cx| {
                        this.with_dashboard(cx, |dashboard, window, cx| {
                            dashboard.set_draft_project(&path, window, cx)
                        })
                    })
                    .ok();
                })
                .detach();
            }
            DashboardEvent::Close => {
                self.close_agents_window(cx);
                window.activate_window();
            }
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
        let (cwd, machine) = {
            let ws = self.workspace.read(cx);
            let machine = ws.machine_of_pane(ws.active_pane_id()).map(str::to_owned);
            // A remote pane's folder is on its machine; the panels keep their roots.
            let cwd = ws
                .pane(ws.active_pane_id())
                .and_then(|pane| pane.active_tab())
                .filter(|_| machine.is_none())
                .and_then(|tab| tab.effective_working_directory());
            (cwd, machine)
        };
        self.right_sidebar.update(cx, |sidebar, cx| sidebar.set_remote_machine(machine, cx));
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
            let valid: HashSet<soprano_types::TerminalTarget> = ws
                .panes()
                .values()
                .flat_map(|pane| {
                    pane.tabs.iter().map(|tab| soprano_types::TerminalTarget::new(&pane.id, &tab.id))
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
            ContentEvent::ProgramStatus { target, status } => {
                let notifications = self.notifications.clone();
                let (target, status) = (target.clone(), status.clone());
                self.workspace
                    .update(cx, |ws| notifications.borrow_mut().handle_program_status(ws, target, status));
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
            shell.machines = snapshot.resolved.machines.clone();
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
        let palette = terminal_theme(theme.theme());
        self.content.update(cx, |content, cx| content.set_terminal_theme(palette, cx));
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

    /// Saves the frame once moving or resizing has paused for [`FRAME_SAVE_DELAY`]: writing
    /// state.json on every bounds event would stutter a live resize. Close and quit save at once.
    fn schedule_frame_save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.frame_save = Some(cx.spawn_in(window, async move |this, cx| {
            cx.background_executor().timer(FRAME_SAVE_DELAY).await;
            this.update_in(cx, |this, window, cx| this.save_window_frame(window, cx)).ok();
        }));
    }

    pub fn save_window_frame(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.frame_save = None;
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
        // The Automations page keeps its own chords (⌘N), as `AutomationsRootView` did.
        if self
            .automations_page
            .as_ref()
            .is_some_and(|page| page.focus_handle(cx).contains_focused(window, cx))
        {
            return FocusedContent::Automations;
        }
        let content = self.content.read(cx);
        for (_, item) in content.contents() {
            let Some(handle) = item.focus_handle(cx) else { continue };
            if handle.contains_focused(window, cx) {
                return item.focused_content();
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

    /// Whether `keystroke` is the chord bound to the Agent Dashboard, read against the bindings
    /// alone: the resolver's own prefix and hint state belongs to the main window.
    fn toggles_agents_window(&self, keystroke: &gpui::Keystroke) -> bool {
        let modifiers = &keystroke.modifiers;
        if !(modifiers.platform || modifiers.control || modifiers.alt) {
            return false;
        }
        let mut resolver = KeybindingResolver::new(self.resolver.config().clone(), self.resolver.platform());
        let outcome =
            resolver.handle(&crate::keyboard::key_event(keystroke), &KeyContext::new(Instant::now()));
        matches!(outcome, KeyOutcome::Action(id) | KeyOutcome::MenuAction(id) if id == "agent-dashboard")
    }

    fn intercept_key(&mut self, event: &KeystrokeEvent, window: &mut Window, cx: &mut Context<Self>) {
        if window.window_handle().window_id() != self.window_id {
            // Keys typed in the Agents window are its own; only the chord that toggles it is
            // the app's.
            if self.toggles_agents_window(&event.keystroke) {
                cx.stop_propagation();
                self.toggle_agents_window(window, cx);
            }
            return;
        }
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
                .map(|tab| soprano_types::TerminalTarget::new(pane, &tab.id))
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
                let target = soprano_types::TerminalTarget::new(pane_id, tab_id);
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
            #[cfg(feature = "visual-snapshot")]
            Request::DebugSnapshot { path } => respond(match crate::snapshot::write_png(window, &path) {
                Ok(()) => Response::success(path.to_string_lossy().into_owned()),
                Err(error) => Response::failure(format!("{error:#}")),
            }),
            #[cfg(feature = "visual-snapshot")]
            Request::DebugInput { input } => crate::debug_input::perform(input, window, cx, respond),
            Request::OpenOnMachine { pane_id, tab_id, machine } => {
                let machines = &self.shell.read(cx).machines;
                if !machines.iter().any(|known| known.name == machine) {
                    let known: Vec<&str> = machines.iter().map(|m| m.name.as_str()).collect();
                    let message = if known.is_empty() {
                        format!(
                            "No machine named {machine}. Add it with: soprano machine add {machine} <user@host>"
                        )
                    } else {
                        format!("No machine named {machine}. Machines: {}.", known.join(", "))
                    };
                    return respond(Response::failure(message));
                }
                let moved =
                    self.workspace.update(cx, |ws| ws.move_tab_to_machine(&pane_id, &tab_id, &machine));
                respond(if moved {
                    Response::success(format!("Connecting to {machine}…"))
                } else {
                    Response::failure("Only a terminal tab can continue on a machine.")
                });
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
            Some(page) => div()
                .flex()
                .flex_col()
                .flex_1()
                .min_h_0()
                .child(crate::views::tab_rows::page_top_row(&self.shell, window, cx))
                .child(self.render_page(page, cx))
                .into_any_element(),
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
            Page::Automations => self.automations_page.clone().map(Into::into),
            Page::Statistics => self.statistics.clone().map(Into::into),
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
            .on_action(cx.listener(|this, action: &menus::Statistics, window, cx| {
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
