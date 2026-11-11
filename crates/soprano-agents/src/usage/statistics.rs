//! The usage history's periods, chart buckets and summed totals (`UsageStatistics.swift`).

use std::fmt;

use chrono::{DateTime, Datelike, Days, LocalResult, Months, NaiveDate, NaiveDateTime, NaiveTime};
use chrono::{TimeDelta, TimeZone, Timelike};

use crate::timeline::Date;

/// A point in time of the usage history.
pub type UsageDate = Date;

/// The span the statistics board covers, with fixed chart buckets in local time: 24h → the last
/// 24 hours in hourly bars (25: the first is the part of its hour inside the window), 7d / 30d /
/// 90d → calendar days ending today, All → weeks since the first request (months once that is
/// more than 26 weeks).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum UsagePeriod {
    Day,
    Week,
    Month,
    Quarter,
    All,
}

impl UsagePeriod {
    pub const ALL: [Self; 5] = [Self::Day, Self::Week, Self::Month, Self::Quarter, Self::All];

    /// Weekly buckets for All up to this many, monthly beyond.
    const ALL_WEEKS_LIMIT: usize = 26;

    pub fn title(self) -> &'static str {
        match self {
            Self::Day => "24h",
            Self::Week => "7d",
            Self::Month => "30d",
            Self::Quarter => "90d",
            Self::All => "All",
        }
    }

    /// How the history is summed when read: hourly for 24h, daily otherwise.
    pub fn granularity(self) -> UsageGranularity {
        if self == Self::Day { UsageGranularity::Hour } else { UsageGranularity::Day }
    }

    /// Where the period's requests start; `None` for All (from the first recorded request).
    pub fn start<Tz: TimeZone>(self, now: UsageDate, tz: &Tz) -> Option<UsageDate> {
        match self {
            Self::Day => now.checked_sub_signed(TimeDelta::seconds(86_400)),
            Self::Week | Self::Month | Self::Quarter => {
                self.first_day(now, tz).map(|wall| local_instant(wall, tz))
            }
            Self::All => None,
        }
    }

    /// The chart buckets: their unit and starts, ascending, from the period's start (All: from
    /// `earliest`) through `now`.
    pub fn buckets<Tz: TimeZone>(
        self,
        now: UsageDate,
        earliest: Option<UsageDate>,
        tz: &Tz,
    ) -> (UsageBucketUnit, Vec<UsageDate>) {
        match self {
            Self::Day => {
                let start = self.start(now, tz).map(|start| hour_start(start, tz));
                (UsageBucketUnit::Hour, hour_steps(start, now))
            }
            Self::Week | Self::Month | Self::Quarter => {
                (UsageBucketUnit::Day, calendar_steps(self.first_day(now, tz), now, CalendarStep::Day, tz))
            }
            Self::All => {
                let first = earliest.map_or(now, |earliest| earliest.min(now));
                let day = first.with_timezone(tz).date_naive();
                let into_week = Days::new(u64::from(day.weekday().num_days_from_monday()));
                let monday = day.checked_sub_days(into_week).map(midnight);
                let weeks = calendar_steps(monday, now, CalendarStep::Week, tz);
                if weeks.len() <= Self::ALL_WEEKS_LIMIT {
                    return (UsageBucketUnit::Week, weeks);
                }
                let month = day.with_day(1).map(midnight);
                (UsageBucketUnit::Month, calendar_steps(month, now, CalendarStep::Month, tz))
            }
        }
    }

    /// Local midnight of the first of the period's calendar days, the last of which is today.
    fn first_day<Tz: TimeZone>(self, now: UsageDate, tz: &Tz) -> Option<NaiveDateTime> {
        let today = now.with_timezone(tz).date_naive();
        today.checked_sub_days(Days::new(self.day_count().saturating_sub(1))).map(midnight)
    }

    fn day_count(self) -> u64 {
        match self {
            Self::Day => 1,
            Self::Week => 7,
            Self::Month => 30,
            Self::Quarter => 90,
            Self::All => 0,
        }
    }
}

/// A calendar step in local wall time, so a day stays a day across a clock change.
#[derive(Clone, Copy)]
enum CalendarStep {
    Day,
    Week,
    Month,
}

impl CalendarStep {
    fn after(self, wall: NaiveDateTime) -> Option<NaiveDateTime> {
        match self {
            Self::Day => wall.checked_add_days(Days::new(1)),
            Self::Week => wall.checked_add_days(Days::new(7)),
            Self::Month => wall.checked_add_months(Months::new(1)),
        }
    }
}

