//! Reads explorer decorations, Source Control changes, and diffs from git.
//! Every call blocks on a child process, so callers run it off the UI thread.

use std::collections::HashSet;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::LazyLock;

use crate::changes::{GitChangeArea, GitChangeList, GitFileDiff};
use crate::status::{GitStatusSnapshot, nul_records};

/// Larger diffs are not shown, like files over the editor's size limit.
pub const MAXIMUM_DIFF_BYTES: usize = 8 * 1024 * 1024;
/// Untracked files get their lines counted for the Source Control list,
/// but only this many, and only files up to [`MAXIMUM_COUNTED_FILE_BYTES`].
pub const MAXIMUM_COUNTED_UNTRACKED_FILES: usize = 500;
pub const MAXIMUM_COUNTED_FILE_BYTES: u64 = 2 * 1024 * 1024;

/// The git executable to run, or `None` when none is installed.
///
/// On macOS `/usr/bin/git` is only a shim: without developer tools it pops an install
/// dialog instead of running, so it is used only when the tools it forwards to exist.
/// Elsewhere the first `git` on `PATH` is used.
pub fn executable() -> Option<&'static Path> {
    EXECUTABLE.as_deref()
}

static EXECUTABLE: LazyLock<Option<PathBuf>> = LazyLock::new(find_executable);

#[cfg(target_os = "macos")]
fn find_executable() -> Option<PathBuf> {
    for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] {
        if is_executable(Path::new(path)) {
            return Some(PathBuf::from(path));
        }
    }
    let developer_tool_gits = [
        "/Library/Developer/CommandLineTools/usr/bin/git",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
    ];
    if developer_tool_gits.iter().any(|path| is_executable(Path::new(path))) {
        return Some(PathBuf::from("/usr/bin/git"));
    }
    None
}

#[cfg(not(target_os = "macos"))]
fn find_executable() -> Option<PathBuf> {
    let name = if cfg!(windows) { "git.exe" } else { "git" };
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).map(|dir| dir.join(name)).find(|candidate| is_executable(candidate))
}

fn is_executable(path: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else { return false };
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        metadata.is_file()
    }
}

/// Decorations for the working tree at `root`: per-path status from
/// `git status` and ignored paths from `git ls-files`.
pub fn snapshot(root: &Path) -> GitStatusSnapshot {
    let Some(status) = run(&["status", "--porcelain=v2", "-z", "--untracked-files=all"], root) else {
        return GitStatusSnapshot::empty();
    };
    GitStatusSnapshot::new(&GitStatusSnapshot::parse_status(&status), ignored_paths(root))
}

/// Ignored files, and ignored folders as one entry each.
pub fn ignored_paths(root: &Path) -> HashSet<String> {
    let data = run(&["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"], root)
        .unwrap_or_default();
    GitStatusSnapshot::parse_ignored(&data)
}

/// The Source Control list for the working tree at `root`, with line
/// counts, or `None` when git cannot read it.
pub fn changes(root: &Path) -> Option<GitChangeList> {
    let status = run(&["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"], root)?;
    let mut list = GitChangeList::parse_status(&status);
    for area in [GitChangeArea::Unstaged, GitChangeArea::Staged] {
        if !list.changes.iter().any(|change| change.area == area) {
            continue;
        }
        let mut arguments = vec!["diff", "-z", "--numstat", "--no-renames", "--no-ext-diff", "--no-textconv"];
        if area == GitChangeArea::Staged {
            arguments.push("--cached");
        }
        if let Some(data) = run(&arguments, root) {
            list.apply_line_counts(&GitChangeList::parse_numstat(&data), area);
        }
    }
    let untracked = list.changes.iter_mut().filter(|change| change.area == GitChangeArea::Untracked);
    for change in untracked.take(MAXIMUM_COUNTED_UNTRACKED_FILES) {
        let path = root.join(&change.path);
        let Ok(metadata) = std::fs::metadata(&path) else { continue };
        if !metadata.is_file() || metadata.len() > MAXIMUM_COUNTED_FILE_BYTES {
            continue;
        }
        let Some(lines) = std::fs::read(&path).ok().and_then(|data| GitChangeList::line_count(&data)) else {
            continue;
        };
        change.lines_added = Some(lines);
        change.lines_deleted = Some(0);
    }
    Some(list)
}

