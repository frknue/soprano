//! One period's usage history folded into totals, chart buckets and breakdowns
//! (`UsageSummary.swift`).

use std::cmp::Ordering;
use std::collections::HashMap;

use chrono::TimeZone;

use super::statistics::{
    UsageBucketUnit, UsageDate, UsageGroup, UsagePeriod, UsageStatisticsError, UsageStatisticsService,
    UsageTotals,
};

/// A model as the agent records it.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct UsageModelKey {
    pub provider: String,
    pub model: String,
}

/// One line of a breakdown.
#[derive(Clone, Debug, PartialEq)]
pub struct UsageRow<K> {
    pub key: K,
    pub totals: UsageTotals,
}

/// One chart bar: a local hour, day, week or month.
#[derive(Clone, Debug, PartialEq)]
pub struct UsageBucket {
    pub start: UsageDate,
    pub totals: UsageTotals,
}

/// The usage history of one period as read, with its chart buckets.
#[derive(Clone, Debug, PartialEq)]
pub struct UsageHistory {
    pub period: UsagePeriod,
    pub now: UsageDate,
    pub groups: Vec<UsageGroup>,
    /// Bucket starts, ascending; the last bucket runs through `now`.
    pub bucket_starts: Vec<UsageDate>,
    pub bucket_unit: UsageBucketUnit,
    /// Why the sync before this read failed; the groups are what was recorded before it.
    pub sync_error: Option<String>,
}

impl UsageHistory {
    pub fn new<Tz: TimeZone>(
        period: UsagePeriod,
        now: UsageDate,
        groups: Vec<UsageGroup>,
        sync_error: Option<String>,
        tz: &Tz,
    ) -> Self {
        let earliest = groups.iter().map(|group| group.start).min();
        let (bucket_unit, bucket_starts) = period.buckets(now, earliest, tz);
        Self { period, now, groups, bucket_starts, bucket_unit, sync_error }
    }

    /// Totals, chart buckets and breakdowns, limited to `model` when set. The model breakdown
    /// always lists every model, so another one can be picked.
    pub fn summary(&self, model: Option<&UsageModelKey>) -> UsageSummary {
        let mut totals = UsageTotals::default();
        let mut buckets: Vec<UsageBucket> = self
            .bucket_starts
            .iter()
            .map(|&start| UsageBucket { start, totals: UsageTotals::default() })
            .collect();
        let mut models: HashMap<(&str, &str), UsageTotals> = HashMap::new();
        let mut folders: HashMap<&str, UsageTotals> = HashMap::new();
        let mut agents: HashMap<&str, UsageTotals> = HashMap::new();
        for group in &self.groups {
            models.entry((group.provider.as_str(), group.model.as_str())).or_default().add(&group.totals);
            if model.is_some_and(|key| key.provider != group.provider || key.model != group.model) {
                continue;
            }
            totals.add(&group.totals);
            folders.entry(group.folder.as_str()).or_default().add(&group.totals);
            agents.entry(group.agent.as_str()).or_default().add(&group.totals);
            if let Some(index) = self.bucket_index(group.start) {
                buckets[index].totals.add(&group.totals);
            }
        }
        let models = models.into_iter().map(|((provider, model), totals)| UsageRow {
            key: UsageModelKey { provider: provider.to_owned(), model: model.to_owned() },
            totals,
        });
        let named = |rows: HashMap<&str, UsageTotals>| {
            let rows = rows.into_iter().map(|(key, totals)| UsageRow { key: key.to_owned(), totals });
            ranked(rows, |a: &String, b: &String| a.cmp(b))
        };
        UsageSummary {
            totals,
            buckets,
            models: ranked(models, model_name_order),
            folders: named(folders),
            agents: named(agents),
        }
    }

    /// The last bucket starting at or before `date`; `None` before the first.
    fn bucket_index(&self, date: UsageDate) -> Option<usize> {
        self.bucket_starts.partition_point(|start| *start <= date).checked_sub(1)
    }
}

/// Models by `"{model} {provider}"`, compared without building the names.
fn model_name_order(a: &UsageModelKey, b: &UsageModelKey) -> Ordering {
    model_name(a).cmp(model_name(b))
}

fn model_name(key: &UsageModelKey) -> impl Iterator<Item = u8> {
    key.model.bytes().chain(std::iter::once(b' ')).chain(key.provider.bytes())
}

/// Highest cost first, then most tokens, then by name.
fn ranked<K>(
    rows: impl Iterator<Item = UsageRow<K>>,
    by_name: impl Fn(&K, &K) -> Ordering,
) -> Vec<UsageRow<K>> {
    let mut rows: Vec<UsageRow<K>> = rows.collect();
    rows.sort_by(|a, b| {
        let by_cost = b.totals.cost().partial_cmp(&a.totals.cost()).unwrap_or(Ordering::Equal);
        by_cost.then_with(|| b.totals.tokens().cmp(&a.totals.tokens())).then_with(|| by_name(&a.key, &b.key))
    });
    rows
}

/// What the statistics board shows for one period and model filter.
#[derive(Clone, Debug, PartialEq)]
pub struct UsageSummary {
    pub totals: UsageTotals,
    pub buckets: Vec<UsageBucket>,
    /// Every model of the period, unfiltered.
    pub models: Vec<UsageRow<UsageModelKey>>,
    /// omp session folders (see [`super::folder_name`]).
    pub folders: Vec<UsageRow<String>>,
    /// omp agent kinds (`main`, `subagent`, `advisor`, …).
    pub agents: Vec<UsageRow<String>>,
}

/// The usage history of `period` up to `now`. `sync` first ingests what the agent recorded since
/// the last read (the board does on open and Refresh, not on every period switch); a failed sync
/// still reads what was recorded before and reports itself in [`UsageHistory::sync_error`].
/// Blocking, like the service.
pub fn usage_history<Tz: TimeZone>(
    service: &dyn UsageStatisticsService,
    period: UsagePeriod,
    sync: bool,
    now: UsageDate,
    tz: &Tz,
) -> Result<UsageHistory, UsageStatisticsError> {
    let sync_error = if sync { service.sync().err().map(|error| error.to_string()) } else { None };
    let groups = service.groups(period.start(now, tz), period.granularity())?;
    Ok(UsageHistory::new(period, now, groups, sync_error, tz))
}
