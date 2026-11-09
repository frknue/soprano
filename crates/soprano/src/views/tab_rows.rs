//! The window tabs row and the layout tab row (`WindowTabBarView.swift`, `LayoutTabBarView.swift`,
//! `TabPillButton.swift`, `StatusCountBadgeView.swift`) in Herdr's tab row look (HERDR-UI §6).
//!
//! The window tabs row lists the active session's logical windows (`1  Editor`) and sits on top
//! unless `hideWindowTabs`; the layout tab row lists the active window's tabs, each named after
//! its focused pane, and ends with the Files / Changes toggles of the right sidebar. Whichever
//! row is on top is the window's drag region, keeps clear of the macOS traffic lights while the
//! sidebar is hidden (and then carries the sidebar toggle), and holds the Linux/Windows window
//! buttons.
//!
//! Tabs scroll horizontally in a strip that keeps the active tab in view; `+` follows the last
//! tab while everything fits and stays pinned beside the strip once the tabs overflow.

use gpui::{
    AnyElement, App, ClickEvent, Context, Entity, InteractiveElement, IntoElement, MouseButton,
    ParentElement, Render, ScrollDelta, ScrollEvent, ScrollHandle, StatefulInteractiveElement, Styled,
    Subscription, Window, div, prelude::*,
};
use soprano_explorer::{RightSidebar, RightSidebarTab};
use soprano_model::Workspace;
use soprano_ui::status::TabBadge;
use soprano_ui::{ActiveSopranoTheme, IconButton, IconName, PanelToggle, TabPill};

use crate::shell::{CloseTarget, Command, Shell, dispatch};
use crate::window_chrome::{self, WindowButtons};
use crate::workspace::WorkspaceHandle;

/// Each tab row's height (HERDR-UI §6), including its bottom border.
pub const TAB_ROW_HEIGHT: f32 = 42.0;
/// Herdr's row padding (`px 10`), and its leading padding when nothing needs clearing.
const ROW_PADDING: f32 = 10.0;
/// Between the row's parts; each tab keeps half of it on either side.
const ROW_GAP: f32 = 3.0;
/// A trackpad's vertical travel that switches one tab.
const WHEEL_PIXELS_PER_TAB: f32 = 24.0;

/// One tab in either row, as the row shows it.
#[derive(Clone, Debug, PartialEq)]
pub struct TabItem {
    /// The window or layout tab id.
    pub id: String,
    /// 1-based position in the row.
    pub number: usize,
    pub title: String,
    pub active: bool,
    /// Running commands, then agents (the agent badge sits at the trailing edge).
    pub badges: [Option<TabBadge>; 2],
    /// `Tab 2: server — 1 agent: 1 working — 1 command running`.
    pub tooltip: String,
}

/// The active window's layout tabs, each named after its focused pane (`LayoutTabBarView`).
pub fn layout_tab_items(workspace: &Workspace) -> Vec<TabItem> {
    let Some(window) = workspace.active_window() else { return Vec::new() };
    let active_id = &window.active_tab().id;
    window
        .tabs()
        .iter()
        .enumerate()
        .map(|(index, tab)| {
            let activity = workspace.layout_tab_activity(&tab.id);
            let title = workspace.layout_tab_title(tab);
            let number = index + 1;
            TabItem {
                id: tab.id.clone(),
                number,
                tooltip: activity.describe(&format!("Tab {number}: {title}")),
                title,
                active: &tab.id == active_id,
                badges: [
                    TabBadge::running_commands(activity.running_commands),
                    TabBadge::agents(&activity.agents),
                ],
            }
        })
        .collect()
}

/// The active session's windows, numbered (`WindowTabBarView`).
pub fn window_tab_items(workspace: &Workspace) -> Vec<TabItem> {
    workspace
        .active_session_windows()
        .into_iter()
        .enumerate()
        .map(|(index, window)| {
            let activity = workspace.window_activity(&window.id);
            let number = index + 1;
            TabItem {
                id: window.id.clone(),
                number,
                tooltip: activity.describe(&format!("Window {number}: {}", window.title)),
                title: window.title.clone(),
                active: window.id == workspace.active_window_id(),
                badges: [
                    TabBadge::running_commands(activity.running_commands),
                    TabBadge::agents(&activity.agents),
                ],
            }
        })
        .collect()
}

/// What the row on top of the work area carries besides its tabs.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TopRowChrome {
    /// Designed px before the first control.
    pub leading_inset: f32,
    /// The sidebar is hidden, so this row offers its toggle (Swift `showsSidebarToggle`).
    pub sidebar_toggle: bool,
    /// Client-side minimize / maximize / close at the right end.
    pub window_buttons: bool,
}

