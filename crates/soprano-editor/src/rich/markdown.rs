//! Markdown drawn natively from soprano-text's block model, in two flavors:
//!
//! - the chat (`MarkdownRenderer.swift` + `MarkdownView.swift`): assistant prose 14 on a 1.625
//!   line at 90 % of the foreground, user bubbles and reasoning lines; headings +6/+4/+2
//!   semibold, lists with a 20 px marker gutter, quotes on a 2 px rule, code blocks, tables
//!   with row rules, images as their alt text;
//! - the reader (`MarkdownPaneView`'s style sheet): 16/26 in a 920 px column, h1 28/34, h2
//!   21/28 over a rule, h3 17/22, links that resolve inside the document's access root,
//!   relative images, source HTML shown as muted source.
//!
//! Nothing in a document is executed: HTML is text, links only reach what the owner allows,
//! code is highlighted text.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;

use base64::Engine as _;
use gpui::{
    AnyElement, App, ElementId, FontStyle, FontWeight, Global, HighlightStyle, Hsla, Image, ImageFormat,
    InteractiveElement, IntoElement, ParentElement, Pixels, RenderOnce, ScrollHandle, SharedString,
    StatefulInteractiveElement, StrikethroughStyle, Styled, StyledImage, Window, div, img,
    prelude::FluentBuilder, px,
};
use soprano_text::markdown::{
    self as model, ImageSource, LinkTarget, MarkdownBlock, MarkdownInline, MarkdownListItem, MarkdownTable,
    TableAlignment, TableCell,
};
use soprano_ui::fonts::{TERMINAL_FONT_FAMILY, UI_FONT_FAMILY};
use soprano_ui::{IconName, SopranoTheme, icon};

use crate::colors::SurfaceColors;
use crate::rich::code::CodeBlock;
use crate::rich::inline::{InlinePiece, InlineText, flatten};
use crate::rich::text::{LinkHandler, RichText, overlay_range};

/// How a piece of Markdown is set (Swift `MarkdownStyle`, plus the reader's style sheet).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MarkdownStyle {
    pub font_size: f32,
    /// Line height as a multiple of the font size.
    pub line_height: f32,
    /// Text color as a fraction of the foreground.
    pub foreground_alpha: f32,
    /// User bubbles use the message foreground.
    pub uses_message_foreground: bool,
    /// Soft line breaks become hard ones (user messages).
    pub line_breaks: bool,
    /// The Markdown reader's typography, links, images and source HTML.
    pub reader: bool,
}

impl MarkdownStyle {
    /// The chat's assistant prose: 14 on a 1.625 line, foreground at 90 %.
    pub const ASSISTANT: Self = Self {
        font_size: 14.0,
        line_height: 1.625,
        foreground_alpha: 0.9,
        uses_message_foreground: false,
        line_breaks: false,
        reader: false,
    };
    /// A user bubble: full foreground, lines kept.
    pub const USER: Self =
        Self { foreground_alpha: 1.0, uses_message_foreground: true, line_breaks: true, ..Self::ASSISTANT };
    /// A reasoning line: foreground at 80 %, lines kept.
    pub const THOUGHT: Self = Self { foreground_alpha: 0.8, line_breaks: true, ..Self::ASSISTANT };
    /// The Markdown reader: 16/26.
    pub const READER: Self = Self {
        font_size: 16.0,
        line_height: 26.0 / 16.0,
        foreground_alpha: 1.0,
        uses_message_foreground: false,
        line_breaks: false,
        reader: true,
    };

    /// The chat's block margin: 0.65 rem at 14 pt prose ≈ 10.
    pub fn block_margin(&self) -> f32 {
        (self.font_size * 0.65 / 0.875).round()
    }
}

/// The document a reader shows: links and images resolve against it, inside `access_root`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReaderDocument {
    pub path: PathBuf,
    pub access_root: PathBuf,
}

impl ReaderDocument {
    /// `path`, with the access root `soprano_text::markdown::access_root` finds for it.
    pub fn new(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
        let access_root = model::access_root(&path);
        Self { path, access_root }
    }

    pub fn resolve_link(&self, destination: &str) -> Option<LinkTarget> {
        model::resolve_link(destination, &self.path, &self.access_root)
    }

    pub fn resolve_image(&self, source: &str) -> Option<ImageSource> {
        model::resolve_image(source, &self.path, &self.access_root)
    }
}

// MARK: - Parse cache

