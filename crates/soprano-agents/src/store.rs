//! Following agent transcripts for the dashboard (`AgentTranscriptStore.swift`).
//!
//! The Swift store parsed on a serial background queue and delivered on the main actor, driven
//! by the dashboard's one-second refresh. Here a worker thread does the reading, `notify`
//! watches the transcripts' directories so appends are read at once, and a polling thread
//! (the dashboard's one-second refresh) catches whatever the watcher misses, such as a
//! transcript that does not exist yet. Change callbacks run on the worker thread; the UI hops
//! them onto its own executor.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime};

use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use soprano_types::AgentConversation;

use crate::claude::ClaudeTranscriptDecoder;
use crate::codex::CodexRolloutDecoder;
use crate::omp::OmpSessionDecoder;
use crate::opencode_reader::OpenCodeTranscriptReader;
use crate::timeline::{AgentTimeline, AgentTranscriptDecoding, AgentTranscriptEntry, AgentTranscriptFormat};

/// Where one agent's conversation is written, in which CLI's format.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct AgentTranscriptSource {
    pub format: AgentTranscriptFormat,
    pub conversation_id: String,
    /// The file the agent's hooks reported: the transcript for JSON Lines CLIs, the SQLite
    /// database for OpenCode. Located from the id when `None`.
    pub path: Option<String>,
}

impl AgentTranscriptSource {
    /// The transcript of an agent's current conversation, when its CLI writes one the dashboard
    /// can read.
    pub fn new(profile_id: &str, conversation: Option<&AgentConversation>) -> Option<Self> {
        let format = AgentTranscriptFormat::from_profile_id(profile_id)?;
        let conversation = conversation?;
        if !AgentConversation::valid_id(&conversation.id) {
            return None;
        }
        Some(Self {
            format,
            conversation_id: conversation.id.clone(),
            path: conversation.transcript_path.clone(),
        })
    }

    /// A reader for this transcript; `home` is where the CLIs keep their data.
    pub fn make_reader(&self, home: &Path) -> Box<dyn AgentTranscriptReader> {
        match self.format {
            AgentTranscriptFormat::ClaudeCode => {
                Box::new(TranscriptFollower::new(self.clone(), home, || {
                    Box::new(ClaudeTranscriptDecoder::new())
                }))
            }
            AgentTranscriptFormat::Codex => {
                Box::new(TranscriptFollower::new(self.clone(), home, || Box::new(CodexRolloutDecoder::new())))
            }
            AgentTranscriptFormat::Omp => Box::new(TranscriptFollower::new(self.clone(), home, || {
                Box::new(OmpSessionDecoder::new(None))
            })),
            AgentTranscriptFormat::OpenCode => Box::new(OpenCodeTranscriptReader::new(self.clone(), home)),
        }
    }
}

/// Reads one agent's conversation for the dashboard, whatever its CLI keeps it in. Only the
/// store's worker calls a reader.
pub trait AgentTranscriptReader: Send {
    fn source(&self) -> &AgentTranscriptSource;
    /// The timeline after reading what changed, or `None` when nothing visible changed or the
    /// transcript is missing.
    fn read_appended(&mut self) -> Option<AgentTimeline>;
    /// The file whose changes mean new content, once it is known, so the store can watch it.
    fn watched_path(&self) -> Option<PathBuf>;
}

type ChangeCallback = Arc<dyn Fn(&str) + Send + Sync>;

#[derive(Default)]
struct Shared {
    sources: HashMap<String, AgentTranscriptSource>,
    timelines: HashMap<String, AgentTimeline>,
}

#[derive(Debug, PartialEq)]
enum Command {
    Track(HashMap<String, AgentTranscriptSource>),
    Read(Option<Vec<String>>),
    FileChanged(PathBuf),
    Stop,
}

/// Follows the transcripts of the agents on the Agent Dashboard. A JSON Lines file is read
/// from its end when first seen and afterwards only for the bytes appended since, an OpenCode
/// database only for the messages that changed; parsing runs on a worker thread. The dashboard
/// owns the store, so nothing is read while it is closed (dropping the store stops its threads).
pub struct AgentTranscriptStore {
    shared: Arc<Mutex<Shared>>,
    on_change: Arc<Mutex<Option<ChangeCallback>>>,
    commands: Sender<Command>,
    worker: Option<JoinHandle<()>>,
    poller: Option<(Sender<()>, JoinHandle<()>)>,
    stopped: Arc<AtomicBool>,
}

