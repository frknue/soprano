//! Bundled fonts and Herdr's type scale (HERDR-UI.md §3). UI text is Geist, terminals and code
//! are JetBrains Mono (Medium for normal text), with Symbols Nerd Font for icon glyphs.

use std::borrow::Cow;
use std::path::{Path, PathBuf};

use anyhow::{Context as _, Result};
use gpui::{App, FontWeight};

/// UI font: every label, row and control.
pub const UI_FONT_FAMILY: &str = "Geist";
/// Terminal and code font (ligatures off; normal text is Medium).
pub const TERMINAL_FONT_FAMILY: &str = "JetBrains Mono";
/// Monospace UI accents (tabular numbers, jump hints).
pub const MONO_FONT_FAMILY: &str = "Geist Mono";
/// Nerd Font icons for terminals, under any font.
pub const SYMBOLS_FONT_FAMILY: &str = "Symbols Nerd Font";

/// Terminal normal-text weight (JetBrains Mono Medium); bold is 700.
pub const TERMINAL_WEIGHT: FontWeight = FontWeight::MEDIUM;
/// Terminal cell height factor over ascent + descent.
pub const TERMINAL_LINE_HEIGHT: f32 = 1.15;

/// Font sizes in designed px (multiply by zoom with `SopranoTheme::z`).
pub mod size {
    /// UI default (rem): rows, tree rows, sidebar footer.
    pub const UI: f32 = 13.0;
    /// Brand title.
    pub const BRAND: f32 = 13.5;
    /// Sidebar section headers ("Spaces", "Agents") and git tails.
    pub const SECTION: f32 = 11.5;
    /// Group headers, ages, shortcut hints, "Esc" chips, keycaps.
    pub const SMALL: f32 = 11.0;
    /// Avatar letter and the "Needs you" pill.
    pub const BADGE: f32 = 10.5;
    /// Sub-agent rows.
    pub const SUBAGENT: f32 = 12.5;
    /// Empty states, panel toggles, pane header, status pills, dialog buttons.
    pub const META: f32 = 12.0;
    /// Tab labels, menu and palette rows, inputs.
    pub const ROW: f32 = 12.8;
    /// Status bar.
    pub const STATUS_BAR: f32 = 11.8;
    /// Panel titles ("Files", "Changes") and toast titles.
    pub const PANEL_TITLE: f32 = 13.0;
    /// Dialog and picker titles.
    pub const DIALOG_TITLE: f32 = 15.0;
    /// Terminal text.
    pub const TERMINAL: f32 = 14.0;
    /// Diff view (terminal font).
    pub const DIFF: f32 = 11.0;
    /// File preview (terminal font).
    pub const FILE_PREVIEW: f32 = 12.0;
}

/// Every `.ttf` in `dir`, sorted by name.
pub fn font_files(dir: &Path) -> Result<Vec<PathBuf>> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(dir)
        .with_context(|| format!("reading fonts from {}", dir.display()))?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.extension().is_some_and(|ext| ext.eq_ignore_ascii_case("ttf")))
        .collect();
    files.sort();
    Ok(files)
}

/// Registers every font in `<resources>/fonts` (Geist, Geist Mono, JetBrains Mono, Symbols
/// Nerd Font) with GPUI's text system.
pub fn register_fonts(cx: &mut App) -> Result<()> {
    let resources = soprano_platform::paths::resources_dir().context("no resources folder")?;
    register_fonts_from(&resources.join("fonts"), cx)
}

/// Registers every `.ttf` in `dir`.
pub fn register_fonts_from(dir: &Path, cx: &mut App) -> Result<()> {
    let fonts = font_files(dir)?
        .into_iter()
        .map(|path| {
            std::fs::read(&path).map(Cow::Owned).with_context(|| format!("reading {}", path.display()))
        })
        .collect::<Result<Vec<_>>>()?;
    cx.text_system().add_fonts(fonts)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_bundled_fonts_are_all_found() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../resources/fonts");
        let names: Vec<String> = font_files(&dir)
            .expect("fonts folder")
            .iter()
            .map(|p| p.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_owned())
            .collect();
        for expected in [
            "Geist.ttf",
            "GeistMono-Variable.ttf",
            "GeistMono-Italic-Variable.ttf",
            "JetBrainsMono-Variable.ttf",
            "JetBrainsMono-Italic-Variable.ttf",
            "SymbolsNerdFont-Regular.ttf",
        ] {
            assert!(names.iter().any(|n| n == expected), "missing {expected}");
        }
        assert!(names.iter().all(|n| n.ends_with(".ttf")));
    }
}
