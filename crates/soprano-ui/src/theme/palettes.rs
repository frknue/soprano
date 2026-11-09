//! Soprano's built-in palettes (`Config/Theme.swift`) as data, plus the theme-level logic the
//! Swift `AppTheme`/`ThemeColors`/`TerminalColors` carried: the folio id resolving by appearance,
//! the picker options, the Ghostty terminal configuration, and the derived semantic tokens that
//! keep Soprano's meaning (status, attention, diff and syntax colors, commit-graph lanes).
//!
//! Surfaces, text and borders are *not* taken from here: the UI uses Herdr's token set derived
//! from each theme's terminal palette ([`crate::theme::HerdrColors`]).

use serde::{Deserialize, Serialize};
use soprano_types::Color;

use crate::color::{contrast_ratio, hue_distance, lab_distance};

/// Whether a palette is ink on paper (light) or dark.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Appearance {
    Light,
    Dark,
}

impl Appearance {
    pub fn is_dark(self) -> bool {
        self == Self::Dark
    }

    /// GPUI's window appearance mapped onto light or dark (vibrant variants included).
    pub fn from_window(appearance: gpui::WindowAppearance) -> Self {
        match appearance {
            gpui::WindowAppearance::Light | gpui::WindowAppearance::VibrantLight => Self::Light,
            gpui::WindowAppearance::Dark | gpui::WindowAppearance::VibrantDark => Self::Dark,
        }
    }
}

/// The `appearance` setting: follow the system, or force light or dark.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AppearancePreference {
    #[default]
    System,
    Light,
    Dark,
}

impl AppearancePreference {
    /// The effective appearance under this preference when the system shows `system`.
    pub fn resolve(self, system: Appearance) -> Appearance {
        match self {
            Self::System => system,
            Self::Light => Appearance::Light,
            Self::Dark => Appearance::Dark,
        }
    }

    /// Parses the `settings.json` value (`"system"`, `"light"`, `"dark"`).
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "system" => Some(Self::System),
            "light" => Some(Self::Light),
            "dark" => Some(Self::Dark),
            _ => None,
        }
    }
}

/// The 16 slots of a Soprano theme (`ThemeColors`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ThemeColors {
    pub bg_base: Color,
    pub bg_panel: Color,
    pub bg_raised: Color,
    pub bg_overlay: Color,
    pub text_primary: Color,
    pub text_muted: Color,
    pub accent: Color,
    pub accent_strong: Color,
    pub border_subtle: Color,
    pub border_strong: Color,
    pub success: Color,
    pub danger: Color,
    pub blue: Color,
    pub cyan: Color,
    pub yellow: Color,
    pub gray: Color,
    /// Third-party palettes are all dark; only Folio Paper is light.
    pub appearance: Appearance,
}

/// A theme's terminal palette (`TerminalColors`): fg/bg/cursor/selection and the 16 ANSI
/// colors (black … bright white).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TerminalColors {
    pub background: Color,
    pub foreground: Color,
    pub cursor: Color,
    pub cursor_accent: Color,
    pub selection_background: Color,
    pub ansi: [Color; 16],
}

/// A complete color theme for the app and terminal.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AppTheme {
    pub id: &'static str,
    pub name: &'static str,
    pub colors: ThemeColors,
    pub terminal: TerminalColors,
}

impl AppTheme {
    pub fn appearance(&self) -> Appearance {
        self.colors.appearance
    }

