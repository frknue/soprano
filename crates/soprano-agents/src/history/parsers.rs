//! Streaming parsers that extract session metadata, recent turns, and searchable text from
//! Claude Code, omp, Codex, and OpenCode transcripts on disk.

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use chrono::DateTime;
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;
use soprano_types::AgentConversation;

use crate::json::{Object, bool_true, obj_at, objects, objects_at, parse_object, str_at};
use crate::timeline::{AgentTranscriptFormat, Date, date_from_value};

use super::{AgentSessionSummary, HistoryMessageRole, HistoryTurnSnippet};

/// Maximum UTF-8 bytes of conversation prose indexed per session for search.
const MAX_SEARCH_TEXT_BYTES: usize = 48 * 1024;
/// Maximum characters stored for a single preview message.
const MAX_PREVIEW_CHARS: usize = 240;
/// Maximum characters stored for a title derived from the first user prompt.
const MAX_TITLE_CHARS: usize = 120;
/// Maximum recent messages kept per session for inline card expansion.
const MAX_RECENT_MESSAGES: usize = 6;
/// Maximum single JSONL line length we fully parse (larger lines are usually embedded images
/// or huge tool outputs; we still inspect smaller/normal lines completely).
const MAX_PARSE_LINE_BYTES: usize = 2 * 1024 * 1024;

/// A candidate file discovered on disk for one CLI.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct DiscoveredSource {
    pub format: AgentTranscriptFormat,
    pub path: PathBuf,
    pub size: u64,
    pub modified_ms: i64,
}

/// Discovers every transcript file or database under `home` (and optional env overrides).
pub(super) fn discover_sources(home: &Path, env: &HashMap<String, String>) -> Vec<DiscoveredSource> {
    let mut sources = Vec::new();
    discover_claude(home, &mut sources);
    discover_omp(home, env, &mut sources);
    discover_codex(home, env, &mut sources);
    discover_opencode(home, env, &mut sources);
    discover_agy(home, &mut sources);
    sources
}

fn file_stamp(path: &Path) -> Option<(u64, i64)> {
    let meta = std::fs::metadata(path).ok()?;
    if !meta.is_file() {
        return None;
    }
    let modified_ms = meta.modified().ok().map(system_time_to_millis).unwrap_or(0);
    Some((meta.len(), modified_ms))
}

fn system_time_to_millis(time: SystemTime) -> i64 {
    time.duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as i64)
}

fn date_from_modified_ms(ms: i64) -> Date {
    DateTime::from_timestamp_millis(ms).unwrap_or(DateTime::UNIX_EPOCH)
}

/// `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`
fn discover_claude(home: &Path, out: &mut Vec<DiscoveredSource>) {
    let projects = home.join(".claude/projects");
    let Ok(dirs) = std::fs::read_dir(projects) else { return };
    for dir in dirs.flatten() {
        let Ok(kind) = dir.file_type() else { continue };
        if !kind.is_dir() {
            continue;
        }
        let Ok(files) = std::fs::read_dir(dir.path()) else { continue };
        for entry in files.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if !name.ends_with(".jsonl") || name.starts_with("agent-") || name.starts_with('.') {
                continue;
            }
            let path = entry.path();
            let Some((size, modified_ms)) = file_stamp(&path) else { continue };
            if size == 0 {
                continue;
            }
            out.push(DiscoveredSource { format: AgentTranscriptFormat::ClaudeCode, path, size, modified_ms });
        }
    }
}

/// `<home>/<PI_CONFIG_DIR or .omp>/agent/sessions/<encoded-cwd>/<time>_<id>.jsonl`
fn discover_omp(home: &Path, env: &HashMap<String, String>, out: &mut Vec<DiscoveredSource>) {
    let mut roots = vec![home.join(".omp/agent/sessions")];
    if let Some(custom) = env.get("PI_CONFIG_DIR").filter(|s| !s.is_empty()) {
        let candidate = PathBuf::from(custom);
        let dir = if candidate.is_absolute() {
            candidate.join("agent/sessions")
        } else {
            home.join(custom).join("agent/sessions")
        };
        if !roots.contains(&dir) {
            roots.push(dir);
        }
    }
    let mut seen = HashSet::new();
    for root in roots {
        let Ok(dirs) = std::fs::read_dir(root) else { continue };
        for dir in dirs.flatten() {
            let Ok(kind) = dir.file_type() else { continue };
            if !kind.is_dir() {
                continue;
            }
            let Ok(files) = std::fs::read_dir(dir.path()) else { continue };
            for entry in files.flatten() {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if !name.ends_with(".jsonl") || name.starts_with('.') {
                    continue;
                }
                let path = entry.path();
                if !seen.insert(path.clone()) {
                    continue;
                }
                let Some((size, modified_ms)) = file_stamp(&path) else { continue };
                if size == 0 {
                    continue;
                }
                out.push(DiscoveredSource { format: AgentTranscriptFormat::Omp, path, size, modified_ms });
            }
        }
    }
}

