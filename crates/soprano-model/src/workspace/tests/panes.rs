//! `AgentManagerPaneTests`, `PaneTabShortcutTests` (model parts), and the `AgentManager` case of
//! `SplitNodeTests`.

use super::*;
use crate::agent_instance::AgentInstance;
use crate::pane::{PaneState, PaneTab, PaneType};
use crate::split_node::{SplitBranchSide, SplitNode};
use soprano_types::{NavigationDirection, SplitDirection};

#[test]
fn focusing_the_already_active_tab_does_not_emit_another_model_change() {
    let mut workspace = Workspace::new();
    let pane_id = workspace.active_pane_id().to_owned();
    let tab_id = active_tab_id(&workspace, &pane_id);
    workspace.take_changes();

    workspace.focus_tab(&pane_id, &tab_id, false);

    assert!(workspace.take_changes().is_empty());
}

#[test]
fn spawn_results_are_truthful_and_become_none_at_tab_pane_capacity_without_consuming_an_id() {
    let mut workspace = Workspace::new();
    let mut created = Vec::new();
    for _ in 1..Workspace::MAX_PANES_PER_TAB {
        created.push(workspace.spawn_terminal(None).expect("room for a pane"));
    }

    assert_eq!(workspace.pane_count(), Workspace::MAX_PANES_PER_TAB);
    assert_eq!(workspace.spawn_terminal(None), None);
    assert_eq!(workspace.spawn_agent("codex", None, false), None);
    assert_eq!(workspace.spawn_browser(None), None);
    assert_eq!(workspace.pane_count(), Workspace::MAX_PANES_PER_TAB);

    workspace.close_pane(&created[0]);
    assert_eq!(workspace.spawn_terminal(None).as_deref(), Some("pane-41"));
}

#[test]
fn split_pane_returns_none_at_tab_capacity_without_adding_a_pane() {
    let mut workspace = Workspace::new();
    for _ in 1..Workspace::MAX_PANES_PER_TAB {
        assert!(workspace.spawn_terminal(None).is_some());
    }
    let active = workspace.active_pane_id().to_owned();

    assert_eq!(workspace.split_pane(SplitDirection::Horizontal, &active), None);
    assert_eq!(workspace.pane_count(), Workspace::MAX_PANES_PER_TAB);
}

#[test]
fn a_full_tab_does_not_block_panes_in_a_new_tab_or_another_window() {
    let mut workspace = Workspace::new();
    for _ in 1..Workspace::MAX_PANES_PER_TAB {
        workspace.spawn_terminal(None).expect("room for a pane");
    }
    let full_window_id = workspace.active_window_id().to_owned();
    let full_tab_pane_id = workspace.active_pane_id().to_owned();

    workspace.create_layout_tab(None, None).expect("new tab");
    workspace.spawn_terminal(None).expect("room in the new tab");
    assert_eq!(workspace.split_pane(SplitDirection::Horizontal, &full_tab_pane_id), None);

    let second_window_id = workspace.create_window(None, None).expect("new window");
    let active = workspace.active_pane_id().to_owned();
    workspace.split_pane(SplitDirection::Horizontal, &active).expect("room in the new window");

    assert_eq!(
        workspace.window(&full_window_id).map(|w| w.pane_ids().len()),
        Some(Workspace::MAX_PANES_PER_TAB + 2)
    );
    assert_eq!(workspace.window(&second_window_id).map(|w| w.pane_ids().len()), Some(2));
}

#[test]
fn terminal_split_preserves_working_directory_without_cloning_attached_agent() {
    let mut workspace = Workspace::new();
    let source_pane_id = workspace.active_pane_id().to_owned();
    {
        let tab = &mut workspace.pane_mut(&source_pane_id).expect("pane").tabs[0];
        tab.cwd = Some("/tmp/terminal-project".into());
        tab.agent = Some(AgentInstance::new("manually-attached", "codex"));
    }

    let new_pane_id = workspace.split_pane(SplitDirection::Horizontal, &source_pane_id).expect("split");
    let split_tab = workspace.pane(&new_pane_id).and_then(PaneState::active_tab).expect("tab");

    assert_eq!(split_tab.pane_type, PaneType::Terminal);
    assert!(split_tab.agent.is_none());
    assert_eq!(split_tab.cwd.as_deref(), Some("/tmp/terminal-project"));
}