impl TopRowChrome {
    /// `is_top`: this row is the topmost (window tabs when shown, else layout tabs).
    /// `traffic_light_inset`: room the macOS traffic lights need, when they show.
    pub fn new(
        is_top: bool,
        sidebar_visible: bool,
        traffic_light_inset: Option<f32>,
        window_buttons: bool,
    ) -> Self {
        let clears_lights = is_top && !sidebar_visible;
        Self {
            leading_inset: if clears_lights {
                traffic_light_inset.unwrap_or(ROW_PADDING)
            } else {
                ROW_PADDING
            },
            sidebar_toggle: clears_lights,
            window_buttons: is_top && window_buttons,
        }
    }

    fn of(is_top: bool, shell: &Shell, window: &Window) -> Self {
        let hide_bar = shell.settings.hide_window_bar;
        Self::new(
            is_top,
            shell.sidebar_visible,
            window_chrome::traffic_light_inset(window, hide_bar),
            window_chrome::shows_window_buttons(hide_bar),
        )
    }
}

/// What a wheel event does to the layout tabs (HERDR-UI §6: down → previous, up → next).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WheelOutcome {
    /// Mostly horizontal: the strip scrolls instead.
    Horizontal,
    /// Vertical travel collected toward the next step.
    Pending,
    /// Switch by this many tabs.
    Step(isize),
}

/// Turns a wheel delta into tab steps, collecting a trackpad's pixel travel in `travel`.
pub fn wheel_outcome(delta: ScrollDelta, travel: &mut f32) -> WheelOutcome {
    let (x, y, precise) = match delta {
        ScrollDelta::Lines(lines) => (lines.x, lines.y, false),
        ScrollDelta::Pixels(pixels) => (f32::from(pixels.x), f32::from(pixels.y), true),
    };
    if y == 0.0 || x.abs() > y.abs() {
        return WheelOutcome::Horizontal;
    }
    let direction = if y > 0.0 { 1 } else { -1 };
    if !precise {
        *travel = 0.0;
        return WheelOutcome::Step(direction);
    }
    if travel.signum() != y.signum() {
        *travel = 0.0;
    }
    *travel += y;
    if travel.abs() >= WHEEL_PIXELS_PER_TAB {
        *travel = 0.0;
        WheelOutcome::Step(direction)
    } else {
        WheelOutcome::Pending
    }
}

/// The scrolling strip of a row: keeps the active tab in view when the tabs, the selection or
/// the viewport change, and leaves a strip the user scrolled alone otherwise.
#[derive(Default)]
struct TabStrip {
    scroll: ScrollHandle,
    revealed: Option<Vec<String>>,
    viewport_width: f32,
}

impl TabStrip {
    /// Reveals the active tab when `key` (what the row shows) or the viewport changed.
    fn reveal_active(&mut self, key: Vec<String>, items: &[TabItem]) {
        let width = f32::from(self.scroll.bounds().size.width);
        if self.revealed.as_ref() == Some(&key) && width == self.viewport_width {
            return;
        }
        self.viewport_width = width;
        self.revealed = Some(key);
        if let Some(index) = items.iter().position(|item| item.active) {
            self.scroll.scroll_to_item(index);
        }
    }

    fn render(&self, id: &'static str, tabs: Vec<AnyElement>) -> impl IntoElement {
        div()
            .id(id)
            .flex()
            .flex_row()
            .items_center()
            .h_full()
            .min_w_0()
            .flex_shrink(1.)
            .overflow_x_scroll()
            .track_scroll(&self.scroll)
            .children(tabs)
    }
}