/// `<CODEX_HOME or ~/.codex>/sessions/YYYY/MM/DD/rollout-*.jsonl`
fn discover_codex(home: &Path, env: &HashMap<String, String>, out: &mut Vec<DiscoveredSource>) {
    let mut roots = vec![home.join(".codex/sessions")];
    if let Some(custom) = env.get("CODEX_HOME").filter(|s| !s.is_empty()) {
        let dir = PathBuf::from(custom).join("sessions");
        if !roots.contains(&dir) {
            roots.push(dir);
        }
    }
    let mut seen = HashSet::new();
    for root in roots {
        let mut pending = vec![root];
        while let Some(dir) = pending.pop() {
            let Ok(entries) = std::fs::read_dir(&dir) else { continue };
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
                if !name.starts_with("rollout-") || !name.ends_with(".jsonl") {
                    continue;
                }
                if !seen.insert(path.clone()) {
                    continue;
                }
                let Some((size, modified_ms)) = file_stamp(&path) else { continue };
                if size == 0 {
                    continue;
                }
                out.push(DiscoveredSource { format: AgentTranscriptFormat::Codex, path, size, modified_ms });
            }
        }
    }
}

/// `~/.local/share/opencode/opencode*.db` (+ `XDG_DATA_HOME`)
fn discover_opencode(home: &Path, env: &HashMap<String, String>, out: &mut Vec<DiscoveredSource>) {
    let mut dirs = vec![home.join(".local/share/opencode")];
    if let Some(data_home) = env.get("XDG_DATA_HOME").filter(|s| !s.is_empty()) {
        let dir = PathBuf::from(data_home).join("opencode");
        if !dirs.contains(&dir) {
            dirs.push(dir);
        }
    }
    let mut seen = HashSet::new();
    for dir in dirs {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if !name.starts_with("opencode") || !name.ends_with(".db") {
                continue;
            }
            let path = entry.path();
            if !seen.insert(path.clone()) {
                continue;
            }
            let Some((mut size, mut modified_ms)) = file_stamp(&path) else { continue };
            // Include SQLite WAL file's size and mtime so live writes invalidate the cache.
            let mut wal_os = path.as_os_str().to_os_string();
            wal_os.push("-wal");
            if let Some((wal_size, wal_modified)) = file_stamp(Path::new(&wal_os)) {
                size = size.saturating_add(wal_size);
                modified_ms = modified_ms.max(wal_modified);
            }
            out.push(DiscoveredSource { format: AgentTranscriptFormat::OpenCode, path, size, modified_ms });
        }
    }
}

/// `~/.gemini/antigravity-cli/brain/<conversation-id>/.system_generated/logs/transcript.jsonl`
/// (and `~/.gemini/antigravity/brain/…`).
fn discover_agy(home: &Path, out: &mut Vec<DiscoveredSource>) {
    let mut seen = HashSet::new();
    for root in [home.join(".gemini/antigravity-cli/brain"), home.join(".gemini/antigravity/brain")] {
        let Ok(dirs) = std::fs::read_dir(root) else { continue };
        for dir in dirs.flatten() {
            let Ok(kind) = dir.file_type() else { continue };
            if !kind.is_dir() {
                continue;
            }
            let path = dir.path().join(".system_generated/logs/transcript.jsonl");
            if !seen.insert(path.clone()) {
                continue;
            }
            let Some((size, modified_ms)) = file_stamp(&path) else { continue };
            if size == 0 {
                continue;
            }
            out.push(DiscoveredSource { format: AgentTranscriptFormat::Agy, path, size, modified_ms });
        }
    }
}

/// Parses one discovered file or database into zero or more session summaries.
pub(super) fn parse_source(source: &DiscoveredSource) -> Vec<AgentSessionSummary> {
    match source.format {
        AgentTranscriptFormat::ClaudeCode => {
            parse_claude_file(&source.path, source.modified_ms).into_iter().collect()
        }
        AgentTranscriptFormat::Omp => parse_omp_file(&source.path, source.modified_ms).into_iter().collect(),
        AgentTranscriptFormat::Codex => {
            parse_codex_file(&source.path, source.modified_ms).into_iter().collect()
        }
        AgentTranscriptFormat::OpenCode => parse_opencode_db(&source.path),
        AgentTranscriptFormat::Agy => parse_agy_file(&source.path, source.modified_ms).into_iter().collect(),
    }
}

// MARK: - Shared accumulator

struct SessionAccumulator {
    id: Option<String>,
    cwd: Option<String>,
    git_branch: Option<String>,
    explicit_title: Option<String>,
    summary_title: Option<String>,
    model: Option<String>,
    first_prompt: Option<String>,
    last_message_role: Option<HistoryMessageRole>,
    last_message_text: Option<String>,
    message_count: usize,
    subagent_count: usize,
    created_at: Option<Date>,
    updated_at: Option<Date>,
    recent_messages: Vec<HistoryTurnSnippet>,
    search_text: String,
}

impl SessionAccumulator {
    fn new() -> Self {
        Self {
            id: None,
            cwd: None,
            git_branch: None,
            explicit_title: None,
            summary_title: None,
            model: None,
            first_prompt: None,
            last_message_role: None,
            last_message_text: None,
            message_count: 0,
            subagent_count: 0,
            created_at: None,
            updated_at: None,
            recent_messages: Vec::new(),
            search_text: String::new(),
        }
    }

    fn note_timestamp(&mut self, ts: Option<Date>) {
        let Some(ts) = ts else { return };
        if self.created_at.is_none_or(|c| ts < c) {
            self.created_at = Some(ts);
        }
        if self.updated_at.is_none_or(|u| ts > u) {
            self.updated_at = Some(ts);
        }
    }