#[test]
fn agent_split_preserves_working_directory() {
    let mut workspace = Workspace::new();
    let source = workspace.spawn_agent("codex", Some("/tmp/agent-project"), false).expect("agent pane");

    let new_pane_id = workspace.split_pane(SplitDirection::Vertical, &source).expect("split");
    let split_tab = workspace.pane(&new_pane_id).and_then(PaneState::active_tab).expect("tab");

    assert_eq!(split_tab.pane_type, PaneType::Agent);
    assert_eq!(split_tab.agent.as_ref().map(|a| a.profile_id.as_str()), Some("codex"));
    assert_eq!(split_tab.cwd.as_deref(), Some("/tmp/agent-project"));
}

#[test]
fn live_working_directory_is_inherited_by_new_content() {
    let mut workspace = Workspace::new();
    let source_pane_id = workspace.active_pane_id().to_owned();
    let source_tab_id = active_tab_id(&workspace, &source_pane_id);

    workspace.update_working_directory(&source_pane_id, &source_tab_id, "/tmp/live-project");

    let split_pane_id = workspace.split_pane(SplitDirection::Horizontal, &source_pane_id).expect("split");
    assert_eq!(
        workspace.pane(&split_pane_id).and_then(|p| p.active_tab()).and_then(|t| t.cwd.as_deref()),
        Some("/tmp/live-project")
    );

    workspace.focus_tab(&source_pane_id, &source_tab_id, false);
    let tab_id = workspace.add_tab_to_pane(&source_pane_id, PaneType::Terminal, None, None).expect("tab");
    assert_eq!(
        workspace.tab(&source_pane_id, &tab_id).and_then(|t| t.cwd.as_deref()),
        Some("/tmp/live-project")
    );

    workspace.switch_tab(&source_pane_id, 0);
    let agent_pane_id = workspace.spawn_agent("codex", None, false).expect("agent");
    assert_eq!(
        workspace.pane(&agent_pane_id).and_then(|p| p.active_tab()).and_then(|t| t.cwd.as_deref()),
        Some("/tmp/live-project")
    );

    workspace.focus_tab(&source_pane_id, &source_tab_id, false);
    let window_id = workspace.create_window(None, None).expect("window");
    let active = workspace.active_pane_id().to_owned();
    assert_eq!(workspace.window(&window_id).map(|w| w.active_pane_id().to_owned()), Some(active.clone()));
    assert_eq!(
        workspace.pane(&active).and_then(|p| p.active_tab()).and_then(|t| t.cwd.as_deref()),
        Some("/tmp/live-project")
    );
}

#[test]
fn working_directory_updates_only_the_exact_terminal_tab() {
    let mut workspace = Workspace::new();
    let pane_id = workspace.active_pane_id().to_owned();
    let first_tab_id = active_tab_id(&workspace, &pane_id);
    let second_tab_id = workspace.add_tab_to_pane(&pane_id, PaneType::Terminal, None, None).expect("tab");

    workspace.update_working_directory(&pane_id, &first_tab_id, "/tmp/first");
    workspace.update_working_directory("missing-pane", &second_tab_id, "/tmp/ignored");

    assert_eq!(workspace.tab(&pane_id, &first_tab_id).and_then(|t| t.cwd.as_deref()), Some("/tmp/first"));
    assert_eq!(workspace.tab(&pane_id, &second_tab_id).and_then(|t| t.cwd.as_deref()), None);
}

#[test]
fn navigation_uses_wrap_when_no_direct_adjacent_pane_exists() {
    let mut workspace = Workspace::new();
    let second = workspace.spawn_terminal(None).expect("pane");
    workspace.set_layout(Some(SplitNode::split(
        SplitDirection::Horizontal,
        SplitNode::leaf("pane-1"),
        SplitNode::leaf(&second),
        50.0,
    )));
    workspace.focus_pane("pane-1");

    workspace.navigate_to_pane(NavigationDirection::Left);

    assert_eq!(workspace.active_pane_id(), second);
}

#[test]
fn last_window_toggles_between_the_two_most_recently_active_logical_windows() {
    let mut workspace = Workspace::new();
    let second = workspace.create_window(None, None).expect("window");
    let third = workspace.create_window(None, None).expect("window");

    workspace.activate_last_window();
    assert_eq!(workspace.active_window_id(), second);

    workspace.activate_last_window();
    assert_eq!(workspace.active_window_id(), third);
}

