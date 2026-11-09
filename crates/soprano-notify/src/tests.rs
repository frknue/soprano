//! Manager behavior, ported from `AgentConversationTests`, `ExternalEventRoutingTests`,
//! `TerminalSessionTests`, `TerminalLifecycleTests`, `AgentWaitingReasonTests`,
//! `AgentDashboardTests` and `NotificationSettingsTests` where they drive
//! `AgentNotificationManager`, plus the banner rules the Swift code states in comments.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use soprano_ipc::agent_event::agent_event_request;
use soprano_ipc::{AgentEvent, AgentEventState, Request};
use soprano_model::{PaneType, Workspace, WorkspaceChange};
use soprano_platform::StateStore;
use soprano_types::TerminalTarget;
use soprano_types::{AgentConversation, AgentStatus, AgentWaitingReason};

use crate::{
    AUTHORIZATION_KEY, Authorization, Banner, BannerClick, NotificationBackend, NotificationManager,
    SystemAuthorization, TerminalNotification,
};

type PostDone = Box<dyn FnOnce(Result<(), String>) + Send>;

/// A notification center that records what it was asked to do.
struct Fake {
    status: Mutex<SystemAuthorization>,
    grants: bool,
    defers_posts: bool,
    requests: AtomicUsize,
    posted: Mutex<Vec<Banner>>,
    pending: Mutex<Vec<PostDone>>,
    removed: Mutex<Vec<String>>,
}

impl Fake {
    fn new(status: SystemAuthorization) -> Arc<Self> {
        Self::with(status, true, false)
    }

    fn with(status: SystemAuthorization, grants: bool, defers_posts: bool) -> Arc<Self> {
        Arc::new(Self {
            status: Mutex::new(status),
            grants,
            defers_posts,
            requests: AtomicUsize::new(0),
            posted: Mutex::new(Vec::new()),
            pending: Mutex::new(Vec::new()),
            removed: Mutex::new(Vec::new()),
        })
    }

    fn posted(&self) -> Vec<Banner> {
        self.posted.lock().unwrap().clone()
    }

    fn removed(&self) -> Vec<String> {
        self.removed.lock().unwrap().clone()
    }

    fn complete_posts(&self) {
        let pending = std::mem::take(&mut *self.pending.lock().unwrap());
        for done in pending {
            done(Ok(()));
        }
    }
}

impl NotificationBackend for Fake {
    fn authorization_status(&self, done: Box<dyn FnOnce(SystemAuthorization) + Send>) {
        let status = *self.status.lock().unwrap();
        done(status);
    }

    fn request_authorization(&self, done: Box<dyn FnOnce(bool) + Send>) {
        self.requests.fetch_add(1, Ordering::SeqCst);
        *self.status.lock().unwrap() =
            if self.grants { SystemAuthorization::Authorized } else { SystemAuthorization::Denied };
        done(self.grants);
    }

    fn post(&self, banner: Banner, done: Box<dyn FnOnce(Result<(), String>) + Send>) {
        self.posted.lock().unwrap().push(banner);
        if self.defers_posts {
            self.pending.lock().unwrap().push(done);
        } else {
            done(Ok(()));
        }
    }

    fn remove_delivered(&self, identifiers: &[String]) {
        self.removed.lock().unwrap().extend(identifiers.iter().cloned());
    }
}

fn manager(fake: &Arc<Fake>) -> NotificationManager {
    NotificationManager::with_backend(Some(fake.clone()), StateStore::in_memory(), || false)
}

fn environment(pane_id: &str, tab_id: &str) -> HashMap<String, String> {
    HashMap::from([
        ("SOPRANO_APP_PID".to_owned(), "4242".to_owned()),
        ("SOPRANO_PANE_ID".to_owned(), pane_id.to_owned()),
        ("SOPRANO_TAB_ID".to_owned(), tab_id.to_owned()),
    ])
}

/// What `soprano agent-event <arguments>` sends from `pane_id`/`tab_id`.
fn reported(
    arguments: &[&str],
    target: &TerminalTarget,
    standard_input: Option<&str>,
    hook_owner: Option<i32>,
) -> AgentEvent {
    let arguments: Vec<String> =
        ["soprano", "agent-event"].iter().chain(arguments).map(|argument| argument.to_string()).collect();
    let request = agent_event_request(
        &arguments,
        &environment(&target.pane_id, &target.tab_id),
        || standard_input.map(|text| text.as_bytes().to_vec()),
        || hook_owner,
    );
    match request {
        Some(Request::AgentEvent(event)) => event,
        other => panic!("not an agent event: {other:?}"),
    }
}

fn event(arguments: &[&str], target: &TerminalTarget) -> AgentEvent {
    reported(arguments, target, None, None)
}

fn first_target(workspace: &Workspace) -> TerminalTarget {
    let pane_id = workspace.active_pane_id().to_owned();
    let tab_id = workspace.pane(&pane_id).and_then(|pane| pane.active_tab()).expect("a tab").id.clone();
    TerminalTarget::new(pane_id, tab_id)
}

fn agent_tab(workspace: &mut Workspace, profile_id: &str) -> TerminalTarget {
    let pane_id = workspace.active_pane_id().to_owned();
    let tab_id =
        workspace.add_tab_to_pane(&pane_id, PaneType::Agent, Some(profile_id), None).expect("tab added");
    TerminalTarget::new(pane_id, tab_id)
}

fn status(workspace: &Workspace, target: &TerminalTarget) -> Option<AgentStatus> {
    workspace.agent(&target.pane_id, &target.tab_id).map(|agent| agent.status)
}

