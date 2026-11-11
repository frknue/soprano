//! `TerminalSessionTests` (model parts), `SidebarCollapseAllTests` and the window-tab model
//! parts of `WindowTabBarTests` / `LayoutTabBarTests`, plus automation-run windows from
//! `AutomationControllerTests`.

use super::*;
use crate::session::WorkspaceSession;
use crate::{PaneType, TerminalLifecycleAction, WorkspaceEvent};
use soprano_types::{AgentLaunch, AgentStatus, AgentWaitingReason};

#[test]
fn window_navigation_and_number_shortcuts_stay_inside_the_current_session() {
    let mut workspace = Workspace::new();
    let first_session = workspace.active_session_id().to_owned();
    let first_window = workspace.active_window_id().to_owned();
    let second_window = workspace.create_window(None, None).expect("window");
    let other_session = workspace.create_session("Other project", None).expect("session");
    let other_window = workspace.active_window_id().to_owned();

    workspace.activate_next_window();
    workspace.activate_previous_window();
    workspace.activate_window_number(2);
    workspace.activate_last_window();
    assert_eq!(workspace.active_window_id(), other_window);
    assert_eq!(workspace.active_session_id(), other_session);

    workspace.activate_session(&first_session);
    assert_eq!(workspace.active_window_id(), second_window);
    workspace.activate_next_window();
    assert_eq!(workspace.active_window_id(), first_window);
    workspace.activate_previous_window();
    assert_eq!(workspace.active_window_id(), second_window);
    workspace.activate_window_number(1);
    assert_eq!(workspace.active_window_id(), first_window);
    workspace.activate_window_number(3);
    assert_eq!(workspace.active_window_id(), first_window);
    assert_eq!(workspace.active_session_id(), first_session);
}

#[test]
fn windows_keep_their_creation_order_once_ids_reach_two_digits() {
    let mut workspace = Workspace::new();
    let mut created = vec![workspace.active_window_id().to_owned()];
    for _ in 0..10 {
        created.push(workspace.create_window(None, None).expect("window"));
    }

    assert_eq!(workspace.ordered_windows().iter().map(|w| w.id.clone()).collect::<Vec<_>>(), created);
    assert_eq!(workspace.active_session_windows().iter().map(|w| w.id.clone()).collect::<Vec<_>>(), created);
}

#[test]
fn each_session_remembers_its_own_current_and_previous_window() {
    let mut workspace = Workspace::new();
    let first_session = workspace.active_session_id().to_owned();
    let first_window = workspace.active_window_id().to_owned();
    let second_window = workspace.create_window(None, None).expect("window");
    let other_session = workspace.create_session("Other", None).expect("session");
    let other_first = workspace.active_window_id().to_owned();
    let other_second = workspace.create_window(None, None).expect("window");

    workspace.activate_session(&first_session);
    workspace.activate_last_window();
    assert_eq!(workspace.active_window_id(), first_window);
    workspace.activate_last_window();
    assert_eq!(workspace.active_window_id(), second_window);
    workspace.activate_session(&other_session);
    assert_eq!(workspace.active_window_id(), other_second);
    workspace.activate_last_window();
    assert_eq!(workspace.active_window_id(), other_first);
}

#[test]
fn switching_sessions_preserves_tabs_and_focusing_an_exact_pane_switches_its_session() {
    let mut workspace = Workspace::new();
    let first_session = workspace.active_session_id().to_owned();
    workspace.create_layout_tab(None, None).expect("tab");
    let inner_pane = workspace.active_pane_id().to_owned();
    let inner_tab = active_tab_id(&workspace, &inner_pane);
    let inner_state = workspace.pane(&inner_pane).cloned();
    let first_layout = workspace.layout().cloned();
    let other_session = workspace.create_session("Other", None).expect("session");
    let other_pane = workspace.active_pane_id().to_owned();

    assert_eq!(workspace.active_window().map(|w| w.tabs().len()), Some(1));
    assert_eq!(
        workspace.pane_shortcut_assignments().into_iter().map(|a| a.pane_id).collect::<Vec<_>>(),
        std::slice::from_ref(&other_pane)
    );
    workspace.focus_tab(&inner_pane, &inner_tab, false);
    assert_eq!(workspace.active_session_id(), first_session);
    assert_eq!(workspace.active_window().map(|w| w.active_tab_index()), Some(1));
    assert_eq!(workspace.layout().cloned(), first_layout);
    assert_eq!(workspace.pane(&inner_pane).cloned(), inner_state);
    workspace.activate_session(&other_session);
    assert_eq!(workspace.active_pane_id(), other_pane);
}

