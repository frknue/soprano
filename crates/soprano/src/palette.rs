//! The command palette's items (`MainWindowController.buildCommandPaletteItems`) and the window,
//! session and project pickers (`buildWindowPaletteItems`, `buildSessionPaletteItems`,
//! `buildProjectPaletteItems`). The picker widget is soprano-ui's; this module decides what it
//! lists and what each row does.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use gpui::{App, Entity, Window};
use soprano_launch::ChatLaunch;
use soprano_model::{PaneContentKind, PaneType, Workspace};
use soprano_types::{AgentCatalog, Machine};
use soprano_ui::{IconName, PickerItem};

use crate::shell::{CloseTarget, Command, MarkdownTarget, Shell, dispatch};
use crate::workspace::WorkspaceHandle;

/// What a row does; gets the query typed when it was chosen.
pub type PaletteAction = Rc<dyn Fn(&str, &mut Window, &mut App)>;

pub struct PaletteEntry {
    pub item: PickerItem,
    pub action: PaletteAction,
}

/// One row: the Swift `CommandItem`.
struct ItemSpec<'a> {
    id: String,
    icon: IconName,
    label: String,
    description: String,
    shortcut: Vec<String>,
    search: Option<&'a str>,
}

fn entry(spec: ItemSpec<'_>, action: impl Fn(&str, &mut Window, &mut App) + 'static) -> PaletteEntry {
    let mut item = PickerItem::new(spec.id, spec.label)
        .icon(spec.icon)
        .description(spec.description)
        .keycaps(spec.shortcut);
    if let Some(search) = spec.search {
        item = item.search_text(search);
    }
    PaletteEntry { item, action: Rc::new(action) }
}

/// Runs a plain model mutation.
fn mutate<F: Fn(&mut Workspace) + 'static>(
    workspace: &WorkspaceHandle,
    f: F,
) -> impl Fn(&str, &mut Window, &mut App) + use<F> {
    let workspace = workspace.clone();
    move |_, _, cx| workspace.update(cx, |ws| f(ws))
}

/// Runs a shell command (after the palette closed).
fn command(shell: &Entity<Shell>, command: Command) -> impl Fn(&str, &mut Window, &mut App) + use<> {
    let shell = shell.clone();
    move |_, _, cx| dispatch(&shell, command.clone(), cx)
}

fn spec<'a>(id: &str, icon: IconName, label: &str, description: &str, shortcut: Vec<String>) -> ItemSpec<'a> {
    ItemSpec {
        id: id.into(),
        icon,
        label: label.into(),
        description: description.into(),
        shortcut,
        search: None,
    }
}

fn searchable<'a>(mut spec: ItemSpec<'a>, search: &'a str) -> ItemSpec<'a> {
    spec.search = Some(search);
    spec
}