fn needs_attention(workspace: &Workspace, target: &TerminalTarget) -> bool {
    workspace.agent(&target.pane_id, &target.tab_id).is_some_and(|agent| agent.needs_attention)
}

#[cfg(unix)]
fn spawn_cat() -> std::process::Child {
    std::process::Command::new("cat")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .expect("cat runs")
}

#[cfg(unix)]
fn end(mut child: std::process::Child) {
    let _ = child.kill();
    let _ = child.wait();
}

// MARK: - AgentConversationTests

#[test]
fn codex_trailing_payload_and_claude_standard_input_both_reach_the_owning_tab() {
    let mut workspace = Workspace::new();
    let codex = agent_tab(&mut workspace, "codex");
    let claude = agent_tab(&mut workspace, "claude-code");
    let mut notifications = manager(&Fake::new(SystemAuthorization::Authorized));

    let codex_event = event(
        &["needs-input", "--profile", "codex", r#"{"thread-id":"codex-one","cwd":"/tmp/repo"}"#],
        &codex,
    );
    let claude_event = reported(
        &["ready", "--profile", "claude-code", "--message-from-stdin"],
        &claude,
        Some(r#"{"session_id":"claude-two","cwd":"/tmp/repo"}"#),
        None,
    );
    notifications.handle_agent_event(&mut workspace, codex_event);
    notifications.handle_agent_event(&mut workspace, claude_event);

    let conversation_id =
        |target: &TerminalTarget| workspace.agent(&target.pane_id, &target.tab_id)?.conversation.clone();
    assert_eq!(conversation_id(&codex).map(|c| c.id).as_deref(), Some("codex-one"));
    assert_eq!(conversation_id(&claude).map(|c| c.id).as_deref(), Some("claude-two"));
    assert_eq!(
        workspace.pane(&claude.pane_id).and_then(|pane| pane.active_tab()).map(|tab| tab.id.clone()),
        Some(claude.tab_id.clone())
    );
}

#[test]
fn manually_launched_omp_attaches_to_the_shell_and_reports_through_the_dashboard() {
    let mut workspace = Workspace::new();
    let target = first_target(&workspace);
    let pane_id = target.pane_id.clone();
    workspace.add_tab_to_pane(&pane_id, PaneType::Terminal, None, None).expect("second tab");
    workspace.focus_tab(&target.pane_id, &target.tab_id, false);
    let mut notifications = manager(&Fake::new(SystemAuthorization::Authorized));
    let own_pid = std::process::id().to_string();
    fn deliver(
        notifications: &mut NotificationManager,
        workspace: &mut Workspace,
        target: &TerminalTarget,
        state: &str,
        options: &[&str],
    ) -> AgentEvent {
        let mut arguments = vec![state, "--profile", "omp"];
        arguments.extend_from_slice(options);
        arguments
            .extend_from_slice(&["--message-json", r#"{"session_id":"0199-aaaa","cwd":"/tmp/project"}"#]);
        let event = event(&arguments, target);
        notifications.handle_agent_event(workspace, event.clone());
        // The process the events named still runs, so monitoring keeps the agent attached.
        notifications.tick(Instant::now(), workspace);
        event
    }
    let entries = |workspace: &Workspace| workspace.agent_dashboard_entries();

    // Like Soprano's omp extension, every event names omp's process.
    deliver(&mut notifications, &mut workspace, &target, "ready", &["--pid", &own_pid]);
    assert_eq!(
        workspace.tab(&target.pane_id, &target.tab_id).map(|tab| tab.pane_type),
        Some(PaneType::Terminal)
    );
    assert_eq!(entries(&workspace).first().map(|entry| entry.profile_name.as_str()), Some("omp"));
    assert_eq!(entries(&workspace).first().map(|entry| entry.status), Some(AgentStatus::Idle));
    assert_eq!(
        workspace.agent(&target.pane_id, &target.tab_id).and_then(|agent| agent.conversation.clone()),
        Some(AgentConversation {
            id: "0199-aaaa".into(),
            cwd: Some("/tmp/project".into()),
            transcript_path: None
        })
    );
    // Shell command-completion events are not proof that omp has exited while the process
    // it named still runs.
    notifications.terminal_command_did_finish(&mut workspace, &target, Some(0));
    assert_eq!(entries(&workspace).first().map(|entry| entry.profile_name.as_str()), Some("omp"));

    deliver(&mut notifications, &mut workspace, &target, "running", &["--pid", &own_pid]);
    assert_eq!(entries(&workspace).iter().filter(|entry| entry.status == AgentStatus::Running).count(), 1);

    let notification = deliver(
        &mut notifications,
        &mut workspace,
        &target,
        "needs-input",
        &[
            "--notify",
            "--title",
            "omp",
            "--body",
            "Response ready",
            "--message-json",
            r#"{"message":"Please confirm the deployment"}"#,
        ],
    );
    assert!(notification.notify);
    assert_eq!(notification.body, "Response ready");
    assert_eq!(notification.message.as_deref(), Some("Please confirm the deployment"));
    assert_eq!(notification.title, "omp");
    let window = workspace.window_containing_pane(&target.pane_id).map(|window| window.title.as_str());
    let tab_title = workspace.tab(&target.pane_id, &target.tab_id).map(|tab| tab.title.as_str());
    assert!(
        NotificationManager::location_subtitle(None, window, tab_title)
            .is_some_and(|s| s.contains("Terminal 1"))
    );
    assert_eq!(entries(&workspace).iter().filter(|entry| entry.status == AgentStatus::Waiting).count(), 1);
    assert!(entries(&workspace).first().is_some_and(|entry| entry.needs_attention));
    assert_eq!(
        workspace
            .agent(&target.pane_id, &target.tab_id)
            .and_then(|agent| agent.last_message.clone())
            .as_deref(),
        Some("Please confirm the deployment")
    );

    deliver(&mut notifications, &mut workspace, &target, "running", &[]);
    assert_eq!(entries(&workspace).iter().filter(|entry| entry.status == AgentStatus::Running).count(), 1);
    assert!(entries(&workspace).first().is_some_and(|entry| !entry.needs_attention));

    deliver(&mut notifications, &mut workspace, &target, "stopped", &[]);
    assert!(entries(&workspace).is_empty());
    assert!(workspace.agent(&target.pane_id, &target.tab_id).is_none());
}

#[cfg(unix)]
#[test]
fn manual_omp_clears_its_badge_when_its_process_exits_without_shutdown_hook() {
    let mut workspace = Workspace::new();
    let target = first_target(&workspace);
    let omp = spawn_cat();
    let mut notifications = manager(&Fake::new(SystemAuthorization::Authorized));
    let pid = omp.id().to_string();
    notifications.handle_agent_event(
        &mut workspace,
        event(
            &["ready", "--profile", "omp", "--pid", &pid, "--message-json", r#"{"session_id":"live-omp"}"#],
            &target,
        ),
    );
    assert_eq!(workspace.agent_dashboard_entries().len(), 1);

    notifications.terminal_command_did_finish(&mut workspace, &target, Some(0));
    assert_eq!(workspace.agent_dashboard_entries().len(), 1);

    end(omp);
    notifications.terminal_command_did_finish(&mut workspace, &target, Some(0));
    assert!(workspace.agent_dashboard_entries().is_empty());
    assert_eq!(
        workspace.tab(&target.pane_id, &target.tab_id).map(|tab| tab.pane_type),
        Some(PaneType::Terminal)
    );
}

#[cfg(unix)]
#[test]
fn shell_started_claude_without_exit_hook_or_pid_clears_its_badge_once_the_hook_owner_has_exited() {
    let mut workspace = Workspace::new();
    let target = first_target(&workspace);
    let claude = spawn_cat();
    let mut notifications = manager(&Fake::new(SystemAuthorization::Authorized));
    // An older merged Claude hook set: SessionStart without --pid, and no SessionEnd.
    let event = reported(
        &["ready", "--profile", "claude-code", "--title", "Claude Code", "--body", "Ready for a prompt"],
        &target,
        None,
        Some(claude.id() as i32),
    );
    notifications.handle_agent_event(&mut workspace, event);
    assert_eq!(workspace.agent_dashboard_entries().len(), 1);

    // Agents such as omp emit their own OSC 133 marks mid-session.
    notifications.terminal_command_did_finish(&mut workspace, &target, Some(0));
    assert_eq!(workspace.agent_dashboard_entries().len(), 1);

    end(claude);
    notifications.terminal_command_did_finish(&mut workspace, &target, Some(0));
    assert!(workspace.agent_dashboard_entries().is_empty());
    assert_eq!(
        workspace.tab(&target.pane_id, &target.tab_id).map(|tab| tab.pane_type),
        Some(PaneType::Terminal)
    );
}

#[test]
fn dedicated_agent_tab_becomes_a_terminal_when_its_shell_reports_the_command_finished() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "omp");
    let mut notifications = manager(&Fake::new(SystemAuthorization::Authorized));

    notifications.terminal_command_did_finish(&mut workspace, &target, Some(0));

    assert!(workspace.agent(&target.pane_id, &target.tab_id).is_none());
    assert_eq!(
        workspace.tab(&target.pane_id, &target.tab_id).map(|tab| tab.pane_type),
        Some(PaneType::Terminal)
    );
}

#[test]
fn duplicate_status_messages_still_update_the_conversation_after_starting_a_new_chat() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "claude-code");
    let mut notifications = manager(&Fake::new(SystemAuthorization::Authorized));
    let now = Instant::now();
    for id in ["first-chat", "second-chat"] {
        notifications.handle_agent_event_at(
            &mut workspace,
            AgentEvent {
                pane_id: target.pane_id.clone(),
                tab_id: target.tab_id.clone(),
                state: AgentEventState::Ready,
                notify: false,
                title: "Claude Code".into(),
                body: "Ready".into(),
                profile_id: Some("claude-code".into()),
                process_id: None,
                message: None,
                reason: None,
                conversation: Some(AgentConversation {
                    id: id.into(),
                    cwd: Some("/tmp/repo".into()),
                    transcript_path: None,
                }),
            },
            now,
        );
    }
    assert_eq!(
        workspace
            .agent(&target.pane_id, &target.tab_id)
            .and_then(|agent| agent.conversation.clone())
            .map(|c| c.id),
        Some("second-chat".into())
    );
}

// MARK: - TerminalLifecycleTests (exit and hook parts)

#[test]
fn an_agent_reported_without_a_process_detaches_when_its_shell_command_returns() {
    let mut workspace = Workspace::new();
    let target = first_target(&workspace);
    workspace.rename_tab(&target.pane_id, &target.tab_id, "Terminal");
    let mut notifications = manager(&Fake::new(SystemAuthorization::Authorized));
    notifications.handle_agent_event(&mut workspace, event(&["running", "--profile", "codex"], &target));
    assert_eq!(status(&workspace, &target), Some(AgentStatus::Running));
    assert_eq!(workspace.agent(&target.pane_id, &target.tab_id).and_then(|agent| agent.process_id), None);

    notifications.terminal_command_did_finish(&mut workspace, &target, Some(130));

    assert!(workspace.agent(&target.pane_id, &target.tab_id).is_none());
    assert_eq!(
        workspace.tab(&target.pane_id, &target.tab_id).map(|tab| tab.title.as_str()),
        Some("Terminal")
    );
}

#[test]
fn an_agent_whose_reported_process_still_runs_stays_attached_when_a_shell_command_finishes() {
    let mut workspace = Workspace::new();
    let target = first_target(&workspace);
    let mut notifications = manager(&Fake::new(SystemAuthorization::Authorized));
    let pid = std::process::id().to_string();
    notifications.handle_agent_event(
        &mut workspace,
        event(&["running", "--profile", "codex", "--pid", &pid], &target),
    );

    notifications.terminal_command_did_finish(&mut workspace, &target, Some(0));

    assert_eq!(status(&workspace, &target), Some(AgentStatus::Running));
}

#[test]
fn a_finished_dedicated_agent_whose_pane_process_exits_stays_stopped_and_restartable() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "codex");
    let mut notifications = manager(&Fake::new(SystemAuthorization::Authorized));
    notifications.handle_agent_event(&mut workspace, event(&["running", "--profile", "codex"], &target));

    notifications.terminal_child_did_exit(&mut workspace, &target, Some(130));

    assert_eq!(status(&workspace, &target), Some(AgentStatus::Stopped));
    assert_eq!(workspace.agent(&target.pane_id, &target.tab_id).and_then(|agent| agent.exit_code), Some(130));
    assert!(workspace.take_events().is_empty());
}