    fn push_message(&mut self, role: HistoryMessageRole, raw_text: &str) {
        let normalized = normalize_whitespace(raw_text);
        if normalized.is_empty() {
            return;
        }
        self.message_count += 1;
        if role == HistoryMessageRole::User && self.first_prompt.is_none() {
            self.first_prompt = Some(truncate_chars(&normalized, MAX_PREVIEW_CHARS));
        }
        let preview = truncate_chars(&normalized, MAX_PREVIEW_CHARS);
        self.last_message_role = Some(role);
        self.last_message_text = Some(preview.clone());
        self.recent_messages.push(HistoryTurnSnippet { role, text: preview });
        if self.recent_messages.len() > MAX_RECENT_MESSAGES {
            self.recent_messages.remove(0);
        }
        append_search_text(&mut self.search_text, role, &normalized);
    }

    fn finish(
        self,
        format: AgentTranscriptFormat,
        fallback_id: Option<String>,
        modified_ms: i64,
        transcript_path: PathBuf,
    ) -> Option<AgentSessionSummary> {
        let id = self.id.or(fallback_id).filter(|id| AgentConversation::valid_id(id))?;
        if self.message_count == 0 && self.explicit_title.is_none() && self.summary_title.is_none() {
            return None;
        }
        let title = self
            .explicit_title
            .or(self.summary_title)
            .or_else(|| self.first_prompt.as_deref().map(|p| truncate_chars(p, MAX_TITLE_CHARS)))
            .unwrap_or_else(|| "Untitled session".to_owned());
        let updated_at = self.updated_at.unwrap_or_else(|| date_from_modified_ms(modified_ms));
        Some(AgentSessionSummary {
            id,
            format,
            profile_id: profile_id_for_format(format),
            title,
            first_prompt: self.first_prompt,
            last_message_role: self.last_message_role,
            last_message_text: self.last_message_text,
            cwd: self.cwd,
            git_branch: self.git_branch,
            model: self.model,
            message_count: self.message_count,
            subagent_count: self.subagent_count,
            created_at: self.created_at,
            updated_at,
            transcript_path: Some(transcript_path),
            recent_messages: self.recent_messages,
            search_text: self.search_text,
        })
    }
}

pub(super) fn profile_id_for_format(format: AgentTranscriptFormat) -> &'static str {
    match format {
        AgentTranscriptFormat::ClaudeCode => "claude-code",
        AgentTranscriptFormat::Codex => "codex",
        AgentTranscriptFormat::Omp => "omp",
        AgentTranscriptFormat::OpenCode => "opencode",
        AgentTranscriptFormat::Agy => "agy",
    }
}

fn append_search_text(buf: &mut String, role: HistoryMessageRole, text: &str) {
    if buf.len() >= MAX_SEARCH_TEXT_BYTES {
        return;
    }
    if !buf.is_empty() {
        buf.push('\n');
    }
    let prefix = match role {
        HistoryMessageRole::User => "You: ",
        HistoryMessageRole::Assistant => "Agent: ",
    };
    let remaining = MAX_SEARCH_TEXT_BYTES.saturating_sub(buf.len() + prefix.len());
    if remaining == 0 {
        return;
    }
    buf.push_str(prefix);
    if text.len() <= remaining {
        buf.push_str(text);
    } else {
        let mut end = remaining;
        while end > 0 && !text.is_char_boundary(end) {
            end -= 1;
        }
        buf.push_str(&text[..end]);
    }
}

pub(super) fn normalize_whitespace(text: &str) -> String {
    let mut out = String::with_capacity(text.len().min(512));
    let mut last_space = true;
    for ch in text.chars() {
        if ch.is_whitespace() {
            if !last_space {
                out.push(' ');
                last_space = true;
            }
        } else {
            out.push(ch);
            last_space = false;
        }
    }
    if out.ends_with(' ') {
        out.pop();
    }
    out
}

pub(super) fn truncate_chars(text: &str, max_chars: usize) -> String {
    let mut chars = text.chars();
    let mut out: String = chars.by_ref().take(max_chars).collect();
    if chars.next().is_some() {
        if let Some(last_space) = out.rfind(' ')
            && last_space > max_chars / 2
        {
            out.truncate(last_space);
        }
        out.push('…');
    }
    out
}

fn read_jsonl_lines(path: &Path, mut handle: impl FnMut(&[u8])) -> bool {
    let Ok(file) = File::open(path) else { return false };
    let mut reader = BufReader::with_capacity(64 * 1024, file);
    let mut buf = Vec::new();
    loop {
        buf.clear();
        let Ok(read) = reader.read_until(b'\n', &mut buf) else { break };
        if read == 0 {
            break;
        }
        if buf.ends_with(b"\n") {
            buf.pop();
        }
        if buf.ends_with(b"\r") {
            buf.pop();
        }
        if buf.is_empty() || buf.len() > MAX_PARSE_LINE_BYTES {
            continue;
        }
        handle(&buf);
    }
    true
}

// MARK: - Claude Code

