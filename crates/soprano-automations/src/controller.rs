//! Runs the automations `settings.json` declares while Soprano is open
//! (`Automations/AutomationController.swift`): the host checks every half minute (and when the
//! machine wakes) which are due by calling [`AutomationController::tick`]; each run is prepared
//! (precheck, worktree) on a background thread, opens its agent in the Automations session
//! without switching to it, follows the agent to the end of its turn, keeps what it said, and
//! closes the run's window if nobody opened it.
//!
//! The host drives it from its main thread:
//! - [`tick`](AutomationController::tick) every [`CHECK_INTERVAL`](AutomationController::CHECK_INTERVAL),
//!   on wake from sleep, and after `settings.json` changed;
//! - [`workspace_changed`](AutomationController::workspace_changed) after every workspace model
//!   change (agent status, tabs closed, a session restored);
//! - [`drain`](AutomationController::drain) whenever the environment's `wake` callback fired;
//! - [`retry_waiting_terminals`](AutomationController::retry_waiting_terminals) every
//!   [`DISPLAY_RETRY_INTERVAL`](AutomationController::DISPLAY_RETRY_INTERVAL) while
//!   [`is_waiting_for_display`](AutomationController::is_waiting_for_display).

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use soprano_agents::{AgentTranscriptSource, TimelineItemKind};
use soprano_config::{Automation, AutomationSession, AutomationWorkspace, ConfigStore};
use soprano_ipc::agent_event::summarize;
use soprano_model::TerminalTarget;
use soprano_platform::AppIdentity;
use soprano_types::{AgentCatalog, AgentConversation, AgentLaunch, AgentStatus, AgentWaitingReason};

use crate::claude_trust;
use crate::clock::{Clock, SystemClock};
use crate::host::AutomationHost;
use crate::precheck::{self, PrecheckOutcome};
use crate::run::{AutomationRun, RunStatus, RunTrigger};
use crate::scheduling::{self, Decision};
use crate::store::AutomationStore;
use crate::tracking::{self, Change, Observation};
use crate::worker::Worker;
use crate::worktree::{self, Checkout};

/// What runs need besides the host: time, where worktrees go, Claude Code's config, the home
/// the agent CLIs keep transcripts in, the login shell prechecks run in, and how to tell the
/// host that background work finished.
#[derive(Clone)]
pub struct AutomationEnvironment {
    pub clock: Arc<dyn Clock>,
    pub worktree_directory: PathBuf,
    /// `~/.claude.json`; `None` leaves Claude Code's folder trust alone.
    pub claude_config: Option<PathBuf>,
    pub home: PathBuf,
    pub shell: String,
    /// Called on the worker thread when a result waits for [`AutomationController::drain`].
    pub wake: Arc<dyn Fn() + Send + Sync>,
}

impl AutomationEnvironment {
    /// The running app's: system clock, `<data dir>/worktrees`, the user's Claude config, home
    /// and login shell.
    pub fn for_app(identity: &AppIdentity, wake: impl Fn() + Send + Sync + 'static) -> Self {
        Self {
            clock: Arc::new(SystemClock),
            worktree_directory: worktree::default_directory(identity),
            claude_config: Some(claude_trust::default_config_path()),
            home: soprano_platform::paths::home_dir(),
            shell: soprano_platform::shell::user_shell(),
            wake: Arc::new(wake),
        }
    }
}

/// What was done off the main thread before a run's window opens.
#[derive(Debug, Default)]
struct Preparation {
    precheck: Option<PrecheckOutcome>,
    checkout: Option<Checkout>,
    failure: Option<String>,
    /// The run's OpenCode takes its model through a private server.
    starts_open_code_server: bool,
    /// Its agents the run's model is pinned on.
    open_code_agents: Vec<String>,
}

/// Background results the host drains on its thread.
enum Completion {
    /// A scheduled reuse run's precheck answered.
    ReusePrecheck {
        run_id: String,
        automation: Box<Automation>,
        outcome: PrecheckOutcome,
    },
    Prepared {
        run_id: String,
        automation: Box<Automation>,
        preparation: Preparation,
    },
    /// A completed run's reply from its transcript, and whether its worktree was taken back.
    Reported {
        run_id: String,
        reply: Option<String>,
        untouched: bool,
    },
}

pub struct AutomationController {
    store: AutomationStore,
    config: ConfigStore,
    environment: AutomationEnvironment,
    worker: Worker<Completion>,
    /// Runs whose terminal could not start because every display slept.
    waiting_for_display: BTreeSet<String>,
    /// The restore of a saved session last seen; one replaces every tab.
    workspace_restore_generation: u64,
}

