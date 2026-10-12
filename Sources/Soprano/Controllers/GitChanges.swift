import Foundation

// MARK: - Changed Files

/// The Source Control list's sections, in Orca's default order.
enum GitChangeArea: Int, CaseIterable, Comparable, Sendable {
    case conflicts
    case unstaged
    case staged
    case untracked

    var title: String {
        switch self {
        case .conflicts: "Conflicts"
        case .unstaged: "Changes"
        case .staged: "Staged Changes"
        case .untracked: "Untracked Files"
        }
    }

    static func < (lhs: GitChangeArea, rhs: GitChangeArea) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One changed file in one area. A file with staged and unstaged edits is
/// two changes, one per area, as in Orca.
struct GitChange: Hashable, Sendable {
    /// Root-relative; a rename's new path.
    var path: String
    /// Root-relative source of a staged rename or copy.
    var originalPath: String? = nil
    /// Unresolved conflicts count as modified.
    var status: GitFileStatus
    var area: GitChangeArea
    /// From `git diff --numstat`, or counted for untracked files; nil for
    /// binary files and files that were not counted.
    var linesAdded: Int? = nil
    var linesDeleted: Int? = nil

    var name: String { (path as NSString).lastPathComponent }
    /// The parent folder, empty at the root.
    var directory: String { (path as NSString).deletingLastPathComponent }
    /// The row's letter: git's status, or "!" for an unresolved conflict.
    var letter: String { area == .conflicts ? "!" : status.letter }
}

/// Added and deleted lines of one file; nil for a binary file's sides.
struct GitLineCounts: Equatable, Sendable {
    var added: Int?
    var deleted: Int?
}

/// What the Source Control list shows for one repository.
struct GitChangeList: Equatable, Sendable {
    /// The checked-out branch, or the short commit of a detached HEAD.
    var branch: String?
    /// Sorted by area, then naturally by path.
    var changes: [GitChange]

    static let empty = GitChangeList(branch: nil, changes: [])

    func changes(in area: GitChangeArea) -> [GitChange] {
        changes.filter { $0.area == area }
    }

    /// Parses `git status --porcelain=v2 -z --branch --untracked-files=all`:
    /// the index side of each entry is a staged change, the working tree side
    /// an unstaged one.
    static func parse(status data: Data) -> GitChangeList {
        var records = data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }[...]
        var head: String?
        var commit: String?
        var changes: [GitChange] = []

        func appendChanges(_ xy: Substring, path: String, originalPath: String? = nil) {
            guard xy.count == 2, let indexSide = xy.first, let workingTreeSide = xy.last else { return }
            for (character, area) in [(indexSide, GitChangeArea.staged), (workingTreeSide, .unstaged)]
                where character != "." {
                let status = GitFileStatus(statusCharacter: character)
                let source = status == .renamed || status == .copied ? originalPath : nil
                changes.append(GitChange(path: path, originalPath: source, status: status, area: area))
            }
        }

        while let record = records.popFirst() {
            if record.hasPrefix("# branch.head ") {
                head = String(record.dropFirst("# branch.head ".count))
                continue
            }
            if record.hasPrefix("# branch.oid ") {
                commit = String(record.dropFirst("# branch.oid ".count))
                continue
            }
            switch record.first {
            case "1":
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                appendChanges(fields[1], path: String(fields[8]))
            case "2":
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                // The rename source follows as its own NUL-terminated record.
                let source = records.popFirst()
                guard fields.count == 10 else { continue }
                appendChanges(fields[1], path: String(fields[9]), originalPath: source)
            case "u":
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                changes.append(GitChange(path: String(fields[10]), status: .modified, area: .conflicts))
            case "?":
                changes.append(GitChange(path: String(record.dropFirst(2)), status: .untracked, area: .untracked))
            default:
                continue
            }
        }

        changes.sort { lhs, rhs in
            if lhs.area != rhs.area {
                return lhs.area < rhs.area
            }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
        let branch: String? = if let head, head != "(detached)" {
            head
        } else if let commit, commit != "(initial)" {
            String(commit.prefix(7))
        } else {
            nil
        }
        return GitChangeList(branch: branch, changes: changes)
    }

