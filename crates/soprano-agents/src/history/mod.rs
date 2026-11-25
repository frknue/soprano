//! Indexed agent session history across Claude Code, omp, Codex, OpenCode, and Antigravity.
//!
//! Scans the CLIs' transcript directories and SQLite databases on disk with an mtime+size
//! incremental cache (optionally persisted to a local SQLite database), then filters by
//! workspace/project/all scope, searches titles + full conversation prose, sorts, and groups
//! by project.

mod parsers;

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::Duration;

use chrono::{DateTime, Utc};
use rusqlite::{Connection, OpenFlags, params};
use serde::{Deserialize, Serialize};
use soprano_git::branch::{common_git_dir, current_branch, repository_root, standardize};
use soprano_types::AgentConversation;

use crate::timeline::{AgentTranscriptFormat, Date};

pub(crate) use self::parsers::{
    discover_agy_transcript_paths, infer_agy_cwd_from_tool_call, read_jsonl_lines, short_model_name,
};
use self::parsers::{discover_sources, parse_source, profile_id_for_format};

/// Bumped whenever the cached `AgentSessionSummary` format changes; old cache rows are
/// simply ignored and re-indexed cleanly.
const CACHE_SCHEMA_VERSION: i64 = 2;

/// Which side of the conversation sent a previewed message.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum HistoryMessageRole {
    User,
    Assistant,
}

impl HistoryMessageRole {
    pub fn prefix(self) -> &'static str {
        match self {
            Self::User => "You: ",
            Self::Assistant => "Agent: ",
        }
    }
}

/// One compact message excerpt stored for inline expansion of a session card.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HistoryTurnSnippet {
    pub role: HistoryMessageRole,
    pub text: String,
}

/// Persisted-cache-friendly format tag.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
enum FormatTag {
    ClaudeCode,
    Codex,
    Omp,
    OpenCode,
    Agy,
}

impl From<AgentTranscriptFormat> for FormatTag {
    fn from(format: AgentTranscriptFormat) -> Self {
        match format {
            AgentTranscriptFormat::ClaudeCode => Self::ClaudeCode,
            AgentTranscriptFormat::Codex => Self::Codex,
            AgentTranscriptFormat::Omp => Self::Omp,
            AgentTranscriptFormat::OpenCode => Self::OpenCode,
            AgentTranscriptFormat::Agy => Self::Agy,
        }
    }
}

impl From<FormatTag> for AgentTranscriptFormat {
    fn from(tag: FormatTag) -> Self {
        match tag {
            FormatTag::ClaudeCode => Self::ClaudeCode,
            FormatTag::Codex => Self::Codex,
            FormatTag::Omp => Self::Omp,
            FormatTag::OpenCode => Self::OpenCode,
            FormatTag::Agy => Self::Agy,
        }
    }
}

/// One indexed agent session on disk.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentSessionSummary {
    pub id: String,
    pub format: AgentTranscriptFormat,
    pub profile_id: &'static str,
    pub title: String,
    pub first_prompt: Option<String>,
    pub last_message_role: Option<HistoryMessageRole>,
    pub last_message_text: Option<String>,
    pub cwd: Option<String>,
    pub git_branch: Option<String>,
    pub model: Option<String>,
    pub message_count: usize,
    pub subagent_count: usize,
    pub created_at: Option<Date>,
    pub updated_at: Date,
    pub transcript_path: Option<PathBuf>,
    pub recent_messages: Vec<HistoryTurnSnippet>,
    pub search_text: String,
}

impl AgentSessionSummary {
    /// Stable composite key across all CLIs.
    pub fn key(&self) -> String {
        format!("{}:{}", self.profile_id, self.id)
    }

    /// The `AgentConversation` Soprano uses to resume this session in a pane or chat.
    pub fn conversation(&self) -> AgentConversation {
        AgentConversation {
            id: self.id.clone(),
            cwd: self.cwd.clone(),
            transcript_path: self.transcript_path.as_ref().map(|p| p.to_string_lossy().into_owned()),
        }
    }

