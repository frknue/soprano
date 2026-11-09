//! When an automation is due, worked out from its schedule and the time its next run was last
//! set for (`Automations/AutomationScheduling.swift`). Free of timers and storage so the rules
//! read, and test, as plain values.

use chrono::{DateTime, Utc};
use chrono_tz::Tz;
use serde::{Deserialize, Serialize};
use soprano_config::Automation;

use crate::run::iso8601;

/// When an automation runs next, and the schedule that time was computed for: a changed
/// schedule, or one switched back on, counts from now.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScheduleState {
    pub signature: String,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "iso8601::option")]
    pub next_run_at: Option<DateTime<Utc>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    /// Start the run that was due at `scheduled_for`.
    Run { scheduled_for: DateTime<Utc> },
    /// The run due at `scheduled_for` is past its grace period: record it as skipped instead
    /// of starting it hours late.
    Missed { scheduled_for: DateTime<Utc> },
}

/// How far past its grace a check may land and still run: the scheduler looks every half
/// minute, so a run due right at the edge is not lost.
pub const CHECK_SLACK_SECONDS: i64 = 60;

/// The next run is kept as an absolute time, so a move to another time zone counts like an
/// edit: 9:00 is 9:00 wherever the machine is.
pub fn signature(automation: &Automation, zone: Tz) -> String {
    format!("{} {}", legacy_signature(automation), zone.name())
}

/// What builds before the time zone joined the signature saved: `<on|off> <cron>`.
fn legacy_signature(automation: &Automation) -> String {
    format!("{} {}", if automation.enabled { "on" } else { "off" }, automation.schedule.expression)
}

/// The first occurrence after `now` in `zone`, or `None` while paused or for a date that
/// never comes.
pub fn next_occurrence(automation: &Automation, now: DateTime<Utc>, zone: Tz) -> Option<DateTime<Utc>> {
    if !automation.enabled {
        return None;
    }
    automation.schedule.next_occurrence(&now.with_timezone(&zone)).map(|date| date.with_timezone(&Utc))
}

/// The state to keep after a check at `now`, and what to do. Only the latest due time runs: a
/// machine that slept through six hourly runs starts one, not six. A new, changed, or
/// re-enabled schedule counts from `now`, so editing one never starts a run that was due
/// before the edit.
pub fn evaluate(
    automation: &Automation,
    state: Option<&ScheduleState>,
    now: DateTime<Utc>,
    zone: Tz,
) -> (ScheduleState, Option<Decision>) {
    let signature = signature(automation, zone);
    let next = || next_occurrence(automation, now, zone);
    // Builds before the time zone joined the signature saved "<on|off> <cron>": that is the
    // same schedule, so a run that came due before the update still starts.
    let Some(state) =
        state.filter(|s| s.signature == signature || s.signature == legacy_signature(automation))
    else {
        return (ScheduleState { signature, next_run_at: next() }, None);
    };
    let due = match state.next_run_at {
        Some(due) if automation.enabled && due <= now => due,
        _ => return (ScheduleState { signature, next_run_at: state.next_run_at }, None),
    };
    let latest = automation
        .schedule
        .latest_occurrence(&due.with_timezone(&zone), &now.with_timezone(&zone))
        .map(|date| date.with_timezone(&Utc))
        .unwrap_or(due);
    let lateness = (now - latest).num_milliseconds();
    let allowed = (automation.grace_minutes * 60 + CHECK_SLACK_SECONDS) * 1000;
    let decision = if lateness > allowed {
        Decision::Missed { scheduled_for: latest }
    } else {
        Decision::Run { scheduled_for: latest }
    };
    (ScheduleState { signature, next_run_at: next() }, Some(decision))
}

#[cfg(test)]
mod tests {
    use chrono::{NaiveDate, TimeZone};
    use chrono_tz::America::New_York;
    use chrono_tz::Europe::Berlin;
    use soprano_config::{AutomationSession, AutomationWorkspace, CronSchedule};

    use super::*;

    fn date(text: &str) -> DateTime<Utc> {
        let naive = chrono::NaiveDateTime::parse_from_str(text, "%Y-%m-%d %H:%M").expect("date");
        Berlin.from_local_datetime(&naive).single().expect("berlin time").with_timezone(&Utc)
    }

    fn automation(schedule: &str, enabled: bool, grace_minutes: i64) -> Automation {
        Automation {
            id: "audit".into(),
            name: "Audit".into(),
            agent_id: "omp".into(),
            folder: "/tmp".into(),
            prompt: "Audit the repository.".into(),
            schedule: CronSchedule::parse(schedule).expect("schedule"),
            enabled,
            workspace: AutomationWorkspace::Folder,
            session: AutomationSession::Fresh,
            grace_minutes,
            precheck: None,
            precheck_timeout_seconds: 60,
            model: None,
        }
    }

    fn audit() -> Automation {
        automation("0 9 * * *", true, 60)
    }

    fn state(automation: &Automation, next_run_at: Option<DateTime<Utc>>) -> ScheduleState {
        ScheduleState { signature: signature(automation, Berlin), next_run_at }
    }

