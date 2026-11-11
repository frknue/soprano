//! omp's usage history for the statistics board: the periods and their chart buckets, the summed
//! totals, the per-model / folder / agent breakdowns and the reader of omp's `stats.db`. No
//! formatting and no UI; the board turns a [`UsageSummary`] into numbers and bars.

pub mod folder_name;
mod omp;
mod statistics;
mod summary;

pub use omp::OmpUsageStatistics;
pub use statistics::{
    UsageBucketUnit, UsageDate, UsageGranularity, UsageGroup, UsageMetric, UsagePart, UsagePeriod,
    UsageStatisticsError, UsageStatisticsService, UsageTotals,
};
pub use summary::{UsageBucket, UsageHistory, UsageModelKey, UsageRow, UsageSummary, usage_history};
