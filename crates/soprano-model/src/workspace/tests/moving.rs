//! Moving panes and layout tabs between layouts, layout tabs and windows.

use super::*;
use crate::split_node::{PaneEdge, SplitNode};
use soprano_types::SplitDirection;

fn tab_ids(workspace: &Workspace, window_id: &str) -> Vec<String> {
    workspace.window(window_id).expect("window").tabs().iter().map(|tab| tab.id.clone()).collect()
}

#[test]
fn a_pane_moved_beside_another_keeps_its_tabs_and_takes_focus_there() {
    let mut workspace = Workspace::new();
    let left = workspace.active_pane_id().to_owned();
    let right = workspace.split_pane(SplitDirection::Horizontal, &left).expect("split");
    let below = workspace.split_pane(SplitDirection::Vertical, &right).expect("split");
    let moved = workspace.pane(&below).cloned().expect("pane");

    assert!(workspace.move_pane_beside(&below, &left, PaneEdge::Top));

    let expected = SplitNode::split(
        SplitDirection::Horizontal,
        SplitNode::split(SplitDirection::Vertical, SplitNode::leaf(&below), SplitNode::leaf(&left), 50.0),
        SplitNode::leaf(&right),
        50.0,
    );
    assert_eq!(workspace.layout(), Some(&expected));
    assert_eq!(workspace.pane(&below), Some(&moved));
    assert_eq!(workspace.active_pane_id(), below);
    assert!(!workspace.move_pane_beside(&below, &below, PaneEdge::Left));
}

#[test]
fn moving_a_windows_last_pane_elsewhere_closes_the_window_and_keeps_the_pane() {
    let mut workspace = Workspace::new();
    let first_window = workspace.active_window_id().to_owned();
    let target = workspace.active_pane_id().to_owned();
    let second_window = workspace.create_window(None, None).expect("window");
    let moving = workspace.active_pane_id().to_owned();
    let moving_tab = active_tab_id(&workspace, &moving);

    assert!(workspace.move_pane_beside(&moving, &target, PaneEdge::Right));

    assert!(workspace.window(&second_window).is_none());
    assert_eq!(workspace.active_window_id(), first_window);
    assert_eq!(workspace.active_pane_id(), moving);
    assert_eq!(active_tab_id(&workspace, &moving), moving_tab);
    assert_eq!(workspace.pane_count(), 2);
    let session = workspace.active_session().expect("session");
    assert_eq!(session.active_window_id, first_window);
    assert_eq!(session.last_active_window_id, None);
}

#[test]
fn a_pane_gets_a_tab_or_a_window_of_its_own_unless_it_already_has_one() {
    let mut workspace = Workspace::new();
    let window = workspace.active_window_id().to_owned();
    let stay = workspace.active_pane_id().to_owned();
    let go = workspace.split_pane(SplitDirection::Horizontal, &stay).expect("split");

    let layout_tab = workspace.move_pane_to_new_layout_tab(&go, None).expect("moved");
    assert_eq!(tab_ids(&workspace, &window).last(), Some(&layout_tab));
    assert_eq!(workspace.layout(), Some(&SplitNode::leaf(&go)));
    assert_eq!(workspace.move_pane_to_new_layout_tab(&go, None), None);

    let new_window = workspace.move_pane_to_new_window(&go).expect("moved");
    assert_eq!(workspace.active_window_id(), new_window);
    assert_eq!(workspace.layout(), Some(&SplitNode::leaf(&go)));
    assert_eq!(tab_ids(&workspace, &window).len(), 1, "the emptied tab closed");
    assert_eq!(workspace.move_pane_to_new_window(&go), None);

    assert!(workspace.move_pane_to_new_layout_tab(&go, Some(&window)).is_some());
    assert!(workspace.window(&new_window).is_none());
    assert_eq!(workspace.active_window_id(), window);
    assert_eq!(tab_ids(&workspace, &window).len(), 2);
}

