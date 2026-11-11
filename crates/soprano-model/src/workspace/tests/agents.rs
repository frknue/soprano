//! `TerminalLifecycleTests` and `AgentConversationTests` (model parts).

use super::*;
use crate::pane::PaneType;
use crate::session::{SavedPane, SavedTab, WorkspaceSession};
use crate::split_node::SplitNode;
use crate::workspace::{TerminalLifecycleAction, WorkspaceEvent};
use soprano_types::SplitDirection;
use soprano_types::{AgentConversation, AgentStatus};

fn lifecycle(workspace: &mut Workspace) -> Vec<TerminalLifecycleAction> {
    workspace.take_events().into_iter().map(|WorkspaceEvent::Terminal(action)| action).collect()
}

fn status(workspace: &Workspace, pane_id: &str, tab_id: &str) -> Option<AgentStatus> {
    workspace.agent(pane_id, tab_id).map(|agent| agent.status)
}

fn conversation(id: &str, cwd: Option<&str>) -> AgentConversation {
    AgentConversation { id: id.into(), cwd: cwd.map(str::to_owned), transcript_path: None }
}

#[test]
fn exact_stop_and_restart_emit_their_target_after_updating_only_that_agent() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let first = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("codex"), None).expect("tab");
    let second = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("claude-code"), None).expect("tab");
    workspace.update_agent_status(&pane, &first, AgentStatus::Running, None, None);
    workspace.update_agent_status(&pane, &second, AgentStatus::Running, None, None);
    workspace.take_events();

    let target = TerminalTarget::new(&pane, &first);
    workspace.stop_agent(&target);

    assert_eq!(lifecycle(&mut workspace), [TerminalLifecycleAction::Stop(target.clone())]);
    assert_eq!(status(&workspace, &pane, &first), Some(AgentStatus::Stopped));
    assert_eq!(status(&workspace, &pane, &second), Some(AgentStatus::Running));

    workspace.restart_agent(&target);

    assert_eq!(lifecycle(&mut workspace), [TerminalLifecycleAction::Restart(target.clone())]);
    assert_eq!(status(&workspace, &pane, &first), Some(AgentStatus::Starting));
    assert_eq!(workspace.agent(&pane, &first).map(|a| a.restart_count), Some(1));
    assert_eq!(status(&workspace, &pane, &second), Some(AgentStatus::Running));
}

#[test]
fn active_tab_conveniences_resolve_and_emit_the_exact_target() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("codex"), None).expect("tab");
    let active = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("claude-code"), None).expect("tab");
    let expected = TerminalTarget::new(&pane, &active);

    workspace.stop_agent_in_pane(&pane);
    workspace.restart_agent_in_pane(&pane);

    assert_eq!(
        lifecycle(&mut workspace),
        [TerminalLifecycleAction::Stop(expected.clone()), TerminalLifecycleAction::Restart(expected)]
    );
}

#[test]
fn stopping_an_already_stopped_agent_emits_nothing() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let tab = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("codex"), None).expect("tab");
    let target = TerminalTarget::new(&pane, &tab);
    workspace.stop_agent(&target);
    workspace.take_events();

    workspace.stop_agent(&target);

    assert!(workspace.take_events().is_empty());
}

#[test]
fn inactive_agent_close_stops_only_the_supplied_tab() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let inactive = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("codex"), None).expect("tab");
    let active = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("claude-code"), None).expect("tab");
    workspace.update_agent_status(&pane, &inactive, AgentStatus::Running, None, None);
    workspace.update_agent_status(&pane, &active, AgentStatus::Running, None, None);

    workspace.handle_terminal_close(&TerminalTarget::new(&pane, &inactive));

    assert_eq!(status(&workspace, &pane, &inactive), Some(AgentStatus::Stopped));
    assert_eq!(status(&workspace, &pane, &active), Some(AgentStatus::Running));
    assert_eq!(active_tab_id(&workspace, &pane), active);

    workspace.handle_terminal_close(&TerminalTarget::new(&pane, &inactive));
    assert_eq!(status(&workspace, &pane, &active), Some(AgentStatus::Running));
}

