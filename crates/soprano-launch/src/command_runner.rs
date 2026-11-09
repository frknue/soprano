//! Runs the agent CLIs (`claude`, `codex`, `omp`) the way agent panes start them — through
//! the user's interactive login shell, so PATH and environment match — and plain executables
//! (`Accounts/CommandRunner.swift`). Synchronous: call it from a worker thread.

use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, LazyLock, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use regex::Regex;

use crate::quote::{ShellFlavor, powershell_quoted, shell_quoted};

/// Output of a finished command.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommandResult {
    /// Exit status; the signal number for a command killed by a signal, -1 when unknown.
    pub status: i32,
    pub stdout: String,
    pub stderr: String,
}

impl CommandResult {
    pub fn succeeded(&self) -> bool {
        self.status == 0
    }

    /// The last non-empty stderr line, else stdout's: what a CLI says when it fails.
    pub fn failure_message(&self) -> String {
        for stream in [&self.stderr, &self.stdout] {
            let text = stripping_terminal_codes(stream);
            if let Some(last) = text.lines().map(str::trim).rfind(|l| !l.is_empty()) {
                return last.to_owned();
            }
        }
        format!("exited with status {}", self.status)
    }

    /// [`failure_message`](Self::failure_message), except that `env`'s "not found" (status
    /// 127) names the missing CLI instead.
    pub fn failure_message_running(&self, command: &str) -> String {
        if self.status == 127 {
            format!("{command} is not installed or not on the login shell's PATH.")
        } else {
            self.failure_message()
        }
    }
}

/// Why a command produced no result.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CommandError {
    LaunchFailed(String),
    TimedOut,
    Cancelled,
}

impl std::fmt::Display for CommandError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::LaunchFailed(reason) => write!(f, "Could not start the command: {reason}"),
            Self::TimedOut => f.write_str("The command took too long and was stopped."),
            Self::Cancelled => f.write_str("Cancelled."),
        }
    }
}

impl std::error::Error for CommandError {}

/// Cancels a running command from another thread (SIGTERM, then SIGKILL after 3 s).
#[derive(Clone, Debug, Default)]
pub struct CancelToken(Arc<AtomicBool>);

impl CancelToken {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

/// Called with each complete output line (stdout and stderr), on a reader thread.
pub type OutputLineHandler = Arc<dyn Fn(&str) + Send + Sync>;

/// Options for one run.
#[derive(Clone)]
pub struct RunOptions {
    pub timeout: Duration,
    /// Replaces the whole environment when set; otherwise the app's is inherited.
    pub environment: Option<BTreeMap<String, String>>,
    /// Written to stdin, which is then closed (unless `keep_stdin_open`).
    pub input: Option<Vec<u8>>,
    /// Leaves stdin open until the command ends, for CLIs that treat end-of-input as
    /// "cancel".
    pub keep_stdin_open: bool,
    pub on_output_line: Option<OutputLineHandler>,
    pub cancel: Option<CancelToken>,
}

impl RunOptions {
    pub fn with_timeout(timeout: Duration) -> Self {
        Self {
            timeout,
            environment: None,
            input: None,
            keep_stdin_open: false,
            on_output_line: None,
            cancel: None,
        }
    }
}

/// Runs commands for the accounts and automations layers.
#[derive(Clone, Debug)]
pub struct CommandRunner {
    /// The login shell agent panes use.
    pub shell: String,
}

impl Default for CommandRunner {
    fn default() -> Self {
        Self { shell: soprano_platform::shell::user_shell() }
    }
}

/// Marks where the rc files' output ends and the command's begins on stderr (ASCII record
/// separator): prompt themes complain on stderr when there is no terminal, and that must not
/// pass for the command's error.
pub const COMMAND_START_MARKER: char = '\u{1E}';

impl CommandRunner {
    pub fn new(shell: impl Into<String>) -> Self {
        Self { shell: shell.into() }
    }

