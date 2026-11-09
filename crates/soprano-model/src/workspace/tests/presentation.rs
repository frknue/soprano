//! Model parts of `ActiveLocationIndicatorTests`, `RunningCommandIndicatorTests`,
//! `AgentDashboardTests`, `WindowTabBarTests`, `LayoutTabBarTests` and
//! `PerformanceOptimizationTests`.

use super::*;
use crate::pane::PaneType;
use crate::split_node::SplitDirection;
use crate::workspace::{AgentDashboardEntry, WorkspaceChange};
use soprano_types::{AgentStatus, AgentWaitingReason};

// MARK: - Status bar location

#[test]
fn the_location_names_the_active_session_window_and_pane() {
    let mut workspace = Workspace::new();
    let window = workspace.active_window_id().to_owned();
    workspace.rename_window(&window, "Soprano");
    let pane = workspace.active_pane_id().to_owned();
    let tab = active_tab_id(&workspace, &pane);
    workspace.rename_tab(&pane, &tab, "Claude");

    assert_eq!(
        workspace.active_location().map(|l| l.text()).as_deref(),
        Some("Session 1  /  Soprano  /  Claude")
    );
}

#[test]
fn the_location_names_the_active_tab_only_for_windows_with_several_tabs() {
    let mut workspace = Workspace::new();
    let window = workspace.active_window_id().to_owned();
    workspace.rename_window(&window, "Soprano");
    let text = |w: &Workspace| w.active_location().map(|l| l.text()).unwrap_or_default();
    assert!(!text(&workspace).contains("· Tab"));

    workspace.create_layout_tab(None, None).expect("tab");
    assert!(text(&workspace).ends_with("· Tab 2"));

    workspace.activate_previous_layout_tab();
    assert!(text(&workspace).ends_with("· Tab 1"));

    let last = workspace.active_window().and_then(|w| w.tabs().last()).map(|t| t.id.clone()).expect("tab");
    workspace.close_layout_tab(&last);
    assert!(!text(&workspace).contains("· Tab"));
}

// MARK: - Running commands

#[test]
fn a_running_command_lights_its_tab_until_an_agent_or_its_end_takes_over() {
    let mut workspace = Workspace::new();
    let server_pane = workspace.active_pane_id().to_owned();
    let server_tab = active_tab_id(&workspace, &server_pane);
    let server = TerminalTarget::new(&server_pane, &server_tab);
    let server_layout_tab = workspace.active_window().map(|w| w.active_tab().id.clone()).expect("tab");
    workspace.create_layout_tab(None, None).expect("tab");
    let other_pane = workspace.active_pane_id().to_owned();
    let other_tab = active_tab_id(&workspace, &other_pane);
    let running = |w: &Workspace, pane: &str| {
        w.pane(pane).and_then(|p| p.active_tab()).is_some_and(|tab| w.is_running_command(tab, pane))
    };

    workspace.set_running_command_targets(HashSet::from([server.clone()]));
    assert_eq!(workspace.running_command_targets(), &HashSet::from([server.clone()]));
    assert!(running(&workspace, &server_pane));
    assert!(!running(&workspace, &other_pane));
    let activity = workspace.layout_tab_activity(&server_layout_tab);
    assert_eq!(activity.running_commands, 1);
    assert!(activity.describe("Tab 1: server").ends_with("1 command running"));

    workspace.attach_agent_if_needed(&server_pane, &server_tab, "codex");
    assert!(!running(&workspace, &server_pane));
    assert_eq!(workspace.layout_tab_activity(&server_layout_tab).running_commands, 0);

    workspace.agent_process_did_exit(&server, None);
    assert!(running(&workspace, &server_pane));

    workspace.set_running_command_targets(HashSet::new());
    assert!(!running(&workspace, &server_pane));

    workspace.set_running_command_targets(HashSet::from([TerminalTarget::new(&other_pane, &other_tab)]));
    workspace.take_changes();
    workspace.set_running_command_targets(HashSet::from([TerminalTarget::new(&other_pane, &other_tab)]));
    assert!(workspace.take_changes().is_empty());
}

#[test]
fn restoring_forgets_running_commands() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let tab = active_tab_id(&workspace, &pane);
    workspace.set_running_command_targets(HashSet::from([TerminalTarget::new(&pane, &tab)]));

    workspace.restore_workspace(workspace.snapshot_workspace());

    assert!(workspace.running_command_targets().is_empty());
}

// MARK: - Window and layout tab badges

