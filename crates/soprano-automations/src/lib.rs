//! soprano-automations: runs the automations `settings.json` declares (`Automations/*` except
//! the config entry, which lives in `soprano-config`): schedules and missed runs, prechecks,
//! worktrees, Claude Code's folder trust, following a run's agent to the end of its turn, and
//! the run history in `<data dir>/automations.json`. No UI; see docs/rust-rewrite/PLAN.md.

pub mod claude_trust;
pub mod clock;
pub mod controller;
pub mod host;
pub mod precheck;
pub mod run;
pub mod scheduling;
pub mod store;
pub mod tracking;
mod worker;
pub mod worktree;

pub use clock::{Clock, FixedClock, SystemClock};
pub use controller::{AutomationController, AutomationEnvironment};
pub use host::AutomationHost;
pub use precheck::PrecheckOutcome;
pub use run::{AutomationRun, RunStatus, RunTrigger, RunWorktree};
pub use scheduling::{Decision, ScheduleState};
pub use store::AutomationStore;
pub use tracking::{Change, Observation};
pub use worktree::{Checkout, WorktreeFailure};
