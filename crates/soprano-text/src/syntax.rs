//! Syntax coloring for the file editor, the diff view and fenced code (port of
//! `CodeSyntaxHighlighter.swift`).
//!
//! A single linear scan over the text's UTF-8 bytes. Every character the scanner
//! acts on is ASCII, so token ranges are UTF-8 **byte** ranges that always fall on
//! character boundaries and can be used to slice the text and to build GPUI text runs.
//! Multi-line comments and strings come out right because the whole text is scanned
//! at once. Colors are the UI's business: the scanner only reports [`SyntaxTokenKind`]s.

use std::collections::{HashMap, HashSet};
use std::ops::Range;
use std::sync::LazyLock;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SyntaxTokenKind {
    Keyword,
    String,
    Comment,
    Number,
    Type,
    Function,
    /// Decorators, annotations, preprocessor lines, shell variables, CSS at-rules.
    Attribute,
    /// JSON and YAML keys, TOML/INI names, markup attributes.
    Key,
    Tag,
    Heading,
    Inserted,
    Deleted,
}

impl SyntaxTokenKind {
    pub const ALL: [Self; 12] = [
        Self::Keyword,
        Self::String,
        Self::Comment,
        Self::Number,
        Self::Type,
        Self::Function,
        Self::Attribute,
        Self::Key,
        Self::Tag,
        Self::Heading,
        Self::Inserted,
        Self::Deleted,
    ];

    /// Keywords, tags and Markdown headings are set Semibold.
    pub fn is_emphasized(self) -> bool {
        matches!(self, Self::Keyword | Self::Tag | Self::Heading)
    }

    /// Comments are set italic.
    pub fn is_italic(self) -> bool {
        self == Self::Comment
    }
}

/// One colored span: a UTF-8 byte range of the scanned text and its kind.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct SyntaxToken {
    pub range: Range<usize>,
    pub kind: SyntaxTokenKind,
}

/// How a language is scanned.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LanguageStyle {
    /// Identifiers, keywords, strings, numbers, comments.
    Code,
    /// `key: value` / `key = value` lines (YAML, TOML, INI, .env).
    KeyValue,
    /// HTML, XML, SVG, plists.
    Markup,
    Markdown,
    Diff,
}

/// A language's scanning rules. Languages are static; compare them by [`CodeLanguage::id`].
#[derive(Debug)]
pub struct CodeLanguage {
    pub id: &'static str,
    pub style: LanguageStyle,
    pub keywords: HashSet<&'static str>,
    pub case_insensitive_keywords: bool,
    pub line_comments: &'static [&'static str],
    pub block_comment: Option<(&'static str, &'static str)>,
    pub quotes: &'static [u8],
    /// Quotes whose strings may span lines (JavaScript template literals, Go raw strings).
    pub multiline_quotes: &'static [u8],
    /// Quotes inside which a backslash is just a character (Go raw strings, shell single quotes).
    pub raw_quotes: &'static [u8],
    /// `"""` (and `'''` where `'` is a quote) open multi-line strings.
    pub triple_quotes: bool,
    /// `'` delimits a character literal; an unclosed one is a Rust lifetime or a generic
    /// tick, not the start of a string.
    pub single_quote_is_character: bool,
    pub capitalized_types: bool,
    /// `@name` decorators and annotations.
    pub at_attributes: bool,
    /// `$name` and `${…}` variables.
    pub dollar_variables: bool,
    /// `#include` style lines.
    pub preprocessor: bool,
    /// A string directly followed by `:` is an object key.
    pub string_keys: bool,
}

impl PartialEq for CodeLanguage {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
    }
}

impl Eq for CodeLanguage {}

impl CodeLanguage {
    const BASE: Spec = Spec {
        id: "",
        style: LanguageStyle::Code,
        keywords: &[],
        case_insensitive_keywords: false,
        line_comments: &[],
        block_comment: None,
        quotes: b"\"'",
        multiline_quotes: b"",
        raw_quotes: b"",
        triple_quotes: false,
        single_quote_is_character: false,
        capitalized_types: true,
        at_attributes: false,
        dollar_variables: false,
        preprocessor: false,
        string_keys: false,
    };

    /// The language for a file, by exact name first and then extension; `None` for plain text.
    pub fn for_file(name: &str) -> Option<&'static CodeLanguage> {
        let lower = name.to_lowercase();
        if let Some(language) = BY_FILE_NAME.iter().find(|(file, _)| *file == lower) {
            return Some(language.1);
        }
        if lower.starts_with(".env") || lower.ends_with(".env") {
            return Some(&DOTENV);
        }
        if lower.starts_with("dockerfile") {
            return Some(&DOCKERFILE);
        }
        let dot = lower.rfind('.')?;
        if dot == 0 {
            return None;
        }
        BY_EXTENSION.get(&lower[dot + 1..]).copied()
    }

    /// The language a fenced code block names (```` ```ts ````), or `None`.
    pub fn named(name: &str) -> Option<&'static CodeLanguage> {
        let lower = name.to_lowercase();
        BY_FENCE_NAME
            .iter()
            .find(|(fence, _)| *fence == lower)
            .map(|(_, language)| *language)
            .or_else(|| BY_EXTENSION.get(lower.as_str()).copied())
    }

    /// The language's keywords, sorted.
    pub fn sorted_keywords(&self) -> Vec<&'static str> {
        let mut keywords: Vec<&'static str> = self.keywords.iter().copied().collect();
        keywords.sort_unstable();
        keywords
    }
}

/// Splits `text` into syntax tokens for `language`, in text order; ranges are UTF-8 bytes.
pub fn tokens(text: &str, language: &CodeLanguage) -> Vec<SyntaxToken> {
    let mut scanner = Scanner::new(text.as_bytes(), language);
    match language.style {
        LanguageStyle::Code | LanguageStyle::KeyValue => scanner.scan_code(),
        LanguageStyle::Markup => scanner.scan_markup(),
        LanguageStyle::Markdown => scanner.scan_markdown(),
        LanguageStyle::Diff => scanner.scan_diff(),
    }
    scanner.tokens
}

// MARK: - Scanner

struct Scanner<'a> {
    units: &'a [u8],
    language: &'a CodeLanguage,
    tokens: Vec<SyntaxToken>,
}

