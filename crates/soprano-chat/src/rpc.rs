//! Stdio JSON-RPC 2.0 with a child process (`JSONRPCConnection.swift`).
//!
//! The Swift connection delivered on the main actor and suspended callers with `async`. Here a
//! connection runs std threads: one reads the child's stdout, one its stderr, one waits for it
//! to exit. Everything the agent says reaches the owner as [`PeerEvent`]s through a
//! [`PeerSink`], in the order the agent wrote it, and the owner answers requests with
//! [`JsonRpcPeer::reply`]. A request returns its id at once; its result arrives later as
//! [`PeerEvent::Response`].

use std::collections::HashSet;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use soprano_agents::JsonValueExt;

/// A JSON-RPC error object, from either side.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JsonRpcError {
    pub code: i64,
    pub message: String,
}

impl JsonRpcError {
    pub const METHOD_NOT_FOUND: i64 = -32_601;
    pub const INTERNAL_ERROR: i64 = -32_603;

    pub fn new(code: i64, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }

    /// Every request still waiting when the agent exits fails with this.
    pub fn closed() -> Self {
        Self::new(-32_000, "The agent exited.")
    }

    pub fn is_closed(&self) -> bool {
        *self == Self::closed()
    }
}

impl std::fmt::Display for JsonRpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} ({})", self.message, self.code)
    }
}

impl std::error::Error for JsonRpcError {}

/// What a peer tells its owner.
#[derive(Clone, Debug, PartialEq)]
pub enum PeerEvent {
    /// A notification from the agent: method and params.
    Notification { method: String, params: Value },
    /// A request from the agent; answer it exactly once with [`JsonRpcPeer::reply`] and this id.
    Request { id: Value, method: String, params: Value },
    /// The result of one of our requests, by the id [`JsonRpcPeer::request`] returned.
    Response { id: u64, result: Result<Value, JsonRpcError> },
    /// The agent went away: its exit status and the end of what it wrote to stderr. Comes after
    /// every response, so no reply is lost.
    Exit { status: i32, stderr: String },
}

/// Where a peer delivers its events: the owner's channel, tagged with the peer it came from,
/// plus a waker the owner uses to schedule processing (the UI hops onto its executor there).
#[derive(Clone)]
pub struct PeerSink {
    peer_id: u64,
    sender: Sender<(u64, PeerEvent)>,
    waker: Option<Arc<dyn Fn() + Send + Sync>>,
}

impl PeerSink {
    pub fn new(
        peer_id: u64,
        sender: Sender<(u64, PeerEvent)>,
        waker: Option<Arc<dyn Fn() + Send + Sync>>,
    ) -> Self {
        Self { peer_id, sender, waker }
    }

    pub fn peer_id(&self) -> u64 {
        self.peer_id
    }

    pub fn send(&self, event: PeerEvent) {
        if self.sender.send((self.peer_id, event)).is_ok()
            && let Some(waker) = &self.waker
        {
            waker();
        }
    }
}

/// What a chat session needs from the process it talks to, so tests can stand in for a real
/// agent.
pub trait JsonRpcPeer: Send {
    /// Starts the agent; its events go to `sink`.
    fn start(&mut self, sink: PeerSink) -> std::io::Result<()>;
    /// Sends a request and returns its id; the result arrives as [`PeerEvent::Response`].
    /// Fails with [`JsonRpcError::closed`] once the agent exited.
    fn request(&mut self, method: &str, params: Value) -> Result<u64, JsonRpcError>;
    fn notify(&mut self, method: &str, params: Value);
    /// Answers a [`PeerEvent::Request`].
    fn reply(&mut self, id: Value, result: Result<Value, JsonRpcError>);
    /// Asks the agent to exit (SIGTERM), and kills it if it is still running after the grace
    /// period.
    fn terminate(&mut self);
    /// Whether the agent's process is gone (or never started), so another process can open the
    /// same conversation.
    fn has_exited(&self) -> bool;
}

/// Splits a byte stream into lines, without their newlines; empty lines are dropped.
#[derive(Default)]
pub struct LineSplitter {
    buffer: Vec<u8>,
}

