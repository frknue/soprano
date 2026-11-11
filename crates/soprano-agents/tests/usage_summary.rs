use std::path::Path;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use chrono::{FixedOffset, LocalResult, NaiveDate, NaiveDateTime, NaiveTime, TimeDelta, TimeZone, Utc};
use soprano_agents::usage::*;

/// A zone without clock changes, so the expectations do not depend on where the tests run.
fn zone() -> FixedOffset {
    FixedOffset::east_opt(3600).expect("offset")
}

fn date_in<Tz: TimeZone>(tz: &Tz, year: i32, month: u32, day: u32, hour: u32, minute: u32) -> UsageDate {
    tz.with_ymd_and_hms(year, month, day, hour, minute, 0).earliest().expect("local time").to_utc()
}

fn date(year: i32, month: u32, day: u32, hour: u32, minute: u32) -> UsageDate {
    date_in(&zone(), year, month, day, hour, minute)
}

/// Berlin's clock in 2026: summer time from March 29 to October 25, 01:00 UTC.
#[derive(Clone, Copy)]
struct Berlin;

impl Berlin {
    fn winter() -> FixedOffset {
        FixedOffset::east_opt(3600).expect("offset")
    }

    fn summer() -> FixedOffset {
        FixedOffset::east_opt(7200).expect("offset")
    }

    fn utc(month: u32, day: u32) -> NaiveDateTime {
        NaiveDate::from_ymd_opt(2026, month, day).expect("date").and_hms_opt(1, 0, 0).expect("time")
    }
}

impl TimeZone for Berlin {
    type Offset = FixedOffset;

    fn from_offset(_offset: &FixedOffset) -> Self {
        Berlin
    }

    fn offset_from_local_date(&self, local: &NaiveDate) -> LocalResult<FixedOffset> {
        self.offset_from_local_datetime(&local.and_time(NaiveTime::MIN))
    }

    fn offset_from_local_datetime(&self, local: &NaiveDateTime) -> LocalResult<FixedOffset> {
        let is_summer = self.offset_from_utc_datetime(&(*local - TimeDelta::hours(2))) == Self::summer();
        let is_winter = self.offset_from_utc_datetime(&(*local - TimeDelta::hours(1))) == Self::winter();
        match (is_summer, is_winter) {
            (true, true) => LocalResult::Ambiguous(Self::summer(), Self::winter()),
            (true, false) => LocalResult::Single(Self::summer()),
            (false, true) => LocalResult::Single(Self::winter()),
            (false, false) => LocalResult::None,
        }
    }

    fn offset_from_utc_date(&self, utc: &NaiveDate) -> FixedOffset {
        self.offset_from_utc_datetime(&utc.and_time(NaiveTime::MIN))
    }

    fn offset_from_utc_datetime(&self, utc: &NaiveDateTime) -> FixedOffset {
        if (Self::utc(3, 29)..Self::utc(10, 25)).contains(utc) { Self::summer() } else { Self::winter() }
    }
}

struct Group {
    start: UsageDate,
    model: &'static str,
    provider: &'static str,
    agent: &'static str,
    folder: &'static str,
    cost: f64,
}

impl Group {
    fn at(start: UsageDate, cost: f64) -> Self {
        Self {
            start,
            model: "claude-opus-5-5",
            provider: "anthropic",
            agent: "main",
            folder: "-git-app",
            cost,
        }
    }

    fn build(self) -> UsageGroup {
        UsageGroup {
            start: self.start,
            provider: self.provider.into(),
            model: self.model.into(),
            agent: self.agent.into(),
            folder: self.folder.into(),
            totals: UsageTotals {
                requests: 1,
                input_tokens: 10,
                output_tokens: 20,
                cache_read_tokens: 60,
                cache_write_tokens: 10,
                input_cost: self.cost * 0.125,
                output_cost: self.cost * 0.5,
                cache_read_cost: self.cost * 0.25,
                cache_write_cost: self.cost * 0.125,
                ..UsageTotals::default()
            },
        }
    }
}

fn costs<K>(rows: &[UsageRow<K>]) -> Vec<f64> {
    rows.iter().map(|row| row.totals.cost()).collect()
}

fn keys(rows: &[UsageRow<String>]) -> Vec<&str> {
    rows.iter().map(|row| row.key.as_str()).collect()
}

fn model_names(rows: &[UsageRow<UsageModelKey>]) -> Vec<&str> {
    rows.iter().map(|row| row.key.model.as_str()).collect()
}