/// Every command, in the Swift order.
pub fn command_items(
    workspace: &WorkspaceHandle,
    shell: &Entity<Shell>,
    soprano_git_installed: bool,
    settings_display_path: &str,
    cx: &App,
) -> Vec<PaletteEntry> {
    let shell_state = shell.read(cx);
    let short = |ids: &[&str]| shell_state.shortcut(ids);
    let profiles: Vec<_> = AgentCatalog::shared().all().into_iter().filter(|p| p.id != "terminal").collect();
    let mut entries = Vec::new();

    // One launcher per agent in the catalog (respecting Chat UI default launch mode).
    for profile in &profiles {
        let id = profile.id.clone();
        let as_chat = shell_state.launches_as_chat(&id);
        entries.push(entry(
            spec(
                &format!("launch-{}", profile.id),
                IconName::Command,
                &format!("Launch {}", profile.name),
                &format!("Launch the {} agent", profile.name),
                short(&[&format!("launch-{}", profile.id)]),
            ),
            mutate(workspace, move |ws| {
                ws.spawn_agent(&id, None, as_chat);
            }),
        ));
    }
    // Each agent as a tab of the focused pane.
    for profile in &profiles {
        let id = profile.id.clone();
        let as_chat = shell_state.launches_as_chat(&id);
        let search = format!("pane tab split {}", profile.name);
        entries.push(entry(
            ItemSpec {
                search: None,
                ..spec(
                    &format!("agent-pane-tab-{}", profile.id),
                    IconName::SquarePlus,
                    &format!("New {} in This Pane", profile.name),
                    &format!("Open {} as a tab of the focused pane", profile.name),
                    Vec::new(),
                )
            },
            mutate(workspace, move |ws| {
                let pane = ws.active_pane_id().to_owned();
                ws.add_tab_to_pane(
                    &pane,
                    PaneType::Agent,
                    Some(&id),
                    as_chat.then_some(PaneContentKind::CHAT),
                );
            }),
        ));
        if let Some(last) = entries.last_mut() {
            last.item = last.item.clone().search_text(search);
        }
    }
    // Switching between Chat UI and terminal CLI, and searching inside a chat.
    entries.push(entry(
        searchable(
            spec(
                "toggle-chat-ui",
                IconName::MessageSquare,
                "Switch Between Chat UI and Terminal",
                "Toggle the active agent tab between Chat UI and its terminal CLI",
                short(&["toggle-chat-ui"]),
            ),
            "chat cli terminal toggle switch mode",
        ),
        command(shell, Command::ToggleChatUi { pane_id: None, tab_id: None }),
    ));
    entries.push(entry(
        searchable(
            spec(
                "find-in-chat",
                IconName::Search,
                "Find in Chat",
                "Search messages in the active chat",
                short(&["find-in-chat"]),
            ),
            "find search chat timeline messages",
        ),
        command(shell, Command::FindInChat),
    ));
    // A chat opens wherever a terminal can.
    let chat_profiles = ChatLaunch::chat_profiles();
    let default_chat = chat_profiles.first().map(|p| p.id.clone());
    for profile in &chat_profiles {
        let name = &profile.name;
        let search = format!("chat conversation gui {name}");
        let id = profile.id.clone();
        let chat_shortcut =
            if Some(&profile.id) == default_chat.as_ref() { short(&["new-chat"]) } else { Vec::new() };
        let rows: [AgentRow; 4] = [
            (
                format!("chat-pane-{id}"),
                format!("New {name} Chat"),
                format!("Open a chat with {name} beside the focused pane"),
                chat_shortcut,
                Box::new({
                    let id = id.clone();
                    move |ws: &mut Workspace| {
                        ws.spawn_agent(&id, None, true);
                    }
                }),
            ),
            (
                format!("chat-pane-tab-{id}"),
                format!("New {name} Chat in This Pane"),
                format!("Open a chat with {name} as a tab of the focused pane"),
                Vec::new(),
                Box::new({
                    let id = id.clone();
                    move |ws: &mut Workspace| {
                        let pane = ws.active_pane_id().to_owned();
                        ws.add_tab_to_pane(&pane, PaneType::Agent, Some(&id), Some(PaneContentKind::CHAT));
                    }
                }),
            ),
            (
                format!("chat-tab-{id}"),
                format!("New {name} Chat Tab"),
                format!("Open a tab holding a chat with {name}"),
                Vec::new(),
                Box::new({
                    let id = id.clone();
                    move |ws: &mut Workspace| {
                        ws.create_layout_tab(None, Some(&id));
                    }
                }),
            ),
            (
                format!("chat-window-{id}"),
                format!("New {name} Chat Window"),
                format!("Open a window holding a chat with {name}"),
                Vec::new(),
                Box::new({
                    let id = id.clone();
                    move |ws: &mut Workspace| {
                        ws.create_window(None, Some(&id));
                    }
                }),
            ),
        ];
        for (row_id, label, description, shortcut, action) in rows {
            let workspace = workspace.clone();
            let mut row = entry(
                spec(&row_id, IconName::MessageSquare, &label, &description, shortcut),
                move |_, _, cx| workspace.update(cx, |ws| action(ws)),
            );
            row.item = row.item.search_text(search.clone());
            entries.push(row);
        }
    }

    if soprano_git_installed {
        entries.push(entry(
            searchable(
                spec(
                    "open-in-soprano-git",
                    IconName::GitBranch,
                    "Open in Soprano Git",
                    "Open the active tab's Git repository in Soprano Git",
                    short(&["open-in-soprano-git"]),
                ),
                "git gitkraken graph history commit branch source control",
            ),
            command(shell, Command::OpenInSopranoGit),
        ));
    }
    entries.push(entry(
        searchable(
            spec(
                "open-in-vscode",
                IconName::Code,
                "Open in VS Code",
                "Open the active tab's directory in Visual Studio Code",
                short(&["open-in-vscode"]),
            ),
            "vscode visual studio code editor folder",
        ),
        command(shell, Command::OpenInVsCode),
    ));

    let omp_launcher: PathBuf =
        soprano_platform::paths::resources_dir().unwrap_or_default().join("bin").join("omp");

    entries.extend([
        entry(
            spec(
                "new-session",
                IconName::Layers,
                "New Session…",
                "Create a named group of windows",
                short(&["new-session"]),
            ),
            command(shell, Command::NewSession),
        ),
        entry(
            spec(
                "find-session",
                IconName::Layers,
                "Switch Session…",
                "Return to a running session",
                short(&["find-session"]),
            ),
            command(shell, Command::FindSession),
        ),
        entry(
            spec(
                "rename-session",
                IconName::SquarePen,
                "Rename Session…",
                "Rename the current session",
                Vec::new(),
            ),
            command(shell, Command::RenameSession),
        ),
        entry(
            spec(
                "close-session",
                IconName::SquareMinus,
                "Close Session…",
                "Close the current session and its terminals",
                Vec::new(),
            ),
            command(shell, Command::CloseSession),
        ),
        entry(
            spec(
                "new-window",
                IconName::AppWindow,
                "New Window…",
                "Create a new logical window in a chosen directory",
                short(&["new-window"]),
            ),
            command(shell, Command::NewWindow),
        ),
        entry(
            spec(
                "new-window-current-directory",
                IconName::AppWindow,
                "New Window Here",
                "Create a logical window in the active terminal directory",
                short(&["new-window-current-directory"]),
            ),
            mutate(workspace, |ws| {
                ws.create_window(None, None);
            }),
        ),
        entry(
            spec(
                "previous-window",
                IconName::ChevronLeft,
                "Previous Window",
                "Switch to the previous logical window",
                short(&["previous-window"]),
            ),
            mutate(workspace, |ws| ws.activate_previous_window()),
        ),
        entry(
            spec(
                "next-window",
                IconName::ChevronRight,
                "Next Window",
                "Switch to the next logical window",
                short(&["next-window"]),
            ),
            mutate(workspace, |ws| ws.activate_next_window()),
        ),
        entry(
            spec(
                "last-window",
                IconName::Undo2,
                "Last Window",
                "Switch to the most recently active logical window",
                short(&["last-window"]),
            ),
            mutate(workspace, |ws| ws.activate_last_window()),
        ),
        entry(
            spec(
                "find-window",
                IconName::AppWindow,
                "Find Window…",
                "Search and switch to a logical window",
                short(&["find-window"]),
            ),
            command(shell, Command::FindWindow),
        ),
        entry(
            spec(
                "rename-window",
                IconName::SquarePen,
                "Rename Window…",
                "Rename the active logical window",
                short(&["rename-window"]),
            ),
            command(shell, Command::RenameWindow(None)),
        ),
        entry(
            spec(
                "close-window",
                IconName::SquareX,
                "Close Window",
                "Close the active logical window",
                short(&["close-window"]),
            ),
            {
                let workspace = workspace.clone();
                let shell = shell.clone();
                move |_, _, cx| {
                    let id = workspace.read(cx).active_window_id().to_owned();
                    dispatch(&shell, Command::Close(CloseTarget::Window(id)), cx);
                }
            },
        ),
        entry(
            spec(
                "open-project",
                IconName::Folder,
                "Open Project…",
                "Search configured projects or choose a directory",
                short(&["open-project"]),
            ),
            command(shell, Command::OpenProjectSearch),
        ),
        entry(
            spec(
                "new-terminal",
                IconName::Terminal,
                "Open Terminal",
                "Open a new terminal pane",
                short(&["new-terminal"]),
            ),
            mutate(workspace, |ws| {
                ws.spawn_terminal(None);
            }),
        ),
        entry(
            searchable(
                spec(
                    "open-omp-web",
                    IconName::Globe,
                    "omp web",
                    "Start the omp web workspace in your default browser",
                    Vec::new(),
                ),
                "ompweb web ui browser coding agent",
            ),
            mutate(workspace, move |ws| {
                ws.spawn_omp_web(&omp_launcher);
            }),
        ),
        entry(
            spec(
                "new-browser",
                IconName::Globe,
                "Open Browser",
                "Split a browser pane to the right",
                short(&["new-browser"]),
            ),
            mutate(workspace, |ws| {
                ws.spawn_browser(None);
            }),
        ),
        entry(
            searchable(
                spec(
                    "open-markdown",
                    IconName::FileText,
                    "Open Markdown…",
                    "Open a local Markdown file in a live reader",
                    Vec::new(),
                ),
                "read preview documentation readme md",
            ),
            command(shell, Command::OpenMarkdown(MarkdownTarget::NewPane)),
        ),
        entry(
            searchable(
                spec(
                    "new-browser-pane-tab",
                    IconName::Globe,
                    "New Browser in This Pane",
                    "Open a browser as a tab of the focused pane",
                    Vec::new(),
                ),
                "pane tab split web",
            ),
            mutate(workspace, |ws| {
                let pane = ws.active_pane_id().to_owned();
                ws.add_tab_to_pane(&pane, PaneType::Browser, None, None);
            }),
        ),
        entry(
            searchable(
                spec(
                    "open-markdown-pane-tab",
                    IconName::FileText,
                    "Open Markdown in This Pane…",
                    "Open a local Markdown file as a tab of the focused pane",
                    Vec::new(),
                ),
                "pane tab split read preview documentation readme md",
            ),
            {
                let workspace = workspace.clone();
                let shell = shell.clone();
                move |_, _, cx| {
                    let pane = workspace.read(cx).active_pane_id().to_owned();
                    dispatch(&shell, Command::OpenMarkdown(MarkdownTarget::PaneTab(pane)), cx);
                }
            },
        ),
        entry(
            spec(
                "split-horizontal",
                IconName::Rows2,
                "Split Horizontal",
                "Split the active pane horizontally",
                short(&["split-horizontal"]),
            ),
            command(shell, Command::RunBinding("split-horizontal".into())),
        ),
        entry(
            spec(
                "split-vertical",
                IconName::Columns2,
                "Split Vertical",
                "Split the active pane vertically",
                short(&["split-vertical"]),
            ),
            command(shell, Command::RunBinding("split-vertical".into())),
        ),
        entry(
            spec(
                "new-tab",
                IconName::SquarePlus,
                "New Tab",
                "Open a tab with a new terminal in the active window",
                short(&["new-tab-direct", "new-tab"]),
            ),
            mutate(workspace, |ws| {
                ws.create_layout_tab(None, None);
            }),
        ),
        entry(
            spec(
                "next-tab",
                IconName::ArrowRight,
                "Next Tab",
                "Switch to the next tab of the active window",
                short(&["next-tab"]),
            ),
            mutate(workspace, |ws| ws.activate_next_layout_tab()),
        ),
        entry(
            spec(
                "previous-tab",
                IconName::ArrowLeft,
                "Previous Tab",
                "Switch to the previous tab of the active window",
                short(&["previous-tab"]),
            ),
            mutate(workspace, |ws| ws.activate_previous_layout_tab()),
        ),
        entry(
            spec(
                "close-tab",
                IconName::SquareX,
                "Close Tab",
                "Close the active tab and every pane in it",
                short(&["close-tab"]),
            ),
            command(shell, Command::Close(CloseTarget::ActiveLayoutTab)),
        ),
        entry(
            spec(
                "move-tab-to-new-window",
                IconName::ExternalLink,
                "Move Tab to New Window",
                "Give the active tab a window of its own",
                Vec::new(),
            ),
            mutate(workspace, |ws| {
                if let Some(tab) = ws.active_window().map(|window| window.active_tab().id.clone()) {
                    ws.move_layout_tab_to_new_window(&tab);
                }
            }),
        ),
        entry(
            spec(
                "move-pane-to-new-tab",
                IconName::SquarePlus,
                "Move Pane to New Tab",
                "Give the active pane a tab of its own in this window",
                Vec::new(),
            ),
            mutate(workspace, |ws| {
                let pane = ws.active_pane_id().to_owned();
                ws.move_pane_to_new_layout_tab(&pane, None);
            }),
        ),
        entry(
            spec(
                "move-pane-to-new-window",
                IconName::AppWindow,
                "Move Pane to New Window",
                "Give the active pane a window of its own",
                Vec::new(),
            ),
            mutate(workspace, |ws| {
                let pane = ws.active_pane_id().to_owned();
                ws.move_pane_to_new_window(&pane);
            }),
        ),
        entry(
            searchable(
                spec(
                    "new-pane-tab",
                    IconName::SquarePlus,
                    "New Pane Tab",
                    "Open a terminal tab inside the active pane",
                    short(&["new-pane-tab-direct", "new-pane-tab"]),
                ),
                "new terminal in this pane split",
            ),
            mutate(workspace, |ws| {
                let pane = ws.active_pane_id().to_owned();
                ws.add_tab_to_pane(&pane, PaneType::Terminal, None, None);
            }),
        ),
        entry(
            spec(
                "next-pane-tab",
                IconName::ChevronRight,
                "Next Pane Tab",
                "Switch to the next tab inside the active pane",
                short(&["next-pane-tab-direct", "next-pane-tab"]),
            ),
            mutate(workspace, |ws| {
                let pane = ws.active_pane_id().to_owned();
                ws.next_tab(&pane);
            }),
        ),
        entry(
            spec(
                "previous-pane-tab",
                IconName::ChevronLeft,
                "Previous Pane Tab",
                "Switch to the previous tab inside the active pane",
                short(&["prev-pane-tab-direct", "prev-pane-tab"]),
            ),
            mutate(workspace, |ws| {
                let pane = ws.active_pane_id().to_owned();
                ws.prev_tab(&pane);
            }),
        ),
        entry(
            spec(
                "close-pane-tab",
                IconName::SquareX,
                "Close Pane Tab",
                "Close the active tab inside the active pane",
                short(&["close-active", "close-pane-tab-direct", "close-pane-tab"]),
            ),
            {
                let workspace = workspace.clone();
                let shell = shell.clone();
                move |_, _, cx| {
                    let ws = workspace.read(cx);
                    let pane_id = ws.active_pane_id().to_owned();
                    let Some(tab) = ws.pane(&pane_id).and_then(|p| p.active_tab()) else { return };
                    let tab_id = tab.id.clone();
                    dispatch(&shell, Command::Close(CloseTarget::PaneTab { pane_id, tab_id }), cx);
                }
            },
        ),
        entry(
            spec(
                "close-pane",
                IconName::SquareX,
                "Close Pane",
                "Close the active pane",
                short(&["close-pane"]),
            ),
            {
                let workspace = workspace.clone();
                let shell = shell.clone();
                move |_, _, cx| {
                    let pane = workspace.read(cx).active_pane_id().to_owned();
                    dispatch(&shell, Command::Close(CloseTarget::Pane(pane)), cx);
                }
            },
        ),
        entry(
            spec(
                "restart-agent",
                IconName::RefreshCw,
                "Restart Agent",
                "Restart the active agent",
                Vec::new(),
            ),
            mutate(workspace, |ws| {
                let pane = ws.active_pane_id().to_owned();
                ws.restart_agent_in_pane(&pane);
            }),
        ),
        entry(
            spec("stop-agent", IconName::CircleStop, "Stop Agent", "Stop the active agent", Vec::new()),
            mutate(workspace, |ws| {
                let pane = ws.active_pane_id().to_owned();
                ws.stop_agent_in_pane(&pane);
            }),
        ),
        entry(
            spec(
                "save-session",
                IconName::Save,
                "Save Workspace As…",
                "Save all sessions and their layouts as a workspace snapshot",
                short(&["save-session"]),
            ),
            command(shell, Command::SaveWorkspaceAs),
        ),
        entry(
            searchable(
                spec(
                    "agent-dashboard",
                    IconName::ChartColumn,
                    "Agent Dashboard",
                    "Every agent as a thread, in its own window",
                    short(&["agent-dashboard"]),
                ),
                "agents monitor status attention working",
            ),
            command(shell, Command::ToggleDashboard),
        ),
        entry(
            searchable(
                spec(
                    "automations",
                    IconName::AlarmClock,
                    "Automations",
                    "Scheduled prompts, their runs and reports",
                    Vec::new(),
                ),
                "automation schedule scheduled cron prompt runs recurring",
            ),
            command(shell, Command::OpenAutomations),
        ),
        entry(
            searchable(
                spec(
                    "statistics",
                    IconName::STATISTICS,
                    "Statistics",
                    "omp's tokens and estimated cost over time",
                    short(&["statistics"]),
                ),
                "usage cost tokens spend models omp stats chart",
            ),
            command(shell, Command::ToggleStatistics),
        ),
        entry(
            spec(
                "toggle-sidebar",
                IconName::PanelLeft,
                "Toggle Sidebar",
                "Show or hide the sidebar",
                short(&["toggle-sidebar"]),
            ),
            command(shell, Command::ToggleSidebar),
        ),
        entry(
            spec(
                "toggle-right-sidebar",
                IconName::PanelRight,
                "Toggle Right Sidebar",
                "Show or hide the right sidebar",
                short(&["toggle-right-sidebar"]),
            ),
            command(shell, Command::ToggleRightSidebar),
        ),
        entry(
            spec(
                "toggle-explorer",
                IconName::Files,
                "Toggle Explorer",
                "Show the file explorer sidebar, or hide it",
                short(&["toggle-explorer"]),
            ),
            command(shell, Command::ToggleExplorer),
        ),
        entry(
            searchable(
                spec(
                    "toggle-source-control",
                    IconName::GitBranch,
                    "Toggle Source Control",
                    "Show the changed files and their diffs, or hide them",
                    short(&["toggle-source-control"]),
                ),
                "git diff changes staged",
            ),
            command(shell, Command::ToggleSourceControl),
        ),
        entry(
            searchable(
                spec(
                    "toggle-session-history",
                    IconName::Clock,
                    "Toggle Session History",
                    "Search and resume past agent sessions in this directory or across all projects",
                    short(&["toggle-session-history"]),
                ),
                "agent session history search resume claude omp codex opencode transcripts",
            ),
            command(shell, Command::ToggleSessionHistory),
        ),
        entry(
            spec(
                "open-settings",
                IconName::Settings,
                "Settings",
                "Open the settings screen",
                short(&["open-settings"]),
            ),
            command(shell, Command::OpenSettings),
        ),
        entry(
            searchable(
                spec(
                    "open-accounts",
                    IconName::User,
                    "Accounts",
                    "Claude and Codex logins and their usage",
                    Vec::new(),
                ),
                "account login usage claude codex omp switch",
            ),
            command(shell, Command::OpenAccountsSettings),
        ),
        entry(
            searchable(
                spec(
                    "open-settings-json",
                    IconName::Braces,
                    "Open settings.json",
                    settings_display_path,
                    Vec::new(),
                ),
                "config json edit settings file",
            ),
            command(shell, Command::OpenSettingsFile),
        ),
    ]);
    if !shell_state.machines.is_empty() {
        entries.push(entry(
            spec(
                "machine-terminal",
                IconName::Server,
                "Terminal on Machine…",
                "Choose a machine and open a terminal on it beside the focused pane",
                short(&["machine-terminal"]),
            ),
            command(shell, Command::MachineTerminal),
        ));
    }
    entries.extend(machine_items(shell, &shell_state.machines));
    entries.push(add_machine_item(shell));
    entries
}

