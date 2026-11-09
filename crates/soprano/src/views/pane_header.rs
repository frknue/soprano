//! A pane card's 30 px header (`Views/PaneHeaderView.swift`, HERDR-UI §7.2): the pane kind's
//! icon, title and dim working directory — or the pane tabs once the pane holds more than one
//! — the `+` pane-tab menu, the status pill (or the RUNNING mark of a shell running a
//! command), and the hover buttons split right / split down / maximize / close.
//!
//! Everything the Swift view computed (title, tab titles and prefixes, which buttons show,
//! the pill, the symbol, the `+` menu) is pure logic in [`HeaderModel`] and the functions
//! below; the element only lays it out.

use std::time::{Duration, SystemTime};

use gpui::{
    App, ClickEvent, Context, ElementId, Entity, FontWeight, Hsla, InteractiveElement, IntoElement,
    MouseButton, ParentElement, RenderOnce, ScrollHandle, SharedString, StatefulInteractiveElement, Styled,
    Task, Window, div, prelude::*,
};
use soprano_model::{
    PaneContentKind, PaneState, PaneTab, PaneType, SplitNode, Workspace, chat_supports, terminal_title,
};
use soprano_types::AgentCatalog;
use soprano_types::SplitDirection;
use soprano_ui::fonts::size;
use soprano_ui::tooltip::tooltip;
use soprano_ui::{
    ActiveSopranoTheme, ContextMenu, Icon, IconButton, IconButtonSize, IconName, MenuItem, StatusClock,
    StatusPill, StatusPillSpec, StatusTone,
};

use crate::shell::{self, CloseTarget, Command, Shell};
use crate::workspace::WorkspaceHandle;

/// Designed header height (HERDR-UI §7.2: the pane card's header is 30).
pub const HEADER_HEIGHT: f32 = 30.0;
/// A pane tab's side padding, close button and the room it keeps for its title
/// (`PaneTabButton.padding/closeSize/minWidth`).
const TAB_PADDING: f32 = 8.0;
const TAB_CLOSE_GAP: f32 = 4.0;
const TAB_MIN_WIDTH: f32 = TAB_PADDING + 26.0 + TAB_CLOSE_GAP + 14.0 + 4.0;

// MARK: - Pure logic

/// The pane kind's glyph (`PaneHeaderView.symbol(for:)`): an agent's program icon, else a
/// symbol. Documents are browser-type tabs, so a diff and a file are told apart before the
/// browser's globe.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HeaderIcon {
    /// `resources/icons/<stem>.svg`.
    Program(&'static str),
    Symbol(IconName),
}

impl HeaderIcon {
    fn icon(&self) -> Icon {
        match self {
            Self::Program(stem) => Icon::program(stem),
            Self::Symbol(name) => Icon::new(*name),
        }
    }
}

/// The program icon stem for an agent profile; agents without their own icon get the generic
/// agent glyph.
pub fn agent_icon_stem(profile_id: &str) -> &'static str {
    match profile_id {
        "claude-code" => "claude",
        "codex" => "codex",
        "opencode" => "opencode",
        "omp" => "pi",
        _ => "agent",
    }
}

pub fn header_icon(tab: Option<&PaneTab>) -> HeaderIcon {
    let Some(tab) = tab else { return HeaderIcon::Symbol(IconName::Terminal) };
    if tab.is_chat() {
        return HeaderIcon::Symbol(IconName::MessageSquare);
    }
    if let Some(agent) = &tab.agent {
        return HeaderIcon::Program(agent_icon_stem(&agent.profile_id));
    }
    if tab.is_diff() {
        return HeaderIcon::Symbol(IconName::FileDiff);
    }
    if tab.is_markdown() || tab.is_editor() || tab.is_file_preview() {
        return HeaderIcon::Symbol(IconName::FILE_TAB);
    }
    if tab.pane_type == PaneType::Browser {
        return HeaderIcon::Symbol(IconName::Globe);
    }
    HeaderIcon::Symbol(IconName::Terminal)
}

/// Whether a tab shows a terminal (a shell or a terminal agent), whose own title is a prompt
/// location or decorated agent title.
fn is_terminal_tab(tab: &PaneTab) -> bool {
    tab.pane_type != PaneType::Browser && tab.content_kind.is_none()
}

/// A tab's title as the header shows it: terminals and terminal agents through
/// [`terminal_title`], everything else verbatim.
pub fn tab_title(tab: &PaneTab, home: &str) -> String {
    if !is_terminal_tab(tab) {
        return tab.title.clone();
    }
    let agent_name = tab
        .agent
        .as_ref()
        .and_then(|agent| AgentCatalog::shared().profile(&agent.profile_id))
        .map(|profile| profile.name);
    terminal_title::display_in(&tab.title, tab.cwd.as_deref(), agent_name.as_deref(), home)
}

/// `path` with the home folder shown as `~`.
pub fn abbreviate_home(path: &str, home: &str) -> String {
    let home = home.trim_end_matches(std::path::is_separator);
    if home.is_empty() {
        return path.to_owned();
    }
    match path.strip_prefix(home) {
        Some("") => "~".to_owned(),
        Some(rest) if rest.starts_with(std::path::is_separator) => format!("~{rest}"),
        _ => path.to_owned(),
    }
}

