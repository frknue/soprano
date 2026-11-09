//! The editor's values and rules (`AutomationEditorPanel`'s model): what the fields hold, which
//! schedule they describe, what the notes under them say, whether Save may write, and the
//! automation Save writes. Plain values, so the rules test without a window.

use std::collections::BTreeSet;
use std::path::Path;

use chrono::{DateTime, Utc};
use chrono_tz::Tz;
use soprano_config::{Automation, AutomationCadence, AutomationSession, AutomationWorkspace, CronSchedule};
use soprano_types::AgentCatalog;

use crate::format;
use crate::templates::AutomationTemplate;

/// The schedule kinds the editor offers by name.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cadence {
    Hourly,
    Daily,
    Weekdays,
    Weekly,
    Custom,
}

impl Cadence {
    pub const ALL: [Cadence; 5] = [Self::Hourly, Self::Daily, Self::Weekdays, Self::Weekly, Self::Custom];

    pub fn title(self) -> &'static str {
        match self {
            Self::Hourly => "Hourly",
            Self::Daily => "Daily",
            Self::Weekdays => "Weekdays",
            Self::Weekly => "Weekly",
            Self::Custom => "Custom",
        }
    }
}

pub const GRACE_OPTIONS: [(i64, &str); 7] = [
    (0, "No grace"),
    (30, "30 minutes"),
    (60, "1 hour"),
    (180, "3 hours"),
    (720, "12 hours"),
    (1_440, "24 hours"),
    (2_880, "48 hours"),
];

pub const TIMEOUT_OPTIONS: [(i64, &str); 5] =
    [(30, "30 sec"), (60, "1 min"), (120, "2 min"), (300, "5 min"), (600, "10 min")];

pub const WEEKDAYS: [&str; 7] =
    ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

/// The grace choices, with `current` added in order when it is none of them.
pub fn grace_options(current: i64) -> Vec<(i64, String)> {
    let mut options: Vec<(i64, String)> = GRACE_OPTIONS.iter().map(|(m, t)| (*m, (*t).to_owned())).collect();
    if !options.iter().any(|(minutes, _)| *minutes == current) {
        options.push((current, format::grace(current)));
        options.sort_by_key(|(minutes, _)| *minutes);
    }
    options
}

/// The precheck timeouts, with `current` added in order when it is none of them.
pub fn timeout_options(current: i64) -> Vec<(i64, String)> {
    let mut options: Vec<(i64, String)> =
        TIMEOUT_OPTIONS.iter().map(|(s, t)| (*s, (*t).to_owned())).collect();
    if !options.iter().any(|(seconds, _)| *seconds == current) {
        options.push((current, format::timeout(current)));
        options.sort_by_key(|(seconds, _)| *seconds);
    }
    options
}

/// The agents an automation can run: the catalog's automation CLIs, plus the one an edited
/// automation names when the catalog lost it.
pub fn agent_ids(existing: Option<&str>) -> Vec<String> {
    let mut ids: Vec<String> = Automation::AGENT_IDS
        .iter()
        .filter(|id| AgentCatalog::shared().profile(id).is_some())
        .map(|id| (*id).to_owned())
        .collect();
    if let Some(existing) = existing
        && !ids.iter().any(|id| id == existing)
    {
        ids.insert(0, existing.to_owned());
    }
    ids
}

/// Folders of existing automations first, then every child folder of the project directories,
/// as Open Project lists them.
pub fn folder_choices(automations: &[Automation], project_directories: &[String]) -> Vec<String> {
    let mut seen = BTreeSet::new();
    let mut choices = Vec::new();
    for automation in automations {
        if seen.insert(automation.folder.clone()) {
            choices.push(automation.folder.clone());
        }
    }
    let mut projects = Vec::new();
    for root in project_directories {
        let Ok(entries) = std::fs::read_dir(soprano_config::expand_path(root)) else { continue };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || !entry.path().is_dir() {
                continue;
            }
            projects.push(entry.path().to_string_lossy().into_owned());
        }
    }
    projects.sort_by(|a, b| {
        let name = |path: &str| {
            Path::new(path).file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default()
        };
        name(a).cmp(&name(b)).then_with(|| a.cmp(b))
    });
    for folder in projects {
        if seen.insert(folder.clone()) {
            choices.push(folder);
        }
    }
    choices
}

