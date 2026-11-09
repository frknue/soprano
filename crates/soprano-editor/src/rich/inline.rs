//! Inline Markdown flattened into one string with styled spans and link ranges, the shape a
//! GPUI text run needs (Swift built an attributed string the same way in
//! `MarkdownRenderer.appendInlines`).

use std::ops::Range;

use soprano_text::markdown::MarkdownInline;

/// The styles a piece of inline text carries; they nest (`***a***` is strong and emphasis).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct InlineMarks {
    pub strong: bool,
    pub emphasis: bool,
    pub strike: bool,
    pub code: bool,
    /// Inside a link, whether or not it leads anywhere.
    pub link: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InlineSpan {
    pub range: Range<usize>,
    pub marks: InlineMarks,
}

/// A link's text range and its destination as the document wrote it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InlineLink {
    pub range: Range<usize>,
    pub destination: String,
}

/// Inline Markdown as one string: spans cover the whole text in order, adjacent equal marks
/// merged; links list every link that has a destination.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct InlineText {
    pub text: String,
    pub spans: Vec<InlineSpan>,
    pub links: Vec<InlineLink>,
}

impl InlineText {
    pub fn is_empty(&self) -> bool {
        self.text.is_empty()
    }

    fn push(&mut self, text: &str, marks: InlineMarks) {
        if text.is_empty() {
            return;
        }
        let start = self.text.len();
        self.text.push_str(text);
        let end = self.text.len();
        match self.spans.last_mut() {
            Some(span) if span.marks == marks && span.range.end == start => span.range.end = end,
            _ => self.spans.push(InlineSpan { range: start..end, marks }),
        }
    }
}

/// A paragraph's content in order: runs of text, and images where the document shows them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InlinePiece {
    Text(InlineText),
    Image { source: String, alt: String },
}

/// Flattens `inlines`. With `show_images` false (the chat), images read as their alt text, as
/// nothing a reply points at is fetched; otherwise each image with a source is its own piece.
pub fn flatten(inlines: &[MarkdownInline], show_images: bool) -> Vec<InlinePiece> {
    let mut pieces = Vec::new();
    let mut current = InlineText::default();
    append(inlines, InlineMarks::default(), show_images, &mut current, &mut pieces);
    if !current.is_empty() || pieces.is_empty() {
        pieces.push(InlinePiece::Text(current));
    }
    pieces
}

/// The text of `inlines` as one run, images as alt text.
pub fn flatten_text(inlines: &[MarkdownInline]) -> InlineText {
    let mut pieces = Vec::new();
    let mut current = InlineText::default();
    append(inlines, InlineMarks::default(), false, &mut current, &mut pieces);
    current
}

fn append(
    inlines: &[MarkdownInline],
    marks: InlineMarks,
    show_images: bool,
    current: &mut InlineText,
    pieces: &mut Vec<InlinePiece>,
) {
    for inline in inlines {
        match inline {
            MarkdownInline::Text(text) | MarkdownInline::Html(text) => current.push(text, marks),
            MarkdownInline::Emphasis(children) => {
                append(children, InlineMarks { emphasis: true, ..marks }, show_images, current, pieces)
            }
            MarkdownInline::Strong(children) => {
                append(children, InlineMarks { strong: true, ..marks }, show_images, current, pieces)
            }
            MarkdownInline::Strikethrough(children) => {
                append(children, InlineMarks { strike: true, ..marks }, show_images, current, pieces)
            }
            MarkdownInline::Code(code) => current.push(code, InlineMarks { code: true, ..marks }),
            MarkdownInline::Link { destination, children, .. } => {
                let start = current.text.len();
                append(children, InlineMarks { link: true, ..marks }, show_images, current, pieces);
                let end = current.text.len();
                if let Some(destination) = destination
                    && end > start
                {
                    current.links.push(InlineLink { range: start..end, destination: destination.clone() });
                }
            }
            MarkdownInline::Image { source: Some(source), alt, .. } if show_images => {
                if !current.is_empty() {
                    pieces.push(InlinePiece::Text(std::mem::take(current)));
                }
                pieces.push(InlinePiece::Image { source: source.clone(), alt: alt.clone() });
            }
            MarkdownInline::Image { alt, .. } => current.push(alt, marks),
            MarkdownInline::SoftBreak => current.push(" ", marks),
            MarkdownInline::LineBreak => current.push("\n", marks),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use soprano_text::markdown::{MarkdownBlock, parse};

    fn paragraph(source: &str) -> Vec<MarkdownInline> {
        match parse(source, false).into_iter().next() {
            Some(MarkdownBlock::Paragraph(inlines)) => inlines,
            other => panic!("expected a paragraph, got {other:?}"),
        }
    }

    #[test]
    fn nested_marks_flatten_into_spans_that_cover_the_text() {
        let text = flatten_text(&paragraph("plain **bold *both*** `code` ~~gone~~"));
        assert_eq!(text.text, "plain bold both code gone");
        let marks: Vec<(&str, InlineMarks)> =
            text.spans.iter().map(|span| (&text.text[span.range.clone()], span.marks)).collect();
        assert_eq!(marks[0], ("plain ", InlineMarks::default()));
        assert_eq!(marks[1], ("bold ", InlineMarks { strong: true, ..Default::default() }));
        assert_eq!(marks[2], ("both", InlineMarks { strong: true, emphasis: true, ..Default::default() }));
        assert!(marks.iter().any(|(text, marks)| *text == "code" && marks.code));
        assert!(marks.iter().any(|(text, marks)| *text == "gone" && marks.strike));
        assert_eq!(text.spans.last().map(|span| span.range.end), Some(text.text.len()));
    }

    #[test]
    fn links_keep_their_destination_and_images_read_as_alt_text_in_the_chat() {
        let inlines = paragraph("see [the docs](https://example.com) and ![a chart](chart.png)");
        let text = flatten_text(&inlines);
        assert_eq!(text.text, "see the docs and a chart");
        assert_eq!(text.links, [InlineLink { range: 4..12, destination: "https://example.com".into() }]);

        let pieces = flatten(&inlines, true);
        assert_eq!(pieces.len(), 2);
        assert_eq!(pieces[1], InlinePiece::Image { source: "chart.png".into(), alt: "a chart".into() });
    }
}
