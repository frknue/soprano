//! The CLI entry point the app's `main` calls first, in Swift `main.swift`'s order: Markdown,
//! browser, agent-event, pane navigation, then the launch decision. `machine` and
//! `remote-attach` run without the app.

use std::collections::HashMap;
use std::ffi::OsStr;
use std::io::{self, IsTerminal, Read, Write};
use std::path::PathBuf;

use crate::agent_event::{agent_event_request, current_hook_owner_process_id};
use crate::browser::{self, BrowserCommandRequest};
use crate::launch::{self, LaunchDispatch, USAGE};
use crate::markdown::{self, MarkdownCommandError, MarkdownCommandRequest};
use crate::navigation;
use crate::protocol::{Request, Response};
use crate::transport::{self, Endpoint, endpoint_for_pid};
use soprano_types::NavigationDirection;

/// What `main` does after [`run_cli`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CliOutcome {
    /// A subcommand ran and printed its output; exit with this code.
    Exit(i32),
    /// No subcommand claimed the invocation: start the app.
    StartApp,
}

/// The process environment a CLI invocation runs against; tests substitute their own.
pub trait CliHost {
    fn current_directory(&self) -> PathBuf;
    fn executable_path(&self) -> Option<PathBuf>;
    /// The hook payload piped to the command; `None` on a terminal, so running
    /// `soprano agent-event …` by hand in a shell cannot block on an open tty.
    fn read_standard_input(&mut self) -> Option<Vec<u8>>;
    fn hook_owner_process_id(&self, app_process_id: Option<i32>) -> Option<i32>;
    fn navigate_within_tmux(
        &mut self,
        direction: NavigationDirection,
        environment: &HashMap<String, String>,
    ) -> bool;
    fn send(&mut self, endpoint: &Endpoint, request: &Request) -> io::Result<Option<Response>>;
    fn write_stdout(&mut self, text: &str);
    fn write_stderr(&mut self, text: &str);
    /// Runs `argv` on this process's terminal and waits; the exit code, `None` for a signal.
    fn run_attached(&mut self, argv: &[String]) -> io::Result<Option<i32>>;
    fn sleep(&mut self, duration: std::time::Duration);
}

/// The real process: stdio, the process table, `tmux`, and the local socket.
pub struct SystemHost;

impl CliHost for SystemHost {
    fn current_directory(&self) -> PathBuf {
        std::env::current_dir().unwrap_or_default()
    }

    fn executable_path(&self) -> Option<PathBuf> {
        std::env::current_exe().ok()
    }

    fn read_standard_input(&mut self) -> Option<Vec<u8>> {
        let mut stdin = io::stdin();
        if stdin.is_terminal() {
            return None;
        }
        let mut data = Vec::new();
        stdin.read_to_end(&mut data).ok().map(|_| data)
    }

    fn hook_owner_process_id(&self, app_process_id: Option<i32>) -> Option<i32> {
        current_hook_owner_process_id(app_process_id)
    }

    fn navigate_within_tmux(
        &mut self,
        direction: NavigationDirection,
        environment: &HashMap<String, String>,
    ) -> bool {
        navigation::navigate_within_tmux(direction, environment)
    }

    fn send(&mut self, endpoint: &Endpoint, request: &Request) -> io::Result<Option<Response>> {
        transport::send(endpoint, request)
    }

    fn write_stdout(&mut self, text: &str) {
        let mut out = io::stdout().lock();
        let _ = out.write_all(text.as_bytes());
        let _ = out.flush();
    }

    fn write_stderr(&mut self, text: &str) {
        let _ = io::stderr().lock().write_all(text.as_bytes());
    }

    fn run_attached(&mut self, argv: &[String]) -> io::Result<Option<i32>> {
        let (program, arguments) = argv.split_first().ok_or_else(|| io::Error::other("no command"))?;
        let status = std::process::Command::new(program).args(arguments).status()?;
        Ok(status.code())
    }

    fn sleep(&mut self, duration: std::time::Duration) {
        std::thread::sleep(duration);
    }
}

