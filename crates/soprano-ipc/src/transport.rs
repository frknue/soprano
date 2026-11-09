//! Local-socket transport between CLI invocations and the running app: a Unix domain socket on
//! macOS/Linux, a named pipe on Windows. Each connection carries one request line of JSON and,
//! for requests that expect one, one response line back.

use std::fmt;
use std::io::{self, BufRead, BufReader, Read, Write};
#[cfg(unix)]
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::Duration;

use interprocess::local_socket::prelude::*;
use interprocess::local_socket::{GenericFilePath, ListenerOptions, Name, Stream};

use crate::protocol::{Request, Response};

/// How long a CLI waits for the app's answer: Swift's `MarkdownCommand.timeout` and
/// `BrowserCommand.timeout`.
pub const REPLY_TIMEOUT: Duration = Duration::from_secs(15);

/// How long a one-way send waits for the app to take the request off the connection.
const DELIVERY_TIMEOUT: Duration = Duration::from_secs(1);

/// Longest request or response line accepted; agent messages are capped far below this.
const MAX_LINE_BYTES: u64 = 4 * 1024 * 1024;

/// How long the app waits for a connected client to finish writing its request line.
const SERVER_READ_TIMEOUT: Duration = Duration::from_secs(5);

/// Where one app instance listens: a socket path on Unix, `\\.\pipe\…` on Windows. Exported to
/// panes as `SOPRANO_SOCKET`.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Endpoint(String);

impl Endpoint {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    fn name(&self) -> io::Result<Name<'_>> {
        self.0.as_str().to_fs_name::<GenericFilePath>()
    }
}

impl fmt::Display for Endpoint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// The endpoint of the app whose process id is `pid`.
pub fn endpoint_for_pid(pid: impl fmt::Display) -> Endpoint {
    imp::endpoint_for_pid(&pid.to_string())
}

#[cfg(unix)]
mod imp {
    use super::*;
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    use std::path::Path;

    /// macOS limits `sun_path` to 104 bytes including the terminating NUL (Linux: 108).
    const SUN_PATH_LIMIT: usize = 103;

    pub(super) fn endpoint_for_pid(pid: &str) -> Endpoint {
        let file = format!("{pid}.sock");
        let path = runtime_dir().join(&file);
        if path.as_os_str().len() <= SUN_PATH_LIMIT {
            return Endpoint(path.to_string_lossy().into_owned());
        }
        Endpoint(fallback_dir().join(file).to_string_lossy().into_owned())
    }

    fn dir_name() -> String {
        // SAFETY: getuid has no preconditions and cannot fail.
        format!("soprano-{}", unsafe { libc::getuid() })
    }

    fn fallback_dir() -> PathBuf {
        Path::new("/tmp").join(dir_name())
    }

    /// `$TMPDIR/soprano-<uid>` (per-user on macOS), else `/tmp/soprano-<uid>`; a `$TMPDIR` long
    /// enough to overflow `sun_path` also falls back to `/tmp`.
    fn runtime_dir() -> PathBuf {
        match std::env::var_os("TMPDIR").filter(|value| !value.is_empty()) {
            Some(tmp) => {
                let dir = PathBuf::from(tmp).join(dir_name());
                // Leave room for `/<pid>.sock` with a 10-digit pid.
                if dir.as_os_str().len() + 16 <= SUN_PATH_LIMIT { dir } else { fallback_dir() }
            }
            None => fallback_dir(),
        }
    }

    /// Creates the socket's directory owner-only and removes sockets of app instances that
    /// exited without cleaning up.
    pub(super) fn prepare(endpoint: &Endpoint) -> io::Result<()> {
        let path = Path::new(endpoint.as_str());
        let Some(dir) = path.parent() else { return Ok(()) };
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
        if dir.file_name().is_some_and(|name| name.to_string_lossy() == dir_name()) {
            let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
            remove_stale_sockets(dir);
        }
        // Our own pid's socket can only be a leftover from a dead process that had our pid.
        let _ = std::fs::remove_file(path);
        Ok(())
    }

    fn remove_stale_sockets(dir: &Path) {
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_none_or(|ext| ext != "sock") {
                continue;
            }
            let Some(pid) = path.file_stem().and_then(|s| s.to_str()).and_then(|s| s.parse::<i32>().ok())
            else {
                continue;
            };
            if pid > 0 && !process_alive(pid) {
                let _ = std::fs::remove_file(&path);
            }
        }
    }

    fn process_alive(pid: i32) -> bool {
        // SAFETY: signal 0 only checks for existence and permission.
        if unsafe { libc::kill(pid, 0) } == 0 {
            return true;
        }
        io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
    }

    pub(super) fn cleanup(endpoint: &Endpoint) {
        let _ = std::fs::remove_file(endpoint.as_str());
    }
}

#[cfg(windows)]
mod imp {
    use super::*;

    pub(super) fn endpoint_for_pid(pid: &str) -> Endpoint {
        Endpoint(format!(r"\\.\pipe\soprano-{pid}"))
    }

