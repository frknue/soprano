//! The Source Control list (changed files per area with line counts), whole-file diffs,
//! their inline and side-by-side layouts, and per-side syntax highlighting.

use std::collections::HashMap;
use std::ops::Range;

use crate::natural::natural_compare;
use crate::status::{GitFileStatus, nul_records};

// MARK: - Changed Files

/// The Source Control list's sections, in Orca's default order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum GitChangeArea {
    Conflicts,
    Unstaged,
    Staged,
    Untracked,
}

impl GitChangeArea {
    pub const ALL: [Self; 4] = [Self::Conflicts, Self::Unstaged, Self::Staged, Self::Untracked];

    pub fn title(self) -> &'static str {
        match self {
            Self::Conflicts => "Conflicts",
            Self::Unstaged => "Changes",
            Self::Staged => "Staged Changes",
            Self::Untracked => "Untracked Files",
        }
    }
}

/// One changed file in one area. A file with staged and unstaged edits is
/// two changes, one per area, as in Orca.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct GitChange {
    /// Root-relative; a rename's new path.
    pub path: String,
    /// Root-relative source of a staged rename or copy.
    pub original_path: Option<String>,
    /// Unresolved conflicts count as modified.
    pub status: GitFileStatus,
    pub area: GitChangeArea,
    /// From `git diff --numstat`, or counted for untracked files; `None` for
    /// binary files and files that were not counted.
    pub lines_added: Option<usize>,
    pub lines_deleted: Option<usize>,
}

impl GitChange {
    pub fn new(path: impl Into<String>, status: GitFileStatus, area: GitChangeArea) -> Self {
        Self { path: path.into(), original_path: None, status, area, lines_added: None, lines_deleted: None }
    }

    pub fn name(&self) -> &str {
        self.path.rsplit('/').next().unwrap_or(&self.path)
    }

    /// The parent folder, empty at the root.
    pub fn directory(&self) -> &str {
        self.path.rfind('/').map_or("", |slash| &self.path[..slash])
    }

    /// The row's letter: git's status, or "!" for an unresolved conflict.
    pub fn letter(&self) -> &'static str {
        if self.area == GitChangeArea::Conflicts { "!" } else { self.status.letter() }
    }
}

/// Added and deleted lines of one file; `None` for a binary file's sides.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GitLineCounts {
    pub added: Option<usize>,
    pub deleted: Option<usize>,
}

/// What the Source Control list shows for one repository.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GitChangeList {
    /// The checked-out branch, or the short commit of a detached HEAD.
    pub branch: Option<String>,
    /// Sorted by area, then naturally by path.
    pub changes: Vec<GitChange>,
}

impl GitChangeList {
    pub fn empty() -> Self {
        Self::default()
    }

    pub fn changes_in(&self, area: GitChangeArea) -> Vec<&GitChange> {
        self.changes.iter().filter(|change| change.area == area).collect()
    }