    /// Shell-friendly command to resume this session from a terminal.
    pub fn resume_command(&self) -> String {
        match self.format {
            AgentTranscriptFormat::ClaudeCode => format!("claude --resume {}", self.id),
            AgentTranscriptFormat::Codex => format!("codex resume {}", self.id),
            AgentTranscriptFormat::Omp => format!("omp --resume {}", self.id),
            AgentTranscriptFormat::OpenCode => format!("opencode --session {}", self.id),
            AgentTranscriptFormat::Agy => format!("agy --resume {}", self.id),
        }
    }

    /// Compact label for the metadata line on a session card.
    pub fn short_agent_label(&self) -> &'static str {
        match self.format {
            AgentTranscriptFormat::ClaudeCode => "Claude",
            AgentTranscriptFormat::Codex => "Codex",
            AgentTranscriptFormat::Omp => "OMP",
            AgentTranscriptFormat::OpenCode => "OpenCode",
            AgentTranscriptFormat::Agy => "AGY",
        }
    }

    /// Full label for filter menus and tooltips.
    pub fn full_agent_label(format: AgentTranscriptFormat) -> &'static str {
        match format {
            AgentTranscriptFormat::ClaudeCode => "Claude Code",
            AgentTranscriptFormat::Codex => "Codex",
            AgentTranscriptFormat::Omp => "omp",
            AgentTranscriptFormat::OpenCode => "OpenCode",
            AgentTranscriptFormat::Agy => "Antigravity",
        }
    }
}

#[derive(Serialize, Deserialize)]
struct CachedSummary {
    id: String,
    format: FormatTag,
    title: String,
    first_prompt: Option<String>,
    last_message_role: Option<HistoryMessageRole>,
    last_message_text: Option<String>,
    cwd: Option<String>,
    git_branch: Option<String>,
    model: Option<String>,
    message_count: usize,
    subagent_count: usize,
    created_at_ms: Option<i64>,
    updated_at_ms: i64,
    transcript_path: Option<String>,
    recent_messages: Vec<HistoryTurnSnippet>,
    search_text: String,
}

impl From<&AgentSessionSummary> for CachedSummary {
    fn from(s: &AgentSessionSummary) -> Self {
        Self {
            id: s.id.clone(),
            format: s.format.into(),
            title: s.title.clone(),
            first_prompt: s.first_prompt.clone(),
            last_message_role: s.last_message_role,
            last_message_text: s.last_message_text.clone(),
            cwd: s.cwd.clone(),
            git_branch: s.git_branch.clone(),
            model: s.model.clone(),
            message_count: s.message_count,
            subagent_count: s.subagent_count,
            created_at_ms: s.created_at.map(|d| d.timestamp_millis()),
            updated_at_ms: s.updated_at.timestamp_millis(),
            transcript_path: s.transcript_path.as_ref().map(|p| p.to_string_lossy().into_owned()),
            recent_messages: s.recent_messages.clone(),
            search_text: s.search_text.clone(),
        }
    }
}

impl From<CachedSummary> for AgentSessionSummary {
    fn from(c: CachedSummary) -> Self {
        let format: AgentTranscriptFormat = c.format.into();
        Self {
            id: c.id,
            format,
            profile_id: profile_id_for_format(format),
            title: c.title,
            first_prompt: c.first_prompt,
            last_message_role: c.last_message_role,
            last_message_text: c.last_message_text,
            cwd: c.cwd,
            git_branch: c.git_branch,
            model: c.model,
            message_count: c.message_count,
            subagent_count: c.subagent_count,
            created_at: c.created_at_ms.and_then(DateTime::from_timestamp_millis),
            updated_at: DateTime::from_timestamp_millis(c.updated_at_ms).unwrap_or(DateTime::UNIX_EPOCH),
            transcript_path: c.transcript_path.map(PathBuf::from),
            recent_messages: c.recent_messages,
            search_text: c.search_text,
        }
    }
}

