//! How a run follows its agent: what the agent reports moves the run along
//! (`Automations/AutomationRunTracking.swift`). Plain values, so the rules read, and test,
//! without a terminal.

use soprano_types::{AgentStatus, AgentWaitingReason};

use crate::run::{AutomationRun, RunStatus};

/// The run's tab as the workspace has it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Observation {
    /// False once the tab is gone: someone closed it.
    pub tab_exists: bool,
    /// False once the agent exited and its tab fell back to a shell.
    pub has_agent: bool,
    pub status: Option<AgentStatus>,
    pub waiting_reason: Option<AgentWaitingReason>,
    pub message: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Change {
    Running,
    NeedsInput { message: Option<String> },
    Completed,
    Failed { message: String },
}

/// What `observation` means for `run`, or `None` when nothing changed.
///
/// A finished turn completes the run: the agent got its prompt at launch, so its first turn is
/// the run. Every CLI reports a finished turn as needs-input (omp and OpenCode say so, Claude
/// Code's Stop and Codex's turn notification read as one), and some say they are working only
/// when hooks are installed, so it counts without having seen the work. READY never completes
/// a run: CLIs report it when they come up, and Claude Code again after compacting its context
/// in the middle of work.
pub fn change(run: &AutomationRun, observation: &Observation) -> Option<Change> {
    if run.status.is_final() {
        return None;
    }
    if !observation.tab_exists {
        return Some(Change::Failed { message: "Its window was closed before the run finished.".into() });
    }
    let status = match observation.status {
        Some(status) if observation.has_agent && status != AgentStatus::Stopped => status,
        _ => {
            let message = if run.saw_work {
                "The agent exited before it finished its turn."
            } else {
                "The agent exited before it started working."
            };
            return Some(Change::Failed { message: message.into() });
        }
    };
    match status {
        AgentStatus::Starting | AgentStatus::Idle | AgentStatus::Stopped => None,
        AgentStatus::Running => (run.status != RunStatus::Running).then_some(Change::Running),
        AgentStatus::Waiting => {
            if observation.waiting_reason.unwrap_or(AgentWaitingReason::TurnEnded).blocks() {
                (run.status != RunStatus::NeedsInput)
                    .then(|| Change::NeedsInput { message: observation.message.clone() })
            } else {
                Some(Change::Completed)
            }
        }
        AgentStatus::Error => Some(Change::Failed {
            message: observation.message.clone().unwrap_or_else(|| "The agent stopped with an error.".into()),
        }),
    }
}

#[cfg(test)]
mod tests {
    use chrono::Utc;

    use super::*;
    use crate::run::RunTrigger;

    fn run(status: RunStatus, saw_work: bool) -> AutomationRun {
        let mut run =
            AutomationRun::new("run-1", "audit", 1, RunTrigger::Scheduled, Utc::now(), status, "omp", "/tmp");
        run.saw_work = saw_work;
        run
    }

    fn starting() -> AutomationRun {
        run(RunStatus::Starting, false)
    }

    fn working() -> AutomationRun {
        run(RunStatus::Running, true)
    }

    fn agent(status: AgentStatus, reason: Option<AgentWaitingReason>, message: Option<&str>) -> Observation {
        Observation {
            tab_exists: true,
            has_agent: true,
            status: Some(status),
            waiting_reason: reason,
            message: message.map(str::to_owned),
        }
    }

    #[test]
    fn a_finished_turn_completes_the_run_even_when_the_agent_never_said_it_was_working() {
        // Codex without its hooks reports only the end of its turn.
        let finished = agent(AgentStatus::Waiting, Some(AgentWaitingReason::TurnEnded), None);
        assert_eq!(change(&starting(), &finished), Some(Change::Completed));
    }

    #[test]
    fn the_ready_an_agent_reports_when_it_comes_up_does_not_complete_the_run() {
        assert_eq!(change(&starting(), &agent(AgentStatus::Idle, None, None)), None);
    }

    #[test]
    fn ready_mid_run_does_not_complete_it_because_only_a_finished_turn_does() {
        // Claude Code starts a session again after compacting its context mid-turn; every CLI
        // reports a finished turn as needs-input instead.
        assert_eq!(change(&working(), &agent(AgentStatus::Idle, None, None)), None);
        let finished = agent(AgentStatus::Waiting, Some(AgentWaitingReason::TurnEnded), None);
        assert_eq!(change(&working(), &finished), Some(Change::Completed));
    }

    #[test]
    fn an_approval_or_question_puts_the_run_on_hold_with_what_the_agent_asked() {
        let question = agent(AgentStatus::Waiting, Some(AgentWaitingReason::Question), Some("Which branch?"));
        assert_eq!(
            change(&working(), &question),
            Some(Change::NeedsInput { message: Some("Which branch?".into()) })
        );
        let approval = agent(AgentStatus::Waiting, Some(AgentWaitingReason::Approval), None);
        assert_eq!(change(&working(), &approval), Some(Change::NeedsInput { message: None }));
    }

    #[test]
    fn a_run_already_waiting_for_an_answer_is_not_announced_again() {
        let waiting = run(RunStatus::NeedsInput, true);
        let question = agent(AgentStatus::Waiting, Some(AgentWaitingReason::Question), None);
        assert_eq!(change(&waiting, &question), None);
    }

    #[test]
    fn working_again_after_an_answer_moves_the_run_back_to_running() {
        let waiting = run(RunStatus::NeedsInput, true);
        assert_eq!(change(&waiting, &agent(AgentStatus::Running, None, None)), Some(Change::Running));
    }

    #[test]
    fn closing_the_runs_window_fails_the_run() {
        let closed = Observation {
            tab_exists: false,
            has_agent: false,
            status: None,
            waiting_reason: None,
            message: None,
        };
        assert_eq!(
            change(&working(), &closed),
            Some(Change::Failed { message: "Its window was closed before the run finished.".into() })
        );
    }

    #[test]
    fn an_agent_that_exits_before_finishing_fails_the_run_saying_how_far_it_got() {
        let exited = Observation {
            tab_exists: true,
            has_agent: false,
            status: None,
            waiting_reason: None,
            message: None,
        };
        assert_eq!(
            change(&starting(), &exited),
            Some(Change::Failed { message: "The agent exited before it started working.".into() })
        );
        assert_eq!(
            change(&working(), &exited),
            Some(Change::Failed { message: "The agent exited before it finished its turn.".into() })
        );
    }

    #[test]
    fn an_agent_error_fails_the_run_with_the_agents_message() {
        assert_eq!(
            change(&working(), &agent(AgentStatus::Error, None, Some("Rate limited"))),
            Some(Change::Failed { message: "Rate limited".into() })
        );
    }

    #[test]
    fn a_finished_run_ignores_whatever_its_agent_does_afterwards() {
        let done = run(RunStatus::Completed, true);
        assert_eq!(change(&done, &agent(AgentStatus::Running, None, None)), None);
    }
}
