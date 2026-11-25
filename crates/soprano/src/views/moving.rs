//! Moving panes and layout tabs around: what a drag carries, the chip that follows the
//! pointer, which edge of a pane a drop lands on, and the Move menus of pane headers and
//! layout tabs. The moves themselves are the workspace's (`Workspace::move_pane_beside` and
//! friends); everything keeps its ids, so terminals and agents carry on.

use gpui::{
    App, AppContext, Bounds, Context, Entity, InteractiveElement, IntoElement, ParentElement, Pixels, Point,
    Render, SharedString, StyleRefinement, Styled, Window, div,
};
use soprano_model::{PaneEdge, Workspace};
use soprano_ui::{ActiveSopranoTheme, MenuItem, fonts::size};

use crate::shell::{self, CloseTarget, Command, Shell};
use crate::workspace::WorkspaceHandle;

/// A pane dragged by its header.
#[derive(Clone, Debug, PartialEq)]
pub struct PaneDrag {
    pub pane_id: String,
}

/// A layout tab dragged by its pill.
#[derive(Clone, Debug, PartialEq)]
pub struct LayoutTabDrag {
    pub layout_tab_id: String,
}

/// What follows the pointer during a drag: the dragged thing's title.
pub struct DragChip {
    title: SharedString,
}

impl Render for DragChip {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.soprano_theme();
        div()
            .flex()
            .items_center()
            .h(theme.z(29.))
            .px(theme.z(10.))
            .max_w(theme.z(220.))
            .rounded(theme.z(7.))
            .border_1()
            .border_color(theme.border)
            .bg(theme.raised)
            .shadow_md()
            .text_size(theme.z(size::ROW))
            .text_color(theme.foreground)
            .child(div().truncate().child(self.title.clone()))
    }
}

/// An `on_drag` constructor showing `title` under the pointer.
pub fn drag_chip<T>(
    title: impl Into<SharedString>,
) -> impl Fn(&T, Point<Pixels>, &mut Window, &mut App) -> Entity<DragChip> + 'static {
    let title = title.into();
    move |_, _, _, cx| cx.new(|_| DragChip { title: title.clone() })
}

/// The edge of `bounds` nearest to `position`; `None` outside them.
pub fn nearest_edge(position: Point<Pixels>, bounds: Bounds<Pixels>) -> Option<PaneEdge> {
    let (width, height) = (f32::from(bounds.size.width), f32::from(bounds.size.height));
    if !bounds.contains(&position) || width <= 0.0 || height <= 0.0 {
        return None;
    }
    let x = f32::from(position.x - bounds.origin.x) / width;
    let y = f32::from(position.y - bounds.origin.y) / height;
    [(x, PaneEdge::Left), (1.0 - x, PaneEdge::Right), (y, PaneEdge::Top), (1.0 - y, PaneEdge::Bottom)]
        .into_iter()
        .min_by(|a, b| a.0.total_cmp(&b.0))
        .map(|(_, edge)| edge)
}

/// Marks a drop target (a tab, a window row) while a pane or a layout tab is dragged over it.
pub fn drop_highlight<E: InteractiveElement>(element: E, cx: &App) -> E {
    drop_highlight_where(element, |_, _| true, cx)
}

/// [`drop_highlight`], marking a dragged pane only where `accepts_pane` says it can land.
pub fn drop_highlight_where<E: InteractiveElement>(
    element: E,
    accepts_pane: impl Fn(&PaneDrag, &App) -> bool + 'static,
    cx: &App,
) -> E {
    let theme = cx.soprano_theme();
    let (fill, radius) = (theme.selected, theme.z(7.));
    let style = move |style: StyleRefinement| style.bg(fill).rounded(radius);
    element
        .drag_over::<PaneDrag>(
            move |refinement, drag, _, cx| {
                if accepts_pane(drag, cx) { style(refinement) } else { refinement }
            },
        )
        .drag_over::<LayoutTabDrag>(move |refinement, _, _, _| style(refinement))
}

