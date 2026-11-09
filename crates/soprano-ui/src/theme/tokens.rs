//! The color tokens every widget paints with: Herdr's token set derived from a theme's terminal
//! palette (HERDR-UI.md §2.1, `settings.rs` `resolve`), plus Soprano's semantic colors (status
//! tones and lamps, attention, diff and syntax) taken from the theme's own slots.

use gpui::Hsla;
use soprano_types::{AgentStatus, Color};

use super::palettes::{AppTheme, Appearance, TerminalColors};
use crate::color::{hsla, is_light_background};

/// Herdr's tokens for one terminal palette, in 8-bit sRGB (alpha tokens carry their alpha).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HerdrColors {
    pub is_light: bool,
    /// Terminal and card background.
    pub background: Color,
    /// Same as `background`.
    pub surface: Color,
    /// Behind cards (work-body gaps).
    pub canvas: Color,
    /// Sidebar, tab row, status bar.
    pub chrome: Color,
    /// Menus, dialogs, toasts.
    pub popover: Color,
    /// Active tab pill, keycaps, secondary buttons.
    pub raised: Color,
    pub hover: Color,
    pub selected: Color,
    pub border: Color,
    /// Input and secondary-button borders, tree lines.
    pub input: Color,
    /// UI primary text (not the terminal foreground).
    pub foreground: Color,
    /// Secondary text.
    pub muted: Color,
    /// Tertiary text and icons.
    pub dim: Color,
    pub idle: Color,
    /// Focus ring, input focus, fuzzy hits.
    pub accent: Color,
    pub accent_foreground: Color,
    /// Primary button fill.
    pub solid: Color,
    pub solid_foreground: Color,
    pub ring: Color,
    pub selection: Color,
    pub cursor: Color,
    pub terminal_foreground: Color,
    pub ansi: [Color; 16],
}

impl HerdrColors {
    /// Herdr's derivation (`settings.rs` `resolve`) over a terminal palette.
    pub fn derive(palette: &TerminalColors) -> Self {
        let bg = palette.background.with_alpha(1.0);
        let light = is_light_background(bg);
        let fg = if light { Color::hex(0x1b1b1e) } else { Color::hex(0xeeeeef) };
        let warm = Color::hex(0xe8e8e2);
        let (popover, raised, hover, selected, border, input, canvas, chrome) = if light {
            (
                bg,
                bg.mix(Color::BLACK, 0.035),
                Color::rgba(0, 0, 0, 0x0c),
                Color::rgba(0, 0, 0, 0x12),
                Color::rgba(0, 0, 0, 0x17),
                Color::rgba(0, 0, 0, 0x26),
                bg.mix(warm, 0.2),
                bg.mix(warm, 0.6),
            )
        } else {
            (
                bg.mix(Color::WHITE, 0.06),
                bg.mix(Color::WHITE, 0.09),
                Color::rgba(0xff, 0xff, 0xff, 0x0e),
                Color::rgba(0xff, 0xff, 0xff, 0x17),
                Color::rgba(0xff, 0xff, 0xff, 0x18),
                Color::rgba(0xff, 0xff, 0xff, 0x24),
                bg.mix(Color::BLACK, 0.16),
                bg.mix(Color::BLACK, 0.32),
            )
        };
        Self {
            is_light: light,
            background: bg,
            surface: bg,
            canvas,
            chrome,
            popover,
            raised,
            hover,
            selected,
            border,
            input,
            foreground: fg,
            muted: bg.mix(fg, if light { 0.66 } else { 0.6 }),
            dim: bg.mix(fg, if light { 0.46 } else { 0.38 }),
            idle: bg.mix(fg, 0.38),
            accent: palette.ansi[4],
            accent_foreground: bg,
            solid: fg,
            solid_foreground: if light { Color::WHITE } else { bg.mix(Color::BLACK, 0.28) },
            ring: bg.mix(fg, 0.7),
            selection: palette.selection_background,
            cursor: palette.cursor,
            terminal_foreground: palette.foreground,
            ansi: palette.ansi,
        }
    }
}

/// The status tone of a pill or badge (`ThreadStatusTone`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum StatusTone {
    Working,
    Approval,
    Input,
    Failed,
    Done,
    Muted,
}

/// A Folio status lamp (`ChromeStatus`): the agent and pane states and their colors.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Lamp {
    Starting,
    Working,
    /// A shell running a command.
    Running,
    Ready,
    NeedsInput,
    Error,
    Stopped,
    /// An idle shell.
    Idle,
}

