//! What the board shows for one summary, as plain data: the headline tiles, the model, project
//! and agent lines, the chart's title line and the footnote
//! (`StatisticsViewController`'s `tiles`, `modelsCard`, `projectsCard`, `agentsCard`,
//! `updateReadout` and `footnote`).

use std::cmp::Ordering;
use std::collections::HashMap;

use chrono::NaiveDateTime;
use soprano_agents::usage::{
    UsageBucketUnit, UsageMetric, UsageModelKey, UsagePeriod, UsageSummary, UsageTotals, folder_name,
};

use crate::format;

/// How many projects are listed before the rest is summed into "N more".
pub const PROJECT_LIMIT: usize = 8;

/// A headline number: its title, the value, one line of detail.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Tile {
    pub title: &'static str,
    pub value: String,
    pub detail: String,
}

/// The four tiles: for Cost the estimated cost, cache savings, requests and cost per request;
/// for Tokens the total, input, output and cache read.
pub fn tiles(totals: &UsageTotals, metric: UsageMetric) -> [Tile; 4] {
    let tile = |title, value, detail| Tile { title, value, detail };
    match metric {
        UsageMetric::Cost => {
            let cost_detail = if totals.unpriced_requests > 0 {
                format!("{} requests unpriced", format::count(totals.unpriced_requests))
            } else {
                "At API rates".to_owned()
            };
            let hit = totals.cache_hit_rate().map_or_else(
                || "No prompt tokens".to_owned(),
                |rate| format!("{} of prompt tokens cached", format::percent(rate)),
            );
            let failures = if totals.failed_requests == 0 {
                "No failed requests".to_owned()
            } else {
                format!("{} failed", format::count(totals.failed_requests))
            };
            let (per_request, tokens_per_request) = match totals.requests {
                0 => (0.0, 0),
                requests => (totals.cost() / requests as f64, totals.tokens() / requests),
            };
            [
                tile("Estimated cost", format::cost(totals.cost()), cost_detail),
                tile("Cache savings", format::cost(totals.cache_savings()), hit),
                tile("Requests", format::count(totals.requests), failures),
                tile(
                    "Per request",
                    format::cost(per_request),
                    format!("{} tokens each", format::tokens(tokens_per_request)),
                ),
            ]
        }
        UsageMetric::Tokens => {
            let hit = totals.cache_hit_rate().map_or_else(
                || "No prompt tokens".to_owned(),
                |rate| format!("{} hit rate", format::percent(rate)),
            );
            [
                tile(
                    "Total tokens",
                    format::tokens(totals.tokens()),
                    format!("{} requests", format::count(totals.requests)),
                ),
                tile("Input", format::tokens(totals.input_tokens), "Uncached prompt".to_owned()),
                tile("Output", format::tokens(totals.output_tokens), "Including reasoning".to_owned()),
                tile(
                    "Cache read",
                    format::tokens(totals.cache_read_tokens),
                    format!("{} written · {hit}", format::tokens(totals.cache_write_tokens)),
                ),
            ]
        }
    }
}

/// One line of a breakdown: who, its share of the listed total, and the value.
#[derive(Clone, Debug, PartialEq)]
pub struct BreakdownRow {
    pub title: String,
    /// 0…1 of the breakdown's total.
    pub share: f64,
    pub value: String,
}

/// One model: its line, provider, request count, cache hit rate, and what a click filters to.
#[derive(Clone, Debug, PartialEq)]
pub struct ModelRow {
    pub key: UsageModelKey,
    pub row: BreakdownRow,
    /// `1,234 req`.
    pub requests: String,
    /// `62% cached`, or `—` without prompt tokens.
    pub cached: String,
    /// The model has requests but no known price: its value reads "Unpriced".
    pub unpriced: bool,
}

/// Every model of the period, the largest first by the shown metric.
pub fn model_rows(summary: &UsageSummary, metric: UsageMetric) -> Vec<ModelRow> {
    let mut models: Vec<_> = summary.models.iter().collect();
    models.sort_by(|a, b| descending(a.totals.value(metric), b.totals.value(metric)));
    let total: f64 = models.iter().map(|row| row.totals.value(metric)).sum();
    models
        .into_iter()
        .map(|model| {
            let totals = &model.totals;
            let unpriced =
                metric == UsageMetric::Cost && totals.cost() == 0.0 && totals.unpriced_requests > 0;
            ModelRow {
                key: model.key.clone(),
                row: BreakdownRow {
                    title: model.key.model.clone(),
                    share: share(totals.value(metric), total),
                    value: if unpriced { "Unpriced".to_owned() } else { format::value(totals, metric) },
                },
                requests: format!("{} req", format::count(totals.requests)),
                cached: totals
                    .cache_hit_rate()
                    .map_or_else(|| "—".to_owned(), |rate| format!("{} cached", format::percent(rate))),
                unpriced,
            }
        })
        .collect()
}

