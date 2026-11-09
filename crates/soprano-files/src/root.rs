//! Which folder the explorer shows, how absolute paths map into it, and the explorer's
//! persisted visibility toggles.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use soprano_git::branch::{repository_root, resolve_head_path, standardize};
use soprano_platform::StateStore;

/// The directory the explorer shows for a pane: the git working tree containing the
/// pane's directory, or the directory itself outside a repository.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExplorerRoot {
    pub path: PathBuf,
    pub is_git_repository: bool,
}

/// The directory the explorer shows for a pane working in `cwd`.
pub fn explorer_root(cwd: &str) -> ExplorerRoot {
    let expanded = soprano_platform::paths::expand_tilde(cwd).to_string_lossy().into_owned();
    match repository_root(&expanded) {
        Some(path) => ExplorerRoot { path, is_git_repository: true },
        None => ExplorerRoot { path: standardize(&expanded), is_git_repository: false },
    }
}

/// The fully symlink-resolved form of `path` (`realpath`), which is what file watchers
/// report (`/private/var/…` for `/var/…` on macOS).
pub fn real_path(path: &Path) -> Option<PathBuf> {
    std::fs::canonicalize(path).ok().map(|resolved| without_verbatim_prefix(&resolved).into_owned())
}

/// On Windows, `C:\x` for a verbatim `\\?\C:\x` (what `canonicalize` returns; watchers and
/// panes report plain paths, and the two spellings share no components). UNC and other
/// paths, and every path elsewhere, are returned as they are.
pub fn without_verbatim_prefix(path: &Path) -> std::borrow::Cow<'_, Path> {
    #[cfg(windows)]
    {
        let text = path.to_string_lossy();
        if let Some(plain) = text.strip_prefix(r"\\?\")
            && !plain.starts_with(r"UNC\")
        {
            return std::borrow::Cow::Owned(PathBuf::from(plain));
        }
    }
    std::borrow::Cow::Borrowed(path)
}

/// The resolved git directory of a working tree whose `.git` is a
/// `gitdir:` file (linked worktree, submodule), or `None` when it is the
/// root's own `.git` folder. The explorer watches it too, since git state changes there.
pub fn external_git_directory(root: &Path) -> Option<PathBuf> {
    let head_path = resolve_head_path(&root.to_string_lossy())?;
    let git_directory = real_path(head_path.parent()?)?;
    let resolved_root = real_path(root).unwrap_or_else(|| root.to_path_buf());
    if git_directory.starts_with(&resolved_root) { None } else { Some(git_directory) }
}

/// `path` relative to the folder `root`, which may be the volume root;
/// `None` for the root itself and anything outside it. Matching is component-wise, so
/// it works with either separator on Windows; the result always uses `/`.
pub fn relative_path(path: &Path, root: &Path) -> Option<String> {
    let (path, root) = (without_verbatim_prefix(path), without_verbatim_prefix(root));
    let rest = path.strip_prefix(&root).ok()?;
    let relative = join_components(rest)?;
    (!relative.is_empty()).then_some(relative)
}

/// Root-relative form of an absolute path, matching the root as configured or its
/// symlink-resolved form (file watchers report the latter); `""` for a root itself.
pub fn relative_path_in_roots(path: &Path, roots: &[&Path]) -> Option<String> {
    let path = without_verbatim_prefix(path);
    roots.iter().find_map(|root| join_components(path.strip_prefix(without_verbatim_prefix(root)).ok()?))
}

/// The absolute path of a root-relative tree path (`a/b`, always `/`-separated) under
/// `root`, with the platform's separators.
pub fn absolute_path(root: &Path, relative_path: &str) -> PathBuf {
    relative_path
        .split('/')
        .filter(|segment| !segment.is_empty())
        .fold(root.to_path_buf(), |path, segment| path.join(segment))
}

/// `a/b/c` from a relative path's normal components; `None` if it climbs or is absolute.
fn join_components(relative: &Path) -> Option<String> {
    use std::path::Component;
    let mut joined = String::new();
    for component in relative.components() {
        match component {
            Component::Normal(name) => {
                if !joined.is_empty() {
                    joined.push('/');
                }
                joined.push_str(&name.to_string_lossy());
            }
            Component::CurDir => {}
            _ => return None,
        }
    }
    Some(joined)
}

/// The parent of a root-relative tree path (tree paths use `/` on every OS), `""` at the top.
pub fn parent_path(relative_path: &str) -> &str {
    relative_path.rfind('/').map_or("", |slash| &relative_path[..slash])
}

/// The relative path of `name` inside the folder at `parent` (`""` = root).
pub fn child_path(parent: &str, name: &str) -> String {
    if parent.is_empty() { name.to_owned() } else { format!("{parent}/{name}") }
}

const SHOW_IGNORED_KEY: &str = "soprano-explorer-show-ignored";
const HIDDEN_DOTFILE_ROOTS_KEY: &str = "soprano-explorer-hidden-dotfile-roots";

/// The explorer's visibility toggles, persisted like the Swift `UserDefaults` keys:
/// ignored files shown (default on, global) and dotfiles hidden per project root.
#[derive(Clone)]
pub struct ExplorerPreferences {
    store: StateStore,
    shows_ignored_files: bool,
    dotfile_hidden_roots: BTreeSet<String>,
}

impl ExplorerPreferences {
    pub fn load(store: StateStore) -> Self {
        let shows_ignored_files = store.get::<bool>(SHOW_IGNORED_KEY).unwrap_or(true);
        let dotfile_hidden_roots =
            store.get::<Vec<String>>(HIDDEN_DOTFILE_ROOTS_KEY).unwrap_or_default().into_iter().collect();
        Self { store, shows_ignored_files, dotfile_hidden_roots }
    }

    pub fn shows_ignored_files(&self) -> bool {
        self.shows_ignored_files
    }

    /// Dotfiles show unless they were hidden for this root.
    pub fn shows_dotfiles(&self, root: &Path) -> bool {
        !self.dotfile_hidden_roots.contains(root.to_string_lossy().as_ref())
    }

    pub fn toggle_dotfiles(&mut self, root: &Path) {
        let key = root.to_string_lossy().into_owned();
        if !self.dotfile_hidden_roots.remove(&key) {
            self.dotfile_hidden_roots.insert(key);
        }
        let sorted: Vec<&String> = self.dotfile_hidden_roots.iter().collect();
        self.store.set(HIDDEN_DOTFILE_ROOTS_KEY, &sorted);
    }

    pub fn toggle_ignored_files(&mut self) {
        self.shows_ignored_files = !self.shows_ignored_files;
        self.store.set(SHOW_IGNORED_KEY, &self.shows_ignored_files);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_linked_worktree_also_watches_its_git_directory() {
        let root = tempfile::tempdir().expect("tempdir");
        let main_git = root.path().join("main/.git");
        let worktree_git = main_git.join("worktrees/feature");
        std::fs::create_dir_all(&worktree_git).expect("mkdir");
        std::fs::write(worktree_git.join("HEAD"), "ref: refs/heads/feature\n").expect("HEAD");
        std::fs::write(main_git.join("HEAD"), "ref: refs/heads/main\n").expect("HEAD");
        let worktree = root.path().join("feature");
        std::fs::create_dir_all(&worktree).expect("mkdir");
        std::fs::write(worktree.join(".git"), format!("gitdir: {}\n", worktree_git.display()))
            .expect("gitdir");

        assert_eq!(external_git_directory(&worktree), real_path(&worktree_git));
        assert_eq!(external_git_directory(&root.path().join("main")), None);
    }

    #[test]
    fn the_root_is_the_working_tree_containing_the_panes_directory() {
        let root = tempfile::tempdir().expect("tempdir");
        let nested = root.path().join("repo/Sources/App");
        std::fs::create_dir_all(&nested).expect("mkdir");
        std::fs::create_dir_all(root.path().join("repo/.git")).expect("mkdir");
        let worktree = root.path().join("repo/Sources/linked");
        std::fs::create_dir_all(&worktree).expect("mkdir");
        std::fs::write(worktree.join(".git"), "gitdir: /elsewhere\n").expect("gitdir");
        let plain = root.path().join("plain/sub");
        std::fs::create_dir_all(&plain).expect("mkdir");

        let repo_root = explorer_root(&nested.to_string_lossy());
        assert_eq!(repo_root.path, standardize(&root.path().join("repo").to_string_lossy()));
        assert!(repo_root.is_git_repository);

        let worktree_root = explorer_root(&worktree.join(".").to_string_lossy());
        assert_eq!(worktree_root.path, standardize(&worktree.to_string_lossy()));

        let plain_root = explorer_root(&plain.to_string_lossy());
        assert_eq!(plain_root.path, standardize(&plain.to_string_lossy()));
        assert!(!plain_root.is_git_repository);
    }

    #[test]
    fn filter_paths_are_relative_to_the_volume_root_too() {
        let rel = |path: &str, root: &str| relative_path(Path::new(path), Path::new(root));
        assert_eq!(rel("/etc/hosts", "/").as_deref(), Some("etc/hosts"));
        assert_eq!(rel("/src/app/main.swift", "/src/app").as_deref(), Some("main.swift"));
        assert_eq!(rel("/src/application", "/src/app"), None);
        assert_eq!(rel("/", "/"), None);
        assert_eq!(rel("/src/app/a/b.rs", "/src/app/").as_deref(), Some("a/b.rs"));
    }

    #[test]
    fn tree_paths_round_trip_through_absolute_paths() {
        let root = Path::new("/repo");
        let absolute = absolute_path(root, "src/app/main.rs");
        assert_eq!(absolute, root.join("src").join("app").join("main.rs"));
        assert_eq!(relative_path(&absolute, root).as_deref(), Some("src/app/main.rs"));
        assert_eq!(absolute_path(root, ""), root);
        assert_eq!(parent_path("src/app/main.rs"), "src/app");
        assert_eq!(child_path("", "a"), "a");
        assert_eq!(child_path("src", "a"), "src/a");
    }

    #[test]
    fn paths_map_into_either_root_spelling() {
        let roots = [Path::new("/repo"), Path::new("/private/repo")];
        assert_eq!(relative_path_in_roots(Path::new("/repo"), &roots).as_deref(), Some(""));
        assert_eq!(relative_path_in_roots(Path::new("/private/repo/a/b"), &roots).as_deref(), Some("a/b"));
        assert_eq!(relative_path_in_roots(Path::new("/repository/a"), &roots), None);
    }

    /// Windows paths use `\`; the tree's relative paths always use `/`.
    #[cfg(windows)]
    #[test]
    fn windows_paths_map_into_the_tree_with_forward_slashes() {
        let root = Path::new(r"C:\proj");
        assert_eq!(relative_path(Path::new(r"C:\proj\src\a.rs"), root).as_deref(), Some("src/a.rs"));
        assert_eq!(relative_path(Path::new(r"C:\project\a.rs"), root), None);
        assert_eq!(relative_path_in_roots(Path::new(r"C:\proj\src"), &[root]).as_deref(), Some("src"));
        // Verbatim spellings from `canonicalize` map too, on either side.
        assert_eq!(relative_path(Path::new(r"\\?\C:\proj\src\a.rs"), root).as_deref(), Some("src/a.rs"));
        assert_eq!(
            relative_path(Path::new(r"C:\proj\src"), Path::new(r"\\?\C:\proj")).as_deref(),
            Some("src")
        );
        assert_eq!(absolute_path(root, "src/a.rs"), Path::new(r"C:\proj\src\a.rs"));
    }

    #[test]
    fn toggles_persist_under_the_swift_keys() {
        let store = StateStore::in_memory();
        let root = Path::new("/tmp/project");
        let mut preferences = ExplorerPreferences::load(store.clone());
        assert!(preferences.shows_ignored_files());
        assert!(preferences.shows_dotfiles(root));

        preferences.toggle_dotfiles(root);
        preferences.toggle_ignored_files();

        assert_eq!(store.get::<Vec<String>>(HIDDEN_DOTFILE_ROOTS_KEY), Some(vec!["/tmp/project".to_owned()]));
        assert_eq!(store.get::<bool>(SHOW_IGNORED_KEY), Some(false));
        let reloaded = ExplorerPreferences::load(store);
        assert!(!reloaded.shows_dotfiles(root));
        assert!(reloaded.shows_dotfiles(Path::new("/tmp/other")));
        assert!(!reloaded.shows_ignored_files());
    }
}
