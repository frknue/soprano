//! The diff tab's model (port of `DiffTextViews.swift`, the loader and navigation logic of
//! `DiffPaneView.swift`, and the row text of `SurfaceDiffRows.swift`).
//!
//! Lines, the inline/side-by-side layouts, intra-line changed ranges and per-side syntax
//! colors come from `soprano_git::changes` (`GitDiffLine`, `GitDiffLayout`,
//! `GitDiffHighlights`); this module prepares them for the diff list: counts, the folded
//! list rows with three lines of context, change navigation, selection and copying, and
//! each row's display text. All ranges are UTF-8 byte ranges.

use std::collections::HashSet;
use std::ops::Range;
use std::path::{Path, PathBuf};

use soprano_git::changes::{
    GitDiffHighlights, GitDiffLayout, GitDiffLine, GitDiffLineKind, GitDiffRow, GitDiffRowKind, GitDiffToken,
    GitFileDiff,
};
use unicode_segmentation::UnicodeSegmentation;

use crate::syntax::{self, CodeLanguage, SyntaxTokenKind};

/// Height of one diff line (SF Mono 13 on a 20 pt line).
pub const LINE_HEIGHT: f32 = 20.0;
/// Width of the change bar on a row's left edge.
pub const BAR_WIDTH: f32 = 3.0;
/// Space between the line-number column and the code.
pub const CODE_INSET: f32 = 12.0;
pub const CODE_TRAILING: f32 = 12.0;
/// Heights of the sticky file header, the fold strip and the space after the last row.
pub const HEADER_HEIGHT: f32 = 36.0;
pub const FOLD_HEIGHT: f32 = 28.0;
pub const END_HEIGHT: f32 = 8.0;
/// Height of the subheader (scope, counts, navigation, layout toggle, wrap).
pub const SUBHEADER_HEIGHT: f32 = 28.0;
/// Longest prefix of a line a row draws, in characters (minified files would otherwise
/// stall layout).
pub const MAXIMUM_DRAWN_LENGTH: usize = 2000;
/// The layout new diff views start in (`true` = split); the toggle updates it.
pub const SIDE_BY_SIDE_STATE_KEY: &str = "soprano-diff-side-by-side";
/// The pause after a file-system event before the diff is read again.
pub const RELOAD_DELAY_MS: u64 = 300;
/// A first read slower than this says "Loading diff…".
pub const LOADING_MESSAGE_DELAY_MS: u64 = 150;

/// What a row draws in: the tint, bar and number colors of its kind.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DiffLineKind {
    Context,
    Added,
    Removed,
    /// "\ No newline at end of file" (chat diffs only).
    NoNewlineMarker,
}

impl From<GitDiffRowKind> for DiffLineKind {
    fn from(kind: GitDiffRowKind) -> Self {
        match kind {
            GitDiffRowKind::Added => Self::Added,
            GitDiffRowKind::Removed => Self::Removed,
            GitDiffRowKind::Context | GitDiffRowKind::Filler => Self::Context,
        }
    }
}

/// Columns `text` takes in a monospaced font, as the rows draw it: tabs four, CJK and emoji
/// two; only the drawn prefix counts.
pub fn columns(text: &str) -> usize {
    text.graphemes(true)
        .take(MAXIMUM_DRAWN_LENGTH)
        .map(|grapheme| match grapheme.chars().next() {
            Some('\t') => 4,
            Some(first) if first as u32 >= 0x2E80 => 2,
            _ => 1,
        })
        .sum()
}

/// Rows of text a line of `columns` wraps to in `width` points.
pub fn wrapped_lines(columns: usize, width: f32, column_width: f32) -> usize {
    if columns == 0 {
        return 1;
    }
    let fitting = ((width / column_width).floor() as usize).max(1);
    columns.div_ceil(fitting).max(1)
}

/// The code area of a row `row_width` wide (per side when split).
pub fn code_width(row_width: f32, layout: DiffListLayout, number_width: f32) -> f32 {
    let side = if layout == DiffListLayout::Split { split_divider_x(row_width) } else { row_width };
    (side - number_width - CODE_INSET - CODE_TRAILING).max(20.0)
}

/// The split row's divider: the middle, on a whole point.
pub fn split_divider_x(row_width: f32) -> f32 {
    (row_width / 2.0).floor()
}

// MARK: - Document

/// The file header's change glyph.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FileChange {
    Added,
    Deleted,
    Modified,
}

/// One file's whole-file diff prepared for the diff list: both layouts, the syntax colors
/// of each side, and the counts the header shows. Build it off the UI thread.
#[derive(Clone, Debug)]
pub struct DiffDocument {
    /// Repository-relative path (the header and Copy path).
    pub path: String,
    pub lines: Vec<GitDiffLine>,
    /// Stacked rows: each change's removed lines above its added ones.
    pub unified: GitDiffLayout,
    /// Split rows, old and new side row for row (fillers pad the shorter).
    pub old: GitDiffLayout,
    pub new: GitDiffLayout,
    pub highlights: GitDiffHighlights<SyntaxTokenKind>,
    pub additions: usize,
    pub deletions: usize,
    /// The largest line number either side shows.
    pub max_line: usize,
    /// The widest line, in monospaced columns.
    pub max_columns: usize,
    pub change: FileChange,
}

