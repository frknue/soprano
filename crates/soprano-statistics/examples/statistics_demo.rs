//! The statistics board inside a mock of the app's frame (sidebar, top row, status bar), over
//! canned omp usage: about four months of working hours on three projects (plus one folder no
//! project claims) with Opus as the main model, Opus subagents, a Sonnet advisor, GPT-6.1 Sol
//! and an unpriced OpenRouter model. `cargo run -p soprano-statistics --example statistics_demo`.
//!
//! `-- --snapshot /abs/dir [--size 1280x820] [--appearance dark|light] [--theme ID]
//! [--usage none]` writes the board's states (every period, Tokens, a model filter) as PNGs
//! into the folder and quits, for visual QA without looking at the screen. Never runs omp or
//! reads its database.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use chrono::{Datelike as _, Duration, Local, TimeZone as _, Timelike as _, Utc, Weekday};
use gpui::{
    App, AppContext as _, AsyncWindowContext, Bounds, Context, Entity, Focusable as _, IntoElement,
    ParentElement, Render, Styled, Window, WindowBounds, WindowOptions, div, px, size,
};
use gpui_component::Root;
use soprano_agents::usage::{
    UsageDate, UsageGranularity, UsageGroup, UsageModelKey, UsageStatisticsError, UsageStatisticsService,
    UsageTotals, folder_name,
};
use soprano_statistics::{StatisticsBoard, StatisticsEvent, StatisticsHost};
use soprano_ui::snapshot::{self, Args};
use soprano_ui::{ActiveSopranoTheme, SopranoAssets};

const HOME: &str = "/Users/demo";
const TEMPORARY: &str = "/var/demo-tmp";
const PROJECTS: [&str; 3] = ["/Users/demo/code/app", "/Users/demo/code/soprano", "/Users/demo/code/site"];
const DAYS: i64 = 120;

struct Model {
    provider: &'static str,
    model: &'static str,
    agent: &'static str,
    /// Requests per busy hour at full intensity.
    rate: f64,
    /// USD per million input, output, cache-read and cache-write tokens; `None` = unpriced.
    prices: Option<[f64; 4]>,
}

const MODELS: [Model; 5] = [
    Model {
        provider: "anthropic",
        model: "claude-opus-5-5",
        agent: "main",
        rate: 22.,
        prices: Some([5., 25., 0.5, 6.25]),
    },
    Model {
        provider: "anthropic",
        model: "claude-opus-5-5",
        agent: "subagent",
        rate: 16.,
        prices: Some([5., 25., 0.5, 6.25]),
    },
    Model {
        provider: "anthropic",
        model: "claude-sonnet-5-5",
        agent: "advisor",
        rate: 4.,
        prices: Some([3., 15., 0.3, 3.75]),
    },
    Model {
        provider: "openai-codex",
        model: "gpt-6.1-sol",
        agent: "main",
        rate: 7.,
        prices: Some([1.25, 10., 0.125, 0.]),
    },
    Model { provider: "openrouter", model: "qwen/qwen3-coder", agent: "main", rate: 2., prices: None },
];

/// SplitMix64 → [0, 1).
struct SeededRandom(u64);

impl SeededRandom {
    fn new(seed: u64) -> Self {
        Self(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15))
    }

    fn next(&mut self) -> f64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^= z >> 31;
        (z >> 11) as f64 / (1u64 << 53) as f64
    }
}

/// Canned usage, deterministic for a given `now`; `empty` is a computer omp never ran on.
struct FixtureUsage {
    now: UsageDate,
    empty: bool,
}

impl FixtureUsage {
    fn folders() -> Vec<String> {
        let mut folders: Vec<String> = PROJECTS
            .iter()
            .map(|project| folder_name::encode(Path::new(project), Path::new(HOME), Path::new(TEMPORARY)))
            .collect();
        folders.push("-Downloads-experiments".to_owned());
        folders
    }

