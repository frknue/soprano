//! File URLs as the Swift app stored them in tab `url`s: `URL.standardizedFileURL.absoluteString`
//! (`file:///tmp/project/README.md`, percent-encoded).
//!
//! Foundation escapes every byte outside `CharacterSet.urlPathAllowed` (so `[ ] ^ |` too) and,
//! on macOS, writes the path decomposed (NFD). Unix builds write the same so workspaces stay
//! readable by older Swift builds; Windows uses the `url` crate (`file:///C:/…`). Because URL
//! strings from different writers can differ for one file, tabs are compared by
//! [`comparable_path`], never by URL string.

use std::path::{Path, PathBuf};

use soprano_platform::paths;
use unicode_normalization::UnicodeNormalization;

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

/// The `file://` URL string for an absolute `path`, as Foundation writes it.
#[cfg(unix)]
pub fn file_url_string(path: &Path) -> String {
    use std::os::unix::ffi::OsStrExt;

    let bytes: Vec<u8> = match path.to_str() {
        // macOS file system paths are decomposed, and so are the URLs Foundation builds.
        Some(text) if cfg!(target_os = "macos") => text.nfd().collect::<String>().into_bytes(),
        Some(text) => text.as_bytes().to_vec(),
        None => path.as_os_str().as_bytes().to_vec(),
    };
    let mut url = String::with_capacity(bytes.len() + 7);
    url.push_str("file://");
    for byte in bytes {
        if byte.is_ascii_alphanumeric() || b"-._~!$&'()*+,;=:@/".contains(&byte) {
            url.push(byte as char);
        } else {
            url.push_str(&format!("%{byte:02X}"));
        }
    }
    url
}

/// The `file://` URL string for an absolute `path`.
#[cfg(not(unix))]
pub fn file_url_string(path: &Path) -> String {
    url::Url::from_file_path(path)
        .map(|url| url.to_string())
        .unwrap_or_else(|()| format!("file://{}", path.to_string_lossy()))
}

/// `path` standardized and in composed Unicode (NFC): the form two references to one file are
/// compared in, whichever program wrote them.
pub fn comparable_path(path: &Path) -> PathBuf {
    let standardized = standardized_path(path);
    match standardized.to_str() {
        Some(text) => PathBuf::from(text.nfc().collect::<String>()),
        None => standardized,
    }
}

/// The [`comparable_path`] of the file a `file://` URL string names.
pub fn comparable_path_from_url(value: &str) -> Option<PathBuf> {
    path_from_file_url(value).map(|path| comparable_path(&path))
}

/// Whether two strings are equal once both are composed (NFC).
pub(crate) fn same_text(lhs: &str, rhs: &str) -> bool {
    lhs == rhs || lhs.nfc().eq(rhs.nfc())
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
        assert_eq!(
            file_url_string(Path::new("/tmp/app/[id]/a^b|c.tsx")),
            "file:///tmp/app/%5Bid%5D/a%5Eb%7Cc.tsx"
        );
        assert_eq!(path_from_file_url("file:///tmp/a%20b.md"), Some(PathBuf::from("/tmp/a b.md")));
        assert_eq!(path_from_file_url("https://example.com"), None);
        assert_eq!(standardized_path(Path::new("/tmp/x/../y/./z.md")), PathBuf::from("/tmp/y/z.md"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_urls_are_decomposed_like_foundations() {
        assert_eq!(
            file_url_string(Path::new("/tmp/Pr\u{e4}sentation.md")),
            "file:///tmp/Pra%CC%88sentation.md"
        );
    }

    #[test]
    fn a_swift_saved_decomposed_url_names_the_same_file_as_a_composed_path() {
        let swift = "file:///tmp/Pra%CC%88sentation%20%5B1%5D.md";
        let composed = Path::new("/tmp/Pr\u{e4}sentation [1].md");
        assert_eq!(comparable_path_from_url(swift), Some(comparable_path(composed)));
        assert_eq!(comparable_path_from_url(&file_url_string(composed)), Some(comparable_path(composed)));
        assert!(same_text("Pra\u{308}sentation.md", "Pr\u{e4}sentation.md"));
    }

    #[test]
    fn the_last_segment_skips_trailing_separators() {
        assert_eq!(last_segment("/work/repo/"), Some("repo"));
        assert_eq!(last_segment("/"), None);
        assert_eq!(last_segment(""), None);
    }
}