/// Parsed documents per text and style; a streaming message keeps only its latest parse
/// (each delta is a new, longer text). Emptied past 600 entries, as in Swift.
#[derive(Default)]
struct MarkdownCache {
    entries: HashMap<CacheKey, Arc<[MarkdownBlock]>>,
    streaming: Option<(CacheKey, Arc<[MarkdownBlock]>)>,
}

/// The source text and whether soft breaks were hard.
type CacheKey = (SharedString, bool);

impl Global for MarkdownCache {}

const CACHE_LIMIT: usize = 600;

/// The blocks of `text`, from the cache when it was parsed before.
pub fn parsed(text: &SharedString, line_breaks: bool, streaming: bool, cx: &mut App) -> Arc<[MarkdownBlock]> {
    let key = (text.clone(), line_breaks);
    let cache = cx.default_global::<MarkdownCache>();
    if let Some(blocks) = cache.entries.get(&key) {
        return blocks.clone();
    }
    if streaming
        && let Some((latest, blocks)) = &cache.streaming
        && *latest == key
    {
        return blocks.clone();
    }
    let blocks: Arc<[MarkdownBlock]> = model::parse(text, line_breaks).into();
    if streaming {
        cache.streaming = Some((key, blocks.clone()));
    } else {
        if cache.entries.len() > CACHE_LIMIT {
            cache.entries.clear();
        }
        cache.entries.insert(key, blocks.clone());
    }
    blocks
}

// MARK: - Element

#[derive(Clone)]
enum Source {
    Text(SharedString),
    Blocks(Arc<[MarkdownBlock]>),
}

/// Rendered Markdown, filling its parent's width (or shrinking to its content with
/// [`Markdown::shrink_to_fit`]). Text is selectable across blocks and copies with ⌘C (the
/// window needs gpui-component's `Root`, which mounts the selection layer).
#[derive(IntoElement)]
pub struct Markdown {
    id: ElementId,
    source: Source,
    style: MarkdownStyle,
    streaming: bool,
    on_link: Option<LinkHandler>,
    text_color: Option<Hsla>,
    shrink_to_fit: bool,
    document: Option<Rc<ReaderDocument>>,
    scroll: Option<ScrollHandle>,
    column: Option<(f32, [f32; 3])>,
}

/// Rendered Markdown from an already parsed block model.
pub struct MarkdownBlocks;

impl MarkdownBlocks {
    // The chat and reader name pre-parsed Markdown by this type; the element is `Markdown`.
    #[allow(clippy::new_ret_no_self)]
    pub fn new(id: impl Into<ElementId>, blocks: Arc<[MarkdownBlock]>, style: MarkdownStyle) -> Markdown {
        Markdown::with_source(id.into(), Source::Blocks(blocks), style)
    }
}

impl Markdown {
    pub fn new(id: impl Into<ElementId>, text: impl Into<SharedString>, style: MarkdownStyle) -> Self {
        Self::with_source(id.into(), Source::Text(text.into()), style)
    }

    fn with_source(id: ElementId, source: Source, style: MarkdownStyle) -> Self {
        Self {
            id,
            source,
            style,
            streaming: false,
            on_link: None,
            text_color: None,
            shrink_to_fit: false,
            document: None,
            scroll: None,
            column: None,
        }
    }

    /// The text is still arriving: only its latest parse is kept.
    pub fn streaming(mut self, streaming: bool) -> Self {
        self.streaming = streaming;
        self
    }

    /// Receives a clicked link's destination. Without a handler, `http`, `https` and
    /// `mailto` links open in their default app and other links do nothing
    /// (`MarkdownTextView.opensExternally`).
    pub fn on_link(mut self, handler: impl Fn(&str, &mut Window, &mut App) + 'static) -> Self {
        self.on_link = Some(Rc::new(handler));
        self
    }

    /// Overrides the body text color.
    pub fn text_color(mut self, color: Hsla) -> Self {
        self.text_color = Some(color);
        self
    }

    /// Sizes to the content (up to the parent's width) instead of filling the parent: prose
    /// shrink-wraps, code blocks and tables take the width they are given.
    pub fn shrink_to_fit(mut self, shrink: bool) -> Self {
        self.shrink_to_fit = shrink;
        self
    }

    /// The reader's document: links resolve against it (only resolvable ones are links) and
    /// relative images load from inside its access root.
    pub fn document(mut self, document: ReaderDocument) -> Self {
        self.document = Some(Rc::new(document));
        self
    }

    /// Makes the element its own vertical scroll container; each top-level block is one
    /// child, so `handle.scroll_to_top_of_item(block_index)` scrolls to a block.
    pub fn track_scroll(mut self, handle: &ScrollHandle) -> Self {
        self.scroll = Some(handle.clone());
        self
    }

