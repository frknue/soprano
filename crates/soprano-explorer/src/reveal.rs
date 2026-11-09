//! "Reveal in Finder" for several items: macOS selects them all in one Finder window, as
//! Swift's `activateFileViewerSelecting`. Elsewhere each item is shown in turn (Explorer's
//! `/select` takes one path; Linux file managers open the folder, once per folder).

use std::path::PathBuf;

pub(crate) fn reveal(paths: &[PathBuf]) -> anyhow::Result<()> {
    if paths.is_empty() {
        return Ok(());
    }
    platform::reveal(paths)
}

#[cfg(target_os = "macos")]
mod platform {
    use std::path::PathBuf;

    use objc2::rc::Retained;
    use objc2_app_kit::NSWorkspace;
    use objc2_foundation::{NSArray, NSString, NSURL};

    pub(super) fn reveal(paths: &[PathBuf]) -> anyhow::Result<()> {
        let urls: Vec<Retained<NSURL>> = paths
            .iter()
            .map(|path| NSURL::fileURLWithPath(&NSString::from_str(&path.to_string_lossy())))
            .collect();
        NSWorkspace::sharedWorkspace().activateFileViewerSelectingURLs(&NSArray::from_retained_slice(&urls));
        Ok(())
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use std::path::PathBuf;

    pub(super) fn reveal(paths: &[PathBuf]) -> anyhow::Result<()> {
        let mut shown: Vec<PathBuf> = Vec::new();
        for path in paths {
            // Linux shows the containing folder; one window per folder is enough.
            let key = if cfg!(windows) || path.is_dir() {
                path.clone()
            } else {
                path.parent().map(PathBuf::from).unwrap_or_else(|| path.clone())
            };
            if shown.contains(&key) {
                continue;
            }
            shown.push(key);
            soprano_platform::system::reveal_in_file_manager(path)?;
        }
        Ok(())
    }
}
