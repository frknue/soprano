//! The board driven headlessly over a canned history: what a load asks of the host, what the
//! keys and the model filter change, and what a failed read leaves on screen.

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::{Arc, Mutex};

use chrono::{FixedOffset, TimeZone as _};
use gpui::{Entity, Focusable as _, TestAppContext, VisualTestContext, px, size};
use soprano_agents::usage::{
    UsageDate, UsageGranularity, UsageGroup, UsageMetric, UsageModelKey, UsagePeriod, UsageStatisticsError,
    UsageStatisticsService, UsageTotals, folder_name, usage_history,
};

use super::{StatisticsBoard, StatisticsEvent, StatisticsHost};

const HOME: &str = "/Users/demo";
const TEMPORARY: &str = "/var/demo-tmp";

fn zone() -> FixedOffset {
    FixedOffset::east_opt(3600).expect("offset")
}

/// 2026-11-11 15:30 local.
fn now() -> UsageDate {
    zone().with_ymd_and_hms(2026, 11, 11, 15, 30, 0).single().expect("now").to_utc()
}

fn days_ago(days: i64) -> UsageDate {
    now() - chrono::Duration::days(days)
}

fn group(start: UsageDate, model: &str, folder: &str, cost: f64) -> UsageGroup {
    UsageGroup {
        start,
        provider: "anthropic".into(),
        model: model.into(),
        agent: "main".into(),
        folder: folder.into(),
        totals: UsageTotals {
            requests: 1,
            output_tokens: 1_000,
            output_cost: cost,
            ..UsageTotals::default()
        },
    }
}

/// A canned history; records what the board asked for and fails on demand.
#[derive(Default)]
struct Recorded {
    groups: Vec<UsageGroup>,
    syncs: usize,
    reads: Vec<Option<UsageDate>>,
    fail_reads: bool,
    fail_syncs: bool,
}

#[derive(Clone, Default)]
struct Service(Arc<Mutex<Recorded>>);

impl UsageStatisticsService for Service {
    fn sync(&self) -> Result<(), UsageStatisticsError> {
        let mut recorded = self.0.lock().expect("lock");
        recorded.syncs += 1;
        if recorded.fail_syncs {
            Err(UsageStatisticsError::Sync("omp is not installed".into()))
        } else {
            Ok(())
        }
    }

    fn groups(
        &self,
        since: Option<UsageDate>,
        _: UsageGranularity,
    ) -> Result<Vec<UsageGroup>, UsageStatisticsError> {
        let mut recorded = self.0.lock().expect("lock");
        recorded.reads.push(since);
        if recorded.fail_reads {
            return Err(UsageStatisticsError::Database("no such table: messages".into()));
        }
        Ok(recorded
            .groups
            .iter()
            .filter(|group| since.is_none_or(|since| group.start >= since))
            .cloned()
            .collect())
    }
}

struct Harness {
    board: Entity<StatisticsBoard>,
    service: Service,
    events: Rc<RefCell<Vec<StatisticsEvent>>>,
}

impl Harness {
    fn recorded<T>(&self, read: impl FnOnce(&mut Recorded) -> T) -> T {
        read(&mut self.service.0.lock().expect("lock"))
    }
}

fn open(
    cx: &mut TestAppContext,
    groups: Vec<UsageGroup>,
    folders: Vec<(PathBuf, String)>,
) -> (Harness, &mut VisualTestContext) {
    cx.update(soprano_ui::init_for_tests);
    let service = Service::default();
    service.0.lock().expect("lock").groups = groups;
    let history = service.clone();
    let host = StatisticsHost::new(move |period, sync| usage_history(&history, period, sync, now(), &zone()))
        .folders(move |_| folders.clone())
        .home(HOME)
        .temporary_directory(TEMPORARY)
        .wall_time(|date| date.with_timezone(&zone()).naive_local());
    let (board, cx) = cx.add_window_view(move |window, cx| StatisticsBoard::new(host, window, cx));
    cx.simulate_resize(size(px(1100.), px(800.)));
    let events = Rc::new(RefCell::new(Vec::new()));
    let recorded = events.clone();
    cx.update(|window, cx| {
        cx.subscribe(&board, move |_, event: &StatisticsEvent, _| recorded.borrow_mut().push(event.clone()))
            .detach();
        let focus = board.focus_handle(cx);
        window.focus(&focus, cx);
    });
    cx.run_until_parked();
    (Harness { board, service, events }, cx)
}

