//! Vim modal editing and motions for [`EditorView`]: Normal, Insert, Visual and Visual Line
//! modes, numeric counts, operators (`d`, `c`, `y`, `>`, `<`), text objects (`iw`/`aw`,
//! quotes, brackets/parens/braces), character search (`f`/`F`/`t`/`T`/`;`/`,`), `%` bracket
//! matching, linewise/charwise yank & paste, and `/` / `n` / `N` / `*` search.

use std::hash::Hash;
use std::ops::Range;

use gpui::{App, ClipboardItem, Context, KeyDownEvent, Window};
use soprano_text::EditorDocument;

use super::layout::{self, next_boundary, previous_boundary};
use super::{EditorView, Find, FindNext, FindPrevious, Redo, Undo};

/// Active Vim mode when `vim_mode` is enabled.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum VimMode {
    #[default]
    Normal,
    Insert,
    Visual,
    VisualLine,
}

impl VimMode {
    pub fn label(self) -> &'static str {
        match self {
            Self::Normal => "Normal",
            Self::Insert => "Insert",
            Self::Visual => "Visual",
            Self::VisualLine => "Visual Line",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum VimOperator {
    Delete,
    Change,
    Yank,
    Indent,
    Outdent,
}

impl VimOperator {
    fn key(self) -> char {
        match self {
            Self::Delete => 'd',
            Self::Change => 'c',
            Self::Yank => 'y',
            Self::Indent => '>',
            Self::Outdent => '<',
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) enum VimPending {
    #[default]
    None,
    G,
    Find {
        forward: bool,
        till: bool,
    },
    Replace,
    TextObject {
        around: bool,
    },
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct VimRegister {
    pub text: String,
    pub linewise: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct LastCharFind {
    pub ch: char,
    pub forward: bool,
    pub till: bool,
}

#[derive(Clone, Debug, Default)]
pub(super) struct VimState {
    pub mode: VimMode,
    pub count: Option<usize>,
    pub operator: Option<VimOperator>,
    pub pending: VimPending,
    pub register: VimRegister,
    pub last_find: Option<LastCharFind>,
}

impl VimState {
    pub fn clear_pending(&mut self) {
        self.count = None;
        self.operator = None;
        self.pending = VimPending::None;
    }

    pub fn is_modal(&self) -> bool {
        self.mode != VimMode::Insert
    }

    pub fn is_visual(&self) -> bool {
        matches!(self.mode, VimMode::Visual | VimMode::VisualLine)
    }

    pub fn is_operator_pending(&self) -> bool {
        self.operator.is_some() || !matches!(self.pending, VimPending::None)
    }

    /// Pending sequence shown beside the mode pill (e.g. `2d`, `ci`, `g`).
    pub fn pending_label(&self) -> String {
        let mut out = String::new();
        if let Some(count) = self.count {
            out.push_str(&count.to_string());
        }
        if let Some(op) = self.operator {
            out.push(op.key());
        }
        match self.pending {
            VimPending::None => {}
            VimPending::G => out.push('g'),
            VimPending::Replace => out.push('r'),
            VimPending::Find { forward: true, till: false } => out.push('f'),
            VimPending::Find { forward: false, till: false } => out.push('F'),
            VimPending::Find { forward: true, till: true } => out.push('t'),
            VimPending::Find { forward: false, till: true } => out.push('T'),
            VimPending::TextObject { around: false } => out.push('i'),
            VimPending::TextObject { around: true } => out.push('a'),
        }
        out
    }

    fn take_count(&mut self) -> usize {
        self.count.take().unwrap_or(1).max(1)
    }

    fn push_digit(&mut self, digit: u32) {
        let next = self.count.unwrap_or(0).saturating_mul(10).saturating_add(digit as usize).min(100_000);
        self.count = Some(next);
    }
}

// MARK: - Pure motion and text-object primitives

#[derive(Clone, Copy, PartialEq, Eq)]
enum CharClass {
    Whitespace,
    Word,
    Punctuation,
}

fn char_class(c: char, big_word: bool) -> CharClass {
    if c.is_whitespace() {
        CharClass::Whitespace
    } else if big_word || c.is_alphanumeric() || c == '_' {
        CharClass::Word
    } else {
        CharClass::Punctuation
    }
}

/// Keeps `offset` on a valid character of its line in Normal/Visual mode (never past the last
/// character of a non-empty line).
pub(super) fn clamp_normal_offset(document: &EditorDocument, offset: usize) -> usize {
    let rope = document.rope();
    let offset = document.clamp_offset(offset);
    let row = rope.byte_to_line(offset);
    let (range, text) = layout::line(document, row);
    if text.is_empty() {
        return range.start;
    }
    let last_char = range.start + previous_boundary(&text, text.len());
    offset.clamp(range.start, last_char)
}

/// First non-whitespace byte offset on `row` (or line end if blank).
pub(super) fn line_first_non_blank(document: &EditorDocument, row: usize) -> usize {
    let (range, text) = layout::line(document, row);
    let indent = text.char_indices().find(|(_, c)| !c.is_whitespace()).map_or(text.len(), |(idx, _)| idx);
    range.start + indent
}

/// Byte offset after the grapheme at `offset` on the same line (used to make inclusive ranges
/// include the target character).
pub(super) fn inclusive_end(document: &EditorDocument, offset: usize) -> usize {
    let rope = document.rope();
    let offset = document.clamp_offset(offset);
    let row = rope.byte_to_line(offset);
    let (range, text) = layout::line(document, row);
    if offset >= range.end {
        return range.end;
    }
    range.start + next_boundary(&text, offset - range.start)
}

/// Effective byte range of a Visual or VisualLine selection (`anchor` and `head` are character
/// offsets).
pub(super) fn visual_byte_range(
    document: &EditorDocument,
    mode: VimMode,
    anchor: usize,
    head: usize,
) -> Range<usize> {
    let rope = document.rope();
    let a = document.clamp_offset(anchor);
    let b = document.clamp_offset(head);
    let (lo, hi) = (a.min(b), a.max(b));
    match mode {
        VimMode::Visual => {
            let end = if hi < rope.len_bytes() {
                let row = rope.byte_to_line(hi);
                let (range, text) = layout::line(document, row);
                if hi < range.end {
                    range.start + next_boundary(&text, hi - range.start)
                } else {
                    // Empty line in Visual mode: include the newline if present.
                    if row + 1 < rope.len_lines() { rope.line_to_byte(row + 1) } else { rope.len_bytes() }
                }
            } else {
                rope.len_bytes()
            };
            lo..end.max(lo)
        }
        VimMode::VisualLine => {
            let start_row = rope.byte_to_line(lo);
            let end_row = rope.byte_to_line(hi);
            let start = rope.line_to_byte(start_row);
            let end = if end_row + 1 < rope.len_lines() {
                rope.line_to_byte(end_row + 1)
            } else {
                rope.len_bytes()
            };
            start..end
        }
        VimMode::Normal | VimMode::Insert => lo..hi,
    }
}

/// Full byte span of `count` lines starting at `row` (including trailing newline when available).
fn line_span(document: &EditorDocument, row: usize, count: usize) -> Range<usize> {
    let rope = document.rope();
    let total = rope.len_lines();
    if total == 0 {
        return 0..0;
    }
    let start_row = row.min(total - 1);
    let end_row = (start_row + count.max(1)).min(total);
    let start = rope.line_to_byte(start_row);
    let end = if end_row < total { rope.line_to_byte(end_row) } else { rope.len_bytes() };
    start..end
}

/// Vim `w` / `W`: start of next word (or end of current word if `for_change` is true and on a
/// non-whitespace word, matching Vim's `cw` special case).
pub(super) fn vim_word_forward(text: &str, offset: usize, big_word: bool, for_change: bool) -> usize {
    let offset = offset.min(text.len());
    let mut iter = text[offset..].char_indices().peekable();
    let Some(&(_, first)) = iter.peek() else {
        return text.len();
    };
    let first_class = char_class(first, big_word);
    if first_class != CharClass::Whitespace {
        while let Some(&(_, c)) = iter.peek() {
            if char_class(c, big_word) != first_class {
                break;
            }
            iter.next();
        }
        if for_change {
            return iter.peek().map_or(text.len(), |&(i, _)| offset + i);
        }
    }
    while let Some(&(_, c)) = iter.peek() {
        if !c.is_whitespace() {
            break;
        }
        iter.next();
    }
    iter.peek().map_or(text.len(), |&(i, _)| offset + i)
}

/// Vim `b` / `B`: start of previous word.
pub(super) fn vim_word_backward(text: &str, offset: usize, big_word: bool) -> usize {
    let offset = offset.min(text.len());
    let mut iter = text[..offset].char_indices().rev().peekable();
    while let Some(&(_, c)) = iter.peek() {
        if !c.is_whitespace() {
            break;
        }
        iter.next();
    }
    let Some(&(_, target)) = iter.peek() else {
        return 0;
    };
    let target_class = char_class(target, big_word);
    let mut start = 0;
    while let Some(&(idx, c)) = iter.peek() {
        if char_class(c, big_word) != target_class {
            break;
        }
        start = idx;
        iter.next();
    }
    start
}

/// Vim `e` / `E`: byte offset of the last character of the current/next word.
pub(super) fn vim_word_end(text: &str, offset: usize, big_word: bool) -> usize {
    let offset = offset.min(text.len());
    let mut iter = text[offset..].char_indices().peekable();
    let Some(&(first_idx, _)) = iter.next().as_ref() else {
        return offset;
    };
    let mut last = offset + first_idx;
    while let Some(&(idx, c)) = iter.peek() {
        if !c.is_whitespace() {
            last = offset + idx;
            break;
        }
        iter.next();
    }
    let Some(&(_, target)) = iter.peek() else {
        return last;
    };
    let target_class = char_class(target, big_word);
    while let Some(&(idx, c)) = iter.peek() {
        if char_class(c, big_word) != target_class {
            break;
        }
        last = offset + idx;
        iter.next();
    }
    last
}

/// Vim `f` / `F` / `t` / `T` on a single line (returns local byte offset in `line_text`).
pub(super) fn find_char_on_line(
    line_text: &str,
    local_offset: usize,
    target: char,
    forward: bool,
    till: bool,
    count: usize,
) -> Option<usize> {
    let local_offset = local_offset.min(line_text.len());
    let mut remaining = count.max(1);
    if forward {
        let mut iter = line_text[local_offset..].char_indices();
        // Skip current character.
        iter.next()?;
        for (rel, c) in iter {
            if c == target {
                remaining -= 1;
                if remaining == 0 {
                    let found = local_offset + rel;
                    return Some(if till { previous_boundary(line_text, found) } else { found });
                }
            }
        }
        None
    } else {
        for (idx, c) in line_text[..local_offset].char_indices().rev() {
            if c == target {
                remaining -= 1;
                if remaining == 0 {
                    return Some(if till { next_boundary(line_text, idx) } else { idx });
                }
            }
        }
        None
    }
}

/// Vim `%`: finds the matching bracket (`()`, `[]`, `{}`) for the bracket at or after `offset`
/// on the current line.
pub(super) fn matching_bracket(document: &EditorDocument, offset: usize) -> Option<usize> {
    let text = document.text();
    let offset = document.clamp_offset(offset);
    let rope = document.rope();
    let row = rope.byte_to_line(offset);
    let (line_range, line_text) = layout::line(document, row);

    let local = offset.saturating_sub(line_range.start).min(line_text.len());
    let (start_offset, ch) = line_text[local..]
        .char_indices()
        .find(|(_, c)| matches!(c, '(' | ')' | '[' | ']' | '{' | '}'))
        .map(|(rel, c)| (line_range.start + local + rel, c))?;

    let (mate, forward) = match ch {
        '(' => (')', true),
        '[' => (']', true),
        '{' => ('}', true),
        ')' => ('(', false),
        ']' => ('[', false),
        '}' => ('{', false),
        _ => return None,
    };

    let mut depth = 0usize;
    if forward {
        for (rel, c) in text[start_offset..].char_indices() {
            if c == ch {
                depth += 1;
            } else if c == mate {
                depth -= 1;
                if depth == 0 {
                    return Some(start_offset + rel);
                }
            }
        }
    } else {
        let search_end = next_boundary(&text, start_offset);
        for (idx, c) in text[..search_end].char_indices().rev() {
            if c == ch {
                depth += 1;
            } else if c == mate {
                depth -= 1;
                if depth == 0 {
                    return Some(idx);
                }
            }
        }
    }
    None
}

/// Vim text objects (`iw`/`aw`, `iW`/`aW`, quotes, parens/brackets/braces/angle-brackets).
pub(super) fn text_object_range(
    document: &EditorDocument,
    offset: usize,
    spec: char,
    around: bool,
) -> Option<Range<usize>> {
    let offset = document.clamp_offset(offset);
    match spec {
        'w' | 'W' => word_object(document, offset, spec == 'W', around),
        '"' | '\'' | '`' => quote_object(document, offset, spec, around),
        '(' | ')' | 'b' => pair_object(document, offset, '(', ')', around),
        '[' | ']' => pair_object(document, offset, '[', ']', around),
        '{' | '}' | 'B' => pair_object(document, offset, '{', '}', around),
        '<' | '>' => pair_object(document, offset, '<', '>', around),
        _ => None,
    }
}

fn word_object(
    document: &EditorDocument,
    offset: usize,
    big_word: bool,
    around: bool,
) -> Option<Range<usize>> {
    let rope = document.rope();
    let row = rope.byte_to_line(offset);
    let (range, line) = layout::line(document, row);
    if line.is_empty() {
        return None;
    }
    let local = offset.saturating_sub(range.start).min(previous_boundary(&line, line.len()));
    let target_ch = line[local..].chars().next()?;
    let target_class = char_class(target_ch, big_word);

    let mut start = local;
    for (idx, c) in line[..local].char_indices().rev() {
        if char_class(c, big_word) != target_class {
            break;
        }
        start = idx;
    }
    let mut end = local;
    for (rel, c) in line[local..].char_indices() {
        if char_class(c, big_word) != target_class {
            break;
        }
        end = local + rel + c.len_utf8();
    }
    if around && target_class != CharClass::Whitespace {
        let trailing = line[end..]
            .char_indices()
            .take_while(|(_, c)| c.is_whitespace())
            .last()
            .map(|(rel, c)| end + rel + c.len_utf8());
        if let Some(after_ws) = trailing {
            end = after_ws;
        } else {
            let leading = line[..start].char_indices().rev().take_while(|(_, c)| c.is_whitespace()).last();
            if let Some((ws_start, _)) = leading {
                start = ws_start;
            }
        }
    }
    Some(range.start + start..range.start + end)
}

fn quote_object(document: &EditorDocument, offset: usize, quote: char, around: bool) -> Option<Range<usize>> {
    let rope = document.rope();
    let row = rope.byte_to_line(offset);
    let (range, line) = layout::line(document, row);
    let local = offset.saturating_sub(range.start).min(line.len());
    let positions: Vec<usize> = line.char_indices().filter(|&(_, c)| c == quote).map(|(i, _)| i).collect();
    if positions.len() < 2 {
        return None;
    }
    // Pair quotes left-to-right on the line; pick the enclosing pair or the next pair after cursor.
    for &[open, close] in positions.as_chunks::<2>().0 {
        if local <= close {
            let (start, end) =
                if around { (open, close + quote.len_utf8()) } else { (open + quote.len_utf8(), close) };
            return Some(range.start + start..range.start + end);
        }
    }
    None
}

fn pair_object(
    document: &EditorDocument,
    offset: usize,
    open_ch: char,
    close_ch: char,
    around: bool,
) -> Option<Range<usize>> {
    let text = document.text();
    let offset = offset.min(text.len());
    // Search backward from cursor for the nearest unmatched opening delimiter.
    let mut depth = 0usize;
    let mut open_pos = None;
    let at_open = text[offset..].starts_with(open_ch);
    if at_open {
        open_pos = Some(offset);
    } else {
        for (idx, c) in text[..offset].char_indices().rev() {
            if c == close_ch {
                depth += 1;
            } else if c == open_ch {
                if depth == 0 {
                    open_pos = Some(idx);
                    break;
                }
                depth -= 1;
            }
        }
    }
    let open = open_pos?;
    let mut depth = 0usize;
    let mut close_pos = None;
    for (rel, c) in text[open..].char_indices() {
        if c == open_ch {
            depth += 1;
        } else if c == close_ch {
            depth -= 1;
            if depth == 0 {
                close_pos = Some(open + rel);
                break;
            }
        }
    }
    let close = close_pos?;
    if around { Some(open..close + close_ch.len_utf8()) } else { Some(open + open_ch.len_utf8()..close) }
}

/// Extracts the typed character from a GPUI keystroke (preferring `key_char` for international
/// layouts, falling back to `key` + `shift` for synthetic test keystrokes).
fn resolved_char(keystroke: &gpui::Keystroke) -> Option<char> {
    if let Some(ch) = keystroke.key_char.as_deref() {
        let mut chars = ch.chars();
        if let (Some(c), None) = (chars.next(), chars.next())
            && !c.is_control()
        {
            return Some(c);
        }
    }
    let mut chars = keystroke.key.chars();
    let (Some(c), None) = (chars.next(), chars.next()) else {
        return None;
    };
    if keystroke.modifiers.shift && c.is_ascii_lowercase() { Some(c.to_ascii_uppercase()) } else { Some(c) }
}

/// The motion target returned by Vim motion commands.
struct MotionTarget {
    /// Destination cursor byte offset.
    offset: usize,
    /// When applied to an operator (`d`/`c`/`y`), whether the target character is included.
    inclusive: bool,
    /// When applied to an operator, whether the motion spans whole lines (`j`, `k`, `gg`, `G`).
    linewise: bool,
}

impl MotionTarget {
    fn exclusive(offset: usize) -> Self {
        Self { offset, inclusive: false, linewise: false }
    }

    fn inclusive(offset: usize) -> Self {
        Self { offset, inclusive: true, linewise: false }
    }

    fn linewise(offset: usize) -> Self {
        Self { offset, inclusive: true, linewise: true }
    }
}

// MARK: - EditorView integration

impl<T: Clone + Eq + Hash + 'static> EditorView<T> {
    /// Whether Vim modal editing is enabled on this editor view.
    pub fn vim_mode_enabled(&self) -> bool {
        self.vim_enabled
    }

    /// Current Vim mode (meaningful when [`Self::vim_mode_enabled`] is true).
    pub fn vim_mode(&self) -> VimMode {
        self.vim.mode
    }

    /// Whether the editor is currently in a non-Insert Vim mode (Normal, Visual, VisualLine).
    pub(super) fn vim_is_modal(&self) -> bool {
        self.vim_enabled && self.vim.is_modal()
    }

    /// Enables or disables Vim mode (live, from `settings.json` or Settings).
    pub fn set_vim_mode(&mut self, enabled: bool, cx: &mut Context<Self>) {
        if self.vim_enabled == enabled {
            return;
        }
        self.vim_enabled = enabled;
        self.vim.clear_pending();
        if enabled {
            self.vim.mode = VimMode::Normal;
            self.clamp_head_normal(cx);
            self.anchor = self.head;
        } else {
            self.vim.mode = VimMode::Normal;
        }
        cx.notify();
    }

    pub(super) fn clamp_head_normal(&mut self, cx: &App) {
        if let Some(clamped) = self.with_document(cx, |doc| clamp_normal_offset(doc, self.head)) {
            self.head = clamped;
        }
    }

    pub(super) fn enter_insert_mode(&mut self, cx: &mut Context<Self>) {
        self.vim.clear_pending();
        self.vim.mode = VimMode::Insert;
        self.anchor = self.head;
        self.break_coalescing(cx);
        cx.notify();
    }

    pub(super) fn exit_to_normal_mode(&mut self, cx: &mut Context<Self>) {
        let was_insert = self.vim.mode == VimMode::Insert;
        self.vim.clear_pending();
        self.vim.mode = VimMode::Normal;
        if was_insert {
            let stepped = self.with_document(cx, |doc| {
                let row = doc.rope().byte_to_line(self.head.min(doc.len()));
                let (range, text) = layout::line(doc, row);
                if self.head > range.start {
                    range.start + previous_boundary(&text, self.head.min(range.end) - range.start)
                } else {
                    range.start
                }
            });
            if let Some(offset) = stepped {
                self.head = offset;
            }
        }
        self.clamp_head_normal(cx);
        self.anchor = self.head;
        self.goal_column = None;
        self.break_coalescing(cx);
        cx.notify();
    }

    /// Handles `KeyDownEvent` when Vim mode is active and the text area itself has keyboard focus.
    pub(super) fn handle_vim_key_down(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !self.vim_enabled || !self.focus.is_focused(window) || !self.is_text(cx) {
            return;
        }
        let ks = &event.keystroke;
        // Let platform (⌘) and Option (⌥) chords pass through to Soprano and OS shortcuts.
        if ks.modifiers.platform || ks.modifiers.alt {
            return;
        }

        // Escape / Ctrl-[ / Ctrl-c always returns to Normal mode (or clears pending state).
        let is_escape = ks.key == "escape"
            || (ks.modifiers.control && !ks.modifiers.shift && matches!(ks.key.as_str(), "[" | "c"));
        if is_escape {
            if self.vim.mode != VimMode::Normal || self.vim.is_operator_pending() || self.vim.count.is_some()
            {
                self.exit_to_normal_mode(cx);
                cx.stop_propagation();
            }
            return;
        }

        // In Insert mode, every other key goes straight through to normal typing / bindings.
        if self.vim.mode == VimMode::Insert {
            return;
        }

        // Control motions/commands in Normal/Visual mode.
        if ks.modifiers.control {
            let handled = match ks.key.as_str() {
                "d" => {
                    let half = (self.page_rows() / 2).max(1);
                    let count = self.vim.take_count();
                    self.vim.clear_pending();
                    self.vim_move_rows(half * count as isize, cx);
                    true
                }
                "u" => {
                    let half = (self.page_rows() / 2).max(1);
                    let count = self.vim.take_count();
                    self.vim.clear_pending();
                    self.vim_move_rows(-half * count as isize, cx);
                    true
                }
                "f" => {
                    let page = self.page_rows();
                    let count = self.vim.take_count();
                    self.vim.clear_pending();
                    self.vim_move_rows(page * count as isize, cx);
                    true
                }
                "b" => {
                    let page = self.page_rows();
                    let count = self.vim.take_count();
                    self.vim.clear_pending();
                    self.vim_move_rows(-page * count as isize, cx);
                    true
                }
                "r" if self.vim.mode == VimMode::Normal => {
                    let count = self.vim.take_count();
                    self.vim.clear_pending();
                    for _ in 0..count {
                        self.redo(&Redo, window, cx);
                    }
                    self.clamp_head_normal(cx);
                    self.anchor = self.head;
                    true
                }
                _ => false,
            };
            if handled {
                cx.stop_propagation();
            }
            return;
        }

        // Named navigation keys are handled by action bindings; ignore modifier-only events.
        let ch = match ks.key.as_str() {
            "space" => ' ',
            _ => {
                let Some(c) = resolved_char(ks) else {
                    return;
                };
                c
            }
        };

        cx.stop_propagation();
        self.handle_vim_char(ch, window, cx);
    }

    fn handle_vim_char(&mut self, ch: char, window: &mut Window, cx: &mut Context<Self>) {
        // 1. Finish any multi-key pending sequence first (`r<c>`, `f<c>`, `g<c>`, `i<obj>`/`a<obj>`).
        match self.vim.pending {
            VimPending::Replace => {
                self.vim.pending = VimPending::None;
                let count = self.vim.take_count();
                self.vim_replace_chars(ch, count, cx);
                return;
            }
            VimPending::Find { forward, till } => {
                self.vim.pending = VimPending::None;
                self.vim.last_find = Some(LastCharFind { ch, forward, till });
                let count = self.vim.take_count();
                if let Some(target) = self.vim_find_char_target(ch, forward, till, count, cx) {
                    self.apply_motion_target(target, cx);
                } else {
                    self.vim.clear_pending();
                    cx.notify();
                }
                return;
            }
            VimPending::TextObject { around } => {
                self.vim.pending = VimPending::None;
                let range =
                    self.with_document(cx, |doc| text_object_range(doc, self.head, ch, around)).flatten();
                if let Some(range) = range {
                    if let Some(op) = self.vim.operator.take() {
                        self.vim.count = None;
                        self.apply_operator_range(op, range, false, cx);
                    } else if self.vim.is_visual() {
                        self.vim.count = None;
                        self.vim.mode = VimMode::Visual;
                        self.anchor = range.start;
                        self.head = self
                            .with_document(cx, |doc| {
                                if range.end > range.start {
                                    let row = doc.rope().byte_to_line(range.end.saturating_sub(1));
                                    let (line_range, line_text) = layout::line(doc, row);
                                    let end_in_line = range.end.min(line_range.end);
                                    if end_in_line > line_range.start {
                                        line_range.start
                                            + previous_boundary(&line_text, end_in_line - line_range.start)
                                    } else {
                                        range.start
                                    }
                                } else {
                                    range.start
                                }
                            })
                            .unwrap_or(range.start);
                        self.autoscroll = true;
                        cx.notify();
                    }
                } else {
                    self.vim.clear_pending();
                    cx.notify();
                }
                return;
            }
            VimPending::G => {
                self.vim.pending = VimPending::None;
                match ch {
                    'g' => {
                        let line_num = self.vim.count.take().unwrap_or(1);
                        let target = self.vim_goto_line_target(line_num, cx);
                        self.apply_motion_target(target, cx);
                    }
                    _ => {
                        self.vim.clear_pending();
                        cx.notify();
                    }
                }
                return;
            }
            VimPending::None => {}
        }

        // 2. Numeric count prefix (`1`–`9`, and `0` once a count has started).
        if let Some(digit) = ch.to_digit(10)
            && (digit != 0 || self.vim.count.is_some())
        {
            self.vim.push_digit(digit);
            cx.notify();
            return;
        }

        // 3. Text-object prefixes (`i`/`a`) when an operator is pending or in Visual mode.
        if (self.vim.operator.is_some() || self.vim.is_visual()) && matches!(ch, 'i' | 'a') {
            self.vim.pending = VimPending::TextObject { around: ch == 'a' };
            cx.notify();
            return;
        }

        // 4. Doubled operator (`dd`, `cc`, `yy`, `>>`, `<<`) acts linewise on `count` lines.
        if let Some(op) = self.vim.operator
            && ch == op.key()
        {
            self.vim.operator = None;
            let count = self.vim.take_count();
            self.apply_linewise_operator(op, count, cx);
            return;
        }

        // 5. Visual-mode immediate actions (no operator pending).
        if self.vim.is_visual() && self.vim.operator.is_none() {
            match ch {
                'v' => {
                    if self.vim.mode == VimMode::Visual {
                        self.exit_to_normal_mode(cx);
                    } else {
                        self.vim.mode = VimMode::Visual;
                        self.vim.clear_pending();
                        cx.notify();
                    }
                    return;
                }
                'V' => {
                    if self.vim.mode == VimMode::VisualLine {
                        self.exit_to_normal_mode(cx);
                    } else {
                        self.vim.mode = VimMode::VisualLine;
                        self.vim.clear_pending();
                        cx.notify();
                    }
                    return;
                }
                'o' => {
                    std::mem::swap(&mut self.anchor, &mut self.head);
                    self.autoscroll = true;
                    cx.notify();
                    return;
                }
                'd' | 'x' => {
                    let (range, linewise) = self.visual_selection_with_kind(cx);
                    self.vim.mode = VimMode::Normal;
                    self.vim.clear_pending();
                    self.apply_operator_range(VimOperator::Delete, range, linewise, cx);
                    return;
                }
                'c' | 's' => {
                    let (range, linewise) = self.visual_selection_with_kind(cx);
                    self.vim.mode = VimMode::Normal;
                    self.vim.clear_pending();
                    self.apply_operator_range(VimOperator::Change, range, linewise, cx);
                    return;
                }
                'y' => {
                    let (range, linewise) = self.visual_selection_with_kind(cx);
                    self.vim.mode = VimMode::Normal;
                    self.vim.clear_pending();
                    self.apply_operator_range(VimOperator::Yank, range, linewise, cx);
                    return;
                }
                '>' => {
                    let (range, _) = self.visual_selection_with_kind(cx);
                    self.vim.mode = VimMode::Normal;
                    self.vim.clear_pending();
                    self.apply_operator_range(VimOperator::Indent, range, true, cx);
                    return;
                }
                '<' => {
                    let (range, _) = self.visual_selection_with_kind(cx);
                    self.vim.mode = VimMode::Normal;
                    self.vim.clear_pending();
                    self.apply_operator_range(VimOperator::Outdent, range, true, cx);
                    return;
                }
                '~' => {
                    let (range, _) = self.visual_selection_with_kind(cx);
                    self.vim.mode = VimMode::Normal;
                    self.vim.clear_pending();
                    self.vim_toggle_case(range, cx);
                    return;
                }
                'p' | 'P' => {
                    let (range, _) = self.visual_selection_with_kind(cx);
                    self.vim.mode = VimMode::Normal;
                    self.vim.clear_pending();
                    self.vim_paste_over_selection(range, cx);
                    return;
                }
                _ => {}
            }
        }

        // 6. Motions (work in Normal, Operator-pending, Visual and VisualLine).
        if let Some(target) = self.resolve_motion(ch, cx) {
            self.apply_motion_target(target, cx);
            return;
        }

        // 7. Pending prefix starters (`g`, `f`/`F`/`t`/`T`).
        match ch {
            'g' => {
                self.vim.pending = VimPending::G;
                cx.notify();
                return;
            }
            'f' => {
                self.vim.pending = VimPending::Find { forward: true, till: false };
                cx.notify();
                return;
            }
            'F' => {
                self.vim.pending = VimPending::Find { forward: false, till: false };
                cx.notify();
                return;
            }
            't' => {
                self.vim.pending = VimPending::Find { forward: true, till: true };
                cx.notify();
                return;
            }
            'T' => {
                self.vim.pending = VimPending::Find { forward: false, till: true };
                cx.notify();
                return;
            }
            _ => {}
        }

        // If an operator was pending and the key wasn't a valid motion/text-object, cancel it.
        if self.vim.operator.is_some() {
            self.vim.clear_pending();
            cx.notify();
            return;
        }

        // 8. Normal-mode operators, mode switches, edits and search.
        match ch {
            // Operators
            'd' => {
                self.vim.operator = Some(VimOperator::Delete);
                cx.notify();
            }
            'c' => {
                self.vim.operator = Some(VimOperator::Change);
                cx.notify();
            }
            'y' => {
                self.vim.operator = Some(VimOperator::Yank);
                cx.notify();
            }
            '>' => {
                self.vim.operator = Some(VimOperator::Indent);
                cx.notify();
            }
            '<' => {
                self.vim.operator = Some(VimOperator::Outdent);
                cx.notify();
            }

            // Shorthand operators
            'D' => {
                self.vim.clear_pending();
                let end = self.line_end_of(self.head, cx);
                self.apply_operator_range(VimOperator::Delete, self.head..end, false, cx);
            }
            'C' => {
                self.vim.clear_pending();
                let end = self.line_end_of(self.head, cx);
                self.apply_operator_range(VimOperator::Change, self.head..end, false, cx);
            }
            'Y' => {
                let count = self.vim.take_count();
                self.apply_linewise_operator(VimOperator::Yank, count, cx);
            }

            // Insert mode entries
            'i' => {
                if self.is_editable(cx) {
                    self.enter_insert_mode(cx);
                }
            }
            'I' => {
                if self.is_editable(cx) {
                    let target = self
                        .with_document(cx, |doc| {
                            let row = doc.rope().byte_to_line(self.head.min(doc.len()));
                            line_first_non_blank(doc, row)
                        })
                        .unwrap_or(self.head);
                    self.head = target;
                    self.enter_insert_mode(cx);
                }
            }
            'a' => {
                if self.is_editable(cx) {
                    let target = self
                        .with_document(cx, |doc| {
                            let row = doc.rope().byte_to_line(self.head.min(doc.len()));
                            let (range, text) = layout::line(doc, row);
                            if self.head < range.end {
                                range.start + next_boundary(&text, self.head - range.start)
                            } else {
                                range.end
                            }
                        })
                        .unwrap_or(self.head);
                    self.head = target;
                    self.enter_insert_mode(cx);
                }
            }
            'A' => {
                if self.is_editable(cx) {
                    self.head = self.line_end_of(self.head, cx);
                    self.enter_insert_mode(cx);
                }
            }
            'o' => {
                if self.is_editable(cx) {
                    self.vim_open_line(true, cx);
                }
            }
            'O' => {
                if self.is_editable(cx) {
                    self.vim_open_line(false, cx);
                }
            }
            's' => {
                if self.is_editable(cx) {
                    let count = self.vim.take_count();
                    let range = self.vim_chars_from_cursor(count, true, cx);
                    self.apply_operator_range(VimOperator::Change, range, false, cx);
                }
            }
            'S' => {
                if self.is_editable(cx) {
                    let count = self.vim.take_count();
                    self.apply_linewise_operator(VimOperator::Change, count, cx);
                }
            }

            // Visual modes
            'v' => {
                self.vim.clear_pending();
                self.vim.mode = VimMode::Visual;
                self.anchor = self.head;
                cx.notify();
            }
            'V' => {
                self.vim.clear_pending();
                self.vim.mode = VimMode::VisualLine;
                self.anchor = self.head;
                cx.notify();
            }

            // Character & line edits
            'x' => {
                let count = self.vim.take_count();
                let range = self.vim_chars_from_cursor(count, true, cx);
                self.apply_operator_range(VimOperator::Delete, range, false, cx);
            }
            'X' => {
                let count = self.vim.take_count();
                let range = self.vim_chars_from_cursor(count, false, cx);
                self.apply_operator_range(VimOperator::Delete, range, false, cx);
            }
            'r' => {
                if self.is_editable(cx) {
                    self.vim.pending = VimPending::Replace;
                    cx.notify();
                }
            }
            '~' => {
                let count = self.vim.take_count();
                let range = self.vim_chars_from_cursor(count, true, cx);
                let next_head = range.end;
                self.vim_toggle_case(range, cx);
                self.head = next_head;
                self.clamp_head_normal(cx);
                self.anchor = self.head;
                cx.notify();
            }
            'J' => {
                let count = self.vim.take_count();
                self.vim_join_lines(count, cx);
            }
            'p' => {
                let count = self.vim.take_count();
                self.vim_paste(true, count, cx);
            }
            'P' => {
                let count = self.vim.take_count();
                self.vim_paste(false, count, cx);
            }
            'u' => {
                let count = self.vim.take_count();
                for _ in 0..count {
                    self.undo(&Undo, window, cx);
                }
                self.clamp_head_normal(cx);
                self.anchor = self.head;
            }

            // Search
            '/' => {
                self.vim.clear_pending();
                self.find(&Find, window, cx);
            }
            'n' => {
                let count = self.vim.take_count();
                for _ in 0..count {
                    self.find_next(&FindNext, window, cx);
                }
                self.anchor = self.head;
                self.clamp_head_normal(cx);
                self.anchor = self.head;
                cx.notify();
            }
            'N' => {
                let count = self.vim.take_count();
                for _ in 0..count {
                    self.find_previous(&FindPrevious, window, cx);
                }
                self.anchor = self.head;
                self.clamp_head_normal(cx);
                self.anchor = self.head;
                cx.notify();
            }
            '*' => {
                self.vim.clear_pending();
                self.vim_search_word_under_cursor(window, cx);
            }
            _ => {
                self.vim.clear_pending();
                cx.notify();
            }
        }
    }

    fn resolve_motion(&mut self, ch: char, cx: &App) -> Option<MotionTarget> {
        let for_change = self.vim.operator == Some(VimOperator::Change);
        let target = match ch {
            'h' => {
                let count = self.vim.take_count();
                self.goal_column = None;
                let offset = self
                    .with_document(cx, |doc| {
                        let row = doc.rope().byte_to_line(self.head.min(doc.len()));
                        let (range, text) = layout::line(doc, row);
                        let mut local = self.head.saturating_sub(range.start).min(text.len());
                        for _ in 0..count {
                            local = previous_boundary(&text, local);
                        }
                        range.start + local
                    })
                    .unwrap_or(self.head);
                MotionTarget::exclusive(offset)
            }
            'l' | ' ' => {
                let count = self.vim.take_count();
                self.goal_column = None;
                let operator = self.vim.operator.is_some();
                let offset = self
                    .with_document(cx, |doc| {
                        let row = doc.rope().byte_to_line(self.head.min(doc.len()));
                        let (range, text) = layout::line(doc, row);
                        let mut local = self.head.saturating_sub(range.start).min(text.len());
                        for _ in 0..count {
                            local = next_boundary(&text, local);
                        }
                        let raw = range.start + local;
                        if operator { raw } else { clamp_normal_offset(doc, raw) }
                    })
                    .unwrap_or(self.head);
                MotionTarget::exclusive(offset)
            }
            'j' => {
                let count = self.vim.take_count();
                let target = self.vertical(self.head, count as isize, cx);
                let clamped =
                    self.with_document(cx, |doc| clamp_normal_offset(doc, target)).unwrap_or(target);
                MotionTarget::linewise(clamped)
            }
            'k' => {
                let count = self.vim.take_count();
                let target = self.vertical(self.head, -(count as isize), cx);
                let clamped =
                    self.with_document(cx, |doc| clamp_normal_offset(doc, target)).unwrap_or(target);
                MotionTarget::linewise(clamped)
            }
            '0' => {
                self.vim.count = None;
                self.goal_column = None;
                MotionTarget::exclusive(self.line_start_of(self.head, cx))
            }
            '^' | '_' => {
                self.vim.count = None;
                self.goal_column = None;
                let offset = self
                    .with_document(cx, |doc| {
                        let row = doc.rope().byte_to_line(self.head.min(doc.len()));
                        line_first_non_blank(doc, row)
                    })
                    .unwrap_or(self.head);
                MotionTarget::exclusive(offset)
            }
            '$' => {
                let count = self.vim.take_count();
                self.goal_column = None;
                let offset = self
                    .with_document(cx, |doc| {
                        let rope = doc.rope();
                        let row = rope.byte_to_line(self.head.min(doc.len()));
                        let target_row = (row + count - 1).min(rope.len_lines().saturating_sub(1));
                        let (range, text) = layout::line(doc, target_row);
                        if text.is_empty() {
                            range.start
                        } else {
                            range.start + previous_boundary(&text, text.len())
                        }
                    })
                    .unwrap_or(self.head);
                MotionTarget::inclusive(offset)
            }
            'G' => {
                self.goal_column = None;
                let explicit = self.vim.count.take();
                let offset = self
                    .with_document(cx, |doc| {
                        let total = doc.rope().len_lines().max(1);
                        let row = match explicit {
                            Some(line_num) => line_num.saturating_sub(1).min(total - 1),
                            None => total - 1,
                        };
                        line_first_non_blank(doc, row)
                    })
                    .unwrap_or(self.head);
                MotionTarget::linewise(offset)
            }
            'w' | 'W' => {
                let count = self.vim.take_count();
                let big_word = ch == 'W';
                self.goal_column = None;
                let mut pos = self.head;
                for i in 0..count {
                    let is_last = i + 1 == count;
                    pos = self.around(pos, cx, |text, off| {
                        vim_word_forward(text, off, big_word, for_change && is_last)
                    });
                }
                MotionTarget::exclusive(pos)
            }
            'b' | 'B' => {
                let count = self.vim.take_count();
                let big_word = ch == 'B';
                self.goal_column = None;
                let mut pos = self.head;
                for _ in 0..count {
                    pos = self.around(pos, cx, |text, off| vim_word_backward(text, off, big_word));
                }
                MotionTarget::exclusive(pos)
            }
            'e' | 'E' => {
                let count = self.vim.take_count();
                let big_word = ch == 'E';
                self.goal_column = None;
                let mut pos = self.head;
                for _ in 0..count {
                    pos = self.around(pos, cx, |text, off| vim_word_end(text, off, big_word));
                }
                MotionTarget::inclusive(pos)
            }
            '%' => {
                self.vim.count = None;
                self.goal_column = None;
                let target = self.with_document(cx, |doc| matching_bracket(doc, self.head)).flatten()?;
                MotionTarget::inclusive(target)
            }
            ';' | ',' => {
                let last = self.vim.last_find?;
                let forward = if ch == ';' { last.forward } else { !last.forward };
                let count = self.vim.take_count();
                self.vim_find_char_target(last.ch, forward, last.till, count, cx)?
            }
            _ => return None,
        };
        Some(target)
    }

    fn vim_goto_line_target(&mut self, line_num: usize, cx: &App) -> MotionTarget {
        self.goal_column = None;
        let offset = self
            .with_document(cx, |doc| {
                let total = doc.rope().len_lines().max(1);
                let row = line_num.saturating_sub(1).min(total - 1);
                line_first_non_blank(doc, row)
            })
            .unwrap_or(0);
        MotionTarget::linewise(offset)
    }

    fn vim_find_char_target(
        &mut self,
        ch: char,
        forward: bool,
        till: bool,
        count: usize,
        cx: &App,
    ) -> Option<MotionTarget> {
        self.goal_column = None;
        let offset = self
            .with_document(cx, |doc| {
                let row = doc.rope().byte_to_line(self.head.min(doc.len()));
                let (range, text) = layout::line(doc, row);
                let local = self.head.saturating_sub(range.start);
                find_char_on_line(&text, local, ch, forward, till, count).map(|found| range.start + found)
            })
            .flatten()?;
        Some(if forward { MotionTarget::inclusive(offset) } else { MotionTarget::exclusive(offset) })
    }

    fn apply_motion_target(&mut self, target: MotionTarget, cx: &mut Context<Self>) {
        if let Some(op) = self.vim.operator.take() {
            let range = if target.linewise {
                self.with_document(cx, |doc| {
                    let rope = doc.rope();
                    let r1 = rope.byte_to_line(self.head.min(doc.len()));
                    let r2 = rope.byte_to_line(target.offset.min(doc.len()));
                    let (lo, hi) = (r1.min(r2), r1.max(r2));
                    line_span(doc, lo, hi - lo + 1)
                })
                .unwrap_or(self.head..self.head)
            } else {
                let (lo, hi) = (self.head.min(target.offset), self.head.max(target.offset));
                let end = if target.inclusive {
                    self.with_document(cx, |doc| inclusive_end(doc, hi)).unwrap_or(hi)
                } else {
                    hi
                };
                lo..end
            };
            self.apply_operator_range(op, range, target.linewise, cx);
            return;
        }

        let dest =
            self.with_document(cx, |doc| clamp_normal_offset(doc, target.offset)).unwrap_or(target.offset);
        self.head = dest;
        if !self.vim.is_visual() {
            self.anchor = dest;
        }
        self.autoscroll = true;
        self.break_coalescing(cx);
        cx.notify();
    }

    fn vim_move_rows(&mut self, rows: isize, cx: &mut Context<Self>) {
        let target = self.vertical(self.head, rows, cx);
        let dest = self.with_document(cx, |doc| clamp_normal_offset(doc, target)).unwrap_or(target);
        self.head = dest;
        if !self.vim.is_visual() {
            self.anchor = dest;
        }
        self.autoscroll = true;
        self.break_coalescing(cx);
        cx.notify();
    }

    fn visual_selection_with_kind(&self, cx: &App) -> (Range<usize>, bool) {
        let linewise = self.vim.mode == VimMode::VisualLine;
        let range = self
            .with_document(cx, |doc| visual_byte_range(doc, self.vim.mode, self.anchor, self.head))
            .unwrap_or_default();
        (range, linewise)
    }

    fn vim_chars_from_cursor(&self, count: usize, forward: bool, cx: &App) -> Range<usize> {
        self.with_document(cx, |doc| {
            let row = doc.rope().byte_to_line(self.head.min(doc.len()));
            let (range, text) = layout::line(doc, row);
            let local = self.head.saturating_sub(range.start).min(text.len());
            if forward {
                let mut end = local;
                for _ in 0..count {
                    end = next_boundary(&text, end);
                }
                range.start + local..range.start + end
            } else {
                let mut start = local;
                for _ in 0..count {
                    start = previous_boundary(&text, start);
                }
                range.start + start..range.start + local
            }
        })
        .unwrap_or(self.head..self.head)
    }

    fn apply_linewise_operator(&mut self, op: VimOperator, count: usize, cx: &mut Context<Self>) {
        let range = self
            .with_document(cx, |doc| {
                let row = doc.rope().byte_to_line(self.head.min(doc.len()));
                line_span(doc, row, count)
            })
            .unwrap_or(self.head..self.head);
        self.apply_operator_range(op, range, true, cx);
    }

    fn apply_operator_range(
        &mut self,
        op: VimOperator,
        range: Range<usize>,
        linewise: bool,
        cx: &mut Context<Self>,
    ) {
        match op {
            VimOperator::Yank => {
                if let Some(yanked) =
                    self.with_document(cx, |doc| doc.rope().byte_slice(range.clone()).to_string())
                {
                    let text =
                        if linewise && !yanked.ends_with('\n') { format!("{yanked}\n") } else { yanked };
                    self.vim.register = VimRegister { text: text.clone(), linewise };
                    cx.write_to_clipboard(ClipboardItem::new_string(text));
                }
                self.head = self
                    .with_document(cx, |doc| clamp_normal_offset(doc, range.start))
                    .unwrap_or(range.start);
                self.anchor = self.head;
                self.autoscroll = true;
                cx.notify();
            }
            VimOperator::Delete => {
                if !self.is_editable(cx) || range.is_empty() {
                    return;
                }
                // Deleting the final line without a trailing newline also removes the preceding `\n`.
                let delete_range = if linewise {
                    self.with_document(cx, |doc| {
                        let text = doc.rope().byte_slice(range.clone()).to_string();
                        if !text.ends_with('\n') && range.start > 0 {
                            let before = doc.rope().byte_slice(0..range.start).to_string();
                            if before.ends_with("\r\n") {
                                range.start - 2..range.end
                            } else if before.ends_with('\n') {
                                range.start - 1..range.end
                            } else {
                                range.clone()
                            }
                        } else {
                            range.clone()
                        }
                    })
                    .unwrap_or(range.clone())
                } else {
                    range.clone()
                };
                if let Some(deleted) =
                    self.with_document(cx, |doc| doc.rope().byte_slice(range.clone()).to_string())
                {
                    let text =
                        if linewise && !deleted.ends_with('\n') { format!("{deleted}\n") } else { deleted };
                    self.vim.register = VimRegister { text: text.clone(), linewise };
                    cx.write_to_clipboard(ClipboardItem::new_string(text));
                }
                if let Some(inserted) = self.edit_text(cx, |doc| Some(doc.replace(delete_range, ""))) {
                    let dest = if linewise {
                        self.with_document(cx, |doc| {
                            let row = doc.rope().byte_to_line(inserted.start.min(doc.len()));
                            line_first_non_blank(doc, row)
                        })
                        .unwrap_or(inserted.start)
                    } else {
                        self.with_document(cx, |doc| clamp_normal_offset(doc, inserted.start))
                            .unwrap_or(inserted.start)
                    };
                    self.head = dest;
                    self.anchor = dest;
                    self.goal_column = None;
                    self.autoscroll = true;
                    self.break_coalescing(cx);
                    cx.notify();
                }
            }
            VimOperator::Change => {
                if !self.is_editable(cx) {
                    return;
                }
                if linewise {
                    // `cc` / `S`: keep indentation of the first line and the trailing newline.
                    let (replace_range, indent, yanked) = self
                        .with_document(cx, |doc| {
                            let start_row = doc.rope().byte_to_line(range.start.min(doc.len()));
                            let (_, first_text) = layout::line(doc, start_row);
                            let indent: String =
                                first_text.chars().take_while(|c| c.is_whitespace()).collect();
                            let raw = doc.rope().byte_slice(range.clone()).to_string();
                            let trimmed_end = if raw.ends_with("\r\n") {
                                range.end - 2
                            } else if raw.ends_with('\n') {
                                range.end - 1
                            } else {
                                range.end
                            };
                            let yanked = if raw.ends_with('\n') { raw } else { format!("{raw}\n") };
                            (range.start..trimmed_end, indent, yanked)
                        })
                        .unwrap_or((range.clone(), String::new(), String::new()));
                    self.vim.register = VimRegister { text: yanked.clone(), linewise: true };
                    cx.write_to_clipboard(ClipboardItem::new_string(yanked));
                    if let Some(inserted) =
                        self.edit_text(cx, |doc| Some(doc.replace(replace_range, &indent)))
                    {
                        self.head = inserted.end;
                        self.anchor = inserted.end;
                        self.goal_column = None;
                        self.autoscroll = true;
                        self.enter_insert_mode(cx);
                    }
                } else {
                    if !range.is_empty()
                        && let Some(deleted) =
                            self.with_document(cx, |doc| doc.rope().byte_slice(range.clone()).to_string())
                    {
                        self.vim.register = VimRegister { text: deleted.clone(), linewise: false };
                        cx.write_to_clipboard(ClipboardItem::new_string(deleted));
                    }
                    if let Some(inserted) = self.edit_text(cx, |doc| Some(doc.replace(range, ""))) {
                        self.head = inserted.start;
                        self.anchor = inserted.start;
                        self.goal_column = None;
                        self.autoscroll = true;
                        self.enter_insert_mode(cx);
                    }
                }
            }
            VimOperator::Indent | VimOperator::Outdent => {
                if !self.is_editable(cx) {
                    return;
                }
                self.vim_indent_range(range, op == VimOperator::Indent, cx);
            }
        }
    }

    fn vim_open_line(&mut self, below: bool, cx: &mut Context<Self>) {
        let Some((insert_at, text_to_insert, caret_offset)) = self.with_document(cx, |doc| {
            let row = doc.rope().byte_to_line(self.head.min(doc.len()));
            let (range, line_text) = layout::line(doc, row);
            let indent: String = line_text.chars().take_while(|c| c.is_whitespace()).collect();
            if below {
                let inserted = format!("\n{indent}");
                let caret = range.end + inserted.len();
                (range.end, inserted, caret)
            } else {
                let inserted = format!("{indent}\n");
                let caret = range.start + indent.len();
                (range.start, inserted, caret)
            }
        }) else {
            return;
        };
        if self.edit_text(cx, |doc| Some(doc.replace(insert_at..insert_at, &text_to_insert))).is_some() {
            self.head = caret_offset;
            self.anchor = caret_offset;
            self.goal_column = None;
            self.autoscroll = true;
            self.enter_insert_mode(cx);
        }
    }

    fn vim_replace_chars(&mut self, ch: char, count: usize, cx: &mut Context<Self>) {
        if !self.is_editable(cx) {
            return;
        }
        let range = self.vim_chars_from_cursor(count, true, cx);
        if range.is_empty() {
            return;
        }
        let char_count = self
            .with_document(cx, |doc| doc.rope().byte_slice(range.clone()).to_string().chars().count())
            .unwrap_or(0);
        if char_count < count {
            return;
        }
        let replacement: String = std::iter::repeat_n(ch, char_count).collect();
        if let Some(inserted) = self.edit_text(cx, |doc| Some(doc.replace(range, &replacement))) {
            let end_char = inserted.end.saturating_sub(ch.len_utf8()).max(inserted.start);
            self.head = self.with_document(cx, |doc| clamp_normal_offset(doc, end_char)).unwrap_or(end_char);
            self.anchor = self.head;
            self.goal_column = None;
            self.autoscroll = true;
            self.break_coalescing(cx);
            cx.notify();
        }
    }

    fn vim_toggle_case(&mut self, range: Range<usize>, cx: &mut Context<Self>) {
        if !self.is_editable(cx) || range.is_empty() {
            return;
        }
        let Some(toggled) = self.with_document(cx, |doc| {
            doc.rope()
                .byte_slice(range.clone())
                .to_string()
                .chars()
                .flat_map(|c| {
                    if c.is_lowercase() {
                        c.to_uppercase().collect::<Vec<_>>()
                    } else if c.is_uppercase() {
                        c.to_lowercase().collect::<Vec<_>>()
                    } else {
                        vec![c]
                    }
                })
                .collect::<String>()
        }) else {
            return;
        };
        if let Some(inserted) = self.edit_text(cx, |doc| Some(doc.replace(range, &toggled))) {
            self.head = self
                .with_document(cx, |doc| clamp_normal_offset(doc, inserted.start))
                .unwrap_or(inserted.start);
            self.anchor = self.head;
            self.goal_column = None;
            self.autoscroll = true;
            self.break_coalescing(cx);
            cx.notify();
        }
    }

    fn vim_join_lines(&mut self, count: usize, cx: &mut Context<Self>) {
        if !self.is_editable(cx) {
            return;
        }
        let joins = count.saturating_sub(1).max(1);
        for _ in 0..joins {
            let Some((replace_range, sep, cursor)) = self
                .with_document(cx, |doc| {
                    let rope = doc.rope();
                    let row = rope.byte_to_line(self.head.min(doc.len()));
                    if row + 1 >= rope.len_lines() {
                        return None;
                    }
                    let (cur_range, cur_text) = layout::line(doc, row);
                    let (next_range, next_text) = layout::line(doc, row + 1);
                    let next_indent = next_text
                        .chars()
                        .take_while(|c| c.is_whitespace())
                        .map(char::len_utf8)
                        .sum::<usize>();
                    let needs_space = !cur_text.is_empty()
                        && !cur_text.ends_with(char::is_whitespace)
                        && next_indent < next_text.len();
                    let sep = if needs_space { " " } else { "" };
                    Some((cur_range.end..next_range.start + next_indent, sep, cur_range.end))
                })
                .flatten()
            else {
                break;
            };
            if self.edit_text(cx, |doc| Some(doc.replace(replace_range, sep))).is_some() {
                self.head = self.with_document(cx, |doc| clamp_normal_offset(doc, cursor)).unwrap_or(cursor);
                self.anchor = self.head;
                self.autoscroll = true;
            }
        }
        self.break_coalescing(cx);
        cx.notify();
    }

    fn vim_indent_range(&mut self, range: Range<usize>, indent: bool, cx: &mut Context<Self>) {
        let Some((span, rebuilt, start_row)) = self.with_document(cx, |doc| {
            let rope = doc.rope();
            let start_row = rope.byte_to_line(range.start.min(doc.len()));
            let end_byte = if range.end > range.start { range.end - 1 } else { range.start };
            let end_row = rope.byte_to_line(end_byte.min(doc.len()));
            let span = line_span(doc, start_row, end_row - start_row + 1);
            let mut out = String::new();
            for row in start_row..=end_row {
                let raw = rope.line(row).to_string();
                if indent {
                    if raw.trim().is_empty() {
                        out.push_str(&raw);
                    } else {
                        out.push_str("    ");
                        out.push_str(&raw);
                    }
                } else if let Some(stripped) = raw.strip_prefix('\t') {
                    out.push_str(stripped);
                } else {
                    let spaces = raw.bytes().take(4).take_while(|&b| b == b' ').count();
                    out.push_str(&raw[spaces..]);
                }
            }
            (span, out, start_row)
        }) else {
            return;
        };
        if self.edit_text(cx, |doc| Some(doc.replace(span, &rebuilt))).is_some() {
            self.head =
                self.with_document(cx, |doc| line_first_non_blank(doc, start_row)).unwrap_or(self.head);
            self.anchor = self.head;
            self.goal_column = None;
            self.autoscroll = true;
            self.break_coalescing(cx);
            cx.notify();
        }
    }

    fn effective_paste_register(&self, cx: &App) -> Option<VimRegister> {
        let clipboard = cx.read_from_clipboard().and_then(|item| item.text());
        if let Some(clip) = clipboard
            && !clip.is_empty()
            && clip != self.vim.register.text
        {
            return Some(VimRegister { text: clip, linewise: false });
        }
        (!self.vim.register.text.is_empty()).then(|| self.vim.register.clone())
    }

    fn vim_paste(&mut self, after: bool, count: usize, cx: &mut Context<Self>) {
        if !self.is_editable(cx) {
            return;
        }
        let Some(reg) = self.effective_paste_register(cx) else {
            return;
        };
        let payload: String = std::iter::repeat_n(reg.text.as_str(), count.max(1)).collect();
        if reg.linewise {
            let body = payload.trim_end_matches('\n');
            let Some((insert_at, to_insert, target_row)) = self.with_document(cx, |doc| {
                let rope = doc.rope();
                let row = rope.byte_to_line(self.head.min(doc.len()));
                let (range, _) = layout::line(doc, row);
                if after {
                    (range.end, format!("\n{body}"), row + 1)
                } else {
                    (range.start, format!("{body}\n"), row)
                }
            }) else {
                return;
            };
            if self.edit_text(cx, |doc| Some(doc.replace(insert_at..insert_at, &to_insert))).is_some() {
                self.head =
                    self.with_document(cx, |doc| line_first_non_blank(doc, target_row)).unwrap_or(insert_at);
                self.anchor = self.head;
                self.goal_column = None;
                self.autoscroll = true;
                self.break_coalescing(cx);
                cx.notify();
            }
        } else {
            let insert_at = if after {
                self.with_document(cx, |doc| inclusive_end(doc, self.head)).unwrap_or(self.head)
            } else {
                self.head
            };
            if let Some(inserted) =
                self.edit_text(cx, |doc| Some(doc.replace(insert_at..insert_at, &payload)))
            {
                let last_offset = if inserted.end > inserted.start {
                    self.with_document(cx, |doc| {
                        let row = doc.rope().byte_to_line(inserted.end.saturating_sub(1));
                        let (range, text) = layout::line(doc, row);
                        let local = inserted.end.min(range.end).saturating_sub(range.start);
                        range.start + previous_boundary(&text, local)
                    })
                    .unwrap_or(inserted.start)
                } else {
                    inserted.start
                };
                self.head = self
                    .with_document(cx, |doc| clamp_normal_offset(doc, last_offset))
                    .unwrap_or(last_offset);
                self.anchor = self.head;
                self.goal_column = None;
                self.autoscroll = true;
                self.break_coalescing(cx);
                cx.notify();
            }
        }
    }

    fn vim_paste_over_selection(&mut self, range: Range<usize>, cx: &mut Context<Self>) {
        if !self.is_editable(cx) {
            return;
        }
        let Some(reg) = self.effective_paste_register(cx) else {
            return;
        };
        let replaced = self.with_document(cx, |doc| doc.rope().byte_slice(range.clone()).to_string());
        if let Some(inserted) = self.edit_text(cx, |doc| Some(doc.replace(range, &reg.text))) {
            if let Some(old) = replaced {
                self.vim.register = VimRegister { text: old, linewise: false };
            }
            self.head = self
                .with_document(cx, |doc| clamp_normal_offset(doc, inserted.start))
                .unwrap_or(inserted.start);
            self.anchor = self.head;
            self.goal_column = None;
            self.autoscroll = true;
            self.break_coalescing(cx);
            cx.notify();
        }
    }

    fn vim_search_word_under_cursor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(word) = self
            .with_document(cx, |doc| {
                let range = word_object(doc, self.head, false, false)?;
                let text = doc.rope().byte_slice(range).to_string();
                (!text.trim().is_empty()).then_some(text)
            })
            .flatten()
        else {
            return;
        };
        self.find.visible = true;
        self.find.input.update(cx, |input, cx| input.set_value(word, window, cx));
        self.update_matches(false, cx);
        let from = self.with_document(cx, |doc| inclusive_end(doc, self.head)).unwrap_or(self.head);
        let query = self.query(cx);
        if let Some(found) = self.with_document(cx, |doc| doc.find_next(&query, from)).flatten() {
            self.find.current = self.find.matches.iter().position(|c| *c == found);
            self.head = found.start;
            self.anchor = found.start;
            self.autoscroll = true;
        }
        cx.notify();
    }
}

#[cfg(test)]
mod tests {
    use soprano_text::EditorDocument;

    use super::*;

    fn doc(text: &str) -> (tempfile::TempDir, EditorDocument) {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("test.rs");
        std::fs::write(&path, text).expect("write");
        (dir, EditorDocument::open(&path))
    }

    #[test]
    fn vim_word_motions_distinguish_words_punctuation_and_big_words() {
        let line = "foo_bar(baz)  qux-1";
        assert_eq!(vim_word_forward(line, 0, false, false), 7); // '('
        assert_eq!(vim_word_forward(line, 7, false, false), 8); // 'baz'
        assert_eq!(vim_word_forward(line, 0, true, false), 14); // 'qux-1'
        assert_eq!(vim_word_forward(line, 0, false, true), 7); // cw stops before '('
        assert_eq!(vim_word_end(line, 0, false), 6); // 'r'
        assert_eq!(vim_word_end(line, 6, false), 7); // '('
        assert_eq!(vim_word_end(line, 0, true), 11); // ')'
        assert_eq!(vim_word_backward(line, 14, false), 11); // ')'
        assert_eq!(vim_word_backward(line, 14, true), 0); // 'foo_bar(baz)'
    }

    #[test]
    fn find_char_handles_forward_backward_till_and_counts() {
        let line = "alpha beta gamma delta";
        assert_eq!(find_char_on_line(line, 0, 'a', true, false, 1), Some(4));
        assert_eq!(find_char_on_line(line, 0, 'a', true, false, 2), Some(9));
        assert_eq!(find_char_on_line(line, 0, 'b', true, true, 1), Some(5));
        assert_eq!(find_char_on_line(line, 16, 'a', false, false, 1), Some(15));
        assert_eq!(find_char_on_line(line, 16, 'a', false, true, 1), Some(16));
    }

    #[test]
    fn matching_bracket_respects_nesting_across_lines() {
        let (_dir, d) = doc("fn f() {\n    let a = (1 + (2));\n}\n");
        let open_brace = 7;
        let close_brace = d.text().rfind('}').unwrap();
        assert_eq!(matching_bracket(&d, open_brace), Some(close_brace));
        assert_eq!(matching_bracket(&d, close_brace), Some(open_brace));
        let outer_paren = d.text().find("(1").unwrap();
        let outer_close = d.text().find("));").unwrap() + 1;
        assert_eq!(matching_bracket(&d, outer_paren), Some(outer_close));
        assert_eq!(matching_bracket(&d, outer_close), Some(outer_paren));
    }

    #[test]
    fn text_objects_select_inner_and_around_words_quotes_and_delimiters() {
        let (_dir, d) = doc("let msg = \"hello world\";\nfn f(a, b) { x }\n");
        let inside_hello = d.text().find("ello").unwrap();
        assert_eq!(
            text_object_range(&d, inside_hello, 'w', false).map(|r| d.text()[r].to_owned()),
            Some("hello".into())
        );
        assert_eq!(
            text_object_range(&d, inside_hello, 'w', true).map(|r| d.text()[r].to_owned()),
            Some("hello ".into())
        );
        assert_eq!(
            text_object_range(&d, inside_hello, '"', false).map(|r| d.text()[r].to_owned()),
            Some("hello world".into())
        );
        assert_eq!(
            text_object_range(&d, inside_hello, '"', true).map(|r| d.text()[r].to_owned()),
            Some("\"hello world\"".into())
        );
        let inside_parens = d.text().find("a, b").unwrap();
        assert_eq!(
            text_object_range(&d, inside_parens, '(', false).map(|r| d.text()[r].to_owned()),
            Some("a, b".into())
        );
        assert_eq!(
            text_object_range(&d, inside_parens, ')', true).map(|r| d.text()[r].to_owned()),
            Some("(a, b)".into())
        );
    }
}
