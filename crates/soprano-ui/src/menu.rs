//! The context menu (HERDR-UI.md §11.4): a popup at the pointer, clamped 8 px from the window
//! edges; rows h31 with icon, label and shortcut; separators, headers, checked and disabled
//! rows, one level of submenus; keyboard navigation (↑ ↓ → ← ↵ esc) and click-outside dismiss.

use std::rc::Rc;

use gpui::{
    App, AppContext as _, Context, DismissEvent, ElementId, EventEmitter, FocusHandle, Focusable,
    IntoElement, KeyDownEvent, MouseButton, ParentElement, Pixels, Point, Render, SharedString,
    StatefulInteractiveElement, Styled, Window, anchored, deferred, div, prelude::*, px, relative,
};

use crate::fonts::{self, size};
use crate::icons::{IconName, icon};
use crate::motion::fade_in;
use crate::theme::ActiveSopranoTheme;

pub type MenuHandler = Rc<dyn Fn(&mut Window, &mut App)>;

/// One row of a menu.
#[derive(Clone)]
pub enum MenuItem {
    Action {
        label: SharedString,
        icon: Option<IconName>,
        shortcut: Option<SharedString>,
        disabled: bool,
        checked: bool,
        handler: Option<MenuHandler>,
    },
    Submenu {
        label: SharedString,
        icon: Option<IconName>,
        items: Vec<MenuItem>,
    },
    Separator,
    Header(SharedString),
}

impl MenuItem {
    /// An action row; give it a handler with [`MenuItem::on_select`].
    pub fn new(label: impl Into<SharedString>) -> Self {
        Self::Action {
            label: label.into(),
            icon: None,
            shortcut: None,
            disabled: false,
            checked: false,
            handler: None,
        }
    }

    pub fn submenu(label: impl Into<SharedString>, items: Vec<MenuItem>) -> Self {
        Self::Submenu { label: label.into(), icon: None, items }
    }

    pub fn separator() -> Self {
        Self::Separator
    }

    /// A small `dim` title over the rows that follow ("Open in", "Start an agent").
    pub fn header(label: impl Into<SharedString>) -> Self {
        Self::Header(label.into())
    }

    pub fn icon(mut self, name: IconName) -> Self {
        match &mut self {
            Self::Action { icon, .. } | Self::Submenu { icon, .. } => *icon = Some(name),
            Self::Separator | Self::Header(_) => {}
        }
        self
    }

    /// The bound key, shown raw at the right in 11 px `dim` (`⌘C`, `not installed`).
    pub fn shortcut(mut self, text: impl Into<SharedString>) -> Self {
        if let Self::Action { shortcut, .. } = &mut self {
            *shortcut = Some(text.into());
        }
        self
    }

    pub fn disabled(mut self, value: bool) -> Self {
        if let Self::Action { disabled, .. } = &mut self {
            *disabled = value;
        }
        self
    }

    /// A check mark at the right (the active option).
    pub fn checked(mut self, value: bool) -> Self {
        if let Self::Action { checked, .. } = &mut self {
            *checked = value;
        }
        self
    }

    pub fn on_select(mut self, f: impl Fn(&mut Window, &mut App) + 'static) -> Self {
        if let Self::Action { handler, .. } = &mut self {
            *handler = Some(Rc::new(f));
        }
        self
    }

    /// Whether keyboard navigation can land here.
    pub fn is_selectable(&self) -> bool {
        match self {
            Self::Action { disabled, .. } => !disabled,
            Self::Submenu { .. } => true,
            Self::Separator | Self::Header(_) => false,
        }
    }
}

/// The next selectable row from `current` by `delta` (±1), not wrapping; the first or last
/// selectable row when nothing is selected.
pub fn next_selectable(items: &[MenuItem], current: Option<usize>, delta: isize) -> Option<usize> {
    let selectable: Vec<usize> =
        items.iter().enumerate().filter(|(_, i)| i.is_selectable()).map(|(i, _)| i).collect();
    let Some(current) = current else {
        return if delta >= 0 { selectable.first().copied() } else { selectable.last().copied() };
    };
    if delta >= 0 {
        selectable.iter().copied().find(|&i| i > current).or(Some(current).filter(|c| selectable.contains(c)))
    } else {
        selectable
            .iter()
            .rev()
            .copied()
            .find(|&i| i < current)
            .or(Some(current).filter(|c| selectable.contains(c)))
    }
}

