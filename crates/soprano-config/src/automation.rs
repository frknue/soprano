//! A prompt Soprano gives an agent on a schedule, as `settings.json` declares it under
//! `automations.<id>` (`Automations/Automation.swift`): the entry type, its validation into an
//! [`Automation`], and the object written back for one.

use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::config::{ConfigIssue, expand_path};
use crate::config_file::abbreviating_home;
use crate::cron::{AutomationCadence, CronSchedule};

/// Where each run's agent works.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AutomationWorkspace {
    /// In `folder` itself, beside whatever else works there.
    Folder,
    /// In a fresh git worktree of `folder`'s repository, branched from `base_branch` (the
    /// remote's default branch when `None`).
    Worktree { base_branch: Option<String> },
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum AutomationSession {
    /// Every run starts a new agent.
    #[default]
    Fresh,
    /// A run hands its prompt to the previous run's agent while that one is still open and
    /// done with its turn, and starts one otherwise.
    Reuse,
}

impl AutomationSession {
    pub const ALL: [Self; 2] = [Self::Fresh, Self::Reuse];

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Fresh => "fresh",
            Self::Reuse => "reuse",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|s| s.raw_value() == raw)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Automation {
    pub id: String,
    pub name: String,
    pub agent_id: String,
    /// Absolute, `~` expanded.
    pub folder: String,
    pub prompt: String,
    pub schedule: CronSchedule,
    pub enabled: bool,
    pub workspace: AutomationWorkspace,
    pub session: AutomationSession,
    /// How late a run due while the machine slept, or Soprano was closed, may still start.
    pub grace_minutes: i64,
    /// A shell command run in `folder` before a scheduled run; the run is skipped unless it
    /// exits 0.
    pub precheck: Option<String>,
    pub precheck_timeout_seconds: i64,
    /// Passed as the CLI's model option; `None` keeps the CLI's default.
    pub model: Option<String>,
}

impl Automation {
    /// The CLIs that take a first prompt on their command line and report their turns back to
    /// Soprano, so a run can start and finish unattended.
    pub const AGENT_IDS: [&'static str; 4] = ["omp", "claude-code", "codex", "opencode"];

    pub const DEFAULT_GRACE_MINUTES: i64 = 720;
    pub const GRACE_MINUTES_RANGE: std::ops::RangeInclusive<i64> = 0..=2_880;
    pub const DEFAULT_PRECHECK_TIMEOUT_SECONDS: i64 = 60;
    pub const PRECHECK_TIMEOUT_RANGE: std::ops::RangeInclusive<i64> = 5..=600;

    pub fn cadence(&self) -> AutomationCadence {
        AutomationCadence::from_schedule(&self.schedule)
    }

    /// `abc`, `weekday-audit`: what may name an automation in settings.json.
    pub fn is_valid_id(id: &str) -> bool {
        !id.is_empty()
            && id.len() <= 64
            && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    }

    /// A new id from `name`, unique among `existing`.
    pub fn make_id(name: &str, existing: &BTreeSet<String>) -> String {
        let mut slug = String::new();
        let mut last_was_dash = false;
        for scalar in name.to_lowercase().chars() {
            if scalar.is_ascii_lowercase() || scalar.is_ascii_digit() {
                slug.push(scalar);
                last_was_dash = false;
            } else if !last_was_dash && !slug.is_empty() {
                slug.push('-');
                last_was_dash = true;
            }
        }
        while slug.ends_with('-') {
            slug.pop();
        }
        let mut slug: String = slug.chars().take(48).collect();
        if slug.is_empty() {
            slug = "automation".into();
        }
        let mut candidate = slug.clone();
        let mut suffix = 2;
        while existing.contains(&candidate) {
            candidate = format!("{slug}-{suffix}");
            suffix += 1;
        }
        candidate
    }

    /// The `automations.<id>` object Soprano writes for this automation: defaults are left
    /// out so the file stays as short as a hand-written one.
    pub fn config_object(&self) -> Value {
        let mut object = Map::new();
        object.insert("name".into(), self.name.clone().into());
        object.insert("agent".into(), self.agent_id.clone().into());
        object.insert("folder".into(), abbreviating_home(&self.folder).into());
        object.insert("prompt".into(), self.prompt.clone().into());
        object.insert("schedule".into(), self.schedule.expression.clone().into());
        if !self.enabled {
            object.insert("enabled".into(), false.into());
        }
        if let AutomationWorkspace::Worktree { base_branch } = &self.workspace {
            object.insert("worktree".into(), true.into());
            if let Some(base_branch) = base_branch {
                object.insert("baseBranch".into(), base_branch.clone().into());
            }
        }
        if self.session != AutomationSession::Fresh {
            object.insert("session".into(), self.session.raw_value().into());
        }
        if self.grace_minutes != Self::DEFAULT_GRACE_MINUTES {
            object.insert("graceMinutes".into(), self.grace_minutes.into());
        }
        if let Some(precheck) = &self.precheck {
            object.insert("precheck".into(), precheck.clone().into());
        }
        if self.precheck_timeout_seconds != Self::DEFAULT_PRECHECK_TIMEOUT_SECONDS {
            object.insert("precheckTimeoutSeconds".into(), self.precheck_timeout_seconds.into());
        }
        if let Some(model) = &self.model {
            object.insert("model".into(), model.clone().into());
        }
        Value::Object(object)
    }
}

/// One `automations.<id>` entry. Every field is optional so a partial or mistyped entry is
/// reported in Settings instead of failing the file.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AutomationEntry {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub schedule: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "crate::config::integral_number"
    )]
    pub grace_minutes: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub precheck: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "crate::config::integral_number"
    )]
    pub precheck_timeout_seconds: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
}