    /// Commit-graph lane colors: a graphite trunk (lane 0) and seven hues, never the accent.
    /// Themes whose palettes repeat a hue skip the repeat and take the next distinct
    /// candidate, so the 8 lanes stay pairwise distinct (CIELAB ΔE ≥ [`MINIMUM_LANE_DISTANCE`]).
    pub fn graph_lanes(&self) -> Vec<Color> {
        let c = &self.colors;
        let t = &self.terminal.ansi;
        let preferred = [c.blue, c.success, t[5], c.cyan, c.yellow, t[13], t[12]];
        let fallbacks = [t[14], t[10], t[11], t[4], t[2], t[6], t[3], t[1], t[9]];
        let mut lanes = vec![c.text_muted];
        let consider = |lanes: &mut Vec<Color>, candidate: Color| {
            if lanes.len() < GRAPH_LANE_COUNT
                && std::iter::once(&c.accent)
                    .chain(lanes.iter())
                    .all(|other| lab_distance(candidate, *other) >= MINIMUM_LANE_DISTANCE)
            {
                lanes.push(candidate);
            }
        };
        let hues: Vec<Color> = preferred.iter().chain(fallbacks.iter()).copied().collect();
        for hue in &hues {
            consider(&mut lanes, *hue);
        }
        // Last resort: the hues lifted toward ink, then sunk toward the page.
        for fraction in [0.4_f32, -0.4] {
            if lanes.len() >= GRAPH_LANE_COUNT {
                break;
            }
            for hue in &hues {
                let candidate = if fraction > 0.0 {
                    hue.mix(c.text_primary, fraction)
                } else {
                    hue.mix(c.bg_base, -fraction)
                };
                consider(&mut lanes, candidate);
            }
        }
        lanes
    }
}

pub const GRAPH_LANE_COUNT: usize = 8;
/// Lanes closer than this CIELAB ΔE (1976) count as the same color. Folio's own closest
/// designed pair (ANSI 5 / ANSI 13 on Paper) is 7.7.
pub const MINIMUM_LANE_DISTANCE: f64 = 6.0;

/// Derived tokens: formulas over the 16 slots (Folio spec §4), so every theme inherits each
/// idiom. Only the ones that keep a Soprano meaning in the Herdr look are ported; surfaces,
/// selection fills, focus and controls come from [`crate::theme::HerdrColors`].
impl ThemeColors {
    fn is_light(&self) -> bool {
        self.appearance == Appearance::Light
    }

    /// The raised surface. Themes whose `bg_raised` equals `bg_panel` (Gruvbox, Solarized)
    /// get 5 % ink mixed into the panel so it still separates.
    pub fn raised(&self) -> Color {
        if contrast_ratio(self.bg_raised, self.bg_panel) < 1.05 {
            self.bg_panel.mix(self.text_primary, 0.05)
        } else {
            self.bg_raised
        }
    }

    /// Attention (a pane or row that wants you): blue, or yellow when `focus` sits within
    /// 40° of blue so focus and attention never share a hue.
    pub fn attention_against(&self, focus: Color) -> Color {
        if hue_distance(focus, self.blue) < 40.0 { self.yellow } else { self.blue }
    }

    /// Attention measured against the theme's own accent, as `Theme.swift` does.
    pub fn attention(&self) -> Color {
        self.attention_against(self.accent)
    }

    /// Lamp of a terminal running a command, apart from the agent colors so a dev server
    /// never reads as an agent at work.
    pub fn running_command(&self) -> Color {
        self.cyan
    }

    /// Idle shell: gray at 60 %.
    pub fn idle_mark(&self) -> Color {
        self.gray.with_alpha(0.60)
    }

    /// Pane-header wash for NEEDS INPUT.
    pub fn needs_input_wash(&self) -> Color {
        self.yellow.with_alpha(0.10)
    }

    /// Pane-header wash for ERROR.
    pub fn error_wash(&self) -> Color {
        self.danger.with_alpha(0.10)
    }

    /// Added-line wash. Paper uses a chromatic green because success @ 12 % reads gray on
    /// paper.
    pub fn diff_add(&self) -> Color {
        self.diff_add_tint().with_alpha(0.16)
    }

    pub fn diff_add_word(&self) -> Color {
        self.diff_add_tint().with_alpha(if self.is_light() { 0.30 } else { 0.28 })
    }

    pub fn diff_delete(&self) -> Color {
        self.danger.with_alpha(0.10)
    }

    pub fn diff_delete_word(&self) -> Color {
        self.danger.with_alpha(0.22)
    }

    pub fn diff_filler(&self) -> Color {
        self.text_primary.with_alpha(0.03)
    }

    fn diff_add_tint(&self) -> Color {
        if self.is_light() { Color::hex(0x5f8f3a) } else { self.success }
    }

    /// Syntax colors (no accent; keywords are bold ink).
    pub fn syntax(&self) -> SyntaxColors {
        SyntaxColors {
            keyword: self.text_primary,
            type_name: self.cyan,
            string: self.success,
            comment: self.text_muted,
            number: self.yellow,
            function: self.blue,
            attribute: self.yellow,
            plain: self.text_primary,
        }
    }