impl LineSplitter {
    /// The complete lines `chunk` finishes.
    pub fn append(&mut self, chunk: &[u8]) -> Vec<Vec<u8>> {
        self.buffer.extend_from_slice(chunk);
        let mut lines = Vec::new();
        while let Some(newline) = self.buffer.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = self.buffer.drain(..=newline).take(newline).collect();
            if !line.is_empty() {
                lines.push(line);
            }
        }
        lines
    }
}

/// The last characters an agent wrote to stderr.
pub struct StderrTail {
    limit: usize,
    data: Mutex<Vec<u8>>,
}

impl StderrTail {
    pub fn new(limit: usize) -> Self {
        Self { limit, data: Mutex::new(Vec::new()) }
    }

    pub fn append(&self, chunk: &[u8]) {
        let mut data = lock(&self.data);
        data.extend_from_slice(chunk);
        if data.len() > self.limit * 2 {
            let cut = data.len() - self.limit;
            data.drain(..cut);
        }
    }

    pub fn text(&self) -> String {
        let data = lock(&self.data);
        let string = String::from_utf8_lossy(&data);
        let trimmed = string.trim();
        let count = trimmed.chars().count();
        if count > self.limit {
            trimmed.chars().skip(count - self.limit).collect()
        } else {
            trimmed.to_owned()
        }
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

struct Shared {
    stdin: Mutex<Option<ChildStdin>>,
    pending: Mutex<HashSet<u64>>,
    exited: AtomicBool,
    exit_signal: (Mutex<bool>, Condvar),
    terminate_requested: Mutex<Option<Instant>>,
    pid: Mutex<Option<u32>>,
}

impl Shared {
    fn write_line(&self, message: &Value) {
        if self.exited.load(Ordering::SeqCst) {
            return;
        }
        let Ok(mut line) = serde_json::to_vec(message) else { return };
        line.push(b'\n');
        if let Some(stdin) = lock(&self.stdin).as_mut() {
            // A write after the agent exited must fail rather than kill Soprano (Rust ignores
            // SIGPIPE); the exit handler fails whatever is still pending.
            let _ = stdin.write_all(&line).and_then(|()| stdin.flush());
        }
    }
}

/// A child process speaking JSON-RPC 2.0 as newline-delimited JSON on its stdin and stdout, the
/// framing the Agent Client Protocol uses. Lines that are not JSON-RPC messages, such as a
/// banner a wrapper prints, are skipped.
pub struct JsonRpcConnection {
    argv: Vec<String>,
    cwd: Option<PathBuf>,
    env: Option<Vec<(String, String)>>,
    /// How long an agent gets to exit after SIGTERM before it is killed.
    exit_grace_period: Duration,
    shared: Arc<Shared>,
    next_request_id: u64,
    started: bool,
    threads: Vec<JoinHandle<()>>,
}

impl JsonRpcConnection {
    /// Characters of stderr kept to explain an unexpected exit.
    pub const STDERR_LIMIT: usize = 4_000;
    pub const DEFAULT_EXIT_GRACE_PERIOD: Duration = Duration::from_secs(3);

    /// `argv[0]` is the executable. `env`, when given, replaces the whole environment.
    pub fn new(argv: Vec<String>, cwd: Option<PathBuf>, env: Option<Vec<(String, String)>>) -> Self {
        Self::with_grace_period(argv, cwd, env, Self::DEFAULT_EXIT_GRACE_PERIOD)
    }

    pub fn with_grace_period(
        argv: Vec<String>,
        cwd: Option<PathBuf>,
        env: Option<Vec<(String, String)>>,
        exit_grace_period: Duration,
    ) -> Self {
        Self {
            argv,
            cwd,
            env,
            exit_grace_period,
            shared: Arc::new(Shared {
                stdin: Mutex::new(None),
                pending: Mutex::new(HashSet::new()),
                exited: AtomicBool::new(false),
                exit_signal: (Mutex::new(false), Condvar::new()),
                terminate_requested: Mutex::new(None),
                pid: Mutex::new(None),
            }),
            next_request_id: 1,
            started: false,
            threads: Vec::new(),
        }
    }

    pub fn process_id(&self) -> Option<u32> {
        *lock(&self.shared.pid)
    }

    /// Blocks until the process is gone. Returns at once for a process that never started.
    pub fn wait_for_exit(&self) {
        if !self.started {
            return;
        }
        let (exited, signal) = &self.shared.exit_signal;
        let mut done = lock(exited);
        while !*done {
            done = signal.wait(done).unwrap_or_else(std::sync::PoisonError::into_inner);
        }
    }

    fn spawn_child(&self) -> std::io::Result<Child> {
        let Some((program, arguments)) = self.argv.split_first() else {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "empty command line"));
        };
        let mut command = Command::new(program);
        command.args(arguments).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        if let Some(cwd) = &self.cwd {
            command.current_dir(cwd);
        }
        if let Some(env) = &self.env {
            command.env_clear();
            command.envs(env.iter().map(|(k, v)| (k, v)));
        }
        command.spawn()
    }
}

