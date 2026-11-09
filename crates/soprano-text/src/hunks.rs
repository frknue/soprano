//! The chat's file-change diffs (port of `Chat/Diff/InlineDiffDrawing.swift` and the model
//! of `FileDiffRowView.swift`): unified hunks parsed into numbered lines, colored per side
//! of the file, ready to draw as stacked rows with tint, change bar and line number.

use std::collections::HashMap;

use crate::diff::{self, DiffLineKind};
use crate::syntax::{self, CodeLanguage, SyntaxToken};

/// One line of a hunk.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct HunkLine {
    pub kind: DiffLineKind,
    /// Line text without the leading `+`/`-`/space (the marker line keeps its `\`).
    pub text: String,
    pub old_number: Option<usize>,
    pub new_number: Option<usize>,
}

impl HunkLine {
    /// What the "\ No newline at end of file" row shows.
    pub const NO_NEWLINE_TEXT: &str = "No newline at end of file";

    /// The text a row draws.
    pub fn display_text(&self) -> &str {
        if self.kind == DiffLineKind::NoNewlineMarker { Self::NO_NEWLINE_TEXT } else { &self.text }
    }

    /// Columns the line takes in a monospaced font: tabs four, CJK and emoji two.
    pub fn columns(&self) -> usize {
        if self.kind == DiffLineKind::NoNewlineMarker {
            Self::NO_NEWLINE_TEXT.chars().count()
        } else {
            diff::columns(&self.text)
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct DiffHunk {
    pub old_start: usize,
    pub new_start: usize,
    /// Text after the closing "@@" (a hashline op, the enclosing function); may be empty.
    pub section: String,
    pub lines: Vec<HunkLine>,
}

/// Unified hunks (`@@ -a,b +c,d @@ section` and their `+`/`-`/` ` lines); file header lines
/// before the first hunk are skipped.
pub fn parse_hunks(text: &str) -> Vec<DiffHunk> {
    let mut lines: Vec<&str> = text.split('\n').collect();
    if lines.last().is_some_and(|line| line.is_empty()) {
        lines.pop();
    }
    let mut hunks = Vec::new();
    let mut hunk: Option<DiffHunk> = None;
    let (mut old_line, mut new_line) = (0, 0);
    let (mut old_remaining, mut new_remaining) = (0_isize, 0_isize);
    for raw in lines {
        let first = raw.chars().next();
        if let Some(current) = hunk.as_mut()
            && (old_remaining > 0 || new_remaining > 0 || first == Some('\\'))
        {
            let body = first.map_or("", |first| &raw[first.len_utf8()..]).to_string();
            let line =
                |kind, old_number, new_number| HunkLine { kind, text: body.clone(), old_number, new_number };
            match first {
                Some('+') => {
                    current.lines.push(line(DiffLineKind::Added, None, Some(new_line)));
                    new_line += 1;
                    new_remaining -= 1;
                    continue;
                }
                Some('-') => {
                    current.lines.push(line(DiffLineKind::Removed, Some(old_line), None));
                    old_line += 1;
                    old_remaining -= 1;
                    continue;
                }
                // An empty line is a context line whose space was stripped.
                Some(' ') | None => {
                    current.lines.push(line(DiffLineKind::Context, Some(old_line), Some(new_line)));
                    old_line += 1;
                    new_line += 1;
                    old_remaining -= 1;
                    new_remaining -= 1;
                    continue;
                }
                Some('\\') => {
                    current.lines.push(HunkLine {
                        kind: DiffLineKind::NoNewlineMarker,
                        text: raw.to_string(),
                        old_number: None,
                        new_number: None,
                    });
                    continue;
                }
                _ => {}
            }
        }
        let Some(header) = Header::parse(raw) else { continue };
        if let Some(finished) = hunk.take() {
            hunks.push(finished);
        }
        hunk = Some(DiffHunk {
            old_start: header.old_start,
            new_start: header.new_start,
            section: header.section,
            lines: Vec::new(),
        });
        old_line = header.old_start;
        new_line = header.new_start;
        old_remaining = header.old_count as isize;
        new_remaining = header.new_count as isize;
    }
    hunks.extend(hunk);
    hunks
}

/// "@@ -a[,b] +c[,d] @@ section".
struct Header {
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
    section: String,
}

impl Header {
    fn parse(line: &str) -> Option<Self> {
        if !line.starts_with("@@ -") {
            return None;
        }
        let close = 3 + line[3..].find(" @@")?;
        let ranges: Vec<&str> = line[3..close].split(' ').filter(|part| !part.is_empty()).collect();
        let [old, new] = ranges.as_slice() else { return None };
        let (old_start, old_count) = Self::range(old.strip_prefix('-')?)?;
        let (new_start, new_count) = Self::range(new.strip_prefix('+')?)?;
        let section = &line[close + 3..];
        let section = section.strip_prefix(' ').unwrap_or(section);
        Some(Self { old_start, old_count, new_start, new_count, section: section.to_string() })
    }

    fn range(text: &str) -> Option<(usize, usize)> {
        let parts: Vec<&str> = text.split(',').collect();
        let start = parts[0].parse().ok()?;
        match parts.as_slice() {
            [_] => Some((start, 1)),
            [_, count] => Some((start, count.parse().ok()?)),
            _ => None,
        }
    }
}

/// Syntax colors for both sides of a chat diff, per line, keyed by old and new line number;
/// ranges are UTF-8 bytes of the line.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HunkHighlights {
    pub old: HashMap<usize, Vec<SyntaxToken>>,
    pub new: HashMap<usize, Vec<SyntaxToken>>,
}

impl HunkHighlights {
    /// Larger sides stay uncolored.
    pub const MAXIMUM_LENGTH: usize = 1_500_000;

    /// Colors from the hunks of `path`: each side rebuilt from its lines and highlighted
    /// whole, so multi-line strings and comments color correctly.
    pub fn compute(hunks: &[DiffHunk], path: &str) -> Self {
        let Some(language) = path.split('/').next_back().and_then(CodeLanguage::for_file) else {
            return Self::default();
        };
        let lines: Vec<&HunkLine> = hunks.iter().flat_map(|hunk| &hunk.lines).collect();
        Self {
            old: side(&lines, DiffLineKind::Added, |line| line.old_number, language),
            new: side(&lines, DiffLineKind::Removed, |line| line.new_number, language),
        }
    }
}

fn side(
    lines: &[&HunkLine],
    excluded: DiffLineKind,
    number: impl Fn(&HunkLine) -> Option<usize>,
    language: &CodeLanguage,
) -> HashMap<usize, Vec<SyntaxToken>> {
    let mut numbers = Vec::new();
    let mut starts = Vec::new();
    let mut text = String::new();
    for line in
        lines.iter().filter(|line| line.kind != excluded && line.kind != DiffLineKind::NoNewlineMarker)
    {
        let Some(line_number) = number(line) else { continue };
        if !numbers.is_empty() {
            text.push('\n');
        }
        numbers.push(line_number);
        starts.push(text.len());
        text.push_str(&line.text);
        if text.len() > HunkHighlights::MAXIMUM_LENGTH {
            return HashMap::new();
        }
    }
    let mut result: HashMap<usize, Vec<SyntaxToken>> = HashMap::new();
    if numbers.is_empty() {
        return result;
    }
    let line_end = |line: usize| starts.get(line + 1).map_or(text.len(), |next| next - 1);
    for token in syntax::tokens(&text, language) {
        // The last line starting at or before the token.
        let mut line = starts.partition_point(|start| *start <= token.range.start).saturating_sub(1);
        while line < starts.len() && starts[line] < token.range.end {
            let from = token.range.start.max(starts[line]);
            let to = token.range.end.min(line_end(line));
            if to > from {
                result
                    .entry(numbers[line])
                    .or_default()
                    .push(SyntaxToken { range: from - starts[line]..to - starts[line], kind: token.kind });
            }
            line += 1;
        }
    }
    result
}

/// A row of an inline diff.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InlineDiffLine {
    /// Between hunks ("⋯") or a hunk's section text (a hashline op: "PUT 12.=14:").
    Separator(String),
    /// `numbered`: the hunk states where it sits, so the line shows its number.
    Line { line: HunkLine, numbered: bool },
}

/// A file change's diff ready to draw: hunk separators and lines, counts, syntax colors.
#[derive(Clone, Debug, Default)]
pub struct InlineDiff {
    pub lines: Vec<InlineDiffLine>,
    pub additions: usize,
    pub deletions: usize,
    pub highlights: HunkHighlights,
    /// The largest line number shown (the number column's width).
    pub max_number: usize,
    hunks: Vec<DiffHunk>,
    path: String,
    highlightable: bool,
    is_highlighted: bool,
}

impl InlineDiff {
    /// Lines past this are not syntax colored (a streamed write recolors on every new line).
    pub const HIGHLIGHT_LIMIT: usize = 3_000;
    /// Below this many columns of code a wrapped line would break every few characters:
    /// the lines stay whole and the diff scrolls sideways instead.
    pub const MINIMUM_WRAP_COLUMNS: usize = 40;

