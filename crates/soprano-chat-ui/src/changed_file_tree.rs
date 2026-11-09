//! Folder/file tree of a turn's changed files (`ChangedFileTree.swift`): folders first, then
//! files, each sorted by name (numeric-aware, case-insensitive); single-child folder chains
//! collapse into one row ("Sources/Auth"); folders carry the summed stats of their files.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use soprano_agents::ChangedFileStat;
use soprano_git::natural::natural_compare;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum ChangedFileNode {
    Directory {
        name: String,
        path: String,
        additions: usize,
        deletions: usize,
        children: Vec<ChangedFileNode>,
    },
    File {
        name: String,
        path: String,
        additions: usize,
        deletions: usize,
    },
}

impl ChangedFileNode {
    pub fn name(&self) -> &str {
        match self {
            Self::Directory { name, .. } | Self::File { name, .. } => name,
        }
    }

    pub fn path(&self) -> &str {
        match self {
            Self::Directory { path, .. } | Self::File { path, .. } => path,
        }
    }

    pub fn is_directory(&self) -> bool {
        matches!(self, Self::Directory { .. })
    }

    /// Lines added and removed under the node.
    pub fn stats(&self) -> (usize, usize) {
        match self {
            Self::Directory { additions, deletions, .. } | Self::File { additions, deletions, .. } => {
                (*additions, *deletions)
            }
        }
    }
}

/// One visible row of the tree with its depth.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ChangedFileTreeRow {
    pub node: ChangedFileNode,
    pub depth: usize,
}

#[derive(Default)]
struct Directory {
    name: String,
    path: String,
    additions: usize,
    deletions: usize,
    directories: BTreeMap<String, Directory>,
    files: Vec<ChangedFileNode>,
}

pub fn build(files: &[ChangedFileStat]) -> Vec<ChangedFileNode> {
    let mut root = Directory::default();
    for file in files {
        let normalized = file.path.replace('\\', "/");
        let segments: Vec<&str> = normalized.split('/').filter(|s| !s.is_empty()).collect();
        let Some((file_name, folders)) = segments.split_last() else { continue };
        root.additions += file.additions;
        root.deletions += file.deletions;
        let mut current = &mut root;
        for segment in folders {
            let parent_path = current.path.clone();
            current = current.directories.entry((*segment).to_owned()).or_insert_with(|| Directory {
                name: (*segment).to_owned(),
                path: if parent_path.is_empty() {
                    (*segment).to_owned()
                } else {
                    format!("{parent_path}/{segment}")
                },
                ..Directory::default()
            });
            current.additions += file.additions;
            current.deletions += file.deletions;
        }
        current.files.push(ChangedFileNode::File {
            name: (*file_name).to_owned(),
            path: segments.join("/"),
            additions: file.additions,
            deletions: file.deletions,
        });
    }
    nodes(root)
}

fn nodes(directory: Directory) -> Vec<ChangedFileNode> {
    let mut folders: Vec<Directory> = directory.directories.into_values().collect();
    folders.sort_by(|a, b| natural_compare(&a.name, &b.name));
    let mut files = directory.files;
    files.sort_by(|a, b| natural_compare(a.name(), b.name()));
    folders
        .into_iter()
        .map(|folder| {
            compact(ChangedFileNode::Directory {
                name: folder.name.clone(),
                path: folder.path.clone(),
                additions: folder.additions,
                deletions: folder.deletions,
                children: nodes(folder),
            })
        })
        .chain(files)
        .collect()
}

fn compact(node: ChangedFileNode) -> ChangedFileNode {
    let ChangedFileNode::Directory { mut name, mut path, mut additions, mut deletions, mut children } = node
    else {
        return node;
    };
    while children.len() == 1 && children[0].is_directory() {
        let Some(ChangedFileNode::Directory {
            name: child_name,
            path: child_path,
            additions: child_additions,
            deletions: child_deletions,
            children: grandchildren,
        }) = children.pop()
        else {
            break;
        };
        name = format!("{name}/{child_name}");
        path = child_path;
        additions = child_additions;
        deletions = child_deletions;
        children = grandchildren;
    }
    ChangedFileNode::Directory { name, path, additions, deletions, children }
}

/// The rows shown with `collapsed` folder paths closed (everything else open).
pub fn rows(nodes: &[ChangedFileNode], collapsed: &HashSet<String>) -> Vec<ChangedFileTreeRow> {
    let mut result = Vec::new();
    append_rows(nodes, collapsed, 0, &mut result);
    result
}

fn append_rows(
    nodes: &[ChangedFileNode],
    collapsed: &HashSet<String>,
    depth: usize,
    result: &mut Vec<ChangedFileTreeRow>,
) {
    for node in nodes {
        result.push(ChangedFileTreeRow { node: node.clone(), depth });
        if let ChangedFileNode::Directory { path, children, .. } = node
            && !collapsed.contains(path)
        {
            append_rows(children, collapsed, depth + 1, result);
        }
    }
}

/// Every folder path in the tree ("Collapse all folders").
pub fn directory_paths(nodes: &[ChangedFileNode]) -> BTreeSet<String> {
    let mut result = BTreeSet::new();
    for node in nodes {
        if let ChangedFileNode::Directory { path, children, .. } = node {
            result.insert(path.clone());
            result.extend(directory_paths(children));
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stat(path: &str, additions: usize, deletions: usize) -> ChangedFileStat {
        ChangedFileStat { path: path.into(), additions, deletions }
    }

    #[test]
    fn folders_come_first_single_child_chains_collapse_and_folders_sum_their_files() {
        let tree = build(&[
            stat("README.md", 1, 0),
            stat("Sources/Auth/Login.swift", 3, 1),
            stat("Sources/Auth/file10.swift", 1, 1),
            stat("Sources/Auth/file2.swift", 2, 0),
        ]);
        assert_eq!(tree.len(), 2);
        let ChangedFileNode::Directory { name, path, additions, deletions, children } = &tree[0] else {
            panic!("expected a folder first");
        };
        assert_eq!(
            (name.as_str(), path.as_str(), *additions, *deletions),
            ("Sources/Auth", "Sources/Auth", 6, 2)
        );
        let names: Vec<&str> = children.iter().map(ChangedFileNode::name).collect();
        assert_eq!(names, ["file2.swift", "file10.swift", "Login.swift"]);
        assert_eq!(tree[1].path(), "README.md");
    }

    #[test]
    fn closed_folders_hide_their_rows_and_every_folder_path_is_listed() {
        let tree = build(&[stat("a/x.rs", 1, 0), stat("a/b/y.rs", 1, 0), stat("c/z.rs", 0, 1)]);
        let open = rows(&tree, &HashSet::new());
        let depths: Vec<(String, usize)> = open.iter().map(|r| (r.node.name().to_owned(), r.depth)).collect();
        assert_eq!(
            depths,
            [("a", 0), ("b", 1), ("y.rs", 2), ("x.rs", 1), ("c", 0), ("z.rs", 1)]
                .map(|(n, d)| (n.to_owned(), d))
        );
        let closed = rows(&tree, &HashSet::from(["a".to_owned()]));
        assert_eq!(closed.len(), 3);
        assert_eq!(directory_paths(&tree), BTreeSet::from(["a".into(), "a/b".into(), "c".into()]));
    }
}
