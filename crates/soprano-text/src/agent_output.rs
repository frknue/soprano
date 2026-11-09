//! Lightweight structure for an agent's plain terminal text (port of
//! `AgentOutputHighlighter.swift`).
//!
//! libghostty's text-reading API returns characters, not the cells' colors or font
//! attributes. This highlighter keeps the text exactly and derives presentation from
//! durable textual signals: prompts, Markdown structure, paths, diagnostics, diffs and
//! fenced code. The result is a list of [`OutputRun`]s covering the whole text in order;
//! ranges are UTF-8 byte ranges. Layers apply in the Swift order, later ones overriding the
//! attributes they set, exactly like `NSMutableAttributedString.addAttributes`.

use std::collections::HashMap;
use std::ops::Range;
use std::sync::LazyLock;

use fancy_regex::{Regex, RegexBuilder};

use crate::syntax::CodeLanguage;

/// A theme color role; the UI maps it onto the active palette.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum OutputColor {
    #[default]
    TextPrimary,
    TextMuted,
    Cyan,
    Blue,
    Success,
    Danger,
    Yellow,
    SyntaxKeyword,
    SyntaxString,
    SyntaxComment,
    SyntaxNumber,
    SyntaxType,
    SyntaxFunction,
    SyntaxAttribute,
}

