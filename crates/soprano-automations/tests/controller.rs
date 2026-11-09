//! `AutomationControllerTests`: runs driven end to end without a display. The terminal
//! "starts" at once, and the agent's hooks are played by setting its status the way the agent
//! event handler does, then telling the controller the workspace changed.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, TimeZone, Utc};
use chrono_tz::Europe::Berlin;
use soprano_automations::worktree::git;
use soprano_automations::{
    AutomationController, AutomationEnvironment, AutomationHost, AutomationRun, AutomationStore, Clock,
    FixedClock, RunStatus, RunTrigger, ScheduleState, scheduling,
};
use soprano_config::{AppSettings, Automation, ConfigStore, DefaultKeybindings};
use soprano_model::Workspace;
use soprano_types::TerminalTarget;
use soprano_types::{AgentConversation, AgentLaunch, AgentStatus, AgentWaitingReason};

#[derive(Default)]
struct TestHost {
    workspace: Workspace,
    accepts_prompts: bool,
    started: Vec<TerminalTarget>,
    banners: Vec<(String, String)>,
    prompts: Vec<(String, TerminalTarget)>,
}

impl AutomationHost for TestHost {
    fn workspace(&self) -> &Workspace {
        &self.workspace
    }

    fn workspace_mut(&mut self) -> &mut Workspace {
        &mut self.workspace
    }

    fn start_terminal(&mut self, target: &TerminalTarget) -> bool {
        self.started.push(target.clone());
        true
    }

    fn send_prompt_to(&mut self, target: &TerminalTarget, prompt: &str) -> bool {
        if !self.accepts_prompts {
            return false;
        }
        self.prompts.push((prompt.to_owned(), target.clone()));
        true
    }

    fn visible_text(&self, _target: &TerminalTarget) -> Option<String> {
        None
    }

    fn display_is_awake(&self) -> bool {
        true
    }

    fn notify(&mut self, title: &str, body: &str, _run_id: &str) {
        self.banners.push((title.to_owned(), body.to_owned()));
    }
}

struct Fixture {
    controller: AutomationController,
    host: TestHost,
    clock: Arc<FixedClock>,
    directory: tempfile::TempDir,
}

impl Fixture {
    fn folder(&self) -> PathBuf {
        self.directory.path().join("repo")
    }

    fn last_run(&self) -> Option<AutomationRun> {
        self.controller.last_run("audit").cloned()
    }

    fn run(&self, id: &str) -> Option<AutomationRun> {
        self.controller.run(id).cloned()
    }

