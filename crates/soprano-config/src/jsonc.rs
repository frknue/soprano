//! The text engine behind Soprano's VS Code-style `~/.config/soprano/settings.json`
//! (`Config/JSONCText.swift`).
//!
//! Two jobs a plain JSON decoder cannot do:
//!
//! 1. **Read what humans write.** Settings files collect `//` and `/* */` comments and trailing
//!    commas. Rejecting them would mean telling the user their hand-written file is invalid over
//!    a stray comma.
//! 2. **Write one value back without destroying the file.** Decoding a model, mutating it and
//!    re-encoding would silently delete every comment, blank line and hand-chosen key order in
//!    the document. So a write is applied as a single surgical text splice over the original
//!    characters — the same approach as VS Code's `jsonc-parser` `modify`/`applyEdits`.
//!
//! Positions are counted in Unicode scalar values (`char`s); a `\r\n` pair counts as one line
//! break, as Swift's `Character` did.

use std::fmt;

use serde::de::DeserializeOwned;
use serde_json::Value;

/// A syntax problem, positioned in the *original* document.
///
/// Comment stripping blanks characters in place instead of deleting them, so every index the
/// parser reports still lines up with what the user sees in their editor.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseError {
    /// Human-readable cause, without the position (the settings UI renders the line
    /// separately).
    pub message: String,
    /// 1-based line in the original text.
    pub line: usize,
    /// 1-based column in the original text, counted in characters.
    pub column: usize,
}

impl ParseError {
    fn at_start(message: impl Into<String>) -> Self {
        Self { message: message.into(), line: 1, column: 1 }
    }
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} (line {}, column {})", self.message, self.line, self.column)
    }
}

impl std::error::Error for ParseError {}

/// Why [`decode`] failed: the text is not JSONC, or it is but its shape does not fit `T`.
#[derive(Debug)]
pub enum DecodeError {
    Syntax(ParseError),
    /// The document parsed but a value has the wrong type or a required key is missing.
    Shape {
        /// Dotted path to the offending value (`keybindings.prefixTimeoutMs`, `agents[0]`);
        /// empty for the document itself.
        path: String,
        /// serde's message without its position suffix, e.g.
        /// `invalid type: string "x", expected i64` or ``missing field `id` ``.
        message: String,
    },
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Syntax(error) => error.fmt(f),
            Self::Shape { path, message } if path.is_empty() => f.write_str(message),
            Self::Shape { path, message } => write!(f, "{path}: {message}"),
        }
    }
}

impl std::error::Error for DecodeError {}

// MARK: - Reading

/// JSONC text -> strict JSON text (comments and trailing commas removed).
///
/// The surviving characters are the user's own: numbers and strings are passed through
/// verbatim rather than re-serialized, so nothing is reformatted or rounded on the way to the
/// decoder.
pub fn strict_json(text: &str) -> Result<String, ParseError> {
    let source: Vec<char> = text.chars().collect();
    let (mut stripped, _) = stripping_comments(&source)?;
    let mut parser = Parser::new(&stripped, &source);
    parser.parse_document()?;
    let commas = std::mem::take(&mut parser.trailing_commas);
    let duplicates = std::mem::take(&mut parser.duplicate_spans);
    for index in commas {
        stripped[index] = ' ';
    }
    for (start, end) in duplicates {
        for character in &mut stripped[start..end] {
            if !is_newline(*character) {
                *character = ' ';
            }
        }
    }
    Ok(stripped.into_iter().collect())
}

/// Decode a value from JSONC text.
pub fn decode<T: DeserializeOwned>(text: &str) -> Result<T, DecodeError> {
    let strict = strict_json(text).map_err(DecodeError::Syntax)?;
    let mut deserializer = serde_json::Deserializer::from_str(&strict);
    let value = serde_path_to_error::deserialize(&mut deserializer).map_err(|error| {
        // Swift's coding-path text: keys and `[index]` joined by dots (`agents.[0].id`).
        let path = error
            .path()
            .iter()
            .map(|segment| match segment {
                serde_path_to_error::Segment::Seq { index } => format!("[{index}]"),
                serde_path_to_error::Segment::Map { key } => key.clone(),
                serde_path_to_error::Segment::Enum { variant } => variant.clone(),
                serde_path_to_error::Segment::Unknown => "?".into(),
            })
            .collect::<Vec<_>>()
            .join(".");
        DecodeError::Shape { path, message: strip_position(&error.into_inner().to_string()) }
    })?;
    deserializer.end().map_err(|error| DecodeError::Shape {
        path: String::new(),
        message: strip_position(&error.to_string()),
    })?;
    Ok(value)
}

fn strip_position(message: &str) -> String {
    match message.rfind(" at line ") {
        Some(index) => message[..index].to_owned(),
        None => message.to_owned(),
    }
}

// MARK: - Writing

/// Surgically set the value at the given key path, preserving every comment, blank line, key
/// order and indentation style in the rest of the document. Missing intermediate objects are
/// created. `Value::Null` writes JSON `null`.
pub fn setting(value: &Value, path: &[&str], text: &str) -> Result<String, ParseError> {
    if path.is_empty() {
        return Err(ParseError::at_start("Cannot set a value without a key path"));
    }
    let source: Vec<char> = text.chars().collect();
    let (stripped, is_comment) = stripping_comments(&source)?;
    let unit = indent_unit(&source);

    // Empty, whitespace-only or comment-only file: there is no document to splice into, so
    // write a fresh one under whatever the user had.
    if !stripped.iter().any(|&c| !is_whitespace(c)) {
        return new_document(value, path, &source, &unit);
    }

    let mut parser = Parser::new(&stripped, &source);
    let root = parser.parse_document()?;
    if !matches!(root.kind, Kind::Object(_)) {
        return Err(parse_error("Expected the document root to be a JSON object", root.start, &source));
    }
    let context = EditContext { source: &source, stripped: &stripped, is_comment: &is_comment, unit: &unit };
    let edit = setting_edit(value, path, &root, &context)?;
    Ok(apply(&edit, &source))
}

