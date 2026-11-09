//! Markdown for the chat and the Markdown reader (port of `Chat/Markdown/MarkdownDocument.swift`,
//! the model-level rules of `MarkdownRenderer.swift`, and the safety and navigation rules of
//! `MarkdownHTMLRenderer.swift` and `MarkdownPaneView.swift`).
//!
//! Text → block model with `pulldown-cmark` (CommonMark + GFM tables, task lists,
//! strikethrough). The GPUI renderer draws the model natively, so nothing in a document is
//! ever executed: source-provided HTML stays visible as source text, links and images only
//! reach what [`resolve_link`] and [`resolve_image`] allow, and code is highlighted text.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use percent_encoding::percent_decode_str;
use pulldown_cmark::{CodeBlockKind, Event, LinkType, Options, Parser, Tag, TagEnd};
use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::is_combining_mark;

use crate::syntax::{self, CodeLanguage, SyntaxToken};

/// Inline Markdown, reduced to what Soprano renders.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum MarkdownInline {
    Text(String),
    Emphasis(Vec<MarkdownInline>),
    Strong(Vec<MarkdownInline>),
    Strikethrough(Vec<MarkdownInline>),
    Code(String),
    /// Resolve `destination` with [`resolve_link`]; children render as plain text when it
    /// resolves to nothing.
    Link {
        destination: Option<String>,
        title: Option<String>,
        children: Vec<MarkdownInline>,
    },
    /// The chat shows images as their alt text (agent output may point anywhere; nothing is
    /// fetched); the reader shows what [`resolve_image`] allows, else the alt text.
    Image {
        source: Option<String>,
        title: Option<String>,
        alt: String,
    },
    SoftBreak,
    LineBreak,
    /// Raw inline HTML stays visible as source text, never interpreted.
    Html(String),
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct MarkdownListItem {
    /// `None` = no task checkbox; `Some(true)` = `- [x]`.
    pub checkbox: Option<bool>,
    pub blocks: Vec<MarkdownBlock>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TableAlignment {
    Left,
    Center,
    Right,
}

/// One table cell. GitHub-flavored table spans (as swift-markdown parses them): an empty
/// cell written as adjacent pipes (`||`) widens the cell before it, and a body cell holding
/// only `^` lengthens the cell above it. A covered cell keeps its place in the row with a
/// zero `colspan` or `rowspan`; renderers skip it.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct TableCell {
    pub inlines: Vec<MarkdownInline>,
    pub colspan: usize,
    pub rowspan: usize,
}

impl TableCell {
    pub fn new(inlines: Vec<MarkdownInline>) -> Self {
        Self { inlines, colspan: 1, rowspan: 1 }
    }

    /// Covered by a neighbor's span: not drawn.
    pub fn is_covered(&self) -> bool {
        self.colspan == 0 || self.rowspan == 0
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct MarkdownTable {
    /// One per column; `None` is the natural alignment.
    pub alignments: Vec<Option<TableAlignment>>,
    pub header: Vec<TableCell>,
    pub rows: Vec<Vec<TableCell>>,
}

impl MarkdownTable {
    pub fn column_count(&self) -> usize {
        self.rows.iter().map(Vec::len).max().unwrap_or(0).max(self.header.len())
    }

    pub fn alignment(&self, column: usize) -> Option<TableAlignment> {
        self.alignments.get(column).copied().flatten()
    }

    /// A `||` cell widens the nearest drawn cell before it in its row.
    fn span_columns(row: &mut [TableCell], column: usize) {
        if let Some(owner) = row[..column].iter_mut().rev().find(|cell| cell.colspan > 0) {
            owner.colspan += 1;
            row[column].colspan = 0;
        }
    }

    /// A `^` cell lengthens the nearest drawn cell above it in its column.
    fn span_rows(&mut self, row: usize, column: usize) {
        let Some(above) = (0..row).rev().find(|above| {
            self.rows[*above].get(column).is_some_and(|cell| cell.rowspan > 0 && cell.colspan > 0)
        }) else {
            return;
        };
        self.rows[above][column].rowspan += 1;
        let cell = &mut self.rows[row][column];
        cell.rowspan = 0;
        cell.inlines.clear();
    }
}

/// Block Markdown: paragraphs, headings, lists, quotes, code, tables, rules.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum MarkdownBlock {
    Paragraph(Vec<MarkdownInline>),
    /// `anchor` is the heading's unique id (GitHub-style slug) that `#fragment` links target.
    Heading {
        level: u8,
        inlines: Vec<MarkdownInline>,
        anchor: String,
    },
    List {
        ordered: bool,
        start: u64,
        items: Vec<MarkdownListItem>,
    },
    Blockquote(Vec<MarkdownBlock>),
    /// `tokens` are the syntax tokens (UTF-8 byte ranges of `code`) when `language` names one.
    Code {
        language: Option<String>,
        code: String,
        tokens: Vec<SyntaxToken>,
    },
    Table(MarkdownTable),
    ThematicBreak,
    /// Source-provided HTML, shown as source text (muted, monospaced in the reader).
    Html(String),
}

/// Parses Markdown into blocks. `line_breaks` turns soft line breaks into hard ones (user
/// messages keep their lines).
pub fn parse(text: &str, line_breaks: bool) -> Vec<MarkdownBlock> {
    // `Document(parsing:)` turns on smart punctuation: ’ “” – — ….
    let options = Options::ENABLE_TABLES
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_SMART_PUNCTUATION;
    let (events, ranges): (Vec<Event>, Vec<std::ops::Range<usize>>) =
        Parser::new_ext(text, options).into_offset_iter().unzip();
    let mut builder =
        Builder { events: &events, ranges: &ranges, position: 0, line_breaks, slugs: HashMap::new() };
    builder.blocks_until(None)
}

/// Text of inlines as it reads (alt text for images, breaks as spaces/newlines).
pub fn plain_text(inlines: &[MarkdownInline]) -> String {
    let mut result = String::new();
    append_plain_text(inlines, &mut result);
    result
}

fn append_plain_text(inlines: &[MarkdownInline], result: &mut String) {
    for inline in inlines {
        match inline {
            MarkdownInline::Text(text) | MarkdownInline::Code(text) | MarkdownInline::Html(text) => {
                result.push_str(text)
            }
            MarkdownInline::Emphasis(children)
            | MarkdownInline::Strong(children)
            | MarkdownInline::Strikethrough(children)
            | MarkdownInline::Link { children, .. } => append_plain_text(children, result),
            MarkdownInline::Image { alt, .. } => result.push_str(alt),
            MarkdownInline::SoftBreak => result.push(' '),
            MarkdownInline::LineBreak => result.push('\n'),
        }
    }
}

/// Syntax tokens for a code block naming `language` (```` ```ts ````); empty otherwise.
pub fn highlighted_code(code: &str, language: Option<&str>) -> Vec<SyntaxToken> {
    language.and_then(CodeLanguage::named).map(|language| syntax::tokens(code, language)).unwrap_or_default()
}

/// The marker of an unordered list item at `depth` (0 = outermost): •, ◦, then ▪.
pub fn bullet(depth: usize) -> &'static str {
    ["•", "◦", "▪"][depth.min(2)]
}