fn non_empty(value: &str) -> Option<String> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

/// The valid automations, sorted by name; every rejected entry becomes an issue and is left
/// out.
pub fn resolve_automations(
    entries: &BTreeMap<String, AutomationEntry>,
    agent_ids: &BTreeSet<String>,
    issues: &mut Vec<ConfigIssue>,
) -> Vec<Automation> {
    let agent_list = Automation::AGENT_IDS.join(", ");
    let mut automations = Vec::new();
    for (id, entry) in entries {
        let mut reject =
            |reason: String| issues.push(ConfigIssue::warning(format!("automations.{id}: {reason}")));
        if !Automation::is_valid_id(id) {
            reject("ids use only letters, digits, - and _; the entry was ignored.".into());
            continue;
        }
        let Some(prompt) = entry.prompt.as_deref().and_then(non_empty) else {
            reject("\"prompt\" is missing; the automation was ignored.".into());
            continue;
        };
        let folder = expand_path(entry.folder.as_deref().unwrap_or(""));
        if folder.is_empty() {
            reject("\"folder\" is missing; the automation was ignored.".into());
            continue;
        }
        let Some(agent_id) = entry.agent.as_deref().and_then(non_empty) else {
            reject(format!("\"agent\" is missing; use one of {agent_list}."));
            continue;
        };
        if !Automation::AGENT_IDS.contains(&agent_id.as_str()) || !agent_ids.contains(&agent_id) {
            reject(format!("\"{agent_id}\" can't run automations; use one of {agent_list}."));
            continue;
        }
        let schedule = match CronSchedule::parse(entry.schedule.as_deref().unwrap_or("")) {
            Ok(schedule) => schedule,
            Err(error) => {
                let written = entry.schedule.as_ref().map_or("is missing".to_owned(), |s| format!("\"{s}\""));
                reject(format!("\"schedule\" {written}: {error}"));
                continue;
            }
        };

        let mut grace_minutes = entry.grace_minutes.unwrap_or(Automation::DEFAULT_GRACE_MINUTES);
        if !Automation::GRACE_MINUTES_RANGE.contains(&grace_minutes) {
            reject(format!(
                "\"graceMinutes\" must be 0–{}; using the default.",
                Automation::GRACE_MINUTES_RANGE.end()
            ));
            grace_minutes = Automation::DEFAULT_GRACE_MINUTES;
        }
        let mut timeout =
            entry.precheck_timeout_seconds.unwrap_or(Automation::DEFAULT_PRECHECK_TIMEOUT_SECONDS);
        if !Automation::PRECHECK_TIMEOUT_RANGE.contains(&timeout) {
            reject(format!(
                "\"precheckTimeoutSeconds\" must be {}–{}; using the default.",
                Automation::PRECHECK_TIMEOUT_RANGE.start(),
                Automation::PRECHECK_TIMEOUT_RANGE.end()
            ));
            timeout = Automation::DEFAULT_PRECHECK_TIMEOUT_SECONDS;
        }
        let workspace = if entry.worktree == Some(true) {
            AutomationWorkspace::Worktree { base_branch: entry.base_branch.as_deref().and_then(non_empty) }
        } else {
            AutomationWorkspace::Folder
        };
        let mut session = AutomationSession::Fresh;
        if let Some(raw) = &entry.session {
            match AutomationSession::from_raw(raw) {
                Some(value) => session = value,
                None => reject("\"session\" must be \"fresh\" or \"reuse\"; using fresh.".into()),
            }
        }
        if session == AutomationSession::Reuse && workspace != AutomationWorkspace::Folder {
            reject(
                "\"session\": \"reuse\" needs the run to work in its folder, not a worktree; using fresh."
                    .into(),
            );
            session = AutomationSession::Fresh;
        }
        let name = entry.name.as_deref().and_then(non_empty).unwrap_or_else(|| id.clone());
        automations.push(Automation {
            id: id.clone(),
            name,
            agent_id,
            folder,
            prompt,
            schedule,
            enabled: entry.enabled.unwrap_or(true),
            workspace,
            session,
            grace_minutes,
            precheck: entry.precheck.as_deref().and_then(non_empty),
            precheck_timeout_seconds: timeout,
            model: entry.model.as_deref().and_then(non_empty),
        });
    }
    automations.sort_by(|a, b| localized_standard_compare(&a.name, &b.name));
    automations
}

