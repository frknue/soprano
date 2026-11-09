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
    /// `link`: the destination of the link the image sits in (a badge, a linked screenshot).
    Image {
        source: String,
        alt: String,
        title: Option<String>,
        link: Option<String>,
    },
}

/// Flattens `inlines`. With `show_images` false (the chat), images read as their alt text, as
/// nothing a reply points at is fetched; otherwise each image with a source is its own piece.
pub fn flatten(inlines: &[MarkdownInline], show_images: bool) -> Vec<InlinePiece> {
    let mut flattener = Flattener { show_images, ..Flattener::default() };
    flattener.append(inlines, InlineMarks::default());
    flattener.finish()
}

/// The text of `inlines` as one run, images as alt text.
pub fn flatten_text(inlines: &[MarkdownInline]) -> InlineText {
    let mut flattener = Flattener::default();
    flattener.append(inlines, InlineMarks::default());
    flattener.current
}

#[derive(Default)]
struct Flattener {
    show_images: bool,
    current: InlineText,
    pieces: Vec<InlinePiece>,
    /// The links being walked (innermost last): destination and where each starts in
    /// `current`.
    open_links: Vec<(Option<String>, usize)>,
}

impl Flattener {
    fn finish(mut self) -> Vec<InlinePiece> {
        if !self.current.is_empty() || self.pieces.is_empty() {
            self.pieces.push(InlinePiece::Text(self.current));
        }
        self.pieces
    }

    /// Ends the current run of text before an image: the links still open close their part
    /// in it and reopen at the start of the next run.
    fn flush(&mut self) {
        if self.current.is_empty() {
            return;
        }
        let end = self.current.text.len();
        for (destination, start) in &mut self.open_links {
            if let Some(destination) = destination
                && end > *start
            {
                self.current.links.push(InlineLink { range: *start..end, destination: destination.clone() });
            }
            *start = 0;
        }
        self.pieces.push(InlinePiece::Text(std::mem::take(&mut self.current)));
    }

    fn append(&mut self, inlines: &[MarkdownInline], marks: InlineMarks) {
        for inline in inlines {
            match inline {
                MarkdownInline::Text(text) | MarkdownInline::Html(text) => self.current.push(text, marks),
                MarkdownInline::Emphasis(children) => {
                    self.append(children, InlineMarks { emphasis: true, ..marks })
                }
                MarkdownInline::Strong(children) => {
                    self.append(children, InlineMarks { strong: true, ..marks })
                }
                MarkdownInline::Strikethrough(children) => {
                    self.append(children, InlineMarks { strike: true, ..marks })
                }
                MarkdownInline::Code(code) => self.current.push(code, InlineMarks { code: true, ..marks }),
                MarkdownInline::Link { destination, children, .. } => {
                    self.open_links.push((destination.clone(), self.current.text.len()));
                    self.append(children, InlineMarks { link: true, ..marks });
                    let Some((destination, start)) = self.open_links.pop() else { continue };
                    let end = self.current.text.len();
                    if let Some(destination) = destination
                        && end > start
                    {
                        self.current.links.push(InlineLink { range: start..end, destination });
                    }
                }
                MarkdownInline::Image { source: Some(source), alt, title } if self.show_images => {
                    self.flush();
                    let link = self.open_links.iter().rev().find_map(|(destination, _)| destination.clone());
                    self.pieces.push(InlinePiece::Image {
                        source: source.clone(),
                        alt: alt.clone(),
                        title: title.clone(),
                        link,
                    });
                }
                MarkdownInline::Image { alt, .. } => self.current.push(alt, marks),
                MarkdownInline::SoftBreak => self.current.push(" ", marks),
                MarkdownInline::LineBreak => self.current.push("\n", marks),
            }
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
        assert_eq!(
            pieces[1],
            InlinePiece::Image { source: "chart.png".into(), alt: "a chart".into(), title: None, link: None }
        );
    }

    #[test]
    fn a_link_around_an_image_keeps_its_text_ranges_and_links_the_image() {
        let inlines = paragraph("abcd [x ![i](i.png) 日本](d.md) after");
        let pieces = flatten(&inlines, true);
        let [InlinePiece::Text(before), InlinePiece::Image { link, .. }, InlinePiece::Text(after)] =
            pieces.as_slice()
        else {
            panic!("text, image, text: {pieces:?}");
        };
        assert_eq!(link.as_deref(), Some("d.md"));
        assert_eq!(before.text, "abcd x ");
        assert_eq!(before.links, [InlineLink { range: 5..7, destination: "d.md".into() }]);
        assert_eq!(after.text, " 日本 after");
        assert_eq!(after.links, [InlineLink { range: 0..7, destination: "d.md".into() }]);
        assert!(after.text.is_char_boundary(7));

        let badge = flatten(&paragraph("[![CI](ci.svg)](https://ci.example.com)"), true);
        assert!(matches!(
            badge.as_slice(),
            [InlinePiece::Image { link: Some(link), .. }] if link == "https://ci.example.com"
        ));
    }
}