    /// Project monogram tints, picked per project name ([`crate::project_color_index`]).
    pub fn project_icon_colors(&self) -> [Color; 7] {
        [self.blue, self.success, self.yellow, self.cyan, self.accent, self.danger, self.gray]
    }
}

/// Code syntax colors (`ThemeColors.syntax*`): keywords are bold ink.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SyntaxColors {
    pub keyword: Color,
    pub type_name: Color,
    pub string: Color,
    pub comment: Color,
    pub number: Color,
    pub function: Color,
    pub attribute: Color,
    pub plain: Color,
}

impl TerminalColors {
    /// Faint (dim) text: 66 % of the foreground over the background.
    pub const FAINT_OPACITY: f64 = 0.66;

    /// The 21 colors in Ghostty's order: background, foreground, cursor, cursor text,
    /// selection, then the 16 ANSI colors.
    fn all(&self) -> [Color; 21] {
        let mut colors = [Color::BLACK; 21];
        colors[..5].copy_from_slice(&[
            self.background,
            self.foreground,
            self.cursor,
            self.cursor_accent,
            self.selection_background,
        ]);
        colors[5..].copy_from_slice(&self.ansi);
        colors
    }

    /// The Ghostty configuration override for this palette (22 lines), so the terminal
    /// renderer cannot drift from the theme.
    pub fn ghostty_configuration(&self) -> String {
        let hex: Vec<String> = self.all().iter().map(|c| ghostty_hex(*c)).collect();
        let mut lines = vec![
            format!("background = {}", hex[0]),
            format!("foreground = {}", hex[1]),
            format!("cursor-color = {}", hex[2]),
            format!("cursor-text = {}", hex[3]),
            format!("selection-background = {}", hex[4]),
            format!("faint-opacity = {}", Self::FAINT_OPACITY),
        ];
        lines.extend(hex[5..].iter().enumerate().map(|(index, hex)| format!("palette = {index}={hex}")));
        lines.join("\n")
    }

    /// Layered on [`Self::ghostty_configuration`] for a surface without keyboard focus:
    /// the hollow cursor is the foreground at 55 % over the background, never the accent.
    pub fn ghostty_unfocused_configuration(&self) -> String {
        format!("cursor-color = {}", ghostty_hex(self.unfocused_cursor()))
    }

    /// The hollow cursor's 1 px outline: fg @ 55 %, opaque because Ghostty draws unfocused
    /// cursors at full opacity.
    pub fn unfocused_cursor(&self) -> Color {
        self.background.mix(self.foreground, 0.55)
    }
}

/// `rrggbb` without `#` and without alpha, as Ghostty reads it.
fn ghostty_hex(color: Color) -> String {
    format!("{:02x}{:02x}{:02x}", color.r, color.g, color.b)
}

const fn c(rgb: u32) -> Color {
    Color::hex(rgb)
}

/// The default theme id. Not a palette of its own: it resolves to Folio Paper or Folio Ink
/// from the effective appearance.
pub const FOLIO_ID: &str = "folio";

/// Folio Paper.
pub static FOLIO_PAPER: AppTheme = AppTheme {
    id: "folio-paper",
    name: "Folio Paper",
    colors: ThemeColors {
        bg_base: c(0xf6f2ea),
        bg_panel: c(0xede7db),
        bg_raised: c(0xfcfaf5),
        bg_overlay: c(0xe5dece),
        text_primary: c(0x2b2620),
        text_muted: c(0x62594d),
        accent: c(0xa34a17),
        accent_strong: c(0x863a0f),
        border_subtle: c(0xe0d8c9),
        border_strong: c(0xcbc0ad),
        success: c(0x456b30),
        danger: c(0xae2f3c),
        blue: c(0x2f5f8a),
        cyan: c(0x266b66),
        yellow: c(0x835f0b),
        gray: c(0x857c6e),
        appearance: Appearance::Light,
    },
    terminal: TerminalColors {
        background: c(0xf6f2ea),
        foreground: c(0x2b2620),
        cursor: c(0xa34a17),
        cursor_accent: c(0xf6f2ea),
        selection_background: c(0xe4cdbc),
        ansi: [
            c(0x2b2620),
            c(0xae2f3c),
            c(0x456b30),
            c(0x835f0b),
            c(0x2f5f8a),
            c(0x8a3f78),
            c(0x266b66),
            c(0x6f665a),
            c(0x5a5248),
            c(0xc0414a),
            c(0x557f3b),
            c(0x9a7212),
            c(0x3d72a3),
            c(0xa04f8d),
            c(0x2f817b),
            c(0x8f8678),
        ],
    },
};

