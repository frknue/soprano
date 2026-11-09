//! The editor's text geometry, independent of GPUI: lines with tabs expanded to four
//! columns, the rows a viewport shows, and caret motion over the shared buffer.
//!
//! The editor does not wrap (Swift's text container was unbounded horizontally): one buffer
//! line is one row on a fixed 20 px line.

use std::ops::Range;

use soprano_text::EditorDocument;
use unicode_segmentation::UnicodeSegmentation;

/// Columns a tab advances to the next multiple of.
pub const TAB_WIDTH: usize = 4;
/// Space between the gutter and the text, and above the first line (`textContainerInset`).
pub const TEXT_INSET_X: f32 = 12.0;
pub const TEXT_INSET_Y: f32 = 8.0;
/// Herdr's file preview: the terminal font at 12.
pub const FONT_SIZE: f32 = 12.0;
/// The gutter's numbers.
pub const GUTTER_FONT_SIZE: f32 = 11.0;

/// One buffer line as drawn: its text without the line break, tabs expanded.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DisplayLine {
    pub text: String,
    /// `(buffer offset, display offset)` of every character start, then the line's end.
    stops: Vec<(usize, usize)>,
}

impl DisplayLine {
    /// `raw` is the line's text without its break; offsets are relative to the line start.
    pub fn new(raw: &str) -> Self {
        let mut text = String::with_capacity(raw.len());
        let mut stops = Vec::with_capacity(raw.len() + 1);
        let mut column = 0;
        for (offset, character) in raw.char_indices() {
            stops.push((offset, text.len()));
            if character == '\t' {
                let spaces = TAB_WIDTH - column % TAB_WIDTH;
                text.extend(std::iter::repeat_n(' ', spaces));
                column += spaces;
            } else {
                text.push(character);
                column += 1;
            }
        }
        stops.push((raw.len(), text.len()));
        Self { text, stops }
    }

    /// The display offset of buffer offset `offset` (clamped to the line).
    pub fn display_offset(&self, offset: usize) -> usize {
        match self.stops.binary_search_by_key(&offset, |(buffer, _)| *buffer) {
            Ok(index) => self.stops[index].1,
            Err(index) => self.stops[index.saturating_sub(1).min(self.stops.len() - 1)].1,
        }
    }

    /// The buffer offset whose character starts nearest `display` (inside a tab: its start
    /// or end, whichever is closer).
    pub fn buffer_offset(&self, display: usize) -> usize {
        match self.stops.binary_search_by_key(&display, |(_, shown)| *shown) {
            Ok(index) => self.stops[index].0,
            Err(index) if index >= self.stops.len() => self.stops[self.stops.len() - 1].0,
            Err(index) => {
                let (before, after) = (self.stops[index.saturating_sub(1)], self.stops[index]);
                if display - before.1 <= after.1 - display { before.0 } else { after.0 }
            }
        }
    }

    /// Display columns of the line.
    pub fn columns(&self) -> usize {
        self.text.chars().count()
    }

    /// The column of display offset `display`.
    pub fn column_of(&self, display: usize) -> usize {
        self.text[..display.min(self.text.len())].chars().count()
    }

    /// The display offset of column `column` (clamped to the line).
    pub fn offset_of_column(&self, column: usize) -> usize {
        self.text.char_indices().nth(column).map_or(self.text.len(), |(offset, _)| offset)
    }
}

/// Buffer line `row` of `document`: its byte range without the line break, and its text.
pub fn line(document: &EditorDocument, row: usize) -> (Range<usize>, String) {
    let rope = document.rope();
    if row >= rope.len_lines() {
        let end = rope.len_bytes();
        return (end..end, String::new());
    }
    let start = rope.line_to_byte(row);
    let mut text = rope.line(row).to_string();
    while text.ends_with('\n') || text.ends_with('\r') {
        text.pop();
    }
    (start..start + text.len(), text)
}

/// The rows a viewport `height` tall shows when scrolled down by `scroll_y`, with one row of
/// overdraw either side: never past the document's rows, so nothing is drawn outside them.
pub fn visible_rows(scroll_y: f32, height: f32, line_height: f32, line_count: usize) -> Range<usize> {
    if line_count == 0 || line_height <= 0.0 || height <= 0.0 {
        return 0..0;
    }
    let first = ((scroll_y - TEXT_INSET_Y) / line_height).floor().max(0.0) as usize;
    let last = ((scroll_y - TEXT_INSET_Y + height) / line_height).ceil().max(0.0) as usize + 1;
    first.min(line_count)..last.min(line_count)
}

