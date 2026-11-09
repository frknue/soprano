//! What the page states, as plain values: the header's subtitle, the search, a run's message
//! split from a precheck's output, and the times a page states.

use chrono::{DateTime, Utc};
use soprano_automations::{AutomationRun, RunStatus};
use soprano_config::Automation;

use crate::format;

/// `4 automations · next run in 2 hr`, or `… · all paused`.
pub fn subtitle(count: usize, next_runs: &[DateTime<Utc>], now: DateTime<Utc>) -> String {
    let mut parts = vec![format::count(count, "automation")];
    if let Some(next) = next_runs.iter().min() {
        parts.push(format!("next run {}", format::relative(*next, now)));
    } else if count > 0 {
        parts.push("all paused".into());
    }
    parts.join(" · ")
}

/// Whether the search `query` (trimmed, non-empty) finds `automation`: its name, agent,
/// folder or prompt, case-insensitively.
pub fn matches(automation: &Automation, query: &str) -> bool {
    let query = query.to_lowercase();
    [
        automation.name.clone(),
        format::agent_name(&automation.agent_id),
        automation.agent_id.clone(),
        automation.folder.clone(),
        format::path(&automation.folder),
        automation.prompt.clone(),
    ]
    .iter()
    .any(|text| text.to_lowercase().contains(&query))
}

/// The detail page's times as it states them, which change with the clock alone: the next
/// run's `in 3 hr` and every unfinished run's duration so far.
pub fn clock_text(runs: &[AutomationRun], next_run: Option<DateTime<Utc>>, now: DateTime<Utc>) -> String {
    let mut parts = vec![next_run.map(|next| format::relative(next, now)).unwrap_or_default()];
    for run in runs.iter().filter(|run| run.finished_at.is_none()) {
        parts.push(format::duration(now - run.started_at));
    }
    parts.join("|")
}

/// The title of a run's message card.
pub fn message_title(status: RunStatus) -> &'static str {
    match status {
        RunStatus::Skipped => "Why it was skipped",
        RunStatus::Failed => "Why it failed",
        RunStatus::NeedsInput => "Waiting for",
        RunStatus::Starting | RunStatus::Running | RunStatus::Completed => "Message",
    }
}

/// A run's message, and a precheck's output after its first paragraph (shown as code).
pub fn message_parts(message: &str) -> (String, Option<String>) {
    if message.starts_with("The precheck")
        && let Some((reason, output)) = message.split_once("\n\n")
    {
        return (reason.to_owned(), Some(output.to_owned()));
    }
    (message.to_owned(), None)
}

/// `text` as a fenced code block, fenced past any backtick run inside it.
pub fn fenced_code(text: &str) -> String {
    let longest = text.split(|c| c != '`').map(str::len).max().unwrap_or(0);
    let fence = "`".repeat(longest.max(2) + 1);
    format!("{fence}\n{text}\n{fence}")
}

/// `#3`'s duration column: its length, `—` for a finished run without one, else how long it
/// has gone so far. The flag says whether it reads muted.
pub fn run_duration(run: &AutomationRun, now: DateTime<Utc>) -> (String, bool) {
    match run.duration() {
        Some(duration) => (format::duration(duration), false),
        None if run.status.is_final() => ("—".into(), true),
        None => (format!("{} so far", format::duration(now - run.started_at)), true),
    }
}

#[cfg(test)]
mod tests {
    use soprano_automations::RunTrigger;

    use super::*;

    fn at(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(1_800_000_000 + seconds, 0).expect("date")
    }

    #[test]
    fn the_subtitle_counts_automations_and_says_when_the_next_runs() {
        assert_eq!(subtitle(0, &[], at(0)), "0 automations");
        assert_eq!(subtitle(1, &[], at(0)), "1 automation · all paused");
        assert_eq!(subtitle(4, &[at(9_000), at(7_300)], at(0)), "4 automations · next run in 2 hr");
    }

    #[test]
    fn refreshing_with_nothing_new_states_the_same_times_until_one_it_states_changed() {
        // The page refreshes every half minute; "in 15 hr" reads the same.
        let now = at(0);
        let next = at(15 * 3_600 + 1_800);
        let before = clock_text(&[], Some(next), now);
        assert_eq!(clock_text(&[], Some(next), at(30)), before);
        assert_ne!(clock_text(&[], Some(next), at(3 * 3_600)), before);
    }

    #[test]
    fn a_precheck_message_splits_its_output_off_as_code() {
        let (reason, output) = message_parts("The precheck exited with code 3.\n\nno open PRs");
        assert_eq!(reason, "The precheck exited with code 3.");
        assert_eq!(output.as_deref(), Some("no open PRs"));
        assert_eq!(message_parts("Run #1 was still working.").1, None);
        assert_eq!(fenced_code("a ```` b"), "`````\na ```` b\n`````");
        assert_eq!(fenced_code("plain"), "```\nplain\n```");
    }

    #[test]
    fn a_runs_duration_says_so_far_while_it_works() {
        let mut run =
            AutomationRun::new("r", "audit", 1, RunTrigger::Manual, at(0), RunStatus::Running, "omp", "/tmp");
        assert_eq!(run_duration(&run, at(75)), ("1m 15s so far".into(), true));
        run.status = RunStatus::Skipped;
        assert_eq!(run_duration(&run, at(75)), ("—".into(), true));
        run.finished_at = Some(at(38));
        assert_eq!(run_duration(&run, at(75)), ("38s".into(), false));
    }
}