#[derive(Clone)]
struct CachedFile {
    size: u64,
    modified_ms: i64,
    sessions: Vec<AgentSessionSummary>,
}

/// Statistics returned after refreshing the session history index.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HistoryRefreshOutcome {
    pub sessions: Vec<AgentSessionSummary>,
    pub reparsed_files: usize,
    pub cached_files: usize,
    pub refreshed_at: Date,
}

/// Scans and incrementally caches agent session transcripts under a home directory.
pub struct AgentSessionIndex {
    home: PathBuf,
    env: HashMap<String, String>,
    cache_path: Option<PathBuf>,
    files: HashMap<PathBuf, CachedFile>,
    cache_loaded: bool,
}

impl AgentSessionIndex {
    /// Index reading the user's home directory and caching into Soprano's data directory.
    pub fn for_current_user() -> Self {
        let home = soprano_platform::paths::home_dir();
        let env = std::env::vars_os()
            .filter_map(|(k, v)| Some((k.into_string().ok()?, v.into_string().ok()?)))
            .collect();
        let cache_path = Some(
            soprano_platform::paths::data_dir(&soprano_platform::AppIdentity::current())
                .join("session-history-cache.db"),
        );
        Self::new(home, env, cache_path)
    }

    /// Index rooted at `home` with explicit `env` and optional SQLite cache path (`None` in
    /// tests that do not need persistence).
    pub fn new(home: PathBuf, env: HashMap<String, String>, cache_path: Option<PathBuf>) -> Self {
        Self { home, env, cache_path, files: HashMap::new(), cache_loaded: false }
    }

    /// Re-scans transcript directories, only re-parsing files whose size or modification time
    /// changed since the previous scan.
    pub fn refresh(&mut self) -> HistoryRefreshOutcome {
        if !self.cache_loaded {
            self.load_cache_from_disk();
            self.cache_loaded = true;
        }

        let discovered = discover_sources(&self.home, &self.env);
        let active_paths: HashSet<PathBuf> = discovered.iter().map(|s| s.path.clone()).collect();
        let mut dirty_paths: Vec<PathBuf> = Vec::new();
        let mut removed_paths: Vec<PathBuf> = Vec::new();

        self.files.retain(|path, _| {
            if active_paths.contains(path) {
                true
            } else {
                removed_paths.push(path.clone());
                false
            }
        });

        let mut reparsed_files = 0usize;
        let mut cached_files = 0usize;

        for source in discovered {
            let hit = self
                .files
                .get(&source.path)
                .is_some_and(|entry| entry.size == source.size && entry.modified_ms == source.modified_ms);
            if hit {
                cached_files += 1;
                continue;
            }
            let parsed = parse_source(&source);
            self.files.insert(
                source.path.clone(),
                CachedFile { size: source.size, modified_ms: source.modified_ms, sessions: parsed },
            );
            dirty_paths.push(source.path);
            reparsed_files += 1;
        }

        if !dirty_paths.is_empty() || !removed_paths.is_empty() {
            self.save_cache_delta(&dirty_paths, &removed_paths);
        }

        // Deduplicate by (format, id), keeping the most recently updated entry if two files
        // somehow describe the same session.
        let mut by_key: HashMap<(AgentTranscriptFormat, String), AgentSessionSummary> = HashMap::new();
        for entry in self.files.values() {
            for session in &entry.sessions {
                let key = (session.format, session.id.clone());
                let replace = by_key.get(&key).is_none_or(|prev| session.updated_at > prev.updated_at);
                if replace {
                    by_key.insert(key, session.clone());
                }
            }
        }
        let mut sessions: Vec<AgentSessionSummary> = by_key.into_values().collect();
        sessions.sort_by(|a, b| b.updated_at.cmp(&a.updated_at).then_with(|| a.id.cmp(&b.id)));

        HistoryRefreshOutcome { sessions, reparsed_files, cached_files, refreshed_at: Utc::now() }
    }