#[test]
fn focusing_a_pane_in_another_window_updates_the_last_window_target() {
    let mut workspace = Workspace::new();
    let first_window_id = workspace.active_window_id().to_owned();
    let first_pane_id = workspace.active_pane_id().to_owned();
    let second_window_id = workspace.create_window(None, None).expect("window");

    workspace.focus_pane(&first_pane_id);
    assert_eq!(workspace.active_window_id(), first_window_id);

    workspace.activate_last_window();
    assert_eq!(workspace.active_window_id(), second_window_id);
}

#[test]
fn closing_the_last_window_target_clears_it() {
    let mut workspace = Workspace::new();
    let first_window_id = workspace.active_window_id().to_owned();
    let second_window_id = workspace.create_window(None, None).expect("window");

    workspace.close_window(&first_window_id);
    workspace.activate_last_window();

    assert_eq!(workspace.active_window_id(), second_window_id);
}

#[test]
fn alphabetic_pane_hints_use_visual_order_across_logical_windows() {
    let mut workspace = Workspace::new();
    let second = workspace.spawn_terminal(None).expect("pane");
    let third = workspace.spawn_terminal(None).expect("pane");
    workspace.set_layout(Some(SplitNode::split(
        SplitDirection::Horizontal,
        SplitNode::leaf(&third),
        SplitNode::split(SplitDirection::Vertical, SplitNode::leaf("pane-1"), SplitNode::leaf(&second), 50.0),
        50.0,
    )));
    let window_id = workspace.active_window_id().to_owned();

    let ordered: Vec<String> = workspace.ordered_panes(&window_id).iter().map(|p| p.id.clone()).collect();
    assert_eq!(ordered, [third.clone(), "pane-1".into(), second.clone()]);
    let assignments = workspace.pane_shortcut_assignments();
    assert_eq!(assignments.iter().map(|a| a.key.as_str()).collect::<Vec<_>>(), ["b", "d", "e"]);
    assert_eq!(
        assignments.iter().map(|a| a.pane_id.clone()).collect::<Vec<_>>(),
        [third.clone(), "pane-1".into(), second.clone()]
    );

    fn focus(workspace: &mut Workspace, key: &str) -> bool {
        let key = key.to_lowercase();
        let Some(pane_id) =
            workspace.pane_shortcut_assignments().into_iter().find(|a| a.key == key).map(|a| a.pane_id)
        else {
            return false;
        };
        workspace.focus_pane(&pane_id);
        true
    }

    assert!(focus(&mut workspace, "d"));
    assert_eq!(workspace.active_pane_id(), "pane-1");
    assert!(focus(&mut workspace, "E"));
    assert_eq!(workspace.active_pane_id(), second);
    assert!(!focus(&mut workspace, "a"));
    assert_eq!(workspace.active_pane_id(), second);

    let second_window_id = workspace.create_window(None, None).expect("window");
    let second_window_pane = workspace.active_pane_id().to_owned();
    let last = workspace.pane_shortcut_assignments().pop().expect("assignment");
    assert_eq!(last.key, "f");
    assert_eq!(last.pane_id, second_window_pane);

    assert!(focus(&mut workspace, "b"));
    assert_eq!(workspace.active_window_id(), window_id);
    assert_eq!(workspace.active_pane_id(), third);
    assert_ne!(workspace.active_window_id(), second_window_id);
}

#[test]
fn every_pane_down_to_the_last_window_gets_a_hint_once_there_are_more_panes_than_letters() {
    let mut workspace = Workspace::new();
    for _ in 0..29 {
        workspace.create_window(None, None).expect("window");
    }
    let pane_ids: Vec<String> = workspace
        .active_session_windows()
        .iter()
        .flat_map(|w| workspace.ordered_panes(&w.id).into_iter().map(|p| p.id.clone()))
        .collect();
    let assignments = workspace.pane_shortcut_assignments();

    assert_eq!(pane_ids.len(), 30);
    assert_eq!(assignments.iter().map(|a| a.pane_id.clone()).collect::<Vec<_>>(), pane_ids);
    // Single letters while they last; the last one turns into the first key of the two-letter
    // hints that cover the rest.
    let singles: Vec<String> = "bdefgimnopqrstuvwxy".chars().map(String::from).collect();
    assert_eq!(assignments[..19].iter().map(|a| a.key.clone()).collect::<Vec<_>>(), singles);
    assert_eq!(
        assignments[19..].iter().map(|a| a.key.as_str()).collect::<Vec<_>>(),
        ["zb", "zd", "ze", "zf", "zg", "zi", "zm", "zn", "zo", "zp", "zq"]
    );
}

