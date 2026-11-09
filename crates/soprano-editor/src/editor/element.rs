//! The editor's text area: line-number gutter, selection, find highlights, syntax-colored
//! lines and the caret, laid out row by row for the visible part of the shared buffer.
//!
//! Look: Herdr's file preview (terminal font 12) on Soprano's fixed 20 px lines; the gutter
//! (`EditorLineNumberRuler`) in the terminal font at 11, muted, right-aligned 10 px from its
//! edge on the text's background with no rule; keywords semibold, comments italic.

use std::hash::Hash;
use std::ops::Range;

use gpui::{
    App, Bounds, ContentMask, Element, ElementId, ElementInputHandler, Entity, Font, FontStyle, FontWeight,
    GlobalElementId, InspectorElementId, IntoElement, LayoutId, Pixels, Point, ShapedLine, SharedString,
    Style, TextAlign, TextRun, Window, fill, point, px, relative, size,
};
use soprano_text::editor::{GUTTER_PADDING, LINE_HEIGHT, number_column_width};
use soprano_text::{EditorDocument, SyntaxToken};
use soprano_ui::SopranoTheme;
use soprano_ui::fonts::TERMINAL_FONT_FAMILY;

use super::EditorView;
use super::layout::{
    self, DisplayLine, FONT_SIZE, GUTTER_FONT_SIZE, TEXT_INSET_X, TEXT_INSET_Y, visible_rows,
};
use crate::colors::SurfaceColors;
use crate::rich::diff::digit_width;

/// One visible row as laid out.
#[derive(Clone)]
pub(super) struct LaidRow {
    pub row: usize,
    /// Buffer byte range of the line, without its break.
    pub range: Range<usize>,
    /// Where the next line starts (after the break).
    pub next_start: usize,
    pub display: DisplayLine,
    pub shaped: ShapedLine,
}

/// The geometry of the last painted frame, for hit testing, IME and scrolling.
#[derive(Clone)]
pub(super) struct EditorLayout {
    pub bounds: Bounds<Pixels>,
    pub line_height: Pixels,
    pub char_width: Pixels,
    pub gutter_width: Pixels,
    /// Window position of row 0, column 0 (scroll applied).
    pub text_origin: Point<Pixels>,
    pub rows: Vec<LaidRow>,
    pub line_count: usize,
    pub zoom: f32,
}

impl EditorLayout {
    pub fn page_rows(&self) -> usize {
        ((self.bounds.size.height / self.line_height).floor() as usize).max(1)
    }

    pub fn max_scroll(&self, widest_columns: usize) -> Point<Pixels> {
        let content_height = px(layout::content_height(self.line_count, LINE_HEIGHT) * self.zoom);
        let content_width = self.char_width * (widest_columns as f32 + 1.0)
            + px(TEXT_INSET_X * 2.0 * self.zoom)
            + self.gutter_width;
        point(
            (content_width - self.bounds.size.width).max(px(0.0)),
            (content_height - self.bounds.size.height).max(px(0.0)),
        )
    }

    fn row_top(&self, row: usize) -> Pixels {
        self.text_origin.y + self.line_height * row as f32
    }

    fn x_for(&self, laid: &LaidRow, offset: usize) -> Pixels {
        let display =
            laid.display.display_offset(offset.saturating_sub(laid.range.start).min(laid.range.len()));
        self.text_origin.x + laid.shaped.x_for_index(display)
    }

    /// The buffer offset under a window point (rows past the visible ones clamp to them).
    pub fn offset_for_point(&self, position: Point<Pixels>) -> Option<usize> {
        let first = self.rows.first()?;
        let last = self.rows.last()?;
        let row = ((position.y - self.text_origin.y) / self.line_height).floor();
        if row < first.row as f32 {
            return Some(if first.row == 0 { 0 } else { first.range.start });
        }
        if row > last.row as f32 {
            return Some(last.range.end);
        }
        let laid = self.rows.iter().find(|laid| laid.row == row as usize)?;
        let x = (position.x - self.text_origin.x).max(px(0.0));
        let display = laid.shaped.closest_index_for_x(x);
        Some(laid.range.start + laid.display.buffer_offset(display))
    }

