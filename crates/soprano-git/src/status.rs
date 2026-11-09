//! Git decorations for the file explorer: per-path status letters, folder rollup, and
//! ignored paths.

use std::collections::{HashMap, HashSet};

/// One path's git status as the explorer and Source Control list show it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum GitFileStatus {
    Modified,
    Added,
    Deleted,
    Renamed,
    Untracked,
    Copied,
}

impl GitFileStatus {
    pub fn letter(self) -> &'static str {
        match self {
            Self::Modified => "M",
            Self::Added => "A",
            Self::Deleted => "D",
            Self::Renamed => "R",
            Self::Untracked => "U",
            Self::Copied => "C",
        }
    }

    /// Which status a path (or folder) shows when several apply.
    pub fn priority(self) -> u8 {
        match self {
            Self::Deleted => 5,
            Self::Modified => 4,
            Self::Added | Self::Untracked => 3,
            Self::Renamed => 2,
            Self::Copied => 1,
        }
    }

    /// Deleted files are not on disk, so they never color their folders.
    pub fn propagates_to_folders(self) -> bool {
        self != Self::Deleted
    }

    /// One side of a porcelain `XY` field; anything unknown counts as modified.
    pub fn from_status_character(character: char) -> Self {
        match character {
            'A' => Self::Added,
            'D' => Self::Deleted,
            'R' => Self::Renamed,
            'C' => Self::Copied,
            _ => Self::Modified,
        }
    }

    /// `current` unless `candidate` strictly outranks it, so the first of two
    /// equally ranked statuses wins.
    pub fn dominant(current: Option<Self>, candidate: Self) -> Self {
        match current {
            Some(current) if candidate.priority() <= current.priority() => current,
            _ => candidate,
        }
    }
}

/// Git decorations for one repository, keyed by root-relative path.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct GitStatusSnapshot {
    pub file_statuses: HashMap<String, GitFileStatus>,
    pub folder_statuses: HashMap<String, GitFileStatus>,
    pub ignored_paths: HashSet<String>,
}

impl GitStatusSnapshot {
    pub fn empty() -> Self {
        Self::default()
    }

    pub fn new(entries: &[(String, GitFileStatus)], ignored_paths: HashSet<String>) -> Self {
        let mut snapshot = Self { ignored_paths, ..Self::default() };
        for (path, status) in entries {
            let current = snapshot.file_statuses.get(path).copied();
            snapshot.file_statuses.insert(path.clone(), GitFileStatus::dominant(current, *status));
            if !status.propagates_to_folders() {
                continue;
            }
            let mut folder = path.as_str();
            while let Some(slash) = folder.rfind('/') {
                folder = &folder[..slash];
                let current = snapshot.folder_statuses.get(folder).copied();
                snapshot.folder_statuses.insert(folder.to_owned(), GitFileStatus::dominant(current, *status));
            }
        }
        snapshot
    }

    pub fn status(&self, relative_path: &str, is_directory: bool) -> Option<GitFileStatus> {
        if is_directory {
            self.folder_statuses.get(relative_path).or_else(|| self.file_statuses.get(relative_path)).copied()
        } else {
            self.file_statuses.get(relative_path).copied()
        }
    }

    /// A path is ignored when it, or any folder above it, is.
    pub fn is_ignored(&self, relative_path: &str) -> bool {
        if self.ignored_paths.is_empty() {
            return false;
        }
        let mut candidate = relative_path;
        loop {
            if self.ignored_paths.contains(candidate) {
                return true;
            }
            match candidate.rfind('/') {
                Some(slash) => candidate = &candidate[..slash],
                None => return false,
            }
        }
    }

    /// Parses `git status --porcelain=v2 -z` output into one entry per
    /// staged and unstaged change. Unmerged paths count as modified.
    pub fn parse_status(data: &[u8]) -> Vec<(String, GitFileStatus)> {
        let mut records = nul_records(data).into_iter();
        let mut entries = Vec::new();
        let append = |entries: &mut Vec<(String, GitFileStatus)>, xy: &str, path: &str| {
            for character in xy.chars().filter(|c| *c != '.') {
                entries.push((path.to_owned(), GitFileStatus::from_status_character(character)));
            }
        };
        while let Some(record) = records.next() {
            match record.chars().next() {
                Some('1') => {
                    let fields: Vec<&str> = record.splitn(9, ' ').collect();
                    if fields.len() == 9 {
                        append(&mut entries, fields[1], fields[8]);
                    }
                }
                Some('2') => {
                    let fields: Vec<&str> = record.splitn(10, ' ').collect();
                    // The rename source follows as its own NUL-terminated record.
                    records.next();
                    if fields.len() == 10 {
                        append(&mut entries, fields[1], fields[9]);
                    }
                }
                Some('u') => {
                    let fields: Vec<&str> = record.splitn(11, ' ').collect();
                    if fields.len() == 11 {
                        entries.push((fields[10].to_owned(), GitFileStatus::Modified));
                    }
                }
                Some('?') => {
                    entries.push((record.get(2..).unwrap_or("").to_owned(), GitFileStatus::Untracked))
                }
                _ => {}
            }
        }
        entries
    }