impl<'a> Scanner<'a> {
    fn new(units: &'a [u8], language: &'a CodeLanguage) -> Self {
        Self { units, language, tokens: Vec::new() }
    }

    fn len(&self) -> usize {
        self.units.len()
    }

    // MARK: Code

    fn scan_code(&mut self) {
        let language = self.language;
        let block = language.block_comment.map(|(open, close)| (open.as_bytes(), close.as_bytes()));
        let mut index = 0;
        let mut at_line_start = true;
        while index < self.len() {
            let unit = self.units[index];
            if unit == b'\n' {
                at_line_start = true;
                index += 1;
                continue;
            }
            if unit == b' ' || unit == b'\t' || unit == b'\r' {
                index += 1;
                continue;
            }
            let line_start = at_line_start;
            at_line_start = false;

            if language.style == LanguageStyle::KeyValue
                && line_start
                && let Some(next) = self.scan_key_value_line_start(index)
            {
                index = next;
                continue;
            }
            if let Some((open, close)) = block
                && self.matches(open, index)
            {
                let end =
                    self.find(close, index + open.len(), false).map_or(self.len(), |at| at + close.len());
                self.add(index, end, SyntaxTokenKind::Comment);
                index = end;
                continue;
            }
            if let Some(prefix) =
                language.line_comments.iter().find(|prefix| self.matches(prefix.as_bytes(), index))
                && (*prefix != "#" || self.is_comment_hash(index))
            {
                let end = self.end_of_line(index);
                self.add(index, end, SyntaxTokenKind::Comment);
                index = end;
                continue;
            }
            if language.preprocessor && line_start && unit == b'#' {
                let end = self.identifier_end(index + 1);
                self.add(index, end, SyntaxTokenKind::Attribute);
                index = end.max(index + 1);
                continue;
            }
            if language.quotes.contains(&unit) || language.multiline_quotes.contains(&unit) {
                index = self.scan_string(index);
                continue;
            }
            if unit.is_ascii_digit() && (index == 0 || !self.is_identifier_part(self.units[index - 1])) {
                let mut end = index + 1;
                while end < self.len() {
                    let next = self.units[end];
                    let decimal =
                        next == b'.' && end + 1 < self.len() && self.units[end + 1].is_ascii_digit();
                    if self.is_identifier_part(next) || decimal {
                        end += 1;
                    } else {
                        break;
                    }
                }
                self.add(index, end, SyntaxTokenKind::Number);
                index = end;
                continue;
            }
            if language.at_attributes
                && unit == b'@'
                && index + 1 < self.len()
                && self.is_identifier_start(self.units[index + 1])
            {
                let end = self.identifier_end(index + 1);
                self.add(index, end, SyntaxTokenKind::Attribute);
                index = end;
                continue;
            }
            if language.dollar_variables && unit == b'$' && index + 1 < self.len() {
                let next = self.units[index + 1];
                if next == b'{' {
                    let end =
                        self.find(b"}", index + 2, true).map_or_else(|| self.end_of_line(index), |at| at + 1);
                    self.add(index, end, SyntaxTokenKind::Attribute);
                    index = end;
                    continue;
                }
                if self.is_identifier_start(next) || next.is_ascii_digit() {
                    let end = self.identifier_end(index + 1);
                    self.add(index, end, SyntaxTokenKind::Attribute);
                    index = end;
                    continue;
                }
            }
            if self.is_identifier_start(unit) {
                let end = self.identifier_end(index);
                self.classify_identifier(index, end);
                index = end;
                continue;
            }
            index += 1;
        }
    }

    fn classify_identifier(&mut self, start: usize, end: usize) {
        // Identifier bytes are ASCII, so this never fails.
        let word = std::str::from_utf8(&self.units[start..end]).unwrap_or_default();
        let is_keyword = if self.language.case_insensitive_keywords {
            self.language.keywords.contains(word.to_ascii_lowercase().as_str())
        } else {
            self.language.keywords.contains(word)
        };
        if is_keyword {
            self.add(start, end, SyntaxTokenKind::Keyword);
            return;
        }
        let mut next = end;
        while next < self.len() && (self.units[next] == b' ' || self.units[next] == b'\t') {
            next += 1;
        }
        if next < self.len() && self.units[next] == b'(' {
            self.add(start, end, SyntaxTokenKind::Function);
        } else if self.language.capitalized_types && self.units[start].is_ascii_uppercase() && end - start > 1
        {
            self.add(start, end, SyntaxTokenKind::Type);
        }
    }

    /// Scans the string starting at `start` and returns the index after it.
    fn scan_string(&mut self, start: usize) -> usize {
        let quote = self.units[start];
        let language = self.language;
        if language.triple_quotes
            && start + 2 < self.len()
            && self.units[start + 1] == quote
            && self.units[start + 2] == quote
        {
            let close = [quote, quote, quote];
            let end = self.find(&close, start + 3, false).map_or(self.len(), |at| at + 3);
            self.add(start, end, SyntaxTokenKind::String);
            return end;
        }

        if quote == b'\'' && language.single_quote_is_character {
            // One character or one escape; anything else (`'a` lifetimes, `<'a>` generics,
            // stray ticks) is not a literal.
            let Some(end) = self.character_literal_end(start) else { return start + 1 };
            self.add(start, end, SyntaxTokenKind::String);
            return end;
        }

        let multiline = language.multiline_quotes.contains(&quote);
        let raw = language.raw_quotes.contains(&quote);
        let mut index = start + 1;
        while index < self.len() {
            let unit = self.units[index];
            if unit == b'\\' && !raw {
                index += 2;
                continue;
            }
            if unit == b'\n' && !multiline {
                break;
            }
            index += 1;
            if unit == quote {
                break;
            }
        }
        // A trailing backslash may step past the end, or into a multi-byte character.
        index = index.min(self.len());
        while index < self.len() && !is_char_boundary(self.units, index) {
            index += 1;
        }
        let mut kind = SyntaxTokenKind::String;
        if language.string_keys {
            let mut next = index;
            while next < self.len() && (self.units[next] == b' ' || self.units[next] == b'\t') {
                next += 1;
            }
            if next < self.len() && self.units[next] == b':' {
                kind = SyntaxTokenKind::Key;
            }
        }
        self.add(start, index, kind);
        index
    }