    /// One record per busy hour and model, hours 9–22 local time over the last [`DAYS`] days.
    fn records(&self) -> Vec<UsageGroup> {
        if self.empty {
            return Vec::new();
        }
        let folders = Self::folders();
        let local = self.now.with_timezone(&Local);
        let current_hour = self.now
            - Duration::seconds(i64::from(local.minute() * 60 + local.second()))
            - sub_second(self.now);
        let hours = DAYS * 24;
        let mut records = Vec::new();
        for hours_ago in 0..hours {
            let start = current_hour - Duration::hours(hours_ago);
            let local = start.with_timezone(&Local);
            if !(9..=22).contains(&local.hour()) {
                continue;
            }
            let mut random = SeededRandom::new((start.timestamp() / 3600) as u64);
            if random.next() <= 0.3 {
                continue;
            }
            let weekend = matches!(local.weekday(), Weekday::Sat | Weekday::Sun);
            let recency = 0.35 + 0.65 * (1.0 - hours_ago as f64 / hours as f64);
            let intensity = (0.25 + 0.75 * random.next()) * recency * if weekend { 0.35 } else { 1.0 };
            let folder = match random.next() {
                pick if pick < 0.5 => &folders[0],
                pick if pick < 0.8 => &folders[1],
                pick if pick < 0.92 => &folders[2],
                _ => &folders[3],
            };
            for model in &MODELS {
                let requests = (model.rate * intensity * (0.5 + random.next())).round() as u64;
                if requests == 0 {
                    continue;
                }
                let input = requests * (300.0 + 1200.0 * random.next()) as u64;
                let output = requests * (1500.0 + 2500.0 * random.next()) as u64;
                let cache_read = requests * (120_000.0 + 140_000.0 * random.next()) as u64;
                let cache_write = requests * (4000.0 + 8000.0 * random.next()) as u64;
                let mut totals = UsageTotals {
                    requests,
                    failed_requests: u64::from(random.next() < 0.06),
                    input_tokens: input,
                    output_tokens: output,
                    cache_read_tokens: cache_read,
                    cache_write_tokens: cache_write,
                    ..UsageTotals::default()
                };
                match model.prices {
                    Some([input_price, output_price, read_price, write_price]) => {
                        let per_million = |tokens: u64, price: f64| tokens as f64 * price / 1e6;
                        totals.input_cost = per_million(input, input_price);
                        totals.output_cost = per_million(output, output_price);
                        totals.cache_read_cost = per_million(cache_read, read_price);
                        totals.cache_write_cost = per_million(cache_write, write_price);
                        totals.cached_prompt_cost =
                            totals.input_cost + totals.cache_read_cost + totals.cache_write_cost;
                        totals.uncached_prompt_cost =
                            per_million(input + cache_read + cache_write, input_price);
                    }
                    None => totals.unpriced_requests = requests,
                }
                records.push(UsageGroup {
                    start,
                    provider: model.provider.to_owned(),
                    model: model.model.to_owned(),
                    agent: model.agent.to_owned(),
                    folder: folder.clone(),
                    totals,
                });
            }
        }
        records
    }
}

fn sub_second(date: UsageDate) -> Duration {
    Duration::nanoseconds(i64::from(date.timestamp_subsec_nanos()))
}

/// The start of `date`'s local day.
fn day_start(date: UsageDate) -> UsageDate {
    let midnight = date.with_timezone(&Local).date_naive().and_time(chrono::NaiveTime::MIN);
    Local.from_local_datetime(&midnight).earliest().map_or(date, |start| start.to_utc())
}

impl UsageStatisticsService for FixtureUsage {
    fn sync(&self) -> Result<(), UsageStatisticsError> {
        Ok(())
    }

    fn groups(
        &self,
        since: Option<UsageDate>,
        granularity: UsageGranularity,
    ) -> Result<Vec<UsageGroup>, UsageStatisticsError> {
        let mut merged: Vec<UsageGroup> = Vec::new();
        let mut index: HashMap<(UsageDate, &str, &str, &str, String), usize> = HashMap::new();
        for record in self.records() {
            if since.is_some_and(|since| record.start < since) {
                continue;
            }
            let start = match granularity {
                UsageGranularity::Hour => record.start,
                UsageGranularity::Day => day_start(record.start),
            };
            let model = MODELS
                .iter()
                .find(|model| model.model == record.model && model.agent == record.agent)
                .expect("a record of a fixture model");
            let key = (start, model.provider, model.model, model.agent, record.folder.clone());
            match index.get(&key) {
                Some(position) => merged[*position].totals.add(&record.totals),
                None => {
                    index.insert(key, merged.len());
                    merged.push(UsageGroup { start, ..record });
                }
            }
        }
        Ok(merged)
    }
}

/// The board where the app shows it: beside the sidebar, under the page's top row, over the
/// status bar.
struct DemoFrame {
    board: Entity<StatisticsBoard>,
}

