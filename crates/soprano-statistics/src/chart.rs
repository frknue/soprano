//! The stacked chart's numbers (`UsageChartView`): its scale, which bars get a label under
//! them, and the order the token kinds stack in.

use soprano_agents::usage::UsagePart;

/// The token kinds of a bar, bottom to top.
pub const STACK_ORDER: [UsagePart; 4] =
    [UsagePart::CacheRead, UsagePart::CacheWrite, UsagePart::Input, UsagePart::Output];

/// Up to this many bars, every label sits centered under its bar; with more, the last one
/// ends at the chart's edge instead of running past it.
pub const CENTERED_LABEL_LIMIT: usize = 12;

/// The smallest 1, 2, 2.5 or 5 × 10ⁿ at or above `value` (1 for nothing).
pub fn nice_ceiling(value: f64) -> f64 {
    if value <= 0.0 || !value.is_finite() {
        return 1.0;
    }
    let magnitude = 10f64.powf(value.log10().floor());
    [1.0, 2.0, 2.5, 5.0, 10.0]
        .into_iter()
        .map(|step| step * magnitude)
        .find(|candidate| *candidate >= value)
        .unwrap_or(10.0 * magnitude)
}

/// The bars that get a label under them: the last one and every `stride`-th before it, about
/// seven in all, ascending.
pub fn labeled_buckets(count: usize) -> Vec<usize> {
    let stride = count.div_ceil(7).max(1);
    let mut indices: Vec<usize> = (0..count).rev().step_by(stride).collect();
    indices.reverse();
    indices
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_chart_scale_rounds_up_to_a_readable_step() {
        assert_eq!(nice_ceiling(0.0), 1.0);
        assert_eq!(nice_ceiling(76.4), 100.0);
        assert_eq!(nice_ceiling(140.0), 200.0);
        assert_eq!(nice_ceiling(230.0), 250.0);
        assert_eq!(nice_ceiling(4.2), 5.0);
        assert_eq!(nice_ceiling(500.0), 500.0);
    }

    #[test]
    fn a_week_labels_every_bar_and_longer_periods_about_seven() {
        assert_eq!(labeled_buckets(0), Vec::<usize>::new());
        assert_eq!(labeled_buckets(7), vec![0, 1, 2, 3, 4, 5, 6]);
        assert_eq!(labeled_buckets(25), vec![0, 4, 8, 12, 16, 20, 24]);
        assert_eq!(labeled_buckets(30), vec![4, 9, 14, 19, 24, 29]);
        assert_eq!(labeled_buckets(90), vec![11, 24, 37, 50, 63, 76, 89]);
    }
}
