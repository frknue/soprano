//! The tiling layout (`Views/SplitTreeView.swift`, `ThemedSplitView`, `PaneContainerView`): the
//! active layout tab's split tree as pane cards with 8 px gaps, each gap a drag handle that
//! resizes its split, and the maximized pane alone when one is maximized.
//!
//! Cards are rebuilt every frame, the content they show is not: each tab's content entity
//! lives in the [`ContentHost`] cache, so a topology change never recreates a terminal.

use gpui::{
    AnyElement, App, AppContext, Context, DragMoveEvent, Empty, Entity, InteractiveElement, IntoElement,
    MouseButton, ParentElement, Pixels, Render, SharedString, StatefulInteractiveElement, Styled, Window,
    div, prelude::FluentBuilder, px,
};
use soprano_explorer::ExplorerDrag;
use soprano_model::{SplitBranchSide, SplitDirection, SplitNode, TerminalTarget};
use soprano_ui::ActiveSopranoTheme;
use soprano_ui::chrome::Card;

use crate::content::{ContentHost, PaneContent};
use crate::shell::Shell;
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
        Self { workspace, content, shell }
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
                    .flex_1()
                    .min_h_0()
                    .w_full()
                    .relative()
                    .child(body)
                    .when_some(drop_target, |body, target| {
                        body.on_drop(move |drag: &ExplorerDrag, window, cx| {
                            let paths = drag.paths();
                            content.update(cx, |host, cx| host.drop_paths(&target, paths, window, cx));
                        })
                    }),
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
    use super::*;

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