/// A popup menu. Create it with [`ContextMenu::new`], render the entity anywhere in the
/// window (it draws itself deferred at `position`), and drop it on [`DismissEvent`].
pub struct ContextMenu {
    position: Point<Pixels>,
    width: f32,
    items: Vec<MenuItem>,
    selected: Option<usize>,
    submenu: Option<usize>,
    submenu_selected: Option<usize>,
    focus_handle: FocusHandle,
    previous_focus: Option<FocusHandle>,
    dismissed: bool,
}

impl EventEmitter<DismissEvent> for ContextMenu {}

impl Focusable for ContextMenu {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl ContextMenu {
    /// A 200 px menu at `position` (window coordinates, usually the click's position). It
    /// takes the keyboard; focus returns to where it was when the menu closes.
    pub fn new(
        position: Point<Pixels>,
        items: Vec<MenuItem>,
        window: &mut Window,
        cx: &mut App,
    ) -> gpui::Entity<Self> {
        let previous_focus = window.focused(cx);
        cx.new(|cx| {
            let focus_handle = cx.focus_handle();
            focus_handle.focus(window, cx);
            Self {
                position,
                width: 200.0,
                items,
                selected: None,
                submenu: None,
                submenu_selected: None,
                focus_handle,
                previous_focus,
                dismissed: false,
            }
        })
    }

    /// Width in designed px (200 context menus, 250 the new-menu).
    pub fn set_width(&mut self, width: f32) {
        self.width = width;
    }

    pub fn items(&self) -> &[MenuItem] {
        &self.items
    }

    /// Closes the menu without picking anything.
    pub fn dismiss(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.dismissed {
            return;
        }
        self.dismissed = true;
        if let Some(previous) = self.previous_focus.take() {
            previous.focus(window, cx);
        }
        cx.emit(DismissEvent);
        cx.notify();
    }

    fn pick(&mut self, index: usize, sub: Option<usize>, window: &mut Window, cx: &mut Context<Self>) {
        let item = match sub {
            Some(sub) => match self.items.get(index) {
                Some(MenuItem::Submenu { items, .. }) => items.get(sub).cloned(),
                _ => None,
            },
            None => self.items.get(index).cloned(),
        };
        match item {
            Some(MenuItem::Action { disabled: false, handler, .. }) => {
                self.dismiss(window, cx);
                if let Some(handler) = handler {
                    window.defer(cx, move |window, cx| handler(window, cx));
                }
            }
            Some(MenuItem::Submenu { items, .. }) => {
                self.submenu = Some(index);
                self.selected = Some(index);
                self.submenu_selected = next_selectable(&items, None, 1);
                cx.notify();
            }
            _ => {}
        }
    }

    fn submenu_items(&self) -> Option<&[MenuItem]> {
        match self.submenu.and_then(|i| self.items.get(i)) {
            Some(MenuItem::Submenu { items, .. }) => Some(items),
            _ => None,
        }
    }

