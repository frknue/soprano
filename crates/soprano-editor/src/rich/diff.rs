//! Diff rows (`SurfaceDiffRows.swift`, `InlineDiffDrawing.swift`): a stacked line or a split
//! old | new pair, each side with its tint (the number column tinted twice, as a gutter), a
//! 3 px change bar, its line number and the code with syntax colors and the changed words on
//! the word tint; a missing split side is a muted filler. Also the "N unmodified lines" fold
//! strip, the `+N -N` counts, and the chat's hunk diffs. Code is in the terminal font at 11 on
//! 20 px rows (Herdr's diff area).

use std::sync::Arc;

use gpui::{
    AnyElement, App, ClickEvent, CursorStyle, ElementId, FontStyle, FontWeight, HighlightStyle,
    InteractiveElement, IntoElement, ParentElement, Pixels, RenderOnce, SharedString,
    StatefulInteractiveElement, Styled, StyledText, Window, div, prelude::FluentBuilder, px,
};
use soprano_git::changes::GitDiffToken;
use soprano_text::diff::{
    BAR_WIDTH, CODE_INSET, CODE_TRAILING, DiffFold, DiffLineKind, DiffSide, FOLD_HEIGHT, LINE_HEIGHT,
    StyledLine,
};
use soprano_text::editor::{GUTTER_PADDING, number_column_width};
use soprano_text::hunks::{HunkLine, InlineDiff, InlineDiffLine};
use soprano_ui::fonts::{TERMINAL_FONT_FAMILY, size};
use soprano_ui::tooltip::tooltip;
use soprano_ui::{IconName, SopranoTheme, icon};

use crate::colors::SurfaceColors;

/// The code and line-number font size of diff rows.
pub const DIFF_FONT_SIZE: f32 = size::DIFF;

type ClickHandler = Arc<dyn Fn(&ClickEvent, &mut Window, &mut App)>;

fn zoom(cx: &App) -> f32 {
    cx.try_global::<SopranoTheme>().map_or(1.0, SopranoTheme::zoom)
}

/// Width of the line-number column for numbers up to `max_line`, in designed pixels: two
/// digits at least, 10 either side.
pub fn number_width(max_line: usize, window: &Window) -> f32 {
    number_column_width(max_line, digit_width(DIFF_FONT_SIZE, window))
}

/// Advance of one digit of the terminal font at `font_size` (designed pixels).
pub fn digit_width(font_size: f32, window: &Window) -> f32 {
    let style = window.text_style();
    let font = gpui::Font { family: TERMINAL_FONT_FAMILY.into(), ..style.font() };
    let run = gpui::TextRun {
        len: 1,
        font,
        color: style.color,
        background_color: None,
        underline: None,
        strikethrough: None,
    };
    let line = window.text_system().shape_line("0".into(), px(font_size), &[run], None);
    let width: f32 = line.width().into();
    if width > 0.0 { width } else { font_size * 0.6 }
}

/// A row side's text as highlights: syntax colors (keywords semibold, comments italic, the
/// editor/diff color map) and the changed words on the word tint.
pub fn styled_highlights(
    line: &StyledLine,
    kind: DiffLineKind,
    colors: &SurfaceColors,
) -> Vec<(std::ops::Range<usize>, HighlightStyle)> {
    let word = if kind == DiffLineKind::Added { colors.diff_add_word } else { colors.diff_delete_word };
    line.spans
        .iter()
        .map(|span| {
            let mut style = HighlightStyle::default();
            if let Some(kind) = span.syntax {
                style.color = Some(colors.code_syntax(kind));
                if kind.is_emphasized() {
                    style.font_weight = Some(FontWeight::SEMIBOLD);
                } else if kind.is_italic() {
                    style.font_style = Some(FontStyle::Italic);
                }
            }
            if span.emphasized {
                style.background_color = Some(word);
            }
            (span.range.clone(), style)
        })
        .collect()
}

