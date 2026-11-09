//! Following one OpenCode session in OpenCode's SQLite database (`OpenCodeTranscriptReader.swift`).

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use rusqlite::types::{ToSql, ValueRef};
use rusqlite::{Connection, OpenFlags, Row as SqlRow};

use crate::json::parse_object;
use crate::opencode::{OpenCodeMessageDecoder, PartRow};
use crate::store::{AgentTranscriptReader, AgentTranscriptSource, TranscriptFollower};
use crate::timeline::{AgentTimeline, AgentTranscriptEntry};

/// Which generation of OpenCode's tables holds the session.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Tables {
    /// 2.x: `session_v2`, `session_message`, `session_part`.
    Current,
    /// 1.x: `session`, `message`, `part`.
    Legacy,
}

/// Where a message sits: `seq` in 2.x, `time_created` then id in 1.x.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct Position {
    order: i64,
    id: String,
}

struct Message {
    position: Position,
    entry: AgentTranscriptEntry,
}

/// What a read compares to notice a change without loading messages.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Signature {
    message_count: i64,
    messages_updated: i64,
    part_count: i64,
    parts_updated: i64,
    revert: Option<String>,
    directory: Option<String>,
    /// Bumped by every commit of another connection, so two writes in the same millisecond that
    /// only rewrite rows still count as a change.
    data_version: i64,
}

struct Row {
    id: String,
    position: Position,
    kind: String,
    data: Vec<u8>,
}

enum Outcome {
    Missing,
    Unchanged,
    Changed(AgentTimeline),
}

/// Follows one OpenCode session in OpenCode's SQLite database. The database is opened
/// read-only and stays open; each read first compares a few aggregates and returns `None` when
/// they did not move, then fetches only the messages updated since the last read. OpenCode 2.x
/// rewrites an assistant message in place while it streams, so entries are kept per message and
/// replaced. Only the store's worker touches it.
pub struct OpenCodeTranscriptReader {
    source: AgentTranscriptSource,
    home: PathBuf,
    environment: HashMap<String, String>,
    database: Option<Connection>,
    database_path: Option<PathBuf>,
    tables: Tables,
    last_lookup: Option<Instant>,
    decoder: OpenCodeMessageDecoder,
    signature: Option<Signature>,
    messages: HashMap<String, Message>,
    /// The oldest message kept; `None` while every message of the session is.
    lower_bound: Option<Position>,
    /// The newest message read, which tells new rows from updated ones.
    newest: Option<Position>,
    /// Messages from here on were rewound and stay hidden.
    revert_boundary: Option<Position>,
    last_timeline: Option<AgentTimeline>,
}

impl OpenCodeTranscriptReader {
    /// Messages read when a session is first opened; the first read grows this up to
    /// [`TranscriptFollower::ENTRY_LIMIT`] to reach [`TranscriptFollower::MINIMUM_PROMPTS`]
    /// prompts.
    pub const INITIAL_MESSAGES: usize = 600;
    /// How long a read waits while OpenCode holds a write lock.
    pub const BUSY_TIMEOUT: Duration = Duration::from_millis(2_000);

    pub fn new(source: AgentTranscriptSource, home: &Path) -> Self {
        // `vars()` panics on a non-UTF-8 variable; such variables are skipped.
        let environment = std::env::vars_os()
            .filter_map(|(key, value)| Some((key.into_string().ok()?, value.into_string().ok()?)))
            .collect();
        Self::with_environment(source, home, environment)
    }

    /// A reader that takes `XDG_DATA_HOME` from `environment` instead of the process.
    pub fn with_environment(
        source: AgentTranscriptSource,
        home: &Path,
        environment: HashMap<String, String>,
    ) -> Self {
        Self {
            source,
            home: home.to_path_buf(),
            environment,
            database: None,
            database_path: None,
            tables: Tables::Current,
            last_lookup: None,
            decoder: OpenCodeMessageDecoder::default(),
            signature: None,
            messages: HashMap::new(),
            lower_bound: None,
            newest: None,
            revert_boundary: None,
            last_timeline: None,
        }
    }

