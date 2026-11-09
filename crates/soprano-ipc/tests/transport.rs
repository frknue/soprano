use std::collections::HashMap;
use std::io;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::thread;
use std::time::Duration;

use soprano_ipc::{
    AgentEventState, CliHost, CliOutcome, Endpoint, IpcServer, NavigationDirection, Request, Response,
    endpoint_for_pid, run_cli_with, send, send_with_timeout,
};

/// A unique endpoint per test: a pid-like number that no live process uses in practice.
fn unique_endpoint() -> Endpoint {
    static NEXT: AtomicU32 = AtomicU32::new(0);
    endpoint_for_pid(format!("test-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::SeqCst)))
}

fn browser_request() -> Request {
    Request::Browser {
        command: "title".into(),
        arguments: vec![],
        target_pane_id: Some("pane-2".into()),
        caller_pane_id: Some("pane-1".into()),
        caller_tab_id: Some("tab-1".into()),
    }
}

#[test]
fn a_request_and_its_reply_round_trip_through_the_socket() {
    let (server, incoming) = IpcServer::start(unique_endpoint()).expect("server");
    let endpoint = server.endpoint().clone();
    let app = thread::spawn(move || {
        let message = incoming.recv_timeout(Duration::from_secs(5)).expect("request");
        assert_eq!(message.request, browser_request());
        message.reply.expect("replier").send(&Response::success("Example Domain")).expect("reply");
    });
    let response = send(&endpoint, &browser_request()).expect("send");
    assert_eq!(response, Some(Response::success("Example Domain")));
    app.join().expect("app thread");
}

#[test]
fn one_way_requests_arrive_without_a_replier() {
    let (server, incoming) = IpcServer::start(unique_endpoint()).expect("server");
    let request =
        Request::NavigatePane { pane_id: "p".into(), tab_id: "t".into(), direction: NavigationDirection::Up };
    assert_eq!(send(server.endpoint(), &request).expect("send"), None);
    let message = incoming.recv_timeout(Duration::from_secs(5)).expect("request");
    assert_eq!(message.request, request);
    assert!(message.reply.is_none());
}

#[test]
fn an_unanswered_request_times_out_instead_of_hanging() {
    let (server, incoming) = IpcServer::start(unique_endpoint()).expect("server");
    let result = send_with_timeout(server.endpoint(), &browser_request(), Duration::from_millis(200));
    assert!(result.is_err());
    drop(incoming);
}

#[test]
fn a_reply_dropped_unanswered_reads_as_no_response() {
    let (server, incoming) = IpcServer::start(unique_endpoint()).expect("server");
    let app = thread::spawn(move || drop(incoming.recv_timeout(Duration::from_secs(5)).expect("request")));
    assert_eq!(send(server.endpoint(), &browser_request()).expect("send"), None);
    app.join().expect("app thread");
}

#[test]
fn sending_to_an_app_that_is_not_running_fails() {
    assert!(send(&unique_endpoint(), &browser_request()).is_err());
}

#[cfg(unix)]
#[test]
fn the_socket_lives_in_a_short_per_user_directory_and_is_removed_on_drop() {
    let endpoint = endpoint_for_pid(4_294_967_295u32);
    assert!(endpoint.as_str().len() <= 103, "{endpoint}");
    assert!(endpoint.as_str().ends_with("/4294967295.sock"));
    // SAFETY: getuid has no preconditions.
    let uid_dir = format!("soprano-{}", unsafe { libc::getuid() });
    assert!(endpoint.as_str().contains(&uid_dir));

    let (server, _incoming) = IpcServer::start(unique_endpoint()).expect("server");
    let path = PathBuf::from(server.endpoint().as_str());
    assert!(path.exists());
    drop(server);
    assert!(!path.exists());
}

#[cfg(unix)]
#[test]
fn a_stale_socket_of_a_dead_instance_is_removed_at_start() {
    // Pid 999_999_999 exceeds every OS's pid range, so no live process owns it.
    let stale = PathBuf::from(endpoint_for_pid(999_999_999u32).as_str());
    std::fs::create_dir_all(stale.parent().expect("dir")).expect("mkdir");
    std::fs::write(&stale, b"").expect("stale file");
    let (_server, _incoming) = IpcServer::start(unique_endpoint()).expect("server");
    assert!(!stale.exists());
}

/// Drives `run_cli_with` against a live server, recording output.
struct TestHost {
    cwd: PathBuf,
    stdin: Option<Vec<u8>>,
    stdout: String,
    stderr: String,
}

impl CliHost for TestHost {
    fn current_directory(&self) -> PathBuf {
        self.cwd.clone()
    }
    fn executable_path(&self) -> Option<PathBuf> {
        None
    }
    fn read_standard_input(&mut self) -> Option<Vec<u8>> {
        self.stdin.take()
    }
    fn hook_owner_process_id(&self, _app_process_id: Option<i32>) -> Option<i32> {
        None
    }
    fn navigate_within_tmux(
        &mut self,
        _direction: NavigationDirection,
        _environment: &HashMap<String, String>,
    ) -> bool {
        false
    }
    fn send(&mut self, endpoint: &Endpoint, request: &Request) -> io::Result<Option<Response>> {
        send(endpoint, request)
    }
    fn write_stdout(&mut self, text: &str) {
        self.stdout.push_str(text);
    }
    fn write_stderr(&mut self, text: &str) {
        self.stderr.push_str(text);
    }
}

fn host() -> TestHost {
    TestHost { cwd: std::env::temp_dir(), stdin: None, stdout: String::new(), stderr: String::new() }
}

fn args(values: &[&str]) -> Vec<String> {
    values.iter().map(|v| v.to_string()).collect()
}

fn pane_env(endpoint: &Endpoint) -> HashMap<String, String> {
    HashMap::from([
        ("SOPRANO_APP_PID".into(), "4242".into()),
        ("SOPRANO_SOCKET".into(), endpoint.as_str().into()),
        ("SOPRANO_PANE_ID".into(), "pane-1".into()),
        ("SOPRANO_TAB_ID".into(), "tab-2".into()),
    ])
}

#[test]
fn browser_cli_prints_the_apps_output_or_error_with_swifts_exit_codes() {
    let (server, incoming) = IpcServer::start(unique_endpoint()).expect("server");
    let env = pane_env(server.endpoint());
    let app = thread::spawn(move || {
        for response in [Response::success("https://example.com"), Response::failure("Element not found: #q")]
        {
            let message = incoming.recv_timeout(Duration::from_secs(5)).expect("request");
            message.reply.expect("replier").send(&response).expect("reply");
        }
    });
    let mut ok = host();
    assert_eq!(run_cli_with(&args(&["soprano", "browser", "url"]), &env, &mut ok), CliOutcome::Exit(0));
    assert_eq!(ok.stdout, "https://example.com\n");
    let mut failed = host();
    assert_eq!(
        run_cli_with(&args(&["soprano", "browser", "click", "#q"]), &env, &mut failed),
        CliOutcome::Exit(1)
    );
    assert_eq!(failed.stderr, "Element not found: #q\n");
    app.join().expect("app thread");
}

#[test]
fn cli_subcommands_outside_a_soprano_terminal_explain_themselves() {
    let mut browser = host();
    assert_eq!(
        run_cli_with(&args(&["soprano", "browser", "url"]), &HashMap::new(), &mut browser),
        CliOutcome::Exit(2)
    );
    assert_eq!(
        browser.stderr,
        "Browser automation must run inside a Soprano terminal (SOPRANO_APP_PID is missing).\n"
    );
    let mut help = host();
    assert_eq!(run_cli_with(&args(&["soprano", "browser"]), &HashMap::new(), &mut help), CliOutcome::Exit(0));
    assert!(help.stdout.starts_with("Usage:\n  soprano browser open [url]\n"));
    let mut missing = host();
    assert_eq!(
        run_cli_with(&args(&["soprano", "md", "nope.md"]), &HashMap::new(), &mut missing),
        CliOutcome::Exit(2)
    );
    assert!(missing.stderr.starts_with("Cannot read Markdown file: "));
    let mut usage = host();
    assert_eq!(
        run_cli_with(&args(&["soprano", "notes.txt"]), &HashMap::new(), &mut usage),
        CliOutcome::Exit(2)
    );
    assert!(usage.stderr.starts_with("Usage:\n  soprano <file.md> [--new]"));
    assert_eq!(run_cli_with(&args(&["soprano"]), &HashMap::new(), &mut host()), CliOutcome::StartApp);
}

#[test]
fn markdown_cli_sends_the_resolved_file_and_times_out_without_an_app() {
    let dir = tempfile::tempdir().expect("dir");
    let file = dir.path().join("README.md");
    std::fs::write(&file, "# Hi").expect("write");
    let (server, incoming) = IpcServer::start(unique_endpoint()).expect("server");
    let env = pane_env(server.endpoint());
    let app = thread::spawn(move || {
        let message = incoming.recv_timeout(Duration::from_secs(5)).expect("request");
        let Request::OpenMarkdown { path, opens_new_pane, caller_pane_id, caller_tab_id } = &message.request
        else {
            panic!("expected OpenMarkdown");
        };
        assert!(path.ends_with("README.md"));
        assert!(*opens_new_pane);
        assert_eq!(caller_pane_id.as_deref(), Some("pane-1"));
        assert_eq!(caller_tab_id.as_deref(), Some("tab-2"));
        message.reply.expect("replier").send(&Response::success("pane-3")).expect("reply");
    });
    let mut cli = host();
    cli.cwd = dir.path().to_path_buf();
    assert_eq!(run_cli_with(&args(&["soprano", "README.md", "--new"]), &env, &mut cli), CliOutcome::Exit(0));
    assert_eq!(cli.stdout, "pane-3\n");
    app.join().expect("app thread");

    drop(server);
    let mut orphan = host();
    orphan.cwd = dir.path().to_path_buf();
    assert_eq!(run_cli_with(&args(&["soprano", "README.md"]), &env, &mut orphan), CliOutcome::Exit(1));
    assert_eq!(orphan.stderr, "Timed out waiting for Soprano to open the Markdown file.\n");
}

#[test]
fn agent_event_cli_delivers_the_hook_payload_from_standard_input() {
    let (server, incoming) = IpcServer::start(unique_endpoint()).expect("server");
    let env = pane_env(server.endpoint());
    let mut cli = host();
    cli.stdin = Some(br#"{"message":"Approve?"}"#.to_vec());
    let outcome = run_cli_with(
        &args(&["soprano", "agent-event", "needs-input", "--notify", "--message-from-stdin"]),
        &env,
        &mut cli,
    );
    assert_eq!(outcome, CliOutcome::Exit(0));
    let message = incoming.recv_timeout(Duration::from_secs(5)).expect("request");
    let Request::AgentEvent(event) = message.request else { panic!("expected an agent event") };
    assert_eq!(event.state, AgentEventState::NeedsInput);
    assert_eq!(event.message.as_deref(), Some("Approve?"));
}

#[test]
fn navigation_cli_reaches_the_app_when_tmux_does_not_take_it() {
    let (server, incoming) = IpcServer::start(unique_endpoint()).expect("server");
    let env = pane_env(server.endpoint());
    assert_eq!(
        run_cli_with(&args(&["soprano", "navigate-pane", "left"]), &env, &mut host()),
        CliOutcome::Exit(0)
    );
    let message = incoming.recv_timeout(Duration::from_secs(5)).expect("request");
    assert_eq!(
        message.request,
        Request::NavigatePane {
            pane_id: "pane-1".into(),
            tab_id: "tab-2".into(),
            direction: NavigationDirection::Left
        }
    );
}

#[test]
fn requests_serialize_as_tagged_json_lines() {
    let json = serde_json::to_value(Request::NavigationPassthrough {
        pane_id: "p".into(),
        tab_id: "t".into(),
        mode: soprano_ipc::PassthroughMode::Enable,
        source: "nvim".into(),
    })
    .expect("json");
    assert_eq!(
        json,
        serde_json::json!({"type": "navigationPassthrough", "paneId": "p", "tabId": "t", "mode": "enable", "source": "nvim"})
    );
    assert_eq!(
        serde_json::to_value(Response::failure("x")).expect("json"),
        serde_json::json!({"status": "error", "error": "x"})
    );
}