/// Folio Ink.
pub static FOLIO_INK: AppTheme = AppTheme {
    id: "folio-ink",
    name: "Folio Ink",
    colors: ThemeColors {
        bg_base: c(0x1d1b18),
        bg_panel: c(0x181613),
        bg_raised: c(0x26231f),
        bg_overlay: c(0x2f2b26),
        text_primary: c(0xe2dacb),
        text_muted: c(0xa0968a),
        accent: c(0xe08a52),
        accent_strong: c(0xf0a774),
        border_subtle: c(0x322e29),
        border_strong: c(0x443e37),
        success: c(0x97ae76),
        danger: c(0xe0707a),
        blue: c(0x86a6cb),
        cyan: c(0x74b3a9),
        yellow: c(0xd6aa4f),
        gray: c(0x776f64),
        appearance: Appearance::Dark,
    },
    terminal: TerminalColors {
        background: c(0x1d1b18),
        foreground: c(0xe2dacb),
        cursor: c(0xe08a52),
        cursor_accent: c(0x1d1b18),
        selection_background: c(0x483325),
        ansi: [
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
    },
};

/// Gruvbox Dark.
pub static GRUVBOX_DARK: AppTheme = AppTheme {
    id: "gruvbox-dark",
    name: "Gruvbox Dark",
    colors: ThemeColors {
        bg_base: c(0x282828),
        bg_panel: c(0x1d2021),
        bg_raised: c(0x1d2021),
        bg_overlay: c(0x3c3836),
        text_primary: c(0xebdbb2),
        text_muted: c(0xa89984),
        accent: c(0xfe8019),
        accent_strong: c(0xfabd2f),
        border_subtle: c(0x3c3836),
        border_strong: c(0x504945),
        success: c(0xb8bb26),
        danger: c(0xfb4934),
        blue: c(0x83a598),
        cyan: c(0x8ec07c),
        yellow: c(0xfabd2f),
        gray: c(0x665c54),
        appearance: Appearance::Dark,
    },
    terminal: TerminalColors {
        background: c(0x282828),
        foreground: c(0xebdbb2),
        cursor: c(0xebdbb2),
        cursor_accent: c(0x282828),
        selection_background: Color::rgba(0x50, 0x49, 0x45, 153),
        ansi: [
            c(0x282828),
            c(0xcc241d),
            c(0x98971a),
            c(0xd79921),
            c(0x458588),
            c(0xb16286),
            c(0x689d6a),
            c(0xa89984),
            c(0x928374),
            c(0xfb4934),
            c(0xb8bb26),
            c(0xfabd2f),
            c(0x83a598),
            c(0xd3869b),
            c(0x8ec07c),
            c(0xebdbb2),
        ],
    },
};

/// Catppuccin Mocha.
pub static CATPPUCCIN_MOCHA: AppTheme = AppTheme {
    id: "catppuccin-mocha",
    name: "Catppuccin Mocha",
    colors: ThemeColors {
        bg_base: c(0x1e1e2e),
        bg_panel: c(0x181825),
        bg_raised: c(0x11111b),
        bg_overlay: c(0x313244),
        text_primary: c(0xcdd6f4),
        text_muted: c(0xa6adc8),
        accent: c(0xcba6f7),
        accent_strong: c(0xf5c2e7),
        border_subtle: c(0x313244),
        border_strong: c(0x45475a),
        success: c(0xa6e3a1),
        danger: c(0xf38ba8),
        blue: c(0x89b4fa),
        cyan: c(0x94e2d5),
        yellow: c(0xf9e2af),
        gray: c(0x45475a),
        appearance: Appearance::Dark,
    },
    terminal: TerminalColors {
        background: c(0x1e1e2e),
        foreground: c(0xcdd6f4),
        cursor: c(0xf5e0dc),
        cursor_accent: c(0x1e1e2e),
        selection_background: Color::rgba(0x45, 0x47, 0x5a, 153),
        ansi: [
            c(0x45475a),
            c(0xf38ba8),
            c(0xa6e3a1),
            c(0xf9e2af),
            c(0x89b4fa),
            c(0xcba6f7),
            c(0x94e2d5),
            c(0xbac2de),
            c(0x585b70),
            c(0xf38ba8),
            c(0xa6e3a1),
            c(0xf9e2af),
            c(0x89b4fa),
            c(0xcba6f7),
            c(0x94e2d5),
            c(0xa6adc8),
        ],
    },
};

/// Dracula.
pub static DRACULA: AppTheme = AppTheme {
    id: "dracula",
    name: "Dracula",
    colors: ThemeColors {
        bg_base: c(0x282a36),
        bg_panel: c(0x21222c),
        bg_raised: c(0x343746),
        bg_overlay: c(0x44475a),
        text_primary: c(0xf8f8f2),
        text_muted: c(0x6272a4),
        accent: c(0xbd93f9),
        accent_strong: c(0xff79c6),
        border_subtle: c(0x44475a),
        border_strong: c(0x6272a4),
        success: c(0x50fa7b),
        danger: c(0xff5555),
        blue: c(0xbd93f9),
        cyan: c(0x8be9fd),
        yellow: c(0xf1fa8c),
        gray: c(0x6272a4),
        appearance: Appearance::Dark,
    },
    terminal: TerminalColors {
        background: c(0x282a36),
        foreground: c(0xf8f8f2),
        cursor: c(0xf8f8f2),
        cursor_accent: c(0x282a36),
        selection_background: c(0x44475a),
        ansi: [
            c(0x21222c),
            c(0xff5555),
            c(0x50fa7b),
            c(0xf1fa8c),
            c(0xbd93f9),
            c(0xff79c6),
            c(0x8be9fd),
            c(0xf8f8f2),
            c(0x6272a4),
            c(0xff6e6e),
            c(0x69ff94),
            c(0xffffa5),
            c(0xd6acff),
            c(0xff92df),
            c(0xa4ffff),
            c(0xffffff),
        ],
    },
};

/// Solarized Dark.
pub static SOLARIZED_DARK: AppTheme = AppTheme {
    id: "solarized-dark",
    name: "Solarized Dark",
    colors: ThemeColors {
        bg_base: c(0x002b36),
        bg_panel: c(0x073642),
        bg_raised: c(0x073642),
        bg_overlay: c(0x586e75),
        text_primary: c(0x93a1a1),
        text_muted: c(0x657b83),
        accent: c(0x268bd2),
        accent_strong: c(0x6c71c4),
        border_subtle: c(0x073642),
        border_strong: c(0x586e75),
        success: c(0x859900),
        danger: c(0xdc322f),
        blue: c(0x268bd2),
        cyan: c(0x2aa198),
        yellow: c(0xb58900),
        gray: c(0x586e75),
        appearance: Appearance::Dark,
    },
    terminal: TerminalColors {
        background: c(0x002b36),
        foreground: c(0x839496),
        cursor: c(0x839496),
        cursor_accent: c(0x073642),
        selection_background: c(0x073642),
        ansi: [
            c(0x073642),
            c(0xdc322f),
            c(0x859900),
            c(0xb58900),
            c(0x268bd2),
            c(0xd33682),
            c(0x2aa198),
            c(0xeee8d5),
            c(0x335e69),
            c(0xcb4b16),
            c(0x586e75),
            c(0x657b83),
            c(0x839496),
            c(0x6c71c4),
            c(0x93a1a1),
            c(0xfdf6e3),
        ],
    },
};

/// Nord.
pub static NORD: AppTheme = AppTheme {
    id: "nord",
    name: "Nord",
    colors: ThemeColors {
        bg_base: c(0x2e3440),
        bg_panel: c(0x3b4252),
        bg_raised: c(0x434c5e),
        bg_overlay: c(0x4c566a),
        text_primary: c(0xeceff4),
        text_muted: c(0x81a1c1),
        accent: c(0x88c0d0),
        accent_strong: c(0x8fbcbb),
        border_subtle: c(0x434c5e),
        border_strong: c(0x4c566a),
        success: c(0xa3be8c),
        danger: c(0xbf616a),
        blue: c(0x81a1c1),
        cyan: c(0x88c0d0),
        yellow: c(0xebcb8b),
        gray: c(0x4c566a),
        appearance: Appearance::Dark,
    },
    terminal: TerminalColors {
        background: c(0x2e3440),
        foreground: c(0xd8dee9),
        cursor: c(0xeceff4),
        cursor_accent: c(0x282828),
        selection_background: c(0xeceff4),
        ansi: [
            c(0x3b4252),
            c(0xbf616a),
            c(0xa3be8c),
            c(0xebcb8b),
            c(0x81a1c1),
            c(0xb48ead),
            c(0x88c0d0),
            c(0xe5e9f0),
            c(0x596377),
            c(0xbf616a),
            c(0xa3be8c),
            c(0xebcb8b),
            c(0x81a1c1),
            c(0xb48ead),
            c(0x8fbcbb),
            c(0xeceff4),
        ],
    },
};

/// Tokyo Night.
pub static TOKYO_NIGHT: AppTheme = AppTheme {
    id: "tokyo-night",
    name: "Tokyo Night",
    colors: ThemeColors {
        bg_base: c(0x1a1b26),
        bg_panel: c(0x15161e),
        bg_raised: c(0x24283b),
        bg_overlay: c(0x292e42),
        text_primary: c(0xc0caf5),
        text_muted: c(0x565f89),
        accent: c(0x7aa2f7),
        accent_strong: c(0xbb9af7),
        border_subtle: c(0x292e42),
        border_strong: c(0x414868),
        success: c(0x9ece6a),
        danger: c(0xf7768e),
        blue: c(0x7aa2f7),
        cyan: c(0x7dcfff),
        yellow: c(0xe0af68),
        gray: c(0x414868),
        appearance: Appearance::Dark,
    },
    terminal: TerminalColors {
        background: c(0x1a1b26),
        foreground: c(0xc0caf5),
        cursor: c(0xc0caf5),
        cursor_accent: c(0x15161e),
        selection_background: c(0x33467c),
        ansi: [
            c(0x15161e),
            c(0xf7768e),
            c(0x9ece6a),
            c(0xe0af68),
            c(0x7aa2f7),
            c(0xbb9af7),
            c(0x7dcfff),
            c(0xa9b1d6),
            c(0x414868),
            c(0xf7768e),
            c(0x9ece6a),
            c(0xe0af68),
            c(0x7aa2f7),
            c(0xbb9af7),
            c(0x7dcfff),
            c(0xc0caf5),
        ],
    },
};

/// Atom One Dark.
pub static ATOM_ONE_DARK: AppTheme = AppTheme {
    id: "atom-one-dark",
    name: "Atom One Dark",
    colors: ThemeColors {
        bg_base: c(0x21252b),
        bg_panel: c(0x1b1f23),
        bg_raised: c(0x282c34),
        bg_overlay: c(0x323844),
        text_primary: c(0xabb2bf),
        text_muted: c(0x5c6370),
        accent: c(0x61afef),
        accent_strong: c(0xc678dd),
        border_subtle: c(0x323844),
        border_strong: c(0x4b5263),
        success: c(0x98c379),
        danger: c(0xe06c75),
        blue: c(0x61afef),
        cyan: c(0x56b6c2),
        yellow: c(0xe5c07b),
        gray: c(0x5c6370),
        appearance: Appearance::Dark,
    },
    terminal: TerminalColors {
        background: c(0x21252b),
        foreground: c(0xabb2bf),
        cursor: c(0xabb2bf),
        cursor_accent: c(0x21252b),
        selection_background: c(0x323844),
        ansi: [
            c(0x21252b),
            c(0xe06c75),
            c(0x98c379),
            c(0xe5c07b),
            c(0x61afef),
            c(0xc678dd),
            c(0x56b6c2),
            c(0xabb2bf),
            c(0x767676),
            c(0xe06c75),
            c(0x98c379),
            c(0xe5c07b),
            c(0x61afef),
            c(0xc678dd),
            c(0x56b6c2),
            c(0xabb2bf),
        ],
    },
};

/// Every concrete palette, in picker order. `folio` is not listed: it resolves to one of the
/// first two.
pub static ALL_THEMES: [&AppTheme; 9] = [
    &FOLIO_PAPER,
    &FOLIO_INK,
    &GRUVBOX_DARK,
    &CATPPUCCIN_MOCHA,
    &DRACULA,
    &SOLARIZED_DARK,
    &NORD,
    &TOKYO_NIGHT,
    &ATOM_ONE_DARK,
];

/// One entry of the theme picker and the `theme` key's allowed values.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ThemeOption {
    pub id: &'static str,
    pub name: &'static str,
}

