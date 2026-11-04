import AppKit

/// One row of the Files explorer: a folder or a file of a thread's working directory. A class so
/// `NSOutlineView` keeps rows (and their expansion) by identity; immutable once built.
final class WorkspaceFileNode: NSObject, Sendable {
    let name: String
    /// Workspace-relative "/"-separated path.
    let path: String
    let isDirectory: Bool
    /// Folders first, then files, each alphabetical (case-insensitive). Empty for files.
    let children: [WorkspaceFileNode]

    init(name: String, path: String, isDirectory: Bool, children: [WorkspaceFileNode] = []) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.children = children
    }

    /// The folder part of `path` ("" at the root).
    var directory: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}

/// The file listing of one working directory: the folder tree the explorer shows and the flat
/// search over every path.
struct WorkspaceFileTree: Sendable {
    /// Most matches a search returns.
    static let searchLimit = 500

    /// Every file path, in listing order.
    let paths: [String]
    /// Top-level folders and files.
    let roots: [WorkspaceFileNode]
    private let lowercasedPaths: [String]

    init(paths: [String]) {
        self.paths = paths
        lowercasedPaths = paths.map { $0.lowercased() }
        let root = FolderBuilder()
        for path in paths {
            let parts = path.split(separator: "/")
            guard let fileName = parts.last else { continue }
            var folder = root
            for part in parts.dropLast() {
                let name = String(part)
                if let next = folder.folders[name] {
                    folder = next
                } else {
                    let next = FolderBuilder()
                    folder.folders[name] = next
                    folder = next
                }
            }
            folder.files.append(String(fileName))
        }
        roots = Self.nodes(of: root, prefix: "")
    }

    var isEmpty: Bool { paths.isEmpty }

    /// Files whose path matches `query` (case-insensitive; surrounding spaces ignored): file
    /// names starting with it, then names containing it, then paths containing it, then paths
    /// containing its characters in order. Listing order within each group; at most `limit`.
    func search(_ query: String, limit: Int = WorkspaceFileTree.searchLimit) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty, limit > 0 else { return [] }
        var groups: [[String]] = [[], [], [], []]
        for (index, path) in lowercasedPaths.enumerated() {
            let name = path.lastIndex(of: "/").map { path[path.index(after: $0)...] } ?? path[...]
            let group: Int
            if name.hasPrefix(needle) {
                group = 0
            } else if name.contains(needle) {
                group = 1
            } else if path.contains(needle) {
                group = 2
            } else if Self.isSubsequence(needle, of: path) {
                group = 3
            } else {
                continue
            }
            groups[group].append(paths[index])
            if group == 0, groups[0].count >= limit { break }
        }
        return Array(groups.joined().prefix(limit))
    }

    /// Paths of every folder in the tree (for expansion bookkeeping).
    var directoryPaths: Set<String> {
        var result: Set<String> = []
        func walk(_ nodes: [WorkspaceFileNode]) {
            for node in nodes where node.isDirectory {
                result.insert(node.path)
                walk(node.children)
            }
        }
        walk(roots)
        return result
    }

    // MARK: - Building

    private final class FolderBuilder {
        var folders: [String: FolderBuilder] = [:]
        var files: [String] = []
    }

    private static func nodes(of folder: FolderBuilder, prefix: String) -> [WorkspaceFileNode] {
        let folders = folder.folders.keys.sorted(by: ordered).map { name in
            let path = prefix + name
            return WorkspaceFileNode(name: name, path: path, isDirectory: true,
                                     children: nodes(of: folder.folders[name] ?? FolderBuilder(), prefix: path + "/"))
        }
        let files = folder.files.sorted(by: ordered).map { name in
            WorkspaceFileNode(name: name, path: prefix + name, isDirectory: false)
        }
        return folders + files
    }

    /// Case-insensitive alphabetical order; exact case breaks ties so the order is total.
    static func ordered(_ lhs: String, _ rhs: String) -> Bool {
        switch lhs.caseInsensitiveCompare(rhs) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs < rhs
        }
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = needle.unicodeScalars.makeIterator()
        guard var wanted = remaining.next() else { return true }
        for scalar in haystack.unicodeScalars where scalar == wanted {
            guard let next = remaining.next() else { return true }
            wanted = next
        }
        return false
    }
}