    fn read(&mut self, database: &Connection) -> Outcome {
        let Some(current) = self.read_signature(database) else { return Outcome::Missing };
        if Some(&current) == self.signature.as_ref() {
            return Outcome::Unchanged;
        }
        let previous = self.signature.replace(current.clone());
        self.decoder.cwd.clone_from(&current.directory);

        let incremental = previous.as_ref().is_some_and(|previous| {
            previous.revert == current.revert
                && previous.directory == current.directory
                && current.message_count >= previous.message_count
                && current.part_count >= previous.part_count
        });
        let loaded = match previous {
            Some(previous)
                if incremental && self.read_changes(database, &previous, current.message_count) =>
            {
                true
            }
            _ => self.load_newest(database),
        };
        if !loaded {
            self.signature = None;
            return Outcome::Unchanged;
        }
        self.revert_boundary =
            current.revert.as_deref().and_then(|revert| self.position_of_revert(database, revert));

        let mut visible: Vec<&Message> = self
            .messages
            .values()
            .filter(|m| self.revert_boundary.as_ref().is_none_or(|boundary| m.position < *boundary))
            .collect();
        visible.sort_by(|a, b| a.position.cmp(&b.position));
        let entries: Vec<AgentTranscriptEntry> = visible.into_iter().map(|m| m.entry.clone()).collect();
        let timeline = AgentTimeline::from_entries(&entries);
        if self.last_timeline.as_ref() == Some(&timeline) {
            return Outcome::Unchanged;
        }
        self.last_timeline = Some(timeline.clone());
        Outcome::Changed(timeline)
    }

    // MARK: - Locating the database

    fn open_database(&mut self) -> bool {
        if self.database.is_some() {
            return true;
        }
        let now = Instant::now();
        if let Some(last) = self.last_lookup
            && now.duration_since(last) < TranscriptFollower::LOOKUP_INTERVAL
        {
            return false;
        }
        self.last_lookup = Some(now);

        let mut seen = HashSet::new();
        for path in self.candidate_paths() {
            if !seen.insert(path.clone()) {
                continue;
            }
            if let Some((database, tables)) = self.open(&path) {
                self.database = Some(database);
                self.database_path = Some(path);
                self.tables = tables;
                self.reset();
                return true;
            }
        }
        false
    }