#[test]
fn window_activity_follows_agent_lifecycle_without_changing_the_window_title() {
    let mut workspace = Workspace::new();
    let window = workspace.active_window_id().to_owned();
    workspace.rename_window(&window, "Editor");
    assert!(workspace.window_activity(&window).agents.is_empty());
    let pane = workspace.active_pane_id().to_owned();
    let tab = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("codex"), None).expect("tab");

    for status in [
        AgentStatus::Starting,
        AgentStatus::Running,
        AgentStatus::Idle,
        AgentStatus::Waiting,
        AgentStatus::Error,
        AgentStatus::Running,
        AgentStatus::Stopped,
    ] {
        workspace.update_agent_status(&pane, &tab, status, None, None);
        let activity = workspace.window_activity(&window);
        let open = status != AgentStatus::Stopped;
        assert_eq!(!activity.agents.is_empty(), open);
        let expected = if open {
            format!("Window 1: Editor — 1 agent: 1 {}", status.display_label().to_lowercase())
        } else {
            "Window 1: Editor".to_owned()
        };
        assert_eq!(activity.describe("Window 1: Editor"), expected);
        assert_eq!(workspace.window(&window).map(|w| w.title.as_str()), Some("Editor"));
    }

    workspace.restart_agent(&TerminalTarget::new(&pane, &tab));
    assert!(!workspace.window_activity(&window).agents.is_empty());
    workspace.remove_tab_from_pane(&pane, &tab);
    assert!(workspace.window_activity(&window).agents.is_empty());
}

#[test]
fn background_windows_count_agents_in_inactive_pane_tabs_and_background_tabs() {
    let mut workspace = Workspace::new();
    let window = workspace.active_window_id().to_owned();
    let pane = workspace.active_pane_id().to_owned();
    let agent_tab = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("codex"), None).expect("tab");
    workspace.update_agent_status(&pane, &agent_tab, AgentStatus::Running, None, None);
    workspace.switch_tab(&pane, 0);
    workspace.create_layout_tab(None, None).expect("tab");
    let inner_pane = workspace.active_pane_id().to_owned();
    let inner_tab =
        workspace.add_tab_to_pane(&inner_pane, PaneType::Agent, Some("claude-code"), None).expect("tab");
    workspace.activate_previous_layout_tab();
    let second = workspace.create_window(None, None).expect("window");
    let describe = |w: &Workspace| w.window_activity(&window).describe("Window 1: Work");

    assert_eq!(describe(&workspace), "Window 1: Work — 2 agents: 1 working, 1 starting");
    assert!(workspace.window_activity(&second).agents.is_empty());

    workspace.update_agent_status(&pane, &agent_tab, AgentStatus::Idle, None, None);
    assert_eq!(describe(&workspace), "Window 1: Work — 2 agents: 1 starting, 1 ready");
    workspace.remove_tab_from_pane(&inner_pane, &inner_tab);
    assert_eq!(describe(&workspace), "Window 1: Work — 1 agent: 1 ready");
    workspace.stop_agent(&TerminalTarget::new(&pane, &agent_tab));
    assert_eq!(describe(&workspace), "Window 1: Work");
}

#[test]
fn the_badge_shows_the_most_urgent_status() {
    let mut workspace = Workspace::new();
    let window = workspace.active_window_id().to_owned();
    for _ in 0..12 {
        workspace.spawn_agent("codex", None, false).expect("pane");
        let active = workspace.active_pane_id().to_owned();
        workspace.update_agent_status_in_pane(&active, AgentStatus::Running);
    }
    let pane = workspace.active_pane_id().to_owned();
    assert_eq!(workspace.window_activity(&window).most_urgent_agent(), Some((AgentStatus::Running, None)));

    workspace.update_agent_status_in_pane(&pane, AgentStatus::Waiting);
    let activity = workspace.window_activity(&window);
    assert_eq!(
        activity.most_urgent_agent(),
        Some((AgentStatus::Waiting, Some(AgentWaitingReason::TurnEnded)))
    );
    assert!(activity.describe("").contains("1 needs input, 11 working"));
    workspace.update_agent_status_in_pane(&pane, AgentStatus::Error);
    assert_eq!(workspace.window_activity(&window).most_urgent_agent(), Some((AgentStatus::Error, None)));
}