/// A tab's slot in the strip: the pill with half the row gap either side, so the slots tile the
/// strip and wheel events over it reach the row's handler.
fn tab_slot(id: (&'static str, usize), pill: TabPill, cx: &App) -> gpui::Stateful<gpui::Div> {
    let theme = cx.soprano_theme();
    div()
        .id(id)
        .flex()
        .flex_none()
        .items_center()
        .h_full()
        .px(theme.z(ROW_GAP / 2.0))
        // A tab is no part of the drag region.
        .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
        .child(pill)
}

/// The row frame: chrome fill, bottom border, Herdr's paddings, the drag region on top.
fn row_frame(id: &'static str, chrome: TopRowChrome, is_top: bool, cx: &App) -> gpui::Stateful<gpui::Div> {
    let theme = cx.soprano_theme();
    let row = div()
        .id(id)
        .flex()
        .flex_row()
        .flex_none()
        .items_center()
        .w_full()
        .h(theme.z(TAB_ROW_HEIGHT))
        .pl(theme.z(chrome.leading_inset))
        .pr(theme.z(ROW_PADDING))
        .gap(theme.z(ROW_GAP))
        .bg(theme.chrome)
        .border_b_1()
        .border_color(theme.border)
        .text_color(theme.foreground);
    if is_top { window_chrome::window_drag_region(row) } else { row }
}

fn sidebar_toggle(shell: &Entity<Shell>) -> IconButton {
    let shell = shell.clone();
    IconButton::new("sidebar-toggle", IconName::Sidebar)
        .tooltip("Toggle Sidebar")
        .on_click(move |_, _, cx| dispatch(&shell, Command::ToggleSidebar, cx))
}

fn add_button(id: &'static str, label: &'static str, cx: &App) -> IconButton {
    IconButton::new(id, IconName::Plus).color(cx.soprano_theme().dim).tooltip(label)
}

// MARK: - Window tabs

/// The active session's windows as numbered tabs, above the layout tabs while `hideWindowTabs`
/// is off.
pub struct WindowTabRow {
    workspace: WorkspaceHandle,
    shell: Entity<Shell>,
    _right_sidebar: Entity<RightSidebar>,
    strip: TabStrip,
    _subscriptions: Vec<Subscription>,
}

impl WindowTabRow {
    pub fn new(
        workspace: WorkspaceHandle,
        shell: Entity<Shell>,
        right_sidebar: Entity<RightSidebar>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let subscriptions = vec![
            // Hidden, the row ignores model changes (busy agents send many) and catches up when
            // shown.
            cx.observe(&workspace.model, |row, _, cx| {
                if row.is_shown(cx) {
                    cx.notify();
                }
            }),
            cx.observe(&shell, |_, _, cx| cx.notify()),
        ];
        Self {
            workspace,
            shell,
            _right_sidebar: right_sidebar,
            strip: TabStrip::default(),
            _subscriptions: subscriptions,
        }
    }

    /// Whether the row is on screen (`hideWindowTabs` off).
    pub fn is_shown(&self, cx: &App) -> bool {
        !self.shell.read(cx).settings.hide_window_tabs
    }

    pub fn activate(&mut self, window_id: &str, cx: &mut Context<Self>) {
        self.workspace.update(cx, |workspace| workspace.activate_window(window_id));
    }

    pub fn add_window(&mut self, cx: &mut Context<Self>) {
        self.workspace.update(cx, |workspace| workspace.create_window(None, None));
    }
}

impl Render for WindowTabRow {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if !self.is_shown(cx) {
            return div().into_any_element();
        }
        let items = window_tab_items(self.workspace.read(cx));
        // A tab that changes width can push the active one out of view.
        let key = items
            .iter()
            .map(|item| format!("{}|{}|{}|{:?}", item.id, item.active, item.title, item.badges))
            .collect();
        self.strip.reveal_active(key, &items);

        let chrome = TopRowChrome::of(true, self.shell.read(cx), window);
        let tabs = items
            .into_iter()
            .enumerate()
            .map(|(index, item)| {
                let id = item.id.clone();
                let pill = TabPill::new(("window-tab", index), item.title)
                    .number(item.number)
                    .active(item.active)
                    .badges(item.badges)
                    .tooltip(item.tooltip)
                    .on_click(cx.listener(move |row, event: &ClickEvent, _, cx| {
                        if event.standard_click() {
                            row.activate(&id, cx);
                        }
                    }));
                tab_slot(("window-tab-slot", index), pill, cx).into_any_element()
            })
            .collect();

        row_frame("window-tab-row", chrome, true, cx)
            .when(chrome.sidebar_toggle, |row| row.child(sidebar_toggle(&self.shell)))
            .child(self.strip.render("window-tab-strip", tabs))
            .child(
                add_button("new-window-tab", "New Window", cx)
                    .on_click(cx.listener(|row, _, _, cx| row.add_window(cx))),
            )
            .child(div().flex_1())
            .when(chrome.window_buttons, |row| row.child(WindowButtons))
            .into_any_element()
    }
}

// MARK: - Layout tabs

/// The active window's layout tabs, then `+` and the Files / Changes toggles.
pub struct LayoutTabRow {
    workspace: WorkspaceHandle,
    shell: Entity<Shell>,
    right_sidebar: Entity<RightSidebar>,
    strip: TabStrip,
    wheel_travel: f32,
    _subscriptions: Vec<Subscription>,
}

impl LayoutTabRow {
    pub fn new(
        workspace: WorkspaceHandle,
        shell: Entity<Shell>,
        right_sidebar: Entity<RightSidebar>,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let subscriptions = vec![
            cx.observe(&workspace.model, |_, _, cx| cx.notify()),
            cx.observe(&shell, |_, _, cx| cx.notify()),
            cx.observe(&right_sidebar, |_, _, cx| cx.notify()),
        ];
        Self {
            workspace,
            shell,
            right_sidebar,
            strip: TabStrip::default(),
            wheel_travel: 0.0,
            _subscriptions: subscriptions,
        }
    }

    /// Topmost while the window tabs are hidden.
    pub fn is_top(&self, cx: &App) -> bool {
        self.shell.read(cx).settings.hide_window_tabs
    }

