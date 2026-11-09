//! Runs the agent CLIs (`claude`, `codex`, `omp`) the way agent panes start
//! them, and plain executables such as `/usr/bin/security`. Private to this
//! crate: only the error type is public, inside `AccountError`.

use std::collections::{BTreeMap, HashMap};
use std::io::{Read, Write};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, LazyLock, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use regex::Regex;

/// Output of a finished command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CommandResult {
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
            let stripped = strip_terminal_codes(stream);
            if let Some(last) = stripped.lines().map(str::trim).rfind(|line| !line.is_empty()) {
                return last.to_owned();
            }
        }
        format!("exited with status {}", self.status)
    }

    /// `failure_message`, except that the shell's "not found" (127; `cmd.exe`'s
    /// 9009 on Windows) names the missing CLI instead.
    pub fn failure_message_running(&self, command: &str) -> String {
        if self.status == 127 || (cfg!(windows) && self.status == 9009) {
            format!("{command} is not installed or not on the login shell's PATH.")
        } else {
            self.failure_message()
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CommandError {
    #[error("Could not start the command: {0}")]
    LaunchFailed(String),
    #[error("The command took too long and was stopped.")]
    TimedOut,
    #[error("Cancelled.")]
    Cancelled,
}

/// Stops a running command (a sign-in the user cancelled). Clones share one flag.
#[derive(Debug, Clone, Default)]
pub(crate) struct CancelToken(Arc<AtomicBool>);

impl CancelToken {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

/// Receives each line a command prints, from a reader thread.
pub(crate) type LineHandler = Arc<dyn Fn(&str) + Send + Sync>;

/// How one command runs besides its arguments.
#[derive(Default, Clone)]
pub(crate) struct RunOptions {
    /// Written to stdin, which is then closed (unless `keep_stdin_open`).
    pub input: Option<Vec<u8>>,
    /// Leaves stdin open until the command ends, for CLIs that treat
    /// end-of-input as "cancel".
    pub keep_stdin_open: bool,
    pub on_output_line: Option<LineHandler>,
    pub cancel: Option<CancelToken>,
}

/// Marks where the rc files' output ends and the command's begins on stderr
/// (ASCII record separator): prompt themes complain on stderr when there is
/// no terminal, and that must not pass for the command's error.
#[cfg(not(windows))]
const COMMAND_START_MARKER: char = '\u{1E}';

#[derive(Debug, Clone)]
pub(crate) struct CommandRunner {
    /// The login shell agent panes use (`soprano_platform::shell::user_shell`).
    #[cfg_attr(windows, allow(dead_code))]
    pub shell: String,
}

impl Default for CommandRunner {
    fn default() -> Self {
        Self { shell: soprano_platform::shell::user_shell() }
    }
}

impl CommandRunner {
    #[cfg(all(test, unix))]
    pub fn with_shell(shell: impl Into<String>) -> Self {
        Self { shell: shell.into() }
    }

    /// Runs `arguments` the way agent panes start CLIs.
    ///
    /// Unix: through `shell -lic`, so PATH and environment match a pane.
    /// `environment` is applied with `exec env` *after* the rc files ran, so a
    /// profile that exports, say, `CODEX_HOME` cannot redirect a managed login.
    ///
    /// Windows has no login shell: the command runs through `cmd.exe /C`
    /// (which finds npm's `.cmd` shims on PATH) with `environment` set on the
    /// process.
    pub fn run_cli(
        &self,
        arguments: &[&str],
        environment: &BTreeMap<String, String>,
        timeout: Duration,
        options: RunOptions,
    ) -> Result<CommandResult, CommandError> {
        #[cfg(not(windows))]
        {
            let assignments = environment.iter().map(|(key, value)| format!("{key}={value}"));
            let command = assignments
                .chain(arguments.iter().map(|argument| (*argument).to_owned()))
                .map(|word| shell_quoted(&word))
                .collect::<Vec<_>>()
                .join(" ");
            let script = format!("printf '\\036' >&2; exec env {command}");
            let result =
                self.run(&self.shell, &["-lic", &script], Some(background_environment()), timeout, options)?;
            let Some(marker) = result.stderr.rfind(COMMAND_START_MARKER) else { return Ok(result) };
            let stderr = result.stderr[marker + COMMAND_START_MARKER.len_utf8()..].to_owned();
            Ok(CommandResult { stderr, ..result })
        }
        #[cfg(windows)]
        {
            let mut env = background_environment();
            env.extend(environment.iter().map(|(key, value)| (key.clone(), value.clone())));
            let line =
                arguments.iter().map(|argument| windows_quoted(argument)).collect::<Vec<_>>().join(" ");
            let script = format!("/D /S /C \"{line}\"");
            self.run_raw_windows("cmd.exe", &script, env, timeout, options)
        }
    }

    /// Runs `executable` directly.
    pub fn run(
        &self,
        executable: &str,
        arguments: &[&str],
        environment: Option<HashMap<String, String>>,
        timeout: Duration,
        options: RunOptions,
    ) -> Result<CommandResult, CommandError> {
        let mut command = Command::new(executable);
        command.args(arguments);
        if let Some(environment) = environment {
            command.env_clear().envs(environment);
        }
        execute(command, timeout, options)
    }

    #[cfg(windows)]
    fn run_raw_windows(
        &self,
        executable: &str,
        raw: &str,
        environment: HashMap<String, String>,
        timeout: Duration,
        options: RunOptions,
    ) -> Result<CommandResult, CommandError> {
        use std::os::windows::process::CommandExt;
        let mut command = Command::new(executable);
        command.raw_arg(raw);
        command.env_clear().envs(environment);
        // CREATE_NO_WINDOW: no console flashes up for a background command.
        command.creation_flags(0x0800_0000);
        execute(command, timeout, options)
    }
}

/// Soprano's own environment minus its pane variables: a background login
/// must not report agent events or look like it runs inside a pane.
pub(crate) fn background_environment() -> HashMap<String, String> {
    std::env::vars().filter(|(key, _)| !key.starts_with("SOPRANO_") && key != "TERM_PROGRAM").collect()
}

#[cfg(not(windows))]
pub(crate) fn shell_quoted(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

#[cfg(windows)]
fn windows_quoted(value: &str) -> String {
    if !value.is_empty() && !value.contains([' ', '\t', '"', '&', '|', '<', '>', '^']) {
        return value.to_owned();
    }
    format!("\"{}\"", value.replace('"', "\"\""))
}

static TERMINAL_CODES: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\x1B(\[[0-9;?]*[ -/]*[@-~]|\][^\x07\x1B]*(\x07|\x1B\\)|[@-Z\\-_])").expect("valid pattern")
});

static HTTPS_URL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"https://[^\s"'<>]+"#).expect("valid pattern"));

/// Removes ANSI escape sequences (colors, cursor moves) from CLI output.
pub(crate) fn strip_terminal_codes(text: &str) -> String {
    TERMINAL_CODES.replace_all(text, "").into_owned()
}

/// The first `https://` URL in a line of CLI output.
pub(crate) fn first_url(line: &str) -> Option<String> {
    let text = strip_terminal_codes(line);
    HTTPS_URL.find(&text).map(|found| found.as_str().to_owned())
}

#[derive(Clone, Copy)]
enum Stream {
    Stdout,
    Stderr,
}

/// One process run: reader threads collect each stream (and hand out its
/// lines), the calling thread waits for the process, a timeout, or a cancel.
fn execute(
    mut command: Command,
    timeout: Duration,
    options: RunOptions,
) -> Result<CommandResult, CommandError> {
    if options.cancel.as_ref().is_some_and(CancelToken::is_cancelled) {
        return Err(CommandError::Cancelled);
    }
    let wants_stdin = options.input.is_some() || options.keep_stdin_open;
    command.stdin(if wants_stdin { Stdio::piped() } else { Stdio::null() });
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = command.spawn().map_err(|error| CommandError::LaunchFailed(error.to_string()))?;

    let stdout_buffer = Arc::new(Mutex::new(Vec::new()));
    let stderr_buffer = Arc::new(Mutex::new(Vec::new()));
    let (closed_sender, closed) = mpsc::channel::<()>();
    let readers: [(Option<Box<dyn Read + Send>>, Stream); 2] = [
        (child.stdout.take().map(|pipe| Box::new(pipe) as Box<dyn Read + Send>), Stream::Stdout),
        (child.stderr.take().map(|pipe| Box::new(pipe) as Box<dyn Read + Send>), Stream::Stderr),
    ];
    for (pipe, stream) in readers {
        let Some(pipe) = pipe else {
            let _ = closed_sender.send(());
            continue;
        };
        let buffer = match stream {
            Stream::Stdout => Arc::clone(&stdout_buffer),
            Stream::Stderr => Arc::clone(&stderr_buffer),
        };
        let handler = options.on_output_line.clone();
        let sender = closed_sender.clone();
        thread::spawn(move || {
            read_stream(pipe, &buffer, handler.as_ref());
            let _ = sender.send(());
        });
    }
    drop(closed_sender);

    let mut stdin = child.stdin.take();
    if let (Some(input), Some(pipe)) = (&options.input, stdin.as_mut()) {
        let _ = pipe.write_all(input);
        let _ = pipe.flush();
    }
    if !options.keep_stdin_open {
        stdin = None;
    }

    let started = Instant::now();
    let outcome = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Ok(status),
            Ok(None) => {}
            Err(error) => break Err(CommandError::LaunchFailed(error.to_string())),
        }
        if options.cancel.as_ref().is_some_and(CancelToken::is_cancelled) {
            terminate(&mut child);
            break Err(CommandError::Cancelled);
        }
        if started.elapsed() >= timeout {
            terminate(&mut child);
            break Err(CommandError::TimedOut);
        }
        thread::sleep(Duration::from_millis(20));
    };
    drop(stdin);
    let status = outcome?;

    // A child the command spawned (a browser opener, say) can hold the pipes
    // open after the command itself exited; don't wait long for it.
    let deadline = Instant::now() + Duration::from_millis(500);
    for _ in 0..2 {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if closed.recv_timeout(remaining).is_err() {
            break;
        }
    }
    let text = |buffer: &Arc<Mutex<Vec<u8>>>| {
        let bytes = buffer.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        String::from_utf8_lossy(&bytes).into_owned()
    };
    Ok(CommandResult {
        status: exit_code(status),
        stdout: text(&stdout_buffer),
        stderr: text(&stderr_buffer),
    })
}