impl Lamp {
    /// The lamp of an agent in `status`.
    pub fn for_agent(status: AgentStatus) -> Self {
        match status {
            AgentStatus::Idle => Self::Ready,
            AgentStatus::Starting => Self::Starting,
            AgentStatus::Running => Self::Working,
            AgentStatus::Waiting => Self::NeedsInput,
            AgentStatus::Error => Self::Error,
            AgentStatus::Stopped => Self::Stopped,
        }
    }

    /// The UPPERCASE label word; idle shells carry none.
    pub fn label(self) -> &'static str {
        match self {
            Self::Starting => "STARTING",
            Self::Working => "WORKING",
            Self::Running => "RUNNING",
            Self::Ready => "READY",
            Self::NeedsInput => "NEEDS INPUT",
            Self::Error => "ERROR",
            Self::Stopped => "STOPPED",
            Self::Idle => "",
        }
    }
}

/// Soprano's semantic colors for a theme, in 8-bit sRGB.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SemanticColors {
    /// Pill tones (`Palette.color(for:)`): Working blue, Approval yellow, Input cyan,
    /// Failed red, Done green, Muted secondary text.
    pub working: Color,
    pub approval: Color,
    pub input: Color,
    pub failed: Color,
    pub done: Color,
    pub muted: Color,
    /// Lamp of a terminal running a command (cyan).
    pub running_command: Color,
    /// Lamp colors (`ChromeStatus`): Starting / Needs input yellow, Working green, Ready
    /// blue, Error red, Stopped gray, idle shell gray at 60 %.
    pub lamp_starting: Color,
    pub lamp_working: Color,
    pub lamp_ready: Color,
    pub lamp_error: Color,
    pub lamp_stopped: Color,
    pub lamp_idle: Color,
    /// A pane or row that wants you: blue, or yellow when the focus accent is blue.
    pub attention: Color,
    pub attention_wash: Color,
    pub attention_row_wash: Color,
    pub needs_input_wash: Color,
    pub error_wash: Color,
    pub diff_add: Color,
    pub diff_add_word: Color,
    pub diff_delete: Color,
    pub diff_delete_word: Color,
    pub diff_filler: Color,
    pub diff_add_foreground: Color,
    pub diff_delete_foreground: Color,
}

impl SemanticColors {
    /// `focus` is the accent the UI draws focus with (Herdr's `accent`), which attention
    /// must never share a hue with.
    pub fn derive(theme: &AppTheme, herdr: &HerdrColors) -> Self {
        let c = &theme.colors;
        let attention = c.attention_against(herdr.accent);
        Self {
            working: c.blue,
            approval: c.yellow,
            input: c.cyan,
            failed: c.danger,
            done: c.success,
            muted: herdr.muted,
            running_command: c.running_command(),
            lamp_starting: c.yellow,
            lamp_working: c.success,
            lamp_ready: c.blue,
            lamp_error: c.danger,
            lamp_stopped: c.gray,
            lamp_idle: c.idle_mark(),
            attention,
            attention_wash: attention.with_alpha(0.10),
            attention_row_wash: attention.with_alpha(0.06),
            needs_input_wash: c.needs_input_wash(),
            error_wash: c.error_wash(),
            diff_add: c.diff_add(),
            diff_add_word: c.diff_add_word(),
            diff_delete: c.diff_delete(),
            diff_delete_word: c.diff_delete_word(),
            diff_filler: c.diff_filler(),
            diff_add_foreground: c.success,
            diff_delete_foreground: c.danger,
        }
    }
}

/// Code syntax colors as GPUI colors.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SyntaxTokens {
    pub keyword: Hsla,
    pub type_name: Hsla,
    pub string: Hsla,
    pub comment: Hsla,
    pub number: Hsla,
    pub function: Hsla,
    pub attribute: Hsla,
    pub plain: Hsla,
}

