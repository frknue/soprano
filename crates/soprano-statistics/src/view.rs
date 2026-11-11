//! The statistics board (`StatisticsViewController.swift`, as T3 Code's Usage page) on the
//! window's own surfaces: on `canvas`, the page header with the period control over a
//! scrolling column of `background` cards — Cost / Tokens, four headline tiles, the stacked
//! chart, then the models, projects and agent kinds.
//!
//! Keys while the keyboard is on the board: Esc closes, C / T switch Cost / Tokens, 1–5 pick
//! the period.

use std::collections::HashMap;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;

use chrono::{Local, NaiveDateTime, Utc};
use gpui::{
    AnyElement, App, AppContext as _, Context, ElementId, EventEmitter, FocusHandle, Focusable, FontWeight,
    Hsla, InteractiveElement, IntoElement, Keystroke, MouseButton, ParentElement, Render, ScrollHandle,
    SharedString, Stateful, StatefulInteractiveElement, Styled, Subscription, Task, Window, div, prelude::*,
    px, relative,
};
use soprano_agents::usage::{
    UsageDate, UsageHistory, UsageMetric, UsageModelKey, UsagePart, UsagePeriod, UsageStatisticsError,
    UsageStatisticsService, UsageSummary, folder_name, usage_history,
};
use soprano_ui::button::{Button, ButtonSize, IconButton};
use soprano_ui::chrome::{Card, ScrollList};
use soprano_ui::controls::SegmentedControl;
use soprano_ui::fonts::{self, size};
use soprano_ui::keycaps::Keycaps;
use soprano_ui::theme::ActiveSopranoTheme;
use soprano_ui::tooltip::tooltip;
use soprano_ui::{IconName, SopranoTheme};

use crate::chart::{self, CENTERED_LABEL_LIMIT, STACK_ORDER};
use crate::format;
use crate::keys::{KeyAction, key_action};
use crate::state::{self, BreakdownRow, Tile};

/// The page header.
const HEADER_HEIGHT: f32 = 48.0;
/// The column of cards is centered at up to this width.
const CONTENT_MAX_WIDTH: f32 = 960.0;
/// The chart: value labels left of the plot, bucket labels under it.
const CHART_HEIGHT: f32 = 200.0;
const CHART_AXIS_WIDTH: f32 = 56.0;
const CHART_TOP_INSET: f32 = 8.0;
const CHART_LABEL_HEIGHT: f32 = 18.0;
const CHART_LABEL_GAP: f32 = 6.0;
const CHART_LABEL_WIDTH: f32 = 64.0;
/// A bar fills two thirds of its slot, up to this width.
const BAR_MAXIMUM_WIDTH: f32 = 28.0;
/// One breakdown line.
const ROW_HEIGHT: f32 = 34.0;

/// What the board asks the app shell to do.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StatisticsEvent {
    /// Esc or the close button: back to the workspace.
    Close,
}

/// Reads one period's history, syncing omp's records first when asked. Blocking: the board
/// calls it on a background thread.
pub type HistoryLoader =
    Arc<dyn Fn(UsagePeriod, bool) -> Result<UsageHistory, UsageStatisticsError> + Send + Sync>;
/// The folders the workspace works in, each with the title its usage is listed under.
pub type FolderProvider = Rc<dyn Fn(&App) -> Vec<(PathBuf, String)>>;
/// An instant as the wall clock shows it (the chart's labels).
pub type WallTime = Rc<dyn Fn(UsageDate) -> NaiveDateTime>;

/// What the shell answers that the board does not know.
#[derive(Clone)]
pub struct StatisticsHost {
    pub load: HistoryLoader,
    /// Read when a load starts; omp's session folders of these are listed under their titles.
    pub folders: FolderProvider,
    /// Where `~` points and where the temporary folder is: omp names session folders by them.
    pub home: PathBuf,
    pub temporary_directory: PathBuf,
    pub wall_time: WallTime,
}

impl StatisticsHost {
    pub fn new(
        load: impl Fn(UsagePeriod, bool) -> Result<UsageHistory, UsageStatisticsError> + Send + Sync + 'static,
    ) -> Self {
        Self {
            load: Arc::new(load),
            folders: Rc::new(|_| Vec::new()),
            home: soprano_platform::paths::home_dir(),
            temporary_directory: std::env::temp_dir(),
            wall_time: Rc::new(|date| date.with_timezone(&Local).naive_local()),
        }
    }