#[test]
fn a_pane_dropped_on_a_layout_tab_joins_it_beside_its_focused_pane() {
    let mut workspace = Workspace::new();
    let first = workspace.active_pane_id().to_owned();
    let first_tab = workspace.active_window().expect("window").active_tab().id.clone();
    workspace.create_layout_tab(None, None).expect("tab");
    let second = workspace.active_pane_id().to_owned();

    assert!(workspace.move_pane_to_layout_tab(&second, &first_tab));
    assert_eq!(workspace.active_window().expect("window").tabs().len(), 1);
    assert_eq!(
        workspace.layout(),
        Some(&SplitNode::split(
            SplitDirection::Horizontal,
            SplitNode::leaf(&first),
            SplitNode::leaf(&second),
            50.0
        ))
    );
    assert!(!workspace.move_pane_to_layout_tab(&second, &first_tab), "already there");
}

#[test]
fn layout_tabs_reorder_move_between_windows_and_take_an_emptied_window_with_them() {
    let mut workspace = Workspace::new();
    let first_window = workspace.active_window_id().to_owned();
    let a = workspace.active_window().expect("window").active_tab().id.clone();
    let b = workspace.create_layout_tab(None, None).expect("tab");
    let c = workspace.create_layout_tab(None, None).expect("tab");

    assert!(workspace.move_layout_tab(&c, &first_window, Some(0)));
    assert_eq!(tab_ids(&workspace, &first_window), [c.clone(), a.clone(), b.clone()]);
    assert_eq!(workspace.active_window().expect("window").active_tab().id, c);

    let second_window = workspace.create_window(None, None).expect("window");
    let d = workspace.active_window().expect("window").active_tab().id.clone();
    let b_panes = workspace.window(&first_window).expect("window").tabs()[2].layout.clone();
    assert!(workspace.move_layout_tab(&b, &second_window, None));
    assert_eq!(tab_ids(&workspace, &second_window), [d.clone(), b.clone()]);
    assert_eq!(workspace.active_window_id(), second_window);
    assert_eq!(workspace.layout(), b_panes.as_ref());

    assert!(workspace.move_layout_tab(&d, &first_window, Some(1)));
    assert!(workspace.move_layout_tab(&b, &first_window, None));
    assert!(workspace.window(&second_window).is_none());
    assert_eq!(tab_ids(&workspace, &first_window), [c, d, a, b]);
    assert_eq!(workspace.pane_count(), 4);
}

#[test]
fn a_layout_tab_gets_a_window_of_its_own_unless_it_is_its_windows_only_tab() {
    let mut workspace = Workspace::new();
    let first_window = workspace.active_window_id().to_owned();
    let only = workspace.active_window().expect("window").active_tab().id.clone();
    assert_eq!(workspace.move_layout_tab_to_new_window(&only), None);

    let second = workspace.create_layout_tab(None, None).expect("tab");
    let new_window = workspace.move_layout_tab_to_new_window(&second).expect("moved");
    assert_eq!(workspace.active_window_id(), new_window);
    assert_eq!(tab_ids(&workspace, &new_window), [second]);
    assert_eq!(tab_ids(&workspace, &first_window), [only]);
}

#[test]
fn merging_a_layout_tab_puts_its_whole_split_beside_the_target_pane() {
    let mut workspace = Workspace::new();
    let target = workspace.active_pane_id().to_owned();
    let into = workspace.active_window().expect("window").active_tab().id.clone();
    let merged = workspace.create_layout_tab(None, None).expect("tab");
    let top = workspace.active_pane_id().to_owned();
    let bottom = workspace.split_pane(SplitDirection::Vertical, &top).expect("split");
    let merged_layout = workspace.layout().cloned().expect("layout");

    assert!(!workspace.merge_layout_tab(&merged, &top, PaneEdge::Left), "into itself");
    assert!(workspace.merge_layout_tab(&merged, &target, PaneEdge::Left));

    let window = workspace.active_window_id().to_owned();
    assert_eq!(tab_ids(&workspace, &window), [into]);
    assert_eq!(
        workspace.layout(),
        Some(&SplitNode::split(SplitDirection::Horizontal, merged_layout, SplitNode::leaf(&target), 50.0))
    );
    assert_eq!(workspace.active_pane_id(), bottom, "focus stays on the merged tab's pane");
}