    /// Centers the blocks in a column at most `width` wide, padded `[top, sides, bottom]`.
    pub fn column(mut self, width: f32, padding: [f32; 3]) -> Self {
        self.column = Some((width, padding));
        self
    }
}

/// Whether the chat hands a link to its default app (`MarkdownTextView.opensExternally`).
pub fn opens_externally(destination: &str) -> bool {
    let scheme = destination.split(':').next().unwrap_or_default().to_ascii_lowercase();
    destination.contains(':') && matches!(scheme.as_str(), "http" | "https" | "mailto")
}

impl RenderOnce for Markdown {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let blocks = match &self.source {
            Source::Text(text) => parsed(text, self.style.line_breaks, self.streaming, cx),
            Source::Blocks(blocks) => blocks.clone(),
        };
        let colors = SurfaceColors::of(cx);
        let zoom = cx.global::<SopranoTheme>().zoom();
        let body = self.text_color.unwrap_or_else(|| colors.foreground.opacity(self.style.foreground_alpha));
        let on_link = self.on_link.clone().unwrap_or_else(|| {
            Rc::new(|destination: &str, _: &mut Window, cx: &mut App| {
                if opens_externally(destination) {
                    cx.open_url(destination);
                }
            })
        });
        let ctx = Ctx {
            style: self.style,
            colors,
            body,
            zoom,
            on_link,
            document: self.document.clone(),
            order: std::cell::Cell::new(0),
        };
        let rendered = ctx.blocks(&blocks, Nest::default());
        let style = self.style;
        let column = self.column;
        let mut root = div()
            .id(self.id)
            .flex()
            .flex_col()
            .font_family(UI_FONT_FAMILY)
            .text_size(ctx.z(style.font_size))
            .line_height(ctx.z(style.font_size * style.line_height))
            .text_color(body)
            .map(|root| if self.shrink_to_fit { root.max_w_full() } else { root.w_full() })
            .when_some(column, |root, (_, [top, sides, bottom])| {
                root.items_center().pt(ctx.z(top)).px(ctx.z(sides)).pb(ctx.z(bottom))
            })
            .when_some(self.scroll.as_ref(), |root, handle| {
                root.size_full().overflow_y_scroll().track_scroll(handle)
            });
        let mut previous_bottom: Option<f32> = None;
        for block in rendered {
            let spacing = previous_bottom.map_or(0.0, |bottom| bottom.max(block.top));
            previous_bottom = Some(block.bottom);
            root = root.child(
                div()
                    .mt(ctx.z(spacing))
                    .flex_shrink_0()
                    .map(|child| match column {
                        Some((width, _)) => child.w_full().max_w(ctx.z(width)),
                        None if self.shrink_to_fit => child.max_w_full(),
                        None => child.w_full(),
                    })
                    .child(block.element),
            );
        }
        root
    }
}

// MARK: - Rendering

struct Ctx {
    style: MarkdownStyle,
    colors: SurfaceColors,
    body: Hsla,
    zoom: f32,
    on_link: LinkHandler,
    document: Option<Rc<ReaderDocument>>,
    order: std::cell::Cell<u64>,
}

/// Where a block sits: inside a list item (tight spacing), how deep in lists and quotes.
#[derive(Clone, Copy, Default)]
struct Nest {
    tight: bool,
    bullet_depth: usize,
    ordered_depth: usize,
    in_quote: bool,
}

struct Rendered {
    element: AnyElement,
    top: f32,
    bottom: f32,
}

/// Font, size, line height and color of one run of prose.
#[derive(Clone, Copy)]
struct TextLook {
    size: f32,
    line_height: f32,
    weight: FontWeight,
    color: Hsla,
}

impl Ctx {
    fn z(&self, value: f32) -> Pixels {
        px(value * self.zoom)
    }

    fn next_id(&self) -> (ElementId, u64) {
        let order = self.order.get();
        self.order.set(order + 1);
        (ElementId::NamedInteger("markdown-text".into(), order), order)
    }

    fn reader(&self) -> bool {
        self.style.reader
    }

    fn body_look(&self, nest: Nest) -> TextLook {
        let size = self.style.font_size;
        TextLook {
            size,
            line_height: size * self.style.line_height,
            weight: FontWeight::NORMAL,
            color: if self.reader() && nest.in_quote { self.colors.muted } else { self.body },
        }
    }