#[test]
fn new_windows_inherit_the_current_directory_and_belong_to_the_selected_session() {
    let mut workspace = Workspace::new();
    let session_id = workspace.create_session("  Project  ", Some("/tmp/project")).expect("session");
    let window_id = workspace.create_window(None, None).expect("window");

    assert_eq!(workspace.active_session().map(|s| s.name.as_str()), Some("Project"));
    assert_eq!(workspace.window(&window_id).map(|w| w.session_id.as_str()), Some(session_id.as_str()));
    assert_eq!(workspace.active_working_directory().as_deref(), Some("/tmp/project"));
    assert_eq!(workspace.active_session_windows().len(), 2);
    assert_eq!(workspace.ordered_windows().len(), 3);
    assert_eq!(workspace.create_session(" \n ", None), None);
    assert_eq!(workspace.terminal_sessions().len(), 2);
    workspace.rename_session(&session_id, "  Renamed  ");
    assert_eq!(workspace.active_session().map(|s| s.name.as_str()), Some("Renamed"));
}

#[test]
fn a_terminal_on_a_machine_passes_it_to_what_opens_from_it_but_not_to_new_sessions() {
    let mut workspace = Workspace::new();
    workspace.spawn_terminal(Some("/tmp/project")).expect("local pane");
    let local = workspace.active_pane_id().to_owned();
    let remote_pane = workspace.spawn_terminal_on("vps").expect("remote pane");
    let remote_tab =
        workspace.pane(&remote_pane).and_then(|p| p.active_tab()).map(|t| t.id.clone()).expect("tab");
    assert_eq!(workspace.machine_of_pane(&remote_pane), Some("vps"));
    assert_eq!(workspace.active_working_directory(), None);

    // Splits, pane tabs, new agents and windows from there run on the same machine, each
    // under its own key; a browser tab stays here.
    let split = workspace.split_pane(soprano_types::SplitDirection::Horizontal, &remote_pane).expect("split");
    let agent = workspace.spawn_agent("claude-code", None, false).expect("agent");
    for pane in [&split, &agent] {
        assert_eq!(workspace.machine_of_pane(pane), Some("vps"));
    }
    let browser = workspace.add_tab_to_pane(&split, PaneType::Browser, None, None).expect("browser tab");
    assert_eq!(workspace.remote_of_tab(&split, &browser), None);
    workspace.focus_pane(&agent);
    let split_tab = workspace.pane(&split).map(|p| p.tabs[0].id.clone()).expect("tab");
    assert_ne!(
        workspace.remote_of_tab(&split, &split_tab),
        workspace.remote_of_tab(&remote_pane, &remote_tab)
    );
    workspace.create_window(None, None).expect("window");
    assert_eq!(workspace.machine_of_pane(workspace.active_pane_id()), Some("vps"));
    // A folder named explicitly is on this computer.
    let explicit = workspace.spawn_terminal(Some("/srv")).expect("pane");
    assert_eq!(workspace.machine_of_pane(&explicit), None);
    assert_eq!(workspace.machine_of_pane(&local), None);

    let encoded = serde_json::to_string(&workspace.snapshot_workspace()).expect("encodes");
    let mut restored = Workspace::new();
    restored.restore_workspace(serde_json::from_str(&encoded).expect("decodes"));
    assert_eq!(
        restored.remote_of_tab(&remote_pane, &remote_tab),
        workspace.remote_of_tab(&remote_pane, &remote_tab)
    );

    // From a machine's pane, a new session starts here, in the home folder.
    restored.focus_pane(&remote_pane);
    restored.create_session("Again local", None).expect("session");
    assert_eq!(restored.machine_of_pane(restored.active_pane_id()), None);
    assert_eq!(restored.active_working_directory(), None);
}