impl AgentTranscriptStore {
    /// The interval the dashboard refreshes at.
    pub const DEFAULT_POLL_INTERVAL: Duration = Duration::from_secs(1);

    /// A store reading the CLIs' data under the user's home directory.
    pub fn new() -> Self {
        // No home at all: the CLIs' folders cannot be found, but reported paths still work.
        Self::with_home(dirs::home_dir().unwrap_or_default())
    }

    /// A store reading the CLIs' data under `home`, with no polling until
    /// [`start_polling`](Self::start_polling).
    pub fn with_home(home: PathBuf) -> Self {
        let shared = Arc::new(Mutex::new(Shared::default()));
        let on_change: Arc<Mutex<Option<ChangeCallback>>> = Arc::new(Mutex::new(None));
        let (commands, receiver) = mpsc::channel();
        let stopped = Arc::new(AtomicBool::new(false));
        let worker = {
            let shared = Arc::clone(&shared);
            let on_change = Arc::clone(&on_change);
            let sender = commands.clone();
            let stopped = Arc::clone(&stopped);
            std::thread::Builder::new()
                .name("soprano-agent-transcripts".into())
                .spawn(move || Worker::new(home, shared, on_change, sender, stopped).run(receiver))
                .ok()
        };
        Self { shared, on_change, commands, worker, poller: None, stopped }
    }

    /// Called with a dashboard entry id whenever that agent's timeline changed. Runs on the
    /// store's worker thread.
    pub fn set_on_change(&self, callback: impl Fn(&str) + Send + Sync + 'static) {
        *lock(&self.on_change) = Some(Arc::new(callback));
    }

    /// Calls [`refresh`](Self::refresh) every `interval` until the store is dropped; a file that
    /// did not grow is only opened and measured.
    pub fn start_polling(&mut self, interval: Duration) {
        if self.poller.is_some() {
            return;
        }
        let (stop, stopped) = mpsc::channel::<()>();
        let commands = self.commands.clone();
        let handle =
            std::thread::Builder::new().name("soprano-agent-transcripts-poll".into()).spawn(move || {
                loop {
                    match stopped.recv_timeout(interval) {
                        Err(RecvTimeoutError::Timeout) => {
                            if commands.send(Command::Read(None)).is_err() {
                                return;
                            }
                        }
                        _ => return,
                    }
                }
            });
        if let Ok(handle) = handle {
            self.poller = Some((stop, handle));
        }
    }

    pub fn is_tracking(&self, entry_id: &str) -> bool {
        lock(&self.shared).sources.contains_key(entry_id)
    }

    pub fn timeline(&self, entry_id: &str) -> Option<AgentTimeline> {
        lock(&self.shared).timelines.get(entry_id).cloned()
    }

    /// Follows `sources`, keyed by dashboard entry id, and drops every other transcript. A
    /// source whose file or conversation changed starts over.
    pub fn track(&self, sources: HashMap<String, AgentTranscriptSource>) {
        {
            let mut shared = lock(&self.shared);
            let Shared { sources: current, timelines } = &mut *shared;
            current.retain(|id, _| sources.contains_key(id));
            timelines.retain(|id, _| sources.contains_key(id));
            for (id, source) in &sources {
                if current.get(id) != Some(source) {
                    current.insert(id.clone(), source.clone());
                    timelines.remove(id);
                }
            }
        }
        let _ = self.commands.send(Command::Track(sources));
    }

    /// Picks up whatever the followed transcripts gained since the last call.
    pub fn refresh(&self) {
        let _ = self.commands.send(Command::Read(None));
    }
}