fn read_stream(mut pipe: Box<dyn Read + Send>, buffer: &Mutex<Vec<u8>>, handler: Option<&LineHandler>) {
    let mut partial = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        let count = match pipe.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(count) => count,
        };
        buffer.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).extend_from_slice(&chunk[..count]);
        let Some(handler) = handler else { continue };
        partial.extend_from_slice(&chunk[..count]);
        while let Some(newline) = partial.iter().position(|byte| *byte == b'\n') {
            let line: Vec<u8> = partial.drain(..=newline).collect();
            handler(&String::from_utf8_lossy(&line[..line.len() - 1]));
        }
    }
    if let Some(handler) = handler
        && !partial.is_empty()
    {
        handler(&String::from_utf8_lossy(&partial));
    }
}

/// SIGTERM, then SIGKILL for a command that ignores it for 3 s. Windows has
/// only the hard stop.
fn terminate(child: &mut Child) {
    #[cfg(unix)]
    {
        if let Ok(pid) = libc::pid_t::try_from(child.id()) {
            // SAFETY: plain signal delivery to our own child's pid.
            unsafe {
                libc::kill(pid, libc::SIGTERM);
            }
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            if matches!(child.try_wait(), Ok(Some(_))) {
                return;
            }
            thread::sleep(Duration::from_millis(20));
        }
    }
    let _ = child.kill();
    let _ = child.wait();
}

