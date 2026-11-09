//! Styled, selectable text with clickable links: GPUI's `StyledText` with highlight runs and
//! font overrides, taking part in the window's text selection (gpui-base `TextSelection`:
//! drag across any number of these and ⌘C copies the lot in reading order), and handing a
//! clicked link's destination to its owner.
//!
//! Selection needs the window's selection layer, which gpui-component's `Root` mounts.

use std::cell::Cell;
use std::ops::Range;
use std::rc::Rc;

use gpui::{
    App, BorderStyle, Bounds, Corners, CursorStyle, DispatchPhase, Edges, Element, ElementId,
    GlobalElementId, HighlightStyle, Hitbox, HitboxBehavior, Hsla, InspectorElementId, IntoElement, LayoutId,
    MouseButton, MouseDownEvent, MouseMoveEvent, MouseUpEvent, PaintQuad, Pixels, Point, SharedString,
    StyledText, TextLayout, UnderlineStyle, Window, px, transparent_black,
};
use gpui_base::{TextSelectionHandle, TextSelectionRegistration, TextSelectionRun};

use soprano_ui::SopranoTheme;
/// Receives a clicked link's destination, as the document wrote it.
pub type LinkHandler = Rc<dyn Fn(&str, &mut Window, &mut App)>;

/// A press that moved further than this is a drag (a selection), not a click.
const CLICK_SLOP: f32 = 4.0;

/// Text laid out with the inherited text style (font, size, line height, color) and
/// `highlights` on top. Give each instance a stable `id`.
pub struct RichText {
    id: ElementId,
    text: SharedString,
    highlights: Vec<(Range<usize>, HighlightStyle)>,
    font_overrides: Vec<(Range<usize>, SharedString)>,
    links: Rc<Vec<(Range<usize>, SharedString)>>,
    on_link: Option<LinkHandler>,
    underline_hovered_link: bool,
    document_order: u64,
    selection_color: Option<Hsla>,
    styled: Option<StyledText>,
}

impl RichText {
    pub fn new(id: impl Into<ElementId>, text: impl Into<SharedString>) -> Self {
        Self {
            id: id.into(),
            text: text.into(),
            highlights: Vec::new(),
            font_overrides: Vec::new(),
            links: Rc::new(Vec::new()),
            on_link: None,
            underline_hovered_link: false,
            document_order: 0,
            selection_color: None,
            styled: None,
        }
    }

    /// Styled ranges: sorted, non-overlapping, on character boundaries.
    pub fn highlights(mut self, highlights: Vec<(Range<usize>, HighlightStyle)>) -> Self {
        self.highlights = highlights;
        self
    }

    /// Ranges set in another font family (inline code): sorted, non-overlapping.
    pub fn font_overrides(mut self, overrides: Vec<(Range<usize>, SharedString)>) -> Self {
        self.font_overrides = overrides;
        self
    }

    /// Clickable ranges and their destinations; a click inside one calls `handler`.
    pub fn links(mut self, links: Vec<(Range<usize>, SharedString)>, handler: LinkHandler) -> Self {
        self.links = Rc::new(links);
        self.on_link = Some(handler);
        self
    }

    /// Underlines the link under the pointer (the reader's `a:hover`).
    pub fn underline_hovered_link(mut self, underline: bool) -> Self {
        self.underline_hovered_link = underline;
        self
    }

    /// Reading order among the other texts of the same document, for copying a selection.
    pub fn document_order(mut self, order: u64) -> Self {
        self.document_order = order;
        self
    }

    pub fn selection_color(mut self, color: Hsla) -> Self {
        self.selection_color = Some(color);
        self
    }

    fn link_at(
        links: &[(Range<usize>, SharedString)],
        layout: &TextLayout,
        position: Point<Pixels>,
    ) -> Option<usize> {
        let index = layout.index_for_position(position).ok()?;
        links.iter().position(|(range, _)| range.contains(&index))
    }
}

/// `highlights` with `range` underlined in `color`, still sorted and non-overlapping.
pub fn underline_range(
    highlights: &[(Range<usize>, HighlightStyle)],
    range: Range<usize>,
    color: Option<Hsla>,
) -> Vec<(Range<usize>, HighlightStyle)> {
    let underline = UnderlineStyle { thickness: px(1.0), color, wavy: false };
    overlay_range(highlights, range, |style| HighlightStyle { underline: Some(underline), ..style })
}