/// What sits right of the title: an agent's status pill, or the RUNNING mark of a shell
/// running a command (`headerPill`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HeaderStatus {
    Pill(StatusPillSpec),
    Running,
}

impl HeaderStatus {
    fn tone(self) -> StatusTone {
        match self {
            Self::Pill(pill) => pill.tone,
            Self::Running => StatusTone::Working,
        }
    }
}

/// A dot before a pane tab's title: attention wins over a running command.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TabPrefix {
    Attention,
    Running,
}

/// One pane tab of the strip.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PaneTabModel {
    pub id: String,
    pub index: usize,
    pub title: String,
    pub prefix: Option<TabPrefix>,
    pub active: bool,
    /// A file preview tab: the title is slanted.
    pub slanted: bool,
}

impl PaneTabModel {
    /// The tab's text, `● title` with a prefix (`PaneTabButton.render`).
    #[cfg(test)]
    pub fn label(&self) -> String {
        match self.prefix {
            Some(_) => format!("● {}", self.title),
            None => self.title.clone(),
        }
    }

    pub fn tooltip(&self) -> String {
        match self.prefix {
            Some(TabPrefix::Attention) => "Needs attention".to_owned(),
            Some(TabPrefix::Running) => "Running a command".to_owned(),
            None => self.title.clone(),
        }
    }
}

/// Everything the header shows for one pane.
#[derive(Clone, Debug, PartialEq)]
pub struct HeaderModel {
    pub pane_id: String,
    pub icon: HeaderIcon,
    pub title: String,
    pub slanted: bool,
    /// The working directory, home as `~`; terminals and terminal agents only.
    pub cwd: Option<String>,
    pub status: Option<HeaderStatus>,
    /// The pane tabs; empty unless the pane holds more than one (they replace icon and title).
    pub tabs: Vec<PaneTabModel>,
    pub active_tab_id: Option<String>,
    pub can_add_tab: bool,
    pub is_focused: bool,
    /// A waiting or failed status, or an attention tab, washes the header in its tone.
    pub wash: Option<StatusTone>,
    /// `Some(maximized)` when the maximize button applies: the layout tab has several panes,
    /// or this pane is the maximized one.
    pub maximize: Option<bool>,
}

impl HeaderModel {
    pub fn new(ws: &Workspace, pane_id: &str, home: &str, clock: &mut StatusClock, now: SystemTime) -> Self {
        let pane = ws.pane(pane_id);
        let tab = pane.and_then(PaneState::active_tab);
        let status = header_status(ws, pane_id, tab, clock, now);
        let needs_attention = pane.is_some_and(|pane| {
            pane.tabs.iter().any(|tab| tab.agent.as_ref().is_some_and(|a| a.needs_attention))
        });
        let tabs = match pane {
            Some(pane) if pane.tabs.len() > 1 => pane_tabs(ws, pane, home),
            _ => Vec::new(),
        };
        let is_maximized = ws.maximized_pane_id() == Some(pane_id);
        let several_panes = ws.layout().map_or(0, SplitNode::leaf_count) > 1;
        Self {
            pane_id: pane_id.to_owned(),
            icon: header_icon(tab),
            title: tab.map_or_else(|| "Pane".to_owned(), |tab| tab_title(tab, home)),
            slanted: tab.is_some_and(PaneTab::is_file_preview),
            cwd: tab
                .filter(|tab| is_terminal_tab(tab))
                .and_then(PaneTab::effective_working_directory)
                .map(|cwd| abbreviate_home(&cwd, home)),
            status,
            tabs,
            active_tab_id: tab.map(|tab| tab.id.clone()),
            can_add_tab: pane.map_or(0, |pane| pane.tabs.len()) < PaneState::MAX_TABS_PER_PANE,
            is_focused: ws.active_pane_id() == pane_id,
            wash: wash_tone(status, needs_attention),
            maximize: (several_panes || is_maximized).then_some(is_maximized),
        }
    }

    pub fn add_tab_tooltip(&self) -> String {
        if self.can_add_tab {
            "New Pane Tab".to_owned()
        } else {
            format!("A pane holds at most {} tabs", PaneState::MAX_TABS_PER_PANE)
        }
    }

    /// The header's close button closes only the pane's active tab; the last tab takes the
    /// pane with it, and the last pane of a layout tab that tab.
    pub fn close_target(&self) -> Option<CloseTarget> {
        let tab_id = self.active_tab_id.clone()?;
        Some(CloseTarget::PaneTab { pane_id: self.pane_id.clone(), tab_id })
    }

    /// Whether the status shows a live duration ("Working 12s").
    pub fn has_live_time(&self) -> bool {
        matches!(self.status, Some(HeaderStatus::Pill(pill)) if pill.since.is_some())
    }
}

fn header_status(
    ws: &Workspace,
    pane_id: &str,
    tab: Option<&PaneTab>,
    clock: &mut StatusClock,
    now: SystemTime,
) -> Option<HeaderStatus> {
    let tab = tab?;
    if let Some(agent) = &tab.agent {
        return clock
            .pill(&agent.id, agent.status, agent.waiting_reason, agent.started_at, now)
            .map(HeaderStatus::Pill);
    }
    ws.is_running_command(tab, pane_id).then_some(HeaderStatus::Running)
}

