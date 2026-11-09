//! `LayoutTabTests`.

use super::*;
use crate::pane::PaneType;
use crate::session::WorkspaceSession;
use crate::split_node::SplitNode;
use soprano_types::SplitDirection;

#[test]
fn a_new_tab_opens_a_fresh_terminal_in_the_active_directory_and_switching_back_restores_the_layout() {
    let mut workspace = Workspace::new();
    let root = workspace.active_pane_id().to_owned();
    let root_tab = active_tab_id(&workspace, &root);
    workspace.update_working_directory(&root, &root_tab, "/tmp/tab-project");
    let sibling = workspace.split_pane(SplitDirection::Horizontal, &root).expect("split");
    workspace.focus_pane(&root);
    let first_layout = workspace.layout().cloned();

    let layout_tab_id = workspace.create_layout_tab(None, None).expect("tab");
    let new_pane = workspace.active_pane_id().to_owned();

    let window = workspace.active_window().expect("window");
    assert_eq!(window.tabs().last().map(|t| t.id.as_str()), Some(layout_tab_id.as_str()));
    assert_eq!(window.active_tab().id, layout_tab_id);
    assert_eq!(workspace.layout(), Some(&SplitNode::leaf(&new_pane)));
    let tab = workspace.pane(&new_pane).and_then(|p| p.active_tab()).expect("tab");
    assert_eq!(tab.pane_type, PaneType::Terminal);
    assert_eq!(tab.cwd.as_deref(), Some("/tmp/tab-project"));

    workspace.activate_previous_layout_tab();
    assert_eq!(workspace.layout().cloned(), first_layout);
    assert_eq!(workspace.active_pane_id(), root);
    assert!(workspace.pane(&sibling).is_some());

    workspace.activate_next_layout_tab();
    assert_eq!(workspace.active_pane_id(), new_pane);
    assert_eq!(workspace.pane_count(), 3);
}

#[test]
fn next_and_previous_tab_wrap_around_the_row_and_do_nothing_with_one_tab() {
    let mut workspace = Workspace::new();
    let first = workspace.active_pane_id().to_owned();
    workspace.take_changes();
    workspace.activate_next_layout_tab();
    workspace.activate_previous_layout_tab();
    assert!(workspace.take_changes().is_empty());
    assert_eq!(workspace.active_pane_id(), first);

    workspace.create_layout_tab(None, None).expect("tab");
    let second = workspace.active_pane_id().to_owned();
    workspace.create_layout_tab(None, None).expect("tab");
    let third = workspace.active_pane_id().to_owned();

    workspace.activate_next_layout_tab();
    assert_eq!(workspace.active_pane_id(), first);
    workspace.activate_previous_layout_tab();
    assert_eq!(workspace.active_pane_id(), third);
    workspace.activate_previous_layout_tab();
    assert_eq!(workspace.active_pane_id(), second);
}

#[test]
fn splits_and_closes_stay_inside_their_tab() {
    let mut workspace = Workspace::new();
    let root = workspace.active_pane_id().to_owned();
    workspace.create_layout_tab(None, None).expect("tab");
    let tab_pane = workspace.active_pane_id().to_owned();
    let split = workspace.split_pane(SplitDirection::Vertical, &tab_pane).expect("split");

    assert_eq!(
        workspace.layout().map(SplitNode::ordered_leaf_ids),
        Some(vec![tab_pane.clone(), split.clone()])
    );
    assert_eq!(
        workspace.active_window().map(|w| w.tabs()[0].layout.clone()),
        Some(Some(SplitNode::leaf(&root)))
    );

    workspace.close_pane(&split);
    assert_eq!(workspace.layout(), Some(&SplitNode::leaf(&tab_pane)));
    assert_eq!(workspace.active_window().map(|w| w.tabs().len()), Some(2));
}

#[test]
fn focusing_a_pane_or_pane_tab_in_a_background_tab_brings_that_tab_to_the_front() {
    let mut workspace = Workspace::new();
    let root = workspace.active_pane_id().to_owned();
    let other_window = workspace.create_window(None, None).expect("window");
    let other_pane = workspace.active_pane_id().to_owned();
    workspace.create_layout_tab(None, None).expect("tab");
    let generation = workspace.layout_generation();

    workspace.focus_pane(&other_pane);
    assert_eq!(workspace.active_window_id(), other_window);
    assert_eq!(workspace.window(&other_window).map(|w| w.active_tab_index()), Some(0));
    assert_eq!(workspace.layout(), Some(&SplitNode::leaf(&other_pane)));
    assert!(workspace.layout_generation() > generation);

    let root_tab = active_tab_id(&workspace, &root);
    workspace.focus_tab(&root, &root_tab, false);
    assert_eq!(workspace.active_pane_id(), root);
    assert_eq!(workspace.layout(), Some(&SplitNode::leaf(&root)));
}