/// `highlights` with `apply` run on the style of every part of `range` (unstyled parts start
/// from the default style), still sorted and non-overlapping.
pub fn overlay_range(
    highlights: &[(Range<usize>, HighlightStyle)],
    range: Range<usize>,
    apply: impl Fn(HighlightStyle) -> HighlightStyle,
) -> Vec<(Range<usize>, HighlightStyle)> {
    let mut points: Vec<usize> = vec![range.start, range.end];
    for (span, _) in highlights {
        points.push(span.start);
        points.push(span.end);
    }
    points.sort_unstable();
    points.dedup();
    let mut result: Vec<(Range<usize>, HighlightStyle)> = Vec::new();
    for pair in points.windows(2) {
        let segment = pair[0]..pair[1];
        let base = highlights
            .iter()
            .find(|(span, _)| span.start <= segment.start && segment.end <= span.end)
            .map(|(_, style)| *style);
        let inside = range.start <= segment.start && segment.end <= range.end;
        let style = match (base, inside) {
            (base, true) => apply(base.unwrap_or_default()),
            (Some(base), false) => base,
            (None, false) => continue,
        };
        result.push((segment, style));
    }
    result
}

/// The link pressed (its index and where), until the button comes up.
type Press = Rc<Cell<Option<(usize, Point<Pixels>)>>>;

struct RichTextState {
    handle: TextSelectionHandle,
    press: Press,
    hovered: Rc<Cell<Option<usize>>>,
}

pub struct RichTextLayout {
    handle: TextSelectionHandle,
    press: Press,
    hovered: Rc<Cell<Option<usize>>>,
}

impl IntoElement for RichText {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

impl Element for RichText {
    type RequestLayoutState = RichTextLayout;
    type PrepaintState = Hitbox;

    fn id(&self) -> Option<ElementId> {
        Some(self.id.clone())
    }

    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        global_id: Option<&GlobalElementId>,
        inspector_id: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, Self::RequestLayoutState) {
        let global_id = global_id.expect("RichText has an element id");
        let text = self.text.clone();
        let layout = window.with_element_state(global_id, |state: Option<RichTextState>, _| {
            let state = state.unwrap_or_else(|| RichTextState {
                handle: TextSelectionHandle::new(text.to_string(), cx),
                press: Rc::default(),
                hovered: Rc::default(),
            });
            let layout = RichTextLayout {
                handle: state.handle.clone(),
                press: state.press.clone(),
                hovered: state.hovered.clone(),
            };
            (layout, state)
        });
        layout.handle.set_fallback_copy_text(self.text.to_string(), cx);

        let mut highlights = std::mem::take(&mut self.highlights);
        if self.underline_hovered_link
            && let Some(range) =
                layout.hovered.get().and_then(|index| self.links.get(index)).map(|(r, _)| r.clone())
        {
            highlights = underline_range(&highlights, range, None);
        }
        let mut styled = StyledText::new(self.text.clone());
        if !highlights.is_empty() {
            styled = styled.with_highlights(highlights);
        }
        if !self.font_overrides.is_empty() {
            styled = styled.with_font_family_overrides(std::mem::take(&mut self.font_overrides));
        }
        let (layout_id, ()) = styled.request_layout(None, inspector_id, window, cx);
        self.styled = Some(styled);
        (layout_id, layout)
    }

    fn prepaint(
        &mut self,
        _global_id: Option<&GlobalElementId>,
        inspector_id: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        state: &mut Self::RequestLayoutState,
        window: &mut Window,
        cx: &mut App,
    ) -> Self::PrepaintState {
        if let Some(styled) = self.styled.as_mut() {
            styled.prepaint(None, inspector_id, bounds, &mut (), window, cx);
        }
        let hitbox = window.insert_hitbox(bounds, HitboxBehavior::Normal);
        let registration = TextSelectionRegistration::new(hitbox.clone(), bounds)
            .with_document_order(self.document_order)
            .with_text_bounds(vec![bounds])
            .with_rendered_element(&state.handle, window, cx);
        state.handle.register(registration, window, cx);
        hitbox
    }