/// Statuses that wash the header (someone has to answer, or it failed), else the attention
/// wash of a pane with an attention tab.
pub fn wash_tone(status: Option<HeaderStatus>, needs_attention: bool) -> Option<StatusTone> {
    match status.map(HeaderStatus::tone) {
        Some(tone @ (StatusTone::Approval | StatusTone::Input | StatusTone::Failed)) => Some(tone),
        _ => needs_attention.then_some(StatusTone::Approval),
    }
}

fn pane_tabs(ws: &Workspace, pane: &PaneState, home: &str) -> Vec<PaneTabModel> {
    let active_index = pane.clamped_active_index();
    pane.tabs
        .iter()
        .enumerate()
        .map(|(index, tab)| {
            let prefix = if tab.agent.as_ref().is_some_and(|agent| agent.needs_attention) {
                Some(TabPrefix::Attention)
            } else if ws.is_running_command(tab, &pane.id) {
                Some(TabPrefix::Running)
            } else {
                None
            };
            PaneTabModel {
                id: tab.id.clone(),
                index,
                title: tab_title(tab, home),
                prefix,
                active: index == active_index,
                slanted: tab.is_file_preview(),
            }
        })
        .collect()
}

/// What one item of the `+` menu opens in the pane.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AddTabAction {
    Terminal,
    Browser,
    Agent(String),
    Chat(String),
    /// Asks for a Markdown file, then opens it here.
    Markdown,
}

/// One row of the `+` menu.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AddTabEntry {
    /// `terminal`, `browser`, `agent-<profile>`, `chat-<profile>`, `markdown`.
    pub id: String,
    pub label: String,
    pub icon: IconName,
    pub action: AddTabAction,
}

/// The `+` menu (`addTabMenu()`): a terminal, a browser, each agent as a terminal, each
/// chat-capable agent as a chat, and a Markdown file; `None` is a separator.
pub fn add_tab_menu_entries() -> Vec<Option<AddTabEntry>> {
    let entry = |id: String, label: String, icon, action| Some(AddTabEntry { id, label, icon, action });
    let profiles = AgentCatalog::shared().all();
    let mut entries = vec![
        entry("terminal".into(), "Terminal".into(), IconName::Terminal, AddTabAction::Terminal),
        entry("browser".into(), "Browser".into(), IconName::Globe, AddTabAction::Browser),
        None,
    ];
    entries.extend(profiles.iter().filter(|profile| profile.id != "terminal").map(|profile| {
        entry(
            format!("agent-{}", profile.id),
            profile.name.clone(),
            IconName::SUBAGENT,
            AddTabAction::Agent(profile.id.clone()),
        )
    }));
    entries.extend(profiles.iter().filter(|profile| chat_supports(&profile.id)).map(|profile| {
        entry(
            format!("chat-{}", profile.id),
            format!("{} Chat", profile.name),
            IconName::MessageSquare,
            AddTabAction::Chat(profile.id.clone()),
        )
    }));
    entries.push(None);
    entries.push(entry(
        "markdown".into(),
        "Markdown File…".into(),
        IconName::FILE_TAB,
        AddTabAction::Markdown,
    ));
    entries
}

/// Opens `action`'s tab in `pane_id` and focuses the pane; the new tab's id. Markdown goes
/// through the file picker ([`Command::OpenMarkdown`]) instead.
pub fn add_tab(ws: &mut Workspace, pane_id: &str, action: &AddTabAction) -> Option<String> {
    let tab_id = match action {
        AddTabAction::Terminal => ws.add_tab_to_pane(pane_id, PaneType::Terminal, None, None),
        AddTabAction::Browser => ws.add_tab_to_pane(pane_id, PaneType::Browser, None, None),
        AddTabAction::Agent(profile) => ws.add_tab_to_pane(pane_id, PaneType::Agent, Some(profile), None),
        AddTabAction::Chat(profile) => {
            ws.add_tab_to_pane(pane_id, PaneType::Agent, Some(profile), Some(PaneContentKind::CHAT))
        }
        AddTabAction::Markdown => None,
    }?;
    ws.focus_pane(pane_id);
    Some(tab_id)
}

/// Split right puts the new pane beside this one, split down below it — the `split-vertical`
/// and `split-horizontal` bindings (`soprano_keys::split_direction`).
pub fn split_right_direction() -> SplitDirection {
    soprano_keys::split_direction("split-vertical").unwrap_or(SplitDirection::Horizontal)
}

pub fn split_down_direction() -> SplitDirection {
    soprano_keys::split_direction("split-horizontal").unwrap_or(SplitDirection::Vertical)
}

// MARK: - Element

#[derive(IntoElement)]
pub struct PaneHeader {
    pane_id: String,
    workspace: WorkspaceHandle,
    shell: Entity<Shell>,
}

impl PaneHeader {
    pub fn new(pane_id: impl Into<String>, workspace: WorkspaceHandle, shell: Entity<Shell>) -> Self {
        Self { pane_id: pane_id.into(), workspace, shell }
    }
}

/// The tab strip's scroll position and the active tab it last revealed.
struct TabStrip {
    scroll: ScrollHandle,
    revealed: Option<String>,
}

/// Redraws the window once a second while the header shows a live duration; dropped (and
/// stopped) the first frame it is not rendered.
struct LiveClock {
    _task: Task<()>,
}