/// The marker of item `number` of an ordered list at `depth`: `1.`, then `a.`, then `i.`,
/// repeating.
pub fn ordered_marker(number: u64, depth: usize) -> String {
    match depth % 3 {
        1 => {
            let mut value = number.max(1);
            let mut letters = Vec::new();
            while value > 0 {
                value -= 1;
                letters.push((b'a' + (value % 26) as u8) as char);
                value /= 26;
            }
            letters.iter().rev().collect::<String>() + "."
        }
        2 => roman(number).to_lowercase() + ".",
        _ => format!("{number}."),
    }
}

fn roman(number: u64) -> String {
    const TABLE: [(u64, &str); 13] = [
        (1000, "M"),
        (900, "CM"),
        (500, "D"),
        (400, "CD"),
        (100, "C"),
        (90, "XC"),
        (50, "L"),
        (40, "XL"),
        (10, "X"),
        (9, "IX"),
        (5, "V"),
        (4, "IV"),
        (1, "I"),
    ];
    let mut value = number.max(1);
    let mut result = String::new();
    for (amount, letters) in TABLE {
        while value >= amount {
            result.push_str(letters);
            value -= amount;
        }
    }
    result
}

/// A heading's anchor: case and diacritics folded (full case folding, so `Straße` reads as
/// `strasse`; Hangul and other precomposed letters recomposed), alphanumeric runs joined by
/// `-`, "section" when nothing is left.
pub fn heading_slug(text: &str) -> String {
    let without_marks: String = text.nfd().filter(|character| !is_combining_mark(*character)).collect();
    let folded: String = caseless::default_case_fold_str(&without_marks).nfc().collect();
    let mut slug = String::new();
    let mut needs_dash = false;
    for character in folded.chars() {
        if character.is_alphanumeric() {
            if needs_dash && !slug.is_empty() {
                slug.push('-');
            }
            slug.push(character);
            needs_dash = false;
        } else {
            needs_dash = true;
        }
    }
    if slug.is_empty() { "section".to_string() } else { slug }
}

struct Builder<'a, 'e> {
    events: &'a [Event<'e>],
    /// The source range of each event (an empty table cell's range tells `||` from `| |`).
    ranges: &'a [std::ops::Range<usize>],
    position: usize,
    line_breaks: bool,
    /// How often each heading slug was used, for unique anchors (`a`, `a-1`, …).
    slugs: HashMap<String, usize>,
}

impl<'a, 'e> Builder<'a, 'e> {
    fn next(&mut self) -> Option<&'a Event<'e>> {
        let events = self.events;
        let event = events.get(self.position);
        self.position += 1;
        event
    }

    fn peek(&self) -> Option<&'a Event<'e>> {
        let events = self.events;
        events.get(self.position)
    }

    /// Blocks until the end tag `end` (or the end of the events).
    fn blocks_until(&mut self, end: Option<TagEnd>) -> Vec<MarkdownBlock> {
        let mut blocks = Vec::new();
        while let Some(event) = self.peek() {
            if let Event::End(tag) = event
                && Some(*tag) == end
            {
                self.position += 1;
                break;
            }
            if let Some(block) = self.block() {
                blocks.push(block);
            }
        }
        blocks
    }