    /// The `-lic` script (or PowerShell `-Command` script) [`run_cli`](Self::run_cli) runs.
    /// `overrides` are applied with `exec env` *after* the rc files ran, so a profile that
    /// exports, say, `CODEX_HOME` cannot redirect a managed login.
    pub fn cli_arguments(&self, arguments: &[String], overrides: &BTreeMap<String, String>) -> Vec<String> {
        match ShellFlavor::of(&self.shell) {
            ShellFlavor::Posix => {
                let words: Vec<String> = overrides
                    .iter()
                    .map(|(k, v)| format!("{k}={v}"))
                    .chain(arguments.iter().cloned())
                    .map(|w| shell_quoted(&w))
                    .collect();
                vec!["-lic".into(), format!("printf '\\036' >&2; exec env {}", words.join(" "))]
            }
            ShellFlavor::PowerShell => {
                let mut script = vec!["[Console]::Error.Write([char]0x1E)".to_owned()];
                script.extend(overrides.iter().map(|(k, v)| format!("$env:{k} = {}", powershell_quoted(v))));
                let words: Vec<String> = arguments.iter().map(|a| powershell_quoted(a)).collect();
                script.push(format!("& {}", words.join(" ")));
                script.push("exit $LASTEXITCODE".into());
                vec!["-NoLogo".into(), "-Command".into(), script.join("; ")]
            }
        }
    }

    /// Runs `arguments` through the login shell with [`background_environment`] and returns
    /// stderr from the marker on.
    pub fn run_cli(
        &self,
        arguments: &[String],
        overrides: &BTreeMap<String, String>,
        mut options: RunOptions,
    ) -> Result<CommandResult, CommandError> {
        options.environment = Some(background_environment(std::env::vars()));
        let result = self.run(&self.shell, &self.cli_arguments(arguments, overrides), options)?;
        match result.stderr.rfind(COMMAND_START_MARKER) {
            Some(index) => Ok(CommandResult {
                stderr: result.stderr[index + COMMAND_START_MARKER.len_utf8()..].to_owned(),
                ..result
            }),
            None => Ok(result),
        }
    }

    /// Runs `executable` directly.
    pub fn run(
        &self,
        executable: &str,
        arguments: &[String],
        options: RunOptions,
    ) -> Result<CommandResult, CommandError> {
        run_process(executable, arguments, options)
    }
}

/// Soprano's own environment minus its pane variables: a background login must not report
/// agent events or look like it runs inside a pane.
pub fn background_environment(env: impl IntoIterator<Item = (String, String)>) -> BTreeMap<String, String> {
    env.into_iter().filter(|(k, _)| !k.starts_with("SOPRANO_") && k != "TERM_PROGRAM").collect()
}

static TERMINAL_CODES: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\x1B(\[[0-9;?]*[ -/]*[@-~]|\][^\x07\x1B]*(\x07|\x1B\\)|[@-Z\\-_])").expect("valid regex")
});
static HTTPS_URL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"https://[^\s"'<>]+"#).expect("valid regex"));

/// Removes ANSI escape sequences (colors, cursor moves) from CLI output.
pub fn stripping_terminal_codes(text: &str) -> String {
    TERMINAL_CODES.replace_all(text, "").into_owned()
}

/// The first `https://` URL in a line of CLI output.
pub fn first_url(line: &str) -> Option<String> {
    let text = stripping_terminal_codes(line);
    HTTPS_URL.find(&text).map(|m| m.as_str().to_owned())
}