    /// Parses `git diff -z --numstat --no-renames`: `added\tdeleted\tpath`
    /// records, with `-` counts for binary files.
    static func parseNumstat(_ data: Data) -> [String: GitLineCounts] {
        var counts: [String: GitLineCounts] = [:]
        for record in data.split(separator: 0, omittingEmptySubsequences: true) {
            let fields = String(decoding: record, as: UTF8.self)
                .split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            counts[String(fields[2])] = GitLineCounts(added: Int(fields[0]), deleted: Int(fields[1]))
        }
        return counts
    }

    mutating func applyLineCounts(_ counts: [String: GitLineCounts], in area: GitChangeArea) {
        for index in changes.indices where changes[index].area == area {
            guard let count = counts[changes[index].path] else { continue }
            changes[index].linesAdded = count.added
            changes[index].linesDeleted = count.deleted
        }
    }

    /// The number of lines in a file's contents, or nil for binary data
    /// (a NUL byte near the start, git's own test).
    static func lineCount(of data: Data) -> Int? {
        if data.prefix(8000).contains(0) {
            return nil
        }
        guard let last = data.last else { return 0 }
        let newline = UInt8(ascii: "\n")
        let newlines = data.reduce(0) { $1 == newline ? $0 + 1 : $0 }
        return last == newline ? newlines : newlines + 1
    }
}

// MARK: - File Diff

/// One line of a whole-file diff.
struct GitDiffLine: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case context
        case removed
        case added
    }

    var kind: Kind
    /// Line number on the old side; nil for added lines.
    var oldNumber: Int?
    /// Line number on the new side; nil for removed lines.
    var newNumber: Int?
    var text: String
}

/// One file's diff, read with full context so the whole file is shown with
/// its changes marked, like Orca's diff editor.
enum GitFileDiff: Equatable, Sendable {
    case text([GitDiffLine])
    case binary
    /// Both sides have the same text: only the mode changed, or the change
    /// was reverted since it was listed.
    case noChanges
    /// More output than `GitStatusReader.maximumDiffBytes`.
    case tooLarge
    /// git is missing or failed.
    case unavailable

    /// Parses `git diff` output for a single file.
    static func parse(patch data: Data) -> GitFileDiff {
        var rawLines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if rawLines.last?.isEmpty == true {
            rawLines.removeLast()
        }
        var lines: [GitDiffLine] = []
        var oldNumber = 0
        var newNumber = 0
        var inHunk = false
        var hasChanges = false

        for raw in rawLines {
            var bytes = raw
            if bytes.last == UInt8(ascii: "\r") {
                bytes = bytes.dropLast()
            }
            if bytes.starts(with: "@@ ".utf8) {
                guard let start = hunkStart(bytes) else { return .unavailable }
                oldNumber = start.old
                newNumber = start.new
                inHunk = true
                continue
            }
            guard inHunk else {
                if bytes.starts(with: "Binary files ".utf8) || bytes.starts(with: "GIT binary patch".utf8) {
                    return .binary
                }
                continue
            }
            // `diff.suppressBlankEmpty` drops the space before an empty context line.
            let marker = bytes.first ?? UInt8(ascii: " ")
            let text = String(decoding: bytes.dropFirst(), as: UTF8.self)
            switch marker {
            case UInt8(ascii: " "):
                lines.append(GitDiffLine(kind: .context, oldNumber: oldNumber, newNumber: newNumber, text: text))
                oldNumber += 1
                newNumber += 1
            case UInt8(ascii: "-"):
                lines.append(GitDiffLine(kind: .removed, oldNumber: oldNumber, newNumber: nil, text: text))
                oldNumber += 1
                hasChanges = true
            case UInt8(ascii: "+"):
                lines.append(GitDiffLine(kind: .added, oldNumber: nil, newNumber: newNumber, text: text))
                newNumber += 1
                hasChanges = true
            case UInt8(ascii: "\\"):
                // "\ No newline at end of file"
                continue
            default:
                inHunk = false
            }
        }
        return hasChanges ? .text(lines) : .noChanges
    }