    fn block(&mut self) -> Option<MarkdownBlock> {
        let event = self.next()?.clone();
        match event {
            Event::Start(Tag::Paragraph) => {
                Some(MarkdownBlock::Paragraph(self.inlines_until(TagEnd::Paragraph)))
            }
            Event::Start(Tag::Heading { level, .. }) => {
                let inlines = self.inlines_until(TagEnd::Heading(level));
                let anchor = self.unique_slug(heading_slug(&plain_text(&inlines)));
                Some(MarkdownBlock::Heading { level: level as u8, inlines, anchor })
            }
            Event::Start(Tag::BlockQuote(kind)) => {
                Some(MarkdownBlock::Blockquote(self.blocks_until(Some(TagEnd::BlockQuote(kind)))))
            }
            Event::Start(Tag::CodeBlock(kind)) => {
                let mut code = String::new();
                while let Some(event) = self.next() {
                    match event {
                        Event::Text(text) => code.push_str(text),
                        Event::End(TagEnd::CodeBlock) => break,
                        _ => {}
                    }
                }
                if code.ends_with('\n') {
                    code.pop();
                }
                let language = match kind {
                    CodeBlockKind::Fenced(info) => {
                        Some(info.trim().to_string()).filter(|info| !info.is_empty())
                    }
                    CodeBlockKind::Indented => None,
                };
                let tokens = highlighted_code(&code, language.as_deref());
                Some(MarkdownBlock::Code { language, code, tokens })
            }
            Event::Start(Tag::HtmlBlock) => {
                let mut raw = String::new();
                while let Some(event) = self.next() {
                    match event {
                        Event::Html(text) | Event::Text(text) => raw.push_str(text),
                        Event::End(TagEnd::HtmlBlock) => break,
                        _ => {}
                    }
                }
                Some(MarkdownBlock::Html(raw.trim_end_matches('\n').to_string()))
            }
            Event::Start(Tag::List(start)) => {
                let ordered = start.is_some();
                let mut items = Vec::new();
                while let Some(event) = self.next() {
                    match event {
                        Event::Start(Tag::Item) => items.push(self.item()),
                        Event::End(TagEnd::List(_)) => break,
                        _ => {}
                    }
                }
                Some(MarkdownBlock::List { ordered, start: start.unwrap_or(1), items })
            }
            Event::Start(Tag::Table(alignments)) => Some(MarkdownBlock::Table(self.table(&alignments))),
            Event::Rule => Some(MarkdownBlock::ThematicBreak),
            Event::Html(text) => Some(MarkdownBlock::Html(text.trim_end_matches('\n').to_string())),
            // Inline content outside a paragraph (not produced at the top level).
            Event::Text(_) | Event::Code(_) | Event::InlineHtml(_) => {
                self.position -= 1;
                let inlines = self.loose_inlines();
                Some(MarkdownBlock::Paragraph(inlines))
            }
            _ => None,
        }
    }

    /// A list item: tight items hold their inline content directly, which becomes a paragraph.
    fn item(&mut self) -> MarkdownListItem {
        let mut checkbox = None;
        let mut blocks = Vec::new();
        while let Some(event) = self.peek() {
            match event {
                Event::End(TagEnd::Item) => {
                    self.position += 1;
                    break;
                }
                Event::TaskListMarker(checked) => {
                    checkbox = Some(*checked);
                    self.position += 1;
                }
                event if is_inline_event(event) => {
                    let inlines = self.loose_inlines();
                    blocks.push(MarkdownBlock::Paragraph(inlines));
                }
                _ => {
                    // A loose item's checkbox comes first inside its paragraph.
                    if checkbox.is_none()
                        && blocks.is_empty()
                        && matches!(event, Event::Start(Tag::Paragraph))
                        && let Some(Event::TaskListMarker(checked)) = self.events.get(self.position + 1)
                    {
                        checkbox = Some(*checked);
                    }
                    if let Some(block) = self.block() {
                        blocks.push(block);
                    }
                }
            }
        }
        MarkdownListItem { checkbox, blocks }
    }

    fn table(&mut self, alignments: &[pulldown_cmark::Alignment]) -> MarkdownTable {
        let alignments = alignments
            .iter()
            .map(|alignment| match alignment {
                pulldown_cmark::Alignment::None => None,
                pulldown_cmark::Alignment::Left => Some(TableAlignment::Left),
                pulldown_cmark::Alignment::Center => Some(TableAlignment::Center),
                pulldown_cmark::Alignment::Right => Some(TableAlignment::Right),
            })
            .collect();
        let mut table = MarkdownTable { alignments, header: Vec::new(), rows: Vec::new() };
        let mut in_head = false;
        while let Some(event) = self.next() {
            match event {
                Event::Start(Tag::TableHead) => in_head = true,
                Event::End(TagEnd::TableHead) => in_head = false,
                Event::Start(Tag::TableRow) => table.rows.push(Vec::new()),
                Event::Start(Tag::TableCell) => {
                    let adjacent_pipes =
                        self.ranges.get(self.position - 1).is_some_and(|range| range.is_empty());
                    let cell = TableCell::new(self.inlines_until(TagEnd::TableCell));
                    let row_index = table.rows.len().saturating_sub(1);
                    let row = if in_head { Some(&mut table.header) } else { table.rows.last_mut() };
                    let Some(row) = row else { continue };
                    let column = row.len();
                    let carets = cell.inlines == [MarkdownInline::Text("^".into())];
                    row.push(cell);
                    if adjacent_pipes {
                        MarkdownTable::span_columns(row, column);
                    } else if carets && !in_head {
                        table.span_rows(row_index, column);
                    }
                }
                Event::End(TagEnd::Table) => break,
                _ => {}
            }
        }
        table
    }

    /// Inlines directly inside an item, up to the next block or the item's end.
    fn loose_inlines(&mut self) -> Vec<MarkdownInline> {
        let mut result = Vec::new();
        while let Some(event) = self.peek() {
            if !is_inline_event(event) {
                break;
            }
            if let Some(inline) = self.inline() {
                push_merging(&mut result, inline);
            }
        }
        result
    }

    fn inlines_until(&mut self, end: TagEnd) -> Vec<MarkdownInline> {
        let mut result = Vec::new();
        while let Some(event) = self.peek() {
            if let Event::End(tag) = event
                && *tag == end
            {
                self.position += 1;
                break;
            }
            if let Some(inline) = self.inline() {
                push_merging(&mut result, inline);
            }
        }
        result
    }

