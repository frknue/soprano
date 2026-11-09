//! The chrome's building blocks in Herdr's measurements: sidebar rows and section headers,
//! card frames, tab pills, panel toggles, the status bar and scroll lists.
//!
//! Each builder takes `Styled` refinements applied after its own look, so callers can size or
//! adjust it (`SidebarRow::new("r").pl(px(22.))`).

use std::rc::Rc;

use gpui::{
    AnyElement, App, ClickEvent, ElementId, FontWeight, Hsla, InteractiveElement, IntoElement, MouseButton,
    MouseDownEvent, ParentElement, Pixels, Point, Refineable, RenderOnce, ScrollHandle, SharedString,
    StatefulInteractiveElement, StyleRefinement, Styled, Window, div, prelude::*,
};
use gpui_component::scroll::{Scrollbar, ScrollbarAxis, ScrollbarMode};

use crate::button::{ClickHandler, IconButton, IconButtonSize};
use crate::fonts::size;
use crate::icons::{Icon, IconName, icon};
use crate::status::{StatusGlyph, TabBadge, TabBadgeView};
use crate::theme::ActiveSopranoTheme;
use crate::tooltip::tooltip;

/// A secondary-click handler with the pointer's window position (for [`crate::ContextMenu`]).
pub type PointHandler = Rc<dyn Fn(Point<Pixels>, &mut Window, &mut App)>;

/// A mouse-down handler.
pub type MouseDownHandler = Rc<dyn Fn(&MouseDownEvent, &mut Window, &mut App)>;

macro_rules! styled_parent {
    ($ty:ident) => {
        impl Styled for $ty {
            fn style(&mut self) -> &mut StyleRefinement {
                &mut self.style
            }
        }

        impl ParentElement for $ty {
            fn extend(&mut self, elements: impl IntoIterator<Item = AnyElement>) {
                self.children.extend(elements);
            }
        }
    };
}

fn secondary_click(handler: PointHandler) -> impl Fn(&MouseDownEvent, &mut Window, &mut App) + 'static {
    move |event, window, cx| {
        cx.stop_propagation();
        handler(event.position, window, cx);
    }
}

/// A sidebar, tree or menu-like row: h30 (default), px 8, gap 9, radius 8, items centered.
/// Selected rows fill `selected` and do not change on hover; others fill `hover` under the
/// pointer.
#[derive(IntoElement)]
pub struct SidebarRow {
    id: ElementId,
    height: f32,
    selected: bool,
    style: StyleRefinement,
    children: Vec<AnyElement>,
    on_click: Option<ClickHandler>,
    on_secondary_click: Option<PointHandler>,
    tooltip: Option<SharedString>,
}

styled_parent!(SidebarRow);

impl SidebarRow {
    pub fn new(id: impl Into<ElementId>) -> Self {
        Self {
            id: id.into(),
            height: 30.0,
            selected: false,
            style: StyleRefinement::default(),
            children: Vec::new(),
            on_click: None,
            on_secondary_click: None,
            tooltip: None,
        }
    }

    /// Row height in designed px (30 rows, 28 footer and tree rows, 26 sub-agents).
    pub fn height(mut self, height: f32) -> Self {
        self.height = height;
        self
    }

    pub fn selected(mut self, selected: bool) -> Self {
        self.selected = selected;
        self
    }

    pub fn on_click(mut self, handler: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static) -> Self {
        self.on_click = Some(Rc::new(handler));
        self
    }

    /// Right-click, with the pointer position for a context menu.
    pub fn on_secondary_click(
        mut self,
        handler: impl Fn(Point<Pixels>, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.on_secondary_click = Some(Rc::new(handler));
        self
    }

    pub fn tooltip(mut self, text: impl Into<SharedString>) -> Self {
        self.tooltip = Some(text.into());
        self
    }
}

impl RenderOnce for SidebarRow {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let hover = theme.hover;
        let mut row = div()
            .id(self.id)
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(theme.z(9.))
            .h(theme.z(self.height))
            .px(theme.z(8.))
            .rounded(theme.z(8.))
            .text_size(theme.z(size::UI))
            .text_color(theme.foreground)
            .overflow_hidden()
            .map(|row| if self.selected { row.bg(theme.selected) } else { row.hover(move |s| s.bg(hover)) })
            .children(self.children)
            .when_some(self.tooltip, |row, text| row.tooltip(tooltip(text)))
            .when_some(self.on_click, |row, handler| row.on_click(move |e, w, cx| handler(e, w, cx)))
            .when_some(self.on_secondary_click, |row, handler| {
                row.on_mouse_down(MouseButton::Right, secondary_click(handler))
            });
        row.style().refine(&self.style);
        row
    }
}