    /// Margins (top, bottom) of a prose-like block.
    fn block_margins(&self, nest: Nest) -> (f32, f32) {
        if self.reader() {
            (0.0, 16.0)
        } else {
            let margin = if nest.tight { 4.0 } else { self.style.block_margin() };
            (margin, margin)
        }
    }

    fn blocks(&self, blocks: &[MarkdownBlock], nest: Nest) -> Vec<Rendered> {
        blocks.iter().map(|block| self.block(block, nest)).collect()
    }

    /// Blocks stacked with collapsed margins; the container's own margins come from its
    /// first and last child (the reader drops a last child's bottom margin, as `li >
    /// :last-child` and `blockquote > :last-child` do).
    fn stack(&self, rendered: Vec<Rendered>) -> Rendered {
        let top = rendered.first().map_or(0.0, |first| first.top);
        let bottom = if self.reader() { 0.0 } else { rendered.last().map_or(0.0, |last| last.bottom) };
        let mut column = div().flex().flex_col().w_full().min_w_0();
        let mut previous: Option<f32> = None;
        for block in rendered {
            let spacing = previous.map_or(0.0, |bottom| bottom.max(block.top));
            previous = Some(block.bottom);
            column = column.child(div().mt(self.z(spacing)).w_full().child(block.element));
        }
        Rendered { element: column.into_any_element(), top, bottom }
    }

    fn block(&self, block: &MarkdownBlock, nest: Nest) -> Rendered {
        let (top, bottom) = self.block_margins(nest);
        match block {
            MarkdownBlock::Paragraph(inlines) => {
                Rendered { element: self.paragraph(inlines, self.body_look(nest)), top, bottom }
            }
            MarkdownBlock::Heading { level, inlines, .. } => self.heading(*level, inlines, nest),
            MarkdownBlock::List { ordered, start, items } => self.list(*ordered, *start, items, nest),
            MarkdownBlock::Blockquote(blocks) => self.quote(blocks, nest),
            MarkdownBlock::Code { language, code, tokens } => {
                let (id, order) = self.next_id();
                let element = CodeBlock::new(id, language.as_deref(), code, tokens)
                    .wrap(!self.reader())
                    .document_order(order);
                let margin = if self.reader() {
                    (0.0, 16.0)
                } else {
                    (self.style.block_margin(), self.style.block_margin())
                };
                Rendered { element: element.into_any_element(), top: margin.0, bottom: margin.1 }
            }
            MarkdownBlock::Table(table) => {
                let margin = if self.reader() {
                    (0.0, 16.0)
                } else {
                    (self.style.block_margin(), self.style.block_margin())
                };
                Rendered { element: self.table(table), top: margin.0, bottom: margin.1 }
            }
            MarkdownBlock::ThematicBreak => {
                let margin = if self.reader() { 24.0 } else { 16.0 };
                let rule = div().w_full().h(px(1.0)).bg(self.colors.border);
                Rendered { element: rule.into_any_element(), top: margin, bottom: margin }
            }
            MarkdownBlock::Html(source) => {
                let source = source.strip_suffix('\n').unwrap_or(source);
                let inlines = [MarkdownInline::Text(source.to_string())];
                if self.reader() {
                    let look = TextLook { color: self.colors.muted, ..self.body_look(nest) };
                    let element =
                        div().font_family(TERMINAL_FONT_FAMILY).child(self.paragraph(&inlines, look));
                    Rendered { element: element.into_any_element(), top, bottom }
                } else {
                    let margin = self.style.block_margin();
                    Rendered {
                        element: self.paragraph(&inlines, self.body_look(nest)),
                        top: margin,
                        bottom: margin,
                    }
                }
            }
        }
    }

    fn heading(&self, level: u8, inlines: &[MarkdownInline], nest: Nest) -> Rendered {
        if self.reader() {
            // h1 28/34, h2 21/28 over a rule, h3 17/22 medium, h4–h6 16/26 semibold.
            let (size, line_height, weight, top, bottom) = match level {
                1 => (28.0, 34.0, FontWeight::NORMAL, 0.0, 12.0),
                2 => (21.0, 28.0, FontWeight::NORMAL, 28.0, 10.0),
                3 => (17.0, 22.0, FontWeight::MEDIUM, 24.0, 8.0),
                _ => (16.0, 26.0, FontWeight::SEMIBOLD, 20.0, 6.0),
            };
            let look = TextLook { size, line_height, weight, color: self.colors.foreground };
            let text = self.paragraph(inlines, look);
            let element = if level == 2 {
                div()
                    .w_full()
                    .pb(self.z(6.0))
                    .border_b_1()
                    .border_color(self.colors.border)
                    .child(text)
                    .into_any_element()
            } else {
                text
            };
            return Rendered { element, top, bottom };
        }
        let base = self.style.font_size;
        let size = match level {
            1 => base + 6.0,
            2 => base + 4.0,
            3 => base + 2.0,
            _ => base,
        };
        let color = if level == 6 { self.colors.muted } else { self.colors.foreground };
        let look = TextLook { size, line_height: (size * 1.3).round(), weight: FontWeight::SEMIBOLD, color };
        let _ = nest;
        Rendered { element: self.paragraph(inlines, look), top: 20.0, bottom: 8.0 }
    }