    fn inline(&mut self) -> Option<MarkdownInline> {
        let event = self.next()?.clone();
        Some(match event {
            Event::Text(text) => MarkdownInline::Text(text.to_string()),
            Event::Code(code) => MarkdownInline::Code(code.to_string()),
            Event::InlineHtml(html) | Event::Html(html) => MarkdownInline::Html(html.to_string()),
            Event::SoftBreak if self.line_breaks => MarkdownInline::LineBreak,
            Event::SoftBreak => MarkdownInline::SoftBreak,
            Event::HardBreak => MarkdownInline::LineBreak,
            Event::Start(Tag::Emphasis) => MarkdownInline::Emphasis(self.inlines_until(TagEnd::Emphasis)),
            Event::Start(Tag::Strong) => MarkdownInline::Strong(self.inlines_until(TagEnd::Strong)),
            Event::Start(Tag::Strikethrough) => {
                MarkdownInline::Strikethrough(self.inlines_until(TagEnd::Strikethrough))
            }
            Event::Start(Tag::Link { link_type, dest_url, title, .. }) => MarkdownInline::Link {
                // `<user@example.com>`: cmark makes the destination a `mailto:` URL.
                destination: Some(if link_type == LinkType::Email {
                    format!("mailto:{dest_url}")
                } else {
                    dest_url.to_string()
                }),
                title: Some(title.to_string()).filter(|title| !title.is_empty()),
                children: self.inlines_until(TagEnd::Link),
            },
            Event::Start(Tag::Image { dest_url, title, .. }) => MarkdownInline::Image {
                source: Some(dest_url.to_string()),
                title: Some(title.to_string()).filter(|title| !title.is_empty()),
                alt: plain_text(&self.inlines_until(TagEnd::Image)),
            },
            // Any other container keeps its children's text without adding style.
            Event::Start(tag) => {
                let end = tag.to_end();
                MarkdownInline::Text(plain_text(&self.inlines_until(end)))
            }
            _ => return None,
        })
    }

    fn unique_slug(&mut self, slug: String) -> String {
        let count = self.slugs.entry(slug.clone()).or_insert(0);
        let unique = if *count == 0 { slug } else { format!("{slug}-{count}") };
        *count += 1;
        unique
    }
}

fn is_inline_event(event: &Event) -> bool {
    match event {
        Event::Text(_)
        | Event::Code(_)
        | Event::InlineHtml(_)
        | Event::SoftBreak
        | Event::HardBreak
        | Event::FootnoteReference(_)
        | Event::InlineMath(_) => true,
        Event::Start(tag) => matches!(
            tag,
            Tag::Emphasis | Tag::Strong | Tag::Strikethrough | Tag::Link { .. } | Tag::Image { .. }
        ),
        _ => false,
    }
}

/// Merges adjacent text runs so searching and measuring see whole words.
fn push_merging(result: &mut Vec<MarkdownInline>, inline: MarkdownInline) {
    if let MarkdownInline::Text(next) = &inline
        && let Some(MarkdownInline::Text(previous)) = result.last_mut()
    {
        previous.push_str(next);
        return;
    }
    result.push(inline);
}

// MARK: - Links and images

/// Where a link in a Markdown document leads.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LinkTarget {
    /// A heading of this document (`#anchor`).
    Anchor(String),
    /// Another Markdown file: open it in the reader (recording history), then scroll to
    /// `fragment`.
    Markdown { path: PathBuf, fragment: Option<String> },
    /// Any other local file: open it when [`opens_linked_file`] allows, else reveal it.
    File(PathBuf),
    /// `http`, `https` and `mailto`: the browser or mail app.
    External(String),
}

/// What a link's `destination` in the document at `document` leads to, or `None` when it
/// leads nowhere (an unsafe scheme such as `javascript:`, or a relative path outside
/// `access_root`, see [`access_root`]).
pub fn resolve_link(destination: &str, document: &Path, access_root: &Path) -> Option<LinkTarget> {
    let trimmed = destination.trim();
    if trimmed.is_empty() {
        return None;
    }
    let local = |path: PathBuf, fragment: Option<String>| {
        if is_markdown(&path) { LinkTarget::Markdown { path, fragment } } else { LinkTarget::File(path) }
    };
    match scheme(trimmed).map(|scheme| scheme.to_lowercase()) {
        None => {
            let (path, fragment) = split_fragment(trimmed);
            if path.is_empty() {
                return fragment.map(LinkTarget::Anchor);
            }
            let resolved = resolve_relative(path, document)?;
            within(&resolved, access_root).then(|| local(resolved, fragment))
        }
        Some(scheme) if matches!(scheme.as_str(), "http" | "https" | "mailto") => {
            Some(LinkTarget::External(trimmed.to_string()))
        }
        Some(scheme) if scheme == "file" => {
            let (rest, fragment) = split_fragment(&trimmed[5..]);
            let rest =
                rest.strip_prefix("//").map_or(rest, |rest| rest.strip_prefix("localhost").unwrap_or(rest));
            let path = PathBuf::from(decode(rest.split('?').next().unwrap_or_default())?);
            path.is_absolute().then(|| local(soprano_platform::paths::normalize(&path), fragment))
        }
        _ => None,
    }
}

/// Where an image of the document at `document` is loaded from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ImageSource {
    /// A workspace file inside the access root.
    File(PathBuf),
    /// An `https` image.
    Remote(String),
    /// A `data:image/…` URI.
    Data(String),
}

