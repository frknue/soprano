//! `SessionPersistenceTests`, `WorkspaceRestoreTests`, `SidebarCollapsePersistenceTests` (model
//! parts), and the persisted JSON shape.

use soprano_platform::StateStore;

use super::*;
use crate::pane::PaneType;
use crate::session::{ReferenceDate, SavedPane, SavedTab, SavedWindow, WorkspaceSession};
use crate::session_manager::SessionManager;
use crate::split_node::SplitNode;

#[test]
fn named_session_round_trip_preserves_custom_tab_titles() {
    let store = StateStore::in_memory();
    let mut source = Workspace::new();
    let pane = source.active_pane_id().to_owned();
    let terminal = active_tab_id(&source, &pane);
    source.rename_tab(&pane, &terminal, "Build logs");
    let agent = source.add_tab_to_pane(&pane, PaneType::Agent, Some("codex"), None).expect("tab");
    source.rename_tab(&pane, &agent, "Review agent");

    let mut writer = SessionManager::new(store.clone());
    writer.save_session("  Release workspace  ", &source);
    assert!(writer.take_changed());

    let mut restored = Workspace::new();
    let reader = SessionManager::new(store);
    let saved = reader.sessions().first().cloned().expect("saved");
    assert_eq!(saved.name, "Release workspace");
    assert!(saved.id.starts_with("session-"));

    assert_eq!(reader.load_session(&saved.id, &mut restored), CloseOutcome::Closed);

    let restored_pane = restored.pane(&pane).expect("pane");
    assert_eq!(
        restored_pane.tabs.iter().map(|t| t.title.as_str()).collect::<Vec<_>>(),
        ["Build logs", "Review agent"]
    );
    assert_eq!(restored_pane.tabs[1].agent.as_ref().map(|a| a.profile_id.as_str()), Some("codex"));
}

#[test]
fn blank_names_are_not_saved_and_deleting_removes_a_session() {
    let store = StateStore::in_memory();
    let workspace = Workspace::new();
    let mut sessions = SessionManager::new(store.clone());
    sessions.save_session(" \n ", &workspace);
    assert!(sessions.sessions().is_empty());
    assert!(!sessions.take_changed());

    sessions.save_session("One", &workspace);
    let id = sessions.sessions()[0].id.clone();
    sessions.delete_session(&id);
    assert!(sessions.sessions().is_empty());
    assert!(SessionManager::new(store).sessions().is_empty());
}

#[test]
fn named_workspace_saving_includes_live_sessions() {
    let store = StateStore::in_memory();
    let mut workspace = Workspace::new();
    workspace.create_session("Project", None).expect("session");
    SessionManager::new(store.clone()).save_session("Everything", &workspace);
    let mut restored = Workspace::new();
    let saved = SessionManager::new(store);
    let id = saved.sessions().first().map(|s| s.id.clone()).expect("saved");
    saved.load_session(&id, &mut restored);

    assert_eq!(
        restored.ordered_sessions().iter().map(|s| s.name.as_str()).collect::<Vec<_>>(),
        ["Session 1", "Project"]
    );
    assert_eq!(restored.active_session().map(|s| s.name.as_str()), Some("Project"));
}

#[test]
fn last_session_persistence_round_trips_a_workspace_snapshot() {
    let store = StateStore::in_memory();
    let mut source = Workspace::new();
    let pane = source.active_pane_id().to_owned();
    let tab = active_tab_id(&source, &pane);
    source.rename_tab(&pane, &tab, "Persistent title");

    WorkspaceSession::save_last(&source.snapshot_workspace(), &store);
    let persisted = WorkspaceSession::load_last(&store).expect("saved");
    let mut restored = Workspace::new();
    restored.restore_workspace(persisted);

    assert_eq!(
        restored.pane(&pane).and_then(|p| p.active_tab()).map(|t| t.title.as_str()),
        Some("Persistent title")
    );
    WorkspaceSession::clear_last(&store);
    assert!(WorkspaceSession::load_last(&store).is_none());
}