impl Default for AgentTranscriptStore {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for AgentTranscriptStore {
    /// Never blocks the caller (the UI thread) on a read in progress: the worker is told to stop
    /// and left to finish on its own.
    fn drop(&mut self) {
        self.stopped.store(true, Ordering::SeqCst);
        if let Some((stop, _poller)) = self.poller.take() {
            let _ = stop.send(());
        }
        let _ = self.commands.send(Command::Stop);
        self.worker.take();
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

struct Worker {
    home: PathBuf,
    shared: Arc<Mutex<Shared>>,
    on_change: Arc<Mutex<Option<ChangeCallback>>>,
    readers: HashMap<String, Box<dyn AgentTranscriptReader>>,
    watcher: Option<RecommendedWatcher>,
    /// Directories watched, with the files in them whose changes matter.
    watched: HashMap<PathBuf, HashSet<PathBuf>>,
    sender: Option<Sender<Command>>,
    /// Set when the store is dropped; checked between reads.
    stopped: Arc<AtomicBool>,
}

impl Worker {
    fn new(
        home: PathBuf,
        shared: Arc<Mutex<Shared>>,
        on_change: Arc<Mutex<Option<ChangeCallback>>>,
        sender: Sender<Command>,
        stopped: Arc<AtomicBool>,
    ) -> Self {
        Self {
            home,
            shared,
            on_change,
            readers: HashMap::new(),
            watcher: None,
            watched: HashMap::new(),
            sender: Some(sender),
            stopped,
        }
    }

    fn run(mut self, receiver: Receiver<Command>) {
        if let Some(sender) = self.sender.take() {
            self.watcher = make_watcher(sender);
        }
        while let Ok(first) = receiver.recv() {
            let batch = std::iter::once(first).chain(std::iter::from_fn(|| receiver.try_recv().ok()));
            let Some(steps) = plan(batch) else { return };
            for step in steps {
                if self.stopped.load(Ordering::SeqCst) {
                    return;
                }
                match step {
                    Step::Track(sources) => self.track(sources),
                    Step::Read { all, ids, paths } => {
                        let ids: Vec<String> = self
                            .readers
                            .iter()
                            .filter(|(id, reader)| {
                                all || ids.contains(*id)
                                    || reader
                                        .watched_path()
                                        .is_some_and(|watched| paths.iter().any(|p| is_related(p, &watched)))
                            })
                            .map(|(id, _)| id.clone())
                            .collect();
                        for id in ids {
                            if self.stopped.load(Ordering::SeqCst) {
                                return;
                            }
                            self.read(&id);
                        }
                    }
                }
            }
        }
    }

    fn track(&mut self, sources: HashMap<String, AgentTranscriptSource>) {
        self.readers.retain(|id, _| sources.contains_key(id));
        let mut started = Vec::new();
        for (id, source) in sources {
            if self.readers.get(&id).is_some_and(|r| r.source() == &source) {
                continue;
            }
            self.readers.insert(id.clone(), source.make_reader(&self.home));
            started.push(id);
        }
        for id in started {
            self.read(&id);
        }
        self.update_watches();
    }

    fn read(&mut self, entry_id: &str) {
        let Some(reader) = self.readers.get_mut(entry_id) else { return };
        let timeline = reader.read_appended();
        let source = reader.source().clone();
        let watch = reader.watched_path();
        let Some(timeline) = timeline else {
            if watch.is_some() {
                self.update_watches();
            }
            return;
        };
        {
            let mut shared = lock(&self.shared);
            // A follower replaced while it was reading reports nothing.
            if shared.sources.get(entry_id) != Some(&source) {
                return;
            }
            shared.timelines.insert(entry_id.to_owned(), timeline);
        }
        self.update_watches();
        let callback = lock(&self.on_change).clone();
        if let Some(callback) = callback {
            callback(entry_id);
        }
    }

    fn update_watches(&mut self) {
        let Some(watcher) = self.watcher.as_mut() else { return };
        let mut wanted: HashMap<PathBuf, HashSet<PathBuf>> = HashMap::new();
        for reader in self.readers.values() {
            if let Some(path) = reader.watched_path()
                && let Some(parent) = path.parent()
            {
                wanted.entry(parent.to_path_buf()).or_default().insert(path);
            }
        }
        for directory in self.watched.keys() {
            if !wanted.contains_key(directory) {
                let _ = watcher.unwatch(directory);
            }
        }
        let mut watched = HashMap::new();
        for (directory, files) in wanted {
            // Only directories watched successfully count, so a failed watch (a folder that
            // does not exist yet) is tried again on the next read; the refresh covers it
            // meanwhile.
            if self.watched.contains_key(&directory) {
                watched.insert(directory, files);
                continue;
            }
            match watcher.watch(&directory, RecursiveMode::NonRecursive) {
                Ok(()) => {
                    watched.insert(directory, files);
                }
                Err(error) => {
                    tracing::debug!(
                        ?error,
                        ?directory,
                        "cannot watch transcript directory; polling covers it"
                    );
                }
            }
        }
        self.watched = watched;
    }
}

/// One step of a batch of commands: a `Track`, or every read the commands between two tracks
/// asked for, done once per reader.
#[derive(Debug, PartialEq)]
enum Step {
    Track(HashMap<String, AgentTranscriptSource>),
    Read { all: bool, ids: BTreeSet<String>, paths: BTreeSet<PathBuf> },
}

/// Folds the queued commands into steps, in order: reads queued while a reader is already due
/// to be read are skipped (Swift dropped a read request while that follower was queued or
/// reading), so a streaming agent's events and the 1 s refresh never pile up. `None` once a
/// `Stop` arrives.
fn plan(commands: impl IntoIterator<Item = Command>) -> Option<Vec<Step>> {
    let mut steps = Vec::new();
    for command in commands {
        let read = match command {
            Command::Stop => return None,
            Command::Track(sources) => {
                steps.push(Step::Track(sources));
                continue;
            }
            other => other,
        };
        if !matches!(steps.last(), Some(Step::Read { .. })) {
            steps.push(Step::Read { all: false, ids: BTreeSet::new(), paths: BTreeSet::new() });
        }
        let Some(Step::Read { all, ids, paths }) = steps.last_mut() else { continue };
        match read {
            Command::Read(None) => *all = true,
            Command::Read(Some(more)) => ids.extend(more),
            Command::FileChanged(path) => {
                paths.insert(path);
            }
            Command::Track(_) | Command::Stop => {}
        }
    }
    Some(steps)
}

fn make_watcher(sender: Sender<Command>) -> Option<RecommendedWatcher> {
    let sender = Mutex::new(sender);
    notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        let Ok(event) = event else { return };
        if matches!(event.kind, notify::EventKind::Access(_)) {
            return;
        }
        let sender = lock(&sender);
        for path in event.paths {
            let _ = sender.send(Command::FileChanged(path));
        }
    })
    .ok()
}

/// `changed` is the watched file or one of its SQLite companions (`-wal`, `-shm`, `-journal`).
/// Folders are compared resolved as well: watchers report real paths (macOS's FSEvents says
/// `/private/var/…` for a file under `/var/…`).
fn is_related(changed: &Path, watched: &Path) -> bool {
    if changed == watched {
        return true;
    }
    let (Some(changed_name), Some(watched_name)) = (changed.file_name(), watched.file_name()) else {
        return false;
    };
    if !changed_name.to_string_lossy().starts_with(watched_name.to_string_lossy().as_ref()) {
        return false;
    }
    let (Some(changed_folder), Some(watched_folder)) = (changed.parent(), watched.parent()) else {
        return false;
    };
    changed_folder == watched_folder
        || match (changed_folder.canonicalize(), watched_folder.canonicalize()) {
            (Ok(a), Ok(b)) => a == b,
            _ => false,
        }
}

/// One JSON Lines transcript being followed. Only the store's worker touches it.
pub struct TranscriptFollower {
    source: AgentTranscriptSource,
    home: PathBuf,
    path: Option<PathBuf>,
    last_lookup: Option<Instant>,
    offset: u64,
    remainder: Vec<u8>,
    make_decoder: fn() -> Box<dyn AgentTranscriptDecoding>,
    decoder: Box<dyn AgentTranscriptDecoding>,
    entries: Vec<AgentTranscriptEntry>,
}

impl TranscriptFollower {
    /// Bytes read from the end of a transcript when it is first opened.
    pub const INITIAL_WINDOW: u64 = 2 << 20;
    /// The first read grows its window up to this size to reach at least
    /// [`MINIMUM_PROMPTS`](Self::MINIMUM_PROMPTS) prompts: one Claude Code record can hold a
    /// whole file or an image, so a fixed tail sometimes covers only part of a turn.
    pub const MAXIMUM_WINDOW: u64 = 32 << 20;
    pub const MINIMUM_PROMPTS: usize = 2;
    /// Entries kept per transcript; older ones fall off the front.
    pub const ENTRY_LIMIT: usize = 4_000;
    /// Time between searches for a transcript that has not been found.
    pub const LOOKUP_INTERVAL: Duration = Duration::from_secs(5);

