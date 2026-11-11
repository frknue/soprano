//! `OmpUsageStatistics` against a scratch database with omp's `messages` table (never the user's
//! `~/.omp/stats.db`, and never `omp stats`).

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use chrono::{Local, TimeDelta, TimeZone};
use rusqlite::{Connection, params};
use soprano_agents::usage::*;

/// omp's own table.
const SCHEMA: &str = "
    CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_file TEXT NOT NULL, entry_id TEXT NOT NULL, folder TEXT NOT NULL,
        model TEXT NOT NULL, provider TEXT NOT NULL, api TEXT NOT NULL, timestamp INTEGER NOT NULL,
        duration INTEGER, ttft INTEGER, stop_reason TEXT NOT NULL, error_message TEXT,
        input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
        cache_read_tokens INTEGER NOT NULL, cache_write_tokens INTEGER NOT NULL,
        total_tokens INTEGER NOT NULL, premium_requests REAL NOT NULL,
        cost_input REAL NOT NULL, cost_output REAL NOT NULL, cost_cache_read REAL NOT NULL,
        cost_cache_write REAL NOT NULL, cost_total REAL NOT NULL, cost_no_cache_input REAL,
        cost_unpriced INTEGER NOT NULL DEFAULT 0, agent_type TEXT NOT NULL DEFAULT 'main',
        service_tier TEXT, UNIQUE(session_file, entry_id)
    );
";

const INSERT: &str = "
    INSERT INTO messages (session_file, entry_id, folder, model, provider, api, timestamp, stop_reason,
        input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, total_tokens, premium_requests,
        cost_input, cost_output, cost_cache_read, cost_cache_write, cost_total, cost_no_cache_input,
        agent_type)
    VALUES ('s.jsonl', ?1, ?2, ?3, ?4, 'api', ?5, ?6,
        ?7, ?8, ?9, ?10, ?11, 0,
        ?12, ?13, ?14, ?15, ?16, ?17,
        ?18)
";

/// One recorded model request.
struct Request {
    at: UsageDate,
    provider: &'static str,
    model: &'static str,
    agent: &'static str,
    folder: &'static str,
    stop_reason: &'static str,
    /// Input, output, cache read, cache write.
    tokens: [i64; 4],
    costs: [f64; 4],
    no_cache_input: Option<f64>,
}

impl Request {
    fn at(at: UsageDate) -> Self {
        Self {
            at,
            provider: "anthropic",
            model: "claude-opus-5-5",
            agent: "main",
            folder: "-git-app",
            stop_reason: "stop",
            tokens: [100, 50, 1000, 200],
            costs: [0.125, 0.5, 0.0625, 0.25],
            no_cache_input: Some(1.0),
        }
    }
}

/// A scratch directory holding `stats.db`.
struct Scratch {
    _directory: tempfile::TempDir,
    path: PathBuf,
}

impl Scratch {
    /// The directory alone: omp never synced.
    fn empty() -> Self {
        let directory = tempfile::tempdir().expect("temp dir");
        let path = directory.path().join("stats.db");
        Self { _directory: directory, path }
    }

    fn with(requests: &[Request]) -> Self {
        let scratch = Self::empty();
        let database = Connection::open(&scratch.path).expect("database");
        database.execute_batch(SCHEMA).expect("schema");
        for (index, request) in requests.iter().enumerate() {
            let [input, output, cache_read, cache_write] = request.tokens;
            let [cost_input, cost_output, cost_cache_read, cost_cache_write] = request.costs;
            database
                .execute(
                    INSERT,
                    params![
                        format!("e{index}"),
                        request.folder,
                        request.model,
                        request.provider,
                        request.at.timestamp_millis(),
                        request.stop_reason,
                        input,
                        output,
                        cache_read,
                        cache_write,
                        request.tokens.iter().sum::<i64>(),
                        cost_input,
                        cost_output,
                        cost_cache_read,
                        cost_cache_write,
                        request.costs.iter().sum::<f64>(),
                        request.no_cache_input,
                        request.agent,
                    ],
                )
                .expect("insert");
        }
        scratch
    }