fn midnight(day: NaiveDate) -> NaiveDateTime {
    day.and_time(NaiveTime::MIN)
}

/// The instant of a local wall time: the earlier one when a clock change repeats it, the first
/// instant after the gap when a clock change skips it.
pub(super) fn local_instant<Tz: TimeZone>(wall: NaiveDateTime, tz: &Tz) -> UsageDate {
    match tz.from_local_datetime(&wall) {
        LocalResult::Single(date) => date.to_utc(),
        LocalResult::Ambiguous(first, second) => first.to_utc().min(second.to_utc()),
        LocalResult::None => after_gap(wall, tz),
    }
}

/// The first instant whose local time is not before the skipped `wall`: the clock change itself.
/// Local time only moves forward around a gap, so a bisection over the two days either side of
/// `wall` read as UTC (no offset is that large) finds it.
fn after_gap<Tz: TimeZone>(wall: NaiveDateTime, tz: &Tz) -> UsageDate {
    let reached = |seconds: i64| {
        DateTime::from_timestamp(seconds, 0)
            .is_some_and(|instant| tz.from_utc_datetime(&instant.naive_utc()).naive_local() >= wall)
    };
    let guess = wall.and_utc();
    let mut before = guess.timestamp() - 172_800;
    let mut after = guess.timestamp() + 172_800;
    while after - before > 1 {
        let middle = before + (after - before) / 2;
        if reached(middle) {
            after = middle;
        } else {
            before = middle;
        }
    }
    DateTime::from_timestamp(after, 0).unwrap_or(guess)
}

/// The start of the local hour `date` is in. Counted back from the instant itself, so the
/// repeated hour of a clock change keeps its own start and half-hour zones work.
fn hour_start<Tz: TimeZone>(date: UsageDate, tz: &Tz) -> UsageDate {
    let time = date.with_timezone(tz).time();
    let into_hour = TimeDelta::seconds(i64::from(time.minute() * 60 + time.second()))
        + TimeDelta::nanoseconds(i64::from(time.nanosecond()));
    date.checked_sub_signed(into_hour).unwrap_or(date)
}

/// Real hours from `start` through `end`.
fn hour_steps(start: Option<UsageDate>, end: UsageDate) -> Vec<UsageDate> {
    let mut dates = Vec::new();
    let Some(mut current) = start else { return dates };
    while current <= end {
        dates.push(current);
        match current.checked_add_signed(TimeDelta::hours(1)) {
            Some(next) if next > current => current = next,
            _ => break,
        }
    }
    dates
}

/// Calendar steps from the local wall time `start` through `end`. Every step is taken in wall
/// time and then placed, so one start moved by a clock change does not shift the ones after it.
fn calendar_steps<Tz: TimeZone>(
    start: Option<NaiveDateTime>,
    end: UsageDate,
    step: CalendarStep,
    tz: &Tz,
) -> Vec<UsageDate> {
    let mut dates = Vec::new();
    let Some(mut wall) = start else { return dates };
    let mut current = local_instant(wall, tz);
    while current <= end {
        dates.push(current);
        let Some(next_wall) = step.after(wall) else { break };
        let next = local_instant(next_wall, tz);
        if next <= current {
            break;
        }
        wall = next_wall;
        current = next;
    }
    dates
}

/// How recorded requests are summed when read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UsageGranularity {
    Hour,
    Day,
}

/// The span of one chart bar.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UsageBucketUnit {
    Hour,
    Day,
    Week,
    Month,
}

/// Which number a chart or breakdown shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum UsageMetric {
    /// Estimated API-equivalent cost in USD.
    Cost,
    Tokens,
}

/// The token kinds a request is billed by.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum UsagePart {
    Input,
    Output,
    CacheRead,
    CacheWrite,
}

impl UsagePart {
    pub const ALL: [Self; 4] = [Self::Input, Self::Output, Self::CacheRead, Self::CacheWrite];

    pub fn title(self) -> &'static str {
        match self {
            Self::Input => "Input",
            Self::Output => "Output",
            Self::CacheRead => "Cache read",
            Self::CacheWrite => "Cache write",
        }
    }
}

/// Summed requests, tokens and estimated cost (USD at the provider's API rates, as omp records
/// them; not a subscription bill).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct UsageTotals {
    pub requests: u64,
    pub failed_requests: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_write_tokens: u64,
    pub input_cost: f64,
    pub output_cost: f64,
    pub cache_read_cost: f64,
    pub cache_write_cost: f64,
    /// Requests whose price is unknown (their zero cost is not free usage).
    pub unpriced_requests: u64,
    /// What the prompts of requests that reported an uncached price cost with the cache, and what
    /// they would have cost without it.
    pub cached_prompt_cost: f64,
    pub uncached_prompt_cost: f64,
}