    #[test]
    fn a_new_automation_waits_for_its_next_time_instead_of_running_one_that_already_passed() {
        let (state, decision) = evaluate(&audit(), None, date("2026-10-29 09:30"), Berlin);
        assert_eq!(decision, None);
        assert_eq!(state.next_run_at, Some(date("2026-10-30 09:00")));
    }

    #[test]
    fn a_run_that_came_due_starts_and_the_next_one_is_set_from_now() {
        let audit = audit();
        let saved = state(&audit, Some(date("2026-10-29 09:00")));
        let (state, decision) = evaluate(&audit, Some(&saved), date("2026-10-29 09:00"), Berlin);
        assert_eq!(decision, Some(Decision::Run { scheduled_for: date("2026-10-29 09:00") }));
        assert_eq!(state.next_run_at, Some(date("2026-10-30 09:00")));
    }

    #[test]
    fn a_run_that_came_due_under_an_older_builds_saved_schedule_still_starts_after_the_update() {
        let audit = audit();
        // Builds before the time zone joined the signature saved "<on|off> <cron>".
        let saved =
            ScheduleState { signature: "on 0 9 * * *".into(), next_run_at: Some(date("2026-10-29 09:00")) };
        let (new_state, decision) = evaluate(&audit, Some(&saved), date("2026-10-29 09:20"), Berlin);
        assert_eq!(decision, Some(Decision::Run { scheduled_for: date("2026-10-29 09:00") }));
        assert_eq!(new_state, state(&audit, Some(date("2026-10-30 09:00"))));
    }

    #[test]
    fn moving_to_another_time_zone_sets_the_next_run_for_nine_there_instead_of_nine_at_home() {
        let audit = audit();
        let (berlin_state, _) = evaluate(&audit, None, date("2026-10-29 08:00"), Berlin);

        let (state, decision) = evaluate(&audit, Some(&berlin_state), date("2026-10-29 08:00"), New_York);

        assert_eq!(decision, None);
        let nine_in_new_york = New_York
            .from_local_datetime(
                &NaiveDate::from_ymd_opt(2026, 10, 29).and_then(|d| d.and_hms_opt(9, 0, 0)).expect("date"),
            )
            .single()
            .expect("new york time")
            .with_timezone(&Utc);
        assert_eq!(state.next_run_at, Some(nine_in_new_york));
    }

    #[test]
    fn a_machine_that_slept_through_several_runs_starts_only_the_latest() {
        let hourly = automation("0 * * * *", true, 30);
        let saved = state(&hourly, Some(date("2026-10-29 02:00")));
        let (state, decision) = evaluate(&hourly, Some(&saved), date("2026-10-29 07:10"), Berlin);
        assert_eq!(decision, Some(Decision::Run { scheduled_for: date("2026-10-29 07:00") }));
        assert_eq!(state.next_run_at, Some(date("2026-10-29 08:00")));
    }

    #[test]
    fn a_run_past_its_grace_period_is_recorded_as_missed_instead_of_starting_late() {
        let audit = audit();
        let saved = state(&audit, Some(date("2026-10-29 09:00")));
        let (state, decision) = evaluate(&audit, Some(&saved), date("2026-10-29 11:00"), Berlin);
        assert_eq!(decision, Some(Decision::Missed { scheduled_for: date("2026-10-29 09:00") }));
        assert_eq!(state.next_run_at, Some(date("2026-10-30 09:00")));
    }

    #[test]
    fn a_run_without_grace_still_starts_when_the_check_lands_within_a_minute_of_it() {
        let audit = automation("0 9 * * *", true, 0);
        let saved = state(&audit, Some(date("2026-10-29 09:00")));
        let now = date("2026-10-29 09:00") + chrono::Duration::seconds(45);
        let (_, decision) = evaluate(&audit, Some(&saved), now, Berlin);
        assert_eq!(decision, Some(Decision::Run { scheduled_for: date("2026-10-29 09:00") }));
    }

    #[test]
    fn a_paused_automation_has_no_next_run_and_starts_nothing() {
        let running = audit();
        let paused = automation("0 9 * * *", false, 60);
        let saved = state(&running, Some(date("2026-10-29 09:00")));
        let (state, decision) = evaluate(&paused, Some(&saved), date("2026-10-29 09:05"), Berlin);
        assert_eq!(decision, None);
        assert_eq!(state.next_run_at, None);
    }

    #[test]
    fn resuming_a_paused_automation_counts_from_now_rather_than_catching_up() {
        let paused = automation("0 9 * * *", false, 60);
        let resumed = audit();
        let saved = state(&paused, None);
        let (state, decision) = evaluate(&resumed, Some(&saved), date("2026-10-29 09:05"), Berlin);
        assert_eq!(decision, None);
        assert_eq!(state.next_run_at, Some(date("2026-10-30 09:00")));
    }

    #[test]
    fn editing_the_schedule_recomputes_the_next_run_without_starting_one() {
        let old = audit();
        let edited = automation("30 18 * * *", true, 60);
        let saved = state(&old, Some(date("2026-10-29 09:00")));
        let (state, decision) = evaluate(&edited, Some(&saved), date("2026-10-29 10:00"), Berlin);
        assert_eq!(decision, None);
        assert_eq!(state.next_run_at, Some(date("2026-10-29 18:30")));
    }
}