#[test]
fn closing_a_tabs_last_pane_shows_its_right_neighbor_and_the_last_tab_takes_the_window() {
    let mut workspace = Workspace::new();
    let first_window = workspace.active_window_id().to_owned();
    let window_id = workspace.create_window(None, None).expect("window");
    let first_pane = workspace.active_pane_id().to_owned();
    workspace.create_layout_tab(None, None).expect("tab");
    let middle = workspace.active_pane_id().to_owned();
    workspace.create_layout_tab(None, None).expect("tab");
    let last = workspace.active_pane_id().to_owned();
    workspace.focus_pane(&middle);

    workspace.close_pane(&middle);
    assert_eq!(workspace.window(&window_id).map(|w| w.tabs().len()), Some(2));
    assert_eq!(workspace.active_pane_id(), last);

    workspace.close_pane(&last);
    assert_eq!(workspace.window(&window_id).map(|w| w.tabs().len()), Some(1));
    assert_eq!(workspace.active_pane_id(), first_pane);

    workspace.close_active_layout_tab();
    assert!(workspace.window(&window_id).is_none());
    assert_eq!(workspace.active_window_id(), first_window);
}

#[test]
fn closing_a_pane_in_a_background_tab_leaves_the_visible_tab_on_screen() {
    let mut workspace = Workspace::new();
    let root = workspace.active_pane_id().to_owned();
    let background = workspace.split_pane(SplitDirection::Horizontal, &root).expect("split");
    workspace.create_layout_tab(None, None).expect("tab");
    let visible = workspace.active_pane_id().to_owned();
    let generation = workspace.layout_generation();

    workspace.close_pane(&background);

    let window = workspace.active_window().expect("window");
    assert_eq!(window.active_tab_index(), 1);
    assert_eq!(workspace.active_pane_id(), visible);
    assert_eq!(window.tabs()[0].layout, Some(SplitNode::leaf(&root)));
    assert!(workspace.layout_generation() > generation);
}

#[test]
fn closing_a_tab_asks_about_every_tab_in_its_panes_and_cancelling_keeps_it() {
    let mut workspace = Workspace::new();
    let root = workspace.active_pane_id().to_owned();
    let layout_tab_id = workspace.create_layout_tab(None, None).expect("tab");
    let first = workspace.active_pane_id().to_owned();
    let second = workspace.split_pane(SplitDirection::Horizontal, &first).expect("split");
    let pane_tab = workspace.add_tab_to_pane(&second, PaneType::Terminal, None, None).expect("tab");
    let expected = targets(&workspace, &[&first, &second]);
    assert!(expected.contains(&TerminalTarget::new(&second, &pane_tab)));
    always_ask(&mut workspace);

    let outcome = workspace.close_layout_tab(&layout_tab_id);
    assert_eq!(asked_about(&outcome), expected);
    assert_eq!(workspace.active_window().map(|w| w.tabs().len()), Some(2));
    assert!(workspace.pane(&first).is_some());

    let CloseOutcome::NeedsConfirmation { request, .. } = outcome else { unreachable!() };
    assert_eq!(workspace.force_close(request), CloseOutcome::Closed);
    assert_eq!(workspace.active_window().map(|w| w.tabs().len()), Some(1));
    assert!(workspace.pane(&first).is_none());
    assert!(workspace.pane(&second).is_none());
    assert_eq!(workspace.active_pane_id(), root);
}

#[test]
fn switching_tabs_ends_a_maximized_pane() {
    let mut workspace = Workspace::new();
    let root = workspace.active_pane_id().to_owned();
    workspace.split_pane(SplitDirection::Horizontal, &root).expect("split");
    workspace.toggle_maximize();
    assert!(workspace.maximized_pane_id().is_some());

    workspace.create_layout_tab(None, None).expect("tab");
    assert!(workspace.maximized_pane_id().is_none());

    workspace.activate_previous_layout_tab();
    workspace.toggle_maximize();
    assert!(workspace.maximized_pane_id().is_some());
    workspace.activate_next_layout_tab();
    assert!(workspace.maximized_pane_id().is_none());
}