    /// The history of `service` up to now, in the computer's time zone.
    pub fn service(service: Arc<dyn UsageStatisticsService>) -> Self {
        Self::new(move |period, sync| usage_history(service.as_ref(), period, sync, Utc::now(), &Local))
    }

    pub fn folders(mut self, provider: impl Fn(&App) -> Vec<(PathBuf, String)> + 'static) -> Self {
        self.folders = Rc::new(provider);
        self
    }

    pub fn home(mut self, home: impl Into<PathBuf>) -> Self {
        self.home = home.into();
        self
    }

    pub fn temporary_directory(mut self, directory: impl Into<PathBuf>) -> Self {
        self.temporary_directory = directory.into();
        self
    }

    pub fn wall_time(mut self, wall_time: impl Fn(UsageDate) -> NaiveDateTime + 'static) -> Self {
        self.wall_time = Rc::new(wall_time);
        self
    }
}

/// The statistics page. Create it with [`StatisticsBoard::new`] (which syncs omp's history
/// and reads the last 7 days), render it over the workspace, focus it ([`Focusable`]) when it
/// opens and drop it when it closes.
pub struct StatisticsBoard {
    host: StatisticsHost,
    period: UsagePeriod,
    metric: UsageMetric,
    model_filter: Option<UsageModelKey>,
    history: Option<UsageHistory>,
    /// `history` under `model_filter`.
    summary: Option<UsageSummary>,
    /// Stats folder → project title, as of the last read.
    folder_titles: HashMap<String, String>,
    /// Why the last read failed; `history` is then the same period's earlier read, if any.
    load_error: Option<String>,
    is_loading: bool,
    /// The running load syncs omp's history first.
    pending_sync: bool,
    updated_at: Option<NaiveDateTime>,
    /// The chart bar under the pointer.
    hovered_bucket: Option<usize>,
    focus: FocusHandle,
    scroll: ScrollHandle,
    /// The running read; a newer one replaces (and so cancels) it.
    load_task: Option<Task<()>>,
    _subscriptions: Vec<Subscription>,
}

impl EventEmitter<StatisticsEvent> for StatisticsBoard {}

impl Focusable for StatisticsBoard {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

impl StatisticsBoard {
    pub fn new(host: StatisticsHost, _: &mut Window, cx: &mut Context<Self>) -> Self {
        let entity = cx.entity().downgrade();
        let subscriptions = vec![cx.intercept_keystrokes(move |event, window, cx| {
            let Some(this) = entity.upgrade() else { return };
            if this.update(cx, |this, cx| this.handle_keystroke(&event.keystroke, window, cx)) {
                cx.stop_propagation();
            }
        })];
        let mut board = Self {
            host,
            period: UsagePeriod::Week,
            metric: UsageMetric::Cost,
            model_filter: None,
            history: None,
            summary: None,
            folder_titles: HashMap::new(),
            load_error: None,
            is_loading: false,
            pending_sync: false,
            updated_at: None,
            hovered_bucket: None,
            focus: cx.focus_handle(),
            scroll: ScrollHandle::new(),
            load_task: None,
            _subscriptions: subscriptions,
        };
        board.load(true, cx);
        board
    }

    // MARK: - Loading

    /// Reads the period's history; `sync` first lets omp ingest new session files. A newer
    /// load supersedes a running one and takes over its sync, so a period switch during the
    /// opening sync still shows fresh data.
    pub fn load(&mut self, sync: bool, cx: &mut Context<Self>) {
        let period = self.period;
        let sync = sync || self.pending_sync;
        self.pending_sync = sync;
        self.is_loading = true;
        let load = self.host.load.clone();
        let folders = (self.host.folders)(cx);
        let home = self.host.home.clone();
        let temporary_directory = self.host.temporary_directory.clone();
        let read = cx.background_spawn(async move {
            let history = load(period, sync);
            let titles: HashMap<String, String> = folders
                .into_iter()
                .map(|(folder, title)| (folder_name::encode(&folder, &home, &temporary_directory), title))
                .collect();
            (history, titles)
        });
        self.load_task = Some(cx.spawn(async move |this, cx| {
            let (history, titles) = read.await;
            this.update(cx, |this, cx| this.finish_load(period, history, titles, cx)).ok();
        }));
        cx.notify();
    }