    /// One paragraph: its text runs and (in the reader) its images, in order.
    fn paragraph(&self, inlines: &[MarkdownInline], look: TextLook) -> AnyElement {
        let pieces = flatten(inlines, self.reader());
        let mut column = div()
            .flex()
            .flex_col()
            .w_full()
            .min_w_0()
            .text_size(self.z(look.size))
            .line_height(self.z(look.line_height))
            .font_weight(look.weight)
            .text_color(look.color);
        for piece in pieces {
            column = column.child(match piece {
                InlinePiece::Text(text) => self.rich_text(text, look),
                InlinePiece::Image { source, alt, title, link } => {
                    self.image(&source, &alt, title.as_deref(), link.as_deref(), look)
                }
            });
        }
        column.into_any_element()
    }

    /// A run of inline text: marks as highlights, inline code in the code font on a
    /// `foreground 10%` chip, links in the link color (the reader: only links that lead
    /// somewhere).
    fn rich_text(&self, text: InlineText, look: TextLook) -> AnyElement {
        let chip = self.colors.foreground.opacity(0.1);
        let link_color = self.colors.info;
        let mut highlights: Vec<(std::ops::Range<usize>, HighlightStyle)> = Vec::new();
        let mut overrides: Vec<(std::ops::Range<usize>, SharedString)> = Vec::new();
        for span in &text.spans {
            let marks = span.marks;
            let mut style = HighlightStyle::default();
            if marks.strong {
                style.font_weight = Some(if look.weight.0 >= FontWeight::SEMIBOLD.0 {
                    FontWeight::BOLD
                } else {
                    FontWeight::SEMIBOLD
                });
            }
            if marks.emphasis {
                style.font_style = Some(FontStyle::Italic);
            }
            if marks.strike {
                style.strikethrough = Some(StrikethroughStyle { thickness: px(1.0), color: None });
            }
            if marks.code {
                style.color = Some(self.colors.foreground);
                style.background_color = Some(chip);
                overrides.push((span.range.clone(), TERMINAL_FONT_FAMILY.into()));
            }
            if marks.link && !self.reader() {
                style.color = Some(link_color);
            }
            if style != HighlightStyle::default() {
                highlights.push((span.range.clone(), style));
            }
        }
        let links: Vec<(std::ops::Range<usize>, SharedString)> = text
            .links
            .iter()
            .filter(|link| {
                self.document
                    .as_ref()
                    .is_none_or(|document| document.resolve_link(&link.destination).is_some())
            })
            .map(|link| (link.range.clone(), SharedString::from(link.destination.clone())))
            .collect();
        if self.reader() {
            for (range, _) in &links {
                highlights = overlay_range(&highlights, range.clone(), |style| HighlightStyle {
                    color: Some(link_color),
                    ..style
                });
            }
        }
        let (id, order) = self.next_id();
        let mut element = RichText::new(id, SharedString::from(text.text))
            .highlights(highlights)
            .font_overrides(overrides)
            .document_order(order)
            .selection_color(self.colors.selection)
            .underline_hovered_link(self.reader());
        if !links.is_empty() {
            element = element.links(links, self.on_link.clone());
        }
        element.into_any_element()
    }