    fn statistics(&self) -> OmpUsageStatistics {
        OmpUsageStatistics::new(self.path.clone(), || Ok(()))
    }
}

/// A time on a day of October 2026 in the zone the tests run in, which is the one SQLite's
/// `'localtime'` uses.
fn local(day: u32, hour: u32, minute: u32) -> UsageDate {
    Local.with_ymd_and_hms(2026, 10, day, hour, minute, 0).earliest().expect("local time").to_utc()
}

fn requests() -> Vec<Request> {
    vec![
        Request::at(local(30, 10, 15)),
        Request { stop_reason: "error", no_cache_input: None, ..Request::at(local(30, 10, 45)) },
        Request { agent: "subagent", ..Request::at(local(30, 11, 5)) },
        Request {
            provider: "xai-oauth",
            model: "grok-5",
            costs: [0.0; 4],
            no_cache_input: None,
            ..Request::at(local(30, 12, 0))
        },
        Request::at(local(29, 23, 59)),
    ]
}

fn sorted(mut groups: Vec<UsageGroup>) -> Vec<UsageGroup> {
    groups.sort_by(|a, b| (a.start, &a.model, &a.agent).cmp(&(b.start, &b.model, &b.agent)));
    groups
}

fn starts(groups: &[UsageGroup]) -> Vec<UsageDate> {
    groups.iter().map(|group| group.start).collect()
}

#[test]
fn requests_are_summed_per_local_hour_model_agent_and_folder_since_the_cutoff() {
    let scratch = Scratch::with(&requests());

    let groups = scratch.statistics().groups(Some(local(30, 0, 0)), UsageGranularity::Hour).expect("groups");
    let groups = sorted(groups);

    assert_eq!(starts(&groups), [local(30, 10, 0), local(30, 11, 0), local(30, 12, 0)]);
    let ten = &groups[0];
    assert_eq!((ten.provider.as_str(), ten.model.as_str()), ("anthropic", "claude-opus-5-5"));
    assert_eq!(ten.agent, "main");
    assert_eq!(ten.totals.requests, 2);
    assert_eq!(ten.totals.failed_requests, 1);
    assert_eq!(ten.totals.input_tokens, 200);
    assert_eq!(ten.totals.output_tokens, 100);
    assert_eq!(ten.totals.cache_read_tokens, 2000);
    assert_eq!(ten.totals.cache_write_tokens, 400);
    assert_eq!(ten.totals.cost(), 1.875);
    assert_eq!(ten.totals.unpriced_requests, 0);
    // Only the request that reported its uncached price counts toward the savings.
    assert_eq!(ten.totals.cached_prompt_cost, 0.4375);
    assert_eq!(ten.totals.uncached_prompt_cost, 1.0);
    assert_eq!(ten.totals.cache_savings(), 0.5625);
    assert_eq!(ten.totals.cache_hit_rate(), Some(2000.0 / 2600.0));
    assert_eq!(groups[1].agent, "subagent");
    assert_eq!(groups[1].totals.failed_requests, 0);
    assert_eq!(groups[2].provider, "xai-oauth");
    assert_eq!(groups[2].totals.unpriced_requests, 1);
    assert_eq!(groups[2].totals.cost(), 0.0);
    assert_eq!(groups[2].totals.cache_savings(), 0.0);
    assert!(groups.iter().all(|group| group.folder == "-git-app"));
}

#[test]
fn daily_grouping_merges_the_hours_of_a_local_day() {
    let scratch = Scratch::with(&requests());

    let groups = scratch.statistics().groups(None, UsageGranularity::Day).expect("groups");

    assert_eq!(groups.len(), 4);
    let opus_main: Vec<UsageGroup> = sorted(groups)
        .into_iter()
        .filter(|group| group.model == "claude-opus-5-5" && group.agent == "main")
        .collect();
    assert_eq!(starts(&opus_main), [local(29, 0, 0), local(30, 0, 0)]);
    assert_eq!(opus_main.iter().map(|group| group.totals.requests).collect::<Vec<_>>(), [1, 2]);
}