    fn finish_load(
        &mut self,
        period: UsagePeriod,
        history: Result<UsageHistory, UsageStatisticsError>,
        titles: HashMap<String, String>,
        cx: &mut Context<Self>,
    ) {
        match history {
            Ok(history) => {
                if let Some(filter) = &self.model_filter
                    && !history
                        .groups
                        .iter()
                        .any(|group| group.provider == filter.provider && group.model == filter.model)
                {
                    self.model_filter = None;
                }
                self.history = Some(history);
                self.folder_titles = titles;
                self.load_error = None;
                self.updated_at = Some((self.host.wall_time)(Utc::now()));
            }
            Err(error) => {
                self.load_error = Some(error.to_string());
                // Never show another period's numbers under this period's label.
                if self.history.as_ref().is_some_and(|history| history.period != period) {
                    self.history = None;
                }
            }
        }
        self.pending_sync = false;
        self.is_loading = false;
        self.hovered_bucket = None;
        self.refresh_summary();
        cx.notify();
    }

    fn refresh_summary(&mut self) {
        self.summary = self.history.as_ref().map(|history| history.summary(self.model_filter.as_ref()));
    }

    // MARK: - Choices

    /// Shows `period`: a read without a sync (or one taking over the sync still running).
    pub fn select_period(&mut self, period: UsagePeriod, cx: &mut Context<Self>) {
        if period == self.period && self.history.is_some() {
            return;
        }
        self.period = period;
        self.load(false, cx);
    }

    pub fn select_metric(&mut self, metric: UsageMetric, cx: &mut Context<Self>) {
        if metric != self.metric {
            self.metric = metric;
            cx.notify();
        }
    }

    /// Limits the board to `model`; the model already filtered to, or `None`, shows every one.
    pub fn select_model(&mut self, model: Option<UsageModelKey>, cx: &mut Context<Self>) {
        self.model_filter = if model == self.model_filter { None } else { model };
        self.hovered_bucket = None;
        self.refresh_summary();
        cx.notify();
    }

    fn set_hovered(&mut self, index: usize, hovered: bool, cx: &mut Context<Self>) {
        let next = match (hovered, self.hovered_bucket) {
            (true, _) => Some(index),
            // Leaving the bar that is still the hovered one; a neighbour may have taken over.
            (false, Some(current)) if current == index => None,
            (false, current) => current,
        };
        if next != self.hovered_bucket {
            self.hovered_bucket = next;
            cx.notify();
        }
    }

    // MARK: - Keyboard

    /// Runs the board shortcut for `keystroke` while the keyboard is on the board. Returns
    /// whether it was one.
    fn handle_keystroke(
        &mut self,
        keystroke: &Keystroke,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.focus.contains_focused(window, cx) {
            return false;
        }
        let Some(action) = key_action(keystroke) else { return false };
        self.perform(action, cx);
        true
    }

    /// Runs one keyboard action.
    pub fn perform(&mut self, action: KeyAction, cx: &mut Context<Self>) {
        match action {
            KeyAction::Dismiss => cx.emit(StatisticsEvent::Close),
            KeyAction::Metric(metric) => self.select_metric(metric, cx),
            KeyAction::Period(period) => self.select_period(period, cx),
        }
    }

    // MARK: - Reading (for the shell and tests)

    pub fn period(&self) -> UsagePeriod {
        self.period
    }

    pub fn metric(&self) -> UsageMetric {
        self.metric
    }

    pub fn model_filter(&self) -> Option<&UsageModelKey> {
        self.model_filter.as_ref()
    }

    /// The history shown, once read.
    pub fn history(&self) -> Option<&UsageHistory> {
        self.history.as_ref()
    }

    /// The shown history under the model filter.
    pub fn summary(&self) -> Option<&UsageSummary> {
        self.summary.as_ref()
    }

    pub fn is_loading(&self) -> bool {
        self.is_loading
    }

    /// Why the last read failed.
    pub fn load_error(&self) -> Option<&str> {
        self.load_error.as_deref()
    }

