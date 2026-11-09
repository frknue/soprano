//! A scheduled run's precheck (`AutomationPrecheck` in `Automations/AutomationWorkspace.swift`):
//! a shell command in the automation's folder whose exit status decides whether the run starts.

use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

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
    let (reader, writer) = match std::io::pipe() {
        Ok(pipe) => pipe,
        Err(error) => return PrecheckOutcome { exit_code: 127, timed_out: false, output: error.to_string() },
    };
    let error_writer = match writer.try_clone() {
        Ok(writer) => writer,
        Err(error) => return PrecheckOutcome { exit_code: 127, timed_out: false, output: error.to_string() },
    };
    let mut process = Command::new(shell);
    process
        .args(shell_arguments(shell, command))
        .current_dir(folder)
        .stdin(Stdio::null())
        .stdout(writer)
        .stderr(error_writer);
    process_group::lead_own_group(&mut process);
    let spawned = process.spawn();
    // The command keeps its own copies of the pipe's write end; ours must close so the read
    // ends with the command.
    drop(process);
    let mut child = match spawned {
        Ok(child) => child,
        Err(error) => return PrecheckOutcome { exit_code: 127, timed_out: false, output: error.to_string() },
    };

    let collected = Arc::new(Mutex::new(Vec::new()));
    let (reached_end, ended) = mpsc::channel();
    {
        let collected = collected.clone();
        let mut reader = reader;
        thread::spawn(move || {
            let mut chunk = [0u8; 8192];
            loop {
                match reader.read(&mut chunk) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        collected.lock().unwrap_or_else(|e| e.into_inner()).extend_from_slice(&chunk[..n])
                    }
                }
            }
            let _ = reached_end.send(());
        });
    }

    let deadline = Instant::now() + timeout;
    let mut timed_out = false;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if Instant::now() >= deadline => {
                timed_out = true;
                break process_group::stop(&mut child);
            }
            Ok(None) => thread::sleep(Duration::from_millis(10)),
            Err(_) => break None,
        }
    };
    // The output ends with the command unless something it started in the background still
    // holds the pipe; that is not waited for, or it would hold every automation's setup until
    // it was done.
    let _ = ended.recv_timeout(Duration::from_millis(500));
    let data = collected.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let text = String::from_utf8_lossy(&data);
    let text = text.trim();
    let skip = text.chars().count().saturating_sub(limit);
    PrecheckOutcome {
        exit_code: status.map(exit_code).unwrap_or(-1),
        timed_out,
        output: text.chars().skip(skip).collect(),
    }
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

fn exit_code(status: std::process::ExitStatus) -> i32 {
    if let Some(code) = status.code() {
        return code;
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt;
        if let Some(signal) = status.signal() {
            return signal;
        }
    }
    -1
}

/// Stopping a timed-out precheck with everything it started.
#[cfg(unix)]
mod process_group {
    use std::os::unix::process::CommandExt;
    use std::process::{Child, Command, ExitStatus};
    use std::thread;
    use std::time::{Duration, Instant};

    /// The shell leads its own process group, so what it starts is in it too.
    pub fn lead_own_group(command: &mut Command) {
        command.process_group(0);
    }

    /// SIGTERM to the whole group, then SIGKILL to whatever is left after two seconds, so
    /// nothing piles up every tick.
    pub fn stop(child: &mut Child) -> Option<ExitStatus> {
        let Ok(pid) = i32::try_from(child.id()) else {
            let _ = child.kill();
            return child.wait().ok();
        };
        let group = -pid;
        // SAFETY: kill(2) on the process group our own child leads.
        unsafe { libc::kill(group, libc::SIGTERM) };
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut status = None;
        while Instant::now() < deadline {
            if status.is_none() {
                status = child.try_wait().ok().flatten();
            }
            // SAFETY: signal 0 only checks whether the group still has members.
            let group_alive = unsafe { libc::kill(group, 0) } == 0;
            if status.is_some() && !group_alive {
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
        // SAFETY: as above.
        unsafe { libc::kill(group, libc::SIGKILL) };
        match status {
            Some(status) => Some(status),
            None => child.wait().ok(),
        }
    }
}

#[cfg(windows)]
mod process_group {
    use std::os::windows::process::CommandExt;
    use std::process::{Child, Command, ExitStatus, Stdio};

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    pub fn lead_own_group(command: &mut Command) {
        command.creation_flags(CREATE_NO_WINDOW);
    }

    /// Ends the shell and every process it started (`taskkill /T`).
    pub fn stop(child: &mut Child) -> Option<ExitStatus> {
        let _ = Command::new("taskkill")
            .args(["/T", "/F", "/PID", &child.id().to_string()])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        let _ = child.kill();
        child.wait().ok()
    }
}

#[cfg(all(test, unix))]
mod tests {
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