fn parse_claude_file(path: &Path, modified_ms: i64) -> Option<AgentSessionSummary> {
    let fallback_id = path.file_stem().and_then(|s| s.to_str()).map(str::to_owned);
    let mut acc = SessionAccumulator::new();
    let mut saw_non_sidechain = false;
    let mut saw_any_message = false;

    if !read_jsonl_lines(path, |line| {
        // Fast pre-skip for noisy bookkeeping lines.
        if line_contains(line, b"\"file-history-snapshot\"") || line_contains(line, b"\"type\":\"progress\"")
        {
            return;
        }
        let Some(record) = parse_object(line) else { return };
        if acc.id.is_none()
            && let Some(id) = str_at(&record, "sessionId").filter(|id| AgentConversation::valid_id(id))
        {
            acc.id = Some(id.to_owned());
        }
        if let Some(cwd) = str_at(&record, "cwd").filter(|c| !c.is_empty()) {
            acc.cwd = Some(cwd.to_owned());
        }
        if let Some(branch) = str_at(&record, "gitBranch").filter(|b| !b.is_empty()) {
            acc.git_branch = Some(branch.to_owned());
        }
        let ts = date_from_value(record.get("timestamp"));
        acc.note_timestamp(ts);

        match str_at(&record, "type") {
            Some("custom-title") => {
                if let Some(title) = str_at(&record, "customTitle").map(normalize_whitespace)
                    && !title.is_empty()
                {
                    acc.explicit_title = Some(truncate_chars(&title, MAX_TITLE_CHARS));
                }
            }
            Some("ai-title") => {
                if let Some(title) = str_at(&record, "aiTitle").map(normalize_whitespace)
                    && !title.is_empty()
                {
                    acc.explicit_title = Some(truncate_chars(&title, MAX_TITLE_CHARS));
                }
            }
            Some("summary") => {
                if let Some(summary) = str_at(&record, "summary").map(normalize_whitespace)
                    && !summary.is_empty()
                {
                    acc.summary_title = Some(truncate_chars(&summary, MAX_TITLE_CHARS));
                }
            }
            Some("user") => {
                saw_any_message = true;
                if bool_true(&record, "isSidechain") {
                    return;
                }
                saw_non_sidechain = true;
                if bool_true(&record, "isMeta") || bool_true(&record, "isCompactSummary") {
                    return;
                }
                if let Some(text) = claude_user_text(&record) {
                    acc.push_message(HistoryMessageRole::User, &text);
                }
            }
            Some("assistant") => {
                saw_any_message = true;
                if bool_true(&record, "isSidechain") {
                    return;
                }
                saw_non_sidechain = true;
                if let Some(message) = obj_at(&record, "message") {
                    if let Some(model) =
                        str_at(message, "model").filter(|m| !m.is_empty() && *m != "<synthetic>")
                    {
                        acc.model = Some(model.to_owned());
                    }
                    let mut reply_parts = Vec::new();
                    for part in objects_at(message, "content") {
                        match str_at(part, "type") {
                            Some("text") => {
                                if let Some(text) = str_at(part, "text").filter(|t| !t.trim().is_empty()) {
                                    reply_parts.push(text);
                                }
                            }
                            Some("tool_use") => {
                                if matches!(str_at(part, "name"), Some("Agent" | "Task")) {
                                    acc.subagent_count += 1;
                                }
                            }
                            _ => {}
                        }
                    }
                    if !reply_parts.is_empty() {
                        acc.push_message(HistoryMessageRole::Assistant, &reply_parts.join(" "));
                    }
                }
            }
            _ => {}
        }
    }) {
        return None;
    }

    // Pure sidechain file (standalone subagent transcript).
    if saw_any_message && !saw_non_sidechain {
        return None;
    }

    // Also check `<project>/<session-id>/subagents/*.jsonl`.
    if let Some(stem) = path.file_stem()
        && let Some(parent) = path.parent()
    {
        let subagents_dir = parent.join(stem).join("subagents");
        if let Ok(entries) = std::fs::read_dir(subagents_dir) {
            let count =
                entries.flatten().filter(|e| e.file_name().to_string_lossy().ends_with(".jsonl")).count();
            acc.subagent_count = acc.subagent_count.max(count);
        }
    }

    acc.finish(AgentTranscriptFormat::ClaudeCode, fallback_id, modified_ms, path.to_path_buf())
}

fn claude_user_text(record: &Object) -> Option<String> {
    let message = obj_at(record, "message")?;
    if let Some(text) = str_at(message, "content") {
        let trimmed = text.trim();
        for skip in [
            "<local-command-stdout>",
            "<local-command-stderr>",
            "<local-command-caveat>",
            "<bash-stdout>",
            "<bash-stderr>",
        ] {
            if trimmed.starts_with(skip) {
                return None;
            }
        }
        if let Some(cmd) = claude_slash_command(trimmed) {
            return Some(cmd);
        }
        if let Some(bash) = tag_content("bash-input", trimmed) {
            return Some(format!("! {}", bash.trim()));
        }
        if trimmed.starts_with("[Request interrupted by user") || trimmed.is_empty() {
            return None;
        }
        return Some(trimmed.to_owned());
    }
    let parts = objects(message.get("content"))?;
    let texts: Vec<&str> = parts
        .into_iter()
        .filter(|p| str_at(p, "type") == Some("text"))
        .filter_map(|p| str_at(p, "text"))
        .map(str::trim)
        .filter(|t| !t.is_empty() && !t.starts_with("[Request interrupted by user"))
        .collect();
    if texts.is_empty() { None } else { Some(texts.join(" ")) }
}

fn claude_slash_command(text: &str) -> Option<String> {
    let name = tag_content("command-name", text)?.trim();
    if name.is_empty() {
        return None;
    }
    let command = if name.starts_with('/') { name.to_owned() } else { format!("/{name}") };
    let args = tag_content("command-args", text).unwrap_or("").trim();
    Some(if args.is_empty() { command } else { format!("{command} {args}") })
}

fn tag_content<'a>(tag: &str, text: &'a str) -> Option<&'a str> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let start = text.find(&open)? + open.len();
    let end = text[start..].find(&close)? + start;
    Some(&text[start..end])
}

// MARK: - omp

