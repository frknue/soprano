//! The runs automations made and when each is due next (`Automations/AutomationStore.swift`):
//! app state in `<data dir>/automations.json`, not in `settings.json`, which only says what the
//! automations are.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use soprano_platform::AppIdentity;

use crate::run::AutomationRun;
use crate::scheduling::ScheduleState;

#[derive(Default, Serialize, Deserialize)]
struct Document {
    #[serde(default)]
    runs: Vec<AutomationRun>,
    #[serde(default)]
    schedules: BTreeMap<String, ScheduleState>,
}

#[derive(Debug)]
pub struct AutomationStore {
    file: Option<PathBuf>,
    schedules: BTreeMap<String, ScheduleState>,
    /// Oldest first.
    runs: Vec<AutomationRun>,
    revision: u64,
}

impl AutomationStore {
    /// Finished runs kept per automation; unfinished ones are always kept.
    pub const FINISHED_RUN_LIMIT: usize = 100;

    /// `file` `None` keeps everything in memory, for tests. A missing or unreadable file starts
    /// empty.
    pub fn new(file: Option<PathBuf>) -> Self {
        let document = file
            .as_deref()
            .and_then(|path| std::fs::read(path).ok())
            .and_then(|data| match serde_json::from_slice::<Document>(&data) {
                Ok(document) => Some(document),
                Err(error) => {
                    tracing::warn!("Soprano: could not read automations: {error}");
                    None
                }
            })
            .unwrap_or_default();
        Self { file, schedules: document.schedules, runs: document.runs, revision: 0 }
    }

    /// `<data dir>/automations.json`: dev and installed builds have their own data folders, so
    /// their automations never record into each other's history.
    pub fn default_file(identity: &AppIdentity) -> PathBuf {
        soprano_platform::paths::data_dir(identity).join("automations.json")
    }

    pub fn file(&self) -> Option<&Path> {
        self.file.as_deref()
    }

    /// Counts every change, so a view can tell whether anything moved.
    pub fn revision(&self) -> u64 {
        self.revision
    }

    // MARK: - Reading

    pub fn schedules(&self) -> &BTreeMap<String, ScheduleState> {
        &self.schedules
    }

    /// Every run, oldest first.
    pub fn all_runs(&self) -> &[AutomationRun] {
        &self.runs
    }

    pub fn run(&self, id: &str) -> Option<&AutomationRun> {
        self.runs.iter().rev().find(|run| run.id == id)
    }

    /// Newest first.
    pub fn runs(&self, automation_id: &str) -> Vec<AutomationRun> {
        self.runs.iter().rev().filter(|run| run.automation_id == automation_id).cloned().collect()
    }

    pub fn last_run(&self, automation_id: &str) -> Option<&AutomationRun> {
        self.runs.iter().rev().find(|run| run.automation_id == automation_id)
    }

    pub fn open_runs(&self) -> Vec<AutomationRun> {
        self.runs.iter().filter(|run| !run.status.is_final()).cloned().collect()
    }

    pub fn next_run_number(&self, automation_id: &str) -> i64 {
        self.runs
            .iter()
            .filter(|run| run.automation_id == automation_id)
            .map(|run| run.number)
            .max()
            .unwrap_or(0)
            + 1
    }

    // MARK: - Writing

    pub fn set_schedule(&mut self, automation_id: &str, state: Option<ScheduleState>) {
        if self.schedules.get(automation_id) == state.as_ref() {
            return;
        }
        match state {
            Some(state) => self.schedules.insert(automation_id.to_owned(), state),
            None => self.schedules.remove(automation_id),
        };
        self.save();
    }

    pub fn insert(&mut self, run: AutomationRun) {
        let automation_id = run.automation_id.clone();
        self.runs.push(run);
        self.prune(&automation_id);
        self.save();
    }

    pub fn update(&mut self, id: &str, change: impl FnOnce(&mut AutomationRun)) {
        let Some(index) = self.runs.iter().rposition(|run| run.id == id) else { return };
        let mut run = self.runs[index].clone();
        change(&mut run);
        if run == self.runs[index] {
            return;
        }
        self.runs[index] = run;
        self.save();
    }

    /// Forgets an automation's runs and schedule, as deleting it does.
    pub fn remove_all(&mut self, automation_id: &str) {
        self.runs.retain(|run| run.automation_id != automation_id);
        self.schedules.remove(automation_id);
        self.save();
    }

    fn prune(&mut self, automation_id: &str) {
        let finished: Vec<usize> = (0..self.runs.len())
            .filter(|&i| self.runs[i].automation_id == automation_id && self.runs[i].status.is_final())
            .collect();
        let Some(excess) = finished.len().checked_sub(Self::FINISHED_RUN_LIMIT).filter(|&n| n > 0) else {
            return;
        };
        let dropped: std::collections::HashSet<usize> = finished.into_iter().take(excess).collect();
        let mut index = 0;
        self.runs.retain(|_| {
            let keep = !dropped.contains(&index);
            index += 1;
            keep
        });
    }