/// "Add Machine…": always listed, and last in the "Terminal on Machine…" picker.
pub fn add_machine_item(shell: &Entity<Shell>) -> PaletteEntry {
    entry(
        searchable(
            spec(
                "add-machine",
                IconName::Plus,
                "Add Machine…",
                "Add a computer reached over SSH, then open terminals on it",
                Vec::new(),
            ),
            "ssh remote server host machine",
        ),
        command(shell, Command::AddMachine),
    )
}

/// "New Terminal on <machine>" for every `machines` entry of settings.json; also the
/// "Terminal on Machine…" picker.
pub fn machine_items(shell: &Entity<Shell>, machines: &[Machine]) -> Vec<PaletteEntry> {
    machines
        .iter()
        .map(|machine| {
            let description =
                format!("Open a terminal on {} over SSH beside the focused pane", machine.destination());
            entry(
                spec(
                    &format!("new-terminal-on-{}", machine.name),
                    IconName::Server,
                    &format!("New Terminal on {}", machine.name),
                    &description,
                    Vec::new(),
                ),
                command(shell, Command::NewTerminalOn(machine.name.clone())),
            )
        })
        .collect()
}

/// "Switch Session…": every session of the workspace.
pub fn session_items(workspace: &WorkspaceHandle, cx: &App) -> Vec<PaletteEntry> {
    let ws = workspace.read(cx);
    ws.ordered_sessions()
        .into_iter()
        .map(|session| {
            let windows = ws.ordered_windows_in(&session.id);
            let current = if session.id == ws.active_session_id() { "Current · " } else { "" };
            let description =
                format!("{current}{} window{}", windows.len(), if windows.len() == 1 { "" } else { "s" });
            let search = windows.iter().map(|w| w.title.clone()).collect::<Vec<_>>().join(" ");
            let id = session.id.clone();
            let handle = workspace.clone();
            PaletteEntry {
                item: PickerItem::new(format!("activate-{}", session.id), session.name.clone())
                    .icon(IconName::Layers)
                    .description(description)
                    .search_text(search),
                action: Rc::new(move |_, _, cx| handle.update(cx, |ws| ws.activate_session(&id))),
            }
        })
        .collect()
}

