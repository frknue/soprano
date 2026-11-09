//! Directory listing and ordering, the name filter, and generated names: the explorer's
//! data rules, free of any UI. Modeled on Orca's right-sidebar explorer.

use std::cmp::Ordering;
use std::ops::Range;
use std::path::Path;

use soprano_git::natural::natural_compare;

/// One directory entry as the explorer shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileExplorerEntry {
    pub name: String,
    /// Directories and symlinks that resolve to directories.
    pub is_directory: bool,
    pub is_symlink: bool,
}

/// Never listed, whatever the dotfile and ignored-file toggles say.
pub const ALWAYS_HIDDEN_NAMES: [&str; 2] = [".git", "node_modules"];

pub fn is_always_hidden(name: &str) -> bool {
    ALWAYS_HIDDEN_NAMES.contains(&name)
}

/// Lists `directory` in display order. Fails when it cannot be read.
pub fn entries(directory: &Path) -> std::io::Result<Vec<FileExplorerEntry>> {
    let mut entries = Vec::new();
    for entry in std::fs::read_dir(directory)? {
        let Ok(entry) = entry else { continue };
        let name = entry.file_name().to_string_lossy().into_owned();
        if is_always_hidden(&name) {
            continue;
        }
        let file_type = entry.file_type().ok();
        let is_symlink = file_type.is_some_and(|t| t.is_symlink());
        let is_directory = if is_symlink {
            std::fs::metadata(entry.path()).is_ok_and(|m| m.is_dir())
        } else {
            file_type.is_some_and(|t| t.is_dir())
        };
        entries.push(FileExplorerEntry { name, is_directory, is_symlink });
    }
    sort(&mut entries);
    Ok(entries)
}

/// Folders first, then Finder's natural order ("file2" before "file10",
/// case-insensitive), with exact code-point order breaking ties.
pub fn compare(lhs: (&str, bool), rhs: (&str, bool)) -> Ordering {
    rhs.1.cmp(&lhs.1).then_with(|| natural_compare(lhs.0, rhs.0)).then_with(|| lhs.0.cmp(rhs.0))
}

pub fn sort(entries: &mut [FileExplorerEntry]) {
    entries.sort_by(|lhs, rhs| compare((&lhs.name, lhs.is_directory), (&rhs.name, rhs.is_directory)));
}

/// Whether any segment of the root-relative path is a dotfile.
pub fn is_dotfile(relative_path: &str) -> bool {
    relative_path
        .split('/')
        .any(|segment| segment.chars().count() > 1 && segment != ".." && segment.starts_with('.'))
}

/// Whether a single name is a dotfile the explorer hides when dotfiles are off.
pub fn is_hidden_name(name: &str) -> bool {
    name.chars().count() > 1 && name.starts_with('.')
}

/// The explorer's "Find files" filter: every whitespace-separated token must
/// appear, case-insensitively, somewhere in the root-relative path.
pub fn filter_tokens(query: &str) -> Vec<String> {
    query.to_lowercase().split_whitespace().map(str::to_owned).collect()
}

pub fn filter_matches(relative_path: &str, tokens: &[String]) -> bool {
    if tokens.is_empty() {
        return true;
    }
    let haystack = relative_path.to_lowercase();
    tokens.iter().all(|token| haystack.contains(token.as_str()))
}

/// "stem copy.ext", then "stem copy 2.ext", "stem copy 3.ext", … — the
/// first that `exists` reports free.
pub fn duplicate_name(name: &str, exists: impl Fn(&str) -> bool) -> String {
    let (stem, extension) = split_name(name);
    let mut candidate = format!("{stem} copy{extension}");
    let mut number = 2;
    while exists(&candidate) {
        candidate = format!("{stem} copy {number}{extension}");
        number += 1;
    }
    candidate
}

/// The part of a name preselected for renaming, as a byte range: everything before the
/// last dot, or the whole name when there is no extension.
pub fn stem_range(name: &str) -> Range<usize> {
    0..split_name(name).0.len()
}

fn split_name(name: &str) -> (&str, &str) {
    match name.rfind('.') {
        Some(dot) if dot > 0 => (&name[..dot], &name[dot..]),
        _ => (name, ""),
    }
}

/// What committing an inline name field does: trims whitespace; an empty name, or the
/// item's own unchanged name (`original`, `None` for a new item), commits nothing.
pub fn committed_name(input: &str, original: Option<&str>) -> Option<String> {
    let name = input.trim();
    if name.is_empty() || original == Some(name) {
        return None;
    }
    Some(name.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn listing_puts_folders_first_in_natural_order_and_hides_git_and_node_modules() {
        let root = tempfile::tempdir().expect("tempdir");
        for folder in ["src", ".git", "node_modules", "Docs"] {
            std::fs::create_dir_all(root.path().join(folder)).expect("mkdir");
        }
        for file in ["file10.txt", "file2.txt", "B.md", "a.md", ".env"] {
            std::fs::write(root.path().join(file), "").expect("write");
        }

        let names: Vec<String> = entries(root.path()).expect("list").into_iter().map(|e| e.name).collect();

        assert_eq!(names, ["Docs", "src", ".env", "a.md", "B.md", "file2.txt", "file10.txt"]);
    }

    #[test]
    fn dotfile_detection_looks_at_every_segment() {
        assert!(is_dotfile(".github/workflows/ci.yml"));
        assert!(is_dotfile("config/.env"));
        assert!(!is_dotfile("src/main.swift"));
        assert!(!is_dotfile("../outside"));
    }

    #[test]
    fn every_filter_token_must_appear_in_the_path_ignoring_case() {
        let tokens = filter_tokens("  explorer VIEW ");

        assert_eq!(tokens, ["explorer", "view"]);
        assert!(filter_matches("Sources/Views/FileExplorerView.swift", &tokens));
        assert!(!filter_matches("Sources/Views/SidebarView.swift", &tokens));
        assert!(filter_matches("anything", &[]));
    }

    #[test]
    fn duplicates_count_up_past_existing_copies() {
        let taken = ["notes copy.txt", "notes copy 2.txt"];

        assert_eq!(duplicate_name("notes.txt", |n| taken.contains(&n)), "notes copy 3.txt");
        assert_eq!(duplicate_name("Makefile", |_| false), "Makefile copy");
        assert_eq!(duplicate_name(".env", |_| false), ".env copy");
    }

    #[test]
    fn renaming_preselects_the_name_before_the_last_dot() {
        assert_eq!(stem_range("archive.tar.gz"), 0..11);
        assert_eq!(stem_range("README"), 0..6);
        assert_eq!(stem_range(".gitignore"), 0..10);
    }

    #[test]
    fn an_inline_name_commits_only_when_it_is_new_and_not_blank() {
        assert_eq!(committed_name("  notes.md \n", None).as_deref(), Some("notes.md"));
        assert_eq!(committed_name("   ", None), None);
        assert_eq!(committed_name("same.txt", Some("same.txt")), None);
        assert_eq!(committed_name("other.txt", Some("same.txt")).as_deref(), Some("other.txt"));
    }
}