/// Surgically remove the key at the given path. No-op when absent.
pub fn removing(path: &[&str], text: &str) -> Result<String, ParseError> {
    if path.is_empty() {
        return Err(ParseError::at_start("Cannot remove a value without a key path"));
    }
    let source: Vec<char> = text.chars().collect();
    let (stripped, is_comment) = stripping_comments(&source)?;
    if !stripped.iter().any(|&c| !is_whitespace(c)) {
        return Ok(text.to_owned());
    }

    let mut parser = Parser::new(&stripped, &source);
    let root = parser.parse_document()?;
    if !matches!(root.kind, Kind::Object(_)) {
        return Err(parse_error("Expected the document root to be a JSON object", root.start, &source));
    }
    let unit = String::new();
    let context = EditContext { source: &source, stripped: &stripped, is_comment: &is_comment, unit: &unit };
    match removal_edit(path, &root, &context) {
        Some(edit) => Ok(apply(&edit, &source)),
        None => Ok(text.to_owned()),
    }
}

// MARK: - Comment stripping

/// Replaces every comment with spaces, leaving newlines alone, and reports which characters
/// those comments occupied.
///
/// Blanking rather than deleting is what keeps parser positions valid in the original
/// document, and what lets the edit machinery treat "trailing comment on this line" as plain
/// whitespace. The companion `is_comment` map is what stops it from treating the *inside* of a
/// multi-line block comment as whitespace too — splicing a new entry there would silently
/// comment it out.
fn stripping_comments(source: &[char]) -> Result<(Vec<char>, Vec<bool>), ParseError> {
    let mut output = source.to_vec();
    let mut is_comment = vec![false; source.len()];
    let mut index = 0;
    let mut in_string = false;

    while index < source.len() {
        let character = source[index];

        if in_string {
            if character == '\\' {
                index += 2;
                continue;
            }
            if character == '"' {
                in_string = false;
            }
            index += 1;
            continue;
        }

        if character == '"' {
            in_string = true;
            index += 1;
            continue;
        }

        if character == '/' && index + 1 < source.len() {
            let next = source[index + 1];
            if next == '/' {
                while index < source.len() && !is_newline(source[index]) {
                    output[index] = ' ';
                    is_comment[index] = true;
                    index += 1;
                }
                continue;
            }
            if next == '*' {
                let start = index;
                output[index] = ' ';
                output[index + 1] = ' ';
                is_comment[index] = true;
                is_comment[index + 1] = true;
                index += 2;
                let mut closed = false;
                while index < source.len() {
                    if source[index] == '*' && index + 1 < source.len() && source[index + 1] == '/' {
                        output[index] = ' ';
                        output[index + 1] = ' ';
                        is_comment[index] = true;
                        is_comment[index + 1] = true;
                        index += 2;
                        closed = true;
                        break;
                    }
                    if !is_newline(source[index]) {
                        output[index] = ' ';
                    }
                    is_comment[index] = true;
                    index += 1;
                }
                if !closed {
                    return Err(parse_error("Unterminated block comment", start, source));
                }
                continue;
            }
        }

        index += 1;
    }
    Ok((output, is_comment))
}

/// Advances past whitespace *and whole comments* — including the newlines inside a block
/// comment, which are the trap: they look like the end of the line but are not a place any
/// JSON may be written.
fn skipping_trailing_filler(position: usize, stripped: &[char], is_comment: &[bool]) -> usize {
    let mut scan = position;
    while scan < stripped.len() && (is_comment[scan] || is_indent_character(stripped[scan])) {
        scan += 1;
    }
    scan
}

// MARK: - Parsed shape

/// A value plus its span in the document. Spans are the whole point: they are what an edit
/// replaces.
struct ParsedValue {
    kind: Kind,
    start: usize,
    end: usize,
}

enum Kind {
    Object(Vec<ParsedMember>),
    Array,
    Scalar,
}

struct ParsedMember {
    key: String,
    /// Index of the opening quote of the key.
    key_start: usize,
    value: ParsedValue,
}

/// Recursive-descent scanner over the comment-stripped characters, with the original text kept
/// alongside purely for error positions.
struct Parser<'a> {
    characters: &'a [char],
    source: &'a [char],
    index: usize,
    /// Commas that sit directly before a `}` or `]`; blanked out when producing strict JSON.
    trailing_commas: Vec<usize>,
    /// A repeated key in one object, from the comma before it to the end of its value; blanked
    /// out when producing strict JSON, so the first occurrence wins — the same one the writer
    /// edits — and a duplicate never rejects the file.
    duplicate_spans: Vec<(usize, usize)>,
}

impl<'a> Parser<'a> {
    fn new(characters: &'a [char], source: &'a [char]) -> Self {
        Self { characters, source, index: 0, trailing_commas: Vec::new(), duplicate_spans: Vec::new() }
    }

    fn parse_document(&mut self) -> Result<ParsedValue, ParseError> {
        self.skip_whitespace();
        let value = self.parse_value()?;
        self.skip_whitespace();
        if self.index < self.characters.len() {
            return Err(self.error(
                format!("Unexpected character '{}' after the top-level value", self.characters[self.index]),
                None,
            ));
        }
        Ok(value)
    }

    fn peek(&self) -> Option<char> {
        self.characters.get(self.index).copied()
    }

    fn skip_whitespace(&mut self) {
        while self.peek().is_some_and(is_whitespace) {
            self.index += 1;
        }
    }

    fn parse_value(&mut self) -> Result<ParsedValue, ParseError> {
        let Some(character) = self.peek() else {
            return Err(self.error("Unexpected end of input, expected a value", None));
        };
        match character {
            '{' => self.parse_object(),
            '[' => self.parse_array(),
            '"' => {
                let start = self.index;
                self.parse_string_literal()?;
                Ok(ParsedValue { kind: Kind::Scalar, start, end: self.index })
            }
            't' => self.parse_literal("true"),
            'f' => self.parse_literal("false"),
            'n' => self.parse_literal("null"),
            '-' | '0'..='9' => self.parse_number(),
            other => Err(self.error(format!("Unexpected character '{other}'"), None)),
        }
    }