/// "Find Window…": the active session's windows; a query that found a pane tab rather than
/// the window's own title lands on that tab.
pub fn window_items(workspace: &WorkspaceHandle, shell: &Entity<Shell>, cx: &App) -> Vec<PaletteEntry> {
    let ws = workspace.read(cx);
    let shell = shell.read(cx);
    ws.active_session_windows()
        .into_iter()
        .enumerate()
        .map(|(index, window)| {
            let panes = ws.ordered_panes(&window.id);
            let active_title = ws
                .pane(window.active_pane_id())
                .and_then(|pane| pane.active_tab())
                .map(|tab| tab.title.clone())
                .unwrap_or_else(|| "No active pane".into());
            let current = if window.id == ws.active_window_id() { "Current · " } else { "" };
            let count = panes.len();
            let description = format!(
                "{current}{count} pane{} · Active: {active_title}",
                if count == 1 { "" } else { "s" }
            );
            let search = panes
                .iter()
                .flat_map(|pane| pane.tabs.iter().flat_map(|tab| tab.search_terms()))
                .collect::<Vec<_>>()
                .join(" ");
            let shortcut = if index < 9 {
                shell.shortcut(&[&format!("select-window-{}", index + 1)])
            } else {
                Vec::new()
            };
            let window_id = window.id.clone();
            let title = window.title.clone();
            let handle = workspace.clone();
            PaletteEntry {
                item: PickerItem::new(format!("activate-{}", window.id), window.title.clone())
                    .icon(IconName::AppWindow)
                    .description(description)
                    .keycaps(shortcut)
                    .search_text(search),
                action: Rc::new(move |query, _, cx| {
                    handle.update(cx, |ws| {
                        let found = soprano_ui::picker::match_range(&title, query)
                            .is_none()
                            .then(|| ws.first_tab_matching(&window_id, query))
                            .flatten();
                        match found {
                            Some(target) => ws.focus_tab(&target.pane_id, &target.tab_id, false),
                            None => ws.activate_window(&window_id),
                        }
                    })
                }),
            }
        })
        .collect()
}