#[test]
fn the_last_24_hours_are_25_hourly_bars() {
    let now = date(2026, 10, 31, 14, 25);
    let (unit, starts) = UsagePeriod::Day.buckets(now, None, &zone());

    assert_eq!(UsagePeriod::Day.start(now, &zone()), Some(date(2026, 10, 30, 14, 25)));
    assert_eq!(unit, UsageBucketUnit::Hour);
    assert_eq!(starts.len(), 25);
    assert_eq!(starts.first(), Some(&date(2026, 10, 30, 14, 0)));
    assert_eq!(starts.last(), Some(&date(2026, 10, 31, 14, 0)));
}

#[test]
fn hourly_bars_start_on_the_local_hour_in_a_half_hour_zone() {
    let india = FixedOffset::east_opt(5 * 3600 + 1800).expect("offset");
    let now = date_in(&india, 2026, 10, 31, 14, 25);

    let (_, starts) = UsagePeriod::Day.buckets(now, None, &india);

    assert_eq!(starts.len(), 25);
    assert_eq!(starts.first(), Some(&date_in(&india, 2026, 10, 30, 14, 0)));
    assert_eq!(starts.last(), Some(&date_in(&india, 2026, 10, 31, 14, 0)));
}

#[test]
fn day_periods_end_today_and_count_whole_local_days() {
    let now = date(2026, 10, 31, 9, 0);
    for (period, days) in [(UsagePeriod::Week, 7), (UsagePeriod::Month, 30), (UsagePeriod::Quarter, 90)] {
        let (unit, starts) = period.buckets(now, None, &zone());
        assert_eq!(unit, UsageBucketUnit::Day, "{period:?}");
        assert_eq!(starts.len(), days, "{period:?}");
        assert_eq!(starts.last(), Some(&date(2026, 10, 31, 0, 0)), "{period:?}");
        assert_eq!(starts.first(), period.start(now, &zone()).as_ref(), "{period:?}");
    }
    assert_eq!(UsagePeriod::Week.start(now, &zone()), Some(date(2026, 10, 25, 0, 0)));
    assert_eq!(UsagePeriod::Month.start(now, &zone()), Some(date(2026, 10, 2, 0, 0)));
    assert_eq!(UsagePeriod::Quarter.start(now, &zone()), Some(date(2026, 8, 3, 0, 0)));
    assert_eq!(UsagePeriod::All.start(now, &zone()), None);
}

#[test]
fn days_stay_calendar_days_across_a_clock_change() {
    // Clocks go back on October 25 in Berlin: that day has 25 hours.
    let now = date_in(&Berlin, 2026, 10, 31, 9, 0);

    let (_, week) = UsagePeriod::Week.buckets(now, None, &Berlin);

    assert_eq!(week.len(), 7);
    assert_eq!(week[0], date_in(&Berlin, 2026, 10, 25, 0, 0));
    assert_eq!(week[1], date_in(&Berlin, 2026, 10, 26, 0, 0));
    assert_eq!(week[1] - week[0], TimeDelta::hours(25));
    assert_eq!(week[6], date_in(&Berlin, 2026, 10, 31, 0, 0));

    // Clocks go forward on March 29: 23 hours.
    let (_, spring) = UsagePeriod::Week.buckets(date_in(&Berlin, 2026, 3, 31, 9, 0), None, &Berlin);
    assert_eq!(spring.len(), 7);
    assert_eq!(spring[5] - spring[4], TimeDelta::hours(23));
    assert_eq!(spring[6], date_in(&Berlin, 2026, 3, 31, 0, 0));
}

#[test]
fn hourly_bars_stay_real_hours_across_a_clock_change() {
    let now = date_in(&Berlin, 2026, 10, 25, 12, 30);

    let (_, starts) = UsagePeriod::Day.buckets(now, None, &Berlin);

    // 24 real hours before 12:30 winter time is 13:30 summer time the day before.
    assert_eq!(starts.len(), 25);
    assert_eq!(starts.first(), Some(&date_in(&Berlin, 2026, 10, 24, 13, 0)));
    assert_eq!(starts.last(), Some(&date_in(&Berlin, 2026, 10, 25, 12, 0)));
    assert!(starts.windows(2).all(|pair| pair[1] - pair[0] == TimeDelta::hours(1)));
}