#[test]
fn inactive_regular_terminal_close_removes_only_the_supplied_tab() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let terminal = active_tab_id(&workspace, &pane);
    let first_agent = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("codex"), None).expect("tab");
    let active_agent =
        workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("claude-code"), None).expect("tab");
    let tab_ids =
        |w: &Workspace| w.pane(&pane).map(|p| p.tabs.iter().map(|t| t.id.clone()).collect::<Vec<_>>());

    let target = TerminalTarget::new(&pane, &terminal);
    workspace.handle_terminal_close(&target);

    assert_eq!(tab_ids(&workspace), Some(vec![first_agent.clone(), active_agent.clone()]));
    assert_eq!(active_tab_id(&workspace, &pane), active_agent);

    workspace.handle_terminal_close(&target);
    assert_eq!(tab_ids(&workspace), Some(vec![first_agent, active_agent]));
}

#[test]
fn finished_manual_agent_detaches_when_its_shell_command_returns() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let tab = active_tab_id(&workspace, &pane);
    workspace.rename_tab(&pane, &tab, "Terminal");
    assert!(workspace.attach_agent_if_needed(&pane, &tab, "codex").is_some());
    workspace.update_agent_status(&pane, &tab, AgentStatus::Running, None, None);

    workspace.agent_process_did_exit(&TerminalTarget::new(&pane, &tab), Some(130));

    assert!(workspace.agent(&pane, &tab).is_none());
    assert_eq!(
        workspace.pane(&pane).and_then(|p| p.active_tab()).map(|t| t.title.as_str()),
        Some("Terminal")
    );

    // A new attach starts a fresh agent rather than reviving the detached one.
    let second = workspace.attach_agent_if_needed(&pane, &tab, "codex").expect("agent");
    assert_eq!(second.status, AgentStatus::Starting);
    assert_eq!(second.exit_code, None);
}

/// A wrapper that reports the agent from the user's shell (`agent-event ready` before `command
/// codex`) gives the app no agent process; quitting the agent before its first turn ends must
/// still detach it when the prompt returns.
#[test]
fn an_agent_reported_without_a_process_detaches_when_its_shell_command_returns() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let tab = active_tab_id(&workspace, &pane);
    workspace.rename_tab(&pane, &tab, "Terminal");
    workspace.attach_agent_if_needed(&pane, &tab, "codex").expect("agent");
    workspace.update_agent_status(&pane, &tab, AgentStatus::Running, None, None);
    assert_eq!(workspace.agent(&pane, &tab).and_then(|a| a.process_id), None);

    workspace.agent_command_did_finish(&TerminalTarget::new(&pane, &tab), Some(130));

    assert!(workspace.agent(&pane, &tab).is_none());
    assert_eq!(
        workspace.pane(&pane).and_then(|p| p.active_tab()).map(|t| t.title.as_str()),
        Some("Terminal")
    );
}

#[test]
fn an_agent_whose_reported_process_still_runs_stays_attached_when_a_shell_command_finishes() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let tab = active_tab_id(&workspace, &pane);
    workspace.attach_agent_if_needed(&pane, &tab, "codex").expect("agent");
    workspace.agent_mut(&pane, &tab).expect("agent").process_id = Some(std::process::id() as i32);
    workspace.update_agent_status(&pane, &tab, AgentStatus::Running, None, None);

    workspace.agent_command_did_finish(&TerminalTarget::new(&pane, &tab), Some(0));

    assert_eq!(status(&workspace, &pane, &tab), Some(AgentStatus::Running));
}

#[test]
fn finished_dedicated_agent_becomes_stopped_without_stopping_its_surface_again() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let tab = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("codex"), None).expect("tab");
    workspace.update_agent_status(&pane, &tab, AgentStatus::Running, None, None);
    workspace.take_events();

    workspace.agent_process_did_exit(&TerminalTarget::new(&pane, &tab), Some(130));

    assert_eq!(status(&workspace, &pane, &tab), Some(AgentStatus::Stopped));
    assert_eq!(workspace.agent(&pane, &tab).and_then(|a| a.exit_code), Some(130));
    assert!(workspace.take_events().is_empty());
}

