//! An agent's terminal output in the theme's colors: the rendering half of
//! `AgentOutputHighlighter.swift`, whose rules live in `soprano_text::agent_output`.

use std::ops::Range;

use gpui::{FontWeight, HighlightStyle, Hsla, UnderlineStyle, px};
use soprano_text::agent_output::{self, OutputColor, OutputWeight};
use soprano_ui::SopranoTheme;
use soprano_ui::color::hsla;

/// The theme colors terminal output is drawn in. Nothing is drawn in the accent.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OutputPalette {
    pub text_primary: Hsla,
    pub text_muted: Hsla,
    pub cyan: Hsla,
    pub blue: Hsla,
    pub success: Hsla,
    pub danger: Hsla,
    pub yellow: Hsla,
    pub keyword: Hsla,
    pub string: Hsla,
    pub comment: Hsla,
    pub number: Hsla,
    pub type_name: Hsla,
    pub function: Hsla,
    pub attribute: Hsla,
    /// Behind inline code: the overlay surface at 55 %.
    pub code_background: Hsla,
}

impl OutputPalette {
    pub fn new(theme: &SopranoTheme) -> Self {
        let colors = &theme.theme().colors;
        let syntax = &theme.syntax;
        Self {
            text_primary: hsla(colors.text_primary),
            text_muted: hsla(colors.text_muted),
            cyan: hsla(colors.cyan),
            blue: hsla(colors.blue),
            success: hsla(colors.success),
            danger: hsla(colors.danger),
            yellow: hsla(colors.yellow),
            keyword: syntax.keyword,
            string: syntax.string,
            comment: syntax.comment,
            number: syntax.number,
            type_name: syntax.type_name,
            function: syntax.function,
            attribute: syntax.attribute,
            code_background: hsla(colors.bg_overlay).opacity(0.55),
        }
    }

    pub fn color(&self, color: OutputColor) -> Hsla {
        match color {
            OutputColor::TextPrimary => self.text_primary,
            OutputColor::TextMuted => self.text_muted,
            OutputColor::Cyan => self.cyan,
            OutputColor::Blue => self.blue,
            OutputColor::Success => self.success,
            OutputColor::Danger => self.danger,
            OutputColor::Yellow => self.yellow,
            OutputColor::SyntaxKeyword => self.keyword,
            OutputColor::SyntaxString => self.string,
            OutputColor::SyntaxComment => self.comment,
            OutputColor::SyntaxNumber => self.number,
            OutputColor::SyntaxType => self.type_name,
            OutputColor::SyntaxFunction => self.function,
            OutputColor::SyntaxAttribute => self.attribute,
        }
    }
}