    /// Named pipes vanish with their last handle; nothing is left behind to clean.
    pub(super) fn prepare(_endpoint: &Endpoint) -> io::Result<()> {
        Ok(())
    }

    pub(super) fn cleanup(_endpoint: &Endpoint) {}
}

/// A request received by the app. `reply` is present exactly when the request
/// [expects one](Request::expects_reply); dropping it unanswered makes the CLI report a timeout.
pub struct Incoming {
    pub request: Request,
    pub reply: Option<Replier>,
}

/// Sends the single response for one request back to its CLI.
pub struct Replier {
    stream: Stream,
}

impl Replier {
    pub fn send(mut self, response: &Response) -> io::Result<()> {
        let mut line = serde_json::to_vec(response).map_err(io::Error::other)?;
        line.push(b'\n');
        self.stream.write_all(&line)?;
        self.stream.flush()
    }
}

/// The app side: accepts connections on a background thread and hands each decoded request to
/// the returned channel. Malformed lines are dropped, like a notification whose `userInfo` did not
/// decode. Dropping the server stops listening and removes the socket.
pub struct IpcServer {
    endpoint: Endpoint,
    shutdown: Arc<AtomicBool>,
}

impl IpcServer {
    pub fn start(endpoint: Endpoint) -> io::Result<(IpcServer, Receiver<Incoming>)> {
        imp::prepare(&endpoint)?;
        let listener = ListenerOptions::new().name(endpoint.name()?).try_overwrite(true).create_sync()?;
        let (sender, receiver) = mpsc::channel();
        let shutdown = Arc::new(AtomicBool::new(false));
        let accept_shutdown = Arc::clone(&shutdown);
        thread::Builder::new().name("soprano-ipc-accept".into()).spawn(move || {
            for connection in listener.incoming() {
                if accept_shutdown.load(Ordering::SeqCst) {
                    break;
                }
                let Ok(stream) = connection else { continue };
                let sender = sender.clone();
                let _ = thread::Builder::new()
                    .name("soprano-ipc-connection".into())
                    .spawn(move || handle_connection(stream, &sender));
            }
        })?;
        Ok((IpcServer { endpoint, shutdown }, receiver))
    }

    pub fn endpoint(&self) -> &Endpoint {
        &self.endpoint
    }
}

impl Drop for IpcServer {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::SeqCst);
        // Wake the blocking accept so the thread sees the flag and exits.
        if let Ok(name) = self.endpoint.name() {
            let _ = Stream::connect(name);
        }
        imp::cleanup(&self.endpoint);
    }
}

fn handle_connection(stream: Stream, sender: &Sender<Incoming>) {
    let _ = stream.set_recv_timeout(Some(SERVER_READ_TIMEOUT));
    let mut line = Vec::new();
    {
        let mut reader = BufReader::new((&stream).take(MAX_LINE_BYTES));
        if reader.read_until(b'\n', &mut line).is_err() {
            return;
        }
    }
    let Ok(request) = serde_json::from_slice::<Request>(&line) else { return };
    let _ = stream.set_recv_timeout(None);
    let reply = request.expects_reply().then_some(Replier { stream });
    let _ = sender.send(Incoming { request, reply });
}

/// Sends `request` to the app at `endpoint`. Returns the app's response for requests that expect
/// one (waiting at most [`REPLY_TIMEOUT`]); `Ok(None)` for one-way requests, or when the app
/// closed the connection without answering.
pub fn send(endpoint: &Endpoint, request: &Request) -> io::Result<Option<Response>> {
    send_with_timeout(endpoint, request, REPLY_TIMEOUT)
}

pub fn send_with_timeout(
    endpoint: &Endpoint,
    request: &Request,
    timeout: Duration,
) -> io::Result<Option<Response>> {
    let mut stream = Stream::connect(endpoint.name()?)?;
    let mut line = serde_json::to_vec(request).map_err(io::Error::other)?;
    line.push(b'\n');
    stream.write_all(&line)?;
    stream.flush()?;

    let expects_reply = request.expects_reply();
    let wait = if expects_reply { timeout } else { DELIVERY_TIMEOUT };
    // The read runs on its own thread so the deadline holds on every platform, whether or not
    // the stream supports receive timeouts.
    let (result_sender, result_receiver) = mpsc::channel();
    thread::Builder::new().name("soprano-ipc-reply".into()).spawn(move || {
        let mut response = Vec::new();
        let result =
            BufReader::new((&stream).take(MAX_LINE_BYTES)).read_until(b'\n', &mut response).map(|_| response);
        let _ = result_sender.send(result);
    })?;
    let received = match result_receiver.recv_timeout(wait) {
        Ok(received) => received,
        Err(_) if !expects_reply => return Ok(None),
        Err(_) => return Err(io::Error::new(io::ErrorKind::TimedOut, "timed out waiting for the app")),
    };
    if !expects_reply {
        return Ok(None);
    }
    let response = received?;
    if response.iter().all(u8::is_ascii_whitespace) {
        return Ok(None);
    }
    serde_json::from_slice(&response)
        .map(Some)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}