    pub fn new(
        source: AgentTranscriptSource,
        home: &Path,
        make_decoder: fn() -> Box<dyn AgentTranscriptDecoding>,
    ) -> Self {
        let path = source.path.as_ref().map(PathBuf::from);
        Self {
            source,
            home: home.to_path_buf(),
            path,
            last_lookup: None,
            offset: 0,
            remainder: Vec::new(),
            make_decoder,
            decoder: make_decoder(),
            entries: Vec::new(),
        }
    }

    fn resolved_path(&mut self) -> Option<PathBuf> {
        if let Some(path) = &self.path {
            return Some(path.clone());
        }
        let now = Instant::now();
        if let Some(last) = self.last_lookup
            && now.duration_since(last) < Self::LOOKUP_INTERVAL
        {
            return None;
        }
        self.last_lookup = Some(now);
        self.path = AgentTranscriptLocator::transcript_path(
            self.source.format,
            &self.source.conversation_id,
            &self.home,
        );
        self.path.clone()
    }

    fn load_tail(&mut self, file: &mut File, size: u64) {
        let mut window = Self::INITIAL_WINDOW;
        loop {
            self.reset();
            let start = size.saturating_sub(window);
            if start > 0 {
                self.read_header(file, start);
            }
            let data = read_range(file, start, size);
            self.consume(&data, start > 0);
            self.offset = size;
            let prompts: usize =
                self.entries.iter().map(|e| e.items.iter().filter(|i| i.is_prompt()).count()).sum();
            if start == 0 || prompts >= Self::MINIMUM_PROMPTS || window >= Self::MAXIMUM_WINDOW {
                return;
            }
            window *= 4;
        }
    }