/// The image `source` names, or `None` (shown as alt text): only `https`, `data:image/`
/// URIs and relative paths inside `access_root` load.
pub fn resolve_image(source: &str, document: &Path, access_root: &Path) -> Option<ImageSource> {
    let trimmed = source.trim();
    if trimmed.is_empty() {
        return None;
    }
    match scheme(trimmed).map(|scheme| scheme.to_lowercase()) {
        None => {
            let (path, _) = split_fragment(trimmed);
            let resolved = resolve_relative(path, document)?;
            within(&resolved, access_root).then_some(ImageSource::File(resolved))
        }
        Some(scheme) if scheme == "https" => Some(ImageSource::Remote(trimmed.to_string())),
        Some(scheme) if scheme == "data" && trimmed.to_lowercase().starts_with("data:image/") => {
            Some(ImageSource::Data(trimmed.to_string()))
        }
        _ => None,
    }
}

/// The folder whose files a document may link and embed: the nearest enclosing Git
/// repository, else the document's own folder.
pub fn access_root(document: &Path) -> PathBuf {
    let folder = soprano_platform::paths::normalize(document.parent().unwrap_or(Path::new("/")));
    let mut directory = folder.as_path();
    loop {
        if directory.join(".git").exists() {
            return directory.to_path_buf();
        }
        match directory.parent() {
            Some(parent) if parent != directory => directory = parent,
            _ => return folder,
        }
    }
}

/// `.md` and `.markdown` files open in the reader.
pub fn is_markdown(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| matches!(extension.to_lowercase().as_str(), "md" | "markdown"))
}

/// A linked document a viewer only displays (an image, a PDF, audio or video, plain text)
/// opens; anything else — an app, a script, a `.command`, an executable — could run code
/// from an untrusted checkout, so it is only revealed. Symlinks are judged by their target.
pub fn opens_linked_file(path: &Path) -> bool {
    let Ok(resolved) = std::fs::canonicalize(path) else { return false };
    let Ok(metadata) = std::fs::metadata(&resolved) else { return false };
    if !metadata.is_file() || is_executable(&metadata) {
        return false;
    }
    let extension =
        resolved.extension().and_then(|extension| extension.to_str()).unwrap_or_default().to_lowercase();
    const SCRIPTS: &[&str] = &[
        "sh",
        "bash",
        "zsh",
        "fish",
        "ksh",
        "csh",
        "command",
        "tool",
        "py",
        "rb",
        "pl",
        "pm",
        "php",
        "js",
        "mjs",
        "cjs",
        "applescript",
        "scpt",
        "ps1",
        "bat",
        "cmd",
        "vbs",
        "lua",
        "tcl",
    ];
    // What conforms to image, PDF, audiovisual content or plain text (source code included)
    // in the system's type tree.
    const VIEWABLE: &[&str] = &[
        // Documents and plain text.
        "pdf", "txt", "text", "md", "markdown", "log", "csv", "tsv", "patch", "diff", "strings",
        // Source code is plain text to the system.
        "c", "h", "cc", "cpp", "cxx", "c++", "hh", "hpp", "hxx", "m", "mm", "swift", "rs", "go", "java", "kt",
        "cs", "css", "scss", "s", "asm", "f", "f77", "f90", "for", "pas", "ada", "adb", "ads", "y", "l",
        // Images.
        "png", "jpg", "jpeg", "jpe", "jfif", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif", "avif",
        "ico", "icns", "svg", "psd", "tga", "exr", "hdr", "jp2", "j2k", "pict", "pct", "dng", "cr2", "cr3",
        "crw", "nef", "nrw", "arw", "srf", "sr2", "orf", "raf", "rw2", "pef", "raw", "3fr", "erf", "mrw",
        "x3f", // Audio and video.
        "mp3", "m4a", "m4b", "aac", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "ogg", "opus",
        "mid", "midi", "kar", "au", "snd", "amr", "ac3", "mp4", "m4v", "mov", "qt", "avi", "mkv", "webm",
        "mpg", "mpeg", "mpe", "m2v", "m2ts", "mts", "vob", "3gp", "3g2", "dv", "wmv", "wma", "flv",
    ];
    !SCRIPTS.contains(&extension.as_str()) && VIEWABLE.contains(&extension.as_str())
}

#[cfg(unix)]
fn is_executable(metadata: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::PermissionsExt;
    metadata.permissions().mode() & 0o111 != 0
}

#[cfg(not(unix))]
fn is_executable(_metadata: &std::fs::Metadata) -> bool {
    false
}

/// The URL scheme of `value`, if it has one (`[A-Za-z][A-Za-z0-9+.-]*:`).
fn scheme(value: &str) -> Option<&str> {
    let colon = value.find(':')?;
    let candidate = &value[..colon];
    let mut characters = candidate.chars();
    let valid = characters.next().is_some_and(|first| first.is_ascii_alphabetic())
        && characters.all(|character| character.is_ascii_alphanumeric() || "+.-".contains(character));
    // A Windows drive letter is a path, not a scheme.
    (valid && candidate.len() > 1).then_some(candidate)
}

fn split_fragment(value: &str) -> (&str, Option<String>) {
    match value.split_once('#') {
        Some((path, fragment)) => (path, decode(fragment).filter(|fragment| !fragment.is_empty())),
        None => (value, None),
    }
}

/// A relative reference resolved against the document's folder, percent-decoded once
/// (a link to `a%2520b.md` names the file `a%20b.md`).
fn resolve_relative(reference: &str, document: &Path) -> Option<PathBuf> {
    let path = decode(reference.split('?').next().unwrap_or_default())?;
    let folder = document.parent().unwrap_or(Path::new("/"));
    let joined = if path.starts_with('/') { PathBuf::from(path) } else { folder.join(path) };
    Some(soprano_platform::paths::normalize(&joined))
}

