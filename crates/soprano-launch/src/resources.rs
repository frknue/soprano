//! Packaged resources a launch refers to (`App/SopranoResources.swift` plus the lookups
//! `TerminalConfig` made through `SopranoResources.bundle`).
//!
//! Layout under the resources folder ([`soprano_platform::paths::resources_dir`]):
//!
//! - `Soprano_Soprano.bundle/` — hook plugins and the zsh fallback startup files
//! - `bin/` — Soprano's CLI dir (`soprano`, the `omp` launcher), put on panes' PATH
//! - `ghostty/shell-integration/` — Ghostty's shell-integration scripts
//! - `terminfo/` — the `xterm-ghostty` terminfo entry

use std::path::{Path, PathBuf};

/// The name of the folder that held the Swift package's resources; kept so packaged
/// layouts stay the same.
pub const BUNDLE_NAME: &str = "Soprano_Soprano.bundle";

/// Resolved resource locations. Every lookup checks the file exists, like
/// `Bundle.url(forResource:)`: a missing resource leaves its integration out.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Resources {
    root: Option<PathBuf>,
    ghostty: Option<PathBuf>,
}

impl Resources {
    /// The running app's resources ([`soprano_platform::paths::resources_dir`]).
    pub fn locate() -> Self {
        Self::at(soprano_platform::paths::resources_dir())
    }

    /// Resources rooted at `root`. Ghostty's resources are `<root>/ghostty` when it holds
    /// `shell-integration`; a source checkout (`<repo>/resources`) falls back to the
    /// submodule's `<repo>/ghostty/src`.
    pub fn at(root: Option<PathBuf>) -> Self {
        let ghostty = root.as_deref().and_then(|root| {
            [root.join("ghostty"), soprano_platform::paths::normalize(&root.join("../ghostty/src"))]
                .into_iter()
                .find(|dir| dir.join("shell-integration").is_dir())
        });
        Self { root, ghostty }
    }

    /// No resources at all: every integration that needs a file is left out.
    pub fn none() -> Self {
        Self::default()
    }

    /// The same resources without Ghostty's shell integration (no `GHOSTTY_RESOURCES_DIR`,
    /// no injected prompt marks).
    pub fn without_ghostty(mut self) -> Self {
        self.ghostty = None;
        self
    }

    pub fn root(&self) -> Option<&Path> {
        self.root.as_deref()
    }

    /// `<root>/Soprano_Soprano.bundle` when it exists.
    pub fn bundle_dir(&self) -> Option<PathBuf> {
        packaged_bundle_dir(self.root.as_deref(), |p| p.exists())
    }

    /// A file or folder inside the bundle, when it exists.
    pub fn bundle_resource(&self, name: &str) -> Option<PathBuf> {
        self.bundle_dir().map(|dir| dir.join(name)).filter(|p| p.exists())
    }

    /// OpenCode 1.x server plugin, loaded from the pane's inline config.
    pub fn opencode_plugin(&self) -> Option<PathBuf> {
        self.bundle_resource("SopranoOpenCodePlugin.js")
    }

    /// OpenCode 2 terminal-UI plugin folder.
    pub fn opencode_tui_plugin(&self) -> Option<PathBuf> {
        self.bundle_resource("SopranoOpenCode")
    }

    /// omp's launch-scoped extension.
    pub fn omp_extension(&self) -> Option<PathBuf> {
        self.bundle_resource("SopranoOmpExtension.js")
    }

    /// `ZDOTDIR` for the zsh a pane falls back to after its agent exits.
    pub fn zsh_startup_dir(&self) -> Option<PathBuf> {
        self.bundle_resource("SopranoZsh")
    }

    /// `<root>/AgentHooks`, the user-installable hook templates.
    pub fn agent_hooks_dir(&self) -> Option<PathBuf> {
        self.root.as_ref().map(|r| r.join("AgentHooks")).filter(|p| p.is_dir())
    }

    /// `<root>/bin` when it holds the `soprano` CLI: the folder panes get on PATH. Windows
    /// packages ship it as `bin\soprano.cmd` (or `.exe`), which need no execute bit.
    pub fn cli_dir(&self) -> Option<PathBuf> {
        let dir = self.root.as_ref()?.join("bin");
        let found = is_executable(&dir.join("soprano"))
            || ["soprano.exe", "soprano.cmd"].iter().any(|name| dir.join(name).is_file());
        found.then_some(dir)
    }

    /// `GHOSTTY_RESOURCES_DIR`: the folder holding `shell-integration/`.
    pub fn ghostty_resources_dir(&self) -> Option<&Path> {
        self.ghostty.as_deref()
    }

    /// `<root>/terminfo` when bundled; panes then get `TERM=xterm-ghostty`.
    pub fn terminfo_dir(&self) -> Option<PathBuf> {
        self.root.as_ref().map(|r| r.join("terminfo")).filter(|p| p.is_dir())
    }
}

/// `<resources>/Soprano_Soprano.bundle` when it exists (`SopranoResources.packagedBundleURL`).
pub fn packaged_bundle_dir(resources: Option<&Path>, exists: impl Fn(&Path) -> bool) -> Option<PathBuf> {
    let bundle = resources?.join(BUNDLE_NAME);
    exists(&bundle).then_some(bundle)
}

pub(crate) fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata().map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0).unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packaged_resources_resolve_inside_the_apps_resources_directory() {
        let resources = Path::new("/Applications/Soprano.app/Contents/Resources");
        let bundle = packaged_bundle_dir(Some(resources), |_| true);
        assert_eq!(
            bundle.as_deref(),
            Some(Path::new("/Applications/Soprano.app/Contents/Resources/Soprano_Soprano.bundle"))
        );
    }

    #[test]
    fn packaged_resource_bundle_is_unavailable_without_app_resources() {
        assert_eq!(packaged_bundle_dir(None, |_| true), None);
        assert_eq!(packaged_bundle_dir(Some(Path::new("/nowhere")), |p| p.exists()), None);
    }

    #[test]
    fn a_windows_package_puts_its_soprano_cmd_folder_on_path() {
        let root = tempfile::tempdir().expect("tempdir");
        let resources = Resources::at(Some(root.path().to_path_buf()));
        assert_eq!(resources.cli_dir(), None);
        std::fs::create_dir_all(root.path().join("bin")).expect("mkdir");
        std::fs::write(root.path().join("bin/soprano.cmd"), "@echo off\r\n").expect("write");
        assert_eq!(resources.cli_dir(), Some(root.path().join("bin")));
    }

    #[test]
    fn a_source_checkout_finds_the_bundle_and_ghosttys_shell_integration() {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../resources");
        let resources = Resources::at(Some(soprano_platform::paths::normalize(&root)));
        assert!(resources.omp_extension().is_some());
        assert!(resources.opencode_plugin().is_some());
        assert!(resources.opencode_tui_plugin().is_some());
        assert!(resources.zsh_startup_dir().is_some());
        let ghostty = resources.ghostty_resources_dir().expect("ghostty shell integration");
        assert!(ghostty.join("shell-integration/zsh").is_dir());
    }
}