    fn open_cache(&self) -> Option<Connection> {
        let path = self.cache_path.as_ref()?;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).ok()?;
        }
        let db = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_CREATE
                | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .ok()?;
        let _ = db.busy_timeout(Duration::from_millis(2_000));
        db.execute_batch(
            "PRAGMA journal_mode = WAL;
             CREATE TABLE IF NOT EXISTS file_cache (
                 path TEXT PRIMARY KEY,
                 schema_version INTEGER NOT NULL,
                 size INTEGER NOT NULL,
                 modified_ms INTEGER NOT NULL,
                 payload TEXT NOT NULL
             );",
        )
        .ok()?;
        Some(db)
    }

    fn load_cache_from_disk(&mut self) {
        let Some(db) = self.open_cache() else { return };
        let Ok(mut stmt) =
            db.prepare("SELECT path, size, modified_ms, payload FROM file_cache WHERE schema_version = ?")
        else {
            return;
        };
        let Ok(rows) = stmt.query_map([CACHE_SCHEMA_VERSION], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, String>(3)?,
            ))
        }) else {
            return;
        };
        for (path, size, modified_ms, payload) in rows.flatten() {
            let Ok(size) = u64::try_from(size) else { continue };
            let Ok(cached) = serde_json::from_str::<Vec<CachedSummary>>(&payload) else { continue };
            let sessions = cached.into_iter().map(AgentSessionSummary::from).collect();
            self.files.insert(PathBuf::from(path), CachedFile { size, modified_ms, sessions });
        }
    }

    fn save_cache_delta(&self, dirty: &[PathBuf], removed: &[PathBuf]) {
        let Some(mut db) = self.open_cache() else { return };
        let Ok(tx) = db.transaction() else { return };
        {
            if let Ok(mut del) = tx.prepare("DELETE FROM file_cache WHERE path = ?") {
                for path in removed {
                    let _ = del.execute([path.to_string_lossy().as_ref()]);
                }
            }
            if let Ok(mut upsert) = tx.prepare(
                "INSERT INTO file_cache (path, schema_version, size, modified_ms, payload)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(path) DO UPDATE SET
                     schema_version = excluded.schema_version,
                     size = excluded.size,
                     modified_ms = excluded.modified_ms,
                     payload = excluded.payload",
            ) {
                for path in dirty {
                    let Some(entry) = self.files.get(path) else { continue };
                    let cached: Vec<CachedSummary> = entry.sessions.iter().map(CachedSummary::from).collect();
                    let Ok(payload) = serde_json::to_string(&cached) else { continue };
                    let _ = upsert.execute(params![
                        path.to_string_lossy().as_ref(),
                        CACHE_SCHEMA_VERSION,
                        entry.size as i64,
                        entry.modified_ms,
                        payload,
                    ]);
                }
            }
        }
        let _ = tx.commit();
    }
}

// MARK: - Querying, scoping, searching, grouping

/// Which sessions the history panel includes relative to the focused pane's directory.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum HistoryScope {
    /// Sessions in the active pane's current worktree / directory.
    Workspace,
    /// Sessions across all worktrees of the active pane's git project (or current directory).
    #[default]
    Project,
    /// Every indexed session on this computer.
    All,
}

impl HistoryScope {
    pub const ALL: [Self; 3] = [Self::Workspace, Self::Project, Self::All];

    pub fn label(self) -> &'static str {
        match self {
            Self::Workspace => "Workspace",
            Self::Project => "Project",
            Self::All => "All",
        }
    }
}

/// Ordering of sessions within each project group.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum HistorySort {
    #[default]
    LastUpdated,
    Created,
    MostMessages,
}

impl HistorySort {
    pub const ALL: [Self; 3] = [Self::LastUpdated, Self::Created, Self::MostMessages];

    pub fn label(self) -> &'static str {
        match self {
            Self::LastUpdated => "Last updated",
            Self::Created => "Newest created",
            Self::MostMessages => "Most messages",
        }
    }
}