    fn parse_object(&mut self) -> Result<ParsedValue, ParseError> {
        let start = self.index;
        self.index += 1;
        let mut members: Vec<ParsedMember> = Vec::new();
        let mut last_comma = None;
        let end_of_input = self.characters.len();

        loop {
            self.skip_whitespace();
            match self.peek() {
                None => return Err(self.error("Unexpected end of input, expected '}'", Some(end_of_input))),
                Some('}') => {
                    self.index += 1;
                    break;
                }
                Some('"') => {}
                Some(_) => return Err(self.error("Expected a double-quoted key", None)),
            }
            let key_start = self.index;
            let key = self.parse_string_literal()?;
            self.skip_whitespace();
            if self.peek() != Some(':') {
                return Err(self.error("Expected ':'", Some(self.index.min(end_of_input))));
            }
            self.index += 1;
            self.skip_whitespace();
            let value = self.parse_value()?;
            if let Some(comma) = last_comma
                && members.iter().any(|member| member.key == key)
            {
                self.duplicate_spans.push((comma, value.end));
            }
            members.push(ParsedMember { key, key_start, value });

            self.skip_whitespace();
            match self.peek() {
                None => return Err(self.error("Unexpected end of input, expected '}'", Some(end_of_input))),
                Some(',') => {
                    let comma = self.index;
                    last_comma = Some(comma);
                    self.index += 1;
                    self.skip_whitespace();
                    if self.peek() == Some('}') {
                        self.trailing_commas.push(comma);
                    }
                }
                Some('}') => {
                    self.index += 1;
                    break;
                }
                Some(_) => return Err(self.error("Expected ','", None)),
            }
        }
        Ok(ParsedValue { kind: Kind::Object(members), start, end: self.index })
    }

    fn parse_array(&mut self) -> Result<ParsedValue, ParseError> {
        let start = self.index;
        self.index += 1;
        let end_of_input = self.characters.len();

        loop {
            self.skip_whitespace();
            match self.peek() {
                None => return Err(self.error("Unexpected end of input, expected ']'", Some(end_of_input))),
                Some(']') => {
                    self.index += 1;
                    break;
                }
                Some(_) => {}
            }
            self.parse_value()?;
            self.skip_whitespace();
            match self.peek() {
                None => return Err(self.error("Unexpected end of input, expected ']'", Some(end_of_input))),
                Some(',') => {
                    let comma = self.index;
                    self.index += 1;
                    self.skip_whitespace();
                    if self.peek() == Some(']') {
                        self.trailing_commas.push(comma);
                    }
                }
                Some(']') => {
                    self.index += 1;
                    break;
                }
                Some(_) => return Err(self.error("Expected ','", None)),
            }
        }
        Ok(ParsedValue { kind: Kind::Array, start, end: self.index })
    }

    fn parse_literal(&mut self, literal: &str) -> Result<ParsedValue, ParseError> {
        let start = self.index;
        for expected in literal.chars() {
            if self.peek() != Some(expected) {
                return Err(self.error(format!("Expected '{literal}'"), Some(start)));
            }
            self.index += 1;
        }
        Ok(ParsedValue { kind: Kind::Scalar, start, end: self.index })
    }

    fn parse_number(&mut self) -> Result<ParsedValue, ParseError> {
        let start = self.index;
        if self.peek() == Some('-') {
            self.index += 1;
        }
        if !self.consume_digits() {
            return Err(self.error("Invalid number", Some(start)));
        }
        if self.peek() == Some('.') {
            self.index += 1;
            if !self.consume_digits() {
                return Err(self.error("Invalid number", Some(start)));
            }
        }
        if matches!(self.peek(), Some('e' | 'E')) {
            self.index += 1;
            if matches!(self.peek(), Some('+' | '-')) {
                self.index += 1;
            }
            if !self.consume_digits() {
                return Err(self.error("Invalid number", Some(start)));
            }
        }
        Ok(ParsedValue { kind: Kind::Scalar, start, end: self.index })
    }

    fn consume_digits(&mut self) -> bool {
        let start = self.index;
        while self.peek().is_some_and(|c| c.is_ascii_digit()) {
            self.index += 1;
        }
        self.index > start
    }

    /// Consumes a string literal and returns its decoded contents (needed so key paths match
    /// keys that were written with escapes).
    fn parse_string_literal(&mut self) -> Result<String, ParseError> {
        let start = self.index;
        self.index += 1;
        let mut value = String::new();

        while let Some(character) = self.peek() {
            if character == '"' {
                self.index += 1;
                return Ok(value);
            }
            if character == '\\' {
                let escape_start = self.index;
                self.index += 1;
                let Some(escaped) = self.peek() else { break };
                match escaped {
                    '"' => value.push('"'),
                    '\\' => value.push('\\'),
                    '/' => value.push('/'),
                    'b' => value.push('\u{08}'),
                    'f' => value.push('\u{0C}'),
                    'n' => value.push('\n'),
                    'r' => value.push('\r'),
                    't' => value.push('\t'),
                    'u' => {
                        value.push(self.consume_unicode_escape(escape_start)?);
                        continue;
                    }
                    other => {
                        return Err(self.error(
                            format!("Invalid escape sequence '\\{other}' in string"),
                            Some(escape_start),
                        ));
                    }
                }
                self.index += 1;
                continue;
            }
            value.push(character);
            self.index += 1;
        }
        Err(self.error("Unterminated string", Some(start)))
    }