    fn on_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let modifiers = event.keystroke.modifiers;
        if modifiers.control || modifiers.alt || modifiers.platform {
            return;
        }
        let in_submenu = self.submenu.is_some() && self.submenu_selected.is_some();
        match event.keystroke.key.as_str() {
            "up" | "down" => {
                let delta = if event.keystroke.key == "up" { -1 } else { 1 };
                if in_submenu {
                    let next = self
                        .submenu_items()
                        .and_then(|items| next_selectable(items, self.submenu_selected, delta));
                    self.submenu_selected = next;
                } else {
                    self.selected = next_selectable(&self.items, self.selected, delta);
                    self.submenu = None;
                }
            }
            "right" => {
                if let Some(index) = self.selected
                    && matches!(self.items.get(index), Some(MenuItem::Submenu { .. }))
                {
                    self.pick(index, None, window, cx);
                }
            }
            "left" => {
                self.submenu = None;
                self.submenu_selected = None;
            }
            "enter" => match (self.selected, in_submenu) {
                (Some(index), true) => self.pick(index, self.submenu_selected, window, cx),
                (Some(index), false) => self.pick(index, None, window, cx),
                _ => {}
            },
            "escape" => {
                if self.submenu.is_some() {
                    self.submenu = None;
                    self.submenu_selected = None;
                } else {
                    self.dismiss(window, cx);
                }
            }
            _ => return,
        }
        cx.stop_propagation();
        cx.notify();
    }

    fn render_rows(
        &self,
        items: &[MenuItem],
        selected: Option<usize>,
        sub: bool,
        cx: &mut Context<Self>,
    ) -> Vec<gpui::AnyElement> {
        let theme = cx.soprano_theme().clone();
        let z = |v: f32| theme.z(v);
        items
            .iter()
            .enumerate()
            .map(|(index, item)| match item {
                MenuItem::Separator => {
                    div().h(px(1.)).mx(z(7.)).my(z(4.)).bg(theme.border).into_any_element()
                }
                MenuItem::Header(label) => div()
                    .px(z(8.))
                    .pt(z(4.))
                    .pb(z(6.))
                    .text_size(z(size::SMALL))
                    .text_color(theme.dim)
                    .child(label.clone())
                    .into_any_element(),
                MenuItem::Action { label, icon: glyph, shortcut, disabled, checked, .. } => {
                    let text = if *disabled { theme.dim } else { theme.foreground };
                    let hover = theme.hover;
                    let row_id = ElementId::NamedInteger(
                        if sub { "submenu-row" } else { "menu-row" }.into(),
                        index as u64,
                    );
                    let parent = self.submenu;
                    div()
                        .id(row_id)
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(z(9.))
                        .h(z(31.))
                        .px(z(8.))
                        .rounded(z(7.))
                        .text_color(text)
                        .when(selected == Some(index), |row| row.bg(theme.selected))
                        .when(!*disabled, |row| row.cursor_pointer().hover(move |s| s.bg(hover)))
                        .when_some(*glyph, |row, name| row.child(icon(name).size(14.).color(theme.muted)))
                        .child(div().flex_1().min_w_0().truncate().child(label.clone()))
                        .when_some(shortcut.clone(), |row, shortcut| {
                            row.child(div().text_size(z(size::SMALL)).text_color(theme.dim).child(shortcut))
                        })
                        .when(*checked, |row| {
                            row.child(icon(IconName::Check).size(14.).color(theme.foreground))
                        })
                        .when(!*disabled, |row| {
                            row.on_click(cx.listener(move |this, _, window, cx| {
                                if sub {
                                    if let Some(parent) = parent {
                                        this.pick(parent, Some(index), window, cx);
                                    }
                                } else {
                                    this.pick(index, None, window, cx);
                                }
                            }))
                        })
                        .into_any_element()
                }
                MenuItem::Submenu { label, icon: glyph, .. } => {
                    let hover = theme.hover;
                    let open = self.submenu == Some(index);
                    div()
                        .id(ElementId::NamedInteger("menu-submenu".into(), index as u64))
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(z(9.))
                        .h(z(31.))
                        .px(z(8.))
                        .rounded(z(7.))
                        .text_color(theme.foreground)
                        .when(selected == Some(index) || open, |row| row.bg(theme.selected))
                        .cursor_pointer()
                        .hover(move |s| s.bg(hover))
                        .when_some(*glyph, |row, name| row.child(icon(name).size(14.).color(theme.muted)))
                        .child(div().flex_1().min_w_0().truncate().child(label.clone()))
                        .child(icon(IconName::ChevronRight).size(12.).color(theme.dim))
                        .on_hover(cx.listener(move |this, hovered: &bool, _, cx| {
                            if *hovered && this.submenu != Some(index) {
                                this.submenu = Some(index);
                                this.selected = Some(index);
                                this.submenu_selected = None;
                                cx.notify();
                            }
                        }))
                        .on_click(cx.listener(move |this, _, window, cx| this.pick(index, None, window, cx)))
                        .into_any_element()
                }
            })
            .collect()
    }