/// Parameters controlling which sessions show and how they are ordered.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HistoryQuery {
    pub scope: HistoryScope,
    pub active_cwd: Option<String>,
    pub search: String,
    pub agent: Option<AgentTranscriptFormat>,
    pub sort: HistorySort,
}

/// A session enriched with project/worktree context and optional search excerpt.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HistorySessionItem {
    pub session: AgentSessionSummary,
    pub project_key: String,
    pub project_name: String,
    pub is_current_worktree: bool,
    pub worktree_label: Option<String>,
    pub branch: Option<String>,
    pub match_snippet: Option<String>,
}

/// Sessions grouped under one project heading (like `ab_tool 122`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HistoryProjectGroup {
    pub key: String,
    pub name: String,
    pub sessions: Vec<HistorySessionItem>,
}

/// Output of [`query_sessions`].
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HistoryQueryResult {
    /// Sessions in the active scope + agent filter before applying the search query.
    pub scoped_count: usize,
    /// Sessions matching scope + agent + search.
    pub matched_count: usize,
    pub groups: Vec<HistoryProjectGroup>,
}

#[derive(Clone, Debug)]
struct CwdInfo {
    canonical: PathBuf,
    worktree_root: Option<PathBuf>,
    git_common_dir: Option<PathBuf>,
    project_key: String,
    project_name: String,
    folder_label: String,
    live_branch: Option<String>,
}

fn canonical_path(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

fn folder_basename(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| path.to_string_lossy().into_owned())
}

fn resolve_cwd_info(raw: &str) -> CwdInfo {
    let standardized = standardize(raw);
    let canonical = canonical_path(&standardized);
    let worktree_root = repository_root(raw).map(|p| canonical_path(&p));
    let git_common_dir = common_git_dir(raw);
    let live_branch = current_branch(raw);

    let (project_key, project_name) = if let Some(common) = &git_common_dir {
        // `<main-repo>/.git` → main repo folder name; bare repo `<name>.git` → stem.
        let name = if common.file_name().is_some_and(|n| n == ".git") {
            common.parent().map(folder_basename).unwrap_or_else(|| folder_basename(common))
        } else {
            let base = folder_basename(common);
            base.strip_suffix(".git").unwrap_or(&base).to_owned()
        };
        (format!("git:{}", common.to_string_lossy()), name)
    } else if let Some(root) = &worktree_root {
        (format!("dir:{}", root.to_string_lossy()), folder_basename(root))
    } else {
        (format!("dir:{}", canonical.to_string_lossy()), folder_basename(&canonical))
    };

    let folder_label =
        worktree_root.as_deref().map(folder_basename).unwrap_or_else(|| folder_basename(&canonical));

    CwdInfo { canonical, worktree_root, git_common_dir, project_key, project_name, folder_label, live_branch }
}

fn path_in_root(path: &Path, root: &Path) -> bool {
    path == root || path.starts_with(root)
}