/// How the rows lay out their code.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DiffRowLayout {
    /// Width of the line-number column (designed pixels).
    pub number_width: f32,
    /// Long lines wrap; otherwise they stay on one line, scrolled left by `text_offset`.
    pub wrap: bool,
    pub text_offset: f32,
}

impl Default for DiffRowLayout {
    fn default() -> Self {
        Self { number_width: 40.0, wrap: true, text_offset: 0.0 }
    }
}

/// One side of a row: tint, bar, number, then the code.
fn side(
    id: ElementId,
    side: Option<&DiffSide>,
    layout: DiffRowLayout,
    selected: bool,
    colors: &SurfaceColors,
    zoom: f32,
) -> AnyElement {
    let z = |value: f32| px(value * zoom);
    let Some(side) = side else {
        return div()
            .id(id)
            .flex_1()
            .min_w_0()
            .min_h(z(LINE_HEIGHT))
            .h_full()
            .bg(colors.wash(0.035, 0.025))
            .when(selected, |filler| filler.bg(colors.selection))
            .into_any_element();
    };
    let (tint, bar, number_color) = match side.kind {
        DiffLineKind::Added => (Some(colors.diff_add), Some(colors.success), colors.diff_add_foreground),
        DiffLineKind::Removed => {
            (Some(colors.diff_delete), Some(colors.error), colors.diff_delete_foreground)
        }
        DiffLineKind::Context | DiffLineKind::NoNewlineMarker => (None, None, colors.muted.opacity(0.75)),
    };
    let highlights = styled_highlights(&side.text, side.kind, colors);
    let mut text = StyledText::new(SharedString::from(side.text.text.clone()));
    if !highlights.is_empty() {
        text = text.with_highlights(highlights);
    }
    let text_color =
        if side.kind == DiffLineKind::NoNewlineMarker { colors.muted } else { colors.foreground };
    div()
        .id(id)
        .relative()
        .flex()
        .flex_row()
        .flex_1()
        .min_w_0()
        .min_h(z(LINE_HEIGHT))
        .when_some(tint, |row, tint| row.bg(tint))
        .child(
            div()
                .flex_shrink_0()
                .w(z(layout.number_width))
                .h(z(LINE_HEIGHT))
                .pr(z(GUTTER_PADDING))
                .flex()
                .flex_row()
                .items_center()
                .justify_end()
                .when_some(tint, |gutter, tint| gutter.bg(tint))
                .text_size(z(DIFF_FONT_SIZE))
                .text_color(number_color)
                .children(side.number.map(|number| number.to_string())),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .overflow_hidden()
                .pl(z(CODE_INSET))
                .pr(z(CODE_TRAILING))
                .text_size(z(DIFF_FONT_SIZE))
                .line_height(z(LINE_HEIGHT))
                .text_color(text_color)
                .map(|code| {
                    if layout.wrap {
                        code.child(text)
                    } else {
                        code.whitespace_nowrap().child(div().ml(-z(layout.text_offset)).child(text))
                    }
                }),
        )
        .when_some(bar, |row, bar| {
            row.child(div().absolute().left_0().top_0().bottom_0().w(z(BAR_WIDTH)).bg(bar))
        })
        .when(selected, |row| {
            row.child(div().absolute().left_0().top_0().right_0().bottom_0().bg(colors.selection))
        })
        .into_any_element()
}

/// A stacked diff line: one number column (old for deletions, new otherwise), then the code.
#[derive(IntoElement)]
pub struct DiffLineRow {
    id: ElementId,
    side: DiffSide,
    layout: DiffRowLayout,
    selected: bool,
}

impl DiffLineRow {
    pub fn new(id: impl Into<ElementId>, side: DiffSide, layout: DiffRowLayout) -> Self {
        Self { id: id.into(), side, layout, selected: false }
    }

    /// The line is in the list's selection: drawn under the selection tint.
    pub fn selected(mut self, selected: bool) -> Self {
        self.selected = selected;
        self
    }
}