/// `9:00 AM`, `9:00 pm`, `21:30`, `09:05`.
pub fn parse_time(text: &str) -> Option<(u32, u32)> {
    let text = text.trim().to_lowercase();
    let (clock, period) = if let Some(rest) = text.strip_suffix("am") {
        (rest.trim(), Some(false))
    } else if let Some(rest) = text.strip_suffix("pm") {
        (rest.trim(), Some(true))
    } else {
        (text.as_str(), None)
    };
    let (hour, minute) = clock.split_once(':')?;
    let hour: u32 = hour.trim().parse().ok()?;
    let minute: u32 = minute.trim().parse().ok()?;
    if minute > 59 {
        return None;
    }
    let hour = match period {
        None if hour <= 23 => hour,
        Some(pm) if (1..=12).contains(&hour) => hour % 12 + if pm { 12 } else { 0 },
        _ => return None,
    };
    Some((hour, minute))
}

/// What the editor's fields hold.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FormValues {
    pub name: String,
    pub prompt: String,
    pub agent_id: String,
    pub model: String,
    pub folder: Option<String>,
    pub worktree: bool,
    pub base_branch: String,
    pub reuse: bool,
    pub cadence: Cadence,
    pub minute: String,
    /// 0 = Sunday.
    pub weekday: u32,
    pub time: String,
    pub cron: String,
    pub grace_minutes: i64,
    pub precheck: String,
    pub precheck_timeout_seconds: i64,
    pub enabled: bool,
}

/// A note under a field.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Note {
    pub text: String,
    pub is_error: bool,
}

impl Note {
    fn muted(text: impl Into<String>) -> Self {
        Self { text: text.into(), is_error: false }
    }