fn two_models() -> Vec<UsageGroup> {
    vec![
        group(days_ago(1), "claude-opus-5-5", "-git-app", 6.0),
        group(days_ago(2), "gpt-6.1-sol", "-git-app", 2.0),
        group(days_ago(20), "claude-opus-5-5", "-git-site", 4.0),
    ]
}

#[gpui::test]
fn opening_syncs_once_and_shows_the_last_seven_days(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, two_models(), Vec::new());
    assert_eq!(harness.recorded(|recorded| recorded.syncs), 1);
    harness.board.read_with(cx, |board, _| {
        assert_eq!((board.period(), board.metric()), (UsagePeriod::Week, UsageMetric::Cost));
        assert!(!board.is_loading());
        let summary = board.summary().expect("summary");
        assert_eq!(summary.buckets.len(), 7);
        assert_eq!(summary.totals.cost(), 8.0);
    });
}

#[gpui::test]
fn switching_the_period_reads_again_without_another_sync(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, two_models(), Vec::new());
    cx.simulate_keystrokes("3");
    cx.run_until_parked();
    assert_eq!(harness.recorded(|recorded| (recorded.syncs, recorded.reads.len())), (1, 2));
    harness.board.read_with(cx, |board, _| {
        assert_eq!(board.period(), UsagePeriod::Month);
        assert_eq!(board.summary().expect("summary").totals.cost(), 12.0);
    });

    // The period already shown is not read again; Refresh syncs.
    cx.simulate_keystrokes("3");
    cx.run_until_parked();
    assert_eq!(harness.recorded(|recorded| recorded.reads.len()), 2);
    harness.board.update(cx, |board, cx| board.load(true, cx));
    cx.run_until_parked();
    assert_eq!(harness.recorded(|recorded| (recorded.syncs, recorded.reads.len())), (2, 3));
}

#[gpui::test]
fn c_and_t_switch_the_metric_and_escape_asks_to_close(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, two_models(), Vec::new());
    cx.simulate_keystrokes("t");
    assert_eq!(harness.board.read_with(cx, |board, _| board.metric()), UsageMetric::Tokens);
    cx.simulate_keystrokes("c");
    assert_eq!(harness.board.read_with(cx, |board, _| board.metric()), UsageMetric::Cost);
    assert!(harness.events.borrow().is_empty());
    cx.simulate_keystrokes("escape");
    assert_eq!(*harness.events.borrow(), [StatisticsEvent::Close]);
}

#[gpui::test]
fn choosing_a_model_filters_everything_but_the_model_list(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, two_models(), Vec::new());
    let sol = UsageModelKey { provider: "anthropic".into(), model: "gpt-6.1-sol".into() };
    harness.board.update(cx, |board, cx| board.select_model(Some(sol.clone()), cx));
    harness.board.read_with(cx, |board, _| {
        let summary = board.summary().expect("summary");
        assert_eq!(summary.totals.cost(), 2.0);
        assert_eq!(summary.models.len(), 2);
        assert_eq!(board.model_filter(), Some(&sol));
    });

    // Choosing it again shows every model.
    harness.board.update(cx, |board, cx| board.select_model(Some(sol.clone()), cx));
    harness.board.read_with(cx, |board, _| {
        assert_eq!(board.model_filter(), None);
        assert_eq!(board.summary().expect("summary").totals.cost(), 8.0);
    });
}