/// A pane header's Move entries.
pub fn pane_menu(workspace: &WorkspaceHandle, pane_id: &str, cx: &App) -> Vec<MenuItem> {
    let ws = workspace.read(cx);
    let Some(window) = ws.window_containing_pane(pane_id) else { return Vec::new() };
    let own_tab = window.tab_index_containing_pane(pane_id);
    let alone_in_tab = own_tab
        .and_then(|index| window.tabs()[index].layout.as_ref())
        .is_some_and(|layout| layout.leaf_count() == 1);
    let alone_in_window = window.pane_ids().len() == 1;
    let act = |label: String, run: Box<dyn Fn(&mut Workspace)>| {
        let workspace = workspace.clone();
        MenuItem::new(label).on_select(move |_, cx| workspace.update(cx, |ws| run(ws)))
    };
    let pane = pane_id.to_owned();
    let tabs = window
        .tabs()
        .iter()
        .enumerate()
        .filter(|(index, _)| Some(*index) != own_tab)
        .map(|(index, tab)| {
            let (pane, tab_id) = (pane.clone(), tab.id.clone());
            let full = !ws.can_move_pane_to_layout_tab(&pane, &tab_id);
            act(
                format!("Tab {}: {}", index + 1, ws.layout_tab_title(tab)),
                Box::new(move |ws| _ = ws.move_pane_to_layout_tab(&pane, &tab_id)),
            )
            .disabled(full)
        })
        .collect();
    let windows = other_windows(ws, &window.id)
        .into_iter()
        .map(|(id, label)| {
            let pane = pane.clone();
            act(label, Box::new(move |ws| _ = ws.move_pane_to_new_layout_tab(&pane, Some(&id))))
        })
        .collect();
    vec![
        act("Move to New Tab".into(), {
            let pane = pane.clone();
            Box::new(move |ws| _ = ws.move_pane_to_new_layout_tab(&pane, None))
        })
        .disabled(alone_in_tab),
        act("Move to New Window".into(), {
            let pane = pane.clone();
            Box::new(move |ws| _ = ws.move_pane_to_new_window(&pane))
        })
        .disabled(alone_in_window),
        submenu("Move to Tab", tabs),
        submenu("Move to Window", windows),
    ]
}

/// A layout tab pill's menu: its Move entries, then Close Tab.
pub fn layout_tab_menu(
    workspace: &WorkspaceHandle,
    shell: &Entity<Shell>,
    layout_tab_id: &str,
    cx: &App,
) -> Vec<MenuItem> {
    let ws = workspace.read(cx);
    let Some(window) = ws.window_containing_layout_tab(layout_tab_id) else { return Vec::new() };
    let act = |label: String, run: Box<dyn Fn(&mut Workspace)>| {
        let workspace = workspace.clone();
        MenuItem::new(label).on_select(move |_, cx| workspace.update(cx, |ws| run(ws)))
    };
    let tab = layout_tab_id.to_owned();
    let windows = other_windows(ws, &window.id)
        .into_iter()
        .map(|(id, label)| {
            let tab = tab.clone();
            act(label, Box::new(move |ws| _ = ws.move_layout_tab(&tab, &id, None)))
        })
        .collect();
    let merge = window
        .tabs()
        .iter()
        .enumerate()
        .filter(|(_, other)| other.id != layout_tab_id)
        .map(|(index, other)| {
            let (tab, into) = (tab.clone(), other.id.clone());
            let full = !ws.can_merge_layout_tab_into(&tab, &into);
            act(
                format!("Tab {}: {}", index + 1, ws.layout_tab_title(other)),
                Box::new(move |ws| _ = ws.merge_layout_tab_into(&tab, &into)),
            )
            .disabled(full)
        })
        .collect();
    let close = {
        let (shell, tab) = (shell.clone(), tab.clone());
        MenuItem::new("Close Tab").on_select(move |_, cx| {
            shell::dispatch(&shell, Command::Close(CloseTarget::LayoutTab(tab.clone())), cx)
        })
    };
    vec![
        act("Move to New Window".into(), Box::new(move |ws| _ = ws.move_layout_tab_to_new_window(&tab)))
            .disabled(window.tabs().len() <= 1),
        submenu("Move to Window", windows),
        submenu("Merge into Tab", merge),
        MenuItem::separator(),
        close,
    ]
}