    /// The project lines as shown.
    pub fn project_rows(&self) -> Vec<BreakdownRow> {
        self.summary
            .as_ref()
            .map(|summary| state::project_rows(summary, self.metric, &self.folder_titles))
            .unwrap_or_default()
    }
}

// MARK: - Rendering

impl Render for StatisticsBoard {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.soprano_theme().clone();
        let z = |value: f32| theme.z(value);
        let column = div()
            .flex()
            .flex_col()
            .w_full()
            .max_w(z(CONTENT_MAX_WIDTH))
            .gap(z(16.))
            .when(self.is_loading && self.history.is_some(), |column| column.opacity(0.6))
            .children(self.render_sections(&theme, cx));
        div()
            .id("statistics")
            .key_context("Statistics")
            .track_focus(&self.focus)
            .flex()
            .flex_col()
            .size_full()
            .bg(theme.canvas)
            .text_color(theme.foreground)
            .font_family(fonts::UI_FONT_FAMILY)
            .text_size(z(size::UI))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, _, window, cx| window.focus(&this.focus, cx)),
            )
            .child(self.render_header(&theme, cx))
            .child(
                div().flex().flex_col().flex_1().min_h_0().child(
                    ScrollList::new("statistics-scroll", &self.scroll).child(
                        div()
                            .flex()
                            .flex_row()
                            .flex_none()
                            .justify_center()
                            .w_full()
                            .px(z(24.))
                            .pt(z(8.))
                            .pb(z(32.))
                            .child(column),
                    ),
                ),
            )
    }
}

impl StatisticsBoard {
    /// The page's title and what it shows, the period control, Refresh, and Esc / close.
    fn render_header(&self, theme: &SopranoTheme, cx: &mut Context<Self>) -> impl IntoElement {
        let board = cx.entity().downgrade();
        let selected = UsagePeriod::ALL.iter().position(|period| *period == self.period).unwrap_or(0);
        let subtitle = if self.is_loading && self.pending_sync {
            "Updating from omp…"
        } else {
            "omp's tokens and estimated cost"
        };
        div()
            .flex()
            .flex_row()
            .flex_none()
            .items_center()
            .gap(theme.z(10.))
            .h(theme.z(HEADER_HEIGHT))
            .pl(theme.z(16.))
            .pr(theme.z(12.))
            .child(
                div()
                    .flex_none()
                    .text_size(theme.z(size::DIALOG_TITLE))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child("Statistics"),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(theme.z(size::ROW))
                    .text_color(theme.muted)
                    .child(subtitle),
            )
            .child(
                SegmentedControl::new("statistics-period", UsagePeriod::ALL.map(UsagePeriod::title))
                    .selected(selected)
                    .well()
                    .on_select(move |index, _, cx| {
                        let Some(period) = UsagePeriod::ALL.get(index).copied() else { return };
                        board.update(cx, |board, cx| board.select_period(period, cx)).ok();
                    }),
            )
            .child(
                IconButton::new("statistics-refresh", IconName::RefreshCw)
                    .disabled(self.is_loading)
                    .tooltip("Refresh")
                    .on_click(cx.listener(|this, _, _, cx| this.load(true, cx))),
            )
            .child(Keycaps::new(["esc"]).small())
            .child(
                IconButton::new("statistics-close", IconName::X)
                    .tooltip("Return to the workspace (Esc)")
                    .on_click(cx.listener(|_, _, _, cx| cx.emit(StatisticsEvent::Close))),
            )
    }

    fn render_sections(&self, theme: &SopranoTheme, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let (Some(history), Some(summary)) = (&self.history, &self.summary) else {
            return vec![match (&self.load_error, self.is_loading) {
                (Some(error), false) => {
                    self.render_notice("statistics-retry-read", error.clone(), theme, cx).into_any_element()
                }
                _ => div().py(theme.z(8.)).text_color(theme.muted).child("Loading usage…").into_any_element(),
            }];
        };
        let mut sections = vec![self.render_toolbar(theme, cx).into_any_element()];
        if let Some(error) = &self.load_error {
            sections.push(
                self.render_notice("statistics-retry-read", error.clone(), theme, cx).into_any_element(),
            );
        }
        if let Some(error) = &history.sync_error {
            let message = format!("Couldn’t update from omp, showing what was recorded before: {error}");
            sections.push(self.render_notice("statistics-retry-sync", message, theme, cx).into_any_element());
        }
        sections.push(self.render_tiles(summary, theme).into_any_element());
        sections.push(self.render_chart_card(history, summary, theme, cx).into_any_element());
        sections.push(self.render_models(summary, theme, cx).into_any_element());
        sections.push(
            div()
                .flex()
                .flex_row()
                .flex_wrap()
                .items_start()
                .gap(theme.z(12.))
                .child(self.render_projects(summary, theme))
                .child(self.render_agents(summary, theme))
                .into_any_element(),
        );
        sections.push(
            div()
                .text_size(theme.z(size::META))
                .text_color(theme.muted)
                .child(state::footnote(self.updated_at))
                .into_any_element(),
        );
        sections
    }