#[test]
fn a_stop_report_never_attaches_an_agent_to_a_plain_terminal() {
    let mut workspace = Workspace::new();
    let target = first_target(&workspace);
    let mut notifications = manager(&Fake::new(SystemAuthorization::Authorized));

    notifications.handle_agent_event(&mut workspace, event(&["stopped", "--profile", "codex"], &target));

    assert!(workspace.agent(&target.pane_id, &target.tab_id).is_none());
}

#[test]
fn a_dedicated_agents_stop_report_turns_its_tab_into_a_terminal() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "claude-code");
    let mut notifications = manager(&Fake::new(SystemAuthorization::Authorized));

    notifications
        .handle_agent_event(&mut workspace, event(&["stopped", "--profile", "claude-code"], &target));

    assert!(workspace.agent(&target.pane_id, &target.tab_id).is_none());
    assert_eq!(
        workspace.tab(&target.pane_id, &target.tab_id).map(|tab| tab.pane_type),
        Some(PaneType::Terminal)
    );
}

#[test]
fn another_agents_process_id_is_not_recorded_for_this_tab() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "claude-code");
    let mut notifications = manager(&Fake::new(SystemAuthorization::Authorized));

    notifications.handle_agent_event(&mut workspace, event(&["running", "--pid", "4321"], &target));
    assert_eq!(workspace.agent(&target.pane_id, &target.tab_id).and_then(|agent| agent.process_id), None);

    notifications.handle_agent_event(
        &mut workspace,
        event(&["running", "--profile", "claude-code", "--pid", "4321"], &target),
    );
    assert_eq!(
        workspace.agent(&target.pane_id, &target.tab_id).and_then(|agent| agent.process_id),
        Some(4321)
    );
}