/// The projects: omp's session folders under the titles the workspace has for them (`titles`,
/// by stats folder), else the folder's own readable name; folders sharing a title are summed.
/// The largest [`PROJECT_LIMIT`] are listed, the rest as "N more".
pub fn project_rows(
    summary: &UsageSummary,
    metric: UsageMetric,
    titles: &HashMap<String, String>,
) -> Vec<BreakdownRow> {
    let mut merged: HashMap<String, UsageTotals> = HashMap::new();
    for folder in &summary.folders {
        let title =
            titles.get(&folder.key).cloned().unwrap_or_else(|| folder_name::fallback_title(&folder.key));
        merged.entry(title).or_default().add(&folder.totals);
    }
    let mut ranked: Vec<(String, UsageTotals)> = merged.into_iter().collect();
    ranked.sort_by(|a, b| descending(a.1.value(metric), b.1.value(metric)).then_with(|| a.0.cmp(&b.0)));
    let total: f64 = ranked.iter().map(|(_, totals)| totals.value(metric)).sum();
    if ranked.len() > PROJECT_LIMIT {
        let hidden = ranked.len() - PROJECT_LIMIT;
        let mut rest = UsageTotals::default();
        for (_, totals) in ranked.drain(PROJECT_LIMIT..) {
            rest.add(&totals);
        }
        ranked.push((format!("{hidden} more"), rest));
    }
    ranked.into_iter().map(|(title, totals)| breakdown_row(title, &totals, metric, total)).collect()
}

/// omp's agent kinds, the largest first.
pub fn agent_rows(summary: &UsageSummary, metric: UsageMetric) -> Vec<BreakdownRow> {
    let mut agents: Vec<_> = summary.agents.iter().collect();
    agents.sort_by(|a, b| descending(a.totals.value(metric), b.totals.value(metric)));
    let total: f64 = agents.iter().map(|row| row.totals.value(metric)).sum();
    agents
        .into_iter()
        .map(|agent| breakdown_row(format::agent_title(&agent.key), &agent.totals, metric, total))
        .collect()
}

/// The chart's title line: the hovered bar (`Fri, Oct 30 · $12.40 · 310 requests`), else the
/// period's total (`7d total · $701.64 · claude-opus-5-5` under a model filter).
pub fn readout(
    period: UsagePeriod,
    unit: UsageBucketUnit,
    summary: &UsageSummary,
    metric: UsageMetric,
    filter: Option<&UsageModelKey>,
    hovered: Option<usize>,
    wall_time: impl Fn(soprano_agents::usage::UsageDate) -> NaiveDateTime,
) -> String {
    match hovered.and_then(|index| summary.buckets.get(index)) {
        Some(bucket) => format!(
            "{} · {} · {} requests",
            format::bucket_title(wall_time(bucket.start), unit),
            format::value(&bucket.totals, metric),
            format::count(bucket.totals.requests),
        ),
        None => {
            let scope = filter.map(|key| format!(" · {}", key.model)).unwrap_or_default();
            format!("{} total · {}{scope}", period.title(), format::value(&summary.totals, metric))
        }
    }
}

/// The line under the board: what the numbers are, and when they were read.
pub fn footnote(updated_at: Option<NaiveDateTime>) -> String {
    let mut text = "Estimated from omp's usage records at API prices, not your subscription bill. \
        Counts every omp session on this computer, not only the ones in Soprano."
        .to_owned();
    if let Some(updated_at) = updated_at {
        text.push_str(&format!(" Updated {}.", format::time(updated_at)));
    }
    text
}

fn breakdown_row(title: String, totals: &UsageTotals, metric: UsageMetric, total: f64) -> BreakdownRow {
    BreakdownRow { title, share: share(totals.value(metric), total), value: format::value(totals, metric) }
}

fn share(value: f64, total: f64) -> f64 {
    if total > 0.0 { (value / total).clamp(0.0, 1.0) } else { 0.0 }
}

fn descending(a: f64, b: f64) -> Ordering {
    b.partial_cmp(&a).unwrap_or(Ordering::Equal)
}

