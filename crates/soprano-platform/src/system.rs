//! Handing files and URLs to the OS: default apps, the file manager, the trash.

use std::path::Path;

use anyhow::{Context, Result};

/// Opens `target` (a path or URL) with its default application.
pub fn open_default(target: &str) -> Result<()> {
    open::that_detached(target).with_context(|| format!("cannot open {target}"))
}

/// Opens `path` with the named application (macOS app name, or an executable elsewhere).
pub fn open_with(path: &Path, app: &str) -> Result<()> {
    open::with_detached(path, app).with_context(|| format!("cannot open {} with {app}", path.display()))
}

/// Shows `path` selected in the platform file manager (Finder, Explorer, or the folder in
/// the default file manager on Linux, which has no portable "select" request).
pub fn reveal_in_file_manager(path: &Path) -> Result<()> {
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open").arg("-R").arg(path).spawn()?;
        Ok(())
    }
    #[cfg(windows)]
    {
        std::process::Command::new("explorer").arg(format!("/select,{}", path.display())).spawn()?;
        Ok(())
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let folder = if path.is_dir() { path } else { path.parent().unwrap_or(path) };
        open_default(&folder.to_string_lossy())
    }
}

/// The label for [`reveal_in_file_manager`] in menus: "Reveal in Finder" on macOS.
pub fn reveal_label() -> &'static str {
    if cfg!(target_os = "macos") {
        "Reveal in Finder"
    } else if cfg!(windows) {
        "Show in Explorer"
    } else {
        "Show in File Manager"
    }
}

/// Moves `paths` to the OS trash (recycle bin).
pub fn move_to_trash(paths: &[&Path]) -> Result<()> {
    trash::delete_all(paths).context("cannot move to the trash")
}