/// The height of the whole text, insets included.
pub fn content_height(line_count: usize, line_height: f32) -> f32 {
    line_count.max(1) as f32 * line_height + TEXT_INSET_Y * 2.0
}

// MARK: - Motion

/// The character boundary before `offset`.
pub fn previous_boundary(text: &str, offset: usize) -> usize {
    text[..offset.min(text.len())].grapheme_indices(true).next_back().map_or(0, |(index, _)| index)
}

/// The character boundary after `offset`.
pub fn next_boundary(text: &str, offset: usize) -> usize {
    let offset = offset.min(text.len());
    text[offset..].graphemes(true).next().map_or(text.len(), |grapheme| offset + grapheme.len())
}

/// ⌥←: the start of the word at or before `offset`.
pub fn word_start(text: &str, offset: usize) -> usize {
    let offset = offset.min(text.len());
    let mut result = 0;
    for (index, word) in text[..offset].split_word_bound_indices() {
        if word.chars().any(char::is_alphanumeric) {
            result = index;
        }
    }
    result
}

/// ⌥→: the end of the word at or after `offset`.
pub fn word_end(text: &str, offset: usize) -> usize {
    let offset = offset.min(text.len());
    for (index, word) in text[offset..].split_word_bound_indices() {
        if word.chars().any(char::is_alphanumeric) {
            return offset + index + word.len();
        }
    }
    text.len()
}

/// A double click: the word (or run of other characters) around `offset`.
pub fn word_range(text: &str, offset: usize) -> Range<usize> {
    let offset = offset.min(text.len());
    for (index, word) in text.split_word_bound_indices() {
        let range = index..index + word.len();
        if range.contains(&offset) || (offset == text.len() && range.end == offset) {
            return range;
        }
    }
    offset..offset
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tabs_expand_to_the_next_multiple_of_four_columns() {
        let line = DisplayLine::new("a\tb\t\tc");
        assert_eq!(line.text, "a   b       c");
        assert_eq!(line.display_offset(1), 1);
        assert_eq!(line.display_offset(2), 4);
        assert_eq!(line.display_offset(4), 8);
        assert_eq!(line.display_offset(6), 13);
        assert_eq!(line.buffer_offset(2), 1);
        assert_eq!(line.buffer_offset(3), 2);
        assert_eq!(line.buffer_offset(99), 6);
        assert_eq!(line.columns(), 13);
    }

    #[test]
    fn display_offsets_follow_multibyte_characters() {
        let line = DisplayLine::new("é\tx");
        assert_eq!(line.text, "é   x");
        assert_eq!(line.display_offset(2), 2);
        assert_eq!(line.display_offset(3), 5);
        assert_eq!(line.column_of(5), 4);
        assert_eq!(line.offset_of_column(4), 5);
    }

    /// `GutterRulerTests`: the gutter draws numbers only for rows that exist and that the
    /// viewport shows, so nothing paints above or below it.
    #[test]
    fn the_gutter_only_lays_out_rows_inside_the_viewport() {
        // 40 lines of 20 px, a 200 px viewport scrolled 100 px down.
        let rows = visible_rows(100.0, 200.0, 20.0, 40);
        assert_eq!(rows, 4..16);
        assert!(rows.end <= 40);
        // Past the end, nothing.
        assert!(visible_rows(2000.0, 200.0, 20.0, 40).is_empty());
        // A short file stops at its last line.
        assert_eq!(visible_rows(0.0, 500.0, 20.0, 3), 0..3);
        assert_eq!(content_height(40, 20.0), 816.0);
    }

    #[test]
    fn word_motion_skips_punctuation_and_spaces() {
        let text = "let value = foo(bar)";
        assert_eq!(word_end(text, 0), 3);
        assert_eq!(word_end(text, 3), 9);
        assert_eq!(word_start(text, 9), 4);
        assert_eq!(word_start(text, 4), 0);
        assert_eq!(word_range(text, 6), 4..9);
        assert_eq!(previous_boundary("aé", 3), 1);
        assert_eq!(next_boundary("aé", 1), 3);
    }
}
