//! The left sidebar (`Views/SidebarView.swift`) in Herdr's frame (HERDR-UI §5, SHELL-MAP): the
//! brand row with the session switcher, Search and the sidebar toggle; the active session's
//! windows with their panes tab by tab; every agent of the session grouped by what it needs;
//! the Automations, Statistics and Settings rows. App-level work goes out as [`Command`]s; plain model
//! changes (activate, focus, collapse, spawn) go through the [`WorkspaceHandle`].

mod model;

pub use model::watched_cwds;

use std::time::{Duration, SystemTime};

use gpui::{
    AnyElement, App, Context, ElementId, Entity, FontWeight, Hsla, IntoElement, ParentElement, Pixels, Point,
    Render, ScrollHandle, SharedString, Styled, Subscription, Task, WeakEntity, Window, div, img, prelude::*,
    px,
};
use gpui_component::scroll::ScrollbarMode;
use soprano_agents::dashboard::AgentDashboardSection;
use soprano_launch::ChatLaunch;
use soprano_model::WorkspaceSession;
use soprano_text::context_line::{ContextLine, ContextPart};
use soprano_types::AgentCatalog;
use soprano_ui::button::IconButtonSize;
use soprano_ui::keycaps::KeyPlatform;
use soprano_ui::status::StatusClock;
use soprano_ui::tooltip::tooltip;
use soprano_ui::{
    ActiveSopranoTheme, Avatar, ContextMenu, Icon, IconButton, IconName, Keycaps, MenuItem, ScrollList,
    SectionHeader, SidebarRow, SopranoTheme, StatusPill, agent_icon_stem, icon, project_color,
};

use self::model::{
    AgentRow, Hints, ListInput, ListRow, PaneKind, PaneRow, RevealTracker, RowModel, TrailingSlot, WindowRow,
};
use crate::services::Services;
use crate::shell::{self, CloseTarget, Command, Page, Shell};
use crate::window_chrome;
use crate::workspace::WorkspaceHandle;

/// Herdr's brand row (§5.1).
const BRAND_HEIGHT: f32 = 46.0;
/// The brand row's left padding when no traffic lights sit there.
const BRAND_INSET: f32 = 14.0;
/// Window rows: a 15 px chevron, then the 18 px avatar (gap 9, px 8); the guide runs under the
/// avatar's middle and pane rows start right of it, their icon under the window's title.
const GUIDE_X: f32 = 41.0;
const PANE_INDENT: f32 = 50.0;
/// The guide starts and ends this far above the bottom of its first and last rows.
const GUIDE_INSET: f32 = 6.0;
const ONE_LINE_ROW: f32 = 30.0;
const TWO_LINE_ROW: f32 = 44.0;

pub struct Sidebar {
    this: WeakEntity<Self>,
    workspace: WorkspaceHandle,
    shell: Entity<Shell>,
    services: Services,
    windows_scroll: ScrollHandle,
    agents_scroll: ScrollHandle,
    reveal: RevealTracker,
    /// The working directories the branch monitor watches.
    watched: Vec<String>,
    home: String,
    /// Ticks live durations ("Working 2m", "5m") once a second while a row shows one.
    clock_task: Option<Task<()>>,
    _branch_task: Task<()>,
    _subscriptions: Vec<Subscription>,
}

impl Sidebar {
    pub fn new(
        workspace: WorkspaceHandle,
        shell: Entity<Shell>,
        services: Services,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let subscriptions = vec![
            cx.observe(&workspace.model, |_, _, cx| cx.notify()),
            cx.observe(&shell, |_, _, cx| cx.notify()),
            cx.observe(&services.sessions, |_, _, cx| cx.notify()),
            cx.observe_global::<SopranoTheme>(|_, cx| cx.notify()),
        ];
        // A HEAD changing on disk re-reads the rows' branches.
        let (changed, branch_changes) = async_channel::unbounded::<()>();
        services.branches.set_on_change(move || {
            let _ = changed.try_send(());
        });
        let branch_task = cx.spawn(async move |this, cx| {
            while branch_changes.recv().await.is_ok() {
                if this.update(cx, |_, cx| cx.notify()).is_err() {
                    break;
                }
            }
        });
        Self {
            this: cx.weak_entity(),
            workspace,
            shell,
            services,
            windows_scroll: ScrollHandle::new(),
            agents_scroll: ScrollHandle::new(),
            reveal: RevealTracker::default(),
            watched: Vec::new(),
            home: soprano_platform::paths::home_dir().to_string_lossy().into_owned(),
            clock_task: None,
            _branch_task: branch_task,
            _subscriptions: subscriptions,
        }
    }