impl RenderOnce for DiffLineRow {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let colors = SurfaceColors::of(cx);
        div().w_full().flex().flex_row().font_family(TERMINAL_FONT_FAMILY).child(side(
            self.id,
            Some(&self.side),
            self.layout,
            self.selected,
            &colors,
            zoom(cx),
        ))
    }
}

/// A split row: the old line left, the new line right, divided by a `border` hairline.
#[derive(IntoElement)]
pub struct DiffSplitRow {
    id: ElementId,
    old: Option<DiffSide>,
    new: Option<DiffSide>,
    layout: DiffRowLayout,
    selected_side: Option<bool>,
}

impl DiffSplitRow {
    pub fn new(
        id: impl Into<ElementId>,
        old: Option<DiffSide>,
        new: Option<DiffSide>,
        layout: DiffRowLayout,
    ) -> Self {
        Self { id: id.into(), old, new, layout, selected_side: None }
    }

    /// The selected side (true: old), `None` when the row is not selected. A filler side
    /// is never drawn selected.
    pub fn selected_side(mut self, side: Option<bool>) -> Self {
        self.selected_side = side;
        self
    }
}

impl RenderOnce for DiffSplitRow {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let colors = SurfaceColors::of(cx);
        let zoom = zoom(cx);
        let old_selected = self.selected_side == Some(true) && self.old.is_some();
        let new_selected = self.selected_side == Some(false) && self.new.is_some();
        div()
            .w_full()
            .flex()
            .flex_row()
            .font_family(TERMINAL_FONT_FAMILY)
            .child(side(
                ElementId::from((self.id.clone(), "old")),
                self.old.as_ref(),
                self.layout,
                old_selected,
                &colors,
                zoom,
            ))
            .child(div().flex_shrink_0().w(px(1.0)).bg(colors.border))
            .child(side(
                ElementId::from((self.id, "new")),
                self.new.as_ref(),
                self.layout,
                new_selected,
                &colors,
                zoom,
            ))
    }
}

/// The strip before a block of lines: "N unmodified lines" (or the `@@` range when nothing is
/// hidden) and the enclosing declaration on a muted strip; a click on a fold shows its lines.
#[derive(IntoElement)]
pub struct DiffFoldRow {
    id: ElementId,
    fold: DiffFold,
    number_width: f32,
    on_expand: Option<ClickHandler>,
}

impl DiffFoldRow {
    pub fn new(id: impl Into<ElementId>, fold: DiffFold, number_width: f32) -> Self {
        Self { id: id.into(), fold, number_width, on_expand: None }
    }

    pub fn on_expand(mut self, handler: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static) -> Self {
        self.on_expand = Some(Arc::new(handler));
        self
    }
}

/// The fold strip's lead: its range, or its hidden-line count.
pub fn fold_lead(fold: &DiffFold) -> String {
    fold.range.clone().or_else(|| fold.label()).unwrap_or_default()
}

impl RenderOnce for DiffFoldRow {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let colors = SurfaceColors::of(cx);
        let zoom = zoom(cx);
        let z = |value: f32| px(value * zoom);
        let expandable = self.fold.hidden_lines() > 0;
        let lead = fold_lead(&self.fold);
        let section = self.fold.section.trim().to_string();
        div()
            .id(self.id)
            .w_full()
            .h(z(FOLD_HEIGHT))
            .flex()
            .flex_row()
            .items_center()
            .bg(colors.wash(0.04, 0.03))
            .border_t_1()
            .border_b_1()
            .border_color(colors.border.opacity(0.6))
            .font_family(TERMINAL_FONT_FAMILY)
            .text_size(z(DIFF_FONT_SIZE))
            .child(
                div()
                    .flex_shrink_0()
                    .w(z(self.number_width))
                    .flex()
                    .justify_center()
                    .child(icon(IconName::ChevronsUpDown).size(10.0 * zoom).color(colors.muted)),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .overflow_hidden()
                    .whitespace_nowrap()
                    .pl(z(CODE_INSET))
                    .pr(z(CODE_TRAILING))
                    .text_color(colors.muted)
                    .child(lead.clone())
                    .when(!section.is_empty(), |label| {
                        label
                            .child(div().text_color(colors.muted.opacity(0.8)).child(format!("   {section}")))
                    })
                    .flex()
                    .flex_row(),
            )
            .when(expandable, |strip| {
                let handler = self.on_expand.clone();
                strip
                    .cursor(CursorStyle::PointingHand)
                    .tooltip(tooltip(format!("Show {lead}")))
                    .when_some(handler, |strip, handler| {
                        strip.on_click(move |event, window, cx| handler(event, window, cx))
                    })
            })
    }
}