#[test]
fn the_cutoff_keeps_the_request_at_it_and_drops_the_ones_before() {
    let scratch = Scratch::with(&requests());
    let statistics = scratch.statistics();
    let at = local(30, 11, 5);

    let hourly = |since: Option<UsageDate>| statistics.groups(since, UsageGranularity::Hour).expect("groups");
    let from = sorted(hourly(Some(at)));
    let after = hourly(Some(at + TimeDelta::milliseconds(1)));
    // A cutoff inside a millisecond is rounded down to it.
    let within = hourly(Some(at + TimeDelta::microseconds(900)));
    let everything = hourly(None);

    assert_eq!(starts(&from), [local(30, 11, 0), local(30, 12, 0)]);
    assert_eq!(starts(&after), [local(30, 12, 0)]);
    assert_eq!(within.len(), 2);
    assert_eq!(everything.len(), 4);
}

#[test]
fn folders_and_days_feed_the_summary() {
    let mut recorded = requests();
    recorded.push(Request { folder: "/opt-work/", ..Request::at(local(30, 9, 0)) });
    let scratch = Scratch::with(&recorded);
    let now = local(30, 13, 0);

    let statistics = scratch.statistics();
    let history = usage_history(&statistics, UsagePeriod::Week, false, now, &Local).expect("history");
    let summary = history.summary(None);

    assert_eq!(summary.totals.requests, 6);
    assert_eq!(summary.totals.failed_requests, 1);
    assert_eq!(summary.totals.unpriced_requests, 1);
    assert_eq!(summary.buckets.len(), 7);
    let bars: Vec<u64> = summary.buckets.iter().map(|bucket| bucket.totals.requests).collect();
    assert_eq!(bars, [0, 0, 0, 0, 0, 1, 5]);
    let folders: Vec<(&str, u64)> =
        summary.folders.iter().map(|row| (row.key.as_str(), row.totals.requests)).collect();
    assert_eq!(folders, [("-git-app", 5), ("/opt-work/", 1)]);
    let agents: Vec<(&str, u64)> =
        summary.agents.iter().map(|row| (row.key.as_str(), row.totals.requests)).collect();
    assert_eq!(agents, [("main", 5), ("subagent", 1)]);
}

#[test]
fn no_database_yet_is_no_history() {
    let scratch = Scratch::empty();

    assert_eq!(scratch.statistics().groups(None, UsageGranularity::Day), Ok(Vec::new()));
    assert_eq!(scratch.statistics().groups(None, UsageGranularity::Hour), Ok(Vec::new()));
    assert!(!scratch.path.exists(), "reading must not create the database");
}

#[test]
fn a_database_without_omps_table_is_an_error() {
    let scratch = Scratch::empty();
    Connection::open(&scratch.path)
        .and_then(|database| database.execute_batch("CREATE TABLE other (id INTEGER)"))
        .expect("database");

    let result = scratch.statistics().groups(None, UsageGranularity::Day);

    match result {
        Err(UsageStatisticsError::Database(message)) => {
            assert!(message.contains("no such table"), "{message}");
        }
        other => panic!("expected a database error, got {other:?}"),
    }
}

/// The first time in 2026 the local clock is set back by an hour onto a full hour; `None` where
/// it never is.
fn clocks_go_back() -> Option<UsageDate> {
    let offset = |seconds: i64| {
        Local.timestamp_opt(seconds, 0).single().map(|date| i64::from(date.offset().local_minus_utc()))
    };
    // 2026-01-01 to 2027-01-01 UTC, in quarter hours (no zone changes its clock off them).
    let change = (1_767_225_600_i64..1_798_761_600).step_by(900).find(|&seconds| {
        offset(seconds).zip(offset(seconds - 900)).is_some_and(|(after, before)| after < before)
    })?;
    let (before, after) = (offset(change - 1)?, offset(change)?);
    if before - after != 3600 || (change + after) % 3600 != 0 {
        return None;
    }
    Local.timestamp_opt(change, 0).single().map(|date| date.to_utc())
}