    fn update_clock(&mut self, live: bool, cx: &mut Context<Self>) {
        if !live {
            self.clock_task = None;
            return;
        }
        if self.clock_task.is_some() {
            return;
        }
        self.clock_task = Some(cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(Duration::from_secs(1)).await;
                if this.update(cx, |_, cx| cx.notify()).is_err() {
                    break;
                }
            }
        }));
    }

    // MARK: - Menus

    /// The session switcher: every session (the active one checked), New / Rename / Close,
    /// then the saved workspaces (load or delete each) and Save Workspace As….
    fn session_menu(&self, cx: &App) -> Vec<MenuItem> {
        let ws = self.workspace.read(cx);
        let mut items: Vec<MenuItem> = ws
            .ordered_sessions()
            .into_iter()
            .map(|session| {
                let workspace = self.workspace.clone();
                let id = session.id.clone();
                MenuItem::new(session.name.clone())
                    .checked(session.id == ws.active_session_id())
                    .on_select(move |_, cx| workspace.update(cx, |ws| ws.activate_session(&id)))
            })
            .collect();
        items.push(MenuItem::separator());
        for (title, command) in [
            ("New Session…", Command::NewSession),
            ("Rename Session…", Command::RenameSession),
            ("Close Session…", Command::CloseSession),
        ] {
            items.push(self.command_item(title, command));
        }
        items.push(MenuItem::separator());
        items.push(MenuItem::header("Saved Workspaces"));
        let saved = self.services.sessions.read(cx).sessions();
        if saved.is_empty() {
            items.push(MenuItem::new("No Saved Workspaces").disabled(true));
        }
        for session in saved {
            let sessions = self.services.sessions.clone();
            let id = session.id.clone();
            items.push(MenuItem::submenu(
                saved_workspace_label(session),
                vec![
                    self.command_item("Load", Command::LoadWorkspace(session.id.clone())),
                    MenuItem::new("Delete").on_select(move |_, cx| {
                        sessions.update(cx, |manager, cx| {
                            manager.delete_session(&id);
                            cx.notify();
                        })
                    }),
                ],
            ));
        }
        items.push(MenuItem::separator());
        items.push(self.command_item("Save Workspace As…", Command::SaveWorkspaceAs));
        items
    }

    /// The Windows header's "+": a window, a pane of each agent (and each chat agent), a
    /// terminal (here and on each machine), a browser, a Markdown file (`plusClicked`).
    fn new_menu(&self, cx: &App) -> Vec<MenuItem> {
        let mut items = vec![self.spawn_item("New Window".into(), |ws| _ = ws.create_window(None, None))];
        items.push(MenuItem::separator());
        for profile in AgentCatalog::shared().all().into_iter().filter(|p| p.id != "terminal") {
            let id = profile.id.clone();
            items.push(self.spawn_item(format!("New {} Pane", profile.name), move |ws| {
                _ = ws.spawn_agent(&id, None, false)
            }));
        }
        for profile in ChatLaunch::chat_profiles() {
            let id = profile.id.clone();
            items.push(self.spawn_item(format!("New {} Chat Pane", profile.name), move |ws| {
                _ = ws.spawn_agent(&id, None, true)
            }));
        }
        items.push(MenuItem::separator());
        items.push(self.spawn_item("New Terminal Pane".into(), |ws| _ = ws.spawn_terminal(None)));
        for machine in &self.shell.read(cx).machines {
            let name = machine.name.clone();
            items.push(
                self.spawn_item(format!("New Terminal on {name}"), move |ws| _ = ws.spawn_terminal_on(&name)),
            );
        }
        items.push(self.command_item("Add Machine…", Command::AddMachine));
        items.push(self.spawn_item("New Browser Pane".into(), |ws| _ = ws.spawn_browser(None)));
        items.push(self.command_item("Open Markdown…", Command::OpenMarkdown { pane_id: None }));
        items
    }

    fn spawn_item(&self, title: String, spawn: impl Fn(&mut soprano_model::Workspace) + 'static) -> MenuItem {
        let workspace = self.workspace.clone();
        MenuItem::new(title).on_select(move |_, cx| workspace.update(cx, |ws| spawn(ws)))
    }

    /// A window row's context menu.
    fn window_menu(&self, row: &WindowRow) -> Vec<MenuItem> {
        let mut items =
            vec![self.command_item("Rename Window…", Command::RenameWindow(Some(row.id.clone())))];
        if row.is_title_custom {
            let workspace = self.workspace.clone();
            let id = row.id.clone();
            items.push(
                MenuItem::new("Reset to Automatic Name")
                    .on_select(move |_, cx| workspace.update(cx, |ws| ws.reset_window_title(&id))),
            );
        }
        items.push(MenuItem::separator());
        items.push(self.command_item("Close Window", Command::Close(CloseTarget::Window(row.id.clone()))));
        items
    }

    fn command_item(&self, title: &'static str, command: Command) -> MenuItem {
        let shell = self.shell.clone();
        MenuItem::new(title).on_select(move |_, cx| shell::dispatch(&shell, command.clone(), cx))
    }

    /// Opens the menu `build` makes at the pointer, built when it opens.
    fn menu_handler(
        &self,
        build: impl Fn(&Sidebar, &App) -> Vec<MenuItem> + 'static,
    ) -> impl Fn(Point<Pixels>, &mut Window, &mut App) + 'static {
        let (this, shell) = (self.this.clone(), self.shell.clone());
        move |position, window, cx| {
            let Ok(items) = this.read_with(cx, |sidebar, cx| build(sidebar, cx)) else { return };
            let menu = ContextMenu::new(position, items, window, cx);
            shell.update(cx, |shell, cx| shell.show_popup(menu, window, cx));
        }
    }

    // MARK: - Brand row

    fn brand_row(&self, inset: f32, session_name: SharedString, cx: &App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let z = |v: f32| theme.z(v);
        let hover = theme.hover;
        let show_sessions = self.menu_handler(|sidebar, cx| sidebar.session_menu(cx));
        let session = div()
            .id("session-selector")
            .flex()
            .flex_row()
            .items_center()
            .min_w_0()
            .gap(z(8.))
            .h(z(26.))
            .px(z(6.))
            .rounded(z(6.))
            .cursor_pointer()
            .hover(move |s| s.bg(hover))
            .on_mouse_down(gpui::MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .on_click(move |event, window, cx| show_sessions(event.position(), window, cx))
            .tooltip(tooltip("Current Session"))
            .child(img("icons/app-icon.png").flex_none().size(z(20.)).rounded(z(5.)))
            .child(div().min_w_0().truncate().font_weight(FontWeight::SEMIBOLD).child(session_name))
            .child(icon(IconName::ChevronDown).size(11.).color(theme.dim));
        let shell = self.shell.clone();
        let toggle_shell = self.shell.clone();
        window_chrome::window_drag_region(div().id("sidebar-brand"))
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .h(z(BRAND_HEIGHT))
            .pl(z(inset))
            .pr(z(10.))
            .gap(z(4.))
            .text_size(z(13.5))
            .text_color(theme.foreground)
            .child(div().flex().flex_row().flex_1().min_w_0().child(session))
            .when(shows_commands_button(), |row| {
                let show_commands = self.menu_handler(|sidebar, _| sidebar.commands_menu());
                row.child(
                    IconButton::new("sidebar-commands", IconName::Ellipsis)
                        .tooltip("Commands")
                        .on_click(move |event, window, cx| show_commands(event.position(), window, cx)),
                )
            })
            .child(
                IconButton::new("sidebar-search", IconName::Search)
                    .tooltip("Find Window")
                    .on_click(move |_, _, cx| shell::dispatch(&shell, Command::FindWindow, cx)),
            )
            .child(
                IconButton::new("sidebar-toggle", IconName::Sidebar)
                    .tooltip("Toggle Sidebar")
                    .on_click(move |_, _, cx| shell::dispatch(&toggle_shell, Command::ToggleSidebar, cx)),
            )
    }

    /// The Commands menu macOS keeps in its menu bar; Linux and Windows open it here.
    fn commands_menu(&self) -> Vec<MenuItem> {
        crate::menus::commands_menu_items()
            .into_iter()
            .map(|(title, command)| self.command_item(title, command))
            .collect()
    }

    // MARK: - Windows

    fn windows_header(&self, count: usize, can_collapse: bool, cx: &App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let workspace = self.workspace.clone();
        let show_new = self.menu_handler(|sidebar, cx| sidebar.new_menu(cx));
        SectionHeader::new("sidebar-windows-header", "Windows").count(count).end_slot(
            div()
                .flex()
                .flex_row()
                .items_center()
                .child(
                    div().debug_selector(|| "sidebar-collapse-all".into()).child(
                        IconButton::new("sidebar-collapse-all", IconName::ChevronsUpDown)
                            .icon_size(14.)
                            .color(theme.dim)
                            .disabled(!can_collapse)
                            .tooltip("Collapse All Windows")
                            .on_click(move |_, _, cx| {
                                workspace.update(cx, |ws| ws.collapse_all_sidebar_windows())
                            }),
                    ),
                )
                .child(
                    IconButton::new("sidebar-new", IconName::Plus)
                        .icon_size(14.)
                        .color(theme.dim)
                        .tooltip("New Window or Pane")
                        .on_click(move |event, window, cx| show_new(event.position(), window, cx)),
                ),
        )
    }

    fn window_row(&self, row: &WindowRow, gap: f32, platform: KeyPlatform, cx: &App) -> AnyElement {
        let theme = cx.soprano_theme();
        let z = |v: f32| theme.z(v);
        let group: SharedString = format!("sidebar-window-{}", row.id).into();
        let toggle = {
            let workspace = self.workspace.clone();
            let id = row.id.clone();
            move |cx: &mut App| workspace.update(cx, |ws| ws.toggle_sidebar_window_collapsed(&id))
        };
        let chevron_toggle = toggle.clone();
        let chevron_label = if row.expanded { "Collapse Window" } else { "Expand Window" };
        let chevron = IconButton::new(
            ElementId::Name(format!("sidebar-window-disclosure-{}", row.id).into()),
            if row.expanded { IconName::ChevronDown } else { IconName::ChevronRight },
        )
        .size(IconButtonSize::Tab)
        .icon_size(11.)
        .color(theme.dim)
        .tooltip(chevron_label)
        .on_click(move |_, _, cx| {
            cx.stop_propagation();
            chevron_toggle(cx)
        });
        let avatar = match row.number {
            Some(number) => Avatar::new(number.to_string()),
            None => Avatar::new(row.title.clone()),
        }
        .color(project_color(&row.title, cx));
        let foreground = theme.foreground;
        let title = div()
            .flex_1()
            .min_w_0()
            .truncate()
            .text_color(if row.active { theme.foreground } else { theme.muted })
            .group_hover(group.clone(), move |s| s.text_color(foreground))
            .child(row.title.clone());
        let trailing = self.trailing(
            &group,
            row.shows_number_hint,
            || {
                let number = row.number.unwrap_or_default();
                div()
                    .id(ElementId::Name(format!("sidebar-jump-window-{}", row.id).into()))
                    .tooltip(tooltip(format!("Ctrl+{number}")))
                    .child(Keycaps::new([model::window_number_cap(number, platform)]).small())
                    .into_any_element()
            },
            || {
                div()
                    .id(ElementId::Name(format!("sidebar-window-counts-{}", row.id).into()))
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(z(6.))
                    .tooltip(tooltip(row.counts_tooltip()))
                    .children(row.agent_badge.map(soprano_ui::status::TabBadgeView::new))
                    .children(row.running_badge.map(soprano_ui::status::TabBadgeView::new))
                    .into_any_element()
            },
            self.close_button(
                format!("sidebar-window-close-{}", row.id),
                "Close Window",
                Command::Close(CloseTarget::Window(row.id.clone())),
                cx,
            ),
            cx,
        );
        let select = {
            let workspace = self.workspace.clone();
            let shell = self.shell.clone();
            let id = row.id.clone();
            move |click_count: usize, cx: &mut App| {
                if click_count >= 2 {
                    toggle(cx);
                } else {
                    shell::dispatch(&shell, Command::LeavePage, cx);
                    workspace.update(cx, |ws| ws.activate_window(&id));
                }
            }
        };
        div()
            .group(group)
            .mt(z(gap))
            .child(
                SidebarRow::new(ElementId::Name(format!("sidebar-window-row-{}", row.id).into()))
                    .child(chevron)
                    .child(avatar)
                    .child(title)
                    .child(trailing)
                    .on_click(move |event, _, cx| select(event.click_count(), cx))
                    .on_secondary_click({
                        let row = row.clone();
                        self.menu_handler(move |sidebar, _| sidebar.window_menu(&row))
                    }),
            )
            .into_any_element()
    }

    /// The row's right end: its hint while hints show, else its status that the close button
    /// replaces under the pointer. The swap changes visibility only (the close button overlays
    /// the status): GPUI re-reads hover between layout passes, so a hover-driven display change
    /// could paint an element it never prepainted.
    fn trailing(
        &self,
        group: &SharedString,
        shows_hint: bool,
        hint: impl FnOnce() -> AnyElement,
        status: impl FnOnce() -> AnyElement,
        close: AnyElement,
        cx: &App,
    ) -> AnyElement {
        let slot = |hovered| model::trailing_slot(shows_hint, hovered);
        if slot(false) == TrailingSlot::Hint {
            return div().flex_none().child(hint()).into_any_element();
        }
        debug_assert_eq!((slot(false), slot(true)), (TrailingSlot::Status, TrailingSlot::Close));
        div()
            .relative()
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .justify_end()
            .min_w(cx.soprano_theme().z(16.))
            .child(div().flex().items_center().group_hover(group.clone(), |s| s.invisible()).child(status()))
            .child(
                div()
                    .absolute()
                    .top_0()
                    .bottom_0()
                    .right_0()
                    .flex()
                    .items_center()
                    .invisible()
                    .group_hover(group.clone(), |s| s.visible())
                    .child(close),
            )
            .into_any_element()
    }

    fn close_button(&self, id: String, label: &'static str, command: Command, cx: &App) -> AnyElement {
        let shell = self.shell.clone();
        IconButton::new(ElementId::Name(id.into()), IconName::X)
            .size(IconButtonSize::Tab)
            .icon_size(12.)
            .color(cx.soprano_theme().dim)
            .tooltip(label)
            .on_click(move |_, _, cx| {
                cx.stop_propagation();
                shell::dispatch(&shell, command.clone(), cx);
            })
            .into_any_element()
    }

    fn pane_row(&self, row: &PaneRow, gap: f32, now: SystemTime, cx: &App) -> AnyElement {
        let theme = cx.soprano_theme();
        let z = |v: f32| theme.z(v);
        let group: SharedString = format!("sidebar-pane-{}", row.pane_id).into();
        let lit = row.focused;
        let title_color =
            if (row.recedes && !lit) || !row.in_active_window { theme.muted } else { theme.foreground };
        let foreground = theme.foreground;
        let is_agent = matches!(row.kind, PaneKind::Agent(_) | PaneKind::Chat(_));
        let title_line = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(z(5.))
            .min_w_0()
            .child(
                div()
                    .min_w_0()
                    .truncate()
                    .text_color(title_color)
                    .group_hover(group.clone(), move |s| s.text_color(foreground))
                    .when(lit, |t| t.font_weight(FontWeight::MEDIUM))
                    .child(row.title.clone()),
            )
            .when(lit, |line| line.child(icon(IconName::SquarePen).size(11.).color(theme.accent)));
        let text = div()
            .flex()
            .flex_col()
            .flex_1()
            .min_w_0()
            .child(title_line)
            .when(!row.meta.is_empty(), |text| text.child(self.meta_line(&row.meta, &row.pane_id, cx)));
        let pill = row.pill;
        let since = if is_agent { row.since } else { None };
        let trailing = self.trailing(
            &group,
            row.shows_hint,
            || {
                let caps = row.hint_caps.clone().unwrap_or_default();
                div()
                    .id(ElementId::Name(format!("sidebar-jump-pane-{}", row.pane_id).into()))
                    .tooltip(tooltip(model::pane_hint_tooltip(&caps)))
                    .child(Keycaps::new(caps).small())
                    .into_any_element()
            },
            || {
                if pill.is_none() && since.is_none() {
                    return div().into_any_element();
                }
                StatusPill::new(pill).relative_to(since).now(now).into_any_element()
            },
            self.close_button(
                format!("sidebar-pane-close-{}", row.pane_id),
                "Close Pane",
                Command::Close(CloseTarget::Pane(row.pane_id.clone())),
                cx,
            ),
            cx,
        );
        let focus = {
            let workspace = self.workspace.clone();
            let shell = self.shell.clone();
            let pane_id = row.pane_id.clone();
            let tab_id = row.tab_id.clone();
            move |_: &gpui::ClickEvent, _: &mut Window, cx: &mut App| {
                shell::dispatch(&shell, Command::LeavePage, cx);
                workspace.update(cx, |ws| match &tab_id {
                    Some(tab_id) => ws.focus_tab(&pane_id, tab_id, false),
                    None => ws.focus_pane(&pane_id),
                });
            }
        };
        let guide_top = gap + if row.first_in_window { GUIDE_INSET } else { 0.0 };
        let guide_bottom = if row.last_in_window { GUIDE_INSET } else { 0.0 };
        div()
            .relative()
            .mt(z(gap))
            .child(
                div()
                    .absolute()
                    .left(z(GUIDE_X))
                    .w(px(1.))
                    .top(z(-guide_top))
                    .bottom(z(guide_bottom))
                    .bg(theme.border),
            )
            .child(
                div().group(group).ml(z(PANE_INDENT)).child(
                    SidebarRow::new(ElementId::Name(format!("sidebar-pane-row-{}", row.pane_id).into()))
                        .height(if row.meta.is_empty() { ONE_LINE_ROW } else { TWO_LINE_ROW })
                        .selected(row.focused)
                        .child(kind_icon(&row.kind, lit, theme.foreground, theme.muted).size(16.))
                        .child(text)
                        .child(trailing)
                        .on_click(focus),
                ),
            )
            .into_any_element()
    }

    /// `omp · shop · ⎇ feat/x · 2 tabs` in 11.5 px `dim`.
    fn meta_line(&self, meta: &ContextLine, pane_id: &str, cx: &App) -> AnyElement {
        let theme = cx.soprano_theme();
        let z = |v: f32| theme.z(v);
        let mut children: Vec<AnyElement> = Vec::new();
        for (index, part) in meta.parts().into_iter().enumerate() {
            if index > 0 {
                children.push(div().flex_none().child(ContextLine::SEPARATOR).into_any_element());
            }
            children.push(match part {
                ContextPart::Text(text) => div().min_w_0().truncate().child(text).into_any_element(),
                ContextPart::Branch(name) => div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .min_w_0()
                    .gap(z(3.))
                    .child(icon(IconName::Branch).size(11.).color(theme.dim))
                    .child(div().min_w_0().truncate().child(name))
                    .into_any_element(),
            });
        }
        div()
            .id(ElementId::Name(format!("pane-row-meta-{pane_id}").into()))
            .flex()
            .flex_row()
            .items_center()
            .min_w_0()
            .overflow_hidden()
            .whitespace_nowrap()
            .text_size(z(11.5))
            .text_color(theme.dim)
            .when_some(meta.branch.clone(), |line, branch| {
                line.tooltip(tooltip(format!("On branch {branch}")))
            })
            .children(children)
            .into_any_element()
    }

    // MARK: - Agents

    fn agents_block(
        &self,
        groups: &[(AgentDashboardSection, Vec<AgentRow>)],
        now: SystemTime,
        cx: &App,
    ) -> AnyElement {
        let theme = cx.soprano_theme();
        let z = |v: f32| theme.z(v);
        let total: usize = groups.iter().map(|(_, rows)| rows.len()).sum();
        let shell = self.shell.clone();
        let header = SectionHeader::new("sidebar-agents-header", "Agents")
            .medium()
            .count(total)
            .h(z(41.))
            .pt(z(14.))
            .pb(z(5.))
            .end_slot(
                IconButton::new("sidebar-dashboard", IconName::Clock)
                    .icon_size(14.)
                    .color(theme.dim)
                    .tooltip("Agent Dashboard")
                    .on_click(move |_, _, cx| shell::dispatch(&shell, Command::OpenDashboard, cx)),
            );
        let body = if groups.is_empty() {
            div()
                .px(z(12.))
                .text_size(z(12.))
                .text_color(theme.dim)
                .child("No agents to monitor")
                .into_any_element()
        } else {
            let mut children: Vec<AnyElement> = Vec::new();
            for (section, rows) in groups {
                children.push(
                    div()
                        .flex()
                        .flex_row()
                        .flex_none()
                        .items_center()
                        .gap(z(6.))
                        .h(z(30.))
                        .pt(z(8.))
                        .px(z(8.))
                        .text_size(z(11.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(section_color(*section, cx))
                        .child(section.title())
                        .child(div().text_color(theme.dim).child(rows.len().to_string()))
                        .into_any_element(),
                );
                children.extend(rows.iter().map(|row| self.agent_row(row, now, cx)));
            }
            ScrollList::new("sidebar-agents", &self.agents_scroll)
                .mode(ScrollbarMode::Always)
                .px(z(8.))
                .pb(z(14.))
                .children(children)
                .into_any_element()
        };
        div()
            .flex()
            .flex_col()
            .flex_1()
            .min_h(z(90.))
            .border_t_1()
            .border_color(theme.border)
            .child(header)
            .child(body)
            .into_any_element()
    }

    fn agent_row(&self, row: &AgentRow, now: SystemTime, cx: &App) -> AnyElement {
        let theme = cx.soprano_theme();
        let z = |v: f32| theme.z(v);
        let workspace = self.workspace.clone();
        let shell = self.shell.clone();
        let (pane_id, tab_id) = (row.pane_id.clone(), row.tab_id.clone());
        SidebarRow::new(ElementId::Name(format!("sidebar-agent-{}:{}", row.pane_id, row.tab_id).into()))
            .selected(row.focused)
            .tooltip(row.location.clone())
            .child(kind_icon(&row.kind, true, theme.foreground, theme.muted).size(16.))
            .child(
                div()
                    .flex_none()
                    .max_w(z(if row.detail.is_some() { 120. } else { 200. }))
                    .truncate()
                    .text_color(if row.idle && !row.focused { theme.muted } else { theme.foreground })
                    .child(row.name.clone()),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_color(theme.dim)
                    .when_some(row.detail.clone(), |d, detail| d.child(format!("· {detail}"))),
            )
            .child(StatusPill::new(row.pill).relative_to(row.since).now(now))
            .on_click(move |_, _, cx| {
                shell::dispatch(&shell, Command::LeavePage, cx);
                workspace.update(cx, |ws| ws.focus_tab(&pane_id, &tab_id, true));
            })
            .into_any_element()
    }

    // MARK: - Footer

    fn footer(&self, page: Option<Page>, cx: &App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let z = |v: f32| theme.z(v);
        let automations_shell = self.shell.clone();
        let statistics_shell = self.shell.clone();
        let settings_shell = self.shell.clone();
        let entry = |id: &'static str, glyph: IconName, label: &'static str, selected: bool| {
            let color = if selected { theme.foreground } else { theme.muted };
            SidebarRow::new(id)
                .height(28.)
                .selected(selected)
                .text_color(color)
                .child(icon(glyph).size(14.).color(color))
                .child(div().min_w_0().truncate().child(label))
        };
        div()
            .flex()
            .flex_col()
            .flex_none()
            .border_t_1()
            .border_color(theme.border)
            .px(z(8.))
            .pt(z(4.))
            .pb(z(8.))
            .child(
                entry(
                    "sidebar-automations",
                    IconName::AlarmClock,
                    "Automations",
                    page == Some(Page::Automations),
                )
                .on_click(move |_, _, cx| {
                    shell::dispatch(&automations_shell, Command::ToggleAutomations, cx)
                }),
            )
            .child(
                entry(
                    "sidebar-statistics",
                    IconName::STATISTICS,
                    "Statistics",
                    page == Some(Page::Statistics),
                )
                .on_click(move |_, _, cx| shell::dispatch(&statistics_shell, Command::ToggleStatistics, cx)),
            )
            .child(
                entry("sidebar-settings", IconName::Settings, "Settings", false)
                    .on_click(move |_, _, cx| shell::dispatch(&settings_shell, Command::OpenSettings, cx)),
            )
    }
}

impl Render for Sidebar {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let shell = self.shell.read(cx);
        let hints = Hints { control_held: shell.control_held, typed: shell.typed_pane_hint.clone() };
        let page = shell.page;
        let resize_highlighted = shell.sidebar_resize_highlighted;
        let hide_window_bar = shell.settings.hide_window_bar;
        let platform = KeyPlatform::current();
        let now = SystemTime::now();

        let mut clock = std::mem::take(cx.default_global::<StatusClock>());
        let ws = self.workspace.model.read(cx);
        // Reconcile the watchers first so rows read fresh branches.
        let watched = model::watched_cwds(ws);
        if watched != self.watched {
            self.services.branches.set_watched_paths(&watched);
            self.watched = watched;
        }
        let branches = self.services.branches.clone();
        let branch = move |cwd: &str| branches.notable_branch(cwd);
        let input = ListInput { hints: &hints, platform, now, home: &self.home, branch: &branch };
        let rows = model::window_list(ws, &input, &mut clock);
        let groups = model::agent_groups(ws, &mut clock, now, &self.home);
        let session_name: SharedString =
            ws.active_session().map_or("Session".into(), |s| s.name.clone().into());
        let can_collapse = model::can_collapse_all(ws);
        let window_count = ws.active_session_windows().len();
        let active_window = ws.active_window_id().to_owned();
        *cx.default_global::<StatusClock>() = clock;

        if self.reveal.needs_reveal(&active_window)
            && let Some(index) = model::window_row_index(&rows, &active_window)
        {
            self.windows_scroll.scroll_to_item(index);
        }
        let live = rows.iter().any(|row| match &row.row {
            RowModel::Pane(pane) => {
                pane.pill.is_some_and(|p| p.since.is_some()) || (pane.pill.is_none() && pane.since.is_some())
            }
            RowModel::Window(_) => false,
        }) || groups.iter().flat_map(|(_, rows)| rows).any(|row| row.since.is_some());
        self.update_clock(live, cx);

        let inset = window_chrome::traffic_light_inset(window, hide_window_bar).unwrap_or(BRAND_INSET);
        let theme = cx.soprano_theme();
        let z = |v: f32| theme.z(v);
        let list: Vec<AnyElement> = rows
            .iter()
            .map(|ListRow { gap, row }| match row {
                RowModel::Window(window_row) => self.window_row(window_row, *gap, platform, cx),
                RowModel::Pane(pane_row) => self.pane_row(pane_row, *gap, now, cx),
            })
            .collect();
        div()
            .flex()
            .flex_col()
            .size_full()
            .overflow_hidden()
            .bg(theme.chrome)
            .border_r_1()
            .border_color(if resize_highlighted { theme.input } else { theme.border })
            .text_size(z(soprano_ui::fonts::size::UI))
            .text_color(theme.foreground)
            .child(self.brand_row(inset, session_name, cx))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_h(z(90.))
                    .child(self.windows_header(window_count, can_collapse, cx))
                    .child(
                        ScrollList::new("sidebar-windows", &self.windows_scroll)
                            .mode(ScrollbarMode::Always)
                            .px(z(8.))
                            .pb(z(14.))
                            .children(list),
                    ),
            )
            .child(self.agents_block(&groups, now, cx))
            .child(self.footer(page, cx))
    }
}