    /// Reads `\uXXXX` (already positioned on the `u`), pairing surrogates so astral-plane keys
    /// survive the round trip.
    fn consume_unicode_escape(&mut self, escape_start: usize) -> Result<char, ParseError> {
        let first = self.read_hex_quad(escape_start)?;
        self.index += 5;

        if (0xD800..=0xDBFF).contains(&first)
            && self.index + 1 < self.characters.len()
            && self.characters[self.index] == '\\'
            && self.characters[self.index + 1] == 'u'
            && let Ok(second) = self.read_hex_quad(self.index)
            && (0xDC00..=0xDFFF).contains(&second)
        {
            let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00);
            self.index += 6;
            return char::from_u32(combined)
                .ok_or_else(|| self.error("Invalid \\u escape in string", Some(escape_start)));
        }
        char::from_u32(first).ok_or_else(|| self.error("Invalid \\u escape in string", Some(escape_start)))
    }

    /// Reads the four hex digits that follow a `\u` whose backslash is at `backslash`.
    fn read_hex_quad(&self, backslash: usize) -> Result<u32, ParseError> {
        let mut value = 0u32;
        for offset in 2..=5 {
            let digit = self
                .characters
                .get(backslash + offset)
                .and_then(|c| c.to_digit(16).filter(|_| c.is_ascii_hexdigit()))
                .ok_or_else(|| self.error("Invalid \\u escape in string", Some(backslash)))?;
            value = value * 16 + digit;
        }
        Ok(value)
    }

    fn error(&self, message: impl Into<String>, position: Option<usize>) -> ParseError {
        parse_error(message, position.unwrap_or(self.index), self.source)
    }
}

// MARK: - Edits

/// A single splice: replace `[start, end)` with `text`.
struct Edit {
    start: usize,
    end: usize,
    text: String,
}

struct EditContext<'a> {
    source: &'a [char],
    stripped: &'a [char],
    is_comment: &'a [bool],
    unit: &'a str,
}

fn apply(edit: &Edit, source: &[char]) -> String {
    let mut output: String = source[..edit.start].iter().collect();
    output.push_str(&edit.text);
    output.extend(&source[edit.end..]);
    output
}

fn collect(chars: &[char]) -> String {
    chars.iter().collect()
}

fn setting_edit(
    value: &Value,
    path: &[&str],
    object: &ParsedValue,
    context: &EditContext<'_>,
) -> Result<Edit, ParseError> {
    let (Some((key, rest)), Kind::Object(members)) = (path.split_first(), &object.kind) else {
        return Err(parse_error("Expected a JSON object", object.start, context.source));
    };

    let Some(member) = members.iter().find(|m| m.key == *key) else {
        return insertion(&nested(value, rest), key, object, members, context);
    };

    if rest.is_empty() {
        let indent = line_indent(member.key_start, context.source);
        return Ok(Edit {
            start: member.value.start,
            end: member.value.end,
            text: format_value(value, &indent, context.unit),
        });
    }
    if matches!(member.value.kind, Kind::Object(_)) {
        return setting_edit(value, rest, &member.value, context);
    }
    // The path continues but the existing value cannot hold it (a string where an object is
    // needed): replace it wholesale.
    let indent = line_indent(member.key_start, context.source);
    Ok(Edit {
        start: member.value.start,
        end: member.value.end,
        text: format_value(&nested(value, rest), &indent, context.unit),
    })
}

fn insertion(
    value: &Value,
    key: &str,
    object: &ParsedValue,
    members: &[ParsedMember],
    context: &EditContext<'_>,
) -> Result<Edit, ParseError> {
    let EditContext { source, stripped, is_comment, unit } = *context;
    let object_indent = line_indent(object.start, source);
    let close_index = object.end - 1;
    let single_line = !stripped[object.start..object.end].iter().any(|&c| is_newline(c));

    let Some(last) = members.last() else {
        let child_indent = format!("{object_indent}{unit}");
        let entry = entry_text(key, value, &child_indent, unit);
        let line_start = line_start_index(close_index, source);
        if source[line_start..close_index].iter().all(|&c| is_indent_character(c)) {
            // The `}` already owns its line, so the new entry gets the line above.
            return Ok(Edit { start: line_start, end: line_start, text: format!("{child_indent}{entry}\n") });
        }
        return Ok(Edit {
            start: close_index,
            end: close_index,
            text: format!("\n{child_indent}{entry}\n{object_indent}"),
        });
    };

    let mut position = last.value.end;
    let mut needs_comma = true;
    let mut scan = position;
    while scan < stripped.len() && is_whitespace(stripped[scan]) {
        scan += 1;
    }
    if scan < stripped.len() && stripped[scan] == ',' {
        // Any comma after the last member is a trailing comma; write after it.
        position = scan + 1;
        needs_comma = false;
    }

    let child_indent = sibling_indent(last, source).unwrap_or_else(|| format!("{object_indent}{unit}"));
    let entry = entry_text(key, value, &child_indent, unit);
    if single_line {
        let separator = if needs_comma { ", " } else { " " };
        return Ok(Edit { start: position, end: position, text: format!("{separator}{entry}") });
    }

    // A trailing comment (blanked to spaces here) documents the entry it follows, so the new
    // entry goes below it while the separating comma stays where JSON needs it — before the
    // comment, not inside it.
    let mut tail = position;
    let line_scan = skipping_trailing_filler(position, stripped, is_comment);
    if line_scan < stripped.len() && is_newline(stripped[line_scan]) {
        tail = line_scan;
    }
    let preserved = collect(&source[position..tail]);
    let comma = if needs_comma { "," } else { "" };
    Ok(Edit { start: position, end: tail, text: format!("{comma}{preserved}\n{child_indent}{entry}") })
}

