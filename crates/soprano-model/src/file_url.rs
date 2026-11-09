//! File URLs as the Swift app stored them in tab `url`s: `URL.standardizedFileURL.absoluteString`
//! (`file:///tmp/project/README.md`, percent-encoded). Built with the `url` crate so Windows
//! paths (`file:///C:/…`) work too.

use std::path::{Path, PathBuf};

use soprano_platform::paths;

/// `path` made absolute against the process's working directory, with `.` and `..` removed —
/// what `URL(fileURLWithPath:).standardizedFileURL.path` gives.
pub fn standardized_path(path: &Path) -> PathBuf {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().map(|cwd| cwd.join(path)).unwrap_or_else(|_| path.to_path_buf())
    };
    paths::normalize(&absolute)
}

/// The `file://` URL string for an absolute `path`.
pub fn file_url_string(path: &Path) -> String {
    url::Url::from_file_path(path)
        .map(|url| url.to_string())
        .unwrap_or_else(|()| format!("file://{}", path.to_string_lossy()))
}

/// The path a `file://` URL string names; `None` for other schemes and unparsable strings.
pub fn path_from_file_url(value: &str) -> Option<PathBuf> {
    let url = url::Url::parse(value).ok()?;
    if url.scheme() != "file" {
        return None;
    }
    url.to_file_path().ok()
}

/// The directory holding `path` as a string (`/` for a file at the root).
pub(crate) fn parent_directory(path: &Path) -> String {
    path.parent().unwrap_or(path).to_string_lossy().into_owned()
}

/// The last path component (`README.md`), or the whole path when there is none.
pub(crate) fn last_component(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.to_string_lossy().into_owned())
}

/// The last non-empty component of a path string (`repo` for `/work/repo/`), split on the
/// platform's separators (`/`, and `\\` on Windows); `None` for a root or empty path.
pub(crate) fn last_segment(path: &str) -> Option<&str> {
    path.split(std::path::is_separator).rfind(|part| !part.is_empty())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn file_urls_match_what_foundation_wrote() {
        assert_eq!(file_url_string(Path::new("/tmp/project/README.md")), "file:///tmp/project/README.md");
        assert_eq!(file_url_string(Path::new("/tmp/a b.md")), "file:///tmp/a%20b.md");
        assert_eq!(path_from_file_url("file:///tmp/a%20b.md"), Some(PathBuf::from("/tmp/a b.md")));
        assert_eq!(path_from_file_url("https://example.com"), None);
        assert_eq!(standardized_path(Path::new("/tmp/x/../y/./z.md")), PathBuf::from("/tmp/y/z.md"));
    }

    #[test]
    fn the_last_segment_skips_trailing_separators() {
        assert_eq!(last_segment("/work/repo/"), Some("repo"));
        assert_eq!(last_segment("/"), None);
        assert_eq!(last_segment(""), None);
    }
}