/// A project folder under one of the `projectDirectories`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProjectEntry {
    pub name: String,
    pub path: String,
}

/// The direct, non-hidden subfolders of every configured root, one per path, by name
/// (case-insensitively, then by path).
pub fn projects(roots: &[String]) -> Vec<ProjectEntry> {
    let mut by_path = std::collections::BTreeMap::new();
    for root in roots {
        let root = soprano_config::expand_path(root);
        let Ok(children) = std::fs::read_dir(Path::new(&root)) else { continue };
        for child in children.flatten() {
            let name = child.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || !child.path().is_dir() {
                continue;
            }
            let path =
                soprano_model::file_url::standardized_path(&child.path()).to_string_lossy().into_owned();
            by_path.insert(path.clone(), ProjectEntry { name, path });
        }
    }
    let mut projects: Vec<ProjectEntry> = by_path.into_values().collect();
    projects.sort_by(|a, b| {
        a.name
            .to_lowercase()
            .cmp(&b.name.to_lowercase())
            .then_with(|| a.path.to_lowercase().cmp(&b.path.to_lowercase()))
    });
    projects
}

/// "Open Project…": each project opens a terminal there; the last row picks any folder.
pub fn project_items(
    workspace: &WorkspaceHandle,
    roots: &[String],
    choose_directory: PaletteAction,
) -> Vec<PaletteEntry> {
    let mut entries: Vec<PaletteEntry> = projects(roots)
        .into_iter()
        .map(|project| {
            let handle = workspace.clone();
            let path = project.path.clone();
            PaletteEntry {
                item: PickerItem::new(format!("open-project-{}", project.path), project.name)
                    .icon(IconName::Folder)
                    .description(project.path),
                action: Rc::new(move |_, _, cx| {
                    handle.update(cx, |ws| {
                        ws.spawn_terminal(Some(&path));
                    })
                }),
            }
        })
        .collect();
    entries.push(PaletteEntry {
        item: PickerItem::new("choose-project-directory", "Choose Directory…")
            .icon(IconName::FolderPlus)
            .description("Open a terminal in any directory"),
        action: choose_directory,
    });
    entries
}