#[test]
fn typing_a_machine_into_a_terminal_moves_that_tab_there_and_restarts_it() {
    let mut workspace = Workspace::new();
    let pane = workspace.spawn_terminal(Some("/tmp")).expect("pane");
    let tab = workspace.pane(&pane).and_then(|p| p.active_tab()).map(|t| t.id.clone()).expect("tab");
    workspace.take_events();

    assert!(workspace.move_tab_to_machine(&pane, &tab, "vps"));
    assert_eq!(workspace.machine_of_pane(&pane), Some("vps"));
    assert_eq!(workspace.active_working_directory(), None);
    assert_eq!(
        workspace.take_events(),
        vec![WorkspaceEvent::Terminal(TerminalLifecycleAction::Restart(TerminalTarget::new(&pane, &tab)))]
    );

    let agent = workspace.spawn_agent("omp", None, false).expect("agent pane");
    let agent_tab = workspace.pane(&agent).and_then(|p| p.active_tab()).map(|t| t.id.clone()).expect("tab");
    assert!(!workspace.move_tab_to_machine(&agent, &agent_tab, "pi"));
}

#[test]
fn closing_the_last_window_keeps_its_session_and_leaves_other_sessions_alone() {
    let mut workspace = Workspace::new();
    let first_session = workspace.active_session_id().to_owned();
    let first_window = workspace.active_window_id().to_owned();
    workspace.create_session("Other", None).expect("session");
    let other_window = workspace.active_window_id().to_owned();

    workspace.close_window(&first_window);
    assert_eq!(workspace.active_window_id(), other_window);
    let replacement =
        workspace.ordered_windows_in(&first_session).first().map(|w| w.id.clone()).expect("replacement");
    assert_ne!(replacement, first_window);
    workspace.activate_session(&first_session);
    assert_eq!(workspace.active_window_id(), replacement);

    workspace.close_window(&replacement);
    assert_eq!(workspace.active_session_id(), first_session);
    assert_eq!(workspace.active_session_windows().len(), 1);
    assert!(workspace.window(&other_window).is_some());
}

#[test]
fn closing_a_session_removes_only_its_windows_and_always_leaves_a_usable_session() {
    let mut workspace = Workspace::new();
    let first_session = workspace.active_session_id().to_owned();
    let first_pane = workspace.active_pane_id().to_owned();
    workspace.create_window(None, None).expect("window");
    let other_session = workspace.create_session("Other", None).expect("session");
    let other_pane = workspace.active_pane_id().to_owned();

    workspace.close_session(&first_session);
    assert_eq!(workspace.active_session_id(), other_session);
    assert!(workspace.pane(&first_pane).is_none());
    assert_eq!(workspace.panes().keys().cloned().collect::<Vec<_>>(), std::slice::from_ref(&other_pane));
    workspace.close_session(&other_session);
    assert_eq!(workspace.terminal_sessions().len(), 1);
    assert_eq!(workspace.active_session_windows().len(), 1);
    assert!(workspace.pane(workspace.active_pane_id()).is_some());
    assert!(workspace.pane(&other_pane).is_none());
}

#[test]
fn snapshots_restore_all_sessions_and_their_independent_window_selection() {
    let mut workspace = Workspace::new();
    let first_session = workspace.active_session_id().to_owned();
    workspace.rename_session(&first_session, "Work");
    let first_window = workspace.active_window_id().to_owned();
    let second_window = workspace.create_window(None, None).expect("window");
    let second_session = workspace.create_session("Personal", None).expect("session");
    let personal_window = workspace.create_window(None, None).expect("window");
    workspace.create_layout_tab(None, None).expect("tab");
    let inner_pane = workspace.active_pane_id().to_owned();
    let inner_tab = active_tab_id(&workspace, &inner_pane);
    let encoded = serde_json::to_string(&workspace.snapshot_workspace()).expect("encodes");
    let mut restored = Workspace::new();
    restored.restore_workspace(serde_json::from_str(&encoded).expect("decodes"));

    assert_eq!(
        restored.ordered_sessions().iter().map(|s| s.name.as_str()).collect::<Vec<_>>(),
        ["Work", "Personal"]
    );
    assert_eq!(restored.active_session_id(), second_session);
    assert_eq!(restored.active_window_id(), personal_window);
    assert_eq!(restored.active_pane_id(), inner_pane);
    assert_eq!(active_tab_id(&restored, &inner_pane), inner_tab);
    assert_eq!(restored.window(&personal_window).map(|w| w.active_tab_index()), Some(1));
    restored.activate_session(&first_session);
    assert_eq!(restored.active_window_id(), second_window);
    restored.activate_last_window();
    assert_eq!(restored.active_window_id(), first_window);
    let new_session = restored.create_session("Third", None).expect("session");
    assert!(new_session != first_session && new_session != second_session);
}

