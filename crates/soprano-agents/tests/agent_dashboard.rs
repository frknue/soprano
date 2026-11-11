use soprano_agents::*;
use soprano_types::AgentStatus;

fn entry(id: &str, status: AgentStatus, needs_attention: bool) -> AgentDashboardEntry {
    AgentDashboardEntry {
        pane_id: format!("pane-{id}"),
        tab_id: id.into(),
        tab_title: id.into(),
        window_title: "Window".into(),
        profile_id: "codex".into(),
        profile_name: "Codex".into(),
        status,
        needs_attention,
        started_at: None,
        cwd: None,
        session_name: None,
        conversation: None,
        is_chat: false,
        branch: None,
        title: id.into(),
    }
}

fn tab_ids(entries: &[AgentDashboardEntry]) -> Vec<&str> {
    entries.iter().map(|e| e.tab_id.as_str()).collect()
}

#[test]
fn snapshot_counts_current_states_and_orders_agents_by_urgency() {
    let snapshot = AgentDashboardSnapshot::new(vec![
        entry("running", AgentStatus::Running, false),
        entry("idle", AgentStatus::Idle, false),
        entry("error", AgentStatus::Error, false),
        entry("waiting", AgentStatus::Waiting, false),
        entry("attention", AgentStatus::Idle, true),
        entry("starting", AgentStatus::Starting, false),
        entry("stopped", AgentStatus::Stopped, false),
    ]);

    assert_eq!(snapshot.total_count(), 7);
    assert_eq!(snapshot.working_count(), 2);
    assert_eq!(snapshot.needs_input_count(), 1);
    assert_eq!(snapshot.error_count(), 1);
    assert_eq!(
        tab_ids(&snapshot.entries),
        vec!["attention", "waiting", "error", "running", "starting", "idle", "stopped"]
    );
}

#[test]
fn sections_group_agents_that_need_you_ahead_of_working_ready_and_stopped_ones() {
    let snapshot = AgentDashboardSnapshot::new(vec![
        entry("running", AgentStatus::Running, false),
        entry("idle", AgentStatus::Idle, false),
        entry("error", AgentStatus::Error, false),
        entry("stopped", AgentStatus::Stopped, false),
        entry("attention", AgentStatus::Idle, true),
        entry("starting", AgentStatus::Starting, false),
        entry("waiting", AgentStatus::Waiting, false),
    ]);

    let sections = AgentDashboardSection::group(&snapshot.entries);

    assert_eq!(
        sections.iter().map(|s| s.0).collect::<Vec<_>>(),
        vec![
            AgentDashboardSection::NeedsYou,
            AgentDashboardSection::Working,
            AgentDashboardSection::Ready,
            AgentDashboardSection::Stopped
        ]
    );
    assert_eq!(
        sections.iter().map(|s| tab_ids(&s.1)).collect::<Vec<_>>(),
        vec![
            vec!["attention", "waiting", "error"],
            vec!["running", "starting"],
            vec!["idle"],
            vec!["stopped"]
        ]
    );
    assert_eq!(
        AgentDashboardSection::group(&[entry("idle", AgentStatus::Idle, false)])
            .iter()
            .map(|s| s.0)
            .collect::<Vec<_>>(),
        vec![AgentDashboardSection::Ready]
    );
    assert_eq!(AgentDashboardSection::NeedsYou.title(), "Needs you");
}

#[test]
fn an_entry_is_identified_by_its_pane_and_tab_and_located_by_session_window_and_title() {
    let mut agent = entry("t1", AgentStatus::Running, false);
    agent.session_name = Some("Work".into());
    agent.title = "Plan the migration".into();
    assert_eq!(agent.id(), "pane-t1:t1");
    assert_eq!(agent.location(), "Work ▸ Window ▸ Plan the migration");
}