/// Every color a widget paints with, as GPUI colors. Herdr's roles first, then Soprano's.
#[derive(Clone, Debug, PartialEq)]
pub struct Tokens {
    pub appearance: Appearance,
    pub background: Hsla,
    pub surface: Hsla,
    pub canvas: Hsla,
    pub chrome: Hsla,
    pub popover: Hsla,
    pub raised: Hsla,
    pub hover: Hsla,
    pub selected: Hsla,
    pub border: Hsla,
    pub input: Hsla,
    pub foreground: Hsla,
    pub muted: Hsla,
    pub dim: Hsla,
    pub idle: Hsla,
    pub accent: Hsla,
    pub accent_foreground: Hsla,
    pub solid: Hsla,
    pub solid_foreground: Hsla,
    pub ring: Hsla,
    pub selection: Hsla,
    pub cursor: Hsla,
    pub terminal_foreground: Hsla,
    pub ansi: [Hsla; 16],
    /// Fixed: the letter on an avatar.
    pub avatar_letter: Hsla,
    /// Fixed: the dialog backdrop, black at 35 %.
    pub backdrop: Hsla,
    /// Fixed: the Windows caption close button's hover fill.
    pub window_close_hover: Hsla,
    pub working: Hsla,
    pub approval: Hsla,
    pub input_tone: Hsla,
    pub failed: Hsla,
    pub done: Hsla,
    pub muted_tone: Hsla,
    pub running_command: Hsla,
    pub attention: Hsla,
    pub attention_wash: Hsla,
    pub attention_row_wash: Hsla,
    pub needs_input_wash: Hsla,
    pub error_wash: Hsla,
    pub diff_add: Hsla,
    pub diff_add_word: Hsla,
    pub diff_delete: Hsla,
    pub diff_delete_word: Hsla,
    pub diff_filler: Hsla,
    pub diff_add_foreground: Hsla,
    pub diff_delete_foreground: Hsla,
    pub syntax: SyntaxTokens,
    /// Project monogram tints (`Palette.projectIconColors`).
    pub project_colors: [Hsla; 7],
    /// Commit-graph lanes: graphite trunk then seven distinct hues.
    pub graph_lanes: std::rc::Rc<[Hsla]>,
    lamps: [Hsla; 8],
}

impl Tokens {
    pub fn new(theme: &AppTheme) -> Self {
        let herdr = HerdrColors::derive(&theme.terminal);
        let semantic = SemanticColors::derive(theme, &herdr);
        let syntax = theme.colors.syntax();
        Self {
            appearance: if herdr.is_light { Appearance::Light } else { Appearance::Dark },
            background: hsla(herdr.background),
            surface: hsla(herdr.surface),
            canvas: hsla(herdr.canvas),
            chrome: hsla(herdr.chrome),
            popover: hsla(herdr.popover),
            raised: hsla(herdr.raised),
            hover: hsla(herdr.hover),
            selected: hsla(herdr.selected),
            border: hsla(herdr.border),
            input: hsla(herdr.input),
            foreground: hsla(herdr.foreground),
            muted: hsla(herdr.muted),
            dim: hsla(herdr.dim),
            idle: hsla(herdr.idle),
            accent: hsla(herdr.accent),
            accent_foreground: hsla(herdr.accent_foreground),
            solid: hsla(herdr.solid),
            solid_foreground: hsla(herdr.solid_foreground),
            ring: hsla(herdr.ring),
            selection: hsla(herdr.selection),
            cursor: hsla(herdr.cursor),
            terminal_foreground: hsla(herdr.terminal_foreground),
            ansi: herdr.ansi.map(hsla),
            avatar_letter: hsla(Color::WHITE),
            backdrop: hsla(Color::BLACK.with_alpha(0.35)),
            window_close_hover: hsla(Color::hex(0xc42b1c)),
            working: hsla(semantic.working),
            approval: hsla(semantic.approval),
            input_tone: hsla(semantic.input),
            failed: hsla(semantic.failed),
            done: hsla(semantic.done),
            muted_tone: hsla(semantic.muted),
            running_command: hsla(semantic.running_command),
            attention: hsla(semantic.attention),
            attention_wash: hsla(semantic.attention_wash),
            attention_row_wash: hsla(semantic.attention_row_wash),
            needs_input_wash: hsla(semantic.needs_input_wash),
            error_wash: hsla(semantic.error_wash),
            diff_add: hsla(semantic.diff_add),
            diff_add_word: hsla(semantic.diff_add_word),
            diff_delete: hsla(semantic.diff_delete),
            diff_delete_word: hsla(semantic.diff_delete_word),
            diff_filler: hsla(semantic.diff_filler),
            diff_add_foreground: hsla(semantic.diff_add_foreground),
            diff_delete_foreground: hsla(semantic.diff_delete_foreground),
            syntax: SyntaxTokens {
                keyword: hsla(syntax.keyword),
                type_name: hsla(syntax.type_name),
                string: hsla(syntax.string),
                comment: hsla(syntax.comment),
                number: hsla(syntax.number),
                function: hsla(syntax.function),
                attribute: hsla(syntax.attribute),
                plain: hsla(syntax.plain),
            },
            project_colors: theme.colors.project_icon_colors().map(hsla),
            graph_lanes: theme.graph_lanes().into_iter().map(hsla).collect::<Vec<_>>().into(),
            lamps: [
                semantic.lamp_starting,
                semantic.lamp_working,
                semantic.running_command,
                semantic.lamp_ready,
                semantic.lamp_starting,
                semantic.lamp_error,
                semantic.lamp_stopped,
                semantic.lamp_idle,
            ]
            .map(hsla),
        }
    }