impl DiffDocument {
    pub fn new(
        path: impl Into<String>,
        lines: Vec<GitDiffLine>,
        language: Option<&'static CodeLanguage>,
    ) -> Self {
        let unified = GitDiffLayout::inline(&lines);
        let (old, new) = GitDiffLayout::side_by_side(&lines);
        let tokenize = language.map(|language| {
            move |text: &str| {
                syntax::tokens(text, language)
                    .into_iter()
                    .map(|token| (token.range, token.kind))
                    .collect::<Vec<_>>()
            }
        });
        let highlights = GitDiffHighlights::compute(&lines, tokenize);
        let (mut added, mut removed, mut context) = (0, 0, 0);
        let mut max_line = 1;
        let mut max_columns = 0;
        for line in &lines {
            match line.kind {
                GitDiffLineKind::Added => added += 1,
                GitDiffLineKind::Removed => removed += 1,
                GitDiffLineKind::Context => context += 1,
            }
            max_line = max_line.max(line.old_number.unwrap_or(0)).max(line.new_number.unwrap_or(0));
            max_columns = max_columns.max(columns(&line.text));
        }
        let change = if context == 0 && removed == 0 {
            FileChange::Added
        } else if context == 0 && added == 0 {
            FileChange::Deleted
        } else {
            FileChange::Modified
        };
        Self {
            path: path.into(),
            lines,
            unified,
            old,
            new,
            highlights,
            additions: added,
            deletions: removed,
            max_line,
            max_columns,
            change,
        }
    }

    /// The changed words of a row, kept only when the line shares real content with its
    /// pair: at least 3 non-blank characters and a quarter of the line (Agents' rule). Two
    /// unrelated lines that merely share indentation or a closing ")" would otherwise light
    /// up whole.
    pub fn emphasis(&self, row: &GitDiffRow) -> Option<Range<usize>> {
        let range = row.changed_range.clone()?;
        if range.is_empty() {
            return None;
        }
        let text = &self.lines[row.line_index?].text;
        if range.end > text.len() {
            return None;
        }
        let non_blank =
            |text: &str| text.graphemes(true).filter(|g| !g.chars().all(char::is_whitespace)).count();
        let shared = non_blank(&text[..range.start]) + non_blank(&text[range.end..]);
        let total = non_blank(text);
        (shared >= 3 && shared * 4 >= total).then_some(range)
    }

    /// The syntax tokens of a row's line as its own side of the file reads it.
    pub fn tokens(&self, row: &GitDiffRow, old_side: bool) -> Option<&[GitDiffToken<SyntaxTokenKind>]> {
        let side = if old_side { &self.highlights.old } else { &self.highlights.new };
        side.get(row.line_index?).map(Vec::as_slice)
    }

    /// What a layout row draws on one side: its kind, the old side's number for removed
    /// lines (and the old column of a split row), the new one otherwise, and its text;
    /// `None` for a filler.
    pub fn side(&self, row: &GitDiffRow, old_side: bool) -> Option<DiffSide> {
        let index = row.line_index?;
        if row.kind == GitDiffRowKind::Filler {
            return None;
        }
        let line = &self.lines[index];
        let kind = DiffLineKind::from(row.kind);
        Some(DiffSide {
            kind,
            number: if old_side { line.old_number } else { line.new_number },
            text: StyledLine::build(&line.text, self.tokens(row, old_side), self.emphasis(row)),
        })
    }
}

/// What one side of a line row shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiffSide {
    pub kind: DiffLineKind,
    pub number: Option<usize>,
    pub text: StyledLine,
}

/// A row's display text with its styled spans (ranges into `text`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StyledLine {
    pub text: String,
    pub spans: Vec<StyledSpan>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StyledSpan {
    pub range: Range<usize>,
    /// The syntax color; `None` draws in the foreground.
    pub syntax: Option<SyntaxTokenKind>,
    /// The changed words, on the word tint (`diffAdditionWord` / `diffDeletionWord`).
    pub emphasized: bool,
}

impl StyledLine {
    /// The text a row draws: cut to [`MAXIMUM_DRAWN_LENGTH`] characters, line breaks the text
    /// system would act on shown as visible symbols, tabs as four spaces; the syntax tokens
    /// and the emphasis (byte ranges of `raw`) follow the text they covered.
    pub fn build(
        raw: &str,
        tokens: Option<&[GitDiffToken<SyntaxTokenKind>]>,
        emphasis: Option<Range<usize>>,
    ) -> Self {
        let cut = match raw.grapheme_indices(true).nth(MAXIMUM_DRAWN_LENGTH) {
            Some((end, _)) => &raw[..end],
            None => raw,
        };
        let mut syntax: Vec<Option<SyntaxTokenKind>> = vec![None; cut.len()];
        for token in tokens.unwrap_or_default() {
            if token.range.start < cut.len() {
                syntax[token.range.start..token.range.end.min(cut.len())].fill(Some(token.kind));
            }
        }
        let mut emphasized = vec![false; cut.len()];
        if let Some(range) = emphasis.filter(|range| range.start < cut.len()) {
            emphasized[range.start..range.end.min(cut.len())].fill(true);
        }

        let mut line = Self { text: String::with_capacity(cut.len()), spans: Vec::new() };
        for (offset, character) in cut.char_indices() {
            let start = line.text.len();
            match character {
                '\t' => line.text.push_str("    "),
                other => line.text.push(line_break_symbol(other).unwrap_or(other)),
            }
            let end = line.text.len();
            let (kind, emphasis) = (syntax[offset], emphasized[offset]);
            match line.spans.last_mut() {
                Some(span) if span.end_matches(start, kind, emphasis) => span.range.end = end,
                _ => line.spans.push(StyledSpan { range: start..end, syntax: kind, emphasized: emphasis }),
            }
        }
        line.spans.retain(|span| span.syntax.is_some() || span.emphasized);
        line
    }
}

