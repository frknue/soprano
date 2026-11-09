//! The terminal's colors (`TerminalColors` in `Config/Theme.swift`): what the app's active
//! theme hands every terminal.

use soprano_types::Color;

/// Terminal palette from the active Soprano theme.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TerminalTheme {
    pub background: Color,
    pub foreground: Color,
    /// The focused cursor (the theme's accent).
    pub cursor: Color,
    /// Text under a block cursor.
    pub cursor_text: Color,
    pub selection_background: Color,
    /// ANSI black, red, green, yellow, blue, magenta, cyan, white, then their bright forms.
    pub palette: [Color; 16],
}

impl TerminalTheme {
    /// Faint (dim) text: 66 % of the foreground over the background.
    pub const FAINT_OPACITY: f32 = 0.66;

    /// The hollow cursor of a terminal without keyboard focus: fg @ 55 % over the background,
    /// opaque, never the accent.
    pub fn unfocused_cursor(&self) -> Color {
        self.background.mix(self.foreground, 0.55)
    }
}

impl Default for TerminalTheme {
    /// Folio Ink's terminal colors, so a terminal shown before the app applies its theme is
    /// already dark and readable.
    fn default() -> Self {
        let c = Color::hex;
        Self {
            background: c(0x1d1b18),
            foreground: c(0xe8e2d6),
            cursor: c(0xe08a52),
            cursor_text: c(0x1d1b18),
            selection_background: c(0x4a3a2c),
            palette: [
                c(0x1d1b18),
                c(0xd9705f),
                c(0x9db07a),
                c(0xd8b36a),
                c(0x7fa1c4),
                c(0xbf8fb5),
                c(0x7fb5ad),
                c(0xb8b0a2),
                c(0x6f665a),
                c(0xe8836f),
                c(0xb3c690),
                c(0xe8c47e),
                c(0x95b5d6),
                c(0xd2a4c8),
                c(0x95c9c1),
                c(0xf4efe5),
            ],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unfocused_surfaces_draw_their_hollow_cursor_in_the_foreground_at_55_percent_never_the_accent() {
        let theme = TerminalTheme::default();
        assert_eq!(theme.unfocused_cursor(), theme.background.mix(theme.foreground, 0.55));
        assert_ne!(theme.unfocused_cursor(), theme.cursor);
        assert_eq!(theme.unfocused_cursor().a, 0xff);
    }
}