/// Filters, searches, sorts, and groups `sessions` according to `query`.
pub fn query_sessions(sessions: &[AgentSessionSummary], query: &HistoryQuery) -> HistoryQueryResult {
    let mut cwd_cache: HashMap<String, CwdInfo> = HashMap::new();
    let active_info = query
        .active_cwd
        .as_deref()
        .filter(|s| !s.is_empty())
        .map(|cwd| cwd_cache.entry(cwd.to_owned()).or_insert_with(|| resolve_cwd_info(cwd)).clone());

    let active_workspace_root =
        active_info.as_ref().map(|info| info.worktree_root.as_ref().unwrap_or(&info.canonical).clone());

    let tokens: Vec<String> =
        query.search.split_whitespace().map(|t| t.to_lowercase()).filter(|t| !t.is_empty()).collect();

    let mut scoped_count = 0usize;
    let mut matched: Vec<HistorySessionItem> = Vec::new();

    for session in sessions {
        if let Some(agent_filter) = query.agent
            && session.format != agent_filter
        {
            continue;
        }

        let info = session
            .cwd
            .as_deref()
            .filter(|c| !c.is_empty())
            .map(|cwd| cwd_cache.entry(cwd.to_owned()).or_insert_with(|| resolve_cwd_info(cwd)).clone());

        let is_current_worktree = match (&active_workspace_root, &info) {
            (Some(active_root), Some(sess_info)) => {
                let sess_root = sess_info.worktree_root.as_ref().unwrap_or(&sess_info.canonical);
                sess_root == active_root || path_in_root(&sess_info.canonical, active_root)
            }
            _ => false,
        };

        let is_same_project = match (&active_info, &info) {
            (Some(active), Some(sess_info)) => {
                if let (Some(a_git), Some(s_git)) = (&active.git_common_dir, &sess_info.git_common_dir) {
                    a_git == s_git
                } else {
                    is_current_worktree
                }
            }
            _ => false,
        };

        let in_scope = match query.scope {
            HistoryScope::Workspace => active_info.is_some() && is_current_worktree,
            HistoryScope::Project => active_info.is_some() && (is_same_project || is_current_worktree),
            HistoryScope::All => true,
        };
        if !in_scope {
            continue;
        }
        scoped_count += 1;

        let (project_key, project_name, worktree_label, live_branch) = match &info {
            Some(info) => (
                info.project_key.clone(),
                info.project_name.clone(),
                (!is_current_worktree).then(|| info.folder_label.clone()),
                info.live_branch.clone(),
            ),
            None => ("unknown".to_owned(), "Other".to_owned(), None, None),
        };
        let branch = session.git_branch.clone().or(live_branch);

        let match_snippet = if tokens.is_empty() {
            None
        } else {
            match match_session(session, &project_name, branch.as_deref(), &tokens) {
                Some(snippet) => snippet,
                None => continue,
            }
        };

        matched.push(HistorySessionItem {
            session: session.clone(),
            project_key,
            project_name,
            is_current_worktree,
            worktree_label,
            branch,
            match_snippet,
        });
    }

    sort_items(&mut matched, query.sort);

    let matched_count = matched.len();
    let mut group_order: Vec<String> = Vec::new();
    let mut group_map: HashMap<String, HistoryProjectGroup> = HashMap::new();
    for item in matched {
        if !group_map.contains_key(&item.project_key) {
            group_order.push(item.project_key.clone());
            group_map.insert(
                item.project_key.clone(),
                HistoryProjectGroup {
                    key: item.project_key.clone(),
                    name: item.project_name.clone(),
                    sessions: Vec::new(),
                },
            );
        }
        if let Some(group) = group_map.get_mut(&item.project_key) {
            group.sessions.push(item);
        }
    }

    let groups = group_order.into_iter().filter_map(|key| group_map.remove(&key)).collect();
    HistoryQueryResult { scoped_count, matched_count, groups }
}

fn sort_items(items: &mut [HistorySessionItem], sort: HistorySort) {
    match sort {
        HistorySort::LastUpdated => {
            items.sort_by(|a, b| {
                b.session.updated_at.cmp(&a.session.updated_at).then_with(|| a.session.id.cmp(&b.session.id))
            });
        }
        HistorySort::Created => {
            items.sort_by(|a, b| {
                let a_ts = a.session.created_at.unwrap_or(a.session.updated_at);
                let b_ts = b.session.created_at.unwrap_or(b.session.updated_at);
                b_ts.cmp(&a_ts).then_with(|| a.session.id.cmp(&b.session.id))
            });
        }
        HistorySort::MostMessages => {
            items.sort_by(|a, b| {
                b.session
                    .message_count
                    .cmp(&a.session.message_count)
                    .then_with(|| b.session.updated_at.cmp(&a.session.updated_at))
            });
        }
    }
}