/// Runs the CLI subcommand `args` names (`args[0]` is the program), printing its output. Text,
/// exit codes and help match the Swift app.
///
/// Accepts anything string-like, including `OsString` straight from `std::env::args_os()` and
/// `std::env::vars_os()`: a value that isn't valid Unicode is converted lossily (invalid bytes
/// become U+FFFD) instead of panicking, as Swift's `CommandLine.arguments` never traps either.
/// The app's `main` calls [`run_cli_from_process`], which does exactly that.
pub fn run_cli<A, K, V>(
    args: impl IntoIterator<Item = A>,
    env: impl IntoIterator<Item = (K, V)>,
) -> CliOutcome
where
    A: AsRef<OsStr>,
    K: AsRef<OsStr>,
    V: AsRef<OsStr>,
{
    let (args, env) = lossy_invocation(args, env);
    run_cli_with(&args, &env, &mut SystemHost)
}

/// [`run_cli`] with this process's `args_os()` and `vars_os()`.
pub fn run_cli_from_process() -> CliOutcome {
    run_cli(std::env::args_os(), std::env::vars_os())
}

/// Converts an OS-level invocation to the `String` form the parsers use, lossily.
pub fn lossy_invocation<A, K, V>(
    args: impl IntoIterator<Item = A>,
    env: impl IntoIterator<Item = (K, V)>,
) -> (Vec<String>, HashMap<String, String>)
where
    A: AsRef<OsStr>,
    K: AsRef<OsStr>,
    V: AsRef<OsStr>,
{
    let lossy = |value: &OsStr| value.to_string_lossy().into_owned();
    let args = args.into_iter().map(|arg| lossy(arg.as_ref())).collect();
    let env = env.into_iter().map(|(key, value)| (lossy(key.as_ref()), lossy(value.as_ref()))).collect();
    (args, env)
}

pub fn run_cli_with(args: &[String], env: &HashMap<String, String>, host: &mut dyn CliHost) -> CliOutcome {
    if let Some(code) = run_markdown(args, env, host) {
        return CliOutcome::Exit(code);
    }
    if let Some(code) = run_browser(args, env, host) {
        return CliOutcome::Exit(code);
    }
    #[cfg(feature = "visual-snapshot")]
    if let Some(code) = run_debug(args, env, host) {
        return CliOutcome::Exit(code);
    }
    if let Some(code) = crate::machines::run_machine(args, env, host) {
        return CliOutcome::Exit(code);
    }
    if let Some(code) = crate::machines::run_remote_attach(args, host) {
        return CliOutcome::Exit(code);
    }
    if run_agent_event(args, env, host) || run_navigation(args, env, host) {
        return CliOutcome::Exit(0);
    }
    if let Some(code) = crate::machines::run_ssh(args, env, host) {
        return CliOutcome::Exit(code);
    }
    let runs_owning_app = launch::runs_owning_app(host.executable_path().as_deref(), env);
    match LaunchDispatch::decide(args, env, runs_owning_app) {
        LaunchDispatch::Help => {
            write_line(host, Stream::Out, USAGE);
            CliOutcome::Exit(0)
        }
        LaunchDispatch::UsageError => {
            write_line(host, Stream::Err, USAGE);
            CliOutcome::Exit(2)
        }
        LaunchDispatch::StartApp => CliOutcome::StartApp,
    }
}

/// The app's endpoint for a pane's environment: `SOPRANO_SOCKET`, else derived from
/// `SOPRANO_APP_PID`. `None` outside a Soprano terminal.
pub fn endpoint_from_environment(env: &HashMap<String, String>) -> Option<Endpoint> {
    let pid = env.get("SOPRANO_APP_PID").filter(|pid| !pid.is_empty())?;
    match env.get("SOPRANO_SOCKET").filter(|socket| !socket.is_empty()) {
        Some(socket) => Some(Endpoint::new(socket.clone())),
        None => Some(endpoint_for_pid(pid)),
    }
}

