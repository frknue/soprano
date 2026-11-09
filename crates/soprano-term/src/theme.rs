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
    /// Folio Ink's terminal colors (`AppTheme.folioInk` in `Theme.swift`), so a terminal
    /// shown before the app applies its theme is already dark and readable.
    fn default() -> Self {
        let c = Color::hex;
        Self {
            background: c(0x1d1b18),
            foreground: c(0xe2dacb),
            cursor: c(0xe08a52),
            cursor_text: c(0x1d1b18),
            selection_background: c(0x483325),
            palette: [
                c(0x2a2622),
                c(0xe0707a),
                c(0x97ae76),
                c(0xd6aa4f),
                c(0x86a6cb),
                c(0xc191b8),
                c(0x74b3a9),
                c(0xcfc6b5),
                c(0x7d7469),
                c(0xec8f97),
                c(0xb0c592),
                c(0xe8c272),
                c(0xa3bfdf),
                c(0xd5aacd),
                c(0x93c9bf),
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

    #[test]
    fn the_default_is_folio_inks_terminal_palette() {
        let t = TerminalTheme::default();
        let hex = |c: Color| c.to_hex();
        assert_eq!(
            [t.background, t.foreground, t.cursor, t.cursor_text, t.selection_background].map(hex),
            ["#1d1b18", "#e2dacb", "#e08a52", "#1d1b18", "#483325"]
        );
        assert_eq!(hex(t.palette[0]), "#2a2622");
        assert_eq!(hex(t.palette[7]), "#cfc6b5");
        assert_eq!(hex(t.palette[15]), "#f4efe5");
    }
}