    /// Parses `git status --porcelain=v2 -z --branch --untracked-files=all`:
    /// the index side of each entry is a staged change, the working tree side
    /// an unstaged one.
    pub fn parse_status(data: &[u8]) -> Self {
        let mut records = nul_records(data).into_iter();
        let mut head: Option<String> = None;
        let mut commit: Option<String> = None;
        let mut changes: Vec<GitChange> = Vec::new();

        let append = |changes: &mut Vec<GitChange>, xy: &str, path: &str, original: Option<&str>| {
            let sides: Vec<char> = xy.chars().collect();
            if sides.len() != 2 {
                return;
            }
            for (character, area) in [(sides[0], GitChangeArea::Staged), (sides[1], GitChangeArea::Unstaged)]
            {
                if character == '.' {
                    continue;
                }
                let status = GitFileStatus::from_status_character(character);
                let mut change = GitChange::new(path, status, area);
                if matches!(status, GitFileStatus::Renamed | GitFileStatus::Copied) {
                    change.original_path = original.map(str::to_owned);
                }
                changes.push(change);
            }
        };

        while let Some(record) = records.next() {
            if let Some(rest) = record.strip_prefix("# branch.head ") {
                head = Some(rest.to_owned());
                continue;
            }
            if let Some(rest) = record.strip_prefix("# branch.oid ") {
                commit = Some(rest.to_owned());
                continue;
            }
            match record.chars().next() {
                Some('1') => {
                    let fields: Vec<&str> = record.splitn(9, ' ').collect();
                    if fields.len() == 9 {
                        append(&mut changes, fields[1], fields[8], None);
                    }
                }
                Some('2') => {
                    let fields: Vec<&str> = record.splitn(10, ' ').collect();
                    // The rename source follows as its own NUL-terminated record.
                    let source = records.next();
                    if fields.len() == 10 {
                        append(&mut changes, fields[1], fields[9], source.as_deref());
                    }
                }
                Some('u') => {
                    let fields: Vec<&str> = record.splitn(11, ' ').collect();
                    if fields.len() == 11 {
                        changes.push(GitChange::new(
                            fields[10],
                            GitFileStatus::Modified,
                            GitChangeArea::Conflicts,
                        ));
                    }
                }
                Some('?') => changes.push(GitChange::new(
                    record.get(2..).unwrap_or(""),
                    GitFileStatus::Untracked,
                    GitChangeArea::Untracked,
                )),
                _ => {}
            }
        }

        changes
            .sort_by(|lhs, rhs| lhs.area.cmp(&rhs.area).then_with(|| natural_compare(&lhs.path, &rhs.path)));
        let branch = match (head, commit) {
            (Some(head), _) if head != "(detached)" => Some(head),
            (_, Some(commit)) if commit != "(initial)" => Some(commit.chars().take(7).collect()),
            _ => None,
        };
        Self { branch, changes }
    }

    /// Parses `git diff -z --numstat --no-renames`: `added\tdeleted\tpath`
    /// records, with `-` counts for binary files.
    pub fn parse_numstat(data: &[u8]) -> HashMap<String, GitLineCounts> {
        let mut counts = HashMap::new();
        for record in nul_records(data) {
            let fields: Vec<&str> = record.splitn(3, '\t').collect();
            if fields.len() != 3 {
                continue;
            }
            counts.insert(
                fields[2].to_owned(),
                GitLineCounts { added: fields[0].parse().ok(), deleted: fields[1].parse().ok() },
            );
        }
        counts
    }

    pub fn apply_line_counts(&mut self, counts: &HashMap<String, GitLineCounts>, area: GitChangeArea) {
        for change in self.changes.iter_mut().filter(|change| change.area == area) {
            if let Some(count) = counts.get(&change.path) {
                change.lines_added = count.added;
                change.lines_deleted = count.deleted;
            }
        }
    }

    /// The number of lines in a file's contents, or `None` for binary data
    /// (a NUL byte near the start, git's own test).
    pub fn line_count(data: &[u8]) -> Option<usize> {
        if data[..data.len().min(8000)].contains(&0) {
            return None;
        }
        let Some(&last) = data.last() else { return Some(0) };
        let newlines = data.iter().filter(|byte| **byte == b'\n').count();
        Some(if last == b'\n' { newlines } else { newlines + 1 })
    }
}

// MARK: - File Diff

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum GitDiffLineKind {
    Context,
    Removed,
    Added,
}

/// One line of a whole-file diff.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GitDiffLine {
    pub kind: GitDiffLineKind,
    /// Line number on the old side; `None` for added lines.
    pub old_number: Option<usize>,
    /// Line number on the new side; `None` for removed lines.
    pub new_number: Option<usize>,
    pub text: String,
}

impl GitDiffLine {
    pub fn new(
        kind: GitDiffLineKind,
        old_number: Option<usize>,
        new_number: Option<usize>,
        text: impl Into<String>,
    ) -> Self {
        Self { kind, old_number, new_number, text: text.into() }
    }
}

/// One file's diff, read with full context so the whole file is shown with
/// its changes marked, like Orca's diff editor.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GitFileDiff {
    Text(Vec<GitDiffLine>),
    Binary,
    /// Both sides have the same text: only the mode changed, or the change
    /// was reverted since it was listed.
    NoChanges,
    /// An empty file was added or deleted: git lists it without a hunk.
    EmptyFile {
        is_new: bool,
    },
    /// More output than [`crate::reader::MAXIMUM_DIFF_BYTES`].
    TooLarge,
    /// git is missing or failed.
    Unavailable,
}