/// Row id for opening a new window in the active tab's place (e.g. a remote machine or default shell).
pub const NEW_WINDOW_CURRENT_ID: &str = "new-window-current";
/// Row id for opening the native OS folder chooser for a new window.
pub const NEW_WINDOW_CHOOSE_ID: &str = "new-window-choose-directory";
/// Row id prefix for a concrete local directory path.
pub const NEW_WINDOW_PATH_PREFIX: &str = "path:";

/// Maximum number of dynamic subdirectory completions shown while typing a path.
const MAX_PATH_COMPLETIONS: usize = 50;

fn folder_display_name(path: &str) -> String {
    Path::new(path)
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| path.to_owned())
}

fn ends_with_separator(raw: &str) -> bool {
    raw.ends_with('/') || (cfg!(windows) && raw.ends_with('\\'))
}

fn looks_like_path(raw: &str) -> bool {
    raw == "~"
        || raw == "."
        || raw == ".."
        || raw.starts_with("~/")
        || raw.starts_with('/')
        || raw.starts_with("./")
        || raw.starts_with("../")
        || raw.contains('/')
        || (cfg!(windows)
            && (raw.starts_with("~\\")
                || raw.starts_with(".\\")
                || raw.starts_with("..\\")
                || raw.contains('\\')
                || Path::new(raw).is_absolute()))
}

fn resolve_typed_path(raw: &str, base_dir: Option<&Path>) -> Option<PathBuf> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let expanded = soprano_platform::paths::expand_tilde(trimmed);
    let absolute = if expanded.is_absolute() { expanded } else { base_dir?.join(expanded) };
    Some(soprano_platform::paths::normalize(&absolute))
}

fn directory_picker_item(path: &Path, icon: IconName) -> (String, PickerItem) {
    let std_path = soprano_model::file_url::standardized_path(path).to_string_lossy().into_owned();
    let label = folder_display_name(&std_path);
    let description = soprano_config::config_file::abbreviating_home(&std_path);
    let item = PickerItem::new(format!("{NEW_WINDOW_PATH_PREFIX}{std_path}"), label)
        .icon(icon)
        .description(description)
        .search_text(std_path.clone());
    (std_path, item)
}

