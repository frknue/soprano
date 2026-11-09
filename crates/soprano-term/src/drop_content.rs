//! What a drop onto a terminal types (`TerminalDropContent.swift`): URLs and file paths
//! shell-escaped so the command line reads them as one word each, plain text as it is.

use std::path::PathBuf;

/// The representations a drop carries, in the order they are preferred.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DropPayload {
    /// A dragged URL (a link from a browser).
    pub url: Option<String>,
    /// Dragged files and folders.
    pub file_paths: Vec<PathBuf>,
    /// Dragged plain text.
    pub text: Option<String>,
}

impl DropPayload {
    pub fn files(paths: impl IntoIterator<Item = PathBuf>) -> Self {
        Self { file_paths: paths.into_iter().collect(), ..Self::default() }
    }

    pub fn text(text: impl Into<String>) -> Self {
        Self { text: Some(text.into()), ..Self::default() }
    }
}

/// The text a drop inserts, or `None` when it carries nothing a terminal takes.
pub fn text_from(payload: &DropPayload) -> Option<String> {
    if let Some(url) = &payload.url {
        return Some(shell_escape(url));
    }
    if !payload.file_paths.is_empty() {
        return Some(
            payload
                .file_paths
                .iter()
                .map(|p| shell_escape(&p.to_string_lossy()))
                .collect::<Vec<_>>()
                .join(" "),
        );
    }
    payload.text.clone()
}

/// Backslash-escapes every character that would change how a shell splits or expands a word.
pub fn shell_escape(value: &str) -> String {
    const SPECIAL: &str = "\\ ()[]{}<>\"'`!#$&;|*?\t";
    let mut escaped = String::with_capacity(value.len());
    for c in value.chars() {
        if SPECIAL.contains(c) {
            escaped.push('\\');
        }
        escaped.push(c);
    }
    escaped
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_escapes_characters_that_would_change_a_command_line() {
        assert_eq!(
            shell_escape("/tmp/Screen Shot [draft] #1.png"),
            "/tmp/Screen\\ Shot\\ \\[draft\\]\\ \\#1.png"
        );
    }

    #[test]
    fn a_backslash_is_escaped_once() {
        assert_eq!(shell_escape("a\\b"), "a\\\\b");
    }

    #[test]
    fn dropped_file_urls_become_escaped_space_separated_paths() {
        let payload = DropPayload::files([
            PathBuf::from("/tmp/Screen Shot 1.png"),
            PathBuf::from("/tmp/Screen Shot 2.png"),
        ]);
        assert_eq!(
            text_from(&payload).as_deref(),
            Some("/tmp/Screen\\ Shot\\ 1.png /tmp/Screen\\ Shot\\ 2.png")
        );
    }

    #[test]
    fn dropped_plain_text_is_inserted_without_shell_escaping() {
        assert_eq!(
            text_from(&DropPayload::text("git status && git diff")).as_deref(),
            Some("git status && git diff")
        );
    }

    #[test]
    fn a_dropped_url_wins_over_files_and_text_and_is_escaped() {
        let payload = DropPayload {
            url: Some("https://example.com/a?b=1&c=2".into()),
            file_paths: vec![PathBuf::from("/tmp/x")],
            text: Some("text".into()),
        };
        assert_eq!(text_from(&payload).as_deref(), Some("https://example.com/a\\?b=1\\&c=2"));
        assert_eq!(text_from(&DropPayload::default()), None);
    }
}