#[test]
fn legacy_saved_tabs_without_titles_still_restore_with_generated_titles() {
    let legacy: SavedTab =
        serde_json::from_str(r#"{"id":"tab-9","type":"terminal","cwd":"/tmp/legacy-project"}"#)
            .expect("decodes");
    assert!(legacy.title.is_none());

    let session = WorkspaceSession::legacy(
        "legacy",
        "Legacy",
        Some(SplitNode::leaf("pane-8")),
        vec![SavedPane { id: "pane-8".into(), active_tab_index: 0, tabs: vec![legacy] }],
        "pane-8",
    );
    let mut restored = Workspace::new();
    restored.restore_workspace(session);

    assert_eq!(
        restored.pane("pane-8").and_then(|p| p.active_tab()).map(|t| t.title.as_str()),
        Some("legacy-project")
    );
}

#[test]
fn restore_generation_advances_only_after_successful_workspace_restore() {
    let mut workspace = Workspace::new();
    let initial = workspace.workspace_restore_generation();

    workspace.set_layout(Some(SplitNode::leaf("pane-1")));
    assert_eq!(workspace.workspace_restore_generation(), initial);

    let empty = WorkspaceSession::legacy("empty", "Empty", None, vec![], "");
    assert_eq!(workspace.restore_workspace(empty), CloseOutcome::Unchanged);
    assert_eq!(workspace.workspace_restore_generation(), initial);

    let restorable = workspace.snapshot_workspace();
    workspace.restore_workspace(restorable.clone());
    assert_eq!(workspace.workspace_restore_generation(), initial + 1);

    workspace.restore_workspace(restorable);
    assert_eq!(workspace.workspace_restore_generation(), initial + 2);
}

#[test]
fn collapsed_windows_remain_collapsed_after_the_saved_workspace_is_restored() {
    let store = StateStore::in_memory();
    let mut source = Workspace::new();
    let window = source.active_window_id().to_owned();
    source.toggle_sidebar_window_collapsed(&window);
    assert!(source.window(&window).is_some_and(|w| w.is_sidebar_collapsed));

    WorkspaceSession::save_last(&source.snapshot_workspace(), &store);
    let mut restored = Workspace::new();
    restored.restore_workspace(WorkspaceSession::load_last(&store).expect("saved"));

    assert!(restored.window(&window).is_some_and(|w| w.is_sidebar_collapsed));
}

#[test]
fn sessions_without_sidebar_disclosure_state_restore_expanded() {
    let saved_window: SavedWindow = serde_json::from_str(
        r#"{"id": "window-1", "title": "Terminal", "layout": {"leaf": {"_0": "pane-1"}}, "activePaneId": "pane-1"}"#,
    )
    .expect("decodes");
    let mut session = WorkspaceSession::legacy(
        "legacy",
        "Legacy",
        saved_window.layout.clone(),
        vec![SavedPane {
            id: "pane-1".into(),
            active_tab_index: 0,
            tabs: vec![SavedTab::new("tab-2", PaneType::Terminal)],
        }],
        "pane-1",
    );
    session.windows = Some(vec![saved_window.clone()]);
    session.active_window_id = Some(saved_window.id.clone());
    let mut workspace = Workspace::new();
    workspace.restore_workspace(session);

    assert!(saved_window.is_sidebar_collapsed.is_none());
    assert!(workspace.window(&saved_window.id).is_some_and(|w| !w.is_sidebar_collapsed));
}

#[test]
fn generated_placeholder_window_titles_are_replaced_and_custom_ones_kept() {
    let pane = SavedPane {
        id: "pane-1".into(),
        active_tab_index: 0,
        tabs: vec![SavedTab {
            cwd: Some("/tmp/legacy-project".into()),
            ..SavedTab::new("tab-2", PaneType::Terminal)
        }],
    };
    let window = |id: &str, title: &str, custom: Option<bool>| SavedWindow {
        id: id.into(),
        session_id: None,
        title: title.into(),
        is_title_custom: custom,
        is_sidebar_collapsed: None,
        layout: Some(SplitNode::leaf("pane-1")),
        active_pane_id: "pane-1".into(),
        tabs: None,
        active_tab_index: None,
        depth_layers: None,
        active_depth_layer_index: None,
        active_depth: None,
    };
    let mut session = WorkspaceSession::legacy("s", "S", None, vec![pane], "pane-1");
    session.windows = Some(vec![window("window-3", "Window 3", None)]);
    let mut workspace = Workspace::new();
    workspace.restore_workspace(session.clone());
    let restored = workspace.window("window-3").expect("window");
    assert_eq!(restored.title, "legacy-project");
    assert!(!restored.is_title_custom);

    session.windows = Some(vec![window("window-3", "Build", None)]);
    workspace.restore_workspace(session);
    let restored = workspace.window("window-3").expect("window");
    assert_eq!(restored.title, "Build");
    assert!(restored.is_title_custom);
}

// MARK: - JSON shape

#[test]
fn snapshots_encode_the_keys_and_shapes_the_swift_app_wrote() {
    let mut workspace = Workspace::new();
    workspace.split_pane(soprano_types::SplitDirection::Horizontal, "pane-1").expect("split");
    let json = serde_json::to_value(workspace.snapshot_workspace()).expect("encodes");

    assert_eq!(json["id"], "last");
    assert_eq!(json["name"], "Last Session");
    assert!(json["savedAt"].is_f64());
    assert_eq!(json["activeWindowId"], "window-1");
    assert_eq!(json["layout"]["split"]["_0"]["direction"], "horizontal");
    assert_eq!(json["layout"]["split"]["_0"]["first"], serde_json::json!({"leaf": {"_0": "pane-1"}}));
    assert_eq!(json["layout"]["split"]["_0"]["splitPercentage"], 50.0);
    let window = &json["windows"][0];
    assert_eq!(window["sessionId"], "session-1");
    assert_eq!(window["isTitleCustom"], false);
    assert_eq!(window["isSidebarCollapsed"], false);
    assert_eq!(window["activeTabIndex"], 0);
    assert!(window.get("depthLayers").is_none());
    assert_eq!(window["tabs"][0]["activePaneId"], window["activePaneId"]);
    let session = &json["terminalSessions"][0];
    assert_eq!(
        session,
        &serde_json::json!({"id": "session-1", "name": "Session 1", "activeWindowId": "window-1"})
    );
    let tab = &json["panes"][0]["tabs"][0];
    assert_eq!(tab["type"], "terminal");
    assert_eq!(tab["title"], "Terminal 1");
    assert!(tab.get("profileId").is_none());
    assert!(tab.get("conversation").is_none());
}

#[test]
fn split_percentages_outside_the_supported_range_decode_clamped() {
    let node: SplitNode = serde_json::from_str(
        r#"{"split":{"_0":{"direction":"vertical","splitPercentage":3,"first":{"leaf":{"_0":"a"}},"second":{"leaf":{"_0":"b"}}}}}"#,
    )
    .expect("decodes");
    assert_eq!(node.split_percentage_at(&[]), Some(10.0));
    assert!(serde_json::from_str::<SavedTab>(r#"{"id":"tab-1","type":"spreadsheet"}"#).is_err());
}

#[test]
fn reference_dates_count_from_2001() {
    let unix_epoch = ReferenceDate::from_system_time(std::time::UNIX_EPOCH);
    assert_eq!(unix_epoch.0, -978_307_200.0);
    assert_eq!(unix_epoch.to_system_time(), Some(std::time::UNIX_EPOCH));
    let distant: ReferenceDate = serde_json::from_str("-63114076800").expect("decodes");
    assert_eq!(distant, ReferenceDate::DISTANT_PAST);
}
