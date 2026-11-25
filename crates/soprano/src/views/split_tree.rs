//! The tiling layout (`Views/SplitTreeView.swift`, `ThemedSplitView`, `PaneContainerView`): the
//! active layout tab's split tree as pane cards with 8 px gaps, each gap a drag handle that
//! resizes its split, and the maximized pane alone when one is maximized.
//!
//! A pane dragged by its header, or a layout tab dragged by its pill, drops onto the nearest
//! edge of another pane, which shows where it will land.
//!
//! Cards are rebuilt every frame, the content they show is not: each tab's content entity
//! lives in the [`ContentHost`] cache, so a topology change never recreates a terminal.

use gpui::{
    AnyElement, App, AppContext, Bounds, Context, DragMoveEvent, Empty, Entity, InteractiveElement,
    IntoElement, MouseButton, ParentElement, Pixels, Point, Render, SharedString, StatefulInteractiveElement,
    Styled, Window, div, prelude::FluentBuilder, px, relative,
};
use soprano_explorer::ExplorerDrag;
use soprano_model::{PaneEdge, SplitBranchSide, SplitNode};
use soprano_types::{SplitDirection, TerminalTarget};
use soprano_ui::ActiveSopranoTheme;
use soprano_ui::chrome::Card;

use crate::content::{ContentHost, PaneContent};
use crate::shell::Shell;
use crate::views::moving::{LayoutTabDrag, PaneDrag, nearest_edge};
use crate::views::pane_header::PaneHeader;
use crate::workspace::WorkspaceHandle;

/// The gap between split panes, which is also the divider's grab area (HERDR-UI §7.1).
pub const GAP: f32 = 8.0;

/// A divider being dragged: which split, by its path from the root.
#[derive(Clone, Debug, PartialEq)]
pub struct DividerDrag {
    pub path: Vec<SplitBranchSide>,
    pub direction: SplitDirection,
}

impl Render for DividerDrag {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        Empty
    }
}

pub struct SplitTree {
    workspace: WorkspaceHandle,
    content: Entity<ContentHost>,
    shell: Entity<Shell>,
    /// The pane edge a pane or layout tab dragged over the layout would land on.
    drop_zone: Option<(String, PaneEdge)>,
}

impl SplitTree {
    pub fn new(
        workspace: WorkspaceHandle,
        content: Entity<ContentHost>,
        shell: Entity<Shell>,
        cx: &mut Context<Self>,
    ) -> Self {
        cx.observe(&workspace.model, |_, _, cx| cx.notify()).detach();
        cx.observe(&content, |_, _, cx| cx.notify()).detach();
        cx.observe(&shell, |_, _, cx| cx.notify()).detach();
        Self { workspace, content, shell, drop_zone: None }
    }

    /// Follows a drag over `pane_id`'s body: the edge under the pointer when the dragged thing
    /// can land there (`accepts`), none once the pointer leaves the pane.
    fn track_drop_zone(
        &mut self,
        pane_id: &str,
        position: Point<Pixels>,
        bounds: Bounds<Pixels>,
        accepts: bool,
        cx: &mut Context<Self>,
    ) {
        let zone = nearest_edge(position, bounds).filter(|_| accepts).map(|edge| (pane_id.to_owned(), edge));
        let next = match zone {
            Some(zone) => Some(zone),
            None if self.drop_zone.as_ref().is_some_and(|(pane, _)| pane == pane_id) => None,
            None => return,
        };
        if self.drop_zone != next {
            self.drop_zone = next;
            cx.notify();
        }
    }

    /// The edge of `pane_id` a drop lands on, taken: a drop ends the drag.
    fn take_drop_zone(&mut self, pane_id: &str, cx: &mut Context<Self>) -> Option<PaneEdge> {
        let (pane, edge) = self.drop_zone.take()?;
        cx.notify();
        (pane == pane_id).then_some(edge)
    }