    fn save(&mut self) {
        self.revision += 1;
        let Some(file) = &self.file else { return };
        if let Err(error) = write_document(file, &self.runs, &self.schedules) {
            tracing::warn!("Soprano: could not save automations to {}: {error}", file.display());
        }
    }
}

fn write_document(
    file: &Path,
    runs: &[AutomationRun],
    schedules: &BTreeMap<String, ScheduleState>,
) -> std::io::Result<()> {
    #[derive(Serialize)]
    struct DocumentRef<'a> {
        runs: &'a [AutomationRun],
        schedules: &'a BTreeMap<String, ScheduleState>,
    }
    let directory = file.parent().unwrap_or(Path::new("."));
    std::fs::create_dir_all(directory)?;
    let mut value = serde_json::to_value(DocumentRef { runs, schedules }).map_err(std::io::Error::other)?;
    // Sorted keys, as the Swift app wrote the file.
    sort_keys(&mut value);
    let data = serde_json::to_vec(&value).map_err(std::io::Error::other)?;
    let temporary = directory.join(format!(".automations.json.{}.tmp", std::process::id()));
    std::fs::write(&temporary, data)?;
    std::fs::rename(&temporary, file).inspect_err(|_| {
        let _ = std::fs::remove_file(&temporary);
    })
}

fn sort_keys(value: &mut Value) {
    match value {
        Value::Object(map) => {
            map.sort_keys();
            map.values_mut().for_each(sort_keys);
        }
        Value::Array(items) => items.iter_mut().for_each(sort_keys),
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use chrono::{DateTime, Utc};

    use super::*;
    use crate::run::{RunStatus, RunTrigger};

    fn run(number: i64, status: RunStatus, automation_id: &str) -> AutomationRun {
        AutomationRun::new(
            uuid::Uuid::new_v4().to_string(),
            automation_id,
            number,
            RunTrigger::Scheduled,
            DateTime::from_timestamp(number * 60, 0).expect("date"),
            status,
            "omp",
            "/tmp",
        )
    }

    #[test]
    fn runs_and_schedule_times_survive_a_reopened_store() {
        let directory = tempfile::tempdir().expect("temp dir");
        let file = directory.path().join("nested").join("automations.json");
        let next = DateTime::from_timestamp(1_800_000_000, 0).expect("date");

        let mut store = AutomationStore::new(Some(file.clone()));
        store.insert(run(1, RunStatus::Completed, "audit"));
        store.set_schedule(
            "audit",
            Some(ScheduleState { signature: "on 0 9 * * *".into(), next_run_at: Some(next) }),
        );

        let reopened = AutomationStore::new(Some(file.clone()));
        assert_eq!(reopened.runs("audit").iter().map(|r| r.number).collect::<Vec<_>>(), [1]);
        assert_eq!(reopened.schedules()["audit"].next_run_at, Some(next));
        assert_eq!(reopened.next_run_number("audit"), 2);
        let text = std::fs::read_to_string(&file).expect("file");
        assert!(text.starts_with(r#"{"runs":[{"automationId":"audit","folder":"/tmp","id":"#), "{text}");
    }

    #[test]
    fn only_the_newest_hundred_finished_runs_are_kept_but_unfinished_ones_always_stay() {
        let mut store = AutomationStore::new(None);
        store.insert(run(1, RunStatus::Running, "audit"));
        let last = AutomationStore::FINISHED_RUN_LIMIT as i64 + 6;
        for number in 2..=last {
            store.insert(run(number, RunStatus::Completed, "audit"));
        }
        store.insert(run(500, RunStatus::Completed, "other"));

        let audit = store.runs("audit");
        assert_eq!(audit.iter().filter(|r| r.status.is_final()).count(), AutomationStore::FINISHED_RUN_LIMIT);
        assert!(audit.iter().any(|r| r.number == 1));
        assert!(!audit.iter().any(|r| r.number == 2));
        assert_eq!(audit.first().map(|r| r.number), Some(last));
        assert_eq!(store.runs("other").len(), 1);
    }

    #[test]
    fn deleting_an_automation_forgets_its_runs_and_schedule_only() {
        let mut store = AutomationStore::new(None);
        store.insert(run(1, RunStatus::Completed, "audit"));
        store.insert(run(1, RunStatus::Completed, "other"));
        store.set_schedule(
            "audit",
            Some(ScheduleState { signature: "on 0 9 * * *".into(), next_run_at: Some(Utc::now()) }),
        );

        store.remove_all("audit");

        assert!(store.runs("audit").is_empty());
        assert!(!store.schedules().contains_key("audit"));
        assert_eq!(store.runs("other").len(), 1);
    }
}