impl GitFileDiff {
    /// Parses `git diff` output for a single file.
    pub fn parse(patch: &[u8]) -> Self {
        let mut raw_lines: Vec<&[u8]> = patch.split(|byte| *byte == b'\n').collect();
        if raw_lines.last().is_some_and(|line| line.is_empty()) {
            raw_lines.pop();
        }
        let mut lines = Vec::new();
        let mut old_number = 0;
        let mut new_number = 0;
        let mut in_hunk = false;
        let mut has_changes = false;
        // From the "new file mode" / "deleted file mode" header.
        let mut is_new_file: Option<bool> = None;

        for raw in raw_lines {
            let bytes = raw.strip_suffix(b"\r").unwrap_or(raw);
            if bytes.starts_with(b"@@ ") {
                let Some((old, new)) = hunk_start(bytes) else { return Self::Unavailable };
                old_number = old;
                new_number = new;
                in_hunk = true;
                continue;
            }
            if !in_hunk {
                if bytes.starts_with(b"Binary files ") || bytes.starts_with(b"GIT binary patch") {
                    return Self::Binary;
                }
                if bytes.starts_with(b"new file mode ") {
                    is_new_file = Some(true);
                } else if bytes.starts_with(b"deleted file mode ") {
                    is_new_file = Some(false);
                }
                continue;
            }
            // `diff.suppressBlankEmpty` drops the space before an empty context line.
            let marker = bytes.first().copied().unwrap_or(b' ');
            let text = || String::from_utf8_lossy(bytes.get(1..).unwrap_or(&[])).into_owned();
            match marker {
                b' ' => {
                    lines.push(GitDiffLine::new(
                        GitDiffLineKind::Context,
                        Some(old_number),
                        Some(new_number),
                        text(),
                    ));
                    old_number += 1;
                    new_number += 1;
                }
                b'-' => {
                    lines.push(GitDiffLine::new(GitDiffLineKind::Removed, Some(old_number), None, text()));
                    old_number += 1;
                    has_changes = true;
                }
                b'+' => {
                    lines.push(GitDiffLine::new(GitDiffLineKind::Added, None, Some(new_number), text()));
                    new_number += 1;
                    has_changes = true;
                }
                // "\ No newline at end of file"
                b'\\' => {}
                _ => in_hunk = false,
            }
        }
        if has_changes {
            return Self::Text(lines);
        }
        // A file with content is all + or − lines; one without has no hunk.
        is_new_file.map_or(Self::NoChanges, |is_new| Self::EmptyFile { is_new })
    }
}

/// "@@ -12,3 +12,4 @@ …" → (12, 12).
fn hunk_start(header: &[u8]) -> Option<(usize, usize)> {
    let header = String::from_utf8_lossy(header);
    let parts: Vec<&str> = header.split(' ').filter(|part| !part.is_empty()).collect();
    if parts.len() < 3 {
        return None;
    }
    let start = |range: &str, sign: char| -> Option<usize> {
        range.strip_prefix(sign)?.split(',').next()?.parse().ok()
    };
    Some((start(parts[1], '-')?, start(parts[2], '+')?))
}

// MARK: - Layout

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum GitDiffRowKind {
    Context,
    Removed,
    Added,
    /// Pads the shorter side of a side-by-side change so both sides
    /// stay aligned.
    Filler,
}

/// One visual row of a diff view.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GitDiffRow {
    pub kind: GitDiffRowKind,
    /// Index into the diff's lines; `None` for filler rows.
    pub line_index: Option<usize>,
    /// The byte range of the line that differs from the line it replaces
    /// or is replaced by, for a stronger tint. `None` when the whole line differs.
    pub changed_range: Option<Range<usize>>,
}

impl GitDiffRow {
    fn new(kind: GitDiffRowKind, line_index: Option<usize>, changed_range: Option<Range<usize>>) -> Self {
        Self { kind, line_index, changed_range }
    }
}

