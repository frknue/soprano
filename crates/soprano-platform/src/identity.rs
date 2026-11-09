//! Release and development builds run side by side without sharing state: each has its own
//! app id, and every per-app location is derived from it.

/// Identity of the running app build.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppIdentity {
    /// Reverse-DNS id: `com.soprano.app` (release) or `com.soprano.dev` (development).
    pub id: String,
    /// Human name shown in window titles and notifications: `Soprano` or `Soprano Dev`.
    pub name: String,
}

impl AppIdentity {
    pub const RELEASE_ID: &'static str = "com.soprano.app";
    pub const DEV_ID: &'static str = "com.soprano.dev";

    pub fn release() -> Self {
        Self { id: Self::RELEASE_ID.into(), name: "Soprano".into() }
    }

    pub fn dev() -> Self {
        Self { id: Self::DEV_ID.into(), name: "Soprano Dev".into() }
    }

    /// The identity of this process: `SOPRANO_APP_ID` wins (packaging sets it for the dev
    /// bundle, tests for isolation); otherwise release builds are `com.soprano.app` and debug
    /// builds `com.soprano.dev`, so a `cargo run` never touches the installed app's state.
    pub fn current() -> Self {
        Self::resolve(std::env::var("SOPRANO_APP_ID").ok().as_deref(), cfg!(debug_assertions))
    }

    pub fn resolve(env_id: Option<&str>, debug_build: bool) -> Self {
        match env_id.map(str::trim).filter(|s| !s.is_empty()) {
            Some(Self::RELEASE_ID) => Self::release(),
            Some(Self::DEV_ID) => Self::dev(),
            Some(other) => Self { id: other.into(), name: "Soprano".into() },
            None if debug_build => Self::dev(),
            None => Self::release(),
        }
    }

    pub fn is_dev(&self) -> bool {
        self.id != Self::RELEASE_ID
    }
}

/// The marketing version of this build: the workspace `version` in `Cargo.toml`, which is the
/// single source of truth (packaging writes it into `Info.plist`).
pub fn app_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_explicit_app_id_wins_over_the_build_profile() {
        assert_eq!(AppIdentity::resolve(Some("com.soprano.app"), true), AppIdentity::release());
        assert_eq!(AppIdentity::resolve(Some("com.soprano.dev"), false), AppIdentity::dev());
    }

    #[test]
    fn debug_builds_default_to_the_dev_identity_so_they_never_share_release_state() {
        assert_eq!(AppIdentity::resolve(None, true), AppIdentity::dev());
        assert_eq!(AppIdentity::resolve(Some("  "), false), AppIdentity::release());
    }
}