    pub fn activate(&mut self, layout_tab_id: &str, cx: &mut Context<Self>) {
        self.workspace.update(cx, |workspace| workspace.activate_layout_tab(layout_tab_id));
    }

    /// × and middle-click: the shell closes it, asking about unsaved editors first.
    pub fn close(&mut self, layout_tab_id: &str, cx: &mut Context<Self>) {
        dispatch(&self.shell, Command::Close(CloseTarget::LayoutTab(layout_tab_id.to_owned())), cx);
    }

    pub fn add_tab(&mut self, cx: &mut Context<Self>) {
        self.workspace.update(cx, |workspace| workspace.create_layout_tab(None, None));
    }

    /// The wheel over the row: up shows the next tab, down the previous one.
    pub fn scroll_tabs(&mut self, delta: ScrollDelta, cx: &mut Context<Self>) -> WheelOutcome {
        let outcome = wheel_outcome(delta, &mut self.wheel_travel);
        if let WheelOutcome::Step(step) = outcome {
            self.workspace.update(cx, |workspace| {
                if step > 0 {
                    workspace.activate_next_layout_tab();
                } else {
                    workspace.activate_previous_layout_tab();
                }
            });
        }
        outcome
    }

    /// Whether the Files (Explorer) or Changes (Source Control) toggle is on.
    pub fn panel_shown(&self, tab: RightSidebarTab, cx: &App) -> bool {
        let sidebar = self.right_sidebar.read(cx);
        sidebar.is_open() && sidebar.tab() == tab
    }

    /// A toggle that is on closes the sidebar; otherwise it shows its panel in the open sidebar.
    pub fn toggle_panel(&mut self, tab: RightSidebarTab, window: &mut Window, cx: &mut Context<Self>) {
        let shown = self.panel_shown(tab, cx);
        self.right_sidebar.update(cx, |sidebar, cx| {
            if shown {
                sidebar.set_open(false, window, cx);
            } else {
                sidebar.select_tab(tab, window, cx);
                sidebar.set_open(true, window, cx);
            }
        });
    }

    fn on_wheel(&mut self, event: &ScrollEvent, cx: &mut Context<Self>) {
        if self.scroll_tabs(event.delta, cx) != WheelOutcome::Horizontal {
            cx.stop_propagation();
        }
    }
}

impl Render for LayoutTabRow {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let items = layout_tab_items(self.workspace.read(cx));
        let key = items.iter().map(|item| format!("{}|{}", item.id, item.active)).collect();
        self.strip.reveal_active(key, &items);

        let is_top = self.is_top(cx);
        let chrome = TopRowChrome::of(is_top, self.shell.read(cx), window);
        let tabs = items
            .into_iter()
            .enumerate()
            .map(|(index, item)| {
                let select_id = item.id.clone();
                let close_id = item.id.clone();
                let middle_id = item.id.clone();
                let pill = TabPill::new(("layout-tab", index), item.title)
                    .active(item.active)
                    .badges(item.badges)
                    .tooltip(item.tooltip)
                    .on_click(cx.listener(move |row, event: &ClickEvent, _, cx| {
                        if event.standard_click() {
                            row.activate(&select_id, cx);
                        }
                    }))
                    .on_close(cx.listener(move |row, _: &ClickEvent, _, cx| row.close(&close_id, cx)));
                tab_slot(("layout-tab-slot", index), pill, cx)
                    // A middle click closes the tab, as in a browser.
                    .on_mouse_down(
                        MouseButton::Middle,
                        cx.listener(move |row, _, _, cx| {
                            cx.stop_propagation();
                            row.close(&middle_id, cx);
                        }),
                    )
                    .on_scroll(cx.listener(|row, event: &ScrollEvent, _, cx| row.on_wheel(event, cx)))
                    .into_any_element()
            })
            .collect();

        let files_on = self.panel_shown(RightSidebarTab::Explorer, cx);
        let changes_on = self.panel_shown(RightSidebarTab::SourceControl, cx);
        row_frame("layout-tab-row", chrome, is_top, cx)
            .on_scroll(cx.listener(|row, event: &ScrollEvent, _, cx| row.on_wheel(event, cx)))
            .when(chrome.sidebar_toggle, |row| row.child(sidebar_toggle(&self.shell)))
            .child(self.strip.render("layout-tab-strip", tabs))
            .child(
                add_button("new-layout-tab", "New Tab", cx)
                    .on_click(cx.listener(|row, _, _, cx| row.add_tab(cx))),
            )
            .child(div().flex_1())
            .child(PanelToggle::new("files-toggle", IconName::File, "Files").on(files_on).on_click(
                cx.listener(|row, _, window, cx| row.toggle_panel(RightSidebarTab::Explorer, window, cx)),
            ))
            .child(PanelToggle::new("changes-toggle", IconName::Changes, "Changes").on(changes_on).on_click(
                cx.listener(|row, _, window, cx| {
                    row.toggle_panel(RightSidebarTab::SourceControl, window, cx)
                }),
            ))
            .when(chrome.window_buttons, |row| row.child(WindowButtons))
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use gpui::{TestAppContext, VisualTestContext, point, px};
    use soprano_config::{AppSettings, DefaultKeybindings};
    use soprano_model::PaneType;
    use soprano_platform::StateStore;
    use soprano_types::AgentStatus;
    use soprano_types::TerminalTarget;
    use soprano_ui::status::StatusPillSpec;