/// A list section header in Soprano's convention, "Title N ⌄": the title, its count in
/// `dim`, a fold chevron when it folds, and an optional trailing control (a "+" button).
/// Herdr's measurements: h31, pl16, pr10, 11.5 px `dim` (no uppercase eyebrow).
#[derive(IntoElement)]
pub struct SectionHeader {
    id: ElementId,
    title: SharedString,
    count: Option<usize>,
    collapsed: Option<bool>,
    medium: bool,
    color: Option<Hsla>,
    end: Option<AnyElement>,
    on_toggle: Option<ClickHandler>,
    style: StyleRefinement,
    children: Vec<AnyElement>,
}

styled_parent!(SectionHeader);

impl SectionHeader {
    pub fn new(id: impl Into<ElementId>, title: impl Into<SharedString>) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            count: None,
            collapsed: None,
            medium: false,
            color: None,
            end: None,
            on_toggle: None,
            style: StyleRefinement::default(),
            children: Vec::new(),
        }
    }

    pub fn count(mut self, count: usize) -> Self {
        self.count = Some(count);
        self
    }

    /// Makes the header fold: ⌄ while open, › while folded.
    pub fn collapsed(mut self, collapsed: bool) -> Self {
        self.collapsed = Some(collapsed);
        self
    }

    /// Medium weight (the Agents header and group headers).
    pub fn medium(mut self) -> Self {
        self.medium = true;
        self
    }

    /// Title color (default `dim`; group headers use a status color).
    pub fn color(mut self, color: Hsla) -> Self {
        self.color = Some(color);
        self
    }

    /// A trailing control, e.g. `IconButton::new("add", IconName::Plus).icon_size(14.)`.
    pub fn end_slot(mut self, element: impl IntoElement) -> Self {
        self.end = Some(element.into_any_element());
        self
    }

    pub fn on_toggle(mut self, handler: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static) -> Self {
        self.on_toggle = Some(Rc::new(handler));
        self
    }
}

impl RenderOnce for SectionHeader {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let color = self.color.unwrap_or(theme.dim);
        let foreground = theme.foreground;
        let chevron = self.collapsed.map(|collapsed| {
            icon(if collapsed { IconName::ChevronRight } else { IconName::ChevronDown })
                .size(11.)
                .color(theme.dim)
        });
        let title = div()
            .id(self.id)
            .flex()
            .flex_row()
            .items_center()
            .gap(theme.z(5.))
            .min_w_0()
            .text_color(color)
            .when(self.on_toggle.is_some(), |t| t.cursor_pointer().hover(move |s| s.text_color(foreground)))
            .child(div().truncate().child(self.title))
            .when_some(self.count, |t, count| {
                t.child(div().text_color(theme.dim).child(SharedString::from(count.to_string())))
            })
            .children(chevron)
            .when_some(self.on_toggle, |t, handler| t.on_click(move |e, w, cx| handler(e, w, cx)));
        let mut header = div()
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .justify_between()
            .h(theme.z(31.))
            .pl(theme.z(16.))
            .pr(theme.z(10.))
            .text_size(theme.z(size::SECTION))
            .font_weight(if self.medium { FontWeight::MEDIUM } else { FontWeight::NORMAL })
            .child(title)
            .children(self.children)
            .children(self.end);
        header.style().refine(&self.style);
        header
    }
}

/// The pane and panel card: radius 10, `background` fill, 1 px border that turns `accent`
/// when focused (or the attention color when it wants you), content clipped to the radius.
#[derive(IntoElement)]
pub struct Card {
    focused: bool,
    attention: bool,
    style: StyleRefinement,
    children: Vec<AnyElement>,
    on_mouse_down: Option<MouseDownHandler>,
}

styled_parent!(Card);

impl Card {
    pub fn new() -> Self {
        Self {
            focused: false,
            attention: false,
            style: StyleRefinement::default(),
            children: Vec::new(),
            on_mouse_down: None,
        }
    }

    pub fn focused(mut self, focused: bool) -> Self {
        self.focused = focused;
        self
    }

    /// Outline in the attention color (a pane that wants you). Focus wins.
    pub fn attention(mut self, attention: bool) -> Self {
        self.attention = attention;
        self
    }