impl LiveClock {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let task = cx.spawn_in(window, async move |_, cx| {
            loop {
                cx.background_executor().timer(Duration::from_secs(1)).await;
                if cx.update(|window, _| window.refresh()).is_err() {
                    break;
                }
            }
        });
        Self { _task: task }
    }
}

impl RenderOnce for PaneHeader {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let home = soprano_platform::paths::home_dir().to_string_lossy().into_owned();
        let now = SystemTime::now();
        // `StatusClock` is a global; take it out so the model can read the workspace alongside.
        let mut clock = std::mem::take(cx.default_global::<StatusClock>());
        let model = HeaderModel::new(self.workspace.read(cx), &self.pane_id, &home, &mut clock, now);
        *cx.default_global::<StatusClock>() = clock;
        if model.has_live_time() {
            window.use_keyed_state(
                ElementId::Name(format!("pane-header-clock-{}", self.pane_id).into()),
                cx,
                LiveClock::new,
            );
        }
        let leading = if model.tabs.is_empty() {
            self.title_row(&model, cx).into_any_element()
        } else {
            self.tab_strip(&model, window, cx).into_any_element()
        };

        let theme = cx.soprano_theme();
        let z = |v: f32| theme.z(v);
        let group: SharedString = format!("pane-header-{}", self.pane_id).into();
        let mut background = theme.background;
        if let Some(tone) = model.wash {
            background = background.blend(theme.tone(tone).opacity(0.10));
        }
        let (dim, muted, border, running) = (theme.dim, theme.muted, theme.border, theme.running_command);

        let add_button = {
            let (pane_id, workspace, shell) =
                (self.pane_id.clone(), self.workspace.clone(), self.shell.clone());
            IconButton::new(
                ElementId::Name(format!("pane-add-tab-button-{}", self.pane_id).into()),
                IconName::Plus,
            )
            .size(IconButtonSize::Pane)
            .color(dim)
            .disabled(!model.can_add_tab)
            .tooltip(model.add_tab_tooltip())
            .on_click(move |event: &ClickEvent, window, cx| {
                show_add_tab_menu(&pane_id, &workspace, &shell, event, window, cx);
            })
        };

        let status = model.status.map(|status| match status {
            HeaderStatus::Pill(pill) => StatusPill::new(Some(pill)).now(now).into_any_element(),
            HeaderStatus::Running => div()
                .flex_none()
                .text_size(z(size::SMALL))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(running)
                .child(Workspace::RUNNING_COMMAND_LABEL)
                .into_any_element(),
        });
        let hover_buttons = self.hover_buttons(&model, group.clone(), cx);

        div()
            .id(ElementId::Name(format!("pane-header-{}", self.pane_id).into()))
            .group(group)
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .w_full()
            .h(z(HEADER_HEIGHT))
            .px(z(10.))
            .gap(z(8.))
            .bg(background)
            .border_b_1()
            .border_color(border)
            .text_size(z(size::META))
            .text_color(muted)
            .on_mouse_down(MouseButton::Left, {
                let (pane_id, workspace) = (self.pane_id.clone(), self.workspace.clone());
                move |_, _, cx| workspace.update(cx, |ws| ws.focus_pane(&pane_id))
            })
            .child(leading)
            .child(add_button)
            .when(!model.tabs.is_empty(), |header| header.child(div().flex_1()))
            .children(status)
            .child(hover_buttons)
    }
}

impl PaneHeader {
    /// Icon, title (medium `foreground` when focused, else `muted`) and dim cwd.
    fn title_row(&self, model: &HeaderModel, cx: &App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let z = |v: f32| theme.z(v);
        let (title_color, title_weight, icon_color) = if model.is_focused {
            (theme.foreground, FontWeight::MEDIUM, theme.foreground)
        } else {
            (theme.muted, FontWeight::NORMAL, theme.dim)
        };
        let dim = theme.dim;
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap(z(8.))
            .flex_1()
            .min_w_0()
            .overflow_hidden()
            .child(model.icon.icon().size(14.).color(icon_color))
            .child(
                div()
                    .flex_none()
                    .max_w(z(260.))
                    .truncate()
                    .text_color(title_color)
                    .font_weight(title_weight)
                    .when(model.slanted, |title| title.italic())
                    .child(model.title.clone()),
            )
            .when_some(model.cwd.clone(), |row, cwd| {
                row.child(div().flex_1().min_w_0().truncate().text_color(dim).child(cwd))
            })
    }

    fn tab_strip(&self, model: &HeaderModel, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let strip = window.use_keyed_state(
            ElementId::Name(format!("pane-tab-strip-{}", self.pane_id).into()),
            cx,
            |_, _| TabStrip { scroll: ScrollHandle::new(), revealed: None },
        );
        let scroll = strip.update(cx, |strip, _| {
            if strip.revealed != model.active_tab_id {
                strip.revealed = model.active_tab_id.clone();
                if let Some(active) = model.tabs.iter().find(|tab| tab.active) {
                    strip.scroll.scroll_to_item(active.index);
                }
            }
            strip.scroll.clone()
        });
        let tabs: Vec<_> = model.tabs.iter().map(|tab| self.pane_tab(tab, cx)).collect();
        let theme = cx.soprano_theme();
        div()
            .id(ElementId::Name(format!("pane-tabs-{}", self.pane_id).into()))
            .flex()
            .flex_row()
            .items_center()
            .gap(theme.z(2.))
            .h(theme.z(22.))
            .min_w_0()
            .overflow_x_scroll()
            .track_scroll(&scroll)
            .children(tabs)
    }