#[test]
fn merging_into_a_tab_in_another_window_closes_the_emptied_window() {
    let mut workspace = Workspace::new();
    let into = workspace.active_window().expect("window").active_tab().id.clone();
    let target = workspace.active_pane_id().to_owned();
    let other_window = workspace.create_window(None, None).expect("window");
    let moved_pane = workspace.active_pane_id().to_owned();
    let moved_tab = workspace.active_window().expect("window").active_tab().id.clone();

    assert!(workspace.merge_layout_tab_into(&moved_tab, &into));
    assert!(workspace.window(&other_window).is_none());
    assert_eq!(
        workspace.layout(),
        Some(&SplitNode::split(
            SplitDirection::Horizontal,
            SplitNode::leaf(&target),
            SplitNode::leaf(&moved_pane),
            50.0
        ))
    );
}

#[test]
fn moves_stay_inside_a_session_and_within_a_tabs_pane_limit() {
    let mut workspace = Workspace::new();
    let first_window = workspace.active_window_id().to_owned();
    let here = workspace.active_pane_id().to_owned();
    for _ in 1..Workspace::MAX_PANES_PER_TAB {
        workspace.spawn_terminal(None).expect("pane");
    }
    let full_tab = workspace.active_window().expect("window").active_tab().id.clone();
    workspace.create_layout_tab(None, None).expect("tab");
    let outsider = workspace.active_pane_id().to_owned();
    assert!(!workspace.move_pane_beside(&outsider, &here, PaneEdge::Right));
    assert!(!workspace.move_pane_to_layout_tab(&outsider, &full_tab));
    let outsider_tab = workspace.active_window().expect("window").active_tab().id.clone();
    assert!(!workspace.merge_layout_tab(&outsider_tab, &here, PaneEdge::Right));

    workspace.create_session("Other", None).expect("session");
    let foreign = workspace.active_pane_id().to_owned();
    let foreign_window = workspace.active_window_id().to_owned();
    assert!(!workspace.move_pane_beside(&foreign, &outsider, PaneEdge::Right));
    assert_eq!(workspace.move_pane_to_new_layout_tab(&foreign, Some(&first_window)), None);
    let foreign_tab = workspace.active_window().expect("window").active_tab().id.clone();
    assert!(!workspace.move_layout_tab(&foreign_tab, &first_window, None));
    assert!(workspace.window(&foreign_window).is_some());
}

#[test]
fn a_merge_that_would_overfill_the_target_tab_is_refused_and_changes_nothing() {
    let mut workspace = Workspace::new();
    let target = workspace.active_pane_id().to_owned();
    for _ in 2..Workspace::MAX_PANES_PER_TAB {
        workspace.spawn_terminal(None).expect("pane");
    }
    let into = workspace.active_window().expect("window").active_tab().id.clone();
    let crowded = workspace.layout().cloned();
    let pair = workspace.create_layout_tab(None, None).expect("tab");
    let top = workspace.active_pane_id().to_owned();
    workspace.split_pane(SplitDirection::Vertical, &top).expect("split");
    let pair_layout = workspace.layout().cloned();

    assert!(!workspace.can_merge_layout_tab(&pair, &target));
    assert!(!workspace.can_merge_layout_tab_into(&pair, &into));
    assert!(!workspace.merge_layout_tab(&pair, &target, PaneEdge::Right));
    assert_eq!(workspace.layout().cloned(), pair_layout);
    workspace.activate_layout_tab(&into);
    assert_eq!(workspace.layout().cloned(), crowded);

    let single = workspace.create_layout_tab(None, None).expect("tab");
    assert!(workspace.can_merge_layout_tab_into(&single, &into), "19 + 1 fits");
    assert!(workspace.merge_layout_tab_into(&single, &into));
    let lone =
        workspace.window(workspace.active_window_id()).expect("window").tabs()[1].active_pane_id.clone();
    assert!(!workspace.can_move_pane_to_layout_tab(&lone, &into), "the tab is full now");
}