    /// The path the plugin reported, then every `opencode*.db` in OpenCode's data directories,
    /// the default database first.
    fn candidate_paths(&self) -> Vec<PathBuf> {
        let mut paths: Vec<PathBuf> = self.source.path.iter().map(PathBuf::from).collect();
        let mut directories = vec![self.home.join(".local/share/opencode")];
        if let Some(data_home) = self.environment.get("XDG_DATA_HOME").filter(|d| !d.is_empty()) {
            directories.push(Path::new(data_home).join("opencode"));
        }
        for directory in directories {
            let Ok(entries) = std::fs::read_dir(&directory) else { continue };
            let mut names: Vec<String> = entries
                .flatten()
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|n| n.starts_with("opencode") && n.ends_with(".db"))
                .collect();
            names.sort_by_key(|n| (n != "opencode.db", n.clone()));
            paths.extend(names.into_iter().map(|n| directory.join(n)));
        }
        paths
    }

    /// The database at `path` opened read-only, when it holds the session.
    fn open(&self, path: &Path) -> Option<(Connection, Tables)> {
        if !path.is_file() {
            return None;
        }
        let database = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .ok()?;
        let _ = database.busy_timeout(Self::BUSY_TIMEOUT);
        if self.contains(&database, "session_v2") {
            return Some((database, Tables::Current));
        }
        if self.contains(&database, "session") {
            return Some((database, Tables::Legacy));
        }
        None
    }

    fn contains(&self, database: &Connection, table: &str) -> bool {
        // Table names are fixed literals, never input.
        query(
            database,
            &format!("SELECT 1 FROM {table} WHERE id = ?"),
            &[&self.source.conversation_id],
            |_| (),
        )
        .is_some_and(|rows| !rows.is_empty())
    }

    fn close(&mut self) {
        self.database = None;
        self.database_path = None;
        self.last_lookup = Some(Instant::now());
        self.reset();
    }

    fn reset(&mut self) {
        self.signature = None;
        self.messages.clear();
        self.lower_bound = None;
        self.newest = None;
        self.revert_boundary = None;
        self.last_timeline = None;
    }

    // MARK: - Reading

    fn read_signature(&self, database: &Connection) -> Option<Signature> {
        let id = &self.source.conversation_id;
        let session_sql = match self.tables {
            Tables::Current => "SELECT revert, directory FROM session_v2 WHERE id = ?",
            Tables::Legacy => "SELECT revert, directory FROM session WHERE id = ?",
        };
        let session =
            query(database, session_sql, &[id], |row| (text(row, 0), text(row, 1)))?.into_iter().next();
        let (message_stats, part_stats) = match self.tables {
            Tables::Current => (
                self.aggregates(database, "session_message"),
                // Older 2.x databases have no part table yet.
                Some(self.aggregates(database, "session_part").unwrap_or((0, 0))),
            ),
            Tables::Legacy => (self.aggregates(database, "message"), self.aggregates(database, "part")),
        };
        let (revert, directory) = session?;
        let message_stats = message_stats?;
        let part_stats = part_stats?;
        let data_version =
            query(database, "PRAGMA data_version", &[], |row| int(row, 0))?.into_iter().next()?;
        Some(Signature {
            message_count: message_stats.0,
            messages_updated: message_stats.1,
            part_count: part_stats.0,
            parts_updated: part_stats.1,
            revert,
            directory,
            data_version,
        })
    }

    fn aggregates(&self, database: &Connection, table: &str) -> Option<(i64, i64)> {
        query(
            database,
            &format!("SELECT count(*), coalesce(max(time_updated), 0) FROM {table} WHERE session_id = ?"),
            &[&self.source.conversation_id],
            |row| (int(row, 0), int(row, 1)),
        )?
        .into_iter()
        .next()
    }

    /// Reads the newest messages, more of them until enough prompts show.
    fn load_newest(&mut self, database: &Connection) -> bool {
        let sql = match self.tables {
            Tables::Current => {
                "SELECT id, seq, type, data FROM session_message WHERE session_id = ? ORDER BY seq DESC LIMIT ?"
            }
            Tables::Legacy => {
                "SELECT id, time_created, '', data FROM message WHERE session_id = ? ORDER BY time_created DESC, id DESC LIMIT ?"
            }
        };
        let mut limit = Self::INITIAL_MESSAGES;
        loop {
            let limit_value = limit as i64;
            let Some(mut rows) = query(database, sql, &[&self.source.conversation_id, &limit_value], row)
            else {
                return false;
            };
            rows.reverse();
            self.messages.clear();
            for row in &rows {
                let entry = self.entry(database, row);
                self.messages.insert(row.id.clone(), Message { position: row.position.clone(), entry });
            }
            self.lower_bound =
                if rows.len() < limit { None } else { rows.first().map(|r| r.position.clone()) };
            self.newest = rows.last().map(|r| r.position.clone());
            let prompts: usize =
                self.messages.values().map(|m| m.entry.items.iter().filter(|i| i.is_prompt()).count()).sum();
            if self.lower_bound.is_none()
                || prompts >= TranscriptFollower::MINIMUM_PROMPTS
                || limit >= TranscriptFollower::ENTRY_LIMIT
            {
                return true;
            }
            limit = (limit * 4).min(TranscriptFollower::ENTRY_LIMIT);
        }
    }

    /// Re-reads the messages updated since `previous`, and those whose parts were. Returns false
    /// when rows went missing, which needs a full reload.
    fn read_changes(&mut self, database: &Connection, previous: &Signature, expected_count: i64) -> bool {
        let id = self.source.conversation_id.clone();
        let (changed_sql, parts_sql, message_sql) = match self.tables {
            Tables::Current => (
                "SELECT id, seq, type, data FROM session_message WHERE session_id = ? AND time_updated >= ?",
                "SELECT DISTINCT message_id FROM session_part WHERE session_id = ? AND time_updated >= ?",
                "SELECT id, seq, type, data FROM session_message WHERE session_id = ? AND id = ?",
            ),
            Tables::Legacy => (
                "SELECT id, time_created, '', data FROM message WHERE session_id = ? AND time_updated >= ?",
                "SELECT DISTINCT message_id FROM part WHERE session_id = ? AND time_updated >= ?",
                "SELECT id, time_created, '', data FROM message WHERE session_id = ? AND id = ?",
            ),
        };

        let Some(mut rows) = query(database, changed_sql, &[&id, &previous.messages_updated], row) else {
            return false;
        };
        let mut changed_ids: HashSet<String> = rows.iter().map(|r| r.id.clone()).collect();
        if self.signature.as_ref().map_or(0, |s| s.part_count) > 0 {
            let Some(owners) = query(database, parts_sql, &[&id, &previous.parts_updated], |r| text(r, 0))
            else {
                return false;
            };
            for message_id in owners.into_iter().flatten() {
                if !changed_ids.insert(message_id.clone()) {
                    continue;
                }
                let Some(owner) = query(database, message_sql, &[&id, &message_id], row) else {
                    return false;
                };
                rows.extend(owner);
            }
        }

        let added: Vec<&Row> =
            rows.iter().filter(|r| self.newest.as_ref().is_none_or(|n| r.position > *n)).collect();
        if previous.message_count + added.len() as i64 != expected_count {
            return false;
        }
        let newest_added = added.iter().map(|r| r.position.clone()).max();

        for row in &rows {
            if self.lower_bound.as_ref().is_none_or(|bound| row.position >= *bound) {
                let entry = self.entry(database, row);
                self.messages.insert(row.id.clone(), Message { position: row.position.clone(), entry });
            }
        }
        if let Some(last) = newest_added {
            self.newest = Some(last);
        }
        if self.messages.len() > TranscriptFollower::ENTRY_LIMIT {
            let mut positions: Vec<Position> = self.messages.values().map(|m| m.position.clone()).collect();
            positions.sort();
            let first_kept = positions[positions.len() - TranscriptFollower::ENTRY_LIMIT].clone();
            self.messages.retain(|_, m| m.position >= first_kept);
            self.lower_bound = Some(first_kept);
        }
        true
    }

    fn entry(&self, database: &Connection, row: &Row) -> AgentTranscriptEntry {
        let id = &self.source.conversation_id;
        match self.tables {
            Tables::Current => {
                let mut parts = Vec::new();
                if row.kind == "assistant" && self.signature.as_ref().map_or(0, |s| s.part_count) > 0 {
                    parts = query(
                        database,
                        "SELECT type, data FROM session_part WHERE session_id = ? AND message_id = ? ORDER BY ordinal",
                        &[id, &row.id],
                        |r| PartRow::new(text(r, 0).unwrap_or_default(), blob(r, 1)),
                    )
                    .unwrap_or_default();
                }
                self.decoder.entry(&row.id, &row.kind, &row.data, &parts)
            }
            Tables::Legacy => {
                let parts = query(
                    database,
                    "SELECT data FROM part WHERE session_id = ? AND message_id = ? ORDER BY id",
                    &[id, &row.id],
                    |r| blob(r, 0),
                )
                .unwrap_or_default();
                self.decoder.legacy_entry(&row.id, &row.data, &parts)
            }
        }
    }

    /// Where the message a rewind returned to sits; it and everything after it are hidden until
    /// the rewind is undone or committed.
    fn position_of_revert(&self, database: &Connection, revert: &str) -> Option<Position> {
        let object = parse_object(revert.as_bytes())?;
        let message_id = object.get("messageID")?.as_str()?.to_owned();
        let sql = match self.tables {
            Tables::Current => "SELECT seq FROM session_message WHERE session_id = ? AND id = ?",
            Tables::Legacy => "SELECT time_created FROM message WHERE session_id = ? AND id = ?",
        };
        query(database, sql, &[&self.source.conversation_id, &message_id], |r| Position {
            order: int(r, 0),
            id: message_id.clone(),
        })?
        .into_iter()
        .next()
    }
}