#[test]
fn layout_tabs_are_named_after_their_focused_panes_and_count_their_agents() {
    let mut workspace = Workspace::new();
    let background_pane = workspace.active_pane_id().to_owned();
    let background_tab = active_tab_id(&workspace, &background_pane);
    workspace.rename_tab(&background_pane, &background_tab, "editor");
    workspace.create_layout_tab(None, None).expect("tab");
    let server_pane = workspace.active_pane_id().to_owned();
    let server_tab = active_tab_id(&workspace, &server_pane);
    workspace.rename_tab(&server_pane, &server_tab, "server");
    let window = workspace.active_window().expect("window");
    let titles: Vec<String> = window.tabs().iter().map(|t| workspace.layout_tab_title(t)).collect();
    assert_eq!(titles, ["editor", "server"]);
    let background_layout_tab = window.tabs()[0].id.clone();

    let agent_tab =
        workspace.add_tab_to_pane(&background_pane, PaneType::Agent, Some("codex"), None).expect("tab");
    // Adding a pane tab brings its layout tab forward; send it back.
    workspace.activate_next_layout_tab();
    workspace.update_agent_status(&background_pane, &agent_tab, AgentStatus::Waiting, None, None);
    assert!(
        workspace
            .layout_tab_activity(&background_layout_tab)
            .describe("Tab 1")
            .ends_with("1 agent: 1 needs input")
    );

    workspace.stop_agent(&TerminalTarget::new(&background_pane, &agent_tab));
    assert!(workspace.layout_tab_activity(&background_layout_tab).agents.is_empty());
}

#[test]
fn agents_attached_to_shells_count_until_they_exit() {
    let mut workspace = Workspace::new();
    let window = workspace.active_window_id().to_owned();
    let pane = workspace.active_pane_id().to_owned();
    let tab = active_tab_id(&workspace, &pane);
    workspace.attach_agent_if_needed(&pane, &tab, "codex").expect("agent");
    workspace.update_agent_status(&pane, &tab, AgentStatus::Idle, None, None);
    assert_eq!(workspace.window_activity(&window).agents.len(), 1);
    assert_eq!(workspace.ready_agent_count(), 1);

    workspace.agent_process_did_exit(&TerminalTarget::new(&pane, &tab), None);
    assert!(workspace.window_activity(&window).agents.is_empty());
}

// MARK: - Agent Dashboard

#[test]
fn dashboard_entries_include_agent_tabs_across_logical_windows() {
    let mut workspace = Workspace::new();
    let codex_pane = workspace.spawn_agent("codex", Some("/tmp/one"), false).expect("pane");
    let codex_tab = active_tab_id(&workspace, &codex_pane);
    workspace.update_agent_status(&codex_pane, &codex_tab, AgentStatus::Running, None, None);
    let second_window = workspace.create_window(Some("/tmp/two"), None).expect("window");
    let claude_pane = workspace.spawn_agent("claude-code", None, false).expect("pane");
    let claude_tab = active_tab_id(&workspace, &claude_pane);
    workspace.update_agent_status(&claude_pane, &claude_tab, AgentStatus::Waiting, Some(true), None);

    let entries = workspace.agent_dashboard_entries();

    // Visual order; the dashboard snapshot sorts these by urgency.
    assert_eq!(entries.iter().map(|e| e.profile_id.as_str()).collect::<Vec<_>>(), ["codex", "claude-code"]);
    assert_eq!(
        Some(entries[1].window_title.as_str()),
        workspace.window(&second_window).map(|w| w.title.as_str())
    );
    assert_eq!(entries[1].cwd.as_deref(), Some("/tmp/two"));
    assert_eq!(entries[0].cwd.as_deref(), Some("/tmp/one"));
    assert_eq!(entries.iter().map(|e| e.title()).collect::<Vec<_>>(), ["Codex", "Claude Code"]);
    assert!(entries[1].needs_attention);
    assert_eq!(entries[1].status, AgentStatus::Waiting);

    workspace.rename_window(&second_window, "Storefront");
    workspace.update_working_directory(&claude_pane, &claude_tab, "/tmp/two/src");
    let renamed =
        workspace.agent_dashboard_entry(&TerminalTarget::new(&claude_pane, &claude_tab)).expect("entry");
    assert_eq!(renamed.window_title, "Storefront");
    assert_eq!(renamed.cwd.as_deref(), Some("/tmp/two/src"));
    assert!(workspace.agent_dashboard_entry(&TerminalTarget::new("pane-1", "tab-2")).is_none());
}

#[test]
fn an_agent_is_named_by_its_task_over_its_name() {
    let entry = |tab_title: &str| AgentDashboardEntry {
        pane_id: "pane-omp".into(),
        tab_id: "omp".into(),
        tab_title: tab_title.into(),
        window_title: "Window".into(),
        profile_id: "codex".into(),
        profile_name: "Codex".into(),
        status: AgentStatus::Running,
        needs_attention: false,
        started_at: None,
        cwd: Some("/tmp/ab_tool".into()),
        session_name: None,
        conversation: None,
        is_chat: false,
        branch: None,
    };
    let working = entry("π ⠋ \u{F04E1} MIGR: Plan the migration");
    assert_eq!(working.title(), "MIGR: Plan the migration");
    assert_eq!(working.location(), "Window ▸ MIGR: Plan the migration");
    assert_eq!(working.id(), "pane-omp:omp");
    assert_eq!(entry("Codex: ab_tool").title(), "Codex");
}

