//! Dev builds (`visual-snapshot`): a window as a PNG, for visual QA where screen capture is
//! unavailable. A frame is drawn for the snapshot and GPUI renders its scene offscreen, so it
//! shows the window as it is now even while the screen does not show it (a window behind
//! others gets no frames of its own).

use std::path::Path;

use anyhow::Context as _;
use gpui::{App, Window};

/// Draws `window` and writes it to `path` (absolute; its folder must exist). None of the
/// window's views may be in an update.
pub fn write_png(window: &mut Window, path: &Path, cx: &mut App) -> anyhow::Result<()> {
    anyhow::ensure!(path.is_absolute(), "The snapshot path must be absolute: {}", path.display());
    window.draw(cx).clear(cx);
    let image = window.render_to_image().context("Cannot render the window")?;
    image
        .save_with_format(path, image::ImageFormat::Png)
        .with_context(|| format!("Cannot write {}", path.display()))
}