/// Linux and Windows have no menu bar for the Commands menu, so the brand row offers it.
fn shows_commands_button() -> bool {
    !cfg!(target_os = "macos")
}

/// A saved workspace in the menu: `Work — 11/9/26, 3:04 PM`.
fn saved_workspace_label(session: &WorkspaceSession) -> String {
    let date = session
        .saved_at
        .to_system_time()
        .map(|time| chrono::DateTime::<chrono::Local>::from(time).format("%-m/%-d/%y, %-I:%M %p").to_string())
        .unwrap_or_default();
    format!("{} — {date}", session.name)
}

/// A row's icon: the agent's program icon, else its kind's glyph.
fn kind_icon(kind: &PaneKind, lit: bool, foreground: Hsla, muted: Hsla) -> Icon {
    let tint = if lit { foreground } else { muted };
    match kind {
        PaneKind::Agent(profile) | PaneKind::Chat(profile) => match agent_icon_stem(profile) {
            Some(stem) => Icon::program(stem).color(foreground),
            None => Icon::new(if matches!(kind, PaneKind::Chat(_)) {
                IconName::MessageSquare
            } else {
                IconName::Bot
            })
            .color(tint),
        },
        PaneKind::Terminal => Icon::new(IconName::Terminal).color(tint),
        PaneKind::Diff => Icon::new(IconName::FileDiff).color(tint),
        PaneKind::Document => Icon::new(IconName::FileText).color(tint),
        PaneKind::Browser => Icon::new(IconName::Globe).color(tint),
    }
}

