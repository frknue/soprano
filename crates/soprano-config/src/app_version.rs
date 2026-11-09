//! The application's marketing version (`Utilities/AppVersion.swift`).
//!
//! The workspace `version` in `Cargo.toml` is the single source of truth (packaging writes it
//! into `Info.plist`), so cutting a release only has to touch `Cargo.toml` and `CHANGELOG.md`.

pub struct AppVersion;

impl AppVersion {
    /// Reported when no usable version is available.
    pub const UNBUNDLED: &'static str = "dev";

    /// Marketing version of the running app.
    pub fn current() -> String {
        Self::resolve(Some(soprano_platform::identity::app_version()))
    }

    /// `version`, or [`Self::UNBUNDLED`] when it is missing or blank.
    pub fn resolve(version: Option<&str>) -> String {
        match version {
            Some(version) if !version.trim().is_empty() => version.to_owned(),
            _ => Self::UNBUNDLED.to_owned(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_marketing_version_comes_from_the_declared_version() {
        assert_eq!(AppVersion::resolve(Some("1.4.2")), "1.4.2");
    }

    #[test]
    fn a_launch_without_a_version_reports_the_development_version() {
        assert_eq!(AppVersion::resolve(None), AppVersion::UNBUNDLED);
    }

    #[test]
    fn a_blank_version_reports_the_development_version() {
        assert_eq!(AppVersion::resolve(Some("")), AppVersion::UNBUNDLED);
        assert_eq!(AppVersion::resolve(Some("   ")), AppVersion::UNBUNDLED);
    }

    #[test]
    fn the_about_tab_reports_whatever_version_the_build_declares() {
        assert_eq!(AppVersion::current(), env!("CARGO_PKG_VERSION"));
    }

    // MARK: - ChangelogVersionTests

    fn changelog_lines() -> Vec<String> {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../CHANGELOG.md");
        let text = std::fs::read_to_string(path).expect("CHANGELOG.md at the repository root");
        text.lines().map(str::to_owned).collect()
    }

    fn version_triple(version: &str) -> Vec<u64> {
        version.split('.').map(|part| part.parse().expect("numeric version component")).collect()
    }

    /// Guards the release workflow in `AGENTS.md`: the newest released heading in
    /// `CHANGELOG.md` may not run ahead of the version the build declares.
    #[test]
    fn the_newest_released_changelog_heading_is_not_ahead_of_the_declared_version() {
        let lines = changelog_lines();
        let heading = lines
            .iter()
            .find(|line| line.starts_with("## [") && line.as_str() != "## [Unreleased]")
            .expect("a released heading");
        let released: String = heading["## [".len()..].chars().take_while(|&c| c != ']').collect();
        assert!(
            version_triple(&released) <= version_triple(env!("CARGO_PKG_VERSION")),
            "CHANGELOG.md's newest release {released} is ahead of the workspace version {}",
            env!("CARGO_PKG_VERSION")
        );
    }

    #[test]
    fn the_changelog_keeps_an_unreleased_section_for_finished_but_unshipped_work() {
        assert!(changelog_lines().iter().any(|line| line == "## [Unreleased]"));
    }
}