fn parse_omp_file(path: &Path, modified_ms: i64) -> Option<AgentSessionSummary> {
    let fallback_id = path
        .file_stem()
        .and_then(|s| s.to_str())
        .and_then(|stem| stem.rsplit_once('_').map(|(_, id)| id).or(Some(stem)))
        .map(str::to_owned);
    let mut acc = SessionAccumulator::new();

    if !read_jsonl_lines(path, |line| {
        let Some(record) = parse_object(line) else { return };
        let Some(kind) = str_at(&record, "type") else { return };
        acc.note_timestamp(date_from_value(record.get("timestamp")));
        match kind {
            "session" => {
                if let Some(id) = str_at(&record, "id").filter(|id| AgentConversation::valid_id(id)) {
                    acc.id = Some(id.to_owned());
                }
                if let Some(cwd) = str_at(&record, "cwd").filter(|c| !c.is_empty()) {
                    acc.cwd = Some(cwd.to_owned());
                }
            }
            "title" => {
                if let Some(title) = str_at(&record, "title").map(normalize_whitespace)
                    && !title.is_empty()
                {
                    acc.explicit_title = Some(truncate_chars(&title, MAX_TITLE_CHARS));
                }
            }
            "model_change" => {
                if let Some(model) =
                    str_at(&record, "modelId").or_else(|| str_at(&record, "model")).filter(|m| !m.is_empty())
                {
                    acc.model = Some(short_model_name(model));
                }
            }
            "message" => {
                let Some(message) = obj_at(&record, "message") else { return };
                match str_at(message, "role") {
                    Some("user") => {
                        if let Some(attr) = str_at(message, "attribution")
                            && attr != "user"
                        {
                            return;
                        }
                        let text = omp_user_text(message.get("content"));
                        if !text.is_empty() {
                            acc.push_message(HistoryMessageRole::User, &text);
                        }
                    }
                    Some("assistant") => {
                        if let Some(model) = str_at(message, "model").filter(|m| !m.is_empty()) {
                            acc.model = Some(short_model_name(model));
                        }
                        let mut reply_parts = Vec::new();
                        for part in objects_at(message, "content") {
                            match str_at(part, "type") {
                                Some("text") => {
                                    if let Some(text) = str_at(part, "text").filter(|t| !t.trim().is_empty())
                                    {
                                        reply_parts.push(text);
                                    }
                                }
                                Some("toolCall") if str_at(part, "name") == Some("task") => {
                                    acc.subagent_count += 1;
                                }
                                _ => {}
                            }
                        }
                        if !reply_parts.is_empty() {
                            acc.push_message(HistoryMessageRole::Assistant, &reply_parts.join(" "));
                        }
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }) {
        return None;
    }

    acc.finish(AgentTranscriptFormat::Omp, fallback_id, modified_ms, path.to_path_buf())
}

fn omp_user_text(content: Option<&Value>) -> String {
    if let Some(text) = content.and_then(Value::as_str) {
        return text.to_owned();
    }
    let Some(parts) = objects(content) else { return String::new() };
    parts
        .into_iter()
        .filter(|p| str_at(p, "type") == Some("text"))
        .filter_map(|p| str_at(p, "text"))
        .collect::<Vec<_>>()
        .join(" ")
}

fn short_model_name(raw: &str) -> String {
    // Strip provider prefix like `anthropic/claude-opus-4-6` → `claude-opus-4-6`.
    raw.rsplit('/').next().unwrap_or(raw).to_owned()
}

// MARK: - Codex

fn parse_codex_file(path: &Path, modified_ms: i64) -> Option<AgentSessionSummary> {
    let fallback_id = codex_thread_id_from_filename(path);
    let mut acc = SessionAccumulator::new();
    let mut event_msgs: Vec<(HistoryMessageRole, String)> = Vec::new();
    let mut response_msgs: Vec<(HistoryMessageRole, String)> = Vec::new();

    if !read_jsonl_lines(path, |line| {
        let Some(record) = parse_object(line) else { return };
        let Some(kind) = str_at(&record, "type") else { return };
        let Some(payload) = obj_at(&record, "payload") else { return };
        acc.note_timestamp(date_from_value(record.get("timestamp")));
        match kind {
            "session_meta" => {
                if let Some(id) = str_at(payload, "id").filter(|id| AgentConversation::valid_id(id)) {
                    acc.id = Some(id.to_owned());
                }
                if let Some(cwd) = str_at(payload, "cwd").filter(|c| !c.is_empty()) {
                    acc.cwd = Some(cwd.to_owned());
                }
                if let Some(git) = obj_at(payload, "git")
                    && let Some(branch) = str_at(git, "branch").filter(|b| !b.is_empty())
                {
                    acc.git_branch = Some(branch.to_owned());
                }
                acc.note_timestamp(date_from_value(payload.get("timestamp")));
            }
            "turn_context" => {
                if let Some(cwd) = str_at(payload, "cwd").filter(|c| !c.is_empty()) {
                    acc.cwd = Some(cwd.to_owned());
                }
                if let Some(model) = str_at(payload, "model").filter(|m| !m.is_empty()) {
                    acc.model = Some(short_model_name(model));
                }
            }
            "event_msg" => match str_at(payload, "type") {
                Some("item_completed") => {
                    let Some(item) = obj_at(payload, "item") else { return };
                    match str_at(item, "type") {
                        Some("UserMessage") => {
                            let text: String = objects_at(item, "content")
                                .into_iter()
                                .filter(|p| str_at(p, "type") == Some("text"))
                                .filter_map(|p| str_at(p, "text"))
                                .collect::<Vec<_>>()
                                .join(" ");
                            if !text.trim().is_empty() {
                                event_msgs.push((HistoryMessageRole::User, text));
                            }
                        }
                        Some("AgentMessage") => {
                            let text: String = objects_at(item, "content")
                                .into_iter()
                                .filter_map(|p| str_at(p, "text"))
                                .collect::<Vec<_>>()
                                .join(" ");
                            if !text.trim().is_empty() {
                                event_msgs.push((HistoryMessageRole::Assistant, text));
                            }
                        }
                        _ => {}
                    }
                }
                Some("user_message") => {
                    if let Some(text) = str_at(payload, "message").filter(|t| !t.trim().is_empty()) {
                        event_msgs.push((HistoryMessageRole::User, text.to_owned()));
                    }
                }
                Some("agent_message") => {
                    if let Some(text) = str_at(payload, "message").filter(|t| !t.trim().is_empty()) {
                        event_msgs.push((HistoryMessageRole::Assistant, text.to_owned()));
                    }
                }
                _ => {}
            },
            "response_item" => match str_at(payload, "type") {
                Some("function_call") => {
                    if matches!(str_at(payload, "name"), Some("spawn_agent" | "subagent")) {
                        acc.subagent_count += 1;
                    }
                }
                Some("message") => {
                    let role = match str_at(payload, "role") {
                        Some("user") => HistoryMessageRole::User,
                        Some("assistant") => HistoryMessageRole::Assistant,
                        _ => return,
                    };
                    let text: String = objects_at(payload, "content")
                        .into_iter()
                        .filter_map(|p| str_at(p, "text"))
                        .collect::<Vec<_>>()
                        .join(" ");
                    let trimmed = text.trim();
                    if trimmed.is_empty() || is_codex_injected_user_message(trimmed) {
                        return;
                    }
                    response_msgs.push((role, trimmed.to_owned()));
                }
                _ => {}
            },
            _ => {}
        }
    }) {
        return None;
    }

    let chosen = if !event_msgs.is_empty() { event_msgs } else { response_msgs };
    for (role, text) in chosen {
        acc.push_message(role, &text);
    }

    acc.finish(AgentTranscriptFormat::Codex, fallback_id, modified_ms, path.to_path_buf())
}

fn is_codex_injected_user_message(text: &str) -> bool {
    text.starts_with("<environment_context>")
        || text.starts_with("# AGENTS.md")
        || text.starts_with("<INSTRUCTIONS>")
        || text.starts_with("<permissions instructions>")
}

fn codex_thread_id_from_filename(path: &Path) -> Option<String> {
    let stem = path.file_stem()?.to_str()?;
    let rest = stem.strip_prefix("rollout-")?;
    // `rollout-2026-10-12T09-00-00-<uuid-or-id>`
    if rest.len() > 20 && rest.as_bytes().get(19) == Some(&b'-') {
        return Some(rest[20..].to_owned());
    }
    rest.rsplit_once('-').map(|(_, id)| id.to_owned())
}

// MARK: - OpenCode SQLite

fn parse_opencode_db(path: &Path) -> Vec<AgentSessionSummary> {
    let Ok(db) =
        Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)
    else {
        return Vec::new();
    };
    let _ = db.busy_timeout(Duration::from_millis(2_000));

    if table_exists(&db, "session_v2") {
        parse_opencode_v2(&db, path)
    } else if table_exists(&db, "session") {
        parse_opencode_legacy(&db, path)
    } else {
        Vec::new()
    }
}

fn table_exists(db: &Connection, name: &str) -> bool {
    db.query_row("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [name], |_| Ok(())).is_ok()
}

fn table_columns(db: &Connection, table: &str) -> HashSet<String> {
    let Ok(mut stmt) = db.prepare(&format!("PRAGMA table_info({table})")) else {
        return HashSet::new();
    };
    let Ok(rows) = stmt.query_map([], |row| row.get::<_, String>(1)) else {
        return HashSet::new();
    };
    rows.flatten().collect()
}

struct OpenCodeSessionRow {
    id: String,
    directory: Option<String>,
    title: Option<String>,
    parent_id: Option<String>,
    time_created: i64,
    time_updated: i64,
}

fn load_opencode_session_rows(db: &Connection, table: &str) -> Vec<OpenCodeSessionRow> {
    let cols = table_columns(db, table);
    let title_expr = if cols.contains("title") { "title" } else { "NULL" };
    let parent_expr = if cols.contains("parent_id") { "parent_id" } else { "NULL" };
    let created_expr = if cols.contains("time_created") { "coalesce(time_created, 0)" } else { "0" };
    let updated_expr = if cols.contains("time_updated") { "coalesce(time_updated, 0)" } else { "0" };
    let sql = format!(
        "SELECT id, directory, {title_expr}, {parent_expr}, {created_expr}, {updated_expr} FROM {table}"
    );
    let Ok(mut stmt) = db.prepare(&sql) else { return Vec::new() };
    let Ok(rows) = stmt.query_map([], |row| {
        Ok(OpenCodeSessionRow {
            id: row.get::<_, String>(0)?,
            directory: row.get::<_, Option<String>>(1).ok().flatten(),
            title: row.get::<_, Option<String>>(2).ok().flatten(),
            parent_id: row.get::<_, Option<String>>(3).ok().flatten(),
            time_created: row.get::<_, i64>(4).unwrap_or(0),
            time_updated: row.get::<_, i64>(5).unwrap_or(0),
        })
    }) else {
        return Vec::new();
    };
    rows.flatten().collect()
}

fn parse_opencode_v2(db: &Connection, path: &Path) -> Vec<AgentSessionSummary> {
    let rows = load_opencode_session_rows(db, "session_v2");
    if rows.is_empty() {
        return Vec::new();
    }
    let mut subagent_counts: HashMap<String, usize> = HashMap::new();
    for row in &rows {
        if let Some(parent) = row.parent_id.as_deref().filter(|p| !p.is_empty()) {
            *subagent_counts.entry(parent.to_owned()).or_default() += 1;
        }
    }

    let mut sessions = Vec::new();
    let has_parts = table_exists(db, "session_part");
    for row in rows {
        if row.parent_id.as_deref().is_some_and(|p| !p.is_empty()) {
            continue;
        }
        if !AgentConversation::valid_id(&row.id) {
            continue;
        }
        let mut acc = SessionAccumulator::new();
        acc.id = Some(row.id.clone());
        acc.cwd = row.directory.filter(|d| !d.is_empty());
        if let Some(title) = row.title.map(|t| normalize_whitespace(&t)).filter(|t| !t.is_empty()) {
            acc.explicit_title = Some(truncate_chars(&title, MAX_TITLE_CHARS));
        }
        acc.subagent_count = subagent_counts.get(&row.id).copied().unwrap_or(0);
        if row.time_created > 0 {
            acc.note_timestamp(DateTime::from_timestamp_millis(row.time_created));
        }
        if row.time_updated > 0 {
            acc.note_timestamp(DateTime::from_timestamp_millis(row.time_updated));
        }

        // Load parts grouped by message_id if session_part exists.
        let mut parts_by_msg: HashMap<String, Vec<String>> = HashMap::new();
        if has_parts
            && let Ok(mut stmt) = db.prepare(
                "SELECT message_id, type, data FROM session_part WHERE session_id = ? ORDER BY ordinal ASC",
            )
            && let Ok(part_rows) = stmt.query_map([&row.id], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1).unwrap_or_default(),
                    r.get::<_, String>(2).unwrap_or_default(),
                ))
            })
        {
            for (msg_id, ptype, data) in part_rows.flatten() {
                if ptype == "text"
                    && let Some(obj) = parse_object(data.as_bytes())
                    && let Some(text) = str_at(&obj, "text").filter(|t| !t.trim().is_empty())
                {
                    parts_by_msg.entry(msg_id).or_default().push(text.to_owned());
                }
            }
        }

        if let Ok(mut stmt) = db.prepare(
            "SELECT id, type, time_created, time_updated, data FROM session_message WHERE session_id = ? ORDER BY seq ASC",
        ) && let Ok(msg_rows) = stmt.query_map([&row.id], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1).unwrap_or_default(),
                r.get::<_, i64>(2).unwrap_or(0),
                r.get::<_, i64>(3).unwrap_or(0),
                r.get::<_, String>(4).unwrap_or_default(),
            ))
        }) {
            for (msg_id, kind, created, updated, data) in msg_rows.flatten() {
                if created > 0 {
                    acc.note_timestamp(DateTime::from_timestamp_millis(created));
                }
                if updated > 0 {
                    acc.note_timestamp(DateTime::from_timestamp_millis(updated));
                }
                let Some(obj) = parse_object(data.as_bytes()) else { continue };
                if let Some(model) = extract_opencode_model(&obj) {
                    acc.model = Some(model);
                }
                match kind.as_str() {
                    "user" => {
                        let text = str_at(&obj, "text")
                            .map(str::to_owned)
                            .or_else(|| parts_by_msg.get(&msg_id).map(|p| p.join(" ")))
                            .unwrap_or_default();
                        acc.push_message(HistoryMessageRole::User, &text);
                    }
                    "assistant" => {
                        let mut texts: Vec<String> = objects_at(&obj, "content")
                            .into_iter()
                            .filter(|p| str_at(p, "type") == Some("text"))
                            .filter_map(|p| str_at(p, "text"))
                            .map(str::to_owned)
                            .collect();
                        if let Some(extra) = parts_by_msg.get(&msg_id) {
                            texts.extend(extra.iter().cloned());
                        }
                        if !texts.is_empty() {
                            acc.push_message(HistoryMessageRole::Assistant, &texts.join(" "));
                        }
                    }
                    _ => {}
                }
            }
        }

        if let Some(summary) =
            acc.finish(AgentTranscriptFormat::OpenCode, Some(row.id), row.time_updated, path.to_path_buf())
        {
            sessions.push(summary);
        }
    }
    sessions
}