/// Finder-style ordering (`localizedStandardCompare`): case- and diacritic-insensitive, so
/// "Änderungen" sorts with the A's, with digit runs compared by value so "Run 9" sorts before
/// "Run 10". Names equal under that folding fall back to their exact text.
pub fn localized_standard_compare(left: &str, right: &str) -> Ordering {
    natural_compare(&fold(left), &fold(right)).then_with(|| left.cmp(right))
}

/// Lowercased with accents removed: decompose, then drop the combining marks.
fn fold(text: &str) -> String {
    use unicode_normalization::UnicodeNormalization;
    use unicode_normalization::char::is_combining_mark;
    text.nfd().filter(|c| !is_combining_mark(*c)).flat_map(char::to_lowercase).collect()
}

fn natural_compare(left: &str, right: &str) -> Ordering {
    let mut a = left.chars().peekable();
    let mut b = right.chars().peekable();
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let mut run_a = String::new();
                while let Some(d) = a.next_if(char::is_ascii_digit) {
                    run_a.push(d);
                }
                let mut run_b = String::new();
                while let Some(d) = b.next_if(char::is_ascii_digit) {
                    run_b.push(d);
                }
                let trimmed_a = run_a.trim_start_matches('0');
                let trimmed_b = run_b.trim_start_matches('0');
                let ordering = trimmed_a.len().cmp(&trimmed_b.len()).then_with(|| trimmed_a.cmp(trimmed_b));
                if ordering != Ordering::Equal {
                    return ordering;
                }
            }
            (Some(x), Some(y)) => {
                let ordering = x.cmp(&y);
                if ordering != Ordering::Equal {
                    return ordering;
                }
                a.next();
                b.next();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_new_id_comes_from_the_name_and_never_collides_with_an_existing_one() {
        assert_eq!(Automation::make_id("Weekday repo audit!", &BTreeSet::new()), "weekday-repo-audit");
        let existing = BTreeSet::from(["weekday-repo-audit".to_string()]);
        assert_eq!(Automation::make_id("Weekday repo audit", &existing), "weekday-repo-audit-2");
        assert_eq!(Automation::make_id("  ✨ ", &BTreeSet::new()), "automation");
    }

    #[test]
    fn automation_ids_use_only_letters_digits_dashes_and_underscores() {
        assert!(Automation::is_valid_id("weekday_audit-2"));
        assert!(!Automation::is_valid_id(""));
        assert!(!Automation::is_valid_id("has space"));
        assert!(!Automation::is_valid_id(&"a".repeat(65)));
    }

    #[test]
    fn names_sort_case_insensitively_and_numbers_by_value() {
        let mut names = vec!["Zebra", "apple", "Run 10", "Run 9"];
        names.sort_by(|a, b| localized_standard_compare(a, b));
        assert_eq!(names, ["apple", "Run 9", "Run 10", "Zebra"]);
    }

    #[test]
    fn names_sort_without_regard_to_accents() {
        let mut names = vec!["Zebra", "Änderungen", "apple", "Écrire", "Bericht"];
        names.sort_by(|a, b| localized_standard_compare(a, b));
        assert_eq!(names, ["Änderungen", "apple", "Bericht", "Écrire", "Zebra"]);
    }
}