    /// Cost / Tokens, and the model the board is limited to.
    fn render_toolbar(&self, theme: &SopranoTheme, cx: &mut Context<Self>) -> impl IntoElement {
        let board = cx.entity().downgrade();
        let selected = if self.metric == UsageMetric::Cost { 0 } else { 1 };
        div()
            .flex()
            .flex_row()
            .items_center()
            .justify_between()
            .gap(theme.z(8.))
            .child(
                SegmentedControl::new("statistics-metric", ["Cost", "Tokens"])
                    .selected(selected)
                    .well()
                    .on_select(move |index, _, cx| {
                        let metric = if index == 0 { UsageMetric::Cost } else { UsageMetric::Tokens };
                        board.update(cx, |board, cx| board.select_metric(metric, cx)).ok();
                    }),
            )
            .when_some(self.model_filter.clone(), |toolbar, filter| {
                toolbar.child(
                    Button::new("statistics-clear-filter", filter.model)
                        .size(ButtonSize::Xs)
                        .icon(IconName::X)
                        .tooltip("Show every model")
                        .on_click(cx.listener(|this, _, _, cx| this.select_model(None, cx))),
                )
            })
    }

    fn render_tiles(&self, summary: &UsageSummary, theme: &SopranoTheme) -> impl IntoElement {
        let tiles = state::tiles(&summary.totals, self.metric);
        div().flex().flex_row().gap(theme.z(12.)).children(tiles.into_iter().map(|tile| {
            let Tile { title, value, detail } = tile;
            Card::new()
                .flex_1()
                .min_w_0()
                .p(theme.z(14.))
                .gap(theme.z(4.))
                .child(
                    div()
                        .truncate()
                        .text_size(theme.z(size::META))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(theme.muted)
                        .child(title),
                )
                .child(
                    div().truncate().text_size(theme.z(22.)).font_weight(FontWeight::SEMIBOLD).child(value),
                )
                .child(div().truncate().text_size(theme.z(size::META)).text_color(theme.muted).child(detail))
        }))
    }

