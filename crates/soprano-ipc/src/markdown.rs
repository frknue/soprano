//! `soprano <file.md> [--new]` / `soprano markdown|md [--new] <file>`: opens local Markdown in the
//! Soprano process that owns the calling terminal.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use crate::caller_cwd;

pub const HELP: &str = "Usage:
  soprano <file.md> [--new]
  soprano --new <file.md>
  soprano markdown [--new] <file>
  soprano md [--new] <file>

Opens a live Markdown reader tab in the calling terminal's pane.
Reuses that reader tab; --new opens a separate pane to the right.";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MarkdownCommandRequest {
    pub path: PathBuf,
    pub opens_new_pane: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MarkdownCommandError {
    HelpRequested,
    InvalidArguments(String),
}

impl MarkdownCommandRequest {
    /// `Ok(None)` when the invocation is not a Markdown command.
    pub fn parse(
        command_line: &[String],
        environment: &HashMap<String, String>,
        current_directory: &Path,
    ) -> Result<Option<Self>, MarkdownCommandError> {
        let Some(first) = command_line.get(1) else { return Ok(None) };
        let is_named_command = first == "markdown" || first == "md";
        let is_direct_command = is_markdown_path(first)
            || (first == "--new" && command_line.get(2).is_some_and(|p| is_markdown_path(p)));
        let tokens = if is_named_command {
            &command_line[2..]
        } else if is_direct_command {
            &command_line[1..]
        } else {
            return Ok(None);
        };

        if is_named_command && (tokens.is_empty() || tokens == ["--help"] || tokens == ["help"]) {
            return Err(MarkdownCommandError::HelpRequested);
        }

        let mut opens_new_pane = false;
        let mut path: Option<&str> = None;
        for token in tokens {
            if token == "--new" {
                opens_new_pane = true;
            } else if token.starts_with('-') {
                return Err(MarkdownCommandError::InvalidArguments(format!("Unknown option: {token}")));
            } else if path.is_none() {
                path = Some(token);
            } else {
                return Err(MarkdownCommandError::InvalidArguments(
                    "Only one Markdown file can be opened at a time.".into(),
                ));
            }
        }

        let Some(path) = path.filter(|p| !p.is_empty()) else {
            return Err(MarkdownCommandError::InvalidArguments("A Markdown file path is required.".into()));
        };
        let expanded = soprano_platform::paths::expand_tilde(path);
        let full = if expanded.is_absolute() {
            expanded
        } else {
            caller_cwd::resolve(environment, current_directory).join(expanded)
        };
        Ok(Some(Self { path: soprano_platform::paths::normalize(&full), opens_new_pane }))
    }
}

fn is_markdown_path(value: &str) -> bool {
    Path::new(value)
        .extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| ext.eq_ignore_ascii_case("md") || ext.eq_ignore_ascii_case("markdown"))
}

/// A regular file the process can read. The app checks again before opening it.
pub fn validate_readable_file(path: &Path) -> bool {
    path.is_file() && std::fs::File::open(path).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(values: &[&str]) -> Result<Option<MarkdownCommandRequest>, MarkdownCommandError> {
        let arguments: Vec<String> = values.iter().map(|v| v.to_string()).collect();
        MarkdownCommandRequest::parse(&arguments, &HashMap::new(), Path::new("/tmp/soprano-project"))
    }

    #[cfg(unix)]
    #[test]
    fn markdown_command_resolves_caller_relative_paths_and_accepts_the_short_alias() {
        let request = parse(&["soprano", "markdown", "--new", "docs/architecture.md"]).unwrap().unwrap();
        assert_eq!(request.path, Path::new("/tmp/soprano-project/docs/architecture.md"));
        assert!(request.opens_new_pane);

        let short = parse(&["soprano", "md", "README.md"]).unwrap().unwrap();
        assert_eq!(short.path, Path::new("/tmp/soprano-project/README.md"));
        assert!(!short.opens_new_pane);

        let direct = parse(&["soprano", "README.md"]).unwrap().unwrap();
        assert_eq!(direct.path, Path::new("/tmp/soprano-project/README.md"));
        assert!(!direct.opens_new_pane);

        let direct_new = parse(&["soprano", "--new", "docs/design.MARKDOWN"]).unwrap().unwrap();
        assert_eq!(direct_new.path, Path::new("/tmp/soprano-project/docs/design.MARKDOWN"));
        assert!(direct_new.opens_new_pane);

        assert_eq!(parse(&["soprano", "not-a-markdown-command"]), Ok(None));
    }

    #[test]
    fn a_bare_named_command_asks_for_help_and_bad_options_are_rejected() {
        assert_eq!(parse(&["soprano", "md"]), Err(MarkdownCommandError::HelpRequested));
        assert_eq!(parse(&["soprano", "markdown", "--help"]), Err(MarkdownCommandError::HelpRequested));
        assert_eq!(
            parse(&["soprano", "md", "--wide", "a.md"]),
            Err(MarkdownCommandError::InvalidArguments("Unknown option: --wide".into()))
        );
        assert_eq!(
            parse(&["soprano", "md", "a.md", "b.md"]),
            Err(MarkdownCommandError::InvalidArguments(
                "Only one Markdown file can be opened at a time.".into()
            ))
        );
        assert_eq!(
            parse(&["soprano", "md", "--new"]),
            Err(MarkdownCommandError::InvalidArguments("A Markdown file path is required.".into()))
        );
    }
}