#[derive(Clone, Copy)]
enum Stream {
    Out,
    Err,
}

/// Writes `value`, newline-terminated unless it already is.
fn write_line(host: &mut dyn CliHost, stream: Stream, value: &str) {
    let text = if value.ends_with('\n') { value.to_string() } else { format!("{value}\n") };
    match stream {
        Stream::Out => host.write_stdout(&text),
        Stream::Err => host.write_stderr(&text),
    }
}

/// Sends a request that expects an answer and prints it: output to stdout (exit 0) or error to
/// stderr (exit 1); `timeout_message` when no answer arrives (the app is gone or did not reply).
pub(crate) fn exchange(
    host: &mut dyn CliHost,
    endpoint: &Endpoint,
    request: &Request,
    timeout_message: &str,
) -> i32 {
    match host.send(endpoint, request) {
        Ok(Some(Response::Ok { output })) => {
            write_line(host, Stream::Out, &output);
            0
        }
        Ok(Some(Response::Error { error })) => {
            write_line(host, Stream::Err, &error);
            1
        }
        Ok(None) | Err(_) => {
            write_line(host, Stream::Err, timeout_message);
            1
        }
    }
}

fn run_markdown(args: &[String], env: &HashMap<String, String>, host: &mut dyn CliHost) -> Option<i32> {
    let request = match MarkdownCommandRequest::parse(args, env, &host.current_directory()) {
        Ok(None) => return None,
        Ok(Some(request)) => request,
        Err(MarkdownCommandError::HelpRequested) => {
            write_line(host, Stream::Out, markdown::HELP);
            return Some(0);
        }
        Err(MarkdownCommandError::InvalidArguments(message)) => {
            write_line(host, Stream::Err, &message);
            write_line(host, Stream::Err, markdown::HELP);
            return Some(2);
        }
    };
    if !markdown::validate_readable_file(&request.path) {
        write_line(host, Stream::Err, &format!("Cannot read Markdown file: {}", request.path.display()));
        return Some(2);
    }
    let Some(endpoint) = endpoint_from_environment(env) else {
        write_line(
            host,
            Stream::Err,
            "Markdown readers must be opened inside a Soprano terminal (SOPRANO_APP_PID is missing).",
        );
        return Some(2);
    };
    let message = Request::OpenMarkdown {
        path: request.path,
        opens_new_pane: request.opens_new_pane,
        caller_pane_id: env.get("SOPRANO_PANE_ID").cloned(),
        caller_tab_id: env.get("SOPRANO_TAB_ID").cloned(),
    };
    Some(exchange(host, &endpoint, &message, "Timed out waiting for Soprano to open the Markdown file."))
}