#[test]
fn pane_hints_are_unique_shortest_first_and_never_start_another_hint() {
    for count in [1, 20, 21, 45, 400, 401] {
        let hints = Workspace::pane_hints(count);
        assert_eq!(hints.len(), count);
        assert_eq!(hints.iter().collect::<HashSet<_>>().len(), count);
        let lengths: Vec<usize> = hints.iter().map(String::len).collect();
        let mut sorted = lengths.clone();
        sorted.sort();
        assert_eq!(lengths, sorted);
        let expected_last = if count <= 20 {
            1
        } else if count <= 400 {
            2
        } else {
            3
        };
        assert_eq!(hints.last().map(String::len), Some(expected_last), "{count}");
        let all: HashSet<&str> = hints.iter().map(String::as_str).collect();
        for hint in &hints {
            for end in 1..hint.len() {
                assert!(!all.contains(&hint[..end]), "{hint} starts with another hint");
            }
        }
    }
}

#[test]
fn window_search_lands_on_the_first_matching_pane_tab_even_in_a_background_layout_tab() {
    let mut workspace = Workspace::new();
    let window_id = workspace.active_window_id().to_owned();
    let first_layout_tab = workspace.active_window().map(|w| w.active_tab().id.clone()).expect("tab");
    let theme_pane = workspace.active_pane_id().to_owned();
    workspace.pane_mut(&theme_pane).expect("pane").tabs[0].title = "theme".into();

    workspace.create_layout_tab(None, None).expect("tab");
    let app_pane = workspace.active_pane_id().to_owned();
    {
        let pane = workspace.pane_mut(&app_pane).expect("pane");
        pane.tabs[0].title = "logs".into();
        pane.tabs.push(PaneTab::new("b2c-tab", PaneType::Terminal, "B2C app"));
        pane.tabs.push(PaneTab::new("b2c-later", PaneType::Terminal, "b2c dev"));
    }
    let later_pane = workspace.split_pane(SplitDirection::Horizontal, &app_pane).expect("split");
    workspace.pane_mut(&later_pane).expect("pane").tabs[0].title = "b2c shell".into();

    workspace.activate_layout_tab(&first_layout_tab);
    workspace.create_window(None, None).expect("window");

    assert_eq!(workspace.first_tab_matching(&window_id, "   "), None);
    assert_eq!(workspace.first_tab_matching(&window_id, "missing"), None);
    let found = workspace.first_tab_matching(&window_id, " b2c ").expect("match");
    assert_eq!(found, TerminalTarget::new(&app_pane, "b2c-tab"));

    workspace.focus_tab(&found.pane_id, &found.tab_id, false);

    assert_eq!(workspace.active_window_id(), window_id);
    assert_eq!(workspace.active_pane_id(), app_pane);
    assert_eq!(active_tab_id(&workspace, &app_pane), "b2c-tab");
    assert!(
        workspace.window(&window_id).and_then(|w| w.layout()).is_some_and(|l| l.contains_leaf(&app_pane))
    );
}

#[test]
fn workspace_sets_an_absolute_nested_percentage_without_changing_topology_generation() {
    let mut workspace = Workspace::new();
    let nested = SplitNode::split(
        SplitDirection::Horizontal,
        SplitNode::leaf("pane-1"),
        SplitNode::split(
            SplitDirection::Vertical,
            SplitNode::leaf("pane-2"),
            SplitNode::leaf("pane-3"),
            35.0,
        ),
        40.0,
    );
    workspace.set_layout(Some(nested));
    let generation = workspace.layout_generation();

    workspace.set_split_percentage(&[SplitBranchSide::Second], 125.0);

    let layout = workspace.layout().expect("layout");
    assert_eq!(layout.split_percentage_at(&[]), Some(40.0));
    assert_eq!(layout.split_percentage_at(&[SplitBranchSide::Second]), Some(90.0));
    assert_eq!(workspace.layout_generation(), generation);

    let saved = workspace.snapshot_workspace().layout.expect("saved layout");
    assert_eq!(saved.split_percentage_at(&[SplitBranchSide::Second]), Some(90.0));
}