#[cfg(test)]
mod tests {
    use soprano_agents::usage::{UsageBucket, UsageRow};

    use super::*;

    fn totals(requests: u64, cost: f64, tokens: u64) -> UsageTotals {
        UsageTotals { requests, output_cost: cost, output_tokens: tokens, ..UsageTotals::default() }
    }

    fn summary(folders: Vec<(&str, UsageTotals)>) -> UsageSummary {
        let mut all = UsageTotals::default();
        for (_, totals) in &folders {
            all.add(totals);
        }
        UsageSummary {
            totals: all,
            buckets: Vec::new(),
            models: Vec::new(),
            folders: folders
                .into_iter()
                .map(|(key, totals)| UsageRow { key: key.to_owned(), totals })
                .collect(),
            agents: Vec::new(),
        }
    }

    #[test]
    fn cost_tiles_show_savings_failures_and_the_cost_of_one_request() {
        let totals = UsageTotals {
            requests: 1_200,
            failed_requests: 3,
            input_tokens: 100_000,
            output_tokens: 300_000,
            cache_read_tokens: 900_000,
            cache_write_tokens: 0,
            input_cost: 1.0,
            output_cost: 9.0,
            cache_read_cost: 2.0,
            cache_write_cost: 0.0,
            unpriced_requests: 0,
            cached_prompt_cost: 3.0,
            uncached_prompt_cost: 10.5,
        };
        let [cost, savings, requests, each] = tiles(&totals, UsageMetric::Cost);
        assert_eq!(
            (cost.title, cost.value.as_str(), cost.detail.as_str()),
            ("Estimated cost", "$12.00", "At API rates")
        );
        assert_eq!(
            (savings.value.as_str(), savings.detail.as_str()),
            ("$7.50", "90% of prompt tokens cached")
        );
        assert_eq!((requests.value.as_str(), requests.detail.as_str()), ("1,200", "3 failed"));
        assert_eq!((each.value.as_str(), each.detail.as_str()), ("$0.01", "1.1k tokens each"));
    }

    #[test]
    fn unpriced_requests_are_named_under_the_cost_and_no_requests_cost_nothing_each() {
        let unpriced = UsageTotals { requests: 4, unpriced_requests: 4, ..UsageTotals::default() };
        assert_eq!(tiles(&unpriced, UsageMetric::Cost)[0].detail, "4 requests unpriced");

        let [_, savings, requests, each] = tiles(&UsageTotals::default(), UsageMetric::Cost);
        assert_eq!(savings.detail, "No prompt tokens");
        assert_eq!(requests.detail, "No failed requests");
        assert_eq!((each.value.as_str(), each.detail.as_str()), ("$0", "0 tokens each"));
    }

    #[test]
    fn token_tiles_split_the_total_by_kind() {
        let totals = UsageTotals {
            requests: 10,
            input_tokens: 1_000,
            output_tokens: 2_000,
            cache_read_tokens: 6_000,
            cache_write_tokens: 1_000,
            ..UsageTotals::default()
        };
        let [total, input, output, cache] = tiles(&totals, UsageMetric::Tokens);
        assert_eq!((total.value.as_str(), total.detail.as_str()), ("10k", "10 requests"));
        assert_eq!((input.value.as_str(), output.value.as_str()), ("1k", "2k"));
        assert_eq!((cache.value.as_str(), cache.detail.as_str()), ("6k", "1k written · 75% hit rate"));
    }

    #[test]
    fn models_rank_by_the_shown_metric_and_an_unpriced_one_says_so() {
        let key = |model: &str| UsageModelKey { provider: "p".into(), model: model.into() };
        let mut summary = summary(Vec::new());
        summary.models = vec![
            UsageRow { key: key("opus"), totals: totals(10, 30.0, 1_000) },
            UsageRow { key: key("sol"), totals: totals(5, 10.0, 9_000) },
            UsageRow {
                key: key("qwen"),
                totals: UsageTotals {
                    requests: 2,
                    unpriced_requests: 2,
                    output_tokens: 500,
                    ..UsageTotals::default()
                },
            },
        ];

        let by_cost = model_rows(&summary, UsageMetric::Cost);
        assert_eq!(
            by_cost.iter().map(|row| row.row.title.as_str()).collect::<Vec<_>>(),
            ["opus", "sol", "qwen"]
        );
        assert_eq!(by_cost[0].row.share, 0.75);
        assert_eq!((by_cost[0].requests.as_str(), by_cost[0].cached.as_str()), ("10 req", "—"));
        assert_eq!((by_cost[2].row.value.as_str(), by_cost[2].unpriced), ("Unpriced", true));

        let by_tokens = model_rows(&summary, UsageMetric::Tokens);
        assert_eq!(
            by_tokens.iter().map(|row| row.row.title.as_str()).collect::<Vec<_>>(),
            ["sol", "opus", "qwen"]
        );
        assert_eq!((by_tokens[2].row.value.as_str(), by_tokens[2].unpriced), ("500", false));
    }