    fn render_node(
        &self,
        node: &SplitNode,
        path: Vec<SplitBranchSide>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        match node {
            SplitNode::Leaf(pane_id) => self.render_pane(pane_id, window, cx),
            SplitNode::Split(branch) => {
                let theme = cx.soprano_theme();
                let gap = theme.z(GAP);
                let horizontal = branch.direction == SplitDirection::Horizontal;
                let fraction = (branch.split_percentage.clamp(10.0, 90.0) / 100.0) as f32;
                let first =
                    self.render_node(&branch.first, child_path(&path, SplitBranchSide::First), window, cx);
                let second =
                    self.render_node(&branch.second, child_path(&path, SplitBranchSide::Second), window, cx);
                let drag = DividerDrag { path: path.clone(), direction: branch.direction };
                let id = SharedString::from(format!("split-divider-{}", path_key(&path)));
                let workspace = self.workspace.clone();
                let own_path = path.clone();
                let divider = div()
                    .id(id)
                    .flex_none()
                    .when(horizontal, |d| d.w(gap).h_full().cursor_col_resize())
                    .when(!horizontal, |d| d.h(gap).w_full().cursor_row_resize())
                    .on_drag(drag, |drag, _, _, cx| cx.new(|_| drag.clone()))
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation());
                div()
                    .flex()
                    .size_full()
                    .min_w_0()
                    .min_h_0()
                    .when(horizontal, |d| d.flex_row())
                    .when(!horizontal, |d| d.flex_col())
                    .on_drag_move(move |event: &DragMoveEvent<DividerDrag>, _, cx| {
                        let drag = event.drag(cx);
                        if drag.path != own_path {
                            return;
                        }
                        let bounds = event.bounds;
                        let (position, start, size) = if horizontal {
                            (event.event.position.x, bounds.origin.x, bounds.size.width)
                        } else {
                            (event.event.position.y, bounds.origin.y, bounds.size.height)
                        };
                        let gap = cx.soprano_theme().z(GAP);
                        let percentage = percentage_for_divider_position(
                            f32::from(position - start - gap / 2.0) as f64,
                            f32::from(size) as f64,
                            f32::from(gap) as f64,
                        );
                        let path = drag.path.clone();
                        workspace.update(cx, |ws| ws.set_split_percentage(&path, percentage));
                    })
                    .child(grow(div().child(first), fraction))
                    .child(divider)
                    .child(grow(div().child(second), 1.0 - fraction))
                    .into_any_element()
            }
        }
    }

    fn render_pane(&self, pane_id: &str, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let workspace = self.workspace.read(cx);
        let Some(pane) = workspace.pane(pane_id) else { return Empty.into_any_element() };
        let focused = workspace.active_pane_id() == pane_id;
        let attention =
            pane.tabs.iter().any(|tab| tab.agent.as_ref().is_some_and(|agent| agent.needs_attention));
        let active_tab = pane.active_tab().map(|tab| tab.id.clone());
        let theme = cx.soprano_theme();
        let body: AnyElement = match active_tab
            .as_ref()
            .and_then(|tab_id| self.content.read(cx).content(&TerminalTarget::new(pane_id, tab_id)).cloned())
        {
            Some(PaneContent::Failed(message)) => placeholder(message, cx),
            Some(content) => match content.view() {
                Some(view) => view.into_any_element(),
                None => div().size_full().bg(theme.background).into_any_element(),
            },
            None if active_tab.is_none() => placeholder("Empty".into(), cx),
            None => div().size_full().bg(theme.background).into_any_element(),
        };
        let workspace_handle = self.workspace.clone();
        let focus_pane = pane_id.to_owned();
        let drop_target = active_tab.map(|tab_id| TerminalTarget::new(pane_id, tab_id));
        let content = self.content.clone();
        let _ = window;
        let zone = self
            .drop_zone
            .as_ref()
            .filter(|(pane, _)| pane == pane_id && cx.has_active_drag())
            .map(|(_, edge)| *edge);
        let (over_pane, over_tab, dropped_pane, dropped_tab) =
            (pane_id.to_owned(), pane_id.to_owned(), pane_id.to_owned(), pane_id.to_owned());
        Card::new()
            .focused(focused)
            .attention(attention)
            .size_full()
            .min_w_0()
            .min_h_0()
            .on_mouse_down(move |_, _, cx| {
                let pane = focus_pane.clone();
                workspace_handle.update(cx, |ws| {
                    if ws.active_pane_id() != pane {
                        ws.focus_pane(&pane)
                    }
                });
            })
            .child(PaneHeader::new(pane_id, self.workspace.clone(), self.shell.clone()))
            .child(
                div()
                    .id(SharedString::from(format!("pane-body-{pane_id}")))
                    .debug_selector({
                        let selector = format!("pane-body-{pane_id}");
                        move || selector
                    })
                    .flex_1()
                    .min_h_0()
                    .w_full()
                    .relative()
                    .child(body)
                    .when_some(zone, |body, edge| body.child(drop_indicator(edge, cx)))
                    .when_some(drop_target, |body, target| {
                        body.on_drop(move |drag: &ExplorerDrag, window, cx| {
                            let paths = drag.paths();
                            content.update(cx, |host, cx| host.drop_paths(&target, paths, window, cx));
                        })
                    })
                    .on_drag_move(cx.listener(move |tree, event: &DragMoveEvent<PaneDrag>, _, cx| {
                        let accepts =
                            tree.workspace.read(cx).can_move_pane_beside(&event.drag(cx).pane_id, &over_pane);
                        tree.track_drop_zone(&over_pane, event.event.position, event.bounds, accepts, cx);
                    }))
                    .on_drag_move(cx.listener(move |tree, event: &DragMoveEvent<LayoutTabDrag>, _, cx| {
                        let accepts = tree
                            .workspace
                            .read(cx)
                            .can_merge_layout_tab(&event.drag(cx).layout_tab_id, &over_tab);
                        tree.track_drop_zone(&over_tab, event.event.position, event.bounds, accepts, cx);
                    }))
                    .on_drop(cx.listener(move |tree, drag: &PaneDrag, _, cx| {
                        if let Some(edge) = tree.take_drop_zone(&dropped_pane, cx) {
                            tree.workspace
                                .update(cx, |ws| ws.move_pane_beside(&drag.pane_id, &dropped_pane, edge));
                        }
                    }))
                    .on_drop(cx.listener(move |tree, drag: &LayoutTabDrag, _, cx| {
                        if let Some(edge) = tree.take_drop_zone(&dropped_tab, cx) {
                            tree.workspace.update(cx, |ws| {
                                ws.merge_layout_tab(&drag.layout_tab_id, &dropped_tab, edge)
                            });
                        }
                    })),
            )
            .into_any_element()
    }
}