#[test]
fn all_is_weekly_from_the_first_request_and_monthly_beyond_26_weeks() {
    let now = date(2026, 10, 31, 12, 0);

    let (unit, weekly) = UsagePeriod::All.buckets(now, Some(date(2026, 9, 23, 18, 0)), &zone());
    assert_eq!(unit, UsageBucketUnit::Week);
    assert_eq!(weekly.first(), Some(&date(2026, 9, 21, 0, 0)));
    assert_eq!(weekly.last(), Some(&date(2026, 10, 26, 0, 0)));
    assert_eq!(weekly.len(), 6);

    // 26 weeks are still weeks, the 27th turns them into months.
    let (unit, half_year) = UsagePeriod::All.buckets(now, Some(date(2026, 5, 4, 0, 0)), &zone());
    assert_eq!(unit, UsageBucketUnit::Week);
    assert_eq!(half_year.len(), 26);
    let (unit, longer) = UsagePeriod::All.buckets(now, Some(date(2026, 5, 3, 23, 0)), &zone());
    assert_eq!(unit, UsageBucketUnit::Month);
    assert_eq!(longer.first(), Some(&date(2026, 5, 1, 0, 0)));
    assert_eq!(longer.len(), 6);

    let (unit, monthly) = UsagePeriod::All.buckets(now, Some(date(2025, 12, 3, 0, 0)), &zone());
    assert_eq!(unit, UsageBucketUnit::Month);
    assert_eq!(monthly.first(), Some(&date(2025, 12, 1, 0, 0)));
    assert_eq!(monthly.last(), Some(&date(2026, 10, 1, 0, 0)));
    assert_eq!(monthly.len(), 11);

    // Without a request, and with one dated after now, All is the current week.
    let (_, empty) = UsagePeriod::All.buckets(now, None, &zone());
    assert_eq!(empty, [date(2026, 10, 26, 0, 0)]);
    let (_, future) = UsagePeriod::All.buckets(now, Some(date(2026, 12, 1, 0, 0)), &zone());
    assert_eq!(future, [date(2026, 10, 26, 0, 0)]);
}

#[test]
fn periods_read_hourly_for_24_hours_and_daily_otherwise() {
    assert_eq!(UsagePeriod::ALL.map(UsagePeriod::title), ["24h", "7d", "30d", "90d", "All"]);
    assert_eq!(UsagePeriod::Day.granularity(), UsageGranularity::Hour);
    for period in &UsagePeriod::ALL[1..] {
        assert_eq!(period.granularity(), UsageGranularity::Day, "{period:?}");
    }
}

#[test]
fn groups_land_in_the_bucket_that_contains_them() {
    let now = date(2026, 10, 31, 12, 0);
    let groups = vec![
        Group::at(date(2026, 10, 20, 9, 0), 1.0).build(),
        Group::at(date(2026, 10, 25, 23, 0), 2.0).build(),
        Group::at(date(2026, 10, 26, 0, 0), 4.0).build(),
        Group::at(date(2026, 10, 31, 11, 0), 8.0).build(),
    ];
    let history = UsageHistory::new(UsagePeriod::All, now, groups, None, &zone());

    let summary = history.summary(None);

    assert_eq!(history.bucket_unit, UsageBucketUnit::Week);
    assert_eq!(history.bucket_starts, [date(2026, 10, 19, 0, 0), date(2026, 10, 26, 0, 0)]);
    let starts: Vec<UsageDate> = summary.buckets.iter().map(|bucket| bucket.start).collect();
    assert_eq!(starts, history.bucket_starts);
    let bars: Vec<f64> = summary.buckets.iter().map(|bucket| bucket.totals.cost()).collect();
    assert_eq!(bars, [3.0, 12.0]);
    assert_eq!(summary.totals.cost(), 15.0);
    assert_eq!(summary.totals.requests, 4);
}

#[test]
fn a_group_before_the_first_bar_counts_in_the_totals_but_in_no_bar() {
    let now = date(2026, 10, 31, 12, 0);
    let groups = vec![
        Group::at(date(2026, 10, 1, 0, 0), 2.0).build(),
        Group::at(date(2026, 10, 31, 0, 0), 1.0).build(),
    ];
    let history = UsageHistory::new(UsagePeriod::Week, now, groups, None, &zone());

    let summary = history.summary(None);

    assert_eq!(summary.buckets.len(), 7);
    assert_eq!(summary.buckets.iter().map(|bucket| bucket.totals.cost()).sum::<f64>(), 1.0);
    assert_eq!(summary.buckets[6].totals.requests, 1);
    assert_eq!(summary.totals.cost(), 3.0);
    assert_eq!(costs(&summary.folders), [3.0]);
}