#[test]
fn a_dedicated_agent_that_returns_to_its_shell_becomes_a_terminal_that_restores_as_one() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let tab = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("omp"), None).expect("tab");
    workspace.record_agent_conversation(conversation("0199-chat", None), &pane, &tab, None);
    workspace.update_agent_status(&pane, &tab, AgentStatus::Running, None, None);
    workspace.take_events();

    workspace.agent_returned_to_shell(&TerminalTarget::new(&pane, &tab), Some(0));

    let returned = workspace.tab(&pane, &tab).expect("tab");
    assert_eq!(returned.pane_type, PaneType::Terminal);
    assert!(returned.agent.is_none());
    assert!(workspace.agent_dashboard_entries().is_empty());
    // The shell keeps running in the same surface.
    assert!(workspace.take_events().is_empty());

    let mut restored = Workspace::new();
    restored.restore_workspace(workspace.snapshot_workspace());
    let restored_tab = restored.tab(&pane, &tab).expect("tab");
    assert_eq!(restored_tab.pane_type, PaneType::Terminal);
    assert!(restored_tab.agent.is_none());
}

#[test]
fn a_dedicated_agent_tab_becomes_a_terminal_when_its_shell_reports_the_command_finished() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let tab = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("omp"), None).expect("tab");

    workspace.agent_command_did_finish(&TerminalTarget::new(&pane, &tab), Some(0));

    assert!(workspace.agent(&pane, &tab).is_none());
    assert_eq!(workspace.tab(&pane, &tab).map(|t| t.pane_type), Some(PaneType::Terminal));
}

/// omp marks its own prompt zones (OSC 133 A/B/C/D;0) while it runs: the terminal reports a
/// finished command with the agent still there.
#[test]
fn a_dedicated_agent_whose_process_still_runs_keeps_its_tab_when_it_marks_a_finished_command() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let tab = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("omp"), None).expect("tab");
    workspace.agent_mut(&pane, &tab).expect("agent").process_id = Some(std::process::id() as i32);
    workspace.update_agent_status(&pane, &tab, AgentStatus::Running, None, None);

    workspace.agent_command_did_finish(&TerminalTarget::new(&pane, &tab), Some(0));

    assert_eq!(status(&workspace, &pane, &tab), Some(AgentStatus::Running));
    assert_eq!(workspace.tab(&pane, &tab).map(|t| t.pane_type), Some(PaneType::Agent));
    assert_eq!(workspace.agent_dashboard_entries().len(), 1);
}

#[test]
fn duplicate_tab_ids_across_panes_keep_distinct_exact_targets() {
    let first = TerminalTarget::new("pane-10", "tab-shared");
    let second = TerminalTarget::new("pane-11", "tab-shared");
    let mut workspace = Workspace::new();
    let tab = |profile: &str| SavedTab {
        profile_id: Some(profile.into()),
        ..SavedTab::new("tab-shared", PaneType::Agent)
    };
    workspace.restore_workspace(WorkspaceSession::legacy(
        "duplicate-tabs",
        "Duplicate tabs",
        Some(SplitNode::split(
            SplitDirection::Horizontal,
            SplitNode::leaf("pane-10"),
            SplitNode::leaf("pane-11"),
            50.0,
        )),
        vec![
            SavedPane { id: first.pane_id.clone(), active_tab_index: 0, tabs: vec![tab("codex")] },
            SavedPane { id: second.pane_id.clone(), active_tab_index: 0, tabs: vec![tab("claude-code")] },
        ],
        "pane-10",
    ));
    workspace.update_agent_status(&first.pane_id, &first.tab_id, AgentStatus::Running, None, None);

    workspace.stop_agent(&second);
    workspace.restart_agent(&second);

    assert_eq!(
        lifecycle(&mut workspace),
        [TerminalLifecycleAction::Stop(second.clone()), TerminalLifecycleAction::Restart(second)]
    );
    assert_eq!(status(&workspace, &first.pane_id, &first.tab_id), Some(AgentStatus::Running));
}

// MARK: - Codex readiness

#[test]
fn a_restart_supersedes_the_previous_readiness_generation() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let tab = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("codex"), None).expect("tab");
    let target = TerminalTarget::new(&pane, &tab);
    let first = workspace.begin_agent_readiness_generation(&target).expect("codex starts");

    workspace.restart_agent(&target);
    let second = workspace.begin_agent_readiness_generation(&target).expect("codex starts again");

    workspace.mark_agent_ready_if_starting(&first);
    assert_eq!(status(&workspace, &pane, &tab), Some(AgentStatus::Starting));
    workspace.mark_agent_ready_if_starting(&second);
    assert_eq!(status(&workspace, &pane, &tab), Some(AgentStatus::Idle));
}