impl Render for SplitTree {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let workspace = self.workspace.read(cx);
        let layout = workspace.layout().cloned();
        // Maximize renders a single-leaf layout; the hidden panes' content stays cached.
        let effective = match (workspace.maximized_pane_id(), layout) {
            (Some(maximized), Some(_)) if workspace.pane(maximized).is_some() => {
                Some(SplitNode::Leaf(maximized.to_owned()))
            }
            (_, layout) => layout,
        };
        let root = match effective {
            Some(node) => self.render_node(&node, Vec::new(), window, cx),
            None => placeholder("No panes open".into(), cx),
        };
        div().size_full().min_w_0().min_h_0().flex().child(root)
    }
}

/// The half of a pane a drop would fill, tinted in the accent color.
fn drop_indicator(edge: PaneEdge, cx: &App) -> AnyElement {
    let theme = cx.soprano_theme();
    let half = relative(0.5);
    div()
        .absolute()
        .map(|zone| match edge {
            PaneEdge::Left => zone.left_0().top_0().bottom_0().w(half),
            PaneEdge::Right => zone.right_0().top_0().bottom_0().w(half),
            PaneEdge::Top => zone.left_0().right_0().top_0().h(half),
            PaneEdge::Bottom => zone.left_0().right_0().bottom_0().h(half),
        })
        .bg(theme.accent.opacity(0.15))
        .border_2()
        .border_color(theme.accent.opacity(0.6))
        .into_any_element()
}

fn grow<E: Styled>(element: E, fraction: f32) -> E {
    let mut element = element.flex().flex_basis(px(0.)).min_w_0().min_h_0().overflow_hidden();
    element.style().flex_grow = Some(fraction);
    element.style().flex_shrink = Some(1.0);
    element
}

fn child_path(path: &[SplitBranchSide], side: SplitBranchSide) -> Vec<SplitBranchSide> {
    let mut path = path.to_vec();
    path.push(side);
    path
}

fn path_key(path: &[SplitBranchSide]) -> String {
    path.iter().map(|side| if *side == SplitBranchSide::First { '0' } else { '1' }).collect()
}

/// A centered muted line (`placeholderLabel`).
fn placeholder(text: SharedString, cx: &App) -> AnyElement {
    let theme = cx.soprano_theme();
    div()
        .size_full()
        .flex()
        .items_center()
        .justify_center()
        .bg(theme.background)
        .text_color(theme.muted)
        .text_size(theme.z(soprano_ui::fonts::size::UI))
        .child(text)
        .into_any_element()
}

/// `ThemedSplitView.percentageForDividerPosition`: where the first side ends, as a share of
/// the space both sides split, clamped to 10–90.
pub fn percentage_for_divider_position(position: f64, total_size: f64, divider_thickness: f64) -> f64 {
    let available = total_size - divider_thickness;
    if available <= 0.0 {
        return 50.0;
    }
    (position / available * 100.0).clamp(10.0, 90.0)
}

/// The first side's length for a model percentage (`applyModelPercentage`).
#[cfg(test)]
pub fn divider_position(percentage: f64, total_size: f64, divider_thickness: f64) -> f64 {
    (total_size - divider_thickness).max(0.0) * percentage.clamp(10.0, 90.0) / 100.0
}