/// "+12 -3" in the diff colors, monospaced; a zero count muted when `mute_zero`.
#[derive(IntoElement)]
pub struct DiffStat {
    additions: usize,
    deletions: usize,
    font_size: f32,
    mute_zero: bool,
}

impl DiffStat {
    pub fn new(additions: usize, deletions: usize, font_size: f32) -> Self {
        Self { additions, deletions, font_size, mute_zero: false }
    }

    pub fn mute_zero(mut self, mute: bool) -> Self {
        self.mute_zero = mute;
        self
    }
}

impl RenderOnce for DiffStat {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let colors = SurfaceColors::of(cx);
        let add =
            if self.mute_zero && self.additions == 0 { colors.muted } else { colors.diff_add_foreground };
        let delete =
            if self.mute_zero && self.deletions == 0 { colors.muted } else { colors.diff_delete_foreground };
        div()
            .flex()
            .flex_row()
            .flex_shrink_0()
            .whitespace_nowrap()
            .font_family(TERMINAL_FONT_FAMILY)
            .text_size(px(self.font_size * zoom(cx)))
            .child(div().text_color(add).child(format!("+{}", self.additions)))
            .child(" ")
            .child(div().text_color(delete).child(format!("-{}", self.deletions)))
    }
}

/// A chat file change's hunks as stacked rows (`FileDiffRowView`): separators between hunks,
/// numbers when the hunk states where it sits, syntax colors once highlighted.
#[derive(IntoElement)]
pub struct HunkDiff {
    id: ElementId,
    diff: Arc<InlineDiff>,
    wrap: bool,
}

impl HunkDiff {
    pub fn new(id: impl Into<ElementId>, diff: Arc<InlineDiff>) -> Self {
        Self { id: id.into(), diff, wrap: true }
    }

    pub fn wrap(mut self, wrap: bool) -> Self {
        self.wrap = wrap;
        self
    }
}

/// What a hunk line row shows.
pub fn hunk_side(diff: &InlineDiff, line: &HunkLine, numbered: bool) -> DiffSide {
    let tokens: Option<Vec<GitDiffToken<soprano_text::SyntaxTokenKind>>> = diff.tokens(line).map(|tokens| {
        tokens.iter().map(|token| GitDiffToken { range: token.range.clone(), kind: token.kind }).collect()
    });
    let number = if !numbered {
        None
    } else if line.kind == DiffLineKind::Removed {
        line.old_number
    } else {
        line.new_number
    };
    DiffSide {
        kind: line.kind,
        number,
        text: StyledLine::build(line.display_text(), tokens.as_deref(), None),
    }
}

impl RenderOnce for HunkDiff {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let colors = SurfaceColors::of(cx);
        let zoom = zoom(cx);
        let layout = DiffRowLayout {
            number_width: if self.diff.max_number > 0 {
                number_width(self.diff.max_number, window)
            } else {
                0.0
            },
            wrap: self.wrap,
            text_offset: 0.0,
        };
        let mut column =
            div().id(self.id.clone()).w_full().flex().flex_col().font_family(TERMINAL_FONT_FAMILY);
        for (index, line) in self.diff.lines.iter().enumerate() {
            let id = ElementId::from(index);
            column = column.child(match line {
                InlineDiffLine::Separator(text) => div()
                    .w_full()
                    .h(px(LINE_HEIGHT * zoom))
                    .flex()
                    .items_center()
                    .pl(px((layout.number_width + CODE_INSET) * zoom))
                    .bg(colors.wash(0.04, 0.03))
                    .text_size(px(DIFF_FONT_SIZE * zoom))
                    .text_color(colors.muted)
                    .whitespace_nowrap()
                    .overflow_hidden()
                    .child(text.clone())
                    .into_any_element(),
                InlineDiffLine::Line { line, numbered } => {
                    let side_view = hunk_side(&self.diff, line, *numbered);
                    div()
                        .w_full()
                        .flex()
                        .child(side(id, Some(&side_view), layout, false, &colors, zoom))
                        .into_any_element()
                }
            });
        }
        column
    }
}