    /// The caret box at `offset`, when its row is visible.
    pub fn caret_bounds(&self, offset: usize) -> Option<Bounds<Pixels>> {
        let laid = self.rows.iter().find(|laid| laid.range.start <= offset && offset <= laid.range.end)?;
        let x = self.x_for(laid, offset);
        Some(Bounds::new(point(x, self.row_top(laid.row)), size(px(2.0), self.line_height)))
    }
}

pub(super) struct EditorElement<T: Clone + Eq + Hash + 'static> {
    view: Entity<EditorView<T>>,
}

impl<T: Clone + Eq + Hash + 'static> EditorElement<T> {
    pub fn new(view: Entity<EditorView<T>>) -> Self {
        Self { view }
    }
}

pub(super) struct EditorPaint {
    layout: EditorLayout,
    numbers: Vec<(usize, ShapedLine)>,
    selection: Range<usize>,
    caret: Option<usize>,
    matches: Vec<(Range<usize>, bool)>,
    focused: bool,
    colors: SurfaceColors,
    scroll: Point<Pixels>,
    widest_columns: usize,
}

impl<T: Clone + Eq + Hash + 'static> IntoElement for EditorElement<T> {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

/// Text runs for a line's display text: syntax colors on the foreground.
fn runs(
    laid_range: &Range<usize>,
    display: &DisplayLine,
    tokens: &[SyntaxToken],
    colors: &SurfaceColors,
    font: &Font,
) -> Vec<TextRun> {
    let plain = |len: usize| TextRun {
        len,
        font: font.clone(),
        color: colors.foreground,
        background_color: None,
        underline: None,
        strikethrough: None,
    };
    let mut result = Vec::new();
    let mut at = 0;
    let first = tokens.partition_point(|token| token.range.end <= laid_range.start);
    for token in &tokens[first..] {
        if token.range.start >= laid_range.end {
            break;
        }
        let start = if token.range.start <= laid_range.start {
            0
        } else {
            display.display_offset(token.range.start - laid_range.start)
        };
        let end = display.display_offset(token.range.end.min(laid_range.end) - laid_range.start);
        if end <= start || start < at {
            continue;
        }
        if start > at {
            result.push(plain(start - at));
        }
        let mut styled = font.clone();
        if token.kind.is_emphasized() {
            styled.weight = FontWeight::SEMIBOLD;
        } else if token.kind.is_italic() {
            styled.style = FontStyle::Italic;
        }
        result
            .push(TextRun { color: colors.code_syntax(token.kind), ..plain(end - start) }.with_font(styled));
        at = end;
    }
    if at < display.text.len() {
        result.push(plain(display.text.len() - at));
    }
    result
}

trait WithFont {
    fn with_font(self, font: Font) -> Self;
}

impl WithFont for TextRun {
    fn with_font(mut self, font: Font) -> Self {
        self.font = font;
        self
    }
}

