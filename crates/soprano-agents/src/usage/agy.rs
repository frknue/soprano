//! Reading Antigravity (`agy`) usage history from its JSONL transcripts, and combining
//! multiple [`UsageStatisticsService`] backends (omp + Antigravity) into one board feed.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, UNIX_EPOCH};

use chrono::{DateTime, Local, NaiveTime, TimeZone};
use serde_json::Value;

use crate::history::{
    discover_agy_transcript_paths, infer_agy_cwd_from_tool_call, read_jsonl_lines, short_model_name,
};
use crate::json::{number_int, objects_at, parse_object, str_at};
use crate::timeline::date_from_value;

use super::folder_name;
use super::statistics::{
    UsageDate, UsageGranularity, UsageGroup, UsageStatisticsError, UsageStatisticsService, UsageTotals,
    hour_start, local_instant,
};

/// Safety margin when skipping transcripts whose file mtime predates `since`.
const MTIME_SKIP_MARGIN: Duration = Duration::from_secs(3600);

/// Antigravity's usage history: each `PLANNER_RESPONSE` step in
/// `~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl` records the
/// model and token counts (`input_tokens`, `output_tokens`, `cache_read_tokens`). Antigravity
/// bills via subscription quota rather than per-token API rates, so requests with tokens are
/// counted as unpriced (full token, cache, and request tracking; `"Unpriced"` in Cost mode).
pub struct AgyUsageStatistics {
    home: PathBuf,
    temporary_directory: PathBuf,
}

impl AgyUsageStatistics {
    pub fn new(home: PathBuf, temporary_directory: PathBuf) -> Self {
        Self { home, temporary_directory }
    }
}

impl UsageStatisticsService for AgyUsageStatistics {
    fn sync(&self) -> Result<(), UsageStatisticsError> {
        Ok(())
    }

    fn groups(
        &self,
        since: Option<UsageDate>,
        granularity: UsageGranularity,
    ) -> Result<Vec<UsageGroup>, UsageStatisticsError> {
        Ok(read_agy_groups(&self.home, &self.temporary_directory, since, granularity, &Local))
    }
}

/// Merges several [`UsageStatisticsService`] sources into one stream for the statistics board.
///
/// `sync` runs every source and surfaces the first sync error (if any); `groups` reads every
/// source, merges matching `(start, provider, model, agent, folder)` buckets, and fails only
/// if every source failed to read.
pub struct CombinedUsageStatistics {
    services: Vec<Arc<dyn UsageStatisticsService>>,
}

impl CombinedUsageStatistics {
    pub fn new(services: Vec<Arc<dyn UsageStatisticsService>>) -> Self {
        Self { services }
    }
}