fn removal_edit(path: &[&str], object: &ParsedValue, context: &EditContext<'_>) -> Option<Edit> {
    let EditContext { source, stripped, is_comment, .. } = *context;
    let (key, rest) = path.split_first()?;
    let Kind::Object(members) = &object.kind else { return None };
    let member = members.iter().find(|m| m.key == *key)?;

    if !rest.is_empty() {
        return removal_edit(rest, &member.value, context);
    }

    // Sole member and nothing else inside the braces: collapse to `{}` rather than leaving a
    // hollow, oddly indented shell.
    if members.len() == 1 {
        let interior_is_blank = ((object.start + 1)..(object.end - 1))
            .filter(|&i| i < member.key_start || i >= member.value.end)
            .all(|i| is_whitespace(source[i]));
        if interior_is_blank {
            return Some(Edit { start: object.start, end: object.end, text: "{}".into() });
        }
    }

    let mut start = member.key_start;
    let mut end = member.value.end;

    // The comma that goes with the entry: the one after it, or — for the last entry — the one
    // before it.
    let mut preceding_comma = None;
    let mut forward = end;
    while forward < stripped.len() && is_whitespace(stripped[forward]) {
        forward += 1;
    }
    if forward < stripped.len() && stripped[forward] == ',' {
        end = forward + 1;
    } else {
        let mut backward = start;
        while backward > 0 && is_whitespace(stripped[backward - 1]) {
            backward -= 1;
        }
        if backward > 0 && stripped[backward - 1] == ',' {
            preceding_comma = Some(backward - 1);
        }
    }

    // When the entry had its line to itself, take the line with it — including a trailing
    // comment, which documented the entry being removed. The prefix check reads the original
    // text so a *leading* comment on that line keeps the line alive.
    let mut owns_line = false;
    let line_start = line_start_index(start, source);
    if source[line_start..start].iter().all(|&c| is_indent_character(c)) {
        let trailing = skipping_trailing_filler(end, stripped, is_comment);
        if trailing < source.len() && is_newline(source[trailing]) {
            start = line_start;
            // A `\r\n` line break goes as a whole.
            end = if source[trailing] == '\r' && source.get(trailing + 1) == Some(&'\n') {
                trailing + 2
            } else {
                trailing + 1
            };
            owns_line = true;
        }
    }

    // Only the preceding comma goes: what sits between it and the entry — a comment
    // documenting the entry before, the line break that ends that entry's line — stays.
    let Some(comma) = preceding_comma else { return Some(Edit { start, end, text: String::new() }) };
    let between = (comma + 1)..start;
    if owns_line {
        return Some(Edit { start: comma, end, text: collect(&source[between]) });
    }
    if !between.clone().any(|i| is_comment[i]) {
        return Some(Edit { start: comma, end, text: String::new() });
    }
    let mut kept = &source[between];
    // Spaces only: the line break after a `//` comment ends it, and the closing brace may
    // follow on the same line as the removed entry.
    while let Some((&last, rest)) = kept.split_last() {
        if !is_indent_character(last) {
            break;
        }
        kept = rest;
    }
    Some(Edit { start: comma, end, text: collect(kept) })
}

/// Builds the document for an empty (or comment-only) file, keeping whatever the user already
/// typed above it.
fn new_document(value: &Value, path: &[&str], source: &[char], unit: &str) -> Result<String, ParseError> {
    let entry = entry_text(path[0], &nested(value, &path[1..]), unit, unit);
    let body = format!("{{\n{unit}{entry}\n}}\n");

    let mut prefix = source;
    while let Some((&last, rest)) = prefix.split_last() {
        if !is_whitespace(last) {
            break;
        }
        prefix = rest;
    }
    Ok(if prefix.is_empty() { body } else { format!("{}\n{body}", collect(prefix)) })
}

/// Wraps `value` in the objects named by `keys`, innermost last.
fn nested(value: &Value, keys: &[&str]) -> Value {
    match keys.split_first() {
        None => value.clone(),
        Some((key, rest)) => {
            let mut object = serde_json::Map::new();
            object.insert((*key).to_owned(), nested(value, rest));
            Value::Object(object)
        }
    }
}

// MARK: - Formatting

fn entry_text(key: &str, value: &Value, indent: &str, unit: &str) -> String {
    format!("{}: {}", quoted(key), format_value(value, indent, unit))
}

/// A number as a JSON value for [`setting`]. NaN and infinity have no JSON form; converting
/// them with `Value::from` silently yields `null`, so they are refused here instead.
pub fn number_value(number: f64) -> Result<Value, ParseError> {
    serde_json::Number::from_f64(number)
        .map(Value::Number)
        .ok_or_else(|| ParseError::at_start("Cannot write a non-finite number"))
}

/// Renders a value, pretty-printed with sorted keys and every continuation line sitting at
/// `indent`.
fn format_value(value: &Value, indent: &str, unit: &str) -> String {
    match value {
        Value::Null => "null".into(),
        Value::Bool(flag) => flag.to_string(),
        Value::String(string) => quoted(string),
        Value::Object(object) => {
            if object.is_empty() {
                return "{}".into();
            }
            let inner = format!("{indent}{unit}");
            let mut keys: Vec<&String> = object.keys().collect();
            keys.sort();
            let entries: Vec<String> = keys
                .into_iter()
                .map(|key| format!("{inner}{}", entry_text(key, &object[key], &inner, unit)))
                .collect();
            format!("{{\n{}\n{indent}}}", entries.join(",\n"))
        }
        Value::Array(array) => {
            if array.is_empty() {
                return "[]".into();
            }
            let inner = format!("{indent}{unit}");
            let entries: Vec<String> = array
                .iter()
                .map(|element| format!("{inner}{}", format_value(element, &inner, unit)))
                .collect();
            format!("[\n{}\n{indent}]", entries.join(",\n"))
        }
        Value::Number(number) => {
            if number.is_i64() || number.is_u64() {
                return number.to_string();
            }
            match number.as_f64() {
                Some(double) if double == double.round() && double.abs() < 1e15 => {
                    (double as i64).to_string()
                }
                _ => number.to_string(),
            }
        }
    }
}

fn quoted(string: &str) -> String {
    let mut output = String::with_capacity(string.len() + 2);
    output.push('"');
    for scalar in string.chars() {
        match scalar {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            '\u{08}' => output.push_str("\\b"),
            '\u{0C}' => output.push_str("\\f"),
            c if (c as u32) < 0x20 => output.push_str(&format!("\\u{:04x}", c as u32)),
            c => output.push(c),
        }
    }
    output.push('"');
    output
}

// MARK: - Layout helpers