#[test]
fn a_model_filter_narrows_everything_but_the_model_list() {
    let now = date(2026, 10, 31, 12, 0);
    let start = date(2026, 10, 31, 0, 0);
    let groups = vec![
        Group::at(start, 5.0).build(),
        Group { agent: "subagent", folder: "-git-site", ..Group::at(start, 3.0) }.build(),
        Group {
            model: "gpt-6.1-sol",
            provider: "openai-codex",
            folder: "-git-site",
            ..Group::at(start, 1.0)
        }
        .build(),
    ];
    let history = UsageHistory::new(UsagePeriod::Week, now, groups, None, &zone());
    let sol = UsageModelKey { provider: "openai-codex".into(), model: "gpt-6.1-sol".into() };

    let all = history.summary(None);
    let filtered = history.summary(Some(&sol));

    assert_eq!(model_names(&all.models), ["claude-opus-5-5", "gpt-6.1-sol"]);
    assert_eq!(costs(&all.models), [8.0, 1.0]);
    assert_eq!(filtered.models, all.models);
    assert_eq!(filtered.totals.cost(), 1.0);
    assert_eq!(filtered.totals.requests, 1);
    assert_eq!(filtered.buckets.last().map(|bucket| bucket.totals.cost()), Some(1.0));
    assert_eq!(keys(&filtered.folders), ["-git-site"]);
    assert_eq!(keys(&filtered.agents), ["main"]);
    assert_eq!(keys(&all.folders), ["-git-app", "-git-site"]);
    assert_eq!(costs(&all.folders), [5.0, 4.0]);
    assert_eq!(keys(&all.agents), ["main", "subagent"]);
    assert_eq!(costs(&all.agents), [6.0, 3.0]);
    assert_eq!(all.buckets.last().map(|bucket| bucket.totals.cost()), Some(9.0));
}

#[test]
fn rows_rank_by_cost_then_tokens_then_name() {
    let start = date(2026, 10, 31, 0, 0);
    let free = |model: &'static str, provider: &'static str, folder: &'static str, tokens: u64| {
        let mut group = Group { model, provider, folder, ..Group::at(start, 0.0) }.build();
        group.totals.output_tokens = tokens;
        group
    };
    let groups = vec![
        free("zeta", "local", "-c", 20),
        free("beta", "local", "-b", 20),
        free("beta", "atlas", "-a", 20),
        free("alpha", "local", "-d", 500),
        Group { model: "omega", folder: "-z", ..Group::at(start, 0.5) }.build(),
    ];
    let history = UsageHistory::new(UsagePeriod::Week, date(2026, 10, 31, 12, 0), groups, None, &zone());

    let summary = history.summary(None);

    let models: Vec<(&str, &str)> =
        summary.models.iter().map(|row| (row.key.model.as_str(), row.key.provider.as_str())).collect();
    assert_eq!(
        models,
        [("omega", "anthropic"), ("alpha", "local"), ("beta", "atlas"), ("beta", "local"), ("zeta", "local")]
    );
    assert_eq!(keys(&summary.folders), ["-z", "-d", "-a", "-b", "-c"]);
}

#[test]
fn cache_savings_and_hit_rate_come_from_the_prompt_costs() {
    let totals = UsageTotals {
        input_tokens: 100,
        cache_read_tokens: 800,
        cache_write_tokens: 100,
        input_cost: 0.5,
        cache_read_cost: 0.4,
        cache_write_cost: 0.6,
        cached_prompt_cost: 1.5,
        uncached_prompt_cost: 5.0,
        ..UsageTotals::default()
    };
    assert_eq!(totals.cache_savings(), 3.5);
    assert_eq!(totals.cache_hit_rate(), Some(0.8));
    let dearer = UsageTotals { cached_prompt_cost: 2.0, uncached_prompt_cost: 1.0, ..UsageTotals::default() };
    assert_eq!(dearer.cache_savings(), 0.0);
    assert_eq!(UsageTotals { output_tokens: 10, ..UsageTotals::default() }.cache_hit_rate(), None);
}