impl StyledSpan {
    fn end_matches(&self, start: usize, syntax: Option<SyntaxTokenKind>, emphasized: bool) -> bool {
        self.range.end == start && self.syntax == syntax && self.emphasized == emphasized
    }
}

/// Characters that would break a row's line, shown as symbols instead.
fn line_break_symbol(character: char) -> Option<char> {
    Some(match character {
        '\r' => '\u{240D}',                  // ␍
        '\u{0B}' => '\u{240B}',              // ␋ vertical tab
        '\u{0C}' => '\u{240C}',              // ␌ form feed
        '\u{85}' | '\u{2028}' => '\u{2424}', // ␤ next line, line separator
        '\u{2029}' => '\u{00B6}',            // ¶ paragraph separator
        _ => return None,
    })
}

/// The text with line-breaking characters replaced by visible symbols.
pub fn display_text(text: &str) -> String {
    text.chars().map(|character| line_break_symbol(character).unwrap_or(character)).collect()
}

// MARK: - List

/// Stacked (one column) or split (old | new) rows.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum DiffListLayout {
    #[default]
    Unified,
    Split,
}

/// A strip before a block of shown lines: the unmodified lines folded away above it (a
/// click shows them), or the block's `@@` range when nothing above is hidden; then the
/// enclosing declaration git would name.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiffFold {
    /// The first hidden line's old line number: stable across both layouts.
    pub id: isize,
    /// The hidden layout rows; empty for a range strip.
    pub rows: Range<usize>,
    /// `@@ -a,b +c,d @@`, shown when no lines are hidden.
    pub range: Option<String>,
    pub section: String,
}

impl DiffFold {
    pub fn hidden_lines(&self) -> usize {
        self.rows.len()
    }

    /// The strip's label: "N unmodified lines" (or "1 unmodified line").
    pub fn label(&self) -> Option<String> {
        match self.hidden_lines() {
            0 => None,
            1 => Some("1 unmodified line".into()),
            count => Some(format!("{count} unmodified lines")),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DiffListRow {
    Header,
    Fold(DiffFold),
    /// A stacked row (index into `unified.rows`).
    Line(usize),
    /// A split row (index into `old.rows` and `new.rows`).
    Pair(usize),
    End,
}

impl DiffListRow {
    pub fn is_line(&self) -> bool {
        matches!(self, Self::Line(_) | Self::Pair(_))
    }

    /// The row's height; line rows are [`LINE_HEIGHT`] unless wrapped (see
    /// [`DiffList::wrapped_height`]).
    pub fn height(&self) -> f32 {
        match self {
            Self::Header => HEADER_HEIGHT,
            Self::Fold(_) => FOLD_HEIGHT,
            Self::End => END_HEIGHT,
            Self::Line(_) | Self::Pair(_) => LINE_HEIGHT,
        }
    }
}

/// Whole lines selected in the list: the rows from `anchor` (where the drag or click
/// started) to `head`, on the side the drag started on in split view (`old_side`; stacked
/// rows have one side).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DiffSelection {
    pub anchor: usize,
    pub head: usize,
    pub old_side: bool,
}

impl DiffSelection {
    pub fn rows(&self) -> std::ops::RangeInclusive<usize> {
        self.anchor.min(self.head)..=self.anchor.max(self.head)
    }
}

/// The rows the diff list shows: the file header, then the changes with three lines of
/// context around each (git's default hunks), longer unmodified runs folded.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DiffList {
    pub rows: Vec<DiffListRow>,
    /// The list row of each change's first line, in order.
    pub change_rows: Vec<usize>,
}

impl DiffList {
    /// Context lines kept around each change.
    pub const CONTEXT: usize = 3;

    /// `expanded` holds the [`DiffFold::id`]s the reader opened.
    pub fn build(
        document: &DiffDocument,
        layout: DiffListLayout,
        collapsed: bool,
        expanded: &HashSet<isize>,
    ) -> Self {
        let mut list = Self { rows: vec![DiffListRow::Header], change_rows: Vec::new() };
        if collapsed {
            return list;
        }
        let unified = layout == DiffListLayout::Unified;
        let layout_rows = if unified { &document.unified.rows } else { &document.old.rows };
        let change_starts: HashSet<usize> =
            if unified { &document.unified.change_starts } else { &document.old.change_starts }
                .iter()
                .copied()
                .collect();
        let row = |index| if unified { DiffListRow::Line(index) } else { DiffListRow::Pair(index) };
        let is_context = |index: usize| layout_rows[index].kind == GitDiffRowKind::Context;
        let fold_id = |range: &Range<usize>| {
            old_number(document, &layout_rows[range.start])
                .map_or(range.start as isize, |number| number as isize)
        };

        // Hidden runs of context rows.
        let mut hidden: Vec<Range<usize>> = Vec::new();
        let mut index = 0;
        while index < layout_rows.len() {
            if !is_context(index) {
                index += 1;
                continue;
            }
            let start = index;
            while index < layout_rows.len() && is_context(index) {
                index += 1;
            }
            let from = if start == 0 { start } else { start + Self::CONTEXT };
            let to = if index == layout_rows.len() { index } else { index.saturating_sub(Self::CONTEXT) };
            if to > from {
                let fold = from..to;
                if !expanded.contains(&fold_id(&fold)) {
                    hidden.push(fold);
                }
            }
        }

        let mut next = 0;
        let mut hidden_index = 0;
        let mut block_started = false;
        while next < layout_rows.len() {
            if let Some(fold) = hidden.get(hidden_index).filter(|fold| fold.start == next).cloned() {
                hidden_index += 1;
                let section = if fold.end < layout_rows.len() {
                    Self::section(document, &layout_rows[fold.end])
                } else {
                    String::new()
                };
                next = fold.end;
                list.rows.push(DiffListRow::Fold(DiffFold {
                    id: fold_id(&fold),
                    rows: fold,
                    range: None,
                    section,
                }));
                block_started = true;
                continue;
            }
            if !block_started {
                // The file opens with a change: its block's range, as git heads a hunk.
                let block_end = hidden.get(hidden_index).map_or(layout_rows.len(), |fold| fold.start);
                let new_rows: &[GitDiffRow] = if unified { &[] } else { &document.new.rows[next..block_end] };
                list.rows.push(DiffListRow::Fold(DiffFold {
                    id: -1,
                    rows: next..next,
                    range: Some(range_text(document, &layout_rows[next..block_end], new_rows)),
                    section: String::new(),
                }));
                block_started = true;
            }
            if change_starts.contains(&next) {
                list.change_rows.push(list.rows.len());
            }
            list.rows.push(row(next));
            next += 1;
        }
        list.rows.push(DiffListRow::End);
        list
    }