    /// A failed read or sync, with Retry (which syncs again).
    fn render_notice(
        &self,
        id: &'static str,
        message: String,
        theme: &SopranoTheme,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        Card::new().p(theme.z(16.)).child(
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(theme.z(12.))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_size(theme.z(size::ROW))
                        .text_color(theme.failed)
                        .child(message),
                )
                .child(
                    Button::new(id, "Retry")
                        .size(ButtonSize::Xs)
                        .on_click(cx.listener(|this, _, _, cx| this.load(true, cx))),
                ),
        )
    }

    /// The stacked chart under its title line (the hovered bar, else the period's total), over
    /// the legend.
    fn render_chart_card(
        &self,
        history: &UsageHistory,
        summary: &UsageSummary,
        theme: &SopranoTheme,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let wall_time = self.host.wall_time.clone();
        let readout = state::readout(
            history.period,
            history.bucket_unit,
            summary,
            self.metric,
            self.model_filter.as_ref(),
            self.hovered_bucket,
            |date| wall_time(date),
        );
        let title = if self.metric == UsageMetric::Cost { "Cost over time" } else { "Tokens over time" };
        let legend = STACK_ORDER.iter().rev().map(|part| {
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(theme.z(6.))
                .child(div().flex_none().size(theme.z(8.)).rounded(theme.z(2.)).bg(part_color(*part, theme)))
                .child(part.title())
        });
        Card::new()
            .p(theme.z(16.))
            .gap(theme.z(12.))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .gap(theme.z(12.))
                    .child(div().flex_none().font_weight(FontWeight::SEMIBOLD).child(title))
                    .child(
                        div()
                            .id("statistics-readout")
                            .debug_selector(|| "statistics-readout".into())
                            .min_w_0()
                            .truncate()
                            .text_size(theme.z(size::META))
                            .text_color(theme.muted)
                            .child(readout),
                    ),
            )
            .child(self.render_chart(history, summary, theme, cx))
            .child(
                div()
                    .flex()
                    .flex_row()
                    .flex_wrap()
                    .gap_x(theme.z(14.))
                    .gap_y(theme.z(4.))
                    .text_size(theme.z(size::META))
                    .text_color(theme.muted)
                    .children(legend),
            )
    }

    /// One slot per bucket with its bar stacked from cache read up to output, over three
    /// gridlines, with value labels on the left and a few bucket labels below.
    fn render_chart(
        &self,
        history: &UsageHistory,
        summary: &UsageSummary,
        theme: &SopranoTheme,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let metric = self.metric;
        let count = summary.buckets.len();
        let peak = summary.buckets.iter().map(|bucket| bucket.totals.value(metric)).fold(0.0, f64::max);
        let scale = chart::nice_ceiling(peak);
        let plot_height = CHART_HEIGHT - CHART_TOP_INSET - CHART_LABEL_HEIGHT - CHART_LABEL_GAP;
        let grid = theme.border.opacity(0.6);
        let label = || {
            div()
                .absolute()
                .flex()
                .flex_row()
                .items_center()
                .whitespace_nowrap()
                .font_family(fonts::MONO_FONT_FAMILY)
                .text_size(theme.z(size::BADGE))
                .text_color(theme.muted)
        };

        let values = (0..3u8).map(|step| {
            let fraction = f32::from(step) / 2.0;
            let line = CHART_TOP_INSET + plot_height * (1.0 - fraction);
            label()
                .top(theme.z(line - 8.0))
                .left_0()
                .w(theme.z(CHART_AXIS_WIDTH - 10.0))
                .h(theme.z(16.))
                .justify_end()
                .child(format::axis_value(scale * f64::from(fraction), metric))
        });
        let gridlines = [
            div().absolute().left_0().right_0().bottom_0(),
            div().absolute().left_0().right_0().top(relative(0.5)),
            div().absolute().left_0().right_0().top_0(),
        ]
        .map(|line| line.h(px(1.)).bg(grid));
        let slots = summary.buckets.iter().enumerate().map(|(index, bucket)| {
            let total = bucket.totals.value(metric);
            let height = (total / scale).clamp(0.0, 1.0) as f32;
            let segments = STACK_ORDER.iter().rev().filter_map(|part| {
                let value = bucket.totals.part_value(*part, metric);
                (value > 0.0).then(|| {
                    div()
                        .flex_none()
                        .w_full()
                        .h(relative((value / total) as f32))
                        .bg(part_color(*part, theme))
                })
            });
            div()
                .id(("statistics-bar", index))
                .flex()
                .flex_row()
                .flex_1()
                .min_w_0()
                .h_full()
                .items_end()
                .justify_center()
                .rounded(theme.z(4.))
                .when(self.hovered_bucket == Some(index), |slot| slot.bg(theme.hover))
                .on_hover(
                    cx.listener(move |this, hovered: &bool, _, cx| this.set_hovered(index, *hovered, cx)),
                )
                .when(total > 0.0, |slot| {
                    slot.child(
                        div()
                            .flex()
                            .flex_col()
                            .flex_none()
                            .w(relative(0.66))
                            .max_w(theme.z(BAR_MAXIMUM_WIDTH))
                            .min_w(px(2.))
                            .h(relative(height))
                            .min_h(px(1.))
                            .rounded(theme.z(2.))
                            .overflow_hidden()
                            .children(segments),
                    )
                })
        });
        let wall_time = &self.host.wall_time;
        let labels = chart::labeled_buckets(count).into_iter().map(|index| {
            let text = format::axis_label(wall_time(summary.buckets[index].start), history.bucket_unit);
            let label = label().top_0().h_full();
            if count > CENTERED_LABEL_LIMIT && index + 1 == count {
                // The last of many narrow bars: end at the plot's edge rather than past it.
                label.right_0().justify_end().child(text)
            } else {
                label
                    .left(relative((index as f32 + 0.5) / count as f32))
                    .ml(-theme.z(CHART_LABEL_WIDTH / 2.0))
                    .w(theme.z(CHART_LABEL_WIDTH))
                    .justify_center()
                    .child(text)
            }
        });

        div()
            .id("statistics-chart")
            .debug_selector(|| "statistics-chart".into())
            .flex()
            .flex_row()
            .flex_none()
            .w_full()
            .h(theme.z(CHART_HEIGHT))
            .child(div().relative().flex_none().w(theme.z(CHART_AXIS_WIDTH)).h_full().children(values))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_w_0()
                    .pt(theme.z(CHART_TOP_INSET))
                    .child(
                        div()
                            .relative()
                            .flex()
                            .flex_row()
                            .flex_none()
                            .w_full()
                            .h(theme.z(plot_height))
                            .children(gridlines)
                            .children(slots),
                    )
                    .child(
                        div()
                            .relative()
                            .flex_none()
                            .w_full()
                            .h(theme.z(CHART_LABEL_HEIGHT))
                            .mt(theme.z(CHART_LABEL_GAP))
                            .children(labels),
                    ),
            )
    }

    /// Every model with its share, requests, cache hit rate and value; a click filters the
    /// board to it, a second one shows every model again.
    fn render_models(
        &self,
        summary: &UsageSummary,
        theme: &SopranoTheme,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let models = state::model_rows(summary, self.metric);
        let count = models.len();
        let hover = theme.hover;
        let rows: Vec<AnyElement> = models
            .into_iter()
            .enumerate()
            .map(|(index, model)| {
                let selected = self.model_filter.as_ref() == Some(&model.key);
                let tint = theme.project_colors[index % theme.project_colors.len()];
                let hint = if selected {
                    "Show every model".to_owned()
                } else {
                    format!("Show only {}", model.key.model)
                };
                let key = model.key.clone();
                breakdown_row(
                    ("statistics-model", index),
                    &model.row,
                    RowStyle {
                        dot: true,
                        tint,
                        subtitle: Some(model.key.provider.clone()),
                        bar_width: 96.0,
                        columns: vec![(model.requests, 72.0), (model.cached, 84.0)],
                        value_muted: model.unpriced,
                    },
                    theme,
                )
                .cursor_pointer()
                .when(selected, |row| row.bg(theme.selected))
                .when(!selected, |row| row.hover(move |style| style.bg(hover)))
                .tooltip(tooltip(hint))
                .on_click(cx.listener(move |this, _, _, cx| this.select_model(Some(key.clone()), cx)))
                .into_any_element()
            })
            .collect();
        breakdown_card("Models", count, (count > 0).then_some("Click a model to filter"), rows, theme)
    }

    fn render_projects(&self, summary: &UsageSummary, theme: &SopranoTheme) -> impl IntoElement {
        let rows = state::project_rows(summary, self.metric, &self.folder_titles);
        plain_breakdown_card("Projects", "statistics-project", rows, theme)
    }

    fn render_agents(&self, summary: &UsageSummary, theme: &SopranoTheme) -> impl IntoElement {
        let rows = state::agent_rows(summary, self.metric);
        plain_breakdown_card("Agents", "statistics-agent", rows, theme)
    }
}