/// "New Window…": current directory first, then open workspace folders, then configured
/// `projectDirectories` subfolders, then the native folder chooser.
pub fn new_window_items(workspace: &Workspace, roots: &[String]) -> Vec<PickerItem> {
    let mut items = Vec::new();
    let mut seen = HashSet::new();

    let active_machine = workspace.machine_of_pane(workspace.active_pane_id()).map(str::to_owned);
    let active_cwd = workspace.active_working_directory();
    if let Some(machine) = active_machine {
        let label =
            active_cwd.as_deref().map(folder_display_name).unwrap_or_else(|| "Current Directory".to_owned());
        let description = match &active_cwd {
            Some(cwd) => format!("Current · {machine}:{cwd}"),
            None => format!("Current · on {machine}"),
        };
        items.push(
            PickerItem::new(NEW_WINDOW_CURRENT_ID, label)
                .icon(IconName::Server)
                .description(description)
                .group("Current")
                .search_text(format!(
                    "current directory active here {machine} {}",
                    active_cwd.as_deref().unwrap_or("")
                )),
        );
    } else if let Some(cwd) = active_cwd {
        let std_path =
            soprano_model::file_url::standardized_path(Path::new(&cwd)).to_string_lossy().into_owned();
        seen.insert(std_path.clone());
        let label = folder_display_name(&std_path);
        let abbrev = soprano_config::config_file::abbreviating_home(&std_path);
        items.push(
            PickerItem::new(format!("{NEW_WINDOW_PATH_PREFIX}{std_path}"), label)
                .icon(IconName::Folder)
                .description(format!("Current · {abbrev}"))
                .group("Current")
                .search_text(format!("current directory active here {std_path}")),
        );
    } else {
        items.push(
            PickerItem::new(NEW_WINDOW_CURRENT_ID, "Current Directory")
                .icon(IconName::Folder)
                .description("Default shell directory")
                .group("Current")
                .search_text("current directory active here default home"),
        );
    }

    let open_dirs = workspace
        .ordered_windows()
        .into_iter()
        .flat_map(|window| workspace.ordered_panes(&window.id))
        .flat_map(|pane| pane.tabs.iter())
        .filter(|tab| tab.pane_type != PaneType::Browser && tab.remote.is_none())
        .filter_map(|tab| tab.cwd.as_deref())
        .map(|cwd| {
            soprano_model::file_url::standardized_path(&Workspace::project_root(cwd))
                .to_string_lossy()
                .into_owned()
        });
    for path in open_dirs {
        if seen.insert(path.clone()) {
            let abbrev = soprano_config::config_file::abbreviating_home(&path);
            items.push(
                PickerItem::new(format!("{NEW_WINDOW_PATH_PREFIX}{path}"), folder_display_name(&path))
                    .icon(IconName::Folder)
                    .description(abbrev)
                    .group("Open")
                    .search_text(path),
            );
        }
    }

    for project in projects(roots) {
        if seen.insert(project.path.clone()) {
            let abbrev = soprano_config::config_file::abbreviating_home(&project.path);
            items.push(
                PickerItem::new(format!("{NEW_WINDOW_PATH_PREFIX}{}", project.path), project.name)
                    .icon(IconName::Folder)
                    .description(abbrev)
                    .group("Projects")
                    .search_text(project.path),
            );
        }
    }

    items.push(
        PickerItem::new(NEW_WINDOW_CHOOSE_ID, "Choose Directory…")
            .icon(IconName::FolderPlus)
            .description("Browse for any folder")
            .group("Other")
            .search_text("choose directory browse finder folder open path"),
    );

    items
}

/// Dynamic directory matches for a path typed into the New Window picker.
///
/// Resolves `~`, absolute paths, and paths relative to `base_dir`, listing the exact directory
/// when it exists plus matching subdirectories when typing a partial path or trailing separator.
pub fn directory_query_items(query: &str, base_dir: Option<&Path>) -> Vec<PickerItem> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }
    let trailing_sep = ends_with_separator(trimmed);
    let path_like = looks_like_path(trimmed);
    let Some(resolved) = resolve_typed_path(trimmed, base_dir) else {
        return Vec::new();
    };

    let mut items = Vec::new();
    let mut seen = HashSet::new();
    let mut push_dir = |dir: &Path, icon: IconName| {
        let (std_path, item) = directory_picker_item(dir, icon);
        if seen.insert(std_path) {
            items.push(item);
        }
    };

    if trailing_sep {
        if resolved.is_dir() {
            push_dir(&resolved, IconName::FolderOpen);
            if let Ok(children) = std::fs::read_dir(&resolved) {
                let mut dirs: Vec<(String, PathBuf)> = children
                    .flatten()
                    .filter_map(|entry| {
                        let name = entry.file_name().to_string_lossy().into_owned();
                        if name.starts_with('.') || !entry.path().is_dir() {
                            return None;
                        }
                        Some((name, entry.path()))
                    })
                    .collect();
                dirs.sort_by_key(|a| a.0.to_lowercase());
                for (_, child) in dirs.into_iter().take(MAX_PATH_COMPLETIONS) {
                    push_dir(&child, IconName::Folder);
                }
            }
        }
        return items;
    }

    if resolved.is_dir() {
        push_dir(&resolved, IconName::FolderOpen);
    }

    if path_like
        && !matches!(trimmed, "~" | "/" | "." | "..")
        && let (Some(parent), Some(prefix)) =
            (resolved.parent(), resolved.file_name().and_then(|name| name.to_str()))
        && parent.is_dir()
    {
        let include_hidden = prefix.starts_with('.');
        let needle = prefix.to_lowercase();
        if let Ok(children) = std::fs::read_dir(parent) {
            let mut matches: Vec<(bool, String, PathBuf)> = children
                .flatten()
                .filter_map(|entry| {
                    let name = entry.file_name().to_string_lossy().into_owned();
                    if (!include_hidden && name.starts_with('.')) || !entry.path().is_dir() {
                        return None;
                    }
                    let lower = name.to_lowercase();
                    if !lower.contains(&needle) {
                        return None;
                    }
                    let is_prefix = lower.starts_with(&needle);
                    Some((!is_prefix, lower, entry.path()))
                })
                .collect();
            matches.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
            for (_, _, child) in matches.into_iter().take(MAX_PATH_COMPLETIONS) {
                push_dir(&child, IconName::Folder);
            }
        }
    }

    items
}

/// Tab-completes a directory row in the New Window picker into an abbreviated path ending with a
/// separator so its subdirectories appear immediately.
pub fn directory_tab_completion(item: &PickerItem) -> Option<String> {
    let path = item.id.strip_prefix(NEW_WINDOW_PATH_PREFIX)?;
    let mut completed = soprano_config::config_file::abbreviating_home(path);
    if !ends_with_separator(&completed) {
        completed.push(std::path::MAIN_SEPARATOR);
    }
    Some(completed)
}