    /// A reader image: workspace files, `https` and `data:image/` sources; anything else (and
    /// the chat) shows the alt text, as does an image that fails to load. An image inside a
    /// link opens it on a click; its title is its tooltip.
    fn image(
        &self,
        source: &str,
        alt: &str,
        title: Option<&str>,
        link: Option<&str>,
        look: TextLook,
    ) -> AnyElement {
        let alt_text = |ctx: &Self| {
            ctx.rich_text(InlineText { text: alt.to_string(), spans: Vec::new(), links: Vec::new() }, look)
        };
        let resolved = self.document.as_ref().and_then(|document| document.resolve_image(source));
        let image = match resolved {
            Some(ImageSource::File(path)) => Some(img(path)),
            Some(ImageSource::Remote(url)) => Some(img(url)),
            Some(ImageSource::Data(uri)) => decode_data_image(&uri).map(|image| img(Arc::new(image))),
            None => None,
        };
        let Some(image) = image else { return alt_text(self) };
        // GPUI's fallback is built when loading fails; it shows the alt text in the body style.
        let fallback_text = SharedString::from(alt.to_string());
        let fallback_color = look.color;
        let image = image.max_w_full().rounded(self.z(8.0)).overflow_hidden().with_fallback(move || {
            div().text_color(fallback_color).child(fallback_text.clone()).into_any_element()
        });
        let (id, _) = self.next_id();
        let link = link
            .filter(|destination| {
                self.document.as_ref().is_none_or(|document| document.resolve_link(destination).is_some())
            })
            .map(str::to_string);
        let on_link = self.on_link.clone();
        div()
            .id(id)
            .w_full()
            .child(image)
            .when_some(title.filter(|title| !title.is_empty()).map(str::to_string), |image, title| {
                image.tooltip(soprano_ui::tooltip(title))
            })
            .when_some(link, move |image, destination| {
                image.cursor_pointer().on_click(move |_, window, cx| on_link(&destination, window, cx))
            })
            .into_any_element()
    }

    fn list(&self, ordered: bool, start: u64, items: &[MarkdownListItem], nest: Nest) -> Rendered {
        let gutter = if self.reader() { 24.0 } else { 20.0 };
        let look = self.body_look(nest);
        let mut column = div().flex().flex_col().w_full();
        for (index, item) in items.iter().enumerate() {
            let mut inner = nest;
            inner.tight = true;
            if ordered {
                inner.ordered_depth += 1;
            } else {
                inner.bullet_depth += 1;
            }
            let marker: AnyElement = match item.checkbox {
                Some(checked) => self.checkbox(checked, look),
                None => {
                    let text = if ordered {
                        model::ordered_marker(start + index as u64, nest.ordered_depth)
                    } else {
                        model::bullet(nest.bullet_depth).to_string()
                    };
                    let single = text.chars().count() == 1;
                    let color = if single && !self.reader() { look.color.opacity(0.6) } else { look.color };
                    div().text_color(color).whitespace_nowrap().child(text).into_any_element()
                }
            };
            let content = self.stack(self.blocks(&item.blocks, inner));
            let row = div()
                .flex()
                .flex_row()
                .items_start()
                .w_full()
                .child(
                    div()
                        .flex_shrink_0()
                        .w(self.z(gutter))
                        .h(self.z(look.line_height))
                        .pr(self.z(6.0))
                        .flex()
                        .flex_row()
                        .items_center()
                        .justify_end()
                        .text_size(self.z(look.size))
                        .line_height(self.z(look.line_height))
                        .child(marker),
                )
                .child(div().flex_1().min_w_0().child(content.element));
            column = column.child(div().when(index > 0, |row| row.mt(self.z(4.0))).w_full().child(row));
        }
        let (top, bottom) = self.block_margins(nest);
        Rendered { element: column.into_any_element(), top, bottom }
    }

    /// A task box: a filled accent square with a check, or an empty muted square.
    fn checkbox(&self, checked: bool, look: TextLook) -> AnyElement {
        let side = self.z((look.size - 2.0).max(10.0));
        let tint = if checked { self.colors.merged } else { self.colors.muted };
        div()
            .size(side)
            .flex_shrink_0()
            .rounded(self.z(3.0))
            .border_1()
            .border_color(tint)
            .flex()
            .items_center()
            .justify_center()
            .when(checked, |square| {
                square.bg(tint).child(
                    icon(IconName::Check)
                        .size((look.size - 4.0).max(8.0) * self.zoom)
                        .color(self.colors.background),
                )
            })
            .into_any_element()
    }

    fn quote(&self, blocks: &[MarkdownBlock], nest: Nest) -> Rendered {
        let inner = Nest { in_quote: true, ..nest };
        let content = self.stack(self.blocks(blocks, inner));
        let rule_color =
            if self.reader() { self.colors.foreground.opacity(0.35) } else { self.body.opacity(0.35) };
        let element = div()
            .flex()
            .flex_row()
            .w_full()
            .child(div().flex_shrink_0().w(px(2.0)).bg(rule_color))
            .child(div().flex_1().min_w_0().pl(self.z(12.8)).child(content.element));
        let (top, bottom) = if self.reader() {
            (0.0, 16.0)
        } else {
            let margin = self.style.block_margin();
            (margin.max(content.top), margin.max(content.bottom))
        };
        Rendered { element: element.into_any_element(), top, bottom }
    }