fn exit_code(status: ExitStatus) -> i32 {
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
pub(crate) mod tests {
    use super::*;

    #[test]
    fn failure_messages_take_the_last_meaningful_stderr_line_without_colors() {
        let result = CommandResult {
            status: 1,
            stdout: "out\n".into(),
            stderr: "first\n\u{1B}[31mError: boom\u{1B}[0m\n  \n".into(),
        };
        assert_eq!(result.failure_message(), "Error: boom");
        let quiet = CommandResult { status: 3, stdout: String::new(), stderr: String::new() };
        assert_eq!(quiet.failure_message(), "exited with status 3");
        let missing =
            CommandResult { status: 127, stdout: String::new(), stderr: "env: omp: not found".into() };
        assert_eq!(
            missing.failure_message_running("omp"),
            "omp is not installed or not on the login shell's PATH."
        );
    }

    #[test]
    fn the_first_https_url_of_a_line_is_the_sign_in_page() {
        assert_eq!(
            first_url("Open \u{1B}[4mhttps://claude.ai/oauth/authorize?code=true\u{1B}[0m to continue")
                .as_deref(),
            Some("https://claude.ai/oauth/authorize?code=true")
        );
        assert_eq!(first_url("visit http://insecure.example"), None);
    }

    #[cfg(not(windows))]
    #[test]
    fn shell_quoting_survives_single_quotes() {
        assert_eq!(shell_quoted("it's"), r"'it'\''s'");
    }

    #[cfg(unix)]
    #[test]
    fn the_cli_sees_the_overrides_and_rc_noise_on_stderr_is_dropped() {
        let dir = tempfile::tempdir().unwrap();
        let shell = dir.path().join("shell");
        std::fs::write(&shell, "#!/bin/bash\necho 'theme: no tty' >&2\nexec /bin/bash -c \"$2\"\n").unwrap();
        make_executable(&shell);
        let runner = CommandRunner::with_shell(shell.to_string_lossy());
        let environment = BTreeMap::from([("CODEX_HOME".to_owned(), "/x y".to_owned())]);

        let result = runner
            .run_cli(
                &["sh", "-c", "echo \"$CODEX_HOME\"; echo oops >&2; exit 3"],
                &environment,
                Duration::from_secs(10),
                RunOptions::default(),
            )
            .unwrap();

        assert_eq!(result.stdout, "/x y\n");
        assert_eq!(result.stderr, "oops\n");
        assert_eq!(result.status, 3);
    }

    #[cfg(unix)]
    #[test]
    fn a_cancelled_command_stops_and_reports_cancelled() {
        let token = CancelToken::default();
        let lines = Arc::new(Mutex::new(Vec::<String>::new()));
        let seen = Arc::clone(&lines);
        let canceller = token.clone();
        let options = RunOptions {
            keep_stdin_open: true,
            on_output_line: Some(Arc::new(move |line: &str| {
                seen.lock().unwrap().push(line.to_owned());
                canceller.cancel();
            })),
            cancel: Some(token),
            ..RunOptions::default()
        };
        let started = Instant::now();
        let result = CommandRunner::default().run(
            "/bin/sh",
            &["-c", "echo https://example.com/login; exec sleep 30"],
            None,
            Duration::from_secs(20),
            options,
        );
        assert_eq!(result, Err(CommandError::Cancelled));
        assert!(started.elapsed() < Duration::from_secs(10));
        assert_eq!(lines.lock().unwrap().as_slice(), ["https://example.com/login"]);
    }

    #[cfg(unix)]
    #[test]
    fn a_command_past_its_timeout_is_stopped() {
        let result = CommandRunner::default().run(
            "/bin/sh",
            &["-c", "exec sleep 30"],
            None,
            Duration::from_millis(200),
            RunOptions::default(),
        );
        assert_eq!(result, Err(CommandError::TimedOut));
    }

    #[cfg(unix)]
    pub(crate) fn make_executable(path: &std::path::Path) {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
}