/// The whole-file diff of `relative_path`: HEAD against the index when
/// `staged`, else the index against the working tree, where an untracked
/// file is all additions.
pub fn diff(root: &Path, relative_path: &str, staged: bool) -> GitFileDiff {
    if executable().is_none() {
        return GitFileDiff::Unavailable;
    }
    let unified = format!("--unified={}", i32::MAX);
    // Every line as context, so the view shows the whole file.
    let options = ["--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", unified.as_str()];
    // Pathspec magic would read `[id].tsx` as a pattern.
    let mut arguments = vec!["--literal-pathspecs", "diff"];
    if staged {
        arguments.push("--cached");
    }
    arguments.extend(options);
    arguments.extend(["--", relative_path]);
    match execute(&arguments, root, &[0], MAXIMUM_DIFF_BYTES) {
        Output::Failed => return GitFileDiff::Unavailable,
        Output::TooLarge => return GitFileDiff::TooLarge,
        Output::Data(data) => {
            if staged || !data.is_empty() {
                return GitFileDiff::parse(&data);
            }
        }
    }
    // An untracked file has no index entry for `git diff` to compare.
    let listed = run(
        &["--literal-pathspecs", "ls-files", "-z", "--others", "--exclude-standard", "--", relative_path],
        root,
    );
    if listed.is_none_or(|listed| listed.is_empty()) {
        return GitFileDiff::NoChanges;
    }
    let mut arguments = vec!["diff", "--no-index"];
    arguments.extend(options);
    arguments.extend(["--", "/dev/null", relative_path]);
    // `--no-index` exits with 1 when the files differ.
    match execute(&arguments, root, &[0, 1], MAXIMUM_DIFF_BYTES) {
        Output::Failed => GitFileDiff::Unavailable,
        Output::TooLarge => GitFileDiff::TooLarge,
        Output::Data(data) => GitFileDiff::parse(&data),
    }
}

/// Root-relative paths of every tracked or untracked, non-ignored file,
/// or `None` when `root` is not a git working tree.
pub fn list_files(root: &Path) -> Option<Vec<String>> {
    let data = run(&["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--deduplicate"], root)?;
    Some(nul_records(&data))
}

/// Runs git in `directory`, returning stdout on a zero exit status.
fn run(arguments: &[&str], directory: &Path) -> Option<Vec<u8>> {
    match execute(arguments, directory, &[0], usize::MAX) {
        Output::Data(data) => Some(data),
        _ => None,
    }
}

enum Output {
    Data(Vec<u8>),
    Failed,
    TooLarge,
}