    fn paint(
        &mut self,
        _global_id: Option<&GlobalElementId>,
        inspector_id: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        state: &mut Self::RequestLayoutState,
        hitbox: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        let Some(mut styled) = self.styled.take() else { return };
        let layout = styled.layout().clone();
        let projection = state.handle.update_runs(
            &[TextSelectionRun::new(self.text.clone(), layout.clone(), bounds)
                .with_document_order(self.document_order)],
            cx,
        );
        let fallback = || cx.try_global::<SopranoTheme>().map(|theme| theme.selection);
        if let Some(color) = self.selection_color.or_else(fallback) {
            for range in projection.ranges().iter().flatten().cloned() {
                paint_selection(&layout, range, color, window);
            }
        }
        styled.paint(None, inspector_id, bounds, &mut (), &mut (), window, cx);

        let Some(handler) = self.on_link.clone() else { return };
        if self.links.is_empty() {
            return;
        }
        let links = self.links.clone();
        if hitbox.is_hovered(window) && Self::link_at(&links, &layout, window.mouse_position()).is_some() {
            window.set_cursor_style(CursorStyle::PointingHand, hitbox);
        }
        window.on_mouse_event({
            let (links, layout, hitbox, press) =
                (links.clone(), layout.clone(), hitbox.clone(), state.press.clone());
            move |event: &MouseDownEvent, phase, window, _| {
                if phase != DispatchPhase::Capture || event.button != MouseButton::Left {
                    return;
                }
                let link = hitbox
                    .is_hovered(window)
                    .then(|| Self::link_at(&links, &layout, event.position))
                    .flatten();
                press.set(link.map(|link| (link, event.position)));
            }
        });
        window.on_mouse_event({
            let (links, layout, hitbox, press) =
                (links.clone(), layout.clone(), hitbox.clone(), state.press.clone());
            move |event: &MouseUpEvent, phase, window, cx| {
                if phase != DispatchPhase::Capture || event.button != MouseButton::Left {
                    return;
                }
                let Some((link, at)) = press.take() else { return };
                let moved = (event.position.x - at.x).abs().max((event.position.y - at.y).abs());
                if hitbox.is_hovered(window)
                    && moved <= px(CLICK_SLOP)
                    && Self::link_at(&links, &layout, event.position) == Some(link)
                {
                    let destination = links[link].1.clone();
                    handler(&destination, window, cx);
                }
            }
        });
        window.on_mouse_event({
            let (hitbox, hovered) = (hitbox.clone(), state.hovered.clone());
            let underline = self.underline_hovered_link;
            move |event: &MouseMoveEvent, phase, window, _| {
                if phase != DispatchPhase::Bubble {
                    return;
                }
                let current = hitbox
                    .is_hovered(window)
                    .then(|| Self::link_at(&links, &layout, event.position))
                    .flatten();
                if current != hovered.get() {
                    hovered.set(current);
                    if underline {
                        window.refresh();
                    }
                }
            }
        });
    }
}

/// The selection behind `range` of `layout`: line by line, from the start to the end edge.
fn paint_selection(layout: &TextLayout, range: Range<usize>, color: Hsla, window: &mut Window) {
    let (Some(start), Some(end)) =
        (layout.position_for_index(range.start), layout.position_for_index(range.end))
    else {
        return;
    };
    let bounds = layout.bounds();
    let line_height = layout.line_height();
    let mut quads = Vec::new();
    if start.y == end.y {
        quads.push(Bounds::from_corners(start, Point::new(end.x, end.y + line_height)));
    } else {
        quads.push(Bounds::from_corners(start, Point::new(bounds.right(), start.y + line_height)));
        if end.y > start.y + line_height {
            quads.push(Bounds::from_corners(
                Point::new(bounds.left(), start.y + line_height),
                Point::new(bounds.right(), end.y),
            ));
        }
        quads.push(Bounds::from_corners(
            Point::new(bounds.left(), end.y),
            Point::new(end.x, end.y + line_height),
        ));
    }
    for quad in quads {
        window.paint_quad(PaintQuad {
            bounds: quad,
            background: color.into(),
            corner_radii: Corners::default(),
            border_widths: Edges::default(),
            border_color: transparent_black(),
            border_style: BorderStyle::default(),
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::FontWeight;

    #[test]
    fn underlining_a_link_splits_the_runs_around_it() {
        let bold = HighlightStyle { font_weight: Some(FontWeight::BOLD), ..Default::default() };
        let result = underline_range(&[(0..10, bold)], 4..6, None);
        let ranges: Vec<Range<usize>> = result.iter().map(|(range, _)| range.clone()).collect();
        assert_eq!(ranges, [0..4, 4..6, 6..10]);
        assert!(result[1].1.underline.is_some());
        assert_eq!(result[1].1.font_weight, Some(FontWeight::BOLD));
        assert!(result[0].1.underline.is_none());
        // A link over unstyled text still gets its underline.
        assert_eq!(underline_range(&[], 2..5, None).len(), 1);
    }
}