    #[test]
    fn folders_of_one_workspace_project_are_summed_under_its_title() {
        let summary = summary(vec![
            ("-git-app", totals(1, 4.0, 0)),
            ("-git-app-worktrees-fix", totals(1, 2.0, 0)),
            ("-Downloads-experiments", totals(1, 2.0, 0)),
            ("-", totals(1, 0.0, 0)),
        ]);
        let titles = HashMap::from([
            ("-git-app".to_owned(), "app".to_owned()),
            ("-git-app-worktrees-fix".to_owned(), "app".to_owned()),
        ]);
        let rows = project_rows(&summary, UsageMetric::Cost, &titles);
        assert_eq!(
            rows.iter().map(|row| (row.title.as_str(), row.value.as_str())).collect::<Vec<_>>(),
            [("app", "$6.00"), ("Downloads-experiments", "$2.00"), ("~", "$0")]
        );
        assert_eq!(rows[0].share, 0.75);
    }

    #[test]
    fn projects_beyond_the_eighth_are_summed_into_one_line() {
        let names: Vec<String> = (0..11).map(|index| format!("-p{index:02}")).collect();
        let summary = summary(
            names
                .iter()
                .enumerate()
                .map(|(index, name)| (name.as_str(), totals(1, (20 - index) as f64, 0)))
                .collect(),
        );
        let rows = project_rows(&summary, UsageMetric::Cost, &HashMap::new());
        assert_eq!(rows.len(), PROJECT_LIMIT + 1);
        assert_eq!(rows[0].title, "p00");
        assert_eq!(rows[PROJECT_LIMIT - 1].title, "p07");
        // 12 + 11 + 10 of the three smallest.
        assert_eq!(
            (rows[PROJECT_LIMIT].title.as_str(), rows[PROJECT_LIMIT].value.as_str()),
            ("3 more", "$33.00")
        );
    }

    #[test]
    fn the_chart_title_reads_the_hovered_bar_else_the_period_total() {
        let start = chrono::DateTime::from_timestamp(1_793_000_000, 0).expect("date");
        let mut summary = summary(vec![("-git-app", totals(310, 12.4, 5_000))]);
        summary.buckets = vec![UsageBucket { start, totals: totals(310, 12.4, 5_000) }];
        let wall = |date: soprano_agents::usage::UsageDate| date.naive_utc();
        let filter = UsageModelKey { provider: "anthropic".into(), model: "claude-opus-5-5".into() };

        let total = |filter| {
            readout(UsagePeriod::Week, UsageBucketUnit::Day, &summary, UsageMetric::Cost, filter, None, wall)
        };
        assert_eq!(total(None), "7d total · $12.40");
        assert_eq!(total(Some(&filter)), "7d total · $12.40 · claude-opus-5-5");

        let hovered = readout(
            UsagePeriod::Week,
            UsageBucketUnit::Day,
            &summary,
            UsageMetric::Tokens,
            None,
            Some(0),
            wall,
        );
        assert_eq!(
            hovered,
            format!("{} · 5k · 310 requests", format::bucket_title(start.naive_utc(), UsageBucketUnit::Day))
        );
        // A bar that is gone (the period changed under the pointer) reads as no bar.
        let gone = readout(
            UsagePeriod::Week,
            UsageBucketUnit::Day,
            &summary,
            UsageMetric::Cost,
            None,
            Some(9),
            wall,
        );
        assert_eq!(gone, "7d total · $12.40");
    }

    #[test]
    fn the_footnote_ends_with_when_the_numbers_were_read() {
        assert!(footnote(None).ends_with("not only the ones in Soprano."));
        let read = chrono::NaiveDate::from_ymd_opt(2026, 11, 11).and_then(|day| day.and_hms_opt(14, 5, 0));
        assert!(footnote(read).ends_with(" Updated 14:05."));
    }
}
