//! Shared `@` file-mention autocomplete and Orca-style composer footer metadata (host, folder,
//! checkout kind, git branch) used by both the Chat UI composer and the Agent Dashboard composer.

use std::cell::Cell;
use std::ops::Range;
use std::path::Path;
use std::process::Command;
use std::rc::Rc;
use std::sync::OnceLock;

use gpui::{
    AnyElement, App, Bounds, FontWeight, IntoElement, ParentElement, Pixels, Styled, Window, canvas, div,
    prelude::*,
};
use soprano_git::branch::{current_branch, repository_root};
use soprano_platform::shell::path_word;
use soprano_ui::fonts::UI_FONT_FAMILY;
use soprano_ui::{IconName, SopranoTheme, icon};

use crate::widgets::text_size;

/// Upper bound on indexed project files so huge monorepos stay instant.
const MAX_INDEXED_FILES: usize = 10_000;
/// Maximum recursion depth for the non-git directory walk fallback.
const MAX_WALK_DEPTH: usize = 12;
/// Maximum rows shown in the `@` mention popup.
pub const MENTION_ROW_LIMIT: usize = 40;

/// Directories skipped during the non-git directory walk fallback.
const SKIPPED_DIRS: &[&str] = &[
    ".git",
    ".hg",
    ".svn",
    "node_modules",
    "target",
    ".next",
    "dist",
    "build",
    ".turbo",
    ".venv",
    "__pycache__",
    ".cache",
];

/// An active `@file` token under the editor's caret. Offsets are UTF-8 byte offsets.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MentionToken {
    /// The whole token, `@` included.
    pub range: Range<usize>,
    /// What was typed between `@` and the caret.
    pub query: String,
}

impl MentionToken {
    /// The `@` mention token around `caret`, when preceded by start-of-text, whitespace, or an
    /// opening delimiter and the caret sits after `@`.
    pub fn at(text: &str, caret: usize) -> Option<Self> {
        if caret == 0 || caret > text.len() || !text.is_char_boundary(caret) {
            return None;
        }
        let start = text[..caret]
            .char_indices()
            .rev()
            .find(|(_, c)| is_mention_boundary(*c))
            .map_or(0, |(i, c)| i + c.len_utf8());
        if start >= caret || text.as_bytes()[start] != b'@' {
            return None;
        }
        let end = text[caret..]
            .char_indices()
            .find(|(_, c)| c.is_whitespace())
            .map_or(text.len(), |(i, _)| caret + i);
        Some(Self { range: start..end, query: text[start + 1..caret].to_owned() })
    }

    /// Replaces this `@` token with `@<path> ` (without doubling an existing trailing space).
    pub fn replacement(&self, path: &str, text: &str) -> (Range<usize>, String) {
        let mut range = self.range.clone();
        if text.as_bytes().get(range.end) == Some(&b' ') {
            range.end += 1;
        }
        let formatted =
            if path.chars().any(char::is_whitespace) { path_word(Path::new(path)) } else { path.to_owned() };
        (range, format!("@{formatted} "))
    }
}

fn is_mention_boundary(c: char) -> bool {
    c.is_whitespace() || matches!(c, '(' | '[' | '{' | '"' | '\'')
}

/// The open `@` file-mention menu state.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MentionMenu {
    pub token: MentionToken,
    pub highlighted: Option<usize>,
    /// The highlighted path, kept highlighted across refreshes.
    pub highlighted_path: Option<String>,
}

/// Lists project files relative to `root` (`/`-separated). Uses `git ls-files` inside git
/// repositories (respecting `.gitignore` while including untracked non-ignored files) and falls
/// back to a bounded directory walk outside git.
pub fn list_project_files(root: &Path) -> Vec<String> {
    if !root.is_dir() {
        return Vec::new();
    }
    if let Some(files) = git_project_files(root) {
        return files;
    }
    let mut files = Vec::new();
    walk_directory(root, root, 0, &mut files);
    files.sort();
    files
}

fn git_project_files(root: &Path) -> Option<Vec<String>> {
    repository_root(&root.to_string_lossy())?;
    let mut cmd = Command::new("git");
    cmd.args(["-C", &root.to_string_lossy(), "ls-files", "--cached", "--others", "--exclude-standard"])
        .env("GIT_OPTIONAL_LOCKS", "0");
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    let output = cmd.output().ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut files: Vec<String> = stdout
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .take(MAX_INDEXED_FILES)
        .map(|line| line.replace('\\', "/"))
        .collect();
    files.sort();
    files.dedup();
    Some(files)
}

