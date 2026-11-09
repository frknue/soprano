//! Copy mode: a keyboard cursor over the grid with vim motions (`TerminalCopyMode.swift`).
//!
//! The session is pure state. The view applies the commands it returns to the terminal's
//! selection and viewport.

/// Whether copy mode is moving its cursor or extending a selection.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CopyModePhase {
    Navigating,
    Selecting,
}

/// How a copy-mode selection grows: by cell (`v`) or by whole lines (`V`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CopyModeSelectionStyle {
    Character,
    Line,
}

/// What a key means in copy mode.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CopyModeCommand {
    MoveLeft,
    MoveDown,
    MoveUp,
    MoveRight,
    LineStart,
    LineEnd,
    ViewportTop,
    ViewportMiddle,
    ViewportBottom,
    HistoryTop,
    HistoryBottom,
    HalfPageUp,
    HalfPageDown,
    PageUp,
    PageDown,
    BeginSelection,
    BeginLineSelection,
    CopyAndExit,
    Cancel,
    /// The first `g` of `gg`: wait for the next key.
    AwaitMore,
}

/// One key press as copy mode reads it.
///
/// `key` is the key's character ignoring modifiers, lowercased, or one of GPUI's named keys:
/// `escape`, `enter`, `left`, `right`, `up`, `down`, `pageup`, `pagedown`. (The Swift version
/// matched macOS virtual key codes for the named keys.)
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CopyModeInput {
    pub key: String,
    pub control: bool,
    pub shift: bool,
    pub option: bool,
    pub command: bool,
}

impl CopyModeInput {
    pub fn new(key: &str) -> Self {
        Self { key: key.to_owned(), ..Self::default() }
    }

    pub fn shift(mut self) -> Self {
        self.shift = true;
        self
    }

    pub fn control(mut self) -> Self {
        self.control = true;
        self
    }

    /// The input for a GPUI keystroke: `space` reads as `" "`, letters are lowercased.
    pub fn from_keystroke(keystroke: &gpui::Keystroke) -> Self {
        let m = keystroke.modifiers;
        let key = match keystroke.key.as_str() {
            "space" => " ".to_owned(),
            other => other.to_lowercase(),
        };
        Self { key, control: m.control, shift: m.shift, option: m.alt, command: m.platform }
    }
}

/// Copy mode's cursor and selection state over a grid of `column_count` x `row_count` cells.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CopyModeSession {
    phase: CopyModePhase,
    selection_style: Option<CopyModeSelectionStyle>,
    column: usize,
    row: usize,
    column_count: usize,
    row_count: usize,
    bottom_content_row: usize,
    awaits_second_g: bool,
}

impl CopyModeSession {
    pub fn new(column: isize, row: isize, column_count: usize, row_count: usize) -> Self {
        let column_count = column_count.max(1);
        let row_count = row_count.max(1);
        let column = column.clamp(0, column_count as isize - 1) as usize;
        let row = row.clamp(0, row_count as isize - 1) as usize;
        Self {
            phase: CopyModePhase::Navigating,
            selection_style: None,
            column,
            row,
            column_count,
            row_count,
            bottom_content_row: row,
            awaits_second_g: false,
        }
    }

    pub fn phase(&self) -> CopyModePhase {
        self.phase
    }

    pub fn selection_style(&self) -> Option<CopyModeSelectionStyle> {
        self.selection_style
    }

    pub fn column(&self) -> usize {
        self.column
    }

    pub fn row(&self) -> usize {
        self.row
    }

    pub fn column_count(&self) -> usize {
        self.column_count
    }

    pub fn row_count(&self) -> usize {
        self.row_count
    }