#[test]
fn totals_give_each_part_in_cost_and_tokens_and_add_up() {
    let mut totals = UsageTotals {
        requests: 2,
        failed_requests: 1,
        input_tokens: 1,
        output_tokens: 2,
        cache_read_tokens: 4,
        cache_write_tokens: 8,
        input_cost: 0.5,
        output_cost: 0.25,
        cache_read_cost: 0.125,
        cache_write_cost: 1.0,
        unpriced_requests: 1,
        cached_prompt_cost: 1.5,
        uncached_prompt_cost: 2.0,
    };

    assert_eq!(UsagePart::ALL.map(UsagePart::title), ["Input", "Output", "Cache read", "Cache write"]);
    let parts = |metric: UsageMetric| UsagePart::ALL.map(|part| totals.part_value(part, metric));
    assert_eq!(parts(UsageMetric::Tokens), [1.0, 2.0, 4.0, 8.0]);
    assert_eq!(parts(UsageMetric::Cost), [0.5, 0.25, 0.125, 1.0]);
    assert_eq!(totals.tokens(), 15);
    assert_eq!(totals.value(UsageMetric::Tokens), 15.0);
    assert_eq!(totals.value(UsageMetric::Cost), 1.875);

    let other = totals;
    totals.add(&other);
    assert_eq!(totals.requests, 4);
    assert_eq!(totals.failed_requests, 2);
    assert_eq!(totals.unpriced_requests, 2);
    assert_eq!(totals.tokens(), 30);
    assert_eq!(totals.cost(), 3.75);
    assert_eq!(totals.cache_savings(), 1.0);
}

/// omp's stats keep the session folder name with every `--` turned into `/` (and a leading `--`
/// into `/`): `--private-tmp--` is stored as `/private-tmp/`.
#[test]
fn folder_names_follow_omps_stats_folders() {
    let (home, temporary) = (Path::new("/Users/ada"), Path::new("/var/tmp-sandbox"));
    let encode = |path: &str| folder_name::encode(Path::new(path), home, temporary);

    assert_eq!(encode("/Users/ada/git/private/soprano-agents"), "-git-private-soprano-agents");
    assert_eq!(encode("/Users/ada"), "-");
    assert_eq!(encode("/Users/ada/"), "-");
    assert_eq!(encode("/Users/ada/git/./app/../site"), "-git-site");
    assert_eq!(encode("/opt/work/app"), "/opt-work-app/");
    assert_eq!(encode("/var/tmp-sandbox/scratch/x"), "-tmp-scratch-x");
    assert_eq!(encode("/var/tmp-sandbox"), "-tmp");
    assert_eq!(encode("/Users/adam/app"), "/Users-adam-app/");
    assert_eq!(encode("/Users/ada/a-/b"), "-a/b");
    assert_eq!(encode("/Users/ada/c:d"), "-c-d");
}

/// Symlinks resolve as Node's realpath does (on macOS `/tmp` is `/private/tmp`).
#[cfg(unix)]
#[test]
fn folder_names_use_the_canonical_path_behind_a_symlink() {
    let scratch = tempfile::tempdir().expect("temp dir");
    let root = scratch.path().canonicalize().expect("canonical temp dir");
    std::fs::create_dir_all(root.join("home/git/app")).expect("directories");
    std::fs::create_dir_all(root.join("elsewhere/work")).expect("directories");
    std::os::unix::fs::symlink(root.join("home/git/app"), root.join("link")).expect("symlink");
    std::os::unix::fs::symlink(root.join("home"), root.join("home-link")).expect("symlink");
    let temporary = Path::new("/var/tmp-sandbox");

    let (home, home_link, link) = (root.join("home"), root.join("home-link"), root.join("link"));
    assert_eq!(folder_name::encode(&link, &home, temporary), "-git-app");
    assert_eq!(folder_name::encode(&home.join("git/app"), &home_link, temporary), "-git-app");
    assert_eq!(folder_name::encode(&link, &root.join("elsewhere"), &home_link), "-tmp-git-app");

    let outside = root.join("elsewhere/work");
    let dashed = outside.to_string_lossy().trim_start_matches('/').replace('/', "-");
    let stored = format!("/{}/", dashed.replace("--", "/"));
    assert_eq!(folder_name::encode(&outside, &root.join("home"), temporary), stored);
}

#[test]
fn a_folder_no_project_claims_is_titled_by_its_name_without_the_dashes_around_it() {
    assert_eq!(folder_name::fallback_title("-git-app"), "git-app");
    assert_eq!(folder_name::fallback_title("/private-tmp/"), "private-tmp");
    assert_eq!(folder_name::fallback_title("-"), "~");
    assert_eq!(folder_name::fallback_title(""), "~");
}