#[gpui::test]
fn a_filter_on_a_model_the_new_period_lacks_is_dropped(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, two_models(), Vec::new());
    let sol = UsageModelKey { provider: "anthropic".into(), model: "gpt-6.1-sol".into() };
    harness.board.update(cx, |board, cx| board.select_model(Some(sol), cx));
    // Sol's only request is two days old: the last 24 hours have none.
    cx.simulate_keystrokes("1");
    cx.run_until_parked();
    harness.board.read_with(cx, |board, _| {
        assert_eq!(board.period(), UsagePeriod::Day);
        assert_eq!(board.model_filter(), None);
        assert_eq!(board.summary().expect("summary").totals.cost(), 6.0);
    });
}

#[gpui::test]
fn a_failed_read_keeps_the_same_periods_numbers_and_drops_another_periods(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, two_models(), Vec::new());
    harness.recorded(|recorded| recorded.fail_reads = true);

    harness.board.update(cx, |board, cx| board.load(true, cx));
    cx.run_until_parked();
    harness.board.read_with(cx, |board, _| {
        assert_eq!(
            board.load_error(),
            Some("Couldn’t read omp’s usage statistics: no such table: messages.")
        );
        assert_eq!(board.summary().expect("the earlier read stays").totals.cost(), 8.0);
    });

    cx.simulate_keystrokes("3");
    cx.run_until_parked();
    harness.board.read_with(cx, |board, _| {
        assert!(board.load_error().is_some());
        assert!(board.history().is_none() && board.summary().is_none());
    });

    // Reading works again: the error goes with the next read.
    harness.recorded(|recorded| recorded.fail_reads = false);
    harness.board.update(cx, |board, cx| board.load(true, cx));
    cx.run_until_parked();
    harness.board.read_with(cx, |board, _| {
        assert_eq!(board.load_error(), None);
        assert_eq!(board.summary().expect("summary").totals.cost(), 12.0);
    });
}

#[gpui::test]
fn a_failed_sync_still_shows_what_was_recorded_before(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, two_models(), Vec::new());
    harness.recorded(|recorded| recorded.fail_syncs = true);
    harness.board.update(cx, |board, cx| board.load(true, cx));
    cx.run_until_parked();
    harness.board.read_with(cx, |board, _| {
        let history = board.history().expect("history");
        assert_eq!(history.sync_error.as_deref(), Some("omp is not installed"));
        assert_eq!(board.load_error(), None);
        assert_eq!(board.summary().expect("summary").totals.cost(), 8.0);
    });
}

#[gpui::test]
fn usage_in_a_workspace_folder_is_listed_under_its_title(cx: &mut TestAppContext) {
    let app = PathBuf::from(HOME).join("git/app");
    let folder = folder_name::encode(&app, HOME.as_ref(), TEMPORARY.as_ref());
    let groups = vec![
        group(days_ago(1), "claude-opus-5-5", &folder, 6.0),
        group(days_ago(1), "claude-opus-5-5", "-Downloads-experiments", 2.0),
    ];
    let (harness, cx) = open(cx, groups, vec![(app, "app".to_owned())]);
    let rows = harness.board.read_with(cx, |board, _| board.project_rows());
    assert_eq!(
        rows.iter().map(|row| (row.title.as_str(), row.value.as_str())).collect::<Vec<_>>(),
        [("app", "$6.00"), ("Downloads-experiments", "$2.00")]
    );
}

#[gpui::test]
fn the_board_draws_its_chart_at_every_period_and_without_any_usage(cx: &mut TestAppContext) {
    let (harness, cx) = open(cx, two_models(), Vec::new());
    for key in ["1", "2", "3", "4", "5", "t"] {
        cx.simulate_keystrokes(key);
        cx.run_until_parked();
        assert!(cx.debug_bounds("statistics-chart").is_some(), "after {key}");
    }
    harness.recorded(|recorded| recorded.groups.clear());
    harness.board.update(cx, |board, cx| board.load(true, cx));
    cx.run_until_parked();
    let chart = cx.debug_bounds("statistics-chart").expect("an empty history still has its chart");
    assert!(chart.size.width > px(400.));
    harness.board.read_with(cx, |board, _| {
        assert_eq!(board.summary().expect("summary").totals.requests, 0);
        assert!(board.project_rows().is_empty());
    });
}