    /// "@@ -12,3 +12,4 @@ …" → (12, 12).
    private static func hunkStart(_ header: Data) -> (old: Int, new: Int)? {
        let parts = String(decoding: header, as: UTF8.self).split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func start(_ range: Substring) -> Int? {
            range.dropFirst().split(separator: ",", omittingEmptySubsequences: false).first.flatMap { Int($0) }
        }
        guard let old = start(parts[1]), let new = start(parts[2]) else { return nil }
        return (old, new)
    }
}

// MARK: - Layout

/// One visual row of a diff view.
struct GitDiffRow: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case context
        case removed
        case added
        /// Pads the shorter side of a side-by-side change so both sides
        /// stay aligned.
        case filler
    }

    var kind: Kind
    /// Index into the diff's lines; nil for filler rows.
    var lineIndex: Int?
    /// The UTF-16 range of the line that differs from the line it replaces
    /// or is replaced by, for a stronger tint. Nil when the whole line differs.
    var changedRange: NSRange? = nil
}

/// A diff's rows for an inline view, or for one side of a side-by-side view.
struct GitDiffLayout: Equatable, Sendable {
    var rows: [GitDiffRow] = []
    /// The first row of each run of changed rows, in order.
    var changeStarts: [Int] = []

    /// Every line in file order, each change's removed lines above its added ones.
    static func inline(_ lines: [GitDiffLine]) -> GitDiffLayout {
        var layout = GitDiffLayout()
        for segment in segments(lines) {
            switch segment {
            case .context(let index):
                layout.rows.append(GitDiffRow(kind: .context, lineIndex: index))
            case .change(let removed, let added):
                layout.changeStarts.append(layout.rows.count)
                let ranges = pairedRanges(lines, removed: removed, added: added)
                for (pair, index) in removed.enumerated() {
                    let range = pair < ranges.count ? ranges[pair]?.old : nil
                    layout.rows.append(GitDiffRow(kind: .removed, lineIndex: index, changedRange: range))
                }
                for (pair, index) in added.enumerated() {
                    let range = pair < ranges.count ? ranges[pair]?.new : nil
                    layout.rows.append(GitDiffRow(kind: .added, lineIndex: index, changedRange: range))
                }
            }
        }
        return layout
    }

    /// The old file on the left, the new one on the right, row for row: a
    /// change's removed and added lines face each other, and the shorter
    /// side is padded with filler rows.
    static func sideBySide(_ lines: [GitDiffLine]) -> (old: GitDiffLayout, new: GitDiffLayout) {
        var old = GitDiffLayout()
        var new = GitDiffLayout()
        for segment in segments(lines) {
            switch segment {
            case .context(let index):
                old.rows.append(GitDiffRow(kind: .context, lineIndex: index))
                new.rows.append(GitDiffRow(kind: .context, lineIndex: index))
            case .change(let removed, let added):
                old.changeStarts.append(old.rows.count)
                new.changeStarts.append(new.rows.count)
                let ranges = pairedRanges(lines, removed: removed, added: added)
                for pair in 0..<max(removed.count, added.count) {
                    let range = pair < ranges.count ? ranges[pair] : nil
                    old.rows.append(pair < removed.count
                        ? GitDiffRow(kind: .removed, lineIndex: removed[pair], changedRange: range?.old)
                        : GitDiffRow(kind: .filler, lineIndex: nil))
                    new.rows.append(pair < added.count
                        ? GitDiffRow(kind: .added, lineIndex: added[pair], changedRange: range?.new)
                        : GitDiffRow(kind: .filler, lineIndex: nil))
                }
            }
        }
        return (old, new)
    }