/// A service that answers from memory and records what it was asked.
struct Recorded {
    groups: Vec<UsageGroup>,
    sync_error: Option<UsageStatisticsError>,
    read_error: Option<UsageStatisticsError>,
    syncs: AtomicUsize,
    reads: Mutex<Vec<(Option<UsageDate>, UsageGranularity)>>,
}

impl Recorded {
    fn new(groups: Vec<UsageGroup>) -> Self {
        Self {
            groups,
            sync_error: None,
            read_error: None,
            syncs: AtomicUsize::new(0),
            reads: Mutex::new(Vec::new()),
        }
    }

    fn reads(&self) -> Vec<(Option<UsageDate>, UsageGranularity)> {
        self.reads.lock().expect("reads").clone()
    }
}

impl UsageStatisticsService for Recorded {
    fn sync(&self) -> Result<(), UsageStatisticsError> {
        self.syncs.fetch_add(1, Ordering::SeqCst);
        self.sync_error.clone().map_or(Ok(()), Err)
    }

    fn groups(
        &self,
        since: Option<UsageDate>,
        granularity: UsageGranularity,
    ) -> Result<Vec<UsageGroup>, UsageStatisticsError> {
        self.reads.lock().expect("reads").push((since, granularity));
        match &self.read_error {
            Some(error) => Err(error.clone()),
            None => Ok(self.groups.clone()),
        }
    }
}

#[test]
fn the_history_reads_the_period_from_its_start_at_its_granularity() {
    let now = date(2026, 10, 31, 14, 25);
    let service = Recorded::new(vec![Group::at(date(2026, 10, 31, 9, 0), 2.0).build()]);

    let day = usage_history(&service, UsagePeriod::Day, false, now, &zone()).expect("history");
    let week = usage_history(&service, UsagePeriod::Week, false, now, &zone()).expect("history");
    let all = usage_history(&service, UsagePeriod::All, false, now, &zone()).expect("history");

    assert_eq!(service.syncs.load(Ordering::SeqCst), 0);
    assert_eq!(
        service.reads(),
        [
            (Some(date(2026, 10, 30, 14, 25)), UsageGranularity::Hour),
            (Some(date(2026, 10, 25, 0, 0)), UsageGranularity::Day),
            (None, UsageGranularity::Day),
        ]
    );
    assert_eq!((day.period, day.now, day.bucket_unit), (UsagePeriod::Day, now, UsageBucketUnit::Hour));
    assert_eq!(day.bucket_starts.len(), 25);
    assert_eq!(day.sync_error, None);
    assert_eq!(day.summary(None).buckets[19].totals.cost(), 2.0);
    assert_eq!(week.bucket_starts.len(), 7);
    assert_eq!(all.bucket_starts, [date(2026, 10, 26, 0, 0)]);
    assert_eq!(all.groups, service.groups);
}

#[test]
fn a_failed_sync_still_reads_what_was_recorded_before() {
    let now = date(2026, 10, 31, 14, 25);
    let mut service = Recorded::new(vec![Group::at(date(2026, 10, 31, 0, 0), 2.0).build()]);
    service.sync_error = Some(UsageStatisticsError::Sync("omp stats exited with status 1".into()));

    let history = usage_history(&service, UsagePeriod::Week, true, now, &zone()).expect("history");

    assert_eq!(service.syncs.load(Ordering::SeqCst), 1);
    assert_eq!(history.sync_error.as_deref(), Some("omp stats exited with status 1"));
    assert_eq!(history.groups, service.groups);
    assert_eq!(history.summary(None).totals.cost(), 2.0);

    service.sync_error = None;
    let synced = usage_history(&service, UsagePeriod::Week, true, now, &zone()).expect("history");
    assert_eq!(service.syncs.load(Ordering::SeqCst), 2);
    assert_eq!(synced.sync_error, None);
}

#[test]
fn a_failed_read_is_the_error() {
    let mut service = Recorded::new(Vec::new());
    service.read_error = Some(UsageStatisticsError::Database("no such table: messages".into()));

    let result = usage_history(&service, UsagePeriod::Week, true, Utc::now(), &zone());

    let error = result.expect_err("read error");
    assert_eq!(error, UsageStatisticsError::Database("no such table: messages".into()));
    assert_eq!(error.to_string(), "Couldn’t read omp’s usage statistics: no such table: messages.");
    assert_eq!(UsageStatisticsError::Sync("omp is not installed".into()).to_string(), "omp is not installed");
}