// MARK: - Process monitoring

#[cfg(unix)]
#[test]
fn a_tick_detaches_a_terminal_agent_whose_hook_owner_exited_before_the_prompt_returned() {
    let mut workspace = Workspace::new();
    let target = first_target(&workspace);
    let claude = spawn_cat();
    let mut notifications = manager(&Fake::new(SystemAuthorization::Authorized));
    let event = reported(&["running", "--profile", "claude-code"], &target, None, Some(claude.id() as i32));
    notifications.handle_agent_event(&mut workspace, event);

    notifications.tick(Instant::now(), &mut workspace);
    assert_eq!(status(&workspace, &target), Some(AgentStatus::Running));

    end(claude);
    notifications.tick(Instant::now(), &mut workspace);
    assert!(workspace.agent(&target.pane_id, &target.tab_id).is_none());
}

#[test]
fn a_tick_leaves_dedicated_agent_tabs_and_agents_without_a_process_alone() {
    let mut workspace = Workspace::new();
    let shell = first_target(&workspace);
    let dedicated = agent_tab(&mut workspace, "codex");
    let mut notifications = manager(&Fake::new(SystemAuthorization::Authorized));
    notifications.handle_agent_event(&mut workspace, event(&["running", "--profile", "codex"], &shell));
    notifications.handle_agent_event(&mut workspace, event(&["running", "--profile", "codex"], &dedicated));
    if let Some(agent) = workspace.agent_mut(&dedicated.pane_id, &dedicated.tab_id) {
        // A pid that cannot exist.
        agent.process_id = Some(i32::MAX);
    }

    notifications.tick(Instant::now(), &mut workspace);

    assert_eq!(status(&workspace, &shell), Some(AgentStatus::Running));
    assert_eq!(status(&workspace, &dedicated), Some(AgentStatus::Running));
    assert_eq!(
        workspace.tab(&dedicated.pane_id, &dedicated.tab_id).map(|tab| tab.pane_type),
        Some(PaneType::Agent)
    );
}

// MARK: - Status transitions (AgentDashboardTests, AgentWaitingReasonTests)