fn decode(value: &str) -> Option<String> {
    percent_decode_str(value).decode_utf8().ok().map(|decoded| decoded.into_owned())
}

fn within(path: &Path, root: &Path) -> bool {
    path.starts_with(soprano_platform::paths::normalize(root))
}

/// The reader's back/forward history of Markdown files.
#[derive(Clone, Debug, Default)]
pub struct ReaderHistory {
    entries: Vec<PathBuf>,
    index: Option<usize>,
}

impl ReaderHistory {
    /// A document opened by a link or a command: later entries are dropped. Returns false
    /// (nothing recorded) when `path` is already the current document — the reader only
    /// scrolls to the link's fragment then.
    pub fn record(&mut self, path: PathBuf) -> bool {
        let path = soprano_platform::paths::normalize(&path);
        if self.current() == Some(path.as_path()) {
            return false;
        }
        let keep = self.index.map_or(0, |index| index + 1);
        self.entries.truncate(keep);
        self.entries.push(path);
        self.index = Some(self.entries.len() - 1);
        true
    }

    pub fn current(&self) -> Option<&Path> {
        self.index.map(|index| self.entries[index].as_path())
    }

    pub fn can_go_back(&self) -> bool {
        self.index.is_some_and(|index| index > 0)
    }

    pub fn can_go_forward(&self) -> bool {
        self.index.is_some_and(|index| index + 1 < self.entries.len())
    }

    /// ⌘[: the previous document, now current.
    pub fn back(&mut self) -> Option<&Path> {
        let index = self.index.filter(|index| *index > 0)? - 1;
        self.index = Some(index);
        Some(&self.entries[index])
    }

    /// ⌘]: the next document, now current.
    pub fn forward(&mut self) -> Option<&Path> {
        let index = self.index.filter(|index| index + 1 < self.entries.len())? + 1;
        self.index = Some(index);
        Some(&self.entries[index])
    }
}