fn walk_directory(root: &Path, dir: &Path, depth: usize, out: &mut Vec<String>) {
    if depth > MAX_WALK_DEPTH || out.len() >= MAX_INDEXED_FILES {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        if out.len() >= MAX_INDEXED_FILES {
            break;
        }
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        let path = entry.path();
        let Ok(file_type) = entry.file_type() else { continue };
        if file_type.is_symlink() {
            continue;
        }
        if file_type.is_dir() {
            if SKIPPED_DIRS.contains(&name_str.as_ref()) {
                continue;
            }
            walk_directory(root, &path, depth + 1, out);
        } else if file_type.is_file()
            && let Ok(rel) = path.strip_prefix(root)
        {
            let normalized = rel.to_string_lossy().replace('\\', "/");
            if !normalized.is_empty() {
                out.push(normalized);
            }
        }
    }
}

/// Filters and ranks `files` against `query` (case-insensitive, basename matches first, then
/// path substring, then fuzzy subsequence).
pub fn matching_files<'a>(files: &'a [String], query: &str, limit: usize) -> Vec<&'a str> {
    let needle = query.trim().to_lowercase();
    if needle.is_empty() {
        return files.iter().take(limit).map(String::as_str).collect();
    }
    let mut scored: Vec<(u8, usize, &'a str)> = files
        .iter()
        .filter_map(|path| {
            let lower = path.to_lowercase();
            let base = lower.rsplit('/').next().unwrap_or(lower.as_str());
            let tier = if base.starts_with(&needle) {
                0
            } else if base.contains(&needle) {
                1
            } else if lower.contains(&needle) {
                2
            } else if is_subsequence(&needle, &lower) {
                3
            } else {
                return None;
            };
            Some((tier, path.len(), path.as_str()))
        })
        .collect();
    scored.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)).then_with(|| a.2.cmp(b.2)));
    scored.into_iter().take(limit).map(|(_, _, path)| path).collect()
}

fn is_subsequence(needle: &str, haystack: &str) -> bool {
    let mut chars = needle.chars();
    let Some(mut target) = chars.next() else { return true };
    for ch in haystack.chars() {
        if ch == target {
            match chars.next() {
                Some(next) => target = next,
                None => return true,
            }
        }
    }
    false
}

/// Splits a relative path into `(file_name, parent_dir)`.
pub fn split_mention_path(path: &str) -> (&str, Option<&str>) {
    match path.rsplit_once('/') {
        Some((parent, name)) if !name.is_empty() => (name, Some(parent)),
        _ => (path, None),
    }
}

/// What sits right beneath the composer card (Orca's metadata bar): host/machine, folder and
/// git checkout kind (`Main checkout` or `Worktree`), and active git branch.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ComposerContextInfo {
    pub host: String,
    pub folder: String,
    pub checkout_kind: Option<&'static str>,
    pub branch: Option<String>,
}

impl ComposerContextInfo {
    /// Resolves host, folder, checkout kind, and current git branch for `cwd`.
    pub fn from_cwd(cwd: &Path, remote_machine: Option<&str>) -> Self {
        let host = remote_machine
            .map(str::trim)
            .filter(|m| !m.is_empty())
            .map_or_else(local_host_name, str::to_owned);
        let cwd_str = cwd.to_string_lossy();
        let folder = cwd
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| cwd_str.to_string());
        let checkout_kind = repository_root(&cwd_str).and_then(|root| {
            let meta = std::fs::metadata(root.join(".git")).ok()?;
            Some(if meta.is_dir() { "Main checkout" } else { "Worktree" })
        });
        let branch = current_branch(&cwd_str);
        Self { host, folder, checkout_kind, branch }
    }

    pub fn is_empty(&self) -> bool {
        self.host.is_empty() && self.folder.is_empty() && self.branch.is_none()
    }
}

/// The local machine's display name (cached once per process).
pub fn local_host_name() -> String {
    if cfg!(test) {
        return "Local".to_owned();
    }
    static HOST: OnceLock<String> = OnceLock::new();
    HOST.get_or_init(detect_local_host_name).clone()
}

fn detect_local_host_name() -> String {
    #[cfg(target_os = "macos")]
    {
        if let Ok(output) = Command::new("scutil").args(["--get", "ComputerName"]).output()
            && output.status.success()
        {
            let name = String::from_utf8_lossy(&output.stdout).trim().to_owned();
            if !name.is_empty() {
                return name;
            }
        }
    }
    if let Ok(output) = Command::new("hostname").arg("-s").output()
        && output.status.success()
    {
        let name = String::from_utf8_lossy(&output.stdout).trim().to_owned();
        if !name.is_empty() {
            return name;
        }
    }
    for var in ["COMPUTERNAME", "HOSTNAME"] {
        if let Ok(name) = std::env::var(var)
            && !name.trim().is_empty()
        {
            return name.trim().to_owned();
        }
    }
    "Local".to_owned()
}

