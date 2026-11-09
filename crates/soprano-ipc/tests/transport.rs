use std::collections::HashMap;
use std::io;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::thread;
use std::time::Duration;

use soprano_ipc::{
    AgentEventState, CliHost, CliOutcome, Endpoint, IpcServer, Request, Response, endpoint_for_pid,
    run_cli_with, send, send_with_timeout,
};
use soprano_types::NavigationDirection;

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

#[test]
fn a_reply_far_larger_than_the_request_cap_still_arrives_whole() {
    let (server, incoming) = IpcServer::start(unique_endpoint()).expect("server");
    let big = "x".repeat(16 * 1024 * 1024);
    let expected = big.clone();
    let app = thread::spawn(move || {
        let message = incoming.recv_timeout(Duration::from_secs(5)).expect("request");
        message.reply.expect("replier").send(&Response::success(big)).expect("reply");
    });
    let response = send(server.endpoint(), &browser_request()).expect("send");
    assert_eq!(response, Some(Response::success(expected)));
    app.join().expect("app thread");
}

#[test]
fn an_oversized_request_gets_an_error_reply_instead_of_a_timeout() {
    let (server, incoming) = IpcServer::start(unique_endpoint()).expect("server");
    let request = Request::Browser {
        command: "eval".into(),
        arguments: vec!["y".repeat(soprano_ipc::transport::MAX_REQUEST_BYTES + 1)],
        target_pane_id: None,
        caller_pane_id: None,
        caller_tab_id: None,
    };
    let started = std::time::Instant::now();
    let response = send(server.endpoint(), &request).expect("send");
    assert_eq!(response, Some(Response::failure(soprano_ipc::transport::REQUEST_TOO_LARGE)));
    assert!(started.elapsed() < Duration::from_secs(5));
    assert!(incoming.try_recv().is_err());
}

#[test]
fn a_line_that_does_not_decode_gets_an_error_reply() {
    use interprocess::local_socket::prelude::*;
    use interprocess::local_socket::{GenericFilePath, Stream};
    use std::io::{BufRead, BufReader, Write};

    let (server, _incoming) = IpcServer::start(unique_endpoint()).expect("server");
    let name = server.endpoint().as_str().to_fs_name::<GenericFilePath>().expect("name");
    let mut stream = Stream::connect(name).expect("connect");
    stream.write_all(b"{not json}\n").expect("write");
    let mut line = String::new();
    BufReader::new(&stream).read_line(&mut line).expect("read");
    let response: Response = serde_json::from_str(&line).expect("response");
    assert_eq!(response, Response::failure(soprano_ipc::transport::REQUEST_UNREADABLE));
}

#[test]
fn a_client_that_never_writes_does_not_stop_other_requests() {
    use interprocess::local_socket::prelude::*;
    use interprocess::local_socket::{GenericFilePath, Stream};

    let (server, incoming) = IpcServer::start(unique_endpoint()).expect("server");
    let name = server.endpoint().as_str().to_fs_name::<GenericFilePath>().expect("name");
    let _silent = Stream::connect(name).expect("connect");
    let request = Request::NavigatePane {
        pane_id: "p".into(),
        tab_id: "t".into(),
        direction: NavigationDirection::Down,
    };
    send(server.endpoint(), &request).expect("send");
    assert_eq!(incoming.recv_timeout(Duration::from_secs(5)).expect("request").request, request);
}

#[cfg(unix)]
#[test]
fn a_socket_directory_that_is_not_private_to_this_user_is_refused() {
    use soprano_ipc::transport::verify_private_dir;
    use std::os::unix::fs::PermissionsExt;

    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    let root = tempfile::tempdir().expect("dir");
    let private = root.path().join("private");
    std::fs::create_dir(&private).expect("mkdir");
    std::fs::set_permissions(&private, std::fs::Permissions::from_mode(0o700)).expect("chmod");
    assert!(verify_private_dir(&private, uid).is_ok());
    // Someone else's directory.
    assert!(verify_private_dir(&private, uid.wrapping_add(1)).is_err());
    // A symlink to a private directory.
    let link = root.path().join("link");
    std::os::unix::fs::symlink(&private, &link).expect("symlink");
    assert!(verify_private_dir(&link, uid).is_err());
    // Readable by others.
    let open = root.path().join("open");
    std::fs::create_dir(&open).expect("mkdir");
    std::fs::set_permissions(&open, std::fs::Permissions::from_mode(0o755)).expect("chmod");
    assert!(verify_private_dir(&open, uid).is_err());
    // A plain file.
    let file = root.path().join("file");
    std::fs::write(&file, b"").expect("write");
    assert!(verify_private_dir(&file, uid).is_err());
}

#[test]
fn non_unicode_arguments_and_environment_are_converted_instead_of_panicking() {
    #[cfg(unix)]
    let bad = {
        use std::os::unix::ffi::OsStringExt;
        std::ffi::OsString::from_vec(vec![b'n', 0xE9, b'.', b't', b'x', b't'])
    };
    #[cfg(windows)]
    let bad = {
        use std::os::windows::ffi::OsStringExt;
        std::ffi::OsString::from_wide(&[0x6E, 0xD800, 0x2E])
    };
    let (args, env) = soprano_ipc::cli::lossy_invocation(
        [std::ffi::OsString::from("soprano"), bad.clone()],
        [(std::ffi::OsString::from("LATIN1"), bad)],
    );
    assert_eq!(args.len(), 2);
    assert!(args[1].contains('\u{FFFD}'));
    assert!(env["LATIN1"].contains('\u{FFFD}'));
}

#[cfg(unix)]
#[test]
fn the_socket_lives_in_a_short_per_user_directory_and_is_removed_on_drop() {
    let endpoint = endpoint_for_pid(4_294_967_295u32);
    assert!(endpoint.as_str().len() <= 103, "{endpoint}");
    assert!(endpoint.as_str().ends_with("/4294967295.sock"));
    // SAFETY: getuid has no preconditions.
    let uid_dir = format!("soprano-{}", unsafe { libc::getuid() });
    let xdg = cfg!(target_os = "linux") && std::env::var_os("XDG_RUNTIME_DIR").is_some_and(|d| !d.is_empty());
    assert!(xdg || endpoint.as_str().contains(&uid_dir));
    let dir = PathBuf::from(endpoint.as_str()).parent().expect("dir").to_path_buf();

    let (server, _incoming) = IpcServer::start(unique_endpoint()).expect("server");
    // SAFETY: getuid has no preconditions.
    soprano_ipc::transport::verify_private_dir(&dir, unsafe { libc::getuid() }).expect("private dir");

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

#[test]
fn run_cli_accepts_both_the_string_and_os_string_forms_main_passes() {
    // Type-checks only: `main` may pass collected `String`s or `args_os()`/`vars_os()` directly.
    let _strings: fn(&Vec<String>, &HashMap<String, String>) -> CliOutcome =
        |args, env| soprano_ipc::run_cli(args, env);
    let _os: fn() -> CliOutcome = || soprano_ipc::run_cli(std::env::args_os(), std::env::vars_os());
}
