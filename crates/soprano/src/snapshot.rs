//! Dev builds (`visual-snapshot`): the main window's last rendered frame as a PNG, for visual QA
//! where screen capture is unavailable. GPUI re-renders the frame's scene offscreen, so it works
//! while the window is in the background or unfocused.

use std::path::Path;

use anyhow::Context as _;
use gpui::Window;

/// Renders `window` and writes it to `path` (absolute; its folder must exist).
pub fn write_png(window: &Window, path: &Path) -> anyhow::Result<()> {
    anyhow::ensure!(path.is_absolute(), "The snapshot path must be absolute: {}", path.display());
    let image = window.render_to_image().context("Cannot render the main window")?;
    image
        .save_with_format(path, image::ImageFormat::Png)
        .with_context(|| format!("Cannot write {}", path.display()))
}