#[test]
fn each_reported_state_moves_the_agent_to_its_dashboard_status() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "codex");
    let mut notifications = manager(&Fake::new(SystemAuthorization::Authorized));
    assert_eq!(status(&workspace, &target), Some(AgentStatus::Starting));

    for (state, expected) in [
        ("running", AgentStatus::Running),
        ("ready", AgentStatus::Idle),
        ("needs-input", AgentStatus::Waiting),
        ("error", AgentStatus::Error),
        ("running", AgentStatus::Running),
    ] {
        notifications.handle_agent_event(&mut workspace, event(&[state, "--profile", "codex"], &target));
        assert_eq!(status(&workspace, &target), Some(expected), "after {state}");
    }
}

#[test]
fn a_finished_turn_stays_done_until_the_next_prompt() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "claude-code");
    let mut notifications = manager(&Fake::new(SystemAuthorization::Authorized));
    notifications
        .handle_agent_event(&mut workspace, event(&["running", "--profile", "claude-code"], &target));
    notifications.handle_agent_event(
        &mut workspace,
        event(&["ready", "--profile", "claude-code", "--notify"], &target),
    );

    notifications.surface_did_focus(&mut workspace, target.clone());
    notifications.tick(Instant::now() + Duration::from_secs(5), &mut workspace);
    notifications.terminal_command_did_finish(
        &mut workspace,
        &TerminalTarget::new("elsewhere", "tab"),
        Some(0),
    );
    assert_eq!(status(&workspace, &target), Some(AgentStatus::Idle));

    notifications
        .handle_agent_event(&mut workspace, event(&["running", "--profile", "claude-code"], &target));
    assert_eq!(status(&workspace, &target), Some(AgentStatus::Running));
}

#[test]
fn a_needs_input_event_records_why_and_a_silent_one_reads_as_a_finished_turn() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "omp");
    let mut notifications = manager(&Fake::new(SystemAuthorization::Authorized));
    let reason = |workspace: &Workspace| {
        workspace.agent(&target.pane_id, &target.tab_id).and_then(|a| a.waiting_reason)
    };
    // The reason is not part of an event's fingerprint, so reports a second apart.
    let start = Instant::now();
    let mut report = |workspace: &mut Workspace, arguments: &[&str], second: u64| {
        notifications.handle_agent_event_at(
            workspace,
            event(arguments, &target),
            start + Duration::from_secs(second),
        );
    };

    report(&mut workspace, &["needs-input", "--profile", "omp", "--reason", "approval"], 0);
    assert_eq!(reason(&workspace), Some(AgentWaitingReason::Approval));

    report(&mut workspace, &["needs-input", "--profile", "omp", "--reason", "question"], 2);
    assert_eq!(reason(&workspace), Some(AgentWaitingReason::Question));

    report(&mut workspace, &["needs-input", "--profile", "omp"], 4);
    assert_eq!(reason(&workspace), Some(AgentWaitingReason::TurnEnded));

    report(&mut workspace, &["running", "--profile", "omp"], 6);
    assert_eq!(reason(&workspace), None);
}

#[test]
fn an_identical_event_within_a_second_is_ignored_but_a_later_one_counts() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "codex");
    let fake = Fake::new(SystemAuthorization::Authorized);
    let mut notifications = manager(&fake);
    let start = Instant::now();
    let ready = event(&["ready", "--profile", "codex", "--notify"], &target);

    notifications.handle_agent_event_at(&mut workspace, ready.clone(), start);
    notifications.handle_agent_event_at(&mut workspace, ready.clone(), start + Duration::from_millis(500));
    assert_eq!(fake.posted().len(), 1);

    notifications.handle_agent_event_at(&mut workspace, ready, start + Duration::from_millis(1500));
    assert_eq!(fake.posted().len(), 2);
}

// MARK: - Banners

#[test]
fn an_unfocused_agent_gets_one_banner_naming_what_it_wants_over_its_conversation() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "claude-code");
    workspace.rename_tab(&target.pane_id, &target.tab_id, "✳ Fix notification layout");
    let fake = Fake::new(SystemAuthorization::Authorized);
    let mut notifications = manager(&fake);

    notifications.handle_agent_event(
        &mut workspace,
        event(&["needs-input", "--profile", "claude-code", "--notify", "--reason", "approval"], &target),
    );

    let banners = fake.posted();
    assert_eq!(banners.len(), 1);
    assert_eq!(banners[0].title, "Claude Code needs approval");
    assert_eq!(banners[0].body, "Fix notification layout");
    assert_eq!(banners[0].subtitle, None);
    assert_eq!(banners[0].identifier, format!("soprano-{}-{}", target.pane_id, target.tab_id));
    assert_eq!(banners[0].thread_identifier, target.pane_id);
    assert_eq!(banners[0].click(), BannerClick::Tab(target.clone()));
    assert!(needs_attention(&workspace, &target));
}

#[test]
fn the_next_banner_for_a_tab_replaces_the_last_instead_of_stacking() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "codex");
    let fake = Fake::new(SystemAuthorization::Authorized);
    let mut notifications = manager(&fake);

    notifications
        .handle_agent_event(&mut workspace, event(&["ready", "--profile", "codex", "--notify"], &target));
    notifications
        .handle_agent_event(&mut workspace, event(&["error", "--profile", "codex", "--notify"], &target));

    let banners = fake.posted();
    assert_eq!(
        banners.iter().map(|banner| banner.title.as_str()).collect::<Vec<_>>(),
        ["Codex finished", "Codex failed"]
    );
    assert_eq!(banners[0].identifier, banners[1].identifier);
}

#[test]
fn the_focused_pane_gets_neither_a_banner_nor_an_attention_mark() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "codex");
    let fake = Fake::new(SystemAuthorization::Authorized);
    let mut notifications = manager(&fake);
    notifications.surface_did_focus(&mut workspace, target.clone());

    notifications
        .handle_agent_event(&mut workspace, event(&["ready", "--profile", "codex", "--notify"], &target));

    assert!(fake.posted().is_empty());
    assert!(!needs_attention(&workspace, &target));
}