/// The hidden visual-QA subcommands of Dev builds (`visual-snapshot`), not in the usage text:
/// `debug-snapshot <absolute-png-path>` renders the main window into a PNG; `debug-keys`,
/// `debug-modifiers`, `debug-type`, `debug-click`, `debug-move` and `debug-scroll`
/// ([`crate::debug::USAGE`]) dispatch input through it. `--agents` right after the subcommand
/// targets the Agents window instead. The app is found through `SOPRANO_SOCKET`, else
/// `SOPRANO_APP_PID`. Prints the app's answer; exits 1 when the app cannot be reached or
/// fails, 2 on bad arguments.
#[cfg(feature = "visual-snapshot")]
fn run_debug(args: &[String], env: &HashMap<String, String>, host: &mut dyn CliHost) -> Option<i32> {
    use crate::debug::{DebugInput, USAGE as INPUT_USAGE};
    let command = args.get(1)?.as_str();
    let rest = &args[2..];
    let agents = rest.first().is_some_and(|arg| arg == "--agents");
    let rest = if agents { &rest[1..] } else { rest };
    let request = if command == "debug-snapshot" {
        match rest {
            [path] if std::path::Path::new(path).is_absolute() => {
                Request::DebugSnapshot { path: PathBuf::from(path), agents }
            }
            _ => {
                write_line(host, Stream::Err, "Usage: soprano debug-snapshot [--agents] <absolute-png-path>");
                return Some(2);
            }
        }
    } else {
        match DebugInput::parse(command, rest)? {
            Ok(input) => Request::DebugInput { input, agents },
            Err(message) => {
                write_line(host, Stream::Err, &message);
                write_line(host, Stream::Err, INPUT_USAGE);
                return Some(2);
            }
        }
    };
    let endpoint = match env.get("SOPRANO_SOCKET").filter(|socket| !socket.is_empty()) {
        Some(socket) => Endpoint::new(socket.clone()),
        None => match env.get("SOPRANO_APP_PID").filter(|pid| !pid.is_empty()) {
            Some(pid) => endpoint_for_pid(pid),
            None => {
                write_line(
                    host,
                    Stream::Err,
                    "Set SOPRANO_SOCKET (or SOPRANO_APP_PID) to the running Soprano.",
                );
                return Some(2);
            }
        },
    };
    match host.send(&endpoint, &request) {
        Ok(Some(Response::Ok { output })) => {
            write_line(host, Stream::Out, &output);
            Some(0)
        }
        Ok(Some(Response::Error { error })) => {
            write_line(host, Stream::Err, &error);
            Some(1)
        }
        Ok(None) => {
            write_line(host, Stream::Err, "Timed out waiting for Soprano to answer.");
            Some(1)
        }
        Err(error) => {
            write_line(host, Stream::Err, &format!("Cannot reach Soprano at {}: {error}", endpoint.as_str()));
            Some(1)
        }
    }
}

fn run_browser(args: &[String], env: &HashMap<String, String>, host: &mut dyn CliHost) -> Option<i32> {
    let request = match BrowserCommandRequest::parse(args, env, &host.current_directory()) {
        Ok(None) => return None,
        Ok(Some(request)) => request,
        Err(message) => {
            write_line(host, Stream::Err, &message);
            return Some(2);
        }
    };
    if request.command == "help" {
        write_line(host, Stream::Out, browser::HELP);
        return Some(0);
    }
    let Some(endpoint) = endpoint_from_environment(env) else {
        write_line(
            host,
            Stream::Err,
            "Browser automation must run inside a Soprano terminal (SOPRANO_APP_PID is missing).",
        );
        return Some(2);
    };
    let message = Request::Browser {
        command: request.command,
        arguments: request.arguments,
        target_pane_id: request.target_pane_id,
        caller_pane_id: env.get("SOPRANO_PANE_ID").cloned(),
        caller_tab_id: env.get("SOPRANO_TAB_ID").cloned(),
    };
    Some(exchange(host, &endpoint, &message, "Timed out waiting for Soprano browser automation."))
}

fn run_agent_event(args: &[String], env: &HashMap<String, String>, host: &mut dyn CliHost) -> bool {
    if args.get(1).map(String::as_str) != Some("agent-event") {
        return false;
    }
    let app_process_id = env.get("SOPRANO_APP_PID").and_then(|pid| pid.parse::<i32>().ok());
    // Both lookups run only for a valid invocation, as in Swift.
    let host_cell = std::cell::RefCell::new(&mut *host);
    let request = agent_event_request(
        args,
        env,
        || host_cell.borrow_mut().read_standard_input(),
        || host_cell.borrow().hook_owner_process_id(app_process_id),
    );
    if let (Some(request), Some(endpoint)) = (request, endpoint_from_environment(env)) {
        let _ = host.send(&endpoint, &request);
    }
    true
}

fn run_navigation(args: &[String], env: &HashMap<String, String>, host: &mut dyn CliHost) -> bool {
    let mut posted = None;
    let handled = navigation::handle(
        args,
        env,
        |direction, environment| host.navigate_within_tmux(direction, environment),
        |request| posted = Some(request.clone()),
    );
    if let (Some(request), Some(endpoint)) = (posted, endpoint_from_environment(env)) {
        let _ = host.send(&endpoint, &request);
    }
    handled
}