    use super::*;

    fn rename_active_pane(workspace: &mut Workspace, title: &str) {
        let pane_id = workspace.active_pane_id().to_owned();
        let tab_id = workspace.panes()[&pane_id].active_tab().unwrap().id.clone();
        workspace.rename_tab(&pane_id, &tab_id, title);
    }

    fn titles(items: &[TabItem]) -> Vec<&str> {
        items.iter().map(|item| item.title.as_str()).collect()
    }

    fn selected(items: &[TabItem]) -> Vec<&str> {
        items.iter().filter(|item| item.active).map(|item| item.title.as_str()).collect()
    }

    // MARK: LayoutTabBarTests

    #[test]
    fn the_row_shows_the_active_windows_tabs_named_after_their_focused_panes() {
        let mut workspace = Workspace::new();
        rename_active_pane(&mut workspace, "editor");
        workspace.create_layout_tab(None, None).unwrap();
        rename_active_pane(&mut workspace, "server");
        assert_eq!(titles(&layout_tab_items(&workspace)), ["editor", "server"]);
        assert_eq!(selected(&layout_tab_items(&workspace)), ["server"]);

        workspace.create_window(None, None).unwrap();
        rename_active_pane(&mut workspace, "logs");
        assert_eq!(titles(&layout_tab_items(&workspace)), ["logs"]);
        let first_window = workspace.active_session_windows()[0].id.clone();
        workspace.activate_window(&first_window);
        assert_eq!(titles(&layout_tab_items(&workspace)), ["editor", "server"]);
    }

    #[test]
    fn a_background_tab_follows_its_focused_panes_title_and_agents() {
        let mut workspace = Workspace::new();
        let background_pane = workspace.active_pane_id().to_owned();
        workspace.create_layout_tab(None, None).unwrap();
        assert_eq!(layout_tab_items(&workspace)[0].badges[1], None);

        let tab_id = workspace.panes()[&background_pane].active_tab().unwrap().id.clone();
        workspace.rename_tab(&background_pane, &tab_id, "renamed by its shell");
        assert_eq!(layout_tab_items(&workspace)[0].title, "renamed by its shell");

        let agent_tab =
            workspace.add_tab_to_pane(&background_pane, PaneType::Agent, Some("codex"), None).unwrap();
        // Adding a pane tab brings its layout tab forward; send it back.
        workspace.activate_next_layout_tab();
        workspace.update_agent_status(&background_pane, &agent_tab, AgentStatus::Waiting, None, None);
        let background = &layout_tab_items(&workspace)[0];
        assert!(!background.active);
        assert!(background.badges[1].is_some());
        assert!(background.tooltip.ends_with("1 agent: 1 needs input"), "{}", background.tooltip);

        workspace.stop_agent(&TerminalTarget::new(background_pane, agent_tab));
        assert_eq!(layout_tab_items(&workspace)[0].badges[1], None);
    }

    // MARK: RunningCommandIndicatorTests (badge parts)

    #[test]
    fn a_running_command_lights_its_layout_tab_until_an_agent_or_its_end_takes_over() {
        let mut workspace = Workspace::new();
        let server_pane = workspace.active_pane_id().to_owned();
        let server_tab = workspace.panes()[&server_pane].active_tab().unwrap().id.clone();
        let server = TerminalTarget::new(server_pane.clone(), server_tab.clone());
        workspace.create_layout_tab(None, None).unwrap();

        workspace.set_running_command_targets(HashSet::from([server.clone()]));
        let items = layout_tab_items(&workspace);
        assert_eq!(items[0].badges[0], Some(TabBadge { count: 1, pill: StatusPillSpec::RUNNING }));
        assert!(items[0].tooltip.ends_with("1 command running"));
        assert_eq!(items[1].badges[0], None);

        workspace.attach_agent_if_needed(&server_pane, &server_tab, "codex");
        assert_eq!(layout_tab_items(&workspace)[0].badges[0], None);

        workspace.set_running_command_targets(HashSet::new());
        assert_eq!(layout_tab_items(&workspace)[0].badges[0], None);
    }

    // MARK: WindowTabBarTests