#[test]
fn a_same_target_restore_ignores_the_replaced_surfaces_readiness_generation() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let tab = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("codex"), None).expect("tab");
    let target = TerminalTarget::new(&pane, &tab);
    let session = workspace.snapshot_workspace();
    let first = workspace.begin_agent_readiness_generation(&target).expect("codex starts");

    workspace.restore_workspace(session);
    let second = workspace.begin_agent_readiness_generation(&target).expect("restored codex starts");

    workspace.mark_agent_ready_if_starting(&first);
    assert_eq!(status(&workspace, &pane, &tab), Some(AgentStatus::Starting));
    workspace.mark_agent_ready_if_starting(&second);
    assert_eq!(status(&workspace, &pane, &tab), Some(AgentStatus::Idle));
}

#[test]
fn only_a_starting_codex_gets_a_readiness_generation() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let claude = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("claude-code"), None).expect("tab");
    let codex = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("codex"), None).expect("tab");
    workspace.update_agent_status(&pane, &codex, AgentStatus::Running, None, None);

    assert!(workspace.begin_agent_readiness_generation(&TerminalTarget::new(&pane, &claude)).is_none());
    assert!(workspace.begin_agent_readiness_generation(&TerminalTarget::new(&pane, &codex)).is_none());
}

// MARK: - Status

#[test]
fn a_waiting_agent_without_a_reason_finished_its_turn_and_stopped_agents_stay_stopped() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let tab = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("codex"), None).expect("tab");

    workspace.update_agent_status(&pane, &tab, AgentStatus::Waiting, Some(true), None);
    let agent = workspace.agent(&pane, &tab).expect("agent");
    assert_eq!(agent.waiting_reason, Some(soprano_types::AgentWaitingReason::TurnEnded));
    assert!(agent.needs_attention);
    assert_eq!(workspace.attention_count(), 1);

    workspace.take_changes();
    workspace.update_agent_status(&pane, &tab, AgentStatus::Waiting, Some(true), None);
    assert!(workspace.take_changes().is_empty());

    workspace.update_agent_status(&pane, &tab, AgentStatus::Running, None, None);
    assert_eq!(workspace.agent(&pane, &tab).and_then(|a| a.waiting_reason), None);

    workspace.stop_agent(&TerminalTarget::new(&pane, &tab));
    workspace.update_agent_status(&pane, &tab, AgentStatus::Idle, None, None);
    assert_eq!(status(&workspace, &pane, &tab), Some(AgentStatus::Stopped));
}

// MARK: - Conversations

#[test]
fn quitting_and_reopening_restores_distinct_conversations_and_the_selected_session_and_tab() {
    let store = soprano_platform::StateStore::in_memory();
    let mut source = Workspace::new();
    let first_pane = source.active_pane_id().to_owned();
    let first_tab = source.add_tab_to_pane(&first_pane, PaneType::Agent, Some("codex"), None).expect("tab");
    let second_tab = source.add_tab_to_pane(&first_pane, PaneType::Agent, Some("codex"), None).expect("tab");
    source.record_agent_conversation(
        conversation("codex-one", Some("/tmp/repo")),
        &first_pane,
        &first_tab,
        None,
    );
    source.record_agent_conversation(
        conversation("codex-two", Some("/tmp/repo")),
        &first_pane,
        &second_tab,
        None,
    );
    let session_id = source.create_session("Other project", None).expect("session");
    source.create_layout_tab(None, None).expect("tab");
    let inner_pane = source.active_pane_id().to_owned();
    let inner_tab =
        source.add_tab_to_pane(&inner_pane, PaneType::Agent, Some("claude-code"), None).expect("tab");
    source.record_agent_conversation(conversation("claude-three", None), &inner_pane, &inner_tab, None);
    let active_window = source.active_window_id().to_owned();

    WorkspaceSession::save_last(&source.snapshot_workspace(), &store);
    let mut restored = Workspace::new();
    restored.restore_workspace(WorkspaceSession::load_last(&store).expect("saved"));

    assert_eq!(restored.active_session_id(), session_id);
    assert_eq!(restored.active_window_id(), active_window);
    assert_eq!(restored.active_pane_id(), inner_pane);
    assert_eq!(restored.active_window().map(|w| w.active_tab_index()), Some(1));
    assert_eq!(active_tab_id(&restored, &inner_pane), inner_tab);
    let conversation_id = |pane: &str, tab: &str| {
        restored.agent(pane, tab).and_then(|a| a.conversation.as_ref()).map(|c| c.id.clone())
    };
    assert_eq!(conversation_id(&first_pane, &first_tab).as_deref(), Some("codex-one"));
    assert_eq!(conversation_id(&first_pane, &second_tab).as_deref(), Some("codex-two"));
    assert_eq!(conversation_id(&inner_pane, &inner_tab).as_deref(), Some("claude-three"));
}