    fn error(text: impl Into<String>) -> Self {
        Self { text: text.into(), is_error: true }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Validation {
    pub prompt_note: Option<Note>,
    pub folder_note: Option<Note>,
    pub schedule_note: Note,
    pub minute_invalid: bool,
    pub cron_invalid: bool,
    pub time_invalid: bool,
    pub can_save: bool,
}

impl FormValues {
    /// The fields for `automation`, else a template's prefill, else a new automation's.
    pub fn load(automation: Option<&Automation>, template: Option<&AutomationTemplate>) -> Self {
        let agents = agent_ids(automation.map(|a| a.agent_id.as_str()));
        let agent_id = automation.map(|a| a.agent_id.clone()).unwrap_or_else(|| {
            if agents.iter().any(|id| id == "omp") {
                "omp".into()
            } else {
                agents.first().cloned().unwrap_or_default()
            }
        });
        let (worktree, base_branch) = match automation.map(|a| &a.workspace) {
            Some(AutomationWorkspace::Worktree { base_branch }) => {
                (true, base_branch.clone().unwrap_or_default())
            }
            _ => (false, String::new()),
        };
        let cadence = automation
            .map(Automation::cadence)
            .or_else(|| template.map(|t| t.cadence.clone()))
            .unwrap_or(AutomationCadence::Weekdays { hour: 9, minute: 0 });
        let (mut hour, mut minute, mut weekday, mut cron) = (9, 0, 1, String::new());
        let selected = match cadence {
            AutomationCadence::Hourly { minute: m } => {
                minute = m;
                Cadence::Hourly
            }
            AutomationCadence::Daily { hour: h, minute: m } => {
                (hour, minute) = (h, m);
                Cadence::Daily
            }
            AutomationCadence::Weekdays { hour: h, minute: m } => {
                (hour, minute) = (h, m);
                Cadence::Weekdays
            }
            AutomationCadence::Weekly { weekday: d, hour: h, minute: m } => {
                (weekday, hour, minute) = (d % 7, h, m);
                Cadence::Weekly
            }
            AutomationCadence::Custom(expression) => {
                cron = expression;
                Cadence::Custom
            }
        };
        Self {
            name: automation
                .map(|a| a.name.clone())
                .or_else(|| template.map(|t| t.name.to_owned()))
                .unwrap_or_default(),
            prompt: automation
                .map(|a| a.prompt.clone())
                .or_else(|| template.map(|t| t.prompt.to_owned()))
                .unwrap_or_default(),
            agent_id,
            model: automation.and_then(|a| a.model.clone()).unwrap_or_default(),
            folder: automation.map(|a| a.folder.clone()),
            worktree,
            base_branch,
            reuse: automation.is_some_and(|a| a.session == AutomationSession::Reuse),
            cadence: selected,
            minute: minute.to_string(),
            weekday,
            time: AutomationCadence::time(hour, minute),
            cron,
            grace_minutes: automation
                .map(|a| a.grace_minutes)
                .or_else(|| template.map(|t| t.grace_minutes))
                .unwrap_or(Automation::DEFAULT_GRACE_MINUTES),
            precheck: automation.and_then(|a| a.precheck.clone()).unwrap_or_default(),
            precheck_timeout_seconds: automation
                .map(|a| a.precheck_timeout_seconds)
                .unwrap_or(Automation::DEFAULT_PRECHECK_TIMEOUT_SECONDS),
            enabled: automation.is_none_or(|a| a.enabled),
        }
    }

    /// Reuse hands a run to the previous run's agent in the same folder, so a worktree run is
    /// always fresh.
    pub fn session(&self) -> AutomationSession {
        if !self.worktree && self.reuse { AutomationSession::Reuse } else { AutomationSession::Fresh }
    }

    pub fn trimmed_prompt(&self) -> &str {
        self.prompt.trim()
    }

    /// The schedule the controls describe, or why they describe none.
    pub fn schedule(&self) -> Result<CronSchedule, String> {
        let time = || parse_time(&self.time).ok_or_else(|| "Enter a time like 9:00 AM.".to_owned());
        let expression = match self.cadence {
            Cadence::Hourly => match self.minute.trim().parse::<u32>() {
                Ok(minute) if minute <= 59 => AutomationCadence::Hourly { minute }.expression(),
                _ => return Err("Enter a minute from 0 to 59.".into()),
            },
            Cadence::Daily => {
                let (hour, minute) = time()?;
                AutomationCadence::Daily { hour, minute }.expression()
            }
            Cadence::Weekdays => {
                let (hour, minute) = time()?;
                AutomationCadence::Weekdays { hour, minute }.expression()
            }
            Cadence::Weekly => {
                let (hour, minute) = time()?;
                AutomationCadence::Weekly { weekday: self.weekday, hour, minute }.expression()
            }
            Cadence::Custom => {
                let text = self.cron.trim();
                if text.is_empty() {
                    return Err("Enter a five-field cron, e.g. 0 9 * * 1-5.".into());
                }
                text.to_owned()
            }
        };
        CronSchedule::parse(&expression).map_err(|error| error.message)
    }

    pub fn folder_exists(&self) -> bool {
        self.folder.as_deref().is_some_and(|folder| Path::new(folder).is_dir())
    }

    /// The notes under the fields and whether Save may write, as of `now` in `zone`.
    pub fn validation(&self, now: DateTime<Utc>, zone: Tz) -> Validation {
        let prompt_valid = !self.trimmed_prompt().is_empty();
        let folder_note = match &self.folder {
            None => Some(Note::muted("Choose the folder its runs work in.")),
            Some(_) if !self.folder_exists() => Some(Note::error("This folder doesn't exist.")),
            Some(_) => None,
        };
        let schedule = self.schedule();
        let (schedule_note, minute_invalid, cron_invalid, time_invalid) = match &schedule {
            Ok(schedule) => {
                let note = schedule
                    .next_occurrence(&now.with_timezone(&zone))
                    .map(|next| format!("Next run {}", format::date_time(next.with_timezone(&Utc), zone)))
                    .unwrap_or_else(|| "This schedule never runs.".into());
                (Note::muted(note), false, false, false)
            }
            Err(message) => {
                let quiet = self.cadence == Cadence::Custom && self.cron.is_empty();
                let note = if quiet { Note::muted(message.clone()) } else { Note::error(message.clone()) };
                let uses_time = matches!(self.cadence, Cadence::Daily | Cadence::Weekdays | Cadence::Weekly);
                (
                    note,
                    self.cadence == Cadence::Hourly,
                    self.cadence == Cadence::Custom && !self.cron.is_empty(),
                    uses_time,
                )
            }
        };
        Validation {
            prompt_note: (!prompt_valid)
                .then(|| Note::muted("Enter the prompt the agent gets on every run.")),
            folder_note,
            schedule_note,
            minute_invalid,
            cron_invalid,
            time_invalid,
            can_save: prompt_valid && self.folder_exists() && schedule.is_ok(),
        }
    }

    /// The automation Save writes, or `None` when the fields describe none.
    pub fn automation(
        &self,
        existing: Option<&Automation>,
        taken_ids: &BTreeSet<String>,
    ) -> Option<Automation> {
        if !self.folder_exists() || self.trimmed_prompt().is_empty() || self.agent_id.is_empty() {
            return None;
        }
        let schedule = self.schedule().ok()?;
        let optional = |text: &str| Some(text.trim().to_owned()).filter(|t| !t.is_empty());
        let name = optional(&self.name).unwrap_or_else(|| "Untitled automation".into());
        Some(Automation {
            id: existing.map_or_else(|| Automation::make_id(&name, taken_ids), |a| a.id.clone()),
            name,
            agent_id: self.agent_id.clone(),
            folder: self.folder.clone()?,
            prompt: self.trimmed_prompt().to_owned(),
            schedule,
            enabled: self.enabled,
            workspace: if self.worktree {
                AutomationWorkspace::Worktree { base_branch: optional(&self.base_branch) }
            } else {
                AutomationWorkspace::Folder
            },
            session: self.session(),
            grace_minutes: self.grace_minutes,
            precheck: optional(&self.precheck),
            precheck_timeout_seconds: self.precheck_timeout_seconds,
            model: optional(&self.model),
        })
    }
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone;
    use chrono_tz::Europe::Berlin;

    use super::*;

    fn now() -> DateTime<Utc> {
        Berlin.with_ymd_and_hms(2026, 10, 29, 8, 0, 0).single().expect("date").with_timezone(&Utc)
    }

    fn values(folder: &str) -> FormValues {
        let mut values = FormValues::load(None, None);
        values.folder = Some(folder.to_owned());
        values.prompt = "  Audit the repo.  ".into();
        values
    }

    #[test]
    fn a_new_automation_starts_on_weekdays_at_nine_with_omp_and_the_default_grace() {
        let values = FormValues::load(None, None);
        assert_eq!(values.cadence, Cadence::Weekdays);
        assert_eq!(values.time, AutomationCadence::time(9, 0));
        assert_eq!(values.grace_minutes, Automation::DEFAULT_GRACE_MINUTES);
        assert_eq!(values.precheck_timeout_seconds, Automation::DEFAULT_PRECHECK_TIMEOUT_SECONDS);
        assert!(values.enabled);
        assert_eq!(values.folder, None);
    }

    #[test]
    fn a_template_prefills_its_name_prompt_schedule_and_grace() {
        let template = &AutomationTemplate::all()[3];
        let values = FormValues::load(None, Some(template));
        assert_eq!(values.name, "Hourly maintenance check");
        assert_eq!(values.cadence, Cadence::Hourly);
        assert_eq!(values.minute, "15");
        assert_eq!(values.grace_minutes, 30);
    }

    #[test]
    fn save_waits_for_a_prompt_an_existing_folder_and_a_schedule() {
        let directory = tempfile::tempdir().expect("temp dir");
        let folder = directory.path().to_string_lossy().into_owned();
        let mut values = values(&folder);
        assert!(values.validation(now(), Berlin).can_save);
        assert_eq!(
            values.validation(now(), Berlin).schedule_note.text,
            format!("Next run Oct 29, {}", AutomationCadence::time(9, 0))
        );

        values.prompt = " ".into();
        let validation = values.validation(now(), Berlin);
        assert!(!validation.can_save);
        assert_eq!(
            validation.prompt_note.map(|n| n.text).as_deref(),
            Some("Enter the prompt the agent gets on every run.")
        );

        let mut missing = super::tests::values("/no/such/folder");
        assert_eq!(
            missing.validation(now(), Berlin).folder_note,
            Some(Note::error("This folder doesn't exist."))
        );
        missing.folder = None;
        assert_eq!(
            missing.validation(now(), Berlin).folder_note,
            Some(Note::muted("Choose the folder its runs work in."))
        );
    }

    #[test]
    fn schedules_report_why_they_are_not_one() {
        let directory = tempfile::tempdir().expect("temp dir");
        let mut values = values(&directory.path().to_string_lossy());
        values.cadence = Cadence::Hourly;
        values.minute = "75".into();
        let validation = values.validation(now(), Berlin);
        assert!(validation.minute_invalid);
        assert_eq!(validation.schedule_note, Note::error("Enter a minute from 0 to 59."));

        values.cadence = Cadence::Custom;
        let quiet = values.validation(now(), Berlin);
        assert_eq!(quiet.schedule_note, Note::muted("Enter a five-field cron, e.g. 0 9 * * 1-5."));
        assert!(!quiet.cron_invalid);

        values.cron = "0 9 * *".into();
        let invalid = values.validation(now(), Berlin);
        assert!(invalid.cron_invalid);
        assert!(invalid.schedule_note.is_error);

        values.cron = "0 0 31 2 *".into();
        assert_eq!(values.validation(now(), Berlin).schedule_note.text, "This schedule never runs.");
    }

    #[test]
    fn saving_builds_the_automation_the_fields_describe() {
        let directory = tempfile::tempdir().expect("temp dir");
        let folder = directory.path().to_string_lossy().into_owned();
        let mut values = values(&folder);
        values.name = "Nightly review".into();
        values.cadence = Cadence::Weekly;
        values.weekday = 4;
        values.time = "2:30 PM".into();
        values.worktree = true;
        values.reuse = true;
        values.base_branch = " origin/main ".into();
        values.precheck = "  ".into();
        values.model = " gpt-5 ".into();
        let taken = BTreeSet::from(["nightly-review".to_owned()]);

        let automation = values.automation(None, &taken).expect("automation");

        assert_eq!(automation.id, "nightly-review-2");
        assert_eq!(automation.prompt, "Audit the repo.");
        assert_eq!(automation.schedule.expression, "30 14 * * 4");
        assert_eq!(
            automation.workspace,
            AutomationWorkspace::Worktree { base_branch: Some("origin/main".into()) }
        );
        // A worktree run is always fresh.
        assert_eq!(automation.session, AutomationSession::Fresh);
        assert_eq!(automation.precheck, None);
        assert_eq!(automation.model.as_deref(), Some("gpt-5"));

        values.name = " ".into();
        assert_eq!(
            values.automation(None, &BTreeSet::new()).map(|a| a.name).as_deref(),
            Some("Untitled automation")
        );
    }

    #[test]
    fn times_read_in_twelve_or_twenty_four_hours() {
        assert_eq!(parse_time("9:00 AM"), Some((9, 0)));
        assert_eq!(parse_time(&AutomationCadence::time(14, 30)), Some((14, 30)));
        assert_eq!(parse_time("12:15 am"), Some((0, 15)));
        assert_eq!(parse_time("12:00 PM"), Some((12, 0)));
        assert_eq!(parse_time("9:05pm"), Some((21, 5)));
        assert_eq!(parse_time("21:30"), Some((21, 30)));
        assert_eq!(parse_time("24:00"), None);
        assert_eq!(parse_time("13:00 PM"), None);
        assert_eq!(parse_time("9"), None);
    }

    #[test]
    fn unusual_grace_and_timeouts_join_the_choices_in_order() {
        let grace = grace_options(90);
        assert_eq!(
            grace.iter().map(|(m, _)| *m).collect::<Vec<_>>(),
            [0, 30, 60, 90, 180, 720, 1_440, 2_880]
        );
        assert_eq!(grace[3].1, "1 hour 30 minutes");
        assert_eq!(timeout_options(45)[1], (45, "45 sec".into()));
    }

    #[test]
    fn folder_choices_list_automation_folders_then_project_folders_by_name() {
        let root = tempfile::tempdir().expect("temp dir");
        for name in ["zeta", "Alpha", ".hidden"] {
            std::fs::create_dir(root.path().join(name)).expect("folder");
        }
        std::fs::write(root.path().join("file.txt"), "").expect("file");
        let mut automation = FormValues::load(None, None);
        automation.folder = Some("/tmp".into());
        let existing = Automation {
            id: "a".into(),
            name: "A".into(),
            agent_id: "omp".into(),
            folder: "/srv/app".into(),
            prompt: "x".into(),
            schedule: CronSchedule::parse("0 9 * * *").expect("cron"),
            enabled: true,
            workspace: AutomationWorkspace::Folder,
            session: AutomationSession::Fresh,
            grace_minutes: 720,
            precheck: None,
            precheck_timeout_seconds: 60,
            model: None,
        };
        let choices = folder_choices(&[existing], &[root.path().to_string_lossy().into_owned()]);
        let names: Vec<String> = choices
            .iter()
            .map(|c| Path::new(c).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default())
            .collect();
        assert_eq!(names, ["app", "Alpha", "zeta"]);
    }
}