/// A diff's rows for an inline view, or for one side of a side-by-side view.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GitDiffLayout {
    pub rows: Vec<GitDiffRow>,
    /// The first row of each run of changed rows, in order.
    pub change_starts: Vec<usize>,
}

type RangePair = (Range<usize>, Range<usize>);

enum Segment {
    Context(usize),
    Change { removed: Vec<usize>, added: Vec<usize> },
}

impl GitDiffLayout {
    /// Every line in file order, each change's removed lines above its added ones.
    pub fn inline(lines: &[GitDiffLine]) -> Self {
        let mut layout = Self::default();
        for segment in segments(lines) {
            match segment {
                Segment::Context(index) => {
                    layout.rows.push(GitDiffRow::new(GitDiffRowKind::Context, Some(index), None))
                }
                Segment::Change { removed, added } => {
                    layout.change_starts.push(layout.rows.len());
                    let ranges = paired_ranges(lines, &removed, &added);
                    for (pair, index) in removed.iter().enumerate() {
                        let range = ranges.get(pair).cloned().flatten().map(|r| r.0);
                        layout.rows.push(GitDiffRow::new(GitDiffRowKind::Removed, Some(*index), range));
                    }
                    for (pair, index) in added.iter().enumerate() {
                        let range = ranges.get(pair).cloned().flatten().map(|r| r.1);
                        layout.rows.push(GitDiffRow::new(GitDiffRowKind::Added, Some(*index), range));
                    }
                }
            }
        }
        layout
    }

    /// The old file on the left, the new one on the right, row for row: a
    /// change's removed and added lines face each other, and the shorter
    /// side is padded with filler rows.
    pub fn side_by_side(lines: &[GitDiffLine]) -> (Self, Self) {
        let mut old = Self::default();
        let mut new = Self::default();
        for segment in segments(lines) {
            match segment {
                Segment::Context(index) => {
                    old.rows.push(GitDiffRow::new(GitDiffRowKind::Context, Some(index), None));
                    new.rows.push(GitDiffRow::new(GitDiffRowKind::Context, Some(index), None));
                }
                Segment::Change { removed, added } => {
                    old.change_starts.push(old.rows.len());
                    new.change_starts.push(new.rows.len());
                    let ranges = paired_ranges(lines, &removed, &added);
                    for pair in 0..removed.len().max(added.len()) {
                        let range = ranges.get(pair).cloned().flatten();
                        old.rows.push(match removed.get(pair) {
                            Some(index) => GitDiffRow::new(
                                GitDiffRowKind::Removed,
                                Some(*index),
                                range.clone().map(|r| r.0),
                            ),
                            None => GitDiffRow::new(GitDiffRowKind::Filler, None, None),
                        });
                        new.rows.push(match added.get(pair) {
                            Some(index) => {
                                GitDiffRow::new(GitDiffRowKind::Added, Some(*index), range.map(|r| r.1))
                            }
                            None => GitDiffRow::new(GitDiffRowKind::Filler, None, None),
                        });
                    }
                }
            }
        }
        (old, new)
    }

    /// The differing middle of two lines that share a prefix or a suffix, as
    /// byte ranges in each; `None` when they share neither or are equal.
    /// Ranges never split a character.
    pub fn changed_ranges(old: &str, new: &str) -> Option<RangePair> {
        let old_bytes = old.as_bytes();
        let new_bytes = new.as_bytes();
        let shorter = old_bytes.len().min(new_bytes.len());
        let mut prefix = 0;
        while prefix < shorter && old_bytes[prefix] == new_bytes[prefix] {
            prefix += 1;
        }
        // Never split a character.
        while prefix > 0 && !(old.is_char_boundary(prefix) && new.is_char_boundary(prefix)) {
            prefix -= 1;
        }
        let mut suffix = 0;
        while suffix < shorter - prefix
            && old_bytes[old_bytes.len() - 1 - suffix] == new_bytes[new_bytes.len() - 1 - suffix]
        {
            suffix += 1;
        }
        while suffix > 0
            && !(old.is_char_boundary(old_bytes.len() - suffix)
                && new.is_char_boundary(new_bytes.len() - suffix))
        {
            suffix -= 1;
        }
        let old_length = old_bytes.len() - prefix - suffix;
        let new_length = new_bytes.len() - prefix - suffix;
        if (prefix == 0 && suffix == 0) || (old_length == 0 && new_length == 0) {
            return None;
        }
        Some((prefix..prefix + old_length, prefix..prefix + new_length))
    }
}