#[test]
fn a_recognized_agent_in_a_shell_resumes_but_an_exited_agent_leaves_a_shell() {
    let mut source = Workspace::new();
    let pane = source.active_pane_id().to_owned();
    let tab = active_tab_id(&source, &pane);
    source.attach_agent_if_needed(&pane, &tab, "codex");
    source.record_agent_conversation(conversation("manual-chat", Some("/tmp/project")), &pane, &tab, None);
    let mut restored = Workspace::new();
    restored.restore_workspace(source.snapshot_workspace());
    assert_eq!(restored.pane(&pane).and_then(|p| p.active_tab()).map(|t| t.pane_type), Some(PaneType::Agent));
    assert_eq!(
        restored.agent(&pane, &tab).and_then(|a| a.conversation.as_ref()).map(|c| c.id.as_str()),
        Some("manual-chat")
    );

    source.agent_process_did_exit(&TerminalTarget::new(&pane, &tab), None);
    restored.restore_workspace(source.snapshot_workspace());
    let restored_tab = restored.pane(&pane).and_then(|p| p.active_tab()).expect("tab");
    assert_eq!(restored_tab.pane_type, PaneType::Terminal);
    assert!(restored_tab.agent.is_none());
}

#[test]
fn older_workspaces_still_open_fresh_agents_without_guessing_the_last_conversation() {
    let tab: SavedTab =
        serde_json::from_str(r#"{"id":"tab-2","type":"agent","profileId":"codex","cwd":"/tmp/repo"}"#)
            .expect("decodes");
    assert!(tab.conversation.is_none());
}

#[test]
fn a_stopped_or_different_agent_cannot_replace_the_saved_conversation() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let tab = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("codex"), None).expect("tab");
    workspace.record_agent_conversation(conversation("right", Some("/tmp/repo")), &pane, &tab, None);
    workspace.record_agent_conversation(conversation("wrong", None), &pane, &tab, Some("claude-code"));
    workspace.record_agent_conversation(conversation("right", None), &pane, &tab, None);
    assert_eq!(
        workspace.agent(&pane, &tab).and_then(|a| a.conversation.clone()),
        Some(conversation("right", Some("/tmp/repo")))
    );
    workspace.stop_agent_in_pane(&pane);
    workspace.record_agent_conversation(conversation("late", None), &pane, &tab, None);
    assert_eq!(
        workspace.agent(&pane, &tab).and_then(|a| a.conversation.as_ref()).map(|c| c.id.as_str()),
        Some("right")
    );
}

#[test]
fn a_new_conversation_report_keeps_the_earlier_transcript_path_of_the_same_conversation() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let tab = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("codex"), None).expect("tab");
    let mut first = conversation("thread", Some("/tmp/repo"));
    first.transcript_path = Some("/tmp/rollout.jsonl".into());
    workspace.record_agent_conversation(first.clone(), &pane, &tab, None);

    workspace.record_agent_conversation(conversation("thread", None), &pane, &tab, None);
    assert_eq!(workspace.agent(&pane, &tab).and_then(|a| a.conversation.clone()), Some(first));

    workspace.record_agent_conversation(conversation("other", None), &pane, &tab, None);
    assert_eq!(
        workspace.agent(&pane, &tab).and_then(|a| a.conversation.clone()),
        Some(conversation("other", None))
    );
}

#[test]
fn malformed_conversation_ids_are_ignored_and_unsupported_agents_record_none() {
    let mut workspace = Workspace::new();
    let pane = workspace.active_pane_id().to_owned();
    let tab = workspace.add_tab_to_pane(&pane, PaneType::Agent, Some("codex"), None).expect("tab");
    workspace.record_agent_conversation(conversation("--last", None), &pane, &tab, None);
    workspace.record_agent_conversation(conversation("a b", None), &pane, &tab, None);
    assert!(workspace.agent(&pane, &tab).and_then(|a| a.conversation.as_ref()).is_none());
}