    /// Git's default function context: the nearest line of the old file above `row` that
    /// starts with a letter, `_` or `$`, at most 80 characters.
    pub fn section(document: &DiffDocument, row: &GitDiffRow) -> String {
        let Some(mut index) = row.line_index else { return String::new() };
        while index > 0 {
            index -= 1;
            let line = &document.lines[index];
            if line.kind == GitDiffLineKind::Added {
                continue;
            }
            let Some(first) = line.text.chars().next() else { continue };
            if first.is_alphabetic() || first == '_' || first == '$' {
                return line.text.trim_end().graphemes(true).take(80).collect();
            }
        }
        String::new()
    }

    /// The file line a list row shows on one side: a stacked row's line, or a split row's
    /// old or new line; `None` for headers, folds and fillers.
    pub fn line<'a>(
        &self,
        row: usize,
        old_side: bool,
        document: &'a DiffDocument,
    ) -> Option<&'a GitDiffLine> {
        let layout_row = match self.rows.get(row)? {
            DiffListRow::Line(index) => &document.unified.rows[*index],
            DiffListRow::Pair(index) if old_side => &document.old.rows[*index],
            DiffListRow::Pair(index) => &document.new.rows[*index],
            DiffListRow::Header | DiffListRow::Fold(_) | DiffListRow::End => return None,
        };
        layout_row.line_index.map(|index| &document.lines[index])
    }

    /// The text ⌘C copies: the selected lines as the file has them, one per line, without
    /// markers or line numbers.
    pub fn text(&self, selection: &DiffSelection, document: &DiffDocument) -> String {
        selection
            .rows()
            .filter_map(|row| self.line(row, selection.old_side, document).map(|line| line.text.as_str()))
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// ⌘A: every line row, keeping the side.
    pub fn select_all(&self, old_side: bool) -> Option<DiffSelection> {
        let first = self.rows.iter().position(DiffListRow::is_line)?;
        let last = self.rows.iter().rposition(DiffListRow::is_line)?;
        Some(DiffSelection { anchor: first, head: last, old_side })
    }

    /// F7: the first change below `anchor` (the row a third of the way down the visible area).
    pub fn next_change(&self, anchor: usize) -> Option<usize> {
        self.change_rows.iter().copied().find(|row| *row > anchor)
    }

    /// ⇧F7: the last change above `anchor`.
    pub fn previous_change(&self, anchor: usize) -> Option<usize> {
        self.change_rows.iter().copied().rev().find(|row| *row < anchor)
    }

    /// The file line a list row stands for (a split row, the earlier of its two lines): what
    /// a layout change or wrap toggle keeps at the top.
    pub fn anchor_line(&self, row: usize, document: &DiffDocument) -> Option<usize> {
        match self.rows.get(row)? {
            DiffListRow::Line(index) => document.unified.rows[*index].line_index,
            DiffListRow::Pair(index) => {
                [document.old.rows[*index].line_index, document.new.rows[*index].line_index]
                    .into_iter()
                    .flatten()
                    .min()
            }
            DiffListRow::Fold(fold) => (!fold.rows.is_empty()).then_some(fold.rows.start),
            DiffListRow::Header | DiffListRow::End => None,
        }
    }

    /// The first row standing for `line` or a later one: where to scroll after rebuilding.
    pub fn row_for_line(&self, line: usize, document: &DiffDocument) -> Option<usize> {
        (0..self.rows.len()).find(|row| self.anchor_line(*row, document).is_some_and(|anchor| anchor >= line))
    }

    /// A line row's height with wrapping on: the most lines either side wraps to.
    pub fn wrapped_height(
        &self,
        row: usize,
        document: &DiffDocument,
        code_width: f32,
        column_width: f32,
    ) -> f32 {
        let lines_of =
            |index: usize| wrapped_lines(columns(&document.lines[index].text), code_width, column_width);
        match self.rows.get(row) {
            Some(DiffListRow::Line(index)) => {
                document.unified.rows[*index].line_index.map_or(1, lines_of) as f32 * LINE_HEIGHT
            }
            Some(DiffListRow::Pair(index)) => {
                [document.old.rows[*index].line_index, document.new.rows[*index].line_index]
                    .into_iter()
                    .flatten()
                    .map(lines_of)
                    .max()
                    .unwrap_or(1) as f32
                    * LINE_HEIGHT
            }
            Some(other) => other.height(),
            None => LINE_HEIGHT,
        }
    }
}

