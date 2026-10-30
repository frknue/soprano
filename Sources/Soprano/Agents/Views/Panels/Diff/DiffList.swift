import AppKit
import SopranoAgentsCore

/// One file of a loaded diff, prepared off the main thread: its rows in both layouts and its
/// syntax colors.
struct DiffFileEntry: Equatable, Sendable {
    var file: FileDiff
    var document: DiffDocument
    var highlights: DiffHighlights

    var path: String { file.path }
    var additions: Int { document.additions }
    var deletions: Int { document.deletions }

    /// Parses a unified diff and prepares every file. Runs off the main thread.
    nonisolated static func prepare(patch: String) -> [DiffFileEntry] {
        DiffParser.parse(patch).map { file in
            let document = DiffDocument.build(files: [file], title: file.path)
            let highlights = DiffHighlights.applies(to: document, isConflicted: false)
                ? DiffHighlights.compute(file: file)
                : .none
            return DiffFileEntry(file: file, document: document, highlights: highlights)
        }
    }
}

/// A row of the diff surface's list: every file's header, then (unless the file is collapsed)
/// its hunks and lines in the chosen layout.
enum DiffListRow: Hashable {
    case fileHeader(file: Int)
    /// Separator before `entries[file].file.hunks[hunk]`.
    case hunk(file: Int, hunk: Int)
    /// Stacked layout: `…hunks[hunk].lines[line]`.
    case line(file: Int, hunk: Int, line: Int)
    /// Split layout: old line on the left, new line on the right; nil is a filler.
    case pair(file: Int, hunk: Int, old: Int?, new: Int?)
    /// Muted one-liner (binary file, rename only, mode change, truncation).
    case notice(file: Int, text: String)
    /// Space after an expanded file.
    case fileEnd(file: Int)

    var file: Int {
        switch self {
        case let .fileHeader(file), let .hunk(file, _), let .line(file, _, _), let .pair(file, _, _, _),
             let .notice(file, _), let .fileEnd(file):
            file
        }
    }
}

struct DiffList: Equatable {
    var rows: [DiffListRow]
    /// Row of each file's header, by file index.
    var fileRows: [Int]

    static let empty = DiffList(rows: [], fileRows: [])

    static func build(entries: [DiffFileEntry], collapsed: Set<Int>, layout: DiffLayout) -> DiffList {
        var rows: [DiffListRow] = []
        var fileRows: [Int] = []
        rows.reserveCapacity(entries.enumerated().reduce(0) { total, item in
            total + 2 + (collapsed.contains(item.offset) ? 0 : item.element.document.rows.count)
        })
        for (index, entry) in entries.enumerated() {
            fileRows.append(rows.count)
            rows.append(.fileHeader(file: index))
            guard !collapsed.contains(index) else { continue }
            if let notice = entry.document.notice {
                rows.append(.notice(file: index, text: notice))
            } else {
                for row in entry.document.rows(in: layout) {
                    switch row {
                    case let .hunk(hunk): rows.append(.hunk(file: index, hunk: hunk))
                    case let .line(hunk, line): rows.append(.line(file: index, hunk: hunk, line: line))
                    case let .pair(hunk, old, new): rows.append(.pair(file: index, hunk: hunk, old: old, new: new))
                    case let .notice(text): rows.append(.notice(file: index, text: text))
                    }
                }
            }
            rows.append(.fileEnd(file: index))
        }
        return DiffList(rows: rows, fileRows: fileRows)
    }

    /// Lines a hunk's separator reports as hidden before it ("N unmodified lines").
    static func hiddenLines(before hunk: Int, in file: FileDiff) -> Int {
        guard file.hunks.indices.contains(hunk) else { return 0 }
        let start = file.hunks[hunk].oldStart
        if hunk == 0 { return max(0, start - 1) }
        let previous = file.hunks[hunk - 1]
        return max(0, start - (previous.oldStart + previous.oldCount))
    }
}

/// The file tree beside the diff: directories (single-child chains joined, "Sources/Auth")
/// and files, depth-first with directories before files, each level sorted by name.
struct DiffTreeItem: Equatable {
    enum Kind: Equatable {
        case directory
        /// Index into the loaded files.
        case file(Int)
    }

    var name: String
    var depth: Int
    var kind: Kind

    static func build(paths: [String]) -> [DiffTreeItem] {
        final class Node {
            var children: [String: Node] = [:]
            var file: Int?
        }
        let root = Node()
        for (index, path) in paths.enumerated() {
            var node = root
            let parts = path.split(separator: "/").map(String.init)
            for (position, part) in parts.enumerated() {
                let key = position == parts.count - 1 ? "\u{1}" + part : part
                let child = node.children[key] ?? Node()
                node.children[key] = child
                node = child
            }
            node.file = index
        }
        var items: [DiffTreeItem] = []
        func visit(_ node: Node, depth: Int) {
            let directories = node.children.filter { !$0.key.hasPrefix("\u{1}") }.sorted { $0.key < $1.key }
            let files = node.children.filter { $0.key.hasPrefix("\u{1}") }.sorted { $0.key < $1.key }
            for (name, child) in directories {
                var label = name
                var current = child
                // Join chains of directories that hold a single directory and nothing else.
                while current.children.count == 1, let (key, only) = current.children.first, !key.hasPrefix("\u{1}") {
                    label += "/" + key
                    current = only
                }
                items.append(DiffTreeItem(name: label, depth: depth, kind: .directory))
                visit(current, depth: depth + 1)
            }
            for (key, child) in files {
                guard let file = child.file else { continue }
                items.append(DiffTreeItem(name: String(key.dropFirst()), depth: depth, kind: .file(file)))
            }
        }
        visit(root, depth: 0)
        return items
    }
}
