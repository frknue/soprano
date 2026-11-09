//! The app's `AssetSource`: files under Soprano's `resources/` folder (UI glyphs in
//! `icons/ui/`, agent and program icons in `icons/`), falling back to gpui-component's
//! embedded icons for the paths its own widgets ask for.

use std::borrow::Cow;
use std::path::{Component, Path, PathBuf};

use anyhow::Result;
use gpui::{AssetSource, SharedString};

pub struct SopranoAssets {
    root: Option<PathBuf>,
    fallback: gpui_kit_assets::Assets,
}

impl SopranoAssets {
    /// Serves `root` (a `resources/` folder).
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: Some(root.into()), fallback: gpui_kit_assets::Assets::new("") }
    }

    /// Serves `soprano_platform::paths::resources_dir()`; without one, only gpui-component's
    /// embedded icons.
    pub fn from_resources_dir() -> Self {
        Self { root: soprano_platform::paths::resources_dir(), fallback: gpui_kit_assets::Assets::new("") }
    }

    pub fn root(&self) -> Option<&Path> {
        self.root.as_deref()
    }

    /// `path` under the root, refusing anything that climbs out of it.
    fn resolve(&self, path: &str) -> Option<PathBuf> {
        let root = self.root.as_ref()?;
        let relative = Path::new(path);
        if relative.components().any(|c| !matches!(c, Component::Normal(_))) {
            return None;
        }
        Some(root.join(relative))
    }
}

impl AssetSource for SopranoAssets {
    fn load(&self, path: &str) -> Result<Option<Cow<'static, [u8]>>> {
        if let Some(file) = self.resolve(path).filter(|file| file.is_file()) {
            return Ok(Some(Cow::Owned(std::fs::read(file)?)));
        }
        self.fallback.load(path)
    }

    fn list(&self, path: &str) -> Result<Vec<SharedString>> {
        let mut entries = self.fallback.list(path).unwrap_or_default();
        if let Some(dir) = self.resolve(path).filter(|dir| dir.is_dir()) {
            for entry in std::fs::read_dir(dir)?.flatten() {
                if let Some(name) = entry.file_name().to_str() {
                    let joined = if path.is_empty() || path.ends_with('/') {
                        format!("{path}{name}")
                    } else {
                        format!("{path}/{name}")
                    };
                    entries.push(joined.into());
                }
            }
        }
        entries.sort();
        entries.dedup();
        Ok(entries)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assets() -> SopranoAssets {
        SopranoAssets::new(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../resources"))
    }

    #[test]
    fn ui_glyphs_and_program_icons_load_from_the_resources_folder() {
        let assets = assets();
        assert!(assets.load("icons/ui/plus.svg").expect("load").is_some());
        assert!(assets.load("icons/claude.svg").expect("load").is_some());
    }

    #[test]
    fn gpui_components_own_icons_fall_back_to_its_embedded_set() {
        assert!(assets().load("icons/chevron-down.svg").expect("load").is_some());
    }

    #[test]
    fn paths_that_climb_out_of_the_resources_folder_are_refused() {
        assert!(assets().resolve("../Cargo.toml").is_none());
        assert!(assets().resolve("/etc/hosts").is_none());
    }

    #[test]
    fn listing_merges_the_resources_folder() {
        let entries = assets().list("icons/ui/").expect("list");
        assert!(entries.iter().any(|e| e.as_ref() == "icons/ui/spinner.svg"));
    }
}