    /// A GFM table with row rules only; cells wrap (chat) or the table scrolls sideways at
    /// its natural width (reader).
    fn table(&self, table: &MarkdownTable) -> AnyElement {
        let count = table.column_count().max(1);
        let reader = self.reader();
        let (size, line_height) = if reader {
            (13.0, 18.0)
        } else {
            (self.style.font_size, (self.style.font_size * self.style.line_height).round())
        };
        let rule = if reader { self.colors.border } else { self.colors.border.opacity(0.6) };
        let rows: Vec<(bool, &Vec<TableCell>)> = (!table.header.is_empty())
            .then_some((true, &table.header))
            .into_iter()
            .chain(table.rows.iter().map(|row| (false, row)))
            .collect();
        let row_count = rows.len();
        let mut grid = div()
            .grid()
            .map(|grid| {
                if reader {
                    grid.grid_cols_max_content(count as u16).min_w_full()
                } else {
                    grid.grid_cols(count as u16).w_full()
                }
            })
            .text_size(self.z(size))
            .line_height(self.z(line_height));
        let empty = TableCell::new(Vec::new());
        for (row_index, (header, cells)) in rows.into_iter().enumerate() {
            for column in 0..count {
                // A cell covered by a neighbor's span is not drawn; a short row gets empty cells.
                let cell = cells.get(column).unwrap_or(&empty);
                if cell.is_covered() {
                    continue;
                }
                let colspan = cell.colspan.clamp(1, count - column);
                let rowspan = cell.rowspan.clamp(1, row_count - row_index);
                let look = TextLook {
                    size,
                    line_height,
                    weight: if header { FontWeight::SEMIBOLD } else { FontWeight::NORMAL },
                    color: if header { self.colors.foreground } else { self.body },
                };
                let vertical = if header {
                    9.0
                } else if reader {
                    8.0
                } else {
                    7.0
                };
                let last_column = column + colspan == count;
                let (left, right) = if reader {
                    (12.0, 12.0)
                } else {
                    (if column == 0 { 0.0 } else { 12.0 }, if last_column { 0.0 } else { 12.0 })
                };
                let text = self.paragraph(&cell.inlines, look);
                let cell = div()
                    .min_w_0()
                    .row_start(row_index as i16 + 1)
                    .row_span(rowspan as u16)
                    .col_start(column as i16 + 1)
                    .col_span(colspan as u16)
                    .py(self.z(vertical))
                    .pl(self.z(left))
                    .pr(self.z(right))
                    .when(row_index + rowspan < row_count, |cell| cell.border_b_1().border_color(rule))
                    .map(|cell| match table.alignment(column) {
                        Some(TableAlignment::Center) => cell.text_center(),
                        Some(TableAlignment::Right) => cell.text_right(),
                        _ => cell,
                    })
                    .child(text);
                grid = grid.child(cell);
            }
        }
        if reader {
            let (id, _) = self.next_id();
            div().id(id).w_full().overflow_x_scroll().child(grid).into_any_element()
        } else {
            grid.into_any_element()
        }
    }
}

/// A `data:image/…;base64,…` URI as an image GPUI can draw.
fn decode_data_image(uri: &str) -> Option<Image> {
    let (header, payload) = uri.split_once(',')?;
    let mime = header.strip_prefix("data:")?.split(';').next()?.to_ascii_lowercase();
    let format = ImageFormat::from_mime_type(&mime)?;
    let bytes = if header.to_ascii_lowercase().ends_with(";base64") {
        base64::engine::general_purpose::STANDARD.decode(payload.trim()).ok()?
    } else {
        // A plain data URI is percent-encoded (`data:image/svg+xml,%3Csvg…`).
        percent_encoding::percent_decode_str(payload).collect()
    };
    Some(Image::from_bytes(format, bytes))
}

/// The top-level block that holds the heading `anchor` (the reader scrolls to it).
pub fn anchor_block(blocks: &[MarkdownBlock], anchor: &str) -> Option<usize> {
    fn contains(block: &MarkdownBlock, anchor: &str) -> bool {
        match block {
            MarkdownBlock::Heading { anchor: own, .. } => own == anchor,
            MarkdownBlock::Blockquote(blocks) => blocks.iter().any(|block| contains(block, anchor)),
            MarkdownBlock::List { items, .. } => {
                items.iter().any(|item| item.blocks.iter().any(|block| contains(block, anchor)))
            }
            _ => false,
        }
    }
    blocks.iter().position(|block| contains(block, anchor))
}