#[test]
fn a_focused_pane_in_a_background_app_counts_as_unfocused() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "codex");
    let fake = Fake::new(SystemAuthorization::Authorized);
    let mut notifications = manager(&fake);
    notifications.surface_did_focus(&mut workspace, target.clone());
    notifications.app_did_resign_active();

    notifications
        .handle_agent_event(&mut workspace, event(&["ready", "--profile", "codex", "--notify"], &target));
    assert_eq!(fake.posted().len(), 1);
    assert!(needs_attention(&workspace, &target));

    // Coming back to the app with that pane focused clears its mark and its banner.
    notifications.app_did_become_active(&mut workspace);
    assert!(!needs_attention(&workspace, &target));
    assert_eq!(fake.removed(), [Banner::identifier(&target)]);
}

#[test]
fn focusing_a_tab_clears_its_mark_and_withdraws_its_banners() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "codex");
    let fake = Fake::new(SystemAuthorization::Authorized);
    let mut notifications = manager(&fake);
    notifications
        .handle_agent_event(&mut workspace, event(&["ready", "--profile", "codex", "--notify"], &target));
    assert!(needs_attention(&workspace, &target));

    notifications.surface_did_focus(&mut workspace, target.clone());

    assert!(!needs_attention(&workspace, &target));
    assert_eq!(fake.removed(), [Banner::identifier(&target)]);
    // Nothing is left to withdraw a second time.
    notifications.surface_did_focus(&mut workspace, target);
    assert_eq!(fake.removed().len(), 1);
}

#[test]
fn a_model_change_clears_the_focused_tabs_mark_but_other_changes_do_not() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "codex");
    let mut notifications = manager(&Fake::new(SystemAuthorization::Authorized));
    notifications.surface_did_focus(&mut workspace, target.clone());
    // A mark the model set on its own (a restored workspace) while that tab has focus.
    workspace.agent_mut(&target.pane_id, &target.tab_id).expect("agent").needs_attention = true;

    notifications.workspace_did_change(&mut workspace, &[WorkspaceChange::TabTitle(target.clone())]);
    assert!(needs_attention(&workspace, &target));

    notifications.workspace_did_change(&mut workspace, &[WorkspaceChange::Model]);
    assert!(!needs_attention(&workspace, &target));
    assert_eq!(notifications.focused_target(), Some(target.clone()));

    notifications.surface_did_lose_focus(&target);
    assert_eq!(notifications.focused_target(), None);
}

#[test]
fn a_banner_posted_after_its_tab_got_focus_is_withdrawn_at_once() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "codex");
    let fake = Fake::with(SystemAuthorization::Authorized, true, true);
    let mut notifications = manager(&fake);
    notifications
        .handle_agent_event(&mut workspace, event(&["ready", "--profile", "codex", "--notify"], &target));
    notifications.surface_did_focus(&mut workspace, target.clone());
    assert!(fake.removed().is_empty());

    fake.complete_posts();

    assert_eq!(fake.removed(), [Banner::identifier(&target)]);
}

/// The OS finishes a post on its own thread while the UI thread focuses the tab: whichever
/// wins, the banner ends up withdrawn exactly once and nothing stays recorded for it.
#[test]
fn a_banner_finishing_while_its_tab_gets_focus_is_always_withdrawn() {
    for _ in 0..500 {
        let mut workspace = Workspace::new();
        let target = agent_tab(&mut workspace, "codex");
        let fake = Fake::with(SystemAuthorization::Authorized, true, true);
        let mut notifications = manager(&fake);
        notifications
            .handle_agent_event(&mut workspace, event(&["ready", "--profile", "codex", "--notify"], &target));
        let start = Arc::new(std::sync::Barrier::new(2));
        let os = {
            let (fake, start) = (fake.clone(), start.clone());
            std::thread::spawn(move || {
                start.wait();
                fake.complete_posts();
            })
        };
        start.wait();
        notifications.surface_did_focus(&mut workspace, target.clone());
        os.join().expect("completion thread");

        assert_eq!(fake.removed(), [Banner::identifier(&target)]);
        // Focusing again finds nothing left to withdraw.
        notifications.surface_did_focus(&mut workspace, target.clone());
        assert_eq!(fake.removed().len(), 1);
    }
}

#[test]
fn an_automation_runs_agent_gets_no_banner_of_its_own() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "codex");
    workspace.agent_mut(&target.pane_id, &target.tab_id).expect("agent").automation_run_id =
        Some("run-1".into());
    let fake = Fake::new(SystemAuthorization::Authorized);
    let mut notifications = manager(&fake);

    notifications.handle_agent_event(
        &mut workspace,
        event(
            &[
                "needs-input",
                "--profile",
                "codex",
                "--notify",
                r#"{"type":"agent-turn-complete","last-assistant-message":"Done."}"#,
            ],
            &target,
        ),
    );

    assert!(fake.posted().is_empty());
    assert_eq!(status(&workspace, &target), Some(AgentStatus::Waiting));
    assert_eq!(
        workspace
            .agent(&target.pane_id, &target.tab_id)
            .and_then(|agent| agent.last_message.clone())
            .as_deref(),
        Some("Done.")
    );
}