/// The reader's note when the file cannot be read; it keeps watching the path and reloads
/// when it reappears.
pub fn unreadable_document(path: &Path, error: &std::io::Error) -> Vec<MarkdownBlock> {
    vec![
        MarkdownBlock::Heading {
            level: 1,
            inlines: vec![MarkdownInline::Text("Unable to read Markdown".into())],
            anchor: "unable-to-read-markdown".into(),
        },
        MarkdownBlock::Paragraph(vec![MarkdownInline::Code(path.display().to_string())]),
        MarkdownBlock::Blockquote(vec![MarkdownBlock::Paragraph(vec![MarkdownInline::Text(
            error.to_string(),
        )])]),
        MarkdownBlock::Paragraph(vec![MarkdownInline::Text(
            "Soprano is still watching this path and will reload it when it reappears.".into(),
        )]),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use MarkdownInline::Text;

    fn text(value: &str) -> MarkdownInline {
        Text(value.to_string())
    }

    #[test]
    fn markdown_supports_gfm_and_keeps_document_provided_html_as_source() {
        let blocks = parse(
            "# Hello & Goodbye\n# Hello & Goodbye\n\n- [x] shipped\n\n| Name | State |\n| --- | ---: |\n| Reader | ready |\n\n<script>alert(\"no\")</script>\n\n[unsafe](javascript:alert(1))\n[safe](https://example.com)\n\n```html\n<button onclick=\"bad()\">Run</button>\n```\n",
            false,
        );
        let anchors: Vec<&str> = blocks
            .iter()
            .filter_map(|block| match block {
                MarkdownBlock::Heading { anchor, .. } => Some(anchor.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(anchors, ["hello-goodbye", "hello-goodbye-1"]);
        assert_eq!(
            blocks[0],
            MarkdownBlock::Heading {
                level: 1,
                inlines: vec![text("Hello & Goodbye")],
                anchor: "hello-goodbye".into()
            }
        );
        assert_eq!(
            blocks[2],
            MarkdownBlock::List {
                ordered: false,
                start: 1,
                items: vec![MarkdownListItem {
                    checkbox: Some(true),
                    blocks: vec![MarkdownBlock::Paragraph(vec![text("shipped")])]
                }]
            }
        );
        assert_eq!(
            blocks[3],
            MarkdownBlock::Table(MarkdownTable {
                alignments: vec![None, Some(TableAlignment::Right)],
                header: vec![TableCell::new(vec![text("Name")]), TableCell::new(vec![text("State")])],
                rows: vec![vec![TableCell::new(vec![text("Reader")]), TableCell::new(vec![text("ready")])]],
            })
        );
        assert_eq!(blocks[4], MarkdownBlock::Html("<script>alert(\"no\")</script>".into()));

        let MarkdownBlock::Paragraph(links) = &blocks[5] else { panic!("{:?}", blocks[5]) };
        let destinations: Vec<&str> = links
            .iter()
            .filter_map(|inline| match inline {
                MarkdownInline::Link { destination, .. } => destination.as_deref(),
                _ => None,
            })
            .collect();
        assert_eq!(destinations, ["javascript:alert(1)", "https://example.com"]);
        let document = Path::new("/repo/README.md");
        assert_eq!(resolve_link(destinations[0], document, Path::new("/repo")), None);
        assert_eq!(
            resolve_link(destinations[1], document, Path::new("/repo")),
            Some(LinkTarget::External("https://example.com".into()))
        );

        // Code is highlighted text, never live markup.
        let MarkdownBlock::Code { language, code, tokens } = &blocks[6] else { panic!() };
        assert_eq!(language.as_deref(), Some("html"));
        assert_eq!(code, "<button onclick=\"bad()\">Run</button>");
        assert!(tokens.iter().any(|token| &code[token.range.clone()] == "onclick"));
    }

    #[test]
    fn inlines_keep_their_styles_and_merge_adjacent_text() {
        let blocks = parse(
            "Some *em* **strong ~~gone~~** `code` [link](a.md \"T\") ![alt *x*](i.png)\nnext<br>",
            false,
        );
        let MarkdownBlock::Paragraph(inlines) = &blocks[0] else { panic!() };
        assert_eq!(
            inlines,
            &vec![
                text("Some "),
                MarkdownInline::Emphasis(vec![text("em")]),
                text(" "),
                MarkdownInline::Strong(vec![
                    text("strong "),
                    MarkdownInline::Strikethrough(vec![text("gone")])
                ]),
                text(" "),
                MarkdownInline::Code("code".into()),
                text(" "),
                MarkdownInline::Link {
                    destination: Some("a.md".into()),
                    title: Some("T".into()),
                    children: vec![text("link")]
                },
                text(" "),
                MarkdownInline::Image { source: Some("i.png".into()), title: None, alt: "alt x".into() },
                MarkdownInline::SoftBreak,
                text("next"),
                MarkdownInline::Html("<br>".into()),
            ]
        );
        assert_eq!(plain_text(inlines), "Some em strong gone code link alt x next<br>");
        let MarkdownBlock::Paragraph(user) = &parse("one\ntwo", true)[0] else { panic!() };
        assert_eq!(user, &vec![text("one"), MarkdownInline::LineBreak, text("two")]);
    }

    #[test]
    fn lists_quotes_rules_and_code_keep_their_structure() {
        let blocks = parse("3. three\n4. four\n   - nested\n\n> quoted\n\n---\n\n    indented\n", false);
        let MarkdownBlock::List { ordered: true, start: 3, items } = &blocks[0] else {
            panic!("{:?}", blocks[0])
        };
        assert_eq!(items.len(), 2);
        assert!(matches!(&items[1].blocks[1], MarkdownBlock::List { ordered: false, .. }));
        assert_eq!(
            blocks[1],
            MarkdownBlock::Blockquote(vec![MarkdownBlock::Paragraph(vec![text("quoted")])])
        );
        assert_eq!(blocks[2], MarkdownBlock::ThematicBreak);
        assert_eq!(
            blocks[3],
            MarkdownBlock::Code { language: None, code: "indented".into(), tokens: Vec::new() }
        );
    }

    #[test]
    fn list_markers_follow_the_nesting_depth() {
        assert_eq!([bullet(0), bullet(1), bullet(2), bullet(5)], ["•", "◦", "▪", "▪"]);
        assert_eq!(ordered_marker(3, 0), "3.");
        assert_eq!(ordered_marker(1, 1), "a.");
        assert_eq!(ordered_marker(28, 1), "ab.");
        assert_eq!(ordered_marker(4, 2), "iv.");
        assert_eq!(ordered_marker(14, 3), "14.");
    }

    #[test]
    fn heading_anchors_fold_case_and_diacritics() {
        assert_eq!(heading_slug("Café Über Straße!"), "cafe-uber-strasse");
        assert_eq!(heading_slug("  --  "), "section");
        assert_eq!(heading_slug("API v2.0"), "api-v2-0");
        // Hangul syllables decompose into jamo; the anchor recomposes them.
        assert_eq!(heading_slug("한국어 문서"), "한국어-문서");
    }

    #[test]
    fn quotes_dashes_and_ellipses_are_set_typographically() {
        let MarkdownBlock::Paragraph(inlines) = &parse("\"Hi\" -- it's 1---2...", false)[0] else { panic!() };
        assert_eq!(plain_text(inlines), "“Hi” – it’s 1—2…");
    }

    #[test]
    fn email_autolinks_become_mailto_links() {
        let MarkdownBlock::Paragraph(inlines) = &parse("<user@example.com> <https://x.dev>", false)[0] else {
            panic!()
        };
        assert_eq!(
            inlines[0],
            MarkdownInline::Link {
                destination: Some("mailto:user@example.com".into()),
                title: None,
                children: vec![text("user@example.com")],
            }
        );
        let MarkdownInline::Link { destination: Some(web), .. } = &inlines[2] else { panic!("{inlines:?}") };
        assert_eq!(web, "https://x.dev");
        assert_eq!(
            resolve_link("mailto:user@example.com", Path::new("/r/a.md"), Path::new("/r")),
            Some(LinkTarget::External("mailto:user@example.com".into()))
        );
    }

    #[test]
    fn adjacent_pipes_widen_a_cell_and_a_caret_lengthens_the_cell_above() {
        let blocks = parse("| a | b | c |\n|---|---|---|\n| x || y |\n| ^ | | z |\n| w |||\n", false);
        let MarkdownBlock::Table(table) = &blocks[0] else { panic!("{blocks:?}") };
        let spans =
            |row: &[TableCell]| row.iter().map(|cell| (cell.colspan, cell.rowspan)).collect::<Vec<_>>();
        assert_eq!(spans(&table.header), [(1, 1), (1, 1), (1, 1)]);
        assert_eq!(spans(&table.rows[0]), [(2, 2), (0, 1), (1, 1)]);
        // `| |` (with a space) is an ordinary empty cell; `^` is covered, without its text.
        assert_eq!(spans(&table.rows[1]), [(1, 0), (1, 1), (1, 1)]);
        assert!(table.rows[1][0].is_covered() && table.rows[1][0].inlines.is_empty());
        assert_eq!(spans(&table.rows[2]), [(3, 1), (0, 1), (0, 1)]);
        // A caret with nothing above stays text.
        let MarkdownBlock::Table(lone) = &parse("| a |\n|---|\n| ^ |\n", false)[0] else { panic!() };
        assert_eq!(lone.rows[0][0], TableCell::new(vec![text("^")]));
    }

    #[test]
    fn markdown_links_to_percent_encoded_file_names_are_decoded_once() {
        let root = Path::new("/tmp/soprano-markdown-links");
        let document = root.join("README.md");
        assert_eq!(
            resolve_link("a%2520b.md", &document, root),
            Some(LinkTarget::Markdown { path: root.join("a%20b.md"), fragment: None })
        );
        assert_eq!(
            resolve_link("a%20b.md#Usage", &document, root),
            Some(LinkTarget::Markdown { path: root.join("a b.md"), fragment: Some("Usage".into()) })
        );
        assert_eq!(resolve_link("#install", &document, root), Some(LinkTarget::Anchor("install".into())));
        assert_eq!(
            resolve_link("docs/x.pdf", &document, root),
            Some(LinkTarget::File(root.join("docs/x.pdf")))
        );
        // Nothing outside the document's repository or folder.
        assert_eq!(resolve_link("../secret.md", &document, root), None);
        assert_eq!(resolve_link("/etc/hosts", &document, root), None);
        assert_eq!(
            resolve_link("file:///etc/notes.md", &document, root),
            Some(LinkTarget::Markdown { path: PathBuf::from("/etc/notes.md"), fragment: None })
        );
        assert_eq!(
            resolve_link("mailto:a@b.c", &document, root),
            Some(LinkTarget::External("mailto:a@b.c".into()))
        );
        assert_eq!(resolve_link("data:text/html,x", &document, root), None);
    }

    #[test]
    fn images_load_only_from_the_workspace_https_or_image_data() {
        let root = Path::new("/repo");
        let document = root.join("docs/README.md");
        assert_eq!(
            resolve_image("img/a.png", &document, root),
            Some(ImageSource::File(root.join("docs/img/a.png")))
        );
        assert_eq!(
            resolve_image("../logo.svg", &document, root),
            Some(ImageSource::File(root.join("logo.svg")))
        );
        assert_eq!(resolve_image("../../x.png", &document, root), None);
        assert_eq!(resolve_image("http://x/a.png", &document, root), None);
        assert_eq!(
            resolve_image("https://x/a.png", &document, root),
            Some(ImageSource::Remote("https://x/a.png".into()))
        );
        assert!(matches!(
            resolve_image("data:image/png;base64,AA", &document, root),
            Some(ImageSource::Data(_))
        ));
        assert_eq!(resolve_image("data:text/html,x", &document, root), None);
    }

    #[test]
    fn the_access_root_is_the_enclosing_repository_or_the_documents_folder() {
        let root = tempfile::tempdir().unwrap();
        let repository = root.path().join("repo");
        std::fs::create_dir_all(repository.join(".git")).unwrap();
        std::fs::create_dir_all(repository.join("docs")).unwrap();
        assert_eq!(access_root(&repository.join("docs/a.md")), repository);
        let loose = root.path().join("loose");
        std::fs::create_dir_all(&loose).unwrap();
        assert_eq!(access_root(&loose.join("a.md")), loose);
    }

    #[cfg(unix)]
    #[test]
    fn markdown_links_open_viewable_files_but_never_run_scripts_or_apps() {
        use std::os::unix::fs::PermissionsExt;
        let root = tempfile::tempdir().unwrap();
        let root = root.path();
        let file = |name: &str, executable: bool| {
            let path = root.join(name);
            std::fs::write(&path, "#!/bin/sh\necho hi\n").unwrap();
            if executable {
                std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
            }
            path
        };
        std::fs::create_dir_all(root.join("Tool.app/Contents/MacOS")).unwrap();
        let disguised = root.join("diagram.png");
        std::os::unix::fs::symlink(file("setup.command", true), &disguised).unwrap();

        assert!(opens_linked_file(&file("diagram.pdf", false)));
        assert!(opens_linked_file(&file("notes.txt", false)));
        assert!(!opens_linked_file(&root.join("setup.command")));
        assert!(!opens_linked_file(&file("install.sh", true)));
        assert!(!opens_linked_file(&file("run", true)));
        assert!(!opens_linked_file(&root.join("Tool.app")));
        assert!(!opens_linked_file(&disguised));
    }

    #[test]
    fn the_reader_history_goes_back_and_forward_and_drops_the_future_on_a_new_link() {
        let mut history = ReaderHistory::default();
        assert!(!history.can_go_back());
        history.record("/a.md".into());
        history.record("/b.md".into());
        history.record("/c.md".into());
        assert_eq!(history.back(), Some(Path::new("/b.md")));
        assert_eq!(history.back(), Some(Path::new("/a.md")));
        assert_eq!(history.back(), None);
        assert_eq!(history.forward(), Some(Path::new("/b.md")));
        assert!(history.record("/d.md".into()));
        assert!(!history.can_go_forward());
        assert_eq!(history.back(), Some(Path::new("/b.md")));
        assert_eq!(history.current(), Some(Path::new("/b.md")));
        // A link into the open document (`README.md#usage`) records nothing and keeps the
        // forward history.
        assert!(!history.record("/x/../b.md".into()));
        assert!(history.can_go_forward());
        assert_eq!(history.forward(), Some(Path::new("/d.md")));
    }
}
