//! Number and date text of the statistics board (`StatisticsFormat.swift`). Dates are wall
//! times: the board converts each instant with its host's clock first.

use chrono::NaiveDateTime;
use soprano_agents::usage::{UsageBucketUnit, UsageMetric, UsageTotals};

/// `$0`, `<$0.01`, `$0.09`, `$701.64`, `$12,345`.
pub fn cost(value: f64) -> String {
    if value <= 0.0 {
        return "$0".into();
    }
    if value < 0.01 {
        return "<$0.01".into();
    }
    // Rounded first: $999.996 shows as $1,000, not $1000.00.
    if (value * 100.0).round() < 100_000.0 {
        return format!("${value:.2}");
    }
    format!("${}", grouped(value.round() as u64))
}

/// `950`, `62.4k`, `5.1M`, `1.78B`. The unit follows the rounded value: 999,960 is `1M`.
pub fn tokens(count: u64) -> String {
    fn scaled(value: f64, suffix: &str, decimals: usize) -> String {
        let mut text = format!("{value:.decimals$}");
        while text.ends_with('0') {
            text.pop();
        }
        if text.ends_with('.') {
            text.pop();
        }
        text + suffix
    }
    fn rounded(value: f64) -> f64 {
        (value * 10.0).round() / 10.0
    }
    let value = count as f64;
    if count >= 1_000_000_000 || rounded(value / 1e6) >= 1000.0 {
        return scaled(value / 1e9, "B", 2);
    }
    if count >= 1_000_000 || rounded(value / 1e3) >= 1000.0 {
        return scaled(value / 1e6, "M", 1);
    }
    if count >= 1000 {
        return scaled(value / 1e3, "k", 1);
    }
    count.to_string()
}

/// `7,353`.
pub fn count(value: u64) -> String {
    grouped(value)
}

/// `62%`, `99.8%`, `0.4%`: one decimal below 10% and above 99%, else whole percents.
pub fn percent(fraction: f64) -> String {
    let percent = fraction * 100.0;
    if percent > 0.0 && (percent < 10.0 || (percent > 99.0 && percent < 100.0)) {
        let text = format!("{percent:.1}");
        return format!("{}%", text.strip_suffix(".0").unwrap_or(&text));
    }
    format!("{}%", percent.round() as i64)
}

/// The totals' cost or token count.
pub fn value(totals: &UsageTotals, metric: UsageMetric) -> String {
    match metric {
        UsageMetric::Cost => cost(totals.cost()),
        UsageMetric::Tokens => tokens(totals.tokens()),
    }
}

/// Axis value for the chart: `$0`, `$2.50`, `$5`, `$100`, `$1,500`; tokens compact.
pub fn axis_value(value: f64, metric: UsageMetric) -> String {
    match metric {
        UsageMetric::Cost if value >= 10.0 || value == value.round() => {
            format!("${}", grouped(value.round() as u64))
        }
        UsageMetric::Cost => format!("${value:.2}"),
        UsageMetric::Tokens => tokens(value.round() as u64),
    }
}

/// `14:05`.
pub fn time(date: NaiveDateTime) -> String {
    date.format("%H:%M").to_string()
}

/// Axis label under a bar: `14:00`, `Oct 30`, `Oct`.
pub fn axis_label(date: NaiveDateTime, unit: UsageBucketUnit) -> String {
    let pattern = match unit {
        UsageBucketUnit::Hour => "%H:%M",
        UsageBucketUnit::Day | UsageBucketUnit::Week => "%b %-d",
        UsageBucketUnit::Month => "%b",
    };
    date.format(pattern).to_string()
}

/// The hovered bar's title: `Oct 31, 14:00`, `Fri, Oct 30`, `Week of Oct 27`, `October 2026`.
pub fn bucket_title(date: NaiveDateTime, unit: UsageBucketUnit) -> String {
    let pattern = match unit {
        UsageBucketUnit::Hour => "%b %-d, %H:%M",
        UsageBucketUnit::Day => "%a, %b %-d",
        UsageBucketUnit::Week => "Week of %b %-d",
        UsageBucketUnit::Month => "%B %Y",
    };
    date.format(pattern).to_string()
}