#[test]
fn an_automation_runs_banner_names_the_automation_and_opens_the_run() {
    let fake = Fake::new(SystemAuthorization::Authorized);
    let notifications = manager(&fake);

    notifications.deliver_automation_notification("Nightly audit finished", "3 findings", "run-7");

    let banners = fake.posted();
    assert_eq!(banners.len(), 1);
    assert_eq!(banners[0].subtitle.as_deref(), Some("Automations"));
    assert_eq!(banners[0].identifier, "soprano-automation-run-7-run-7");
    assert_eq!(banners[0].click(), BannerClick::AutomationRun("run-7".into()));
}

#[test]
fn the_sound_setting_is_read_for_every_banner() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "codex");
    let fake = Fake::new(SystemAuthorization::Authorized);
    let sound = Arc::new(AtomicBool::new(false));
    let setting = sound.clone();
    let mut notifications =
        NotificationManager::with_backend(Some(fake.clone()), StateStore::in_memory(), move || {
            setting.load(Ordering::SeqCst)
        });

    notifications
        .handle_agent_event(&mut workspace, event(&["ready", "--profile", "codex", "--notify"], &target));
    sound.store(true, Ordering::SeqCst);
    notifications
        .handle_agent_event(&mut workspace, event(&["error", "--profile", "codex", "--notify"], &target));

    assert_eq!(fake.posted().iter().map(|banner| banner.plays_sound).collect::<Vec<_>>(), [false, true]);
}

#[test]
fn clicking_a_banner_focuses_its_tab() {
    let mut workspace = Workspace::new();
    let first = first_target(&workspace);
    let target = agent_tab(&mut workspace, "codex");
    workspace.focus_tab(&first.pane_id, &first.tab_id, false);

    BannerClick::Tab(target.clone()).focus(&mut workspace);

    assert_eq!(
        workspace.pane(&target.pane_id).and_then(|pane| pane.active_tab()).map(|tab| tab.id.clone()),
        Some(target.tab_id)
    );
}

#[test]
fn banner_user_info_written_by_either_app_decodes_to_its_click() {
    assert_eq!(
        BannerClick::from_user_info(Some("pane-1"), Some("tab-2"), None),
        Some(BannerClick::Tab(TerminalTarget::new("pane-1", "tab-2")))
    );
    assert_eq!(
        BannerClick::from_user_info(Some("automation-r"), Some("r"), Some("r")),
        Some(BannerClick::AutomationRun("r".into()))
    );
    assert_eq!(BannerClick::from_user_info(Some("pane-1"), None, None), None);
}

// MARK: - Terminal notifications

#[test]
fn a_plain_terminals_notification_keeps_its_words_and_names_where_it_came_from() {
    let mut workspace = Workspace::new();
    let target = first_target(&workspace);
    let fake = Fake::new(SystemAuthorization::Authorized);
    let mut notifications = manager(&fake);

    notifications.handle_terminal_notification(
        &mut workspace,
        TerminalNotification { target: target.clone(), title: "Build".into(), body: "Build finished".into() },
    );

    let window = workspace.window_containing_pane(&target.pane_id).expect("window").title.clone();
    let banners = fake.posted();
    assert_eq!(banners.len(), 1);
    assert_eq!(banners[0].title, "Build");
    assert_eq!(banners[0].body, "Build finished");
    assert_eq!(banners[0].subtitle, Some(format!("Session 1 ▸ {window} ▸ Terminal 1")));
    assert!(workspace.agent(&target.pane_id, &target.tab_id).is_none());
}

#[test]
fn a_plain_terminals_notification_in_the_focused_pane_shows_nothing() {
    let mut workspace = Workspace::new();
    let target = first_target(&workspace);
    let fake = Fake::new(SystemAuthorization::Authorized);
    let mut notifications = manager(&fake);
    notifications.surface_did_focus(&mut workspace, target.clone());

    notifications.handle_terminal_notification(
        &mut workspace,
        TerminalNotification { target, title: String::new(), body: "Build finished".into() },
    );

    assert!(fake.posted().is_empty());
}

#[test]
fn codex_osc_notifications_are_approvals() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "codex");
    let fake = Fake::new(SystemAuthorization::Authorized);
    let mut notifications = manager(&fake);

    notifications.handle_terminal_notification(
        &mut workspace,
        TerminalNotification { target: target.clone(), title: String::new(), body: String::new() },
    );

    let agent = workspace.agent(&target.pane_id, &target.tab_id).expect("agent");
    assert_eq!(agent.status, AgentStatus::Waiting);
    assert_eq!(agent.waiting_reason, Some(AgentWaitingReason::Approval));
    assert!(agent.needs_attention);
    assert_eq!(fake.posted().first().map(|banner| banner.title.as_str()), Some("Codex needs approval"));
}

#[test]
fn an_agents_osc_notification_reads_its_words_for_what_it_waits_on() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "claude-code");
    let fake = Fake::new(SystemAuthorization::Authorized);
    let mut notifications = manager(&fake);
    let mut notify = |workspace: &mut Workspace, body: &str| {
        notifications.handle_terminal_notification(
            workspace,
            TerminalNotification { target: target.clone(), title: "Claude Code".into(), body: body.into() },
        );
        let agent = workspace.agent(&target.pane_id, &target.tab_id).expect("agent");
        (agent.status, agent.waiting_reason)
    };

    assert_eq!(
        notify(&mut workspace, "Claude needs your permission"),
        (AgentStatus::Waiting, Some(AgentWaitingReason::Approval))
    );
    assert_eq!(
        notify(&mut workspace, "A question for you"),
        (AgentStatus::Waiting, Some(AgentWaitingReason::Question))
    );
    assert_eq!(notify(&mut workspace, "All done"), (AgentStatus::Idle, None));
    assert_eq!(
        fake.posted().iter().map(|banner| banner.title.as_str()).collect::<Vec<_>>(),
        ["Claude Code needs approval", "Claude Code needs input", "Claude Code finished"]
    );
}