impl JsonRpcPeer for JsonRpcConnection {
    fn start(&mut self, sink: PeerSink) -> std::io::Result<()> {
        let mut child = self.spawn_child()?;
        self.started = true;
        *lock(&self.shared.pid) = Some(child.id());
        *lock(&self.shared.stdin) = child.stdin.take();
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        let tail = Arc::new(StderrTail::new(Self::STDERR_LIMIT));

        let reader = stdout.map(|stdout| {
            let shared = Arc::clone(&self.shared);
            let sink = sink.clone();
            std::thread::spawn(move || read_messages(stdout, &shared, &sink))
        });
        let stderr_reader = stderr.map(|mut stderr| {
            let tail = Arc::clone(&tail);
            std::thread::spawn(move || {
                let mut buffer = [0u8; 4096];
                while let Ok(count) = stderr.read(&mut buffer) {
                    if count == 0 {
                        break;
                    }
                    tail.append(&buffer[..count]);
                }
            })
        });

        let shared = Arc::clone(&self.shared);
        let grace = self.exit_grace_period;
        let waiter = std::thread::spawn(move || {
            let status = wait_child(&mut child, &shared, grace);
            // After the output reader's last delivery, so no reply is lost.
            if let Some(reader) = reader {
                let _ = reader.join();
            }
            if let Some(stderr_reader) = stderr_reader {
                let _ = stderr_reader.join();
            }
            shared.exited.store(true, Ordering::SeqCst);
            *lock(&shared.stdin) = None;
            let waiting: Vec<u64> = lock(&shared.pending).drain().collect();
            for id in waiting {
                sink.send(PeerEvent::Response { id, result: Err(JsonRpcError::closed()) });
            }
            {
                let (exited, signal) = &shared.exit_signal;
                *lock(exited) = true;
                signal.notify_all();
            }
            sink.send(PeerEvent::Exit { status, stderr: tail.text() });
        });
        self.threads.push(waiter);
        Ok(())
    }