    /// The end of a character literal opening at `start` (`'x'`, `'é'`, `'\n'`,
    /// `'\u{1F600}'`), or `None` when the tick opens none.
    fn character_literal_end(&self, start: usize) -> Option<usize> {
        let first = start + 1;
        if first >= self.len() || self.units[first] == b'\n' || self.units[first] == b'\'' {
            return None;
        }
        if self.units[first] == b'\\' {
            let mut index = first + 2;
            while index < self.len() && index - start <= 12 && self.units[index] != b'\n' {
                if self.units[index] == b'\'' {
                    return Some(index + 1);
                }
                index += 1;
            }
            return None;
        }
        let close = first + utf8_width(self.units[first]);
        (close < self.len() && self.units[close] == b'\'').then_some(close + 1)
    }

    /// A YAML/TOML/INI line start: `[section]`, `- ` list markers and `key:` / `key =`
    /// names. Returns where scanning resumes, or `None` when the line starts with
    /// something else.
    fn scan_key_value_line_start(&mut self, start: usize) -> Option<usize> {
        let mut index = start;
        if self.units[index] == b'[' {
            let end = self.find(b"]", index + 1, true).map_or_else(|| self.end_of_line(index), |at| at + 1);
            self.add(index, end, SyntaxTokenKind::Heading);
            return Some(end);
        }
        if self.units[index] == b'-' && index + 1 < self.len() && self.units[index + 1] == b' ' {
            index += 2;
            while index < self.len() && self.units[index] == b' ' {
                index += 1;
            }
        }
        let resume = |index: usize| (index != start).then_some(index);
        if index >= self.len() || self.language.quotes.contains(&self.units[index]) {
            return resume(index);
        }
        let mut end = index;
        while end < self.len() {
            let unit = self.units[end];
            if unit == b'\n' || unit == b'#' || (unit == b';' && index == end) {
                break;
            }
            if unit == b'=' {
                break;
            }
            if unit == b':'
                && (end + 1 >= self.len()
                    || self.units[end + 1] == b' '
                    || self.units[end + 1] == b'\n'
                    || self.units[end + 1] == b'\r')
            {
                break;
            }
            end += 1;
        }
        if end >= self.len() || end <= index || !(self.units[end] == b':' || self.units[end] == b'=') {
            return resume(index);
        }
        let mut key_end = end;
        while key_end > index && (self.units[key_end - 1] == b' ' || self.units[key_end - 1] == b'\t') {
            key_end -= 1;
        }
        self.add(index, key_end, SyntaxTokenKind::Key);
        Some(end + 1)
    }

    // MARK: Markup

    fn scan_markup(&mut self) {
        let mut index = 0;
        while index < self.len() {
            if self.matches(b"<!--", index) {
                let end = self.find(b"-->", index + 4, false).map_or(self.len(), |at| at + 3);
                self.add(index, end, SyntaxTokenKind::Comment);
                index = end;
                continue;
            }
            if self.matches(b"<![CDATA[", index) {
                let end = self.find(b"]]>", index + 9, false).map_or(self.len(), |at| at + 3);
                self.add(index, end, SyntaxTokenKind::String);
                index = end;
                continue;
            }
            if self.units[index] != b'<' || index + 1 >= self.len() {
                index += 1;
                continue;
            }
            let mut name_start = index + 1;
            if matches!(self.units[name_start], b'/' | b'?' | b'!') {
                name_start += 1;
            }
            if name_start >= self.len() || !self.is_identifier_start(self.units[name_start]) {
                index += 1;
                continue;
            }
            let name_end = self.markup_name_end(name_start);
            self.add(name_start, name_end, SyntaxTokenKind::Tag);
            index = self.scan_markup_attributes(name_end);
        }
    }

    fn scan_markup_attributes(&mut self, start: usize) -> usize {
        let mut index = start;
        while index < self.len() {
            let unit = self.units[index];
            if unit == b'>' {
                return index + 1;
            }
            if unit == b'<' {
                return index;
            }
            if unit == b'"' || unit == b'\'' {
                let end = self.find(&[unit], index + 1, false).map_or(self.len(), |at| at + 1);
                self.add(index, end, SyntaxTokenKind::String);
                index = end;
                continue;
            }
            if self.is_identifier_start(unit) {
                let end = self.markup_name_end(index);
                self.add(index, end, SyntaxTokenKind::Key);
                index = end;
                continue;
            }
            index += 1;
        }
        index
    }

    fn markup_name_end(&self, start: usize) -> usize {
        let mut end = start;
        while end < self.len() {
            let unit = self.units[end];
            if !(self.is_identifier_part(unit) || unit == b'-' || unit == b':' || unit == b'.') {
                break;
            }
            end += 1;
        }
        end
    }

    // MARK: Markdown

    fn scan_markdown(&mut self) {
        let mut index = 0;
        let mut fence: Option<u8> = None;
        while index < self.len() {
            let line_end = self.end_of_line(index);
            let mut content = index;
            while content < line_end && content - index < 4 && self.units[content] == b' ' {
                content += 1;
            }
            let fence_marker = (content + 2 < line_end
                && (self.units[content] == b'`' || self.units[content] == b'~')
                && self.units[content + 1] == self.units[content]
                && self.units[content + 2] == self.units[content])
                .then(|| self.units[content]);

            if let Some(open) = fence {
                self.add(index, line_end, SyntaxTokenKind::String);
                if fence_marker == Some(open) {
                    fence = None;
                }
            } else if let Some(marker) = fence_marker {
                fence = Some(marker);
                self.add(index, line_end, SyntaxTokenKind::String);
            } else if content < line_end && self.units[content] == b'#' && self.is_heading(content, line_end)
            {
                self.add(content, line_end, SyntaxTokenKind::Heading);
            } else {
                let list_marker = content + 1 < line_end
                    && matches!(self.units[content], b'-' | b'*' | b'+')
                    && self.units[content + 1] == b' ';
                let quote_marker = content < line_end && self.units[content] == b'>';
                if list_marker || quote_marker {
                    self.add(content, content + 1, SyntaxTokenKind::Keyword);
                }
                self.scan_inline_code(content, line_end);
            }
            index = line_end + 1;
        }
    }