// MARK: - Location subtitle (ExternalEventRoutingTests, TerminalSessionTests)

#[test]
fn notification_subtitle_names_the_window_and_pane_it_came_from() {
    assert_eq!(
        NotificationManager::location_subtitle(None, Some("Soprano"), Some("Claude Code")).as_deref(),
        Some("Soprano ▸ Claude Code")
    );
    assert_eq!(
        NotificationManager::location_subtitle(Some("Other"), Some("Build"), Some("Claude")).as_deref(),
        Some("Other ▸ Build ▸ Claude")
    );
}

#[test]
fn notification_subtitle_skips_missing_and_empty_location_parts() {
    assert_eq!(
        NotificationManager::location_subtitle(None, Some("Soprano"), None).as_deref(),
        Some("Soprano")
    );
    assert_eq!(
        NotificationManager::location_subtitle(None, Some(""), Some("Codex")).as_deref(),
        Some("Codex")
    );
    assert_eq!(NotificationManager::location_subtitle(None, None, Some("")), None);
}

// MARK: - Authorization (NotificationSettingsTests and the Swift permission flow)

#[test]
fn an_unbundled_build_reports_notifications_unavailable_and_posts_nothing() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "codex");
    let mut notifications = NotificationManager::with_backend(None, StateStore::in_memory(), || false);
    assert!(!notifications.can_post());

    notifications.request_authorization_if_needed();
    assert_eq!(notifications.authorization(), None);
    notifications.refresh_authorization();
    assert_eq!(notifications.authorization(), Some(Authorization::Unavailable));

    // The model still updates: the pane shows its status and unread ring.
    notifications
        .handle_agent_event(&mut workspace, event(&["ready", "--profile", "codex", "--notify"], &target));
    assert!(needs_attention(&workspace, &target));
}

#[test]
fn launch_asks_once_and_persists_the_answer_under_the_swift_key() {
    let fake = Fake::new(SystemAuthorization::NotDetermined);
    let store = StateStore::in_memory();
    let notifications = NotificationManager::with_backend(Some(fake.clone()), store.clone(), || false);
    let changes = Arc::new(Mutex::new(Vec::new()));
    let seen = changes.clone();
    notifications.on_authorization_changed(move |value| seen.lock().unwrap().push(value));

    notifications.request_authorization_if_needed();
    assert_eq!(fake.requests.load(Ordering::SeqCst), 1);
    assert_eq!(notifications.authorization(), Some(Authorization::Authorized));
    assert_eq!(store.get::<String>(AUTHORIZATION_KEY).as_deref(), Some("authorized"));

    // Already answered: no second prompt, and an unchanged answer is not announced again.
    notifications.request_authorization_if_needed();
    notifications.refresh_authorization();
    assert_eq!(fake.requests.load(Ordering::SeqCst), 1);
    assert_eq!(*changes.lock().unwrap(), [Authorization::Authorized]);
}

#[test]
fn a_denied_permission_is_recorded_and_no_banner_is_attempted() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "codex");
    let fake = Fake::new(SystemAuthorization::Denied);
    let mut notifications = manager(&fake);

    notifications
        .handle_agent_event(&mut workspace, event(&["ready", "--profile", "codex", "--notify"], &target));

    assert!(fake.posted().is_empty());
    assert_eq!(fake.requests.load(Ordering::SeqCst), 0);
    assert_eq!(notifications.authorization(), Some(Authorization::Denied));
}

#[test]
fn the_first_banner_asks_when_launch_did_not_and_posts_only_if_granted() {
    let mut workspace = Workspace::new();
    let target = agent_tab(&mut workspace, "codex");
    let granting = Fake::with(SystemAuthorization::NotDetermined, true, false);
    let mut notifications = manager(&granting);
    notifications
        .handle_agent_event(&mut workspace, event(&["ready", "--profile", "codex", "--notify"], &target));
    assert_eq!(granting.posted().len(), 1);
    assert_eq!(notifications.authorization(), Some(Authorization::Authorized));

    let refusing = Fake::with(SystemAuthorization::NotDetermined, false, false);
    let mut notifications = manager(&refusing);
    notifications
        .handle_agent_event(&mut workspace, event(&["error", "--profile", "codex", "--notify"], &target));
    assert!(refusing.posted().is_empty());
    assert_eq!(notifications.authorization(), Some(Authorization::Denied));
}

#[test]
fn refreshing_reports_every_os_answer_in_the_settings_terms() {
    for (system, expected) in [
        (SystemAuthorization::Authorized, Authorization::Authorized),
        (SystemAuthorization::Denied, Authorization::Denied),
        (SystemAuthorization::NotDetermined, Authorization::NotDetermined),
        (SystemAuthorization::Unknown, Authorization::Unavailable),
    ] {
        let notifications = manager(&Fake::new(system));
        notifications.refresh_authorization();
        assert_eq!(notifications.authorization(), Some(expected));
    }
}

#[test]
fn an_answer_the_swift_app_stored_is_read_back() {
    let store = StateStore::in_memory();
    store.set(AUTHORIZATION_KEY, "notDetermined");
    let notifications = NotificationManager::with_backend(None, store, || false);
    assert_eq!(notifications.authorization(), Some(Authorization::NotDetermined));
    for value in [
        Authorization::Authorized,
        Authorization::Denied,
        Authorization::NotDetermined,
        Authorization::Unavailable,
    ] {
        assert_eq!(Authorization::from_raw(value.raw_value()), Some(value));
    }
}