/// A group header's color: the status it collects.
fn section_color(section: AgentDashboardSection, cx: &App) -> Hsla {
    let theme = cx.soprano_theme();
    match section {
        AgentDashboardSection::NeedsYou => theme.approval,
        AgentDashboardSection::Working => theme.working,
        AgentDashboardSection::Ready => theme.done,
        AgentDashboardSection::Stopped => theme.dim,
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use gpui::{Bounds, Modifiers, TestAppContext, VisualTestContext, point, size};
    use soprano_accounts::AccountsController;
    use soprano_config::{AppSettings, ConfigStore, DefaultKeybindings};
    use soprano_git::branch::GitBranchMonitor;
    use soprano_model::{SessionManager, Workspace};
    use soprano_platform::StateStore;
    use soprano_types::SplitDirection;

    use super::*;

    struct Harness<'a> {
        view: Entity<Sidebar>,
        workspace: WorkspaceHandle,
        cx: &'a mut VisualTestContext,
    }

    impl Harness<'_> {
        /// The list rows as the sidebar draws them (no keys held).
        fn rows(&mut self) -> Vec<ListRow> {
            let hints = Hints::default();
            let no_branch = |_: &str| -> Option<String> { None };
            let input = ListInput {
                hints: &hints,
                platform: KeyPlatform::Mac,
                now: SystemTime::now(),
                home: "/",
                branch: &no_branch,
            };
            self.read(|ws| model::window_list(ws, &input, &mut StatusClock::default()))
        }

        /// Where `selector` is on screen: `sidebar-collapse-all`, `sidebar-window-<id>`,
        /// `sidebar-window-disclosure-<id>` or `sidebar-pane-<id>`.
        fn bounds(&mut self, selector: &str) -> Option<Bounds<Pixels>> {
            if selector == "sidebar-collapse-all" {
                return self.cx.debug_bounds("sidebar-collapse-all");
            }
            let disclosure = selector.strip_prefix("sidebar-window-disclosure-");
            let window = disclosure.or_else(|| selector.strip_prefix("sidebar-window-"));
            let pane = selector.strip_prefix("sidebar-pane-");
            let index = self.rows().iter().position(|row| match &row.row {
                RowModel::Window(w) => window == Some(w.id.as_str()),
                RowModel::Pane(p) => pane == Some(p.pane_id.as_str()),
            })?;
            let list = self.list();
            let mut bounds = list.bounds_for_item(index)?;
            bounds.origin.y += list.offset().y;
            if disclosure.is_some() {
                // The chevron: 15 px after the row's 8 px padding.
                return Some(Bounds::new(
                    point(bounds.left() + px(8.), bounds.top()),
                    size(px(15.), bounds.size.height),
                ));
            }
            Some(bounds)
        }

        fn redraw(&mut self) {
            self.cx.update(|window, _| window.refresh());
            self.cx.run_until_parked();
            self.cx.update(|window, _| window.refresh());
            self.cx.run_until_parked();
        }

        fn update<R>(&mut self, f: impl FnOnce(&mut Workspace) -> R) -> R {
            let workspace = self.workspace.clone();
            let result = self.cx.update(|_, cx| workspace.update(cx, f));
            self.redraw();
            result
        }

        fn read<R>(&mut self, f: impl FnOnce(&Workspace) -> R) -> R {
            let workspace = self.workspace.clone();
            self.cx.update(|_, cx| f(workspace.read(cx)))
        }

        fn list(&mut self) -> ScrollHandle {
            self.view.read_with(self.cx, |sidebar, _| sidebar.windows_scroll.clone())
        }

        fn is_visible(&mut self, selector: &str) -> bool {
            let viewport = self.list().bounds();
            self.bounds(selector)
                .is_some_and(|row| row.top() >= viewport.top() && row.bottom() <= viewport.bottom())
        }

        fn click(&mut self, selector: &str) {
            let bounds = self.bounds(selector).unwrap_or_else(|| panic!("{selector} is drawn"));
            self.cx.simulate_click(bounds.center(), Modifiers::none());
            self.redraw();
        }

        fn pane_row_count(&mut self) -> usize {
            let list = self.list();
            let drawn = (0..).take_while(|index| list.bounds_for_item(*index).is_some()).count();
            drawn - self.read(|ws| ws.active_session_windows().len())
        }
    }

    fn harness<'a>(
        cx: &'a mut TestAppContext,
        height: f32,
        build: impl FnOnce(&mut Workspace),
    ) -> Harness<'a> {
        cx.update(soprano_ui::init_for_tests);
        let state = StateStore::in_memory();
        let mut workspace = Workspace::new();
        build(&mut workspace);
        let (handle, shell, services) = cx.update(|cx| {
            let handle = WorkspaceHandle::new(workspace, cx);
            let shell = cx.new(|_| {
                Shell::new(state.clone(), AppSettings::default_settings(), DefaultKeybindings::config())
            });
            let services = Services {
                state: state.clone(),
                config: ConfigStore::new(std::env::temp_dir().join("soprano-sidebar-tests-settings.json")),
                accounts: AccountsController::new(state.clone()),
                branches: Arc::new(GitBranchMonitor::new()),
                sessions: cx.new(|_| SessionManager::new(state.clone())),
            };
            (handle, shell, services)
        });
        let workspace = handle.clone();
        let (view, cx) = cx.add_window_view(|window, cx| Sidebar::new(handle, shell, services, window, cx));
        cx.simulate_resize(size(px(220.), px(height)));
        let mut harness = Harness { view, workspace, cx };
        harness.redraw();
        harness
    }

    fn windows(ws: &Workspace) -> Vec<String> {
        ws.active_session_windows().iter().map(|w| w.id.clone()).collect()
    }

    fn twenty_windows(collapsed: bool) -> impl FnOnce(&mut Workspace) {
        move |ws| {
            for _ in 0..19 {
                ws.create_window(None, None).expect("window");
            }
            if collapsed {
                for id in windows(ws) {
                    ws.toggle_sidebar_window_collapsed(&id);
                }
            }
            let first = windows(ws)[0].clone();
            ws.activate_window(&first);
        }
    }

    // SidebarSelectionScrollTests

    fn switching_windows_reveals_their_headers(cx: &mut TestAppContext, collapsed: bool) {
        let mut h = harness(cx, 520., twenty_windows(collapsed));
        let ids = h.read(windows);
        let (first, last) = (ids[0].clone(), ids[ids.len() - 1].clone());
        assert!(h.is_visible(&format!("sidebar-window-{first}")));
        assert!(!h.is_visible(&format!("sidebar-window-{last}")));

        // The dashboard focuses a terminal tab, while Find Window activates its window.
        let (pane, tab) = h.read(|ws| {
            let pane = ws.window(&last).expect("window").active_pane_id().to_owned();
            let tab = ws.pane(&pane).and_then(|p| p.active_tab()).expect("tab").id.clone();
            (pane, tab)
        });
        h.update(|ws| ws.focus_tab(&pane, &tab, false));
        assert!(h.is_visible(&format!("sidebar-window-{last}")));

        h.update(|ws| ws.activate_window(&first));
        assert!(h.is_visible(&format!("sidebar-window-{first}")));
        assert_eq!(h.read(|ws| ws.window(&last).expect("window").is_sidebar_collapsed), collapsed);
    }

    #[gpui::test]
    fn switching_windows_reveals_their_headers_in_both_directions(cx: &mut TestAppContext) {
        switching_windows_reveals_their_headers(cx, false);
    }

    #[gpui::test]
    fn switching_collapsed_windows_reveals_their_headers_in_both_directions(cx: &mut TestAppContext) {
        switching_windows_reveals_their_headers(cx, true);
    }

    #[gpui::test]
    fn background_refreshes_and_reselecting_the_same_window_preserve_manual_scrolling(
        cx: &mut TestAppContext,
    ) {
        let mut h = harness(cx, 520., twenty_windows(false));
        let last = h.read(windows).last().cloned().expect("window");
        h.update(|ws| ws.activate_window(&last));
        assert!(h.is_visible(&format!("sidebar-window-{last}")));
        h.list().set_offset(point(px(0.), px(0.)));
        h.redraw();

        h.update(|ws| ws.rename_window(&last, "Renamed window"));
        h.update(|ws| ws.activate_window(&last));

        assert_eq!(h.list().offset(), point(px(0.), px(0.)));
        assert!(!h.is_visible(&format!("sidebar-window-{last}")));
    }

    #[gpui::test]
    fn switching_to_an_already_visible_window_does_not_move_the_list(cx: &mut TestAppContext) {
        let mut h = harness(cx, 520., twenty_windows(false));
        let second = h.read(windows)[1].clone();
        assert!(h.is_visible(&format!("sidebar-window-{second}")));
        let original = h.list().offset();
        h.update(|ws| ws.activate_window(&second));
        assert_eq!(h.list().offset(), original);
    }

    #[gpui::test]
    fn dashboard_selection_across_sessions_reveals_the_window_after_its_rows_are_rebuilt(
        cx: &mut TestAppContext,
    ) {
        let mut h = harness(cx, 520., twenty_windows(false));
        let last = h.read(windows).last().cloned().expect("window");
        let (pane, tab) = h.read(|ws| {
            let pane = ws.window(&last).expect("window").active_pane_id().to_owned();
            let tab = ws.pane(&pane).and_then(|p| p.active_tab()).expect("tab").id.clone();
            (pane, tab)
        });
        h.update(|ws| ws.create_session("Other session", None).expect("session"));
        assert!(h.bounds(&format!("sidebar-window-{last}")).is_none());

        h.update(|ws| ws.focus_tab(&pane, &tab, false));
        assert!(h.is_visible(&format!("sidebar-window-{last}")));
    }

    // SidebarLayoutTabTests

    #[gpui::test]
    fn a_click_on_a_row_selects_it_and_one_on_its_disclosure_does_not(cx: &mut TestAppContext) {
        let mut h = harness(cx, 600., |_| {});
        let first = h.read(|ws| ws.active_pane_id().to_owned());
        h.update(|ws| ws.create_layout_tab(None, None).expect("tab"));
        let second = h.read(|ws| ws.active_pane_id().to_owned());
        let third = h.update(|ws| ws.split_pane(SplitDirection::Horizontal, &second).expect("split"));

        for pane in [&first, &third] {
            h.click(&format!("sidebar-pane-{pane}"));
            assert_eq!(h.read(|ws| ws.active_pane_id().to_owned()), *pane);
        }
        assert_eq!(h.read(|ws| ws.active_window().expect("window").active_tab_index()), 1);
        h.click(&format!("sidebar-pane-{first}"));
        assert_eq!(h.read(|ws| ws.active_window().expect("window").active_tab_index()), 0);

        // A click on the disclosure button is the button's, not a row select.
        let window = h.update(|ws| ws.create_window(None, None).expect("window"));
        h.update(|ws| ws.activate_previous_window());
        h.click(&format!("sidebar-window-disclosure-{window}"));
        assert_ne!(h.read(|ws| ws.active_window_id().to_owned()), window);
        assert!(h.read(|ws| ws.window(&window).expect("window").is_sidebar_collapsed));

        h.click(&format!("sidebar-window-{window}"));
        assert_eq!(h.read(|ws| ws.active_window_id().to_owned()), window);
    }

    #[gpui::test]
    fn panes_sharing_a_tab_sit_closer_than_panes_in_separate_tabs(cx: &mut TestAppContext) {
        let mut h = harness(cx, 600., |_| {});
        let first = h.read(|ws| ws.active_pane_id().to_owned());
        h.update(|ws| ws.create_layout_tab(None, None).expect("tab"));
        let second = h.read(|ws| ws.active_pane_id().to_owned());
        let split = h.update(|ws| ws.split_pane(SplitDirection::Horizontal, &second).expect("split"));
        let window = h.update(|ws| ws.create_window(None, None).expect("window"));
        let gap = |h: &mut Harness, upper: String, lower: String| {
            let (upper, lower) = (h.bounds(&upper).expect("upper"), h.bounds(&lower).expect("lower"));
            f32::from(lower.top() - upper.bottom()).round()
        };
        let pane = |id: &str| format!("sidebar-pane-{id}");
        assert_eq!(gap(&mut h, pane(&second), pane(&split)), model::ROW_GAP);
        assert_eq!(gap(&mut h, pane(&first), pane(&second)), model::TAB_GAP);
        assert_eq!(gap(&mut h, pane(&split), format!("sidebar-window-{window}")), model::WINDOW_GAP);
    }

    // SidebarCollapseAllTests / SidebarCollapsePersistenceTests (view parts)

    #[gpui::test]
    fn collapse_all_collapses_every_window_and_hides_their_panes(cx: &mut TestAppContext) {
        let mut h = harness(cx, 600., |ws| {
            ws.create_window(None, None).expect("window");
            ws.create_window(None, None).expect("window");
            let first = windows(ws)[0].clone();
            ws.toggle_sidebar_window_collapsed(&first);
        });
        assert!(h.pane_row_count() > 0);
        h.click("sidebar-collapse-all");
        assert!(h.read(|ws| ws.active_session_windows().iter().all(|w| w.is_sidebar_collapsed)));
        assert_eq!(h.pane_row_count(), 0);

        // Disabled now: a click changes nothing.
        let last = h.read(windows).last().cloned().expect("window");
        h.click(&format!("sidebar-window-disclosure-{last}"));
        assert_eq!(h.pane_row_count(), 1);
        h.click("sidebar-collapse-all");
        assert_eq!(h.pane_row_count(), 0);
    }

    #[gpui::test]
    fn a_collapsed_window_shows_no_pane_rows_until_control_is_held(cx: &mut TestAppContext) {
        let mut h = harness(cx, 600., |ws| {
            let window = ws.active_window_id().to_owned();
            ws.toggle_sidebar_window_collapsed(&window);
        });
        assert_eq!(h.pane_row_count(), 0);
        let shell = h.view.read_with(h.cx, |sidebar, _| sidebar.shell.clone());
        h.cx.update(|_, cx| {
            shell.update(cx, |shell, cx| {
                shell.control_held = true;
                cx.notify();
            })
        });
        h.redraw();
        assert_eq!(h.pane_row_count(), 1);
    }

    #[test]
    fn saved_workspaces_read_their_name_and_short_date() {
        let mut session = WorkspaceSession::legacy("id", "Work", None, Vec::new(), "pane-1");
        session.saved_at = soprano_model::ReferenceDate::now();
        let label = saved_workspace_label(&session);
        assert!(label.starts_with("Work — "));
        assert!(label.ends_with("AM") || label.ends_with("PM"));
    }
}