    /// Parses `git ls-files -z --others --ignored --exclude-standard --directory`:
    /// ignored files, and ignored folders as one entry with a trailing slash.
    pub fn parse_ignored(data: &[u8]) -> HashSet<String> {
        nul_records(data)
            .into_iter()
            .map(|mut path| {
                if path.ends_with('/') {
                    path.pop();
                }
                path
            })
            .collect()
    }
}

/// NUL-separated records, empty ones dropped, decoded leniently as UTF-8.
pub(crate) fn nul_records(data: &[u8]) -> Vec<String> {
    data.split(|byte| *byte == 0)
        .filter(|record| !record.is_empty())
        .map(|record| String::from_utf8_lossy(record).into_owned())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map(pairs: &[(&str, GitFileStatus)]) -> HashMap<String, GitFileStatus> {
        pairs.iter().map(|(p, s)| ((*p).to_owned(), *s)).collect()
    }

    #[test]
    fn porcelain_status_maps_every_record_kind_to_its_path() {
        let records = [
            "1 .M N... 100644 100644 100644 abc abc Sources/App/main.swift",
            "1 A. N... 000000 100644 100644 000 abc docs/new guide.md",
            "2 R. N... 100644 100644 100644 abc abc R100 Sources/Renamed.swift",
            "Sources/Old.swift",
            "u UU N... 100644 100644 100644 100644 a b c conflicted.txt",
            "? notes/todo.txt",
        ];
        let data = records.join("\0") + "\0";

        let snapshot =
            GitStatusSnapshot::new(&GitStatusSnapshot::parse_status(data.as_bytes()), HashSet::new());

        assert_eq!(
            snapshot.file_statuses,
            map(&[
                ("Sources/App/main.swift", GitFileStatus::Modified),
                ("docs/new guide.md", GitFileStatus::Added),
                ("Sources/Renamed.swift", GitFileStatus::Renamed),
                ("conflicted.txt", GitFileStatus::Modified),
                ("notes/todo.txt", GitFileStatus::Untracked),
            ])
        );
    }

    #[test]
    fn folders_show_their_most_important_change_but_never_a_deletion() {
        let entries: Vec<(String, GitFileStatus)> = [
            ("src/a/added.swift", GitFileStatus::Added),
            ("src/a/modified.swift", GitFileStatus::Modified),
            ("src/b/gone.swift", GitFileStatus::Deleted),
            ("src/b/new.swift", GitFileStatus::Untracked),
            ("only-deleted/x.swift", GitFileStatus::Deleted),
        ]
        .iter()
        .map(|(p, s)| ((*p).to_owned(), *s))
        .collect();
        let snapshot = GitStatusSnapshot::new(&entries, HashSet::new());

        assert_eq!(snapshot.status("src", true), Some(GitFileStatus::Modified));
        assert_eq!(snapshot.status("src/a", true), Some(GitFileStatus::Modified));
        assert_eq!(snapshot.status("src/b", true), Some(GitFileStatus::Untracked));
        assert_eq!(snapshot.status("only-deleted", true), None);
    }

    #[test]
    fn a_file_staged_and_modified_again_shows_the_higher_ranked_status() {
        let snapshot = GitStatusSnapshot::new(
            &GitStatusSnapshot::parse_status(b"1 AM N... 000000 100644 100644 000 abc new.swift\0"),
            HashSet::new(),
        );

        assert_eq!(snapshot.file_statuses.get("new.swift"), Some(&GitFileStatus::Modified));
    }

    #[test]
    fn ignored_folders_cover_everything_beneath_them() {
        let ignored = GitStatusSnapshot::parse_ignored(b".build/\0debug.log\0");
        let snapshot = GitStatusSnapshot::new(&[], ignored);

        assert!(snapshot.is_ignored(".build"));
        assert!(snapshot.is_ignored(".build/debug/Soprano"));
        assert!(snapshot.is_ignored("debug.log"));
        assert!(!snapshot.is_ignored(".buildozer"));
        assert!(!snapshot.is_ignored("Sources/debug.log"));
    }
}
