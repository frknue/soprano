//! The page's wording for times, durations and settings (`AutomationFormat`), in one place so
//! the list, the detail and the run report read alike.

use chrono::{DateTime, Timelike, Utc};
use chrono_tz::Tz;
use soprano_automations::RunTrigger;
use soprano_config::{AutomationCadence, AutomationSession, AutomationWorkspace};
use soprano_types::AgentCatalog;

/// `Oct 29, 9:00 AM`, in `zone`; the time reads as the schedules' summaries do.
pub fn date_time(date: DateTime<Utc>, zone: Tz) -> String {
    let local = date.with_timezone(&zone);
    format!("{} {}", local.format("%b %-d,"), AutomationCadence::time(local.hour(), local.minute()))
}

/// `in 3 hr`, `in 12 min`, `5 min ago`, `just now`, `2 days ago`.
pub fn relative(date: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let seconds = (date - now).num_milliseconds() as f64 / 1000.0;
    let magnitude = seconds.abs();
    let is_future = seconds > 0.0;
    if magnitude < 60.0 {
        return if is_future { "in under a minute".into() } else { "just now".into() };
    }
    let amount = if magnitude < 3_600.0 {
        format!("{} min", (magnitude / 60.0) as i64)
    } else if magnitude < 86_400.0 {
        format!("{} hr", (magnitude / 3_600.0) as i64)
    } else {
        let days = (magnitude / 86_400.0) as i64;
        if days == 1 { "1 day".into() } else { format!("{days} days") }
    };
    if is_future { format!("in {amount}") } else { format!("{amount} ago") }
}

/// `38s`, `4m 12s`, `2h 7m`.
pub fn duration(interval: chrono::Duration) -> String {
    let total = ((interval.num_milliseconds() as f64) / 1000.0).round().max(0.0) as i64;
    let hours = total / 3_600;
    let minutes = (total % 3_600) / 60;
    let seconds = total % 60;
    if hours > 0 {
        format!("{hours}h {minutes}m")
    } else if minutes > 0 {
        format!("{minutes}m {seconds}s")
    } else {
        format!("{seconds}s")
    }
}

/// `None`, `30 minutes`, `12 hours`, `1 hour 30 minutes`.
pub fn grace(minutes: i64) -> String {
    if minutes <= 0 {
        return "None".into();
    }
    let hours = minutes / 60;
    let rest = minutes % 60;
    let hour_text = if hours == 1 { "1 hour".to_owned() } else { format!("{hours} hours") };
    let minute_text = if rest == 1 { "1 minute".to_owned() } else { format!("{rest} minutes") };
    if hours == 0 {
        minute_text
    } else if rest == 0 {
        hour_text
    } else {
        format!("{hour_text} {minute_text}")
    }
}

/// `30 sec`, `1 min`, `90 sec`.
pub fn timeout(seconds: i64) -> String {
    if seconds % 60 == 0 { format!("{} min", seconds / 60) } else { format!("{seconds} sec") }
}

/// `~/git/shop`.
pub fn path(path: &str) -> String {
    soprano_config::config_file::abbreviating_home(path)
}

/// The agent's catalog name, or its id when the catalog lost it.
pub fn agent_name(agent_id: &str) -> String {
    AgentCatalog::shared().profile(agent_id).map_or_else(|| agent_id.to_owned(), |profile| profile.name)
}

pub fn workspace(workspace: &AutomationWorkspace) -> String {
    match workspace {
        AutomationWorkspace::Folder => "Its folder".into(),
        AutomationWorkspace::Worktree { base_branch } => {
            format!("New worktree from {}", base_branch.as_deref().unwrap_or("origin's default branch"))
        }
    }
}

pub fn session(session: AutomationSession) -> &'static str {
    match session {
        AutomationSession::Fresh => "Fresh each run",
        AutomationSession::Reuse => "Reuses the open agent",
    }
}

pub fn trigger(trigger: RunTrigger) -> &'static str {
    match trigger {
        RunTrigger::Scheduled => "Scheduled",
        RunTrigger::Manual => "Manual",
    }
}

/// `1 automation`, `4 automations`.
pub fn count(count: usize, noun: &str) -> String {
    format!("{count} {noun}{}", if count == 1 { "" } else { "s" })
}

/// A message's first paragraph, without the precheck output after it, for the failure notice.
pub fn first_paragraph(text: &str) -> String {
    text.split("\n\n").next().unwrap_or(text).trim().to_owned()
}

/// The prompt's first non-empty line, for the list's second line.
pub fn first_line(text: &str) -> String {
    text.lines().map(str::trim).find(|line| !line.is_empty()).unwrap_or_default().to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(1_800_000_000 + seconds, 0).expect("date")
    }

    #[test]
    fn relative_times_round_down_to_the_unit_they_name() {
        let now = at(0);
        assert_eq!(relative(at(30), now), "in under a minute");
        assert_eq!(relative(at(-30), now), "just now");
        assert_eq!(relative(at(12 * 60 + 59), now), "in 12 min");
        assert_eq!(relative(at(-5 * 60), now), "5 min ago");
        assert_eq!(relative(at(3 * 3_600 + 100), now), "in 3 hr");
        assert_eq!(relative(at(-86_400 - 5), now), "1 day ago");
        assert_eq!(relative(at(-2 * 86_400), now), "2 days ago");
    }

    #[test]
    fn durations_show_the_two_largest_units() {
        assert_eq!(duration(chrono::Duration::seconds(38)), "38s");
        assert_eq!(duration(chrono::Duration::seconds(4 * 60 + 12)), "4m 12s");
        assert_eq!(duration(chrono::Duration::seconds(2 * 3_600 + 7 * 60 + 5)), "2h 7m");
        assert_eq!(duration(chrono::Duration::seconds(-5)), "0s");
    }

    #[test]
    fn grace_and_timeouts_read_as_words() {
        assert_eq!(grace(0), "None");
        assert_eq!(grace(30), "30 minutes");
        assert_eq!(grace(60), "1 hour");
        assert_eq!(grace(90), "1 hour 30 minutes");
        assert_eq!(grace(720), "12 hours");
        assert_eq!(grace(61), "1 hour 1 minute");
        assert_eq!(timeout(30), "30 sec");
        assert_eq!(timeout(60), "1 min");
        assert_eq!(timeout(90), "90 sec");
    }

    #[test]
    fn dates_read_in_the_schedules_time_zone() {
        let date = DateTime::from_timestamp(1_793_260_800, 0).expect("date");
        assert_eq!(
            date_time(date, chrono_tz::Europe::Berlin),
            format!("Oct 29, {}", AutomationCadence::time(9, 0))
        );
    }

    #[test]
    fn texts_for_settings_and_messages() {
        assert_eq!(count(1, "automation"), "1 automation");
        assert_eq!(count(4, "automation"), "4 automations");
        assert_eq!(
            first_paragraph("The precheck exited with code 3.\n\nno open PRs"),
            "The precheck exited with code 3."
        );
        assert_eq!(first_line("\n  \n  Review it.\nThen more."), "Review it.");
        assert_eq!(
            workspace(&AutomationWorkspace::Worktree { base_branch: None }),
            "New worktree from origin's default branch"
        );
        assert_eq!(workspace(&AutomationWorkspace::Folder), "Its folder");
    }
}