    #[test]
    fn numbered_tabs_follow_window_creation_selection_renaming_and_closing() {
        let mut workspace = Workspace::new();
        let first = workspace.active_window_id().to_owned();
        workspace.rename_window(&first, "Editor");
        let second = workspace.create_window(None, None).unwrap();
        workspace.rename_window(&second, "Logs");
        let items = window_tab_items(&workspace);
        assert_eq!(
            items.iter().map(|item| (item.number, item.title.as_str())).collect::<Vec<_>>(),
            [(1, "Editor"), (2, "Logs")]
        );
        assert_eq!(selected(&items), ["Logs"]);

        workspace.activate_window(&first);
        assert_eq!(selected(&window_tab_items(&workspace)), ["Editor"]);
        workspace.rename_window(&first, "Code");
        assert_eq!(window_tab_items(&workspace)[0].title, "Code");

        let third = workspace.create_window(None, None).unwrap();
        let items = window_tab_items(&workspace);
        assert_eq!(items.len(), 3);
        assert_eq!(items.iter().find(|item| item.active).map(|item| item.id.as_str()), Some(third.as_str()));
        let _ = workspace.close_window(&second);
        let items = window_tab_items(&workspace);
        assert_eq!(items.len(), 2);
        assert_eq!(items[1].number, 2);
    }

    #[test]
    fn the_row_shows_only_the_current_sessions_windows() {
        let mut workspace = Workspace::new();
        let first_session = workspace.active_session_id().to_owned();
        let window = workspace.active_window_id().to_owned();
        workspace.rename_window(&window, "Work");
        workspace.create_session("Personal", None).unwrap();
        let notes = workspace.active_window_id().to_owned();
        workspace.rename_window(&notes, "Notes");
        assert_eq!(titles(&window_tab_items(&workspace)), ["Notes"]);
        workspace.activate_session(&first_session);
        assert_eq!(titles(&window_tab_items(&workspace)), ["Work"]);
    }

    #[test]
    fn activity_indicators_follow_agent_lifecycle_without_changing_the_window_title() {
        let mut workspace = Workspace::new();
        let window = workspace.active_window_id().to_owned();
        workspace.rename_window(&window, "Editor");
        assert_eq!(window_tab_items(&workspace)[0].badges[1], None);
        let pane = workspace.active_pane_id().to_owned();
        let tab = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("codex"), None).unwrap();

