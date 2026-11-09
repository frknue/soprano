//! The code a write or edit call carries in its arguments (`OmpEditPreview.swift`).

use std::sync::LazyLock;

use regex::Regex;

use crate::chat_turns::{FileChange, FileChangeKind};
use crate::json::{JsonValue, JsonValueExt};
use crate::timeline::trim_spaces;

/// The code a write or edit call carries in its arguments, as unified hunks
/// ([`FileChange::diff`]), so the timeline shows it while the model still streams the call and
/// before omp reports the applied diff.
///
/// - `write {path, content}` → every line added, numbered from 1. Internal URLs (`xd://`,
///   `agent://`, `local://`, …) carry no code: none.
/// - `edit {input}` → per `[path#TAG]` section (hashline; ops start hunks, `+` rows are added
///   lines), `*** Update|Add|Delete File:` section (apply_patch; `@@` starts a hunk, `+`/`-`/` `
///   lines) or `*** Edit File:` section (sloppy; `*** Find` lines removed, `*** Replace` and
///   `*** Insert …` lines added). `*** Begin Patch` / `*** End Patch` wrappers are skipped.
/// - `edit {path, old_string, new_string}` (replace) → old lines removed, new lines added.
/// - `edit {path, edits:[{op?, rename?, diff?}]}` (patch) → the entries' diff lines.
///
/// Positions the arguments do not state (everything but a write) give hunks starting at line 0;
/// the timeline shows those without line numbers.
pub fn omp_edit_changes(tool: &str, args: &JsonValue, relative: &dyn Fn(&str) -> String) -> Vec<FileChange> {
    match tool {
        "write" => {
            let Some(path) = args.get("path").and_then(JsonValue::non_empty_string) else {
                return Vec::new();
            };
            if path.contains("://") {
                return Vec::new();
            }
            let Some(content) = args.get("content").and_then(JsonValue::as_str) else { return Vec::new() };
            let mut hunk = Hunk { numbered: true, ..Hunk::default() };
            for line in lines(content) {
                hunk.add(LineKind::Added, line);
            }
            vec![FileChange {
                path: relative(path),
                kind: FileChangeKind::Update,
                move_path: None,
                diff: render(&[hunk]),
                is_full_content: Some(true),
            }]
        }
        "edit" | "apply_patch" => {
            if let Some(input) = args.get("input").and_then(JsonValue::as_str) {
                return sections(input)
                    .into_iter()
                    .map(|section| FileChange {
                        path: relative(&section.path),
                        kind: section.kind,
                        move_path: section.move_path.as_deref().map(relative),
                        diff: render(&section.hunks),
                        is_full_content: None,
                    })
                    .collect();
            }
            let Some(path) = args.get("path").and_then(JsonValue::non_empty_string) else {
                return Vec::new();
            };
            if let Some(edits) = args.get("edits").and_then(JsonValue::as_array) {
                let mut kind = FileChangeKind::Update;
                let mut move_path = None;
                let mut hunks = Vec::new();
                for edit in edits {
                    match edit.get("op").and_then(JsonValue::as_str) {
                        Some("create") => kind = FileChangeKind::Add,
                        Some("delete") => kind = FileChangeKind::Delete,
                        _ => {}
                    }
                    if let Some(rename) = edit.get("rename").and_then(JsonValue::non_empty_string) {
                        move_path = Some(relative(rename));
                        kind = FileChangeKind::Move;
                    }
                    let mut section = Section::new(path.to_owned());
                    for line in lines(edit.get("diff").and_then(JsonValue::as_str).unwrap_or("")) {
                        section.patch_line(line);
                    }
                    hunks.extend(section.hunks);
                }
                return vec![FileChange {
                    path: relative(path),
                    kind,
                    move_path,
                    diff: render(&hunks),
                    is_full_content: None,
                }];
            }
            let old = args.get("old_string").and_then(JsonValue::as_str);
            let new = args.get("new_string").and_then(JsonValue::as_str);
            if old.is_none() && new.is_none() {
                return Vec::new();
            }
            let mut hunk = Hunk::default();
            for line in lines(old.unwrap_or("")) {
                hunk.add(LineKind::Removed, line);
            }
            for line in lines(new.unwrap_or("")) {
                hunk.add(LineKind::Added, line);
            }
            vec![FileChange::with_diff(relative(path), FileChangeKind::Update, render(&[hunk]))]
        }
        _ => Vec::new(),
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum LineKind {
    Added,
    Removed,
    Context,
}

impl LineKind {
    fn marker(self) -> char {
        match self {
            Self::Added => '+',
            Self::Removed => '-',
            Self::Context => ' ',
        }
    }
}

#[derive(Default)]
struct Hunk {
    /// Lines are numbered from 1 (a whole new file); else the position is unknown (0).
    numbered: bool,
    section: String,
    lines: Vec<(LineKind, String)>,
}

impl Hunk {
    fn add(&mut self, kind: LineKind, text: &str) {
        self.lines.push((kind, text.to_owned()));
    }

    fn header(&self) -> String {
        let old = self.lines.iter().filter(|l| l.0 != LineKind::Added).count();
        let new = self.lines.iter().filter(|l| l.0 != LineKind::Removed).count();
        let range = if self.numbered { format!("-0,0 +1,{new}") } else { format!("-0,{old} +0,{new}") };
        if self.section.is_empty() {
            format!("@@ {range} @@")
        } else {
            format!("@@ {range} @@ {}", self.section)
        }
    }
}

fn render(hunks: &[Hunk]) -> Option<String> {
    let shown: Vec<&Hunk> = hunks.iter().filter(|h| !h.lines.is_empty() || !h.section.is_empty()).collect();
    if shown.is_empty() {
        return None;
    }
    Some(
        shown
            .iter()
            .map(|hunk| {
                let mut rows = vec![hunk.header()];
                rows.extend(hunk.lines.iter().map(|(kind, text)| format!("{}{text}", kind.marker())));
                rows.join("\n")
            })
            .collect::<Vec<_>>()
            .join("\n"),
    )
}

/// Lines of a text (`\n` or `\r\n`); a final line break ends the last line rather than starting
/// an empty one.
fn lines(text: &str) -> Vec<&str> {
    if text.is_empty() {
        return Vec::new();
    }
    let mut parts: Vec<&str> = text.split('\n').map(|l| l.strip_suffix('\r').unwrap_or(l)).collect();
    if parts.last() == Some(&"") {
        parts.pop();
    }
    parts
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Hashline,
    Patch,
    Find,
    Insert,
}

struct Section {
    path: String,
    kind: FileChangeKind,
    move_path: Option<String>,
    mode: Mode,
    hunks: Vec<Hunk>,
}

impl Section {
    fn new(path: String) -> Self {
        Self { path, kind: FileChangeKind::Update, move_path: None, mode: Mode::Patch, hunks: Vec::new() }
    }

    fn start_hunk(&mut self, section: &str) {
        self.hunks.push(Hunk { section: section.to_owned(), ..Hunk::default() });
    }

    fn add(&mut self, kind: LineKind, text: &str) {
        if self.hunks.is_empty() {
            self.hunks.push(Hunk::default());
        }
        if let Some(last) = self.hunks.last_mut() {
            last.add(kind, text);
        }
    }

    /// One body line of an apply_patch / patch section.
    fn patch_line(&mut self, line: &str) {
        if let Some(rest) = line.strip_prefix("@@") {
            // "@@ -1,3 +1,4 @@ func f()" or apply_patch's "@@ class Foo": the text after the markers.
            let rest = match rest.find("@@") {
                Some(close) => &rest[close + 2..],
                None => rest,
            };
            self.start_hunk(trim_spaces(rest));
            return;
        }
        let Some(marker) = line.chars().next() else { return };
        let text = &line[marker.len_utf8()..];
        match marker {
            '+' => self.add(LineKind::Added, text),
            '-' => self.add(LineKind::Removed, text),
            ' ' => self.add(LineKind::Context, text),
            _ => {}
        }
    }
}

static HASHLINE_OP: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(PUT|CUT|REM|MV)\b").expect("valid regex"));
/// "[src/app.ts#1A2B]".
static HASHLINE_HEADER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\[(.+)#[0-9A-Fa-f]{4}\]$").expect("valid regex"));

fn sections(input: &str) -> Vec<Section> {
    let mut sections: Vec<Section> = Vec::new();
    let open = |sections: &mut Vec<Section>, path: String, mode: Mode, kind: FileChangeKind| {
        let mut section = Section::new(path);
        section.mode = mode;
        section.kind = kind;
        sections.push(section);
    };
    for line in lines(input) {
        if let Some(directive) = line.strip_prefix("*** ") {
            if let Some(path) = value(directive, "Update File:") {
                open(&mut sections, path, Mode::Patch, FileChangeKind::Update);
            } else if let Some(path) = value(directive, "Add File:") {
                open(&mut sections, path, Mode::Patch, FileChangeKind::Add);
            } else if let Some(path) = value(directive, "Delete File:") {
                open(&mut sections, path, Mode::Patch, FileChangeKind::Delete);
            } else if let Some(path) = value(directive, "Move to:").filter(|_| !sections.is_empty()) {
                if let Some(last) = sections.last_mut() {
                    last.move_path = Some(path);
                    last.kind = FileChangeKind::Move;
                }
            } else if let Some(mut path) = value(directive, "Edit File:") {
                if let Some(stripped) = path.strip_suffix(" all") {
                    path = stripped.to_owned();
                }
                if path.is_empty()
                    && let Some(current) = sections.last()
                {
                    path = current.path.clone();
                }
                open(&mut sections, path, Mode::Find, FileChangeKind::Update);
            } else if let Some(last) = sections.last_mut() {
                if directive.starts_with("Find") {
                    last.mode = Mode::Find;
                    last.start_hunk("");
                } else if directive.starts_with("Replace") || directive.starts_with("Insert") {
                    last.mode = Mode::Insert;
                }
            }
            continue;
        }
        if let Some(header) = HASHLINE_HEADER.captures(line) {
            open(&mut sections, header[1].to_owned(), Mode::Hashline, FileChangeKind::Update);
            continue;
        }
        let Some(last) = sections.last_mut() else { continue };
        match last.mode {
            Mode::Hashline => {
                if line.chars().all(char::is_whitespace) {
                    continue;
                }
                if HASHLINE_OP.is_match(line) {
                    last.start_hunk(trim_spaces(line));
                } else if let Some(added) = line.strip_prefix('+') {
                    last.add(LineKind::Added, added);
                }
            }
            Mode::Patch => last.patch_line(line),
            Mode::Find => last.add(LineKind::Removed, line),
            Mode::Insert => last.add(LineKind::Added, line),
        }
    }
    sections.retain(|s| !s.path.is_empty());
    sections
}

fn value(directive: &str, name: &str) -> Option<String> {
    directive.strip_prefix(name).map(|rest| trim_spaces(rest).to_owned())
}