fn run_process(
    executable: &str,
    arguments: &[String],
    options: RunOptions,
) -> Result<CommandResult, CommandError> {
    if options.cancel.as_ref().is_some_and(CancelToken::is_cancelled) {
        return Err(CommandError::Cancelled);
    }
    let mut command = Command::new(executable);
    command.args(arguments).stdout(Stdio::piped()).stderr(Stdio::piped());
    if let Some(environment) = &options.environment {
        command.env_clear().envs(environment);
    }
    let wants_stdin = options.input.is_some() || options.keep_stdin_open;
    command.stdin(if wants_stdin { Stdio::piped() } else { Stdio::null() });
    let mut child = command.spawn().map_err(|e| CommandError::LaunchFailed(e.to_string()))?;

    let stdout = Arc::new(Mutex::new(Vec::new()));
    let stderr = Arc::new(Mutex::new(Vec::new()));
    let (closed_tx, closed_rx) = mpsc::channel::<()>();
    if let Some(pipe) = child.stdout.take() {
        spawn_reader(pipe, stdout.clone(), options.on_output_line.clone(), closed_tx.clone());
    }
    if let Some(pipe) = child.stderr.take() {
        spawn_reader(pipe, stderr.clone(), options.on_output_line.clone(), closed_tx.clone());
    }
    drop(closed_tx);

    let mut stdin = child.stdin.take();
    if let Some(input) = options.input.clone() {
        // Large input would block until the command reads it; write from the side. With
        // `keep_stdin_open` a second handle writes and the original stays open until exit.
        let writer: Option<Box<dyn Write + Send>> = if options.keep_stdin_open {
            stdin
                .as_ref()
                .and_then(|pipe| pipe.try_clone_handle())
                .map(|f| Box::new(f) as Box<dyn Write + Send>)
        } else {
            stdin.take().map(|pipe| Box::new(pipe) as Box<dyn Write + Send>)
        };
        if let Some(mut writer) = writer {
            thread::spawn(move || {
                let _ = writer.write_all(&input);
            });
        }
    }

    let deadline = Instant::now() + options.timeout;
    let mut stop_reason: Option<CommandError> = None;
    let mut kill_at: Option<Instant> = None;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) => {}
            Err(_) => break None,
        }
        if stop_reason.is_none() {
            if options.cancel.as_ref().is_some_and(CancelToken::is_cancelled) {
                stop_reason = Some(CommandError::Cancelled);
            } else if Instant::now() >= deadline {
                stop_reason = Some(CommandError::TimedOut);
            }
            if stop_reason.is_some() {
                terminate(&mut child);
                kill_at = Some(Instant::now() + Duration::from_secs(3));
            }
        }
        // SIGTERM, then SIGKILL for a command that ignores it.
        if kill_at.is_some_and(|at| Instant::now() >= at) {
            let _ = child.kill();
            kill_at = None;
        }
        thread::sleep(Duration::from_millis(10));
    };
    drop(stdin);

    // A child the command spawned (a browser opener, say) can hold the pipes open after the
    // command itself exited; don't wait for it longer than half a second.
    let grace = Instant::now() + Duration::from_millis(500);
    let mut open = 2;
    while open > 0 {
        let left = grace.saturating_duration_since(Instant::now());
        match closed_rx.recv_timeout(left) {
            Ok(()) => open -= 1,
            Err(_) => break,
        }
    }

    if let Some(reason) = stop_reason {
        return Err(reason);
    }
    let text = |buffer: &Arc<Mutex<Vec<u8>>>| {
        String::from_utf8_lossy(&buffer.lock().map(|b| b.clone()).unwrap_or_default()).into_owned()
    };
    Ok(CommandResult {
        status: status.map(exit_code).unwrap_or(-1),
        stdout: text(&stdout),
        stderr: text(&stderr),
    })
}

fn spawn_reader(
    mut pipe: impl Read + Send + 'static,
    sink: Arc<Mutex<Vec<u8>>>,
    on_line: Option<OutputLineHandler>,
    closed: mpsc::Sender<()>,
) {
    thread::spawn(move || {
        let mut partial: Vec<u8> = Vec::new();
        let mut chunk = [0u8; 8192];
        loop {
            match pipe.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if let Ok(mut sink) = sink.lock() {
                        sink.extend_from_slice(&chunk[..n]);
                    }
                    partial.extend_from_slice(&chunk[..n]);
                    while let Some(newline) = partial.iter().position(|&b| b == b'\n') {
                        let line: Vec<u8> = partial.drain(..=newline).collect();
                        if let Some(handler) = &on_line {
                            handler(&String::from_utf8_lossy(&line[..line.len() - 1]));
                        }
                    }
                }
            }
        }
        if !partial.is_empty()
            && let Some(handler) = &on_line
        {
            handler(&String::from_utf8_lossy(&partial));
        }
        let _ = closed.send(());
    });
}

/// A second handle on the child's stdin, so input is written on another thread while the
/// original stays open for `keep_stdin_open`.
trait CloneHandle {
    fn try_clone_handle(&self) -> Option<std::fs::File>;
}

impl CloneHandle for std::process::ChildStdin {
    fn try_clone_handle(&self) -> Option<std::fs::File> {
        #[cfg(unix)]
        {
            use std::os::fd::AsFd;
            self.as_fd().try_clone_to_owned().ok().map(std::fs::File::from)
        }
        #[cfg(windows)]
        {
            use std::os::windows::io::AsHandle;
            self.as_handle().try_clone_to_owned().ok().map(std::fs::File::from)
        }
    }
}

#[cfg(unix)]
fn terminate(child: &mut Child) {
    if let Ok(pid) = i32::try_from(child.id()) {
        // SAFETY: plain kill(2) on our own child's pid.
        unsafe {
            libc::kill(pid, libc::SIGTERM);
        }
    }
}