/// Returns `Some(optional_body_snippet)` if every token matches the session's metadata or
/// conversation text; `None` if any token fails to match.
fn match_session(
    session: &AgentSessionSummary,
    project_name: &str,
    branch: Option<&str>,
    tokens: &[String],
) -> Option<Option<String>> {
    let title_lower = session.title.to_lowercase();
    let preview_lower = session.last_message_text.as_deref().unwrap_or("").to_lowercase();
    let cwd_lower = session.cwd.as_deref().unwrap_or("").to_lowercase();
    let branch_lower = branch.unwrap_or("").to_lowercase();
    let model_lower = session.model.as_deref().unwrap_or("").to_lowercase();
    let agent_lower = AgentSessionSummary::full_agent_label(session.format).to_lowercase();
    let short_agent_lower = session.short_agent_label().to_lowercase();
    let project_lower = project_name.to_lowercase();
    let id_lower = session.id.to_lowercase();

    let mut body_lower: Option<String> = None;
    let mut matched_in_body_token: Option<&str> = None;

    for token in tokens {
        let in_meta = title_lower.contains(token.as_str())
            || preview_lower.contains(token.as_str())
            || cwd_lower.contains(token.as_str())
            || branch_lower.contains(token.as_str())
            || model_lower.contains(token.as_str())
            || agent_lower.contains(token.as_str())
            || short_agent_lower.contains(token.as_str())
            || project_lower.contains(token.as_str())
            || id_lower.contains(token.as_str());
        if in_meta {
            continue;
        }
        let body = body_lower.get_or_insert_with(|| session.search_text.to_lowercase());
        if body.contains(token.as_str()) {
            if matched_in_body_token.is_none() {
                matched_in_body_token = Some(token.as_str());
            }
        } else {
            return None;
        }
    }

    let snippet = matched_in_body_token.and_then(|token| extract_match_snippet(&session.search_text, token));
    Some(snippet)
}

/// Extracts a concise single-line snippet centered on the first case-insensitive hit of
/// `token_lower` inside `search_text`.
pub fn extract_match_snippet(search_text: &str, token_lower: &str) -> Option<String> {
    // Search line-by-line (each line is `"You: ..."` or `"Agent: ..."`).
    for line in search_text.lines() {
        let lower = line.to_lowercase();
        let Some(hit_byte) = lower.find(token_lower) else { continue };
        // Convert byte offset in lowercased line to a char index so slicing the original
        // string is always valid UTF-8 even if case-folding changed byte length.
        let hit_char = lower[..hit_byte].chars().count();
        let chars: Vec<char> = line.chars().collect();
        let total = chars.len();
        const WINDOW: usize = 160;
        if total <= WINDOW {
            return Some(line.to_owned());
        }
        let prefix_len = if line.starts_with("You: ") {
            5
        } else if line.starts_with("Agent: ") {
            7
        } else {
            0
        };
        let prefix: String = chars[..prefix_len].iter().collect();
        let body_start = hit_char.saturating_sub(45).max(prefix_len);
        let body_end = (body_start + WINDOW - prefix_len).min(total);
        let slice: String = chars[body_start..body_end].iter().collect();
        let mut out = prefix;
        if body_start > prefix_len {
            out.push('…');
        }
        out.push_str(slice.trim());
        if body_end < total {
            out.push('…');
        }
        return Some(out);
    }
    None
}

/// Compact relative age like `"Just now"`, `"4m ago"`, `"11h ago"`, `"3d ago"`, `"2w ago"`.
pub fn format_relative_age(when: Date, now: Date) -> String {
    let secs = now.signed_duration_since(when).num_seconds();
    if secs < 45 {
        return "Just now".to_owned();
    }
    let mins = secs / 60;
    if mins < 60 {
        return format!("{mins}m ago");
    }
    let hours = mins / 60;
    if hours < 24 {
        return format!("{hours}h ago");
    }
    let days = hours / 24;
    if days < 14 {
        return format!("{days}d ago");
    }
    let weeks = days / 7;
    if weeks < 8 {
        return format!("{weeks}w ago");
    }
    let months = days / 30;
    if months < 12 {
        return format!("{months}mo ago");
    }
    format!("{}y ago", days / 365)
}