#[test]
fn older_snapshots_migrate_all_windows_into_one_session() {
    let mut workspace = Workspace::new();
    workspace.create_window(None, None).expect("window");
    let mut snapshot = workspace.snapshot_workspace();
    snapshot.terminal_sessions = None;
    for window in snapshot.windows.iter_mut().flatten() {
        window.session_id = None;
    }
    let mut restored = Workspace::new();
    restored.restore_workspace(snapshot.clone());

    assert_eq!(restored.terminal_sessions().len(), 1);
    assert_eq!(restored.active_session_windows().len(), 2);
    assert_eq!(Some(restored.active_window_id().to_owned()), snapshot.active_window_id);
    assert_eq!(restored.panes().len(), snapshot.panes.len());
}

#[test]
fn restoring_keeps_window_names_independent_and_repairs_cross_session_history() {
    let mut workspace = Workspace::new();
    let first_session = workspace.active_session_id().to_owned();
    let first_window = workspace.active_window_id().to_owned();
    workspace.create_session("Other", None).expect("session");
    let other_window = workspace.active_window_id().to_owned();
    let mut snapshot = workspace.snapshot_workspace();
    if let Some(first) = snapshot.terminal_sessions.as_mut().and_then(|s| s.first_mut()) {
        first.active_window_id = other_window.clone();
        first.last_active_window_id = Some(other_window.clone());
    }
    let mut restored = Workspace::new();
    restored.restore_workspace(snapshot);

    assert_eq!(
        restored.window(&first_window).map(|w| &w.title),
        restored.window(&other_window).map(|w| &w.title)
    );
    restored.activate_session(&first_session);
    restored.activate_last_window();
    assert_eq!(restored.active_window_id(), first_window);
    assert_eq!(restored.active_session_id(), first_session);
}

#[test]
fn global_agent_locations_include_their_session() {
    let mut workspace = Workspace::new();
    let first_session_name = workspace.active_session().map(|s| s.name.clone()).expect("session");
    workspace.spawn_agent("codex", None, false).expect("agent");
    workspace.create_session("Other", None).expect("session");
    workspace.spawn_agent("claude-code", None, false).expect("agent");

    let entries = workspace.agent_dashboard_entries();
    let names: HashSet<String> = entries.iter().filter_map(|e| e.session_name.clone()).collect();
    assert_eq!(names, HashSet::from([first_session_name, "Other".to_owned()]));
    assert!(
        entries
            .iter()
            .all(|e| e.location().starts_with(&format!("{} ▸ ", e.session_name.as_deref().unwrap_or(""))))
    );
}

// MARK: - SidebarCollapseAllTests

#[test]
fn collapse_all_collapses_every_window_of_the_session_and_does_nothing_once_they_are() {
    let mut workspace = Workspace::new();
    for _ in 0..2 {
        workspace.create_window(None, None).expect("window");
    }
    let windows: Vec<String> = workspace.active_session_windows().iter().map(|w| w.id.clone()).collect();
    workspace.toggle_sidebar_window_collapsed(&windows[0]);
    workspace.take_changes();

    workspace.collapse_all_sidebar_windows();
    assert!(windows.iter().all(|id| workspace.window(id).is_some_and(|w| w.is_sidebar_collapsed)));
    assert_eq!(workspace.take_changes().len(), 1);

    workspace.collapse_all_sidebar_windows();
    assert!(workspace.take_changes().is_empty());

    workspace.toggle_sidebar_window_collapsed(&windows[2]);
    assert!(workspace.window(&windows[2]).is_some_and(|w| !w.is_sidebar_collapsed));
}

// MARK: - WindowTabBarTests / LayoutTabBarTests (model parts)