    fn is_heading(&self, start: usize, end: usize) -> bool {
        let mut index = start;
        while index < end && self.units[index] == b'#' {
            index += 1;
        }
        index - start <= 6 && (index == end || self.units[index] == b' ')
    }

    fn scan_inline_code(&mut self, start: usize, end: usize) {
        let mut index = start;
        while index < end {
            if self.units[index] != b'`' {
                index += 1;
                continue;
            }
            let Some(close) = self.find(b"`", index + 1, true).filter(|close| *close < end) else { return };
            self.add(index, close + 1, SyntaxTokenKind::String);
            index = close + 1;
        }
    }

    // MARK: Diff

    fn scan_diff(&mut self) {
        let mut index = 0;
        while index < self.len() {
            let end = self.end_of_line(index);
            if self.matches(b"+++", index)
                || self.matches(b"---", index)
                || self.matches(b"diff ", index)
                || self.matches(b"index ", index)
            {
                self.add(index, end, SyntaxTokenKind::Heading);
            } else if self.matches(b"@@", index) {
                self.add(index, end, SyntaxTokenKind::Keyword);
            } else if self.units[index] == b'+' {
                self.add(index, end, SyntaxTokenKind::Inserted);
            } else if self.units[index] == b'-' {
                self.add(index, end, SyntaxTokenKind::Deleted);
            }
            index = end + 1;
        }
    }

    // MARK: Helpers

    fn add(&mut self, start: usize, end: usize, kind: SyntaxTokenKind) {
        if end > start {
            self.tokens.push(SyntaxToken { range: start..end, kind });
        }
    }

    fn matches(&self, pattern: &[u8], index: usize) -> bool {
        !pattern.is_empty() && self.units.get(index..index + pattern.len()) == Some(pattern)
    }

    fn find(&self, pattern: &[u8], start: usize, stop_at_newline: bool) -> Option<usize> {
        let mut index = start;
        while index + pattern.len() <= self.len() {
            if stop_at_newline && self.units[index] == b'\n' {
                return None;
            }
            if self.matches(pattern, index) {
                return Some(index);
            }
            index += 1;
        }
        None
    }

    fn end_of_line(&self, start: usize) -> usize {
        self.units[start.min(self.len())..]
            .iter()
            .position(|unit| *unit == b'\n')
            .map_or(self.len(), |at| start + at)
    }

    fn identifier_end(&self, start: usize) -> usize {
        let mut end = start;
        while end < self.len() && self.is_identifier_part(self.units[end]) {
            end += 1;
        }
        end
    }

    /// `#` only starts a comment at the start of a word, so `$#`, `a#b` and URL fragments
    /// are left alone.
    fn is_comment_hash(&self, index: usize) -> bool {
        index == 0 || matches!(self.units[index - 1], b' ' | b'\t' | b'\n' | b';' | b'\r')
    }

    fn is_identifier_start(&self, unit: u8) -> bool {
        unit.is_ascii_alphabetic() || unit == b'_' || (unit == b'$' && !self.language.dollar_variables)
    }

    fn is_identifier_part(&self, unit: u8) -> bool {
        self.is_identifier_start(unit) || unit.is_ascii_digit()
    }
}

/// Bytes in the UTF-8 sequence a leading byte starts.
fn utf8_width(lead: u8) -> usize {
    match lead {
        0xF0.. => 4,
        0xE0.. => 3,
        0xC0.. => 2,
        _ => 1,
    }
}

fn is_char_boundary(bytes: &[u8], index: usize) -> bool {
    index >= bytes.len() || (bytes[index] as i8) >= -0x40
}

// MARK: - Languages

/// The literal fields of a language; keyword lists are joined into a set when built.
struct Spec {
    id: &'static str,
    style: LanguageStyle,
    keywords: &'static [&'static [&'static str]],
    case_insensitive_keywords: bool,
    line_comments: &'static [&'static str],
    block_comment: Option<(&'static str, &'static str)>,
    quotes: &'static [u8],
    multiline_quotes: &'static [u8],
    raw_quotes: &'static [u8],
    triple_quotes: bool,
    single_quote_is_character: bool,
    capitalized_types: bool,
    at_attributes: bool,
    dollar_variables: bool,
    preprocessor: bool,
    string_keys: bool,
}

impl Spec {
    fn build(self) -> CodeLanguage {
        CodeLanguage {
            id: self.id,
            style: self.style,
            keywords: self.keywords.iter().flat_map(|list| list.iter().copied()).collect(),
            case_insensitive_keywords: self.case_insensitive_keywords,
            line_comments: self.line_comments,
            block_comment: self.block_comment,
            quotes: self.quotes,
            multiline_quotes: self.multiline_quotes,
            raw_quotes: self.raw_quotes,
            triple_quotes: self.triple_quotes,
            single_quote_is_character: self.single_quote_is_character,
            capitalized_types: self.capitalized_types,
            at_attributes: self.at_attributes,
            dollar_variables: self.dollar_variables,
            preprocessor: self.preprocessor,
            string_keys: self.string_keys,
        }
    }
}

const SLASH: &[&str] = &["//"];
const HASH: &[&str] = &["#"];
const DASHES: &[&str] = &["--"];
const C_BLOCK: Option<(&str, &str)> = Some(("/*", "*/"));

const JAVASCRIPT_KEYWORDS: &[&str] = &[
    "async",
    "await",
    "break",
    "case",
    "catch",
    "class",
    "const",
    "continue",
    "debugger",
    "default",
    "delete",
    "do",
    "else",
    "enum",
    "export",
    "extends",
    "false",
    "finally",
    "for",
    "from",
    "function",
    "get",
    "if",
    "implements",
    "import",
    "in",
    "instanceof",
    "interface",
    "let",
    "new",
    "null",
    "of",
    "private",
    "protected",
    "public",
    "return",
    "set",
    "static",
    "super",
    "switch",
    "this",
    "throw",
    "true",
    "try",
    "type",
    "typeof",
    "undefined",
    "var",
    "void",
    "while",
    "with",
    "yield",
];

const C_KEYWORDS: &[&str] = &[
    "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern",
    "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short",
    "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile",
    "while", "NULL",
];