    /// What `input` means here; `None` for keys copy mode ignores (it still swallows them).
    pub fn command(&mut self, input: &CopyModeInput) -> Option<CopyModeCommand> {
        use CopyModeCommand::*;
        if input.command || input.option {
            self.awaits_second_g = false;
            return None;
        }

        if input.key == "escape" || (input.control && input.key == "c") {
            self.awaits_second_g = false;
            return Some(Cancel);
        }

        if input.control {
            self.awaits_second_g = false;
            return match input.key.as_str() {
                "u" => Some(HalfPageUp),
                "d" => Some(HalfPageDown),
                "b" => Some(PageUp),
                "f" => Some(PageDown),
                " " => Some(BeginSelection),
                _ => None,
            };
        }

        let named = match input.key.as_str() {
            "left" => Some(MoveLeft),
            "right" => Some(MoveRight),
            "down" => Some(MoveDown),
            "up" => Some(MoveUp),
            "pageup" => Some(PageUp),
            "pagedown" => Some(PageDown),
            "enter" => Some(CopyAndExit),
            _ => None,
        };
        if named.is_some() {
            self.awaits_second_g = false;
            return named;
        }

        let shift = input.shift;
        let command = match input.key.as_str() {
            "h" if shift => ViewportTop,
            "m" if shift => ViewportMiddle,
            "l" if shift => ViewportBottom,
            "h" => MoveLeft,
            "j" => MoveDown,
            "k" => MoveUp,
            "l" => MoveRight,
            "0" | "^" => LineStart,
            "6" if shift => LineStart,
            "$" => LineEnd,
            "4" if shift => LineEnd,
            "g" if shift => HistoryBottom,
            "g" => {
                if self.awaits_second_g {
                    self.awaits_second_g = false;
                    return Some(HistoryTop);
                }
                self.awaits_second_g = true;
                return Some(AwaitMore);
            }
            "v" if shift => BeginLineSelection,
            "v" | " " => BeginSelection,
            "y" => CopyAndExit,
            "q" => Cancel,
            _ => {
                self.awaits_second_g = false;
                return None;
            }
        };
        self.awaits_second_g = false;
        Some(command)
    }

    pub fn begin_selection(&mut self, style: CopyModeSelectionStyle) {
        self.phase = CopyModePhase::Selecting;
        self.selection_style = Some(style);
    }

    /// A mouse press or drag inside copy mode moves the cursor there; a selection made with
    /// the mouse is a character selection that the keyboard can extend or yank.
    pub fn update_mouse_selection(&mut self, column: isize, row: isize, has_selection: bool) {
        self.column = column.clamp(0, self.column_count as isize - 1) as usize;
        self.row = row.clamp(0, self.row_count as isize - 1) as usize;
        self.phase = if has_selection { CopyModePhase::Selecting } else { CopyModePhase::Navigating };
        self.selection_style = has_selection.then_some(CopyModeSelectionStyle::Character);
        self.awaits_second_g = false;
    }

    /// Moves the cursor sideways within the row; whether it moved.
    pub fn move_horizontal(&mut self, delta: isize) -> bool {
        let next = (self.column as isize + delta).clamp(0, self.column_count as isize - 1) as usize;
        if next == self.column {
            return false;
        }
        self.column = next;
        true
    }

    /// Returns the number of lines that the viewport must scroll. The cursor
    /// remains on the boundary row when movement crosses the visible grid.
    pub fn move_vertical(&mut self, delta: isize) -> isize {
        let candidate = self.row as isize + delta;
        if candidate < 0 {
            self.row = 0;
            return candidate;
        }
        let last = self.row_count as isize - 1;
        if candidate > last {
            self.row = last as usize;
            return candidate - last;
        }
        self.row = candidate as usize;
        0
    }

    pub fn move_to_line_start(&mut self) {
        self.column = 0;
    }

    pub fn move_to_line_end(&mut self) {
        self.column = self.column_count - 1;
    }

    pub fn move_to_viewport_row(&mut self, target: isize) {
        self.row = target.clamp(0, self.row_count as isize - 1) as usize;
    }

    pub fn move_to_history_top(&mut self) {
        self.column = 0;
        self.row = 0;
    }

    /// Back to the row the cursor started on: the last row with content when copy mode began.
    pub fn move_to_history_bottom(&mut self) {
        self.column = self.column_count - 1;
        self.row = self.bottom_content_row;
    }
}

#[cfg(test)]
mod tests {
    use super::CopyModeCommand::*;
    use super::*;

    fn session() -> CopyModeSession {
        CopyModeSession::new(3, 4, 80, 24)
    }

    fn key(k: &str) -> CopyModeInput {
        CopyModeInput::new(k)
    }

    #[test]
    fn vim_keys_map_to_copy_mode_commands() {
        let mut s = session();
        assert_eq!(s.command(&key("h")), Some(MoveLeft));
        assert_eq!(s.command(&key("j")), Some(MoveDown));
        assert_eq!(s.command(&key("k")), Some(MoveUp));
        assert_eq!(s.command(&key("l")), Some(MoveRight));
        assert_eq!(s.command(&key("h").shift()), Some(ViewportTop));
        assert_eq!(s.command(&key("m").shift()), Some(ViewportMiddle));
        assert_eq!(s.command(&key("l").shift()), Some(ViewportBottom));
        assert_eq!(s.command(&key("v")), Some(BeginSelection));
        assert_eq!(s.command(&key("v").shift()), Some(BeginLineSelection));
        assert_eq!(s.command(&key("y")), Some(CopyAndExit));
        assert_eq!(s.command(&key("q")), Some(Cancel));
    }

