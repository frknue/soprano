//! Reading omp's usage history from its `stats.db` (`OmpUsageStatistics.swift`).

use std::path::{Path, PathBuf};
use std::time::Duration;

use chrono::{DateTime, Local, NaiveDate, NaiveTime, TimeZone};
use rusqlite::types::ValueRef;
use rusqlite::{Connection, OpenFlags, Row};

use super::folder_name::lexically_normalized;
use super::statistics::{
    UsageDate, UsageGranularity, UsageGroup, UsageStatisticsError, UsageStatisticsService, UsageTotals,
    local_instant,
};

/// omp's usage history: `omp stats` ingests every session file into `~/.omp/stats.db` (one row
/// per model request with tokens and its API-equivalent cost), which this reads directly, so any
/// period and grouping is one query. A sync is whatever the owner injects: the app runs
/// `omp stats --summary` (it ingests what was written since the last run, then prints a summary
/// nobody reads) and owns that run's timeout. `PI_CONFIG_DIR` moves `~/.omp` under home as it
/// does for omp.
pub struct OmpUsageStatistics {
    database_path: PathBuf,
    sync: Box<dyn Fn() -> Result<(), String> + Send + Sync>,
}

impl OmpUsageStatistics {
    /// `sync` is what [`UsageStatisticsService::sync`] runs; its message is shown as it is.
    pub fn new(
        database_path: PathBuf,
        sync: impl Fn() -> Result<(), String> + Send + Sync + 'static,
    ) -> Self {
        Self { database_path, sync: Box::new(sync) }
    }

    /// `<home>/<PI_CONFIG_DIR or .omp>/stats.db`; an empty setting counts as unset. omp joins the
    /// setting onto home (Node's `path.join`), so even an absolute value stays under home.
    pub fn default_database_path(pi_config_dir: Option<&str>, home: &Path) -> PathBuf {
        let directory = pi_config_dir.filter(|directory| !directory.is_empty()).unwrap_or(".omp");
        let mut root = home.as_os_str().to_os_string();
        root.push("/");
        root.push(directory);
        lexically_normalized(Path::new(&root)).join("stats.db")
    }
}

impl UsageStatisticsService for OmpUsageStatistics {
    fn sync(&self) -> Result<(), UsageStatisticsError> {
        (self.sync)().map_err(UsageStatisticsError::Sync)
    }

    fn groups(
        &self,
        since: Option<UsageDate>,
        granularity: UsageGranularity,
    ) -> Result<Vec<UsageGroup>, UsageStatisticsError> {
        // SQLite's `'localtime'` made the day keys, so the process's zone turns them back.
        read(&self.database_path, since, granularity, &Local)
            .map_err(|error| UsageStatisticsError::Database(error.to_string()))
    }
}

/// The grouped query: requests (`stop_reason = 'error'` counts as failed), tokens, cost per
/// token kind, unpriced requests (omp's own rule: tokens but no cost, from `xai-oauth` or
/// marked `cost_unpriced`) and the cached / uncached prompt cost behind the cache savings.
/// Hours are keyed by the epoch second their local hour starts (the local UTC offset of each
/// request, so the repeated hour of a clock change stays two hours and half-hour zones
/// work); days by their local date.
fn query(granularity: UsageGranularity) -> String {
    let bucket = match granularity {
        UsageGranularity::Hour => {
            "(timestamp / 1000) - (((timestamp / 1000)
                + CAST(ROUND((julianday(timestamp / 1000, 'unixepoch', 'localtime')
                - julianday(timestamp / 1000, 'unixepoch')) * 86400) AS INTEGER)) % 3600)"
        }
        UsageGranularity::Day => "strftime('%Y-%m-%d', timestamp / 1000, 'unixepoch', 'localtime')",
    };
    format!(
        "SELECT {bucket} AS bucket,
            provider, model, agent_type, folder,
            COUNT(*),
            SUM(CASE WHEN stop_reason = 'error' THEN 1 ELSE 0 END),
            SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens), SUM(cache_write_tokens),
            TOTAL(cost_input), TOTAL(cost_output), TOTAL(cost_cache_read), TOTAL(cost_cache_write),
            SUM(CASE WHEN total_tokens > 0 AND cost_total = 0
                AND (provider = 'xai-oauth' OR cost_unpriced = 1) THEN 1 ELSE 0 END),
            TOTAL(CASE WHEN cost_no_cache_input > 0
                THEN cost_input + cost_cache_read + cost_cache_write ELSE 0 END),
            TOTAL(CASE WHEN cost_no_cache_input > 0 THEN cost_no_cache_input ELSE 0 END)
        FROM messages
        WHERE timestamp >= ?1
        GROUP BY 1, 2, 3, 4, 5"
    )
}

