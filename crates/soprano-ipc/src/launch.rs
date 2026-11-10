//! What `main` does with an invocation no subcommand claimed. The app binary doubles as
//! `$SOPRANO_BIN`, so a bare `soprano`, a typo, or a non-Markdown path typed in a pane must never
//! start a second full app that restores the same session and writes the same stores.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LaunchDispatch {
    StartApp,
    Help,
    UsageError,
}

pub const USAGE: &str = "Usage:
  soprano <file.md> [--new]            open a Markdown reader in this pane
  soprano markdown|md [--new] <file>
  soprano browser [--pane pane-id] <command> ...   (soprano browser --help)
  soprano navigate-pane left|right|up|down
  soprano navigation-passthrough enable|disable <source>
  soprano agent-event <state> [options]
  soprano ssh <machine>                continue this terminal on a machine (or soprano <machine>)
  soprano machine add|list|remove ...    (soprano machine --help)

Subcommands drive the Soprano instance that owns the calling terminal.
Start the app itself from Finder, Spotlight, or `open -a Soprano`.";

impl LaunchDispatch {
    /// Decides for an invocation that no subcommand handled. `runs_owning_app`: this binary is the
    /// one of the app that owns the calling terminal (see [`runs_owning_app`]).
    pub fn decide(
        arguments: &[String],
        environment: &HashMap<String, String>,
        runs_owning_app: bool,
    ) -> Self {
        let first = arguments.get(1).map(String::as_str);
        if let Some(first) = first
            && ["--help", "-h", "help"].contains(&first)
        {
            return Self::Help;
        }
        // Inside a Soprano terminal a call of that app's own binary is a CLI call: the app is
        // already running. Another build (`target/debug/soprano`) starts as it would outside.
        if runs_owning_app && environment.get("SOPRANO_APP_PID").is_some_and(|pid| !pid.is_empty()) {
            return Self::UsageError;
        }
        let Some(first) = first else { return Self::StartApp };
        // AppKit, LaunchServices and Xcode pass single-dash arguments
        // (`-NSDocumentRevisionsDebugMode YES`, `-psn_0_12345`).
        if first.starts_with('-') && !first.starts_with("--") {
            return Self::StartApp;
        }
        Self::UsageError
    }
}

/// Whether `executable_path` is the binary of the app owning the calling terminal, which exports
/// it as `SOPRANO_BIN` (panes call it through the `soprano` symlink). Without a recorded binary a
/// call from a pane counts as the owning app's.
pub fn runs_owning_app(executable_path: Option<&Path>, environment: &HashMap<String, String>) -> bool {
    let Some(owner) = environment.get("SOPRANO_BIN").filter(|owner| !owner.is_empty()) else { return true };
    let Some(executable_path) = executable_path else { return true };
    resolved(executable_path) == resolved(Path::new(owner))
}

fn resolved(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| soprano_platform::paths::normalize(path))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|v| v.to_string()).collect()
    }

    fn env(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    fn pane() -> HashMap<String, String> {
        env(&[("SOPRANO_APP_PID", "4242")])
    }

    fn decide(values: &[&str], environment: &HashMap<String, String>) -> LaunchDispatch {
        LaunchDispatch::decide(&args(values), environment, true)
    }

    #[test]
    fn a_bare_launch_and_appkit_or_launch_services_arguments_still_start_the_app() {
        let empty = HashMap::new();
        assert_eq!(decide(&["Soprano"], &empty), LaunchDispatch::StartApp);
        assert_eq!(
            decide(&["Soprano", "-NSDocumentRevisionsDebugMode", "YES"], &empty),
            LaunchDispatch::StartApp
        );
        assert_eq!(decide(&["Soprano", "-psn_0_12345"], &empty), LaunchDispatch::StartApp);
    }

    #[test]
    fn unknown_subcommands_and_paths_print_usage_instead_of_starting_a_second_app() {
        let empty = HashMap::new();
        assert_eq!(decide(&["soprano", "notes.txt"], &empty), LaunchDispatch::UsageError);
        assert_eq!(decide(&["soprano", "brwoser", "open"], &empty), LaunchDispatch::UsageError);
        assert_eq!(decide(&["soprano", "--version"], &empty), LaunchDispatch::UsageError);
        assert_eq!(decide(&["soprano", "--help"], &empty), LaunchDispatch::Help);
        assert_eq!(decide(&["soprano", "-h"], &pane()), LaunchDispatch::Help);
    }

    #[test]
    fn any_unclaimed_call_of_the_owning_app_inside_a_soprano_terminal_never_starts_it() {
        assert_eq!(decide(&["soprano"], &pane()), LaunchDispatch::UsageError);
        assert_eq!(
            decide(&["soprano", "-NSDocumentRevisionsDebugMode", "YES"], &pane()),
            LaunchDispatch::UsageError
        );
        assert_eq!(decide(&["soprano"], &env(&[("SOPRANO_APP_PID", "")])), LaunchDispatch::StartApp);
    }

    #[test]
    fn another_build_started_from_a_soprano_terminal_starts_like_outside_one() {
        assert_eq!(LaunchDispatch::decide(&args(&["Soprano"]), &pane(), false), LaunchDispatch::StartApp);
        assert_eq!(
            LaunchDispatch::decide(&args(&["Soprano", "notes.txt"]), &pane(), false),
            LaunchDispatch::UsageError
        );
    }

    #[cfg(unix)]
    #[test]
    fn the_owning_app_is_recognized_through_the_panes_symlinked_soprano_command() {
        let root = tempfile::tempdir().expect("temp dir");
        let mac_os = root.path().join("Soprano.app/Contents/MacOS");
        let bin = root.path().join("Soprano.app/Contents/Resources/bin");
        std::fs::create_dir_all(&mac_os).expect("mkdir");
        std::fs::create_dir_all(&bin).expect("mkdir");
        let binary = mac_os.join("Soprano");
        std::fs::write(&binary, b"").expect("write");
        std::os::unix::fs::symlink("../../MacOS/Soprano", bin.join("soprano")).expect("symlink");
        let pane_env = env(&[("SOPRANO_APP_PID", "4242"), ("SOPRANO_BIN", binary.to_str().expect("utf8"))]);

        assert!(runs_owning_app(Some(&bin.join("soprano")), &pane_env));
        assert!(!runs_owning_app(Some(Path::new("/tmp/elsewhere/.build/debug/Soprano")), &pane_env));
        // Without a recorded binary, a call from a pane is taken to be the owning app's.
        assert!(runs_owning_app(Some(Path::new("/tmp/x/Soprano")), &pane()));
    }
}
