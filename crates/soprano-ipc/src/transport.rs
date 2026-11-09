//! Local-socket transport between CLI invocations and the running app: a Unix domain socket on
//! macOS/Linux, a named pipe on Windows. Each connection carries one request line of JSON and,
//! for requests that expect one, one response line back.

use std::fmt;
use std::io::{self, Read, Write};
#[cfg(unix)]
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::{Duration, Instant};

use interprocess::local_socket::prelude::*;
use interprocess::local_socket::{GenericFilePath, ListenerOptions, Name, Stream};

use crate::protocol::{Request, Response};

/// How long a CLI waits for the app's answer: Swift's `MarkdownCommand.timeout` and
/// `BrowserCommand.timeout`.
pub const REPLY_TIMEOUT: Duration = Duration::from_secs(15);

/// How long a one-way send waits for the app to take the request off the connection.
const DELIVERY_TIMEOUT: Duration = Duration::from_secs(1);

/// Longest request line the app accepts; agent messages are capped far below this. A longer
/// request is answered with [`REQUEST_TOO_LARGE`] rather than dropped.
pub const MAX_REQUEST_BYTES: usize = 4 * 1024 * 1024;

/// Longest response line a CLI reads. Browser replies (`snapshot`, `eval`, `get html`) can be
/// large; this only guards against an endless stream.
pub const MAX_RESPONSE_BYTES: usize = 1024 * 1024 * 1024;

/// How long the app waits for a connected client to finish writing its request line.
const SERVER_READ_TIMEOUT: Duration = Duration::from_secs(5);

/// The error the app answers an oversized request with.
pub const REQUEST_TOO_LARGE: &str = "The request is too large for Soprano (over 4 MiB).";

/// The error the app answers a request line it cannot decode with.
pub const REQUEST_UNREADABLE: &str = "Soprano could not read the request.";

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
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
    use std::path::Path;

    /// macOS limits `sun_path` to 104 bytes including the terminating NUL (Linux: 108).
    const SUN_PATH_LIMIT: usize = 103;

    /// Room for `/<pid>.sock` with a 10-digit pid.
    const FILE_ROOM: usize = 16;

    pub(super) fn endpoint_for_pid(pid: &str) -> Endpoint {
        let file = format!("{pid}.sock");
        let path = runtime_dir().join(&file);
        if path.as_os_str().len() <= SUN_PATH_LIMIT {
            return Endpoint(path.to_string_lossy().into_owned());
        }
        Endpoint(fallback_dir().join(file).to_string_lossy().into_owned())
    }

    fn uid() -> libc::uid_t {
        // SAFETY: getuid has no preconditions and cannot fail.
        unsafe { libc::getuid() }
    }

    fn dir_name() -> String {
        format!("soprano-{}", uid())
    }

    fn fallback_dir() -> PathBuf {
        Path::new("/tmp").join(dir_name())
    }

    fn fits(dir: &Path) -> bool {
        dir.as_os_str().len() + FILE_ROOM <= SUN_PATH_LIMIT
    }

    /// Linux: `$XDG_RUNTIME_DIR/soprano` (already private to the user). Otherwise
    /// `$TMPDIR/soprano-<uid>` (per-user on macOS), else `/tmp/soprano-<uid>`. A directory long
    /// enough to overflow `sun_path` falls back to `/tmp`.
    fn runtime_dir() -> PathBuf {
        let env_dir = |key: &str| std::env::var_os(key).map(PathBuf::from).filter(|dir| dir.is_absolute());
        if cfg!(target_os = "linux")
            && let Some(runtime) = env_dir("XDG_RUNTIME_DIR")
        {
            let dir = runtime.join("soprano");
            if fits(&dir) {
                return dir;
            }
        }
        match env_dir("TMPDIR") {
            Some(tmp) => {
                let dir = tmp.join(dir_name());
                if fits(&dir) { dir } else { fallback_dir() }
            }
            None => fallback_dir(),
        }
    }

    /// Creates the socket's directory owner-only, refuses one that is not a real directory owned
    /// by this user with mode 0700 (another local user could pre-create it and intercept or fake
    /// traffic), and removes sockets of app instances that exited without cleaning up.
    pub(super) fn prepare(endpoint: &Endpoint) -> io::Result<()> {
        let path = Path::new(endpoint.as_str());
        let Some(dir) = path.parent() else { return Ok(()) };
        if let Some(parent) = dir.parent() {
            std::fs::create_dir_all(parent)?;
        }
        match std::fs::DirBuilder::new().mode(0o700).create(dir) {
            // The umask may have narrowed the mode further; a directory we just made is ours.
            Ok(()) => std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
        verify_private_dir(dir, uid())?;
        remove_stale_sockets(dir);
        // Our own pid's socket can only be a leftover from a dead process that had our pid.
        let _ = std::fs::remove_file(path);
        Ok(())
    }

    /// `lstat` check: a directory (not a symlink to one) owned by `uid` with mode exactly 0700.
    pub(super) fn verify_private_dir(dir: &Path, uid: libc::uid_t) -> io::Result<()> {
        let metadata = std::fs::symlink_metadata(dir)?;
        let refuse = |reason: &str| {
            Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!("refusing socket directory {}: {reason}", dir.display()),
            ))
        };
        if !metadata.file_type().is_dir() {
            return refuse("not a directory");
        }
        if metadata.uid() != uid {
            return refuse("owned by another user");
        }
        if metadata.mode() & 0o777 != 0o700 {
            return refuse("permissions are not 0700");
        }
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