    /// A tail skips the file's first line, which in omp and Codex files is the session header
    /// the decoder takes the working directory from. The decoder reads it for that state only;
    /// whatever entry it makes lies outside the window.
    fn read_header(&mut self, file: &mut File, end: u64) {
        let limit = end.min(Self::INITIAL_WINDOW);
        let chunk_size: u64 = 64 << 10;
        let mut header = Vec::new();
        let mut position = 0;
        while position < limit {
            let chunk_end = (position + chunk_size).min(limit);
            let chunk = read_range(file, position, chunk_end);
            if chunk.is_empty() {
                return;
            }
            if let Some(newline) = chunk.iter().position(|&b| b == b'\n') {
                header.extend_from_slice(&chunk[..newline]);
                let _ = self.decoder.entry_for_line(&header);
                return;
            }
            header.extend_from_slice(&chunk);
            position = chunk_end;
        }
    }

    /// Decodes every complete line in `data` and keeps a trailing partial line for the next
    /// read. Returns whether any entry was added.
    fn consume(&mut self, data: &[u8], skipping_first_line: bool) -> bool {
        let mut buffer = std::mem::take(&mut self.remainder);
        buffer.extend_from_slice(data);
        let mut line_start = 0;
        if skipping_first_line {
            // A tail starts mid-record; that partial line cannot parse.
            match buffer.iter().position(|&b| b == b'\n') {
                Some(newline) => line_start = newline + 1,
                None => {
                    self.remainder = buffer;
                    return false;
                }
            }
        }

        let mut added = false;
        while let Some(offset) = buffer[line_start..].iter().position(|&b| b == b'\n') {
            let newline = line_start + offset;
            if newline > line_start
                && let Some(entry) = self.decoder.entry_for_line(&buffer[line_start..newline])
            {
                self.entries.push(entry);
                added = true;
            }
            line_start = newline + 1;
        }
        self.remainder = buffer[line_start..].to_vec();
        if self.entries.len() > Self::ENTRY_LIMIT {
            self.entries.drain(..self.entries.len() - Self::ENTRY_LIMIT);
        }
        added
    }

    fn reset(&mut self) {
        self.offset = 0;
        self.remainder.clear();
        self.entries.clear();
        self.decoder = (self.make_decoder)();
    }
}

impl AgentTranscriptReader for TranscriptFollower {
    fn source(&self) -> &AgentTranscriptSource {
        &self.source
    }

    fn watched_path(&self) -> Option<PathBuf> {
        self.path.clone()
    }

