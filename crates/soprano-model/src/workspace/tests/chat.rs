//! `AgentChatTabTests` (model parts).

use super::*;
use crate::pane::{PaneContentKind, PaneType};
use crate::session::WorkspaceSession;
use soprano_types::SplitDirection;
use soprano_types::{AgentConversation, AgentStatus};

fn active_tab(workspace: &Workspace) -> crate::PaneTab {
    workspace.pane(workspace.active_pane_id()).and_then(|p| p.active_tab()).cloned().expect("active tab")
}

#[test]
fn a_chat_opens_in_a_pane_a_tab_of_a_pane_a_layout_tab_and_a_window() {
    let mut workspace = Workspace::new();
    let root = workspace.active_pane_id().to_owned();

    let pane = workspace.spawn_agent("omp", Some("/work/repo"), true).expect("pane");
    let tab = workspace.pane(&pane).and_then(|p| p.active_tab()).expect("tab");
    assert!(tab.is_chat());
    assert_eq!(tab.title, "omp: repo");

    let tab_id = workspace
        .add_tab_to_pane(&root, PaneType::Agent, Some("omp"), Some(PaneContentKind::CHAT))
        .expect("tab");
    assert!(workspace.tab(&root, &tab_id).is_some_and(|t| t.is_chat()));

    workspace.create_layout_tab(None, Some("omp")).expect("tab");
    assert!(active_tab(&workspace).is_chat());

    workspace.create_window(None, Some("omp")).expect("window");
    assert!(active_tab(&workspace).is_chat());

    let active = workspace.active_pane_id().to_owned();
    let split = workspace.split_pane(SplitDirection::Horizontal, &active).expect("split");
    let split_tab = workspace.pane(&split).and_then(|p| p.active_tab()).expect("tab");
    assert!(split_tab.is_chat());
    assert_eq!(split_tab.agent.as_ref().map(|a| a.profile_id.as_str()), Some("omp"));
}

#[test]
fn an_agent_without_a_chat_opens_its_terminal_instead() {
    let mut workspace = Workspace::new();
    let pane = workspace.spawn_agent("codex", None, true).expect("pane");
    let tab = workspace.pane(&pane).and_then(|p| p.active_tab()).expect("tab");
    assert_eq!(tab.pane_type, PaneType::Agent);
    assert!(!tab.is_chat());
}

#[test]
fn a_restored_chat_reopens_as_a_chat_on_its_conversation() {
    let mut source = Workspace::new();
    let pane = source.spawn_agent("omp", Some("/work/repo"), true).expect("pane");
    let tab = active_tab_id(&source, &pane);
    let conversation = AgentConversation {
        id: "01a1b56e-610b-72eb".into(),
        cwd: Some("/work/repo".into()),
        transcript_path: None,
    };
    source.record_agent_conversation(conversation, &pane, &tab, None);

    let json = serde_json::to_string(&source.snapshot_workspace()).expect("encodes");
    let mut restored = Workspace::new();
    restored.restore_workspace(serde_json::from_str::<WorkspaceSession>(&json).expect("decodes"));
    let restored_tab = restored.tab(&pane, &tab).expect("tab");
    assert!(restored_tab.is_chat());
    assert_eq!(
        restored_tab.agent.as_ref().and_then(|a| a.conversation.as_ref()).map(|c| c.id.as_str()),
        Some("01a1b56e-610b-72eb")
    );
}

#[test]
fn stopping_a_chat_leaves_it_a_chat_stopped_rather_than_a_terminal() {
    let mut workspace = Workspace::new();
    let root = workspace.active_pane_id().to_owned();
    let tab = workspace
        .add_tab_to_pane(&root, PaneType::Agent, Some("omp"), Some(PaneContentKind::CHAT))
        .expect("tab");
    workspace.update_agent_status(&root, &tab, AgentStatus::Running, None, None);

    workspace.stop_agent(&TerminalTarget::new(&root, &tab));

    assert!(workspace.tab(&root, &tab).is_some_and(|t| t.is_chat()));
    assert_eq!(workspace.agent(&root, &tab).map(|a| a.status), Some(AgentStatus::Stopped));
}