/// The plain text of a heading-free document for tests and accessibility.
pub fn document_text(blocks: &[MarkdownBlock]) -> String {
    let mut lines = Vec::new();
    for block in blocks {
        match block {
            MarkdownBlock::Paragraph(inlines) | MarkdownBlock::Heading { inlines, .. } => {
                lines.push(model::plain_text(inlines))
            }
            MarkdownBlock::List { items, .. } => {
                for item in items {
                    lines.push(document_text(&item.blocks));
                }
            }
            MarkdownBlock::Blockquote(blocks) => lines.push(document_text(blocks)),
            MarkdownBlock::Code { code, .. } => lines.push(code.trim_end_matches('\n').to_string()),
            MarkdownBlock::Table(table) => {
                for row in std::iter::once(&table.header).chain(&table.rows) {
                    lines.push(
                        row.iter()
                            .filter(|cell| !cell.is_covered())
                            .map(|cell| model::plain_text(&cell.inlines))
                            .collect::<Vec<_>>()
                            .join("\t"),
                    );
                }
            }
            MarkdownBlock::ThematicBreak => {}
            MarkdownBlock::Html(source) => lines.push(source.trim_end_matches('\n').to_string()),
        }
    }
    lines.join("\n")
}

/// Whether `path` names a Markdown file the reader opens (`.md`, `.markdown`).
pub fn is_markdown(path: &Path) -> bool {
    model::is_markdown(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_chat_styles_match_the_swift_presets() {
        let (assistant, user) = (MarkdownStyle::ASSISTANT, MarkdownStyle::USER);
        assert_eq!(assistant.font_size, 14.0);
        assert_eq!(assistant.foreground_alpha, 0.9);
        assert_eq!(
            (assistant.line_breaks, user.line_breaks, user.uses_message_foreground),
            (false, true, true)
        );
        assert_eq!(MarkdownStyle::THOUGHT.foreground_alpha, 0.8);
        assert_eq!(MarkdownStyle::ASSISTANT.block_margin(), 10.0);
        assert_eq!(MarkdownStyle::READER.font_size * MarkdownStyle::READER.line_height, 26.0);
    }

    #[test]
    fn only_web_and_mail_links_open_from_the_chat() {
        assert!(opens_externally("https://example.com"));
        assert!(opens_externally("HTTP://example.com"));
        assert!(opens_externally("mailto:a@b.c"));
        assert!(!opens_externally("file:///etc/passwd"));
        assert!(!opens_externally("javascript:alert(1)"));
        assert!(!opens_externally("docs/guide.md"));
        assert!(!opens_externally("vscode://open"));
    }

    #[test]
    fn data_images_decode_and_other_schemes_do_not() {
        // A 1×1 PNG.
        let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
        assert!(decode_data_image(png).is_some());
        assert!(decode_data_image("data:text/html;base64,PGI+").is_none());
        assert!(decode_data_image("data:image/png;base64").is_none());
        let svg = decode_data_image("data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'/%3E")
            .expect("a percent-encoded SVG");
        assert_eq!(svg.bytes(), b"<svg xmlns='http://www.w3.org/2000/svg'/>");
    }

    #[test]
    fn anchors_are_found_inside_quotes_and_lists() {
        let blocks = model::parse("intro\n\n> # Quoted\n\n- item\n\n  ## Nested\n", false);
        assert_eq!(anchor_block(&blocks, "quoted"), Some(1));
        assert_eq!(anchor_block(&blocks, "nested"), Some(2));
        assert_eq!(anchor_block(&blocks, "missing"), None);
    }

    #[gpui::test]
    fn parsed_text_is_cached_and_streaming_keeps_only_the_latest(cx: &mut gpui::TestAppContext) {
        cx.update(|cx| {
            let text = SharedString::from("# Title\n\nbody");
            let first = parsed(&text, false, false, cx);
            let again = parsed(&text, false, false, cx);
            assert!(Arc::ptr_eq(&first, &again));
            let streamed = SharedString::from("partial **bo");
            let one = parsed(&streamed, false, true, cx);
            let two = parsed(&streamed, false, true, cx);
            assert!(Arc::ptr_eq(&one, &two));
            let longer = SharedString::from("partial **bold**");
            let _ = parsed(&longer, false, true, cx);
            let three = parsed(&streamed, false, true, cx);
            assert!(!Arc::ptr_eq(&one, &three));
        });
    }
}