/// The document's indent unit, guessed from the first indented line. Two spaces when the file
/// has nothing to learn from.
fn indent_unit(source: &[char]) -> String {
    let mut line_start = 0;
    for index in 0..=source.len() {
        if index == source.len() || is_newline(source[index]) {
            let mut scan = line_start;
            while scan < index && is_indent_character(source[scan]) {
                scan += 1;
            }
            if scan > line_start && scan < index {
                let prefix = collect(&source[line_start..scan]);
                return if prefix.contains('\t') { "\t".into() } else { prefix };
            }
            line_start = index + 1;
        }
    }
    "  ".into()
}

fn line_start_index(index: usize, source: &[char]) -> usize {
    let mut start = index.min(source.len());
    while start > 0 && !is_newline(source[start - 1]) {
        start -= 1;
    }
    start
}

fn line_indent(index: usize, source: &[char]) -> String {
    let start = line_start_index(index, source);
    let mut scan = start;
    while scan < index && scan < source.len() && is_indent_character(source[scan]) {
        scan += 1;
    }
    collect(&source[start..scan])
}

/// The indentation a sibling entry uses, or `None` when the member shares its line with other
/// content and therefore teaches us nothing.
fn sibling_indent(member: &ParsedMember, source: &[char]) -> Option<String> {
    let line_start = line_start_index(member.key_start, source);
    let prefix = &source[line_start..member.key_start];
    prefix.iter().all(|&c| is_indent_character(c)).then(|| collect(prefix))
}