#[test]
fn window_tabs_follow_creation_selection_renaming_and_closing() {
    let mut workspace = Workspace::new();
    let first = workspace.active_window_id().to_owned();
    workspace.rename_window(&first, "Editor");
    let second = workspace.create_window(None, None).expect("window");
    workspace.rename_window(&second, "Logs");
    let titles =
        |w: &Workspace| w.active_session_windows().iter().map(|w| w.title.clone()).collect::<Vec<_>>();
    assert_eq!(titles(&workspace), ["Editor", "Logs"]);
    assert_eq!(workspace.active_window_id(), second);

    workspace.activate_window(&first);
    assert_eq!(workspace.active_window_id(), first);
    workspace.rename_window(&first, "Code");
    assert_eq!(titles(&workspace)[0], "Code");
    assert!(workspace.window(&first).is_some_and(|w| w.is_title_custom));

    workspace.create_window(None, None).expect("window");
    assert_eq!(workspace.active_session_windows().len(), 3);
    workspace.close_window(&second);
    assert_eq!(workspace.active_session_windows().len(), 2);
}

#[test]
fn the_window_row_lists_only_the_current_sessions_windows() {
    let mut workspace = Workspace::new();
    let first_session = workspace.active_session_id().to_owned();
    let first = workspace.active_window_id().to_owned();
    workspace.rename_window(&first, "Work");
    workspace.create_session("Personal", None).expect("session");
    let notes = workspace.active_window_id().to_owned();
    workspace.rename_window(&notes, "Notes");
    let titles =
        |w: &Workspace| w.active_session_windows().iter().map(|w| w.title.clone()).collect::<Vec<_>>();
    assert_eq!(titles(&workspace), ["Notes"]);
    workspace.activate_session(&first_session);
    assert_eq!(titles(&workspace), ["Work"]);
}

#[test]
fn automatic_window_titles_stay_unique_within_a_session_and_reset_restores_one() {
    let mut workspace = Workspace::new();
    let first = workspace.active_window_id().to_owned();
    let second = workspace.create_window(None, None).expect("window");
    let first_title = workspace.window(&first).map(|w| w.title.clone()).expect("title");
    let second_title = workspace.window(&second).map(|w| w.title.clone()).expect("title");
    assert_eq!(second_title, format!("{first_title} (2)"));

    workspace.rename_window(&second, "Logs");
    workspace.reset_window_title(&second);
    assert_eq!(workspace.window(&second).map(|w| w.title.clone()), Some(second_title));
    assert!(workspace.window(&second).is_some_and(|w| !w.is_title_custom));

    workspace.create_session("Other", None).expect("session");
    let other = workspace.active_window_id().to_owned();
    assert_eq!(workspace.window(&other).map(|w| w.title.clone()), Some(first_title));
}

// MARK: - Automation runs (AutomationControllerTests, model parts)

fn launch() -> AgentLaunch {
    AgentLaunch { prompt: "Audit the repo.".into(), skips_approvals: true, ..AgentLaunch::default() }
}

#[test]
fn an_automation_run_opens_in_the_automations_session_without_switching_to_it() {
    let mut workspace = Workspace::new();
    let session_before = workspace.active_session_id().to_owned();

    let target = workspace
        .open_automation_window("Audit #1", "omp", "/tmp/repo", Some("run-1".into()), launch(), None)
        .expect("run target");

    let agent = workspace.agent(&target.pane_id, &target.tab_id).expect("agent");
    assert_eq!(agent.launch, Some(launch()));
    assert_eq!(agent.automation_run_id.as_deref(), Some("run-1"));
    let window = workspace.window_containing_pane(&target.pane_id).expect("window");
    assert_eq!(window.title, "Audit #1");
    assert!(window.is_title_custom);
    assert_eq!(
        workspace.terminal_sessions().get(&window.session_id).map(|s| s.name.as_str()),
        Some(Workspace::AUTOMATION_SESSION_NAME)
    );
    assert_eq!(workspace.active_session_id(), session_before);
    assert_eq!(workspace.open_automation_window("Shell", "terminal", "/tmp", None, launch(), None), None);
}

#[test]
fn a_finished_unseen_run_closes_its_window_and_the_background_automations_session() {
    let mut workspace = Workspace::new();
    let target = workspace
        .open_automation_window("Audit #1", "omp", "/tmp/repo", Some("run-1".into()), launch(), None)
        .expect("run");
    workspace.update_agent_status(
        &target.pane_id,
        &target.tab_id,
        AgentStatus::Waiting,
        None,
        Some(AgentWaitingReason::TurnEnded),
    );

    assert_eq!(workspace.close_automation_run(&target), CloseOutcome::Closed);

    assert!(workspace.pane(&target.pane_id).is_none());
    assert!(!workspace.terminal_sessions().values().any(|s| s.name == Workspace::AUTOMATION_SESSION_NAME));
}