    fn pane_tab(&self, tab: &PaneTabModel, cx: &App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let z = |v: f32| theme.z(v);
        let group: SharedString = format!("pane-tab-{}", tab.id).into();
        let (fill, text, weight) = if tab.active {
            (theme.selected, theme.foreground, FontWeight::MEDIUM)
        } else {
            (gpui::transparent_black(), theme.muted, FontWeight::NORMAL)
        };
        let hover = theme.hover;
        let prefix_color: Option<Hsla> = tab.prefix.map(|prefix| match prefix {
            TabPrefix::Attention => theme.approval,
            TabPrefix::Running => theme.working,
        });
        let close = {
            let (pane_id, tab_id, shell) = (self.pane_id.clone(), tab.id.clone(), self.shell.clone());
            div()
                .flex_none()
                .when(!tab.active, |close| close.invisible().group_hover(group.clone(), |s| s.visible()))
                .child(
                    IconButton::new(
                        ElementId::Name(format!("close-pane-tab-{}", tab.id).into()),
                        IconName::X,
                    )
                    .size(IconButtonSize::Tab)
                    .icon_size(10.)
                    .color(theme.dim)
                    .tooltip("Close Tab")
                    .on_click(move |_, _, cx| {
                        cx.stop_propagation();
                        shell::dispatch(
                            &shell,
                            Command::Close(CloseTarget::PaneTab {
                                pane_id: pane_id.clone(),
                                tab_id: tab_id.clone(),
                            }),
                            cx,
                        );
                    }),
                )
        };
        let (pane_id, workspace, index) = (self.pane_id.clone(), self.workspace.clone(), tab.index);
        div()
            .id(ElementId::Name(format!("pane-tab-{}", tab.id).into()))
            .group(group)
            .flex()
            .flex_row()
            .items_center()
            .gap(z(TAB_CLOSE_GAP))
            .h_full()
            .min_w(z(TAB_MIN_WIDTH))
            .pl(z(TAB_PADDING))
            .pr(z(4.))
            .rounded(z(6.))
            .bg(fill)
            .text_color(text)
            .font_weight(weight)
            .cursor_pointer()
            .when(!tab.active, |row| row.hover(move |s| s.bg(hover)))
            .when_some(prefix_color, |row, color| row.child(div().flex_none().text_color(color).child("●")))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .when(tab.slanted, |title| title.italic())
                    .child(tab.title.clone()),
            )
            .child(close)
            .tooltip(tooltip(tab.tooltip()))
            .on_click(move |_, _, cx| {
                workspace.update(cx, |ws| ws.switch_tab(&pane_id, index));
            })
    }

    fn hover_buttons(&self, model: &HeaderModel, group: SharedString, cx: &App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let dim = theme.dim;
        let button = |id: &str, icon: IconName, label: &str| {
            IconButton::new(ElementId::Name(format!("pane-{id}-{}", self.pane_id).into()), icon)
                .size(IconButtonSize::Pane)
                .color(dim)
                .tooltip(label.to_owned())
        };
        let split = |id: &str, icon: IconName, label: &str, direction: SplitDirection| {
            let (pane_id, workspace) = (self.pane_id.clone(), self.workspace.clone());
            button(id, icon, label).on_click(move |_, _, cx| {
                workspace.update(cx, |ws| ws.split_pane(direction, &pane_id));
            })
        };
        let maximize = model.maximize.map(|maximized| {
            let (pane_id, workspace) = (self.pane_id.clone(), self.workspace.clone());
            let (icon, label) = if maximized {
                (IconName::Unzoom, "Restore Pane")
            } else {
                (IconName::Zoom, "Maximize Pane")
            };
            button("maximize", icon, label).on_click(move |_, _, cx| {
                workspace.update(cx, |ws| {
                    ws.focus_pane(&pane_id);
                    ws.toggle_maximize();
                });
            })
        });
        let close = model.close_target().map(|target| {
            let shell = self.shell.clone();
            button("close-button", IconName::PaneClose, "Close active tab")
                .on_click(move |_, _, cx| shell::dispatch(&shell, Command::Close(target.clone()), cx))
        });
        div()
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(theme.z(2.))
            .invisible()
            .group_hover(group, |s| s.visible())
            .child(split("split-right", IconName::SplitRight, "Split Right", split_right_direction()))
            .child(split("split-down", IconName::SplitDown, "Split Down", split_down_direction()))
            .children(maximize)
            .children(close)
    }
}