impl AgentTranscriptReader for OpenCodeTranscriptReader {
    fn source(&self) -> &AgentTranscriptSource {
        &self.source
    }

    fn watched_path(&self) -> Option<PathBuf> {
        self.database_path.clone()
    }

    /// The timeline after reading what changed, or `None` when nothing visible changed or the
    /// session is not in any database found.
    fn read_appended(&mut self) -> Option<AgentTimeline> {
        if !self.open_database() {
            return None;
        }
        let database = self.database.take()?;
        if self.tables == Tables::Legacy && self.contains(&database, "session_v2") {
            // OpenCode 2.x migrated the session since it was opened.
            self.tables = Tables::Current;
            self.reset();
        }

        // One read transaction, so the aggregates and the rows agree.
        if database.execute_batch("BEGIN").is_err() {
            self.database = Some(database);
            return None;
        }
        let outcome = self.read(&database);
        let _ = database.execute_batch("COMMIT");
        self.database = Some(database);
        match outcome {
            Outcome::Missing => {
                // The session was deleted; look for it again later.
                self.close();
                None
            }
            Outcome::Unchanged => None,
            Outcome::Changed(timeline) => Some(timeline),
        }
    }
}

fn row(r: &SqlRow<'_>) -> Row {
    let id = text(r, 0).unwrap_or_default();
    Row {
        position: Position { order: int(r, 1), id: id.clone() },
        id,
        kind: text(r, 2).unwrap_or_default(),
        data: blob(r, 3),
    }
}