#[test]
fn focusing_a_dashboard_target_shows_its_background_tab_and_exact_pane_tab() {
    let mut workspace = Workspace::new();
    let root = workspace.active_pane_id().to_owned();
    workspace.create_layout_tab(None, None).expect("tab");
    let agent_pane = workspace.active_pane_id().to_owned();
    let agent_tab =
        workspace.add_tab_to_pane(&agent_pane, PaneType::Agent, Some("codex"), None).expect("tab");
    workspace.switch_tab(&agent_pane, 0);
    workspace.activate_previous_layout_tab();
    assert_eq!(workspace.layout().map(|l| l.leaf_ids()), Some(HashSet::from([root])));

    workspace.focus_tab(&agent_pane, &agent_tab, false);

    assert_eq!(workspace.active_pane_id(), agent_pane);
    assert_eq!(workspace.active_window().map(|w| w.active_tab_index()), Some(1));
    assert_eq!(workspace.layout().map(|l| l.leaf_ids()), Some(HashSet::from([agent_pane.clone()])));
    assert_eq!(active_tab_id(&workspace, &agent_pane), agent_tab);
}

#[test]
fn opening_the_already_focused_agent_from_the_dashboard_still_unfolds_its_group() {
    let mut workspace = Workspace::new();
    let window = workspace.active_window_id().to_owned();
    let pane = workspace.active_pane_id().to_owned();
    let tab = active_tab_id(&workspace, &pane);
    workspace.collapse_all_sidebar_windows();
    workspace.take_changes();

    workspace.focus_tab(&pane, &tab, true);

    assert!(workspace.window(&window).is_some_and(|w| !w.is_sidebar_collapsed));
    assert_eq!(workspace.take_changes().len(), 1);
}

#[test]
fn focusing_a_tab_from_its_pane_leaves_a_collapsed_window_group_folded() {
    let mut workspace = Workspace::new();
    let window = workspace.active_window_id().to_owned();
    let pane = workspace.active_pane_id().to_owned();
    let tab = active_tab_id(&workspace, &pane);
    workspace.create_window(None, None).expect("window");
    workspace.collapse_all_sidebar_windows();

    workspace.focus_tab(&pane, &tab, false);

    assert_eq!(workspace.active_window_id(), window);
    assert!(workspace.window(&window).is_some_and(|w| w.is_sidebar_collapsed));
}

#[test]
fn focusing_a_pane_marks_its_agent_seen() {
    let mut workspace = Workspace::new();
    let first = workspace.active_pane_id().to_owned();
    let agent_pane = workspace.spawn_agent("codex", None, false).expect("pane");
    let agent_tab = active_tab_id(&workspace, &agent_pane);
    workspace.update_agent_status(&agent_pane, &agent_tab, AgentStatus::Waiting, Some(true), None);
    workspace.focus_pane(&first);
    assert_eq!(workspace.attention_count(), 1);

    workspace.focus_pane(&agent_pane);

    assert_eq!(workspace.attention_count(), 0);
}

// MARK: - Change log (PerformanceOptimizationTests)

#[test]
fn tab_metadata_changes_tell_observers_exactly_which_target_changed() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let terminal = active_tab_id(&workspace, &pane);
    workspace.take_changes();

    workspace.rename_tab(&pane, &terminal, "Live title");
    workspace.update_working_directory(&pane, &terminal, "/tmp/live-project");

    let target = TerminalTarget::new(&pane, &terminal);
    assert_eq!(
        workspace.take_changes(),
        [WorkspaceChange::TabTitle(target.clone()), WorkspaceChange::TabWorkingDirectory(target)]
    );

    let browser = workspace.add_tab_to_pane(&pane, PaneType::Browser, None, None).expect("tab");
    workspace.take_changes();
    workspace.update_browser_url(&pane, &browser, "https://example.com/updated");

    assert_eq!(workspace.take_changes(), [WorkspaceChange::BrowserUrl(TerminalTarget::new(&pane, &browser))]);
}

#[test]
fn topology_changes_are_flagged_and_bump_the_layout_generation() {
    let mut workspace = Workspace::new();
    workspace.take_changes();
    let generation = workspace.layout_generation();

    workspace.split_pane(SplitDirection::Horizontal, "pane-1").expect("split");

    assert!(workspace.take_changes().iter().any(WorkspaceChange::layout_changed));
    assert!(workspace.layout_generation() > generation);
}
