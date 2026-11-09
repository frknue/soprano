//! A Markdown code block (`CodeBlockView`): rounded 8 on the code wash, a 30 px header with the
//! language in mono 11 and a Copy button (a check for 1.2 s after copying), then the code in
//! mono 13 on 18 px lines with syntax colors, wrapped (chat) or scrolling sideways (reader).

use std::ops::Range;
use std::time::Duration;

use gpui::{
    App, ClipboardItem, ElementId, HighlightStyle, InteractiveElement, IntoElement, ParentElement,
    RenderOnce, SharedString, StatefulInteractiveElement, Styled, Window, div, prelude::FluentBuilder, px,
};
use soprano_text::SyntaxToken;
use soprano_ui::button::IconButton;
use soprano_ui::fonts::TERMINAL_FONT_FAMILY;
use soprano_ui::{IconName, SopranoTheme};

use crate::colors::SurfaceColors;
use crate::rich::text::RichText;

pub const CODE_FONT_SIZE: f32 = 13.0;
pub const CODE_LINE_HEIGHT: f32 = 18.0;
const HEADER_HEIGHT: f32 = 30.0;
const COPIED_FOR: Duration = Duration::from_millis(1200);

#[derive(IntoElement)]
pub struct CodeBlock {
    id: ElementId,
    language: Option<SharedString>,
    code: SharedString,
    tokens: Vec<SyntaxToken>,
    wrap: bool,
    document_order: u64,
}

impl CodeBlock {
    /// `tokens` are byte ranges of `code` (`MarkdownBlock::Code`); a trailing newline is not
    /// shown.
    pub fn new(id: impl Into<ElementId>, language: Option<&str>, code: &str, tokens: &[SyntaxToken]) -> Self {
        let code = code.strip_suffix('\n').unwrap_or(code);
        Self {
            id: id.into(),
            language: language
                .filter(|language| !language.is_empty())
                .map(|l| SharedString::from(l.to_string())),
            code: SharedString::from(code.to_string()),
            tokens: tokens.to_vec(),
            wrap: true,
            document_order: 0,
        }
    }

    /// Long lines wrap (the chat) or the block scrolls sideways (the reader).
    pub fn wrap(mut self, wrap: bool) -> Self {
        self.wrap = wrap;
        self
    }

    pub fn document_order(mut self, order: u64) -> Self {
        self.document_order = order;
        self
    }
}

/// Token colors for `text`: sorted, clipped to the text, overlaps dropped.
pub(crate) fn token_highlights(
    text: &str,
    tokens: &[SyntaxToken],
    color: impl Fn(soprano_text::SyntaxTokenKind) -> HighlightStyle,
) -> Vec<(Range<usize>, HighlightStyle)> {
    let mut sorted: Vec<&SyntaxToken> = tokens.iter().collect();
    sorted.sort_by_key(|token| token.range.start);
    let mut result: Vec<(Range<usize>, HighlightStyle)> = Vec::new();
    let mut end = 0;
    for token in sorted {
        let range = token.range.start.max(end)..token.range.end.min(text.len());
        if range.is_empty() || !text.is_char_boundary(range.start) || !text.is_char_boundary(range.end) {
            continue;
        }
        end = range.end;
        result.push((range, color(token.kind)));
    }
    result
}

impl RenderOnce for CodeBlock {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let colors = SurfaceColors::of(cx);
        let copied = window.use_keyed_state(ElementId::from((self.id.clone(), "copied")), cx, |_, _| false);
        let is_copied = *copied.read(cx);
        let highlights = token_highlights(&self.code, &self.tokens, |kind| HighlightStyle {
            color: Some(colors.markdown_syntax(kind)),
            ..Default::default()
        });
        let code = self.code.clone();
        let body = RichText::new(ElementId::from((self.id.clone(), "code")), self.code.clone())
            .highlights(highlights)
            .document_order(self.document_order)
            .selection_color(colors.selection);
        let zoom = cx.global::<SopranoTheme>().zoom();
        let z = |value: f32| px(value * zoom);

        div()
            .id(self.id.clone())
            .w_full()
            .rounded(z(8.0))
            .overflow_hidden()
            .bg(colors.code_block_background())
            .when(!colors.is_dark, |block| block.border_1().border_color(colors.border.opacity(0.7)))
            .child(
                div()
                    .h(z(HEADER_HEIGHT))
                    .pl(z(12.0))
                    .pr(z(6.0))
                    .flex()
                    .flex_row()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .overflow_hidden()
                            .whitespace_nowrap()
                            .text_ellipsis()
                            .font_family(TERMINAL_FONT_FAMILY)
                            .text_size(z(11.0))
                            .line_height(z(16.0))
                            .text_color(colors.foreground.opacity(0.72))
                            .child(self.language.clone().unwrap_or_default()),
                    )
                    .child(
                        IconButton::new(
                            ElementId::from((self.id.clone(), "copy")),
                            if is_copied { IconName::Check } else { IconName::Copy },
                        )
                        .icon_size(12.0)
                        .when(is_copied, |button| button.color(colors.merged))
                        .tooltip("Copy code")
                        .on_click(move |_, _, cx| {
                            cx.write_to_clipboard(ClipboardItem::new_string(code.to_string()));
                            copied.update(cx, |copied, cx| {
                                *copied = true;
                                cx.notify();
                            });
                            let copied = copied.clone();
                            cx.spawn(async move |cx| {
                                cx.background_executor().timer(COPIED_FOR).await;
                                copied.update(cx, |copied, cx| {
                                    *copied = false;
                                    cx.notify();
                                });
                            })
                            .detach();
                        }),
                    ),
            )
            .child(
                div()
                    .id(ElementId::from((self.id, "scroll")))
                    .px(z(14.0))
                    .pt(z(12.0))
                    .pb(z(12.0))
                    .font_family(TERMINAL_FONT_FAMILY)
                    .text_size(z(CODE_FONT_SIZE))
                    .line_height(z(CODE_LINE_HEIGHT))
                    .text_color(colors.foreground)
                    .when(!self.wrap, |code| code.overflow_x_scroll().whitespace_nowrap())
                    .child(body),
            )
    }
}