impl<T: Clone + Eq + Hash + 'static> Element for EditorElement<T> {
    type RequestLayoutState = ();
    type PrepaintState = Option<EditorPaint>;

    fn id(&self) -> Option<ElementId> {
        None
    }

    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, ()) {
        let mut style = Style::default();
        style.size.width = relative(1.0).into();
        style.size.height = relative(1.0).into();
        (window.request_layout(style, [], cx), ())
    }

    fn prepaint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _: &mut (),
        window: &mut Window,
        cx: &mut App,
    ) -> Self::PrepaintState {
        let zoom = cx.try_global::<SopranoTheme>().map_or(1.0, SopranoTheme::zoom);
        let colors = SurfaceColors::of(cx);
        let view = self.view.read(cx);
        let focused = view.focus.is_focused(window);
        let (selection, head) = (view.selected_range(), view.head);
        let (mut scroll, autoscroll, mut widest) = (view.scroll, view.autoscroll, view.widest_columns);
        let matches: Vec<(Range<usize>, bool)> = if view.find.visible {
            view.find
                .matches
                .iter()
                .enumerate()
                .map(|(index, found)| (found.clone(), Some(index) == view.find.current))
                .collect()
        } else {
            Vec::new()
        };
        let documents = view.documents.read(cx);
        let document: &EditorDocument = documents.document(view.document)?;

        let line_height = px(LINE_HEIGHT * zoom);
        let font_size = px(FONT_SIZE * zoom);
        let font = Font {
            family: TERMINAL_FONT_FAMILY.into(),
            weight: FontWeight::NORMAL,
            ..window.text_style().font()
        };
        let char_width = px(digit_width(FONT_SIZE, window) * zoom);
        let line_count = document.line_count();
        let gutter_digit = digit_width(GUTTER_FONT_SIZE, window);
        let gutter_width = px(number_column_width(line_count, gutter_digit) * zoom);
        let inset = point(px(TEXT_INSET_X * zoom), px(TEXT_INSET_Y * zoom));

        // Keep the caret in view after it moved.
        if autoscroll {
            let rope = document.rope();
            let row = rope.byte_to_line(head.min(rope.len_bytes()));
            let (range, text) = layout::line(document, row);
            let line = DisplayLine::new(&text);
            let column = line.column_of(line.display_offset(head.saturating_sub(range.start)));
            let top = line_height * row as f32 + inset.y;
            let viewport = bounds.size.height;
            if top < scroll.y + inset.y {
                scroll.y = (top - inset.y).max(px(0.0));
            } else if top + line_height + inset.y > scroll.y + viewport {
                scroll.y = top + line_height + inset.y - viewport;
            }
            let x = char_width * column as f32;
            let text_width = bounds.size.width - gutter_width - inset.x * 2.0;
            if x < scroll.x {
                scroll.x = x;
            } else if x + char_width > scroll.x + text_width {
                scroll.x = x + char_width - text_width;
            }
        }

        let rows_range = visible_rows(
            f32::from(scroll.y) / zoom,
            f32::from(bounds.size.height) / zoom,
            LINE_HEIGHT,
            line_count,
        );
        let text_origin =
            point(bounds.origin.x + gutter_width + inset.x - scroll.x, bounds.origin.y + inset.y - scroll.y);
        let tokens = document.tokens();
        let mut rows = Vec::with_capacity(rows_range.len());
        let mut numbers = Vec::with_capacity(rows_range.len());
        let number_font = Font { family: TERMINAL_FONT_FAMILY.into(), ..window.text_style().font() };
        for row in rows_range {
            let (range, text) = layout::line(document, row);
            let next_start =
                if row + 1 < line_count { document.rope().line_to_byte(row + 1) } else { range.end };
            let display = DisplayLine::new(&text);
            widest = widest.max(display.columns());
            let line_runs = runs(&range, &display, tokens, &colors, &font);
            let shaped = window.text_system().shape_line(
                SharedString::from(display.text.clone()),
                font_size,
                &line_runs,
                None,
            );
            let label = (row + 1).to_string();
            let number_run = TextRun {
                len: label.len(),
                font: number_font.clone(),
                color: colors.muted,
                background_color: None,
                underline: None,
                strikethrough: None,
            };
            numbers.push((
                row,
                window.text_system().shape_line(
                    label.into(),
                    px(GUTTER_FONT_SIZE * zoom),
                    &[number_run],
                    None,
                ),
            ));
            rows.push(LaidRow { row, range, next_start, display, shaped });
        }
        let layout = EditorLayout {
            bounds,
            line_height,
            char_width,
            gutter_width,
            text_origin,
            rows,
            line_count,
            zoom,
        };
        let max = layout.max_scroll(widest);
        scroll = point(scroll.x.clamp(px(0.0), max.x), scroll.y.clamp(px(0.0), max.y));
        let caret = (focused && selection.is_empty()).then_some(head);
        Some(EditorPaint {
            layout,
            numbers,
            selection,
            caret,
            matches,
            focused,
            colors,
            scroll,
            widest_columns: widest,
        })
    }

    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _: &mut (),
        paint: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        let Some(paint) = paint.take() else { return };
        let EditorPaint {
            layout,
            numbers,
            selection,
            caret,
            matches,
            focused,
            colors,
            scroll,
            widest_columns,
        } = paint;
        window.paint_quad(fill(bounds, colors.background));
        let text_area = Bounds::from_corners(
            point(bounds.left() + layout.gutter_width, bounds.top()),
            bounds.bottom_right(),
        );
        window.with_content_mask(Some(ContentMask { bounds: text_area }), |window| {
            for laid in &layout.rows {
                let top = layout.row_top(laid.row);
                let band = |range: &Range<usize>, extends: bool| -> Option<Bounds<Pixels>> {
                    let start = range.start.max(laid.range.start);
                    let end = range.end.min(laid.next_start);
                    if start > end || (start == end && !range.is_empty()) || end < laid.range.start {
                        return None;
                    }
                    let x0 = layout.x_for(laid, start);
                    let mut x1 = layout.x_for(laid, end.min(laid.range.end));
                    if extends && end > laid.range.end {
                        x1 += layout.char_width;
                    }
                    (x1 > x0)
                        .then(|| Bounds::from_corners(point(x0, top), point(x1, top + layout.line_height)))
                };
                if !selection.is_empty()
                    && let Some(rect) = band(&selection, true)
                {
                    window.paint_quad(fill(rect, colors.selection));
                }
                for (found, current) in &matches {
                    if let Some(rect) = band(found, false) {
                        window.paint_quad(fill(
                            rect,
                            colors.accent.opacity(if *current { 0.55 } else { 0.28 }),
                        ));
                    }
                }
                let _ = laid.shaped.paint(
                    point(layout.text_origin.x, top),
                    layout.line_height,
                    TextAlign::Left,
                    None,
                    window,
                    cx,
                );
            }
            if let Some(caret) = caret.and_then(|offset| layout.caret_bounds(offset)) {
                window.paint_quad(fill(caret, colors.cursor));
            }
        });

        // The gutter, on the text's background.
        let gutter = Bounds::new(bounds.origin, size(layout.gutter_width, bounds.size.height));
        window.with_content_mask(Some(ContentMask { bounds: gutter }), |window| {
            window.paint_quad(fill(gutter, colors.background));
            let padding = px(GUTTER_PADDING * layout.zoom);
            for (row, number) in &numbers {
                let x = gutter.right() - padding - number.width();
                let _ = number.paint(
                    point(x, layout.row_top(*row)),
                    layout.line_height,
                    TextAlign::Left,
                    None,
                    window,
                    cx,
                );
            }
        });

        // A scroll indicator when the text is taller than the view (Herdr's 6 px thumb).
        let max = layout.max_scroll(widest_columns);
        if max.y > px(0.0) {
            let height = bounds.size.height;
            let content = height + max.y;
            let thumb = (height * (height / content)).max(px(48.0)).min(height);
            let y = bounds.top() + (height - thumb) * (scroll.y / max.y);
            let rect = Bounds::new(point(bounds.right() - px(10.0), y), size(px(6.0), thumb));
            window.paint_quad(fill(rect, colors.foreground.opacity(0.35)));
        }

        if focused {
            let focus = self.view.read(cx).focus.clone();
            window.handle_input(&focus, ElementInputHandler::new(bounds, self.view.clone()), cx);
        }
        let stored = layout;
        self.view.update(cx, |view, _| {
            view.layout = Some(stored);
            view.scroll = scroll;
            view.autoscroll = false;
            view.widest_columns = widest_columns;
        });
    }
}