/// Context lines one by one, and each run of changed lines as one change.
fn segments(lines: &[GitDiffLine]) -> Vec<Segment> {
    let mut segments = Vec::new();
    let mut removed = Vec::new();
    let mut added = Vec::new();
    let flush = |segments: &mut Vec<Segment>, removed: &mut Vec<usize>, added: &mut Vec<usize>| {
        if removed.is_empty() && added.is_empty() {
            return;
        }
        segments.push(Segment::Change { removed: std::mem::take(removed), added: std::mem::take(added) });
    };
    for (index, line) in lines.iter().enumerate() {
        match line.kind {
            GitDiffLineKind::Context => {
                flush(&mut segments, &mut removed, &mut added);
                segments.push(Segment::Context(index));
            }
            GitDiffLineKind::Removed => removed.push(index),
            GitDiffLineKind::Added => added.push(index),
        }
    }
    flush(&mut segments, &mut removed, &mut added);
    segments
}

/// The n-th removed line of a change is taken to be replaced by its n-th
/// added line.
fn paired_ranges(lines: &[GitDiffLine], removed: &[usize], added: &[usize]) -> Vec<Option<RangePair>> {
    removed
        .iter()
        .zip(added)
        .map(|(old, new)| GitDiffLayout::changed_ranges(&lines[*old].text, &lines[*new].text))
        .collect()
}

// MARK: - Highlighting

/// One colored span of a line, as a byte range relative to the line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GitDiffToken<K> {
    pub range: Range<usize>,
    pub kind: K,
}

/// Syntax colors for both sides of a diff, per line, so every row is colored
/// as the line reads in its own version of the file. Generic over the token kind
/// so the syntax highlighter lives with the editor.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GitDiffHighlights<K> {
    /// Indexed like the diff's lines, with ranges relative to the line; empty
    /// for lines that are not on that side.
    pub old: Vec<Vec<GitDiffToken<K>>>,
    pub new: Vec<Vec<GitDiffToken<K>>>,
}

impl<K> Default for GitDiffHighlights<K> {
    fn default() -> Self {
        Self { old: Vec::new(), new: Vec::new() }
    }
}

impl<K: Clone> GitDiffHighlights<K> {
    /// Larger sides stay uncolored, like large files in the editor.
    pub const MAXIMUM_LENGTH: usize = 1_500_000;

    /// `tokenize` highlights a whole text, returning byte ranges with their kinds; `None`
    /// (no language) leaves both sides uncolored.
    pub fn compute<F>(lines: &[GitDiffLine], tokenize: Option<F>) -> Self
    where
        F: Fn(&str) -> Vec<(Range<usize>, K)>,
    {
        let Some(tokenize) = tokenize else { return Self::default() };
        Self {
            old: side(lines, GitDiffLineKind::Added, &tokenize),
            new: side(lines, GitDiffLineKind::Removed, &tokenize),
        }
    }
}

type Tokenizer<'a, K> = dyn Fn(&str) -> Vec<(Range<usize>, K)> + 'a;

