import Foundation

// The file explorer's data rules, kept free of AppKit so they can be tested
// directly: directory listing and ordering, git decorations, the name filter,
// and generated names. Modeled on Orca's right-sidebar explorer.

// MARK: - Directory Listing

/// One directory entry as the explorer shows it.
struct FileExplorerEntry: Equatable, Sendable {
    let name: String
    /// Directories and symlinks that resolve to directories.
    let isDirectory: Bool
    let isSymlink: Bool
}

enum FileExplorerListing {
    /// Never listed, whatever the dotfile and ignored-file toggles say.
    static let alwaysHiddenNames: Set<String> = [".git", "node_modules"]

    /// Lists `directory` in display order. Throws when it cannot be read.
    static func entries(in directory: URL) throws -> [FileExplorerEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: []
        )
        let entries = urls.compactMap { url -> FileExplorerEntry? in
            let name = url.lastPathComponent
            guard !alwaysHiddenNames.contains(name) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isSymlink = values?.isSymbolicLink == true
            var isDirectory = values?.isDirectory == true
            if isSymlink {
                isDirectory = (try? url.resolvingSymlinksInPath()
                    .resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            return FileExplorerEntry(name: name, isDirectory: isDirectory, isSymlink: isSymlink)
        }
        return sorted(entries)
    }

    /// Folders first, then Finder's natural order ("file2" before "file10",
    /// case-insensitive), with exact code-unit order breaking ties.
    static func sorted(_ entries: [FileExplorerEntry]) -> [FileExplorerEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.name < rhs.name
            }
        }
    }

    /// Whether any segment of the root-relative path is a dotfile.
    static func isDotfile(relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { segment in
            segment.count > 1 && segment != ".." && segment.hasPrefix(".")
        }
    }
}

// MARK: - Git Decorations

enum GitFileStatus: String, Equatable, Sendable {
    case modified
    case added
    case deleted
    case renamed
    case untracked
    case copied

    var letter: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "U"
        case .copied: "C"
        }
    }

    /// Which status a path (or folder) shows when several apply.
    var priority: Int {
        switch self {
        case .deleted: 5
        case .modified: 4
        case .added, .untracked: 3
        case .renamed: 2
        case .copied: 1
        }
    }

    /// Deleted files are not on disk, so they never color their folders.
    var propagatesToFolders: Bool { self != .deleted }

    init(statusCharacter: Character) {
        switch statusCharacter {
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        default: self = .modified
        }
    }

    /// `current` unless `candidate` strictly outranks it, so the first of two
    /// equally ranked statuses wins.
    static func dominant(_ current: GitFileStatus?, _ candidate: GitFileStatus) -> GitFileStatus {
        guard let current else { return candidate }
        return candidate.priority > current.priority ? candidate : current
    }
}

/// Git decorations for one repository, keyed by root-relative path.
struct GitStatusSnapshot: Equatable, Sendable {
    var fileStatuses: [String: GitFileStatus] = [:]
    var folderStatuses: [String: GitFileStatus] = [:]
    var ignoredPaths: Set<String> = []

    static let empty = GitStatusSnapshot()

    init(entries: [(path: String, status: GitFileStatus)] = [], ignoredPaths: Set<String> = []) {
        for entry in entries {
            fileStatuses[entry.path] = GitFileStatus.dominant(fileStatuses[entry.path], entry.status)
            guard entry.status.propagatesToFolders else { continue }
            var folder = Substring(entry.path)
            while let slash = folder.lastIndex(of: "/") {
                folder = folder[..<slash]
                let key = String(folder)
                folderStatuses[key] = GitFileStatus.dominant(folderStatuses[key], entry.status)
            }
        }
        self.ignoredPaths = ignoredPaths
    }

    func status(forRelativePath path: String, isDirectory: Bool) -> GitFileStatus? {
        isDirectory ? folderStatuses[path] ?? fileStatuses[path] : fileStatuses[path]
    }

    /// A path is ignored when it, or any folder above it, is.
    func isIgnored(relativePath path: String) -> Bool {
        guard !ignoredPaths.isEmpty else { return false }
        var candidate = Substring(path)
        while true {
            if ignoredPaths.contains(String(candidate)) {
                return true
            }
            guard let slash = candidate.lastIndex(of: "/") else { return false }
            candidate = candidate[..<slash]
        }
    }

    /// Parses `git status --porcelain=v2 -z` output into one entry per
    /// staged and unstaged change. Unmerged paths count as modified.
    static func parseStatus(_ data: Data) -> [(path: String, status: GitFileStatus)] {
        var records = data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }[...]
        var entries: [(path: String, status: GitFileStatus)] = []

        func appendChanges(_ xy: Substring, path: String) {
            for character in xy where character != "." {
                entries.append((path, GitFileStatus(statusCharacter: character)))
            }
        }

        while let record = records.popFirst() {
            guard let kind = record.first else { continue }
            switch kind {
            case "1":
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                appendChanges(fields[1], path: String(fields[8]))
            case "2":
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                // The rename source follows as its own NUL-terminated record.
                _ = records.popFirst()
                guard fields.count == 10 else { continue }
                appendChanges(fields[1], path: String(fields[9]))
            case "u":
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                entries.append((String(fields[10]), .modified))
            case "?":
                entries.append((String(record.dropFirst(2)), .untracked))
            default:
                continue
            }
        }
        return entries
    }

    /// Parses `git ls-files -z --others --ignored --exclude-standard --directory`:
    /// ignored files, and ignored folders as one entry with a trailing slash.
    static func parseIgnored(_ data: Data) -> Set<String> {
        Set(data.split(separator: 0, omittingEmptySubsequences: true).map { bytes in
            var path = String(decoding: bytes, as: UTF8.self)
            if path.hasSuffix("/") {
                path.removeLast()
            }
            return path
        })
    }
}

// MARK: - Name Filter

/// The explorer's "Find files" filter: every whitespace-separated token must
/// appear, case-insensitively, somewhere in the root-relative path.
enum FileNameFilter {
    static func tokens(_ query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    static func matches(_ relativePath: String, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        let haystack = relativePath.lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }
}

// MARK: - Names

enum FileExplorerNaming {
    /// "stem copy.ext", then "stem copy 2.ext", "stem copy 3.ext", … — the
    /// first that `exists` reports free.
    static func duplicateName(for name: String, exists: (String) -> Bool) -> String {
        let (stem, pathExtension) = split(name)
        var candidate = "\(stem) copy\(pathExtension)"
        var number = 2
        while exists(candidate) {
            candidate = "\(stem) copy \(number)\(pathExtension)"
            number += 1
        }
        return candidate
    }

    /// The part of a name preselected for renaming: everything before the
    /// last dot, or the whole name when there is no extension.
    static func stemRange(of name: String) -> NSRange {
        let stemLength = (split(name).stem as NSString).length
        return NSRange(location: 0, length: stemLength)
    }

    private static func split(_ name: String) -> (stem: String, pathExtension: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return (name, "")
        }
        return (String(name[..<dot]), String(name[dot...]))
    }
}