fn parse_opencode_legacy(db: &Connection, path: &Path) -> Vec<AgentSessionSummary> {
    let rows = load_opencode_session_rows(db, "session");
    if rows.is_empty() {
        return Vec::new();
    }
    let mut subagent_counts: HashMap<String, usize> = HashMap::new();
    for row in &rows {
        if let Some(parent) = row.parent_id.as_deref().filter(|p| !p.is_empty()) {
            *subagent_counts.entry(parent.to_owned()).or_default() += 1;
        }
    }

    let mut sessions = Vec::new();
    let has_parts = table_exists(db, "part");
    for row in rows {
        if row.parent_id.as_deref().is_some_and(|p| !p.is_empty()) {
            continue;
        }
        if !AgentConversation::valid_id(&row.id) {
            continue;
        }
        let mut acc = SessionAccumulator::new();
        acc.id = Some(row.id.clone());
        acc.cwd = row.directory.filter(|d| !d.is_empty());
        if let Some(title) = row.title.map(|t| normalize_whitespace(&t)).filter(|t| !t.is_empty()) {
            acc.explicit_title = Some(truncate_chars(&title, MAX_TITLE_CHARS));
        }
        acc.subagent_count = subagent_counts.get(&row.id).copied().unwrap_or(0);
        if row.time_created > 0 {
            acc.note_timestamp(DateTime::from_timestamp_millis(row.time_created));
        }
        if row.time_updated > 0 {
            acc.note_timestamp(DateTime::from_timestamp_millis(row.time_updated));
        }

        let mut parts_by_msg: HashMap<String, Vec<String>> = HashMap::new();
        if has_parts
            && let Ok(mut stmt) = db.prepare(
                "SELECT message_id, data FROM part WHERE session_id = ? ORDER BY time_created ASC, id ASC",
            )
            && let Ok(part_rows) = stmt.query_map([&row.id], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1).unwrap_or_default()))
            })
        {
            for (msg_id, data) in part_rows.flatten() {
                if let Some(obj) = parse_object(data.as_bytes())
                    && str_at(&obj, "type") == Some("text")
                    && let Some(text) = str_at(&obj, "text").filter(|t| !t.trim().is_empty())
                {
                    parts_by_msg.entry(msg_id).or_default().push(text.to_owned());
                }
            }
        }

        if let Ok(mut stmt) = db.prepare(
            "SELECT id, time_created, time_updated, data FROM message WHERE session_id = ? ORDER BY time_created ASC, id ASC",
        ) && let Ok(msg_rows) = stmt.query_map([&row.id], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1).unwrap_or(0),
                r.get::<_, i64>(2).unwrap_or(0),
                r.get::<_, String>(3).unwrap_or_default(),
            ))
        }) {
            for (msg_id, created, updated, data) in msg_rows.flatten() {
                if created > 0 {
                    acc.note_timestamp(DateTime::from_timestamp_millis(created));
                }
                if updated > 0 {
                    acc.note_timestamp(DateTime::from_timestamp_millis(updated));
                }
                let Some(obj) = parse_object(data.as_bytes()) else { continue };
                if let Some(model) = extract_opencode_model(&obj) {
                    acc.model = Some(model);
                }
                let role = match str_at(&obj, "role") {
                    Some("user") => HistoryMessageRole::User,
                    Some("assistant") => HistoryMessageRole::Assistant,
                    _ => continue,
                };
                if let Some(parts) = parts_by_msg.get(&msg_id) {
                    acc.push_message(role, &parts.join(" "));
                }
            }
        }

        if let Some(summary) =
            acc.finish(AgentTranscriptFormat::OpenCode, Some(row.id), row.time_updated, path.to_path_buf())
        {
            sessions.push(summary);
        }
    }
    sessions
}