    /// The differing middle of two lines that share a prefix or a suffix, as
    /// UTF-16 ranges in each; nil when they share neither or are equal.
    static func changedRanges(old: String, new: String) -> (old: NSRange, new: NSRange)? {
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)
        let shorter = min(oldUnits.count, newUnits.count)
        var prefix = 0
        while prefix < shorter, oldUnits[prefix] == newUnits[prefix] {
            prefix += 1
        }
        // Never split a surrogate pair.
        if prefix > 0, prefix < oldUnits.count, UTF16.isLeadSurrogate(oldUnits[prefix - 1]) {
            prefix -= 1
        }
        var suffix = 0
        while suffix < shorter - prefix,
              oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] {
            suffix += 1
        }
        if suffix > 0, UTF16.isTrailSurrogate(oldUnits[oldUnits.count - suffix]) {
            suffix -= 1
        }
        let oldLength = oldUnits.count - prefix - suffix
        let newLength = newUnits.count - prefix - suffix
        guard prefix > 0 || suffix > 0, oldLength > 0 || newLength > 0 else { return nil }
        return (NSRange(location: prefix, length: oldLength), NSRange(location: prefix, length: newLength))
    }

    private enum Segment {
        case context(Int)
        case change(removed: [Int], added: [Int])
    }

    /// Context lines one by one, and each run of changed lines as one change.
    private static func segments(_ lines: [GitDiffLine]) -> [Segment] {
        var segments: [Segment] = []
        var removed: [Int] = []
        var added: [Int] = []
        func flush() {
            guard !removed.isEmpty || !added.isEmpty else { return }
            segments.append(.change(removed: removed, added: added))
            removed = []
            added = []
        }
        for (index, line) in lines.enumerated() {
            switch line.kind {
            case .context:
                flush()
                segments.append(.context(index))
            case .removed:
                removed.append(index)
            case .added:
                added.append(index)
            }
        }
        flush()
        return segments
    }

    /// The n-th removed line of a change is taken to be replaced by its n-th
    /// added line.
    private static func pairedRanges(
        _ lines: [GitDiffLine],
        removed: [Int],
        added: [Int]
    ) -> [(old: NSRange, new: NSRange)?] {
        (0..<min(removed.count, added.count)).map { pair in
            changedRanges(old: lines[removed[pair]].text, new: lines[added[pair]].text)
        }
    }
}

// MARK: - Highlighting

/// Syntax colors for both sides of a diff, per line, so every row is colored
/// as the line reads in its own version of the file.
struct GitDiffHighlights: Equatable, Sendable {
    /// Larger sides stay uncolored, like large files in the editor.
    static let maximumLength = 1_500_000

    /// Indexed like the diff's lines, with ranges relative to the line; empty
    /// for lines that are not on that side.
    var old: [[SyntaxToken]] = []
    var new: [[SyntaxToken]] = []

    static func compute(_ lines: [GitDiffLine], language: CodeLanguage?) -> GitDiffHighlights {
        guard let language else { return GitDiffHighlights() }
        return GitDiffHighlights(
            old: side(of: lines, excluding: .added, language: language),
            new: side(of: lines, excluding: .removed, language: language)
        )
    }

    /// Highlights one version of the file as a whole, so multi-line strings
    /// and comments color correctly, then splits the tokens per line.
    private static func side(
        of lines: [GitDiffLine],
        excluding excluded: GitDiffLine.Kind,
        language: CodeLanguage
    ) -> [[SyntaxToken]] {
        var result = Array(repeating: [SyntaxToken](), count: lines.count)
        var indices: [Int] = []
        var starts: [Int] = []
        var lengths: [Int] = []
        var text = ""
        var length = 0
        for (index, line) in lines.enumerated() where line.kind != excluded {
            if !indices.isEmpty {
                text += "\n"
                length += 1
            }
            let lineLength = line.text.utf16.count
            indices.append(index)
            starts.append(length)
            lengths.append(lineLength)
            text += line.text
            length += lineLength
            if length > maximumLength {
                return result
            }
        }

        for token in CodeSyntaxHighlighter.tokens(in: text, language: language) {
            let tokenEnd = NSMaxRange(token.range)
            // The last line starting at or before the token.
            var low = 0
            var high = starts.count
            while low < high {
                let middle = (low + high) / 2
                if starts[middle] <= token.range.location {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            var line = max(0, low - 1)
            while line < starts.count, starts[line] < tokenEnd {
                let from = max(token.range.location, starts[line])
                let to = min(tokenEnd, starts[line] + lengths[line])
                if to > from {
                    result[indices[line]].append(SyntaxToken(
                        range: NSRange(location: from - starts[line], length: to - from),
                        kind: token.kind
                    ))
                }
                line += 1
            }
        }
        return result
    }
}