/// Pixels of the designed length at the theme's zoom.
pub fn zoomed(value: f32, cx: &App) -> Pixels {
    px(value * zoom(cx))
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::{Hsla, hsla};
    use soprano_text::diff::StyledSpan;

    fn colors() -> SurfaceColors {
        let c = |hue: f32| -> Hsla { hsla(hue, 0.5, 0.5, 1.0) };
        SurfaceColors {
            is_dark: true,
            background: c(0.0),
            foreground: c(0.01),
            muted: c(0.02),
            dim: c(0.03),
            border: c(0.04),
            hover: c(0.05),
            selected: c(0.06),
            raised: c(0.07),
            popover: c(0.08),
            input: c(0.09),
            selection: c(0.10),
            accent: c(0.11),
            cursor: c(0.12),
            merged: c(0.13),
            info: c(0.14),
            warning: c(0.15),
            success: c(0.16),
            error: c(0.17),
            input_tone: c(0.18),
            diff_add: c(0.19),
            diff_add_word: c(0.20),
            diff_delete: c(0.21),
            diff_delete_word: c(0.22),
            diff_add_foreground: c(0.23),
            diff_delete_foreground: c(0.24),
        }
    }

    #[test]
    fn changed_words_sit_on_their_sides_word_tint_and_keywords_are_semibold() {
        let colors = colors();
        let line = StyledLine {
            text: "let b = 3".into(),
            spans: vec![
                StyledSpan {
                    range: 0..3,
                    syntax: Some(soprano_text::SyntaxTokenKind::Keyword),
                    emphasized: false,
                },
                StyledSpan {
                    range: 8..9,
                    syntax: Some(soprano_text::SyntaxTokenKind::Number),
                    emphasized: true,
                },
            ],
        };
        let added = styled_highlights(&line, DiffLineKind::Added, &colors);
        assert_eq!(added[0].1.color, Some(colors.merged));
        assert_eq!(added[0].1.font_weight, Some(FontWeight::SEMIBOLD));
        assert_eq!(added[1].1.color, Some(colors.warning));
        assert_eq!(added[1].1.background_color, Some(colors.diff_add_word));
        let removed = styled_highlights(&line, DiffLineKind::Removed, &colors);
        assert_eq!(removed[1].1.background_color, Some(colors.diff_delete_word));
    }

    #[test]
    fn hunk_lines_number_by_their_own_side() {
        let mut diff = InlineDiff::new("@@ -1,2 +1,2 @@\n a\n-b\n+c\n", "x.txt", false);
        diff.highlight();
        let lines: Vec<DiffSide> = diff
            .lines
            .iter()
            .filter_map(|line| match line {
                InlineDiffLine::Line { line, numbered } => Some(hunk_side(&diff, line, *numbered)),
                InlineDiffLine::Separator(_) => None,
            })
            .collect();
        assert_eq!(lines.iter().map(|side| side.number).collect::<Vec<_>>(), [Some(1), Some(2), Some(2)]);
        assert_eq!(lines[1].kind, DiffLineKind::Removed);
        assert_eq!(lines[2].text.text, "c");
        assert_eq!(
            fold_lead(&DiffFold { id: 4, rows: 2..9, range: None, section: String::new() }),
            "7 unmodified lines"
        );
    }
}