fn extract_opencode_model(obj: &Object) -> Option<String> {
    if let Some(model_id) = str_at(obj, "modelID").filter(|m| !m.is_empty()) {
        return Some(short_model_name(model_id));
    }
    if let Some(model) = str_at(obj, "model").filter(|m| !m.is_empty()) {
        return Some(short_model_name(model));
    }
    if let Some(model_obj) = obj_at(obj, "model")
        && let Some(model_id) = str_at(model_obj, "modelID").filter(|m| !m.is_empty())
    {
        return Some(short_model_name(model_id));
    }
    None
}

// MARK: - Antigravity (agy)

fn parse_agy_file(path: &Path, modified_ms: i64) -> Option<AgentSessionSummary> {
    // `<brain>/<conversation-id>/.system_generated/logs/transcript.jsonl`
    let fallback_id = path
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .and_then(Path::file_name)
        .and_then(|s| s.to_str())
        .map(str::to_owned);
    let mut acc = SessionAccumulator::new();

    if !read_jsonl_lines(path, |line| {
        let Some(record) = parse_object(line) else { return };
        if let Some(cwd) = str_at(&record, "cwd").filter(|c| !c.is_empty()) {
            acc.cwd = Some(cwd.to_owned());
        }
        let ts = date_from_value(record.get("created_at").or_else(|| record.get("timestamp")));
        acc.note_timestamp(ts);

        match str_at(&record, "type") {
            Some("USER_INPUT") => {
                if let Some(source) = str_at(&record, "source")
                    && source != "USER_EXPLICIT"
                {
                    return;
                }
                if let Some(raw) = str_at(&record, "content")
                    && let Some(text) = crate::agy::extract_user_request(raw)
                {
                    acc.push_message(HistoryMessageRole::User, &text);
                }
            }
            Some("PLANNER_RESPONSE") => {
                if let Some(model) = str_at(&record, "model").filter(|m| !m.is_empty()) {
                    acc.model = Some(short_model_name(model));
                }
                for call in objects_at(&record, "tool_calls") {
                    if str_at(call, "name") == Some("invoke_subagent") {
                        acc.subagent_count += 1;
                    }
                }
                if let Some(reply) = str_at(&record, "content")
                    .or_else(|| str_at(&record, "response"))
                    .filter(|t| !t.trim().is_empty())
                {
                    acc.push_message(HistoryMessageRole::Assistant, reply);
                }
            }
            _ => {}
        }
    }) {
        return None;
    }

    acc.finish(AgentTranscriptFormat::Agy, fallback_id, modified_ms, path.to_path_buf())
}

fn line_contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}