/// Runs git in `directory`. Output beyond `byte_limit` stops git rather
/// than being buffered.
fn execute(arguments: &[&str], directory: &Path, accepted_statuses: &[i32], byte_limit: usize) -> Output {
    let Some(executable) = executable() else { return Output::Failed };
    let mut command = Command::new(executable);
    // Reading must never take the index lock or rewrite the index: either
    // would race the user's own git commands and wake the file watcher.
    command
        .arg("--no-optional-locks")
        .arg("-C")
        .arg(directory)
        .args(arguments)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let Ok(mut child) = command.spawn() else { return Output::Failed };
    let Some(mut stdout) = child.stdout.take() else {
        let _ = child.kill();
        let _ = child.wait();
        return Output::Failed;
    };
    let mut data = Vec::new();
    let mut chunk = [0u8; 64 * 1024];
    loop {
        match stdout.read(&mut chunk) {
            Ok(0) => break,
            Ok(count) => {
                data.extend_from_slice(&chunk[..count]);
                if data.len() > byte_limit {
                    let _ = child.kill();
                    drop(stdout);
                    let _ = child.wait();
                    return Output::TooLarge;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => break,
        }
    }
    match child.wait() {
        Ok(status) if status.code().is_some_and(|code| accepted_statuses.contains(&code)) => {
            Output::Data(data)
        }
        _ => Output::Failed,
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::changes::{GitDiffLine, GitDiffLineKind};
    use crate::status::GitFileStatus;

    pub(crate) fn git(arguments: &[&str], directory: &Path) {
        let executable = executable().expect("git is installed");
        let status = Command::new(executable)
            .arg("-C")
            .arg(directory)
            .args(arguments)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .expect("git runs");
        assert!(status.success(), "git {arguments:?} failed");
    }

    pub(crate) fn commit(directory: &Path) {
        git(
            &[
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "core.hooksPath=/dev/null",
                "commit",
                "-qm",
                "init",
            ],
            directory,
        );
    }

    fn write(text: &str, path: &str, root: &Path) {
        std::fs::write(root.join(path), text).expect("write");
    }

    #[test]
    fn reading_a_real_repository_lists_changes_with_counts_and_whole_file_diffs() {
        if executable().is_none() {
            return;
        }
        let temp = tempfile::tempdir().expect("tempdir");
        let root = temp.path();
        git(&["init", "-q"], root);
        write("one\ntwo\nthree\n", "app.swift", root);
        write("x\n", "[id].tsx", root);
        git(&["add", "."], root);
        commit(root);
        write("one\n2\nthree\n", "app.swift", root);
        git(&["add", "app.swift"], root);
        write("one\n2\nthree\nfour\n", "app.swift", root);
        write("y\n", "[id].tsx", root);
        write("new\nfile", "fresh.txt", root);

        let list = changes(root).expect("changes");

        let rows: Vec<String> = list
            .changes
            .iter()
            .map(|c| {
                let count = |n: Option<usize>| n.map_or("-1".to_owned(), |n| n.to_string());
                format!("{} {} +{} -{}", c.area.title(), c.path, count(c.lines_added), count(c.lines_deleted))
            })
            .collect();
        assert_eq!(
            rows,
            [
                "Changes [id].tsx +1 -1",
                "Changes app.swift +1 -0",
                "Staged Changes app.swift +1 -1",
                "Untracked Files fresh.txt +2 -0",
            ]
        );

        use GitDiffLineKind::{Added, Context, Removed};
        assert_eq!(
            diff(root, "app.swift", true),
            GitFileDiff::Text(vec![
                GitDiffLine::new(Context, Some(1), Some(1), "one"),
                GitDiffLine::new(Removed, Some(2), None, "two"),
                GitDiffLine::new(Added, None, Some(2), "2"),
                GitDiffLine::new(Context, Some(3), Some(3), "three"),
            ])
        );
        let GitFileDiff::Text(unstaged) = diff(root, "app.swift", false) else {
            panic!("Expected the working-tree diff");
        };
        assert_eq!(unstaged.iter().map(|l| l.kind).collect::<Vec<_>>(), [Context, Context, Context, Added]);
        assert_eq!(unstaged.last().map(|l| l.text.as_str()), Some("four"));

        assert_eq!(
            diff(root, "[id].tsx", false),
            GitFileDiff::Text(vec![
                GitDiffLine::new(Removed, Some(1), None, "x"),
                GitDiffLine::new(Added, None, Some(1), "y"),
            ])
        );
        assert_eq!(
            diff(root, "fresh.txt", false),
            GitFileDiff::Text(vec![
                GitDiffLine::new(Added, None, Some(1), "new"),
                GitDiffLine::new(Added, None, Some(2), "file"),
            ])
        );
        assert_eq!(diff(root, "[id].tsx", true), GitFileDiff::NoChanges);
    }

    #[test]
    fn diffs_over_the_byte_limit_are_too_large() {
        if executable().is_none() {
            return;
        }
        let temp = tempfile::tempdir().expect("tempdir");
        let root = temp.path();
        git(&["init", "-q"], root);
        let line = "x".repeat(1023) + "\n";
        write(&line.repeat(MAXIMUM_DIFF_BYTES / 1024 + 16), "big.txt", root);

        assert_eq!(diff(root, "big.txt", false), GitFileDiff::TooLarge);
    }

    #[test]
    fn reading_a_real_repository_reports_changes_and_ignored_paths() {
        if executable().is_none() {
            return;
        }
        let temp = tempfile::tempdir().expect("tempdir");
        let root = temp.path();
        git(&["init", "-q"], root);
        write("ignored/\n", ".gitignore", root);
        std::fs::create_dir_all(root.join("ignored")).expect("mkdir");
        write("", "ignored/cache.bin", root);
        write("one", "tracked.txt", root);
        git(&["add", "tracked.txt", ".gitignore"], root);
        commit(root);
        write("two", "tracked.txt", root);
        write("", "fresh.txt", root);

        let snapshot = snapshot(root);

        let expected: std::collections::HashMap<String, GitFileStatus> = [
            ("tracked.txt".to_owned(), GitFileStatus::Modified),
            ("fresh.txt".to_owned(), GitFileStatus::Untracked),
        ]
        .into();
        assert_eq!(snapshot.file_statuses, expected);
        assert!(snapshot.is_ignored("ignored/cache.bin"));
        let mut files = list_files(root).expect("files");
        files.sort();
        assert_eq!(files, [".gitignore", "fresh.txt", "tracked.txt"]);
    }
}