    /// Any press inside the card (focus the pane).
    pub fn on_mouse_down(
        mut self,
        handler: impl Fn(&MouseDownEvent, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.on_mouse_down = Some(Rc::new(handler));
        self
    }
}

impl Default for Card {
    fn default() -> Self {
        Self::new()
    }
}

impl RenderOnce for Card {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let border = if self.focused {
            theme.accent
        } else if self.attention {
            theme.attention
        } else {
            theme.border
        };
        let mut card = div()
            .flex()
            .flex_col()
            .relative()
            .overflow_hidden()
            .rounded(theme.z(10.))
            .bg(theme.background)
            .border_1()
            .border_color(border)
            .text_size(theme.z(size::UI))
            .text_color(theme.foreground)
            .children(self.children)
            .when_some(self.on_mouse_down, |card, handler| {
                card.on_mouse_down(MouseButton::Left, move |e, w, cx| handler(e, w, cx))
            });
        card.style().refine(&self.style);
        card
    }
}

/// A card's 30 px header strip (pane header, panel header at 42): px 10, gap 8,
/// `background`, bottom border, 12 px text.
#[derive(IntoElement)]
pub struct CardHeader {
    height: f32,
    style: StyleRefinement,
    children: Vec<AnyElement>,
}

styled_parent!(CardHeader);

impl CardHeader {
    /// The pane header (30 px).
    pub fn pane() -> Self {
        Self { height: 30.0, style: StyleRefinement::default(), children: Vec::new() }
    }

    /// The Files/Changes panel header (42 px, px 14).
    pub fn panel() -> Self {
        Self { height: 42.0, style: StyleRefinement::default(), children: Vec::new() }
    }
}

impl RenderOnce for CardHeader {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let panel = self.height > 30.0;
        let mut header = div()
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .w_full()
            .h(theme.z(self.height))
            .px(theme.z(if panel { 14. } else { 10. }))
            .gap(theme.z(8.))
            .bg(theme.background)
            .border_b_1()
            .border_color(theme.border)
            .text_size(theme.z(if panel { size::PANEL_TITLE } else { size::META }))
            .children(self.children);
        header.style().refine(&self.style);
        header
    }
}

/// A tab in the tab row: h29, px10, gap7, radius 7, 12.8 px, 1 px border. Active: `raised`
/// with a `border` edge, `foreground` text and a close button. Inactive: invisible edge,
/// `muted` text, `hover` fill under the pointer. Soprano's badges (agents by most urgent
/// status, running commands) follow the label; the tooltip carries the breakdown
/// ([`crate::status::tab_tooltip`]).
#[derive(IntoElement)]
pub struct TabPill {
    id: ElementId,
    number: Option<usize>,
    label: SharedString,
    active: bool,
    icon: Option<Icon>,
    status: Option<StatusGlyph>,
    badges: Vec<TabBadge>,
    tooltip: Option<SharedString>,
    on_click: Option<ClickHandler>,
    on_close: Option<ClickHandler>,
    on_secondary_click: Option<PointHandler>,
}

impl TabPill {
    pub fn new(id: impl Into<ElementId>, label: impl Into<SharedString>) -> Self {
        Self {
            id: id.into(),
            number: None,
            label: label.into(),
            active: false,
            icon: None,
            status: None,
            badges: Vec::new(),
            tooltip: None,
            on_click: None,
            on_close: None,
            on_secondary_click: None,
        }
    }

    pub fn active(mut self, active: bool) -> Self {
        self.active = active;
        self
    }

    /// A window tab's index before the label (`1  Editor`), in `muted` at 80 %.
    pub fn number(mut self, number: usize) -> Self {
        self.number = Some(number);
        self
    }

    /// The program icon (14 px, tinted `muted`).
    pub fn icon(mut self, icon: Icon) -> Self {
        self.icon = Some(icon);
        self
    }

    /// Herdr's status glyph (spinner, 6 px dot) after the label.
    pub fn status(mut self, glyph: Option<StatusGlyph>) -> Self {
        self.status = glyph;
        self
    }

    /// The agent badge, then the running-commands badge.
    pub fn badges(mut self, badges: impl IntoIterator<Item = Option<TabBadge>>) -> Self {
        self.badges = badges.into_iter().flatten().collect();
        self
    }

    pub fn tooltip(mut self, text: impl Into<SharedString>) -> Self {
        self.tooltip = Some(text.into());
        self
    }

    pub fn on_click(mut self, handler: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static) -> Self {
        self.on_click = Some(Rc::new(handler));
        self
    }

    /// Shows the close button on the active tab.
    pub fn on_close(mut self, handler: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static) -> Self {
        self.on_close = Some(Rc::new(handler));
        self
    }