#[test]
fn workspace_round_trip_restores_every_tab_and_the_active_one() {
    let mut source = Workspace::new();
    let root = source.active_pane_id().to_owned();
    source.create_layout_tab(None, None).expect("tab");
    let first = source.active_pane_id().to_owned();
    let second = source.split_pane(SplitDirection::Vertical, &first).expect("split");
    source.focus_pane(&first);
    source.create_layout_tab(None, None).expect("tab");
    let last = source.active_pane_id().to_owned();
    source.activate_previous_layout_tab();

    let mut restored = Workspace::new();
    restored.restore_workspace(source.snapshot_workspace());

    let window = restored.active_window().expect("window");
    assert_eq!(
        window.tabs().iter().map(|t| t.layout.clone()).collect::<Vec<_>>(),
        [Some(SplitNode::leaf(&root)), source.layout().cloned(), Some(SplitNode::leaf(&last))]
    );
    assert_eq!(window.active_tab_index(), 1);
    assert_eq!(restored.active_pane_id(), first);
    assert_eq!(restored.layout().map(SplitNode::ordered_leaf_ids), Some(vec![first.clone(), second.clone()]));
    let ids: HashSet<String> = window.tabs().iter().map(|t| t.id.clone()).collect();
    assert_eq!(ids.len(), 3);

    let new_tab = restored.create_layout_tab(None, None).expect("tab");
    assert!(!ids.contains(&new_tab));
}

#[test]
fn workspaces_saved_with_window_depth_reopen_each_layer_as_a_tab() {
    let json = r#"
    {
      "id": "last", "name": "Last Session", "savedAt": 0, "activePaneId": "pane-5",
      "panes": [
        {"id": "pane-1", "activeTabIndex": 0, "tabs": [{"id": "tab-2", "type": "terminal", "cwd": "/tmp/root"}]},
        {"id": "pane-3", "activeTabIndex": 0, "tabs": [{"id": "tab-4", "type": "terminal"}]},
        {"id": "pane-5", "activeTabIndex": 0, "tabs": [{"id": "tab-6", "type": "terminal"}]},
        {"id": "pane-7", "activeTabIndex": 0, "tabs": [{"id": "tab-8", "type": "terminal"}]}
      ],
      "windows": [{
        "id": "window-9", "title": "Soprano", "isTitleCustom": true,
        "layout": {"leaf": {"_0": "pane-1"}}, "activePaneId": "pane-5",
        "depthLayers": [
          {"layout": {"leaf": {"_0": "pane-1"}}, "activePaneId": "pane-1", "isExpanded": true},
          {"parentPaneId": "pane-1", "isExpanded": true, "activePaneId": "pane-5",
           "layout": {"split": {"_0": {"direction": "horizontal", "splitPercentage": 40,
             "first": {"leaf": {"_0": "pane-3"}}, "second": {"leaf": {"_0": "pane-5"}}}}}},
          {"parentPaneId": "pane-5", "isExpanded": false, "activePaneId": "pane-7",
           "layout": {"leaf": {"_0": "pane-7"}}}
        ],
        "activeDepthLayerIndex": 1,
        "activeDepth": 1
      }],
      "activeWindowId": "window-9"
    }
    "#;
    let session: WorkspaceSession = serde_json::from_str(json).expect("decodes");
    let mut workspace = Workspace::new();

    workspace.restore_workspace(session);

    let window = workspace.window("window-9").expect("window");
    assert_eq!(window.title, "Soprano");
    assert_eq!(
        window
            .tabs()
            .iter()
            .map(|t| t.layout.as_ref().map(SplitNode::ordered_leaf_ids).unwrap_or_default())
            .collect::<Vec<_>>(),
        [vec!["pane-1".to_owned()], vec!["pane-3".into(), "pane-5".into()], vec!["pane-7".into()]]
    );
    assert_eq!(
        window.tabs().iter().map(|t| t.active_pane_id.as_str()).collect::<Vec<_>>(),
        ["pane-1", "pane-5", "pane-7"]
    );
    assert_eq!(window.active_tab_index(), 1);
    assert_eq!(workspace.active_pane_id(), "pane-5");
    assert_eq!(workspace.pane_count(), 4);

    let resaved = serde_json::to_string(&workspace.snapshot_workspace()).expect("encodes");
    assert!(!resaved.contains("depthLayers"));
    let decoded: WorkspaceSession = serde_json::from_str(&resaved).expect("decodes");
    let resaved_window = decoded.windows.and_then(|w| w.into_iter().next()).expect("window");
    assert!(resaved_window.depth_layers.is_none());
    assert_eq!(resaved_window.tabs.map(|t| t.len()), Some(3));
    assert_eq!(resaved_window.active_tab_index, Some(1));
}