#[test]
fn resizing_grows_the_focused_pane_along_the_nearest_matching_split() {
    let mut workspace = Workspace::new();
    let right = workspace.split_pane(SplitDirection::Horizontal, "pane-1").expect("split");
    let below = workspace.split_pane(SplitDirection::Vertical, &right).expect("split");
    let generation = workspace.layout_generation();

    workspace.resize_pane(NavigationDirection::Left, 5.0);
    assert_eq!(workspace.active_pane_id(), below);
    let layout = workspace.layout().expect("layout");
    assert_eq!(layout.split_percentage_at(&[]), Some(45.0));
    assert_eq!(layout.split_percentage_at(&[SplitBranchSide::Second]), Some(50.0));

    workspace.resize_pane(NavigationDirection::Down, 5.0);
    assert_eq!(
        workspace.layout().and_then(|l| l.split_percentage_at(&[SplitBranchSide::Second])),
        Some(55.0)
    );
    assert_eq!(workspace.layout_generation(), generation);
}

#[test]
fn maximizing_needs_two_panes_and_any_topology_change_ends_it() {
    let mut workspace = Workspace::new();
    workspace.toggle_maximize();
    assert_eq!(workspace.maximized_pane_id(), None);

    let second = workspace.split_pane(SplitDirection::Horizontal, "pane-1").expect("split");
    workspace.toggle_maximize();
    assert_eq!(workspace.maximized_pane_id(), Some(second.as_str()));
    workspace.toggle_maximize();
    assert_eq!(workspace.maximized_pane_id(), None);

    workspace.toggle_maximize();
    workspace.navigate_to_pane(NavigationDirection::Left);
    assert_eq!(workspace.maximized_pane_id(), None);
    assert_eq!(workspace.active_pane_id(), "pane-1");
}

// MARK: - PaneTabShortcutTests (model parts: the actions the chords run)

#[test]
fn new_tabs_cycle_and_close_inside_the_focused_split_only() {
    let mut workspace = Workspace::new();
    let left = workspace.active_pane_id().to_owned();
    let right = workspace.split_pane(SplitDirection::Horizontal, &left).expect("split");
    assert_eq!(workspace.active_pane_id(), right);

    workspace.add_tab_to_pane(&right, PaneType::Terminal, None, None).expect("tab");
    workspace.add_tab_to_pane(&right, PaneType::Terminal, None, None).expect("tab");
    let pane = |w: &Workspace| w.pane(&right).cloned().expect("pane");
    assert_eq!(pane(&workspace).tabs.len(), 3);
    assert_eq!(pane(&workspace).active_tab_index, 2);
    assert_eq!(workspace.pane(&left).map(|p| p.tabs.len()), Some(1));

    workspace.prev_tab(&right);
    assert_eq!(pane(&workspace).active_tab_index, 1);
    workspace.next_tab(&right);
    workspace.next_tab(&right);
    assert_eq!(pane(&workspace).active_tab_index, 0);

    let closed = active_tab_id(&workspace, &right);
    workspace.remove_tab_from_pane(&right, &closed);
    assert_eq!(pane(&workspace).tabs.len(), 2);
    assert!(pane(&workspace).tab(&closed).is_none());
    assert_eq!(workspace.pane(&left).map(|p| p.tabs.len()), Some(1));
}

#[test]
fn closing_the_active_pane_tab_closes_only_it_until_the_last_one_takes_the_pane() {
    let mut workspace = Workspace::new();
    let left = workspace.active_pane_id().to_owned();
    let right = workspace.split_pane(SplitDirection::Horizontal, &left).expect("split");
    workspace.add_tab_to_pane(&right, PaneType::Terminal, None, None).expect("tab");
    workspace.add_tab_to_pane(&right, PaneType::Terminal, None, None).expect("tab");

    for remaining in [2, 1] {
        let closed = active_tab_id(&workspace, &right);
        assert_eq!(workspace.remove_tab_from_pane(&right, &closed), CloseOutcome::Closed);
        let pane = workspace.pane(&right).expect("pane stays");
        assert_eq!(pane.tabs.len(), remaining);
        assert!(pane.tab(&closed).is_none());
    }

    let last = active_tab_id(&workspace, &right);
    workspace.remove_tab_from_pane(&right, &last);
    assert!(workspace.pane(&right).is_none());
    assert_eq!(workspace.pane(&left).map(|p| p.tabs.len()), Some(1));
}