/// Highlights one version of the file as a whole, so multi-line strings
/// and comments color correctly, then splits the tokens per line.
fn side<K: Clone>(
    lines: &[GitDiffLine],
    excluded: GitDiffLineKind,
    tokenize: &Tokenizer<'_, K>,
) -> Vec<Vec<GitDiffToken<K>>> {
    let mut result: Vec<Vec<GitDiffToken<K>>> = vec![Vec::new(); lines.len()];
    let mut indices = Vec::new();
    let mut starts = Vec::new();
    let mut lengths = Vec::new();
    let mut text = String::new();
    for (index, line) in lines.iter().enumerate().filter(|(_, line)| line.kind != excluded) {
        if !indices.is_empty() {
            text.push('\n');
        }
        indices.push(index);
        starts.push(text.len());
        lengths.push(line.text.len());
        text.push_str(&line.text);
        if text.len() > GitDiffHighlights::<K>::MAXIMUM_LENGTH {
            return result;
        }
    }

    for (range, kind) in tokenize(&text) {
        // The last line starting at or before the token.
        let mut line = starts.partition_point(|start| *start <= range.start).saturating_sub(1);
        while line < starts.len() && starts[line] < range.end {
            let from = range.start.max(starts[line]);
            let to = range.end.min(starts[line] + lengths[line]);
            if to > from {
                result[indices[line]]
                    .push(GitDiffToken { range: from - starts[line]..to - starts[line], kind: kind.clone() });
            }
            line += 1;
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use GitDiffLineKind::{Added, Context, Removed};

    fn line(kind: GitDiffLineKind, old: Option<usize>, new: Option<usize>, text: &str) -> GitDiffLine {
        GitDiffLine::new(kind, old, new, text)
    }

    #[test]
    fn status_splits_each_file_into_its_staged_and_unstaged_changes_in_section_order() {
        let status = [
            "# branch.oid 0123456789abcdef",
            "# branch.head feature/diff",
            "1 MM N... 100644 100644 100644 aaa bbb src/both.swift",
            "1 .D N... 100644 100644 000000 aaa aaa gone.txt",
            "2 R. N... 100644 100644 100644 aaa bbb R100 docs/new name.md",
            "docs/old name.md",
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc merge.txt",
            "? notes 10.txt",
            "? notes 9.txt",
            "1 A. N... 000000 100644 100644 000 bbb added.swift",
        ]
        .join("\0")
            + "\0";

        let list = GitChangeList::parse_status(status.as_bytes());

        assert_eq!(list.branch.as_deref(), Some("feature/diff"));
        let rows: Vec<String> =
            list.changes.iter().map(|c| format!("{}: {} {}", c.area.title(), c.letter(), c.path)).collect();
        assert_eq!(
            rows,
            [
                "Conflicts: ! merge.txt",
                "Changes: D gone.txt",
                "Changes: M src/both.swift",
                "Staged Changes: A added.swift",
                "Staged Changes: R docs/new name.md",
                "Staged Changes: M src/both.swift",
                "Untracked Files: U notes 9.txt",
                "Untracked Files: U notes 10.txt",
            ]
        );
        let renamed = list.changes.iter().find(|c| c.status == GitFileStatus::Renamed);
        assert_eq!(renamed.and_then(|c| c.original_path.as_deref()), Some("docs/old name.md"));
        assert_eq!(
            list.changes.iter().find(|c| c.path == "src/both.swift").map(GitChange::directory),
            Some("src")
        );
    }

    #[test]
    fn a_detached_head_is_named_by_its_short_commit_and_an_unborn_branch_by_its_name() {
        let detached =
            GitChangeList::parse_status(b"# branch.oid 0123456789abcdef\0# branch.head (detached)\0");
        let unborn = GitChangeList::parse_status(b"# branch.oid (initial)\0# branch.head main\0");

        assert_eq!(detached.branch.as_deref(), Some("0123456"));
        assert_eq!(unborn.branch.as_deref(), Some("main"));
    }

    #[test]
    fn numstat_counts_land_on_their_area_and_binary_files_have_none() {
        let mut list = GitChangeList {
            branch: None,
            changes: vec![
                GitChange::new("a.txt", GitFileStatus::Modified, GitChangeArea::Staged),
                GitChange::new("a.txt", GitFileStatus::Modified, GitChangeArea::Unstaged),
                GitChange::new("logo.png", GitFileStatus::Modified, GitChangeArea::Unstaged),
            ],
        };

        list.apply_line_counts(
            &GitChangeList::parse_numstat(b"3\t1\ta.txt\0-\t-\tlogo.png\0"),
            GitChangeArea::Unstaged,
        );

        assert_eq!(list.changes[0].lines_added, None);
        assert_eq!(list.changes[1].lines_added, Some(3));
        assert_eq!(list.changes[1].lines_deleted, Some(1));
        assert_eq!(list.changes[2].lines_added, None);
        assert_eq!(list.changes[2].lines_deleted, None);
    }

    #[test]
    fn untracked_line_counts_include_an_unterminated_last_line_and_skip_binary_data() {
        assert_eq!(GitChangeList::line_count(b""), Some(0));
        assert_eq!(GitChangeList::line_count(b"a\nb\n"), Some(2));
        assert_eq!(GitChangeList::line_count(b"a\nb"), Some(2));
        assert_eq!(GitChangeList::line_count(&[0x61, 0x00, 0x0A]), None);
    }

    #[test]
    fn a_full_context_patch_becomes_the_whole_file_with_numbered_changes() {
        let patch = "diff --git a/f.txt b/f.txt\nindex de98044..f8f7a32 100644\n--- a/f.txt\n+++ b/f.txt\n@@ -1,3 +1,4 @@\n a\n-b\r\n+B\r\n c\n+d\n\\ No newline at end of file\n";

        let GitFileDiff::Text(lines) = GitFileDiff::parse(patch.as_bytes()) else {
            panic!("Expected a text diff");
        };

        assert_eq!(
            lines,
            [
                line(Context, Some(1), Some(1), "a"),
                line(Removed, Some(2), None, "b"),
                line(Added, None, Some(2), "B"),
                line(Context, Some(3), Some(3), "c"),
                line(Added, None, Some(4), "d"),
            ]
        );
    }

    #[test]
    fn patches_without_line_changes_are_binary_or_unchanged() {
        let binary =
            "diff --git a/x.png b/x.png\nindex 1..2 100644\nBinary files a/x.png and b/x.png differ\n";
        let mode_only = "diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n";

        assert_eq!(GitFileDiff::parse(binary.as_bytes()), GitFileDiff::Binary);
        assert_eq!(GitFileDiff::parse(mode_only.as_bytes()), GitFileDiff::NoChanges);
        assert_eq!(GitFileDiff::parse(b""), GitFileDiff::NoChanges);
    }

    #[test]
    fn an_empty_file_added_or_deleted_is_named_as_such_rather_than_unchanged() {
        let added = "diff --git a/empty b/empty\nnew file mode 100644\nindex 0000000..e69de29\n";
        let deleted = "diff --git a/empty b/empty\ndeleted file mode 100644\nindex e69de29..0000000\n";

        assert_eq!(GitFileDiff::parse(added.as_bytes()), GitFileDiff::EmptyFile { is_new: true });
        assert_eq!(GitFileDiff::parse(deleted.as_bytes()), GitFileDiff::EmptyFile { is_new: false });
    }

    #[test]
    fn a_blank_context_line_without_its_space_stays_a_line() {
        // `diff.suppressBlankEmpty` drops the space before empty context lines.
        let GitFileDiff::Text(lines) = GitFileDiff::parse(b"@@ -1,3 +1,3 @@\n a\n\n-b\n+c\n") else {
            panic!("Expected a text diff");
        };

        assert_eq!(lines.iter().map(|l| l.kind).collect::<Vec<_>>(), [Context, Context, Removed, Added]);
        assert_eq!(lines[1], line(Context, Some(2), Some(2), ""));
        assert_eq!(lines[3].new_number, Some(3));
    }

    /// Line 0 context, a two-line change replaced by one line, context, an addition.
    fn sample_lines() -> Vec<GitDiffLine> {
        vec![
            line(Context, Some(1), Some(1), "import A"),
            line(Removed, Some(2), None, "let x = 1"),
            line(Removed, Some(3), None, "let y = 3"),
            line(Added, None, Some(2), "let x = 2"),
            line(Context, Some(4), Some(3), "print(x)"),
            line(Added, None, Some(4), "print(y)"),
        ]
    }

    #[test]
    fn inline_rows_list_each_changes_removals_above_its_additions() {
        use GitDiffRowKind as K;
        let layout = GitDiffLayout::inline(&sample_lines());

        assert_eq!(
            layout.rows.iter().map(|r| r.kind).collect::<Vec<_>>(),
            [K::Context, K::Removed, K::Removed, K::Added, K::Context, K::Added]
        );
        assert_eq!(
            layout.rows.iter().map(|r| r.line_index).collect::<Vec<_>>(),
            [0, 1, 2, 3, 4, 5].map(Some)
        );
        assert_eq!(layout.change_starts, [1, 5]);
        // "let x = 1" became "let x = 2": only the value differs.
        assert_eq!(layout.rows[1].changed_range, Some(8..9));
        assert_eq!(layout.rows[3].changed_range, Some(8..9));
        assert_eq!(layout.rows[2].changed_range, None);
    }

    #[test]
    fn side_by_side_rows_face_each_other_and_pad_the_shorter_side() {
        use GitDiffRowKind as K;
        let (old, new) = GitDiffLayout::side_by_side(&sample_lines());

        assert_eq!(old.rows.len(), new.rows.len());
        assert_eq!(
            old.rows.iter().map(|r| r.kind).collect::<Vec<_>>(),
            [K::Context, K::Removed, K::Removed, K::Context, K::Filler]
        );
        assert_eq!(
            new.rows.iter().map(|r| r.kind).collect::<Vec<_>>(),
            [K::Context, K::Added, K::Filler, K::Context, K::Added]
        );
        assert_eq!(
            old.rows.iter().map(|r| r.line_index).collect::<Vec<_>>(),
            [Some(0), Some(1), Some(2), Some(4), None]
        );
        assert_eq!(
            new.rows.iter().map(|r| r.line_index).collect::<Vec<_>>(),
            [Some(0), Some(3), None, Some(4), Some(5)]
        );
        assert_eq!(old.change_starts, [1, 4]);
        assert_eq!(new.change_starts, old.change_starts);
        assert_eq!(new.rows[1].changed_range, Some(8..9));
    }

    #[test]
    fn changed_ranges_never_split_a_character_and_ignore_unrelated_lines() {
        let ranges = GitDiffLayout::changed_ranges("a😀b", "a😃b");

        // Byte ranges: each emoji is four bytes.
        assert_eq!(ranges, Some((1..5, 1..5)));
        assert_eq!(GitDiffLayout::changed_ranges("abc", "xyz"), None);
        assert_eq!(GitDiffLayout::changed_ranges("abc", "abXc").map(|r| r.0), Some(2..2));
    }

    #[test]
    fn highlights_color_each_side_as_its_own_file_and_split_tokens_per_line() {
        #[derive(Clone, Debug, PartialEq)]
        enum Kind {
            Comment,
            Keyword,
        }
        // A tiny tokenizer: `/* … */` comments (across lines) and the `let` keyword.
        let tokenize = |text: &str| -> Vec<(Range<usize>, Kind)> {
            let mut tokens = Vec::new();
            let mut offset = 0;
            while offset < text.len() {
                if text[offset..].starts_with("/*") {
                    let end = text[offset..].find("*/").map_or(text.len(), |e| offset + e + 2);
                    tokens.push((offset..end, Kind::Comment));
                    offset = end;
                } else if text[offset..].starts_with("let") {
                    tokens.push((offset..offset + 3, Kind::Keyword));
                    offset += 3;
                } else {
                    offset += text[offset..].chars().next().map_or(1, char::len_utf8);
                }
            }
            tokens
        };
        let lines = vec![
            line(Removed, Some(1), None, "/* old"),
            line(Added, None, Some(1), "let a = 1"),
            line(Context, Some(2), Some(2), "end */"),
        ];

        let highlights = GitDiffHighlights::compute(&lines, Some(tokenize));

        // On the old side the comment runs across both of its lines.
        assert_eq!(highlights.old[0], [GitDiffToken { range: 0..6, kind: Kind::Comment }]);
        assert_eq!(highlights.old[2], [GitDiffToken { range: 0..6, kind: Kind::Comment }]);
        assert!(highlights.old[1].is_empty());
        assert!(highlights.new[0].is_empty());
        assert_eq!(highlights.new[1].first().map(|t| t.kind.clone()), Some(Kind::Keyword));
        assert!(!highlights.new[2].iter().any(|t| t.kind == Kind::Comment));
    }
}