#[cfg(not(unix))]
fn terminate(child: &mut Child) {
    // Windows has no SIGTERM; TerminateProcess is the only stop there is.
    let _ = child.kill();
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failure_messages_prefer_the_last_stderr_line_without_colors() {
        let result = CommandResult {
            status: 1,
            stdout: "out\n".into(),
            stderr: "noise\n\x1b[31mboom\x1b[0m\n\n".into(),
        };
        assert_eq!(result.failure_message(), "boom");
        let quiet = CommandResult { status: 2, stdout: String::new(), stderr: String::new() };
        assert_eq!(quiet.failure_message(), "exited with status 2");
        let missing = CommandResult { status: 127, ..quiet };
        assert_eq!(
            missing.failure_message_running("codex"),
            "codex is not installed or not on the login shell's PATH."
        );
    }

    #[test]
    fn the_first_https_url_is_found_behind_terminal_codes() {
        assert_eq!(
            first_url("Open \x1b]8;;x\x07\x1b[1mhttps://auth.example.com/a?b=1\x1b[0m to log in").as_deref(),
            Some("https://auth.example.com/a?b=1")
        );
        assert_eq!(first_url("no link"), None);
    }

    #[test]
    fn overrides_are_applied_after_the_rc_files_with_exec_env() {
        let runner = CommandRunner::new("/bin/zsh");
        let overrides = BTreeMap::from([("CODEX_HOME".to_owned(), "/a b".to_owned())]);
        assert_eq!(
            runner.cli_arguments(&["codex".into(), "login".into()], &overrides),
            vec!["-lic".to_owned(), "printf '\\036' >&2; exec env 'CODEX_HOME=/a b' 'codex' 'login'".into()]
        );
    }

    #[test]
    fn background_logins_carry_no_pane_identity() {
        let env = background_environment([
            ("SOPRANO_PANE_ID".to_owned(), "p".to_owned()),
            ("TERM_PROGRAM".into(), "Soprano".into()),
            ("PATH".into(), "/bin".into()),
        ]);
        assert_eq!(env, BTreeMap::from([("PATH".to_owned(), "/bin".to_owned())]));
    }

    #[cfg(unix)]
    #[test]
    fn a_cli_run_drops_what_the_rc_files_printed_on_stderr() {
        let runner = CommandRunner::new("/bin/sh");
        let lines = Arc::new(Mutex::new(Vec::<String>::new()));
        let collected = lines.clone();
        let mut options = RunOptions::with_timeout(Duration::from_secs(10));
        options.on_output_line =
            Some(Arc::new(move |line: &str| collected.lock().unwrap().push(line.to_owned())));
        let overrides = BTreeMap::from([("GREETING".to_owned(), "hi there".to_owned())]);
        let script = "echo \"$GREETING\"; echo oops >&2; exit 3".to_owned();
        let result = runner.run_cli(&["sh".into(), "-c".into(), script], &overrides, options).expect("ran");
        assert_eq!(result.status, 3);
        assert_eq!(result.stdout, "hi there\n");
        assert_eq!(result.stderr, "oops\n");
        assert!(lines.lock().unwrap().contains(&"hi there".to_owned()));
    }

    #[cfg(unix)]
    #[test]
    fn a_command_that_takes_too_long_is_stopped() {
        let started = Instant::now();
        let error = CommandRunner::default()
            .run("/bin/sleep", &["5".into()], RunOptions::with_timeout(Duration::from_millis(200)))
            .expect_err("timed out");
        assert_eq!(error, CommandError::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(3));
    }

    #[cfg(unix)]
    #[test]
    fn input_is_written_to_stdin_and_a_cancelled_command_reports_it() {
        let mut options = RunOptions::with_timeout(Duration::from_secs(10));
        options.input = Some(b"piped\n".to_vec());
        let result = CommandRunner::default().run("/bin/cat", &[], options).expect("ran");
        assert_eq!(result.stdout, "piped\n");

        let token = CancelToken::new();
        let mut options = RunOptions::with_timeout(Duration::from_secs(10));
        options.cancel = Some(token.clone());
        let canceller = thread::spawn(move || {
            thread::sleep(Duration::from_millis(100));
            token.cancel();
        });
        let error =
            CommandRunner::default().run("/bin/sleep", &["5".into()], options).expect_err("cancelled");
        canceller.join().expect("joined");
        assert_eq!(error, CommandError::Cancelled);
    }

    #[test]
    fn a_missing_executable_fails_to_launch() {
        let error = CommandRunner::default()
            .run("/definitely/not/here", &[], RunOptions::with_timeout(Duration::from_secs(1)))
            .expect_err("missing");
        assert!(matches!(error, CommandError::LaunchFailed(_)));
    }
}