fn old_number(document: &DiffDocument, row: &GitDiffRow) -> Option<usize> {
    row.line_index.and_then(|index| document.lines[index].old_number)
}

/// `@@ -a,b +c,d @@` for a block of shown rows.
fn range_text(document: &DiffDocument, rows: &[GitDiffRow], new_rows: &[GitDiffRow]) -> String {
    let mut indices: Vec<usize> = rows.iter().chain(new_rows).filter_map(|row| row.line_index).collect();
    indices.sort_unstable();
    indices.dedup();
    let lines: Vec<&GitDiffLine> = indices.iter().map(|index| &document.lines[*index]).collect();
    let old: Vec<usize> = lines.iter().filter_map(|line| line.old_number).collect();
    let new: Vec<usize> = lines.iter().filter_map(|line| line.new_number).collect();
    format!(
        "@@ -{},{} +{},{} @@",
        old.first().copied().unwrap_or(0),
        old.len(),
        new.first().copied().unwrap_or(0),
        new.len()
    )
}

// MARK: - Loading

/// Where a diff's file lives, as the watcher reports paths.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiffLocation {
    pub root: PathBuf,
    pub real_root: PathBuf,
    pub real_file_path: PathBuf,
}

impl DiffLocation {
    /// Only the file itself and git's own state can change its diff. `external_git_directory`
    /// is a worktree's git directory outside the root, when it has one.
    pub fn is_relevant(&self, path: &Path, external_git_directory: Option<&Path>) -> bool {
        let git_directory = self.real_root.join(".git");
        path == self.real_file_path
            || path.starts_with(&git_directory)
            || external_git_directory.is_some_and(|directory| path.starts_with(directory))
    }

    /// Whether a batch of file-system events should reload the diff: the watcher asked for a
    /// rescan (it dropped events), or one of `paths` is relevant.
    pub fn needs_reload(
        &self,
        paths: &[PathBuf],
        needs_rescan: bool,
        external_git_directory: Option<&Path>,
    ) -> bool {
        needs_rescan || paths.iter().any(|path| self.is_relevant(path, external_git_directory))
    }

    /// The paths to watch: the repository root, and an external git directory.
    pub fn watched_paths(&self, external_git_directory: Option<&Path>) -> Vec<PathBuf> {
        std::iter::once(self.root.clone()).chain(external_git_directory.map(Path::to_path_buf)).collect()
    }
}

#[derive(Clone, Debug)]
pub enum DiffContent {
    Text(Box<DiffDocument>),
    /// Shown centered instead of the list.
    Message(String),
}

#[derive(Clone, Debug)]
pub struct DiffLoadResult {
    pub location: Option<DiffLocation>,
    pub file_exists: bool,
    pub content: DiffContent,
}

/// The note a diff tab shows instead of lines, for a git result without text.
pub fn diff_message(diff: &GitFileDiff, staged: bool) -> Option<&'static str> {
    Some(match diff {
        GitFileDiff::Text(_) => return None,
        GitFileDiff::Binary => "Binary file changed\nText diff is unavailable for this file.",
        GitFileDiff::TooLarge => "This diff is too large to show.",
        GitFileDiff::NoChanges if staged => "No staged changes",
        GitFileDiff::NoChanges => "No changes",
        GitFileDiff::EmptyFile { is_new: true } => "Empty file added",
        GitFileDiff::EmptyFile { is_new: false } => "Empty file deleted",
        GitFileDiff::Unavailable => "Could not read this diff.",
    })
}

pub const LOADING_MESSAGE: &str = "Loading diff…";
pub const GIT_MISSING_MESSAGE: &str = "Git is not installed.";
pub const NOT_IN_REPOSITORY_MESSAGE: &str = "This file is not in a Git repository.";

/// Reads and lays out the diff of `file_path` (staged or working tree). Blocks on git: run
/// it off the UI thread.
pub fn load_diff(file_path: &Path, staged: bool) -> DiffLoadResult {
    // Like `standardizedFileURL`: `..` and `.` never reach git or the watcher's paths.
    let file_path = &crate::editor::standardized(file_path);
    let file_exists = file_path.exists();
    let message = |text: &str, location: Option<DiffLocation>| DiffLoadResult {
        location,
        file_exists,
        content: DiffContent::Message(text.to_string()),
    };
    if soprano_git::reader::executable().is_none() {
        return message(GIT_MISSING_MESSAGE, None);
    }
    let folder = file_path.parent().unwrap_or(Path::new("/"));
    // Walks up from the folder, so a deleted file still finds its repository.
    let Some(root) = soprano_git::branch::repository_root(&folder.to_string_lossy()) else {
        return message(NOT_IN_REPOSITORY_MESSAGE, None);
    };
    let real_root = resolved_path(&root);
    let real_file_path = resolved_path(file_path);
    let Some(relative) =
        relative_path(file_path, &root).or_else(|| relative_path(&real_file_path, &real_root))
    else {
        return message(NOT_IN_REPOSITORY_MESSAGE, None);
    };
    let location = DiffLocation { root: root.clone(), real_root, real_file_path };
    let diff = soprano_git::reader::diff(&root, &relative, staged);
    if let Some(text) = diff_message(&diff, staged) {
        return message(text, Some(location));
    }
    let GitFileDiff::Text(lines) = diff else { return message("Could not read this diff.", Some(location)) };
    let language = file_path.file_name().and_then(|name| name.to_str()).and_then(CodeLanguage::for_file);
    DiffLoadResult {
        location: Some(location),
        file_exists,
        content: DiffContent::Text(Box::new(DiffDocument::new(relative, lines, language))),
    }
}