    /// Lets the controller's background preparation come back to this thread.
    fn wait_until(&mut self, condition: impl Fn(&Self) -> bool) {
        for _ in 0..500 {
            self.controller.drain(&mut self.host);
            if condition(self) {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("condition never held");
    }

    fn set_status(
        &mut self,
        target: &TerminalTarget,
        status: AgentStatus,
        reason: Option<AgentWaitingReason>,
    ) {
        self.host.workspace.update_agent_status(&target.pane_id, &target.tab_id, status, None, reason);
        self.controller.workspace_changed(&mut self.host);
    }

    fn finish_turn(&mut self, target: &TerminalTarget) {
        self.set_status(target, AgentStatus::Running, None);
        self.set_status(target, AgentStatus::Waiting, Some(AgentWaitingReason::TurnEnded));
    }

    fn set_last_message(&mut self, target: &TerminalTarget, message: &str) {
        if let Some(agent) = self.host.workspace.agent_mut(&target.pane_id, &target.tab_id) {
            agent.last_message = Some(message.to_owned());
        }
    }

    fn run_now_and_wait_for_window(&mut self) -> AutomationRun {
        let before = self.last_run().map(|run| run.id);
        self.controller.run_now(&mut self.host, "audit");
        self.wait_until(|f| {
            f.last_run().is_some_and(|run| Some(&run.id) != before.as_ref() && run.target().is_some())
        });
        self.last_run().expect("run")
    }

    /// Makes the automation's next run due at `due` (the clock is half a minute past it).
    fn set_due(&mut self, due: DateTime<Utc>) {
        let automation = self.controller.automation("audit").expect("automation");
        self.controller.store_mut().set_schedule(
            "audit",
            Some(ScheduleState {
                signature: scheduling::signature(&automation, Berlin),
                next_run_at: Some(due),
            }),
        );
    }

    fn tick(&mut self) {
        let now = self.clock.now();
        self.controller.tick(&mut self.host, now);
    }
}

/// Today 9:00 in Berlin.
fn nine_today() -> DateTime<Utc> {
    let today = Utc::now().with_timezone(&Berlin).date_naive();
    Berlin
        .from_local_datetime(&today.and_hms_opt(9, 0, 0).expect("time"))
        .single()
        .expect("berlin time")
        .with_timezone(&Utc)
}

fn make_fixture(automation: &str, now: DateTime<Utc>, accepts_prompts: bool) -> Fixture {
    let directory = tempfile::tempdir().expect("temp dir");
    let folder = directory.path().join("repo");
    std::fs::create_dir_all(&folder).expect("folder");
    let settings = directory.path().join("settings.json");
    let entry = automation.replace("$FOLDER", &folder.to_string_lossy());
    soprano_config::config_file::write(&format!(r#"{{ "automations": {{ "audit": {entry} }} }}"#), &settings)
        .expect("settings");
    let config = ConfigStore::new(&settings);
    config.start(false, &AppSettings::default_settings(), &DefaultKeybindings::config());

    let clock = Arc::new(FixedClock::new(now, Berlin));
    let environment = AutomationEnvironment {
        clock: clock.clone(),
        worktree_directory: directory.path().join("worktrees"),
        claude_config: None,
        home: directory.path().to_path_buf(),
        shell: "/bin/sh".into(),
        wake: Arc::new(|| {}),
    };
    let mut host = TestHost { accepts_prompts, ..TestHost::default() };
    let controller = AutomationController::new(AutomationStore::new(None), config, environment, &mut host);
    Fixture { controller, host, clock, directory }
}

fn absent_config() -> (ConfigStore, tempfile::TempDir) {
    let directory = tempfile::tempdir().expect("temp dir");
    (ConfigStore::new(directory.path().join("absent.json")), directory)
}

fn simple_environment() -> AutomationEnvironment {
    AutomationEnvironment {
        clock: Arc::new(FixedClock::new(Utc::now(), Berlin)),
        worktree_directory: std::env::temp_dir().join("soprano-unused-worktrees"),
        claude_config: None,
        home: std::env::temp_dir(),
        shell: "/bin/sh".into(),
        wake: Arc::new(|| {}),
    }
}

const OMP: &str = r#"{ "name": "Audit", "agent": "omp", "folder": "$FOLDER", "prompt": "Audit the repo.", "schedule": "0 9 * * *" }"#;

#[test]
fn a_new_automation_never_takes_the_id_of_an_entry_the_file_rejected() {
    // No prompt: the entry is reported and left out, but stays in the file.
    let fixture =
        make_fixture(r#"{ "name": "Audit", "agent": "omp", "folder": "$FOLDER" }"#, Utc::now(), false);

    assert!(fixture.controller.automations().is_empty());
    assert_eq!(Automation::make_id("Audit", &fixture.controller.taken_ids()), "audit-2");
}

#[test]
fn a_manual_run_opens_its_agent_in_the_automations_session_without_switching_to_it() {
    let mut fixture = make_fixture(OMP, Utc::now(), false);
    let session_before = fixture.host.workspace.active_session_id().to_owned();

    let run = fixture.run_now_and_wait_for_window();

    let target = run.target().expect("target");
    let workspace = &fixture.host.workspace;
    let agent = workspace.agent(&target.pane_id, &target.tab_id).expect("agent");
    let window = workspace.window_containing_pane(&target.pane_id).expect("window");
    assert_eq!(
        workspace.terminal_sessions().get(&window.session_id).map(|s| s.name.as_str()),
        Some(Workspace::AUTOMATION_SESSION_NAME)
    );
    assert_eq!(workspace.active_session_id(), session_before);
    assert_eq!(fixture.host.started, std::slice::from_ref(&target));
    assert_eq!(
        agent.launch,
        Some(AgentLaunch {
            prompt: "Audit the repo.".into(),
            skips_approvals: true,
            ..AgentLaunch::default()
        })
    );
    assert_eq!(agent.automation_run_id.as_deref(), Some(run.id.as_str()));
    assert_eq!(run.trigger, RunTrigger::Manual);
    assert_eq!(run.status, RunStatus::Starting);
    assert_eq!(window.title, "Audit #1");
}

#[test]
fn a_run_completes_when_its_agent_finishes_its_turn_keeps_the_reply_and_closes_the_unseen_window() {
    let mut fixture = make_fixture(OMP, Utc::now(), false);
    let target = fixture.run_now_and_wait_for_window().target().expect("target");

    fixture.set_status(&target, AgentStatus::Running, None);
    assert_eq!(fixture.last_run().map(|r| r.status), Some(RunStatus::Running));

    fixture.set_last_message(&target, "## Findings\nNothing risky.");
    fixture.set_status(&target, AgentStatus::Waiting, Some(AgentWaitingReason::TurnEnded));

    let run = fixture.last_run().expect("run");
    assert_eq!(run.status, RunStatus::Completed);
    assert_eq!(run.output.as_deref(), Some("## Findings\nNothing risky."));
    assert!(run.finished_at.is_some());
    assert_eq!(run.target(), None);
    assert!(fixture.host.workspace.pane(&target.pane_id).is_none());
    assert!(
        !fixture
            .host
            .workspace
            .terminal_sessions()
            .values()
            .any(|s| s.name == Workspace::AUTOMATION_SESSION_NAME)
    );
    let titles: Vec<&str> = fixture.host.banners.iter().map(|(title, _)| title.as_str()).collect();
    assert_eq!(titles, ["Audit is done"]);
}

#[test]
fn a_run_waiting_on_a_question_is_announced_and_keeps_its_window() {
    let mut fixture = make_fixture(OMP, Utc::now(), false);
    let target = fixture.run_now_and_wait_for_window().target().expect("target");

    fixture.set_status(&target, AgentStatus::Running, None);
    fixture.set_last_message(&target, "Which store?");
    fixture.set_status(&target, AgentStatus::Waiting, Some(AgentWaitingReason::Question));

    let run = fixture.last_run().expect("run");
    assert_eq!(run.status, RunStatus::NeedsInput);
    assert_eq!(run.message.as_deref(), Some("Which store?"));
    assert!(fixture.host.workspace.pane(&target.pane_id).is_some());
    assert_eq!(fixture.host.banners, [("Audit has a question".to_owned(), "Which store?".to_owned())]);
}

#[test]
fn a_scheduled_run_whose_precheck_fails_is_skipped_without_opening_a_window() {
    let due = nine_today();
    let mut fixture = make_fixture(
        r#"{ "name": "Audit", "agent": "omp", "folder": "$FOLDER", "prompt": "x", "schedule": "0 9 * * *", "precheck": "exit 4" }"#,
        due + chrono::Duration::seconds(30),
        false,
    );
    fixture.set_due(due);

    fixture.tick();
    fixture.wait_until(|f| f.last_run().is_some_and(|run| run.status.is_final()));

    let run = fixture.last_run().expect("run");
    assert_eq!(run.status, RunStatus::Skipped);
    assert_eq!(run.trigger, RunTrigger::Scheduled);
    assert_eq!(run.scheduled_for, Some(due));
    assert_eq!(run.message.as_deref(), Some("The precheck exited with code 4."));
    assert!(fixture.host.started.is_empty());
    assert!(fixture.host.banners.is_empty());
}

#[test]
fn a_scheduled_run_due_while_the_previous_one_still_works_is_skipped() {
    let due = nine_today();
    let mut fixture = make_fixture(OMP, due + chrono::Duration::seconds(30), false);
    fixture.run_now_and_wait_for_window();
    fixture.set_due(due);

    fixture.tick();

    let runs = fixture.controller.runs("audit");
    assert_eq!(runs.len(), 2);
    assert_eq!(runs[0].status, RunStatus::Skipped);
    assert_eq!(runs[0].message.as_deref(), Some("Run #1 was still working."));
    assert_eq!(runs[1].status, RunStatus::Starting);
}

#[test]
fn a_run_due_past_its_grace_period_is_recorded_as_missed() {
    let due = nine_today();
    let mut fixture = make_fixture(
        r#"{ "name": "Audit", "agent": "omp", "folder": "$FOLDER", "prompt": "x", "schedule": "0 9 * * *", "graceMinutes": 10 }"#,
        due + chrono::Duration::hours(2),
        false,
    );
    fixture.set_due(due);

    fixture.tick();

    let run = fixture.last_run().expect("run");
    assert_eq!(run.status, RunStatus::Skipped);
    assert_eq!(run.message.as_deref(), Some(AutomationController::MISSED_MESSAGE));
    assert!(fixture.host.started.is_empty());
}

#[test]
fn runs_left_open_when_soprano_quit_are_marked_failed_on_the_next_launch() {
    let mut store = AutomationStore::new(None);
    let mut open = AutomationRun::new(
        "run-1",
        "audit",
        1,
        RunTrigger::Scheduled,
        Utc::now(),
        RunStatus::Running,
        "omp",
        "/tmp",
    );
    open.pane_id = Some("pane-9".into());
    open.tab_id = Some("tab-9".into());
    store.insert(open);
    let (config, _directory) = absent_config();

    let controller = AutomationController::new(store, config, simple_environment(), &mut TestHost::default());

    let run = controller.run("run-1").expect("run");
    assert_eq!(run.status, RunStatus::Failed);
    assert_eq!(run.message.as_deref(), Some("Soprano quit before the run finished."));
    assert_eq!(run.target(), None);
}

#[test]
fn a_finished_run_from_an_earlier_launch_never_takes_over_the_tab_that_now_has_its_ids() {
    // Pane and tab ids start over on relaunch, so the ids a finished run kept can belong to an
    // unrelated agent of the same CLI by now.
    let mut host = TestHost { accepts_prompts: true, ..TestHost::default() };
    let pane_id = host.workspace.spawn_agent("omp", Some("/tmp"), false).expect("pane");
    let tab_id =
        host.workspace.pane(&pane_id).and_then(|p| p.active_tab()).map(|t| t.id.clone()).expect("tab");
    host.workspace.update_agent_status(&pane_id, &tab_id, AgentStatus::Idle, None, None);
    let mut store = AutomationStore::new(None);
    let mut finished = AutomationRun::new(
        "run-1",
        "audit",
        1,
        RunTrigger::Scheduled,
        Utc::now(),
        RunStatus::Completed,
        "omp",
        "/tmp",
    );
    finished.pane_id = Some(pane_id);
    finished.tab_id = Some(tab_id);
    store.insert(finished);
    let (config, _directory) = absent_config();

    let mut controller = AutomationController::new(store, config, simple_environment(), &mut host);

    assert_eq!(controller.run("run-1").and_then(AutomationRun::target), None);
    assert!(!controller.open_run(&mut host, "run-1"));
    assert!(host.prompts.is_empty());
}

/// A reuse automation whose first run finished with its window left open, and its next run
/// due now.
fn make_reuse_fixture(precheck: &str) -> (Fixture, AutomationRun) {
    let due = nine_today();
    let entry = format!(
        r#"{{ "name": "Audit", "agent": "omp", "folder": "$FOLDER", "prompt": "Audit.", "schedule": "0 9 * * *", "session": "reuse", "precheck": "{precheck}" }}"#
    );
    let mut fixture = make_fixture(&entry, due + chrono::Duration::seconds(30), true);
    let first = fixture.run_now_and_wait_for_window();
    fixture.finish_turn(&first.target().expect("target"));
    assert_eq!(fixture.run(&first.id).map(|r| r.status), Some(RunStatus::Completed));
    fixture.set_due(due);
    (fixture, first)
}

#[test]
fn a_scheduled_reuse_run_whose_precheck_fails_is_skipped_without_prompting_the_previous_agent() {
    let (mut fixture, first) = make_reuse_fixture("exit 4");

    fixture.tick();
    fixture.wait_until(|f| f.last_run().is_some_and(|run| run.status.is_final() && run.id != first.id));

    let run = fixture.last_run().expect("run");
    assert_eq!(run.status, RunStatus::Skipped);
    assert_eq!(run.message.as_deref(), Some("The precheck exited with code 4."));
    assert!(fixture.host.prompts.is_empty());
    assert!(fixture.run(&first.id).and_then(|r| r.target()).is_some());
}

#[test]
fn a_scheduled_reuse_run_whose_precheck_passes_hands_the_prompt_to_the_previous_agent() {
    let (mut fixture, first) = make_reuse_fixture("true");
    let target = first.target().expect("target");

    fixture.tick();
    fixture.wait_until(|f| f.last_run().is_some_and(|run| run.status == RunStatus::Running));

    let run = fixture.last_run().expect("run");
    assert_ne!(run.id, first.id);
    assert_eq!(run.target(), Some(target.clone()));
    assert_eq!(fixture.host.prompts, [("Audit.".to_owned(), target)]);
    assert_eq!(fixture.run(&first.id).and_then(|r| r.target()), None);
    assert_eq!(fixture.host.started.len(), 1);
}

#[test]
fn loading_a_saved_session_fails_open_runs_instead_of_following_the_tabs_that_take_their_ids() {
    let mut fixture = make_fixture(OMP, Utc::now(), false);
    let run = fixture.run_now_and_wait_for_window();
    let target = run.target().expect("target");

    // The saved session has a tab under the ids the run's tab has now.
    let saved = fixture.host.workspace.snapshot_workspace();
    fixture.host.workspace.restore_workspace(saved);
    assert!(fixture.host.workspace.agent(&target.pane_id, &target.tab_id).is_some());
    fixture.set_last_message(&target, "Someone else's reply.");
    fixture.finish_turn(&target);

    let after = fixture.run(&run.id).expect("run");
    assert_eq!(after.status, RunStatus::Failed);
    assert_eq!(
        after.message.as_deref(),
        Some("A saved session replaced the run's window before it finished.")
    );
    assert_eq!(after.output, None);
    assert_eq!(after.target(), None);
    assert!(fixture.host.workspace.pane(&target.pane_id).is_some());
    assert_eq!(
        fixture
            .host
            .workspace
            .agent(&target.pane_id, &target.tab_id)
            .and_then(|a| a.automation_run_id.clone()),
        None
    );
}

fn init_repository(folder: &Path) {
    for arguments in [
        &["init", "--quiet", "--initial-branch=main"][..],
        &["config", "user.email", "test@example.com"],
        &["config", "user.name", "Test"],
        &["commit", "--quiet", "--allow-empty", "-m", "init"],
    ] {
        git(arguments, folder).expect("git");
    }
}

#[test]
fn an_untouched_worktree_stays_while_its_runs_window_is_open_and_goes_with_an_unseen_one() {
    if soprano_git::reader::executable().is_none() {
        return;
    }
    let worktree_audit = r#"{ "name": "Audit", "agent": "omp", "folder": "$FOLDER", "prompt": "Audit.", "schedule": "0 9 * * *", "worktree": true }"#;
    let mut fixture = make_fixture(worktree_audit, Utc::now(), false);
    init_repository(&fixture.folder());

    // Someone opened this run while it worked: its agent stays, in its worktree.
    let watched = fixture.run_now_and_wait_for_window();
    let watched_target = watched.target().expect("target");
    assert!(fixture.controller.open_run(&mut fixture.host, &watched.id));
    fixture.finish_turn(&watched_target);
    // The report is read on the background thread that also removes worktrees.
    fixture.wait_until(|f| f.run(&watched.id).is_some_and(|r| r.status == RunStatus::Completed));
    std::thread::sleep(Duration::from_millis(300));
    fixture.controller.drain(&mut fixture.host);
    let watched_worktree = fixture.run(&watched.id).and_then(|r| r.worktree).expect("worktree");
    assert!(!watched_worktree.removed);
    assert!(Path::new(&watched_worktree.path).exists());
    assert!(fixture.host.workspace.pane(&watched_target.pane_id).is_some());

    // Nobody looked: the window closes and the untouched worktree goes too.
    let unseen = fixture.run_now_and_wait_for_window();
    fixture.finish_turn(&unseen.target().expect("target"));
    fixture.wait_until(|f| f.run(&unseen.id).and_then(|r| r.worktree).is_some_and(|w| w.removed));
    let unseen_worktree = fixture.run(&unseen.id).and_then(|r| r.worktree).expect("worktree");
    assert!(!Path::new(&unseen_worktree.path).exists());
}

#[test]
fn opening_a_closed_run_twice_returns_to_the_conversation_it_resumed_instead_of_starting_another() {
    let mut fixture = make_fixture(OMP, Utc::now(), false);
    let run = fixture.run_now_and_wait_for_window();
    let target = run.target().expect("target");
    let conversation = AgentConversation {
        cwd: Some("/tmp".into()),
        ..AgentConversation::new("01a186a9-695e-72bb-abf9-4646ac0bf7ea")
    };
    fixture.host.workspace.record_agent_conversation(
        conversation,
        &target.pane_id,
        &target.tab_id,
        Some("omp"),
    );
    fixture.finish_turn(&target);
    assert_eq!(fixture.run(&run.id).and_then(|r| r.target()), None);
    let panes_before = fixture.host.workspace.pane_count();

    assert!(fixture.controller.open_run(&mut fixture.host, &run.id));
    assert!(fixture.controller.open_run(&mut fixture.host, &run.id));

    assert_eq!(fixture.host.workspace.pane_count(), panes_before + 1);
    let resumed = fixture.run(&run.id).and_then(|r| r.target()).expect("resumed");
    assert_eq!(
        fixture
            .host
            .workspace
            .agent(&resumed.pane_id, &resumed.tab_id)
            .and_then(|a| a.conversation.as_ref())
            .map(|c| c.id.as_str()),
        Some("01a186a9-695e-72bb-abf9-4646ac0bf7ea")
    );
}

#[test]
fn a_run_whose_terminal_cannot_start_waits_for_a_display_and_starts_when_one_wakes() {
    struct SleepingHost {
        inner: TestHost,
        awake: bool,
    }
    impl AutomationHost for SleepingHost {
        fn workspace(&self) -> &Workspace {
            &self.inner.workspace
        }
        fn workspace_mut(&mut self) -> &mut Workspace {
            &mut self.inner.workspace
        }
        fn start_terminal(&mut self, target: &TerminalTarget) -> bool {
            self.awake && self.inner.start_terminal(target)
        }
        fn send_prompt_to(&mut self, _target: &TerminalTarget, _prompt: &str) -> bool {
            false
        }
        fn visible_text(&self, _target: &TerminalTarget) -> Option<String> {
            None
        }
        fn display_is_awake(&self) -> bool {
            self.awake
        }
        fn notify(&mut self, title: &str, body: &str, run_id: &str) {
            self.inner.notify(title, body, run_id);
        }
    }

    let fixture = make_fixture(OMP, Utc::now(), false);
    let Fixture { mut controller, host, directory: _directory, .. } = fixture;
    let mut host = SleepingHost { inner: host, awake: false };
    controller.run_now(&mut host, "audit");
    for _ in 0..500 {
        controller.drain(&mut host);
        if controller.is_waiting_for_display() {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let run = controller.last_run("audit").cloned().expect("run");
    assert_eq!(run.message.as_deref(), Some(AutomationController::WAITING_FOR_DISPLAY_MESSAGE));

    controller.retry_waiting_terminals(&mut host);
    assert!(controller.is_waiting_for_display());
    host.awake = true;
    controller.retry_waiting_terminals(&mut host);

    assert!(!controller.is_waiting_for_display());
    assert_eq!(controller.last_run("audit").and_then(|r| r.message.clone()), None);
    assert_eq!(host.inner.started.len(), 1);
}

#[cfg(unix)]
fn write_script(path: &Path, text: &str) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, text).expect("script");
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).expect("permissions");
}

#[test]
#[cfg(unix)]
fn only_an_open_code_that_offers_a_private_server_is_started_with_one() {
    let directory = tempfile::tempdir().expect("temp dir");
    let cli = |name: &str, help: &str| {
        let path = directory.path().join(name);
        write_script(&path, &format!("#!/bin/sh\nprintf '%s\\n' '{help}'\n"));
        path.to_string_lossy().into_owned()
    };
    let current =
        cli("opencode2", "  --standalone   Run with a private server instead of the background service");
    let legacy = cli("opencode1", "  -m, --model   model to use in the format of provider/model");
    let folder = directory.path().to_string_lossy().into_owned();

    assert!(AutomationController::open_code_has_private_server(&current, &folder, "/bin/sh"));
    assert!(!AutomationController::open_code_has_private_server(&legacy, &folder, "/bin/sh"));
    let missing = directory.path().join("missing").to_string_lossy().into_owned();
    assert!(AutomationController::open_code_has_private_server(&missing, &folder, "/bin/sh"));
}

#[test]
#[cfg(unix)]
fn a_runs_model_is_pinned_on_every_agent_a_session_can_start_with_so_an_agents_own_model_cannot_win() {
    let directory = tempfile::tempdir().expect("temp dir");
    let cli = directory.path().join("opencode");
    write_script(
        &cli,
        r#"#!/bin/sh
echo 'rc noise'
cat <<'EOF'
[{"id":"build","mode":"primary","hidden":false,"model":{"providerID":"a","id":"own"}},
 {"id":"review","mode":"all"},
 {"id":"compaction","mode":"primary","hidden":true},
 {"id":"explore","mode":"subagent"}]
EOF
"#,
    );

    let agents = AutomationController::open_code_primary_agents(
        &cli.to_string_lossy(),
        &directory.path().to_string_lossy(),
        "/bin/sh",
    );
    assert_eq!(agents, ["build", "review"]);
}

#[test]
fn saving_pausing_and_deleting_go_through_settings_json() {
    let mut fixture = make_fixture(OMP, Utc::now(), false);
    // Reading the automations copies nothing until settings.json changes.
    assert!(Arc::ptr_eq(&fixture.controller.automations(), &fixture.controller.automations()));
    let before = fixture.controller.automations();
    let mut automation = fixture.controller.automation("audit").expect("automation");
    automation.prompt = "Audit it all.".into();
    assert!(fixture.controller.save(&automation));
    assert_eq!(fixture.controller.automation("audit").map(|a| a.prompt), Some("Audit it all.".into()));
    assert!(!Arc::ptr_eq(&before, &fixture.controller.automations()));

    assert!(fixture.controller.set_enabled("audit", false));
    assert_eq!(fixture.controller.automation("audit").map(|a| a.enabled), Some(false));
    assert_eq!(fixture.controller.next_run_date("audit"), None);
    assert!(fixture.controller.set_enabled("audit", true));
    assert!(fixture.controller.next_run_date("audit").is_some());
    assert!(!fixture.controller.set_enabled("missing", false));

    let run = fixture.run_now_and_wait_for_window();
    let target = run.target().expect("target");
    assert!(fixture.controller.delete(&mut fixture.host, "audit"));
    assert!(fixture.controller.automation("audit").is_none());
    assert!(fixture.controller.runs("audit").is_empty());
    assert_eq!(
        fixture
            .host
            .workspace
            .agent(&target.pane_id, &target.tab_id)
            .and_then(|a| a.automation_run_id.clone()),
        None
    );
}