/// `lstat` check of a socket directory: a real directory owned by `uid` with mode 0700.
#[cfg(unix)]
pub fn verify_private_dir(dir: &std::path::Path, uid: u32) -> io::Result<()> {
    imp::verify_private_dir(dir, uid)
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
        write_line(&mut self.stream, response)
    }
}

fn write_line(stream: &mut Stream, value: &impl serde::Serialize) -> io::Result<()> {
    let mut line = serde_json::to_vec(value).map_err(io::Error::other)?;
    line.push(b'\n');
    stream.write_all(&line)?;
    stream.flush()
}

/// The app side: accepts connections on a background thread and hands each decoded request to
/// the returned channel. A line that is too long or does not decode is answered with an error
/// response so the CLI does not wait out its timeout. Dropping the server stops listening and
/// removes the socket.
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
            let mut backoff = AcceptBackoff::default();
            for connection in listener.incoming() {
                if accept_shutdown.load(Ordering::SeqCst) {
                    break;
                }
                let stream = match connection {
                    Ok(stream) => {
                        backoff.reset();
                        stream
                    }
                    Err(_) => {
                        // e.g. out of file descriptors: wait instead of spinning a core.
                        thread::sleep(backoff.next_delay());
                        continue;
                    }
                };
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

/// Exponential delay between failing accepts: 10 ms doubling to 1 s, reset by a success.
#[derive(Debug)]
pub struct AcceptBackoff {
    delay: Duration,
}

impl AcceptBackoff {
    const FIRST: Duration = Duration::from_millis(10);
    const MAX: Duration = Duration::from_secs(1);

    pub fn next_delay(&mut self) -> Duration {
        let delay = self.delay;
        self.delay = (self.delay * 2).min(Self::MAX);
        delay
    }

    pub fn reset(&mut self) {
        self.delay = Self::FIRST;
    }
}

impl Default for AcceptBackoff {
    fn default() -> Self {
        Self { delay: Self::FIRST }
    }
}

fn handle_connection(mut stream: Stream, sender: &Sender<Incoming>) {
    let line = read_line(&stream, MAX_REQUEST_BYTES, Instant::now() + SERVER_READ_TIMEOUT);
    if stream.set_nonblocking(false).is_err() {
        return;
    }
    let line = match line {
        Ok(Line::Complete(line)) => line,
        Ok(Line::TooLong) => {
            let _ = write_line(&mut stream, &Response::failure(REQUEST_TOO_LARGE));
            return;
        }
        // A client that never finished writing, or vanished.
        Err(_) => return,
    };
    let Ok(request) = serde_json::from_slice::<Request>(&line) else {
        let _ = write_line(&mut stream, &Response::failure(REQUEST_UNREADABLE));
        return;
    };
    let reply = request.expects_reply().then_some(Replier { stream });
    let _ = sender.send(Incoming { request, reply });
}

enum Line {
    /// The bytes before the first newline (or before EOF).
    Complete(Vec<u8>),
    TooLong,
}

/// Reads one line by polling the stream in non-blocking mode until `deadline`. Polling holds the
/// deadline on every platform: named pipes on Windows ignore receive timeouts, so a blocking read
/// on a client that never writes would hold its thread forever. Leaves the stream non-blocking.
fn read_line(stream: &Stream, cap: usize, deadline: Instant) -> io::Result<Line> {
    stream.set_nonblocking(true)?;
    let mut line = Vec::new();
    let mut chunk = [0u8; 64 * 1024];
    let mut pause = Duration::from_millis(1);
    loop {
        match (&*stream).read(&mut chunk) {
            Ok(0) => return Ok(Line::Complete(line)),
            Ok(read) => {
                let chunk = &chunk[..read];
                if let Some(end) = chunk.iter().position(|byte| *byte == b'\n') {
                    line.extend_from_slice(&chunk[..end]);
                    return Ok(if line.len() > cap { Line::TooLong } else { Line::Complete(line) });
                }
                line.extend_from_slice(chunk);
                if line.len() > cap {
                    return Ok(Line::TooLong);
                }
                pause = Duration::from_millis(1);
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                let now = Instant::now();
                if now >= deadline {
                    return Err(io::Error::new(io::ErrorKind::TimedOut, "timed out waiting for a line"));
                }
                thread::sleep(pause.min(deadline - now));
                pause = (pause * 2).min(Duration::from_millis(20));
            }
            Err(error) => return Err(error),
        }
    }
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
    // The app answers an oversized request early and closes; its answer still waits to be read.
    let written = write_line(&mut stream, request);

    let expects_reply = request.expects_reply();
    let wait = if expects_reply { timeout } else { DELIVERY_TIMEOUT };
    let received = read_line(&stream, MAX_RESPONSE_BYTES, Instant::now() + wait);
    if !expects_reply {
        return written.map(|()| None);
    }
    let response = match received {
        Ok(Line::Complete(response)) => response,
        Ok(Line::TooLong) => {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "the response is too large"));
        }
        Err(error) => return Err(written.err().unwrap_or(error)),
    };
    if response.iter().all(u8::is_ascii_whitespace) {
        return written.map(|()| None);
    }
    serde_json::from_slice(&response)
        .map(Some)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failing_accepts_back_off_exponentially_up_to_a_second_and_reset_on_success() {
        let mut backoff = AcceptBackoff::default();
        let delays: Vec<_> = (0..9).map(|_| backoff.next_delay().as_millis()).collect();
        assert_eq!(delays, vec![10, 20, 40, 80, 160, 320, 640, 1000, 1000]);
        backoff.reset();
        assert_eq!(backoff.next_delay(), Duration::from_millis(10));
    }
}