    /// `diff`: unified hunks as a file change carries them, of the file at `path`.
    /// `full_content`: the hunk is a written file's whole content, shown as plain lines.
    pub fn new(diff: &str, path: &str, full_content: bool) -> Self {
        let hunks = parse_hunks(diff);
        let mut inline = Self { path: path.to_string(), ..Self::default() };
        let mut all_numbered = true;
        for (index, hunk) in hunks.iter().enumerate() {
            let numbered = hunk.old_start != 0 || hunk.new_start != 0;
            all_numbered &= numbered;
            if index > 0 || !hunk.section.is_empty() {
                let separator =
                    if hunk.section.is_empty() { "⋯".to_string() } else { hunk.section.clone() };
                inline.lines.push(InlineDiffLine::Separator(separator));
            }
            for line in &hunk.lines {
                let mut line = line.clone();
                match line.kind {
                    DiffLineKind::Added => inline.additions += 1,
                    DiffLineKind::Removed => inline.deletions += 1,
                    DiffLineKind::Context | DiffLineKind::NoNewlineMarker => {}
                }
                if full_content && line.kind == DiffLineKind::Added {
                    line.kind = DiffLineKind::Context;
                }
                if numbered {
                    inline.max_number =
                        inline.max_number.max(line.old_number.unwrap_or(0)).max(line.new_number.unwrap_or(0));
                }
                inline.lines.push(InlineDiffLine::Line { line, numbered });
            }
        }
        // Unpositioned hunks share line numbers, so their tokens would collide.
        inline.highlightable = all_numbered && inline.lines.len() <= Self::HIGHLIGHT_LIMIT;
        inline.hunks = hunks;
        inline
    }