impl UsageStatisticsService for CombinedUsageStatistics {
    fn sync(&self) -> Result<(), UsageStatisticsError> {
        let mut first_error = None;
        for service in &self.services {
            if let Err(error) = service.sync()
                && first_error.is_none()
            {
                first_error = Some(error);
            }
        }
        match first_error {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }

    fn groups(
        &self,
        since: Option<UsageDate>,
        granularity: UsageGranularity,
    ) -> Result<Vec<UsageGroup>, UsageStatisticsError> {
        let mut merged: HashMap<GroupKey, UsageTotals> = HashMap::new();
        let mut succeeded = 0usize;
        let mut first_error = None;
        for service in &self.services {
            match service.groups(since, granularity) {
                Ok(groups) => {
                    succeeded += 1;
                    for group in groups {
                        let key = GroupKey {
                            start: group.start,
                            provider: group.provider,
                            model: group.model,
                            agent: group.agent,
                            folder: group.folder,
                        };
                        merged.entry(key).or_default().add(&group.totals);
                    }
                }
                Err(error) => {
                    if first_error.is_none() {
                        first_error = Some(error);
                    }
                }
            }
        }
        if succeeded == 0
            && let Some(error) = first_error
        {
            return Err(error);
        }
        Ok(merged
            .into_iter()
            .map(|(key, totals)| UsageGroup {
                start: key.start,
                provider: key.provider,
                model: key.model,
                agent: key.agent,
                folder: key.folder,
                totals,
            })
            .collect())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct GroupKey {
    start: UsageDate,
    provider: String,
    model: String,
    agent: String,
    folder: String,
}

fn read_agy_groups<Tz: TimeZone>(
    home: &Path,
    temporary_directory: &Path,
    since: Option<UsageDate>,
    granularity: UsageGranularity,
    tz: &Tz,
) -> Vec<UsageGroup> {
    let mut merged: HashMap<GroupKey, UsageTotals> = HashMap::new();
    for path in discover_agy_transcript_paths(home) {
        if let Some(cutoff) = since
            && let Some(modified) = file_modified_at(&path)
            && modified + chrono::Duration::from_std(MTIME_SKIP_MARGIN).unwrap_or_default() < cutoff
        {
            continue;
        }
        collect_transcript(&path, home, temporary_directory, since, granularity, tz, &mut merged);
    }
    merged
        .into_iter()
        .map(|(key, totals)| UsageGroup {
            start: key.start,
            provider: key.provider,
            model: key.model,
            agent: key.agent,
            folder: key.folder,
            totals,
        })
        .collect()
}

fn collect_transcript<Tz: TimeZone>(
    path: &Path,
    home: &Path,
    temporary_directory: &Path,
    since: Option<UsageDate>,
    granularity: UsageGranularity,
    tz: &Tz,
    merged: &mut HashMap<GroupKey, UsageTotals>,
) {
    let mut explicit_cwd: Option<String> = None;
    let mut inferred_git: Option<(String, Option<String>)> = None;
    let mut inferred_dir: Option<String> = None;
    let mut records: Vec<(UsageDate, String, UsageTotals)> = Vec::new();

    read_jsonl_lines(path, |line| {
        let Some(record) = parse_object(line) else { return };
        if let Some(cwd) = str_at(&record, "cwd").filter(|c| !c.is_empty()) {
            explicit_cwd = Some(cwd.to_owned());
        } else if explicit_cwd.is_none()
            && let Some(ws) = record
                .get("workspacePaths")
                .and_then(Value::as_array)
                .and_then(|arr| arr.iter().find_map(Value::as_str))
                .filter(|c| !c.is_empty())
        {
            explicit_cwd = Some(ws.to_owned());
        }

        if str_at(&record, "type") != Some("PLANNER_RESPONSE") {
            return;
        }

        if explicit_cwd.is_none() && inferred_git.is_none() {
            for call in objects_at(&record, "tool_calls") {
                infer_agy_cwd_from_tool_call(call, &mut inferred_git, &mut inferred_dir);
                if inferred_git.is_some() {
                    break;
                }
            }
        }

        let Some(timestamp) = date_from_value(record.get("created_at").or_else(|| record.get("timestamp")))
        else {
            return;
        };
        if since.is_some_and(|cutoff| timestamp < cutoff) {
            return;
        }

        let model = str_at(&record, "model")
            .filter(|m| !m.is_empty())
            .map(short_model_name)
            .unwrap_or_else(|| "antigravity".to_owned());
        let input_tokens = token_count(record.get("input_tokens"));
        let output_tokens = token_count(record.get("output_tokens"));
        let cache_read_tokens = token_count(record.get("cache_read_tokens"));
        let cache_write_tokens = token_count(record.get("cache_write_tokens"));
        let failed = matches!(str_at(&record, "status"), Some("ERROR" | "FAILED"))
            || str_at(&record, "error").is_some_and(|e| !e.trim().is_empty());
        let total_tokens = input_tokens + output_tokens + cache_read_tokens + cache_write_tokens;
        let totals = UsageTotals {
            requests: 1,
            failed_requests: u64::from(failed),
            input_tokens,
            output_tokens,
            cache_read_tokens,
            cache_write_tokens,
            unpriced_requests: u64::from(total_tokens > 0),
            ..UsageTotals::default()
        };
        records.push((timestamp, model, totals));
    });

    if records.is_empty() {
        return;
    }

    let cwd_path = explicit_cwd
        .or_else(|| inferred_git.map(|(root, _)| root))
        .or(inferred_dir)
        .map(PathBuf::from)
        .unwrap_or_else(|| home.to_path_buf());
    let folder = folder_name::encode(&cwd_path, home, temporary_directory);

    for (timestamp, model, totals) in records {
        let start = bucket_start(timestamp, granularity, tz);
        let key = GroupKey {
            start,
            provider: "antigravity".to_owned(),
            model,
            agent: "antigravity".to_owned(),
            folder: folder.clone(),
        };
        merged.entry(key).or_default().add(&totals);
    }
}

fn bucket_start<Tz: TimeZone>(date: UsageDate, granularity: UsageGranularity, tz: &Tz) -> UsageDate {
    match granularity {
        UsageGranularity::Hour => hour_start(date, tz),
        UsageGranularity::Day => {
            let day = date.with_timezone(tz).date_naive();
            local_instant(day.and_time(NaiveTime::MIN), tz)
        }
    }
}

fn token_count(value: Option<&Value>) -> u64 {
    number_int(value).and_then(|n| u64::try_from(n).ok()).unwrap_or(0)
}

fn file_modified_at(path: &Path) -> Option<UsageDate> {
    let modified = std::fs::metadata(path).ok()?.modified().ok()?;
    let millis = modified.duration_since(UNIX_EPOCH).ok()?.as_millis();
    DateTime::from_timestamp_millis(i64::try_from(millis).ok()?)
}

#[cfg(test)]
mod tests {
    use chrono::FixedOffset;

    use super::*;

    fn zone() -> FixedOffset {
        FixedOffset::east_opt(3600).expect("offset")
    }

    #[test]
    fn agy_usage_statistics_aggregates_planner_tokens_by_model_folder_and_day() {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("home");
        let temp = root.path().join("tmp");
        let project = home.join("git/soprano");
        std::fs::create_dir_all(project.join(".git")).unwrap();
        std::fs::write(project.join(".git/HEAD"), "ref: refs/heads/main\n").unwrap();
        std::fs::create_dir_all(&temp).unwrap();

        let log_dir = home.join(".gemini/antigravity-cli/brain/conv-1/.system_generated/logs");
        std::fs::create_dir_all(&log_dir).unwrap();
        let transcript = format!(
            concat!(
                "{{\"type\":\"USER_INPUT\",\"created_at\":\"2026-11-25T10:00:00Z\",\"content\":\"hi\"}}\n",
                "{{\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"created_at\":\"2026-11-25T10:05:00Z\",",
                "\"model\":\"gemini-4-neon-high\",\"input_tokens\":1000,\"cache_read_tokens\":250,\"output_tokens\":200,",
                "\"tool_calls\":[{{\"name\":\"read_file\",\"args\":{{\"Path\":\"{}/Cargo.toml\"}}}}]}}\n",
                "{{\"type\":\"PLANNER_RESPONSE\",\"status\":\"ERROR\",\"created_at\":\"2026-11-25T11:15:00Z\",",
                "\"model\":\"gemini-4-neon-high\",\"input_tokens\":500,\"cache_read_tokens\":0,\"output_tokens\":50}}\n"
            ),
            project.display()
        );
        std::fs::write(log_dir.join("transcript.jsonl"), transcript).unwrap();

        let groups = read_agy_groups(&home, &temp, None, UsageGranularity::Day, &zone());
        assert_eq!(groups.len(), 1);
        let group = &groups[0];
        assert_eq!(group.provider, "antigravity");
        assert_eq!(group.model, "gemini-4-neon-high");
        assert_eq!(group.agent, "antigravity");
        assert_eq!(group.folder, "-git-soprano");
        assert_eq!(group.totals.requests, 2);
        assert_eq!(group.totals.failed_requests, 1);
        assert_eq!(group.totals.input_tokens, 1_500);
        assert_eq!(group.totals.cache_read_tokens, 250);
        assert_eq!(group.totals.output_tokens, 250);
        assert_eq!(group.totals.unpriced_requests, 2);
        assert_eq!(group.totals.tokens(), 2_000);
        assert_eq!(group.totals.cost(), 0.0);

        let cutoff = DateTime::parse_from_rfc3339("2026-11-25T11:00:00Z").unwrap().to_utc();
        let filtered = read_agy_groups(&home, &temp, Some(cutoff), UsageGranularity::Hour, &zone());
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].totals.requests, 1);
        assert_eq!(filtered[0].totals.input_tokens, 500);
    }

    struct StubService {
        sync_result: Result<(), UsageStatisticsError>,
        groups_result: Result<Vec<UsageGroup>, UsageStatisticsError>,
    }

    impl UsageStatisticsService for StubService {
        fn sync(&self) -> Result<(), UsageStatisticsError> {
            self.sync_result.clone()
        }

        fn groups(
            &self,
            _: Option<UsageDate>,
            _: UsageGranularity,
        ) -> Result<Vec<UsageGroup>, UsageStatisticsError> {
            self.groups_result.clone()
        }
    }

    #[test]
    fn combined_usage_statistics_merges_sources_and_keeps_working_when_one_source_fails() {
        let start = DateTime::from_timestamp(1_793_000_000, 0).unwrap();
        let group_a = UsageGroup {
            start,
            provider: "antigravity".into(),
            model: "gemini-4-neon-high".into(),
            agent: "antigravity".into(),
            folder: "-git-app".into(),
            totals: UsageTotals { requests: 2, input_tokens: 100, ..UsageTotals::default() },
        };
        let group_b = UsageGroup {
            start,
            provider: "anthropic".into(),
            model: "claude-opus-5-5".into(),
            agent: "main".into(),
            folder: "-git-app".into(),
            totals: UsageTotals { requests: 1, output_cost: 1.5, ..UsageTotals::default() },
        };

        let combined = CombinedUsageStatistics::new(vec![
            Arc::new(StubService {
                sync_result: Err(UsageStatisticsError::Sync("omp unavailable".into())),
                groups_result: Ok(vec![group_b]),
            }),
            Arc::new(StubService { sync_result: Ok(()), groups_result: Ok(vec![group_a.clone()]) }),
        ]);

        assert!(combined.sync().is_err());
        let groups = combined.groups(None, UsageGranularity::Day).unwrap();
        assert_eq!(groups.len(), 2);

        // Even if one reader fails completely, the other source still serves its records.
        let partial = CombinedUsageStatistics::new(vec![
            Arc::new(StubService {
                sync_result: Ok(()),
                groups_result: Err(UsageStatisticsError::Database("missing".into())),
            }),
            Arc::new(StubService { sync_result: Ok(()), groups_result: Ok(vec![group_a]) }),
        ]);
        let groups = partial.groups(None, UsageGranularity::Day).unwrap();
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].provider, "antigravity");
    }
}