impl AutomationController {
    /// Seconds a run's agent may take to say anything at all before the run counts as failed:
    /// long enough for a slow CLI to come up, short enough that a dialog nobody answers does not
    /// hold the automation for hours.
    pub const START_TIMEOUT_SECONDS: i64 = 180;
    pub const WAITING_FOR_DISPLAY_MESSAGE: &'static str = "Waiting for a display to wake.";
    /// How often the host calls [`Self::tick`].
    pub const CHECK_INTERVAL: Duration = Duration::from_secs(30);
    /// How often the host calls [`Self::retry_waiting_terminals`] while runs wait.
    pub const DISPLAY_RETRY_INTERVAL: Duration = Duration::from_secs(15);
    /// Why a run due while the machine slept is skipped; the Swift wording on macOS.
    pub const MISSED_MESSAGE: &'static str = if cfg!(target_os = "macos") {
        "It was due while the Mac slept or Soprano was closed, and is past its grace period."
    } else {
        "It was due while the computer slept or Soprano was closed, and is past its grace period."
    };

    pub fn new(
        store: AutomationStore,
        config: ConfigStore,
        environment: AutomationEnvironment,
        host: &mut dyn AutomationHost,
    ) -> Self {
        let worker = Worker::new(environment.wake.clone());
        let mut controller = Self {
            store,
            config,
            environment,
            worker,
            waiting_for_display: BTreeSet::new(),
            workspace_restore_generation: host.workspace_restore_generation(),
        };
        // Their agents went with the Soprano that quit; a restored window resumes the
        // conversation as an ordinary agent.
        controller.forget_tabs("Soprano quit before the run finished.", true);
        controller
    }

    /// Pane and tab ids start over when a session is restored, at launch or from a saved one,
    /// so no run keeps the ids it had: by now they may name someone else's tab, which following
    /// the run, Open or a reused session would take over. An open run's agent went with its
    /// tab.
    fn forget_tabs(&mut self, message: &str, even_unopened: bool) {
        let now = self.now();
        let affected: Vec<String> = self
            .store
            .all_runs()
            .iter()
            .filter(|run| run.target().is_some() || (even_unopened && !run.status.is_final()))
            .map(|run| run.id.clone())
            .collect();
        for id in affected {
            self.waiting_for_display.remove(&id);
            self.store.update(&id, |run| {
                if !run.status.is_final() {
                    run.status = RunStatus::Failed;
                    run.finished_at = Some(run.finished_at.unwrap_or(now));
                    run.message = Some(message.to_owned());
                }
                run.pane_id = None;
                run.tab_id = None;
            });
        }
    }

    fn now(&self) -> DateTime<Utc> {
        self.environment.clock.now()
    }

    // MARK: - Reading

    pub fn store(&self) -> &AutomationStore {
        &self.store
    }

    pub fn store_mut(&mut self) -> &mut AutomationStore {
        &mut self.store
    }

    pub fn config(&self) -> &ConfigStore {
        &self.config
    }

    pub fn clock(&self) -> &Arc<dyn Clock> {
        &self.environment.clock
    }

    /// Changes with every run or schedule change (not with `settings.json`, which the config
    /// store reports itself).
    pub fn revision(&self) -> u64 {
        self.store.revision()
    }

    pub fn automations(&self) -> Vec<Automation> {
        self.config.resolved().automations
    }

    /// Every id under `automations` in settings.json, including entries the file rejected, so
    /// a new automation never takes over one of them.
    pub fn taken_ids(&self) -> BTreeSet<String> {
        self.config.config().automations.map(|entries| entries.into_keys().collect()).unwrap_or_default()
    }

    pub fn automation(&self, id: &str) -> Option<Automation> {
        self.automations().into_iter().find(|automation| automation.id == id)
    }

    /// Newest first.
    pub fn runs(&self, automation_id: &str) -> Vec<AutomationRun> {
        self.store.runs(automation_id)
    }

    pub fn run(&self, run_id: &str) -> Option<&AutomationRun> {
        self.store.run(run_id)
    }

    pub fn last_run(&self, automation_id: &str) -> Option<&AutomationRun> {
        self.store.last_run(automation_id)
    }

    /// When the automation runs next, or `None` while it is paused.
    pub fn next_run_date(&self, automation_id: &str) -> Option<DateTime<Utc>> {
        let automation = self.automation(automation_id).filter(|a| a.enabled)?;
        let zone = self.environment.clock.time_zone();
        if let Some(state) = self.store.schedules().get(automation_id)
            && state.signature == scheduling::signature(&automation, zone)
        {
            return state.next_run_at;
        }
        scheduling::next_occurrence(&automation, self.now(), zone)
    }

    /// Whether the run's tab is still open in this Soprano.
    pub fn is_live(&self, run: &AutomationRun, host: &dyn AutomationHost) -> bool {
        run.target().is_some_and(|target| host.tab_exists(&target))
    }

    pub fn run_title(name: &str, number: i64) -> String {
        format!("{name} #{number}")
    }

    // MARK: - Editing

    /// Writes the automation to `settings.json`; the config store's reload brings it back as
    /// configuration.
    pub fn save(&self, automation: &Automation) -> bool {
        self.config.write(automation.config_object(), &["automations", &automation.id])
    }

    pub fn set_enabled(&self, automation_id: &str, enabled: bool) -> bool {
        if self.automation(automation_id).is_none() {
            return false;
        }
        if enabled {
            self.config.remove(&["automations", automation_id, "enabled"])
        } else {
            self.config.write(false, &["automations", automation_id, "enabled"])
        }
    }

    /// Removes the automation and its run history. Windows of runs still open stay, as
    /// ordinary agents again, and so do worktrees runs left work in.
    pub fn delete(&mut self, host: &mut dyn AutomationHost, automation_id: &str) -> bool {
        if !self.config.remove(&["automations", automation_id]) {
            return false;
        }
        for run in self.store.runs(automation_id) {
            self.waiting_for_display.remove(&run.id);
            if let Some(target) = run.target()
                && host
                    .agent(&target)
                    .is_some_and(|agent| agent.automation_run_id.as_deref() == Some(&run.id))
            {
                host.set_agent_run_id(&target, None);
            }
        }
        self.store.remove_all(automation_id);
        true
    }

    /// Starts a run now, skipping the precheck: the person asking is the check.
    pub fn run_now(&mut self, host: &mut dyn AutomationHost, automation_id: &str) {
        let Some(automation) = self.automation(automation_id) else { return };
        self.begin(host, &automation, RunTrigger::Manual, None);
    }

    /// Shows the run's agent: its tab while it is open, or its conversation resumed in a new
    /// window when the run's window was closed, which the run then keeps so opening it again
    /// returns there instead of starting a second agent on the same conversation. False when
    /// there is neither.
    pub fn open_run(&mut self, host: &mut dyn AutomationHost, run_id: &str) -> bool {
        let Some(run) = self.store.run(run_id).cloned() else { return false };
        if let Some(target) = run.target()
            && host.tab_exists(&target)
        {
            self.store.update(run_id, |run| run.viewed = true);
            host.focus_tab(&target);
            return true;
        }
        let Some(conversation) = run.conversation.clone() else { return false };
        if !AgentConversation::supports(&run.profile_id) {
            return false;
        }
        let automation = self.automation(&run.automation_id);
        let title = Self::run_title(automation.as_ref().map_or(&run.automation_id, |a| &a.name), run.number);
        // A worktree the run left untouched is gone; its repository is not.
        let candidates = [
            conversation.cwd.clone(),
            Some(run.folder.clone()),
            run.worktree.as_ref().map(|w| w.repository.clone()),
            automation.as_ref().map(|a| a.folder.clone()),
        ];
        let cwd = candidates
            .into_iter()
            .flatten()
            .find(|path| Path::new(path).exists())
            .unwrap_or_else(|| run.folder.clone());
        let launch = AgentLaunch {
            prompt: String::new(),
            model: automation.as_ref().and_then(|a| a.model.clone()),
            skips_approvals: true,
            ..AgentLaunch::default()
        };
        let Some(target) =
            host.open_run_window(&title, &run.profile_id, &cwd, None, launch, Some(conversation))
        else {
            return false;
        };
        self.store.update(run_id, |run| {
            run.pane_id = Some(target.pane_id.clone());
            run.tab_id = Some(target.tab_id.clone());
            run.viewed = true;
        });
        host.focus_tab(&target);
        true
    }

    // MARK: - Schedules

    /// Starts every automation that came due, records the ones that are too late, and fails
    /// runs whose agent never said anything.
    pub fn tick(&mut self, host: &mut dyn AutomationHost, now: DateTime<Utc>) {
        let automations = self.automations();
        let ids: BTreeSet<&str> = automations.iter().map(|a| a.id.as_str()).collect();
        let stale: Vec<String> =
            self.store.schedules().keys().filter(|id| !ids.contains(id.as_str())).cloned().collect();
        for id in stale {
            self.store.set_schedule(&id, None);
        }
        let zone = self.environment.clock.time_zone();
        for automation in &automations {
            let (state, decision) =
                scheduling::evaluate(automation, self.store.schedules().get(&automation.id), now, zone);
            self.store.set_schedule(&automation.id, Some(state));
            match decision {
                Some(Decision::Run { scheduled_for }) => {
                    self.begin(host, automation, RunTrigger::Scheduled, Some(scheduled_for))
                }
                Some(Decision::Missed { scheduled_for }) => {
                    self.record(automation, Some(scheduled_for), RunStatus::Skipped, Self::MISSED_MESSAGE)
                }
                None => {}
            }
        }
        for run in self.store.open_runs() {
            if run.status != RunStatus::Starting || self.waiting_for_display.contains(&run.id) {
                continue;
            }
            let Some(target) = run.target() else { continue };
            let still_starting =
                host.agent(&target).is_some_and(|agent| agent.status == AgentStatus::Starting);
            if still_starting && (now - run.started_at).num_seconds() > Self::START_TIMEOUT_SECONDS {
                let message = format!(
                    "The agent didn't start within {} minutes. Open its window to see what it's waiting for.",
                    Self::START_TIMEOUT_SECONDS / 60
                );
                self.finish(host, &run.id, RunStatus::Failed, Some(message), None);
            }
        }
    }

    fn record(
        &mut self,
        automation: &Automation,
        scheduled_for: Option<DateTime<Utc>>,
        status: RunStatus,
        message: &str,
    ) {
        let now = self.now();
        let mut run = AutomationRun::new(
            new_run_id(),
            &automation.id,
            self.store.next_run_number(&automation.id),
            RunTrigger::Scheduled,
            now,
            status,
            &automation.agent_id,
            &automation.folder,
        );
        run.scheduled_for = scheduled_for;
        run.finished_at = Some(now);
        run.message = Some(message.to_owned());
        self.store.insert(run);
    }

    // MARK: - Starting runs

    fn begin(
        &mut self,
        host: &mut dyn AutomationHost,
        automation: &Automation,
        trigger: RunTrigger,
        scheduled_for: Option<DateTime<Utc>>,
    ) {
        if trigger == RunTrigger::Scheduled
            && let Some(open) = self.store.runs(&automation.id).into_iter().find(|run| !run.status.is_final())
        {
            let message = format!("Run #{} was still working.", open.number);
            self.record(automation, scheduled_for, RunStatus::Skipped, &message);
            return;
        }

        let mut run = AutomationRun::new(
            new_run_id(),
            &automation.id,
            self.store.next_run_number(&automation.id),
            trigger,
            self.now(),
            RunStatus::Starting,
            &automation.agent_id,
            &automation.folder,
        );
        run.scheduled_for = scheduled_for;
        let run_id = run.id.clone();
        self.store.insert(run);

        if !Path::new(&automation.folder).is_dir() {
            let message = format!(
                "{} is not a folder.",
                soprano_config::config_file::abbreviating_home(&automation.folder)
            );
            self.finish(host, &run_id, RunStatus::Skipped, Some(message), None);
            return;
        }

        let precheck = automation.precheck.clone().filter(|_| trigger == RunTrigger::Scheduled);
        if automation.session == AutomationSession::Reuse
            && self.reusable_run(host, automation, &run_id).is_some()
        {
            // The precheck decides over a reused agent too; its answer arrives later, when the
            // agent may be gone, busy or closed.
            if let Some(command) = precheck {
                let timeout = precheck_timeout(automation);
                let shell = self.environment.shell.clone();
                let folder = automation.folder.clone();
                let automation = Box::new(automation.clone());
                self.worker.run(move || {
                    let outcome = precheck::run(&command, &folder, timeout, &shell, precheck::OUTPUT_LIMIT);
                    Some(Completion::ReusePrecheck { run_id, automation, outcome })
                });
                return;
            }
            if self.hand_over(host, &run_id, automation) {
                return;
            }
        }

        self.prepare(&run_id, automation, precheck);
    }

    /// Gives the run's prompt to the agent of the automation's last run, which the run then
    /// follows. False when there is none to take it.
    fn hand_over(&mut self, host: &mut dyn AutomationHost, run_id: &str, automation: &Automation) -> bool {
        let Some(previous) = self.reusable_run(host, automation, run_id) else { return false };
        let Some(target) = previous.target() else { return false };
        if !host.send_prompt_to(&target, &automation.prompt) {
            return false;
        }
        self.store.update(&previous.id, |run| {
            run.pane_id = None;
            run.tab_id = None;
        });
        self.store.update(run_id, |run| {
            run.pane_id = Some(target.pane_id.clone());
            run.tab_id = Some(target.tab_id.clone());
            run.conversation = previous.conversation.clone();
            run.viewed = previous.viewed;
            run.saw_work = true;
            run.status = RunStatus::Running;
        });
        host.set_agent_run_id(&target, Some(run_id.to_owned()));
        true
    }

    /// Runs the precheck, makes the worktree and records folder trust off the main thread;
    /// [`Self::drain`] then opens the run's agent.
    fn prepare(&mut self, run_id: &str, automation: &Automation, precheck: Option<String>) {
        let timeout = precheck_timeout(automation);
        let worktree_base = match &automation.workspace {
            AutomationWorkspace::Worktree { base_branch } => Some(base_branch.clone()),
            AutomationWorkspace::Folder => None,
        };
        let worktree_directory = self.environment.worktree_directory.clone();
        let claude_config =
            self.environment.claude_config.clone().filter(|_| automation.agent_id == "claude-code");
        let open_code_command = (automation.agent_id == "opencode" && automation.model.is_some())
            .then(|| AgentCatalog::shared().profile("opencode").map(|profile| profile.command))
            .flatten();
        let date = self.now();
        let zone = self.environment.clock.time_zone();
        let shell = self.environment.shell.clone();
        let run_id = run_id.to_owned();
        let automation = Box::new(automation.clone());
        self.worker.run(move || {
            let folder = automation.folder.as_str();
            let mut preparation = Preparation {
                precheck: precheck
                    .map(|command| precheck::run(&command, folder, timeout, &shell, precheck::OUTPUT_LIMIT)),
                ..Preparation::default()
            };
            let proceeds = preparation.precheck.as_ref().is_none_or(PrecheckOutcome::passed);
            if proceeds && let Some(base_branch) = worktree_base {
                match worktree::create(
                    folder,
                    &automation.id,
                    base_branch.as_deref(),
                    date,
                    zone,
                    &worktree_directory,
                ) {
                    Ok(checkout) => preparation.checkout = Some(checkout),
                    Err(failure) => preparation.failure = Some(failure.to_string()),
                }
            }
            let working_directory = preparation
                .checkout
                .as_ref()
                .map_or_else(|| folder.to_owned(), |checkout| checkout.working_directory.clone());
            if proceeds && preparation.failure.is_none() {
                if let Some(config) = claude_config {
                    claude_trust::trust(&working_directory, &config, Duration::from_secs(2));
                }
                if let Some(command) = open_code_command {
                    preparation.starts_open_code_server =
                        Self::open_code_has_private_server(&command, &working_directory, &shell);
                    if preparation.starts_open_code_server {
                        preparation.open_code_agents =
                            Self::open_code_primary_agents(&command, &working_directory, &shell);
                    }
                }
            }
            Some(Completion::Prepared { run_id, automation, preparation })
        });
    }

    /// OpenCode 2 lists `--standalone` in its help; OpenCode 1.x rejects the flag. A CLI the
    /// login shell cannot run is taken for the current major. Blocks; call it off the main
    /// thread.
    pub fn open_code_has_private_server(command: &str, folder: &str, shell: &str) -> bool {
        let script = precheck::exec_script(shell, command, "--help", false);
        let help = precheck::run(&script, folder, Duration::from_secs(20), shell, precheck::OUTPUT_LIMIT);
        if !help.passed() {
            return true;
        }
        help.output.contains("--standalone")
    }

    /// The agents a session can start with. OpenCode 2's terminal UI prefers an agent's own
    /// model over the top-level one, so a run's model is pinned on each of them. Blocks; call it
    /// off the main thread.
    pub fn open_code_primary_agents(command: &str, folder: &str, shell: &str) -> Vec<String> {
        let script = precheck::exec_script(shell, command, "debug agents --standalone", true);
        let listed = precheck::run(&script, folder, Duration::from_secs(30), shell, usize::MAX);
        // Login files may print before the command; the list is the JSON array.
        if !listed.passed() {
            return Vec::new();
        }
        let Some(start) = listed.output.find('[') else { return Vec::new() };
        let Ok(serde_json::Value::Array(agents)) = serde_json::from_str(&listed.output[start..]) else {
            return Vec::new();
        };
        agents
            .iter()
            .filter_map(|agent| {
                let id = agent.get("id")?.as_str()?;
                let hidden = agent.get("hidden").and_then(serde_json::Value::as_bool) == Some(true);
                let mode = agent.get("mode").and_then(serde_json::Value::as_str);
                (!hidden && matches!(mode, Some("primary" | "all"))).then(|| id.to_owned())
            })
            .collect()
    }

    /// Handles what the background thread finished. Call it on the host's thread whenever the
    /// environment's `wake` fired; it does nothing when nothing waits.
    pub fn drain(&mut self, host: &mut dyn AutomationHost) {
        while let Some(completion) = self.worker.next() {
            match completion {
                Completion::ReusePrecheck { run_id, automation, outcome } => {
                    if !outcome.passed() {
                        self.finish(host, &run_id, RunStatus::Skipped, Some(outcome.summary()), None);
                        continue;
                    }
                    // Its automation was deleted while the precheck ran.
                    if self.store.run(&run_id).is_none() {
                        continue;
                    }
                    if !self.hand_over(host, &run_id, &automation) {
                        self.prepare(&run_id, &automation, None);
                    }
                }
                Completion::Prepared { run_id, automation, preparation } => {
                    self.prepared(host, &run_id, &automation, preparation)
                }
                Completion::Reported { run_id, reply, untouched } => {
                    self.store.update(&run_id, |run| {
                        if let Some(reply) = AutomationRun::trimmed_output(reply.as_deref()) {
                            run.output = Some(reply);
                        }
                        if untouched && let Some(worktree) = &mut run.worktree {
                            worktree.removed = true;
                        }
                    });
                }
            }
        }
    }

    fn prepared(
        &mut self,
        host: &mut dyn AutomationHost,
        run_id: &str,
        automation: &Automation,
        preparation: Preparation,
    ) {
        if let Some(precheck) = preparation.precheck.as_ref().filter(|p| !p.passed()) {
            self.finish(host, run_id, RunStatus::Skipped, Some(precheck.summary()), None);
            return;
        }
        if let Some(failure) = preparation.failure {
            self.finish(host, run_id, RunStatus::Failed, Some(failure), None);
            return;
        }
        // Its automation was deleted while the run was being prepared.
        if self.store.run(run_id).is_none() {
            self.discard(preparation.checkout.as_ref());
            return;
        }
        let mut working_directory = automation.folder.clone();
        if let Some(checkout) = &preparation.checkout {
            working_directory = checkout.working_directory.clone();
            self.store.update(run_id, |run| {
                run.worktree = Some(checkout.worktree.clone());
                run.folder = checkout.working_directory.clone();
            });
        }
        let Some(number) = self.store.run(run_id).map(|run| run.number) else { return };
        let launch = AgentLaunch {
            prompt: automation.prompt.clone(),
            model: automation.model.clone(),
            skips_approvals: true,
            starts_private_server: preparation.starts_open_code_server,
            model_agents: preparation.open_code_agents.clone(),
        };
        let opened = host.open_run_window(
            &Self::run_title(&automation.name, number),
            &automation.agent_id,
            &working_directory,
            Some(run_id.to_owned()),
            launch,
            None,
        );
        let Some(target) = opened else {
            self.discard(preparation.checkout.as_ref());
            let had_checkout = preparation.checkout.is_some();
            self.store.update(run_id, |run| {
                if let Some(worktree) = &mut run.worktree {
                    worktree.removed = had_checkout;
                }
            });
            self.finish(
                host,
                run_id,
                RunStatus::Failed,
                Some("Soprano couldn't open a window for the run.".into()),
                None,
            );
            return;
        };
        self.store.update(run_id, |run| {
            run.pane_id = Some(target.pane_id.clone());
            run.tab_id = Some(target.tab_id.clone());
        });
        self.start_terminal(host, run_id, &target);
    }

    /// Removes a worktree made for a run that never started in it.
    fn discard(&self, checkout: Option<&Checkout>) {
        let Some(worktree) = checkout.map(|c| c.worktree.clone()) else { return };
        self.worker.run(move || {
            worktree::remove(&worktree);
            None
        });
    }

    /// Starts the run's terminal, or waits for a display to wake: the terminal renderer draws
    /// on one, so a run due at night begins when a display wakes. The run counts from the
    /// terminal's start, so a night's wait does not read as an agent that never came up.
    fn start_terminal(&mut self, host: &mut dyn AutomationHost, run_id: &str, target: &TerminalTarget) {
        if host.start_terminal(target) {
            self.waiting_for_display.remove(run_id);
            let now = self.now();
            self.store.update(run_id, |run| {
                run.started_at = now;
                if run.message.as_deref() == Some(Self::WAITING_FOR_DISPLAY_MESSAGE) {
                    run.message = None;
                }
            });
            return;
        }
        self.waiting_for_display.insert(run_id.to_owned());
        self.store.update(run_id, |run| run.message = Some(Self::WAITING_FOR_DISPLAY_MESSAGE.into()));
    }

    /// Whether runs wait for a display; the host then calls [`Self::retry_waiting_terminals`]
    /// every [`Self::DISPLAY_RETRY_INTERVAL`].
    pub fn is_waiting_for_display(&self) -> bool {
        !self.waiting_for_display.is_empty()
    }

    pub fn retry_waiting_terminals(&mut self, host: &mut dyn AutomationHost) {
        if !host.display_is_awake() {
            return;
        }
        for run_id in self.waiting_for_display.clone() {
            let target =
                self.store.run(&run_id).filter(|run| !run.status.is_final()).and_then(AutomationRun::target);
            match target {
                Some(target) => self.start_terminal(host, &run_id, &target),
                None => {
                    self.waiting_for_display.remove(&run_id);
                }
            }
        }
    }

    /// The newest run of a reuse automation whose agent is still open and done with its turn.
    fn reusable_run(
        &self,
        host: &dyn AutomationHost,
        automation: &Automation,
        run_id: &str,
    ) -> Option<AutomationRun> {
        for run in self.store.runs(&automation.id) {
            if run.id == run_id {
                continue;
            }
            let Some(target) = run.target() else { continue };
            let Some(agent) = host.agent(&target).filter(|agent| agent.profile_id == automation.agent_id)
            else {
                continue;
            };
            let is_done = agent.status == AgentStatus::Idle
                || (agent.status == AgentStatus::Waiting
                    && !agent.waiting_reason.unwrap_or(AgentWaitingReason::TurnEnded).blocks());
            return is_done.then_some(run);
        }
        None
    }

    // MARK: - Following runs

    /// Moves every open run along with what its agent reports, and forgets the tab of a
    /// finished run once it is closed. Call after every workspace model change.
    pub fn workspace_changed(&mut self, host: &mut dyn AutomationHost) {
        let generation = host.workspace_restore_generation();
        if generation != self.workspace_restore_generation {
            self.workspace_restore_generation = generation;
            // A run still being prepared opens its window afterwards.
            self.forget_tabs("A saved session replaced the run's window before it finished.", false);
        }
        self.follow_runs(host);
    }

    fn follow_runs(&mut self, host: &mut dyn AutomationHost) {
        let closed: Vec<String> = self
            .store
            .all_runs()
            .iter()
            .filter(|run| {
                run.status.is_final() && run.target().is_some_and(|target| !host.tab_exists(&target))
            })
            .map(|run| run.id.clone())
            .collect();
        for id in closed {
            self.store.update(&id, |run| {
                run.pane_id = None;
                run.tab_id = None;
            });
        }
        for run in self.store.open_runs() {
            let Some(target) = run.target() else { continue };
            let tab_exists = host.tab_exists(&target);
            let agent = host.agent(&target).cloned();
            let is_looked_at = host.is_window_opened_by_user(&target);
            let conversation = agent.as_ref().and_then(|agent| agent.conversation.clone());
            let conversation_changed = conversation.is_some() && conversation != run.conversation;
            if (is_looked_at && !run.viewed) || conversation_changed {
                self.store.update(&run.id, |run| {
                    if is_looked_at {
                        run.viewed = true;
                    }
                    if let Some(conversation) = conversation {
                        run.conversation = Some(conversation);
                    }
                });
            }
            let observation = Observation {
                tab_exists,
                has_agent: agent.is_some(),
                status: agent.as_ref().map(|agent| agent.status),
                waiting_reason: agent.as_ref().and_then(|agent| agent.waiting_reason),
                message: agent.as_ref().and_then(|agent| agent.last_message.clone()),
            };
            let Some(current) = self.store.run(&run.id).cloned() else { continue };
            if let Some(change) = tracking::change(&current, &observation) {
                self.apply(host, change, &current, &target);
            }
        }
    }

    fn apply(
        &mut self,
        host: &mut dyn AutomationHost,
        change: Change,
        run: &AutomationRun,
        target: &TerminalTarget,
    ) {
        let name = self.automation_name(&run.automation_id);
        match change {
            Change::Running => self.store.update(&run.id, |run| {
                run.status = RunStatus::Running;
                run.saw_work = true;
                run.message = None;
            }),
            Change::NeedsInput { message } => {
                self.store.update(&run.id, |run| {
                    run.status = RunStatus::NeedsInput;
                    run.message = message.clone();
                });
                let reason = host.agent(target).and_then(|agent| agent.waiting_reason);
                let title = if reason == Some(AgentWaitingReason::Approval) {
                    format!("{name} needs approval")
                } else {
                    format!("{name} has a question")
                };
                let body = message
                    .as_deref()
                    .and_then(summarize)
                    .unwrap_or_else(|| "Open the run to answer.".into());
                host.notify(&title, &body, &run.id);
            }
            Change::Failed { message } => self.finish(host, &run.id, RunStatus::Failed, Some(message), None),
            Change::Completed => self.complete(host, run, target, &name),
        }
    }

    /// Keeps what the agent said, closes the run's window when nobody opened it, and then takes
    /// back a worktree the run left untouched. A window that stays open keeps its worktree: the
    /// agent there still works in it.
    fn complete(
        &mut self,
        host: &mut dyn AutomationHost,
        run: &AutomationRun,
        target: &TerminalTarget,
        name: &str,
    ) {
        let agent = host.agent(target).cloned();
        let said =
            agent.as_ref().and_then(|agent| agent.last_message.clone()).or_else(|| host.visible_text(target));
        let fallback = AutomationRun::trimmed_output(said.as_deref());
        let conversation = agent.and_then(|agent| agent.conversation).or_else(|| run.conversation.clone());
        self.finish(host, &run.id, RunStatus::Completed, None, fallback.clone());
        let body =
            fallback.as_deref().and_then(summarize).unwrap_or_else(|| "Its report is in Automations.".into());
        host.notify(&format!("{name} is done"), &body, &run.id);

        let reuses =
            self.automation(&run.automation_id).is_some_and(|a| a.session == AutomationSession::Reuse);
        let closes_window = !run.viewed && !reuses;
        if closes_window {
            host.close_window(target);
            self.store.update(&run.id, |run| {
                run.pane_id = None;
                run.tab_id = None;
            });
        }

        let worktree = if closes_window { run.worktree.clone() } else { None };
        let profile_id = run.profile_id.clone();
        let home = self.environment.home.clone();
        let run_id = run.id.clone();
        self.worker.run(move || {
            let reply =
                conversation.and_then(|conversation| Self::final_reply(&profile_id, &conversation, &home));
            let untouched = worktree.as_ref().is_some_and(worktree::is_untouched);
            if untouched && let Some(worktree) = &worktree {
                worktree::remove(worktree);
            }
            Some(Completion::Reported { run_id, reply, untouched })
        });
    }

    fn finish(
        &mut self,
        host: &mut dyn AutomationHost,
        run_id: &str,
        status: RunStatus,
        message: Option<String>,
        output: Option<String>,
    ) {
        self.waiting_for_display.remove(run_id);
        let now = self.now();
        self.store.update(run_id, |run| {
            run.status = status;
            run.finished_at = Some(now);
            run.message = message.clone();
            if let Some(output) = output {
                run.output = Some(output);
            }
        });
        // A window left open after the run is an ordinary agent again, whose banners name its
        // pane like any other.
        if let Some(target) = self.store.run(run_id).and_then(AutomationRun::target)
            && host.agent(&target).is_some_and(|agent| agent.automation_run_id.as_deref() == Some(run_id))
        {
            host.set_agent_run_id(&target, None);
        }
        if status != RunStatus::Failed {
            return;
        }
        let Some(automation_id) = self.store.run(run_id).map(|run| run.automation_id.clone()) else { return };
        let name = self.automation_name(&automation_id);
        let body =
            message.as_deref().and_then(summarize).unwrap_or_else(|| "Open the run to see why.".into());
        host.notify(&format!("{name} failed"), &body, run_id);
    }

    fn automation_name(&self, automation_id: &str) -> String {
        self.automation(automation_id).map_or_else(|| automation_id.to_owned(), |a| a.name)
    }

    /// The agent's last reply from its transcript, for the CLIs that write one.
    pub fn final_reply(profile_id: &str, conversation: &AgentConversation, home: &Path) -> Option<String> {
        let source = AgentTranscriptSource::new(profile_id, Some(conversation))?;
        let timeline = source.make_reader(home).read_appended()?;
        timeline.items.iter().rev().find_map(|item| match &item.kind {
            TimelineItemKind::Reply(text) => Some(text.clone()),
            _ => None,
        })
    }
}

fn precheck_timeout(automation: &Automation) -> Duration {
    Duration::from_secs(u64::try_from(automation.precheck_timeout_seconds).unwrap_or(0))
}

/// Run ids are uppercase UUIDs, as the Swift app made them.
fn new_run_id() -> String {
    uuid::Uuid::new_v4().to_string().to_uppercase()
}