    /// The timeline after reading what the file gained, or `None` when the file is missing or
    /// nothing visible changed.
    fn read_appended(&mut self) -> Option<AgentTimeline> {
        let path = self.resolved_path()?;
        let mut file = File::open(&path).ok()?;
        let size = file.seek(SeekFrom::End(0)).ok()?;

        if size < self.offset {
            // Rewritten in place: start over from its end.
            self.reset();
        }
        if size <= self.offset {
            return None;
        }

        let changed = if self.offset == 0 {
            self.load_tail(&mut file, size);
            true
        } else {
            let data = read_range(&mut file, self.offset, size);
            let changed = self.consume(&data, false);
            self.offset = size;
            changed
        };
        changed.then(|| AgentTimeline::from_entries(&self.entries))
    }
}

fn read_range(file: &mut File, start: u64, end: u64) -> Vec<u8> {
    if file.seek(SeekFrom::Start(start)).is_err() {
        return Vec::new();
    }
    let mut data = Vec::new();
    match file.take(end.saturating_sub(start)).read_to_end(&mut data) {
        Ok(_) => data,
        Err(_) => Vec::new(),
    }
}

/// Finds a conversation's transcript when no hook reported its path: workspaces saved before
/// Soprano kept it, Codex without its opt-in hooks, and agents started outside Soprano's
/// launcher.
pub struct AgentTranscriptLocator;

impl AgentTranscriptLocator {
    pub fn transcript_path(
        format: AgentTranscriptFormat,
        conversation_id: &str,
        home: &Path,
    ) -> Option<PathBuf> {
        // Valid ids are plain file-name characters, so they cannot escape the directories
        // searched below.
        if !AgentConversation::valid_id(conversation_id) {
            return None;
        }
        match format {
            AgentTranscriptFormat::ClaudeCode => {
                // ~/.claude/projects/<encoded cwd>/<session id>.jsonl
                let projects = home.join(".claude/projects");
                let file_name = format!("{conversation_id}.jsonl");
                std::fs::read_dir(projects)
                    .ok()?
                    .flatten()
                    .map(|entry| entry.path().join(&file_name))
                    .find(|candidate| candidate.exists())
            }
            AgentTranscriptFormat::Codex => {
                // ~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<thread id>.jsonl
                let suffix = format!("-{conversation_id}.jsonl");
                newest_file(&home.join(".codex/sessions"), &|name| {
                    name.starts_with("rollout-") && name.ends_with(&suffix)
                })
            }
            AgentTranscriptFormat::Omp => {
                // ~/.omp/agent/sessions/<encoded cwd>/<time>_<session id>.jsonl
                let suffix = format!("_{conversation_id}.jsonl");
                newest_file(&home.join(".omp/agent/sessions"), &|name| name.ends_with(&suffix))
            }
            // A database, not a file per conversation: OpenCodeTranscriptReader searches
            // OpenCode's data directories itself.
            AgentTranscriptFormat::OpenCode => None,
        }
    }
}

fn newest_file(root: &Path, matches: &dyn Fn(&str) -> bool) -> Option<PathBuf> {
    let mut newest: Option<(PathBuf, SystemTime)> = None;
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        let Ok(entries) = std::fs::read_dir(&directory) else { continue };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.starts_with('.') {
                continue;
            }
            let path = entry.path();
            let Ok(kind) = entry.file_type() else { continue };
            if kind.is_dir() {
                pending.push(path);
                continue;
            }
            if !matches(&name) {
                continue;
            }
            let date = entry.metadata().and_then(|m| m.modified()).unwrap_or(SystemTime::UNIX_EPOCH);
            if newest.as_ref().is_none_or(|(_, newest)| date > *newest) {
                newest = Some((path, date));
            }
        }
    }
    newest.map(|(path, _)| path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queued_reads_collapse_into_one_read_per_reader_between_tracks() {
        let mut commands = vec![Command::Read(Some(vec!["a".into()]))];
        for _ in 0..50 {
            commands.push(Command::FileChanged(PathBuf::from("/t/x.db-wal")));
            commands.push(Command::Read(Some(vec!["a".into(), "b".into()])));
        }
        commands.push(Command::Track(HashMap::new()));
        commands.push(Command::Read(None));
        commands.push(Command::Read(None));

        let steps = plan(commands).expect("no stop");
        assert_eq!(
            steps,
            vec![
                Step::Read {
                    all: false,
                    ids: BTreeSet::from(["a".to_owned(), "b".to_owned()]),
                    paths: BTreeSet::from([PathBuf::from("/t/x.db-wal")]),
                },
                Step::Track(HashMap::new()),
                Step::Read { all: true, ids: BTreeSet::new(), paths: BTreeSet::new() },
            ]
        );
    }

    #[test]
    fn a_stop_ends_the_batch_without_running_what_was_queued_before_it() {
        assert_eq!(plan([Command::Read(None), Command::Stop, Command::Read(None)]), None);
    }
}