/// Reads the grouped history; no database yet (omp never synced) is no history. Opened
/// read-only for the one query, so omp can keep writing.
fn read<Tz: TimeZone>(
    database_path: &Path,
    since: Option<UsageDate>,
    granularity: UsageGranularity,
    tz: &Tz,
) -> rusqlite::Result<Vec<UsageGroup>> {
    if !database_path.exists() {
        return Ok(Vec::new());
    }
    let database = Connection::open_with_flags(database_path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    database.busy_timeout(Duration::from_secs(5))?;
    let mut statement = database.prepare(&query(granularity))?;
    // Milliseconds, rounded down.
    let since = since.map_or(i64::MIN, |since| since.timestamp_millis());
    let mut rows = statement.query([since])?;
    let mut groups = Vec::new();
    while let Some(row) = rows.next()? {
        let start = match granularity {
            UsageGranularity::Hour => DateTime::from_timestamp(signed(row, 0)?, 0),
            UsageGranularity::Day => day_start(&text(row, 0)?, tz),
        };
        let Some(start) = start else { continue };
        groups.push(UsageGroup {
            start,
            provider: text(row, 1)?,
            model: text(row, 2)?,
            agent: text(row, 3)?,
            folder: text(row, 4)?,
            totals: UsageTotals {
                requests: count(row, 5)?,
                failed_requests: count(row, 6)?,
                input_tokens: count(row, 7)?,
                output_tokens: count(row, 8)?,
                cache_read_tokens: count(row, 9)?,
                cache_write_tokens: count(row, 10)?,
                input_cost: real(row, 11)?,
                output_cost: real(row, 12)?,
                cache_read_cost: real(row, 13)?,
                cache_write_cost: real(row, 14)?,
                unpriced_requests: count(row, 15)?,
                cached_prompt_cost: real(row, 16)?,
                uncached_prompt_cost: real(row, 17)?,
            },
        });
    }
    Ok(groups)
}

/// `2026-10-31`, a local date → the start of that day.
fn day_start<Tz: TimeZone>(key: &str, tz: &Tz) -> Option<UsageDate> {
    let mut parts = key.split('-');
    let year = parts.next()?.parse().ok()?;
    let month = parts.next()?.parse().ok()?;
    let day = parts.next()?.parse().ok()?;
    if parts.next().is_some() {
        return None;
    }
    let date = NaiveDate::from_ymd_opt(year, month, day)?;
    Some(local_instant(date.and_time(NaiveTime::MIN), tz))
}

// The columns are read the way SQLite itself converts them, whatever type a sum came out as: omp
// declares the column types, but SQLite does not enforce them.

fn text(row: &Row<'_>, column: usize) -> rusqlite::Result<String> {
    Ok(match row.get_ref(column)? {
        ValueRef::Text(bytes) | ValueRef::Blob(bytes) => String::from_utf8_lossy(bytes).into_owned(),
        ValueRef::Integer(number) => number.to_string(),
        ValueRef::Real(number) => number.to_string(),
        ValueRef::Null => String::new(),
    })
}

fn signed(row: &Row<'_>, column: usize) -> rusqlite::Result<i64> {
    Ok(match row.get_ref(column)? {
        ValueRef::Integer(number) => number,
        ValueRef::Real(number) => number as i64,
        ValueRef::Null | ValueRef::Text(_) | ValueRef::Blob(_) => 0,
    })
}

fn count(row: &Row<'_>, column: usize) -> rusqlite::Result<u64> {
    Ok(u64::try_from(signed(row, column)?).unwrap_or(0))
}

fn real(row: &Row<'_>, column: usize) -> rusqlite::Result<f64> {
    Ok(match row.get_ref(column)? {
        ValueRef::Integer(number) => number as f64,
        ValueRef::Real(number) => number,
        ValueRef::Null | ValueRef::Text(_) | ValueRef::Blob(_) => 0.0,
    })
}