/// `path` relative to `root`, with `/` separators; `None` outside it or for the root itself.
pub fn relative_path(path: &Path, root: &Path) -> Option<String> {
    let relative = path.strip_prefix(root).ok()?;
    let parts: Vec<String> =
        relative.components().map(|part| part.as_os_str().to_string_lossy().into_owned()).collect();
    (!parts.is_empty()).then(|| parts.join("/"))
}

/// The symlink-free path, resolving the nearest existing ancestor for a deleted file.
pub fn resolved_path(path: &Path) -> PathBuf {
    if let Ok(resolved) = std::fs::canonicalize(path) {
        return without_verbatim_prefix(resolved);
    }
    match (path.parent(), path.file_name()) {
        (Some(parent), Some(name)) if !parent.as_os_str().is_empty() && parent != path => {
            resolved_path(parent).join(name)
        }
        _ => path.to_path_buf(),
    }
}

/// On Windows, `C:\x` for the verbatim `\\?\C:\x` that `canonicalize` returns: watchers
/// report plain paths, and the two spellings share no components. UNC and other paths, and
/// every path elsewhere, stay as they are.
fn without_verbatim_prefix(path: PathBuf) -> PathBuf {
    if cfg!(windows)
        && let Some(plain) = path.to_str().and_then(|text| text.strip_prefix(r"\\?\"))
        && !plain.starts_with(r"UNC\")
    {
        return PathBuf::from(plain);
    }
    path
}

#[cfg(test)]
mod tests {
    use super::*;
    use GitDiffLineKind::{Added, Context, Removed};

    fn line(kind: GitDiffLineKind, old: Option<usize>, new: Option<usize>, text: &str) -> GitDiffLine {
        GitDiffLine::new(kind, old, new, text)
    }

    fn fold(id: isize, rows: Range<usize>, range: Option<&str>, section: &str) -> DiffListRow {
        DiffListRow::Fold(DiffFold {
            id,
            rows,
            range: range.map(str::to_string),
            section: section.to_string(),
        })
    }

    #[test]
    fn characters_that_break_a_line_show_as_symbols() {
        let text = "a\rb\u{2028}c\u{0C}d\u{2029}e\u{85}f";
        let shown = display_text(text);
        assert!(!shown.contains('\r'));
        assert!(!shown.contains('\u{2028}'));
        assert_eq!(shown.chars().count(), text.chars().count());
    }

    #[test]
    fn row_text_keeps_token_and_emphasis_spans_on_their_text_through_tabs_and_symbols() {
        let raw = "\tlet a\r= 1";
        let tokens = [
            GitDiffToken { range: 1..4, kind: SyntaxTokenKind::Keyword },
            GitDiffToken { range: 9..10, kind: SyntaxTokenKind::Number },
        ];
        let line = StyledLine::build(raw, Some(&tokens), Some(5..10));
        assert_eq!(line.text, "    let a\u{240D}= 1");
        let texts: Vec<(&str, Option<SyntaxTokenKind>, bool)> = line
            .spans
            .iter()
            .map(|span| (&line.text[span.range.clone()], span.syntax, span.emphasized))
            .collect();
        assert_eq!(
            texts,
            [
                ("let", Some(SyntaxTokenKind::Keyword), false),
                ("a\u{240D}= ", None, true),
                ("1", Some(SyntaxTokenKind::Number), true),
            ]
        );
    }

    #[test]
    fn long_lines_draw_only_their_first_two_thousand_characters() {
        let raw = "é".repeat(2500);
        let line = StyledLine::build(&raw, None, None);
        assert_eq!(line.text.chars().count(), MAXIMUM_DRAWN_LENGTH);
        assert_eq!(columns(&raw), MAXIMUM_DRAWN_LENGTH);
        assert_eq!(columns("\t日本"), 8);
    }

    #[test]
    fn wrapped_lines_fit_whole_columns_into_the_width() {
        assert_eq!(wrapped_lines(0, 100.0, 8.0), 1);
        assert_eq!(wrapped_lines(12, 100.0, 8.0), 1);
        assert_eq!(wrapped_lines(13, 100.0, 8.0), 2);
        assert_eq!(wrapped_lines(5, 3.0, 8.0), 5);
    }

    #[test]
    fn long_unmodified_runs_fold_behind_a_strip_naming_the_enclosing_declaration() {
        let mut lines = vec![line(Context, Some(1), Some(1), "struct Login {")];
        for number in 2..=10 {
            lines.push(line(Context, Some(number), Some(number), &format!("    let a{number} = 1")));
        }
        lines.push(line(Removed, Some(11), None, "    let old = 1"));
        lines.push(line(Added, None, Some(11), "    let new = 1"));
        for number in 12..=20 {
            lines.push(line(Context, Some(number), Some(number), &format!("    let b{number} = 1")));
        }
        let document = DiffDocument::new("Sources/Login.swift", lines, None);
        assert_eq!((document.additions, document.deletions), (1, 1));
        assert_eq!(document.change, FileChange::Modified);

        let list = DiffList::build(&document, DiffListLayout::Unified, false, &HashSet::new());
        // 10 context lines above the change keep 3; 9 below keep 3.
        assert_eq!(list.rows[0], DiffListRow::Header);
        assert_eq!(list.rows[1], fold(1, 0..7, None, "struct Login {"));
        assert_eq!(list.rows[2..10], (7..15).map(DiffListRow::Line).collect::<Vec<_>>());
        // Nothing follows the last fold, so it names no declaration.
        assert_eq!(list.rows[10], fold(15, 15..21, None, ""));
        assert_eq!(list.rows.last(), Some(&DiffListRow::End));
        assert_eq!(list.change_rows, [5]);
        if let DiffListRow::Fold(strip) = &list.rows[1] {
            assert_eq!(strip.hidden_lines(), 7);
            assert_eq!(strip.label().as_deref(), Some("7 unmodified lines"));
        }

        // Opening a fold shows its lines; collapsing leaves only the header.
        let expanded = DiffList::build(&document, DiffListLayout::Unified, false, &HashSet::from([1]));
        assert_eq!(expanded.rows[1], fold(-1, 0..0, Some("@@ -1,14 +1,14 @@"), ""));
        assert_eq!(expanded.rows[2], DiffListRow::Line(0));
        assert_eq!(
            DiffList::build(&document, DiffListLayout::Split, true, &HashSet::new()).rows,
            [DiffListRow::Header]
        );
    }

    #[test]
    fn copying_a_split_selection_takes_the_side_the_drag_started_on_and_skips_fillers() {
        let lines = vec![
            line(Context, Some(1), Some(1), "one"),
            line(Removed, Some(2), None, "two"),
            line(Context, Some(3), Some(2), "three"),
            line(Added, None, Some(3), "\tfour"),
        ];
        let document = DiffDocument::new("app.txt", lines, None);
        let list = DiffList::build(&document, DiffListLayout::Split, false, &HashSet::new());
        // header, range strip, four split rows, end.
        assert_eq!(list.rows.len(), 7);
        let mut all = DiffSelection { anchor: 5, head: 0, old_side: true };
        assert_eq!(list.text(&all, &document), "one\ntwo\nthree");
        all.old_side = false;
        assert_eq!(list.text(&all, &document), "one\nthree\n\tfour");

        let stacked = DiffList::build(&document, DiffListLayout::Unified, false, &HashSet::new());
        let selection = DiffSelection { anchor: 2, head: 5, old_side: true };
        assert_eq!(stacked.text(&selection, &document), "one\ntwo\nthree\n\tfour");
        assert_eq!(stacked.select_all(true), Some(DiffSelection { anchor: 2, head: 5, old_side: true }));
    }

    #[test]
    fn a_file_opening_with_its_change_is_headed_by_the_blocks_range_and_navigates_by_change() {
        // "one\ntwo\nthree" became "one\nthree\nfour".
        let lines = vec![
            line(Context, Some(1), Some(1), "one"),
            line(Removed, Some(2), None, "two"),
            line(Context, Some(3), Some(2), "three"),
            line(Added, None, Some(3), "four"),
        ];
        let document = DiffDocument::new("app.txt", lines, None);
        let stacked = DiffList::build(&document, DiffListLayout::Unified, false, &HashSet::new());
        assert_eq!(
            stacked.rows,
            [
                DiffListRow::Header,
                fold(-1, 0..0, Some("@@ -1,3 +1,3 @@"), ""),
                DiffListRow::Line(0),
                DiffListRow::Line(1),
                DiffListRow::Line(2),
                DiffListRow::Line(3),
                DiffListRow::End,
            ]
        );
        assert_eq!(stacked.change_rows, [3, 5]);
        assert_eq!(stacked.next_change(0), Some(3));
        assert_eq!(stacked.next_change(3), Some(5));
        assert_eq!(stacked.next_change(5), None);
        assert_eq!(stacked.previous_change(5), Some(3));
        assert_eq!(stacked.previous_change(3), None);

        let selection = DiffSelection { anchor: 3, head: 4, old_side: false };
        assert_eq!(stacked.text(&selection, &document), "two\nthree");

        let split = DiffList::build(&document, DiffListLayout::Split, false, &HashSet::new());
        assert_eq!(
            document.old.rows.iter().map(|row| row.kind).collect::<Vec<_>>(),
            [
                GitDiffRowKind::Context,
                GitDiffRowKind::Removed,
                GitDiffRowKind::Context,
                GitDiffRowKind::Filler
            ]
        );
        assert_eq!(split.rows.iter().filter(|row| matches!(row, DiffListRow::Pair(_))).count(), 4);
        assert_eq!(split.change_rows.len(), 2);
        // Switching layouts keeps the same file line on top.
        let line = stacked.anchor_line(4, &document).unwrap();
        assert_eq!(split.row_for_line(line, &document), Some(4));
    }

    #[test]
    fn changed_words_show_only_when_the_lines_share_real_content() {
        let lines = vec![
            line(Removed, Some(1), None, "let total = price * 2"),
            line(Added, None, Some(1), "let total = price * 3"),
            line(Removed, Some(2), None, "  foo)"),
            line(Added, None, Some(2), "  bar)"),
        ];
        let document = DiffDocument::new("a.swift", lines, CodeLanguage::for_file("a.swift"));
        let rows = &document.unified.rows;
        assert_eq!(document.emphasis(&rows[0]), Some(20..21));
        assert_eq!(document.emphasis(&rows[1]), None);
        let side = document.side(&rows[0], true).unwrap();
        assert_eq!(side.number, Some(1));
        assert_eq!(side.kind, DiffLineKind::Removed);
        assert_eq!(side.text.spans.first().map(|span| span.syntax), Some(Some(SyntaxTokenKind::Keyword)));
        assert!(side.text.spans.iter().any(|span| span.emphasized));
        assert_eq!(document.side(&document.new.rows[0], false).map(|side| side.number), Some(Some(1)));
    }

    #[test]
    fn git_results_without_text_become_notes() {
        assert_eq!(diff_message(&GitFileDiff::NoChanges, true), Some("No staged changes"));
        assert_eq!(diff_message(&GitFileDiff::NoChanges, false), Some("No changes"));
        assert_eq!(
            diff_message(&GitFileDiff::Binary, false),
            Some("Binary file changed\nText diff is unavailable for this file.")
        );
        assert_eq!(diff_message(&GitFileDiff::EmptyFile { is_new: true }, false), Some("Empty file added"));
        assert_eq!(diff_message(&GitFileDiff::Text(Vec::new()), false), None);
    }

    #[test]
    fn only_the_file_and_gits_own_state_are_relevant_to_a_diff() {
        let location = DiffLocation {
            root: PathBuf::from("/repo"),
            real_root: PathBuf::from("/real/repo"),
            real_file_path: PathBuf::from("/real/repo/src/a.rs"),
        };
        assert!(location.is_relevant(Path::new("/real/repo/src/a.rs"), None));
        assert!(location.is_relevant(Path::new("/real/repo/.git/index"), None));
        assert!(!location.is_relevant(Path::new("/real/repo/src/b.rs"), None));
        assert!(!location.is_relevant(Path::new("/real/repo/.gitignore"), None));
        assert!(
            location
                .is_relevant(Path::new("/wt/.git/worktrees/x/HEAD"), Some(Path::new("/wt/.git/worktrees/x")))
        );
        assert_eq!(
            relative_path(Path::new("/repo/src/a.rs"), Path::new("/repo")).as_deref(),
            Some("src/a.rs")
        );
        assert_eq!(relative_path(Path::new("/repo"), Path::new("/repo")), None);
        assert_eq!(relative_path(Path::new("/repository/a"), Path::new("/repo")), None);

        // A batch reloads when any path is relevant, or when the watcher dropped events.
        let unrelated = [PathBuf::from("/real/repo/src/b.rs")];
        assert!(!location.needs_reload(&unrelated, false, None));
        assert!(location.needs_reload(&unrelated, true, None));
        assert!(location.needs_reload(
            &[unrelated[0].clone(), PathBuf::from("/real/repo/.git/HEAD")],
            false,
            None
        ));
    }

    #[test]
    fn verbatim_paths_lose_their_prefix_only_on_windows() {
        let plain = without_verbatim_prefix(PathBuf::from(r"\\?\C:\repo\a.rs"));
        let expected = if cfg!(windows) { r"C:\repo\a.rs" } else { r"\\?\C:\repo\a.rs" };
        assert_eq!(plain, PathBuf::from(expected));
        let unc = PathBuf::from(r"\\?\UNC\server\share\a.rs");
        assert_eq!(without_verbatim_prefix(unc.clone()), unc);
    }

    #[test]
    fn the_fold_strip_names_at_most_eighty_characters_of_the_declaration() {
        // "é" written as e + combining accent: 80 characters, 160 code points.
        let long = format!("struct {}", "e\u{301}".repeat(90));
        let mut lines = vec![GitDiffLine::new(Context, Some(1), Some(1), &long)];
        for number in 2..=10 {
            lines.push(line(Context, Some(number), Some(number), "    x"));
        }
        lines.push(line(Added, None, Some(11), "    y"));
        let document = DiffDocument::new("a.swift", lines, None);
        let section = DiffList::section(&document, &document.unified.rows[7]);
        assert_eq!(section.graphemes(true).count(), 80);
        assert!(section.ends_with("e\u{301}"));
    }

    #[cfg(unix)]
    #[test]
    fn a_diff_tab_reads_the_working_tree_change_of_a_real_repository() {
        if soprano_git::reader::executable().is_none() {
            return;
        }
        let root = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(root.path()).unwrap();
        let git = |arguments: &[&str]| {
            let status = std::process::Command::new("git")
                .arg("-C")
                .arg(&root)
                .args([
                    "-c",
                    "user.name=t",
                    "-c",
                    "user.email=t@t",
                    "-c",
                    "commit.gpgsign=false",
                    "-c",
                    "core.hooksPath=/dev/null",
                ])
                .args(arguments)
                .output()
                .unwrap();
            assert!(status.status.success());
        };
        git(&["init", "-q"]);
        let file = root.join("app.txt");
        std::fs::write(&file, "one\ntwo\nthree\n").unwrap();
        git(&["add", "app.txt"]);
        git(&["commit", "-qm", "init"]);
        std::fs::write(&file, "one\nthree\n").unwrap();

        let result = load_diff(&file, false);
        let DiffContent::Text(document) = result.content else { panic!("expected a text diff") };
        assert_eq!(document.path, "app.txt");
        assert_eq!(
            document.lines.iter().map(|line| line.text.as_str()).collect::<Vec<_>>(),
            ["one", "two", "three"]
        );
        assert!(result.location.unwrap().is_relevant(&file, None));

        let staged = load_diff(&file, true);
        assert!(matches!(staged.content, DiffContent::Message(text) if text == "No staged changes"));
        let outside = load_diff(Path::new("/"), false);
        assert!(matches!(outside.content, DiffContent::Message(_)));
        // `..` in the path is resolved before git sees it.
        let dotted = load_diff(&root.join("missing/../app.txt"), false);
        let DiffContent::Text(document) = dotted.content else { panic!("expected a text diff") };
        assert_eq!(document.path, "app.txt");
        assert_eq!(dotted.location.unwrap().real_file_path, file);
    }
}