#[test]
fn a_run_window_someone_added_to_keeps_the_added_panes() {
    let mut workspace = Workspace::new();
    let target = workspace
        .open_automation_window("Audit #1", "omp", "/tmp/repo", Some("run-1".into()), launch(), None)
        .expect("run");
    let added =
        workspace.add_tab_to_pane(&target.pane_id, crate::PaneType::Terminal, None, None).expect("tab");

    workspace.close_automation_run(&target);

    assert!(workspace.tab(&target.pane_id, &target.tab_id).is_none());
    assert!(workspace.tab(&target.pane_id, &added).is_some());
}

#[test]
fn a_second_run_joins_the_existing_automations_session() {
    let mut workspace = Workspace::new();
    let first =
        workspace.open_automation_window("Audit", "omp", "/tmp/repo", None, launch(), None).expect("run");
    let second =
        workspace.open_automation_window("Audit", "omp", "/tmp/repo", None, launch(), None).expect("run");
    let first_window = workspace.window_containing_pane(&first.pane_id).expect("window");
    let second_window = workspace.window_containing_pane(&second.pane_id).expect("window");

    assert_eq!(first_window.session_id, second_window.session_id);
    assert_eq!(second_window.title, "Audit (2)");
    let session = workspace.terminal_sessions().get(&first_window.session_id).expect("session");
    assert_eq!(session.active_window_id, first_window.id);
}

#[test]
fn workspace_sessions_without_a_window_list_restore_their_single_layout() {
    let session = WorkspaceSession::legacy(
        "legacy",
        "Legacy",
        None,
        vec![crate::SavedPane { id: "pane-8".into(), active_tab_index: 0, tabs: vec![] }],
        "pane-8",
    );
    let mut workspace = Workspace::new();

    assert_eq!(workspace.restore_workspace(session), CloseOutcome::Closed);
    assert_eq!(workspace.active_window_id(), "window-1");
    assert_eq!(workspace.active_pane_id(), "pane-8");
    assert_eq!(workspace.pane("pane-8").map(|p| p.tabs[0].id.as_str()), Some("tab-9"));
    assert_eq!(workspace.spawn_terminal(None).as_deref(), Some("pane-11"));
}

/// A git checkout `name` with a `sub` folder, under a fresh temporary folder.
fn checkout(name: &str) -> (tempfile::TempDir, String, String) {
    let parent = tempfile::tempdir().expect("temp");
    let root = parent.path().join(name);
    std::fs::create_dir_all(root.join(".git")).expect("git");
    std::fs::create_dir_all(root.join("sub")).expect("sub");
    let sub = root.join("sub").to_string_lossy().into_owned();
    (parent, root.to_string_lossy().into_owned(), sub)
}

#[test]
fn a_thread_joins_the_window_working_on_its_project_as_a_tab_behind_the_visible_one() {
    let (_keep, root, sub) = checkout("storefront");
    let mut workspace = Workspace::new();
    let project_window = workspace.create_window(Some(&sub), None).expect("window");
    let other_window = workspace.create_window(Some("/tmp/elsewhere"), None).expect("window");
    let visible_pane = workspace.active_pane_id().to_owned();

    let thread = workspace.open_thread("omp", false, &root, None).expect("thread");

    let window = workspace.window_containing_pane(&thread.pane_id).expect("window");
    assert_eq!(window.id, project_window);
    assert_eq!(window.tabs().len(), 2);
    assert_eq!(window.active_tab_index(), 0);
    assert_eq!(workspace.active_window_id(), other_window);
    assert_eq!(workspace.active_pane_id(), visible_pane);
    let tab = workspace.tab(&thread.pane_id, &thread.tab_id).expect("tab");
    assert_eq!(tab.cwd.as_deref(), Some(root.as_str()));
    assert_eq!(tab.agent.as_ref().map(|agent| agent.profile_id.as_str()), Some("omp"));
}