/// Whether a permission/approval mode value or name represents an unrestricted / bypass mode
/// (renders the amber warning shield like Orca).
pub fn is_bypass_permission_mode(value: &str, name: &str) -> bool {
    let combined = format!("{value} {name}").to_ascii_lowercase();
    ["yolo", "bypass", "danger", "unrestricted", "full-auto", "full auto", "auto-approve", "auto approve"]
        .iter()
        .any(|needle| combined.contains(needle))
}

/// Callback invoked when the composer context bar's branch trigger is clicked.
pub type BranchClickHandler = Rc<dyn Fn(&mut Window, &mut App)>;

/// Makes the `[GitBranch] <name>` chip in [`render_composer_context_bar`] clickable so it can
/// open a [`crate::BranchSwitcher`] anchored right above it.
pub struct BranchTrigger {
    pub bounds: Rc<Cell<Bounds<Pixels>>>,
    pub open: bool,
    pub on_click: BranchClickHandler,
}

/// Renders Orca's subtle single-line context bar right underneath the composer card:
/// `[Server] host   [Folder] folder · Main checkout   [GitBranch] branch`.
pub fn render_composer_context_bar(
    id: &'static str,
    info: &ComposerContextInfo,
    scale: impl Fn(f32) -> Pixels,
    zoom_factor: f32,
    t: &SopranoTheme,
    branch_trigger: Option<BranchTrigger>,
) -> Option<AnyElement> {
    if info.is_empty() {
        return None;
    }
    let icon_size = 12.0 * zoom_factor;
    Some(
        div()
            .id(id)
            .debug_selector(move || id.into())
            .w_full()
            .flex()
            .flex_row()
            .items_center()
            .gap(scale(14.0))
            .px(scale(10.0))
            .pt(scale(6.0))
            .font_family(UI_FONT_FAMILY)
            .text_size(scale(text_size::SMALL))
            .text_color(t.muted)
            .overflow_hidden()
            .when(!info.host.is_empty(), |bar| {
                bar.child(
                    div()
                        .flex()
                        .flex_row()
                        .flex_none()
                        .items_center()
                        .gap(scale(5.0))
                        .child(icon(IconName::Server).size(icon_size).color(t.muted))
                        .child(div().whitespace_nowrap().child(info.host.clone())),
                )
            })
            .when(!info.folder.is_empty(), |bar| {
                bar.child(
                    div()
                        .flex()
                        .flex_row()
                        .min_w_0()
                        .items_center()
                        .gap(scale(5.0))
                        .child(icon(IconName::Folder).size(icon_size).color(t.muted))
                        .child(
                            div()
                                .min_w_0()
                                .truncate()
                                .font_weight(FontWeight::MEDIUM)
                                .text_color(t.foreground.opacity(0.75))
                                .child(info.folder.clone()),
                        )
                        .when_some(info.checkout_kind, |slot, kind| {
                            slot.child(
                                div()
                                    .flex_none()
                                    .whitespace_nowrap()
                                    .text_color(t.muted)
                                    .child(format!("· {kind}")),
                            )
                        }),
                )
            })
            .when_some(info.branch.clone(), |bar, branch| {
                let chip = div()
                    .id(gpui::SharedString::from(format!("{id}-branch")))
                    .debug_selector(move || format!("{id}-branch"))
                    .relative()
                    .flex()
                    .flex_row()
                    .min_w_0()
                    .items_center()
                    .gap(scale(5.0))
                    .child(icon(IconName::GitBranch).size(icon_size).color(t.muted))
                    .child(div().min_w_0().truncate().child(branch));
                let chip = match branch_trigger {
                    Some(trigger) => {
                        let bounds = trigger.bounds;
                        let on_click = trigger.on_click;
                        let hover_bg = t.hover;
                        let hover_fg = t.foreground;
                        chip.rounded(scale(4.0))
                            .px(scale(5.0))
                            .py(scale(1.0))
                            .mx(scale(-5.0))
                            .my(scale(-1.0))
                            .cursor_pointer()
                            .when(trigger.open, move |s| s.bg(hover_bg).text_color(hover_fg))
                            .hover(move |s| s.bg(hover_bg).text_color(hover_fg))
                            .tooltip(soprano_ui::tooltip("Switch branch"))
                            .on_click(move |_, window, cx| on_click(window, cx))
                            .child(
                                canvas(move |drawn, _, _| bounds.set(drawn), |_, _, _, _| {})
                                    .absolute()
                                    .size_full(),
                            )
                    }
                    None => chip,
                };
                bar.child(chip)
            })
            .into_any_element(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mention_token_matches_at_start_or_after_whitespace_and_replaces_cleanly() {
        assert_eq!(MentionToken::at("@", 1), Some(MentionToken { range: 0..1, query: "".into() }));
        assert_eq!(
            MentionToken::at("check @src/main", 15),
            Some(MentionToken { range: 6..15, query: "src/main".into() })
        );
        // Email address does not trigger a file mention.
        assert_eq!(MentionToken::at("foo@bar.com", 11), None);
        // Inside parens does trigger.
        assert_eq!(
            MentionToken::at("see (@comp", 10),
            Some(MentionToken { range: 5..10, query: "comp".into() })
        );

        let token = MentionToken::at("check @comp now", 11).expect("token");
        let (range, insert) = token.replacement("src/composer.rs", "check @comp now");
        // Absorbs existing trailing space so it doesn't double up.
        assert_eq!(range, 6..12);
        assert_eq!(insert, "@src/composer.rs ");
    }

    #[test]
    fn matching_files_ranks_basename_prefix_ahead_of_substring_and_subsequence() {
        let files: Vec<String> = vec![
            "docs/notes.md".into(),
            "crates/ui/src/composer_parts.rs".into(),
            "crates/ui/src/composer.rs".into(),
            "src/my_composer_helper.rs".into(),
        ];
        let matches = matching_files(&files, "comp", 10);
        assert_eq!(
            matches,
            vec!["crates/ui/src/composer.rs", "crates/ui/src/composer_parts.rs", "src/my_composer_helper.rs"]
        );
        // Fuzzy subsequence still finds it.
        assert_eq!(matching_files(&files, "cmprs", 10)[0], "crates/ui/src/composer.rs");
    }

    #[test]
    fn list_project_files_walks_a_plain_folder_and_skips_ignored_dirs() {
        let dir = tempfile::tempdir().expect("tempdir");
        std::fs::create_dir_all(dir.path().join("src")).expect("src");
        std::fs::create_dir_all(dir.path().join("node_modules/pkg")).expect("nm");
        std::fs::write(dir.path().join("README.md"), "hi").expect("readme");
        std::fs::write(dir.path().join("src/main.rs"), "fn main() {}").expect("main");
        std::fs::write(dir.path().join("node_modules/pkg/index.js"), "").expect("nm file");

        let files = list_project_files(dir.path());
        assert_eq!(files, vec!["README.md", "src/main.rs"]);
    }

    #[test]
    fn context_info_distinguishes_main_checkout_and_worktree() {
        let root = tempfile::tempdir().expect("root");
        let main_repo = root.path().join("soprano");
        std::fs::create_dir_all(main_repo.join(".git")).expect("git");
        std::fs::write(main_repo.join(".git/HEAD"), "ref: refs/heads/main\n").expect("head");

        let info = ComposerContextInfo::from_cwd(&main_repo, None);
        assert_eq!(info.folder, "soprano");
        assert_eq!(info.checkout_kind, Some("Main checkout"));
        assert_eq!(info.branch.as_deref(), Some("main"));

        let wt_git = main_repo.join(".git/worktrees/feat");
        std::fs::create_dir_all(&wt_git).expect("wt git");
        std::fs::write(wt_git.join("HEAD"), "ref: refs/heads/feat/orca\n").expect("wt head");
        let wt = root.path().join("soprano-orca");
        std::fs::create_dir_all(&wt).expect("wt");
        std::fs::write(wt.join(".git"), format!("gitdir: {}\n", wt_git.display())).expect("gitdir");

        let wt_info = ComposerContextInfo::from_cwd(&wt, Some("devbox"));
        assert_eq!(wt_info.host, "devbox");
        assert_eq!(wt_info.folder, "soprano-orca");
        assert_eq!(wt_info.checkout_kind, Some("Worktree"));
        assert_eq!(wt_info.branch.as_deref(), Some("feat/orca"));
    }

    #[test]
    fn bypass_mode_detection_catches_unrestricted_modes_and_ignores_default() {
        assert!(is_bypass_permission_mode("yolo", "Bypass permissions"));
        assert!(is_bypass_permission_mode("full-auto", "Full Auto"));
        assert!(!is_bypass_permission_mode("default", "Default"));
        assert!(!is_bypass_permission_mode("ask", "Ask before edits"));
    }
}
