//! A scheduled run's precheck (`AutomationPrecheck` in `Automations/AutomationWorkspace.swift`):
//! a shell command in the automation's folder whose exit status decides whether the run starts.

use std::path::PathBuf;
use std::time::Duration;

use soprano_launch::command_runner::{CommandError, CommandResult, CommandRunner, RunOptions};
use soprano_launch::quote::{ShellFlavor, powershell_quoted, shell_quoted};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PrecheckOutcome {
    /// The exit status; the signal number for a command killed by a signal.
    pub exit_code: i32,
    pub timed_out: bool,
    /// The end of what it printed, stdout and stderr together.
    pub output: String,
}

impl PrecheckOutcome {
    pub fn passed(&self) -> bool {
        self.exit_code == 0 && !self.timed_out
    }

    pub fn summary(&self) -> String {
        let reason = if self.timed_out {
            "The precheck timed out.".to_owned()
        } else {
            format!("The precheck exited with code {}.", self.exit_code)
        };
        if self.output.is_empty() { reason } else { format!("{reason}\n\n{}", self.output) }
    }
}

/// Characters of output kept with a skipped run.
pub const OUTPUT_LIMIT: usize = 4_000;

/// Runs `command` through the user's login shell so it finds what their terminal finds (`gh`,
/// `jq`). Keeps the last `limit` characters of what it printed. A command that outlives
/// `timeout` is stopped along with everything it started. Blocks; call it off the main thread.
pub fn run(command: &str, folder: &str, timeout: Duration, shell: &str, limit: usize) -> PrecheckOutcome {
    let mut options = RunOptions::with_timeout(timeout);
    options.working_directory = Some(PathBuf::from(folder));
    options.merge_stderr = true;
    let (exit_code, timed_out, output) =
        match CommandRunner::new(shell).run(shell, &shell_arguments(shell, command), options) {
            Ok(CommandResult { status, stdout, .. }) => (status, false, stdout),
            Err(CommandError::TimedOut { stdout, stderr }) => (-1, true, stdout + &stderr),
            Err(CommandError::LaunchFailed(reason)) => (127, false, reason),
            Err(CommandError::Cancelled) => (-1, true, String::new()),
        };
    let text = output.trim();
    let skip = text.chars().count().saturating_sub(limit);
    PrecheckOutcome { exit_code, timed_out, output: text.chars().skip(skip).collect() }
}

/// How `shell` runs a command string as a login shell.
fn shell_arguments(shell: &str, command: &str) -> Vec<String> {
    match ShellFlavor::of(shell) {
        ShellFlavor::Posix => vec!["-lc".into(), command.into()],
        ShellFlavor::PowerShell => vec!["-NoLogo".into(), "-Command".into(), command.into()],
    }
}

/// A command string that replaces the shell with `program arguments…`, stderr discarded when
/// asked; `program` is quoted, `arguments` are taken as written.
pub(crate) fn exec_script(shell: &str, program: &str, arguments: &str, discard_errors: bool) -> String {
    match ShellFlavor::of(shell) {
        ShellFlavor::Posix => {
            let redirect = if discard_errors { " 2>/dev/null" } else { "" };
            format!("exec {} {arguments}{redirect}", shell_quoted(program))
        }
        ShellFlavor::PowerShell => {
            let redirect = if discard_errors { " 2>$null" } else { "" };
            format!("& {} {arguments}{redirect}", powershell_quoted(program))
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use std::thread;
    use std::time::Instant;

    use super::*;

    fn precheck(command: &str, folder: &str, timeout: u64) -> PrecheckOutcome {
        run(command, folder, Duration::from_secs(timeout), "/bin/sh", OUTPUT_LIMIT)
    }

    #[test]
    fn a_precheck_that_exits_zero_lets_the_run_start() {
        let outcome = precheck("echo ready", "/tmp", 10);
        assert!(outcome.passed());
        assert_eq!(outcome.output, "ready");
    }

    #[test]
    fn a_failing_precheck_says_its_exit_code_and_what_it_printed() {
        let outcome = precheck("echo 'no open PRs' >&2; exit 3", "/tmp", 10);
        assert!(!outcome.passed());
        assert_eq!(outcome.exit_code, 3);
        assert_eq!(outcome.summary(), "The precheck exited with code 3.\n\nno open PRs");
    }

    #[test]
    fn a_precheck_that_outlives_its_timeout_is_stopped_and_fails() {
        let started = Instant::now();
        let outcome = precheck("sleep 30", "/tmp", 1);
        assert!(outcome.timed_out);
        assert!(!outcome.passed());
        assert!(started.elapsed() < Duration::from_secs(10));
        assert_eq!(outcome.summary(), "The precheck timed out.");
    }

    #[test]
    fn a_precheck_that_leaves_a_background_process_running_still_answers_when_it_exits() {
        // The child inherits the output pipe; waiting for the pipe to close held every
        // automation's setup until the child was done.
        let started = Instant::now();
        let outcome = precheck("sleep 20 & echo started", "/tmp", 10);
        assert!(outcome.passed());
        assert_eq!(outcome.output, "started");
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn a_precheck_that_times_out_stops_the_commands_it_started_along_with_its_shell() {
        let directory = tempfile::tempdir().expect("temp dir");
        // A command that shrugs off SIGTERM, the way one handling it would.
        let outcome = precheck(
            "trap '' TERM; sleep 30 & echo $! > child.pid; sleep 30",
            &directory.path().to_string_lossy(),
            1,
        );
        assert!(outcome.timed_out);
        let text = std::fs::read_to_string(directory.path().join("child.pid")).expect("pid file");
        let child: i32 = text.trim().parse().expect("pid");
        let deadline = Instant::now() + Duration::from_secs(3);
        // SAFETY: signal 0 only checks whether the process exists.
        while unsafe { libc::kill(child, 0) } == 0 && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(50));
        }
        // SAFETY: as above; SIGKILL cleans up after a failed expectation.
        let alive = unsafe { libc::kill(child, 0) } == 0;
        if alive {
            unsafe { libc::kill(child, libc::SIGKILL) };
        }
        assert!(!alive);
    }

    #[test]
    fn only_the_end_of_a_long_output_is_kept() {
        let outcome = run("printf 'abcdef'", "/tmp", Duration::from_secs(10), "/bin/sh", 3);
        assert_eq!(outcome.output, "def");
    }
}
