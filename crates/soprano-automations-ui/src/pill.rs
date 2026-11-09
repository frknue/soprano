//! The pills of the Automations page (`AutomationPill`): a run's status, and an automation's
//! state (its live run, else Paused, Failed after a failed last run, else Active).

use std::time::SystemTime;

use chrono::{DateTime, Utc};
use soprano_automations::{AutomationRun, RunStatus};
use soprano_config::Automation;
use soprano_ui::{IconName, StatusPillSpec, StatusTone};

fn pill(
    label: &'static str,
    icon: IconName,
    tone: StatusTone,
    since: Option<DateTime<Utc>>,
) -> StatusPillSpec {
    StatusPillSpec { label, icon, tone, since: since.map(SystemTime::from) }
}

/// A run's status; a running run counts from `since`.
pub fn run(status: RunStatus, since: Option<DateTime<Utc>>) -> StatusPillSpec {
    match status {
        RunStatus::Starting => pill("Starting", IconName::STATUS_WORKING, StatusTone::Working, None),
        RunStatus::Running => pill("Running", IconName::STATUS_WORKING, StatusTone::Working, since),
        RunStatus::NeedsInput => pill("Input", IconName::STATUS_INPUT, StatusTone::Input, None),
        RunStatus::Completed => pill("Done", IconName::STATUS_DONE, StatusTone::Done, None),
        RunStatus::Failed => pill("Failed", IconName::STATUS_FAILED, StatusTone::Failed, None),
        RunStatus::Skipped => pill("Skipped", IconName::Minus, StatusTone::Muted, None),
    }
}

/// A run's pill as its report shows it: a running run counts from its start.
pub fn for_run(run: &AutomationRun) -> StatusPillSpec {
    self::run(run.status, (run.status == RunStatus::Running).then_some(run.started_at))
}

/// An automation's state: its live run, else Paused, Failed after a failed last run, else
/// Active.
pub fn state(automation: &Automation, last_run: Option<&AutomationRun>) -> StatusPillSpec {
    if let Some(last_run) = last_run.filter(|run| !run.status.is_final()) {
        return for_run(last_run);
    }
    if !automation.enabled {
        return pill("Paused", IconName::Pause, StatusTone::Muted, None);
    }
    if last_run.is_some_and(|run| run.status == RunStatus::Failed) {
        return run(RunStatus::Failed, None);
    }
    pill("Active", IconName::ALARM, StatusTone::Done, None)
}

#[cfg(test)]
mod tests {
    use soprano_automations::RunTrigger;
    use soprano_config::{AutomationSession, AutomationWorkspace, CronSchedule};

    use super::*;

    fn automation() -> Automation {
        Automation {
            id: "audit".into(),
            name: "Weekday repo audit".into(),
            agent_id: "omp".into(),
            folder: "/tmp".into(),
            prompt: "Review the repository health and summarize what needs attention.".into(),
            schedule: CronSchedule::parse("0 9 * * 1-5").expect("schedule"),
            enabled: true,
            workspace: AutomationWorkspace::Folder,
            session: AutomationSession::Fresh,
            grace_minutes: 720,
            precheck: None,
            precheck_timeout_seconds: 60,
            model: None,
        }
    }

    fn run(status: RunStatus) -> AutomationRun {
        AutomationRun::new("run", "audit", 1, RunTrigger::Manual, Utc::now(), status, "omp", "/tmp")
    }

    #[test]
    fn an_automations_state_pill_shows_its_live_run_else_paused_failed_or_active() {
        let mut automation = automation();
        assert_eq!(state(&automation, None).label, "Active");
        assert_eq!(state(&automation, Some(&run(RunStatus::Failed))).label, "Failed");
        assert_eq!(state(&automation, Some(&run(RunStatus::Running))).label, "Running");
        assert_eq!(state(&automation, Some(&run(RunStatus::NeedsInput))).tone, StatusTone::Input);
        automation.enabled = false;
        assert_eq!(state(&automation, Some(&run(RunStatus::Completed))).label, "Paused");
        // A run still going outranks the pause.
        assert_eq!(state(&automation, Some(&run(RunStatus::Starting))).label, "Starting");
    }

    #[test]
    fn only_a_running_run_counts_its_time() {
        assert!(for_run(&run(RunStatus::Running)).since.is_some());
        assert!(for_run(&run(RunStatus::Starting)).since.is_none());
    }
}