    fn panel(&self, width: f32, cx: &App) -> gpui::Div {
        let theme = cx.soprano_theme();
        div()
            .flex()
            .flex_col()
            .w(theme.z(width))
            .p(theme.z(5.))
            .bg(theme.popover)
            .border_1()
            .border_color(theme.border)
            .rounded(theme.z(8.))
            .shadow_lg()
            .font_family(fonts::UI_FONT_FAMILY)
            .text_size(theme.z(size::ROW))
    }
}

impl Render for ContextMenu {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.dismissed {
            return div().into_any_element();
        }
        let items = self.items.clone();
        let rows = self.render_rows(&items, self.selected, false, cx);
        let submenu = self.submenu.and_then(|index| match items.get(index) {
            Some(MenuItem::Submenu { items: sub_items, .. }) => {
                let sub_rows = self.render_rows(sub_items, self.submenu_selected, true, cx);
                let top = cx.soprano_theme().z(5.0 + 31.0 * index as f32);
                Some(
                    self.panel(self.width, cx)
                        .absolute()
                        .left(relative(1.))
                        .top(top)
                        .ml(px(4.))
                        .children(sub_rows),
                )
            }
            _ => None,
        });
        let theme = cx.soprano_theme();
        let max_height = theme.z(512.);
        let panel = self
            .panel(self.width, cx)
            .id("soprano-context-menu")
            .relative()
            .track_focus(&self.focus_handle)
            .key_context("SopranoMenu")
            .on_key_down(cx.listener(Self::on_key))
            .on_mouse_down_out(cx.listener(|this, _, window, cx| this.dismiss(window, cx)))
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .on_mouse_down(MouseButton::Right, |_, _, cx| cx.stop_propagation())
            .child(div().id("soprano-context-menu-rows").max_h(max_height).overflow_y_scroll().children(rows))
            .children(submenu);
        deferred(anchored().position(self.position).snap_to_window_with_margin(px(8.)).child(fade_in(
            panel,
            "soprano-context-menu-fade",
            cx,
        )))
        .with_priority(1)
        .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn items() -> Vec<MenuItem> {
        vec![
            MenuItem::header("Tab"),
            MenuItem::new("Rename").icon(IconName::SquarePen),
            MenuItem::new("Disabled").disabled(true),
            MenuItem::separator(),
            MenuItem::new("Close").icon(IconName::X).shortcut("⌘W"),
        ]
    }

    #[test]
    fn keyboard_selection_skips_headers_separators_and_disabled_rows() {
        let items = items();
        assert_eq!(next_selectable(&items, None, 1), Some(1));
        assert_eq!(next_selectable(&items, None, -1), Some(4));
        assert_eq!(next_selectable(&items, Some(1), 1), Some(4));
        assert_eq!(next_selectable(&items, Some(4), -1), Some(1));
    }

    #[test]
    fn keyboard_selection_stops_at_the_ends() {
        let items = items();
        assert_eq!(next_selectable(&items, Some(4), 1), Some(4));
        assert_eq!(next_selectable(&items, Some(1), -1), Some(1));
        assert_eq!(next_selectable(&[MenuItem::separator()], None, 1), None);
    }

    #[test]
    fn builders_only_touch_the_rows_they_apply_to() {
        let checked = MenuItem::new("Priority").checked(true);
        assert!(matches!(checked, MenuItem::Action { checked: true, .. }));
        let header = MenuItem::header("Sort").checked(true).icon(IconName::Check);
        assert!(matches!(header, MenuItem::Header(_)));
        assert!(MenuItem::submenu("Open in", vec![]).is_selectable());
    }
}
