//! Visual QA for the examples' `--snapshot` mode: draw a window that need not be on screen,
//! drive it with clicks, scrolls and keys as real input, and write what it shows as a PNG.
//!
//! Behind the `snapshot` feature, for dev-dependencies only: it needs gpui's test support,
//! and the platform's renderer needs its own (`gpui_platform/test-support`, which the
//! examples enable on macOS).

use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::Context as _;
use gpui::{
    App, AsyncWindowContext, Keystroke, MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, Pixels,
    PlatformInput, Point, ScrollDelta, ScrollEvent, Window, point, px,
};

use crate::theme::AppearancePreference;

/// What every example's command line takes:
/// `--snapshot /abs/dir [--size WIDTHxHEIGHT] [--appearance dark|light]`, plus the example's
/// own `--flag value` pairs in `rest`.
pub struct Args {
    /// Where the PNGs go; `None` runs the example as a window to use.
    pub directory: Option<PathBuf>,
    pub width: f32,
    pub height: f32,
    pub appearance: AppearancePreference,
    pub rest: Vec<(String, String)>,
}

impl Args {
    /// Reads the process arguments; `width`×`height` is the window without `--size`.
    pub fn parse(width: f32, height: f32) -> Self {
        let mut parsed = Self {
            directory: None,
            width,
            height,
            appearance: AppearancePreference::System,
            rest: Vec::new(),
        };
        let mut args = std::env::args().skip(1);
        while let Some(flag) = args.next() {
            let value = args.next().unwrap_or_else(|| panic!("{flag} needs a value"));
            match flag.as_str() {
                "--snapshot" => {
                    let directory = PathBuf::from(value);
                    assert!(directory.is_absolute(), "--snapshot needs an absolute folder");
                    parsed.directory = Some(directory);
                }
                "--size" => {
                    let (width, height) = value.split_once('x').expect("--size WIDTHxHEIGHT");
                    parsed.width = width.parse().expect("--size width");
                    parsed.height = height.parse().expect("--size height");
                }
                "--appearance" => {
                    parsed.appearance = match value.as_str() {
                        "dark" => AppearancePreference::Dark,
                        "light" => AppearancePreference::Light,
                        _ => panic!("--appearance dark|light"),
                    }
                }
                _ => parsed.rest.push((flag, value)),
            }
        }
        parsed
    }
}

/// Lets pending work land (background reads, a fade), then draws the window: one that is not
/// on screen gets no frames of its own. Twice, because the first draw measures what the second
/// one places.
pub async fn redraw(cx: &mut AsyncWindowContext) {
    for _ in 0..2 {
        cx.background_executor().timer(Duration::from_millis(100)).await;
        let _ = cx.update(|window, cx| window.draw(cx).clear(cx));
    }
}

/// Ends a snapshot run: quits the app, or says why a frame could not be written and exits 1.
pub fn finish(result: anyhow::Result<()>, cx: &mut AsyncWindowContext) {
    if let Err(error) = result {
        eprintln!("{error:#}");
        std::process::exit(1);
    }
    let _ = cx.update(|_, cx| cx.quit());
}

/// A left click at `position`, the pointer moved there first.
pub fn click(position: Point<Pixels>, window: &mut Window, cx: &mut App) {
    let modifiers = window.modifiers();
    let button = MouseButton::Left;
    window.dispatch_event(
        PlatformInput::MouseMove(MouseMoveEvent { position, pressed_button: None, modifiers }),
        cx,
    );
    window.dispatch_event(
        PlatformInput::MouseDown(MouseDownEvent {
            button,
            position,
            modifiers,
            click_count: 1,
            first_mouse: false,
        }),
        cx,
    );
    window.dispatch_event(
        PlatformInput::MouseUp(MouseUpEvent { button, position, modifiers, click_count: 1 }),
        cx,
    );
}

/// Scrolls what is under `position` by `distance` toward its end, as a wheel turned down does.
pub fn scroll(position: Point<Pixels>, distance: Pixels, window: &mut Window, cx: &mut App) {
    let modifiers = window.modifiers();
    window.dispatch_event(
        PlatformInput::MouseMove(MouseMoveEvent { position, pressed_button: None, modifiers }),
        cx,
    );
    window.dispatch_event(
        PlatformInput::Scroll(ScrollEvent {
            position,
            delta: ScrollDelta::Pixels(point(px(0.), -distance)),
            modifiers,
            ..ScrollEvent::default()
        }),
        cx,
    );
}

/// Presses each of the space-separated keystrokes (`"j j enter"`, `"shift-tab"`).
pub fn press(keystrokes: &str, window: &mut Window, cx: &mut App) {
    for source in keystrokes.split_whitespace() {
        let keystroke = Keystroke::parse_with_os(source, cx.platform_info().os)
            .unwrap_or_else(|error| panic!("not a keystroke: {source} ({error})"));
        window.dispatch_keystroke(keystroke, cx);
    }
}

/// The window's last drawn frame as RGBA bytes, to tell whether two frames differ.
pub fn pixels(window: &Window) -> anyhow::Result<Vec<u8>> {
    Ok(window.render_to_image().context("Cannot render the window")?.into_raw())
}

/// Writes the window's last drawn frame to `path` and prints the path.
pub fn write_png(window: &Window, path: &Path) -> anyhow::Result<()> {
    let image = window.render_to_image().context("Cannot render the window")?;
    image.save(path).with_context(|| format!("Cannot write {}", path.display()))?;
    println!("{}", path.display());
    Ok(())
}