/// Weight of the monospaced font (11 pt in the dashboard).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum OutputWeight {
    #[default]
    Regular,
    Semibold,
    Bold,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct OutputStyle {
    pub color: OutputColor,
    pub weight: OutputWeight,
    /// URLs are underlined.
    pub underline: bool,
    /// Inline code sits on `bgOverlay` at 55% alpha.
    pub code_background: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutputRun {
    pub range: Range<usize>,
    pub style: OutputStyle,
}

/// The attributes one layer sets; `None` leaves what is there.
#[derive(Clone, Copy, Default)]
struct Layer {
    color: Option<OutputColor>,
    weight: Option<OutputWeight>,
    underline: bool,
    code_background: bool,
}

impl Layer {
    fn color(color: OutputColor) -> Self {
        Self { color: Some(color), ..Self::default() }
    }

    fn semibold(color: OutputColor) -> Self {
        Self { color: Some(color), weight: Some(OutputWeight::Semibold), ..Self::default() }
    }
}

/// Styles `text`: the runs cover every byte of it, in order (empty text gives no runs).
pub fn highlight(text: &str) -> Vec<OutputRun> {
    let mut styles = vec![OutputStyle::default(); text.len()];
    let mut fence: Option<(&str, String)> = None;
    let mut in_diff = false;

    for line_range in lines(text) {
        let line = &text[line_range.clone()];
        let trimmed = trim_whitespace(line);
        let mut output = Output { styles: &mut styles, offset: line_range.start };

        if let Some((delimiter, language)) = fence_marker(trimmed) {
            output.style_fence_marker(line, language);
            if fence.as_ref().is_some_and(|open| open.0 == delimiter) {
                fence = None;
            } else if fence.is_none() {
                fence = Some((delimiter, normalized_language(language)));
            }
            in_diff = false;
        } else if let Some((_, language)) = &fence {
            output.style_code_line(line, language);
        } else {
            if begins_diff(trimmed) {
                in_diff = true;
            } else if in_diff && trimmed.is_empty() {
                in_diff = false;
            }
            output.style_terminal_line(line, in_diff);
        }
    }
    coalesce(&styles)
}

/// The content ranges of each line (without its terminator), as `NSString.getLineStart`
/// splits: `\n`, `\r\n`, `\r`, U+0085, U+2028 and U+2029 end lines.
fn lines(text: &str) -> Vec<Range<usize>> {
    let mut lines = Vec::new();
    let mut start = 0;
    let mut chars = text.char_indices().peekable();
    while let Some((index, character)) = chars.next() {
        match character {
            '\r' => {
                lines.push(start..index);
                if chars.peek().is_some_and(|(_, next)| *next == '\n') {
                    chars.next();
                    start = index + 2;
                } else {
                    start = index + 1;
                }
            }
            '\n' | '\u{85}' | '\u{2028}' | '\u{2029}' => {
                lines.push(start..index);
                start = index + character.len_utf8();
            }
            _ => {}
        }
    }
    if start < text.len() {
        lines.push(start..text.len());
    }
    lines
}

/// `trimmingCharacters(in: .whitespaces)`: spaces and tabs, not line breaks.
fn trim_whitespace(text: &str) -> &str {
    text.trim_matches(|character: char| {
        character == '\t' || (character.is_whitespace() && !is_line_break(character))
    })
}

fn is_line_break(character: char) -> bool {
    matches!(character, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

fn fence_marker(trimmed: &str) -> Option<(&'static str, &str)> {
    ["```", "~~~"]
        .into_iter()
        .find_map(|delimiter| trimmed.strip_prefix(delimiter).map(|rest| (delimiter, trim_whitespace(rest))))
}

fn normalized_language(language: &str) -> String {
    let lower = language.to_lowercase();
    match lower.as_str() {
        "js" | "jsx" | "javascript" => "javascript",
        "ts" | "tsx" | "typescript" => "typescript",
        "py" | "python" => "python",
        "rb" | "ruby" => "ruby",
        "sh" | "bash" | "zsh" | "shell" => "shell",
        "yml" | "yaml" => "yaml",
        "rs" | "rust" => "rust",
        "c++" | "cpp" | "cc" => "cpp",
        "objective-c" | "objc" => "objc",
        "patch" | "diff" => "diff",
        _ => return lower,
    }
    .to_string()
}

fn begins_diff(trimmed: &str) -> bool {
    trimmed.starts_with("diff --git ")
        || trimmed.starts_with("--- a/")
        || trimmed.starts_with("+++ b/")
        || trimmed.starts_with("@@")
}

struct Output<'a> {
    styles: &'a mut [OutputStyle],
    offset: usize,
}

impl Output<'_> {
    fn set(&mut self, range: Range<usize>, layer: Layer) {
        for style in &mut self.styles[self.offset + range.start..self.offset + range.end] {
            if let Some(color) = layer.color {
                style.color = color;
            }
            if let Some(weight) = layer.weight {
                style.weight = weight;
            }
            style.underline |= layer.underline;
            style.code_background |= layer.code_background;
        }
    }

    fn apply(&mut self, pattern: &Regex, line: &str, layer: Layer) {
        // An error (the backtracking limit on a pathological line) is returned again by every
        // later `next()` without moving on, so it ends the layer rather than being skipped.
        for found in pattern.find_iter(line) {
            let Ok(found) = found else { break };
            self.set(found.range(), layer);
        }
    }

    fn style_terminal_line(&mut self, line: &str, in_diff: bool) {
        let trimmed = trim_whitespace(line);
        let whole = 0..line.len();
        if is_match(&PATTERNS.divider, line) {
            self.set(whole, Layer::color(OutputColor::TextMuted));
        } else if is_match(&PATTERNS.heading, line) {
            self.set(whole, Layer::semibold(OutputColor::TextPrimary));
        } else if in_diff && (trimmed.starts_with("@@") || trimmed.starts_with("diff --git ")) {
            self.set(whole, Layer::semibold(OutputColor::Cyan));
            return;
        } else if in_diff && trimmed.starts_with('+') {
            self.set(whole, Layer::color(OutputColor::Success));
            return;
        } else if in_diff && trimmed.starts_with('-') {
            self.set(whole, Layer::color(OutputColor::Danger));
            return;
        } else {
            self.apply(&PATTERNS.prompt, line, Layer::semibold(OutputColor::TextPrimary));
            self.apply(&PATTERNS.bullet, line, Layer::semibold(OutputColor::TextMuted));
            self.apply(&PATTERNS.quote, line, Layer::color(OutputColor::TextMuted));
        }
        self.style_common_tokens(line);
    }

    fn style_common_tokens(&mut self, line: &str) {
        let patterns = &*PATTERNS;
        self.apply(&patterns.path, line, Layer::color(OutputColor::Cyan));
        self.apply(&patterns.file, line, Layer::color(OutputColor::Cyan));
        self.apply(&patterns.url, line, Layer { underline: true, ..Layer::color(OutputColor::Blue) });
        self.apply(&patterns.flag, line, Layer::color(OutputColor::Cyan));
        self.apply(&patterns.error, line, Layer::semibold(OutputColor::Danger));
        self.apply(&patterns.warning, line, Layer::semibold(OutputColor::Yellow));
        self.apply(&patterns.success, line, Layer::semibold(OutputColor::Success));
        self.apply(
            &patterns.inline_code,
            line,
            Layer { code_background: true, ..Layer::semibold(OutputColor::Cyan) },
        );
    }

    fn style_fence_marker(&mut self, line: &str, language: &str) {
        self.set(0..line.len(), Layer::semibold(OutputColor::TextMuted));
        if language.is_empty() {
            return;
        }
        if let Some(start) = line.find(language) {
            self.set(start..start + language.len(), Layer::color(OutputColor::TextPrimary));
        }
    }

    fn style_code_line(&mut self, line: &str, language: &str) {
        let patterns = &*PATTERNS;
        if language == "diff" {
            let trimmed = trim_whitespace(line);
            let color = if trimmed.starts_with('+') {
                OutputColor::Success
            } else if trimmed.starts_with('-') {
                OutputColor::Danger
            } else if trimmed.starts_with("@@") {
                OutputColor::Cyan
            } else {
                return;
            };
            self.set(0..line.len(), Layer::color(color));
            return;
        }

        self.apply(&patterns.type_name, line, Layer::color(OutputColor::SyntaxType));
        if let Some(keywords) = patterns.keywords.get(language).or_else(|| patterns.keywords.get("generic")) {
            let layer =
                Layer { weight: Some(OutputWeight::Bold), ..Layer::color(OutputColor::SyntaxKeyword) };
            self.apply(keywords, line, layer);
        }
        self.apply(&patterns.attribute, line, Layer::color(OutputColor::SyntaxAttribute));
        self.apply(&patterns.function_call, line, Layer::color(OutputColor::SyntaxFunction));
        self.apply(&patterns.number, line, Layer::color(OutputColor::SyntaxNumber));
        self.apply(&patterns.string_literal, line, Layer::color(OutputColor::SyntaxString));
        if language == "json" {
            self.apply(&patterns.json_key, line, Layer::color(OutputColor::SyntaxFunction));
        }
        let comments: &[&Regex] = match language {
            "python" | "ruby" | "shell" | "yaml" | "toml" => &[&patterns.hash_comment],
            "sql" => &[&patterns.sql_comment],
            "json" => &[],
            _ => &[&patterns.slash_comment, &patterns.block_comment],
        };
        for comment in comments {
            self.apply(comment, line, Layer::color(OutputColor::SyntaxComment));
        }
    }
}

fn is_match(pattern: &Regex, line: &str) -> bool {
    pattern.is_match(line).unwrap_or(false)
}

fn coalesce(styles: &[OutputStyle]) -> Vec<OutputRun> {
    let mut runs: Vec<OutputRun> = Vec::new();
    for (index, style) in styles.iter().enumerate() {
        match runs.last_mut() {
            Some(run) if run.style == *style => run.range.end = index + 1,
            _ => runs.push(OutputRun { range: index..index + 1, style: *style }),
        }
    }
    runs
}

struct Patterns {
    divider: Regex,
    heading: Regex,
    prompt: Regex,
    bullet: Regex,
    quote: Regex,
    path: Regex,
    file: Regex,
    url: Regex,
    flag: Regex,
    error: Regex,
    warning: Regex,
    success: Regex,
    inline_code: Regex,
    function_call: Regex,
    /// Capitalized identifiers: types and initializers.
    type_name: Regex,
    /// Swift attributes, decorators and annotations.
    attribute: Regex,
    number: Regex,
    string_literal: Regex,
    json_key: Regex,
    hash_comment: Regex,
    sql_comment: Regex,
    slash_comment: Regex,
    block_comment: Regex,
    keywords: HashMap<&'static str, Regex>,
}

fn expression(pattern: &str) -> Regex {
    // Compile-time constant patterns covered by the tests below.
    Regex::new(pattern).expect("agent output pattern compiles")
}

fn case_insensitive(pattern: &str) -> Regex {
    RegexBuilder::new(pattern).case_insensitive(true).build().expect("agent output pattern compiles")
}

/// The editor's language table is the one source of keyword lists.
fn keywords(language: &str) -> Vec<&'static str> {
    CodeLanguage::named(language)
        .map_or_else(|| vec!["false", "nil", "null", "true"], |language| language.sorted_keywords())
}