    pub fn on_secondary_click(
        mut self,
        handler: impl Fn(Point<Pixels>, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.on_secondary_click = Some(Rc::new(handler));
        self
    }
}

impl RenderOnce for TabPill {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let hover = theme.hover;
        let (fill, edge, text) = if self.active {
            (theme.raised, theme.border, theme.foreground)
        } else {
            (theme.chrome, theme.chrome, theme.muted)
        };
        let close_id = ElementId::Name(format!("{:?}-close", self.id).into());
        let close = self.on_close.filter(|_| self.active).map(|handler| {
            IconButton::new(close_id, IconName::PaneClose)
                .size(IconButtonSize::Tab)
                .color(theme.dim)
                .tooltip("Close Tab")
                .on_click(move |e, w, cx| {
                    cx.stop_propagation();
                    handler(e, w, cx)
                })
        });
        div()
            .id(self.id)
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(theme.z(7.))
            .h(theme.z(29.))
            .px(theme.z(10.))
            .rounded(theme.z(7.))
            .border_1()
            .border_color(edge)
            .bg(fill)
            .text_size(theme.z(size::ROW))
            .text_color(text)
            .when(!self.active, |tab| tab.hover(move |s| s.bg(hover)))
            .when_some(self.icon, |tab, glyph| tab.child(glyph.size(14.).color(theme.muted)))
            .when_some(self.number, |tab, number| {
                tab.child(
                    div()
                        .flex_none()
                        .text_color(theme.muted.opacity(0.8))
                        .child(SharedString::from(number.to_string())),
                )
            })
            .child(div().max_w(theme.z(170.)).truncate().child(self.label))
            .children(self.status)
            .children(self.badges.into_iter().map(TabBadgeView::new))
            .children(close)
            .when_some(self.tooltip, |tab, text| tab.tooltip(tooltip(text)))
            .when_some(self.on_click, |tab, handler| tab.on_click(move |e, w, cx| handler(e, w, cx)))
            .when_some(self.on_secondary_click, |tab, handler| {
                tab.on_mouse_down(MouseButton::Right, secondary_click(handler))
            })
    }
}

/// The tab row's Files / Changes toggles: h26, px8, gap5, radius 6, 12 px; on = `selected`
/// fill and `foreground`, off = `muted`.
#[derive(IntoElement)]
pub struct PanelToggle {
    id: ElementId,
    label: SharedString,
    icon: IconName,
    on: bool,
    on_click: Option<ClickHandler>,
}

impl PanelToggle {
    pub fn new(id: impl Into<ElementId>, icon: IconName, label: impl Into<SharedString>) -> Self {
        Self { id: id.into(), label: label.into(), icon, on: false, on_click: None }
    }

    pub fn on(mut self, on: bool) -> Self {
        self.on = on;
        self
    }

    pub fn on_click(mut self, handler: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static) -> Self {
        self.on_click = Some(Rc::new(handler));
        self
    }
}

impl RenderOnce for PanelToggle {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let hover = theme.hover;
        let text = if self.on { theme.foreground } else { theme.muted };
        div()
            .id(self.id)
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(theme.z(5.))
            .h(theme.z(26.))
            .px(theme.z(8.))
            .rounded(theme.z(6.))
            .text_size(theme.z(size::META))
            .text_color(text)
            .cursor_pointer()
            .map(|t| if self.on { t.bg(theme.selected) } else { t.hover(move |s| s.bg(hover)) })
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .child(icon(self.icon).size(14.).color(text))
            .child(self.label)
            .when_some(self.on_click, |t, handler| t.on_click(move |e, w, cx| handler(e, w, cx)))
    }
}

/// The status bar: h28, px14, gap16, `chrome`, top border, 11.8 px `muted`. Items go in as
/// children; [`StatusBar::end`] children sit at the right.
#[derive(IntoElement)]
pub struct StatusBar {
    style: StyleRefinement,
    children: Vec<AnyElement>,
    end: Vec<AnyElement>,
}

styled_parent!(StatusBar);

impl StatusBar {
    pub fn new() -> Self {
        Self { style: StyleRefinement::default(), children: Vec::new(), end: Vec::new() }
    }

    /// A right-aligned item (the palette hint).
    pub fn end(mut self, element: impl IntoElement) -> Self {
        self.end.push(element.into_any_element());
        self
    }
}

impl Default for StatusBar {
    fn default() -> Self {
        Self::new()
    }
}