/// Swift's `Character.isNewline`.
fn is_newline(character: char) -> bool {
    matches!(character, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

fn is_whitespace(character: char) -> bool {
    character == ' ' || character == '\t' || is_newline(character)
}

fn is_indent_character(character: char) -> bool {
    character == ' ' || character == '\t'
}

fn parse_error(message: impl Into<String>, index: usize, source: &[char]) -> ParseError {
    let mut line = 1;
    let mut column = 1;
    let limit = index.min(source.len());
    for position in 0..limit {
        let character = source[position];
        if character == '\r' && source.get(position + 1) == Some(&'\n') {
            // `\r\n` is one line break; the `\n` counts it.
            continue;
        }
        if is_newline(character) {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    ParseError { message: message.into(), line, column }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;
    use serde_json::{Map, json};

    fn top_level_object(text: &str) -> Map<String, Value> {
        let strict = strict_json(text).expect("valid JSONC");
        match serde_json::from_str::<Value>(&strict).expect("valid strict JSON") {
            Value::Object(map) => map,
            _ => Map::new(),
        }
    }

    fn parse_error_from(text: &str) -> Option<ParseError> {
        strict_json(text).err()
    }

    fn set(value: Value, path: &[&str], text: &str) -> String {
        setting(&value, path, text).expect("setting succeeds")
    }

    fn remove(path: &[&str], text: &str) -> String {
        removing(path, text).expect("removing succeeds")
    }

    // MARK: - Reading

    #[test]
    fn strips_line_and_block_comments_before_handing_the_document_to_the_decoder() {
        let text = "// a leading note\n{\n  // about a\n  \"a\": 1, /* inline */ \"b\": 2,\n  /* a block\n     spanning lines */\n  \"c\": 3\n}";
        let values = top_level_object(text);
        assert_eq!(values["a"], 1);
        assert_eq!(values["b"], 2);
        assert_eq!(values["c"], 3);
    }

    #[test]
    fn leaves_comment_like_text_inside_string_values_alone() {
        let text = r#"{"url": "https://example.com//path", "note": "a /* not a comment */ b"}"#;
        let values = top_level_object(text);
        assert_eq!(values["url"], "https://example.com//path");
        assert_eq!(values["note"], "a /* not a comment */ b");
    }

    #[test]
    fn handles_escaped_quotes_escaped_backslashes_and_comments_containing_quotes() {
        let text = r#"{
  "quote": "she said \"hi\" // not a comment",
  "path": "C:\\temp\\",
  /* the comment says "hi" and /* looks nested */
  "kept": true
}"#;
        let values = top_level_object(text);
        assert_eq!(values["quote"], r#"she said "hi" // not a comment"#);
        assert_eq!(values["path"], r"C:\temp\");
        assert_eq!(values["kept"], true);
    }

    #[test]
    fn a_repeated_key_keeps_its_first_value_instead_of_rejecting_the_document() {
        let values = top_level_object("{\n  \"a\": 1,\n  \"b\": { \"x\": 1 },\n  \"a\": 2,\n}");
        assert_eq!(values["a"], 1);
        assert_eq!(values["b"]["x"], 1);
        assert_eq!(top_level_object(r#"{"a": 1, "b": 2, "a": {"deep": [3]}}"#)["a"], 1);
        assert_eq!(top_level_object(r#"{"m": {"k": "first", "k": "second"}}"#)["m"]["k"], "first");

        #[derive(Deserialize)]
        struct Theme {
            theme: String,
        }
        let decoded: Theme = decode(r#"{ "theme": "nord", "theme": "dracula" }"#).expect("decodes");
        assert_eq!(decoded.theme, "nord");
    }

    #[test]
    fn the_writer_edits_the_same_occurrence_of_a_repeated_key_the_reader_uses() {
        let text = "{\n  \"theme\": \"nord\",\n  \"theme\": \"dracula\"\n}";
        let updated = set(json!("gruvbox-dark"), &["theme"], text);
        assert_eq!(top_level_object(&updated)["theme"], "gruvbox-dark");
    }

    #[test]
    fn accepts_trailing_commas_in_objects_and_arrays() {
        let text = "{\n  \"list\": [1, 2, 3,],\n  \"nested\": { \"x\": 1, },\n}";
        let values = top_level_object(text);
        assert_eq!(values["list"], json!([1, 2, 3]));
        assert_eq!(values["nested"]["x"], 1);
    }

    #[test]
    fn decodes_jsonc_text_into_a_deserializable_value() {
        #[derive(Deserialize, PartialEq, Debug)]
        struct Sample {
            name: String,
            count: i64,
            flags: Vec<String>,
        }
        let text = "// sample settings\n{\n  \"name\": \"soprano\", // the app\n  \"count\": 3,\n  /* trailing comma below is fine */\n  \"flags\": [\"a\", \"b\",],\n}";
        let sample: Sample = decode(text).expect("decodes");
        assert_eq!(sample, Sample { name: "soprano".into(), count: 3, flags: vec!["a".into(), "b".into()] });
    }

    #[test]
    fn reports_error_positions_from_the_original_document_even_after_stripping_comments() {
        let line_commented = "{\n  // the entry below is missing its comma\n  \"a\": 1\n  \"b\": 2\n}";
        let line_error = parse_error_from(line_commented).expect("error");
        assert_eq!(line_error.message, "Expected ','");
        assert_eq!(line_error.line, 4);
        assert_eq!(line_error.column, 3);
        assert_eq!(line_error.to_string(), "Expected ',' (line 4, column 3)");

        // The same document, but with a multi-line block comment above the error: stripping
        // must not shift a single character.
        let block_commented =
            "{\n  /* a block comment\n     spanning two lines */\n  \"a\": 1\n  \"b\": 2\n}";
        let block_error = parse_error_from(block_commented).expect("error");
        assert_eq!(block_error.line, 5);
        assert_eq!(block_error.column, 3);

        assert_eq!(parse_error_from("{\n  \"a\": /* nope */ }").map(|e| e.line), Some(2));
        assert_eq!(
            parse_error_from("{ /* never closed").map(|e| e.message),
            Some("Unterminated block comment".into())
        );
    }

    // MARK: - Setting

    #[test]
    fn setting_an_existing_key_keeps_the_comment_above_it_and_the_comment_on_its_line() {
        let text =
            "{\n  // font size in points\n  \"fontSize\": 13, // tweak me\n  \"theme\": \"gruvbox-dark\"\n}";
        let updated = set(json!(16), &["fontSize"], text);
        assert_eq!(
            updated,
            "{\n  // font size in points\n  \"fontSize\": 16, // tweak me\n  \"theme\": \"gruvbox-dark\"\n}"
        );
        assert_eq!(top_level_object(&updated)["fontSize"], 16);
    }

    #[test]
    fn setting_a_missing_top_level_key_appends_it_with_the_sibling_indentation() {
        assert_eq!(
            set(json!("dark"), &["theme"], "{\n  \"a\": 1\n}"),
            "{\n  \"a\": 1,\n  \"theme\": \"dark\"\n}"
        );

        // An existing trailing comma is reused rather than doubled.
        assert_eq!(
            set(json!("dark"), &["theme"], "{\n  \"a\": 1,\n}"),
            "{\n  \"a\": 1,\n  \"theme\": \"dark\"\n}"
        );

        // The separating comma belongs before a trailing comment, not inside it.
        let with_comment = set(json!(2), &["b"], "{\n  \"a\": 1 // hi\n}");
        assert_eq!(with_comment, "{\n  \"a\": 1, // hi\n  \"b\": 2\n}");
        assert_eq!(top_level_object(&with_comment)["b"], 2);

        // A one-line object stays a one-line object.
        assert_eq!(set(json!(2), &["b"], "{ \"a\": 1 }"), "{ \"a\": 1, \"b\": 2 }");
    }

    #[test]
    fn setting_respects_the_indent_unit_the_document_already_uses() {
        assert_eq!(set(json!(2), &["b"], "{\n    \"a\": 1\n}"), "{\n    \"a\": 1,\n    \"b\": 2\n}");
        assert_eq!(set(json!(2), &["b"], "{\n\t\"a\": 1\n}"), "{\n\t\"a\": 1,\n\t\"b\": 2\n}");
    }

    #[test]
    fn setting_through_a_missing_intermediate_object_creates_the_whole_chain() {
        let created = set(json!("a"), &["keybindings", "prefixKey"], "{}");
        assert_eq!(created, "{\n  \"keybindings\": {\n    \"prefixKey\": \"a\"\n  }\n}");
        assert_eq!(top_level_object(&created)["keybindings"]["prefixKey"], "a");

        let deep = set(json!(1), &["a", "b", "c"], "{\n  \"z\": 0\n}");
        assert_eq!(deep, "{\n  \"z\": 0,\n  \"a\": {\n    \"b\": {\n      \"c\": 1\n    }\n  }\n}");

        // A scalar standing where an object is needed is replaced outright.
        let replaced = set(json!(1), &["a", "b"], "{\n  \"a\": \"scalar\"\n}");
        assert_eq!(replaced, "{\n  \"a\": {\n    \"b\": 1\n  }\n}");
    }

    #[test]
    fn setting_into_an_empty_or_comment_only_document_produces_a_valid_file() {
        assert_eq!(set(json!("dark"), &["theme"], ""), "{\n  \"theme\": \"dark\"\n}\n");
        assert_eq!(set(json!("dark"), &["theme"], "   \n\n"), "{\n  \"theme\": \"dark\"\n}\n");

        let from_comment = set(json!("dark"), &["theme"], "// hello\n");
        assert_eq!(from_comment, "// hello\n{\n  \"theme\": \"dark\"\n}\n");
        assert_eq!(top_level_object(&from_comment)["theme"], "dark");
    }

    #[test]
    fn writes_array_and_dictionary_values_pretty_printed_at_their_own_depth() {
        let base = "{\n  \"theme\": \"x\"\n}";

        let with_array = set(json!(["~/a", "~/b"]), &["projects"], base);
        assert_eq!(
            with_array,
            "{\n  \"theme\": \"x\",\n  \"projects\": [\n    \"~/a\",\n    \"~/b\"\n  ]\n}"
        );
        assert_eq!(top_level_object(&with_array)["projects"], json!(["~/a", "~/b"]));

        // Dictionary keys are sorted so writes stay deterministic.
        let with_dictionary = set(json!({"prefixTimeoutMs": 900, "prefixKey": "b"}), &["keybindings"], base);
        assert_eq!(
            with_dictionary,
            "{\n  \"theme\": \"x\",\n  \"keybindings\": {\n    \"prefixKey\": \"b\",\n    \"prefixTimeoutMs\": 900\n  }\n}"
        );

        let nested_text =
            set(json!({"x": {"y": [1, 2]}}), &["a", "b"], "{\n  \"a\": {\n    \"keep\": true\n  }\n}");
        assert_eq!(
            nested_text,
            "{\n  \"a\": {\n    \"keep\": true,\n    \"b\": {\n      \"x\": {\n        \"y\": [\n          1,\n          2\n        ]\n      }\n    }\n  }\n}"
        );
        assert!(!top_level_object(&nested_text).is_empty());

        let scalars = set(json!({"flag": true, "nothing": null, "ratio": 1.5, "empty": {}}), &["misc"], base);
        let misc = &top_level_object(&scalars)["misc"];
        assert_eq!(misc["flag"], true);
        assert!(misc["nothing"].is_null());
        assert_eq!(misc["ratio"], 1.5);
        assert_eq!(misc["empty"], json!({}));
    }

    // MARK: - Removing

    #[test]
    fn removing_drops_the_key_its_value_and_exactly_one_adjacent_comma() {
        let text = "{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": 3\n}";

        assert_eq!(remove(&["a"], text), "{\n  \"b\": 2,\n  \"c\": 3\n}");
        assert_eq!(remove(&["b"], text), "{\n  \"a\": 1,\n  \"c\": 3\n}");
        assert_eq!(remove(&["c"], text), "{\n  \"a\": 1,\n  \"b\": 2\n}");

        for key in ["a", "b", "c"] {
            let updated = remove(&[key], text);
            assert_eq!(top_level_object(&updated).len(), 2, "removing {key}");
        }

        assert_eq!(remove(&["a"], "{\n  \"a\": 1\n}"), "{}");
        assert_eq!(remove(&["a"], "{ \"a\": 1 }"), "{}");
        assert_eq!(
            remove(&["a", "b"], "{\n  \"a\": {\n    \"b\": 1,\n    \"c\": 2\n  }\n}"),
            "{\n  \"a\": {\n    \"c\": 2\n  }\n}"
        );
    }

    #[test]
    fn removing_keeps_unrelated_comments_and_ignores_absent_keys() {
        let text = "{\n  // about a\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": 3\n}";
        assert_eq!(remove(&["b"], text), "{\n  // about a\n  \"a\": 1,\n  \"c\": 3\n}");
        assert_eq!(remove(&["missing"], text), text);
        assert_eq!(remove(&["a", "deep"], text), text);
    }

    #[test]
    fn removing_the_last_key_keeps_the_comment_documenting_the_entry_before_it() {
        let text = "{\n  \"a\": 1, // about a\n  \"b\": 2\n}";
        assert_eq!(remove(&["b"], text), "{\n  \"a\": 1 // about a\n}");
        assert_eq!(remove(&["b"], r#"{ "a": 1, /* about a */ "b": 2 }"#), r#"{ "a": 1 /* about a */ }"#);
    }

    #[test]
    fn removing_a_last_key_that_shares_its_line_with_the_brace_keeps_the_line_comment_before_it_closed() {
        let text = "{ \"a\": 1, // note\n  \"b\": 2 }";
        let result = remove(&["b"], text);
        assert_eq!(result, "{ \"a\": 1 // note\n }");
        let decoded: std::collections::BTreeMap<String, i64> = decode(&result).expect("decodes");
        assert_eq!(decoded, [("a".to_string(), 1)].into_iter().collect());
    }

    // MARK: - Round trip

    #[test]
    fn applying_several_settings_to_a_realistic_file_keeps_it_parseable_and_commented() {
        let mut document = r#"// Soprano settings
{
  // Appearance
  "theme": "gruvbox-dark",
  "fontSize": 13,

  "keybindings": {
    "prefixKey": "a",
    /* milliseconds */
    "prefixTimeoutMs": 1500,
  },

  "projects": [
    "~/git/soprano",
  ],
}"#
        .to_string();

        let edits: Vec<(&str, Value, Vec<&str>)> = vec![
            ("fontSize", json!(15), vec!["fontSize"]),
            ("prefixKey", json!("b"), vec!["keybindings", "prefixKey"]),
            ("prefixTimeoutMs", json!(2000), vec!["keybindings", "prefixTimeoutMs"]),
            ("repeatable", json!(true), vec!["keybindings", "repeatable"]),
            ("projects", json!(["~/git/soprano", "~/git/edi"]), vec!["projects"]),
            ("animations", json!("linear"), vec!["animations", "curve"]),
        ];

        for (label, value, path) in edits {
            document = set(value, &path, &document);
            assert!(!top_level_object(&document).is_empty(), "{label} produced an unparseable document");
            assert!(document.contains("// Soprano settings"), "{label} dropped the header comment");
            assert!(document.contains("/* milliseconds */"), "{label} dropped a block comment");
        }

        let values = top_level_object(&document);
        assert_eq!(values["fontSize"], 15);
        assert_eq!(values["theme"], "gruvbox-dark");
        assert_eq!(values["projects"], json!(["~/git/soprano", "~/git/edi"]));
        assert_eq!(values["keybindings"]["prefixKey"], "b");
        assert_eq!(values["keybindings"]["prefixTimeoutMs"], 2000);
        assert_eq!(values["keybindings"]["repeatable"], true);
        assert_eq!(values["animations"]["curve"], "linear");

        document = remove(&["theme"], &document);
        let after_removal = top_level_object(&document);
        assert!(!after_removal.contains_key("theme"));
        assert_eq!(after_removal["fontSize"], 15);
        assert!(document.contains("// Soprano settings"));
        assert!(document.contains("// Appearance"));
    }

    #[test]
    fn a_crlf_document_reports_lines_the_way_an_editor_counts_them() {
        let error = parse_error_from("{\r\n  \"a\": 1\r\n  \"b\": 2\r\n}").expect("error");
        assert_eq!((error.line, error.column), (3, 3));
    }
}