fn text(row: &SqlRow<'_>, column: usize) -> Option<String> {
    match row.get_ref(column).ok()? {
        ValueRef::Text(bytes) | ValueRef::Blob(bytes) => Some(String::from_utf8_lossy(bytes).into_owned()),
        ValueRef::Integer(v) => Some(v.to_string()),
        ValueRef::Real(v) => Some(v.to_string()),
        ValueRef::Null => None,
    }
}

fn blob(row: &SqlRow<'_>, column: usize) -> Vec<u8> {
    match row.get_ref(column) {
        Ok(ValueRef::Text(bytes) | ValueRef::Blob(bytes)) => bytes.to_vec(),
        _ => Vec::new(),
    }
}

/// `sqlite3_column_int64`: NULL and text that is not a number read as 0.
fn int(row: &SqlRow<'_>, column: usize) -> i64 {
    match row.get_ref(column) {
        Ok(ValueRef::Integer(v)) => v,
        Ok(ValueRef::Real(v)) => v as i64,
        Ok(ValueRef::Text(bytes)) => {
            std::str::from_utf8(bytes).ok().and_then(|s| s.trim().parse().ok()).unwrap_or(0)
        }
        _ => 0,
    }
}

/// Every row `sql` returns, or `None` when it cannot run, such as for a table this database
/// does not have.
fn query<T>(
    database: &Connection,
    sql: &str,
    arguments: &[&dyn ToSql],
    mut make_row: impl FnMut(&SqlRow<'_>) -> T,
) -> Option<Vec<T>> {
    let mut statement = database.prepare(sql).ok()?;
    let mut rows = statement.query(arguments).ok()?;
    let mut result = Vec::new();
    loop {
        match rows.next() {
            Ok(Some(r)) => result.push(make_row(r)),
            Ok(None) => return Some(result),
            Err(_) => return None,
        }
    }
}