/// The session's other windows, each with its menu label.
fn other_windows(ws: &Workspace, window_id: &str) -> Vec<(String, String)> {
    let Some(session) = ws.window(window_id).map(|window| window.session_id.clone()) else {
        return Vec::new();
    };
    ws.ordered_windows_in(&session)
        .into_iter()
        .enumerate()
        .filter(|(_, window)| window.id != window_id)
        .map(|(index, window)| (window.id.clone(), format!("Window {}: {}", index + 1, window.title)))
        .collect()
}

/// A submenu, or its label greyed out when there is nowhere to go.
fn submenu(label: &str, items: Vec<MenuItem>) -> MenuItem {
    if items.is_empty() {
        MenuItem::new(label.to_owned()).disabled(true)
    } else {
        MenuItem::submenu(label.to_owned(), items)
    }
}

#[cfg(test)]
mod tests {
    use gpui::{TestAppContext, point, px, size};
    use soprano_config::{AppSettings, DefaultKeybindings};
    use soprano_platform::StateStore;
    use soprano_types::SplitDirection;

    use super::*;

    /// The submenu `label` of `items`, as (label, disabled) per entry.
    fn submenu_entries(items: &[MenuItem], label: &str) -> Vec<(String, bool)> {
        let Some(MenuItem::Submenu { items, .. }) =
            items.iter().find(|item| matches!(item, MenuItem::Submenu { label: l, .. } if l == label))
        else {
            panic!("{label} is a submenu");
        };
        items
            .iter()
            .map(|item| match item {
                MenuItem::Action { label, disabled, .. } => (label.to_string(), *disabled),
                _ => panic!("an action"),
            })
            .collect()
    }

    #[gpui::test]
    fn a_tab_that_would_overfill_another_is_offered_greyed_out(cx: &mut TestAppContext) {
        let mut model = Workspace::new();
        for _ in 2..Workspace::MAX_PANES_PER_TAB {
            model.spawn_terminal(None).expect("pane");
        }
        model.create_layout_tab(None, None).expect("tab");
        let pair = model.create_layout_tab(None, None).expect("tab");
        let top = model.active_pane_id().to_owned();
        model.split_pane(SplitDirection::Vertical, &top).expect("split");
        cx.update(|cx| {
            let workspace = WorkspaceHandle::new(model, cx);
            let shell = cx.new(|_| {
                Shell::new(
                    StateStore::in_memory(),
                    AppSettings::default_settings(),
                    DefaultKeybindings::config(),
                )
            });
            let merge = submenu_entries(&layout_tab_menu(&workspace, &shell, &pair, cx), "Merge into Tab");
            // Tab 1 holds 19 panes: two more do not fit. Tab 2 holds one.
            assert_eq!(merge.iter().map(|(_, disabled)| *disabled).collect::<Vec<_>>(), [true, false]);
        });
    }

    #[test]
    fn a_drop_lands_on_the_nearest_edge_of_the_pane_and_nowhere_outside_it() {
        let bounds = Bounds::new(point(px(100.), px(100.)), size(px(400.), px(200.)));
        assert_eq!(nearest_edge(point(px(120.), px(200.)), bounds), Some(PaneEdge::Left));
        assert_eq!(nearest_edge(point(px(480.), px(200.)), bounds), Some(PaneEdge::Right));
        assert_eq!(nearest_edge(point(px(300.), px(110.)), bounds), Some(PaneEdge::Top));
        assert_eq!(nearest_edge(point(px(300.), px(290.)), bounds), Some(PaneEdge::Bottom));
        // A wide pane: a point a quarter of the way in is still nearer its left edge (in
        // relative terms) than its top.
        assert_eq!(nearest_edge(point(px(190.), px(160.)), bounds), Some(PaneEdge::Left));
        assert_eq!(nearest_edge(point(px(50.), px(200.)), bounds), None);
    }
}