const JVM_KEYWORDS: &[&str] = &[
    "abstract",
    "boolean",
    "break",
    "byte",
    "case",
    "catch",
    "char",
    "class",
    "const",
    "continue",
    "default",
    "do",
    "double",
    "else",
    "enum",
    "extends",
    "false",
    "final",
    "finally",
    "float",
    "for",
    "if",
    "implements",
    "import",
    "instanceof",
    "int",
    "interface",
    "long",
    "new",
    "null",
    "package",
    "private",
    "protected",
    "public",
    "record",
    "return",
    "short",
    "static",
    "super",
    "switch",
    "this",
    "throw",
    "throws",
    "true",
    "try",
    "var",
    "void",
    "while",
    "yield",
];

pub static SWIFT: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "swift",
        keywords: &[&[
            "Any",
            "Self",
            "actor",
            "any",
            "as",
            "associatedtype",
            "async",
            "await",
            "break",
            "case",
            "catch",
            "class",
            "continue",
            "convenience",
            "default",
            "defer",
            "deinit",
            "didSet",
            "do",
            "dynamic",
            "else",
            "enum",
            "extension",
            "fallthrough",
            "false",
            "fileprivate",
            "final",
            "for",
            "func",
            "get",
            "guard",
            "if",
            "import",
            "in",
            "indirect",
            "init",
            "inout",
            "internal",
            "is",
            "isolated",
            "lazy",
            "let",
            "mutating",
            "nil",
            "nonisolated",
            "nonmutating",
            "open",
            "operator",
            "optional",
            "override",
            "package",
            "private",
            "protocol",
            "public",
            "repeat",
            "required",
            "rethrows",
            "return",
            "self",
            "set",
            "some",
            "static",
            "struct",
            "subscript",
            "super",
            "switch",
            "throw",
            "throws",
            "true",
            "try",
            "typealias",
            "unowned",
            "var",
            "weak",
            "where",
            "while",
            "willSet",
        ]],
        line_comments: SLASH,
        block_comment: C_BLOCK,
        quotes: b"\"",
        triple_quotes: true,
        at_attributes: true,
        preprocessor: true,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static JAVASCRIPT: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "javascript",
        keywords: &[JAVASCRIPT_KEYWORDS],
        line_comments: SLASH,
        block_comment: C_BLOCK,
        multiline_quotes: b"`",
        at_attributes: true,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static TYPESCRIPT: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "typescript",
        keywords: &[
            JAVASCRIPT_KEYWORDS,
            &[
                "abstract",
                "as",
                "asserts",
                "declare",
                "infer",
                "is",
                "keyof",
                "namespace",
                "never",
                "override",
                "readonly",
                "satisfies",
                "unique",
                "unknown",
            ],
        ],
        line_comments: SLASH,
        block_comment: C_BLOCK,
        multiline_quotes: b"`",
        at_attributes: true,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static PYTHON: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "python",
        keywords: &[&[
            "False", "None", "True", "and", "as", "assert", "async", "await", "break", "case", "class",
            "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if",
            "import", "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise", "return",
            "self", "try", "while", "with", "yield",
        ]],
        line_comments: HASH,
        triple_quotes: true,
        at_attributes: true,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static RUBY: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "ruby",
        keywords: &[&[
            "BEGIN", "END", "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do",
            "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not",
            "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless",
            "until", "when", "while", "yield",
        ]],
        line_comments: HASH,
        multiline_quotes: b"\"'",
        at_attributes: true,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static SHELL: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "shell",
        keywords: &[&[
            "case", "declare", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if",
            "in", "local", "readonly", "return", "select", "set", "source", "then", "time", "unset", "until",
            "while",
        ]],
        line_comments: HASH,
        multiline_quotes: b"\"'",
        raw_quotes: b"'",
        capitalized_types: false,
        dollar_variables: true,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static RUST: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "rust",
        keywords: &[&[
            "Self", "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
            "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut",
            "pub", "ref", "return", "self", "static", "struct", "super", "trait", "true", "type", "unsafe",
            "use", "where", "while",
        ]],
        line_comments: SLASH,
        block_comment: C_BLOCK,
        multiline_quotes: b"\"",
        single_quote_is_character: true,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static GO: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "go",
        keywords: &[&[
            "break",
            "case",
            "chan",
            "const",
            "continue",
            "default",
            "defer",
            "else",
            "fallthrough",
            "false",
            "for",
            "func",
            "go",
            "goto",
            "if",
            "import",
            "interface",
            "iota",
            "map",
            "nil",
            "package",
            "range",
            "return",
            "select",
            "struct",
            "switch",
            "true",
            "type",
            "var",
        ]],
        line_comments: SLASH,
        block_comment: C_BLOCK,
        multiline_quotes: b"`",
        raw_quotes: b"`",
        single_quote_is_character: true,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static C: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "c",
        keywords: &[C_KEYWORDS],
        line_comments: SLASH,
        block_comment: C_BLOCK,
        single_quote_is_character: true,
        preprocessor: true,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static CPP: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "cpp",
        keywords: &[
            C_KEYWORDS,
            &[
                "auto",
                "bool",
                "catch",
                "class",
                "constexpr",
                "delete",
                "explicit",
                "false",
                "friend",
                "mutable",
                "namespace",
                "new",
                "noexcept",
                "nullptr",
                "operator",
                "override",
                "private",
                "protected",
                "public",
                "template",
                "this",
                "throw",
                "true",
                "try",
                "typename",
                "using",
                "virtual",
                // Objective-C
                "id",
                "nil",
                "self",
                "super",
                "YES",
                "NO",
            ],
        ],
        line_comments: SLASH,
        block_comment: C_BLOCK,
        single_quote_is_character: true,
        at_attributes: true,
        preprocessor: true,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static JAVA: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "java",
        keywords: &[JVM_KEYWORDS],
        line_comments: SLASH,
        block_comment: C_BLOCK,
        triple_quotes: true,
        single_quote_is_character: true,
        at_attributes: true,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static KOTLIN: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "kotlin",
        keywords: &[
            JVM_KEYWORDS,
            &[
                "as",
                "by",
                "companion",
                "data",
                "fun",
                "in",
                "init",
                "inline",
                "internal",
                "is",
                "lateinit",
                "object",
                "open",
                "override",
                "sealed",
                "suspend",
                "typealias",
                "val",
                "var",
                "when",
            ],
        ],
        line_comments: SLASH,
        block_comment: C_BLOCK,
        triple_quotes: true,
        single_quote_is_character: true,
        at_attributes: true,
        dollar_variables: true,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static CSHARP: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "csharp",
        keywords: &[
            JVM_KEYWORDS,
            &[
                "as",
                "async",
                "await",
                "base",
                "bool",
                "decimal",
                "delegate",
                "event",
                "explicit",
                "get",
                "implicit",
                "in",
                "internal",
                "is",
                "namespace",
                "object",
                "operator",
                "out",
                "override",
                "params",
                "readonly",
                "ref",
                "sealed",
                "set",
                "string",
                "struct",
                "using",
                "var",
                "virtual",
            ],
        ],
        line_comments: SLASH,
        block_comment: C_BLOCK,
        single_quote_is_character: true,
        preprocessor: true,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static PHP: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "php",
        keywords: &[&[
            "abstract",
            "array",
            "as",
            "break",
            "case",
            "catch",
            "class",
            "const",
            "continue",
            "default",
            "do",
            "echo",
            "else",
            "elseif",
            "extends",
            "false",
            "final",
            "finally",
            "fn",
            "for",
            "foreach",
            "function",
            "if",
            "implements",
            "interface",
            "match",
            "namespace",
            "new",
            "null",
            "private",
            "protected",
            "public",
            "readonly",
            "return",
            "static",
            "switch",
            "this",
            "throw",
            "trait",
            "true",
            "try",
            "use",
            "while",
        ]],
        line_comments: &["//", "#"],
        block_comment: C_BLOCK,
        multiline_quotes: b"\"'",
        dollar_variables: true,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static SQL: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "sql",
        keywords: &[&[
            "add",
            "all",
            "alter",
            "and",
            "as",
            "asc",
            "begin",
            "between",
            "by",
            "case",
            "check",
            "column",
            "commit",
            "constraint",
            "create",
            "cross",
            "database",
            "default",
            "delete",
            "desc",
            "distinct",
            "drop",
            "else",
            "end",
            "exists",
            "false",
            "foreign",
            "from",
            "full",
            "group",
            "having",
            "if",
            "in",
            "index",
            "inner",
            "insert",
            "into",
            "is",
            "join",
            "key",
            "left",
            "like",
            "limit",
            "not",
            "null",
            "offset",
            "on",
            "or",
            "order",
            "outer",
            "primary",
            "references",
            "returning",
            "right",
            "rollback",
            "select",
            "set",
            "table",
            "then",
            "true",
            "union",
            "unique",
            "update",
            "values",
            "view",
            "when",
            "where",
            "with",
        ]],
        case_insensitive_keywords: true,
        line_comments: DASHES,
        block_comment: C_BLOCK,
        capitalized_types: false,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static LUA: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "lua",
        keywords: &[&[
            "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
            "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
        ]],
        line_comments: DASHES,
        block_comment: Some(("--[[", "]]")),
        ..CodeLanguage::BASE
    }
    .build()
});