    pub fn is_highlighted(&self) -> bool {
        self.is_highlighted
    }

    /// Syntax colors, computed once the diff shows (a closed row only needs its counts).
    pub fn highlight(&mut self) {
        if self.is_highlighted {
            return;
        }
        self.is_highlighted = true;
        if self.highlightable {
            self.highlights = HunkHighlights::compute(&self.hunks, &self.path);
        }
    }

    /// The tokens of a line as its own side reads it (old side for removed lines).
    pub fn tokens(&self, line: &HunkLine) -> Option<&[SyntaxToken]> {
        let (side, number) = match line.kind {
            DiffLineKind::Removed => (&self.highlights.old, line.old_number?),
            DiffLineKind::NoNewlineMarker => return None,
            _ => (&self.highlights.new, line.new_number?),
        };
        side.get(&number).map(Vec::as_slice)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::syntax::SyntaxTokenKind;

    const PATCH: &str = "--- a/app.swift\n+++ b/app.swift\n@@ -1,3 +1,3 @@ struct App {\n let a = 1\n-let b = 2\n+let b = 3\n\n@@ -10,2 +10,3 @@\n x\n+y\n z\n\\ No newline at end of file\n";

    #[test]
    fn hunks_number_their_lines_from_the_header_and_skip_file_headers() {
        let hunks = parse_hunks(PATCH);
        assert_eq!(hunks.len(), 2);
        assert_eq!(
            (hunks[0].old_start, hunks[0].new_start, hunks[0].section.as_str()),
            (1, 1, "struct App {")
        );
        let kinds: Vec<_> = hunks[0].lines.iter().map(|line| line.kind).collect();
        assert_eq!(
            kinds,
            [DiffLineKind::Context, DiffLineKind::Removed, DiffLineKind::Added, DiffLineKind::Context]
        );
        // The empty line is a context line whose space was stripped.
        assert_eq!(
            hunks[0].lines[3],
            HunkLine {
                kind: DiffLineKind::Context,
                text: String::new(),
                old_number: Some(3),
                new_number: Some(3)
            }
        );
        assert_eq!(hunks[0].lines[2].new_number, Some(2));
        let last = hunks[1].lines.last().unwrap();
        assert_eq!(last.kind, DiffLineKind::NoNewlineMarker);
        assert_eq!(last.display_text(), "No newline at end of file");
        assert_eq!(hunks[1].lines[2].new_number, Some(12));
    }

    #[test]
    fn headers_without_counts_mean_one_line_and_malformed_headers_are_ignored() {
        let hunks = parse_hunks("@@ -5 +5 @@\n-a\n+b\n@@ nonsense @@\n");
        assert_eq!(hunks.len(), 1);
        assert_eq!(hunks[0].lines.len(), 2);
        assert!(parse_hunks("plain text\n").is_empty());
    }

    #[test]
    fn inline_diffs_count_changes_separate_hunks_and_color_each_side() {
        let mut inline = InlineDiff::new(PATCH, "Sources/app.swift", false);
        assert_eq!((inline.additions, inline.deletions), (2, 1));
        assert_eq!(inline.max_number, 12);
        assert_eq!(inline.lines[0], InlineDiffLine::Separator("struct App {".into()));
        assert!(inline.lines.contains(&InlineDiffLine::Separator("⋯".into())));
        assert!(!inline.is_highlighted());

        inline.highlight();
        let InlineDiffLine::Line { line: removed, numbered } = &inline.lines[2] else { panic!() };
        assert!(*numbered);
        assert_eq!(removed.kind, DiffLineKind::Removed);
        let tokens = inline.tokens(removed).unwrap();
        assert_eq!(
            tokens.first().map(|token| (token.range.clone(), token.kind)),
            Some((0..3, SyntaxTokenKind::Keyword))
        );
        assert_eq!(
            tokens
                .iter()
                .find(|token| token.kind == SyntaxTokenKind::Number)
                .map(|token| token.range.clone()),
            Some(8..9)
        );
    }

    #[test]
    fn a_written_files_content_shows_as_plain_lines_and_unpositioned_hunks_stay_uncolored() {
        let written = InlineDiff::new("@@ -0,0 +1,2 @@\n+one\n+two\n", "notes.txt", true);
        assert_eq!(written.additions, 2);
        assert!(written.lines.iter().all(
            |line| matches!(line, InlineDiffLine::Line { line, .. } if line.kind == DiffLineKind::Context)
        ));

        let mut unpositioned = InlineDiff::new("@@ -0,0 +0,1 @@\n+let a = 1\n", "a.swift", false);
        unpositioned.highlight();
        assert!(unpositioned.highlights.new.is_empty());
        assert_eq!(unpositioned.max_number, 0);
    }
}