        for status in [
            AgentStatus::Starting,
            AgentStatus::Running,
            AgentStatus::Idle,
            AgentStatus::Waiting,
            AgentStatus::Error,
            AgentStatus::Running,
            AgentStatus::Stopped,
        ] {
            if status == AgentStatus::Stopped {
                workspace.stop_agent(&TerminalTarget::new(pane.clone(), tab.clone()));
            } else {
                workspace.update_agent_status(&pane, &tab, status, None, None);
            }
            let item = &window_tab_items(&workspace)[0];
            let open = status != AgentStatus::Stopped;
            assert_eq!(item.badges[1].is_some(), open);
            let expected = if open {
                format!("Window 1: Editor — 1 agent: 1 {}", status.display_label().to_lowercase())
            } else {
                "Window 1: Editor".to_owned()
            };
            assert_eq!(item.tooltip, expected);
            assert_eq!(item.title, "Editor");
            assert!(item.active);
        }
    }

    #[test]
    fn agent_badges_show_the_most_urgent_status() {
        let mut workspace = Workspace::new();
        let pane = workspace.active_pane_id().to_owned();
        let mut tabs = Vec::new();
        for _ in 0..3 {
            let tab = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("codex"), None).unwrap();
            workspace.update_agent_status(&pane, &tab, AgentStatus::Running, None, None);
            tabs.push(tab);
        }
        let badge = window_tab_items(&workspace)[0].badges[1].unwrap();
        assert_eq!((badge.count, badge.pill.label), (3, "Working"));

        workspace.update_agent_status(&pane, &tabs[0], AgentStatus::Waiting, None, None);
        let item = &window_tab_items(&workspace)[0];
        // A wait of a finished turn reads Done (as Swift's `StatusCountBadgeView`).
        assert_eq!(item.badges[1].unwrap().pill.label, "Done");
        assert!(item.tooltip.contains("1 needs input, 2 working"), "{}", item.tooltip);
        workspace.update_agent_status(&pane, &tabs[1], AgentStatus::Error, None, None);
        assert_eq!(window_tab_items(&workspace)[0].badges[1].unwrap().pill.label, "Failed");
    }

    // MARK: Top row chrome

    #[test]
    fn only_the_top_row_clears_the_traffic_lights_and_offers_the_sidebar_toggle_while_the_sidebar_is_hidden()
    {
        let hidden = TopRowChrome::new(true, false, Some(76.0), false);
        assert_eq!(hidden, TopRowChrome { leading_inset: 76.0, sidebar_toggle: true, window_buttons: false });
        // Linux/Windows (no traffic lights): Herdr's padding, plus the window buttons.
        let other = TopRowChrome::new(true, false, None, true);
        assert_eq!(
            other,
            TopRowChrome { leading_inset: ROW_PADDING, sidebar_toggle: true, window_buttons: true }
        );
        // The sidebar holds the lights.
        assert_eq!(TopRowChrome::new(true, true, Some(76.0), true).leading_inset, ROW_PADDING);
        assert!(!TopRowChrome::new(true, true, Some(76.0), true).sidebar_toggle);
        // The second row carries nothing.
        assert_eq!(
            TopRowChrome::new(false, false, Some(76.0), true),
            TopRowChrome { leading_inset: ROW_PADDING, sidebar_toggle: false, window_buttons: false }
        );
    }

    #[test]
    fn the_wheel_steps_tabs_vertically_and_leaves_horizontal_scrolling_to_the_strip() {
        let mut travel = 0.0;
        assert_eq!(wheel_outcome(ScrollDelta::Lines(point(0.0, 1.0)), &mut travel), WheelOutcome::Step(1));
        assert_eq!(wheel_outcome(ScrollDelta::Lines(point(0.0, -3.0)), &mut travel), WheelOutcome::Step(-1));
        assert_eq!(wheel_outcome(ScrollDelta::Lines(point(2.0, 1.0)), &mut travel), WheelOutcome::Horizontal);
        assert_eq!(
            wheel_outcome(ScrollDelta::Pixels(point(px(0.), px(10.))), &mut travel),
            WheelOutcome::Pending
        );
        assert_eq!(
            wheel_outcome(ScrollDelta::Pixels(point(px(0.), px(15.))), &mut travel),
            WheelOutcome::Step(1)
        );
        // A reversed swipe starts over.
        assert_eq!(
            wheel_outcome(ScrollDelta::Pixels(point(px(0.), px(20.))), &mut travel),
            WheelOutcome::Pending
        );
        assert_eq!(
            wheel_outcome(ScrollDelta::Pixels(point(px(0.), px(-20.))), &mut travel),
            WheelOutcome::Pending
        );
        assert_eq!(
            wheel_outcome(ScrollDelta::Pixels(point(px(0.), px(-5.))), &mut travel),
            WheelOutcome::Step(-1)
        );
    }

    // MARK: Views

    struct Rows {
        workspace: WorkspaceHandle,
        shell: Entity<Shell>,
        layout: Entity<LayoutTabRow>,
        windows: Entity<WindowTabRow>,
        commands: std::rc::Rc<std::cell::RefCell<Vec<Command>>>,
        cx: VisualTestContext,
    }

    fn rows(cx: &mut TestAppContext) -> Rows {
        cx.update(soprano_ui::init_for_tests);
        let state = StateStore::in_memory();
        let workspace = cx.update(|cx| WorkspaceHandle::new(Workspace::new(), cx));
        let shell = cx.new(|_| {
            Shell::new(state.clone(), AppSettings::default_settings(), DefaultKeybindings::config())
        });
        let commands = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
        let sink = commands.clone();
        cx.update(|cx| {
            cx.subscribe(&shell, move |_, command: &Command, _| sink.borrow_mut().push(command.clone()))
        })
        .detach();
        let (handle, shell_for_view, state_for_view) = (workspace.clone(), shell.clone(), state.clone());
        let window = cx.add_window(move |window, cx| {
            let sidebar = cx.new(|cx| RightSidebar::new(state_for_view, window, cx));
            let layout = cx.new(|cx| {
                LayoutTabRow::new(handle.clone(), shell_for_view.clone(), sidebar.clone(), window, cx)
            });
            let windows = cx.new(|cx| WindowTabRow::new(handle, shell_for_view, sidebar, window, cx));
            Host { layout, windows }
        });
        let host = window.root(cx).unwrap();
        let (layout, windows) = cx.read(|cx| (host.read(cx).layout.clone(), host.read(cx).windows.clone()));
        let cx = VisualTestContext::from_window(*window, cx);
        Rows { workspace, shell, layout, windows, commands, cx }
    }

    struct Host {
        layout: Entity<LayoutTabRow>,
        windows: Entity<WindowTabRow>,
    }

    impl Render for Host {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div().size_full().flex().flex_col().child(self.windows.clone()).child(self.layout.clone())
        }
    }

    impl Rows {
        fn mutate<R>(&mut self, f: impl FnOnce(&mut Workspace) -> R) -> R {
            let workspace = self.workspace.clone();
            self.cx.update(|_, cx| workspace.update(cx, f))
        }
    }

    #[gpui::test]
    fn clicking_selects_closes_and_adds_tabs(cx: &mut TestAppContext) {
        let mut rows = rows(cx);
        let first_pane = rows.cx.read(|cx| rows.workspace.read(cx).active_pane_id().to_owned());
        let second = rows.mutate(|ws| ws.create_layout_tab(None, None)).unwrap();
        let first = rows.cx.read(|cx| layout_tab_items(rows.workspace.read(cx))[0].id.clone());

        rows.layout.update(&mut rows.cx, |row, cx| row.activate(&first, cx));
        rows.cx.read(|cx| assert_eq!(rows.workspace.read(cx).active_pane_id(), first_pane));

        // Closing goes through the shell, which asks about unsaved editors.
        rows.layout.update(&mut rows.cx, |row, cx| row.close(&second, cx));
        assert_eq!(*rows.commands.borrow(), [Command::Close(CloseTarget::LayoutTab(second))]);

        rows.layout.update(&mut rows.cx, |row, cx| row.add_tab(cx));
        let items = rows.cx.read(|cx| layout_tab_items(rows.workspace.read(cx)));
        assert_eq!(items.len(), 3);
        assert!(items[2].active);
        rows.cx.run_until_parked();
    }

    #[gpui::test]
    fn the_wheel_switches_layout_tabs(cx: &mut TestAppContext) {
        let mut rows = rows(cx);
        rows.mutate(|ws| ws.create_layout_tab(None, None));
        let active = |rows: &mut Rows| {
            rows.cx.read(|cx| layout_tab_items(rows.workspace.read(cx)).iter().position(|item| item.active))
        };
        assert_eq!(active(&mut rows), Some(1));
        rows.layout.update(&mut rows.cx, |row, cx| row.scroll_tabs(ScrollDelta::Lines(point(0.0, -1.0)), cx));
        assert_eq!(active(&mut rows), Some(0));
        rows.layout.update(&mut rows.cx, |row, cx| row.scroll_tabs(ScrollDelta::Lines(point(0.0, 1.0)), cx));
        assert_eq!(active(&mut rows), Some(1));
    }

    #[gpui::test]
    fn the_files_and_changes_toggles_open_select_and_close_the_right_sidebar(cx: &mut TestAppContext) {
        let mut rows = rows(cx);
        let layout = rows.layout.clone();
        rows.cx.update(|window, cx| {
            layout.update(cx, |row, cx| {
                if row.panel_shown(RightSidebarTab::Explorer, cx) {
                    row.toggle_panel(RightSidebarTab::Explorer, window, cx);
                }
            })
        });
        rows.cx.update(|window, cx| {
            layout.update(cx, |row, cx| {
                assert!(!row.panel_shown(RightSidebarTab::Explorer, cx));
                row.toggle_panel(RightSidebarTab::Explorer, window, cx);
                assert!(row.panel_shown(RightSidebarTab::Explorer, cx));
                // The other toggle switches panels in the open sidebar.
                row.toggle_panel(RightSidebarTab::SourceControl, window, cx);
                assert!(row.panel_shown(RightSidebarTab::SourceControl, cx));
                assert!(!row.panel_shown(RightSidebarTab::Explorer, cx));
                // Pressed again, it closes the sidebar.
                row.toggle_panel(RightSidebarTab::SourceControl, window, cx);
                assert!(!row.panel_shown(RightSidebarTab::SourceControl, cx));
                assert!(!row.right_sidebar.read(cx).is_open());
            })
        });
    }

    #[gpui::test]
    fn hidden_window_tabs_leave_the_layout_row_on_top_and_catch_up_when_shown(cx: &mut TestAppContext) {
        let mut rows = rows(cx);
        rows.shell.update(&mut rows.cx, |shell, cx| {
            shell.settings.hide_window_tabs = true;
            cx.notify();
        });
        rows.cx.read(|cx| {
            assert!(!rows.windows.read(cx).is_shown(cx));
            assert!(rows.layout.read(cx).is_top(cx));
        });
        rows.mutate(|ws| ws.create_window(None, None));
        rows.windows.update(&mut rows.cx, |row, cx| row.add_window(cx));
        rows.shell.update(&mut rows.cx, |shell, cx| {
            shell.settings.hide_window_tabs = false;
            cx.notify();
        });
        rows.cx.run_until_parked();
        rows.cx.read(|cx| {
            assert!(rows.windows.read(cx).is_shown(cx));
            assert!(!rows.layout.read(cx).is_top(cx));
            assert_eq!(window_tab_items(rows.workspace.read(cx)).len(), 3);
        });
        let first = rows.cx.read(|cx| window_tab_items(rows.workspace.read(cx))[0].id.clone());
        rows.windows.update(&mut rows.cx, |row, cx| row.activate(&first, cx));
        rows.cx.read(|cx| assert_eq!(rows.workspace.read(cx).active_window_id(), first));
    }
}