impl RenderOnce for StatusBar {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let mut bar = div()
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .w_full()
            .h(theme.z(28.))
            .px(theme.z(14.))
            .gap(theme.z(16.))
            .bg(theme.chrome)
            .border_t_1()
            .border_color(theme.border)
            .text_size(theme.z(size::STATUS_BAR))
            .text_color(theme.muted)
            .children(self.children)
            .child(div().flex_1())
            .children(self.end);
        bar.style().refine(&self.style);
        bar
    }
}

/// One status-bar item: a 13 px icon (or a 6 px dot) and text, 6 px apart.
#[derive(IntoElement)]
pub struct StatusBarItem {
    id: Option<ElementId>,
    text: SharedString,
    icon: Option<IconName>,
    dot: Option<Hsla>,
    color: Option<Hsla>,
    tooltip: Option<SharedString>,
    on_click: Option<ClickHandler>,
    children: Vec<AnyElement>,
}

impl ParentElement for StatusBarItem {
    fn extend(&mut self, elements: impl IntoIterator<Item = AnyElement>) {
        self.children.extend(elements);
    }
}

impl StatusBarItem {
    pub fn new(text: impl Into<SharedString>) -> Self {
        Self {
            id: None,
            text: text.into(),
            icon: None,
            dot: None,
            color: None,
            tooltip: None,
            on_click: None,
            children: Vec::new(),
        }
    }

    pub fn icon(mut self, icon: IconName) -> Self {
        self.icon = Some(icon);
        self
    }

    /// A 6 px dot instead of an icon (the agents count).
    pub fn dot(mut self, color: Hsla) -> Self {
        self.dot = Some(color);
        self
    }

    pub fn color(mut self, color: Hsla) -> Self {
        self.color = Some(color);
        self
    }

    pub fn tooltip(mut self, id: impl Into<ElementId>, text: impl Into<SharedString>) -> Self {
        self.id = Some(id.into());
        self.tooltip = Some(text.into());
        self
    }

    pub fn on_click(
        mut self,
        id: impl Into<ElementId>,
        handler: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    ) -> Self {
        self.id = Some(id.into());
        self.on_click = Some(Rc::new(handler));
        self
    }
}

impl RenderOnce for StatusBarItem {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let theme = cx.soprano_theme();
        let color = self.color.unwrap_or(theme.muted);
        let id = self.id.unwrap_or_else(|| ElementId::Name(format!("status-item-{}", self.text).into()));
        div()
            .id(id)
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(theme.z(6.))
            .text_color(color)
            .whitespace_nowrap()
            .when_some(self.icon, |item, name| item.child(icon(name).size(13.).color(color)))
            .when_some(self.dot, |item, dot| item.child(div().size(theme.z(6.)).rounded(theme.z(3.)).bg(dot)))
            .child(self.text)
            .children(self.children)
            .when_some(self.tooltip, |item, text| item.tooltip(tooltip(text)))
            .when_some(self.on_click, |item, handler| {
                item.cursor_pointer().on_click(move |e, w, cx| handler(e, w, cx))
            })
    }
}

/// A vertically scrolling list with Herdr's scrollbar (6 px thumb at `foreground` 35 %),
/// shown per `mode` (`Always` for the sidebar lists).
#[derive(IntoElement)]
pub struct ScrollList {
    id: ElementId,
    handle: ScrollHandle,
    mode: ScrollbarMode,
    style: StyleRefinement,
    children: Vec<AnyElement>,
}

styled_parent!(ScrollList);

impl ScrollList {
    pub fn new(id: impl Into<ElementId>, handle: &ScrollHandle) -> Self {
        Self {
            id: id.into(),
            handle: handle.clone(),
            mode: ScrollbarMode::Scrolling,
            style: StyleRefinement::default(),
            children: Vec::new(),
        }
    }

    pub fn mode(mut self, mode: ScrollbarMode) -> Self {
        self.mode = mode;
        self
    }
}

impl RenderOnce for ScrollList {
    fn render(self, _: &mut Window, _: &mut App) -> impl IntoElement {
        let scrollbar_id = ElementId::Name(format!("{:?}-scrollbar", self.id).into());
        let mut list = div()
            .id(self.id)
            .flex()
            .flex_col()
            .size_full()
            .overflow_y_scroll()
            .track_scroll(&self.handle)
            .children(self.children);
        list.style().refine(&self.style);
        div().relative().flex_1().min_h_0().size_full().child(list).child(
            div().absolute().inset_0().child(
                Scrollbar::new(&self.handle)
                    .id(scrollbar_id)
                    .axis(ScrollbarAxis::Vertical)
                    .viewport_from_layout()
                    .mode(self.mode),
            ),
        )
    }
}