    #[test]
    fn line_motions_page_motions_and_cancel_keys_are_recognized() {
        let mut s = session();
        assert_eq!(s.command(&key("0")), Some(LineStart));
        assert_eq!(s.command(&key("6").shift()), Some(LineStart));
        assert_eq!(s.command(&key("$")), Some(LineEnd));
        assert_eq!(s.command(&key("4").shift()), Some(LineEnd));
        assert_eq!(s.command(&key("u").control()), Some(HalfPageUp));
        assert_eq!(s.command(&key("d").control()), Some(HalfPageDown));
        assert_eq!(s.command(&key("b").control()), Some(PageUp));
        assert_eq!(s.command(&key("f").control()), Some(PageDown));
        assert_eq!(s.command(&key("c").control()), Some(Cancel));
        assert_eq!(s.command(&key("escape")), Some(Cancel));
        assert_eq!(s.command(&key("left")), Some(MoveLeft));
        assert_eq!(s.command(&key("pagedown")), Some(PageDown));
        let mut cmd = key("c");
        cmd.command = true;
        assert_eq!(s.command(&cmd), None);
    }

    #[test]
    fn selection_style_is_remembered_for_subsequent_motions() {
        let mut character = session();
        character.begin_selection(CopyModeSelectionStyle::Character);
        let mut line = session();
        line.begin_selection(CopyModeSelectionStyle::Line);
        assert_eq!(character.selection_style(), Some(CopyModeSelectionStyle::Character));
        assert_eq!(line.selection_style(), Some(CopyModeSelectionStyle::Line));
    }

    #[test]
    fn double_g_and_shift_g_map_to_history_boundaries() {
        let mut s = session();
        assert_eq!(s.command(&key("g")), Some(AwaitMore));
        assert_eq!(s.command(&key("g")), Some(HistoryTop));
        assert_eq!(s.command(&key("g").shift()), Some(HistoryBottom));
    }

    #[test]
    fn dragging_with_the_mouse_starts_a_selection_that_can_be_yanked_or_extended_with_the_keyboard() {
        let mut s = session();
        s.update_mouse_selection(12, 8, true);
        assert_eq!(s.phase(), CopyModePhase::Selecting);
        assert_eq!(s.selection_style(), Some(CopyModeSelectionStyle::Character));
        assert_eq!((s.column(), s.row()), (12, 8));
        assert_eq!(s.command(&key("y")), Some(CopyAndExit));
        assert_eq!(s.command(&key("enter")), Some(CopyAndExit));
        s.move_horizontal(1);
        assert_eq!(s.column(), 13);
    }

    #[test]
    fn clicking_without_a_selection_returns_to_navigation_at_the_mouse_position() {
        let mut s = session();
        s.begin_selection(CopyModeSelectionStyle::Line);
        assert_eq!(s.command(&key("g")), Some(AwaitMore));
        s.update_mouse_selection(12, 8, false);
        assert_eq!(s.phase(), CopyModePhase::Navigating);
        assert_eq!(s.selection_style(), None);
        assert_eq!((s.column(), s.row()), (12, 8));
        assert_eq!(s.command(&key("g")), Some(AwaitMore));
    }

    #[test]
    fn mouse_selection_replaces_keyboard_line_selection_and_clamps_outside_the_grid() {
        let mut s = session();
        s.begin_selection(CopyModeSelectionStyle::Line);
        s.update_mouse_selection(-5, 30, true);
        assert_eq!(s.phase(), CopyModePhase::Selecting);
        assert_eq!(s.selection_style(), Some(CopyModeSelectionStyle::Character));
        assert_eq!((s.column(), s.row()), (0, 23));
        assert_eq!(s.command(&key("q")), Some(Cancel));
    }

    #[test]
    fn cursor_clamps_horizontally_and_requests_vertical_scroll_at_edges() {
        let mut s = CopyModeSession::new(0, 0, 3, 2);
        assert!(!s.move_horizontal(-1));
        assert_eq!(s.column(), 0);
        assert_eq!(s.move_vertical(-1), -1);
        assert_eq!(s.row(), 0);
        assert!(s.move_horizontal(10));
        assert_eq!(s.column(), 2);
        assert_eq!(s.move_vertical(10), 9);
        assert_eq!(s.row(), 1);
    }

    #[test]
    fn history_bottom_returns_to_the_last_active_content_row() {
        let mut s = CopyModeSession::new(3, 7, 80, 24);
        s.move_to_viewport_row(0);
        s.move_to_history_bottom();
        assert_eq!((s.column(), s.row()), (79, 7));
    }
}