impl UsageTotals {
    pub fn tokens(&self) -> u64 {
        self.input_tokens + self.output_tokens + self.cache_read_tokens + self.cache_write_tokens
    }

    pub fn cost(&self) -> f64 {
        self.input_cost + self.output_cost + self.cache_read_cost + self.cache_write_cost
    }

    /// What the prompt cache saved: the uncached price minus what the cached prompts cost.
    pub fn cache_savings(&self) -> f64 {
        (self.uncached_prompt_cost - self.cached_prompt_cost).max(0.0)
    }

    /// Share of prompt tokens (input, cache read and cache write) served from the cache; `None`
    /// without prompt tokens.
    pub fn cache_hit_rate(&self) -> Option<f64> {
        let prompt = self.input_tokens + self.cache_read_tokens + self.cache_write_tokens;
        (prompt > 0).then(|| self.cache_read_tokens as f64 / prompt as f64)
    }

    pub fn value(&self, metric: UsageMetric) -> f64 {
        match metric {
            UsageMetric::Cost => self.cost(),
            UsageMetric::Tokens => self.tokens() as f64,
        }
    }

    pub fn part_value(&self, part: UsagePart, metric: UsageMetric) -> f64 {
        match (part, metric) {
            (UsagePart::Input, UsageMetric::Cost) => self.input_cost,
            (UsagePart::Output, UsageMetric::Cost) => self.output_cost,
            (UsagePart::CacheRead, UsageMetric::Cost) => self.cache_read_cost,
            (UsagePart::CacheWrite, UsageMetric::Cost) => self.cache_write_cost,
            (UsagePart::Input, UsageMetric::Tokens) => self.input_tokens as f64,
            (UsagePart::Output, UsageMetric::Tokens) => self.output_tokens as f64,
            (UsagePart::CacheRead, UsageMetric::Tokens) => self.cache_read_tokens as f64,
            (UsagePart::CacheWrite, UsageMetric::Tokens) => self.cache_write_tokens as f64,
        }
    }

    pub fn add(&mut self, other: &UsageTotals) {
        self.requests += other.requests;
        self.failed_requests += other.failed_requests;
        self.input_tokens += other.input_tokens;
        self.output_tokens += other.output_tokens;
        self.cache_read_tokens += other.cache_read_tokens;
        self.cache_write_tokens += other.cache_write_tokens;
        self.input_cost += other.input_cost;
        self.output_cost += other.output_cost;
        self.cache_read_cost += other.cache_read_cost;
        self.cache_write_cost += other.cache_write_cost;
        self.unpriced_requests += other.unpriced_requests;
        self.cached_prompt_cost += other.cached_prompt_cost;
        self.uncached_prompt_cost += other.uncached_prompt_cost;
    }
}

/// Requests of one model, agent kind and session folder within one local hour or day.
#[derive(Clone, Debug, PartialEq)]
pub struct UsageGroup {
    /// Start of the local hour or day.
    pub start: UsageDate,
    pub provider: String,
    pub model: String,
    /// omp's agent kind: `main`, `subagent`, `advisor`, …
    pub agent: String,
    /// omp's session folder for the working directory (`-git-app` for `~/git/app`).
    pub folder: String,
    pub totals: UsageTotals,
}

/// Why the usage history could not be read or brought up to date.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UsageStatisticsError {
    /// The recorded history could not be read; holds the database's own message.
    Database(String),
    /// Ingesting what the agent recorded failed; holds the message to show as it is.
    Sync(String),
}

impl fmt::Display for UsageStatisticsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Database(message) => write!(f, "Couldn’t read omp’s usage statistics: {message}."),
            Self::Sync(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for UsageStatisticsError {}

/// Reads the agent's recorded usage history. Both calls block (a process run, a database read),
/// so the board calls them off the main thread.
pub trait UsageStatisticsService: Send + Sync {
    /// Blocking: ingests what the agent recorded since the last sync.
    fn sync(&self) -> Result<(), UsageStatisticsError>;

    /// Blocking: recorded requests since `since` (every one when `None`), summed per local hour
    /// or day, model, agent kind and folder.
    fn groups(
        &self,
        since: Option<UsageDate>,
        granularity: UsageGranularity,
    ) -> Result<Vec<UsageGroup>, UsageStatisticsError>;
}
