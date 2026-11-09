//! The About page: version, runtime, the settings file, links, third-party notices and the
//! quick reference.

use std::path::PathBuf;

use soprano_types::{KeyBinding, KeyBindingConfig};

pub const VERSION_DESCRIPTION: &str = "Current version of the application.";
pub const RUNTIME_DESCRIPTION: &str = "AI agent orchestration platform.";
pub const RUNTIME: &str = "Rust + GPUI + libghostty";

/// The quick reference's actions, in order; missing ones (unbound) are skipped.
pub const QUICK_REFERENCE_IDS: [&str; 9] = [
    "command-palette",
    "find-window",
    "open-settings",
    "new-window",
    "new-terminal",
    "split-horizontal",
    "split-vertical",
    "toggle-sidebar",
    "save-session",
];

pub fn quick_reference_bindings(config: &KeyBindingConfig) -> Vec<&KeyBinding> {
    QUICK_REFERENCE_IDS.iter().filter_map(|id| config.bindings.iter().find(|b| b.id == *id)).collect()
}

/// A link row: title, what it is, the URL it opens.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AboutLink {
    pub title: &'static str,
    pub description: &'static str,
    pub url: &'static str,
}

pub const LINKS: [AboutLink; 3] = [
    AboutLink {
        title: "Source code",
        description: "Soprano on GitHub.",
        url: "https://github.com/frknue/soprano",
    },
    AboutLink {
        title: "Release notes",
        description: "What changed in each version.",
        url: "https://github.com/frknue/soprano/releases",
    },
    AboutLink {
        title: "Report an issue",
        description: "Bugs and feature requests.",
        url: "https://github.com/frknue/soprano/issues",
    },
];

/// A component Soprano ships, its license, and the license text in the app's resources.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LicenseNotice {
    pub component: &'static str,
    pub license: &'static str,
    /// Relative to the resources directory; `None` when the text is not bundled.
    pub file: Option<&'static str>,
}

pub const LICENSE_NOTICES: [LicenseNotice; 10] = [
    LicenseNotice { component: "Soprano", license: "MIT License", file: Some("LICENSE") },
    LicenseNotice { component: "libghostty", license: "MIT License", file: Some("LICENSE-ghostty") },
    LicenseNotice {
        component: "GPUI and gpui-component",
        license: "Apache License 2.0",
        file: Some("licenses/LICENSE-gpui"),
    },
    LicenseNotice {
        component: "Herdr (interface design)",
        license: "Apache License 2.0",
        file: Some("licenses/LICENSE-herdr-app"),
    },
    LicenseNotice {
        component: "Lucide icons",
        license: "ISC License",
        file: Some("icons/LICENSE-Lucide.txt"),
    },
    LicenseNotice {
        component: "LobeHub icons",
        license: "MIT License",
        file: Some("icons/LICENSE-LobeHub.txt"),
    },
    LicenseNotice {
        component: "Geist and Geist Mono",
        license: "SIL Open Font License 1.1",
        file: Some("fonts/OFL.txt"),
    },
    LicenseNotice {
        component: "JetBrains Mono",
        license: "SIL Open Font License 1.1",
        file: Some("fonts/OFL-JetBrainsMono.txt"),
    },
    LicenseNotice {
        component: "Symbols Nerd Font",
        license: "MIT License",
        file: Some("fonts/LICENSE-SymbolsNerdFont.txt"),
    },
    LicenseNotice {
        component: "Third-party icon notices",
        license: "Various",
        file: Some("icons/LICENSES.md"),
    },
];

impl LicenseNotice {
    /// The bundled license text, when the resources directory has it.
    pub fn path(&self) -> Option<PathBuf> {
        let path = soprano_platform::paths::resources_dir()?.join(self.file?);
        path.is_file().then_some(path)
    }
}

/// "Show in Finder" on macOS (the Swift wording); the file manager's name elsewhere.
pub fn reveal_label() -> &'static str {
    if cfg!(target_os = "macos") { "Show in Finder" } else { soprano_platform::system::reveal_label() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use soprano_config::{DefaultKeybindings, KeyPlatform};

    #[test]
    fn the_quick_reference_lists_the_swift_actions_in_order() {
        let config = DefaultKeybindings::config_for(KeyPlatform::Mac);
        let ids: Vec<&str> = quick_reference_bindings(&config).iter().map(|b| b.id.as_str()).collect();
        assert_eq!(ids, QUICK_REFERENCE_IDS);
    }

    #[test]
    fn an_unbound_action_drops_out_of_the_quick_reference() {
        let mut config = DefaultKeybindings::config_for(KeyPlatform::Mac);
        config.bindings.retain(|b| b.id != "save-session");
        assert_eq!(quick_reference_bindings(&config).len(), QUICK_REFERENCE_IDS.len() - 1);
    }

    #[test]
    fn every_bundled_notice_names_a_file_the_repository_ships() {
        let repo = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        for notice in LICENSE_NOTICES {
            let Some(file) = notice.file else { continue };
            // LICENSE-ghostty is staged from Support/Licenses by the packaging script.
            let source = match file {
                "LICENSE" => repo.join("LICENSE"),
                "LICENSE-ghostty" => repo.join("Support/Licenses/LICENSE-ghostty"),
                other => repo.join("resources").join(other),
            };
            assert!(source.is_file(), "{}", source.display());
        }
    }
}