    fn request(&mut self, method: &str, params: Value) -> Result<u64, JsonRpcError> {
        if !self.started || self.shared.exited.load(Ordering::SeqCst) {
            return Err(JsonRpcError::closed());
        }
        let id = self.next_request_id;
        self.next_request_id += 1;
        lock(&self.shared.pending).insert(id);
        self.shared.write_line(&json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
        Ok(id)
    }

    fn notify(&mut self, method: &str, params: Value) {
        self.shared.write_line(&json!({"jsonrpc": "2.0", "method": method, "params": params}));
    }

    fn reply(&mut self, id: Value, result: Result<Value, JsonRpcError>) {
        self.shared.write_line(&reply_message(id, result));
    }

    fn terminate(&mut self) {
        if !self.started || self.shared.exited.load(Ordering::SeqCst) {
            return;
        }
        let mut requested = lock(&self.shared.terminate_requested);
        if requested.is_none() {
            *requested = Some(Instant::now());
        }
    }

    fn has_exited(&self) -> bool {
        !self.started || self.shared.exited.load(Ordering::SeqCst)
    }
}

impl Drop for JsonRpcConnection {
    fn drop(&mut self) {
        // The threads end with the process; never block the owner on them.
        self.threads.clear();
    }
}

fn reply_message(id: Value, result: Result<Value, JsonRpcError>) -> Value {
    match result {
        Ok(value) => json!({"jsonrpc": "2.0", "id": id, "result": value}),
        Err(error) => {
            json!({"jsonrpc": "2.0", "id": id, "error": {"code": error.code, "message": error.message}})
        }
    }
}

fn read_messages(stdout: impl Read, shared: &Shared, sink: &PeerSink) {
    let mut reader = BufReader::new(stdout);
    let mut splitter = LineSplitter::default();
    loop {
        let chunk = match reader.fill_buf() {
            Ok([]) | Err(_) => return,
            Ok(chunk) => chunk.to_vec(),
        };
        reader.consume(chunk.len());
        for line in splitter.append(&chunk) {
            receive(&line, shared, sink);
        }
    }
}

fn receive(line: &[u8], shared: &Shared, sink: &PeerSink) {
    let Ok(message) = serde_json::from_slice::<Value>(line) else { return };
    if !message.is_object() {
        return;
    }
    let id = message.get("id").filter(|id| !id.is_null()).cloned();
    if let Some(method) = message.get("method").and_then(Value::as_str) {
        let params = message.get("params").cloned().unwrap_or(Value::Null);
        match id {
            None => sink.send(PeerEvent::Notification { method: method.to_owned(), params }),
            Some(id) => sink.send(PeerEvent::Request { id, method: method.to_owned(), params }),
        }
        return;
    }
    let Some(request_id) = id.as_ref().and_then(JsonValueExt::int).and_then(|i| u64::try_from(i).ok()) else {
        return;
    };
    if !lock(&shared.pending).remove(&request_id) {
        return;
    }
    let result = match message.get("error") {
        Some(error) => Err(JsonRpcError::new(
            error.get("code").and_then(JsonValueExt::int).unwrap_or(JsonRpcError::INTERNAL_ERROR),
            error.get("message").and_then(Value::as_str).unwrap_or("Unknown error"),
        )),
        None => Ok(message.get("result").cloned().unwrap_or(Value::Null)),
    };
    sink.send(PeerEvent::Response { id: request_id, result });
}

/// Waits for the child, sending SIGTERM when asked and SIGKILL once the grace period passed.
/// Returns the exit code, or the signal number for a process a signal ended (what
/// `Process.terminationStatus` reports).
fn wait_child(child: &mut Child, shared: &Shared, grace: Duration) -> i32 {
    let mut signalled = false;
    let mut killed = false;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return exit_code(status),
            Ok(None) => {}
            Err(_) => return -1,
        }
        let requested = *lock(&shared.terminate_requested);
        if let Some(at) = requested {
            if !signalled {
                signalled = true;
                platform::terminate(child);
            } else if !killed && at.elapsed() >= grace {
                killed = true;
                let _ = child.kill();
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn exit_code(status: std::process::ExitStatus) -> i32 {
    if let Some(code) = status.code() {
        return code;
    }
    platform::signal_of(status).unwrap_or(-1)
}

#[cfg(unix)]
mod platform {
    use std::os::unix::process::ExitStatusExt;
    use std::process::Child;

    /// SIGTERM, which lets the agent save its session before it exits.
    pub fn terminate(child: &Child) {
        if let Ok(pid) = libc::pid_t::try_from(child.id()) {
            // SAFETY: `kill` takes a pid and a signal number and touches no memory.
            unsafe {
                libc::kill(pid, libc::SIGTERM);
            }
        }
    }

    pub fn signal_of(status: std::process::ExitStatus) -> Option<i32> {
        status.signal()
    }
}

#[cfg(not(unix))]
mod platform {
    use std::process::Child;

    /// Windows has no SIGTERM for a console child: it is ended at once (TerminateProcess).
    pub fn terminate(child: &mut Child) {
        let _ = child.kill();
    }

    pub fn signal_of(_status: std::process::ExitStatus) -> Option<i32> {
        None
    }
}
