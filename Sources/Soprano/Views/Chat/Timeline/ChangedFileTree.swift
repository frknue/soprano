import Foundation

/// Folder/file tree of a turn's changed files: folders first,
/// then files, each sorted by name (numeric-aware, case-insensitive); single-child folder chains
/// collapse into one row ("Sources/Auth"); folders carry the summed stats of their files.
indirect enum ChangedFileNode: Hashable, Sendable {
    case directory(name: String, path: String, additions: Int, deletions: Int, children: [ChangedFileNode])
    case file(name: String, path: String, additions: Int, deletions: Int)

    var name: String {
        switch self {
        case let .directory(name, _, _, _, _), let .file(name, _, _, _): name
        }
    }

    var path: String {
        switch self {
        case let .directory(_, path, _, _, _), let .file(_, path, _, _): path
        }
    }

    var isDirectory: Bool {
        if case .directory = self { return true }
        return false
    }
}

/// One visible row of the tree with its depth.
struct ChangedFileTreeRow: Hashable, Sendable {
    var node: ChangedFileNode
    var depth: Int
}

enum ChangedFileTree {
    static func build(_ files: [ChangedFileStat]) -> [ChangedFileNode] {
        final class Directory {
            let name: String
            let path: String
            var additions = 0
            var deletions = 0
            var directories: [String: Directory] = [:]
            var files: [ChangedFileNode] = []

            init(name: String, path: String) {
                self.name = name
                self.path = path
            }
        }

        let root = Directory(name: "", path: "")
        for file in files {
            let segments = file.path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
            guard let fileName = segments.last else { continue }
            var ancestors = [root]
            var current = root
            for segment in segments.dropLast() {
                let next = current.directories[segment] ?? {
                    let created = Directory(name: segment, path: current.path.isEmpty ? segment : "\(current.path)/\(segment)")
                    current.directories[segment] = created
                    return created
                }()
                current = next
                ancestors.append(current)
            }
            current.files.append(.file(name: fileName, path: segments.joined(separator: "/"), additions: file.additions, deletions: file.deletions))
            for ancestor in ancestors {
                ancestor.additions += file.additions
                ancestor.deletions += file.deletions
            }
        }

        func nodes(of directory: Directory) -> [ChangedFileNode] {
            let folders = directory.directories.values
                .sorted { compare($0.name, $1.name) }
                .map { compact(.directory(name: $0.name, path: $0.path, additions: $0.additions, deletions: $0.deletions, children: nodes(of: $0))) }
            let files = directory.files.sorted { compare($0.name, $1.name) }
            return folders + files
        }
        return nodes(of: root)
    }

    /// The rows shown with `collapsed` folder paths closed (everything else open).
    static func rows(_ nodes: [ChangedFileNode], collapsed: Set<String> = [], depth: Int = 0) -> [ChangedFileTreeRow] {
        var result: [ChangedFileTreeRow] = []
        for node in nodes {
            result.append(ChangedFileTreeRow(node: node, depth: depth))
            if case let .directory(_, path, _, _, children) = node, !collapsed.contains(path) {
                result += rows(children, collapsed: collapsed, depth: depth + 1)
            }
        }
        return result
    }

    /// Every folder path in the tree ("Collapse all folders").
    static func directoryPaths(_ nodes: [ChangedFileNode]) -> Set<String> {
        var result: Set<String> = []
        for node in nodes {
            if case let .directory(_, path, _, _, children) = node {
                result.insert(path)
                result.formUnion(directoryPaths(children))
            }
        }
        return result
    }

    private static func compact(_ node: ChangedFileNode) -> ChangedFileNode {
        guard case .directory(var name, var path, var additions, var deletions, var children) = node else { return node }
        while children.count == 1, case let .directory(childName, childPath, childAdditions, childDeletions, grandchildren) = children[0] {
            name = "\(name)/\(childName)"
            path = childPath
            additions = childAdditions
            deletions = childDeletions
            children = grandchildren
        }
        return .directory(name: name, path: path, additions: additions, deletions: deletions, children: children)
    }

    private static func compare(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.numeric, .caseInsensitive, .diacriticInsensitive]) == .orderedAscending
    }
}