/// The color of a token kind in the bars and the legend.
fn part_color(part: UsagePart, theme: &SopranoTheme) -> Hsla {
    match part {
        // Magenta: the accent and the working blue are one hue in most themes.
        UsagePart::Input => theme.ansi[5],
        UsagePart::Output => theme.accent,
        UsagePart::CacheRead => theme.done,
        UsagePart::CacheWrite => theme.approval,
    }
}

/// How one breakdown line is drawn beyond its title, share and value.
struct RowStyle {
    /// A color dot before the title (the models).
    dot: bool,
    /// The dot's and the share bar's color.
    tint: Hsla,
    /// Muted, after the title (a model's provider).
    subtitle: Option<String>,
    bar_width: f32,
    /// Muted, right-aligned columns between the share and the value: text and width.
    columns: Vec<(String, f32)>,
    value_muted: bool,
}

/// One breakdown line: optional color dot, title and muted subtitle, a share bar with its
/// percentage, extra columns, and the value on the right.
fn breakdown_row(
    id: impl Into<ElementId>,
    row: &BreakdownRow,
    style: RowStyle,
    theme: &SopranoTheme,
) -> Stateful<gpui::Div> {
    let column = |text: String, width: f32, color: Hsla| {
        div()
            .flex()
            .flex_row()
            .flex_none()
            .justify_end()
            .w(theme.z(width))
            .whitespace_nowrap()
            .font_family(fonts::MONO_FONT_FAMILY)
            .text_size(theme.z(size::SMALL))
            .text_color(color)
            .child(text)
    };
    let fill = (row.share > 0.0).then(|| {
        div().h_full().w(relative(row.share as f32)).min_w(px(2.)).rounded(theme.z(2.)).bg(style.tint)
    });
    div()
        .id(id)
        .flex()
        .flex_row()
        .flex_none()
        .items_center()
        .gap(theme.z(8.))
        .h(theme.z(ROW_HEIGHT))
        .px(theme.z(8.))
        .rounded(theme.z(6.))
        .when(style.dot, |line| line.child(div().flex_none().size(theme.z(8.)).rounded_full().bg(style.tint)))
        .child(
            div()
                .min_w_0()
                .truncate()
                .text_size(theme.z(size::ROW))
                .font_weight(FontWeight::MEDIUM)
                .child(row.title.clone()),
        )
        .when_some(style.subtitle, |line, subtitle| {
            // The subtitle gives way long before the title does.
            let mut subtitle = div()
                .min_w_0()
                .truncate()
                .text_size(theme.z(size::META))
                .text_color(theme.muted)
                .child(subtitle);
            subtitle.style().flex_shrink = Some(100.0);
            line.child(subtitle)
        })
        .child(div().flex_1())
        .child(
            div()
                .flex_none()
                .w(theme.z(style.bar_width))
                .h(theme.z(4.))
                .rounded(theme.z(2.))
                .bg(theme.foreground.opacity(0.08))
                .children(fill),
        )
        .child(column(format::percent(row.share), 44.0, theme.muted))
        .children(style.columns.into_iter().map(|(text, width)| column(text, width, theme.muted)))
        .child(
            column(row.value.clone(), 76.0, if style.value_muted { theme.muted } else { theme.foreground })
                .font_weight(FontWeight::MEDIUM),
        )
}