#[allow(dead_code)]
fn _pixels(value: Pixels) -> f32 {
    f32::from(value)
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::rc::Rc;

    use gpui::{Modifiers, MouseButton, TestAppContext, VisualTestContext, point, size};
    use soprano_config::{AppSettings, DefaultKeybindings};
    use soprano_model::Workspace;
    use soprano_platform::StateStore;
    use soprano_term::{TerminalLaunch, TerminalSettings, TerminalView};

    use super::*;
    use crate::content::TerminalFactory;

    /// Counts terminal starts and fails each one, so no shell ever runs.
    #[derive(Default)]
    struct CountingTerminals(Cell<usize>);

    impl TerminalFactory for CountingTerminals {
        fn create(
            &self,
            _: TerminalLaunch,
            _: TerminalSettings,
            _: &mut Window,
            _: &mut App,
        ) -> anyhow::Result<Entity<TerminalView>> {
            self.0.set(self.0.get() + 1);
            anyhow::bail!("no shells in tests")
        }

        fn restart(&self, _: &Entity<TerminalView>, _: TerminalLaunch, _: &mut App) -> bool {
            false
        }

        fn run_detached(&self, _: Vec<String>) {}
    }

    fn redraw(cx: &mut VisualTestContext) {
        cx.update(|window, _| window.refresh());
        cx.run_until_parked();
    }

    #[gpui::test]
    fn a_pane_dragged_by_its_header_lands_on_the_edge_of_the_pane_it_is_dropped_on(cx: &mut TestAppContext) {
        cx.update(soprano_ui::init_for_tests);
        let mut model = Workspace::new();
        let left = model.active_pane_id().to_owned();
        let right = model.split_pane(SplitDirection::Horizontal, &left).expect("split");
        let terminals = Rc::new(CountingTerminals::default());
        let factory: Rc<dyn TerminalFactory> = terminals.clone();
        let workspace = cx.update(|cx| WorkspaceHandle::new(model, cx));
        let handle = workspace.clone();
        let (_, cx) = cx.add_window_view(move |window, cx| {
            let shell = cx.new(|_| {
                Shell::new(
                    StateStore::in_memory(),
                    AppSettings::default_settings(),
                    DefaultKeybindings::config(),
                )
            });
            let content = cx.new(|cx| {
                ContentHost::new(
                    handle.clone(),
                    shell.clone(),
                    factory,
                    crate::content::tests::context(),
                    TerminalSettings::default(),
                    cx.new(|_| soprano_editor::EditorDocuments::new()),
                    StateStore::in_memory(),
                    window,
                    cx,
                )
            });
            SplitTree::new(handle, content, shell, cx)
        });
        cx.simulate_resize(size(px(1000.), px(600.)));
        redraw(cx);
        let started = terminals.0.get();

        // `debug_bounds` takes static selectors: a fresh workspace numbers these two panes.
        assert_eq!((left.as_str(), right.as_str()), ("pane-1", "pane-3"));
        let header = cx.debug_bounds("pane-header-pane-3").expect("header");
        let target = cx.debug_bounds("pane-body-pane-1").expect("body");
        let start = header.center();
        let near_top = point(target.center().x, target.top() + px(10.));
        cx.simulate_mouse_down(start, MouseButton::Left, Modifiers::none());
        cx.simulate_mouse_move(start - point(px(20.), px(0.)), MouseButton::Left, Modifiers::none());
        cx.simulate_mouse_move(near_top, MouseButton::Left, Modifiers::none());
        redraw(cx);
        cx.simulate_mouse_up(near_top, MouseButton::Left, Modifiers::none());
        redraw(cx);

        let layout = cx.read(|cx| workspace.read(cx).layout().cloned());
        assert_eq!(
            layout,
            Some(SplitNode::split(
                SplitDirection::Vertical,
                SplitNode::leaf(&right),
                SplitNode::leaf(&left),
                50.0
            ))
        );
        assert_eq!(terminals.0.get(), started, "the moved pane kept its terminal");
    }

    #[test]
    fn divider_positions_map_to_percentages_of_the_space_both_sides_share() {
        assert_eq!(percentage_for_divider_position(496.0, 1000.0, 8.0), 50.0);
        assert_eq!(percentage_for_divider_position(0.0, 1000.0, 8.0), 10.0);
        assert_eq!(percentage_for_divider_position(1000.0, 1000.0, 8.0), 90.0);
        assert_eq!(percentage_for_divider_position(100.0, 4.0, 8.0), 50.0);
    }

    #[test]
    fn model_percentages_round_trip_through_divider_positions() {
        for percentage in [10.0, 25.0, 50.0, 73.5, 90.0] {
            let position = divider_position(percentage, 1200.0, 8.0);
            assert!((percentage_for_divider_position(position, 1200.0, 8.0) - percentage).abs() < 1e-9);
        }
        assert_eq!(divider_position(95.0, 1008.0, 8.0), 900.0);
    }
}