pub static CSS: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "css",
        keywords: &[&["from", "to"]],
        block_comment: C_BLOCK,
        capitalized_types: false,
        at_attributes: true,
        ..CodeLanguage::BASE
    }
    .build()
});

/// SCSS and Less add `//` comments and `$variables` to CSS; plain CSS has neither, and an
/// unquoted `url(http://…)` must not start a comment.
pub static SCSS: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "scss",
        keywords: &[&["from", "to"]],
        line_comments: SLASH,
        block_comment: C_BLOCK,
        capitalized_types: false,
        at_attributes: true,
        dollar_variables: true,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static JSON: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "json",
        keywords: &[&["false", "null", "true"]],
        line_comments: SLASH,
        block_comment: C_BLOCK,
        capitalized_types: false,
        string_keys: true,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static YAML: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "yaml",
        style: LanguageStyle::KeyValue,
        keywords: &[&["false", "no", "null", "off", "on", "true", "yes"]],
        line_comments: HASH,
        capitalized_types: false,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static TOML: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "toml",
        style: LanguageStyle::KeyValue,
        keywords: &[&["false", "true"]],
        line_comments: HASH,
        triple_quotes: true,
        capitalized_types: false,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static INI: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "ini",
        style: LanguageStyle::KeyValue,
        keywords: &[&["false", "no", "off", "on", "true", "yes"]],
        line_comments: &["#", ";"],
        capitalized_types: false,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static DOTENV: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "dotenv",
        style: LanguageStyle::KeyValue,
        line_comments: HASH,
        capitalized_types: false,
        dollar_variables: true,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static DOCKERFILE: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "dockerfile",
        keywords: &[&[
            "add",
            "arg",
            "as",
            "cmd",
            "copy",
            "entrypoint",
            "env",
            "expose",
            "from",
            "healthcheck",
            "label",
            "onbuild",
            "run",
            "shell",
            "stopsignal",
            "user",
            "volume",
            "workdir",
        ]],
        case_insensitive_keywords: true,
        line_comments: HASH,
        multiline_quotes: b"\"'",
        raw_quotes: b"'",
        capitalized_types: false,
        dollar_variables: true,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static MAKEFILE: LazyLock<CodeLanguage> = LazyLock::new(|| {
    Spec {
        id: "makefile",
        keywords: &[&[
            "define", "else", "endef", "endif", "export", "ifdef", "ifeq", "ifndef", "ifneq", "include",
        ]],
        line_comments: HASH,
        raw_quotes: b"'",
        capitalized_types: false,
        dollar_variables: true,
        ..CodeLanguage::BASE
    }
    .build()
});

pub static MARKUP: LazyLock<CodeLanguage> =
    LazyLock::new(|| Spec { id: "markup", style: LanguageStyle::Markup, ..CodeLanguage::BASE }.build());
pub static MARKDOWN: LazyLock<CodeLanguage> =
    LazyLock::new(|| Spec { id: "markdown", style: LanguageStyle::Markdown, ..CodeLanguage::BASE }.build());
pub static DIFF: LazyLock<CodeLanguage> =
    LazyLock::new(|| Spec { id: "diff", style: LanguageStyle::Diff, ..CodeLanguage::BASE }.build());

