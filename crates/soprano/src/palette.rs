//! The command palette's items (`MainWindowController.buildCommandPaletteItems`) and the window,
//! session and project pickers (`buildWindowPaletteItems`, `buildSessionPaletteItems`,
//! `buildProjectPaletteItems`). The picker widget is soprano-ui's; this module decides what it
//! lists and what each row does.

use std::path::{Path, PathBuf};
use std::rc::Rc;

use gpui::{App, Entity, Window};
use soprano_launch::ChatLaunch;
use soprano_model::{PaneContentKind, PaneType, Workspace};
use soprano_types::AgentCatalog;
use soprano_ui::{IconName, PickerItem};

use crate::shell::{CloseTarget, Command, Shell, dispatch};
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

    // One launcher per agent in the catalog.
    for profile in &profiles {
        let id = profile.id.clone();
        entries.push(entry(
            spec(
                &format!("launch-{}", profile.id),
                IconName::Command,
                &format!("Launch {}", profile.name),
                &format!("Launch the {} agent", profile.name),
                short(&[&format!("launch-{}", profile.id)]),
            ),
            mutate(workspace, move |ws| {
                ws.spawn_agent(&id, None, false);
            }),
        ));
    }
    // Each agent as a tab of the focused pane.
    for profile in &profiles {
        let id = profile.id.clone();
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
                ws.add_tab_to_pane(&pane, PaneType::Agent, Some(&id), None);
            }),
        ));
        if let Some(last) = entries.last_mut() {
            last.item = last.item.clone().search_text(search);
        }
    }
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
                "New Window",
                "Create a new logical window",
                short(&["new-window"]),
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
            command(shell, Command::OpenMarkdown { pane_id: None }),
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
                    dispatch(&shell, Command::OpenMarkdown { pane_id: Some(pane) }, cx);
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
                    "Monitor every agent across all windows",
                    short(&["agent-dashboard"]),
                ),
                "agents monitor status attention working",
            ),
            command(shell, Command::OpenDashboard),
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
    entries
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
}