/// The styled ranges that draw `text` (an agent's visible terminal text): every byte covered,
/// colors and weights from the highlighter's rules; regular runs keep the base weight.
pub fn output_highlights(text: &str, palette: &OutputPalette) -> Vec<(Range<usize>, HighlightStyle)> {
    agent_output::highlight(text)
        .into_iter()
        .map(|run| {
            let style = run.style;
            let color = palette.color(style.color);
            let font_weight = match style.weight {
                OutputWeight::Regular => None,
                OutputWeight::Semibold => Some(FontWeight::SEMIBOLD),
                OutputWeight::Bold => Some(FontWeight::BOLD),
            };
            let highlight = HighlightStyle {
                color: Some(color),
                font_weight,
                background_color: style.code_background.then_some(palette.code_background),
                underline: style.underline.then_some(UnderlineStyle {
                    thickness: px(1.),
                    color: Some(color),
                    wavy: false,
                }),
                ..HighlightStyle::default()
            };
            (run.range, highlight)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use gpui::hsla as color;

    use super::*;

    fn palette() -> OutputPalette {
        let tone = |hue: f32| color(hue, 0.5, 0.5, 1.0);
        OutputPalette {
            text_primary: tone(0.0),
            text_muted: tone(0.05),
            cyan: tone(0.1),
            blue: tone(0.15),
            success: tone(0.2),
            danger: tone(0.25),
            yellow: tone(0.3),
            keyword: tone(0.35),
            string: tone(0.4),
            comment: tone(0.45),
            number: tone(0.5),
            type_name: tone(0.55),
            function: tone(0.6),
            attribute: tone(0.65),
            code_background: tone(0.7),
        }
    }

    /// The highlight at the first occurrence of `needle`.
    fn highlight_at<'a>(
        text: &str,
        highlights: &'a [(Range<usize>, HighlightStyle)],
        needle: &str,
    ) -> &'a HighlightStyle {
        let offset = text.find(needle).expect("needle");
        highlights
            .iter()
            .find(|(range, _)| range.contains(&offset))
            .map(|(_, style)| style)
            .expect("highlight")
    }

    #[test]
    fn terminal_output_keeps_every_byte_and_colors_diagnostics_paths_and_results() {
        let source = "❯ Run swift test --filter AgentDashboard\n\
            • Updated Sources/Soprano/Views/AgentDashboardViewController.swift:842\n\
            warning: waiting for input\nerror: build failed\nAll 301 tests passed";
        let palette = palette();
        let highlights = output_highlights(source, &palette);
        assert_eq!(highlights.iter().map(|(range, _)| range.len()).sum::<usize>(), source.len());
        let color = |needle| highlight_at(source, &highlights, needle).color;
        assert_eq!(color("❯"), Some(palette.text_primary));
        assert_eq!(color("•"), Some(palette.text_muted));
        assert_eq!(color("Sources/Soprano/Views/AgentDashboardViewController.swift:842"), Some(palette.cyan));
        assert_eq!(color("--filter"), Some(palette.cyan));
        assert_eq!(color("warning"), Some(palette.yellow));
        assert_eq!(color("error"), Some(palette.danger));
        assert_eq!(color("passed"), Some(palette.success));
    }

    #[test]
    fn fenced_code_uses_the_syntax_colors_and_bold_keywords() {
        let source =
            "```swift\n@MainActor let count: Int = 42\nprint(\"ready\")\n// keep the exact text\n```";
        let palette = palette();
        let highlights = output_highlights(source, &palette);
        let style = |needle| highlight_at(source, &highlights, needle);
        assert_eq!(style("swift").color, Some(palette.text_primary));
        assert_eq!(style("let").color, Some(palette.keyword));
        assert_eq!(style("let").font_weight, Some(FontWeight::BOLD));
        assert_eq!(style("@MainActor").color, Some(palette.attribute));
        assert_eq!(style("Int").color, Some(palette.type_name));
        assert_eq!(style("42").color, Some(palette.number));
        assert_eq!(style("print").color, Some(palette.function));
        assert_eq!(style("\"ready\"").color, Some(palette.string));
        assert_eq!(style("// keep").color, Some(palette.comment));
    }

    #[test]
    fn a_unified_diff_colors_only_the_patch_instead_of_markdown_bullets() {
        let source = "- This is an ordinary agent bullet\n\ndiff --git a/App.swift b/App.swift\n--- a/App.swift\n\
            +++ b/App.swift\n@@ -1,2 +1,2 @@\n-let oldValue = false\n+let newValue = true";
        let palette = palette();
        let highlights = output_highlights(source, &palette);
        let color = |needle| highlight_at(source, &highlights, needle).color;
        assert_eq!(color("- This"), Some(palette.text_muted));
        assert_eq!(color("-let old"), Some(palette.danger));
        assert_eq!(color("+let new"), Some(palette.success));
        assert_eq!(color("@@"), Some(palette.cyan));
    }

    #[test]
    fn the_palette_maps_roles_onto_the_themes_colors_and_never_the_accent() {
        let theme = soprano_ui::SopranoTheme::new(soprano_ui::theme::ThemeManager::new(
            "gruvbox-dark",
            soprano_ui::AppearancePreference::Dark,
            soprano_ui::Appearance::Dark,
        ));
        let palette = OutputPalette::new(&theme);
        let colors = theme.theme().colors;
        assert_eq!(palette.color(OutputColor::Success), hsla(colors.success));
        assert_eq!(palette.color(OutputColor::Cyan), hsla(colors.cyan));
        assert_eq!(palette.color(OutputColor::SyntaxKeyword), theme.syntax.keyword);
        let accents = [hsla(colors.accent), hsla(colors.accent_strong)];
        let source = "# Summary\n❯ swift build\n- first point\n```swift\nstruct App { func run() {} }\n```";
        for (_, style) in output_highlights(source, &palette) {
            assert!(!accents.contains(&style.color.expect("color")));
        }
    }
}