static PATTERNS: LazyLock<Patterns> = LazyLock::new(|| Patterns {
    divider: expression(r"^\s*[-─━═_]{4,}\s*$"),
    heading: expression(r"^\s*#{1,6}\s+"),
    prompt: expression(r"^\s*(?:›|❯|\$)\s+"),
    bullet: expression(r"^\s*(?:[•◦▪▸]|[-*+]|\d+[.)])\s+"),
    quote: expression(r"^\s*[>│]\s?"),
    path: expression(
        r"(?<![A-Za-z0-9_])(?:~|\.{1,2}|/)?(?:[A-Za-z0-9_.@+-]+/)+[A-Za-z0-9_.@+~-]+(?::\d+(?::\d+)?)?",
    ),
    file: case_insensitive(
        r"\b[A-Za-z0-9_-]+\.(?:swift|m|mm|c|h|cpp|cc|hpp|js|jsx|ts|tsx|py|rb|rs|go|java|kt|sh|bash|zsh|fish|json|jsonc|yaml|yml|toml|md|markdown|html|css|scss|sql|plist)(?::\d+(?::\d+)?)?\b",
    ),
    url: case_insensitive(r"\bhttps?://[^\s<>()]+"),
    flag: expression(r"(?<![A-Za-z0-9_])--?[A-Za-z][A-Za-z0-9-]*"),
    error: case_insensitive(r"\b(?:error|errors|failed|failure|fatal|denied|panic)\b"),
    warning: case_insensitive(r"\b(?:warning|warnings|warn|waiting|attention)\b"),
    success: case_insensitive(r"\b(?:passed|pass|success|succeeded|complete|completed|done|ready|green)\b"),
    inline_code: expression(r"`[^`\n]+`"),
    function_call: expression(r"\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()"),
    type_name: expression(r"\b[A-Z][A-Za-z0-9_]*\b"),
    attribute: expression(r"(?<![A-Za-z0-9_])@[A-Za-z_][A-Za-z0-9_]*"),
    number: expression(r"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"),
    string_literal: expression(r#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#),
    json_key: expression(r#""(?:\\.|[^"\\])*"(?=\s*:)"#),
    hash_comment: expression(r"#.*$"),
    sql_comment: expression(r"--.*$"),
    slash_comment: expression(r"//.*$"),
    block_comment: expression(r"/\*.*?\*/"),
    keywords: [
        "swift",
        "javascript",
        "typescript",
        "python",
        "shell",
        "ruby",
        "json",
        "yaml",
        "rust",
        "generic",
    ]
    .into_iter()
    .map(|language| {
        let alternatives: Vec<String> =
            keywords(language).iter().map(|word| fancy_regex::escape(word).into_owned()).collect();
        (language, expression(&format!(r"\b(?:{})\b", alternatives.join("|"))))
    })
    .collect(),
});

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_regex_that_gives_up_on_a_line_ends_its_layer_instead_of_looping() {
        // Lookaround runs in the backtracking engine; a limit of 1 makes it fail at once.
        let pattern = RegexBuilder::new(r"(?<=a)(?:a|aa)+b").backtrack_limit(1).build().unwrap();
        let line = "a".repeat(64);
        assert!(pattern.find_iter(&line).next().is_some_and(|found| found.is_err()));
        let mut styles = vec![OutputStyle::default(); line.len()];
        let mut output = Output { styles: &mut styles, offset: 0 };
        output.apply(&pattern, &line, Layer::color(OutputColor::Cyan));
        assert!(styles.iter().all(|style| style.color == OutputColor::TextPrimary));
    }

    fn style_of(text: &str, needle: &str, runs: &[OutputRun]) -> OutputStyle {
        let at = text.find(needle).unwrap_or_else(|| panic!("{needle} not in text"));
        runs.iter().find(|run| run.range.contains(&at)).map(|run| run.style).unwrap()
    }

    fn color_of(text: &str, needle: &str) -> OutputColor {
        style_of(text, needle, &highlight(text)).color
    }

    #[test]
    fn semantic_highlighting_preserves_every_terminal_character() {
        let source = "❯ Run swift test --filter AgentDashboard\n• Updated Sources/Soprano/Views/AgentDashboardViewController.swift:842\nwarning: waiting for input\nerror: build failed\nAll 301 tests passed";
        let runs = highlight(source);
        assert_eq!(runs.first().map(|run| run.range.start), Some(0));
        assert_eq!(runs.last().map(|run| run.range.end), Some(source.len()));
        assert!(runs.windows(2).all(|pair| pair[0].range.end == pair[1].range.start));

        assert_eq!(color_of(source, "❯"), OutputColor::TextPrimary);
        assert_eq!(color_of(source, "•"), OutputColor::TextMuted);
        assert_eq!(
            color_of(source, "Sources/Soprano/Views/AgentDashboardViewController.swift:842"),
            OutputColor::Cyan
        );
        assert_eq!(color_of(source, "--filter"), OutputColor::Cyan);
        assert_eq!(color_of(source, "warning"), OutputColor::Yellow);
        assert_eq!(color_of(source, "error"), OutputColor::Danger);
        assert_eq!(color_of(source, "passed"), OutputColor::Success);
    }

    #[test]
    fn fenced_swift_code_uses_the_syntax_colors_and_bold_ink_keywords() {
        let source =
            "```swift\n@MainActor let count: Int = 42\nprint(\"ready\")\n// keep the exact text\n```";
        let runs = highlight(source);
        let color = |needle| style_of(source, needle, &runs).color;
        assert_eq!(color("swift"), OutputColor::TextPrimary);
        assert_eq!(color("let"), OutputColor::SyntaxKeyword);
        assert_eq!(style_of(source, "let", &runs).weight, OutputWeight::Bold);
        assert_eq!(color("@MainActor"), OutputColor::SyntaxAttribute);
        assert_eq!(color("Int"), OutputColor::SyntaxType);
        assert_eq!(color("42"), OutputColor::SyntaxNumber);
        assert_eq!(color("print"), OutputColor::SyntaxFunction);
        assert_eq!(color("\"ready\""), OutputColor::SyntaxString);
        assert_eq!(color("// keep"), OutputColor::SyntaxComment);
    }

    #[test]
    fn unified_diff_colors_only_the_patch_instead_of_markdown_bullets() {
        let source = "- This is an ordinary agent bullet\n\ndiff --git a/App.swift b/App.swift\n--- a/App.swift\n+++ b/App.swift\n@@ -1,2 +1,2 @@\n-let oldValue = false\n+let newValue = true";
        assert_eq!(color_of(source, "- This"), OutputColor::TextMuted);
        assert_eq!(color_of(source, "-let old"), OutputColor::Danger);
        assert_eq!(color_of(source, "+let new"), OutputColor::Success);
        assert_eq!(color_of(source, "@@"), OutputColor::Cyan);
    }

    #[test]
    fn urls_are_underlined_and_inline_code_sits_on_a_chip() {
        let source = "see https://example.com/x and `cargo test`";
        let runs = highlight(source);
        let url = style_of(source, "https://", &runs);
        assert_eq!((url.color, url.underline), (OutputColor::Blue, true));
        let code = style_of(source, "`cargo", &runs);
        assert!(code.code_background);
        assert_eq!(code.weight, OutputWeight::Semibold);
    }

    #[test]
    fn crlf_lines_and_empty_text_keep_their_bytes() {
        assert!(highlight("").is_empty());
        let source = "# Title\r\nplain";
        let runs = highlight(source);
        assert_eq!(runs.last().map(|run| run.range.end), Some(source.len()));
        assert_eq!(style_of(source, "Title", &runs).weight, OutputWeight::Semibold);
        assert_eq!(style_of(source, "plain", &runs).weight, OutputWeight::Regular);
    }
}