impl Render for DemoFrame {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        cx.soprano_theme().apply_to_window(window);
        let theme = cx.soprano_theme().clone();
        let bar = || div().flex_none().bg(theme.chrome).border_color(theme.border);
        div()
            .flex()
            .flex_row()
            .size_full()
            .bg(theme.canvas)
            .child(bar().w(theme.z(220.)).h_full().border_r_1())
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .child(bar().h(theme.z(42.)).border_b_1())
                    .child(div().flex_1().min_h_0().child(self.board.clone()))
                    .child(bar().h(theme.z(28.)).border_t_1()),
            )
    }
}

/// Writes the opening state, Tokens, every other period, a model filter and the scrolled end.
async fn write_snapshots(
    directory: PathBuf,
    board: Entity<StatisticsBoard>,
    size: (f32, f32),
    cx: &mut AsyncWindowContext,
) -> anyhow::Result<()> {
    std::fs::create_dir_all(&directory)?;
    let mut number = 0;
    let mut shot = async |keys: &str, name: &str, cx: &mut AsyncWindowContext| -> anyhow::Result<()> {
        cx.update(|window, cx| snapshot::press(keys, window, cx))?;
        // The read runs on a background thread.
        cx.background_executor().timer(std::time::Duration::from_millis(300)).await;
        snapshot::redraw(cx).await;
        number += 1;
        let path = directory.join(format!("{number:02}-{name}.png"));
        cx.update(|window, _| snapshot::write_png(window, &path))?
    };
    shot("", "cost-7d", cx).await?;
    shot("t", "tokens-7d", cx).await?;
    shot("c 1", "cost-24h", cx).await?;
    shot("3", "cost-30d", cx).await?;
    shot("4", "cost-90d", cx).await?;
    shot("5", "cost-all", cx).await?;
    board.update(cx, |board, cx| {
        let model = UsageModelKey { provider: "openai-codex".into(), model: "gpt-6.1-sol".into() };
        board.select_model(Some(model), cx);
    });
    shot("3", "filtered-30d", cx).await?;
    let (width, height) = size;
    cx.update(|window, cx| {
        snapshot::scroll(gpui::point(px(width * 0.6), px(height * 0.3)), px(2000.), window, cx);
    })?;
    shot("", "filtered-30d-end", cx).await?;
    Ok(())
}

fn main() {
    let args = Args::parse(1280., 820.);
    let mut theme = "folio".to_owned();
    let mut empty = false;
    for (flag, value) in &args.rest {
        match (flag.as_str(), value.as_str()) {
            ("--theme", id) => theme = id.to_owned(),
            ("--usage", "none") => empty = true,
            ("--usage", "demo") => empty = false,
            _ => panic!("unknown option {flag} {value}"),
        }
    }

    gpui_platform::application().with_assets(SopranoAssets::from_resources_dir()).run(move |cx: &mut App| {
        soprano_ui::init(cx, &theme, args.appearance);
        let bounds = Bounds::centered(None, size(px(args.width), px(args.height)), cx);
        let snapshot = args.directory.clone();
        let interactive = snapshot.is_none();
        let window_size = (args.width, args.height);
        cx.open_window(
            WindowOptions { window_bounds: Some(WindowBounds::Windowed(bounds)), ..WindowOptions::default() },
            |window, cx| {
                let usage: Arc<dyn UsageStatisticsService> =
                    Arc::new(FixtureUsage { now: Utc::now(), empty });
                let host =
                    StatisticsHost::service(usage).home(HOME).temporary_directory(TEMPORARY).folders(|_| {
                        PROJECTS
                            .iter()
                            .map(|project| {
                                let path = PathBuf::from(project);
                                let title = path
                                    .file_name()
                                    .map_or_else(String::new, |name| name.to_string_lossy().into_owned());
                                (path, title)
                            })
                            .collect()
                    });
                let board = cx.new(|cx| StatisticsBoard::new(host, window, cx));
                cx.subscribe(&board, |_, event: &StatisticsEvent, cx| {
                    println!("{event:?}");
                    match event {
                        StatisticsEvent::Close => cx.quit(),
                    }
                })
                .detach();
                let focus = board.focus_handle(cx);
                window.focus(&focus, cx);
                if let Some(directory) = snapshot {
                    let board = board.clone();
                    window
                        .spawn(cx, async move |cx| {
                            let result = write_snapshots(directory, board, window_size, cx).await;
                            snapshot::finish(result, cx);
                        })
                        .detach();
                }
                let frame = cx.new(|_| DemoFrame { board });
                cx.new(|cx| Root::new(frame, window, cx))
            },
        )
        .expect("the demo window opens");
        if interactive {
            cx.activate(true);
        }
    });
}