/// Every id `settings.json` accepts, in picker order: Folio (following the appearance), then
/// each concrete palette.
pub fn theme_options() -> Vec<ThemeOption> {
    std::iter::once(ThemeOption { id: FOLIO_ID, name: "Folio" })
        .chain(ALL_THEMES.iter().map(|theme| ThemeOption { id: theme.id, name: theme.name }))
        .collect()
}

pub fn is_known_theme_id(id: &str) -> bool {
    id == FOLIO_ID || ALL_THEMES.iter().any(|theme| theme.id == id)
}

/// The palette for `id`. `folio`, and any unknown id, resolves to Folio Paper or Folio Ink
/// from `appearance`.
pub fn theme_for(id: &str, appearance: Appearance) -> &'static AppTheme {
    ALL_THEMES.iter().copied().find(|theme| theme.id == id).unwrap_or(match appearance {
        Appearance::Light => &FOLIO_PAPER,
        Appearance::Dark => &FOLIO_INK,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_built_in_theme_catalog_leads_with_folio_paper_and_ink_and_keeps_the_third_party_ids() {
        let ids: Vec<&str> = ALL_THEMES.iter().map(|theme| theme.id).collect();
        assert_eq!(
            ids,
            [
                "folio-paper",
                "folio-ink",
                "gruvbox-dark",
                "catppuccin-mocha",
                "dracula",
                "solarized-dark",
                "nord",
                "tokyo-night",
                "atom-one-dark",
            ]
        );
        let options = theme_options();
        assert_eq!(options[0].id, "folio");
        assert_eq!(options[1..].iter().map(|o| o.id).collect::<Vec<_>>(), ids);
    }

    #[test]
    fn folio_resolves_to_paper_when_light_and_ink_when_dark() {
        assert_eq!(theme_for("folio", Appearance::Light).id, "folio-paper");
        assert_eq!(theme_for("folio", Appearance::Dark).id, "folio-ink");
        assert_eq!(theme_for("folio-ink", Appearance::Light).id, "folio-ink");
        assert_eq!(theme_for("mission-control", Appearance::Light).id, "folio-paper");
    }

    #[test]
    fn only_folio_paper_is_light() {
        let light: Vec<&str> =
            ALL_THEMES.iter().filter(|t| t.appearance() == Appearance::Light).map(|t| t.id).collect();
        assert_eq!(light, ["folio-paper"]);
    }

    #[test]
    fn every_app_theme_produces_a_complete_ghostty_terminal_palette() {
        for theme in ALL_THEMES {
            let config = theme.terminal.ghostty_configuration();
            let lines: Vec<&str> = config.split('\n').collect();
            assert_eq!(lines.len(), 22, "{}", theme.id);
            for prefix in [
                "background = ",
                "foreground = ",
                "cursor-color = ",
                "cursor-text = ",
                "selection-background = ",
            ] {
                assert!(lines.iter().any(|l| l.starts_with(prefix)), "{} lacks {prefix}", theme.id);
            }
            assert!(lines.contains(&"faint-opacity = 0.66"));
            for index in 0..16 {
                let prefix = format!("palette = {index}=");
                assert!(lines.iter().any(|l| l.starts_with(&prefix)), "{} lacks {prefix}", theme.id);
            }
        }
    }

    #[test]
    fn unfocused_surfaces_draw_their_hollow_cursor_in_the_foreground_at_55_percent_never_the_accent() {
        for theme in ALL_THEMES {
            let terminal = theme.terminal;
            let config = terminal.ghostty_unfocused_configuration();
            assert_eq!(config.split('\n').count(), 1);
            assert!(config.starts_with("cursor-color = "));
            assert!(!terminal.ghostty_configuration().contains(&config), "{}", theme.id);
            assert!(lab_distance(terminal.unfocused_cursor(), theme.colors.accent) > 10.0, "{}", theme.id);
            assert_eq!(terminal.unfocused_cursor(), terminal.background.mix(terminal.foreground, 0.55));
        }
    }

    #[test]
    fn folio_terminal_palettes_match_the_tokens() {
        let paper = FOLIO_PAPER.terminal.ghostty_configuration();
        assert!(paper.contains("background = f6f2ea"));
        assert!(paper.contains("cursor-color = a34a17"));
        assert!(paper.contains("selection-background = e4cdbc"));
        assert!(paper.contains("palette = 7=6f665a"));
        let ink = FOLIO_INK.terminal.ghostty_configuration();
        assert!(ink.contains("background = 1d1b18"));
        assert!(ink.contains("cursor-color = e08a52"));
        assert!(ink.contains("palette = 15=f4efe5"));
    }

    #[test]
    fn built_in_terminal_themes_use_their_declared_background_colors() {
        for (theme, background) in [
            (&GRUVBOX_DARK, "282828"),
            (&CATPPUCCIN_MOCHA, "1e1e2e"),
            (&DRACULA, "282a36"),
            (&SOLARIZED_DARK, "002b36"),
            (&NORD, "2e3440"),
            (&TOKYO_NIGHT, "1a1b26"),
            (&ATOM_ONE_DARK, "21252b"),
        ] {
            assert!(theme.terminal.ghostty_configuration().contains(&format!("background = {background}")));
        }
    }

    #[test]
    fn translucent_selections_keep_their_alpha_but_ghostty_reads_only_rgb() {
        assert_eq!(GRUVBOX_DARK.terminal.selection_background.a, 153);
        assert!(GRUVBOX_DARK.terminal.ghostty_configuration().contains("selection-background = 504945"));
    }

    #[test]
    fn themes_whose_raised_equals_their_panel_mix_in_ink() {
        assert_eq!(
            GRUVBOX_DARK.colors.raised(),
            GRUVBOX_DARK.colors.bg_panel.mix(GRUVBOX_DARK.colors.text_primary, 0.05)
        );
        assert_eq!(DRACULA.colors.raised(), DRACULA.colors.bg_raised);
    }

    #[test]
    fn attention_avoids_the_hue_of_the_focus_color() {
        // Tokyo Night's accent is its blue: attention turns yellow.
        assert_eq!(TOKYO_NIGHT.colors.attention(), TOKYO_NIGHT.colors.yellow);
        // Folio's sienna accent leaves attention blue.
        assert_eq!(FOLIO_PAPER.colors.attention(), FOLIO_PAPER.colors.blue);
    }

    #[test]
    fn every_theme_has_eight_pairwise_distinct_graph_lanes_that_avoid_the_accent() {
        for theme in ALL_THEMES {
            let lanes = theme.graph_lanes();
            assert_eq!(lanes.len(), GRAPH_LANE_COUNT, "{}", theme.id);
            assert_eq!(lanes[0], theme.colors.text_muted);
            for (i, a) in lanes.iter().enumerate() {
                if i > 0 {
                    assert!(lab_distance(*a, theme.colors.accent) >= MINIMUM_LANE_DISTANCE, "{}", theme.id);
                }
                for b in &lanes[i + 1..] {
                    assert!(lab_distance(*a, *b) >= MINIMUM_LANE_DISTANCE, "{}", theme.id);
                }
            }
        }
    }

    #[test]
    fn the_appearance_preference_resolves_against_the_system() {
        assert_eq!(AppearancePreference::System.resolve(Appearance::Dark), Appearance::Dark);
        assert_eq!(AppearancePreference::Light.resolve(Appearance::Dark), Appearance::Light);
        assert_eq!(AppearancePreference::Dark.resolve(Appearance::Light), Appearance::Dark);
        assert_eq!(AppearancePreference::parse("light"), Some(AppearancePreference::Light));
        assert_eq!(AppearancePreference::parse("auto"), None);
    }
}