/// When clocks go back, the repeated local hour is two real hours and two bars.
#[test]
fn the_repeated_hour_of_a_clock_change_stays_two_hours() {
    let Some(change) = clocks_go_back() else { return };
    let first = change - TimeDelta::minutes(30);
    let second = change + TimeDelta::minutes(30);
    let scratch = Scratch::with(&[Request::at(first), Request::at(second)]);

    let groups = sorted(scratch.statistics().groups(None, UsageGranularity::Hour).expect("groups"));

    assert_eq!(starts(&groups), [change - TimeDelta::hours(1), change]);
    assert_eq!(groups.iter().map(|group| group.totals.requests).collect::<Vec<_>>(), [1, 1]);
    let history = UsageHistory::new(UsagePeriod::Day, second + TimeDelta::minutes(1), groups, None, &Local);
    let bars: Vec<u64> = history.summary(None).buckets.iter().map(|bucket| bucket.totals.requests).collect();
    assert_eq!(bars.len(), 25);
    assert_eq!(bars[23..], [1, 1]);
}

#[test]
fn the_database_lives_in_omps_config_root() {
    let home = Path::new("/Users/ada");
    let path = |setting: Option<&str>| OmpUsageStatistics::default_database_path(setting, home);

    assert_eq!(path(None), Path::new("/Users/ada/.omp/stats.db"));
    assert_eq!(path(Some("")), Path::new("/Users/ada/.omp/stats.db"));
    assert_eq!(path(Some(".omp-work")), Path::new("/Users/ada/.omp-work/stats.db"));
    assert_eq!(path(Some("config/./omp/")), Path::new("/Users/ada/config/omp/stats.db"));
    // omp joins the setting onto home (`path.join`), absolute or not.
    assert_eq!(path(Some("/srv/omp")), Path::new("/Users/ada/srv/omp/stats.db"));
    assert_eq!(path(Some("../shared/omp")), Path::new("/Users/shared/omp/stats.db"));
}

#[test]
fn a_sync_runs_what_the_owner_gave_it_and_reports_its_failure() {
    let runs = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&runs);
    let working = OmpUsageStatistics::new(PathBuf::from("/nonexistent/stats.db"), move || {
        counted.fetch_add(1, Ordering::SeqCst);
        Ok(())
    });
    let failing = OmpUsageStatistics::new(PathBuf::from("/nonexistent/stats.db"), || {
        Err("omp stats exited with status 1".to_owned())
    });

    assert_eq!(working.sync(), Ok(()));
    assert_eq!(working.sync(), Ok(()));
    assert_eq!(runs.load(Ordering::SeqCst), 2);
    assert_eq!(failing.sync(), Err(UsageStatisticsError::Sync("omp stats exited with status 1".into())));
}

#[test]
fn a_failed_sync_still_reads_the_database() {
    let scratch = Scratch::with(&requests());
    let statistics =
        OmpUsageStatistics::new(scratch.path.clone(), || Err("omp stats exited with status 1".to_owned()));

    let history =
        usage_history(&statistics, UsagePeriod::Week, true, local(30, 13, 0), &Local).expect("history");

    assert_eq!(history.sync_error.as_deref(), Some("omp stats exited with status 1"));
    assert_eq!(history.groups.len(), 4);
    assert_eq!(history.summary(None).totals.requests, 5);

    let unsynced =
        usage_history(&statistics, UsagePeriod::Week, false, local(30, 13, 0), &Local).expect("history");
    assert_eq!(unsynced.sync_error, None);
}