fn show_add_tab_menu(
    pane_id: &str,
    workspace: &WorkspaceHandle,
    shell: &Entity<Shell>,
    event: &ClickEvent,
    window: &mut Window,
    cx: &mut App,
) {
    let items = add_tab_menu_entries()
        .into_iter()
        .map(|entry| {
            let Some(entry) = entry else { return MenuItem::separator() };
            let (pane_id, workspace, shell) = (pane_id.to_owned(), workspace.clone(), shell.clone());
            let action = entry.action;
            MenuItem::new(entry.label).icon(entry.icon).on_select(move |_, cx| match &action {
                AddTabAction::Markdown => {
                    shell::dispatch(&shell, Command::OpenMarkdown { pane_id: Some(pane_id.clone()) }, cx);
                }
                action => {
                    workspace.update(cx, |ws| add_tab(ws, &pane_id, action));
                }
            })
        })
        .collect();
    let menu = ContextMenu::new(event.position(), items, window, cx);
    shell.update(cx, |shell, cx| shell.show_popup(menu, window, cx));
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use soprano_types::TerminalTarget;
    use soprano_types::{AgentStatus, AgentWaitingReason};

    use super::*;

    const HOME: &str = "/Users/tester";

    fn model(ws: &Workspace, pane_id: &str) -> HeaderModel {
        HeaderModel::new(ws, pane_id, HOME, &mut StatusClock::default(), SystemTime::now())
    }

    fn close(ws: &mut Workspace, pane_id: &str) {
        match model(ws, pane_id).close_target() {
            Some(CloseTarget::PaneTab { pane_id, tab_id }) => {
                ws.remove_tab_from_pane(&pane_id, &tab_id);
            }
            other => panic!("unexpected close target {other:?}"),
        }
    }

    fn choose(ws: &mut Workspace, pane_id: &str, id: &str) -> Option<String> {
        let entry = add_tab_menu_entries().into_iter().flatten().find(|entry| entry.id == id).expect(id);
        add_tab(ws, pane_id, &entry.action)
    }

    fn active_tab_id(ws: &Workspace, pane_id: &str) -> String {
        ws.pane(pane_id).unwrap().active_tab().unwrap().id.clone()
    }

    fn tab_ids(ws: &Workspace, pane_id: &str) -> Vec<String> {
        ws.pane(pane_id).unwrap().tabs.iter().map(|tab| tab.id.clone()).collect()
    }

    #[test]
    fn closing_one_pane_of_a_split_tab_keeps_its_sibling_and_only_the_last_pane_closes_the_tab() {
        let mut ws = Workspace::new();
        let root_pane = ws.active_pane_id().to_owned();
        ws.create_layout_tab(None, None).unwrap();
        let first = ws.active_pane_id().to_owned();
        let second = ws.split_pane(SplitDirection::Horizontal, &first).unwrap();

        close(&mut ws, &second);
        assert!(ws.pane(&second).is_none());
        assert!(ws.pane(&first).is_some());
        assert_eq!(ws.active_window().unwrap().active_tab_index(), 1);
        assert_eq!(ws.layout().unwrap().ordered_leaf_ids(), vec![first.clone()]);

        close(&mut ws, &first);
        assert!(ws.pane(&first).is_none());
        assert_eq!(ws.active_window().unwrap().tabs().len(), 1);
        assert_eq!(ws.active_pane_id(), root_pane);
        assert_eq!(ws.layout().unwrap().ordered_leaf_ids(), vec![root_pane]);
    }

    #[test]
    fn closing_in_a_tab_closes_only_the_panes_active_pane_tab() {
        let mut ws = Workspace::new();
        ws.create_layout_tab(None, None).unwrap();
        let pane = ws.active_pane_id().to_owned();
        let first_tab = active_tab_id(&ws, &pane);
        ws.add_tab_to_pane(&pane, PaneType::Terminal, None, None).unwrap();

        close(&mut ws, &pane);
        assert_eq!(tab_ids(&ws, &pane), vec![first_tab]);
        assert_eq!(ws.active_window().unwrap().active_tab_index(), 1);
    }

    #[test]
    fn the_active_pane_tab_shows_its_close_button_and_each_tab_closes_only_itself() {
        let mut ws = Workspace::new();
        let pane = ws.active_pane_id().to_owned();
        let first = active_tab_id(&ws, &pane);
        let second = ws.add_tab_to_pane(&pane, PaneType::Terminal, None, None).unwrap();
        let tabs = model(&ws, &pane).tabs;
        assert_eq!(
            tabs.iter().map(|t| (t.id.clone(), t.active)).collect::<Vec<_>>(),
            vec![(first.clone(), false), (second.clone(), true)]
        );

        ws.remove_tab_from_pane(&pane, &first);
        assert_eq!(tab_ids(&ws, &pane), vec![second.clone()]);
        assert_eq!(active_tab_id(&ws, &pane), second);
    }

    #[test]
    fn clicking_an_inactive_pane_tab_switches_the_pane_to_that_tab() {
        let mut ws = Workspace::new();
        let pane = ws.active_pane_id().to_owned();
        let first = active_tab_id(&ws, &pane);
        ws.add_tab_to_pane(&pane, PaneType::Terminal, None, None).unwrap();
        let tab = model(&ws, &pane).tabs.into_iter().find(|t| t.id == first).unwrap();
        ws.switch_tab(&pane, tab.index);
        assert_eq!(active_tab_id(&ws, &pane), first);
    }

    #[test]
    fn the_plus_menu_opens_terminals_browsers_agents_and_chats_as_tabs_of_that_split_only_until_it_is_full() {
        let mut ws = Workspace::new();
        let left = ws.active_pane_id().to_owned();
        let right = ws.split_pane(SplitDirection::Horizontal, &left).unwrap();
        ws.focus_pane(&left);
        let chat_profile =
            AgentCatalog::shared().all().into_iter().find(|p| chat_supports(&p.id)).unwrap().id;

        choose(&mut ws, &right, "terminal").unwrap();
        assert_eq!(ws.active_pane_id(), right);
        choose(&mut ws, &right, "browser").unwrap();
        choose(&mut ws, &right, "agent-claude-code").unwrap();
        choose(&mut ws, &right, &format!("chat-{chat_profile}")).unwrap();

        let pane = ws.pane(&right).unwrap();
        let added = &pane.tabs[1..];
        assert_eq!(
            added.iter().map(|t| t.pane_type).collect::<Vec<_>>(),
            vec![PaneType::Terminal, PaneType::Browser, PaneType::Agent, PaneType::Agent]
        );
        assert_eq!(
            added.iter().map(PaneTab::is_web_browser).collect::<Vec<_>>(),
            vec![false, true, false, false]
        );
        assert_eq!(
            added.iter().map(|t| t.agent.as_ref().map(|a| a.profile_id.clone())).collect::<Vec<_>>(),
            vec![None, None, Some("claude-code".to_owned()), Some(chat_profile.clone())]
        );
        assert_eq!(added.iter().map(PaneTab::is_chat).collect::<Vec<_>>(), vec![false, false, false, true]);
        assert_eq!(pane.active_tab().unwrap().id, added.last().unwrap().id);
        assert_eq!(ws.pane(&left).unwrap().tabs.len(), 1);
        assert!(add_tab_menu_entries().into_iter().flatten().any(|e| e.id == "markdown"));

        while ws.pane(&right).unwrap().tabs.len() < PaneState::MAX_TABS_PER_PANE {
            assert!(model(&ws, &right).can_add_tab);
            choose(&mut ws, &right, "terminal").unwrap();
        }
        let full = model(&ws, &right);
        assert!(!full.can_add_tab);
        assert_eq!(full.add_tab_tooltip(), "A pane holds at most 10 tabs");
        assert_eq!(choose(&mut ws, &right, "terminal"), None);
    }

    #[test]
    fn the_plus_menu_lists_every_kind_in_swift_order() {
        let labels: Vec<_> = add_tab_menu_entries()
            .iter()
            .map(|e| e.as_ref().map_or("—".to_owned(), |e| e.label.clone()))
            .collect();
        let profiles = AgentCatalog::shared().all();
        let mut expected = vec!["Terminal".to_owned(), "Browser".to_owned(), "—".to_owned()];
        expected.extend(profiles.iter().filter(|p| p.id != "terminal").map(|p| p.name.clone()));
        expected.extend(profiles.iter().filter(|p| chat_supports(&p.id)).map(|p| format!("{} Chat", p.name)));
        expected.extend(["—".to_owned(), "Markdown File…".to_owned()]);
        assert_eq!(labels, expected);
    }

    #[test]
    fn pane_tabs_mark_the_active_tab_and_prefix_attention_and_running_tabs() {
        let mut ws = Workspace::new();
        let pane = ws.active_pane_id().to_owned();
        let first = active_tab_id(&ws, &pane);
        ws.rename_tab(&pane, &first, "server");
        let agent_tab = ws.add_tab_to_pane(&pane, PaneType::Terminal, None, None).unwrap();
        ws.attach_agent_if_needed(&pane, &agent_tab, "codex");
        ws.rename_tab(&pane, &agent_tab, "Codex");
        ws.update_agent_status(&pane, &agent_tab, AgentStatus::Waiting, Some(true), None);
        ws.set_running_command_targets(HashSet::from([TerminalTarget::new(&pane, &first)]));
        ws.switch_tab(&pane, 0);

        let tabs = model(&ws, &pane).tabs;
        assert_eq!(tabs.iter().map(PaneTabModel::label).collect::<Vec<_>>(), vec!["● server", "● Codex"]);
        assert_eq!(
            tabs.iter().map(|t| t.prefix).collect::<Vec<_>>(),
            vec![Some(TabPrefix::Running), Some(TabPrefix::Attention)]
        );
        assert_eq!(tabs.iter().map(|t| t.active).collect::<Vec<_>>(), vec![true, false]);
        assert_eq!(
            tabs.iter().map(PaneTabModel::tooltip).collect::<Vec<_>>(),
            vec!["Running a command", "Needs attention"]
        );
    }

    #[test]
    fn only_the_pane_tab_running_a_command_carries_its_lamp_in_the_tab_strip() {
        let mut ws = Workspace::new();
        let pane = ws.active_pane_id().to_owned();
        let idle = active_tab_id(&ws, &pane);
        let server = ws.add_tab_to_pane(&pane, PaneType::Terminal, None, None).unwrap();
        ws.set_running_command_targets(HashSet::from([TerminalTarget::new(&pane, &server)]));

        let header = model(&ws, &pane);
        let prefixes: Vec<_> = header.tabs.iter().map(|t| (t.id.clone(), t.prefix)).collect();
        assert_eq!(prefixes, vec![(idle, None), (server, Some(TabPrefix::Running))]);
        // The server tab is active, so the header's own mark reports it too.
        assert_eq!(header.status, Some(HeaderStatus::Running));
        assert_eq!(Workspace::RUNNING_COMMAND_LABEL, "RUNNING");
    }

    #[test]
    fn a_single_tab_pane_shows_icon_title_and_cwd_instead_of_tabs() {
        let mut ws = Workspace::new();
        let pane = ws.active_pane_id().to_owned();
        let tab = active_tab_id(&ws, &pane);
        ws.update_working_directory(&pane, &tab, "/Users/tester/git/shop");
        ws.rename_tab(&pane, &tab, "npm run dev");
        let header = model(&ws, &pane);
        assert!(header.tabs.is_empty());
        assert_eq!(header.icon, HeaderIcon::Symbol(IconName::Terminal));
        assert_eq!(header.title, "npm run dev");
        assert_eq!(header.cwd.as_deref(), Some("~/git/shop"));
        assert!(header.is_focused);
        assert_eq!(header.status, None);
    }

    #[test]
    fn a_shell_prompt_title_reads_as_its_folder() {
        let mut ws = Workspace::new();
        let pane = ws.active_pane_id().to_owned();
        let tab = active_tab_id(&ws, &pane);
        ws.rename_tab(&pane, &tab, "user@host:~/git/shop");
        assert_eq!(model(&ws, &pane).title, "shop");
    }

    #[test]
    fn an_agent_pane_shows_its_program_icon_name_and_status_pill() {
        let mut ws = Workspace::new();
        let pane = ws.spawn_agent("claude-code", Some("/tmp/project"), false).unwrap();
        let tab = active_tab_id(&ws, &pane);
        ws.update_agent_status(
            &pane,
            &tab,
            AgentStatus::Waiting,
            Some(false),
            Some(AgentWaitingReason::TurnEnded),
        );
        let header = model(&ws, &pane);
        assert_eq!(header.icon, HeaderIcon::Program("claude"));
        assert_eq!(header.title, "Claude Code");
        match header.status {
            Some(HeaderStatus::Pill(pill)) => {
                assert_eq!(pill.label, "Done");
                assert_eq!(pill.tone, StatusTone::Done);
            }
            other => panic!("expected a Done pill, got {other:?}"),
        }
        assert_eq!(header.wash, None);
    }

    #[test]
    fn header_washes_follow_the_component_precedence() {
        let input =
            StatusPillSpec::of(AgentStatus::Waiting, Some(AgentWaitingReason::Question), None).unwrap();
        let done =
            StatusPillSpec::of(AgentStatus::Waiting, Some(AgentWaitingReason::TurnEnded), None).unwrap();
        assert_eq!(wash_tone(Some(HeaderStatus::Pill(input)), true), Some(StatusTone::Input));
        assert_eq!(wash_tone(Some(HeaderStatus::Pill(done)), true), Some(StatusTone::Approval));
        assert_eq!(wash_tone(None, true), Some(StatusTone::Approval));
        assert_eq!(wash_tone(Some(HeaderStatus::Running), false), None);
        assert_eq!(wash_tone(None, false), None);
    }

    #[test]
    fn documents_browsers_and_chats_get_their_own_symbols() {
        let mut tab = PaneTab::new("t", PaneType::Browser, "Page");
        assert_eq!(header_icon(Some(&tab)), HeaderIcon::Symbol(IconName::Globe));
        tab.content_kind = Some(PaneContentKind::MARKDOWN.to_owned());
        assert_eq!(header_icon(Some(&tab)), HeaderIcon::Symbol(IconName::FILE_TAB));
        tab.content_kind = Some(PaneContentKind::EDITOR.to_owned());
        assert_eq!(header_icon(Some(&tab)), HeaderIcon::Symbol(IconName::FILE_TAB));
        tab.content_kind = Some(PaneContentKind::DIFF.to_owned());
        assert_eq!(header_icon(Some(&tab)), HeaderIcon::Symbol(IconName::FileDiff));
        let mut chat = PaneTab::new("c", PaneType::Agent, "omp Chat");
        chat.content_kind = Some(PaneContentKind::CHAT.to_owned());
        assert_eq!(header_icon(Some(&chat)), HeaderIcon::Symbol(IconName::MessageSquare));
        assert_eq!(header_icon(None), HeaderIcon::Symbol(IconName::Terminal));
        // Document titles stay verbatim.
        assert_eq!(tab_title(&tab, HOME), "Page");
    }

    #[test]
    fn the_maximize_button_shows_for_split_layouts_and_reflects_the_maximized_pane() {
        let mut ws = Workspace::new();
        let left = ws.active_pane_id().to_owned();
        assert_eq!(model(&ws, &left).maximize, None);
        let right = ws.split_pane(split_right_direction(), &left).unwrap();
        assert_eq!(model(&ws, &left).maximize, Some(false));
        ws.focus_pane(&right);
        ws.toggle_maximize();
        assert_eq!(model(&ws, &right).maximize, Some(true));
        assert_eq!(model(&ws, &left).maximize, Some(false));
    }

    #[test]
    fn split_right_places_panes_side_by_side_and_split_down_stacks_them() {
        assert_eq!(split_right_direction(), SplitDirection::Horizontal);
        assert_eq!(split_down_direction(), SplitDirection::Vertical);
    }

    #[test]
    fn home_is_shown_as_a_tilde() {
        assert_eq!(abbreviate_home("/Users/tester", HOME), "~");
        assert_eq!(abbreviate_home("/Users/tester/git", HOME), "~/git");
        assert_eq!(abbreviate_home("/Users/testerx/git", HOME), "/Users/testerx/git");
        assert_eq!(abbreviate_home("/tmp", HOME), "/tmp");
    }
}