static BY_EXTENSION: LazyLock<HashMap<&'static str, &'static CodeLanguage>> = LazyLock::new(|| {
    let groups: [(&'static CodeLanguage, &[&'static str]); 26] = [
        (&SWIFT, &["swift"]),
        (&JAVASCRIPT, &["js", "jsx", "mjs", "cjs"]),
        (&TYPESCRIPT, &["ts", "tsx", "mts", "cts"]),
        (&PYTHON, &["py", "pyi", "pyw"]),
        (&RUBY, &["rb", "rake", "gemspec", "ru"]),
        (&SHELL, &["sh", "bash", "zsh", "fish", "ksh", "command"]),
        (&RUST, &["rs"]),
        (&GO, &["go"]),
        (&C, &["c", "h"]),
        (&CPP, &["cc", "cpp", "cxx", "hh", "hpp", "hxx", "m", "mm"]),
        (&JAVA, &["java", "groovy", "gradle", "scala", "dart"]),
        (&KOTLIN, &["kt", "kts"]),
        (&CSHARP, &["cs"]),
        (&PHP, &["php"]),
        (&SQL, &["sql"]),
        (&LUA, &["lua"]),
        (&CSS, &["css"]),
        (&SCSS, &["scss", "sass", "less"]),
        (&JSON, &["json", "jsonc", "json5", "webmanifest"]),
        (&YAML, &["yaml", "yml"]),
        (&TOML, &["toml"]),
        (&INI, &["ini", "cfg", "conf", "properties", "editorconfig", "gitconfig"]),
        (&MARKUP, &["html", "htm", "xhtml", "xml", "svg", "plist", "vue", "svelte", "xib", "storyboard"]),
        (&MARKDOWN, &["md", "markdown", "mdx"]),
        (&DIFF, &["diff", "patch"]),
        (&MAKEFILE, &["mk"]),
    ];
    let mut table = HashMap::new();
    for (language, extensions) in groups {
        for extension in extensions {
            table.insert(*extension, language);
        }
    }
    table
});

static BY_FILE_NAME: LazyLock<[(&'static str, &'static CodeLanguage); 20]> = LazyLock::new(|| {
    [
        ("makefile", &*MAKEFILE),
        ("gnumakefile", &*MAKEFILE),
        ("gemfile", &*RUBY),
        ("rakefile", &*RUBY),
        ("podfile", &*RUBY),
        ("brewfile", &*RUBY),
        (".zshrc", &*SHELL),
        (".zprofile", &*SHELL),
        (".bashrc", &*SHELL),
        (".bash_profile", &*SHELL),
        (".profile", &*SHELL),
        (".envrc", &*SHELL),
        (".gitignore", &*DOTENV),
        (".dockerignore", &*DOTENV),
        (".npmrc", &*INI),
        (".gitconfig", &*INI),
        (".editorconfig", &*INI),
        ("package.resolved", &*JSON),
        (".babelrc", &*JSON),
        (".prettierrc", &*JSON),
    ]
});

static BY_FENCE_NAME: LazyLock<[(&'static str, &'static CodeLanguage); 18]> = LazyLock::new(|| {
    [
        ("javascript", &*JAVASCRIPT),
        ("typescript", &*TYPESCRIPT),
        ("python", &*PYTHON),
        ("ruby", &*RUBY),
        ("shell", &*SHELL),
        ("bash", &*SHELL),
        ("console", &*SHELL),
        ("rust", &*RUST),
        ("golang", &*GO),
        ("c++", &*CPP),
        ("objc", &*CPP),
        ("objective-c", &*CPP),
        ("kotlin", &*KOTLIN),
        ("csharp", &*CSHARP),
        ("html", &*MARKUP),
        ("xml", &*MARKUP),
        ("dockerfile", &*DOCKERFILE),
        ("makefile", &*MAKEFILE),
    ]
});

#[cfg(test)]
mod tests {
    use super::*;
    use SyntaxTokenKind::*;