/// omp's agent kinds: `main` → Main agent, `subagent` → Subagents, `advisor` → Advisor.
pub fn agent_title(agent: &str) -> String {
    match agent {
        "main" => "Main agent".into(),
        "subagent" => "Subagents".into(),
        "advisor" => "Advisor".into(),
        other => {
            let mut letters = other.chars();
            match letters.next() {
                Some(first) => first.to_uppercase().chain(letters).collect(),
                None => String::new(),
            }
        }
    }
}

/// `12345` → `12,345`.
fn grouped(value: u64) -> String {
    let digits = value.to_string();
    let mut text = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            text.push(',');
        }
        text.push(digit);
    }
    text
}

#[cfg(test)]
mod tests {
    use chrono::NaiveDate;

    use super::*;

    #[test]
    fn token_counts_scale_to_thousands_millions_and_billions() {
        assert_eq!(tokens(950), "950");
        assert_eq!(tokens(62_400), "62.4k");
        assert_eq!(tokens(200_000), "200k");
        assert_eq!(tokens(5_116_590), "5.1M");
        assert_eq!(tokens(1_781_725_306), "1.78B");
        assert_eq!(tokens(3_000_000_000), "3B");
    }

    #[test]
    fn a_total_that_rounds_up_to_the_next_unit_shows_in_that_unit() {
        assert_eq!(tokens(999_949), "999.9k");
        assert_eq!(tokens(999_960), "1M");
        assert_eq!(tokens(999_960_000), "1B");
        assert_eq!(cost(999.99), "$999.99");
        assert_eq!(cost(999.996), "$1,000");
    }

    #[test]
    fn costs_keep_cents_until_a_thousand_and_flag_tiny_amounts() {
        assert_eq!(cost(0.0), "$0");
        assert_eq!(cost(0.004), "<$0.01");
        assert_eq!(cost(0.09), "$0.09");
        assert_eq!(cost(701.644), "$701.64");
        assert_eq!(cost(12_345.6), "$12,346");
        assert_eq!(axis_value(0.0, UsageMetric::Cost), "$0");
        assert_eq!(axis_value(2.5, UsageMetric::Cost), "$2.50");
        assert_eq!(axis_value(1500.0, UsageMetric::Cost), "$1,500");
        assert_eq!(axis_value(2_500_000.0, UsageMetric::Tokens), "2.5M");
    }

    #[test]
    fn percentages_show_a_decimal_only_near_the_ends() {
        assert_eq!(percent(0.0), "0%");
        assert_eq!(percent(0.004), "0.4%");
        assert_eq!(percent(0.62), "62%");
        assert_eq!(percent(0.9975), "99.8%");
        assert_eq!(percent(1.0), "100%");
    }

    #[test]
    fn counts_group_their_thousands() {
        assert_eq!(count(7), "7");
        assert_eq!(count(999), "999");
        assert_eq!(count(7_353), "7,353");
        assert_eq!(count(1_234_567), "1,234,567");
    }

    #[test]
    fn bars_are_named_by_their_hour_day_week_or_month() {
        let date =
            NaiveDate::from_ymd_opt(2026, 10, 30).and_then(|day| day.and_hms_opt(14, 0, 0)).expect("date");
        assert_eq!(axis_label(date, UsageBucketUnit::Hour), "14:00");
        assert_eq!(axis_label(date, UsageBucketUnit::Day), "Oct 30");
        assert_eq!(axis_label(date, UsageBucketUnit::Month), "Oct");
        assert_eq!(bucket_title(date, UsageBucketUnit::Hour), "Oct 30, 14:00");
        assert_eq!(bucket_title(date, UsageBucketUnit::Day), "Fri, Oct 30");
        assert_eq!(bucket_title(date, UsageBucketUnit::Week), "Week of Oct 30");
        assert_eq!(bucket_title(date, UsageBucketUnit::Month), "October 2026");
        assert_eq!(time(date), "14:00");
    }

    #[test]
    fn agent_kinds_read_as_titles() {
        assert_eq!(agent_title("main"), "Main agent");
        assert_eq!(agent_title("subagent"), "Subagents");
        assert_eq!(agent_title("advisor"), "Advisor");
        assert_eq!(agent_title("reviewer"), "Reviewer");
        assert_eq!(agent_title(""), "");
    }
}