#[test]
fn a_thread_of_a_project_no_window_works_on_opens_a_window_named_after_it() {
    let (_keep, root, _) = checkout("payments");
    let mut workspace = Workspace::new();
    let session = workspace.active_session_id().to_owned();
    let first_window = workspace.active_window_id().to_owned();

    let thread = workspace.open_thread("claude-code", false, &root, None).expect("thread");

    let window = workspace.window_containing_pane(&thread.pane_id).expect("window").clone();
    assert_ne!(window.id, first_window);
    assert_eq!(window.title, "payments");
    assert_eq!(window.session_id, session);
    assert_eq!(workspace.active_window_id(), first_window);
    // The next thread of the project finds that window.
    let second = workspace.open_thread("omp", false, &root, None).expect("thread");
    assert_eq!(
        workspace.window_containing_pane(&second.pane_id).map(|w| w.id.clone()),
        Some(window.id.clone())
    );
    assert_eq!(workspace.window_count(), 2);
}

#[test]
fn a_threads_first_message_starts_a_terminal_agent_and_is_left_to_a_chats_session() {
    let mut workspace = Workspace::new();

    let terminal =
        workspace.open_thread("codex", false, "/tmp/repo", Some("  Fix the totals \n")).expect("thread");
    let chat = workspace.open_thread("omp", true, "/tmp/repo", Some("Fix the totals")).expect("thread");
    let silent = workspace.open_thread("codex", false, "/tmp/repo", Some("  ")).expect("thread");

    let launch = |target: &TerminalTarget| {
        workspace.agent(&target.pane_id, &target.tab_id).and_then(|agent| agent.launch.clone())
    };
    assert_eq!(launch(&terminal).map(|launch| launch.prompt).as_deref(), Some("Fix the totals"));
    assert_eq!(launch(&terminal).map(|launch| launch.skips_approvals), Some(false));
    assert!(workspace.tab(&chat.pane_id, &chat.tab_id).is_some_and(|tab| tab.is_chat()));
    assert_eq!(launch(&chat), None);
    assert_eq!(launch(&silent), None);
}

#[test]
fn a_first_message_is_refused_for_an_agent_that_cannot_be_handed_one() {
    use crate::workspace::sessions::thread_launch;
    use soprano_types::{AgentProfile, DefaultAgents};

    let custom = AgentProfile { id: "aider".into(), command: "aider".into(), ..DefaultAgents::codex() };
    let scripted =
        AgentProfile { launch_script: Some("./start-claude.sh".into()), ..DefaultAgents::claude_code() };
    for profile in [&custom, &scripted] {
        // Its CLI would start and the message would be gone.
        assert_eq!(thread_launch(profile, false, Some("Fix the totals")), Err(()), "{}", profile.id);
        // Without a message there is nothing to lose.
        assert_eq!(thread_launch(profile, false, None), Ok(None));
        assert_eq!(thread_launch(profile, false, Some(" \n")), Ok(None));
    }
    // A chat takes the message through its session, whatever its profile's command line.
    let scripted_omp = AgentProfile { launch_script: Some("./omp.sh".into()), ..DefaultAgents::omp() };
    assert_eq!(thread_launch(&scripted_omp, true, Some("Fix the totals")), Ok(None));
    assert_eq!(
        thread_launch(&DefaultAgents::open_code(), false, Some("Fix the totals"))
            .map(|l| l.map(|l| l.prompt)),
        Ok(Some("Fix the totals".to_owned()))
    );
}

#[test]
fn threads_stay_out_of_the_automations_session_and_need_an_agent() {
    let mut workspace = Workspace::new();
    let run =
        workspace.open_automation_window("Audit", "omp", "/tmp/repo", None, launch(), None).expect("run");
    let panes = workspace.pane_count();

    assert_eq!(workspace.open_thread("terminal", false, "/tmp/repo", None), None);
    assert_eq!(workspace.open_thread("no-such-agent", false, "/tmp/repo", None), None);
    assert_eq!(workspace.pane_count(), panes);

    let thread = workspace.open_thread("omp", false, "/tmp/repo", None).expect("thread");
    let run_window = workspace.window_containing_pane(&run.pane_id).expect("window");
    let thread_window = workspace.window_containing_pane(&thread.pane_id).expect("window");
    assert_ne!(thread_window.id, run_window.id);
    assert_ne!(thread_window.session_id, run_window.session_id);
}