    fn highlighted<'a>(text: &'a str, language: &CodeLanguage) -> Vec<(&'a str, SyntaxTokenKind)> {
        tokens(text, language).into_iter().map(|token| (&text[token.range], token.kind)).collect()
    }

    fn texts<'a>(tokens: &[(&'a str, SyntaxTokenKind)], kind: SyntaxTokenKind) -> Vec<&'a str> {
        tokens.iter().filter(|token| token.1 == kind).map(|token| token.0).collect()
    }

    #[test]
    fn swift_code_is_split_into_keywords_strings_calls_types_and_comments() {
        let tokens = highlighted(
            "@MainActor\nfunc greet(_ name: String) -> Int {\n    print(\"hi // not a comment\") // done\n    return 42\n}",
            &SWIFT,
        );
        for expected in [
            ("@MainActor", Attribute),
            ("func", Keyword),
            ("greet", Function),
            ("String", Type),
            ("\"hi // not a comment\"", String),
            ("// done", Comment),
            ("42", Number),
        ] {
            assert!(tokens.contains(&expected), "missing {expected:?} in {tokens:?}");
        }
        assert!(!tokens.iter().any(|token| token.1 == Comment && token.0.contains("not a comment")));
    }

    #[test]
    fn block_comments_and_triple_quoted_strings_span_lines() {
        let c = highlighted("int a; /* one\ntwo */ int b;", &C);
        assert!(c.contains(&("/* one\ntwo */", Comment)));
        assert_eq!(texts(&c, Keyword), ["int", "int"]);

        let python = highlighted("x = \"\"\"first\nsecond\"\"\"\ny = 1  # note", &PYTHON);
        assert!(python.contains(&("\"\"\"first\nsecond\"\"\"", String)));
        assert!(python.contains(&("# note", Comment)));
    }

    #[test]
    fn an_unclosed_rust_tick_is_a_lifetime_not_a_string() {
        let tokens = highlighted("fn f<'a>(s: &'a str) -> char { 'x' }", &RUST);
        assert!(!tokens.iter().any(|token| token.1 == String && token.0.starts_with("'a")));
        assert_eq!(texts(&tokens, String), ["'x'"]);
        let escapes = highlighted(r"let c = '\''; let e = '\u{1F600}';", &RUST);
        assert_eq!(texts(&escapes, String), [r"'\''", r"'\u{1F600}'"]);
        assert_eq!(texts(&highlighted("let e = 'é'; let f = '😀';", &RUST), String), ["'é'", "'😀'"]);
    }

    #[test]
    fn raw_strings_keep_backslashes_and_shell_strings_may_span_lines() {
        let go = highlighted("a := `C:\\dir\\`\nb := 1", &GO);
        assert!(go.contains(&("`C:\\dir\\`", String)));
        assert!(go.contains(&("1", Number)));

        let shell = highlighted("awk 'BEGIN {\n  print $1\n}' file", &SHELL);
        assert!(shell.contains(&("'BEGIN {\n  print $1\n}'", String)));
        assert!(highlighted(r"echo 'a\' b", &SHELL).contains(&(r"'a\'", String)));
    }

    #[test]
    fn a_hash_only_starts_a_shell_comment_at_a_word_boundary() {
        let tokens = highlighted("echo $# ${HOME}#x # real", &SHELL);
        assert!(tokens.contains(&("# real", Comment)));
        assert_eq!(texts(&tokens, Comment).len(), 1);
        assert!(tokens.contains(&("${HOME}", Attribute)));
    }

    #[test]
    fn plain_css_urls_are_not_comments() {
        let tokens = highlighted("a { background: url(http://example.com/x.png); }", &CSS);
        assert!(texts(&tokens, Comment).is_empty());
        assert!(highlighted("$x: 1; // note", &SCSS).contains(&("// note", Comment)));
    }

    #[test]
    fn json_keys_are_keys_and_values_are_strings() {
        let tokens = highlighted(r#"{"name": "soprano", "ok": true}"#, &JSON);
        assert!(tokens.contains(&(r#""name""#, Key)));
        assert!(tokens.contains(&(r#""soprano""#, String)));
        assert!(tokens.contains(&("true", Keyword)));
    }

    #[test]
    fn yaml_and_toml_names_are_keys_but_values_with_colons_are_not() {
        let yaml = highlighted("name: soprano\nurl: http://x\nitems:\n  - id: 1 # c\n", &YAML);
        assert_eq!(texts(&yaml, Key), ["name", "url", "items", "id"]);
        assert!(yaml.contains(&("# c", Comment)));

        let toml = highlighted("[package]\nname = \"x\"\n", &TOML);
        assert!(toml.contains(&("[package]", Heading)));
        assert!(toml.contains(&("name", Key)));
    }

    #[test]
    fn markdown_colors_headings_lists_and_code() {
        let tokens = highlighted("# Title\n- item with `code`\n```swift\nlet a = 1\n```\nafter", &MARKDOWN);
        assert!(tokens.contains(&("# Title", Heading)));
        assert!(tokens.contains(&("-", Keyword)));
        assert!(tokens.contains(&("`code`", String)));
        assert!(tokens.contains(&("let a = 1", String)));
        assert!(!tokens.iter().any(|token| token.0 == "after"));
    }

    #[test]
    fn markup_colors_tags_attributes_values_and_comments() {
        let tokens = highlighted(r#"<!-- c --><a href="/x">don't</a>"#, &MARKUP);
        assert_eq!(
            tokens.iter().map(|token| token.0).collect::<Vec<_>>(),
            ["<!-- c -->", "a", "href", r#""/x""#, "a"]
        );
        assert_eq!(tokens.iter().map(|token| token.1).collect::<Vec<_>>(), [Comment, Tag, Key, String, Tag]);
    }

    #[test]
    fn diffs_color_headers_hunks_insertions_and_deletions() {
        let tokens = highlighted("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n same", &DIFF);
        assert_eq!(
            tokens,
            [
                ("--- a/x", Heading),
                ("+++ b/x", Heading),
                ("@@ -1 +1 @@", Keyword),
                ("-old", Deleted),
                ("+new", Inserted)
            ]
        );
    }

    #[test]
    fn ranges_are_utf8_byte_offsets_so_non_ascii_text_stays_aligned() {
        let text = "let ü = \"✓\" // ok";
        let comment = tokens(text, &SWIFT).into_iter().find(|token| token.kind == Comment).unwrap();
        assert_eq!(&text[comment.range], "// ok");
        let string = tokens("\"a\\é\" x", &SWIFT).into_iter().find(|token| token.kind == String).unwrap();
        assert_eq!(&"\"a\\é\" x"[string.range], "\"a\\é\"");
    }

    #[test]
    fn files_are_matched_by_name_then_extension() {
        assert_eq!(CodeLanguage::for_file("Makefile").map(|l| l.id), Some("makefile"));
        assert_eq!(CodeLanguage::for_file("Dockerfile.dev").map(|l| l.id), Some("dockerfile"));
        assert_eq!(CodeLanguage::for_file(".env.local").map(|l| l.id), Some("dotenv"));
        assert_eq!(CodeLanguage::for_file("App.TSX").map(|l| l.id), Some("typescript"));
        assert_eq!(CodeLanguage::for_file("notes.txt"), None);
        assert_eq!(CodeLanguage::for_file("README"), None);
        assert_eq!(CodeLanguage::for_file(".hidden"), None);
    }

    #[test]
    fn fence_names_and_extensions_both_name_languages() {
        assert_eq!(CodeLanguage::named("ts").map(|l| l.id), Some("typescript"));
        assert_eq!(CodeLanguage::named("Objective-C").map(|l| l.id), Some("cpp"));
        assert_eq!(CodeLanguage::named("console").map(|l| l.id), Some("shell"));
        assert_eq!(CodeLanguage::named("text"), None);
    }

    #[test]
    fn keywords_tags_and_headings_are_emphasized_and_only_comments_are_italic() {
        let emphasized: Vec<_> =
            SyntaxTokenKind::ALL.into_iter().filter(|kind| kind.is_emphasized()).collect();
        assert_eq!(emphasized, [Keyword, Tag, Heading]);
        let italic: Vec<_> = SyntaxTokenKind::ALL.into_iter().filter(|kind| kind.is_italic()).collect();
        assert_eq!(italic, [Comment]);
    }

    #[test]
    fn sql_and_dockerfile_keywords_ignore_case() {
        assert_eq!(texts(&highlighted("SELECT a FROM t", &SQL), Keyword), ["SELECT", "FROM"]);
        assert_eq!(texts(&highlighted("FROM rust AS build", &DOCKERFILE), Keyword), ["FROM", "AS"]);
    }
}
