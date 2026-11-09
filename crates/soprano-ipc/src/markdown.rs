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
        let expanded = expand_tilde(path);
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

/// `NSString.expandingTildeInPath`: `~` and `~/…` name the caller's home, `~user` and `~user/…`
/// that user's home; an unknown user leaves the path as written.
pub fn expand_tilde(path: &str) -> PathBuf {
    let Some(rest) = path.strip_prefix('~') else { return PathBuf::from(path) };
    let (user, tail) = match rest.find(['/', std::path::MAIN_SEPARATOR]) {
        Some(index) => (&rest[..index], &rest[index + 1..]),
        None => (rest, ""),
    };
    let home = if user.is_empty() { Some(soprano_platform::paths::home_dir()) } else { home_of_user(user) };
    match home {
        Some(home) if tail.is_empty() => home,
        Some(home) => home.join(tail),
        None => PathBuf::from(path),
    }
}

#[cfg(unix)]
fn home_of_user(user: &str) -> Option<PathBuf> {
    use std::ffi::{CStr, CString};
    use std::os::unix::ffi::OsStrExt;

    let name = CString::new(user).ok()?;
    let mut buffer = vec![0 as libc::c_char; 16 * 1024];
    // SAFETY: `passwd` is plain old data; all-zero is a valid value.
    let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: every pointer is valid for the call; `buffer` outlives the reads of `entry` below.
    let status = unsafe {
        libc::getpwnam_r(name.as_ptr(), &mut entry, buffer.as_mut_ptr(), buffer.len(), &mut result)
    };
    if status != 0 || result.is_null() || entry.pw_dir.is_null() {
        return None;
    }
    // SAFETY: `pw_dir` points to a NUL-terminated string inside `buffer`.
    let dir = unsafe { CStr::from_ptr(entry.pw_dir) };
    Some(PathBuf::from(std::ffi::OsStr::from_bytes(dir.to_bytes())))
}

/// Windows has no `~user` convention; such paths stay as written.
#[cfg(not(unix))]
fn home_of_user(_user: &str) -> Option<PathBuf> {
    None
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

    #[cfg(unix)]
    #[test]
    fn a_named_users_home_is_expanded_like_nsstring_does() {
        let user = std::env::var("USER").expect("USER");
        let home = home_of_user(&user).expect("home of the current user");
        assert_eq!(expand_tilde(&format!("~{user}/notes.md")), home.join("notes.md"));
        assert_eq!(expand_tilde(&format!("~{user}")), home);
        assert_eq!(expand_tilde("~/a.md"), soprano_platform::paths::home_dir().join("a.md"));
        assert_eq!(expand_tilde("~no-such-user-soprano/a.md"), PathBuf::from("~no-such-user-soprano/a.md"));
        assert_eq!(expand_tilde("docs/a.md"), PathBuf::from("docs/a.md"));
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