    /// The color of a pill or badge tone.
    pub fn tone(&self, tone: StatusTone) -> Hsla {
        match tone {
            StatusTone::Working => self.working,
            StatusTone::Approval => self.approval,
            StatusTone::Input => self.input_tone,
            StatusTone::Failed => self.failed,
            StatusTone::Done => self.done,
            StatusTone::Muted => self.muted_tone,
        }
    }

    /// The color of a status lamp.
    pub fn lamp(&self, lamp: Lamp) -> Hsla {
        self.lamps[lamp as usize]
    }

    pub fn is_dark(&self) -> bool {
        self.appearance.is_dark()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::theme::palettes::{ALL_THEMES, FOLIO_INK, FOLIO_PAPER, TOKYO_NIGHT};

    fn hex(c: Color) -> String {
        c.to_hex()
    }

    fn ansi(list: &str) -> [Color; 16] {
        let colors: Vec<Color> = list.split_whitespace().map(Color::from_hex).collect();
        colors.try_into().expect("16 colors")
    }

    /// Herdr's graphite preset, whose tokens HERDR-UI.md §2.2 tabulates.
    fn graphite() -> TerminalColors {
        let ansi = ansi(
            "#45484f #dc8c95 #a6bd91 #d8be87 #96b2d7 #b5a2ce #8cbdc3 #d2d4d9 \
             #818793 #f0a5ad #bad5a2 #ead2a1 #b0cbef #cbb7e6 #a4d5db #f0f0f2",
        );
        TerminalColors {
            background: Color::hex(0x17191d),
            foreground: Color::hex(0xd2d4d9),
            cursor: Color::hex(0xd2d4d9),
            cursor_accent: Color::hex(0x17191d),
            selection_background: Color::hex(0x394454),
            ansi,
        }
    }

    #[test]
    fn graphite_derives_the_dark_token_table() {
        let t = HerdrColors::derive(&graphite());
        assert!(!t.is_light);
        assert_eq!(hex(t.background), "#17191d");
        assert_eq!(hex(t.canvas), "#131518");
        assert_eq!(hex(t.chrome), "#101114");
        assert_eq!(hex(t.popover), "#25272b");
        assert_eq!(hex(t.raised), "#2c2e31");
        assert_eq!(hex(t.hover), "#ffffff0e");
        assert_eq!(hex(t.selected), "#ffffff17");
        assert_eq!(hex(t.border), "#ffffff18");
        assert_eq!(hex(t.input), "#ffffff24");
        assert_eq!(hex(t.foreground), "#eeeeef");
        assert_eq!(hex(t.muted), "#98999b");
        assert_eq!(hex(t.dim), "#696a6d");
        assert_eq!(hex(t.idle), "#696a6d");
        assert_eq!(hex(t.accent), "#96b2d7");
        assert_eq!(hex(t.accent_foreground), "#17191d");
        assert_eq!(hex(t.solid), "#eeeeef");
        assert_eq!(hex(t.solid_foreground), "#111215");
        assert_eq!(hex(t.selection), "#394454");
        assert_eq!(hex(t.cursor), "#d2d4d9");
        assert_eq!(hex(t.terminal_foreground), "#d2d4d9");
        // ±1 on red from rounding, as the spec notes.
        assert!(t.ring.r.abs_diff(0xae) <= 1 && t.ring.g == 0xae && t.ring.b == 0xb0);
    }

    #[test]
    fn paper_derives_the_light_token_table() {
        let paper = TerminalColors {
            background: Color::WHITE,
            foreground: Color::hex(0x25272c),
            cursor: Color::hex(0x25272c),
            cursor_accent: Color::WHITE,
            selection_background: Color::hex(0xcfdcf5),
            ansi: ansi(
                "#25272c #c62a2a #1a7f37 #8f5d00 #1f62d0 #7a45c8 #0f6f74 #5f6068 \
                 #7b7e87 #d1242f #1f883d #9a6700 #0969da #8250df #1b7c83 #111214",
            ),
        };
        let t = HerdrColors::derive(&paper);
        assert!(t.is_light);
        assert_eq!(hex(t.canvas), "#fafaf9");
        assert_eq!(hex(t.chrome), "#f1f1ee");
        assert_eq!(hex(t.popover), "#ffffff");
        assert_eq!(hex(t.raised), "#f6f6f6");
        assert_eq!(hex(t.hover), "#0000000c");
        assert_eq!(hex(t.border), "#00000017");
        assert_eq!(hex(t.foreground), "#1b1b1e");
        assert_eq!(hex(t.ring), "#5f5f62");
        assert_eq!(hex(t.accent), "#1f62d0");
        assert_eq!(hex(t.solid_foreground), "#ffffff");
        assert!(t.muted.r == 0x69 && t.muted.g == 0x69 && t.muted.b.abs_diff(0x6b) <= 1);
        assert!(t.dim.r == 0x96 && t.dim.g == 0x96 && t.dim.b.abs_diff(0x98) <= 1);
    }

    #[test]
    fn only_folio_paper_derives_light_tokens() {
        for theme in ALL_THEMES {
            assert_eq!(
                HerdrColors::derive(&theme.terminal).is_light,
                theme.id == "folio-paper",
                "{}",
                theme.id
            );
        }
    }

    #[test]
    fn surfaces_step_from_chrome_to_canvas_to_cards_on_dark_themes() {
        let t = HerdrColors::derive(&FOLIO_INK.terminal);
        let l = |c: Color| crate::color::relative_luminance(c);
        assert!(l(t.chrome) < l(t.canvas) && l(t.canvas) < l(t.background) && l(t.background) < l(t.raised));
    }

    #[test]
    fn status_tones_keep_sopranos_pill_colors() {
        let t = Tokens::new(&FOLIO_PAPER);
        let c = FOLIO_PAPER.colors;
        assert_eq!(t.tone(StatusTone::Working), hsla(c.blue));
        assert_eq!(t.tone(StatusTone::Approval), hsla(c.yellow));
        assert_eq!(t.tone(StatusTone::Input), hsla(c.cyan));
        assert_eq!(t.tone(StatusTone::Failed), hsla(c.danger));
        assert_eq!(t.tone(StatusTone::Done), hsla(c.success));
    }

    #[test]
    fn lamps_keep_the_folio_status_colors() {
        let t = Tokens::new(&FOLIO_INK);
        let c = FOLIO_INK.colors;
        assert_eq!(t.lamp(Lamp::Starting), hsla(c.yellow));
        assert_eq!(t.lamp(Lamp::NeedsInput), hsla(c.yellow));
        assert_eq!(t.lamp(Lamp::Working), hsla(c.success));
        assert_eq!(t.lamp(Lamp::Running), hsla(c.cyan));
        assert_eq!(t.lamp(Lamp::Ready), hsla(c.blue));
        assert_eq!(t.lamp(Lamp::Error), hsla(c.danger));
        assert_eq!(t.lamp(Lamp::Stopped), hsla(c.gray));
        assert_eq!(t.lamp(Lamp::Idle), hsla(c.gray.with_alpha(0.6)));
        assert_eq!(Lamp::for_agent(AgentStatus::Waiting), Lamp::NeedsInput);
        assert_eq!(Lamp::for_agent(AgentStatus::Idle).label(), "READY");
    }

    #[test]
    fn attention_never_shares_the_focus_accents_hue() {
        // Herdr's accent is ANSI blue, so attention turns yellow wherever ANSI blue is blue.
        let herdr = HerdrColors::derive(&TOKYO_NIGHT.terminal);
        let semantic = SemanticColors::derive(&TOKYO_NIGHT, &herdr);
        assert_eq!(semantic.attention, TOKYO_NIGHT.colors.yellow);
        for theme in ALL_THEMES {
            let herdr = HerdrColors::derive(&theme.terminal);
            let semantic = SemanticColors::derive(theme, &herdr);
            assert!(
                crate::color::hue_distance(semantic.attention, herdr.accent) >= 40.0
                    || semantic.attention == theme.colors.yellow,
                "{}",
                theme.id
            );
        }
    }
}