/// A card of plain lines (projects, agent kinds): share bars in the accent color.
fn plain_breakdown_card(
    title: &'static str,
    id: &'static str,
    rows: Vec<BreakdownRow>,
    theme: &SopranoTheme,
) -> Card {
    let count = rows.len();
    let rows = rows
        .iter()
        .enumerate()
        .map(|(index, row)| {
            let style = RowStyle {
                dot: false,
                tint: theme.accent,
                subtitle: None,
                bar_width: 56.0,
                columns: Vec::new(),
                value_muted: false,
            };
            breakdown_row((id, index), row, style, theme).into_any_element()
        })
        .collect();
    breakdown_card(title, count, None, rows, theme).flex_1().min_w(theme.z(300.))
}

/// A breakdown under its "Title N" line. The card pads 8 px so a line's hover fill reaches
/// near its edge; the title and the empty note add 8 px more, lining up with the lines' text.
fn breakdown_card(
    title: &'static str,
    count: usize,
    hint: Option<&'static str>,
    rows: Vec<AnyElement>,
    theme: &SopranoTheme,
) -> Card {
    let header = div()
        .flex()
        .flex_row()
        .flex_none()
        .items_center()
        .gap(theme.z(6.))
        .px(theme.z(8.))
        .pt(theme.z(6.))
        .pb(theme.z(8.))
        .child(div().font_weight(FontWeight::SEMIBOLD).child(title))
        .when(count > 0, |header| {
            header.child(div().text_color(theme.dim).child(SharedString::from(count.to_string())))
        })
        .when_some(hint, |header, hint| {
            header.child(
                div().pl(theme.z(4.)).text_size(theme.z(size::META)).text_color(theme.muted).child(hint),
            )
        });
    let card = Card::new().p(theme.z(8.)).child(header);
    if rows.is_empty() {
        card.child(
            div()
                .px(theme.z(8.))
                .pb(theme.z(8.))
                .text_size(theme.z(size::ROW))
                .text_color(theme.muted)
                .child("No requests in this period."),
        )
    } else {
        card.children(rows)
    }
}

#[cfg(test)]
#[path = "view_tests.rs"]
mod tests;