/// An agent row: title, subtitle, search text, keycaps, and what it opens.
type AgentRow = (String, String, String, Vec<String>, Box<dyn Fn(&mut Workspace)>);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn projects_list_each_visible_subfolder_once_sorted_by_name() {
        let first = tempfile::tempdir().expect("temp");
        let second = tempfile::tempdir().expect("temp");
        for name in ["beta", "Alpha", ".hidden"] {
            std::fs::create_dir(first.path().join(name)).expect("dir");
        }
        std::fs::write(first.path().join("file.txt"), "").expect("file");
        std::fs::create_dir(second.path().join("alpha")).expect("dir");
        let roots = vec![
            first.path().to_string_lossy().into_owned(),
            second.path().to_string_lossy().into_owned(),
            first.path().to_string_lossy().into_owned(),
            "/no/such/root".to_owned(),
        ];
        let names: Vec<String> = projects(&roots).into_iter().map(|p| p.name).collect();
        // Names compare case-insensitively; equal names fall back to their paths.
        let lowered: Vec<String> = names.iter().map(|n| n.to_lowercase()).collect();
        assert_eq!(lowered, ["alpha", "alpha", "beta"]);
        assert_eq!(names.len(), 3);
    }

    #[test]
    fn new_window_items_put_current_directory_first_then_open_and_configured_projects() {
        let root = tempfile::tempdir().expect("temp");
        for name in ["alpha", "beta"] {
            std::fs::create_dir_all(root.path().join(name).join(".git")).expect("project");
        }
        let current = tempfile::tempdir().expect("temp");
        let path_str =
            |p: &Path| soprano_model::file_url::standardized_path(p).to_string_lossy().into_owned();
        let current_path = path_str(current.path());
        let beta_path = path_str(&root.path().join("beta"));
        let alpha_path = path_str(&root.path().join("alpha"));

        let mut workspace = Workspace::new();
        workspace.spawn_terminal(Some(&beta_path)).expect("beta pane");
        workspace.spawn_terminal(Some(&current_path)).expect("current pane");

        let items = new_window_items(&workspace, &[root.path().to_string_lossy().into_owned()]);
        let ids: Vec<&str> = items.iter().map(|item| item.id.as_ref()).collect();
        assert_eq!(
            ids,
            [
                format!("{NEW_WINDOW_PATH_PREFIX}{current_path}").as_str(),
                format!("{NEW_WINDOW_PATH_PREFIX}{beta_path}").as_str(),
                format!("{NEW_WINDOW_PATH_PREFIX}{alpha_path}").as_str(),
                NEW_WINDOW_CHOOSE_ID,
            ]
        );
        assert!(items[0].description.starts_with("Current · "));
        assert_eq!(items[0].group.as_deref(), Some("Current"));
        assert_eq!(items[1].group.as_deref(), Some("Open"));
        assert_eq!(items[2].group.as_deref(), Some("Projects"));
        assert_eq!(items[3].group.as_deref(), Some("Other"));
    }

    #[test]
    fn new_window_items_preserve_remote_active_place_without_listing_it_as_local() {
        let mut workspace = Workspace::new();
        workspace.spawn_terminal_on("vps").expect("remote pane");
        let items = new_window_items(&workspace, &[]);
        assert_eq!(items[0].id.as_ref(), NEW_WINDOW_CURRENT_ID);
        assert!(items[0].description.contains("vps"));
    }

    #[test]
    fn directory_query_items_resolve_typed_paths_and_complete_subdirectories() {
        let root = tempfile::tempdir().expect("temp");
        let alpha = root.path().join("alpha");
        let alpha_two = root.path().join("alpha-two");
        let beta = root.path().join("beta");
        let hidden = root.path().join(".secret");
        for dir in [&alpha, &alpha_two, &beta, &hidden] {
            std::fs::create_dir(dir).expect("dir");
        }
        std::fs::write(root.path().join("alpha-file.txt"), "").expect("file");

        let std = |p: &Path| {
            format!(
                "{NEW_WINDOW_PATH_PREFIX}{}",
                soprano_model::file_url::standardized_path(p).to_string_lossy()
            )
        };

        // Trailing separator lists the directory itself followed by visible subdirectories.
        let listed = directory_query_items(&format!("{}/", root.path().display()), None);
        let listed_ids: Vec<&str> = listed.iter().map(|i| i.id.as_ref()).collect();
        assert_eq!(listed_ids, [std(root.path()), std(&alpha), std(&alpha_two), std(&beta)]);

        // Partial path completes matching subdirectories (files and hidden dirs excluded).
        let partial = directory_query_items(&format!("{}/alp", root.path().display()), None);
        let partial_ids: Vec<&str> = partial.iter().map(|i| i.id.as_ref()).collect();
        assert_eq!(partial_ids, [std(&alpha), std(&alpha_two)]);

        // Explicit dot prefix includes hidden directories.
        let dot = directory_query_items(&format!("{}/.sec", root.path().display()), None);
        let dot_ids: Vec<&str> = dot.iter().map(|i| i.id.as_ref()).collect();
        assert_eq!(dot_ids, [std(&hidden)]);

        // Relative path resolves against base_dir.
        let relative = directory_query_items("./beta", Some(root.path()));
        let relative_ids: Vec<&str> = relative.iter().map(|i| i.id.as_ref()).collect();
        assert_eq!(relative_ids, [std(&beta)]);

        // Non-existent path yields no dynamic entries.
        let missing = directory_query_items(&format!("{}/nope", root.path().display()), None);
        assert!(missing.is_empty());
    }

    #[test]
    fn directory_tab_completion_abbreviates_home_and_appends_separator() {
        let home = soprano_platform::paths::home_dir();
        let sub = home.join("projects");
        let item = PickerItem::new(format!("{NEW_WINDOW_PATH_PREFIX}{}", sub.display()), "projects");
        assert_eq!(
            directory_tab_completion(&item),
            Some(format!("~{sep}projects{sep}", sep = std::path::MAIN_SEPARATOR))
        );
        assert_eq!(directory_tab_completion(&PickerItem::new(NEW_WINDOW_CHOOSE_ID, "Choose")), None);
    }
}
